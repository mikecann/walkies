import CoreLocation
import Foundation
import Observation
import os

@Observable
final class AppModel {
    private(set) var cities: [City] = []
    private(set) var walks: [Walk] = []
    var selectedCityID: UUID? {
        didSet { UserDefaults.standard.set(selectedCityID?.uuidString, forKey: "selectedCity") }
    }
    /// Bumps when the map should fly to the selected place: when you pick or add one,
    /// not when it changes because you've walked into it.
    private(set) var flyToSelected = 0
    /// Where you were at the last GPS fix, for things like sorting secrets by distance.
    private(set) var lastLocation: CLLocation?
    /// Set when the app opens, so the next fix selects the place you're in. Otherwise the
    /// selection only follows you on a walk, so looking at another place sticks.
    @ObservationIgnored var placeYouOnNextFix = true
    private(set) var activeWalk: Walk?
    /// Accepted fixes from the current walk, for drawing the line on the map.
    private(set) var activePath: [Coordinate] = []
    /// Tiles uncovered on the current walk, per city, so the map can make a fuss of them.
    private(set) var freshTiles: [UUID: Set<Hex>] = [:]
    /// Bumps whenever any city's tiles change.
    private(set) var tilesRevision = 0
    /// Bumps for every newly uncovered tile, to drive haptics.
    private(set) var revealCount = 0
    /// Set when a walk ends, to play the celebration.
    var recap: WalkRecap?
    /// Tilted, isometric-style map with Apple's 3D buildings and trees. On unless
    /// you turn it off. (A new key, so phones that had the old flat default get it too.)
    var tilted3D = UserDefaults.standard.object(forKey: "map3D") as? Bool ?? true {
        didSet { UserDefaults.standard.set(tilted3D, forKey: "map3D") }
    }
    /// Whether the first-run setup (location, motion, notifications, Always on) is done.
    var setupDone = UserDefaults.standard.bool(forKey: "setupDone") {
        didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") }
    }
    /// Record walks by themselves in the background, so there's no Start walk to press.
    var alwaysOn = false {
        didSet {
            guard alwaysOn != oldValue else { return }
            UserDefaults.standard.set(alwaysOn, forKey: "alwaysOn")
            alwaysOn ? turnOnAlwaysOn() : turnOffAlwaysOn()
        }
    }

