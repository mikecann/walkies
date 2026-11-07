import ChefKit
import SwiftUI
import UIKit
import UserNotifications

/// Owns the model, so it exists even when iOS relaunches the app in the background
/// for always-on tracking and no window ever appears. That can be before the phone's
/// first unlock since it started, when saved files and the Keychain can't be read yet,
/// so they wait for it.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private lazy var locked = !UIApplication.shared.isProtectedDataAvailable
    lazy var model: AppModel = {
        #if DEBUG
        // App Store screenshots: a made-up explorer, never the saved data.
        if ScreenshotMode.isOn { return AppModel(store: ScreenshotMode.makeStore(), servicesEnabled: false, alwaysOn: false) }
        #endif
        return AppModel(waitForUnlock: locked)
    }()
    lazy var account = Account(waitForUnlock: locked)
    lazy var sync = SyncEngine(model: model, account: account)
    private var unlockObserver: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // First, so a crash anywhere in launch is reported. Does nothing outside Release on a phone.
        CrashReporting.start()
        // Before this returns, or the tap that launched the app is never delivered.
        UNUserNotificationCenter.current().delegate = self
        model.makePlaceClient = { [weak account] in await account?.client() }
        model.requestSync = { [weak self] in self?.sync.schedule() }
        // Chef (Seth's feedback board): opened from Settings rather than floating over the map.
        ChefKit.install(client: ChefConnection(account: account))
        ChefKit.isHidden = true
        // Straight away, even before the first unlock, so the exit that relaunched us arrives.
        model.tracker.openFence()
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

    /// A notification's been tapped.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let target = NotificationTarget(userInfo: response.notification.request.content.userInfo) {
            model.notificationTarget = target
        }
        completionHandler()
    }

    /// iOS hides a notification for the app that's open, which would lose one you're meant
    /// to act on. The rest stay hidden, since the app shows those its own way.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let actionable = NotificationTarget(userInfo: notification.request.content.userInfo) != nil
        completionHandler(actionable ? [.banner, .list, .sound] : [])
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushTokens.save(deviceToken)
        sync.schedule()
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
        // For pushes when a suburb's secrets are ready. Needs no prompt; whether they show is
        // the notification permission setup already asks for. Sync hands the token over.
        UIApplication.shared.registerForRemoteNotifications()
        model.refreshNeighbours()
        model.resumeAlwaysOn()
        sync.schedule()
        #if DEBUG
        if ScreenshotMode.isOn {
            Task {
                await model.waitForHistory()
                model.showSample(at: ScreenshotMode.location, recap: ScreenshotMode.screen == .recap)
            }
        }
        #endif
    }
}

@main
struct WalkiesApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// `-skipSignIn` on a simulator debug build goes straight in, for checking screens
    /// without an Apple or Google account. Nothing syncs. Screenshot mode does too.
    private static var skipSignIn: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-skipSignIn") || ScreenshotMode.isOn
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
            .onOpenURL { url in
                // Safari finishing a sign-in that iOS wouldn't open in the sheet.
                if SignInSheet.browserReturned(url) { return }
                delegate.model.openTeamURL(url)
            }
            .onChange(of: scenePhase) { _, phase in SignInSheet.scenePhaseChanged(to: phase) }
            .preferredColorScheme(.light)
            .tint(Color.burnt)
            .environment(delegate.model)
            .environment(delegate.account)
            .environment(delegate.sync)
        }
    }
}
