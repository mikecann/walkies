import Foundation

nonisolated enum TeamColour: String, Codable, CaseIterable, Sendable {
    case teal, orange, purple, rose, blue, green
}

nonisolated struct TeamMember: Codable, Sendable, Identifiable {
    var userId: String
    var name: String
    var colour: String
    var joinedAt: Double
    var isYou: Bool
    var picture: String? = nil
    var id: String { userId }
}

/// Teams hold membership only. Exploring and finding secrets always stays personal.
nonisolated struct Team: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var createdBy: String
    var inviteCode: String
    var createdAt: Double = 0
    var members: [TeamMember] = []

    var you: TeamMember? { members.first(where: \.isYou) }
    var inviteURL: URL { Backend.site.appending(path: "join/\(inviteCode)") }
    private enum CodingKeys: String, CodingKey { case id = "teamId", name, createdBy, inviteCode, createdAt, members }
}

nonisolated enum TeamInviteCode {
    static func normalise(_ code: String) -> String { code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    static func isValid(_ code: String) -> Bool {
        code.count == 8 && code.allSatisfy { "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0) }
    }
}

/// The sheet can receive another deep link while a preview request is in flight.
nonisolated struct TeamInviteDraft: Sendable {
    var code = ""
    var preview: TeamsAPI.Invite?
    var checkedCode = ""
    var normalisedCode: String { TeamInviteCode.normalise(code) }

    mutating func replace(with code: String) {
        self.code = code
        preview = nil
        checkedCode = ""
    }

    @discardableResult
    mutating func receive(_ preview: TeamsAPI.Invite?, for code: String) -> Bool {
        guard code == normalisedCode else { return false }
        self.preview = preview
        checkedCode = code
        return true
    }
}
