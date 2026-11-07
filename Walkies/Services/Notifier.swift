import UIKit
import UserNotifications

/// Local notifications for secrets found while the phone's in your pocket.
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
}

/// The phone's APNs token, handed to the server so it can tell you when a suburb's secrets
/// are ready (and tell Mike how research and new places are going). convex/devices.ts keeps it.
nonisolated enum PushTokens {
    private static let tokenKey = "push.token"
    private static let deviceKey = "push.deviceId"
    /// The account and token the server last took, so it's only sent again when either changes.
    private static let sentKey = "push.sent"

    /// Ours, kept across launches, so the server sees one phone however many tokens iOS hands out.
    static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    static func save(_ token: Data) {
        UserDefaults.standard.set(token.map { String(format: "%02x", $0) }.joined(), forKey: tokenKey)
    }

    /// A Debug build always gets a sandbox token; the server tries the other if Apple says no.
    private static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// Sends the token if the server hasn't got it for this account yet. Cheap to call after every sync.
    static func register(_ client: ConvexClient, userId: String?) async {
        guard let userId, let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        let sent = "\(userId)|\(token)"
        guard UserDefaults.standard.string(forKey: sentKey) != sent else { return }
        let args = ["deviceId": deviceId, "platform": "ios", "apnsToken": token, "apnsEnvironment": environment]
        do {
            let _: Nothing = try await client.mutation("devices:register", args)
            UserDefaults.standard.set(sent, forKey: sentKey)
        } catch {
            // Offline, or a server without devices yet: the next sync tries again.
        }
    }

    /// Signing out: this phone stops getting the account's pushes.
    static func unregister(_ client: ConvexClient) async {
        UserDefaults.standard.removeObject(forKey: sentKey)
        let _: Nothing? = try? await client.mutation("devices:unregister", ["deviceId": deviceId])
    }
}
