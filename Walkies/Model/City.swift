import Foundation

nonisolated struct City: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// The rest of the place name, e.g. "Busselton, Western Australia, Australia".
    var detail: String
    /// The grid is never saved: all places and all users use the world grid.
    var grid: HexGrid { .world }
    var osmId: Int? = nil
    var gridVersion: Int? = HexGrid.version
    var boundary: Boundary
    /// Tiles that count towards completion: every tile in the boundary with a street or
    /// path through it, plus any other tile in the boundary you've actually been to.
    var tiles: Set<Hex>
    var visited: Set<Hex>
    /// Streets and paths drawn as dotted lines over the clouds. Nil for cities
    /// saved before we kept them; the app fetches them again on launch.
    var roads: [RoadLine]?
    /// Which tile each lore sticker is hidden under, by lore id.
    var stickers: [String: Hex]?
    var createdAt = Date()
    /// When anything about it last changed on this phone, so sync knows to send it.
    var updatedAt: Date?
    /// Coverage from confirmed automatic outings too short to keep in walk history.
    /// These records travel with the place so tile quests retain their date and identity.
    var tileCredits: [TileCredit]?
    /// The WalkableRule.version its street tiles were worked out with. Nil for places
    /// built before busy roads were left out; the app redoes their tiles once.
    var streetsVersion: Int?

    struct TileCredit: Codable, Equatable, Sendable {
        var id: UUID
        var at: Date
        var hexes: Set<Hex>
    }

    mutating func mergeTileCredits(from other: City) {
        var credits = Dictionary((tileCredits ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for credit in other.tileCredits ?? [] {
            if var old = credits[credit.id] {
                old.hexes.formUnion(credit.hexes)
                old.at = min(old.at, credit.at)
                credits[credit.id] = old
            } else {
                credits[credit.id] = credit
            }
        }
        if !credits.isEmpty { tileCredits = credits.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    }

    var lastChanged: Date { updatedAt ?? createdAt }

    var progress: Double {
        tiles.isEmpty ? 0 : Double(visited.count) / Double(tiles.count)
    }

    func shape() -> BoundaryShape {
        BoundaryShape(boundary, projection: grid.projection)
    }

    static func hexes(inside shape: BoundaryShape, grid: HexGrid) -> Set<Hex> {
        Set(grid.hexes(from: shape.lo, to: shape.hi).filter { shape.contains(grid.centre(of: $0)) })
    }

    /// Which tiles in the boundary are under cloud and which are clear. Tiles with no
    /// street or path (bush, wetland, canals) don't count towards 100%, and can't be
    /// walked to. Instead, a whole patch of them clears at once the moment you walk a
    /// tile beside it, spreading through every no-path tile it touches.
    /// `blocked` is the no-path tiles still under cloud.
    func cloudCover() -> (clouded: Set<Hex>, clear: Set<Hex>, blocked: Set<Hex>) {
        let inside = InsideTiles.shared.hexes(in: self)
        let noPath = inside.subtracting(tiles)
        var clear = visited
        var queue = Array(visited)
        while let hex = queue.popLast() {
            for n in hex.neighbours where noPath.contains(n) && !clear.contains(n) {
                clear.insert(n)
                queue.append(n)
            }
        }
        return (inside.union(tiles).subtracting(clear), clear, noPath.subtracting(clear))
    }

    /// New street tiles from a newer WalkableRule, keeping everything you've done: the
    /// tiles you've been to (credits included) and the ones hiding a secret stay tiles.
    /// The rest of the place becomes no-path, so the clouds and % follow.
    mutating func replaceStreetTiles(_ streetTiles: Set<Hex>, roads: [RoadLine]?, version: Int) {
        var kept = streetTiles.union(visited)
        for credit in tileCredits ?? [] { kept.formUnion(credit.hexes) }
        kept.formUnion((stickers ?? [:]).values)
        tiles = kept
        if let roads { self.roads = roads }
        streetsVersion = version
    }

    /// Marks the tiles under these points as visited and returns the ones that are new.
    mutating func visit(_ points: [Coordinate], within shape: BoundaryShape) -> Set<Hex> {
        var fresh = Set<Hex>()
        for point in points {
            let h = grid.hex(containing: point)
            if visited.contains(h) || fresh.contains(h) { continue }
            guard tiles.contains(h) || shape.contains(grid.centre(of: h)) else { continue }
            fresh.insert(h)
        }
        visited.formUnion(fresh)
        tiles.formUnion(fresh)
        return fresh
    }
}

/// Every tile inside each place's boundary. Testing each one against the outline is
/// the slow part of working out the clouds, and it only changes with the boundary.
nonisolated final class InsideTiles: @unchecked Sendable {
    static let shared = InsideTiles()
    private let lock = NSLock()
    private var places: [UUID: (boundary: Boundary, hexes: Set<Hex>)] = [:]

    func hexes(in city: City) -> Set<Hex> {
        lock.lock()
        let saved = places[city.id]
        lock.unlock()
        if let saved, saved.boundary == city.boundary { return saved.hexes }
        let hexes = City.hexes(inside: city.shape(), grid: city.grid)
        lock.lock()
        places[city.id] = (city.boundary, hexes)
        lock.unlock()
        return hexes
    }
}

nonisolated struct RoadLine: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case road, path
    }

    var kind: Kind
    var points: [Coordinate]
}

nonisolated extension Double {
    /// "23%", or "0.4%" while you're just getting started.
    var percentText: String {
        let pct = self * 100
        if pct > 0, pct < 10 { return String(format: "%.1f%%", pct) }
        return "\(Int(pct.rounded(.down)))%"
    }
}
