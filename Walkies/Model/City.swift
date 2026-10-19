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
    var createdAt = Date()

    var progress: Double {
        tiles.isEmpty ? 0 : Double(visited.count) / Double(tiles.count)
    }

    func shape() -> BoundaryShape {
        BoundaryShape(boundary, projection: grid.projection)
    }

    /// Every tile whose centre is inside the boundary, walkable or not.
    func boundaryHexes() -> Set<Hex> {
        Self.hexes(inside: shape(), grid: grid)
    }

    static func hexes(inside shape: BoundaryShape, grid: HexGrid) -> Set<Hex> {
        Set(grid.hexes(from: shape.lo, to: shape.hi).filter { shape.contains(grid.centre(of: $0)) })
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
