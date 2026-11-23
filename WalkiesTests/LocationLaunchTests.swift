import CoreLocation
import CoreMotion
import Foundation
import Testing
@testable import Walkies

@MainActor
struct LocationLaunchTests {
    private let home = Coordinate(lat: -33.65, lon: 115.35)

    private func fix(_ metresNorth: Double, at date: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: home.lat + metresNorth / 111_195, longitude: home.lon),
                   altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: date)
    }

    private func tracker(_ fence: TrackingTestFence, _ driver: TrackingTestDriver,
                         now: @escaping () -> Date = { .now }) -> LocationTracker {
        LocationTracker(geofence: fence, manager: driver, makeBackgroundSession: { TrackingTestSession() },
                        makeAlwaysSession: { TrackingTestSession() }, now: now)
    }

    @Test func aBufferedHomeExitSurvivesSavedStateLoadingAndStartsPocketGPS() {
        launchWithBufferedExit(stop: false)
    }

    @Test func aBufferedStopExitSurvivesSavedStateLoadingAndStartsPocketGPS() {
        launchWithBufferedExit(stop: true)
    }

    private func launchWithBufferedExit(stop: Bool) {
        let fence = TrackingTestFence()
        let driver = TrackingTestDriver()
        let tracker = tracker(fence, driver)
        defer { tracker.stopAlwaysOn() }
        var loaded = false
        var unlock: (() -> Void)?
        var order: [String] = []
        fence.opened = {
            guard fence.opens == 1 else { return }
            order.append("fence")
            fence.onOpen?(home)
            if stop { fence.onStopExit?() } else { fence.onExit?() }
        }
        let startup = AppStartup(savedDataReadable: { false }, openFence: { tracker.openFence() }, observeUnlock: {
            unlock = $0
            return {}
        }, loadSaved: {
            order.append("load")
            loaded = true
        }, start: {
            #expect(loaded)
            order.append("start")
            tracker.startAlwaysOn()
        })
        startup.launch()
        #expect(driver.starts == 0)
        unlock?()
        #expect(order == ["fence", "load", "start"])
        #expect(driver.significantStarts == 1)
        #expect(driver.starts > 0)
        #expect(driver.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(driver.distanceFilter == kCLDistanceFilterNone)
        #expect(driver.allowsBackgroundLocationUpdates)
        #expect(!driver.showsBackgroundLocationIndicator)
        #expect(tracker.watch == .live)
        tracker.settle(at: fix(0, at: .now), stationary: true)
        #expect(fence.stopsRemoved == 1)
        #expect(tracker.watch == .idle)
    }

    @Test func stopExitBeforeTheHomeFenceRestoresCannotBecomeAnIdleWatch() {
        for startsBeforeRestore in [false, true] {
            let fence = TrackingTestFence()
            let driver = TrackingTestDriver()
            let tracker = tracker(fence, driver)
            defer { tracker.stopAlwaysOn() }
            fence.onStopExit?()
            if startsBeforeRestore { tracker.startAlwaysOn() }
            fence.onOpen?(home)
            if !startsBeforeRestore { tracker.startAlwaysOn() }
            #expect(tracker.watch == .live)
            #expect(driver.distanceFilter == kCLDistanceFilterNone)
            #expect(driver.allowsBackgroundLocationUpdates)
        }
    }

    @Test func homeExitBeforeTheHomeFenceRestoresAlsoKeepsTheWatchAwake() {
        let fence = TrackingTestFence()
        let driver = TrackingTestDriver()
        let tracker = tracker(fence, driver)
        defer { tracker.stopAlwaysOn() }
        fence.onExit?()
        tracker.startAlwaysOn()
        fence.onOpen?(home)
        #expect(tracker.watch == .live)
        #expect(driver.distanceFilter == kCLDistanceFilterNone)
    }

    @Test func alwaysOnStartsAndStopsEachServiceOnce() {
        let fence = TrackingTestFence()
        let driver = TrackingTestDriver()
        let session = TrackingTestSession()
        var sessions = 0
        let tracker = LocationTracker(geofence: fence, manager: driver, makeBackgroundSession: { TrackingTestSession() },
                                      makeAlwaysSession: { sessions += 1; return session })
        fence.onOpen?(home)
        tracker.startAlwaysOn()
        tracker.startAlwaysOn()
        #expect(sessions == 1)
        #expect(driver.significantStarts == 1)
        #expect(driver.desiredAccuracy == kCLLocationAccuracyThreeKilometers)
        #expect(driver.distanceFilter == 1000)
        tracker.stopAlwaysOn()
        #expect(session.invalidations == 1)
        #expect(driver.significantStops == 1)
        #expect(!driver.allowsBackgroundLocationUpdates)
        #expect(fence.removed == 1)
    }

    @Test func returningHomeResetsTheThirtyMinuteSettlingClockEvenWhileOnWheels() {
        let fence = TrackingTestFence()
        let driver = TrackingTestDriver()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let tracker = tracker(fence, driver, now: { now })
        defer { tracker.stopAlwaysOn() }
        tracker.isOnWheels = { true }
        fence.onOpen?(home)
        tracker.startAlwaysOn()
        fence.onExit?()
        tracker.settle(at: fix(800, at: now), stationary: true)
        now.addTimeInterval(29 * 60)
        tracker.settle(at: fix(800, at: now), stationary: true)
        #expect(fence.placed.isEmpty)
        tracker.settle(at: fix(20, at: now), stationary: true)
        #expect(tracker.watch == .idle)
        fence.onExit?()
        now.addTimeInterval(60)
        tracker.settle(at: fix(800, at: now), stationary: true)
        now.addTimeInterval(29 * 60 + 59)
        tracker.settle(at: fix(800, at: now), stationary: true)
        #expect(fence.placed.isEmpty)
        now.addTimeInterval(1)
        tracker.settle(at: fix(800, at: now), stationary: true)
        #expect(fence.placed.count == 1)
        #expect(fence.placed[0].distance(to: Coordinate(fix(800, at: now).coordinate)) < 1)
    }

    @Test func restoredHomeWinsAgainstEarlyFixesAndWalksAtTheThirtyMinuteBoundary() {
        for restoreFirst in [false, true] {
            let fence = TrackingTestFence()
            let driver = TrackingTestDriver()
            var now = Date(timeIntervalSince1970: 1_000_000)
            let tracker = tracker(fence, driver, now: { now })
            var walking = true
            tracker.isWalking = { walking }
            if restoreFirst { fence.onOpen?(home) }
            tracker.settle(at: fix(800, at: now), stationary: true)
            if !restoreFirst {
                fence.onOpen?(home)
                tracker.settle(at: fix(800, at: now), stationary: true)
            }
            now.addTimeInterval(LocationTracker.moveFenceAfter)
            tracker.settle(at: fix(800, at: now), stationary: true)
            #expect(fence.placed.isEmpty)
            walking = false
            tracker.settle(at: fix(800, at: now), stationary: true)
            #expect(fence.placed.count == 1)
        }
    }

    @Test func walkingForThirtySecondsActuallyChangesTheManagerConfiguration() async {
        let clock = WalkingClock()
        let fence = TrackingTestFence()
        let driver = TrackingTestDriver()
        let tracker = LocationTracker(geofence: fence, manager: driver,
                                      makeBackgroundSession: { TrackingTestSession() },
                                      makeAlwaysSession: { TrackingTestSession() }, sleep: { try await clock.sleep($0) })
        defer { tracker.stopAlwaysOn() }
        var onFoot = true
        tracker.isOnFoot = { onFoot }
        fence.onOpen?(home)
        tracker.startAlwaysOn()
        tracker.motionChanged()
        await clock.waitForSleep()
        clock.advance(by: .seconds(29))
        #expect(tracker.watch == .idle)
        #expect(driver.desiredAccuracy == kCLLocationAccuracyThreeKilometers)
        clock.advance(by: .seconds(1))
        await Task { @MainActor in }.value
        #expect(tracker.watch == .live)
        #expect(driver.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(driver.distanceFilter == kCLDistanceFilterNone)
        onFoot = false
        tracker.motionChanged()
        #expect(tracker.watch == .idle)
    }

    @Test func aStationaryAnswerCancelsTheWalkingWakeTimer() async {
        let clock = WalkingClock()
        let fence = TrackingTestFence()
        let driver = TrackingTestDriver()
        let tracker = LocationTracker(geofence: fence, manager: driver,
                                      makeBackgroundSession: { TrackingTestSession() },
                                      makeAlwaysSession: { TrackingTestSession() }, sleep: { try await clock.sleep($0) })
        defer { tracker.stopAlwaysOn() }
        var onFoot = true
        tracker.isOnFoot = { onFoot }
        fence.onOpen?(home)
        tracker.startAlwaysOn()
        tracker.motionChanged()
        await clock.waitForSleep()
        clock.advance(by: .seconds(29))
        onFoot = false
        tracker.isStill = { true }
        tracker.motionChanged()
        clock.advance(by: .seconds(1))
        await Task { @MainActor in }.value
        #expect(tracker.watch == .idle)
        #expect(driver.desiredAccuracy == kCLLocationAccuracyThreeKilometers)
    }

    @Test func withoutMotionPermissionAFenceExitStillStartsPrecisePocketGPS() {
        let fence = TrackingTestFence()
        let driver = TrackingTestDriver()
        let tracker = tracker(fence, driver)
        defer { tracker.stopAlwaysOn() }
        fence.onOpen?(home)
        tracker.startAlwaysOn()
        #expect(tracker.watch == .idle)
        fence.onExit?()
        #expect(tracker.watch == .live)
        #expect(driver.distanceFilter == kCLDistanceFilterNone)
        #expect(driver.desiredAccuracy == kCLLocationAccuracyBest)
    }
}

