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

    @Test func stageMetadataRoundTripsAndOldFilesStillLoad() throws {
        let old = Data(#"{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"points":[],"distance":0,"newTiles":0}"#.utf8)
        let decoded = try JSONDecoder().decode(Walk.self, from: old)
        #expect(decoded.stage == nil && decoded.rideSeen == nil && decoded.resumeAnchor == nil)
        #expect(decoded.isLegacyOpen)
        var ended = decoded
        ended.endedAt = Date(timeIntervalSince1970: 200)
        #expect(ended.currentStage == .done && !ended.isLegacyOpen)
        var walk = Walk(startedAt: Date(timeIntervalSince1970: start), automatic: true, stage: .tentative)
        walk.rideSeen = true
        walk.resumeAnchor = point(900, 720)
        let saved = try JSONDecoder().decode(Walk.self, from: JSONEncoder().encode(walk))
        #expect(saved.stage == .tentative && saved.rideSeen == true)
        #expect(saved.resumeAnchor == walk.resumeAnchor)
        #expect(walk.move(.confirmed) && walk.stage == .walking)
        #expect(!walk.move(.committed) && walk.stage == .walking)
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

    @Test func aRecordingWalkIsTracedAgainOnRelaunchAndItsTilesStayOutOfSavedPlaces() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesResumeCoverage-\(UUID())"))
        defer { store.wipe() }
        let place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        store.save([place])
        let points = (0...4).map { point(Double($0) * 50, 720 + Double($0) * 40) }
        var open = Walk(startedAt: Date(timeIntervalSince1970: start + 720), points: points, automatic: true, stage: .walking)
        open.resumeAnchor = points.last
        store.save(open)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true,
                             now: { Date(timeIntervalSince1970: start + 900) })
        await model.waitForHistory()
        #expect(model.activeWalk?.id == open.id)
        #expect(!model.autoWalkPending)
        #expect(!model.cities[0].visited.isEmpty)
        #expect(model.freshTiles[place.id] == model.cities[0].visited)
        model.saveNow(waiting: true)
        #expect(store.loadCities()[0].visited.isEmpty)
        model.endAutoWalk()
        #expect(model.activeWalk == nil)
        #expect(store.loadCities()[0].visited == model.cities[0].visited)
        #expect(store.loadWalks().first { $0.id == open.id }?.stage == .done)
        #expect(store.loadWalks().first { $0.id == open.id }?.newTileHexesByPlace?[place.id.uuidString] == model.cities[0].visited)
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

    @Test(arguments: [false, true])
    func aFinishThatAnOlderVersionLeftWaitingClosesBothOutingsAtLaunch(restartExpired: Bool) async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesLegacyFinish-\(UUID())"))
        defer { store.wipe() }
        let points = (0...8).map { point(Double($0) * 50, Double($0) * 40) }
        let next = Walk.LegacyNextWalk(arrival: point(900, 720), point: point(950, 760),
                                       following: (2...7).map { point(900 + Double($0) * 50, 720 + Double($0) * 40) })
        var old = Walk(startedAt: Date(timeIntervalSince1970: start), points: points, newTileHexesByPlace: [:], automatic: true)
        old.pendingFinish = Walk.LegacyFinish(at: Date(timeIntervalSince1970: start + 320), reason: .rode, byYou: false, successor: next)
        store.save(old)
        let time = start + (restartExpired ? 1700 : 1010)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: restartExpired,
                             now: { Date(timeIntervalSince1970: time) })
        await model.waitForHistory()
        #expect(model.activeWalk == nil)
        #expect(Set(model.walks.map(\.id)) == [old.id, next.id])
        #expect(model.walks.allSatisfy { $0.endedAt != nil && $0.stage == .done && $0.pendingFinish == nil })
        #expect(store.loadWalks().allSatisfy { $0.stage == .done })
    }

    @Test(arguments: [200.0, 350.0])
    func anExpiredConfirmedSeedKeepsCityCoverageEvenWhenItsRouteIsDropped(distance: Double) async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesExpiredCoverage-\(UUID())"))
        defer { store.wipe() }
        let place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        store.save([place])
        let count = Int(distance / 50)
        let points = (0...count).map { point(Double($0) * 50, 720 + Double($0) * 40) }
        let walk = Walk(startedAt: Date(timeIntervalSince1970: start + 720), points: points, automatic: true)
        store.save(walk)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        #expect(model.activeWalk == nil)
        #expect(!model.cities[0].visited.isEmpty)
        #expect(store.loadCities()[0].visited == model.cities[0].visited)
        #expect(model.freshTiles.isEmpty)
        if distance < 300 {
            #expect(model.walks.isEmpty)
            #expect(model.cities[0].tileCredits?.first?.id == walk.id)
            #expect(model.cities[0].tileCredits?.first?.hexes.isEmpty == false)
        } else {
            #expect(model.walks.first?.id == walk.id)
            #expect(model.walks.first?.newTileHexesByPlace?[place.id.uuidString]?.isEmpty == false)
        }
    }

    @Test func aRideArrivalThatGoesStaleStartsTheNextWalkFromAFreshFix() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesSingleAnchor-\(UUID())"))
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true,
                             now: { Date(timeIntervalSince1970: start + 700) })
        await model.waitForHistory()
        _ = try seed(model)
        var wheels = point(450, 340); wheels.wheels = true
        model.recordAlwaysOnForTesting(wheels)
        model.recordAlwaysOnForTesting(point(900, 400))
        model.recordAlwaysOnForTesting(point(950, 700))
        model.recordAlwaysOnForTesting(point(1000, 950))
        model.recordAlwaysOnForTesting(point(1050, 990))
        #expect(model.activeWalk?.startedAt == Date(timeIntervalSince1970: start + 950))
        #expect(model.activeWalk?.points == [point(1000, 950), point(1050, 990)])
    }



    @Test(arguments: [200.0, 400.0])
    func aRecoveredRetraceCannotClaimAnEarlierWalksTiles(distance: Double) async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesPriorCredit-\(UUID())"))
        defer { store.wipe() }
        var place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        let oldPoints = (0...8).map { point(Double($0) * 50, Double($0) * 40) }
        let fresh = place.visit(CoverageTracer.samples(for: oldPoints), within: place.shape())
        store.save([place])
        let old = Walk(startedAt: Date(timeIntervalSince1970: start), endedAt: Date(timeIntervalSince1970: start + 320),
                       points: oldPoints, newTiles: fresh.count, newTilesByPlace: [place.id.uuidString: fresh.count],
                       newTileHexesByPlace: [place.id.uuidString: fresh], automatic: true)
        store.save(old)
        let points = (0...Int(distance / 50)).map { point(Double($0) * 50, 1000 + Double($0) * 40) }
        let retrace = Walk(startedAt: Date(timeIntervalSince1970: start + 1000), points: points, automatic: true)
        store.save(retrace)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        #expect(model.cities[0].tileCredits?.contains { $0.id == retrace.id } != true)
        if distance >= 300 {
            let kept = try #require(model.walks.first { $0.id == retrace.id })
            #expect(kept.newTiles == 0)
            #expect(kept.newTileHexesByPlace?.values.allSatisfy(\.isEmpty) != false)
        } else {
            #expect(!model.walks.contains { $0.id == retrace.id })
        }
    }

}
