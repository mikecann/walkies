import Foundation
import Testing
@testable import Walkies

/// Cities are written in the background, with their streets in a file of their own.
struct StoreTests {
    func root() -> URL {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesStoreTests")
        return base.appending(path: UUID().uuidString)
    }

    func city(_ name: String, roads: [RoadLine]?) -> City {
        let grid = HexGrid.world
        let base = grid.hex(containing: Coordinate(lat: -33.638, lon: 115.386))
        let ring = [SIMD2(-300.0, -300), SIMD2(300.0, -300), SIMD2(300.0, 300), SIMD2(-300.0, 300)]
            .map { grid.projection.unproject(grid.centre(of: base) + $0) }
        return City(name: name, detail: "Tests", boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]),
                    tiles: [base], visited: [], roads: roads)
    }

    let street = [RoadLine(kind: .road, points: [Coordinate(lat: -33.63, lon: 115.38), Coordinate(lat: -33.631, lon: 115.381)])]

    @Test func streetsGoInTheirOwnFileAndComeBack() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let cities = [city("A", roads: street), city("B", roads: []), city("C", roads: nil)]
        store.save(cities)
        let loaded = store.loadCities()
        #expect(loaded == cities)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "cities.json"))) as! [[String: Any]]
        #expect(saved.allSatisfy { $0["roads"] == nil })
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "roads.json").path))
    }

    @Test func oldSingleFileStillLoadsAndMovesItsStreets() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let cities = [city("A", roads: street), city("B", roads: nil)]
        try JSONEncoder().encode(cities).write(to: root.appending(path: "cities.json"))
        let loaded = store.loadCities()
        #expect(loaded == cities)
        store.save(loaded)
        #expect(Store(root: root).loadCities() == cities)
    }

    @Test func savesMatchEncodingEverythingAndTheLastOneWins() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        var cities = [city("A", roads: street), city("B", roads: street)]
        store.save(cities)
        for n in 0..<20 {
            cities[n % 2].visited.insert(Hex(q: Int32(n), r: 0))
            cities[n % 2].updatedAt = Date(timeIntervalSince1970: Double(n))
            store.save(cities)
        }
        store.flush()
        var bare = cities
        for i in bare.indices { bare[i].roads = nil }
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "cities.json"))) as? NSArray
        let whole = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? NSArray
        #expect(disk == whole)
        #expect(store.loadCities() == cities)
    }

    @Test func wipingAfterASaveLeavesNothingBehind() {
        let root = root()
        let store = Store(root: root)
        store.save([city("A", roads: street)])
        store.wipe()
        store.flush()
        #expect(store.loadCities().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "roads.json").path))
    }
}
