import CoreLocation
import Observation
import os

/// GPS for walks. Keeps going with the phone locked in your pocket, using
/// "while using the app" permission plus a background activity session, or
/// runs all the time in always-on mode.
///
/// iOS shows a blue location arrow for as long as the session's held. With Always
/// permission, always on only holds it while the app's open or a walk it started on screen
/// is going, so the arrow isn't up all day at home. iOS only hands out a session while the
/// app's on screen, and live updates stall in the pocket without one (Mike's walk to
/// Busselton Jetty was cut off at 81 m on 3 Nov). So a walk that starts with the app in
/// your pocket uses the pocket watch instead: plain CLLocationManager updates at full
/// accuracy, which Always permission lets the app start and keep in the background with
/// no session. A tap-to-start question was tried first (#82) and lost walks when the
/// notification went unseen (#89); Mike wants walks picked up with no tap (13 Nov 2026).
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
    /// The app's open, on any tab: the only time iOS will start a background session.
    @ObservationIgnored var isInForeground: () -> Bool = { false }
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
    /// The pocket watch's GPS updates are running.
    @ObservationIgnored private var pocketOn = false
    /// Fixes the pocket watch has had this run, for the trace.
    @ObservationIgnored private var pocketFixes = 0

    /// How hard always on works.
    enum Watch: Equatable {
        /// Live updates: GPS while you're moving.
        case live
        /// Wi-Fi and cell towers, every 25 m or so: enough to notice you've got out of the car.
        case light
        /// No GPS, just cell-tower updates we throw away. They keep the app running so the
        /// motion chip can tell us you've set off. The fence is the backstop if iOS kills it.
        case idle
        /// GPS at full accuracy through plain CLLocationManager updates, for when live
        /// updates would want a session the app can't get from the background.
        case pocket
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

    /// Live updates stall in the background without a session, so the pocket watch does
    /// the same job. The light watch used to stand in, but its 100 m fixes are too rough to
    /// record (the tracer wants 30 m), so walks on 10 Nov saved nothing.
    nonisolated static func withoutSession(_ watch: Watch) -> Watch {
        watch == .live ? .pocket : watch
    }

    private var insideFence: Bool { fence.center != nil && !outside }

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
        settleTries = 0
        if stationary { lookToSettle() } else { settleCheck?.cancel() }
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
        defer { traceState() }
        var watch = watch
        refreshSession(live: watch == .live)
        if watch == .live, backgroundSession == nil {
            watch = Self.withoutSession(watch)
        }
        if watch == .live {
            if liveTask == nil { startLiveUpdates() }
        } else {
            liveTask?.cancel()
            liveTask = nil
        }
        // Stops first: these share the manager, so stopping second would undo the start.
        if watch != .light { stopLight() }
        if watch != .idle { stopIdle() }
        if watch != .pocket { stopPocket() }
        if watch == .light { startLight() }
        if watch == .idle { startIdle() }
        if watch == .pocket { startPocket() }
    }

    /// With Always permission the session's only for live updates that started with the app
    /// open, held until you've settled again so a coffee stop doesn't drop to the pocket watch.
    /// While using the app, always on can't run in the background without one.
    /// Any walk counts, not just a confirmed one: on 7 Nov Mike opened the app, set off and
    /// put the phone away before the walk was confirmed, and letting go then (still inside
    /// the fence) left him walking out with no session and no question yet.
    nonisolated static func wantsSession(holdAllDay: Bool, inForeground: Bool, live: Bool,
                                         insideFence: Bool, walking: Bool) -> Bool {
        holdAllDay || inForeground || live || !insideFence || walking
    }

    private func refreshSession(live: Bool) {
        let holdAllDay = !hasAlwaysPermission
        let wanted = Self.wantsSession(holdAllDay: holdAllDay, inForeground: isInForeground(), live: live,
                                       insideFence: insideFence, walking: isWalking())
        if !wanted {
            backgroundSession?.invalidate()
            backgroundSession = nil
        } else if backgroundSession == nil, !hasAlwaysPermission || isInForeground() {
            // With Always permission, one made in the background (iOS relaunching the app)
            // wouldn't keep live updates going, and would hide that there's no real one.
            backgroundSession = CLBackgroundActivitySession()
        }
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

    @ObservationIgnored private var settleCheck: Task<Void, Never>?
    @ObservationIgnored private var settleTries = 0

    /// The light watch only sends a fix every 25 m, and only to 100 m, so a phone that's
    /// stopped outside the fence never got one good enough to settle (50 m), which kept the
    /// session, and the blue arrow, after a walk on 5 Nov 2026. So when you go still out
    /// there it asks for a precise fix for a minute, and tries again every five minutes,
    /// three times at most until you move again.
    private func lookToSettle() {
        guard stationary, outside, lightOn, settleTries < 3 else { return }
        settleTries += 1
        stopLight()
        startLight()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        settleCheck?.cancel()
        settleCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            if self.lightOn { self.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
            try? await Task.sleep(for: .seconds(240))
            guard !Task.isCancelled else { return }
            self.lookToSettle()
        }
    }

    /// Like the manual walk's GPS (start()), but with no session, so no blue arrow.
    private func startPocket() {
        guard !pocketOn else { return }
        pocketOn = true
        pocketFixes = 0
        TrackerTrace.write("pocket GPS on")
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    private func stopPocket() {
        guard pocketOn else { return }
        pocketOn = false
        TrackerTrace.write("pocket GPS off after \(pocketFixes) fixes")
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
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
        TrackerTrace.write("always on started")
        // Left on by a manual walk earlier in this launch, it'd show the arrow all day.
        manager.showsBackgroundLocationIndicator = false
        manager.startMonitoringSignificantLocationChanges()
        geofence.open()
        refreshWatch()
    }

    func stopAlwaysOn() {
        alwaysOnRunning = false
        outside = false
        settleCheck?.cancel()
        settleCheck = nil
        liveTask?.cancel()
        liveTask = nil
        walkingTimer?.cancel()
        walkingTimer = nil
        walkingForAWhile = false
        stopLight()
        stopIdle()
        stopPocket()
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
                TrackerTrace.write("settled back where the fence is")
                refreshWatch()
            }
            return
        }
        outside = false
        TrackerTrace.write("settled somewhere new")
        geofence.place(around: center, radius: StationaryFence.radius)
        refreshWatch()
    }

    /// You've left where you settled. Live updates should pick up again by themselves,
    /// but start them afresh unless they're plainly already coming in.
    private func leftFence() {
        guard alwaysOnRunning else { return }
        TrackerTrace.write("left the fence")
        outside = true
        stationary = false
        pausedAt = nil
        guard liveTask != nil, backgroundSession != nil else { return refreshWatch() }
        if let lastLive, Date.now.timeIntervalSince(lastLive) < 10 { return }
        startLiveUpdates()
    }

    @ObservationIgnored private var lastTrace = ""

    /// Only when something that decides the session or the question changes.
    private func traceState() {
        let line = "watch=\(watch) session=\(backgroundSession != nil) fence=\(fence.center != nil) outside=\(outside) "
            + "walk=\(isWalking()) confirmed=\(isOnConfirmedWalk()) still=\(stationary) foot=\(isOnFoot()) wheels=\(isOnWheels()) "
            + "fg=\(isInForeground()) always=\(hasAlwaysPermission) "
            + "light=\(lightOn) idle=\(idleOn) pocket=\(pocketOn) live=\(liveTask != nil)"
        guard line != lastTrace else { return }
        lastTrace = line
        TrackerTrace.write(line)
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
                    // Fresh fixes only: restarting the watch can hand back a cached one from
                    // home, which would look like you'd settled back there (Codex, 8 Nov).
                    if lightOn || pocketOn, !isOnWheels(), location.timestamp.timeIntervalSinceNow > -10 {
                        settle(at: location, stationary: isStill())
                    }
                    if pocketOn {
                        pocketFixes += 1
                        // Proof on the trace that the GPS kept going in the pocket.
                        if pocketFixes % 50 == 0 { TrackerTrace.write("pocket GPS \(pocketFixes) fixes") }
                    }
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
            refreshWatch()
            onAuthorizationChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Self.log.error("Location error: \(error)")
    }
}

