import UIKit
import UserNotifications

/// Local notifications for secrets found while the phone's in your pocket.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        guard let image = UIImage(named: "sticker-\(entry.id)"), let png = image.pngData() else { return nil }
        let url = URL.temporaryDirectory.appending(path: "sticker-\(entry.id).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: entry.id, url: url)
    }
}
