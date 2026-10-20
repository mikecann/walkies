import CoreLocation
import Foundation
import Observation
import os

@Observable
final class AppModel {
    private(set) var cities: [City] = []
    private(set) var walks: [Walk] = []
    private(set) var teams: [Team] = []
    var pendingTeamInvite: String?
    var teamNotice: String?
    private(set) var teamMembershipRevision = 0
    var selectedCityID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedCityID?.uuidString, forKey: "selectedCity")
        }
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
    @ObservationIgnored private let store: Store
    /// Wired by the app with Account.client(), just like sync. Tests leave it nil.
    @ObservationIgnored var makePlaceClient: (() async -> ConvexClient?)?
    @ObservationIgnored private var warmedNeighbourIds: [Int]?
    @ObservationIgnored private var warmingNeighbours = false
    @ObservationIgnored private let servicesEnabled: Bool
    @ObservationIgnored private var tracer = CoverageTracer()
    @ObservationIgnored private var shapes: [UUID: BoundaryShape] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var startWhenAllowed = false

    @ObservationIgnored private var historyTask: Task<Void, Never>?
    private(set) var historyReady = false
    private(set) var worldGridResetPending = false
    @ObservationIgnored private var dataGeneration = 0
    @ObservationIgnored private var recapRequest = 0
    @ObservationIgnored private var historyRevision = 0
    @ObservationIgnored private var placesRevision = 0
    @ObservationIgnored private var batchingProgress = false
    @ObservationIgnored private var countingTilesByPlace: [UUID: Int] = [:]
    @ObservationIgnored private var questTileCounts: [UUID: [UUID: Int]] = [:]
    @ObservationIgnored private var addedTiles: [UUID: Set<Hex>] = [:]

    init(store: Store = Store(), servicesEnabled: Bool = true, alwaysOn: Bool? = nil) {
        self.store = store
        self.servicesEnabled = servicesEnabled
        do { try store.prepareWorldGridReset() }
        catch { Self.log.error("Couldn't prepare world grid reset: \(error)") }
        worldGridResetPending = store.needsWorldGridReset
        if worldGridResetPending { UserDefaults.standard.removeObject(forKey: "lastSynced") }
        ledger = worldGridResetPending ? Ledger() : store.loadProgress()
        cities = worldGridResetPending ? [] : store.loadCities()
        teams = store.loadTeams()
        self.alwaysOn = alwaysOn ?? UserDefaults.standard.bool(forKey: "alwaysOn")

        // A walk without an end means the app was killed mid-walk. If iOS has just
        // relaunched us during an always-on walk, carry on with it; otherwise close it off.
        for var walk in store.loadWalks() {
            if walk.endedAt == nil {
                if !worldGridResetPending, self.alwaysOn, walk.isAutomatic, let last = walk.points.last,
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
        if servicesEnabled { fetchMissingRoads() }
        foundStickers = worldGridResetPending ? [:] : store.loadStickers()
        placeStickers()
        refreshNeighbours()
        rebuildCountingTiles()
        // Migration can be sizeable on an older phone. Never trace saved routes
        // while opening the app, reading balance or processing a location fix.
        historyTask = Task { await prepareHistory() }
    }

    /// Sync calls this before uploading anything. If the cache/network is unavailable,
    /// keep the descriptor file and retry on the next sync instead of accepting old tiles.
    func rebuildWorldGrid(using client: ConvexClient) async throws {
        guard worldGridResetPending else { return }
        await historyTask?.value
        try store.prepareWorldGridReset()
        let generation = dataGeneration
        var pending = try store.pendingResetPlaces()
        // Older City saves never retained osmId. Look each name up once, a second
        // apart as Nominatim asks, and keep what's found so a retry carries on from there.
        var searched = false
        for i in pending.indices where pending[i].osmId == nil {
            if searched { try await Task.sleep(for: .seconds(1.2)) }
            searched = true
            let saved = pending[i]
            let matches = try await OSMClient.searchPlaces("\(saved.name), \(saved.detail)", session: client.session)
            if let match = matches.first(where: {
                $0.name.caseInsensitiveCompare(saved.name) == .orderedSame
                    && $0.boundary.centre.distance(to: saved.boundary.centre) < 10_000
            }) {
                pending[i].osmId = match.osmId
                try store.savePendingResetPlaces(pending)
            }
        }
        var rebuilt: [City] = []
        for saved in pending {
            var place = PlaceResult(id: 0, name: saved.name, detail: saved.detail, kind: "suburb",
                                    boundary: saved.boundary, area: 0, osmId: saved.osmId)
            let city: City
            if let osmId = place.osmId {
                let cached = try await CachedPlaceData.fetch(osmId: osmId, client: client)
                place.boundary = cached.boundary
                city = await Task.detached(priority: .utility) {
                    CityBuilder.build(from: place, ways: cached.ways, walks: [])
                }.value
            } else {
                // Custom/retired boundaries can still be rebuilt from current OSM ways.
                city = try await CityBuilder.build(from: place, walks: [], client: client, status: { _ in })
            }
            var restored = city
            restored.id = saved.id
            restored.createdAt = saved.createdAt
            restored.updatedAt = .now
            rebuilt.append(restored)
        }
        guard generation == dataGeneration else { throw CancellationError() }
        cities = rebuilt
        shapes = [:]
        foundStickers = [:]
        ledger = Ledger()
        placeStickers()
        let replayCities = cities
        let replayWalks = walks
        let replayed = await Task.detached(priority: .utility) {
            CityBuilder.replay(replayWalks, through: replayCities)
        }.value
        guard generation == dataGeneration else { throw CancellationError() }
        cities = replayed.cities
        let savedSelection = UserDefaults.standard.string(forKey: "selectedCity").flatMap(UUID.init)
        if let id = cities.first(where: { $0.id == savedSelection })?.id ?? cities.first?.id { select(id) }
        walks = replayed.walks
        foundStickers = replayed.secrets
        stickerQueue = []
        // Remove the retry marker only after all rebuilt files are on disk.
        try store.finishWorldGridReset(cities: cities, walks: walks, stickers: foundStickers, progress: ledger)
        worldGridResetPending = false
        placesRevision += 1
        tilesRevision += 1
        rebuildCountingTiles()
        await prepareHistory()
        if servicesEnabled { resumeAlwaysOn(); refreshNeighbours() }
    }

    private func rebuildCountingTiles() {
        countingTilesByPlace = Dictionary(cities.map { ($0.id, $0.tiles.intersection($0.visited).count) }, uniquingKeysWith: max)
    }

    func waitForHistory() async { await historyTask?.value }

    private func prepareHistory() async {
        guard !worldGridResetPending else { return }
        let generation = dataGeneration
        let savedWalks = walks
        let savedCities = cities
        var resumed = activeWalk
        let resumedEnd = resumed?.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? .now
        resumed?.endedAt = resumedEnd
        let routes = savedWalks + (autoWalkPending ? [] : resumed.map { [$0] } ?? [])
        let repaired = await Task.detached(priority: .utility) {
            Progression.backfill(walks: routes, cities: savedCities)
        }.value
        guard generation == dataGeneration else { return }
        installBackfill(repaired)
        if let active = activeWalk, let recovered = repaired.walks.first(where: { $0.id == active.id }) {
            for (key, hexes) in recovered.newTileHexesByPlace ?? active.newTileHexesByPlace ?? [:] {
                if let id = UUID(uuidString: key) { freshTiles[id, default: []].formUnion(hexes) }
            }
            for (key, hexes) in active.addedTilesByPlace ?? [:] {
                if let id = UUID(uuidString: key) { addedTiles[id, default: []].formUnion(hexes) }
            }
        }
        if var active = activeWalk {
            active.newTilesByPlace = freshTiles.countsByPlaceID
            active.newTileHexesByPlace = Dictionary(uniqueKeysWithValues: freshTiles.map { ($0.key.uuidString, $0.value) })
            activeWalk = active
            store.save(active)
        }
        historyReady = true
        historyRevision += 1
        refreshProgressPicks()
    }

    private func installBackfill(_ repaired: Progression.Backfill) {
        let byID = Dictionary(repaired.walks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in walks.indices {
            guard let recovered = byID[walks[i].id] else { continue }
            let newTiles = recovered.newTileHexesByPlace.map { $0.values.reduce(0) { $0 + $1.count } } ?? recovered.newTiles
            if walks[i].newTiles != newTiles || walks[i].newTilesByPlace != recovered.newTilesByPlace || walks[i].newTileHexesByPlace != recovered.newTileHexesByPlace {
                walks[i].newTiles = newTiles
                walks[i].newTilesByPlace = recovered.newTilesByPlace
                walks[i].newTileHexesByPlace = recovered.newTileHexesByPlace
                store.save(walks[i])
            }
        }
        questTileCounts = repaired.counts
        for walk in walks where questTileCounts[walk.id] == nil {
            questTileCounts[walk.id] = Dictionary((walk.newTilesByPlace ?? [:]).compactMap { key, n in UUID(uuidString: key).map { ($0, n) } }, uniquingKeysWith: +)
        }
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
        guard !worldGridResetPending, activeWalk == nil, !alwaysOn else { return }
        if servicesEnabled {
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
        }
        activeWalk = Walk(startedAt: .now, newTilesByPlace: [:], newTileHexesByPlace: [:], addedTilesByPlace: [:])
        activePath = []
        freshTiles = [:]
        addedTiles = [:]
        tracer = CoverageTracer()
        if servicesEnabled {
            tracker.start()
            Notifier.requestPermission()
        }
    }

    func endWalk() {
        guard historyReady else {
            Task { await historyTask?.value; if historyReady { endWalk() } }
            return
        }
        guard var walk = activeWalk else { return }
        tracker.stop()
        walk.endedAt = .now
        finishCoverage(of: &walk)
        let history = walks
        let fresh = freshTiles
        let counts = questTileCounts
        walks.append(walk)
        questTileCounts[walk.id] = fresh.mapValues(\.count)
        historyRevision += 1
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        addedTiles = [:]
        tilesRevision += 1
        store.save(walk)
        store.save(cities)
        recapRequest += 1
        recap = WalkRecap.make(walk: walk, cities: cities, fresh: fresh, found: foundStickers, history: history, counts: counts)
        refreshProgressPicks()
        requestSync?()
    }

    /// Plays an old walk's celebration again, from walk history. Which tiles were new
    /// on it is worked out again: the tiles under its route that no earlier walk crossed.
    func replay(_ walk: Walk) {
        let earlier = walks.filter { $0.id != walk.id && $0.startedAt < walk.startedAt }
        let savedCities = cities
        let counts = questTileCounts
        let found = foundStickers
        let generation = dataGeneration
        recapRequest += 1
        let request = recapRequest
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var fresh: [UUID: Set<Hex>] = [:]
                var before = savedCities
                for i in before.indices {
                    var city = before[i]
                    city.visited = []
                    let shape = city.shape()
                    for old in earlier { _ = city.visit(CoverageTracer.samples(for: old.points), within: shape) }
                    let new = city.visit(CoverageTracer.samples(for: walk.points), within: shape)
                    if !new.isEmpty { fresh[city.id] = new }
                    before[i] = city
                }
                return WalkRecap.make(walk: walk, cities: before, fresh: fresh, found: found, history: earlier, counts: counts)
            }.value
            if generation == dataGeneration, request == recapRequest { recap = result }
        }
    }

    /// The End walk button on an always-on walk: ends it now and plays the celebration.
    func endAutoWalk() {
        finishAutoWalk(byYou: true)
    }

    private func finishCoverage(of walk: inout Walk) {
        // Don't overwrite a resumed legacy walk while its worker is still finding
        // the tiles uncovered before launch.
        guard historyReady else { return }
        walk.newTilesByPlace = freshTiles.countsByPlaceID
        walk.newTileHexesByPlace = Dictionary(uniqueKeysWithValues: freshTiles.map { ($0.key.uuidString, $0.value) })
        walk.addedTilesByPlace = Dictionary(uniqueKeysWithValues: addedTiles.map { ($0.key.uuidString, $0.value) })
    }

    func saveNow() {
        if var walk = activeWalk {
            finishCoverage(of: &walk)
            activeWalk = walk
            store.save(walk)
        }
        store.save(cities)
        saveTeams()
        lastSave = .now
    }

    private func record(_ location: CLLocation) {
        // iOS can hand over a cached fix from wherever you last were when tracking starts.
        guard !worldGridResetPending, location.timestamp.timeIntervalSinceNow > -10 else { return }
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
            activeWalk = Walk(startedAt: Date(timeIntervalSince1970: point.time), newTilesByPlace: [:], newTileHexesByPlace: [:], addedTilesByPlace: [:], automatic: true)
            activePath = []
            freshTiles = [:]
            addedTiles = [:]
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
        guard historyReady else {
            Task { await historyTask?.value; if historyReady { finishAutoWalk(byYou: byYou) } }
            return
        }
        guard var walk = activeWalk, walk.isAutomatic else { return }
        let wasPending = autoWalkPending
        finishCoverage(of: &walk)
        let fresh = freshTiles
        autoWalkPending = false
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        addedTiles = [:]
        tracer = CoverageTracer()
        tilesRevision += 1
        walk.endedAt = byYou ? .now : walk.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? walk.startedAt
        // Measure again by today's rules, so walks logged by older versions (or GPS
        // wobble at home) don't get kept as real ones. Tiles already uncovered stay.
        walk.distance = CoverageTracer.distance(for: walk.points)
        if !wasPending, byYou || walk.distance >= Self.minimumAutoWalk {
            let history = walks
            let counts = questTileCounts
            walks.append(walk)
            questTileCounts[walk.id] = fresh.mapValues(\.count)
            historyRevision += 1
            store.save(walk)
            // If it ended by itself while the phone was in your pocket, this plays the
            // next time you open the app.
            recapRequest += 1
            recap = WalkRecap.make(walk: walk, cities: cities, fresh: fresh, found: foundStickers, history: history, counts: counts)
        } else {
            // Keep the dated tile credit even though this outing doesn't qualify
            // for walk history, distance/day quests or streak rewards.
            for i in cities.indices {
                guard let hexes = fresh[cities[i].id], !hexes.isEmpty else { continue }
                cities[i].tileCredits = (cities[i].tileCredits ?? []) + [
                    City.TileCredit(id: walk.id, at: walk.startedAt, hexes: hexes)
                ]
                cities[i].updatedAt = .now
            }
            if !fresh.isEmpty {
                questTileCounts[walk.id] = fresh.mapValues(\.count)
                historyRevision += 1
            }
            store.delete(walk)
        }
        store.save(cities)
        refreshProgressPicks()
        requestSync?()
    }

    // MARK: Always on

    /// Called at launch, including when iOS relaunches the app in the background.
    func resumeAlwaysOn() {
        guard !worldGridResetPending else { return }
        // Starting motion asks for permission, so leave that to the setup the first time.
        if setupDone { motion.start() }
        if alwaysOn {
            tracker.startAlwaysOn()
        }
    }

    private func turnOnAlwaysOn() {
        guard !worldGridResetPending else { return }
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
            let originalTiles = city.tiles
            let fresh = city.visit(points, within: shape(for: city))
            guard !fresh.isEmpty else { continue }
            city.updatedAt = .now
            cities[i] = city
            freshTiles[city.id, default: []].formUnion(fresh)
            addedTiles[city.id, default: []].formUnion(fresh.subtracting(originalTiles))
            countingTilesByPlace[city.id, default: 0] += fresh.count
            tilesRevision += 1
            uncovered += fresh.count
            unlockStickers(in: city, on: fresh, notify: true, popUp: true)
        }
        if uncovered > 0 { refreshProgressPicks() }
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
        for entry in entries { foundStickers[entry.id] = notify ? .now : Progression.exploredSecretDate }
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
        placesRevision += 1
        rebuildCountingTiles()
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
        placesRevision += 1
        rebuildCountingTiles()
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
        guard servicesEnabled, !fetchingNearby, let wanted = box(around: Self.neighbourhood), let fetch = box(around: Self.neighbourhood * 2) else { return }
        if let saved = store.loadNearby(),
           saved.covers(south: wanted.south, west: wanted.west, north: wanted.north, east: wanted.east),
           saved.fetchedAt.timeIntervalSinceNow > -30 * 24 * 3600 {
            nearby = saved.places
            warmNeighbours()
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
            warmNeighbours()
            store.save(nearby: NearbyPlaces(
                south: found.box.south, west: found.box.west, north: found.box.north, east: found.box.east,
                fetchedAt: .now, places: found.places
            ))
        }
    }

    /// One background warm per loaded list. Failed/offline attempts can retry on
    /// the next refresh, and signing in can warm a list loaded before authentication.
    private func warmNeighbours() {
        let ids = Array(Set(nearby.compactMap(\.osmId))).sorted()
        guard !ids.isEmpty, ids != warmedNeighbourIds, !warmingNeighbours, let makePlaceClient else { return }
        warmingNeighbours = true
        Task {
            defer {
                warmingNeighbours = false
                // A newer list may have arrived while this request was running.
                if warmedNeighbourIds != nil, ids != Array(Set(nearby.compactMap(\.osmId))).sorted() { warmNeighbours() }
            }
            guard let client = await makePlaceClient() else { return }
            do {
                // Keep each request bounded for larger neighbourhoods.
                for start in stride(from: 0, to: ids.count, by: 100) {
                    let _: Nothing = try await client.action("places:warm", ["osmIds": Array(ids[start..<min(start + 100, ids.count)])])
                }
                warmedNeighbourIds = ids
            } catch {
                Self.log.info("Couldn't warm nearby streets: \(error)")
            }
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
    #if DEBUG
    @ObservationIgnored private(set) var progressionHistoryBuilds = 0
    #endif
    @ObservationIgnored private var cachedHistoricalRewards: (key: String, rewards: Progression.HistoricalRewards)?

    var progression: Progression.State {
        let calendar = Progression.calendar
        let now = Date.now
        let day = calendar.startOfDay(for: now)
        let historyKey = "\(historyRevision)-\(placesRevision)-\(secretsRevision)-\(day)"
        let key = "\(tilesRevision)-\(historyKey)"
        if let cachedProgression, cachedProgression.key == key { return cachedProgression.state }
        var inputs = Progression.Inputs(cities: cities, walks: walks, foundSecrets: foundStickers, now: now, calendar: calendar,
                                       newTilesByWalk: questTileCounts, countingTilesByPlace: countingTilesByPlace,
                                       unrecordedTilesByPlace: activeWalk == nil ? [:] : freshTiles.mapValues(\.count))
        if cachedHistoricalRewards?.key != historyKey {
            #if DEBUG
            progressionHistoryBuilds += 1
            #endif
            cachedHistoricalRewards = (historyKey, Progression.historicalRewards(inputs))
        }
        inputs.historicalRewards = cachedHistoricalRewards?.rewards
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
    var pendingPicks: [Int] { historyReady && !batchingProgress ? Progression.pendingLevels(xp: xp, ledger: ledger) : [] }
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
        guard historyReady, let item = Progression.item(itemID), !item.isFree,
              item.group == nil || !owned.contains(itemID), balance >= item.price else { return false }
        // Include levels reached since the last refresh before ownership changes.
        ledger.preparePicks(xp: xp)
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
        guard historyReady, !batchingProgress else { return }
        let old = ledger
        ledger.preparePicks(xp: xp)
        if ledger != old { saveProgress() }
    }

    private func saveProgress() {
        if historyReady, !batchingProgress { ledger.preparePicks(xp: xp) }
        store.save(progress: ledger)
        requestSync?()
    }

    /// The server accepted its first claim for a level. Give that copy precedence
    /// so two offline choices converge when both phones next pull a snapshot.
    func addRemoteProgress(_ remote: Ledger) {
        let merged = remote.merged(with: ledger)
        guard merged != ledger else { return }
        ledger = merged
        if historyReady, !batchingProgress { ledger.preparePicks(xp: xp) }
        store.save(progress: ledger)
        requestSync?()
    }

    // MARK: Sync

    /// Asks the sync engine to push and pull shortly. Set by the app delegate.
    @ObservationIgnored var requestSync: (() -> Void)?

    /// Apply a pull as one batch. Merge ownership before preparing any level menu,
    /// and do coverage recovery on a worker rather than once per downloaded walk.
    func addRemote(cities remoteCities: [City], walks remoteWalks: [Walk], progress: Ledger?, secrets: [String: Date]) async {
        await historyTask?.value
        let generation = dataGeneration
        batchingProgress = true
        defer {
            batchingProgress = false
            if generation == dataGeneration { refreshProgressPicks() }
        }
        if let progress { addRemoteProgress(progress) }
        addRemoteSecrets(secrets)
        var changedCities: Set<UUID> = []
        for remote in remoteCities {
            changedCities.insert(remote.id)
            if let i = cities.firstIndex(where: { $0.id == remote.id }) {
                var city = cities[i]
                let localCredits = Set((city.tileCredits ?? []).map(\.id))
                let remoteCredits = Set((remote.tileCredits ?? []).map(\.id))
                let hadMore = !city.visited.isSubset(of: remote.visited) || !localCredits.isSubset(of: remoteCredits)
                city.mergeTileCredits(from: remote)
                city.visited.formUnion(remote.visited)
                city.tiles.formUnion(remote.tiles)
                city.roads = city.roads ?? remote.roads
                city.stickers = (city.stickers ?? [:]).merging(remote.stickers ?? [:]) { _, theirs in theirs }
                city.updatedAt = hadMore ? .now : max(city.lastChanged, remote.lastChanged)
                cities[i] = city
            } else {
                cities.append(remote)
                if selectedCityID == nil { select(remote.id) }
            }
            shapes[remote.id] = nil
        }
        let have = Set(walks.map(\.id))
        let missing = remoteWalks.filter { $0.endedAt != nil && $0.id != activeWalk?.id && !have.contains($0.id) }
        walks.append(contentsOf: missing)
        walks.sort { $0.startedAt < $1.startedAt }
        for walk in missing { store.save(walk) }
        guard !changedCities.isEmpty || !missing.isEmpty else { return }
        placesRevision += 1
        tilesRevision += 1
        rebuildCountingTiles()
        let snapshotCities = cities
        let snapshotWalks = walks
        let newIDs = Set(missing.map(\.id))
        let restored = await Task.detached(priority: .utility) {
            var restoredCities = snapshotCities
            let shapes = restoredCities.map { $0.shape() }
            for walk in snapshotWalks {
                let targets = restoredCities.indices.filter { changedCities.contains(restoredCities[$0].id) || newIDs.contains(walk.id) }
                guard !targets.isEmpty else { continue }
                let samples = CoverageTracer.samples(for: walk.points)
                for i in targets { _ = restoredCities[i].visit(samples, within: shapes[i]) }
            }
            return (restoredCities, Progression.backfill(walks: snapshotWalks, cities: restoredCities))
        }.value
        guard generation == dataGeneration else { return }
        // Location fixes can arrive while the worker runs. Union its result so no
        // live coverage is overwritten by the snapshot it started with.
        for restoredCity in restored.0 {
            guard let i = cities.firstIndex(where: { $0.id == restoredCity.id }) else { continue }
            cities[i].visited.formUnion(restoredCity.visited)
            cities[i].tiles.formUnion(restoredCity.tiles)
        }
        installBackfill(restored.1)
        historyRevision += 1
        placesRevision += 1
        tilesRevision += 1
        rebuildCountingTiles()
        placeStickers()
        for city in cities { unlockStickers(in: city, on: city.visited, notify: false, popUp: false) }
        store.save(cities)
        refreshNeighbours()
    }

    /// A genuine discovery beats the explored-coverage sentinel; otherwise the
    /// earliest discovery wins, matching the server's existing secret merge.
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

    /// Forgets everything on this phone, for signing out. It's all in the account.
    func wipeLocalData() {
        dataGeneration += 1
        teamMembershipRevision += 1
        historyTask?.cancel()
        historyTask = nil
        historyReady = true
        worldGridResetPending = false
        alwaysOn = false
        setupDone = false
        tracker.stop()
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        recap = nil
        cities = []
        teams = []
        pendingTeamInvite = nil
        walks = []
        shapes = [:]
        foundStickers = [:]
        ledger = Ledger()
        cachedProgression = nil
        cachedHistoricalRewards = nil
        questTileCounts = [:]
        countingTilesByPlace = [:]
        addedTiles = [:]
        historyRevision += 1
        placesRevision += 1
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

extension AppModel {
    func editTeam(_ id: String, _ edit: (inout Team) -> Void) {
        guard let index = teams.firstIndex(where: { $0.id == id }) else { return }
        // Invalidate any list request started before this local membership edit.
        teamMembershipRevision += 1
        edit(&teams[index])
        saveTeams()
    }

    func saveTeams() { store.save(teams: teams) }

    func joinedTeam(_ id: String) {
        teamMembershipRevision += 1
        if !teams.contains(where: { $0.id == id }) {
            teams.append(Team(id: id, name: "Team", createdBy: "", inviteCode: ""))
        }
        saveTeams()
    }

    @discardableResult
    func acceptTeamList(_ listings: [Team], revision: Int) -> Bool {
        guard revision == teamMembershipRevision else { return false }
        let removed = teams.filter { team in !listings.contains(where: { $0.id == team.id }) }
        if !removed.isEmpty { teamNotice = "You’re no longer a member of \(removed.map(\.name).joined(separator: ", "))." }
        teamMembershipRevision += 1
        teams = listings
        saveTeams()
        return true
    }

    func retainTeams(_ ids: Set<String>) {
        teamMembershipRevision += 1
        teams.removeAll { !ids.contains($0.id) }
        saveTeams()
    }

    func teamAPI() async throws -> TeamsAPI {
        guard let client = await makePlaceClient?() else { throw ConvexError.server("Connect and sign in to manage a team.") }
        return TeamsAPI(client: client)
    }

    func refreshTeam(_ id: String, api: TeamsAPI) async throws {
        let generation = dataGeneration
        let revision = teamMembershipRevision
        guard teams.contains(where: { $0.id == id }) else { throw CancellationError() }
        let listings = try await api.list()
        guard generation == dataGeneration, acceptTeamList(listings, revision: revision) else { throw CancellationError() }
    }

    /// Both the neighbour buttons and place search add to your own places.
    func addPlace(_ place: PlaceResult, status: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard !worldGridResetPending else { throw ConvexError.server("Connect to finish rebuilding your places first.") }
        let generation = dataGeneration
        let city = try await CityBuilder.build(from: place, walks: walks, client: await makePlaceClient?(), status: status)
        guard generation == dataGeneration else { throw CancellationError() }
        add(city)
    }

    func openTeamURL(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme?.lowercased() == "walkies", url.host?.lowercased() == "join",
              parts.count == 1, let raw = parts.first, TeamInviteCode.isValid(TeamInviteCode.normalise(raw)) else { return }
        pendingTeamInvite = TeamInviteCode.normalise(raw)
    }
}