@MainActor
private final class WalkingClock {
    private var time: Duration = .zero
    private var sleeps: [(at: Duration, continuation: CheckedContinuation<Void, Error>)] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleeps.append((time + duration, continuation))
            waiting?.resume()
            waiting = nil
        }
    }

    func waitForSleep() async {
        if !sleeps.isEmpty { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func advance(by duration: Duration) {
        time += duration
        let ready = sleeps.filter { $0.at <= time }
        sleeps.removeAll { $0.at <= time }
        for sleep in ready { sleep.continuation.resume() }
    }
}

@MainActor
struct MotionClassificationTests {
    @Test func lowConfidenceDoesNotWakeGPSOrClearAConfidentRide() {
        let motion = MotionMonitor()
        motion.update(confidence: .high, stationary: false, walking: false, running: false, cycling: false, automotive: true)
        motion.update(confidence: .high, stationary: true, walking: false, running: false, cycling: false, automotive: false)
        #expect(motion.onWheels)
        #expect(motion.still)
        motion.update(confidence: .low, stationary: false, walking: true, running: false, cycling: false, automotive: false)
        #expect(motion.onWheels)
        #expect(motion.still)
        #expect(!motion.onFoot)
        motion.update(confidence: .medium, stationary: true, walking: true, running: false, cycling: false, automotive: false)
        #expect(!motion.onWheels)
        #expect(!motion.still)
        #expect(motion.onFoot)
    }

    @Test func unknownSamplesKeepWheelsUntilAConfidentOnFootClassification() {
        let motion = MotionMonitor()
        motion.update(confidence: .medium, stationary: false, walking: false, running: false, cycling: true, automotive: false)
        motion.update(confidence: .high, stationary: false, walking: false, running: false, cycling: false, automotive: false)
        #expect(motion.onWheels)
        #expect(!motion.onFoot)
        motion.update(confidence: .high, stationary: false, walking: false, running: true, cycling: false, automotive: false)
        #expect(!motion.onWheels)
        #expect(motion.onFoot)
    }
}
