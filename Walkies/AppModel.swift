import CoreLocation
import Foundation
import Observation

@Observable
final class AppModel {
    private(set) var cities: [City] = []
    private(set) var walks: [Walk] = []
    var selectedCityID: UUID? {
        didSet { UserDefaults.standard.set(selectedCityID?.uuidString, forKey: "selectedCity") }
    }
    private(set) var activeWalk: Walk?
    /// Accepted fixes from the current walk, for drawing the line on the map.
    private(set) var activePath: [Coordinate] = []
    /// Tiles uncovered on the current walk, per city, so the map can make a fuss of them.
    private(set) var freshTiles: [UUID: Set<Hex>] = [:]
    /// Bumps whenever any city's tiles change.
    private(set) var tilesRevision = 0
    /// Bumps for every newly uncovered tile, to drive haptics.
    private(set) var revealCount = 0
    /// Set when a walk ends, to show the summary.
    var finishedWalk: Walk?
    /// Tilted map with Apple's 3D buildings and trees.
    var tilted3D = UserDefaults.standard.bool(forKey: "tilted3D") {
        didSet { UserDefaults.standard.set(tilted3D, forKey: "tilted3D") }
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

    /// Shorter than this with no new tiles and it wasn't really a walk: pottering
    /// round the house, or GPS drift.
    static let minimumAutoWalk = 100.0

    let tracker = LocationTracker()
    let motion = MotionMonitor()
    @ObservationIgnored private let store = Store()
    @ObservationIgnored private var tracer = CoverageTracer()
    @ObservationIgnored private var shapes: [UUID: BoundaryShape] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var startWhenAllowed = false

    init() {
        cities = store.loadCities()
        alwaysOn = UserDefaults.standard.bool(forKey: "alwaysOn")

        // A walk without an end means the app was killed mid-walk. If iOS has just
        // relaunched us during an always-on walk, carry on with it; otherwise close it off.
        for var walk in store.loadWalks() {
            if walk.endedAt == nil {
                if alwaysOn, walk.isAutomatic, let last = walk.points.last,
                   Date.now.timeIntervalSince1970 - last.time < Self.autoWalkGap {
                    activeWalk = walk
                    activePath = walk.points.map(\.coordinate)
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
                tilesRevision += 1
                store.save(cities)
            }
        }
    }

    var selectedCity: City? { cities.first { $0.id == selectedCityID } }

    /// What the cloud layer draws for the selected city. Working out which tiles are
    /// clouded takes a moment on a big city, so it's only redone when the tiles change.
    @ObservationIgnored private var cachedField: (key: String, field: CloudField)?

    var cloudKey: String { "\(selectedCityID?.uuidString ?? "none")-\(tilesRevision)-\(foundStickers.count)" }

    var cloudField: CloudField {
        let key = cloudKey
        if let cachedField, cachedField.key == key { return cachedField.field }
        let hidden = stickersHere.filter { foundStickers[$0.entry.id] == nil }.map(\.hex)
        let field = selectedCity.map { CloudField(city: $0, hints: hidden) } ?? CloudField()
        cachedField = (key, field)
        return field
    }

    var selectedFreshTiles: Set<Hex> {
        selectedCityID.flatMap { freshTiles[$0] } ?? []
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
        walks.append(walk)
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        tilesRevision += 1
        store.save(walk)
        store.save(cities)
        finishedWalk = walk
    }

    func saveNow() {
        if let activeWalk { store.save(activeWalk) }
        store.save(cities)
        lastSave = .now
    }

    private func record(_ location: CLLocation) {
        // iOS can hand over a cached fix from wherever you last were when tracking starts.
        guard location.timestamp.timeIntervalSinceNow > -10 else { return }
        var point = TrackPoint(location)
        if motion.onWheels { point.wheels = true }
        if alwaysOn {
            recordAlwaysOn(point)
        } else if activeWalk != nil {
            recordWalk(point)
        }
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
        }
        guard var walk = activeWalk else { return }
        walk.points.append(point)
        apply(step, at: point, to: &walk)
        activeWalk = walk
        saveIfDue()
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

    private func finishAutoWalk() {
        guard var walk = activeWalk, walk.isAutomatic else { return }
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        tracer = CoverageTracer()
        tilesRevision += 1
        walk.endedAt = walk.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? walk.startedAt
        if walk.distance >= Self.minimumAutoWalk || walk.newTiles > 0 {
            walks.append(walk)
            store.save(walk)
        } else {
            store.delete(walk)
        }
        store.save(cities)
    }

    /// New tiles from today's walks, for the always-on status.
    var newTilesToday: Int {
        let today = Calendar.current.startOfDay(for: .now)
        return walks.filter { $0.startedAt >= today }.reduce(0) { $0 + $1.newTiles } + (activeWalk?.newTiles ?? 0)
    }

    // MARK: Always on

    /// Called at launch, including when iOS relaunches the app in the background.
    func resumeAlwaysOn() {
        motion.start()
        if alwaysOn {
            tracker.startAlwaysOn()
        }
    }

    private func turnOnAlwaysOn() {
        Notifier.requestPermission()
        // Hand over from a walk you started yourself, without the summary popping up.
        if activeWalk != nil {
            endWalk()
            finishedWalk = nil
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
            cities[i] = city
            freshTiles[city.id, default: []].formUnion(fresh)
            uncovered += fresh.count
            unlockStickers(in: city, on: fresh, notify: true)
        }
        if uncovered > 0 { tilesRevision += 1 }
        return uncovered
    }

    // MARK: Stickers

    /// When each sticker was found, by lore id.
    private(set) var foundStickers: [String: Date] = [:]
    /// Stickers just found, waiting to pop up.
    var stickerQueue: [LoreEntry] = []

    /// Every sticker hidden in the selected city, found or not.
    var stickersHere: [(entry: LoreEntry, hex: Hex)] {
        guard let city = selectedCity, let placed = city.stickers else { return [] }
        return LoreLibrary.entries(for: city)
            .compactMap { entry in placed[entry.id].map { (entry, $0) } }
            .sorted { $0.entry.title < $1.entry.title }
    }

    /// Hides any lore that hasn't got a spot yet. Stickers under tiles you've already
    /// walked are yours straight away.
    private func placeStickers() {
        for i in cities.indices {
            let entries = LoreLibrary.entries(for: cities[i])
            let placed = cities[i].stickers ?? [:]
            let missing = entries.filter { placed[$0.id] == nil }
            guard !missing.isEmpty else { continue }
            cities[i].stickers = placed.merging(cities[i].placeStickers(missing)) { old, _ in old }
            unlockStickers(in: cities[i], on: cities[i].visited, notify: false)
        }
        store.save(cities)
    }

    private func unlockStickers(in city: City, on hexes: Set<Hex>, notify: Bool) {
        guard let placed = city.stickers else { return }
        let ids = placed.filter { hexes.contains($0.value) && foundStickers[$0.key] == nil }.map(\.key)
        guard !ids.isEmpty else { return }
        let entries = LoreLibrary.entries(for: city).filter { ids.contains($0.id) }
        for entry in entries { foundStickers[entry.id] = .now }
        store.save(stickers: foundStickers)
        stickerQueue.append(contentsOf: entries)
        if notify { Notifier.stickersFound(entries) }
    }

    private func authorizationChanged() {
        guard startWhenAllowed, tracker.authorization != .notDetermined else { return }
        startWhenAllowed = false
        startWalk()
    }

    // MARK: Cities

    func add(_ city: City) {
        cities.append(city)
        shapes[city.id] = city.shape()
        selectedCityID = city.id
        placeStickers()
        tilesRevision += 1
        store.save(cities)
    }

    func deleteCities(at offsets: IndexSet) {
        let removed = offsets.map { cities[$0].id }
        cities.remove(atOffsets: offsets)
        for id in removed { shapes[id] = nil }
        if let selectedCityID, removed.contains(selectedCityID) {
            self.selectedCityID = cities.first?.id
        }
        store.save(cities)
    }

    private func shape(for city: City) -> BoundaryShape {
        if let shape = shapes[city.id] { return shape }
        let shape = city.shape()
        shapes[city.id] = shape
        return shape
    }
}
