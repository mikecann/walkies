import CoreMotion
import Observation

/// Asks the phone's motion chip (the one that counts your steps) whether you're on
/// foot, on a bike or in a car, so a slow ride doesn't sneak under the speed limit.
@Observable
final class MotionMonitor {
    /// True while the phone is reasonably sure you're cycling or in a vehicle.
    private(set) var onWheels = false
    /// True while the phone is reasonably sure you're not moving at all.
    private(set) var still = false

    private let manager = CMMotionActivityManager()
    @ObservationIgnored private var started = false

    func start() {
        guard !started, CMMotionActivityManager.isActivityAvailable() else { return }
        started = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated {
                self?.update(with: activity)
            }
        }
    }

    private func update(with activity: CMMotionActivity) {
        still = activity.stationary && !activity.walking && !activity.running && activity.confidence != .low
        if activity.walking || activity.running {
            onWheels = false
        } else if (activity.cycling || activity.automotive), activity.confidence != .low {
            onWheels = true
        }
        // Stationary or unknown: keep the last answer. Sitting at the lights is still driving.
    }
}