    /// In always-on mode, a walk ends after this long without moving on foot.
    /// Overridable with `-autoWalkGap <seconds>` for testing in the simulator.
    static var autoWalkGap: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "autoWalkGap")
        return override > 0 ? override : 10 * 60
    }

    /// Shorter than this and it wasn't really a walk: pottering round the house, or
    /// GPS drift. Any tiles it uncovered stay uncovered.
    static let minimumAutoWalk = 300.0

    /// An always-on walk only counts once you've got this far (metres, as the crow
    /// flies) from where it started. GPS indoors can wander tens of metres back and
    /// forth, which adds up as distance but never carries you this far away.
    static let autoWalkConfirmDistance = 150.0

    /// True while an always-on walk has started but you haven't gone far enough yet to
    /// be sure it's a real one. Nothing gets uncovered until it's sure.
    private(set) var autoWalkPending = false

    let tracker = LocationTracker()
    let motion = MotionMonitor()
    @ObservationIgnored private let store = Store()
    @ObservationIgnored private var tracer = CoverageTracer()
    @ObservationIgnored private var shapes: [UUID: BoundaryShape] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var startWhenAllowed = false

    init() {
        ledger = store.loadProgress()
        cities = store.loadCities()
        alwaysOn = UserDefaults.standard.bool(forKey: "alwaysOn")

        // A walk without an end means the app was killed mid-walk. If iOS has just
        // relaunched us during an always-on walk, carry on with it; otherwise close it off.
        for var walk in store.loadWalks() {
            if walk.endedAt == nil {
                if alwaysOn, walk.isAutomatic, let last = walk.points.last,
                   Date.now.timeIntervalSince1970 - last.time < Self.autoWalkGap {
                    activeWalk = walk
                    autoWalkPending = Self.displacement(of: walk.points) < Self.autoWalkConfirmDistance
                    activePath = autoWalkPending ? [] : walk.points.map(\.coordinate)
                    continue
                }
                walk.endedAt = walk.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? walk.startedAt
                store.save(walk)
            }
            walks.append(walk)
        }

        let saved = UserDefaults.standard.string(forKey: "selectedCity").flatMap(UUID.init)
        selectedCityID = cities.first { $0.id == saved }?.id ?? cities.first?.id

        tracker.onLocation = { [weak self] in self?.record($0) }
        tracker.onAuthorizationChange = { [weak self] in self?.authorizationChanged() }
        fetchMissingRoads()
        foundStickers = store.loadStickers()
        placeStickers()
        refreshNeighbours()
        refreshProgressPicks()
    }

    /// Cities saved before we kept road lines get them fetched again in the background.
    private func fetchMissingRoads() {
        for city in cities where city.roads == nil {
            let id = city.id
            let b = city.boundary.bounds
            Task {
                guard let ways = try? await OSMClient.walkableWays(south: b.south, west: b.west, north: b.north, east: b.east),
                      let i = cities.firstIndex(where: { $0.id == id })
                else { return }
                cities[i].roads = CityBuilder.roadLines(from: ways)
                cities[i].updatedAt = .now
                tilesRevision += 1
                store.save(cities)
            }
        }
    }

    var selectedCity: City? { cities.first { $0.id == selectedCityID } }

    /// What the cloud layer draws: every place at once. Working out which tiles are
    /// clouded takes a moment on a big place, so it's only redone when the tiles change.
    @ObservationIgnored private var cachedField: (key: String, field: CloudField)?

    var cloudKey: String { "\(tilesRevision)-\(cities.count)" }

    var cloudField: CloudField {
        let key = cloudKey
        if let cachedField, cachedField.key == key { return cachedField.field }
        let field = CloudField(cities: cities)
        cachedField = (key, field)
        return field
    }

    // MARK: Walks

    func startWalk() {
        guard activeWalk == nil, !alwaysOn else { return }
        switch tracker.authorization {
        case .notDetermined:
            startWhenAllowed = true
            tracker.requestPermissionIfNeeded()
            return
        case .denied, .restricted:
            return
        default:
            break
        }
        activeWalk = Walk(startedAt: .now)
        activePath = []
        freshTiles = [:]
        tracer = CoverageTracer()
        tracker.start()
        Notifier.requestPermission()
    }

    func endWalk() {
        guard var walk = activeWalk else { return }
        tracker.stop()
        walk.endedAt = .now
        let counts = freshTiles.countsByPlaceID
        // A walk resumed after a restart may have fresh tiles from before launch.
        // Leave counts nil then, so quest history replays its whole saved route.
        walk.newTilesByPlace = counts.values.reduce(0, +) == walk.newTiles ? counts : nil
        let history = walks
        let fresh = freshTiles
        walks.append(walk)
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        tilesRevision += 1
        store.save(walk)
        store.save(cities)
        recap = WalkRecap.make(walk: walk, cities: cities, fresh: fresh, found: foundStickers, history: history)
        refreshProgressPicks()
        requestSync?()
    }

    /// Plays an old walk's celebration again, from walk history. Which tiles were new
    /// on it is worked out again: the tiles under its route that no earlier walk crossed.
    func replay(_ walk: Walk) {
        let earlier = walks.filter { $0.id != walk.id && $0.startedAt < walk.startedAt }
        var fresh: [UUID: Set<Hex>] = [:]
        var before = cities
        for i in before.indices {
            var city = before[i]
            city.visited = []
            let shape = shape(for: city)
            for old in earlier { _ = city.visit(CoverageTracer.samples(for: old.points), within: shape) }
            let new = city.visit(CoverageTracer.samples(for: walk.points), within: shape)
            if !new.isEmpty { fresh[city.id] = new }
            before[i] = city
        }
        recap = WalkRecap.make(walk: walk, cities: before, fresh: fresh, found: foundStickers, history: earlier)
    }

    /// The End walk button on an always-on walk: ends it now and plays the celebration.
    func endAutoWalk() {
        finishAutoWalk(byYou: true)
    }

    func saveNow() {
        if let activeWalk { store.save(activeWalk) }
        store.save(cities)
        lastSave = .now
    }

    private func record(_ location: CLLocation) {
        // iOS can hand over a cached fix from wherever you last were when tracking starts.
        guard location.timestamp.timeIntervalSinceNow > -10 else { return }
        lastLocation = location
        var point = TrackPoint(location)
        if motion.onWheels { point.wheels = true }
        if motion.still { point.still = true }
        if alwaysOn {
            recordAlwaysOn(point)
        } else if activeWalk != nil {
            recordWalk(point)
        }
        if activeWalk != nil || placeYouOnNextFix {
            placeYouOnNextFix = false
            followIntoPlace(at: point.coordinate)
        }
    }

    /// On a walk, whichever of your places you're in becomes the selected one, so the
    /// percentage and secrets are for where you are. The map doesn't jump to it.
    private func followIntoPlace(at point: Coordinate) {
        if let current = selectedCity, shape(for: current).contains(current.grid.projection.project(point)) { return }
        if let here = cities.first(where: { shape(for: $0).contains($0.grid.projection.project(point)) }) {
            selectedCityID = here.id
        }
    }

    /// Picks a place to look at, and flies the map there.
    func select(_ id: UUID) {
        selectedCityID = id
        flyToSelected += 1
    }

    /// A walk you started yourself: keep every fix.
    private func recordWalk(_ point: TrackPoint) {
        guard var walk = activeWalk else { return }
        walk.points.append(point)
        apply(tracer.add(point), at: point, to: &walk)
        activeWalk = walk
        saveIfDue()
    }

    /// Always on: a walk starts the moment you're moving on foot and ends once you've
    /// stopped for a while. Only on-foot fixes are kept, so drives don't fill the phone.
    private func recordAlwaysOn(_ point: TrackPoint) {
        if let last = activeWalk?.points.last, point.time - last.time > Self.autoWalkGap {
            finishAutoWalk()
        }
        let step = tracer.add(point)
        guard !step.samples.isEmpty else { return }
        if activeWalk == nil {
            activeWalk = Walk(startedAt: Date(timeIntervalSince1970: point.time), automatic: true)
            activePath = []
            freshTiles = [:]
            autoWalkPending = true
        }
        guard var walk = activeWalk else { return }
        walk.points.append(point)
        if autoWalkPending {
            walk.distance += step.distance
            if Self.displacement(of: walk.points) >= Self.autoWalkConfirmDistance {
                // It's a real walk: uncover everything since it started in one go.
                autoWalkPending = false
                let samples = CoverageTracer.samples(for: walk.points)
                activePath = samples
                let uncovered = visit(samples)
                walk.newTiles += uncovered
                revealCount += uncovered
            }
        } else {
            apply(step, at: point, to: &walk)
        }
        activeWalk = walk
        saveIfDue()
    }

    /// How far a pending walk has got from where it started, in metres.
    var pendingWalkDistance: Double {
        activeWalk.map { Self.displacement(of: $0.points) } ?? 0
    }

    /// How far the furthest point gets from the first, in metres.
    static func displacement(of points: [TrackPoint]) -> Double {
        guard let first = points.first?.coordinate else { return 0 }
        return points.map { first.distance(to: $0.coordinate) }.max() ?? 0
    }

    private func apply(_ step: CoverageTracer.Step, at point: TrackPoint, to walk: inout Walk) {
        walk.distance += step.distance
        guard !step.samples.isEmpty else { return }
        activePath.append(point.coordinate)
        let uncovered = visit(step.samples)
        if uncovered > 0 {
            walk.newTiles += uncovered
            revealCount += uncovered
        }
    }

    private func saveIfDue() {
        if Date.now.timeIntervalSince(lastSave) > 30 {
            saveNow()
        }
    }

    /// Closes an always-on walk that's gone quiet. New fixes do this too, but there
    /// may not be any for a while, so the app checks again whenever it comes back.
    func finishStaleAutoWalk() {
        guard let last = activeWalk?.points.last,
              Date.now.timeIntervalSince1970 - last.time > Self.autoWalkGap
        else { return }
        finishAutoWalk()
    }

    /// - Parameter byYou: you pressed End walk, so it ends now and is kept however short.
    ///   Otherwise it ended by itself, at its last fix, and only counts if it's long enough.
    private func finishAutoWalk(byYou: Bool = false) {
        guard var walk = activeWalk, walk.isAutomatic else { return }
        let wasPending = autoWalkPending
        let fresh = freshTiles
        autoWalkPending = false
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        tracer = CoverageTracer()
        tilesRevision += 1
        walk.endedAt = byYou ? .now : walk.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? walk.startedAt
        // Measure again by today's rules, so walks logged by older versions (or GPS
        // wobble at home) don't get kept as real ones. Tiles already uncovered stay.
        walk.distance = CoverageTracer.distance(for: walk.points)
        let counts = fresh.countsByPlaceID
        walk.newTilesByPlace = counts.values.reduce(0, +) == walk.newTiles ? counts : nil
        if !wasPending, byYou || walk.distance >= Self.minimumAutoWalk {
            let history = walks
            walks.append(walk)
            store.save(walk)
            // If it ended by itself while the phone was in your pocket, this plays the
            // next time you open the app.
            recap = WalkRecap.make(walk: walk, cities: cities, fresh: fresh, found: foundStickers, history: history)
        } else {
            store.delete(walk)
        }
        store.save(cities)
        refreshProgressPicks()
        requestSync?()
    }

    // MARK: Always on

    /// Called at launch, including when iOS relaunches the app in the background.
    func resumeAlwaysOn() {
        // Starting motion asks for permission, so leave that to the setup the first time.
        if setupDone { motion.start() }
        if alwaysOn {
            tracker.startAlwaysOn()
        }
    }

    private func turnOnAlwaysOn() {
        Notifier.requestPermission()
        // Hand over from a walk you started yourself, without the summary popping up.
        if activeWalk != nil {
            endWalk()
            recap = nil
        }
        tracer = CoverageTracer()
        if !tracker.hasAlwaysPermission {
            tracker.requestAlwaysPermission()
        }
        tracker.startAlwaysOn()
    }

    private func turnOffAlwaysOn() {
        tracker.stopAlwaysOn()
        finishAutoWalk()
    }

    /// Marks these points as visited in every city. Returns how many tiles were new.
    private func visit(_ points: [Coordinate]) -> Int {
        var uncovered = 0
        for i in cities.indices {
            var city = cities[i]
            let fresh = city.visit(points, within: shape(for: city))
            guard !fresh.isEmpty else { continue }
            city.updatedAt = .now
            cities[i] = city
            freshTiles[city.id, default: []].formUnion(fresh)
            uncovered += fresh.count
            unlockStickers(in: city, on: fresh, notify: true, popUp: true)
        }
        if uncovered > 0 { tilesRevision += 1 }
        return uncovered
    }

    // MARK: Stickers

    /// When each sticker was found, by lore id.
    private(set) var foundStickers: [String: Date] = [:] {
        didSet { secretsRevision += 1 }
    }
    private var secretsRevision = 0
    /// Stickers just found, waiting to pop up.
    var stickerQueue: [LoreEntry] = []

    /// Every sticker hidden in the selected city, found or not.
    var stickersHere: [(entry: LoreEntry, hex: Hex)] {
        guard let placed = selectedCity?.stickers else { return [] }
        return placed
            .compactMap { id, hex in LoreLibrary.entry(id: id).map { ($0, hex) } }
            .sorted { $0.entry.title < $1.entry.title }
    }

    /// Hides each place's secrets under its tiles. A secret that now belongs to a
    /// different place (say its suburb's just been added) moves there, unless you've
    /// already found it, when it stays where you found it. Secrets under tiles you've
    /// already walked are yours straight away.
    private func placeStickers() {
        let assigned = LoreLibrary.assign(to: cities) { city, point in
            shape(for: city).contains(city.grid.projection.project(point))
        }
        var changed = false
        for i in cities.indices {
            let wanted = Set((assigned[cities[i].id] ?? []).map(\.id))
            guard var placed = cities[i].stickers else { continue }
            let leaving = placed.keys.filter { !wanted.contains($0) && foundStickers[$0] == nil }
            guard !leaving.isEmpty else { continue }
            for id in leaving { placed[id] = nil }
            cities[i].stickers = placed
            cities[i].updatedAt = .now
            changed = true
        }
        let hidden = Set(cities.flatMap { $0.stickers?.keys.map { $0 } ?? [] })
        for i in cities.indices {
            let missing = (assigned[cities[i].id] ?? []).filter { !hidden.contains($0.id) }
            guard !missing.isEmpty else { continue }
            let placed = cities[i].stickers ?? [:]
            cities[i].stickers = placed.merging(cities[i].placeStickers(missing, avoiding: Set(placed.values))) { old, _ in old }
            cities[i].updatedAt = .now
            changed = true
            unlockStickers(in: cities[i], on: cities[i].visited, notify: false, popUp: true)
        }
        if changed {
            tilesRevision += 1
            store.save(cities)
        }
    }

    private func unlockStickers(in city: City, on hexes: Set<Hex>, notify: Bool, popUp: Bool) {
        guard let placed = city.stickers else { return }
        let ids = placed.filter { hexes.contains($0.value) && foundStickers[$0.key] == nil }.map(\.key)
        guard !ids.isEmpty else { return }
        let entries = ids.sorted().compactMap(LoreLibrary.entry(id:))
        for entry in entries { foundStickers[entry.id] = .now }
        store.save(stickers: foundStickers)
        if popUp { stickerQueue.append(contentsOf: entries) }
        if notify { Notifier.stickersFound(entries) }
        refreshProgressPicks()
        requestSync?()
    }

    private func authorizationChanged() {
        guard startWhenAllowed, tracker.authorization != .notDetermined else { return }
        startWhenAllowed = false
        startWalk()
    }

    // MARK: Cities

    func add(_ city: City) {
        var city = city
        city.updatedAt = .now
        cities.append(city)
        shapes[city.id] = city.shape()
        select(city.id)
        placeStickers()
        tilesRevision += 1
        store.save(cities)
        refreshProgressPicks()
        requestSync?()
        refreshNeighbours()
    }

    func deleteCities(at offsets: IndexSet) {
        let removed = offsets.map { cities[$0].id }
        cities.remove(atOffsets: offsets)
        for id in removed { shapes[id] = nil }
        if let selectedCityID, removed.contains(selectedCityID) {
            self.selectedCityID = cities.first?.id
        }
        tilesRevision += 1
        placeStickers()
        store.save(cities)
        refreshProgressPicks()
        requestSync?()
    }

    // MARK: Neighbours

    /// Suburbs around your places, fetched from OpenStreetMap.
    private(set) var nearby: [PlaceResult] = []
    @ObservationIgnored private var fetchingNearby = false
    @ObservationIgnored private var nearbyRetries = 0
    nonisolated private static let log = Logger(subsystem: "com.mikecann.walkies", category: "places")

    /// How far around your places to offer suburbs, in metres. Twice this is fetched
    /// and kept, so adding the next suburb over doesn't mean fetching again.
    static let neighbourhood = 5000.0

    /// Suburbs within reach of your places that you haven't added yet, for the map to offer.
    var neighbours: [PlaceResult] {
        guard let box = box(around: Self.neighbourhood) else { return [] }
        let have = Set(cities.map { $0.name.lowercased() })
        return nearby.filter { place in
            let b = place.boundary.bounds
            return !have.contains(place.name.lowercased()) && place.area <= CityBuilder.maxArea
                && b.north >= box.south && b.south <= box.north && b.east >= box.west && b.west <= box.east
        }
    }

    /// The box around all your places, grown by this many metres each way.
    private func box(around metres: Double) -> (south: Double, west: Double, north: Double, east: Double)? {
        let all = cities.map(\.boundary.bounds)
        guard let south = all.map(\.south).min(), let west = all.map(\.west).min(),
              let north = all.map(\.north).max(), let east = all.map(\.east).max()
        else { return nil }
        let dLat = metres / 111_320
        let dLon = dLat / max(0.1, cos((south + north) / 2 * .pi / 180))
        return (south - dLat, west - dLon, north + dLat, east + dLon)
    }

    /// Uses the saved list if it still covers your places and is under a month old.
    /// Otherwise asks Overpass, which is quick when it's up, and falls back to asking
    /// Nominatim point by point when it isn't. Tries again a few times if both fail,
    /// and again whenever the app comes back.
    func refreshNeighbours() {
        guard !fetchingNearby, let wanted = box(around: Self.neighbourhood), let fetch = box(around: Self.neighbourhood * 2) else { return }
        if let saved = store.loadNearby(),
           saved.covers(south: wanted.south, west: wanted.west, north: wanted.north, east: wanted.east),
           saved.fetchedAt.timeIntervalSinceNow > -30 * 24 * 3600 {
            nearby = saved.places
            return
        }
        fetchingNearby = true
        let points = samplePoints(in: wanted)
        Task {
            defer { fetchingNearby = false }
            var found: (places: [PlaceResult], box: (south: Double, west: Double, north: Double, east: Double))?
            do {
                found = (try await OSMClient.placesNear(south: fetch.south, west: fetch.west, north: fetch.north, east: fetch.east), fetch)
            } catch {
                Self.log.error("Overpass couldn't list suburbs, asking Nominatim instead: \(error)")
                do {
                    found = (try await OSMClient.placesAt(points), wanted)
                } catch {
                    Self.log.error("Nominatim couldn't list suburbs either: \(error)")
                }
            }
            guard let found else {
                if nearbyRetries < 3 {
                    nearbyRetries += 1
                    try? await Task.sleep(for: .seconds(90))
                    refreshNeighbours()
                }
                return
            }
            nearbyRetries = 0
            nearby = found.places
            store.save(nearby: NearbyPlaces(
                south: found.box.south, west: found.box.west, north: found.box.north, east: found.box.east,
                fetchedAt: .now, places: found.places
            ))
        }
    }

    /// Points about 2.5 km apart across the box, leaving out the ones inside places
    /// you've already got, for asking Nominatim which suburb each is in.
    private func samplePoints(in box: (south: Double, west: Double, north: Double, east: Double)) -> [Coordinate] {
        let step = 2500.0 / 111_320
        let lonStep = step / max(0.1, cos((box.south + box.north) / 2 * .pi / 180))
        var points: [Coordinate] = []
        for lat in stride(from: box.south + step / 2, to: box.north, by: step) {
            for lon in stride(from: box.west + lonStep / 2, to: box.east, by: lonStep) {
                let point = Coordinate(lat: lat, lon: lon)
                let inside = cities.contains { shape(for: $0).contains($0.grid.projection.project(point)) }
                if !inside { points.append(point) }
            }
        }
        return points
    }

    // MARK: Progression

    private(set) var ledger = Ledger()
    @ObservationIgnored private var cachedProgression: (key: String, state: Progression.State)?
    @ObservationIgnored private var cachedQuestTiles: (key: String, counts: [UUID: [UUID: Int]])?

    /// Coverage and history only change at the revisions below. The day/time-zone
    /// key also lets the quest sheet roll over without a GPS fix or a new walk.
    var progression: Progression.State {
        let calendar = Calendar.current
        let now = Date.now
        let key = "\(tilesRevision)-\(cities.count)-\(walks.count)-\(secretsRevision)-\(calendar.identifier)-\(calendar.startOfDay(for: now))-\(calendar.timeZone.identifier)"
        if let cachedProgression, cachedProgression.key == key { return cachedProgression.state }
        var inputs = Progression.Inputs(cities: cities, walks: walks, foundSecrets: foundStickers, now: now, calendar: calendar)
        // Legacy route replay doesn't depend on newly visited tiles. Keep it across
        // GPS fixes, and redo it only for a new walk or a changed counting grid.
        let historyKey = "\(walks.count)-\(cities.map { "\($0.id):\($0.tiles.count)" })"
        if cachedQuestTiles?.key != historyKey {
            cachedQuestTiles = (historyKey, Progression.placeTileCounts(inputs))
        }
        inputs.newTilesByWalk = cachedQuestTiles?.counts
        let state = Progression.state(inputs)
        cachedProgression = (key, state)
        return state
    }

    var earnedBreakdown: Progression.Earned { progression.earned }
    var balance: Int { ledger.balance(earned: progression.earned.total) }
    var xp: Int { progression.xp }
    var level: Int { progression.level }
    var nextLevelXP: Int { progression.nextLevelXP }
    var xpToNextLevel: Int { nextLevelXP - xp }
    var pendingPicks: [Int] { Progression.pendingLevels(xp: xp, ledger: ledger) }
    var weeklyQuests: [Progression.Quest] { progression.quests }
    var owned: Set<String> { ledger.owned }
    var equipped: Ledger.Equipped { ledger.resolvedEquipment }
    var spyglasses: Int { ledger.spyglassesLeft }
    /// Re-read on a timer while showing the map so the ring disappears at expiry.
    var activeSpyglassRing: Progression.Ring? {
        guard let city = selectedCity else { return nil }
        return Progression.activeRing(in: city, ledger: ledger, found: foundStickers, now: .now)
    }

    func picks(for level: Int) -> [String] { ledger.picks(for: level) }

    /// False means unknown item, already owned, or too few shells. Concurrent
    /// offline spending is retained on merge; the resulting debt blocks purchases.
    @discardableResult func buy(_ itemID: String) -> Bool {
        guard let item = Progression.item(itemID), !item.isFree,
              item.group == nil || !owned.contains(itemID), balance >= item.price else { return false }
        ledger.purchases.append(Ledger.Purchase(item: itemID, cost: item.price, at: Date.now.timeIntervalSince1970))
        if let group = item.group { setEquipped(itemID, group: group) }
        saveProgress()
        return true
    }

    @discardableResult func equip(_ itemID: String) -> Bool {
        guard let group = Progression.item(itemID)?.group, owned.contains(itemID) else { return false }
        setEquipped(itemID, group: group)
        saveProgress()
        return true
    }

    @discardableResult func claim(level: Int, choice: String) -> Bool {
        guard pendingPicks.contains(level), picks(for: level).contains(choice) else { return false }
        // A frozen offer may have been bought in the meantime. Give the bag
        // instead of taking a level pick for something the player already owns.
        let reward = owned.contains(choice) ? Progression.shellBag : choice
        ledger.claims.append(Ledger.Claim(level: level, choice: reward))
        if let group = Progression.item(reward)?.group { setEquipped(reward, group: group) }
        saveProgress()
        return true
    }

    @discardableResult func useSpyglass() -> Bool {
        guard spyglasses > 0, let city = selectedCity, activeSpyglassRing == nil,
              let use = Progression.spyglass(in: city, from: lastLocation.map { Coordinate($0.coordinate) }, found: foundStickers, now: .now)
        else { return false }
        ledger.spyglasses.append(use)
        saveProgress()
        return true
    }

    private func setEquipped(_ itemID: String, group: Progression.Group) {
        ledger.equipped[group] = itemID
        ledger.equipped.updatedAt = max(Date.now.timeIntervalSince1970, ledger.equipped.updatedAt.nextUp)
    }

    private func refreshProgressPicks() {
        let old = ledger
        ledger.preparePicks(xp: xp)
        if ledger != old { saveProgress() }
    }

    private func saveProgress() {
        ledger.preparePicks(xp: xp)
        store.save(progress: ledger)
        requestSync?()
    }

    /// The server accepted its first claim for a level. Give that copy precedence
    /// so two offline choices converge when both phones next pull a snapshot.
    func addRemoteProgress(_ remote: Ledger) {
        let merged = remote.merged(with: ledger)
        guard merged != ledger else { return }
        ledger = merged
        ledger.preparePicks(xp: xp)
        store.save(progress: ledger)
        requestSync?()
    }

    // MARK: Sync

    /// Asks the sync engine to push and pull shortly. Set by the app delegate.
    @ObservationIgnored var requestSync: (() -> Void)?

    /// A walk from the server that this phone hasn't got: keep it and replay it over every city.
    func addRemote(_ walk: Walk) {
        guard walk.endedAt != nil, walk.id != activeWalk?.id, !walks.contains(where: { $0.id == walk.id }) else { return }
        walks.append(walk)
        walks.sort { $0.startedAt < $1.startedAt }
        store.save(walk)
        replay([walk])
    }

    /// A city from the server. A new one is added; one this phone already has is merged,
    /// keeping every tile either copy uncovered.
    func addRemote(_ remote: City) {
        if let i = cities.firstIndex(where: { $0.id == remote.id }) {
            var city = cities[i]
            let hadMore = !city.visited.isSubset(of: remote.visited)
            city.visited.formUnion(remote.visited)
            city.tiles.formUnion(remote.tiles)
            city.roads = city.roads ?? remote.roads
            city.stickers = (city.stickers ?? [:]).merging(remote.stickers ?? [:]) { _, theirs in theirs }
            // If this phone had tiles the server didn't, send the merged copy back.
            city.updatedAt = hadMore ? .now : max(city.lastChanged, remote.lastChanged)
            cities[i] = city
        } else {
            cities.append(remote)
            if selectedCityID == nil { select(remote.id) }
            refreshNeighbours()
            placeStickers()
        }
        shapes[remote.id] = nil
        replay(walks, onlyCity: remote.id)
    }

    /// Secrets found on another phone, keeping the earliest time each was found.
    func addRemoteSecrets(_ remote: [String: Date]) {
        var changed = false
        for (id, date) in remote where foundStickers[id].map({ date < $0 }) ?? true {
            foundStickers[id] = date
            changed = true
        }
        if changed {
            store.save(stickers: foundStickers)
            refreshProgressPicks()
        }
    }

    /// Runs walks over the cities again, quietly unlocking any secrets they pass.
    private func replay(_ walks: [Walk], onlyCity: UUID? = nil) {
        for i in cities.indices where onlyCity == nil || cities[i].id == onlyCity {
            var city = cities[i]
            let shape = shape(for: city)
            for walk in walks {
                _ = city.visit(CoverageTracer.samples(for: walk.points), within: shape)
            }
            cities[i] = city
            unlockStickers(in: city, on: city.visited, notify: false, popUp: false)
        }
        tilesRevision += 1
        store.save(cities)
        refreshProgressPicks()
    }

    /// Forgets everything on this phone, for signing out. It's all in the account.
    func wipeLocalData() {
        alwaysOn = false
        setupDone = false
        tracker.stop()
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        recap = nil
        cities = []
        walks = []
        shapes = [:]
        foundStickers = [:]
        ledger = Ledger()
        cachedProgression = nil
        cachedQuestTiles = nil
        stickerQueue = []
        nearby = []
        selectedCityID = nil
        tilesRevision += 1
        store.wipe()
    }

    private func shape(for city: City) -> BoundaryShape {
        if let shape = shapes[city.id] { return shape }
        let shape = city.shape()
        shapes[city.id] = shape
        return shape
    }
}

private extension Dictionary where Key == UUID, Value == Set<Hex> {
    var countsByPlaceID: [String: Int] {
        Dictionary<String, Int>(uniqueKeysWithValues: map { ($0.key.uuidString, $0.value.count) })
    }
}
