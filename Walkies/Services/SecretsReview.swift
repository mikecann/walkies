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
    /// What's waiting, or nil when you're not the admin (or the server can't say).
    static func waiting(_ client: ConvexClient) async -> [WaitingSecret]? {
        try? await client.query("lore:adminPending") as [WaitingSecret]?
    }

    static func approve(_ secret: WaitingSecret, _ client: ConvexClient) async throws {
        let _: Nothing = try await client.mutation("lore:adminApprove", ["entryId": secret.entryId])
    }

    static func hide(_ secret: WaitingSecret, _ client: ConvexClient) async throws {
        let _: Nothing = try await client.mutation("lore:adminHide", ["entryId": secret.entryId])
    }
}
