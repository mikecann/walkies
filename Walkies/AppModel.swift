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

    let tracker = LocationTracker()
    @ObservationIgnored private let store = Store()
    @ObservationIgnored private var tracer = CoverageTracer()
    @ObservationIgnored private var shapes: [UUID: BoundaryShape] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var startWhenAllowed = false

    init() {
        cities = store.loadCities()
        walks = store.loadWalks()

        // A walk without an end means the app was killed mid-walk. Close it off.
        for i in walks.indices where walks[i].endedAt == nil {
            walks[i].endedAt = walks[i].points.last.map { Date(timeIntervalSince1970: $0.time) } ?? walks[i].startedAt
            store.save(walks[i])
        }

        let saved = UserDefaults.standard.string(forKey: "selectedCity").flatMap(UUID.init)
        selectedCityID = cities.first { $0.id == saved }?.id ?? cities.first?.id

        tracker.onLocation = { [weak self] in self?.record($0) }
        tracker.onAuthorizationChange = { [weak self] in self?.authorizationChanged() }
        fetchMissingRoads()
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

    var selectedFreshTiles: Set<Hex> {
        selectedCityID.flatMap { freshTiles[$0] } ?? []
    }

    // MARK: Walks

    func startWalk() {
        guard activeWalk == nil else { return }
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
        guard var walk = activeWalk, location.timestamp.timeIntervalSinceNow > -10 else { return }
        let point = TrackPoint(location)
        walk.points.append(point)

        let step = tracer.add(point)
        walk.distance += step.distance
        if !step.samples.isEmpty {
            activePath.append(point.coordinate)
            let uncovered = visit(step.samples)
            if uncovered > 0 {
                walk.newTiles += uncovered
                revealCount += uncovered
            }
        }
        activeWalk = walk

        if Date.now.timeIntervalSince(lastSave) > 30 {
            saveNow()
        }
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
        }
        if uncovered > 0 { tilesRevision += 1 }
        return uncovered
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
