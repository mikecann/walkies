import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct WorldGridResetTests {
    @Test(arguments: [true, false]) func resetPreservesRawWalkAndSettingsAndRetriesAfterAnOfflineLaunch(hasOSMID: Bool) async throws {
        let storageBase = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory
        let root = storageBase.appending(path: "WorldGridReset-\(UUID())")
        let store = Store(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let grid = HexGrid.world
        let base = grid.centre(of: grid.hex(containing: Coordinate(lat: -33.65, lon: 115.35)))
        func coordinate(_ x: Double, _ y: Double) -> Coordinate { grid.projection.unproject(base + SIMD2(x, y)) }
        let ring = [coordinate(-300, -300), coordinate(300, -300), coordinate(300, 300), coordinate(-300, 300)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: ring, holes: [])])
        let legacyHex = Hex(q: 999, r: 999)
        let city = City(name: "Old place", detail: "Tests", osmId: 123, boundary: boundary,
                        tiles: [legacyHex], visited: [legacyHex], roads: [], stickers: ["old-secret": legacyHex],
                        tileCredits: [.init(id: UUID(), at: .now, hexes: [legacyHex])])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode([city])) as! [[String: Any]]
        json[0]["gridVersion"] = nil
        if !hasOSMID { json[0]["osmId"] = nil }
        json[0]["grid"] = ["projection": ["origin": ["lat": -33.65, "lon": 115.35]], "size": 50]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appending(path: "cities.json"))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let points = stride(from: -120.0, through: 120, by: 30).enumerated().map { i, x in
            let c = coordinate(x, 100) // Off the mapped street: visit must add these tiles too.
            return TrackPoint(lat: c.lat, lon: c.lon, time: start.timeIntervalSince1970 + Double(i) * 30,
                              accuracy: 5, speed: 1)
        }
        var walk = Walk(startedAt: start, endedAt: start.addingTimeInterval(300), points: points,
                        distance: 9999, newTiles: 999, newTilesByPlace: [city.id.uuidString: 999],
                        newTileHexesByPlace: [city.id.uuidString: [legacyHex]], addedTilesByPlace: [city.id.uuidString: [legacyHex]])
        walk.gridVersion = nil
        store.save(walk)
        var ledger = Ledger()
        ledger.purchases = [.init(id: "purchase", item: "spyglass", cost: 60, at: 1)]
        ledger.claims = [.init(level: 2, choice: Progression.shellBag)]
        store.save(progress: ledger)
        store.save(stickers: ["old-secret": start])
        store.save(syncState: SyncState(uploadedWalks: [walk.id], uploadedPlaces: [city.id: .now], uploadedSecrets: ["old-secret"], uploadedProgress: "old"))
        try FileManager.default.removeItem(at: root.appending(path: "data-version.json"))
        let settings = UserDefaults.standard.dictionaryRepresentation().filter { ["setupDone", "alwaysOn", "map3D"].contains($0.key) } as NSDictionary
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        // Check synchronously before other suites can temporarily override preferences.
        #expect(settings == UserDefaults.standard.dictionaryRepresentation().filter { ["setupDone", "alwaysOn", "map3D"].contains($0.key) } as NSDictionary)
        await model.waitForHistory()
        #expect(model.worldGridResetPending)
        #expect(!model.historyReady)
        #expect(model.cities.isEmpty)
        #expect(model.foundStickers.isEmpty)
        #expect(model.ledger.purchases.isEmpty)
        #expect(store.loadSyncState().uploadedWalks.isEmpty)
        #expect(store.loadWalks().first?.points == walk.points)
        #expect(store.loadWalks().first?.newTileHexesByPlace == nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ResetProtocol.respond = nil }
        let client = ConvexClient(token: "test-token", session: session)
        ResetProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        do { try await model.rebuildWorldGrid(using: client); Issue.record("Offline rebuild should fail") }
        catch { }
        #expect(store.needsWorldGridReset)
        #expect(try store.pendingResetPlaces().first?.osmId == (hasOSMID ? 123 : nil))

        // Simulate the process dying while offline. The descriptor survives the relaunch.
        let reopened = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let cachedFile = try JSONSerialization.data(withJSONObject: [
            "boundary": [[ring.map { [$0.lon, $0.lat] }]],
            "ways": [["highway": "residential", "points": [coordinate(-250, 0), coordinate(250, 0)].map { [$0.lat, $0.lon] }]],
        ])
        let resolvedPlace = try JSONSerialization.data(withJSONObject: [[
            "place_id": 1234, "osm_id": 123, "osm_type": "relation", "name": "Old place",
            "display_name": "Old place, Tests", "geojson": ["type": "Polygon", "coordinates": [ring.map { [$0.lon, $0.lat] }]],
        ]])
        ResetProtocol.respond = { request in
            if request.url?.host == "nominatim.openstreetmap.org" {
                #expect(!hasOSMID)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return resolvedPlace
            }
            if request.url?.path == "/api/action" {
                return Data(#"{"status":"success","value":{"url":"https://reset.test/place.json","fetchedAt":1000}}"#.utf8)
            }
            return cachedFile
        }
        try await reopened.rebuildWorldGrid(using: client)
        #expect(!store.needsWorldGridReset)
        #expect(!reopened.worldGridResetPending)
        #expect(reopened.historyReady)
        let rebuilt = try #require(reopened.cities.first)
        let replayed = try #require(reopened.walks.first)
        #expect(rebuilt.id == city.id)
        #expect(rebuilt.osmId == 123)
        #expect(rebuilt.gridVersion == 2)
        #expect(rebuilt.tileCredits == nil)
        #expect(!rebuilt.visited.contains(legacyHex))
        #expect(!rebuilt.visited.isEmpty)
        #expect(replayed.id == walk.id)
        #expect(replayed.points == walk.points)
        #expect(replayed.startedAt == walk.startedAt && replayed.endedAt == walk.endedAt)
        #expect(replayed.gridVersion == 2)
        #expect(replayed.newTileHexesByPlace?[city.id.uuidString] == rebuilt.visited)
        #expect(replayed.newTiles == rebuilt.visited.count)
        let additions = try #require(replayed.addedTilesByPlace?[city.id.uuidString])
        #expect(additions.count > 0)
        #expect(reopened.earnedBreakdown.tiles == rebuilt.visited.count)
        #expect(reopened.xp > 0)
        #expect(reopened.ledger.purchases.isEmpty && reopened.ledger.claims.isEmpty && reopened.ledger.spyglasses.isEmpty)
        #expect(reopened.foundStickers["old-secret"] == nil)
        #expect(reopened.selectedCityID == city.id)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rebuilt)) as! [String: Any]
        #expect(encoded["grid"] == nil)
        let again = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await again.waitForHistory()
        #expect(!again.worldGridResetPending)
        #expect(again.cities.first?.visited == rebuilt.visited)
        #expect(again.walks.first?.newTiles == replayed.newTiles)
    }

    @Test func replayKeepsTheFirstSecretDiscoveryAndDeduplicatesLaterWalks() {
        let grid = HexGrid.world
        let c = Coordinate(lat: -33.65, lon: 115.35)
        let base = grid.centre(of: grid.hex(containing: c))
        let corners = [SIMD2(-300.0, -300), SIMD2(300, -300), SIMD2(300, 300), SIMD2(-300, 300)]
            .map { grid.projection.unproject(base + $0) }
        let city = City(name: "Replay", detail: "", boundary: Boundary(polygons: [GeoPolygon(outer: corners, holes: [])]),
                        tiles: [], visited: [], stickers: ["secret": grid.hex(containing: c)])
        let start = Date(timeIntervalSince1970: 1000)
        let points = [-20.0, 0, 20].enumerated().map { i, x in
            let p = grid.projection.unproject(base + SIMD2(x, 0))
            return TrackPoint(lat: p.lat, lon: p.lon, time: start.timeIntervalSince1970 + Double(i) * 20,
                              accuracy: 5, speed: 1)
        }
        let first = Walk(startedAt: start, endedAt: start.addingTimeInterval(60), points: points)
        let second = Walk(startedAt: start.addingTimeInterval(100), endedAt: start.addingTimeInterval(160), points: points)
        let replayed = CityBuilder.replay([second, first], through: [city])
        #expect(replayed.walks.map(\.id) == [first.id, second.id])
        #expect(replayed.walks[0].newTiles == 1)
        #expect(replayed.walks[1].newTiles == 0)
        #expect(replayed.cities[0].visited == [grid.hex(containing: c)])
        #expect(replayed.secrets["secret"] == first.endedAt)
    }

}

private nonisolated final class ResetProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (@Sendable (URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
