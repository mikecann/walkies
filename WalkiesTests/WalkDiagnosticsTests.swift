import Foundation
import Testing
@testable import Walkies

private nonisolated final class WalkEndEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TrackerTrace.EndEvent] = []
    func append(_ event: TrackerTrace.EndEvent) { lock.lock(); defer { lock.unlock() }; values.append(event) }
    var events: [TrackerTrace.EndEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
@Suite(.serialized)
struct WalkDiagnosticsTests {
    @Test(arguments: ["gap", "quiet", "rode", "you", "always on off"])
    func everyAutomaticFinishKeepsItsReason(reason: String) async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesReasons-\(UUID())"))
        defer { store.wipe() }
        var time = 100_320.0
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { Date(timeIntervalSince1970: time) })
        await model.waitForHistory()
        let helper = WalkBoundaryTests()
        let old = try helper.seed(model)
        let sink = WalkEndEvents()
        await TrackerTrace.$endSink.withValue({ sink.append($0) }) {
            switch reason {
            case "gap": model.recordAlwaysOnForTesting(helper.point(450, 920))
            case "quiet": time = 100_920; model.finishStaleAutoWalk()
            case "rode":
                var wheels = helper.point(450, 340); wheels.wheels = true
                model.recordAlwaysOnForTesting(wheels)
                model.recordAlwaysOnForTesting(helper.point(900, 720))
                model.recordAlwaysOnForTesting(helper.point(950, 760))
            case "you": model.endAutoWalk()
            default: model.alwaysOn = false
            }
        }
        let event = try #require(sink.events.first)
        #expect(sink.events.count == 1)
        #expect(event.reason == reason)
        #expect(event.kept)
        #expect(event.walk.id == old.id)
        #expect(store.loadWalks().first { $0.id == old.id }?.endReason?.rawValue == reason)
    }

    @Test func aRecoveredDropEmitsItsRouteAndReason() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesDrop-\(UUID())"))
        defer { store.wipe() }
        let helper = WalkBoundaryTests()
        let points = (0...2).map { helper.point(Double($0) * 40, Double($0) * 40) }
        let walk = Walk(startedAt: Date(timeIntervalSince1970: helper.start), points: points, automatic: true)
        store.save(walk)
        let sink = WalkEndEvents()
        await TrackerTrace.$endSink.withValue({ sink.append($0) }) {
            let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true,
                                 now: { Date(timeIntervalSince1970: 101_000) })
            await model.waitForHistory()
            #expect(model.walks.isEmpty)
        }
        let event = try #require(sink.events.first)
        #expect(event.reason == "recovered")
        #expect(!event.kept)
        #expect(event.pending)
        #expect(event.walk.points == points)
        #expect(event.walk.endedAt == Date(timeIntervalSince1970: points.last!.time))
        #expect(store.loadWalks().isEmpty)
    }
}
