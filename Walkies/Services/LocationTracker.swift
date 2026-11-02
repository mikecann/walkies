import CoreLocation
import Observation
import os

/// GPS for walks. Keeps going with the phone locked in your pocket, using
/// "while using the app" permission plus a background activity session, or
/// runs all the time in always-on mode.
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    nonisolated private static let log = Logger(subsystem: "com.mikecann.walkies", category: "location")

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @ObservationIgnored var onLocation: ((CLLocation) -> Void)?
    @ObservationIgnored var onAuthorizationChange: (() -> Void)?
    @ObservationIgnored var isWalking: () -> Bool = { false }
    /// Manual walks keep full accuracy even through a stop.
    @ObservationIgnored var isOnManualWalk: () -> Bool = { false }
    /// An automatic walk that's past pending, including its resumable pause gap.
    @ObservationIgnored var isOnConfirmedWalk: () -> Bool = { false }
    /// The app's on screen, for the you-are-here dot.
    @ObservationIgnored var isOnScreen: () -> Bool = { false }
    /// The motion chip's answers (MotionMonitor).
    @ObservationIgnored var isOnWheels: () -> Bool = { false }
    @ObservationIgnored var isStill: () -> Bool = { false }
    @ObservationIgnored var isOnFoot: () -> Bool = { false }

    private let manager = CLLocationManager()
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    init(geofence: any Geofence = MonitorFence.shared) {
        self.geofence = geofence
        super.init()
        geofence.onOpen = { [weak self] center in
            guard let self, self.fence.center == nil else { return }
            self.fence.center = center
            self.refreshWatch()
        }
        geofence.onExit = { [weak self] in self?.leftFence() }
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func requestPermissionIfNeeded() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        stopLight()
        stopIdle()
        backgroundSession = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    // MARK: Always on

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private let geofence: any Geofence
    @ObservationIgnored private var fence = StationaryFence()
    @ObservationIgnored private var lastLive: Date?
    @ObservationIgnored private var alwaysOnRunning = false
    /// You've left the fence and haven't settled anywhere since.
    @ObservationIgnored private var outside = false
    @ObservationIgnored private var lightOn = false
    /// The idle watch's cheap location updates are running.
    @ObservationIgnored private var idleOn = false
    /// The chip has said you're on foot for `walkingCheck` without a break.
    @ObservationIgnored private var walkingForAWhile = false
    @ObservationIgnored private var walkingTimer: Task<Void, Never>?
    @ObservationIgnored private var stationary = false
    @ObservationIgnored private var pausedAt: Coordinate?
    @ObservationIgnored private var lastLocation: Coordinate?

    /// How hard always on works.
    enum Watch: Equatable {
        /// Live updates: GPS while you're moving.
        case live
        /// Wi-Fi and cell towers, every 25 m or so: enough to notice you've got out of the car.
        case light
        /// No GPS, just cell-tower updates we throw away. They keep the app running so the
        /// motion chip can tell us you've set off. The fence is the backstop if iOS kills it.
        case idle
    }

    /// How long the chip has to say you're on foot before a walk from home gets the GPS.
    /// Long enough that crossing the kitchen doesn't count.
    static let walkingCheck: Duration = .seconds(30)

    /// Always on used to run live updates whenever you were moving, which meant the GPS ran
    /// for whole drives and every time you walked round the house (28 Oct 2026). Relying on the
    /// fence alone then missed the start of walks: 270 m on 29 and 30 Oct, 10 minutes on 2 Nov,
    /// because iOS takes its time reporting an exit. So the chip wakes the GPS inside the fence.
    nonisolated static func watch(confirmedWalk: Bool, onScreen: Bool, onWheels: Bool, insideFence: Bool,
                                 manualWalk: Bool = false, stationary: Bool = false,
                                 walkingForAWhile: Bool = false) -> Watch {
        if manualWalk || onScreen { return .live }
        if onWheels { return insideFence && !confirmedWalk ? .idle : .light }
        // Keep the walk open, but use Wi-Fi/cell fixes until motion or displacement
        // says it's moving again. This also works when Core Motion isn't available.
        if stationary { return confirmedWalk || !insideFence ? .light : .idle }
        if confirmedWalk { return .live }
        if insideFence { return walkingForAWhile ? .live : .idle }
        return .live
    }

    var watch: Watch {
        Self.watch(confirmedWalk: isOnConfirmedWalk(), onScreen: isOnScreen(), onWheels: isOnWheels(),
                   insideFence: fence.center != nil && !outside, manualWalk: isOnManualWalk(), stationary: stationary,
                   walkingForAWhile: walkingForAWhile)
    }

    /// A fence exit can override the chip's old stationary answer until a fresh update.
    func motionChanged() {
        stationary = isStill()
        if stationary { pausedAt = pausedAt ?? lastLocation } else { pausedAt = nil }
        noteWalking()
        refreshWatch()
    }

    private func noteWalking() {
        guard isOnFoot() else {
            walkingTimer?.cancel()
            walkingTimer = nil
            walkingForAWhile = false
            return
        }
        guard walkingTimer == nil, !walkingForAWhile else { return }
        walkingTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.walkingCheck)
            guard let self, !Task.isCancelled else { return }
            self.walkingTimer = nil
            self.walkingForAWhile = true
            self.refreshWatch()
        }
    }

    private func noteMovement(_ location: CLLocation) {
        guard stationary, let pausedAt, location.timestamp.timeIntervalSinceNow > -10,
              location.horizontalAccuracy >= 0 else { return }
        if pausedAt.distance(to: Coordinate(location.coordinate)) - location.horizontalAccuracy > StationaryFence.settleRadius {
            stationary = false
            self.pausedAt = nil
        }
    }

    /// Call when anything `watch` depends on changes.
    func refreshWatch() {
        guard alwaysOnRunning else { return }
        let watch = watch
        if watch == .live {
            if liveTask == nil { startLiveUpdates() }
        } else {
            liveTask?.cancel()
            liveTask = nil
        }
        // Stops first: light and idle share the manager, so stopping second would undo the start.
        if watch != .light { stopLight() }
        if watch != .idle { stopIdle() }
        if watch == .light { startLight() }
        if watch == .idle { startIdle() }
    }

    private func startIdle() {
        guard !idleOn else { return }
        idleOn = true
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1000
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    private func stopIdle() {
        guard idleOn else { return }
        idleOn = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    private func startLight() {
        guard !lightOn else { return }
        lightOn = true
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    private func stopLight() {
        guard lightOn else { return }
        lightOn = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    /// A fix plainly outside the fence (even the near edge of its accuracy circle) means
    /// you've left, even if the fence hasn't said so yet.
    private func noteOutside(_ location: CLLocation) {
        guard !outside, let center = fence.center else { return }
        if center.distance(to: Coordinate(location.coordinate)) - max(location.horizontalAccuracy, 0) > StationaryFence.radius {
            outside = true
        }
    }

    var hasAlwaysPermission: Bool { authorization == .authorizedAlways }

    /// From "not asked yet" this shows the usual prompt. From "while using the app" it
    /// offers the upgrade to Always, which iOS only shows once; after that it's Settings.
    func requestAlwaysPermission() {
        manager.requestAlwaysAuthorization()
    }

    /// Tracking without pressing Start walk. Live updates pause by themselves while
    /// you're sitting still and pick up again when you move. If the app's been closed,
    /// the stationary fence relaunches it in the background once you leave where you
    /// settled. Significant-change monitoring is the backstop for when there's no fence.
    func startAlwaysOn() {
        guard !alwaysOnRunning else { return }
        alwaysOnRunning = true
        backgroundSession = CLBackgroundActivitySession()
        manager.startMonitoringSignificantLocationChanges()
        geofence.open()
        refreshWatch()
    }

    func stopAlwaysOn() {
        alwaysOnRunning = false
        outside = false
        liveTask?.cancel()
        liveTask = nil
        walkingTimer?.cancel()
        walkingTimer = nil
        walkingForAWhile = false
        stopLight()
        stopIdle()
        manager.stopMonitoringSignificantLocationChanges()
        backgroundSession?.invalidate()
        backgroundSession = nil
        removeFence()
    }

    /// Opens the stationary fence at launch, so an exit that relaunched the app arrives.
    func openFence() {
        geofence.open()
    }

    func removeFence() {
        fence.reset()
        geofence.remove()
    }

    private func startLiveUpdates() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            var last: CLLocation?
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    guard let self, !Task.isCancelled else { return }
                    last = update.location ?? last
                    self.lastLive = update.stationary ? nil : .now
                    self.stationary = update.stationary
                    if let location = update.location {
                        self.lastLocation = Coordinate(location.coordinate)
                        if update.stationary { self.pausedAt = Coordinate(location.coordinate) }
                        self.noteOutside(location)
                        self.onLocation?(location)
                    }
                    if let last {
                        if update.stationary { self.pausedAt = Coordinate(last.coordinate) }
                        self.settle(at: last, stationary: update.stationary)
                    }
                    self.refreshWatch()
                }
            } catch {
                Self.log.error("Live updates stopped: \(error)")
            }
        }
    }

    /// Moves the stationary fence when this fix means you've settled somewhere new.
    func settle(at location: CLLocation, stationary: Bool) {
        // Not a cached fix from wherever you were when updates started.
        guard stationary || location.timestamp.timeIntervalSinceNow > -10 else { return }
        let point = Coordinate(location.coordinate)
        guard let center = fence.add(point, time: location.timestamp.timeIntervalSince1970, accuracy: location.horizontalAccuracy, stationary: stationary, walking: isWalking()) else {
            // Back where you were (home after a walk, say): inside again, though the fence stays put.
            if fence.settledInPlace, outside {
                outside = false
                refreshWatch()
            }
            return
        }
        outside = false
        geofence.place(around: center, radius: StationaryFence.radius)
        refreshWatch()
    }

    /// You've left where you settled. Live updates should pick up again by themselves,
    /// but start them afresh unless they're plainly already coming in.
    private func leftFence() {
        guard alwaysOnRunning else { return }
        outside = true
        stationary = false
        pausedAt = nil
        guard liveTask != nil else { return refreshWatch() }
        if let lastLive, Date.now.timeIntervalSince(lastLive) < 10 { return }
        startLiveUpdates()
    }

    // The manager was made on the main thread, so its callbacks arrive there too.

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for location in locations {
                // Only there to keep the app running, and far too vague to record. A
                // significant-change fix can still show you've gone, if it's clear enough.
                if idleOn {
                    noteOutside(location)
                    continue
                }
                // Light watch and significant-change fixes, while always on.
                if alwaysOnRunning {
                    noteOutside(location)
                    noteMovement(location)
                    if stationary, pausedAt == nil { pausedAt = Coordinate(location.coordinate) }
                    lastLocation = Coordinate(location.coordinate)
                    // Not in a car: stopping at the lights isn't settling somewhere.
                    if lightOn, !isOnWheels() { settle(at: location, stationary: isStill()) }
                }
                onLocation?(location)
            }
            refreshWatch()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            onAuthorizationChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Self.log.error("Location error: \(error)")
    }
}
