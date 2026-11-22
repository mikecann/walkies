import CoreLocation

/// Core Location's manager boundary. Tests record the actual watch configuration
/// without asking a test runner for background-location capability.
protocol LocationDriver: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var activityType: CLActivityType { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
}

extension CLLocationManager: LocationDriver {}

protocol TrackerSession: AnyObject {
    func invalidate()
}

extension CLBackgroundActivitySession: TrackerSession {}
extension CLServiceSession: TrackerSession {}
