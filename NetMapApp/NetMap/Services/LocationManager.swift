import Foundation
import CoreLocation

// MARK: - Location Manager

/// Lightweight CoreLocation wrapper. Provides GPS coordinates for tagging sensor records.
@MainActor
final class LocationManager: NSObject, ObservableObject {

    @Published var location: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        authorizationStatus = manager.authorizationStatus
        manager.delegate           = self
        manager.desiredAccuracy    = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter     = 5    // metres
        checkAndRequest()
    }

    func checkAndRequest() {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            #if os(iOS)
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            #endif
            manager.startUpdatingLocation()
        #if os(iOS)
        case .authorizedWhenInUse:
            manager.startUpdatingLocation()
            // Ask for Always so background GPS works
            manager.requestAlwaysAuthorization()
        #endif
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: - Convenience

    /// Max age for a location fix to be considered valid.
    /// iOS: 60 s (device moves frequently).
    /// macOS: 3600 s (Mac is stationary — CoreLocation only fires on movement).
    private var locationMaxAge: TimeInterval {
        #if os(macOS)
        return 3600
        #else
        return 60
        #endif
    }

    /// Current latitude — nil if unavailable, not authorized, or fix is too old.
    var currentLatitude: Double? {
        guard let loc = location, -loc.timestamp.timeIntervalSinceNow < locationMaxAge else { return nil }
        return loc.coordinate.latitude
    }
    /// Current longitude — nil if unavailable, not authorized, or fix is too old.
    var currentLongitude: Double? {
        guard let loc = location, -loc.timestamp.timeIntervalSinceNow < locationMaxAge else { return nil }
        return loc.coordinate.longitude
    }

    var isAuthorized: Bool {
        #if os(iOS)
        return authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #else
        return authorizationStatus == .authorizedAlways
        #endif
    }
}

// MARK: - Delegate

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.location = loc }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorizationStatus = status
            #if os(iOS)
            if status == .authorizedAlways {
                manager.allowsBackgroundLocationUpdates = true
                manager.pausesLocationUpdatesAutomatically = false
                manager.startUpdatingLocation()
            } else if status == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
            #else
            if status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
            #endif
        }
    }
}
