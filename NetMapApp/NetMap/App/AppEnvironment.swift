import Foundation
import os.log

private let envLog = Logger(subsystem: "com.phil.netmap.app", category: "App")

@MainActor
final class AppEnvironment: ObservableObject {

    let bleScanner      = BLEScanner()
    let vehicleStore    = VehicleStore.shared
    let locationManager = LocationManager()
    let serverClient    = NetMapServerClient()
    let pushService     = SensorPushService()

    init() {
        UserDefaults.standard.removeObject(forKey: "history_v1")
        envLog.error("[App] init — wiring push pipeline")
        pushService.configure(
            scanner:  bleScanner,
            store:    vehicleStore,
            location: locationManager,
            client:   serverClient
        )
        envLog.error("[App] wired OK")
    }
}
