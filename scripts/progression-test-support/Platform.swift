// Only the OS services are replaced. AppModel, Store, SyncEngine and HTTP client
// below this boundary are the same files compiled into the iPhone app.
@_exported import SwiftUI
import CoreLocation
import Foundation

final class LocationTracker {
    var authorization: CLAuthorizationStatus = .authorizedAlways
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorizationChange: (() -> Void)?
    var hasAlwaysPermission = true
    func requestPermissionIfNeeded() {}
    func requestAlwaysPermission() {}
    func start() {}
    func stop() {}
    func startAlwaysOn() {}
    func stopAlwaysOn() {}
}
final class MotionMonitor {
    var onWheels = false
    var still = false
    func start() {}
}
enum Notifier {
    static func requestPermission() {}
    static func stickersFound(_ entries: [LoreEntry]) {}
}
final class Account {
    var isSignedIn = false
    func client() async -> ConvexClient? { nil }
}
nonisolated struct CloudField {
    init(cities: [City]) {}
}
