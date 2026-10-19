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

    /// `-skipSignIn` on a simulator debug build goes straight in, for checking screens
    /// without an Apple or Google account. Nothing syncs.
    private static var skipSignIn: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-skipSignIn")
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !delegate.account.isSignedIn && !Self.skipSignIn {
                    SignInView { delegate.sync.schedule() }
                } else if !delegate.model.setupDone {
                    SetupView()
                } else {
                    ContentView()
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
