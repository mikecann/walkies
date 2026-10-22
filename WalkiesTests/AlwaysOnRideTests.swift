import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct AlwaysOnRideTests {
    let projection = LocalProjection(origin: Coordinate(lat: 12.345, lon: 45.678))

    func fix(east metres: Double, at time: Double, speed: Double = 1, wheels: Bool = false) -> TrackPoint {
        let c = projection.unproject(SIMD2(metres, 0))
        return TrackPoint(lat: c.lat, lon: c.lon, time: time, accuracy: 5, speed: speed, wheels: wheels)
    }

    func startWalk(_ model: AppModel, at start: Double) throws -> Walk {
        for i in 0...8 {
            model.recordAlwaysOnForTesting(fix(east: Double(i) * 50, at: start + Double(i) * 40))
        }
        #expect(!model.autoWalkPending)
        return try #require(model.activeWalk)
    }

    func makeModel() async -> (AppModel, Store) {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesRide-\(UUID())"))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        return (model, store)
    }

    /// Mike's school run: the fix after the drive looked like walking (stopped at home),
    /// and the drive was shorter than the gap that ends a walk.
    @Test func aDriveEndsTheWalkEvenWhenTheArrivalFixLooksOnFoot() async throws {
        let (model, store) = await makeModel()
        defer { store.wipe() }
        let old = try startWalk(model, at: Date.now.timeIntervalSince1970)
        let last = try #require(old.points.last)
        let arrival = fix(east: 2900, at: last.time + 519, speed: 1.2)
        model.recordAlwaysOnForTesting(arrival)
        // One fix on its own could be a GPS glitch, so nothing happens yet.
        #expect(model.activeWalk?.id == old.id)
        #expect(model.walks.isEmpty)
        model.recordAlwaysOnForTesting(fix(east: 2950, at: arrival.time + 40))
        let saved = try #require(model.walks.first)
        #expect(saved.id == old.id)
        #expect(saved.points == old.points)
        #expect(saved.endedAt == Date(timeIntervalSince1970: last.time))
        #expect(store.loadWalks().first?.endedAt == saved.endedAt)
        for i in 2...4 {
            model.recordAlwaysOnForTesting(fix(east: 2900 + Double(i) * 50, at: arrival.time + Double(i) * 40))
        }
        let next = try #require(model.activeWalk)
        #expect(next.id != old.id)
        #expect(next.points.first == arrival)
        #expect(next.startedAt == Date(timeIntervalSince1970: arrival.time))
        #expect(next.points.allSatisfy { $0.coordinate.distance(to: arrival.coordinate) < 250 })
    }

    @Test(arguments: [true, false])
    func aRideWithALongWaitStillEndsTheWalk(wheels: Bool) async throws {
        let (model, store) = await makeModel()
        defer { store.wipe() }
        let old = try startWalk(model, at: Date.now.timeIntervalSince1970)
        let last = try #require(old.points.last)
        // Ride evidence close by must wait until you've gone more than maxGap.
        model.recordAlwaysOnForTesting(fix(east: 450, at: last.time + 20, speed: wheels ? 1 : 8, wheels: wheels))
        #expect(model.activeWalk?.id == old.id)
        #expect(model.activeWalk?.points == old.points)
        let arrival = fix(east: 900, at: last.time + 400)
        #expect(last.coordinate.distance(to: arrival.coordinate) / 400 < CoverageTracer.maxSpeed)
        model.recordAlwaysOnForTesting(arrival)
        model.recordAlwaysOnForTesting(fix(east: 950, at: arrival.time + 40))
        #expect(model.walks.first?.id == old.id)
        #expect(model.walks.first?.points == old.points)
        #expect(model.walks.first?.endedAt == Date(timeIntervalSince1970: last.time))
        let next = try #require(model.activeWalk)
        #expect(next.id != old.id)
        #expect(next.points.first == arrival)
        // Ride evidence from the previous walk mustn't split this walking dropout.
        model.recordAlwaysOnForTesting(fix(east: 1150, at: arrival.time + 220))
        model.recordAlwaysOnForTesting(fix(east: 1200, at: arrival.time + 260))
        #expect(model.activeWalk?.id == next.id)
        #expect(model.activeWalk?.points.last?.coordinate == fix(east: 1200, at: 0).coordinate)
    }

    @Test func aWalkingGPSDropoutKeepsTheSameWalk() async throws {
        let (model, store) = await makeModel()
        defer { store.wipe() }
        let old = try startWalk(model, at: Date.now.timeIntervalSince1970)
        let last = try #require(old.points.last)
        model.recordAlwaysOnForTesting(fix(east: 600, at: last.time + 180))
        model.recordAlwaysOnForTesting(fix(east: 650, at: last.time + 220))
        #expect(model.walks.isEmpty)
        #expect(model.activeWalk?.id == old.id)
        #expect(model.activeWalk?.startedAt == old.startedAt)
        #expect(model.activeWalk?.points.last?.coordinate == fix(east: 650, at: 0).coordinate)
    }

    @Test func oneWildFixMidWalkKeepsTheSameWalk() async throws {
        let (model, store) = await makeModel()
        defer { store.wipe() }
        let old = try startWalk(model, at: Date.now.timeIntervalSince1970)
        let last = try #require(old.points.last)
        model.recordAlwaysOnForTesting(fix(east: 700, at: last.time + 5, speed: 9))
        for i in 1...3 {
            model.recordAlwaysOnForTesting(fix(east: 400 + Double(i) * 50, at: last.time + 5 + Double(i) * 40))
        }
        #expect(model.walks.isEmpty)
        #expect(model.activeWalk?.id == old.id)
        #expect(model.activeWalk?.points.last?.coordinate == fix(east: 550, at: 0).coordinate)
    }
}
