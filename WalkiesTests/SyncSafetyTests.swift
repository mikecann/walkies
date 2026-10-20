import Foundation
import Testing
@testable import Walkies

/// Sync must never lose places or walks: not from a file that won't load, a bad
/// download, a sign-out mid-sync or someone else signing in on the same phone.
@MainActor
@Suite(.serialized)
struct SyncSafetyTests {
    func root() -> URL {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesSyncSafetyTests")
        return base.appending(path: UUID().uuidString)
    }

    func city(_ name: String = "Test place") -> City {
        let grid = HexGrid.world
        let origin = Coordinate(lat: 12.345, lon: 45.678)
        let base = grid.hex(containing: origin)
        let ring = [SIMD2(-1000.0, -1000), SIMD2(1000.0, -1000), SIMD2(1000.0, 1000), SIMD2(-1000.0, 1000)]
            .map { grid.projection.unproject(grid.centre(of: base) + $0) }
        return City(name: name, detail: "Tests",
                    boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]),
                    tiles: Set((0..<20).map { Hex(q: base.q + Int32($0), r: base.r) }),
                    visited: [base], roads: [])
    }

    func walk(_ n: Int, in city: City) -> Walk {
        let date = Date.now.addingTimeInterval(-Double(n + 1) * 86400)
        let centre = city.grid.centre(of: city.grid.hex(containing: city.boundary.centre))
        let points = [0.0, 15.0, 30.0].enumerated().map { index, x in
            let c = city.grid.projection.unproject(centre + SIMD2(x, 0))
            return TrackPoint(lat: c.lat, lon: c.lon, time: date.timeIntervalSince1970 + Double(index) * 20, accuracy: 5, speed: 1)
        }
        return Walk(startedAt: date, endedAt: date.addingTimeInterval(600), points: points, distance: 300, newTiles: 1)
    }

    func client(_ server: SafetyServer) -> ConvexClient {
        SafetyProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafetyProtocol.self]
        return ConvexClient(token: nil, session: URLSession(configuration: configuration))
    }

    @Test func corruptCitiesFileNeverDeletesFromTheAccount() async throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let place = city()
        store.save([place])
        let server = SafetyServer()
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(await server.places.count == 1)

        store.flush()
        try Data("not json".utf8).write(to: root.appending(path: "cities.json"))
        let relaunched = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        #expect(relaunched.cities.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(files.contains { $0.hasPrefix("cities.corrupt-") })
        let again = SyncEngine(model: relaunched, store: store, isSignedIn: { true }, makeClient: { client })
        await again.sync()
        #expect(again.status == .idle)
        #expect(!(await server.calls).contains("sync:deletePlace"))
        #expect(await server.places.count == 1)
        // Pull brings it back.
        #expect(relaunched.cities.map(\.id) == [place.id])
        #expect(store.loadCities().map(\.id) == [place.id])
    }

    @Test func deletedPlacesArePushedOnceAndNotPulledBack() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let keep = city("Keep"), gone = city("Gone")
        store.save([keep, gone])
        let server = SafetyServer()
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(await server.places.count == 2)

        model.deleteCities(at: IndexSet(integer: 1))
        #expect(store.loadSyncState().deletedPlaces == [gone.id])
        #expect(engine.waiting == 1)
        // Survives a relaunch before there's signal.
        let relaunched = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await relaunched.sync()
        #expect(relaunched.status == .idle)
        #expect(await server.deleted == [gone.id.uuidString])
        #expect(await server.places.keys.sorted() == [keep.id.uuidString])
        #expect(store.loadSyncState().deletedPlaces?.isEmpty != false)
        #expect(model.cities.map(\.id) == [keep.id])
        await relaunched.sync()
        #expect(await server.deleted.count == 1)
    }

    @Test func oneBadDownloadDoesNotHoldBackTheRest() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let place = city()
        let walks = (0..<3).map { walk($0, in: place) }
        let server = SafetyServer()
        await server.seed(place)
        for walk in walks { await server.seed(walk) }
        await server.fail(walks[0].id)
        await server.garble(walks[1].id)
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        guard case .failed = engine.status else { Issue.record("Expected the failed download to show"); return }
        #expect(model.cities.map(\.id) == [place.id])
        #expect(model.walks.map(\.id) == [walks[2].id])
        #expect(store.loadSyncState().uploadedWalks == [walks[2].id])

        // The failed one comes next time; the unreadable one is skipped without failing the sync.
        await server.fail(nil)
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(Set(model.walks.map(\.id)) == [walks[0].id, walks[2].id])
    }

    @Test func signingOutDuringAPullLeavesNothingBehind() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let place = city()
        let server = SafetyServer()
        await server.seed(place)
        for n in 0..<3 { await server.seed(walk(n, in: place)) }
        await server.pauseDownloads()
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        var signedIn = true
        let engine = SyncEngine(model: model, store: store, isSignedIn: { signedIn }, makeClient: { client })
        let syncing = Task { await engine.sync() }
        await server.waitForDownload()
        let wiping = Task { await engine.wipe() }
        await server.resumeDownloads()
        await wiping.value
        signedIn = false
        await syncing.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.cities.isEmpty)
        #expect(model.walks.isEmpty)
        #expect(store.loadCities().isEmpty)
        #expect(store.loadWalks().isEmpty)
        #expect(store.loadSyncState().uploadedPlaces.isEmpty)
        #expect(engine.status == .idle)
    }

    @Test func someoneElseSigningInStartsFromTheirOwnAccount() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let place = city()
        store.save([place])
        store.save(walk(0, in: place))
        let server = SafetyServer()
        let client = client(server)

        // Data from before owners were recorded belongs to whoever syncs it first.
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let alice = SyncEngine(model: model, store: store, isSignedIn: { true }, userId: { "alice" }, makeClient: { client })
        await alice.sync()
        #expect(store.loadOwner() == "alice")
        #expect(model.cities.count == 1)

        let relaunched = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let bobServer = SafetyServer()
        let bobClient = self.client(bobServer)
        let bob = SyncEngine(model: relaunched, store: store, isSignedIn: { true }, userId: { "bob" }, makeClient: { bobClient })
        await bob.sync()
        #expect(bob.status == .idle)
        #expect(relaunched.cities.isEmpty)
        #expect(relaunched.walks.isEmpty)
        #expect(store.loadCities().isEmpty)
        #expect(store.loadWalks().isEmpty)
        #expect(store.loadOwner() == "bob")
        #expect(!(await bobServer.calls).contains("sync:savePlace"))
        #expect(!(await bobServer.calls).contains("sync:saveWalk"))
    }
}

