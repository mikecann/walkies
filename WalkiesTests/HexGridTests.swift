import Foundation
import simd
import Testing
@testable import Walkies

struct HexGridTests {
    let geographe = Coordinate(lat: -33.638, lon: 115.386)
    var grid: HexGrid { HexGrid.world }

    // Kept identical to convex/grid.test.ts and design/grid.md.
    @Test(arguments: [
        [0.0, 0, 0, 0],
        [-33.65, 115.35, 145525, -44196],
        [-33.638, 115.386, 145554, -44178],
        [51.5074, -0.1278, -37383, 74493],
        [0, 30, 32101, 0],
        [-33.65, -115.35, -101329, -44196],
        [40.7128, -74.006, -106770, 55164],
        [85, 179.9, 81661, 221671],
        [-85, -179.9, -81661, -221671],
    ]) func worldExamplesAndCoordinateHexCentreRoundTrips(example: [Double]) {
        let coordinate = Coordinate(lat: example[0], lon: example[1])
        let hex = Hex(q: Int32(example[2]), r: Int32(example[3]))
        #expect(grid.hex(containing: coordinate) == hex)
        #expect(grid.hex(containing: grid.projection.unproject(grid.centre(of: hex))) == hex)
    }

    @Test func neighboursAndHalfTiesHaveAStableOrder() {
        #expect(Hex(q: 0, r: 0).neighbours == [Hex(q: 1, r: 0), Hex(q: 1, r: -1), Hex(q: 0, r: -1),
                                            Hex(q: -1, r: 0), Hex(q: -1, r: 1), Hex(q: 0, r: 1)])
        #expect(HexGrid.round(q: 0.5, r: 0) == Hex(q: 1, r: 0))
        #expect(HexGrid.round(q: -0.5, r: 0) == Hex(q: -1, r: 0))
        #expect(HexGrid.round(q: 0.5, r: 0.5) == Hex(q: 1, r: 0))
        #expect(HexGrid.round(q: -0.5, r: -0.5) == Hex(q: -1, r: 0))
        #expect(HexGrid.round(q: 0.4, r: 0.4) == Hex(q: 0, r: 1))
    }

    @Test func projectedSizeIsGroundMetresAtBusselton() {
        let c = Coordinate(lat: -33.65, lon: 115.35)
        let p = grid.projection.project(c)
        // Ground distance uses the same spherical radius as the specified projection.
        // Coordinate.distance uses the mean Earth radius, about 0.056 m different here.
        for direction in [SIMD2(50.0, 0), SIMD2(0.0, 50)] {
            let ground = c.distance(to: grid.projection.unproject(p + direction))
                * WorldProjection.earthRadius / LocalProjection.earthRadius
            #expect(abs(ground - 50) < 0.001)
        }
    }

    @Test func adjacentPlacesUseTheSameBorderTilesRegardlessOfBuildOrder() {
        let base = grid.centre(of: grid.hex(containing: geographe))
        func place(_ west: Double, _ east: Double) -> PlaceResult {
            let points = [SIMD2(west, -300), SIMD2(east, -300), SIMD2(east, 300), SIMD2(west, 300)]
                .map { grid.projection.unproject(base + $0) }
            return PlaceResult(id: 1, name: "Neighbour", detail: "", kind: "suburb",
                               boundary: Boundary(polygons: [GeoPolygon(outer: points, holes: [])]), area: 0)
        }
        // The border cuts a hex 20 projected metres east of its centre.
        let east = CityBuilder.build(from: place(20, 300), ways: [], walks: [])
        var west = CityBuilder.build(from: place(-300, 20), ways: [], walks: [])
        let whole = CityBuilder.build(from: place(-300, 300), ways: [], walks: [])
        #expect(west.grid == east.grid)
        #expect(west.tiles.isDisjoint(with: east.tiles))
        #expect(west.tiles.union(east.tiles) == whole.tiles)
        let a = grid.projection.unproject(base + SIMD2(15, 0))
        let b = grid.projection.unproject(base + SIMD2(25, 0))
        let hex = grid.hex(containing: a)
        #expect(east.grid.hex(containing: b) == hex)
        #expect(west.tiles.contains(hex))
        #expect(!east.tiles.contains(hex)) // Membership follows the centre, not the GPS point.
        #expect(west.visit([b], within: west.shape()) == [hex])
    }

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
        #expect(abs(flat - a.distance(to: b)) < 2)
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
        let hex = grid.hex(containing: Coordinate(lat: -33.65, lon: 115.35))
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
