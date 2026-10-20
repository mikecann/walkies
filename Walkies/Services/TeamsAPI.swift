import Foundation

/// All team function names and wire formats live here, alongside the documented API.
nonisolated struct TeamsAPI: Sendable {
    var client: ConvexClient

    struct Invite: Decodable, Sendable { var name: String; var memberNames: [String] }
    struct Created: Decodable, Sendable { var teamId: String; var inviteCode: String }
    struct Listing: Decodable, Sendable { var teamId: String; var name: String; var memberCount: Int; var membership: TeamMember }
    struct Preferences: Encodable, Sendable { var teamId: String; var colour: String?; var sharing: TeamSharing?; var walksCount: Bool? }
    private struct Create: Encodable { var name: String; var colour: String; var sharing: TeamSharing }
    private struct Join: Encodable { var code: String; var colour: String; var sharing: TeamSharing }
    private struct Place: Encodable { var teamId: String; var clientId: String; var name: String; var file: String; var bounds: TeamPlaceBounds; var gridPlaceId: String?
        enum CodingKeys: String, CodingKey { case teamId, clientId, name, file, bounds, gridPlaceId }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(teamId, forKey: .teamId); try c.encode(clientId, forKey: .clientId)
            try c.encode(name, forKey: .name); try c.encode(file, forKey: .file); try c.encode(bounds, forKey: .bounds)
            // Explicit null means we built the first grid, rather than an older client omitting the guard.
            try c.encode(gridPlaceId, forKey: .gridPlaceId)
        }
    }
    private struct Tiles: Encodable { var teamId: String; var placeId: String; var hexes: [Hex]; var at: Double; var discoveredAt: [Double]? }
    private struct Trail: Encodable { var teamId: String; var walkClientId: String; var file: String; var updatedAt: Double }
    private struct Secret: Encodable { var secretId: String; var at: Double }
    private struct Secrets: Encodable { var teamId: String; var secrets: [Secret] }
    private struct Pull: Encodable { var teamId: String; var since: Double?; var cursor: TeamSnapshot.TileCursor? }

    func list() async throws -> [Listing] { try await client.query("teams:myTeams") }
    func preview(_ code: String) async throws -> Invite? { try await client.mutation("teams:teamForInvite", ["code": code]) }
    func create(name: String, colour: String, sharing: TeamSharing) async throws -> Created {
        try await client.action("teams:createTeam", Create(name: name, colour: colour, sharing: sharing))
    }
    func join(code: String, colour: String, sharing: TeamSharing) async throws -> String {
        try await client.action("teams:joinTeam", Join(code: code, colour: colour, sharing: sharing))
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
    func addPlace(_ id: String, city: City, file: String, gridPlaceId: String?) async throws -> String {
        try await client.action("teams:addTeamPlace", Place(teamId: id, clientId: city.id.uuidString, name: city.name, file: file, bounds: try TeamPlaceBounds(city: city), gridPlaceId: gridPlaceId))
    }
    func tiles(_ id: String, batch: TeamTileBatch) async throws {
        let _: Int = try await client.mutation("teams:uploadTeamTiles", Tiles(teamId: id, placeId: batch.placeId, hexes: batch.hexes, at: batch.at, discoveredAt: batch.discoveredAt))
    }
    func trail(_ id: String, trail: TeamPendingTrail, file: String) async throws {
        let _: Nothing = try await client.action("teams:uploadTeamTrail", Trail(teamId: id, walkClientId: trail.walkClientId, file: file, updatedAt: trail.updatedAt))
    }
    func secrets(_ id: String, secrets: [String: Double]) async throws {
        let _: Nothing = try await client.mutation("teams:recordTeamSecrets", Secrets(teamId: id, secrets: secrets.map { Secret(secretId: $0.key, at: $0.value) }))
    }
    func snapshot(_ id: String, since: Double?, onPage: @MainActor @Sendable (TeamSnapshot) -> Void = { _ in }) async throws -> TeamSnapshot {
        var snapshot: TeamSnapshot = try await client.query("teams:teamSnapshot", Pull(teamId: id, since: since))
        await onPage(snapshot)
        var tiles = snapshot.tiles
        while snapshot.more {
            guard let cursor = snapshot.cursor else { throw ConvexError.server("Missing team snapshot cursor") }
            snapshot = try await client.query("teams:teamSnapshot", Pull(teamId: id, since: since, cursor: cursor))
            await onPage(snapshot)
            tiles += snapshot.tiles
        }
        // Nothing reaches the persisted model until the entire frozen traversal succeeds.
        snapshot.tiles = tiles
        snapshot.isFull = since == nil
        return snapshot
    }
    func upload<T: Encodable & Sendable>(_ value: T) async throws -> String {
        let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(value) }.value
        return try await upload(data)
    }
    func upload(_ data: Data) async throws -> String {
        guard data.count <= 2 * 1024 * 1024, let json = String(data: data, encoding: .utf8) else {
            throw ConvexError.coded("INVALID_ARGUMENT", "Team files must be valid JSON under 2 MiB.")
        }
        return try await client.action("teams:uploadFile", ["json": json])
    }
    func city(_ url: URL) async throws -> City { try JSONDecoder().decode(City.self, from: await client.download(url)) }
    func route(_ url: URL) async throws -> TeamRoute { try JSONDecoder().decode(TeamRoute.self, from: await client.download(url)) }
}

nonisolated struct TeamSnapshot: Decodable, Sendable {
    struct Info: Decodable, Sendable { var teamId: String; var name: String; var createdBy: String; var inviteCode: String; var createdAt: Double }
    struct Place: Decodable, Sendable { var placeId: String; var clientId: String; var name: String; var updatedAt: Double; var url: String? }
    struct Tile: Decodable, Sendable { var placeId: String; var q: Int32; var r: Int32; var by: String; var at: Double }
    struct Trail: Decodable, Sendable {
        var walkClientId: String; var url: String?; var by: String; var at: Double
        var version: TeamTrail.Version { .init(by: by, walkClientId: walkClientId, at: at) }
    }
    struct Secret: Decodable, Sendable { var secretId: String; var by: String; var at: Double }
    var team: Info
    var members: [TeamMember]
    var places: [Place]
    var tiles: [Tile]
    var trails: [Trail]
    var secrets: [Secret]
    struct TileCursor: Codable, Sendable, Equatable {
        var position: String
        var until: Double
        var since: Double?
        enum CodingKeys: String, CodingKey { case position, until, since }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(position, forKey: .position)
            try c.encode(until, forKey: .until)
            try c.encode(since, forKey: .since)
        }
    }
    var cursor: TileCursor? = nil
    var more = false
    var serverTime: Double
    var isFull = false
    private enum CodingKeys: String, CodingKey { case team, members, places, tiles, trails, secrets, serverTime, cursor, more }
}
