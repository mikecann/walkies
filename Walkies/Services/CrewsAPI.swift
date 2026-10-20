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
    private struct Place: Encodable { var crewId: String; var clientId: String; var name: String; var file: String }
    private struct Tiles: Encodable { var crewId: String; var placeId: String; var hexes: [Hex]; var at: Double }
    private struct Trail: Encodable { var crewId: String; var walkClientId: String; var file: String }
    private struct Secret: Encodable { var secretId: String; var at: Double }
    private struct Secrets: Encodable { var crewId: String; var secrets: [Secret] }
    private struct Pull: Encodable { var crewId: String; var since: Double? }

    func list() async throws -> [Listing] { try await client.query("crews:myCrews") }
    func preview(_ code: String) async throws -> Invite? { try await client.query("crews:crewForInvite", ["code": code]) }
    func create(name: String, colour: String, sharing: CrewSharing) async throws -> Created {
        try await client.mutation("crews:createCrew", Create(name: name, colour: colour, sharing: sharing))
    }
    func join(code: String, colour: String, sharing: CrewSharing) async throws -> String {
        try await client.mutation("crews:joinCrew", Join(code: code, colour: colour, sharing: sharing))
    }
    func update(_ preferences: Preferences) async throws {
        let _: Nothing = try await client.mutation("crews:updateMembership", preferences)
    }
    func rename(_ id: String, name: String) async throws {
        let _: Nothing = try await client.mutation("crews:renameCrew", ["crewId": id, "name": name])
    }
    func remove(_ id: String, userId: String) async throws {
        let _: Nothing = try await client.mutation("crews:removeMember", ["crewId": id, "userId": userId])
    }
    func leave(_ id: String) async throws {
        let _: Nothing = try await client.mutation("crews:leaveCrew", ["crewId": id])
    }
    func addPlace(_ id: String, city: City, file: String) async throws -> String {
        try await client.mutation("crews:addCrewPlace", Place(crewId: id, clientId: city.id.uuidString, name: city.name, file: file))
    }
    func tiles(_ id: String, batch: CrewTileBatch) async throws {
        let _: Int = try await client.mutation("crews:uploadCrewTiles", Tiles(crewId: id, placeId: batch.placeId, hexes: batch.hexes, at: batch.at))
    }
    func trail(_ id: String, trail: CrewPendingTrail, file: String) async throws {
        let _: Nothing = try await client.mutation("crews:uploadCrewTrail", Trail(crewId: id, walkClientId: trail.walkClientId, file: file))
    }
    func secrets(_ id: String, secrets: [String: Double]) async throws {
        let _: Nothing = try await client.mutation("crews:recordCrewSecrets", Secrets(crewId: id, secrets: secrets.map { Secret(secretId: $0.key, at: $0.value) }))
    }
    func snapshot(_ id: String, since: Double?) async throws -> CrewSnapshot {
        var snapshot: CrewSnapshot = try await client.query("crews:crewSnapshot", Pull(crewId: id, since: since))
        snapshot.isFull = since == nil
        return snapshot
    }
    func upload(_ data: Data) async throws -> String {
        let url: String = try await client.mutation("sync:generateUploadUrl")
        guard let url = URL(string: url) else { throw ConvexError.server("Bad upload URL") }
        return try await client.upload(data, to: url)
    }
    func city(_ url: URL) async throws -> City { try JSONDecoder().decode(City.self, from: await client.download(url)) }
    func route(_ url: URL) async throws -> CrewRoute { try JSONDecoder().decode(CrewRoute.self, from: await client.download(url)) }
}

nonisolated struct CrewSnapshot: Decodable, Sendable {
    struct Info: Decodable, Sendable { var crewId: String; var name: String; var createdBy: String; var inviteCode: String; var createdAt: Double }
    struct Place: Decodable, Sendable { var placeId: String; var clientId: String; var name: String; var updatedAt: Double; var url: String? }
    struct Tile: Decodable, Sendable { var placeId: String; var q: Int32; var r: Int32; var by: String; var at: Double }
    struct Trail: Decodable, Sendable { var walkClientId: String; var url: String?; var by: String; var at: Double }
    struct Secret: Decodable, Sendable { var secretId: String; var by: String; var at: Double }
    var crew: Info
    var members: [CrewMember]
    var places: [Place]
    var tiles: [Tile]
    var trails: [Trail]
    var secrets: [Secret]
    var serverTime: Double
    var isFull = false
    private enum CodingKeys: String, CodingKey { case crew, members, places, tiles, trails, secrets, serverTime }
}
