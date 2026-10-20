import Foundation

nonisolated enum TeamSharing: String, Codable, CaseIterable, Sendable {
    case tiles, tilesAndTrail
    var title: String { self == .tiles ? "Tiles only" : "Tiles and trail" }
    var detail: String {
        self == .tiles ? "Share the tiles you uncover, without your route." : "Share tiles and your route inside this team's places."
    }
}

nonisolated enum TeamColour: String, Codable, CaseIterable, Sendable {
    case teal, orange, purple, rose, blue, green
    static let fallback = "grey"
}

nonisolated struct TeamMember: Codable, Sendable, Identifiable {
    var userId: String
    var name: String
    var colour: String
    var sharing: TeamSharing
    var walksCount: Bool
    var joinedAt: Double
    var isYou: Bool
    var id: String { userId }
}

nonisolated struct TeamDiscovery: Codable, Sendable {
    var by: String
    var at: Double
}

nonisolated struct TeamPlace: Codable, Sendable, Identifiable {
    var placeId: String
    var clientId: String
    var city: City
    var first: [Hex: TeamDiscovery] = [:]
    var id: String { placeId }
}

/// Deliberately contains no raw GPS fixes or personal walk metadata.
nonisolated struct TeamRoute: Codable, Sendable, Equatable {
    var segments: [[Coordinate]]
}

nonisolated struct TeamTrail: Codable, Sendable {
    struct Version: Hashable, Sendable { var by: String; var walkClientId: String; var at: Double }
    var version: Version { Version(by: by, walkClientId: walkClientId, at: at) }
    var walkClientId: String
    var by: String
    var at: Double
    var route: TeamRoute
}

nonisolated struct TeamTileBatch: Codable, Sendable, Identifiable {
    var id = UUID()
    var placeId: String
    var hexes: [Hex]
    var at: Double
    /// Replay packs different walks together without losing each tile's date.
    var discoveredAt: [Double]? = nil
}

nonisolated struct TeamPendingPlace: Codable, Sendable, Identifiable {
    var city: City
    var file: String?
    var uploadClaimed: Bool?
    var id: UUID { city.id }
}

nonisolated struct TeamPendingTrail: Codable, Sendable, Identifiable {
    var walkClientId: String
    var route: TeamRoute
    /// Keep the storage id across retries; each row owns a dedicated file.
    var file: String?
    var updatedAt: Double
    var id: String { walkClientId }

    init(walkClientId: String, route: TeamRoute, file: String? = nil, updatedAt: Double = Date.now.ms) {
        self.walkClientId = walkClientId; self.route = route; self.file = file; self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case walkClientId, route, file, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        walkClientId = try c.decode(String.self, forKey: .walkClientId)
        route = try c.decode(TeamRoute.self, forKey: .route)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? Date.now.ms
        // Old queued files were uploaded through personal sync and cannot be claimed.
        if !c.contains(.updatedAt) { file = nil }
    }
}

