import CoreMotion
import Observation
import UIKit

/// Reads the motion chip's saved counts. GPS and accelerometer sampling aren't needed.
@Observable
final class StepCounter {
    private(set) var live: Int?
    private(set) var today: Int?
    private(set) var needsMotionAccess = false
    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private var liveStart: Date?
    @ObservationIgnored private var revision = 0

    var available: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeSteps") { return true }
        #endif
        let status = CMPedometer.authorizationStatus()
        return CMPedometer.isStepCountingAvailable() && status == .authorized
    }

    func updateLive(from start: Date?) {
        guard start != liveStart else { return }
        pedometer.stopUpdates()
        liveStart = start
        live = nil
        guard let start, available else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeSteps") { live = 1234; return }
        #endif
        pedometer.startUpdates(from: start) { [weak self] data, error in
            let count = error == nil ? data?.numberOfSteps.intValue : nil
            Task { @MainActor in
                guard let self, self.liveStart == start else { return }
                self.live = count
            }
        }
    }

    func clear() {
        revision += 1
        updateLive(from: nil)
        today = nil
    }

    func refreshToday(enabled: Bool) async {
        let status = CMPedometer.authorizationStatus()
        needsMotionAccess = status == .denied || status == .restricted
        revision += 1
        let request = revision
        guard enabled, available else { today = nil; return }
        let now = Date.now
        let count = await count(from: Calendar.current.startOfDay(for: now), to: now)
        guard request == revision else { return }
        today = count
    }

    /// Always completes within two seconds, including when Core Motion never replies.
    func count(from start: Date, to end: Date) async -> Int? {
        guard available, end > start else { return nil }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeSteps") { return 1234 }
        #endif
        let background = UIApplication.shared.beginBackgroundTask(withName: "Finish step count")
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        return await withCheckedContinuation { continuation in
            var resolved = false
            let finish: (Int?) -> Void = { count in
                guard !resolved else { return }
                resolved = true
                continuation.resume(returning: count)
            }
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                let count = error == nil ? data?.numberOfSteps.intValue : nil
                Task { @MainActor in finish(count) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                finish(nil)
            }
        }
    }
}
