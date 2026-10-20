import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct TeamTests {
    private func team() -> Team {
        Team(id: "team", name: "Mike & Dad", createdBy: "you", inviteCode: "ABCD2345", members: [
            TeamMember(userId: "you", name: "Mike", colour: "teal", joinedAt: 1, isYou: true),
            TeamMember(userId: "dad", name: "Dad", colour: "blue", joinedAt: 2, isYou: false, picture: "https://example.com/dad.jpg"),
        ])
    }

    private func store() -> Store { Store(root: URL.temporaryDirectory.appending(path: "TeamTests-\(UUID())")) }

    private func client(_ server: TeamHTTPServer) -> ConvexClient {
        TeamHTTPProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHTTPProtocol.self]
        return ConvexClient(token: "test-token", session: URLSession(configuration: configuration))
    }

    @Test func membershipRoundTripsInOneFile() throws {
        let root = URL.temporaryDirectory.appending(path: "TeamStore-\(UUID())")
        let store = Store(root: root)
        defer { store.wipe() }
        store.save(teams: [team()])
        let restored = try #require(store.loadTeams().first)
        #expect(restored.members.map(\.name) == ["Mike", "Dad"])
        #expect(restored.members[1].picture == "https://example.com/dad.jpg")
        #expect(restored.you?.userId == "you")
        #expect(restored.inviteURL.path == "/join/ABCD2345")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent).sorted() == ["teams.json", "walks"])
        store.save(teams: [])
        #expect(store.loadTeams().isEmpty)
    }

    @Test func inviteCodesAndDeepLinks() {
        #expect(TeamInviteCode.normalise(" abcd2345 \n") == "ABCD2345")
        #expect(TeamInviteCode.isValid("ABCD2345"))
        for invalid in ["ABC", "ABCD2340", "ABCD2341", "abcd2345", "ABCD234I"] {
            #expect(!TeamInviteCode.isValid(invalid))
        }
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        model.openTeamURL(URL(string: "walkies://join/abcd2345")!)
        #expect(model.pendingTeamInvite == "ABCD2345")
        model.pendingTeamInvite = nil
        for invalid in ["https://join/ABCD2345", "walkies://other/ABCD2345", "walkies://join/ABCD2345/extra", "walkies://join/bad"] {
            model.openTeamURL(URL(string: invalid)!)
            #expect(model.pendingTeamInvite == nil)
        }
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

    @Test func membershipEditsDoNotChangePersonalExploration() async {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let grid = HexGrid(projection: LocalProjection(origin: Coordinate(lat: -33.6, lon: 115.4)), size: 50)
        let ring = [SIMD2(-200.0, -200), SIMD2(200.0, -200), SIMD2(200.0, 200), SIMD2(-200.0, 200)].map(grid.projection.unproject)
        let boundary = Boundary(polygons: [GeoPolygon(outer: ring, holes: [])])
        let city = City(name: "Home", detail: "Tests", grid: grid, boundary: boundary, tiles: [Hex(q: 0, r: 0)], visited: [], roads: [])
        model.add(city)
        let key = model.cloudKey
        let secrets = model.foundStickers
        let balance = model.ledger
        #expect(model.acceptTeamList([team()], revision: model.teamMembershipRevision))
        model.editTeam("team") { $0.members[1].colour = "rose" }
        #expect(model.selectedCityID == city.id)
        #expect(model.cities[0].visited.isEmpty)
        #expect(model.cloudKey == key)
        #expect(model.foundStickers == secrets)
        #expect(model.ledger == balance)
        model.retainTeams([])
        #expect(model.selectedCityID == city.id)
        #expect(model.cloudKey == key)
    }

    @Test func oldListsCannotUndoJoinLeaveOrColourEdits() {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let revision = model.teamMembershipRevision
        model.joinedTeam("team")
        #expect(!model.acceptTeamList([], revision: revision))
        #expect(model.acceptTeamList([team()], revision: model.teamMembershipRevision))
        let beforeEdit = model.teamMembershipRevision
        model.editTeam("team") { $0.members[0].colour = "rose" }
        #expect(!model.acceptTeamList([team()], revision: beforeEdit))
        #expect(model.teams[0].you?.colour == "rose")
        let beforeLeave = model.teamMembershipRevision
        model.retainTeams([])
        #expect(!model.acceptTeamList([team()], revision: beforeLeave))
        #expect(model.teams.isEmpty)
    }

    @Test func APIUsesMembershipEndpointsAndDecodesMemberPhotos() async throws {
        let server = TeamHTTPServer(teams: [team()])
        let api = TeamsAPI(client: client(server))
        defer { TeamHTTPProtocol.server = nil }
        let preview = try await api.preview("ABCD2345")
        #expect(preview?.name == "Mike & Dad")
        let created = try await api.create(name: "Family", colour: "teal", memberName: "Mike")
        #expect(created.teamId == "team")
        let joined = try await api.join(code: "ABCD2345", colour: "blue", name: "Dad")
        #expect(joined == "team")
        let teams = try await api.list()
        #expect(teams[0].members[1].picture == "https://example.com/dad.jpg")
        try await api.update(.init(teamId: "team", colour: "rose", name: "Mike"))
        try await api.rename("team", name: "Family")
        try await api.remove("team", userId: "dad")
        #expect(try await api.newInviteCode("team") == "EFGH2345")
        try await api.leave("team")
        #expect(await server.calls == ["teams:teamForInvite", "teams:createTeam", "teams:joinTeam", "teams:myTeams", "teams:updateMembership", "teams:renameTeam", "teams:removeMember", "teams:newInviteCode", "teams:leaveTeam"])
    }

    @Test func syncRefreshesMembershipAndRemovalNoticeWithoutUploads() async {
        let store = store()
        store.save(teams: [team()])
        let server = TeamHTTPServer(teams: [team()])
        let client = client(server)
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let sync = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await sync.sync()
        #expect(sync.status == .idle)
        #expect(model.teams[0].members[1].picture != nil)
        #expect(sync.waiting == 0)
        await server.setTeams([])
        await sync.sync()
        #expect(sync.status == .idle)
        #expect(model.teams.isEmpty)
        #expect(store.loadTeams().isEmpty)
        #expect(model.teamNotice?.contains("Mike & Dad") == true)
        #expect(await server.calls.filter { $0.hasPrefix("teams:") } == ["teams:myTeams", "teams:myTeams"])
    }

    @Test func inFlightRefreshCannotResurrectLeftTeam() async throws {
        let store = store()
        store.save(teams: [team()])
        let server = TeamHTTPServer(teams: [team()])
        let api = TeamsAPI(client: client(server))
        defer { store.wipe(); TeamHTTPProtocol.server = nil }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await server.pauseNextList()
        let refresh = Task { try await model.refreshTeam("team", api: api) }
        await server.waitForList()
        model.retainTeams([])
        await server.releaseList()
        do { try await refresh.value; Issue.record("Expected stale refresh to be cancelled") }
        catch is CancellationError {} catch { throw error }
        #expect(model.teams.isEmpty)
        #expect(store.loadTeams().isEmpty)
    }
}

