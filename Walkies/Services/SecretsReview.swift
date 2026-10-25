import Foundation

/// A secret the server wrote that's waiting for Mike's OK before it goes live: stories
/// about First Nations heritage, deaths or crime, and living people (convex/lore.ts).
nonisolated struct WaitingSecret: Decodable, Identifiable, Hashable, Sendable {
    var entryId: String
    var osmId: Int
    var suburb: String
    var title: String
    var body: String
    var category: String
    var sources: [String]
    /// What sent it for review, such as "death" or "Noongar".
    var sensitive: [String]
    var stickerUrl: URL?

    var id: String { entryId }

    /// As a LoreEntry, for the sticker placeholder.
    var entry: LoreEntry {
        LoreEntry(id: entryId, title: title, body: body, category: category, sticker: "", sources: sources, suburb: suburb)
    }
}

/// Mike's review from Settings. Only Chef's admin gets anything back; the server
/// checks every call.
nonisolated enum SecretsReview {
    /// How long a "you're not the admin" answer is believed before Settings asks again.
    static let notAdminFor: TimeInterval = 7 * 24 * 3600

    /// What's waiting, or nil when you're not the admin (or the server can't say). Only
    /// the admin ever gets a list, so once the server has said this account isn't, Settings
    /// stops asking for a week instead of calling it on every visit for everyone.
    static func waiting(_ client: ConvexClient, userId: String?, defaults: UserDefaults = .standard, now: Date = .now) async -> [WaitingSecret]? {
        let key = userId.map { "secretsReview.notAdmin.\($0)" }
        if let key, let said = defaults.object(forKey: key) as? Date, now.timeIntervalSince(said) < notAdminFor { return nil }
        let answer: [WaitingSecret]??
        do { answer = .some(try await client.query("lore:adminPending") as [WaitingSecret]?) } catch { answer = .none }
        // Only a real answer counts: a failed call says nothing about who you are.
        if let key, case .some(let list) = answer {
            if list == nil { defaults.set(now, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        return answer ?? nil
    }

    static func approve(_ secret: WaitingSecret, _ client: ConvexClient) async throws {
        let _: Nothing = try await client.mutation("lore:adminApprove", ["entryId": secret.entryId])
    }

    static func hide(_ secret: WaitingSecret, _ client: ConvexClient) async throws {
        let _: Nothing = try await client.mutation("lore:adminHide", ["entryId": secret.entryId])
    }
}
