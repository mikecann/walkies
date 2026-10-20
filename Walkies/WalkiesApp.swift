import ChefKit
import SwiftUI
import UIKit

/// Owns the model, so it exists even when iOS relaunches the app in the background
/// for always-on tracking and no window ever appears. That can be before the phone's
/// first unlock since it started, when saved files and the Keychain can't be read yet,
/// so they wait for it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private lazy var locked = !UIApplication.shared.isProtectedDataAvailable
    lazy var model = AppModel(waitForUnlock: locked)
    lazy var account = Account(waitForUnlock: locked)
    lazy var sync = SyncEngine(model: model, account: account)
    private var unlockObserver: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        model.makePlaceClient = { [weak account] in await account?.client() }
        model.requestSync = { [weak self] in self?.sync.schedule() }
        // Chef (Seth's feedback board): opened from Settings rather than floating over the map.
        ChefKit.install(client: ChefConnection(account: account))
        ChefKit.isHidden = true
        if model.locked {
            unlockObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.unlocked() }
            }
            // In case it unlocked just before the observer was added.
            if application.isProtectedDataAvailable { unlocked() }
        } else {
            start()
        }
        return true
    }

    private func unlocked() {
        guard model.locked else { return }
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        unlockObserver = nil
        account.loadSession()
        model.loadSaved()
        sync.reload()
        start()
    }

    private func start() {
        model.refreshNeighbours()
        model.resumeAlwaysOn()
        sync.schedule()
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
                    SignInView {
                        delegate.sync.schedule()
                        delegate.model.refreshNeighbours()
                        ChefKit.retryPending()
                    }
                } else if !delegate.model.setupDone {
                    SetupView()
                } else {
                    ContentView()
                }
            }
            // The cream-paper look is a light design, so the app stays light.
            .onOpenURL { delegate.model.openTeamURL($0) }
            .preferredColorScheme(.light)
            .tint(Color.burnt)
            .environment(delegate.model)
            .environment(delegate.account)
            .environment(delegate.sync)
        }
    }
}
