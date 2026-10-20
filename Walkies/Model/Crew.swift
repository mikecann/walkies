import Foundation

nonisolated enum CrewSharing: String, Codable, CaseIterable, Sendable {
    case tiles, tilesAndTrail
    var title: String { self == .tiles ? "Tiles only" : "Tiles and trail" }
    var detail: String {
        self == .tiles ? "Share the tiles you uncover, without your route." : "Share tiles and your route inside this crew's places."
    }
}

nonisolated enum CrewColour: String, Codable, CaseIterable, Sendable {
    case teal, orange, purple, rose, blue, green
    static let fallback = "grey"
}

nonisolated struct CrewMember: Codable, Sendable, Identifiable {
    var userId: String
    var name: String
    var colour: String
    var sharing: CrewSharing
    var walksCount: Bool
    var joinedAt: Double
    var isYou: Bool
    var id: String { userId }
}

nonisolated struct CrewDiscovery: Codable, Sendable {
    var by: String
    var at: Double
}

nonisolated struct CrewPlace: Codable, Sendable, Identifiable {
    var placeId: String
    var clientId: String
    var city: City
    var first: [Hex: CrewDiscovery] = [:]
    var id: String { placeId }
}

/// Deliberately contains no raw GPS fixes or personal walk metadata.
nonisolated struct CrewRoute: Codable, Sendable, Equatable {
    var segments: [[Coordinate]]
}

nonisolated struct CrewTrail: Codable, Sendable {
    var walkClientId: String
    var by: String
    var at: Double
    var route: CrewRoute
}

nonisolated struct CrewTileBatch: Codable, Sendable, Identifiable {
    var id = UUID()
    var placeId: String
    var hexes: [Hex]
    var at: Double
}

nonisolated struct CrewPendingPlace: Codable, Sendable, Identifiable {
    var city: City
    var file: String?
    var id: UUID { city.id }
}

nonisolated struct CrewPendingTrail: Codable, Sendable, Identifiable {
    var walkClientId: String
    var route: CrewRoute
    /// Keep the storage id across retries; each row owns a dedicated file.
    var file: String?
    var id: String { walkClientId }
}

