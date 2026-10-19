import Foundation
import simd
import Testing
@testable import Walkies

struct HexGridTests {
    let geographe = Coordinate(lat: -33.638, lon: 115.386)
    var grid: HexGrid { HexGrid(projection: LocalProjection(origin: geographe), size: 50) }

    @Test func projectionRoundTrips() {
        let projection = grid.projection
        let point = Coordinate(lat: -33.63, lon: 115.40)
        let back = projection.unproject(projection.project(point))
        #expect(back.distance(to: point) < 0.01)
    }

    @Test func projectionMatchesRealDistance() {
        let projection = grid.projection
        let a = Coordinate(lat: -33.640, lon: 115.380)
        let b = Coordinate(lat: -33.632, lon: 115.392)
        let flat = simd_length(projection.project(a) - projection.project(b))
        #expect(abs(flat - a.distance(to: b)) < 1)
    }

    @Test func centreOfAHexIsInThatHex() {
        for q in -20...20 {
            for r in -20...20 {
                let hex = Hex(q: Int32(q), r: Int32(r))
                #expect(grid.hex(at: grid.centre(of: hex)) == hex)
            }
        }
    }

    @Test func cornersAreTheRightDistanceFromTheCentre() {
        let hex = Hex(q: 7, r: -3)
        let centre = grid.projection.unproject(grid.centre(of: hex))
        for corner in grid.corners(of: hex) {
            #expect(abs(corner.distance(to: centre) - 50) < 0.5)
        }
    }

    @Test func pointsMapToTheNearestCentre() {
        // Every point is closer to its own hex's centre than to any neighbour's.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let p = SIMD2(Double.random(in: -2000...2000, using: &rng), Double.random(in: -2000...2000, using: &rng))
            let hex = grid.hex(at: p)
            let own = simd_distance(p, grid.centre(of: hex))
            #expect(own <= 50.001)
            for (dq, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)] {
                let n = Hex(q: hex.q + Int32(dq), r: hex.r + Int32(dr))
                #expect(own <= simd_distance(p, grid.centre(of: n)) + 0.001)
            }
        }
    }

    @Test func rectangleCountMatchesArea() {
        let hexes = grid.hexes(from: SIMD2(-1000, -1000), to: SIMD2(1000, 1000))
        let expected = 4_000_000 / grid.tileArea
        #expect(abs(Double(hexes.count) - expected) / expected < 0.05)
        #expect(Set(hexes).count == hexes.count)
    }

    @Test func hexEncodesCompactly() throws {
        let data = try JSONEncoder().encode([Hex(q: 3, r: -4)])
        #expect(String(decoding: data, as: UTF8.self) == "[[3,-4]]")
        #expect(try JSONDecoder().decode([Hex].self, from: data) == [Hex(q: 3, r: -4)])
    }
}

struct BoundaryTests {
    let square = Boundary(polygons: [GeoPolygon(
        outer: [
            Coordinate(lat: -33.640, lon: 115.380),
            Coordinate(lat: -33.640, lon: 115.390),
            Coordinate(lat: -33.630, lon: 115.390),
            Coordinate(lat: -33.630, lon: 115.380),
        ],
        holes: [[
            Coordinate(lat: -33.636, lon: 115.384),
            Coordinate(lat: -33.636, lon: 115.386),
            Coordinate(lat: -33.634, lon: 115.386),
            Coordinate(lat: -33.634, lon: 115.384),
        ]]
    )])

    @Test func containsRespectsHoles() {
        let projection = LocalProjection(origin: square.centre)
        let shape = BoundaryShape(square, projection: projection)
        #expect(shape.contains(projection.project(Coordinate(lat: -33.638, lon: 115.382))))
        #expect(!shape.contains(projection.project(Coordinate(lat: -33.635, lon: 115.385))))
        #expect(!shape.contains(projection.project(Coordinate(lat: -33.620, lon: 115.385))))
    }

    @Test func areaIsAboutRight() {
        let shape = BoundaryShape(square, projection: LocalProjection(origin: square.centre))
        // 0.01° x 0.01° at this latitude is about 926 m x 1112 m, minus a ~185 m x 222 m hole.
        let expected = 926.0 * 1112 - 185.3 * 222.4
        #expect(abs(shape.area - expected) / expected < 0.01)
    }
}