/// A short log of always on's decisions in Library/Caches, for working out what happened
/// on a real walk: Release builds don't keep the app's os_log lines, and reading the
/// phone's own log needs root. Copy it off with `xcrun devicectl device copy from`.
/// TEMPORARY while the tap-to-start walk question is being tried (Nov 2026).
enum TrackerTrace {
    /// Every always-on fix, in its own file so the decisions above stay readable. Walks
    /// on 12 Nov 2026 were thrown away as never confirmed and there was no route to see why.
    nonisolated static func fix(_ point: TrackPoint, walk: Bool, pending: Bool) {
        let line = String(format: "%.0f %.6f %.6f acc=%.0f spd=%.1f wheels=%@ still=%@ walk=%@ pending=%@",
                          point.time, point.lat, point.lon, point.accuracy, point.speed ?? -1,
                          "\(point.wheels ?? false)", "\(point.still ?? false)", "\(walk)", "\(pending)")
        append(line + "\n", to: "tracker-fixes.log", limit: 2_000_000)
    }

    /// Why an automatic walk ended and whether it was kept. A dropped one's route goes to
    /// Caches/dropped-walks, since nothing else keeps it.
    nonisolated static func walkEnded(_ walk: Walk, kept: Bool, pending: Bool, reason: String, displacement: Double) {
        let minutes = (walk.points.last.map { $0.time } ?? walk.startedAt.timeIntervalSince1970) - walk.startedAt.timeIntervalSince1970
        write("auto walk ended (\(reason)): \(kept ? "kept" : "dropped") pending=\(pending) points=\(walk.points.count) "
              + "farthest=\(Int(displacement)) m distance=\(Int(walk.distance)) m length=\(Int(minutes / 60)) min")
        guard !kept, !walk.points.isEmpty,
              let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "dropped-walks") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(walk) {
            try? data.write(to: dir.appending(path: "\(walk.id).json"))
        }
    }

    nonisolated static func write(_ text: String) {
        append("\(Date.now.formatted(date: .numeric, time: .standard)) \(text)\n", to: "tracker-trace.log", limit: 300_000)
    }

    private nonisolated static func append(_ line: String, to name: String, limit: Int) {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appending(path: name)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > limit {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