private actor TeamHTTPServer {
    var teams: [Team]
    private(set) var calls: [String] = []
    private var pauseList = false
    private var pendingList: CheckedContinuation<Void, Never>?

    init(teams: [Team]) { self.teams = teams }
    func setTeams(_ teams: [Team]) { self.teams = teams }
    func pauseNextList() { pauseList = true }
    func waitForList() async { while pendingList == nil { await Task.yield() } }
    func releaseList() { pendingList?.resume(); pendingList = nil }

    func respond(_ request: URLRequest) async throws -> Data {
        let call = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
        let path = call["path"] as! String
        let args = call["args"] as! [String: Any]
        calls.append(path)
        var value: Any = NSNull()
        switch path {
        case "teams:myTeams":
            #expect(request.url?.path == "/api/query")
            value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(teams))
        case "teams:teamForInvite":
            #expect(request.url?.path == "/api/mutation")
            value = ["name": "Mike & Dad", "memberNames": []] as [String: Any]
        case "teams:createTeam":
            #expect(request.url?.path == "/api/action")
            #expect(args["memberName"] as? String == "Mike")
            #expect(Set(args.keys) == ["name", "colour", "memberName"])
            value = ["teamId": "team", "inviteCode": "ABCD2345"]
        case "teams:joinTeam":
            #expect(request.url?.path == "/api/action")
            #expect(Set(args.keys) == ["code", "colour", "name"])
            value = "team"
        case "teams:newInviteCode":
            #expect(request.url?.path == "/api/action")
            value = "EFGH2345"
        case "teams:removeMember": #expect(request.url?.path == "/api/action")
        case "teams:updateMembership", "teams:renameTeam", "teams:leaveTeam":
            #expect(request.url?.path == "/api/mutation")
        case "sync:snapshot": value = ["walks": [], "places": [], "secrets": []] as [String: Any]
        case "sync:saveProgress": break
        default: Issue.record("Unexpected endpoint \(path)")
        }
        // Freeze the reply before yielding so the race test returns an old list.
        let data = try JSONSerialization.data(withJSONObject: ["status": "success", "value": value])
        if path == "teams:myTeams", pauseList {
            pauseList = false
            await withCheckedContinuation { pendingList = $0 }
        }
        return data
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
