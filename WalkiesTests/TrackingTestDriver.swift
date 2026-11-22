import CoreLocation
@testable import Walkies

@MainActor
final class TrackingTestDriver: LocationDriver {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var activityType: CLActivityType = .other
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    var starts = 0
    var stops = 0
    var significantStarts = 0
    var significantStops = 0
    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func startMonitoringSignificantLocationChanges() { significantStarts += 1 }
    func stopMonitoringSignificantLocationChanges() { significantStops += 1 }
}

@MainActor
final class TrackingTestSession: TrackerSession {
    var invalidations = 0
    func invalidate() { invalidations += 1 }
}

@MainActor
final class TrackingTestFence: Geofence {
    var onExit: (() -> Void)?
    var onStopExit: (() -> Void)?
    var onOpen: ((Coordinate?) -> Void)?
    var opened: (() -> Void)?
    var opens = 0
    var placed: [Coordinate] = []
    var removed = 0
    var stops: [Coordinate] = []
    var stopsRemoved = 0
    func open() { opens += 1; opened?() }
    func place(around center: Coordinate, radius: Double) { placed.append(center) }
    func remove() { removed += 1 }
    func placeStop(around center: Coordinate, radius: Double) { stops.append(center) }
    func removeStop() { stopsRemoved += 1 }
}
