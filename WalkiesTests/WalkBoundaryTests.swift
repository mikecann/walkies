import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct WalkBoundaryTests {
    let start = 100_000.0

    func point(_ metres: Double, _ elapsed: Double) -> TrackPoint {
        TrackPoint(lat: metres / LocalProjection.earthRadius * 180 / .pi, lon: 0,
                   time: start + elapsed, accuracy: 5, speed: 1)
    }

    func seed(_ model: AppModel) throws -> Walk {
        for i in 0...8 { model.recordAlwaysOnForTesting(point(Double(i) * 50, Double(i) * 40)) }
        return try #require(model.activeWalk)
    }

    @Test(arguments: [599.999, 600.0, 600.001])
    func restUsesTheSameGapBoundaryLiveAndAfterRelaunch(gap: Double) async throws {
        for relaunch in [false, true] {
            let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesGap-\(UUID())"))
            defer { store.wipe() }
            var time = start + 320
            var model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { Date(timeIntervalSince1970: time) })
            await model.waitForHistory()
            let old = try seed(model)
            model.saveNow(waiting: true)
            time += gap
            if relaunch {
                model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { Date(timeIntervalSince1970: time) })
                await model.waitForHistory()
            }
            model.recordAlwaysOnForTesting(point(450, time - start))
            model.recordAlwaysOnForTesting(point(500, time - start + 40))
            #expect((model.activeWalk?.id == old.id) == (gap < 600))
            #expect(model.walks.count == (gap < 600 ? 0 : 1))
            if gap >= 600 { #expect(model.walks.first?.endedAt == Date(timeIntervalSince1970: start + 320)) }
        }
    }

    @Test(arguments: [119.999, 120.0, 120.001])
    func aNewWalkUsesOnlyAFreshAnchor(age: Double) async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesAnchor-\(UUID())"))
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        model.recordAlwaysOnForTesting(point(0, 0))
        model.recordAlwaysOnForTesting(point(50, age))
        if age <= 120 {
            #expect(model.activeWalk?.points.first == point(0, 0))
        } else {
            #expect(model.activeWalk == nil)
            model.recordAlwaysOnForTesting(point(100, age + 40))
            #expect(model.activeWalk?.points.first == point(50, age))
        }
    }

    @Test func aLongLocalLoopStillNeedsTheDisplacementThreshold() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesLoop-\(UUID())"))
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        for (index, x) in [0.0, 75, 140, 75, 0, 75, 140, 75, 0].enumerated() {
            model.recordAlwaysOnForTesting(point(x, Double(index) * 60))
        }
        #expect(model.autoWalkPending)
        #expect(try #require(model.activeWalk).distance > 500)
        // A gap ends it automatically; a short local loop isn't a confirmed outing.
        model.recordAlwaysOnForTesting(point(0, 1080))
        #expect(model.activeWalk == nil)
        #expect(model.walks.isEmpty)
        #expect(store.loadWalks().isEmpty)
    }

    @Test func theQuietClockFinishesWithoutAnotherFix() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesQuiet-\(UUID())"))
        defer { store.wipe() }
        var time = start + 320
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { Date(timeIntervalSince1970: time) })
        await model.waitForHistory()
        let old = try seed(model)
        time = start + 919.999
        model.finishStaleAutoWalk()
        #expect(model.activeWalk?.id == old.id)
        time = start + 920
        model.finishStaleAutoWalk()
        model.finishStaleAutoWalk()
        #expect(model.activeWalk == nil)
        #expect(model.walks.count == 1)
        #expect(model.walks.first?.endReason == .quiet)
        #expect(store.loadWalks().first?.endedAt == Date(timeIntervalSince1970: start + 320))
    }

    @Test func continuationMetadataRoundTripsAndOldFilesStillLoad() throws {
        let old = Data(#"{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"points":[],"distance":0,"newTiles":0}"#.utf8)
        let decoded = try JSONDecoder().decode(Walk.self, from: old)
        #expect(decoded.continuation == nil)
        #expect(decoded.resumeAnchor == nil)
        var walk = Walk(startedAt: Date(timeIntervalSince1970: start))
        walk.continueAfter(.observedRide)
        walk.resumeAnchor = point(900, 720)
        let saved = try JSONDecoder().decode(Walk.self, from: JSONEncoder().encode(walk))
        #expect(saved.continuation == .rode)
        #expect(saved.resumeAnchor == walk.resumeAnchor)
        walk.continueAfter(.acceptedWalkingStep)
        #expect(walk.continuation == .walking)
    }

    @Test(arguments: [149.999, 150.0, 150.001])
    func confirmationNeeds150MetresOfDisplacement(farthest: Double) {
        let xs = [0.0, 75, farthest, 75, 0, 75, farthest]
        let points = xs.enumerated().map { point($0.element, Double($0.offset) * 60) }
        #expect(CoverageTracer.distance(for: points) > 300)
        #expect(AppModel.countsAsAutoWalk(points) == (farthest >= 150))
    }

    @Test(arguments: [299.999, 300.001])
    func automaticHistoryNeeds300MetresOfRoute(distance: Double) {
        let points = [0.0, 100, 200, distance].enumerated().map { point($0.element, Double($0.offset) * 100) }
        #expect(AppModel.countsAsAutoWalk(points) == (distance >= 300))
    }


    @Test func exactDistanceCutoffsIncludeTheThresholdItself() {
        // Threshold policy is tested on exact metre values. Haversine segment sums
        // can round a synthetic nominal 300 m route to 299.99999999999994 m.
        #expect(AppModel.countsAsAutoWalk(displacement: 150, distance: 300))
        #expect(!AppModel.countsAsAutoWalk(displacement: 150.0.nextDown, distance: 300))
        #expect(!AppModel.countsAsAutoWalk(displacement: 150, distance: 300.0.nextDown))
    }

}
