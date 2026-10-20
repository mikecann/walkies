import CoreLocation
import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct CrewTests {
    func city(origin: Coordinate = Coordinate(lat: -33.6, lon: 115.4), size: Double = 50) -> City {
        let grid = HexGrid(projection: LocalProjection(origin: origin), size: size)
        let ring = [SIMD2(-200.0, -200), SIMD2(200.0, -200), SIMD2(200.0, 200), SIMD2(-200.0, 200)].map(grid.projection.unproject)
        let boundary = Boundary(polygons: [GeoPolygon(outer: ring, holes: [])])
        return City(name: "Crew suburb", detail: "Tests", grid: grid, boundary: boundary,
                    tiles: City.hexes(inside: BoundaryShape(boundary, projection: grid.projection), grid: grid), visited: [], roads: [])
    }
    func member(_ id: String = "you", sharing: CrewSharing = .tilesAndTrail, walksCount: Bool = true) -> CrewMember {
        CrewMember(userId: id, name: id == "you" ? "Mike" : "Dad", colour: id == "you" ? "teal" : "blue", sharing: sharing, walksCount: walksCount, joinedAt: 1, isYou: id == "you")
    }
    func crew(_ city: City) -> CrewMap {
        CrewMap(id: "crew", name: "Mike & Dad", createdBy: "you", inviteCode: "ABCD2345", members: [member(), member("dad")], places: [CrewPlace(placeId: "place", clientId: city.id.uuidString, city: city)])
    }
    func walk(_ city: City) -> Walk {
        let date = Date(timeIntervalSince1970: 10_000)
        let points = [-100.0, -50, 0, 50, 100].enumerated().map { n, x in
            let c = city.grid.projection.unproject(SIMD2(x, 0))
            return TrackPoint(lat: c.lat, lon: c.lon, time: date.timeIntervalSince1970 + Double(n) * 40, accuracy: 5, speed: 1)
        }
        return Walk(startedAt: date, endedAt: date.addingTimeInterval(180), points: points)
    }
    func snapshot(_ crew: CrewMap, tiles: [CrewSnapshot.Tile] = [], since: Double = 100, full: Bool = false) -> CrewSnapshot {
        CrewSnapshot(crew: .init(crewId: crew.id, name: crew.name, createdBy: crew.createdBy, inviteCode: crew.inviteCode, createdAt: 1),
                     members: crew.members, places: crew.places.map { .init(placeId: $0.id, clientId: $0.clientId, name: $0.city.name, updatedAt: 1, url: nil) },
                     tiles: tiles, trails: [], secrets: [], serverTime: since, isFull: full)
    }
    func store() -> Store { Store(root: URL.temporaryDirectory.appending(path: "CrewTests-\(UUID())")) }

    @Test func visitQueuesOnceWithPersonalGridIndependentAndHonoursSwitch() {
        let city = city()
        var map = crew(city)
        let samples = [city.grid.projection.origin]
        #expect(map.visit(samples, at: Date(timeIntervalSince1970: 1)) == 1)
        #expect(map.visit(samples, at: .now) == 0)
        #expect(map.pendingTiles.count == 1)
        #expect(map.pendingTiles[0].hexes == [Hex(q: 0, r: 0)])
        #expect(map.firstColour(placeId: "place", hex: Hex(q: 0, r: 0)) == "teal")
        map.members[0].walksCount = false
        #expect(map.visit([city.grid.projection.unproject(SIMD2(100, 0))], at: .now) == 0)
        #expect(map.pendingTiles.count == 1)
    }

    @Test func overlapCountsSharedTilesOnceWhileQueuingEachPlace() {
        let city = city()
        var map = crew(city)
        var neighbour = city
        neighbour.id = UUID()
        map.places.append(CrewPlace(placeId: "overlap", clientId: neighbour.id.uuidString, city: neighbour))
        #expect(map.visit([city.grid.projection.origin], at: .now) == 1)
        #expect(map.pendingTiles.count == 2)
        #expect(map.visit([city.grid.projection.origin], at: .now) == 0)
    }

    @Test func tileBatchesStayBelowBackendLimit() {
        let city = city(size: 5)
        var map = crew(city)
        let samples = city.tiles.prefix(1100).map { city.grid.projection.unproject(city.grid.centre(of: $0)) }
        #expect(map.visit(samples, at: .now) == 1100)
        #expect(map.pendingTiles.count == 3)
        #expect(map.pendingTiles.allSatisfy { $0.hexes.count <= 400 })
    }

    @Test func tilesAndSecretsQueueIndependentlyOfAlreadyVisitedTiles() {
        var city = city()
        city.stickers = ["test-secret": Hex(q: 0, r: 0)]
        city.visited = [Hex(q: 0, r: 0)]
        var map = crew(city)
        #expect(map.visit([city.grid.projection.origin], at: .now) == 0)
        #expect(map.pendingSecrets["test-secret"] != nil)
        #expect(map.secrets["test-secret"]?.by == "you")
    }

    @Test func replayUsesCrewGridAndNeverChangesOriginalOrPersonalRewards() {
        let personal = city(size: 50)
        let shared = city(origin: personal.grid.projection.unproject(SIMD2(37, 21)), size: 35)
        let map = crew(shared)
        let walk = walk(personal)
        let replayed = CrewCoverage.replay(map, walks: [walk])
        var expected = shared
        _ = expected.visit(CoverageTracer.samples(for: walk.points), within: shared.shape())
        #expect(replayed.places[0].city.visited == expected.visited)
        #expect(map.places[0].city.visited.isEmpty)
        #expect(replayed.replayedPlaces == ["place"])
        #expect(!replayed.pendingTrails.isEmpty)
        #expect(replayed.pendingTiles.allSatisfy { $0.hexes.count <= 400 })
    }

    @Test func newPlaceReplayLeavesExistingPlaceCoverageAlone() {
        let city = city()
        var map = crew(city)
        var new = city
        new.id = UUID()
        map.places.append(CrewPlace(placeId: "new", clientId: new.id.uuidString, city: new))
        let replayed = CrewCoverage.replay(map, walks: [walk(city)], placeIDs: ["new"])
        #expect(replayed.places[0].city.visited.isEmpty)
        #expect(!replayed.places[1].city.visited.isEmpty)
        #expect(replayed.pendingTiles.allSatisfy { $0.placeId == "new" })
    }

    @Test func enablingTrailsDoesNotBackfillTilesFromPausedWalks() {
        let city = city()
        let replayed = CrewCoverage.replay(crew(city), walks: [walk(city)], includeTiles: false)
        #expect(replayed.places[0].city.visited.isEmpty)
        #expect(replayed.pendingTiles.isEmpty)
        #expect(!replayed.pendingTrails.isEmpty)
    }

    @Test func clippingSplitsOutsideJourneyAndHoleEvenWithInsideEndpoints() {
        var city = city()
        let projection = city.grid.projection
        let hole = [SIMD2(-20.0, -20), SIMD2(20.0, -20), SIMD2(20.0, 20), SIMD2(-20.0, 20)].map(projection.unproject)
        city.boundary.polygons[0].holes = [hole]
        let run = [-300.0, -100, 100, 300].map { projection.unproject(SIMD2($0, 0)) }
        let clipped = CrewCoverage.clip([run], to: [city])
        #expect(clipped.segments.count == 2)
        for segment in clipped.segments {
            for (a, b) in zip(segment, segment.dropFirst()) {
                #expect(city.shape().contains(projection.project(a.lerp(to: b, 0.5))))
            }
        }
        #expect(clipped.segments.flatMap { $0 }.allSatisfy { abs(projection.project($0).x) <= 200.01 })
    }

    @Test func clippingSupportsDisjointPlacesWithoutConnectingThem() {
        let first = city()
        let second = city(origin: first.grid.projection.unproject(SIMD2(1000, 0)))
        let route = CrewCoverage.clip([[-400.0, 1400].map { first.grid.projection.unproject(SIMD2($0, 0)) }], to: [first, second])
        #expect(route.segments.count == 2)
        #expect(CrewCoverage.clip(route.segments, to: []).segments.isEmpty)
    }

    @Test func drivingAndGPSGapsDoNotProduceSharedConnectingLines() {
        let city = city()
        var route = walk(city)
        route.points[2].wheels = true
        let shared = CrewCoverage.route(for: route.points, cities: [city])
        #expect(!shared.segments.isEmpty)
        for segment in shared.segments {
            let xs = segment.map { city.grid.projection.project($0).x }
            #expect(!(xs.min()! < -10 && xs.max()! > 10))
        }
        var map = crew(city)
        map.members[0].sharing = .tiles
        map.queueTrail(route)
        #expect(map.pendingTrails.isEmpty)
    }

    @Test func incrementalMergeRetainsUnionButServerFirstCreditWins() {
        let city = city()
        var map = crew(city)
        let zero = Hex(q: 0, r: 0), one = Hex(q: 1, r: 0)
        _ = map.visit([city.grid.projection.origin], at: Date(timeIntervalSince1970: 1))
        var pull = snapshot(map, tiles: [.init(placeId: "place", q: 0, r: 0, by: "dad", at: 9000)])
        map.merge(pull, cities: [:], trails: [])
        #expect(map.firstColour(placeId: "place", hex: zero) == "blue")
        pull.tiles = [.init(placeId: "place", q: 1, r: 0, by: "gone", at: 10)]
        pull.serverTime = 101
        map.merge(pull, cities: [:], trails: [])
        #expect(map.places[0].city.visited == [zero, one])
        #expect(map.since == 101)
        #expect(map.firstColour(placeId: "place", hex: one) == CrewColour.fallback)
        #expect(map.memberName("gone") == "Past member")
    }

    @Test func snapshotReplacesOptedOutTrailsAndSecretsButKeepsOfflineQueue() {
        let city = city()
        var map = crew(city)
        map.queueTrail(walk(city))
        map.secrets["old"] = .init(by: "dad", at: 1)
        map.pendingSecrets["local"] = 2
        let trail = CrewTrail(walkClientId: "remote", by: "dad", at: 1, route: .init(segments: [[city.grid.projection.origin]]))
        var pull = snapshot(map)
        pull.members[1].sharing = .tiles
        pull.members[0].sharing = .tiles
        map.merge(pull, cities: [:], trails: [trail])
        #expect(map.trails.isEmpty)
        #expect(map.pendingTrails.isEmpty)
        #expect(map.secrets["old"] == nil)
        #expect(map.secrets["local"]?.at == 2)
    }

    @Test func crewFilesRoundTripAndWipe() {
        let store = store()
        defer { store.wipe() }
        let city = city()
        var map = crew(city)
        _ = map.visit([city.grid.projection.origin], at: .now)
        map.since = 123
        store.save(crews: [map])
        let restored = store.loadCrews()
        #expect(restored.count == 1)
        #expect(restored.first?.since == 123)
        #expect(restored.first?.pendingTiles.count == 1)
        #expect(restored.first?.places[0].city.visited == map.places[0].city.visited)
        store.wipe()
        #expect(store.loadCrews().isEmpty)
    }

    @Test func selectingCrewDoesNotChangePersonalCloudsOrShellInputsAndLinksAreParsed() async {
        let store = store()
        defer { store.wipe() }
        let personal = city()
        let shared = city(origin: personal.grid.projection.unproject(SIMD2(5000, 0)))
        store.save([personal])
        store.save(crews: [crew(shared)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let before = model.balance
        model.currentCrewID = "crew"
        #expect(model.mapCities[0].id == shared.id)
        #expect(model.cities[0].id == personal.id)
        #expect(model.balance == before)
        model.openCrewURL(URL(string: "walkies://join/abcd2345")!)
        #expect(model.pendingCrewInvite == "ABCD2345")
        model.openCrewURL(URL(string: "walkies://signed-in?code=nope")!)
        #expect(model.pendingCrewInvite == "ABCD2345")
        model.wipeLocalData()
        #expect(model.crews.isEmpty)
        #expect(model.currentCrewID == nil)
    }
}

extension CrewTests {
    @Test func walkingContributesToEveryEnabledMapRegardlessOfSelection() async {
        let store = store()
        let personal = city()
        let shared = city(origin: personal.grid.projection.unproject(SIMD2(27, 10)), size: 35)
        var enabled = crew(shared)
        enabled.replayedPlaces = ["place"]
        var paused = enabled
        paused.id = "paused"
        paused.members[0].walksCount = false
        store.save([personal])
        store.save(crews: [enabled, paused])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.currentCrewID = "paused"
        model.startWalk()
        for (n, x) in [-80.0, -30, 20, 70].enumerated() {
            let c = personal.grid.projection.unproject(SIMD2(x, 0))
            model.tracker.onLocation?(CLLocation(coordinate: c.cl, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                                course: 90, speed: 1, timestamp: Date.now.addingTimeInterval(Double(n) * 40)))
        }
        #expect(!model.cities[0].visited.isEmpty)
        #expect(!model.crews[0].places[0].city.visited.isEmpty)
        #expect(!model.crews[0].pendingTiles.isEmpty)
        #expect(model.crews[1].places[0].city.visited.isEmpty)
        #expect(model.crews[1].pendingTiles.isEmpty)
        model.endWalk()
        #expect(model.recap?.crewGains.first?.name == "Mike & Dad")
        #expect((model.recap?.crewGains.first?.tiles ?? 0) > 0)
        #expect(model.walks[0].crewTiles?["crew"] == model.recap?.crewGains.first?.tiles)
        model.wipeLocalData()
    }

    @Test func routeClippingWorkSurvivesRelaunch() async {
        let store = store()
        let city = city()
        var map = crew(city)
        map.routeWork = [walk(city)]
        store.save(crews: [map])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        await model.prepareCrewRoutes()
        #expect(model.crews[0].routeWork.isEmpty)
        #expect(model.crews[0].pendingTrails.count == 1)
        #expect(store.loadCrews()[0].pendingTrails.count == 1)
        model.wipeLocalData()
    }

    @Test func interruptedManualWalkStillQueuesItsCrewTrailOnLaunch() async {
        let store = store()
        let city = city()
        var interrupted = walk(city)
        interrupted.endedAt = nil
        store.save(interrupted)
        store.save(crews: [crew(city)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        #expect(model.crews[0].routeWork.count == 1)
        await model.prepareCrewRoutes()
        #expect(model.crews[0].pendingTrails.count == 1)
        #expect(model.crews[0].pendingTrails[0].walkClientId == interrupted.id.uuidString)
        model.wipeLocalData()
    }

    @Test func placeBuilderUsesExactSharedGridEvenFarFromItsOrigin() {
        let first = city()
        let distant = city(origin: Coordinate(lat: -34.5, lon: 116.2))
        let place = PlaceResult(id: 9, name: "Far suburb", detail: "Tests", kind: "suburb", boundary: distant.boundary, area: 160_000)
        let built = CityBuilder.build(from: place, ways: [], walks: [], near: [distant], grid: first.grid)
        #expect(built.grid == first.grid)
        #expect(built.visited.isEmpty)
        #expect(!built.tiles.isEmpty)
    }

    @Test func inviteCodesAndActionKindsMatchCurrentContract() async throws {
        #expect(CrewInviteCode.isValid(CrewInviteCode.normalise(" abcd2345 ")))
        #expect(!CrewInviteCode.isValid("ABC234"))
        #expect(!CrewInviteCode.isValid("ABCI2345"))
        let server = CrewHTTPServer(map: crew(city()))
        CrewHTTPProtocol.server = server
        defer { CrewHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrewHTTPProtocol.self]
        let api = CrewsAPI(client: ConvexClient(session: URLSession(configuration: configuration)))
        #expect(try await api.create(name: "Crew", colour: "teal", sharing: .tiles).inviteCode == "ABCD2345")
        #expect(try await api.join(code: "ABCD2345", colour: "teal", sharing: .tiles) == "crew")
        #expect(try await api.newInviteCode("crew") == "EFGH2345")
        try await api.remove("crew", userId: "dad")
        for code in ["RATE_LIMITED", "MEMBER_REMOVED", "CREW_FULL", "NOT_A_MEMBER"] {
            let message = ConvexError.coded(code, "Raw backend message").localizedDescription
            #expect(!message.contains("Raw backend"))
        }
    }

    @Test func trailVersionsSurviveRetriesChangesAndLegacySavesAndRespectCap() throws {
        let city = city()
        var map = crew(city)
        let walk = walk(city)
        map.queueTrail(walk)
        let first = map.pendingTrails[0]
        map.pendingTrails[0].file = "claimed"
        map.queueTrail(walk)
        #expect(map.pendingTrails[0].updatedAt == first.updatedAt)
        #expect(map.pendingTrails[0].file == "claimed")
        let route = CrewRoute(segments: [[Coordinate(lat: 1, lon: 1), Coordinate(lat: 2, lon: 2)]])
        map.queueRoute(route, walkClientId: first.id)
        #expect(map.pendingTrails[0].updatedAt > first.updatedAt)
        #expect(map.pendingTrails[0].file == nil)
        let restored = try JSONDecoder().decode(CrewMap.self, from: JSONEncoder().encode(map))
        #expect(restored.pendingTrails[0].updatedAt == map.pendingTrails[0].updatedAt)
        let legacy = Data(#"{"walkClientId":"old","route":{"segments":[]},"file":"personal-upload"}"#.utf8)
        let migrated = try JSONDecoder().decode(CrewPendingTrail.self, from: legacy)
        #expect(migrated.file == nil)
        #expect(migrated.updatedAt.isFinite)
        for n in 0..<100 { map.queueRoute(route, walkClientId: "walk-\(n)") }
        #expect(map.pendingTrails.count == 64)
        map.queueRoute(first.route, walkClientId: first.id)
        #expect(map.pendingTrails.count == 64)
    }

    @Test func boundsCoverNonStreetDiscoveryAndRejectOversizedPlaces() throws {
        var city = city()
        let inside = city.tiles
        city.tiles = [Hex(q: 0, r: 0)]
        let bounds = try CrewPlaceBounds(city: city)
        #expect(inside.allSatisfy { $0.q >= bounds.minQ && $0.q <= bounds.maxQ && $0.r >= bounds.minR && $0.r <= bounds.maxR })
        city.tiles.insert(Hex(q: 1_000_001, r: 0))
        #expect(throws: (any Error).self) { try CrewPlaceBounds(city: city) }
    }

    @Test func snapshotPagingIsAtomicOnFailureAndKeepsExactCursor() async throws {
        let store = store()
        defer { store.wipe() }
        let city = city()
        var local = crew(city)
        local.since = 90
        local.replayedPlaces = ["place"]
        local.trails = [CrewTrail(walkClientId: "walk", by: "you", at: 1, route: CrewRoute(segments: []))]
        store.save(crews: [local])
        let server = CrewHTTPServer(map: crew(city))
        await server.configurePaging(fail: true)
        CrewHTTPProtocol.server = server
        defer { CrewHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrewHTTPProtocol.self]
        let api = CrewsAPI(client: ConvexClient(session: URLSession(configuration: configuration)))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        do { try await model.refreshCrew("crew", api: api); Issue.record("Expected page failure") } catch { }
        #expect(model.crews[0].since == 90)
        #expect(store.loadCrews()[0].since == 90)
        #expect(model.crews[0].places[0].city.visited.isEmpty)
        #expect(model.crews[0].trails.isEmpty)
        await server.configurePaging(fail: false)
        try await model.refreshCrew("crew", api: api)
        #expect(model.crews[0].places[0].city.visited.count == 2001)
        #expect(store.loadCrews()[0].since == 200)
        #expect(model.crews[0].name == "Last page")
        // Initial full sync also echoes cursor.since as explicit JSON null.
        let full = try await api.snapshot("crew", since: nil)
        #expect(full.isFull && full.tiles.count == 2001)
    }

    @Test func firstPlaceRaceRebuildsOnWinningGridBeforeSaving() async throws {
        let store = store()
        defer { store.wipe() }
        let original = city()
        let winning = city(origin: original.grid.projection.unproject(SIMD2(37, 21)), size: 35)
        var local = crew(original)
        local.places = []
        local.pendingPlaces = [CrewPendingPlace(city: original)]
        store.save(crews: [local])
        let server = CrewHTTPServer(map: crew(winning))
        await server.configureRace()
        CrewHTTPProtocol.server = server
        defer { CrewHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrewHTTPProtocol.self]
        let api = CrewsAPI(client: ConvexClient(session: URLSession(configuration: configuration)))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        try await model.uploadCrewPlaces("crew", api: api)
        #expect(model.crews[0].pendingPlaces.isEmpty)
        #expect(await server.uploadCalls == 2)
        #expect(await server.placeClientIDs == [original.id.uuidString, original.id.uuidString])
        let data = try #require(await server.routeFile)
        let saved = try JSONDecoder().decode(City.self, from: data)
        #expect(saved.grid == winning.grid)
        #expect(saved.id == original.id)
        #expect(saved.visited.isEmpty)
    }

    @Test func placeRetryReusesClientAndStorageIDsAfterLostReply() async throws {
        let store = store()
        let city = city()
        var map = crew(city)
        var draft = city
        draft.id = UUID()
        map.pendingPlaces = [CrewPendingPlace(city: draft)]
        store.save(crews: [map])
        let server = CrewHTTPServer(map: crew(city))
        CrewHTTPProtocol.server = server
        defer { CrewHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrewHTTPProtocol.self]
        let api = CrewsAPI(client: ConvexClient(token: nil, session: URLSession(configuration: configuration)))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        do {
            try await model.uploadCrewPlaces("crew", api: api)
            Issue.record("The first place reply should have been lost")
        } catch { }
        #expect(model.crews[0].pendingPlaces[0].file == "crew-route-file")
        #expect(store.loadCrews()[0].pendingPlaces[0].city.id == draft.id)
        try await model.uploadCrewPlaces("crew", api: api)
        #expect(model.crews[0].pendingPlaces.isEmpty)
        #expect(await server.uploadCalls == 1)
        #expect(await server.placeClientIDs == [draft.id.uuidString, draft.id.uuidString])
        let data = try #require(await server.routeFile)
        #expect(try JSONDecoder().decode(City.self, from: data).visited.isEmpty)
        model.wipeLocalData()
    }

    @Test func permanentLimitsDrainQueuesAndExpiredTrailUploadIsReplaced() async throws {
        let store = store()
        defer { store.wipe() }
        let city = city()
        var local = crew(city)
        local.replayedPlaces = ["place"]
        local.queueTrail(walk(city))
        let version = local.pendingTrails[0].updatedAt
        store.save(crews: [local])
        let server = CrewHTTPServer(map: crew(city))
        await server.expireNextTrail()
        CrewHTTPProtocol.server = server
        defer { CrewHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrewHTTPProtocol.self]
        let client = ConvexClient(session: URLSession(configuration: configuration))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(model.crews[0].pendingTrails[0].file == nil)
        #expect(store.loadCrews()[0].pendingTrails[0].updatedAt == version)
        await engine.sync()
        #expect(await server.uploadCalls == 2)
        #expect(model.crews[0].pendingTrails.isEmpty)
        #expect(engine.status == .idle)
        await server.rejectContributions()
        model.editCrew("crew") { crew in
            _ = crew.visit([city.grid.projection.origin], at: .now)
            crew.pendingSecrets["limit"] = Date.now.ms
            crew.queueRoute(CrewRoute(segments: [[Coordinate(lat: 0, lon: 0), Coordinate(lat: 1, lon: 1)]]), walkClientId: "extra")
        }
        await engine.sync()
        #expect(model.crews[0].waiting == 0)
        #expect(model.crews[0].syncMessage != nil)
        #expect(model.crews[0].places[0].city.visited.isEmpty)
        let calls = await server.trailCalls
        await engine.sync()
        #expect(await server.trailCalls == calls)
    }

    @Test func httpSyncRetriesCommittedTilesUsesCursorAndHonoursTrailOptOut() async throws {
        let store = store()
        defer { store.wipe() }
        let city = city()
        var local = crew(city)
        local.places[0].city.stickers = ["secret": Hex(q: 0, r: 0)]
        local.replayedPlaces = ["place"]
        _ = local.visit([city.grid.projection.origin], at: Date(timeIntervalSince1970: 50))
        local.queueTrail(walk(city))
        store.save(crews: [local])
        let server = CrewHTTPServer(map: crew(city))
        CrewHTTPProtocol.server = server
        defer { CrewHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrewHTTPProtocol.self]
        let client = ConvexClient(token: "mock", session: URLSession(configuration: configuration))
        let invalidInvite = try await CrewsAPI(client: client).preview("BAD23456")
        #expect(invalidInvite == nil)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(engine.status != .idle)
        #expect(model.crews[0].pendingTiles.count == 1)
        #expect(await server.tileCalls == 1)
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(model.crews[0].waiting == 0)
        #expect(await server.tileCalls == 2)
        #expect(await server.savedTileCount == 1)
        #expect(await server.savedSecrets == ["secret"])
        #expect(await server.trailCalls == 1)
        #expect(await server.sinceValues.contains(101))
        #expect(model.crews[0].trails.count == 1)
        let restored = try #require(store.loadCrews().first)
        #expect(restored.since == 101)
        #expect(restored.pendingTiles.isEmpty)
        let uploaded = try #require(await server.routeFile)
        let clipped = try JSONDecoder().decode(CrewRoute.self, from: uploaded)
        #expect(!clipped.segments.isEmpty)
        #expect(clipped.segments.flatMap { $0 }.allSatisfy { abs(city.grid.projection.project($0).x) <= 200.01 })
        await server.disableTrails()
        await engine.sync()
        #expect(model.crews[0].trails.isEmpty)
        #expect(model.crews[0].pendingTrails.isEmpty)
        #expect(await server.trailCalls == 1)
        engine.reset()
    }
}

private actor CrewHTTPServer {
    var map: CrewMap
    var savedTileCount: Int { savedTiles.count }
    var tileCalls = 0
    var trailCalls = 0
    var uploadCalls = 0
    var placeClientIDs: [String] = []
    var savedTiles: [String: [String: Any]] = [:]
    var savedSecrets: Set<String> = []
    var sinceValues: [Double] = []
    var routeFile: Data?
    var expireTrail = false
    var rejectLimits = false
    func expireNextTrail() { expireTrail = true }
    func rejectContributions() { rejectLimits = true }
    var paging = false
    var failPage = false
    var racing = false
    var raceWon = false
    var trailSharing = true
    func configurePaging(fail: Bool) { paging = true; failPage = fail; trailSharing = false }
    func configureRace() { racing = true }

    init(map: CrewMap) { self.map = map }
    func disableTrails() { trailSharing = false }

    func respond(_ request: URLRequest) throws -> Data {
        if request.url?.path == "/upload" {
            uploadCalls += 1
            routeFile = Self.body(request)
            return Data(#"{"storageId":"crew-route-file"}"#.utf8)
        }
        if request.url?.path == "/route" { return routeFile! }
        if request.url?.path == "/place" { return try JSONEncoder().encode(map.places[0].city) }
        if request.url?.path == "/api/interpreter" { return Data(#"{"elements":[]}"#.utf8) }
        let call = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
        let path = call["path"] as! String, args = call["args"] as! [String: Any]
        var value: Any = NSNull()
        switch path {
        case "sync:snapshot": value = ["walks": [], "places": [], "secrets": []]
        case "crews:uploadFile":
            #expect(request.url?.path == "/api/action")
            uploadCalls += 1
            routeFile = Data((args["json"] as! String).utf8)
            value = "crew-route-file"
        case "crews:createCrew":
            #expect(request.url?.path == "/api/action")
            value = ["crewId": "crew", "inviteCode": "ABCD2345"]
        case "crews:joinCrew":
            #expect(request.url?.path == "/api/action")
            value = "crew"
        case "crews:newInviteCode":
            #expect(request.url?.path == "/api/action")
            value = "EFGH2345"
        case "crews:removeMember": #expect(request.url?.path == "/api/action")
        case "crews:myCrews":
            let membership = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map.members[0]))
            value = [["crewId": map.id, "name": map.name, "memberCount": 2, "membership": membership]]
        case "crews:crewSnapshot":
            let since = args["since"] as? Double
            if let since { sinceValues.append(since) }
            var members = map.members
            if !trailSharing { members[0].sharing = .tiles }
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(members))
            value = [
                "crew": ["crewId": map.id, "name": map.name, "createdBy": map.createdBy, "inviteCode": map.inviteCode, "createdAt": 1],
                "members": encoded,
                "places": [["placeId": "place", "clientId": map.places[0].clientId, "name": "Crew suburb", "updatedAt": 1, "url": NSNull()]],
                "tiles": (since ?? 0) < 101 ? Array(savedTiles.values) : [],
                "trails": trailSharing && trailCalls > 0 ? [["walkClientId": "walk", "by": "you", "at": 100, "url": "https://crew.walkies.test/route"]] : [],
                "secrets": savedSecrets.map { ["secretId": $0, "by": "you", "at": 50_000] as [String: Any] },
                "serverTime": savedTiles.isEmpty ? 100 : 101,
                "more": false, "cursor": NSNull(),
            ] as [String: Any]
            if racing {
                var page = value as! [String: Any]
                page["places"] = raceWon ? [["placeId": "place", "clientId": map.places[0].clientId, "name": "Winner", "updatedAt": 1, "url": "https://crew.walkies.test/place"]] : []
                value = page
            }
            if paging {
                let cursor = args["cursor"] as? [String: Any]
                let pageIndex = cursor?["position"] as? String == "opaque/second+=" ? 1 : cursor == nil ? 0 : 2
                if let cursor {
                    #expect(cursor["until"] as? Double == 200)
                    if let since { #expect(cursor["since"] as? Double == since) }
                    else { #expect(cursor["since"] is NSNull) }
                }
                if failPage && pageIndex == 1 { return Data(#"{"status":"error","errorData":{"code":"RETRY","message":"page failed"}}"#.utf8) }
                var page = value as! [String: Any]
                let start = pageIndex * 1000, end = min(start + 1000, 2001)
                page["tiles"] = (start..<end).map { ["placeId": "place", "q": $0, "r": 0, "by": "dad", "at": 1] as [String: Any] }
                page["serverTime"] = 200
                page["more"] = pageIndex < 2
                page["cursor"] = pageIndex < 2 ? ["position": pageIndex == 0 ? "opaque/second+=" : "opaque/third+=", "until": 200, "since": since.map { $0 as Any } ?? NSNull()] : NSNull()
                page["crew"] = ["crewId": map.id, "name": pageIndex == 2 ? "Last page" : map.name, "createdBy": map.createdBy, "inviteCode": map.inviteCode, "createdAt": 1]
                value = page
            }
        case "crews:addCrewPlace":
            #expect(request.url?.path == "/api/action")
            #expect(args["bounds"] != nil)
            #expect(args.keys.contains("gridPlaceId"))
            placeClientIDs.append(args["clientId"] as! String)
            if racing {
                if !raceWon {
                    #expect(args["gridPlaceId"] is NSNull)
                    raceWon = true
                    return Data(#"{"status":"error","errorData":{"code":"GRID_CHANGED","message":"Another place won"}}"#.utf8)
                }
                #expect(args["gridPlaceId"] as? String == "place")
            }
            if !racing && placeClientIDs.count == 1 { return Data(#"{"status":"error","errorMessage":"Lost place reply"}"#.utf8) }
            value = "place"
        case "crews:uploadCrewTiles":
            tileCalls += 1
            if rejectLimits { return Self.failure("TILE_LIMIT") }
            for hex in args["hexes"] as! [[Int]] {
                savedTiles["\(hex[0]),\(hex[1])"] = ["placeId": "place", "q": hex[0], "r": hex[1], "by": "you", "at": args["at"]!]
            }
            if tileCalls == 1 { return Data(#"{"status":"error","errorData":{"code":"RETRY","message":"Reply lost after commit"}}"#.utf8) }
            value = 0
        case "crews:crewForInvite": #expect(request.url?.path == "/api/mutation")
        case "crews:uploadCrewTrail":
            #expect(request.url?.path == "/api/action")
            #expect((args["updatedAt"] as? Double)?.isFinite == true)
            trailCalls += 1
            if expireTrail { expireTrail = false; return Self.failure("INVALID_UPLOAD") }
            if rejectLimits { return Self.failure("TRAIL_LIMIT") }
        case "crews:recordCrewSecrets":
            if rejectLimits { return Self.failure("SECRET_LIMIT") }
            for secret in args["secrets"] as! [[String: Any]] { savedSecrets.insert(secret["secretId"] as! String) }
        default: break
        }
        return try JSONSerialization.data(withJSONObject: ["status": "success", "value": value])
    }
    private static func failure(_ code: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["status": "error", "errorData": ["code": code, "message": code]])
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private nonisolated final class CrewHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: CrewHTTPServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.server else { return }
        Task {
            do {
                let data = try await server.respond(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