nonisolated struct CrewMap: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var createdBy: String
    var inviteCode: String
    var members: [CrewMember] = []
    var places: [CrewPlace] = []
    var trails: [CrewTrail] = []
    var secrets: [String: CrewDiscovery] = [:]
    var since: Double?
    var pendingPlaces: [CrewPendingPlace] = []
    var pendingTiles: [CrewTileBatch] = []
    var pendingTrails: [CrewPendingTrail] = []
    /// Local-only jobs, persisted before the clipping worker starts. Never uploaded.
    var routeWork: [Walk] = []
    var pendingSecrets: [String: Double] = [:]
    /// Places needing an initial replay, persisted so an interrupted join resumes.
    var replayedPlaces: Set<String> = []

    var you: CrewMember? { members.first(where: \.isYou) }
    var cities: [City] { places.map(\.city) }
    var waiting: Int { pendingPlaces.count + pendingTiles.count + pendingTrails.count + pendingSecrets.count + routeWork.count }
    var inviteURL: URL { Backend.site.appending(path: "join/\(inviteCode)") }

    func memberName(_ id: String) -> String { members.first { $0.userId == id }?.name ?? "Past member" }
    func colour(for userId: String) -> String { members.first { $0.userId == userId }?.colour ?? CrewColour.fallback }
    func firstColour(placeId: String, hex: Hex) -> String? {
        places.first { $0.id == placeId }?.first[hex].map { colour(for: $0.by) }
    }

    /// Called with the same accepted samples as My map, regardless of which map is open.
    @discardableResult
    mutating func visit(_ points: [Coordinate], at: Date, only placeIDs: Set<String>? = nil) -> Int {
        guard let you, you.walksCount else { return 0 }
        let alreadyUncovered = Set(places.flatMap { $0.city.visited })
        var uncovered = Set<Hex>()
        for i in places.indices where placeIDs?.contains(places[i].id) != false {
            let fresh = places[i].city.visit(points, within: places[i].city.shape())
            if !fresh.isEmpty {
                for hex in fresh { places[i].first[hex] = CrewDiscovery(by: you.userId, at: at.ms) }
                // A bounded batch keeps retries below the backend's 1,000 tile limit.
                let sorted = fresh.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
                for start in stride(from: 0, to: sorted.count, by: 400) {
                    pendingTiles.append(CrewTileBatch(placeId: places[i].id, hexes: Array(sorted[start..<min(start + 400, sorted.count)]), at: at.ms))
                }
                uncovered.formUnion(fresh)
            }
            let touched = Set(points.map { places[i].city.grid.hex(containing: $0) })
            for (id, hex) in places[i].city.stickers ?? [:] where touched.contains(hex) && secrets[id] == nil {
                secrets[id] = CrewDiscovery(by: you.userId, at: at.ms)
                pendingSecrets[id] = at.ms
            }
        }
        return uncovered.subtracting(alreadyUncovered).count
    }

    mutating func queueTrail(_ walk: Walk) {
        guard let you, you.walksCount, you.sharing == .tilesAndTrail else { return }
        let route = CrewCoverage.route(for: walk.points, cities: cities)
        guard !route.segments.isEmpty else { return }
        pendingTrails.removeAll { $0.walkClientId == walk.id.uuidString }
        pendingTrails.append(CrewPendingTrail(walkClientId: walk.id.uuidString, route: route))
    }

    /// Server credit wins over optimistic local credit, even for an older offline walk.
    mutating func merge(_ snapshot: CrewSnapshot, cities downloaded: [String: City], trails downloadedTrails: [CrewTrail]) {
        name = snapshot.crew.name
        createdBy = snapshot.crew.createdBy
        inviteCode = snapshot.crew.inviteCode
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
                first[hex] = CrewDiscovery(by: tile.by, at: tile.at)
            }
            for batch in pendingTiles where batch.placeId == remote.placeId {
                for hex in batch.hexes {
                    city.visited.insert(hex)
                    city.tiles.insert(hex)
                    if first[hex] == nil { first[hex] = CrewDiscovery(by: you?.userId ?? "", at: batch.at) }
                }
            }
            return CrewPlace(placeId: remote.placeId, clientId: remote.clientId, city: city, first: first)
        }
        trails = downloadedTrails.filter { trail in members.contains { $0.userId == trail.by && $0.sharing == .tilesAndTrail } }
        secrets = Dictionary(snapshot.secrets.map { ($0.secretId, CrewDiscovery(by: $0.by, at: $0.at)) }, uniquingKeysWith: { first, _ in first })
        for (id, at) in pendingSecrets where secrets[id] == nil { secrets[id] = CrewDiscovery(by: you?.userId ?? "", at: at) }
        if you?.sharing != .tilesAndTrail { pendingTrails = []; routeWork = [] }
        since = snapshot.serverTime
    }
}

nonisolated enum CrewCoverage {
    static func replay(_ crew: CrewMap, walks: [Walk], includeTiles: Bool = true, placeIDs: Set<String>? = nil) -> CrewMap {
        var crew = crew
        guard crew.you?.walksCount == true else { return crew }
        for walk in walks.sorted(by: { $0.startedAt < $1.startedAt }) {
            if includeTiles { _ = crew.visit(CoverageTracer.samples(for: walk.points), at: walk.startedAt, only: placeIDs) }
            crew.queueTrail(walk)
        }
        crew.replayedPlaces.formUnion(crew.places.map(\.id))
        return crew
    }

    /// Keep separate accepted steps so rejected driving fixes and GPS gaps are never joined.
    static func route(for points: [TrackPoint], cities: [City]) -> CrewRoute {
        var tracer = CoverageTracer()
        let runs: [[Coordinate]] = points.map { point in
            let step = tracer.add(point)
            guard !step.samples.isEmpty else { return [] }
            return (step.origin.map { [$0] } ?? []) + step.samples
        }.filter { !$0.isEmpty }
        return clip(runs, to: cities)
    }

    /// Split each segment at every boundary and hole intersection, then keep only
    /// intervals inside the union. Two inside endpoints alone aren't enough for
    /// concave suburbs or a route crossing a private hole in the boundary.
    static func clip(_ runs: [[Coordinate]], to cities: [City]) -> CrewRoute {
        guard let grid = cities.first?.grid else { return CrewRoute(segments: []) }
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
        return CrewRoute(segments: out)
    }
}
