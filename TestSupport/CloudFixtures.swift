import Foundation
@testable import Walkies

// Shared by both test targets, WalkiesTests and WalkiesTimingTests (see the note at
// the top of WalkiesTimingTests/BakedLayerTests.swift), and copied into the macOS
// model tests by scripts/test-progression-model.sh, so it needs only the model.

/// Suburbs for the cloud tests.
enum CloudFixtures {
    static let start = Coordinate(lat: -33.638, lon: 115.386)

    static func hex(q: Int32, r: Int32) -> Hex {
        let base = HexGrid.world.hex(containing: start)
        return Hex(q: base.q + q, r: base.r + r)
    }

    static func city(tiles: Set<Hex>, visited: Set<Hex>, roads: [RoadLine]? = nil) -> City {
        let projection = HexGrid.world.projection
        let base = HexGrid.world.centre(of: hex(q: 0, r: 0))
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map { projection.unproject(base + $0) }, holes: [])])
        return City(
            name: "Test", detail: "", boundary: boundary,
            tiles: tiles, visited: visited, roads: roads
        )
    }

    /// A block of street tiles, then the same with the middle one walked.
    static func clearingField() -> (before: CloudField, after: CloudField) {
        var tiles = Set<Hex>()
        for q in -4...4 {
            for r in -4...4 { tiles.insert(hex(q: Int32(q), r: Int32(r))) }
        }
        let before = city(tiles: tiles, visited: [])
        var after = before
        after.visited = [hex(q: 0, r: 0)]
        return (CloudField(city: before), CloudField(city: after))
    }
}
