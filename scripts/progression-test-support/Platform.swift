// Only the OS services are replaced. AppModel, Store, SyncEngine and HTTP client
// below this boundary are the same files compiled into the iPhone app.
@_exported import SwiftUI
import CoreLocation
import Foundation

final class LocationTracker {
    var authorization: CLAuthorizationStatus = .authorizedAlways
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorizationChange: (() -> Void)?
    var isWalking: () -> Bool = { false }
    var hasAlwaysPermission = true
    func removeFence() {}
    func requestPermissionIfNeeded() {}
    func requestAlwaysPermission() {}
    func start() {}
    func stop() {}
    func startAlwaysOn() {}
    func stopAlwaysOn() {}
    func refreshWatch() {}
    func motionChanged() {}
    // Always on asks these of AppModel; it sets them, the stub never calls them.
    var isOnManualWalk: () -> Bool = { false }
    var isOnConfirmedWalk: () -> Bool = { false }
    var isOnScreen: () -> Bool = { false }
    var isInForeground: () -> Bool = { false }
    var askToStartWalk: () -> Void = {}
    var withdrawWalkQuestion: () -> Void = {}
    var canAskToStartWalk: () -> Bool = { false }
    var isOnWheels: () -> Bool = { false }
    var isStill: () -> Bool = { false }
    var isOnFoot: () -> Bool = { false }
}
final class MotionMonitor {
    static let canTell = false
    var onWheels = false
    var still = false
    var onFoot = false
    var onChange: (() -> Void)?
    func start() {}
    func setOff(before now: Date) async -> Date? { nil }
}
final class StepCounter {
    func updateLive(from: Date?) {}
    func clear() {}
    func refreshToday(enabled: Bool) async {}
    func count(from: Date, to: Date) async -> Int? { nil }
}
enum Notifier {
    static let allowed = false
    static func requestPermission() {}
    static func refreshAllowed() async {}
    static func stickersFound(_ entries: [LoreEntry]) {}
    static func askToStartWalk() {}
    static func withdrawWalkQuestion() {}
}
final class Account {
    var isSignedIn = false
    var isGuest = false
    var userId: String?
    func client() async -> ConvexClient? { nil }
}
// App-only theme values used by the real cloud renderer in this macOS target.
extension Color {
    static let walkiesOrange = Color(red: 1, green: 0.47, blue: 0.18)
    static let badgeTeal = Color(red: 0.29, green: 0.58, blue: 0.58)
    static let badgeGreen = Color(red: 0.62, green: 0.77, blue: 0.58)
}