actor SafetyServer {
    private(set) var calls: [String] = []
    private(set) var places: [String: (updatedAt: Double, file: String)] = [:]
    private(set) var walks: [String: String] = [:]
    private(set) var deleted: [String] = []
    private var files: [String: Data] = [:]
    private var failing: String?
    private var garbled: Set<String> = []
    private var paused = false
    private var downloadStarted = false
    private var downloadWaiter: CheckedContinuation<Void, Never>?
    private var resumers: [CheckedContinuation<Void, Never>] = []

    func seed(_ city: City) {
        files[city.id.uuidString] = try! JSONEncoder().encode(city)
        places[city.id.uuidString] = (city.lastChanged.ms, city.id.uuidString)
    }

    func seed(_ walk: Walk) {
        files[walk.id.uuidString] = try! JSONEncoder().encode(walk)
        walks[walk.id.uuidString] = walk.id.uuidString
    }

    func fail(_ id: UUID?) { failing = id?.uuidString }
    func garble(_ id: UUID) { garbled.insert(id.uuidString) }
    func pauseDownloads() { paused = true }
    func waitForDownload() async {
        if !downloadStarted { await withCheckedContinuation { downloadWaiter = $0 } }
    }
    func resumeDownloads() {
        paused = false
        for resumer in resumers { resumer.resume() }
        resumers = []
    }

    func respond(_ request: URLRequest) async throws -> (Int, Data) {
        let url = request.url!
        let body = Self.body(request)
        if url.host == "files.walkies.test" {
            downloadStarted = true
            downloadWaiter?.resume()
            downloadWaiter = nil
            if paused { await withCheckedContinuation { resumers.append($0) } }
            let file = url.lastPathComponent
            if file == failing { return (500, Data()) }
            if garbled.contains(file) { return (200, Data("{\"nope\":".utf8)) }
            return (200, files[file]!)
        }
        if url.path == "/upload" {
            let id = UUID().uuidString
            files[id] = body
            return (200, Data(#"{"storageId":"\#(id)"}"#.utf8))
        }
        let call = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let path = call["path"] as! String
        let args = call["args"] as! [String: Any]
        calls.append(path)
        var value: Any = NSNull()
        switch path {
        case "teams:myTeams": value = [] as [String]
        case "sync:generateUploadUrl": value = "https://sync.walkies.test/upload"
        case "sync:savePlace": places[args["clientId"] as! String] = (args["updatedAt"] as! Double, args["file"] as! String)
        case "sync:saveWalk": walks[args["clientId"] as! String] = args["file"] as? String
        case "sync:deletePlace":
            let id = args["clientId"] as! String
            deleted.append(id)
            places[id] = nil
        case "sync:snapshot":
            value = [
                "places": places.map { ["clientId": $0.key, "updatedAt": $0.value.updatedAt, "url": "https://files.walkies.test/\($0.value.file)"] },
                "walks": walks.map { ["clientId": $0.key, "url": "https://files.walkies.test/\($0.value)"] },
                "secrets": [] as [String],
            ] as [String: Any]
        default: break
        }
        return (200, try JSONSerialization.data(withJSONObject: ["status": "success", "value": value]))
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
}

private nonisolated final class SafetyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: SafetyServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let server = Self.server!
        Task {
            do {
                let (status, data) = try await server.respond(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
