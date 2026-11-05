import UIKit
import UserNotifications

/// Local notifications: secrets found while the phone's in your pocket, and the nudge to
/// open the app when you head out.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The same, waiting for the answer.
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Only when the app isn't on screen; when it is, the secret pops up in the app instead.
    static func stickersFound(_ entries: [LoreEntry]) {
        guard UIApplication.shared.applicationState != .active else { return }
        for entry in entries {
            let content = UNMutableNotificationContent()
            content.title = "Secret found: \(entry.title)"
            content.body = entry.body
            content.sound = .default
            content.userInfo = ["sticker": entry.id]
            if let attachment = attachment(for: entry) {
                content.attachments = [attachment]
            }
            let request = UNNotificationRequest(identifier: "sticker-\(entry.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// The sticker art, copied to a temporary file because notifications need one.
    private static func attachment(for entry: LoreEntry) -> UNNotificationAttachment? {
        guard let image = StickerImage.of(entry), let png = image.pngData() else { return nil }
        let url = URL.temporaryDirectory.appending(path: "sticker-\(entry.id).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: entry.id, url: url)
    }

    private static let walkQuestion = "walk-question"

    /// Whether notifications can be shown, read when the app opens. Always on only relies
    /// on the walk question when they can.
    @MainActor private(set) static var allowed = false

    @MainActor static func refreshAllowed() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }

    /// Opening the app from this is what lets the GPS follow you (see LocationTracker).
    static func askToStartWalk() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Out for a walk?"
        content.body = "Tap to start recording it."
        content.sound = .default
        let request = UNNotificationRequest(identifier: walkQuestion, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func withdrawWalkQuestion() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [walkQuestion])
        center.removeDeliveredNotifications(withIdentifiers: [walkQuestion])
    }
}
