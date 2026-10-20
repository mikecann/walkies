import CoreLocation
import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct TeamTests {
    func city(origin: Coordinate = Coordinate(lat: -33.6, lon: 115.4), size: Double = 50) -> City {
        let grid = HexGrid(projection: LocalProjection(origin: origin), size: size)
        let ring = [SIMD2(-200.0, -200), SIMD2(200.0, -200), SIMD2(200.0, 200), SIMD2(-200.0, 200)].map(grid.projection.unproject)
        let boundary = Boundary(polygons: [GeoPolygon(outer: ring, holes: [])])
        return City(name: "Team suburb", detail: "Tests", grid: grid, boundary: boundary,
                    tiles: City.hexes(inside: BoundaryShape(boundary, projection: grid.projection), grid: grid), visited: [], roads: [])
    }
    func member(_ id: String = "you", sharing: TeamSharing = .tilesAndTrail, walksCount: Bool = true) -> TeamMember {
        TeamMember(userId: id, name: id == "you" ? "Mike" : "Dad", colour: id == "you" ? "teal" : "blue", sharing: sharing, walksCount: walksCount, joinedAt: 1, isYou: id == "you")
    }
    func team(_ city: City) -> TeamMap {
        TeamMap(id: "team", name: "Mike & Dad", createdBy: "you", inviteCode: "ABCD2345", members: [member(), member("dad")], places: [TeamPlace(placeId: "place", clientId: city.id.uuidString, city: city)])
    }
    func walk(_ city: City) -> Walk {
        let date = Date(timeIntervalSince1970: 10_000)
        let points = [-100.0, -50, 0, 50, 100].enumerated().map { n, x in
            let c = city.grid.projection.unproject(SIMD2(x, 0))
            return TrackPoint(lat: c.lat, lon: c.lon, time: date.timeIntervalSince1970 + Double(n) * 40, accuracy: 5, speed: 1)
        }
        return Walk(startedAt: date, endedAt: date.addingTimeInterval(180), points: points)
    }
    func snapshot(_ team: TeamMap, tiles: [TeamSnapshot.Tile] = [], since: Double = 100, full: Bool = false) -> TeamSnapshot {
        TeamSnapshot(team: .init(teamId: team.id, name: team.name, createdBy: team.createdBy, inviteCode: team.inviteCode, createdAt: 1),
                     members: team.members, places: team.places.map { .init(placeId: $0.id, clientId: $0.clientId, name: $0.city.name, updatedAt: 1, url: nil) },
                     tiles: tiles, trails: [], secrets: [], serverTime: since, isFull: full)
    }
    func store() -> Store { Store(root: URL.temporaryDirectory.appending(path: "TeamTests-\(UUID())")) }

    @Test func visitQueuesOnceWithPersonalGridIndependentAndHonoursSwitch() {
        let city = city()
        var map = team(city)
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
        var map = team(city)
        var neighbour = city
        neighbour.id = UUID()
        map.places.append(TeamPlace(placeId: "overlap", clientId: neighbour.id.uuidString, city: neighbour))
        #expect(map.visit([city.grid.projection.origin], at: .now) == 1)
        #expect(map.pendingTiles.count == 2)
        #expect(map.visit([city.grid.projection.origin], at: .now) == 0)
    }

    @Test func tileBatchesStayBelowBackendLimit() {
        let city = city(size: 5)
        var map = team(city)
        let samples = city.tiles.prefix(1100).map { city.grid.projection.unproject(city.grid.centre(of: $0)) }
        #expect(map.visit(samples, at: .now) == 1100)
        #expect(map.pendingTiles.count == 3)
        #expect(map.pendingTiles.allSatisfy { $0.hexes.count <= 400 })
    }

    @Test func tilesAndSecretsQueueIndependentlyOfAlreadyVisitedTiles() {
        var city = city()
        city.stickers = ["test-secret": Hex(q: 0, r: 0)]
        city.visited = [Hex(q: 0, r: 0)]
        var map = team(city)
        #expect(map.visit([city.grid.projection.origin], at: .now) == 0)
        #expect(map.pendingSecrets["test-secret"] != nil)
        #expect(map.secrets["test-secret"]?.by == "you")
    }

    @Test func replayUsesTeamGridAndNeverChangesOriginalOrPersonalRewards() {
        let personal = city(size: 50)
        let shared = city(origin: personal.grid.projection.unproject(SIMD2(37, 21)), size: 35)
        let map = team(shared)
        let walk = walk(personal)
        let replayed = TeamCoverage.replay(map, walks: [walk])
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
        var map = team(city)
        var new = city
        new.id = UUID()
        map.places.append(TeamPlace(placeId: "new", clientId: new.id.uuidString, city: new))
        let replayed = TeamCoverage.replay(map, walks: [walk(city)], placeIDs: ["new"])
        #expect(replayed.places[0].city.visited.isEmpty)
        #expect(!replayed.places[1].city.visited.isEmpty)
        #expect(replayed.pendingTiles.allSatisfy { $0.placeId == "new" })
    }

    @Test func enablingTrailsDoesNotBackfillTilesFromPausedWalks() {
        let city = city()
        let replayed = TeamCoverage.replay(team(city), walks: [walk(city)], includeTiles: false)
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
        let clipped = TeamCoverage.clip([run], to: [city])
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
        let route = TeamCoverage.clip([[-400.0, 1400].map { first.grid.projection.unproject(SIMD2($0, 0)) }], to: [first, second])
        #expect(route.segments.count == 2)
        #expect(TeamCoverage.clip(route.segments, to: []).segments.isEmpty)
    }

    @Test func drivingAndGPSGapsDoNotProduceSharedConnectingLines() {
        let city = city()
        var route = walk(city)
        route.points[2].wheels = true
        let shared = TeamCoverage.route(for: route.points, cities: [city])
        #expect(!shared.segments.isEmpty)
        for segment in shared.segments {
            let xs = segment.map { city.grid.projection.project($0).x }
            #expect(!(xs.min()! < -10 && xs.max()! > 10))
        }
        var map = team(city)
        map.members[0].sharing = .tiles
        map.queueTrail(route)
        #expect(map.pendingTrails.isEmpty)
    }

    @Test func incrementalMergeRetainsUnionButServerFirstCreditWins() {
        let city = city()
        var map = team(city)
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
        #expect(map.firstColour(placeId: "place", hex: one) == TeamColour.fallback)
        #expect(map.memberName("gone") == "Past member")
    }

    @Test func snapshotReplacesOptedOutTrailsAndSecretsButKeepsOfflineQueue() {
        let city = city()
        var map = team(city)
        map.queueTrail(walk(city))
        map.secrets["old"] = .init(by: "dad", at: 1)
        map.pendingSecrets["local"] = 2
        let trail = TeamTrail(walkClientId: "remote", by: "dad", at: 1, route: .init(segments: [[city.grid.projection.origin]]))
        var pull = snapshot(map)
        pull.members[1].sharing = .tiles
        pull.members[0].sharing = .tiles
        map.merge(pull, cities: [:], trails: [trail])
        #expect(map.trails.isEmpty)
        #expect(map.pendingTrails.isEmpty)
        #expect(map.secrets["old"] == nil)
        #expect(map.secrets["local"]?.at == 2)
    }

    @Test func teamFilesRoundTripAndWipe() {
        let store = store()
        defer { store.wipe() }
        let city = city()
        var map = team(city)
        _ = map.visit([city.grid.projection.origin], at: .now)
        map.since = 123
        store.save(teams: [map])
        let restored = store.loadTeams()
        #expect(restored.count == 1)
        #expect(restored.first?.since == 123)
        #expect(restored.first?.pendingTiles.count == 1)
        #expect(restored.first?.places[0].city.visited == map.places[0].city.visited)
        store.wipe()
        #expect(store.loadTeams().isEmpty)
    }

    @Test func selectingTeamDoesNotChangePersonalCloudsOrShellInputsAndLinksAreParsed() async {
        let store = store()
        defer { store.wipe() }
        let personal = city()
        let shared = city(origin: personal.grid.projection.unproject(SIMD2(5000, 0)))
        store.save([personal])
        store.save(teams: [team(shared)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let before = model.balance
        model.currentTeamID = "team"
        #expect(model.mapCities[0].id == shared.id)
        #expect(model.cities[0].id == personal.id)
        #expect(model.balance == before)
        model.openTeamURL(URL(string: "walkies://join/abcd2345")!)
        #expect(model.pendingTeamInvite == "ABCD2345")
        model.openTeamURL(URL(string: "walkies://signed-in?code=nope")!)
        #expect(model.pendingTeamInvite == "ABCD2345")
        model.wipeLocalData()
        #expect(model.teams.isEmpty)
        #expect(model.currentTeamID == nil)
    }
}

extension TeamTests {
    @Test func walkingContributesToEveryEnabledMapRegardlessOfSelection() async {
        let store = store()
        let personal = city()
        let shared = city(origin: personal.grid.projection.unproject(SIMD2(27, 10)), size: 35)
        var enabled = team(shared)
        enabled.replayedPlaces = ["place"]
        var paused = enabled
        paused.id = "paused"
        paused.members[0].walksCount = false
        store.save([personal])
        store.save(teams: [enabled, paused])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.currentTeamID = "paused"
        model.startWalk()
        for (n, x) in [-80.0, -30, 20, 70].enumerated() {
            let c = personal.grid.projection.unproject(SIMD2(x, 0))
            model.tracker.onLocation?(CLLocation(coordinate: c.cl, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                                course: 90, speed: 1, timestamp: Date.now.addingTimeInterval(Double(n) * 40)))
        }
        #expect(!model.cities[0].visited.isEmpty)
        #expect(!model.teams[0].places[0].city.visited.isEmpty)
        #expect(!model.teams[0].pendingTiles.isEmpty)
        #expect(model.teams[1].places[0].city.visited.isEmpty)
        #expect(model.teams[1].pendingTiles.isEmpty)
        model.endWalk()
        #expect(model.recap?.teamGains.first?.name == "Mike & Dad")
        #expect((model.recap?.teamGains.first?.tiles ?? 0) > 0)
        #expect(model.walks[0].teamTiles?["team"] == model.recap?.teamGains.first?.tiles)
        model.wipeLocalData()
    }

    @Test func routeClippingWorkSurvivesRelaunch() async {
        let store = store()
        let city = city()
        var map = team(city)
        map.routeWork = [walk(city)]
        store.save(teams: [map])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        await model.prepareTeamRoutes()
        #expect(model.teams[0].routeWork.isEmpty)
        #expect(model.teams[0].pendingTrails.count == 1)
        #expect(store.loadTeams()[0].pendingTrails.count == 1)
        model.wipeLocalData()
    }

    @Test func interruptedManualWalkStillQueuesItsTeamTrailOnLaunch() async {
        let store = store()
        let city = city()
        var interrupted = walk(city)
        interrupted.endedAt = nil
        store.save(interrupted)
        store.save(teams: [team(city)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        #expect(model.teams[0].routeWork.count == 1)
        await model.prepareTeamRoutes()
        #expect(model.teams[0].pendingTrails.count == 1)
        #expect(model.teams[0].pendingTrails[0].walkClientId == interrupted.id.uuidString)
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
        #expect(TeamInviteCode.isValid(TeamInviteCode.normalise(" abcd2345 ")))
        #expect(!TeamInviteCode.isValid("ABC234"))
        #expect(!TeamInviteCode.isValid("ABCI2345"))
        let server = TeamHTTPServer(map: team(city()))
        TeamHTTPProtocol.server = server
        defer { TeamHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        let api = TeamsAPI(client: ConvexClient(session: URLSession(configuration: configuration)))
        #expect(try await api.create(name: "Team", colour: "teal", sharing: .tiles).inviteCode == "ABCD2345")
        #expect(try await api.join(code: "ABCD2345", colour: "teal", sharing: .tiles) == "team")
        #expect(try await api.newInviteCode("team") == "EFGH2345")
        try await api.remove("team", userId: "dad")
        for code in ["RATE_LIMITED", "MEMBER_REMOVED", "TEAM_FULL", "NOT_A_MEMBER"] {
            let message = ConvexError.coded(code, "Raw backend message").localizedDescription
            #expect(!message.contains("Raw backend"))
        }
    }

    @Test func trailVersionsSurviveRetriesChangesAndLegacySavesAndRespectCap() throws {
        let city = city()
        var map = team(city)
        let walk = walk(city)
        map.queueTrail(walk)
        let first = map.pendingTrails[0]
        map.pendingTrails[0].file = "claimed"
        map.queueTrail(walk)
        #expect(map.pendingTrails[0].updatedAt == first.updatedAt)
        #expect(map.pendingTrails[0].file == "claimed")
        let route = TeamRoute(segments: [[Coordinate(lat: 1, lon: 1), Coordinate(lat: 2, lon: 2)]])
        map.queueRoute(route, walkClientId: first.id)
        #expect(map.pendingTrails[0].updatedAt > first.updatedAt)
        #expect(map.pendingTrails[0].file == nil)
        let restored = try JSONDecoder().decode(TeamMap.self, from: JSONEncoder().encode(map))
        #expect(restored.pendingTrails[0].updatedAt == map.pendingTrails[0].updatedAt)
        let legacy = Data(#"{"walkClientId":"old","route":{"segments":[]},"file":"personal-upload"}"#.utf8)
        let migrated = try JSONDecoder().decode(TeamPendingTrail.self, from: legacy)
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
        let bounds = try TeamPlaceBounds(city: city)
        #expect(inside.allSatisfy { $0.q >= bounds.minQ && $0.q <= bounds.maxQ && $0.r >= bounds.minR && $0.r <= bounds.maxR })
        city.tiles.insert(Hex(q: 1_000_001, r: 0))
        #expect(throws: (any Error).self) { try TeamPlaceBounds(city: city) }
    }

    @Test func snapshotPagingIsAtomicOnFailureAndKeepsExactCursor() async throws {
        let store = store()
        defer { store.wipe() }
        let city = city()
        var local = team(city)
        local.since = 90
        local.replayedPlaces = ["place"]
        local.trails = [TeamTrail(walkClientId: "walk", by: "you", at: 1, route: TeamRoute(segments: []))]
        store.save(teams: [local])
        let server = TeamHTTPServer(map: team(city))
        await server.configurePaging(fail: true)
        TeamHTTPProtocol.server = server
        defer { TeamHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        let api = TeamsAPI(client: ConvexClient(session: URLSession(configuration: configuration)))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        do { try await model.refreshTeam("team", api: api); Issue.record("Expected page failure") } catch { }
        #expect(model.teams[0].since == 90)
        #expect(store.loadTeams()[0].since == 90)
        #expect(model.teams[0].places[0].city.visited.isEmpty)
        #expect(model.teams[0].trails.isEmpty)
        await server.configurePaging(fail: false)
        try await model.refreshTeam("team", api: api)
        #expect(model.teams[0].places[0].city.visited.count == 2001)
        #expect(store.loadTeams()[0].since == 200)
        #expect(model.teams[0].name == "Last page")
        // Initial full sync also echoes cursor.since as explicit JSON null.
        let full = try await api.snapshot("team", since: nil)
        #expect(full.isFull && full.tiles.count == 2001)
    }

    @Test func firstPlaceRaceRebuildsOnWinningGridBeforeSaving() async throws {
        let store = store()
        defer { store.wipe() }
        let original = city()
        let winning = city(origin: original.grid.projection.unproject(SIMD2(37, 21)), size: 35)
        var local = team(original)
        local.places = []
        local.pendingPlaces = [TeamPendingPlace(city: original)]
        store.save(teams: [local])
        let server = TeamHTTPServer(map: team(winning))
        await server.configureRace()
        TeamHTTPProtocol.server = server
        defer { TeamHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        let api = TeamsAPI(client: ConvexClient(session: URLSession(configuration: configuration)))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        try await model.uploadTeamPlaces("team", api: api)
        #expect(model.teams[0].pendingPlaces.isEmpty)
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
        var map = team(city)
        var draft = city
        draft.id = UUID()
        map.pendingPlaces = [TeamPendingPlace(city: draft)]
        store.save(teams: [map])
        let server = TeamHTTPServer(map: team(city))
        TeamHTTPProtocol.server = server
        defer { TeamHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        let api = TeamsAPI(client: ConvexClient(token: nil, session: URLSession(configuration: configuration)))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        do {
            try await model.uploadTeamPlaces("team", api: api)
            Issue.record("The first place reply should have been lost")
        } catch { }
        #expect(model.teams[0].pendingPlaces[0].file == "team-route-file")
        #expect(store.loadTeams()[0].pendingPlaces[0].city.id == draft.id)
        #expect(store.loadTeams()[0].pendingPlaces[0].file == "team-route-file")
        try await model.uploadTeamPlaces("team", api: api)
        #expect(model.teams[0].pendingPlaces.isEmpty)
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
        var local = team(city)
        local.replayedPlaces = ["place"]
        local.queueTrail(walk(city))
        let version = local.pendingTrails[0].updatedAt
        store.save(teams: [local])
        let server = TeamHTTPServer(map: team(city))
        await server.expireNextTrail()
        TeamHTTPProtocol.server = server
        defer { TeamHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        let client = ConvexClient(session: URLSession(configuration: configuration))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(model.teams[0].pendingTrails[0].file == nil)
        #expect(store.loadTeams()[0].pendingTrails[0].updatedAt == version)
        await engine.sync()
        #expect(await server.uploadCalls == 2)
        #expect(model.teams[0].pendingTrails.isEmpty)
        #expect(engine.status == .idle)
        await server.rejectContributions()
        model.editTeam("team") { team in
            _ = team.visit([city.grid.projection.origin], at: .now)
            team.pendingSecrets["limit"] = Date.now.ms
            team.queueRoute(TeamRoute(segments: [[Coordinate(lat: 0, lon: 0), Coordinate(lat: 1, lon: 1)]]), walkClientId: "extra")
        }
        await engine.sync()
        #expect(model.teams[0].waiting == 0)
        #expect(model.teams[0].syncMessage != nil)
        #expect(model.teams[0].places[0].city.visited.isEmpty)
        let calls = await server.trailCalls
        await engine.sync()
        #expect(await server.trailCalls == calls)
    }

    @Test func httpSyncRetriesCommittedTilesUsesCursorAndHonoursTrailOptOut() async throws {
        let store = store()
        defer { store.wipe() }
        let city = city()
        var local = team(city)
        local.places[0].city.stickers = ["secret": Hex(q: 0, r: 0)]
        local.replayedPlaces = ["place"]
        _ = local.visit([city.grid.projection.origin], at: Date(timeIntervalSince1970: 50))
        local.queueTrail(walk(city))
        store.save(teams: [local])
        let server = TeamHTTPServer(map: team(city))
        TeamHTTPProtocol.server = server
        defer { TeamHTTPProtocol.server = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        let client = ConvexClient(token: "mock", session: URLSession(configuration: configuration))
        let invalidInvite = try await TeamsAPI(client: client).preview("BAD23456")
        #expect(invalidInvite == nil)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(engine.status != .idle)
        #expect(model.teams[0].pendingTiles.count == 1)
        #expect(await server.tileCalls == 1)
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(model.teams[0].waiting == 0)
        #expect(await server.tileCalls == 2)
        #expect(await server.savedTileCount == 1)
        #expect(await server.savedSecrets == ["secret"])
        #expect(await server.trailCalls == 1)
        #expect(await server.sinceValues.contains(101))
        #expect(model.teams[0].trails.count == 1)
        let restored = try #require(store.loadTeams().first)
        #expect(restored.since == 101)
        #expect(restored.pendingTiles.isEmpty)
        let uploaded = try #require(await server.routeFile)
        let clipped = try JSONDecoder().decode(TeamRoute.self, from: uploaded)
        #expect(!clipped.segments.isEmpty)
        #expect(clipped.segments.flatMap { $0 }.allSatisfy { abs(city.grid.projection.project($0).x) <= 200.01 })
        await server.disableTrails()
        await engine.sync()
        #expect(model.teams[0].trails.isEmpty)
        #expect(model.teams[0].pendingTrails.isEmpty)
        #expect(await server.trailCalls == 1)
        engine.reset()
    }
}

extension TeamTests {
    func fix(_ model: AppModel, city: City, x: Double, seconds: Double) {
        let c = city.grid.projection.unproject(SIMD2(x, 0))
        model.tracker.onLocation?(CLLocation(coordinate: c.cl, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                            course: 90, speed: 1, timestamp: Date.now.addingTimeInterval(seconds)))
    }

    @Test func teamOnlySecretsNeverEnterPersonalBookOrAwardShells() async throws {
        let store = store()
        defer { store.wipe() }
        var shared = city()
        let entry = try #require(LoreLibrary.all.first)
        shared.stickers = [entry.id: Hex(q: 0, r: 0)]
        var map = team(shared)
        map.replayedPlaces = ["place"]
        store.save(teams: [map])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let balance = model.balance, xp = model.xp
        model.startWalk()
        fix(model, city: shared, x: -60, seconds: 0)
        fix(model, city: shared, x: 60, seconds: 80)
        #expect(model.teams[0].secrets[entry.id]?.by == "you")
        #expect(model.foundStickers.isEmpty)
        #expect(model.stickerQueue.isEmpty)
        #expect(model.balance == balance)
        #expect(model.xp == xp)
        model.endWalk()
        #expect(model.balance == balance)
        #expect(store.loadStickers().isEmpty)
    }

    @Test func fixesThrottleTeamFilesAndOnlyChangedTeamIsWritten() async throws {
        let root = URL.temporaryDirectory.appending(path: "TeamSaveTest-\(UUID())")
        let store = Store(root: root)
        defer { store.wipe() }
        let shared = city()
        var first = team(shared)
        first.replayedPlaces = ["place"]
        var second = team(city(origin: Coordinate(lat: -34, lon: 116)))
        second.id = "other"
        store.save(teams: [first, second])
        func file(_ id: String) -> URL { root.appending(path: "teams/\(Data(id.utf8).base64EncodedString()).json") }
        let otherFile = file("other")
        // Valid trailing whitespace makes an unexpected rewrite detectable.
        var otherBytes = try Data(contentsOf: otherFile)
        otherBytes.append(Data("\n  \n".utf8))
        try otherBytes.write(to: otherFile)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.startWalk()
        model.saveNow()
        let before = try Data(contentsOf: file("team"))
        for (i, x) in [-100.0, -50, 0, 50, 100].enumerated() { fix(model, city: shared, x: x, seconds: Double(i) * 40) }
        #expect(!model.teams[0].pendingTiles.isEmpty)
        #expect(try Data(contentsOf: file("team")) == before)
        model.saveNow()
        #expect(!store.loadTeams()[0].pendingTiles.isEmpty)
        #expect(try Data(contentsOf: otherFile) == otherBytes)
        model.endWalk()
    }

    @Test func queueEditsDoNotInvalidatePersonalOrTeamCloudsAndTintsRefreshWithTiles() async {
        let store = store()
        defer { store.wipe() }
        let shared = city()
        let personal = city(origin: Coordinate(lat: -34, lon: 116))
        store.save([personal])
        store.save(teams: [team(shared)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let personalKey = model.cloudKey
        model.editTeam("team") { _ = $0.visit([shared.grid.projection.origin], at: .now) }
        #expect(model.cloudKey == personalKey)
        model.currentTeamID = "team"
        let tint = CloudField.Tile(grid: shared.grid, hex: Hex(q: 0, r: 0))
        #expect(model.teamTints[tint] == "teal")
        let teamKey = model.cloudKey
        model.editTeam("team") { $0.pendingTiles = [] }
        #expect(model.cloudKey == teamKey)
        #expect(model.teamTints[tint] == "teal")
        model.startWalk()
        fix(model, city: personal, x: -100, seconds: 0)
        fix(model, city: personal, x: 0, seconds: 80)
        #expect(model.cloudKey == teamKey)
        model.endWalk()
        #expect(model.cloudKey == teamKey)
        model.setTeamPreferences("team", colour: "orange", sharing: .tiles, walksCount: true)
        #expect(model.teamTints[tint] == "orange")
        model.editTeam("team", mapChanged: true) { $0.places[0].first[Hex(q: 1, r: 0)] = TeamDiscovery(by: "dad", at: 1) }
        #expect(model.cloudKey != teamKey)
        #expect(model.teamTints[CloudField.Tile(grid: shared.grid, hex: Hex(q: 1, r: 0))] == "blue")
    }

    @Test func secondInviteReplacesFirstAndRejectsItsLatePreview() {
        var draft = TeamInviteDraft()
        draft.replace(with: "ABCD2345")
        let first = draft.receive(.init(name: "First", memberNames: []), for: "ABCD2345")
        #expect(first)
        draft.replace(with: "EFGH2345")
        #expect(draft.preview == nil)
        #expect(draft.checkedCode.isEmpty)
        let stale = draft.receive(.init(name: "First", memberNames: []), for: "ABCD2345")
        #expect(!stale)
        let second = draft.receive(.init(name: "Second", memberNames: []), for: "EFGH2345")
        #expect(second)
        #expect(draft.preview?.name == "Second")
    }

    @Test func replayPacksManyWalksAndJoinsConsecutiveRouteSteps() {
        let shared = city()
        var walks = (0..<20).map { _ in walk(shared) }
        for i in walks.indices { walks[i].startedAt += Double(i) }
        let replayed = TeamCoverage.replay(team(shared), walks: walks)
        #expect(replayed.pendingTiles.count == 1)
        #expect(Set(replayed.pendingTiles.flatMap(\.hexes)).count == replayed.places[0].city.visited.count)
        #expect(TeamCoverage.route(for: walks[0].points, cities: [shared]).segments.count == 1)
    }

    @Test func packedReplayKeepsEachTileDiscoveryDate() {
        let shared = city()
        var first = walk(shared), second = walk(shared)
        first.points = Array(first.points.prefix(2))
        second.startedAt += 1000
        second.points = Array(second.points.suffix(2))
        let replayed = TeamCoverage.replay(team(shared), walks: [first, second])
        #expect(replayed.pendingTiles.count == 1)
        let batch = replayed.pendingTiles[0]
        #expect(batch.discoveredAt?.count == batch.hexes.count)
        #expect(Set(batch.discoveredAt ?? []) == [first.startedAt.ms, second.startedAt.ms])
        for (index, hex) in batch.hexes.enumerated() {
            #expect(replayed.places[0].first[hex]?.at == batch.discoveredAt?[index])
        }
    }

    @Test func pausedQueuesAreClearedAndPausedWalksNeverReplayAfterResume() async {
        let store = store()
        defer { store.wipe() }
        let shared = city()
        var map = team(shared)
        _ = map.visit([shared.grid.projection.origin], at: .now)
        map.pendingSecrets["secret"] = 1
        map.queueTrail(walk(shared))
        map.routeWork = [walk(shared)]
        store.save(teams: [map])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.startWalk()
        let pausedWalkID = model.activeWalk?.id
        model.setTeamPreferences("team", colour: "teal", sharing: .tilesAndTrail, walksCount: false)
        #expect(model.teams[0].waiting == 0)
        #expect(model.teams[0].replayedPlaces == ["place"])
        #expect(model.teams[0].excludedWalks?.contains(pausedWalkID!) == true)
        for (i, x) in [-100.0, -50, 0, 50, 100].enumerated() { fix(model, city: shared, x: x, seconds: Double(i) * 40) }
        model.endWalk()
        #expect(model.teams[0].waiting == 0)
        model.setTeamPreferences("team", colour: "teal", sharing: .tilesAndTrail, walksCount: true)
        await model.replayTeamHistory("team", forceTrails: true)
        #expect(model.teams[0].waiting == 0)
        #expect(store.loadTeams()[0].excludedWalks?.contains(pausedWalkID!) == true)
        var paused = team(shared)
        paused.members[0].walksCount = false
        let replayed = TeamCoverage.replay(paused, walks: [walk(shared)])
        #expect(replayed.replayedPlaces == ["place"])
        #expect(replayed.waiting == 0)
    }

    @Test func overlappingReplaysShareWorkerAndTilesOnlyNeverQueuesTrails() async {
        let store = store()
        defer { store.wipe() }
        let shared = city()
        var map = team(shared)
        map.members[0].sharing = .tiles
        store.save(teams: [map])
        for _ in 0..<30 { store.save(walk(shared)) }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        async let first: Void = model.replayTeamHistory("team")
        async let second: Void = model.replayTeamHistory("team")
        _ = await (first, second)
        #expect(model.teams[0].pendingTiles.count == 1)
        #expect(model.teams[0].pendingTrails.isEmpty)
        #expect(model.teams[0].routeWork.isEmpty)
    }

    @Test func switchingMapsRestoresEachSelectionAndBlocksPersonalSpyglasses() async {
        let store = store()
        defer { store.wipe() }
        let first = city(), second = city(origin: Coordinate(lat: -34, lon: 116))
        store.save([first, second])
        store.save(teams: [team(city())])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.currentTeamID = nil
        model.select(second.id)
        model.currentTeamID = "team"
        let teamSelection = model.selectedCityID
        #expect(model.activeSpyglassRing == nil)
        #expect(!model.useSpyglass())
        model.currentTeamID = nil
        #expect(model.selectedCityID == second.id)
        model.currentTeamID = "team"
        #expect(model.selectedCityID == teamSelection)
    }

    @Test func staleListsAndSnapshotsCannotUndoJoinOrLeaveAndRemovalShowsMessage() async {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let revision = model.teamMembershipRevision
        model.joinedTeam("team")
        #expect(!model.acceptTeamList([], revision: revision))
        #expect(model.teams.map(\.id) == ["team"])
        model.retainTeams([])
        model.applyTeam(snapshot(team(city())), cities: [:], trails: [])
        #expect(model.teams.isEmpty)
        model.joinedTeam("team")
        #expect(model.acceptTeamList([], revision: model.teamMembershipRevision))
        #expect(model.teamNotice != nil)
    }

    @Test func joinReplaysActivePrefixAndCreditsItWithoutSharingUnfinishedTrail() async {
        let store = store()
        defer { store.wipe() }
        let shared = city()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.startWalk()
        fix(model, city: shared, x: -100, seconds: 0)
        fix(model, city: shared, x: 0, seconds: 80)
        model.joinedTeam("team")
        model.applyTeam(snapshot(team(shared)), cities: ["place": shared], trails: [])
        await model.replayTeamHistory("team")
        let gained = model.teams[0].places[0].city.visited.count
        #expect(gained > 0)
        #expect(model.teams[0].pendingTrails.isEmpty)
        model.endWalk()
        #expect(model.walks[0].teamTiles?["team"] == gained)
    }

    @Test func droppedShortAutomaticWalkDoesNotQueueTeamRoute() async {
        let store = store()
        defer { store.wipe() }
        let shared = city()
        store.save(teams: [team(shared)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        for (i, x) in [-180.0, -130, -80, -30, 20, 70].enumerated() { fix(model, city: shared, x: x, seconds: Double(i) * 40) }
        #expect(!model.autoWalkPending)
        fix(model, city: shared, x: 100, seconds: 1000)
        #expect(model.walks.isEmpty)
        await model.prepareTeamRoutes()
        #expect(model.teams[0].routeWork.isEmpty)
        #expect(model.teams[0].pendingTrails.isEmpty)
    }
}

extension TeamTests {
    fileprivate func client(_ server: TeamHTTPServer) -> ConvexClient {
        TeamHTTPProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        return ConvexClient(session: URLSession(configuration: configuration))
    }

    @Test func unchangedTrailVersionsAreReusedAndOneFailedFileDoesNotFailRefresh() async throws {
        let store = store()
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        let shared = city()
        var map = team(shared)
        map.replayedPlaces = ["place"]
        store.save(teams: [map])
        let route = TeamCoverage.route(for: walk(shared).points, cities: [shared])
        let good = TeamTrail(walkClientId: "good", by: "dad", at: 1, route: route)
        var changed = TeamTrail(walkClientId: "changed", by: "dad", at: 1, route: route)
        let server = TeamHTTPServer(map: map)
        await server.setRemoteTrails([good, changed], failures: ["changed"])
        let api = TeamsAPI(client: client(server))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        try await model.refreshTeam("team", api: api)
        #expect(model.teams[0].trails.count == 1)
        #expect(model.teams[0].since == 100)
        #expect(await server.routeDownloads == 2)
        await server.setRemoteTrails([good, changed])
        try await model.refreshTeam("team", api: api)
        #expect(model.teams[0].trails.count == 2)
        #expect(await server.routeDownloads == 3)
        try await model.refreshTeam("team", api: api)
        #expect(await server.routeDownloads == 3)
        changed.at = 2
        await server.setRemoteTrails([good, changed])
        try await model.refreshTeam("team", api: api)
        #expect(await server.routeDownloads == 4)
    }

    @Test func idleSyncRefreshesOnceAndPausedOrTilesOnlyTeamsNeverUploadRoutes() async {
        for paused in [true, false] {
            let store = store()
            let shared = city()
            var local = team(shared)
            local.queueTrail(walk(shared))
            _ = local.visit([shared.grid.projection.origin], at: .now)
            local.pendingSecrets["secret"] = 1
            local.routeWork = [walk(shared)]
            var remote = local
            remote.members[0].sharing = .tiles
            if paused { remote.members[0].walksCount = false }
            remote.replayedPlaces = ["place"]
            local.replayedPlaces = ["place"]
            store.save(teams: [local])
            let server = TeamHTTPServer(map: remote)
            let client = client(server)
            let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
            await model.waitForHistory()
            let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
            await engine.sync()
            #expect(await server.uploadCalls == 0)
            #expect(await server.trailCalls == 0)
            #expect(model.teams[0].pendingTrails.isEmpty)
            #expect(model.teams[0].routeWork.isEmpty)
            if paused {
                #expect(await server.tileCalls == 0)
                #expect(await server.savedSecrets.isEmpty)
                #expect(await server.snapshotCalls == 1)
                #expect(model.teams[0].waiting == 0)
            }
            store.wipe()
        }
        TeamHTTPProtocol.server = nil
    }

    @Test func rejectedSecretAloneGetsRefreshWithoutLeavingOptimisticCredit() async {
        let store = store()
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        var map = team(city())
        map.replayedPlaces = ["place"]
        map.pendingSecrets["limit"] = 1
        map.secrets["limit"] = TeamDiscovery(by: "you", at: 1)
        store.save(teams: [map])
        let server = TeamHTTPServer(map: map)
        await server.rejectContributions()
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(model.teams[0].pendingSecrets.isEmpty)
        #expect(model.teams[0].secrets["limit"] == nil)
        #expect(await server.snapshotCalls == 2)
    }

    @Test func tilesOnlyJoinReplayNeverUploadsAnyRouteFile() async {
        let store = store()
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        let shared = city()
        var map = team(shared)
        map.members[0].sharing = .tiles
        store.save(teams: [map])
        store.save(walk(shared))
        let server = TeamHTTPServer(map: map)
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        await engine.sync()
        #expect(await server.savedTileCount > 0)
        #expect(await server.uploadCalls == 0)
        #expect(await server.trailCalls == 0)
        #expect(model.teams[0].pendingTrails.isEmpty)
    }

    @Test func joinFinishingAfterEndWalkStillCreditsSavedWalkAndRecap() async throws {
        let store = store()
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        let shared = city()
        let server = TeamHTTPServer(map: team(shared))
        let api = TeamsAPI(client: client(server))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.startWalk()
        fix(model, city: shared, x: -100, seconds: 0)
        fix(model, city: shared, x: 0, seconds: 80)
        model.joinedTeam("team")
        model.applyTeam(snapshot(team(shared)), cities: ["place": shared], trails: [])
        await server.pauseReply("teams:teamSnapshot")
        let refresh = Task { try await model.refreshTeam("team", api: api) }
        for _ in 0..<200 { if await server.replyHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await server.replyHeld)
        model.endWalk()
        await server.releaseReply()
        try await refresh.value
        let gained = model.teams[0].places[0].city.visited.count
        #expect(gained > 0)
        #expect(model.walks[0].teamTiles?["team"] == gained)
        #expect(model.recap?.teamGains.first?.tiles == gained)
        #expect(store.loadWalks()[0].teamTiles?["team"] == gained)
    }

    @Test func notMemberRefreshShowsNoticeAndDeletesTeam() async throws {
        let store = store()
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        let map = team(city())
        store.save(teams: [map])
        let server = TeamHTTPServer(map: map)
        let api = TeamsAPI(client: client(server))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.currentTeamID = "team"
        await server.removeCurrentMember()
        do { try await model.refreshTeam("team", api: api); Issue.record("Expected membership error") } catch { }
        #expect(model.teams.isEmpty)
        #expect(model.currentTeamID == nil)
        #expect(model.teamNotice?.contains(map.name) == true)
    }

    @Test func listReplyStartedBeforeJoinCannotRemoveItAndLeftTeamCannotReappear() async throws {
        let store = store()
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        let shared = city()
        var map = team(shared)
        map.replayedPlaces = ["place"]
        store.save(teams: [map])
        let server = TeamHTTPServer(map: map)
        let client = client(server)
        let api = TeamsAPI(client: client)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await server.pauseReply("teams:myTeams")
        let sync = Task { await engine.sync() }
        for _ in 0..<200 { if await server.replyHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await server.replyHeld)
        model.joinedTeam("newly-joined")
        model.currentTeamID = "newly-joined"
        await server.releaseReply()
        await sync.value
        #expect(model.teams.contains { $0.id == "newly-joined" })
        #expect(model.currentTeamID == "newly-joined")
        await server.pauseReply("teams:teamSnapshot")
        let refresh = Task { try await model.refreshTeam("team", api: api) }
        for _ in 0..<200 { if await server.replyHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await server.replyHeld)
        model.retainTeams(["newly-joined"])
        await server.releaseReply()
        do { try await refresh.value; Issue.record("Expected stale refresh cancellation") } catch is CancellationError { }
        #expect(!model.teams.contains { $0.id == "team" })
    }
}

private actor TeamHTTPServer {
    var map: TeamMap
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
    var snapshotCalls = 0
    var removed = false
    func removeCurrentMember() { removed = true }
    var routeDownloads = 0
    var remoteTrails: [TeamTrail]?
    var failedRoutes: Set<String> = []
    var pausePath: String?
    var replyHeld = false
    var heldReply: CheckedContinuation<Void, Never>?
    func pauseReply(_ path: String) { pausePath = path }
    func releaseReply() { heldReply?.resume(); heldReply = nil; replyHeld = false }
    func setRemoteTrails(_ trails: [TeamTrail], failures: Set<String> = []) { remoteTrails = trails; failedRoutes = failures }
    func configurePaging(fail: Bool) { paging = true; failPage = fail; trailSharing = false }
    func configureRace() { racing = true }

    init(map: TeamMap) { self.map = map }
    func disableTrails() { trailSharing = false }

    func respond(_ request: URLRequest) async throws -> Data {
        if request.url?.path == "/upload" {
            uploadCalls += 1
            routeFile = Self.body(request)
            return Data(#"{"storageId":"team-route-file"}"#.utf8)
        }
        if let path = request.url?.path, path.hasPrefix("/route") {
            routeDownloads += 1
            let id = path.components(separatedBy: "/").last ?? ""
            if failedRoutes.contains(id) { throw ConvexError.badResponse(404) }
            if let trail = remoteTrails?.first(where: { $0.walkClientId == id }) { return try JSONEncoder().encode(trail.route) }
            return routeFile ?? Data("{}".utf8)
        }
        if request.url?.path == "/place" { return try JSONEncoder().encode(map.places[0].city) }
        if request.url?.path == "/api/interpreter" { return Data(#"{"elements":[]}"#.utf8) }
        let call = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
        let path = call["path"] as! String, args = call["args"] as! [String: Any]
        var value: Any = NSNull()
        switch path {
        case "sync:snapshot": value = ["walks": [], "places": [], "secrets": []]
        case "teams:uploadFile":
            #expect(request.url?.path == "/api/action")
            uploadCalls += 1
            routeFile = Data((args["json"] as! String).utf8)
            value = "team-route-file"
        case "teams:createTeam":
            #expect(request.url?.path == "/api/action")
            value = ["teamId": "team", "inviteCode": "ABCD2345"]
        case "teams:joinTeam":
            #expect(request.url?.path == "/api/action")
            value = "team"
        case "teams:newInviteCode":
            #expect(request.url?.path == "/api/action")
            value = "EFGH2345"
        case "teams:removeMember": #expect(request.url?.path == "/api/action")
        case "teams:myTeams":
            let membership = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map.members[0]))
            value = [["teamId": map.id, "name": map.name, "memberCount": 2, "membership": membership]]
        case "teams:teamSnapshot":
            if removed { return Self.failure("NOT_A_MEMBER") }
            snapshotCalls += 1
            let since = args["since"] as? Double
            if let since { sinceValues.append(since) }
            var members = map.members
            if !trailSharing { members[0].sharing = .tiles }
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(members))
            value = [
                "team": ["teamId": map.id, "name": map.name, "createdBy": map.createdBy, "inviteCode": map.inviteCode, "createdAt": 1],
                "members": encoded,
                "places": [["placeId": "place", "clientId": map.places[0].clientId, "name": "Team suburb", "updatedAt": 1, "url": NSNull()]],
                "tiles": (since ?? 0) < 101 ? Array(savedTiles.values) : [],
                "trails": trailSharing && trailCalls > 0 ? [["walkClientId": "walk", "by": "you", "at": 100, "url": "https://team.walkies.test/route"]] : [],
                "secrets": savedSecrets.map { ["secretId": $0, "by": "you", "at": 50_000] as [String: Any] },
                "serverTime": savedTiles.isEmpty ? 100 : 101,
                "more": false, "cursor": NSNull(),
            ] as [String: Any]
            if let remoteTrails {
                var page = value as! [String: Any]
                page["trails"] = remoteTrails.map { ["walkClientId": $0.walkClientId, "by": $0.by, "at": $0.at, "url": "https://team.walkies.test/route/\($0.walkClientId)"] as [String: Any] }
                value = page
            }
            if racing {
                var page = value as! [String: Any]
                page["places"] = raceWon ? [["placeId": "place", "clientId": map.places[0].clientId, "name": "Winner", "updatedAt": 1, "url": "https://team.walkies.test/place"]] : []
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
                page["team"] = ["teamId": map.id, "name": pageIndex == 2 ? "Last page" : map.name, "createdBy": map.createdBy, "inviteCode": map.inviteCode, "createdAt": 1]
                value = page
            }
        case "teams:addTeamPlace":
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
        case "teams:uploadTeamTiles":
            tileCalls += 1
            if rejectLimits { return Self.failure("TILE_LIMIT") }
            for hex in args["hexes"] as! [[Int]] {
                savedTiles["\(hex[0]),\(hex[1])"] = ["placeId": "place", "q": hex[0], "r": hex[1], "by": "you", "at": args["at"]!]
            }
            if tileCalls == 1 { return Data(#"{"status":"error","errorData":{"code":"RETRY","message":"Reply lost after commit"}}"#.utf8) }
            value = 0
        case "teams:teamForInvite": #expect(request.url?.path == "/api/mutation")
        case "teams:uploadTeamTrail":
            #expect(request.url?.path == "/api/action")
            #expect((args["updatedAt"] as? Double)?.isFinite == true)
            trailCalls += 1
            if expireTrail { expireTrail = false; return Self.failure("INVALID_UPLOAD") }
            if rejectLimits { return Self.failure("TRAIL_LIMIT") }
        case "teams:recordTeamSecrets":
            if rejectLimits { return Self.failure("SECRET_LIMIT") }
            for secret in args["secrets"] as! [[String: Any]] { savedSecrets.insert(secret["secretId"] as! String) }
        default: break
        }
        let data = try JSONSerialization.data(withJSONObject: ["status": "success", "value": value])
        if pausePath == path {
            pausePath = nil
            replyHeld = true
            await withCheckedContinuation { heldReply = $0 }
        }
        return data
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

private nonisolated final class TeamHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: TeamHTTPServer?
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
