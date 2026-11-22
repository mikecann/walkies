import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct RideRelaunchTests {
    private let projection = LocalProjection(origin: Coordinate(lat: 12.345, lon: 45.678))
    private func fix(_ x: Double, _ time: Double, wheels: Bool = false) -> TrackPoint {
        let c = projection.unproject(SIMD2(x, 0))
        return TrackPoint(lat: c.lat, lon: c.lon, time: time, accuracy: 5, speed: 1, wheels: wheels)
    }

    @Test(arguments: ["none", "afterRide", "afterArrival"])
    func aKnownRideStillSplitsTheWalkAcrossRelaunch(stage: String) async throws {
        let root = URL.temporaryDirectory.appending(path: "WalkiesLossReplay-\(UUID())")
        let store = Store(root: root)
        defer { store.wipe() }
        var model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        let start = Date.now.timeIntervalSince1970 - 500
        for i in 0...8 { model.recordAlwaysOnForTesting(fix(Double(i) * 50, start + Double(i) * 40)) }
        let old = try #require(model.activeWalk)
        let last = try #require(old.points.last)
        #expect(!model.autoWalkPending)
        #expect(old.distance > 399)
        model.saveNow(waiting: true)
        model.recordAlwaysOnForTesting(fix(450, last.time + 20, wheels: true))
        // The rejected wheels fix must checkpoint the evidence itself.
        if stage == "afterRide" {
            model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
            await model.waitForHistory()
            #expect(model.activeWalk?.id == old.id)
        }
        // A ride, then a wait: average pace is below the GPS speed cutoff. The explicit
        // wheels event is the evidence that distinguishes this from a walking dropout.
        model.recordAlwaysOnForTesting(fix(900, last.time + 400))
        if stage == "afterArrival" {
            model.saveNow(waiting: true)
            model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
            await model.waitForHistory()
        }
        model.recordAlwaysOnForTesting(fix(950, last.time + 440))
        let kept = model.walks.contains { $0.id == old.id }
        let split = model.activeWalk?.id != old.id
        print("RIDE_RELAUNCH stage=\(stage) savedOld=\(kept) newIdentity=\(split) oldPoints=\(old.points.count) currentPoints=\(model.activeWalk?.points.count ?? 0)")
        #expect(kept, "The pre-ride walk must end even if the process was relaunched")
        #expect(split, "On-foot fixes after a known ride must start a new walk")
        if let saved = model.walks.first { #expect(saved.endedAt == Date(timeIntervalSince1970: last.time)) }
        let next = try #require(model.activeWalk)
        #expect(next.points.first == fix(900, last.time + 400))
        #expect(next.startedAt == Date(timeIntervalSince1970: last.time + 400))
    }

    @Test func aRelaunchDuringRestKeepsTheFirstResumedSegment() async throws {
        let root = URL.temporaryDirectory.appending(path: "WalkiesRestReplay-\(UUID())")
        let store = Store(root: root)
        defer { store.wipe() }
        var model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        let start = Date.now.timeIntervalSince1970 - 500
        for i in 0...8 { model.recordAlwaysOnForTesting(fix(Double(i) * 50, start + Double(i) * 40)) }
        let before = try #require(model.activeWalk)
        model.saveNow(waiting: true)
        model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        model.recordAlwaysOnForTesting(fix(450, start + 500))
        let resumed = try #require(model.activeWalk)
        #expect(resumed.id == before.id)
        #expect(resumed.points.count == before.points.count + 1)
        #expect(abs(resumed.distance - 450) < 1)
        model.endWalk()
        #expect(model.walks.first?.id == before.id)
        #expect(abs((store.loadWalks().first?.distance ?? 0) - 450) < 1)
    }


    @Test func anotherRideWithPoorGPSCannotRestoreAnEarlierArrival() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesPoorRide-\(UUID())"))
        defer { store.wipe() }
        var model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        let start = Date.now.timeIntervalSince1970 - 500
        for i in 0...8 { model.recordAlwaysOnForTesting(fix(Double(i) * 50, start + Double(i) * 40)) }
        let old = try #require(model.activeWalk)
        let last = try #require(old.points.last)
        model.saveNow(waiting: true)
        model.recordAlwaysOnForTesting(fix(450, last.time + 20, wheels: true))
        model.recordAlwaysOnForTesting(fix(900, last.time + 180))
        var poorRide = fix(1000, last.time + 200, wheels: true)
        poorRide.accuracy = 1000
        model.recordAlwaysOnForTesting(poorRide)
        model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        model.recordAlwaysOnForTesting(fix(950, last.time + 400))
        model.recordAlwaysOnForTesting(fix(1000, last.time + 440))
        #expect(model.walks.first?.id == old.id)
        #expect(model.activeWalk?.points.first == fix(950, last.time + 400))
    }

}
