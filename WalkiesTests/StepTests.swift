import Foundation
import Testing
@testable import Walkies

struct WalkStepJSONTests {
    @Test func oldJSONWithoutStepsStillDecodes() throws {
        let json = #"{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"points":[],"distance":0,"newTiles":0}"#
        let walk = try JSONDecoder().decode(Walk.self, from: Data(json.utf8))
        #expect(walk.steps == nil)
    }

    @Test func stepsRoundTripIncludingZero() throws {
        for count in [0, 1234] {
            let walk = Walk(startedAt: Date(timeIntervalSince1970: 100), steps: count)
            let data = try JSONEncoder().encode(walk)
            #expect(try JSONDecoder().decode(Walk.self, from: data).steps == count)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["steps"] as? Int == count)
        }
    }

    @Test func nilStepsAreAbsentRatherThanNull() throws {
        let data = try JSONEncoder().encode(Walk(startedAt: .now))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!json.keys.contains("steps"))
    }
}

@MainActor
@Suite(.serialized)
struct WalkStepFinishTests {
    func store() -> Store {
        Store(root: URL.temporaryDirectory.appending(path: "WalkiesSteps-\(UUID())"))
    }

    /// A controlled reply makes a late sensor callback reproducible.
    final class Source {
        var continuation: CheckedContinuation<Int?, Never>?
        var ranges: [(Date, Date)] = []
        func count(_ start: Date, _ end: Date) async -> Int? {
            ranges.append((start, end))
            return await withCheckedContinuation { continuation = $0 }
        }
        func reply(_ count: Int?) { continuation?.resume(returning: count); continuation = nil }
    }

    @Test func countIsSavedBeforeSyncAndRepeatedEndCannotReplaceTheWalk() async throws {
        let store = store()
        defer { store.wipe() }
        let source = Source()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false, stepQuery: source.count)
        model.countSteps = true
        await model.waitForHistory()
        var syncedSteps: Int?
        model.requestSync = { syncedSteps = model.walks.last?.steps }
        model.startWalk()
        let id = try #require(model.activeWalk?.id)
        model.endWalk()
        model.endWalk()
        model.startWalk()
        await Task.yield()
        #expect(model.activeWalk?.id == id)
        #expect(model.walks.isEmpty)
        #expect(source.ranges.count == 1)
        source.reply(1234)
        for _ in 0..<20 where model.activeWalk != nil { await Task.yield() }
        #expect(model.walks.last?.id == id)
        #expect(model.walks.last?.steps == 1234)
        #expect(model.recap?.walk.steps == 1234)
        #expect(syncedSteps == 1234)
        #expect(store.loadWalks().first?.steps == 1234)
    }

    @Test func turningCountingOffDiscardsAnInFlightReply() async {
        let store = store()
        defer { store.wipe() }
        let source = Source()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false, stepQuery: source.count)
        model.countSteps = true
        await model.waitForHistory()
        model.startWalk()
        model.endWalk()
        await Task.yield()
        model.countSteps = false
        source.reply(500)
        for _ in 0..<20 where model.activeWalk != nil { await Task.yield() }
        #expect(model.walks.last?.steps == nil)
        #expect(model.walks.count == 1)
        model.countSteps = true
    }

    @Test func aReplyAfterWipeCannotFinishANewWalk() async {
        let store = store()
        defer { store.wipe() }
        let source = Source()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false, stepQuery: source.count)
        model.countSteps = true
        await model.waitForHistory()
        model.startWalk()
        model.endWalk()
        await Task.yield()
        model.wipeLocalData()
        model.startWalk()
        let next = model.activeWalk?.id
        source.reply(600)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.walks.isEmpty)
        #expect(model.activeWalk?.id == next)
        #expect(model.activeWalk?.steps == nil)
    }

    @Test func automaticWalkSavesStepsWithItsRecap() async throws {
        let store = store()
        defer { store.wipe() }
        let start = Date.now.addingTimeInterval(-400)
        let points = (0...3).map { i in
            TrackPoint(lat: 0, lon: Double(i) * 0.001, time: start.timeIntervalSince1970 + Double(i) * 100, accuracy: 5, speed: 1)
        }
        store.save(Walk(startedAt: start, points: points, automatic: true))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, stepQuery: { from, to in
            #expect(from == start)
            #expect(to >= Date(timeIntervalSince1970: points.last!.time))
            return 450
        })
        await model.waitForHistory()
        model.endAutoWalk()
        for _ in 0..<100 where model.activeWalk != nil { await Task.yield() }
        #expect(model.walks.first?.steps == 450)
        #expect(model.recap?.walk.steps == 450)
        #expect(store.loadWalks().first?.steps == 450)
    }

    @Test func recoveredWalkGetsItsCountBeforeBecomingFinished() async throws {
        let store = store()
        defer { store.wipe() }
        let start = Date.now.addingTimeInterval(-600)
        // A whole second, so it comes back the same from the point's timeIntervalSince1970.
        // Any old time can be a rounding error out, which made this fail now and then.
        let last = Date(timeIntervalSince1970: (start.timeIntervalSince1970 + 300).rounded())
        store.save(Walk(startedAt: start, points: [TrackPoint(lat: 1, lon: 1, time: last.timeIntervalSince1970, accuracy: 5)]))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false, stepQuery: { from, to in
            #expect(from == start)
            #expect(to == last)
            return 400
        })
        await model.waitForHistory()
        #expect(model.walks.first?.steps == 400)
        #expect(model.walks.first?.endedAt == last)
        #expect(store.loadWalks().first?.steps == 400)
    }
}