nonisolated struct TeamMap: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var createdBy: String
    var inviteCode: String
    var members: [TeamMember] = []
    var places: [TeamPlace] = []
    var trails: [TeamTrail] = []
    var secrets: [String: TeamDiscovery] = [:]
    var since: Double?
    /// Retained after delivery so replay versions always increase, even in one millisecond.
    var trailVersions: [String: Double]?
    var syncMessage: String?
    var pendingPlaces: [TeamPendingPlace] = []
    var pendingTiles: [TeamTileBatch] = []
    var pendingTrails: [TeamPendingTrail] = []
    /// Local-only jobs, persisted before the clipping worker starts. Never uploaded.
    var routeWork: [Walk] = []
    var pendingSecrets: [String: Double] = [:]
    /// Places needing an initial replay, persisted so an interrupted join resumes.
    var replayedPlaces: Set<String> = []

    /// Walks paused on this phone must never be backfilled when sharing resumes.
    var excludedWalks: Set<UUID>? = nil

    mutating func enforcePreferences() {
        if you?.walksCount != true {
            pendingTiles = []; pendingSecrets = [:]; pendingTrails = []; routeWork = []
            replayedPlaces.formUnion(places.map(\.id))
        }
        if you?.sharing != .tilesAndTrail { pendingTrails = []; routeWork = [] }
    }

    var you: TeamMember? { members.first(where: \.isYou) }
    var cities: [City] { places.map(\.city) }
    var waiting: Int { pendingPlaces.count + pendingTiles.count + pendingTrails.count + pendingSecrets.count + routeWork.count }
    var inviteURL: URL { Backend.site.appending(path: "join/\(inviteCode)") }

    func memberName(_ id: String) -> String { members.first { $0.userId == id }?.name ?? "Past member" }
    func colour(for userId: String) -> String { members.first { $0.userId == userId }?.colour ?? TeamColour.fallback }
    func firstColour(placeId: String, hex: Hex) -> String? {
        places.first { $0.id == placeId }?.first[hex].map { colour(for: $0.by) }
    }

    /// Called with the same accepted samples as My map, regardless of which map is open.
    @discardableResult
    mutating func visit(_ points: [Coordinate], at: Date, only placeIDs: Set<String>? = nil) -> Int {
        guard you?.walksCount == true else { return 0 }
        var cache = TeamCoverageCache(places: places)
        return visit(points, at: at, only: placeIDs, cache: &cache)
    }

    /// The live phone and replay worker each own a cache. Keeping it outside the
    /// Codable map prevents SwiftUI's value snapshots from copying a 50k-tile union
    /// on the next GPS fix, and prevents sharing mutable caches with detached work.
    @discardableResult
    mutating func visit(_ points: [Coordinate], at: Date, only placeIDs: Set<String>? = nil, cache: inout TeamCoverageCache) -> Int {
        guard let you, you.walksCount else { return 0 }
        var gained = 0
        for i in places.indices where placeIDs?.contains(places[i].id) != false {
            let fresh = places[i].city.visit(points, within: cache.shapes[places[i].id]!)
            if !fresh.isEmpty {
                for hex in fresh { places[i].first[hex] = TeamDiscovery(by: you.userId, at: at.ms) }
                // A bounded batch keeps retries below the backend's 1,000 tile limit.
                let sorted = fresh.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
                for start in stride(from: 0, to: sorted.count, by: 400) {
                    pendingTiles.append(TeamTileBatch(placeId: places[i].id, hexes: Array(sorted[start..<min(start + 400, sorted.count)]), at: at.ms))
                }
                for hex in fresh where cache.uncovered.insert(hex).inserted { gained += 1 }
            }
            let touched = Set(points.map { places[i].city.grid.hex(containing: $0) })
            for (id, hex) in places[i].city.stickers ?? [:] where touched.contains(hex) && secrets[id] == nil {
                secrets[id] = TeamDiscovery(by: you.userId, at: at.ms)
                pendingSecrets[id] = at.ms
            }
        }
        return gained
    }

    mutating func queueTrail(_ walk: Walk) {
        guard let you, you.walksCount, you.sharing == .tilesAndTrail, excludedWalks?.contains(walk.id) != true else { return }
        let clientId = walk.id.uuidString
        let queued = Set(trails.filter { $0.by == you.userId }.map(\.walkClientId) + pendingTrails.map(\.id))
        guard queued.contains(clientId) || queued.count < 64 else { return }
        let route = TeamCoverage.route(for: walk.points, cities: cities)
        guard !route.segments.isEmpty else { return }
        queueRoute(route, walkClientId: walk.id.uuidString)
    }

    mutating func queueRoute(_ route: TeamRoute, walkClientId: String) {
        guard you?.walksCount == true, you?.sharing == .tilesAndTrail, !route.segments.isEmpty else { return }
        let pending = pendingTrails.first { $0.id == walkClientId }
        if pending?.route == route { return }
        if pending == nil, trails.contains(where: { $0.by == you?.userId && $0.walkClientId == walkClientId && $0.route == route }) { return }
        let ids = Set(trails.filter { $0.by == you?.userId }.map(\.walkClientId) + pendingTrails.map(\.id))
        guard ids.contains(walkClientId) || ids.count < 64 else { return }
        let previous = max(trailVersions?[walkClientId] ?? 0, pending?.updatedAt ?? 0)
        let version = max(Date.now.ms, previous + 1)
        if trailVersions == nil { trailVersions = [:] }
        trailVersions?[walkClientId] = version
        pendingTrails.removeAll { $0.id == walkClientId }
        pendingTrails.append(TeamPendingTrail(walkClientId: walkClientId, route: route, updatedAt: version))
    }

    /// Server credit wins over optimistic local credit, even for an older offline walk.
    mutating func merge(_ snapshot: TeamSnapshot, cities downloaded: [String: City], trails downloadedTrails: [TeamTrail]) {
        name = snapshot.team.name
        createdBy = snapshot.team.createdBy
        inviteCode = snapshot.team.inviteCode
        members = snapshot.members
        let old = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        places = snapshot.places.compactMap { remote in
            guard var city = downloaded[remote.placeId] ?? old[remote.placeId]?.city else { return nil }
            var first = snapshot.isFull ? [:] : (old[remote.placeId]?.first ?? [:])
            // A full pull rebuilds the union but retains unsent coverage.
            if snapshot.isFull { city.visited = [] }
            for tile in snapshot.tiles where tile.placeId == remote.placeId {
                let hex = Hex(q: tile.q, r: tile.r)
                city.visited.insert(hex)
                city.tiles.insert(hex)
                first[hex] = TeamDiscovery(by: tile.by, at: tile.at)
            }
            for batch in pendingTiles where batch.placeId == remote.placeId {
                for (index, hex) in batch.hexes.enumerated() {
                    city.visited.insert(hex)
                    city.tiles.insert(hex)
                    if first[hex] == nil { first[hex] = TeamDiscovery(by: you?.userId ?? "", at: batch.discoveredAt?[index] ?? batch.at) }
                }
            }
            return TeamPlace(placeId: remote.placeId, clientId: remote.clientId, city: city, first: first)
        }
        trails = downloadedTrails.filter { trail in members.contains { $0.userId == trail.by && $0.sharing == .tilesAndTrail } }
        secrets = Dictionary(snapshot.secrets.map { ($0.secretId, TeamDiscovery(by: $0.by, at: $0.at)) }, uniquingKeysWith: { first, _ in first })
        for (id, at) in pendingSecrets where secrets[id] == nil { secrets[id] = TeamDiscovery(by: you?.userId ?? "", at: at) }
        enforcePreferences()
        since = snapshot.serverTime
    }
}

