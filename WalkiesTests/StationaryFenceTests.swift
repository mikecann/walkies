import CoreLocation
import Testing
@testable import Walkies

struct StationaryFenceTests {
    private let home = Coordinate(lat: -33.65, lon: 115.35)

    /// A point this many metres north of home.
    private func north(_ metres: Double) -> Coordinate {
        Coordinate(lat: home.lat + metres / 111_195, lon: home.lon)
    }

    @Test func placesRightAwayWhenThereIsNoFenceAndNoWalk() {
        var fence = StationaryFence()
        #expect(fence.add(home, time: 0, accuracy: 10, stationary: false, walking: false) == home)
        #expect(fence.center == home)
    }

    @Test func waitsToSettleDuringAWalk() {
        var fence = StationaryFence()
        #expect(fence.add(home, time: 0, accuracy: 10, stationary: false, walking: true) == nil)
        #expect(fence.add(north(50), time: 30, accuracy: 10, stationary: false, walking: true) == nil)
        #expect(fence.add(north(100), time: 60, accuracy: 10, stationary: false, walking: true) == nil)
        #expect(fence.center == nil)
    }

    @Test func movesWhenYouStaySomewhereNewForAWhile() {
        var fence = StationaryFence(center: home)
        let cafe = north(800)
        #expect(fence.add(cafe, time: 0, accuracy: 10, stationary: false, walking: true) == nil)
        #expect(fence.add(north(810), time: 60, accuracy: 10, stationary: false, walking: true) == nil)
        #expect(fence.add(north(805), time: StationaryFence.settleTime, accuracy: 10, stationary: false, walking: true) == north(805))
        #expect(fence.center == north(805))
    }

    @Test func movesAsSoonAsIOSSaysYouHaveStopped() {
        var fence = StationaryFence(center: home)
        #expect(fence.add(north(800), time: 0, accuracy: 10, stationary: true, walking: true) == north(800))
    }

    @Test func leavesItWhereItIsWhenYouSettleInTheSameSpot() {
        var fence = StationaryFence(center: home)
        #expect(fence.add(north(10), time: 0, accuracy: 10, stationary: true, walking: false) == nil)
        #expect(fence.add(north(15), time: StationaryFence.settleTime * 3, accuracy: 10, stationary: false, walking: false) == nil)
        #expect(fence.center == home)
    }

    @Test func ignoresVagueFixes() {
        var fence = StationaryFence()
        #expect(fence.add(home, time: 0, accuracy: 200, stationary: true, walking: false) == nil)
        #expect(fence.add(home, time: 0, accuracy: -1, stationary: true, walking: false) == nil)
        #expect(fence.center == nil)
    }

    @Test func movingOnStartsTheClockAgain() {
        var fence = StationaryFence(center: home)
        #expect(fence.add(north(500), time: 0, accuracy: 10, stationary: false, walking: true) == nil)
        #expect(fence.add(north(600), time: StationaryFence.settleTime, accuracy: 10, stationary: false, walking: true) == nil)
        #expect(fence.add(north(600), time: StationaryFence.settleTime * 2, accuracy: 10, stationary: false, walking: true) == north(600))
    }

    @Test func resetForgetsTheFence() {
        var fence = StationaryFence(center: home)
        fence.reset()
        #expect(fence.center == nil)
        #expect(fence.add(north(300), time: 0, accuracy: 10, stationary: false, walking: false) == north(300))
    }
}

@MainActor
struct LocationTrackerFenceTests {
    private final class FakeFence: Geofence {
        var onExit: (() -> Void)?
        var onOpen: ((Coordinate?) -> Void)?
        var placed: [Coordinate] = []
        var removed = 0
        func open() {}
        func place(around center: Coordinate, radius: Double) { placed.append(center) }
        func remove() { removed += 1 }
    }

    private func fix(_ lat: Double, _ lon: Double, accuracy: Double = 10) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 10, timestamp: .now)
    }

    @Test func placesTheFenceWhereYouSettleAndRemovesItWhenTurnedOff() {
        let fake = FakeFence()
        let tracker = LocationTracker(geofence: fake)
        tracker.settle(at: fix(-33.65, 115.35), stationary: false)
        tracker.settle(at: fix(-33.65, 115.35), stationary: true)
        #expect(fake.placed == [Coordinate(lat: -33.65, lon: 115.35)])
        tracker.stopAlwaysOn()
        #expect(fake.removed == 1)
        tracker.settle(at: fix(-33.65, 115.35), stationary: false)
        #expect(fake.placed.count == 2)
    }

    @Test func keepsTheFenceFromLastTimeWhenItOpens() {
        let fake = FakeFence()
        let tracker = LocationTracker(geofence: fake)
        fake.onOpen?(Coordinate(lat: -33.65, lon: 115.35))
        tracker.settle(at: fix(-33.65, 115.35), stationary: true)
        #expect(fake.placed.isEmpty)
    }

    @Test func waitsWhileYouAreOnAWalk() {
        let fake = FakeFence()
        let tracker = LocationTracker(geofence: fake)
        tracker.isWalking = { true }
        tracker.settle(at: fix(-33.65, 115.35), stationary: false)
        #expect(fake.placed.isEmpty)
    }
}
