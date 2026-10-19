import SwiftUI
import UIKit

/// Owns the model, so it exists even when iOS relaunches the app in the background
/// for always-on tracking and no window ever appears.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        model.resumeAlwaysOn()
        return true
    }
}

@main
struct WalkiesApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(delegate.model)
        }
    }
}