nonisolated struct TeamCoverageCache: Sendable {
    var shapes: [String: BoundaryShape]
    var uncovered: Set<Hex>
    init(places: [TeamPlace]) {
        shapes = Dictionary(places.map { ($0.id, $0.city.shape()) }, uniquingKeysWith: { first, _ in first })
        uncovered = Set(places.flatMap { $0.city.visited })
    }
}

nonisolated enum TeamCoverage {
    static func replay(_ team: TeamMap, walks: [Walk], includeTiles: Bool = true, placeIDs: Set<String>? = nil) -> TeamMap {
        var team = team
        guard team.you?.walksCount == true else {
            team.enforcePreferences()
            return team
        }
        let walks = walks.filter { team.excludedWalks?.contains($0.id) != true }
        let originalBatches = team.pendingTiles.count
        var cache = TeamCoverageCache(places: team.places)
        for walk in walks.sorted(by: { $0.startedAt < $1.startedAt }) {
            if includeTiles { _ = team.visit(CoverageTracer.samples(for: walk.points), at: walk.startedAt, only: placeIDs, cache: &cache) }
        }
        // Preserve each tile's first discovery time, then pack a place's replay
        // into 400-tile batches rather than one tiny batch per historic walk.
        let replayBatches = team.pendingTiles.dropFirst(originalBatches)
        var byPlace: [String: [Hex: Double]] = [:]
        for batch in replayBatches {
            for hex in batch.hexes { byPlace[batch.placeId, default: [:]][hex] = min(byPlace[batch.placeId]?[hex] ?? batch.at, batch.at) }
        }
        team.pendingTiles = Array(team.pendingTiles.prefix(originalBatches))
        for (place, discoveries) in byPlace {
            let hexes = discoveries.keys.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
            for start in stride(from: 0, to: hexes.count, by: 400) {
                let chunk = Array(hexes[start..<min(start + 400, hexes.count)])
                let dates = chunk.map { discoveries[$0]! }
                team.pendingTiles.append(TeamTileBatch(placeId: place, hexes: chunk, at: dates.min()!, discoveredAt: dates))
            }
        }
        for walk in walks.sorted(by: { $0.startedAt > $1.startedAt }) { team.queueTrail(walk) }
        team.replayedPlaces.formUnion(team.places.map(\.id))
        return team
    }

    /// Keep separate accepted steps so rejected driving fixes and GPS gaps are never joined.
    static func route(for points: [TrackPoint], cities: [City]) -> TeamRoute {
        var tracer = CoverageTracer()
        var runs: [[Coordinate]] = []
        for point in points {
            let step = tracer.add(point)
            guard !step.samples.isEmpty else { continue }
            if let origin = step.origin, runs.last?.last == origin {
                runs[runs.count - 1].append(contentsOf: step.samples)
            } else {
                runs.append((step.origin.map { [$0] } ?? []) + step.samples)
            }
        }
        return clip(runs, to: cities)
    }

    /// Split each segment at every boundary and hole intersection, then keep only
    /// intervals inside the union. Two inside endpoints alone aren't enough for
    /// concave suburbs or a route crossing a private hole in the boundary.
    static func clip(_ runs: [[Coordinate]], to cities: [City]) -> TeamRoute {
        guard let grid = cities.first?.grid else { return TeamRoute(segments: []) }
        let projection = grid.projection
        let shapes = cities.map { BoundaryShape($0.boundary, projection: projection) }
        let rings = cities.flatMap { $0.boundary.polygons.flatMap { [$0.outer] + $0.holes } }.map { $0.map(projection.project) }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
        var out: [[Coordinate]] = []
        for run in runs {
            var current: [Coordinate] = []
            for (a, b) in zip(run, run.dropFirst()) {
                let start = projection.project(a), end = projection.project(b), d = end - start
                var cuts = [0.0, 1.0]
                for ring in rings where ring.count > 2 {
                    for i in ring.indices {
                        let p = ring[i], e = ring[(i + 1) % ring.count] - p
                        let denominator = cross(d, e)
                        guard abs(denominator) > 1e-12 else { continue }
                        let t = cross(p - start, e) / denominator
                        let u = cross(p - start, d) / denominator
                        if t > 0, t < 1, u >= 0, u <= 1 { cuts.append(t) }
                    }
                }
                cuts.sort()
                for (lo, hi) in zip(cuts, cuts.dropFirst()) where hi - lo > 1e-10 {
                    let midpoint = start + d * ((lo + hi) / 2)
                    if shapes.contains(where: { $0.contains(midpoint) }) {
                        let from = a.lerp(to: b, lo), to = a.lerp(to: b, hi)
                        if let last = current.last, last.distance(to: from) > 0.01 {
                            if current.count > 1 { out.append(current) }
                            current = []
                        }
                        if current.isEmpty { current.append(from) }
                        current.append(to)
                    } else {
                        if current.count > 1 { out.append(current) }
                        current = []
                    }
                }
            }
            if current.count > 1 { out.append(current) }
        }
        return TeamRoute(segments: out)
    }
}

/// Include every boundary hex, not only streets: walking can uncover a non-street tile too.
nonisolated struct TeamPlaceBounds: Encodable {
    var minQ: Int32; var maxQ: Int32; var minR: Int32; var maxR: Int32
    init(city: City) throws {
        let hexes = City.hexes(inside: city.shape(), grid: city.grid).union(city.tiles)
        guard let minQ = hexes.map(\.q).min(), let maxQ = hexes.map(\.q).max(),
              let minR = hexes.map(\.r).min(), let maxR = hexes.map(\.r).max(),
              [minQ, maxQ, minR, maxR].allSatisfy({ abs(Int($0)) <= 1_000_000 }),
              Int(maxQ) - Int(minQ) <= 10_000, Int(maxR) - Int(minR) <= 10_000 else {
            throw ConvexError.coded("INVALID_ARGUMENT", "This place is too large for a team map. Choose a smaller place.")
        }
        self.minQ = minQ; self.maxQ = maxQ; self.minR = minR; self.maxR = maxR
    }
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
