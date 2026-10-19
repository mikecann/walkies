import SwiftUI
import UIKit

/// Owns the model, so it exists even when iOS relaunches the app in the background
/// for always-on tracking and no window ever appears.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    let account = Account()
    lazy var sync = SyncEngine(model: model, account: account)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        model.requestSync = { [weak self] in self?.sync.schedule() }
        model.resumeAlwaysOn()
        sync.schedule()
        return true
    }
}

@main
struct WalkiesApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if delegate.account.isSignedIn {
                    ContentView()
                } else {
                    SignInView { delegate.sync.schedule() }
                }
            }
            // The cream-paper look is a light design, so the app stays light.
            .preferredColorScheme(.light)
            .tint(Color.burnt)
            .environment(delegate.model)
            .environment(delegate.account)
            .environment(delegate.sync)
        }
    }
}
