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
    /// True while the phone is reasonably sure you're walking or running.
    private(set) var onFoot = false

    private let manager = CMMotionActivityManager()
    @ObservationIgnored private var started = false
    /// Called after each update, so always on can change how hard it works.
    @ObservationIgnored var onChange: (() -> Void)?

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
        // An uncertain sample mustn't wake GPS after a confident stationary answer.
        guard activity.confidence != .low else { return }
        still = activity.stationary && !activity.walking && !activity.running && activity.confidence != .low
        if activity.walking || activity.running {
            onWheels = false
            onFoot = true
        } else if (activity.cycling || activity.automotive), activity.confidence != .low {
            onWheels = true
            onFoot = false
        } else if activity.stationary {
            onFoot = false
        }
        // Stationary or unknown: keep the last answer. Sitting at the lights is still driving.
        onChange?()
    }

    // MARK: When you set off

    /// One stretch of the motion chip's history, for working out when you set off.
    struct Stretch {
        enum Kind { case onFoot, wheels, other }
        var start: Date
        var kind: Kind
    }

    /// How far back to look. Keeps a morning of pottering from becoming one long walk.
    static let setOffWindow: TimeInterval = 30 * 60
    /// Standing still for longer than this means you hadn't set off yet. Shorter is a
    /// road crossing or the dog having a sniff.
    static let longestPause: TimeInterval = 60

    /// When the on-foot stretch that's still going at `now` began, if there is one.
    nonisolated static func setOff(in stretches: [Stretch], now: Date) -> Date? {
        var found: Date?
        var end = now
        var pause: TimeInterval = 0
        for stretch in stretches.sorted(by: { $0.start < $1.start }).reversed() where stretch.start < now {
            switch stretch.kind {
            case .wheels:
                return found
            case .onFoot:
                found = stretch.start
                pause = 0
            case .other:
                pause += end.timeIntervalSince(stretch.start)
                if pause > longestPause { return found }
            }
            end = stretch.start
        }
        return found
    }

    /// When you set off on foot, from the chip's history. The chip keeps recording while the
    /// app's asleep, so this still works when iOS was slow to tell us you'd gone.
    func setOff(before now: Date) async -> Date? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: now.addingTimeInterval(-Self.setOffWindow), to: now, to: .main) { activities, _ in
                let stretches = (activities ?? []).map { activity -> Stretch in
                    let kind: Stretch.Kind
                    // Even an unsure "walking" counts here, or it would clip the start of the walk.
                    if activity.walking || activity.running { kind = .onFoot }
                    else if activity.confidence != .low, activity.cycling || activity.automotive { kind = .wheels }
                    else { kind = .other }
                    return Stretch(start: activity.startDate, kind: kind)
                }
                continuation.resume(returning: Self.setOff(in: stretches, now: now))
            }
        }
    }
}
