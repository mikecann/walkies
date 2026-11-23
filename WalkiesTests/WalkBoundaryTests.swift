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


    @Test(arguments: [false, true])
    func aRideArrivalOlderThanTwoMinutesCannotBackdateTheNextWalk(relaunch: Bool) async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesStaleArrival-\(UUID())"))
        defer { store.wipe() }
        var time = start + 320
        var model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { Date(timeIntervalSince1970: time) })
        await model.waitForHistory()
        let old = try seed(model)
        model.saveNow(waiting: true)
        var wheels = point(450, 340); wheels.wheels = true
        model.recordAlwaysOnForTesting(wheels)
        model.recordAlwaysOnForTesting(point(900, 400))
        time = start + 400
        if relaunch {
            model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: { Date(timeIntervalSince1970: time) })
            await model.waitForHistory()
        }
        time = start + 700
        model.recordAlwaysOnForTesting(point(950, 700))
        model.recordAlwaysOnForTesting(point(1000, 740))
        #expect(model.walks.first?.id == old.id)
        #expect(model.walks.first?.endedAt == Date(timeIntervalSince1970: start + 320))
        #expect(model.activeWalk?.startedAt == Date(timeIntervalSince1970: start + 700))
        #expect(model.activeWalk?.points.first == point(950, 700))
        #expect(model.activeWalk?.points.count == 2)
    }

    @Test func firstUnlockReloadsTheStepPreferenceThatWasUnreadableAtLaunch() async {
        let prior = UserDefaults.standard.object(forKey: "countSteps")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "countSteps") }
            else { UserDefaults.standard.removeObject(forKey: "countSteps") }
        }
        UserDefaults.standard.removeObject(forKey: "countSteps")
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesUnlockSteps-\(UUID())"))
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, waitForUnlock: true)
        #expect(model.countSteps)
        UserDefaults.standard.set(false, forKey: "countSteps")
        model.loadSaved()
        #expect(!model.countSteps)
        await model.waitForHistory()
    }

    @Test func aConfirmedSuccessorSeedReplaysCoverageAfterItsPredecessorHasFinished() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesSeedCoverage-\(UUID())"))
        defer { store.wipe() }
        let place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        store.save([place])
        let seed = Walk.NextWalk(arrival: point(0, 720), point: point(50, 760),
                                 following: [point(100, 800), point(150, 840), point(200, 880)])
        let saved = seed.walk
        #expect(saved.newTileHexesByPlace == nil)
        store.save(saved)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true,
                             now: { Date(timeIntervalSince1970: start + 900) })
        await model.waitForHistory()
        #expect(model.activeWalk?.id == saved.id)
        #expect(!model.autoWalkPending)
        #expect(!model.cities[0].visited.isEmpty)
        #expect(model.activeWalk?.newTileHexesByPlace?[place.id.uuidString]?.isEmpty == false)
        #expect(store.loadCities()[0].visited == model.cities[0].visited)
    }

    @Test func replayingADropAfterCityCreditButBeforeDeleteCannotAwardTwice() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesCreditCrash-\(UUID())"))
        defer { store.wipe() }
        let place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        store.save([place])
        let hexes: Set<Hex> = [place.grid.hex(containing: Coordinate(lat: 0, lon: 0))]
        let checkpoint = Walk(startedAt: Date(timeIntervalSince1970: start),
                              points: [point(0, 0), point(50, 40), point(100, 80)],
                              newTileHexesByPlace: [place.id.uuidString: hexes], automatic: true)
        store.save(checkpoint)
        let first = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await first.waitForHistory()
        store.flush()
        // Replay the durable pair left by a kill between the city write and walk deletion.
        store.save(checkpoint)
        let again = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await again.waitForHistory()
        let date = checkpoint.startedAt
        let week = Progression.week(containing: date, calendar: Progression.calendar)
        let inputs = Progression.Inputs(cities: again.cities, walks: again.walks, now: date.addingTimeInterval(1000))
        #expect(Progression.questProgress(.tiles25, week: week, inputs: inputs) == 1)
        #expect(again.walks.isEmpty)
        #expect(store.loadWalks().isEmpty)
    }

}
