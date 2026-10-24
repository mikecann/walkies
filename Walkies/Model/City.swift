import CryptoKit
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
    /// When each walked tile was last walked, for the mist (Mist.swift). Nil for places
    /// saved before it was kept; the app works it out once from the saved walks.
    var lastWalked: LastWalked?

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

    /// The id a place gets from its OSM relation, the same on every phone, so a suburb
    /// added on two phones before they've synced (say by adding itself on both) is one
    /// place in the account rather than two. A name-based UUID (version 3), which is
    /// what Java's UUID.nameUUIDFromBytes makes on Android.
    static func id(forOSM osmId: Int) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data("walkies:osm-relation:\(osmId)".utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Takes in another copy of the same place, from the account or another phone:
    /// every tile either has walked, credits, secrets and mist dates. Street tiles come
    /// from the copy with the newer WalkableRule, so a phone that hasn't updated can't
    /// bring busy roads back. Tiles you've been to stay. True if this copy had anything
    /// the other didn't, so it should be sent back up.
    mutating func merge(_ other: City) -> Bool {
        let localCredits = Set((tileCredits ?? []).map(\.id))
        let otherCredits = Set((other.tileCredits ?? []).map(\.id))
        let localStreets = streetsVersion ?? 0, otherStreets = other.streetsVersion ?? 0
        let hadMore = !visited.isSubset(of: other.visited) || !localCredits.isSubset(of: otherCredits)
            || localStreets > otherStreets || lastWalked?.hasLater(than: other.lastWalked) == true
        mergeTileCredits(from: other)
        mergeLastWalked(other.lastWalked)
        visited.formUnion(other.visited)
        stickers = (stickers ?? [:]).merging(other.stickers ?? [:]) { _, theirs in theirs }
        if otherStreets > localStreets {
            replaceStreetTiles(other.tiles, roads: other.roads, version: otherStreets)
        } else if otherStreets < localStreets {
            replaceStreetTiles(tiles, roads: nil, version: localStreets)
        } else {
            tiles.formUnion(other.tiles)
        }
        roads = roads ?? other.roads
        return hadMore
    }

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
