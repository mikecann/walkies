import Foundation

nonisolated struct City: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// The rest of the place name, e.g. "Busselton, Western Australia, Australia".
    var detail: String
    var grid: HexGrid
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
    /// street or path (bush, wetland, canals) don't count towards 100%, so instead of
    /// staying clouded forever, each one clears when you walk the counting tile nearest it.
    func cloudCover() -> (clouded: Set<Hex>, clear: Set<Hex>) {
        let shape = shape()
        let area = grid.hexes(from: shape.lo, to: shape.hi)
        let inside = Set(area.filter { shape.contains(grid.centre(of: $0)) })
        var clear = visited
        for (hex, owner) in nearestTile(for: inside.subtracting(tiles), within: Set(area)) where visited.contains(owner) {
            clear.insert(hex)
        }
        return (inside.union(tiles).subtracting(clear), clear)
    }

    /// The nearest counting tile to each of these hexes, found by spreading out from
    /// every counting tile at once. Seeded in a fixed order, so ties always go the same
    /// way and a hex never flips between clear and clouded from one launch to the next.
    private func nearestTile(for hexes: Set<Hex>, within area: Set<Hex>) -> [Hex: Hex] {
        var queue = tiles.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        var owner = Dictionary(uniqueKeysWithValues: queue.map { ($0, $0) })
        var next = 0
        while next < queue.count {
            let hex = queue[next]
            next += 1
            for n in hex.neighbours where owner[n] == nil && area.contains(n) {
                owner[n] = owner[hex]
                queue.append(n)
            }
        }
        return owner.filter { hexes.contains($0.key) }
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
