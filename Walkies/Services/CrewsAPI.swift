import Foundation

/// All crew function names and wire formats live here, alongside the documented API.
nonisolated struct CrewsAPI: Sendable {
    var client: ConvexClient

    struct Invite: Decodable, Sendable { var name: String; var memberNames: [String] }
    struct Created: Decodable, Sendable { var crewId: String; var inviteCode: String }
    struct Listing: Decodable, Sendable { var crewId: String; var name: String; var memberCount: Int; var membership: CrewMember }
    struct Preferences: Encodable, Sendable { var crewId: String; var colour: String?; var sharing: CrewSharing?; var walksCount: Bool? }
    private struct Create: Encodable { var name: String; var colour: String; var sharing: CrewSharing }
    private struct Join: Encodable { var code: String; var colour: String; var sharing: CrewSharing }
    private struct Place: Encodable { var crewId: String; var clientId: String; var name: String; var file: String; var bounds: CrewPlaceBounds; var gridPlaceId: String?
        enum CodingKeys: String, CodingKey { case crewId, clientId, name, file, bounds, gridPlaceId }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(crewId, forKey: .crewId); try c.encode(clientId, forKey: .clientId)
            try c.encode(name, forKey: .name); try c.encode(file, forKey: .file); try c.encode(bounds, forKey: .bounds)
            // Explicit null means we built the first grid, rather than an older client omitting the guard.
            try c.encode(gridPlaceId, forKey: .gridPlaceId)
        }
    }
    private struct Tiles: Encodable { var crewId: String; var placeId: String; var hexes: [Hex]; var at: Double; var discoveredAt: [Double]? }
    private struct Trail: Encodable { var crewId: String; var walkClientId: String; var file: String; var updatedAt: Double }
    private struct Secret: Encodable { var secretId: String; var at: Double }
    private struct Secrets: Encodable { var crewId: String; var secrets: [Secret] }
    private struct Pull: Encodable { var crewId: String; var since: Double?; var cursor: CrewSnapshot.TileCursor? }

    func list() async throws -> [Listing] { try await client.query("crews:myCrews") }
    func preview(_ code: String) async throws -> Invite? { try await client.mutation("crews:crewForInvite", ["code": code]) }
    func create(name: String, colour: String, sharing: CrewSharing) async throws -> Created {
        try await client.action("crews:createCrew", Create(name: name, colour: colour, sharing: sharing))
    }
    func join(code: String, colour: String, sharing: CrewSharing) async throws -> String {
        try await client.action("crews:joinCrew", Join(code: code, colour: colour, sharing: sharing))
    }
    func newInviteCode(_ id: String) async throws -> String {
        try await client.action("crews:newInviteCode", ["crewId": id])
    }
    func update(_ preferences: Preferences) async throws {
        let _: Nothing = try await client.mutation("crews:updateMembership", preferences)
    }
    func rename(_ id: String, name: String) async throws {
        let _: Nothing = try await client.mutation("crews:renameCrew", ["crewId": id, "name": name])
    }
    func remove(_ id: String, userId: String) async throws {
        let _: Nothing = try await client.action("crews:removeMember", ["crewId": id, "userId": userId])
    }
    func leave(_ id: String) async throws {
        let _: Nothing = try await client.mutation("crews:leaveCrew", ["crewId": id])
    }
    func addPlace(_ id: String, city: City, file: String, gridPlaceId: String?) async throws -> String {
        try await client.action("crews:addCrewPlace", Place(crewId: id, clientId: city.id.uuidString, name: city.name, file: file, bounds: try CrewPlaceBounds(city: city), gridPlaceId: gridPlaceId))
    }
    func tiles(_ id: String, batch: CrewTileBatch) async throws {
        let _: Int = try await client.mutation("crews:uploadCrewTiles", Tiles(crewId: id, placeId: batch.placeId, hexes: batch.hexes, at: batch.at, discoveredAt: batch.discoveredAt))
    }
    func trail(_ id: String, trail: CrewPendingTrail, file: String) async throws {
        let _: Nothing = try await client.action("crews:uploadCrewTrail", Trail(crewId: id, walkClientId: trail.walkClientId, file: file, updatedAt: trail.updatedAt))
    }
    func secrets(_ id: String, secrets: [String: Double]) async throws {
        let _: Nothing = try await client.mutation("crews:recordCrewSecrets", Secrets(crewId: id, secrets: secrets.map { Secret(secretId: $0.key, at: $0.value) }))
    }
    func snapshot(_ id: String, since: Double?, onPage: @MainActor @Sendable (CrewSnapshot) -> Void = { _ in }) async throws -> CrewSnapshot {
        var snapshot: CrewSnapshot = try await client.query("crews:crewSnapshot", Pull(crewId: id, since: since))
        await onPage(snapshot)
        var tiles = snapshot.tiles
        while snapshot.more {
            guard let cursor = snapshot.cursor else { throw ConvexError.server("Missing crew snapshot cursor") }
            snapshot = try await client.query("crews:crewSnapshot", Pull(crewId: id, since: since, cursor: cursor))
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
            throw ConvexError.coded("INVALID_ARGUMENT", "Crew files must be valid JSON under 2 MiB.")
        }
        return try await client.action("crews:uploadFile", ["json": json])
    }
    func city(_ url: URL) async throws -> City { try JSONDecoder().decode(City.self, from: await client.download(url)) }
    func route(_ url: URL) async throws -> CrewRoute { try JSONDecoder().decode(CrewRoute.self, from: await client.download(url)) }
}

nonisolated struct CrewSnapshot: Decodable, Sendable {
    struct Info: Decodable, Sendable { var crewId: String; var name: String; var createdBy: String; var inviteCode: String; var createdAt: Double }
    struct Place: Decodable, Sendable { var placeId: String; var clientId: String; var name: String; var updatedAt: Double; var url: String? }
    struct Tile: Decodable, Sendable { var placeId: String; var q: Int32; var r: Int32; var by: String; var at: Double }
    struct Trail: Decodable, Sendable {
        var walkClientId: String; var url: String?; var by: String; var at: Double
        var version: CrewTrail.Version { .init(by: by, walkClientId: walkClientId, at: at) }
    }
    struct Secret: Decodable, Sendable { var secretId: String; var by: String; var at: Double }
    var crew: Info
    var members: [CrewMember]
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
    private enum CodingKeys: String, CodingKey { case crew, members, places, tiles, trails, secrets, serverTime, cursor, more }
}
