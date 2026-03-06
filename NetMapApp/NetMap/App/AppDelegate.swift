#if os(iOS)
import UIKit
import os.log

private let appLog = Logger(subsystem: "com.phil.netmap.app", category: "App")

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // netMapApp's @StateObject env is already initialized before this call
        // because UIApplicationDelegateAdaptor guarantees AppDelegate init runs
        // after SwiftUI creates the App struct and its @StateObject properties.
        appLog.error("[App] didFinishLaunching")
        return true
    }
}
#endif
