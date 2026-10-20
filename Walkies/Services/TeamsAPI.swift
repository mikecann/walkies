import Foundation

/// All team function names and wire formats live here, alongside the documented API.
nonisolated struct TeamsAPI: Sendable {
    var client: ConvexClient

    struct Invite: Decodable, Sendable { var name: String; var memberNames: [String] }
    struct Created: Decodable, Sendable { var teamId: String; var inviteCode: String }
    struct Preferences: Encodable, Sendable { var teamId: String; var colour: String?; var name: String? }
    private struct Create: Encodable { var name: String; var colour: String; var memberName: String }
    private struct Join: Encodable { var code: String; var colour: String; var name: String }

    func list() async throws -> [Team] { try await client.query("teams:myTeams") }
    func preview(_ code: String) async throws -> Invite? { try await client.mutation("teams:teamForInvite", ["code": code]) }
    func create(name: String, colour: String, memberName: String) async throws -> Created {
        try await client.action("teams:createTeam", Create(name: name, colour: colour, memberName: memberName))
    }
    func join(code: String, colour: String, name: String) async throws -> String {
        try await client.action("teams:joinTeam", Join(code: code, colour: colour, name: name))
    }
    func newInviteCode(_ id: String) async throws -> String {
        try await client.action("teams:newInviteCode", ["teamId": id])
    }
    func update(_ preferences: Preferences) async throws {
        let _: Nothing = try await client.mutation("teams:updateMembership", preferences)
    }
    func rename(_ id: String, name: String) async throws {
        let _: Nothing = try await client.mutation("teams:renameTeam", ["teamId": id, "name": name])
    }
    func remove(_ id: String, userId: String) async throws {
        let _: Nothing = try await client.action("teams:removeMember", ["teamId": id, "userId": userId])
    }
    func leave(_ id: String) async throws {
        let _: Nothing = try await client.mutation("teams:leaveTeam", ["teamId": id])
    }
}
