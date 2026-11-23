import Foundation
import Testing
@testable import Walkies

/// One event stream and expected identities for both clients. All coordinates are made up.
@MainActor
@Suite(.serialized)
struct WalkLifecycleTests {
    struct Fixture: Decodable {
        var version: Int
        var startTime: Double
        var origin: Coordinate
        var initial: Initial
        var scenarios: [Scenario]
        struct Initial: Decodable { var xs: [Double]; var interval: Double }
        struct Scenario: Decodable { var name: String; var events: [Event]; var expected: Expected }
        struct Event: Decodable {
            var action: String
            var x: Double?
            var time: Double?
            var wheels: Bool?
            var speed: Double?
            var accuracy: Double?
        }
        struct Expected: Decodable {
            var active: String
            var finished: Int
            var points: Int?
            var endTime: Double?
            var startTime: Double?
            var distance: Double?
            var finishedDistance: Double?
        }
    }

    @Test func sharedLifecycleScenarios() async throws {
        let url = ProcessInfo.processInfo.environment["WALKIES_LIFECYCLE_FIXTURES"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "shared/fixtures/walk-lifecycle.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.version == 1)
        for scenario in fixture.scenarios {
            let root = URL.temporaryDirectory.appending(path: "WalkiesLifecycle-\(UUID())")
            let store = Store(root: root)
            defer { store.wipe() }
            var time = fixture.startTime
            var model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { Date(timeIntervalSince1970: time) })
            await model.waitForHistory()
            func point(_ x: Double, _ elapsed: Double, wheels: Bool = false, speed: Double = 1, accuracy: Double = 5) -> TrackPoint {
                TrackPoint(lat: fixture.origin.lat + x / 111195, lon: fixture.origin.lon,
                           time: fixture.startTime + elapsed, accuracy: accuracy, speed: speed, wheels: wheels)
            }
            for (index, x) in fixture.initial.xs.enumerated() {
                time = fixture.startTime + Double(index) * fixture.initial.interval
                model.recordAlwaysOnForTesting(point(x, time - fixture.startTime))
            }
            let original = try #require(model.activeWalk)
            #expect(!model.autoWalkPending)
            model.saveNow(waiting: true)
            for event in scenario.events {
                if let elapsed = event.time { time = fixture.startTime + elapsed }
                switch event.action {
                case "fix":
                    model.recordAlwaysOnForTesting(point(try #require(event.x), time - fixture.startTime,
                                                         wheels: event.wheels ?? false, speed: event.speed ?? 1, accuracy: event.accuracy ?? 5))
                case "advance": break
                case "checkpoint": model.saveNow(waiting: true)
                case "relaunch":
                    store.flush()
                    model = AppModel(store: Store(root: root), servicesEnabled: false, alwaysOn: true,
                                     now: { Date(timeIntervalSince1970: time) })
                    await model.waitForHistory()
                case "finish": model.endAutoWalk()
                case "stale": model.finishStaleAutoWalk()
                default: Issue.record("Unknown lifecycle event \(event.action)")
                }
            }
            switch scenario.expected.active {
            case "same": #expect(model.activeWalk?.id == original.id, "\(scenario.name)")
            case "different":
                #expect(model.activeWalk != nil, "\(scenario.name)")
                #expect(model.activeWalk?.id != original.id, "\(scenario.name)")
            case "none": #expect(model.activeWalk == nil, "\(scenario.name)")
            default: Issue.record("Unknown expected state \(scenario.expected.active)")
            }
            #expect(model.walks.count == scenario.expected.finished, "\(scenario.name)")
            if let points = scenario.expected.points { #expect(model.activeWalk?.points.count == points, "\(scenario.name)") }
            if let start = scenario.expected.startTime {
                #expect(model.activeWalk?.startedAt == Date(timeIntervalSince1970: fixture.startTime + start), "\(scenario.name)")
            }
            if let distance = scenario.expected.distance {
                #expect(abs((model.activeWalk?.distance ?? -1) - distance) < 0.01, "\(scenario.name)")
            }
            if let distance = scenario.expected.finishedDistance {
                #expect(abs((model.walks.first?.distance ?? -1) - distance) < 0.01, "\(scenario.name)")
            }
            if let end = scenario.expected.endTime {
                let ended = try #require(model.walks.first)
                #expect(ended.id == original.id, "\(scenario.name)")
                #expect(ended.endedAt == Date(timeIntervalSince1970: fixture.startTime + end), "\(scenario.name)")
                #expect(ended.points == original.points, "\(scenario.name)")
            }
            model.saveNow(waiting: true)
            let disk = Store(root: root).loadWalks()
            #expect(Set(disk.map(\.id)) == Set(model.walks.map(\.id) + (model.activeWalk.map { [$0.id] } ?? [])), "\(scenario.name)")
        }
    }
}
