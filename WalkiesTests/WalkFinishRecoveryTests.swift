import Foundation
import Testing
@testable import Walkies

extension SyncSafetyTests {
    @Test(arguments: [120.0, 601.0])
    func anExplicitShortEndSurvivesDeathWhileItsFinalStepsArePending(relaunchAge: Double) async throws {
        let originalRoot = root()
        let original = Store(root: originalRoot)
        defer { original.wipe() }
        let clock = FinishRecoveryClock(0)
        let gate = FinishStepGate()
        let place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        original.save([place])
        let model = AppModel(store: original, servicesEnabled: false, alwaysOn: true,
                             stepQuery: gate.count, now: clock.now)
        let previousCounting = model.countSteps
        model.countSteps = true
        defer { model.countSteps = previousCounting; gate.reply(111) }
        await model.waitForHistory()
        for i in 0...2 {
            clock.elapsed = Double(i) * 40
            model.recordAlwaysOnForTesting(finishFix(Double(i) * 50, clock.elapsed))
        }
        let outing = try #require(model.activeWalk)
        #expect(model.autoWalkPending)
        clock.elapsed = 100
        let requestedEnd = clock.now()
        model.endAutoWalk()
        await gate.waitForRequest()
        let pending = try #require(original.loadWalks().first { $0.id == outing.id })
        #expect(pending.endedAt == nil)
        #expect(try finishMetadata(pending) != nil)
        #expect(model.walks.allSatisfy { $0.id != outing.id })

        // The old process's callbacks must only touch its old files. Copy the durable
        // checkpoint into a new root before letting the held response return.
        let recovered = try forkWalkFiles(from: originalRoot, into: root())
        defer { recovered.wipe() }
        gate.reply(111)
        await waitForAutomaticFinish(model, id: outing.id)
        let nextClock = FinishRecoveryClock(80 + relaunchAge)
        let relaunched = AppModel(store: recovered, servicesEnabled: false, alwaysOn: true,
                                  stepQuery: { from, to in
            #expect(from == outing.startedAt)
            #expect(to == requestedEnd)
            return 222
        }, now: nextClock.now)
        relaunched.countSteps = true
        await relaunched.waitForHistory()
        #expect(relaunched.activeWalk == nil)
        let finished = relaunched.walks.first { $0.id == outing.id }
        #expect(finished?.startedAt == outing.startedAt)
        #expect(finished?.endedAt == requestedEnd)
        #expect(finished?.endReason == .you)
        #expect(finished?.points == outing.points)
        #expect(finished?.steps == 222)
        #expect((finished?.newTiles ?? 0) > 0)
        #expect(finished?.newTileHexesByPlace?[place.id.uuidString]?.isEmpty == false)
        #expect(relaunched.questTileCounts[outing.id]?[place.id] == finished?.newTilesByPlace?[place.id.uuidString])
        #expect(relaunched.freshTiles.isEmpty)
        #expect(recovered.loadWalks().first { $0.id == outing.id }?.endedAt == requestedEnd)
        if let finished { #expect(try finishMetadata(finished) == nil) }

        let server = SafetyServer()
        let client = client(server)
        let sync = SyncEngine(model: relaunched, store: recovered, isSignedIn: { true }, makeClient: { client })
        await sync.sync()
        #expect(sync.status == .idle)
        #expect(try await server.uploadedWalk(outing.id)?.endedAt == requestedEnd)
        #expect(try await server.uploadedWalk(outing.id)?.points == outing.points)

        nextClock.elapsed += 10
        relaunched.recordAlwaysOnForTesting(finishFix(500, nextClock.elapsed))
        nextClock.elapsed += 40
        relaunched.recordAlwaysOnForTesting(finishFix(550, nextClock.elapsed))
        #expect(relaunched.activeWalk?.id != outing.id)
        #expect(relaunched.walks.first { $0.id == outing.id }?.points == outing.points)
    }

    @Test(arguments: [false, true], [false, true])
    func aRideSuccessorSurvivesDeathBeforeOrImmediatelyAfterTheFinalStepReply(afterReply: Bool, followingWhilePending: Bool) async throws {
        let originalRoot = root()
        let original = Store(root: originalRoot)
        defer { original.wipe() }
        let clock = FinishRecoveryClock(0)
        let gate = FinishStepGate()
        let model = AppModel(store: original, servicesEnabled: false, alwaysOn: true,
                             stepQuery: gate.count, now: clock.now)
        let previousCounting = model.countSteps
        model.countSteps = true
        defer { model.countSteps = previousCounting; gate.reply(111) }
        await model.waitForHistory()
        let first = try seedFinishWalk(model, clock: clock)
        clock.elapsed = 340
        model.recordAlwaysOnForTesting(finishFix(450, 340, wheels: true))
        clock.elapsed = 720
        let arrival = finishFix(900, 720)
        model.recordAlwaysOnForTesting(arrival)
        clock.elapsed = 760
        let confirmation = finishFix(950, 760)
        model.recordAlwaysOnForTesting(confirmation)
        await gate.waitForRequest()
        let pending = try #require(original.loadWalks().first { $0.id == first.id })
        #expect(pending.endedAt == nil)
        let successorID = try finishSuccessorID(pending)
        #expect(successorID != nil)
        var successorPoints = [arrival, confirmation]
        if followingWhilePending {
            for i in 0...1 {
                clock.elapsed = 800 + Double(i) * 40
                let point = finishFix(1000 + Double(i) * 50, clock.elapsed)
                model.recordAlwaysOnForTesting(point)
                successorPoints.append(point)
            }
            #expect(model.activeWalk?.points == first.points)
        }

        let server = SafetyServer()
        let client = client(server)
        let beforeSync = SyncEngine(model: model, store: original, isSignedIn: { true }, makeClient: { client })
        await beforeSync.sync()
        #expect(await server.walks.isEmpty)
        #expect(!original.loadSyncState().uploadedWalks.contains(first.id))
        if afterReply {
            gate.reply(111)
            await waitForAutomaticFinish(model, id: first.id)
            #expect(model.activeWalk?.id == successorID)
            #expect(model.activeWalk?.points == successorPoints)
        }
        let recovered = try forkWalkFiles(from: originalRoot, into: root())
        defer { recovered.wipe() }
        gate.reply(111)
        await waitForAutomaticFinish(model, id: first.id)
        let nextClock = FinishRecoveryClock(clock.elapsed)
        let relaunched = AppModel(store: recovered, servicesEnabled: false, alwaysOn: true,
                                  stepQuery: { _, _ in 222 }, now: nextClock.now)
        relaunched.countSteps = true
        await relaunched.waitForHistory()
        let next = try #require(relaunched.activeWalk)
        #expect(next.id == successorID)
        #expect(next.id != first.id)
        #expect(next.startedAt == Date(timeIntervalSince1970: finishBase + 720))
        #expect(next.points == successorPoints)
        #expect(abs(next.distance - (followingWhilePending ? 150 : 50)) < 0.01)
        #expect(recovered.loadWalks().first { $0.id == next.id }?.points == successorPoints)
        let finished = relaunched.walks.first { $0.id == first.id }
        #expect(finished?.endedAt == Date(timeIntervalSince1970: finishBase + 320))
        #expect(finished?.endReason == .rode)
        #expect(finished?.points == first.points)
        #expect(finished?.steps == (afterReply ? 111 : 222))

        let firstNewIndex = followingWhilePending ? 2 : 0
        for i in firstNewIndex...(firstNewIndex + 2) {
            nextClock.elapsed = 800 + Double(i) * 40
            relaunched.recordAlwaysOnForTesting(finishFix(1000 + Double(i) * 50, nextClock.elapsed))
        }
        nextClock.elapsed += 20
        relaunched.countSteps = false
        relaunched.endAutoWalk()
        #expect(Set(relaunched.walks.map(\.id)) == [first.id, next.id])
        let sync = SyncEngine(model: relaunched, store: recovered, isSignedIn: { true }, makeClient: { client })
        await sync.sync()
        #expect(sync.status == .idle)
        #expect(await server.walks.count == 2)
        #expect(try await server.uploadedWalk(first.id)?.points == first.points)
        #expect(try await server.uploadedWalk(next.id)?.points.first == arrival)
        #expect(try await server.uploadedWalk(next.id)?.points[1] == confirmation)
        #expect(recovered.loadSyncState().uploadedWalks == [first.id, next.id])
    }

    @Test func aFailedSuccessorWriteKeepsItsSeedUntilAForegroundRetry() async throws {
        let originalRoot = root()
        let original = Store(root: originalRoot)
        defer { original.wipe() }
        let clock = FinishRecoveryClock(0)
        let gate = FinishStepGate()
        let model = AppModel(store: original, servicesEnabled: false, alwaysOn: true,
                             stepQuery: gate.count, now: clock.now)
        let previousCounting = model.countSteps
        model.countSteps = true
        defer { model.countSteps = previousCounting; gate.reply(111) }
        await model.waitForHistory()
        let first = try seedFinishWalk(model, clock: clock)
        clock.elapsed = 340
        model.recordAlwaysOnForTesting(finishFix(450, 340, wheels: true))
        clock.elapsed = 720
        let arrival = finishFix(900, 720)
        model.recordAlwaysOnForTesting(arrival)
        clock.elapsed = 760
        let confirmation = finishFix(950, 760)
        model.recordAlwaysOnForTesting(confirmation)
        await gate.waitForRequest()
        let pending = try #require(original.loadWalks().first { $0.id == first.id })
        let successorID = try #require(try finishSuccessorID(pending))
        let blocked = originalRoot.appending(path: "walks/\(successorID.uuidString).json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        gate.reply(111)
        await gate.waitForReturn()
        // The child's save fails, while the predecessor's file is still writable.
        // Completing the predecessor here would erase the only durable arrival.
        let retained = try #require(original.loadWalks().first { $0.id == first.id })
        #expect(retained.endedAt == nil)
        #expect(try finishSuccessorID(retained) == successorID)
        #expect(model.walks.allSatisfy { $0.id != first.id })
        #expect(model.activeWalk?.id == first.id)
        try FileManager.default.removeItem(at: blocked)
        model.resumeAlwaysOn()
        await waitForAutomaticFinish(model, id: first.id)
        #expect(model.activeWalk?.id == successorID)
        #expect(model.activeWalk?.points == [arrival, confirmation])
        #expect(original.loadWalks().first { $0.id == successorID }?.points == [arrival, confirmation])
        #expect(original.loadWalks().first { $0.id == first.id }?.endedAt == Date(timeIntervalSince1970: finishBase + 320))

        let recovered = try forkWalkFiles(from: originalRoot, into: root())
        defer { recovered.wipe() }
        let relaunched = AppModel(store: recovered, servicesEnabled: false, alwaysOn: true, now: clock.now)
        await relaunched.waitForHistory()
        #expect(relaunched.activeWalk?.id == successorID)
        #expect(relaunched.activeWalk?.points == [arrival, confirmation])
        #expect(relaunched.walks.first { $0.id == first.id }?.points == first.points)
    }

    @Test(arguments: [false, true], ["rode", "gap"])
    func anotherRideKeepsAQualifyingSuccessorWhoseFirstWriteIsBlocked(recreate: Bool, boundary: String) async throws {
        let originalRoot = root()
        let original = Store(root: originalRoot)
        defer { original.wipe() }
        let clock = FinishRecoveryClock(0)
        let gate = FinishStepGate()
        let model = AppModel(store: original, servicesEnabled: false, alwaysOn: true,
                             stepQuery: gate.count, now: clock.now)
        let previousCounting = model.countSteps
        model.countSteps = true
        defer { model.countSteps = previousCounting; gate.reply(111) }
        await model.waitForHistory()
        let first = try seedFinishWalk(model, clock: clock)
        clock.elapsed = 340
        model.recordAlwaysOnForTesting(finishFix(450, 340, wheels: true))
        clock.elapsed = 720
        model.recordAlwaysOnForTesting(finishFix(900, 720))
        clock.elapsed = 760
        model.recordAlwaysOnForTesting(finishFix(950, 760))
        await gate.waitForRequest()
        let pending = try #require(original.loadWalks().first { $0.id == first.id })
        let secondID = try #require(try finishSuccessorID(pending))
        let blocked = originalRoot.appending(path: "walks/\(secondID.uuidString).json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        gate.reply(111)
        await gate.waitForReturn()
        model.countSteps = false
        for i in 2...8 {
            clock.elapsed = 720 + Double(i) * 40
            model.recordAlwaysOnForTesting(finishFix(900 + Double(i) * 50, clock.elapsed))
        }
        let accepted = (0...8).map { finishFix(900 + Double($0) * 50, 720 + Double($0) * 40) }
        let beforeRide = try #require(original.loadWalks().first { $0.id == first.id })
        #expect(beforeRide.endedAt == nil)
        #expect(beforeRide.pendingFinish?.successor?.id == secondID)
        #expect(beforeRide.pendingFinish?.successor?.walk.points == accepted)
        #expect(abs((beforeRide.pendingFinish?.successor?.walk.distance ?? 0) - 400) < 0.01)
        if boundary == "rode" {
            clock.elapsed = 1060
            model.recordAlwaysOnForTesting(finishFix(1350, 1060, wheels: true))
        }
        // A ride invalidates the cursor, but accepted walking stays durable while
        // the next displaced arrival confirms the next outing.
        let afterRide = try #require(original.loadWalks().first { $0.id == first.id })
        let closed = try finishMetadata(afterRide)?["closedSuccessors"] as? [[String: Any]] ?? []
        #expect(afterRide.pendingFinish?.successor?.id == secondID
                || closed.contains { $0["id"] as? String == secondID.uuidString })
        let arrivalTime = boundary == "gap" ? 1640.0 : 1400.0
        let arrivalX = boundary == "gap" ? 1350.0 : 1800.0
        clock.elapsed = arrivalTime
        let thirdArrival = finishFix(arrivalX, arrivalTime)
        model.recordAlwaysOnForTesting(thirdArrival)
        clock.elapsed = arrivalTime + 40
        model.recordAlwaysOnForTesting(finishFix(arrivalX + 50, clock.elapsed))
        model.saveNow(waiting: true)

        let recovered: AppModel
        let recoveredStore: Store
        var cloned: Store?
        defer { cloned?.wipe() }
        if recreate {
            let recreatedRoot = root()
            let store = try forkWalkFiles(from: originalRoot, into: recreatedRoot)
            cloned = store
            try FileManager.default.removeItem(at: recreatedRoot.appending(path: "walks/\(secondID.uuidString).json"))
            recoveredStore = store
            recovered = AppModel(store: store, servicesEnabled: false, alwaysOn: true,
                                 stepQuery: { _, _ in 333 }, now: clock.now)
            recovered.countSteps = true
            await recovered.waitForHistory()
        } else {
            try FileManager.default.removeItem(at: blocked)
            recoveredStore = original
            recovered = model
            recovered.countSteps = true
            recovered.resumeAlwaysOn()
        }
        await waitForAutomaticFinish(recovered, id: secondID)
        let second = try #require(recovered.walks.first { $0.id == secondID })
        #expect(second.points == accepted)
        #expect(second.startedAt == Date(timeIntervalSince1970: finishBase + 720))
        #expect(second.endedAt == Date(timeIntervalSince1970: finishBase + 1040))
        #expect(second.endReason?.rawValue == boundary)
        #expect(second.steps != nil)
        #expect(abs(second.distance - 400) < 0.01)
        #expect(recoveredStore.loadWalks().first { $0.id == secondID }?.points == accepted)
        #expect(recovered.walks.first { $0.id == first.id }?.points == first.points)
        let third = try #require(recovered.activeWalk)
        #expect(third.id != first.id && third.id != secondID)
        #expect(third.points.first == thirdArrival)
        #expect(third.points.allSatisfy { $0.time >= finishBase + arrivalTime })
        let server = SafetyServer()
        let client = client(server)
        let sync = SyncEngine(model: recovered, store: recoveredStore, isSignedIn: { true }, makeClient: { client })
        await sync.sync()
        #expect(sync.status == .idle)
        #expect(await server.walks.count == 2)
        let uploaded = try #require(try await server.uploadedWalk(secondID))
        #expect(uploaded.id == secondID)
        #expect(uploaded.points == accepted)
        #expect(uploaded.endedAt == Date(timeIntervalSince1970: finishBase + 1040))
        #expect(recoveredStore.loadSyncState().uploadedWalks == [first.id, secondID])
        #expect(try await server.uploadedWalk(third.id) == nil)
    }

    @Test func oneWildSpeedFixCannotEndAnAlreadyAcceptedQueuedWalk() async throws {
        let directory = root()
        let store = Store(root: directory)
        defer { store.wipe() }
        let clock = FinishRecoveryClock(0)
        let gate = FinishStepGate()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true,
                             stepQuery: gate.count, now: clock.now)
        let previous = model.countSteps
        model.countSteps = true
        defer { model.countSteps = previous; gate.reply(111) }
        await model.waitForHistory()
        let first = try seedFinishWalk(model, clock: clock)
        clock.elapsed = 340
        model.recordAlwaysOnForTesting(finishFix(450, 340, wheels: true))
        clock.elapsed = 720
        model.recordAlwaysOnForTesting(finishFix(900, 720))
        clock.elapsed = 760
        model.recordAlwaysOnForTesting(finishFix(950, 760))
        await gate.waitForRequest()
        let pending = try #require(store.loadWalks().first { $0.id == first.id })
        let secondID = try #require(try finishSuccessorID(pending))
        let blocked = directory.appending(path: "walks/\(secondID.uuidString).json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        gate.reply(111)
        await gate.waitForReturn()
        model.countSteps = false
        for i in 2...8 {
            clock.elapsed = 720 + Double(i) * 40
            model.recordAlwaysOnForTesting(finishFix(900 + Double(i) * 50, clock.elapsed))
        }
        var wild = finishFix(1600, 1045)
        wild.speed = 9
        model.recordAlwaysOnForTesting(wild)
        clock.elapsed = 1085
        model.recordAlwaysOnForTesting(finishFix(1350, 1085))
        clock.elapsed = 1125
        model.recordAlwaysOnForTesting(finishFix(1400, 1125))
        let saved = try #require(store.loadWalks().first { $0.id == first.id })
        #expect(saved.pendingFinish?.closedSuccessors?.isEmpty != false)
        #expect(saved.pendingFinish?.successor?.id == secondID)
        #expect(saved.pendingFinish?.successor?.walk.points.count == 11)
        try FileManager.default.removeItem(at: blocked)
        model.resumeAlwaysOn()
        await waitForAutomaticFinish(model, id: first.id)
        #expect(model.walks.count == 1)
        #expect(model.activeWalk?.id == secondID)
        #expect(model.activeWalk?.points.count == 11)
        #expect(abs((model.activeWalk?.distance ?? 0) - 500) < 0.01)
    }

    @Test func newWheelsDuringHeldHistoryInvalidateTheDeferredSuccessorAcrossRelaunch() async throws {
        let originalRoot = root()
        let original = Store(root: originalRoot)
        defer { original.wipe() }
        let points = (0...8).map { finishFix(Double($0) * 50, Double($0) * 40) }
        var first = Walk(startedAt: Date(timeIntervalSince1970: finishBase), points: points,
                         distance: CoverageTracer.distance(for: points), automatic: true)
        first.continuation = .rode
        first.resumeAnchor = finishFix(900, 720)
        original.save(first)
        // Recovering an older manual walk holds real history preparation at a step
        // query. The automatic walk's arrival can be confirmed while it waits.
        let older = Walk(startedAt: Date(timeIntervalSince1970: finishBase - 1000),
                         points: [finishFix(-100, -1000), finishFix(-50, -960)])
        original.save(older)
        let gate = FinishStepGate()
        let clock = FinishRecoveryClock(720)
        let model = AppModel(store: original, servicesEnabled: false, alwaysOn: true,
                             stepQuery: gate.count, now: clock.now)
        let previousCounting = model.countSteps
        model.countSteps = true
        defer { model.countSteps = previousCounting; gate.reply(111) }
        await gate.waitForRequest()
        #expect(!model.historyReady)
        clock.elapsed = 760
        model.recordAlwaysOnForTesting(finishFix(950, 760))
        let requested = try #require(original.loadWalks().first { $0.id == first.id })
        #expect(try finishSuccessorID(requested) != nil)
        clock.elapsed = 770
        model.recordAlwaysOnForTesting(finishFix(1000, 770, wheels: true, accuracy: 80))
        model.saveNow(waiting: true)
        let invalidated = try #require(original.loadWalks().first { $0.id == first.id })
        #expect(invalidated.resumeAnchor == nil)
        #expect(try finishSuccessorID(invalidated) == nil)
        let recovered = try forkWalkFiles(from: originalRoot, into: root())
        defer { recovered.wipe() }
        gate.reply(111)
        await model.waitForHistory()
        await waitForAutomaticFinish(model, id: first.id)
        let nextClock = FinishRecoveryClock(770)
        let relaunched = AppModel(store: recovered, servicesEnabled: false, alwaysOn: true,
                                  stepQuery: { _, _ in 222 }, now: nextClock.now)
        relaunched.countSteps = true
        await relaunched.waitForHistory()
        #expect(relaunched.activeWalk == nil)
        nextClock.elapsed = 800
        let genuineArrival = finishFix(950, 800)
        relaunched.recordAlwaysOnForTesting(genuineArrival)
        nextClock.elapsed = 840
        relaunched.recordAlwaysOnForTesting(finishFix(1000, 840))
        let next = try #require(relaunched.activeWalk)
        #expect(next.id != first.id)
        #expect(next.startedAt == Date(timeIntervalSince1970: finishBase + 800))
        #expect(next.points.first == genuineArrival)
        #expect(next.points.allSatisfy { $0.time >= finishBase + 800 })
        #expect(relaunched.walks.first { $0.id == first.id }?.points == first.points)
        #expect(relaunched.walks.first { $0.id == first.id }?.endedAt == Date(timeIntervalSince1970: finishBase + 320))
    }
}

private let finishBase = 1_000_000.0

private func finishFix(_ x: Double, _ elapsed: Double, wheels: Bool = false, accuracy: Double = 5) -> TrackPoint {
    TrackPoint(lat: x / 111195, lon: 0, time: finishBase + elapsed, accuracy: accuracy, speed: 1, wheels: wheels)
}

@MainActor
private final class FinishRecoveryClock {
    var elapsed: Double
    init(_ elapsed: Double) { self.elapsed = elapsed }
    func now() -> Date { Date(timeIntervalSince1970: finishBase + elapsed) }
}

@MainActor
private final class FinishStepGate {
    private var continuation: CheckedContinuation<Int?, Never>?
    private var requested = false
    private var returned = false
    private var holdNext = true
    func count(_ start: Date, _ end: Date) async -> Int? {
        guard holdNext else { return 111 }
        holdNext = false
        requested = true
        let answer = await withCheckedContinuation { continuation = $0 }
        returned = true
        return answer
    }
    func waitForRequest() async {
        for _ in 0..<1000 where !requested { await Task.yield() }
        #expect(requested, "The final step query must actually be pending at the crash point")
    }
    func waitForReturn() async {
        for _ in 0..<1000 where !returned { await Task.yield() }
        #expect(returned)
        // The model handles this synchronous reply on the same actor. Let its
        // completion finish before reading the durable result of the failed save.
        for _ in 0..<20 { await Task.yield() }
    }
    func reply(_ value: Int?) { continuation?.resume(returning: value); continuation = nil }
}

private func forkWalkFiles(from original: URL, into recreated: URL) throws -> Store {
    try FileManager.default.copyItem(at: original, to: recreated)
    return Store(root: recreated)
}

private func finishMetadata(_ walk: Walk) throws -> [String: Any]? {
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(walk)) as! [String: Any]
    return json["pendingFinish"] as? [String: Any]
}

private func finishSuccessorID(_ walk: Walk) throws -> UUID? {
    let successor = try finishMetadata(walk)?["successor"] as? [String: Any]
    return (successor?["id"] as? String).flatMap(UUID.init(uuidString:))
}

@MainActor
private func seedFinishWalk(_ model: AppModel, clock: FinishRecoveryClock) throws -> Walk {
    for i in 0...8 {
        clock.elapsed = Double(i) * 40
        model.recordAlwaysOnForTesting(finishFix(Double(i) * 50, clock.elapsed))
    }
    let walk = try #require(model.activeWalk)
    #expect(!model.autoWalkPending)
    #expect(abs(walk.distance - 400) < 0.01)
    return walk
}

@MainActor
private func waitForAutomaticFinish(_ model: AppModel, id: UUID) async {
    for _ in 0..<1000 where !model.walks.contains(where: { $0.id == id }) { await Task.yield() }
    #expect(model.walks.contains { $0.id == id })
}
