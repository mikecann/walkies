import Foundation
import Testing
@testable import Walkies

extension SyncSafetyTests {
    @Test(arguments: [true, false])
    func lockedLaunchResumesTheSavedUUIDAndUploadsTheCompletedRoute(probeReadable: Bool) async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let ride = AlwaysOnRideTests()
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let start = clock.timeIntervalSince1970 - 700
        let points = (0...8).map { ride.fix(east: Double($0) * 50, at: start + Double($0) * 40) }
        let checkpoint = Walk(startedAt: Date(timeIntervalSince1970: start), points: points,
                              distance: CoverageTracer.distance(for: points), automatic: true)
        store.save(checkpoint)
        let readable = FirstUnlock.happened(protectedDataAvailable: false, readProbe: { probeReadable }, makeProbe: { false })
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, waitForUnlock: !readable, now: { clock })
        let previousCounting = model.countSteps
        model.countSteps = false
        defer { model.countSteps = previousCounting }
        let server = SafetyServer()
        let client = client(server)
        let delay = SyncDelay()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client }, sleep: delay.sleep)
        var observer: (() -> Void)?
        var available = false
        var ordering: [String] = []
        let startup = AppStartup(savedDataReadable: { readable || available }, openFence: { ordering.append("fence") },
                                 observeUnlock: { observer = $0; return { observer = nil } },
                                 loadSaved: {
            ordering.append("load")
            // The real account/model load is synchronous on the main actor. Limit
            // the preference override to that call, so other fixtures cannot see it.
            let prior = UserDefaults.standard.object(forKey: "alwaysOn")
            UserDefaults.standard.set(true, forKey: "alwaysOn")
            model.loadSaved()
            if let prior { UserDefaults.standard.set(prior, forKey: "alwaysOn") }
            else { UserDefaults.standard.removeObject(forKey: "alwaysOn") }
            engine.reload()
        }, start: {
            ordering.append("start")
            model.resumeAlwaysOn()
            engine.schedule()
        })
        startup.launch()
        startup.launch()
        if !probeReadable {
            #expect(model.activeWalk == nil)
            #expect(ordering == ["fence"])
            available = true
            let notify = observer
            notify?()
            notify?()
        }
        #expect(startup.state == .running)
        #expect(ordering == (probeReadable ? ["fence", "start"] : ["fence", "load", "start"]))
        await model.waitForHistory()
        #expect(model.activeWalk?.id == checkpoint.id)
        for i in 1...4 {
            model.recordAlwaysOnForTesting(ride.fix(east: 400 + Double(i) * 50, at: points.last!.time + 140 + Double(i) * 40))
        }
        model.saveNow(waiting: true)
        let resumed = try #require(store.loadWalks().first)
        #expect(resumed.id == checkpoint.id)
        #expect(resumed.points.count == 13)
        #expect(resumed.endedAt == nil)
        #expect(resumed.distance > checkpoint.distance + 190)
        model.endAutoWalk()
        let finished = try #require(model.walks.first)
        #expect(finished.id == checkpoint.id)
        #expect(finished.startedAt == checkpoint.startedAt)
        #expect(finished.points == resumed.points)
        #expect(finished.endedAt != nil)
        await delay.waitForRequests(1)
        delay.advance()
        await engine.waitForScheduledSync()
        #expect(engine.status == .idle)
        let uploaded = try #require(try await server.uploadedWalk(checkpoint.id))
        #expect(uploaded.startedAt == checkpoint.startedAt)
        #expect(uploaded.endedAt == finished.endedAt)
        #expect(uploaded.points == resumed.points)
        #expect(store.loadSyncState().uploadedWalks == [checkpoint.id])
    }

    @Test func aRideThenRelaunchUploadsTwoOutingsWithSeparateIDsAndRoutes() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let ride = AlwaysOnRideTests()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let before = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { clock })
        let previousCounting = before.countSteps
        before.countSteps = false
        defer { before.countSteps = previousCounting }
        await before.waitForHistory()
        let first = try ride.startWalk(before, at: clock.timeIntervalSince1970 - 320)
        let last = try #require(first.points.last)
        clock = Date(timeIntervalSince1970: last.time + 20)
        before.recordAlwaysOnForTesting(ride.fix(east: 450, at: clock.timeIntervalSince1970, wheels: true))
        before.saveNow(waiting: true)
        let resumed = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { clock })
        resumed.countSteps = false
        await resumed.waitForHistory()
        let arrival = ride.fix(east: 900, at: last.time + 400)
        for i in 0...8 {
            clock = Date(timeIntervalSince1970: arrival.time + Double(i) * 40)
            resumed.recordAlwaysOnForTesting(ride.fix(east: 900 + Double(i) * 50, at: clock.timeIntervalSince1970))
        }
        let next = try #require(resumed.activeWalk)
        #expect(next.id != first.id)
        #expect(next.startedAt == Date(timeIntervalSince1970: arrival.time))
        #expect(next.points.first == arrival)
        resumed.endAutoWalk()
        #expect(resumed.walks.count == 2)
        let firstSaved = try #require(resumed.walks.first { $0.id == first.id })
        #expect(firstSaved.endedAt == Date(timeIntervalSince1970: last.time))
        #expect(firstSaved.points == first.points)
        #expect(store.loadWalks().count == 2)
        let server = SafetyServer()
        let client = client(server)
        let engine = SyncEngine(model: resumed, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(await server.walks.count == 2)
        #expect(try await server.uploadedWalk(first.id)?.points == first.points)
        #expect(try await server.uploadedWalk(next.id)?.points == next.points)
        #expect(store.loadSyncState().uploadedWalks == [first.id, next.id])
        #expect(engine.waiting == 0)
    }

    @Test(arguments: SafetyServer.PushFault.allCases)
    func interruptedUploadRetriesTheSameWalkAfterProcessRecreation(phase: SafetyServer.PushFault) async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let saved = walk(0, in: city())
        store.save(saved)
        let server = SafetyServer()
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await server.failNextPush(phase)
        await engine.sync()
        guard case .failed = engine.status else { Issue.record("Expected failure at \(phase)"); return }
        #expect(!store.loadSyncState().uploadedWalks.contains(saved.id))
        #expect(store.loadWalks().contains { $0.id == saved.id && $0.endedAt == saved.endedAt })
        #expect(await server.walks.count == (phase == .acknowledgement ? 1 : 0))

        let relaunched = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let again = SyncEngine(model: relaunched, store: store, isSignedIn: { true }, makeClient: { client })
        await again.sync()
        #expect(again.status == .idle)
        #expect(await server.walks.keys.sorted() == [saved.id.uuidString])
        let uploaded = try #require(try await server.uploadedWalk(saved.id))
        #expect(uploaded.startedAt == saved.startedAt)
        #expect(uploaded.endedAt == saved.endedAt)
        #expect(uploaded.points == saved.points)
        #expect(store.loadSyncState().uploadedWalks.contains(saved.id))
        #expect(again.waiting == 0)
    }

    @Test func aFailedLocalUploadMarkerRetriesWithoutDuplicatingTheServerWalk() async throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let saved = walk(0, in: city())
        store.save(saved)
        // The server can commit successfully while sync.json cannot be replaced.
        let marker = root.appending(path: "sync.json")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        let server = SafetyServer()
        let client = client(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(await server.walks.count == 1)
        #expect(store.loadSyncState().uploadedWalks.isEmpty)
        #expect(store.loadWalks().contains { $0.id == saved.id })
        try FileManager.default.removeItem(at: marker)

        let relaunched = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let again = SyncEngine(model: relaunched, store: store, isSignedIn: { true }, makeClient: { client })
        await again.sync()
        #expect(again.status == .idle)
        #expect(await server.walks.keys.sorted() == [saved.id.uuidString])
        #expect(await server.calls.filter { $0 == "sync:saveWalk" }.count == 2)
        #expect(store.loadSyncState().uploadedWalks == [saved.id])
        #expect(again.waiting == 0)
    }

    @Test func recoveredWalkWaitsForHistoryAndStepsBeforeReachingTheServer() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        var interrupted = walk(0, in: city())
        interrupted.endedAt = nil
        interrupted.steps = nil
        store.save(interrupted)
        let reply = StepReply()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false, stepQuery: reply.count)
        let previous = model.countSteps
        model.countSteps = true
        defer { model.countSteps = previous }
        let server = SafetyServer()
        let client = client(server)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        let syncing = Task { await engine.sync() }
        await reply.waitForRequest()
        #expect(await server.walks.isEmpty)
        #expect(store.loadWalks().first?.endedAt == nil)
        #expect(store.loadSyncState().uploadedWalks.isEmpty)
        reply.finish(432)
        await syncing.value
        let end = Date(timeIntervalSince1970: interrupted.points.last!.time)
        let uploaded = try #require(try await server.uploadedWalk(interrupted.id))
        #expect(uploaded.startedAt == interrupted.startedAt)
        #expect(uploaded.endedAt == end)
        #expect(uploaded.steps == 432)
        #expect(uploaded.points == interrupted.points)
        #expect(store.loadWalks().first?.steps == 432)
        #expect(store.loadSyncState().uploadedWalks == [interrupted.id])
    }

    @Test func aBackgroundFailureRetriesWhenTheNextForegroundRequestHasASession() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let saved = walk(0, in: city())
        store.save(saved)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let server = SafetyServer()
        let client = client(server)
        let delay = SyncDelay()
        var available = false
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true },
                                makeClient: { available ? client : nil }, sleep: delay.sleep)
        // Same delayed trigger as AppDelegate's background launch.
        engine.schedule()
        await delay.waitForRequests(1)
        #expect(await server.calls.isEmpty)
        delay.advance()
        await engine.waitForScheduledSync()
        #expect(engine.status == .failed("Offline"))
        #expect(store.loadSyncState().uploadedWalks.isEmpty)

        available = true
        // Same delayed trigger as ContentView's next active scene change.
        engine.schedule()
        await delay.waitForRequests(2)
        delay.advance()
        await engine.waitForScheduledSync()
        #expect(engine.status == .idle)
        #expect(await server.walks.keys.sorted() == [saved.id.uuidString])
        #expect(store.loadSyncState().uploadedWalks == [saved.id])
        #expect(delay.durations == [.seconds(2), .seconds(2)])
    }

    @Test func repeatedSyncRequestsCoalesceAndResetCancelsThePendingTimer() async throws {
        let store = Store(root: root())
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let server = SafetyServer()
        let client = client(server)
        let delay = SyncDelay()
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client }, sleep: delay.sleep)
        for n in 1...3 {
            engine.schedule()
            await delay.waitForRequests(n)
        }
        delay.advance()
        await engine.waitForScheduledSync()
        #expect(await server.calls.filter { $0 == "sync:snapshot" }.count == 1)
        #expect(engine.status == .idle)
        engine.schedule()
        await delay.waitForRequests(4)
        engine.reset()
        delay.advance()
        await engine.waitForScheduledSync()
        #expect(await server.calls.filter { $0 == "sync:snapshot" }.count == 1)
    }
}

@MainActor
private final class StepReply {
    private var continuation: CheckedContinuation<Int?, Never>?
    func count(_ start: Date, _ end: Date) async -> Int? {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForRequest() async {
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        #expect(continuation != nil)
    }
    func finish(_ count: Int?) { continuation?.resume(returning: count); continuation = nil }
}

@MainActor
private final class SyncDelay {
    private(set) var durations: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []
    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<1000 where durations.count < count { await Task.yield() }
        #expect(durations.count == count)
    }
    func advance() {
        let ready = continuations
        continuations = []
        for continuation in ready { continuation.resume() }
    }
}
