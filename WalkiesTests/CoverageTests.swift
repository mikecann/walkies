import Foundation
import Testing
@testable import Walkies

struct CoverageTests {
    let start = Coordinate(lat: -33.638, lon: 115.386)

    /// A fix `metres` east of the start, `seconds` after it.
    func fix(east metres: Double, at seconds: Double, accuracy: Double = 5) -> TrackPoint {
        let p = LocalProjection(origin: start).unproject(SIMD2(metres, 0))
        return TrackPoint(lat: p.lat, lon: p.lon, time: 1_000_000 + seconds, accuracy: accuracy)
    }

    @Test func walkingFillsTheGapBetweenFixes() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        let step = tracer.add(fix(east: 45, at: 36))
        #expect(step.samples.count == 5)
        #expect(abs(step.distance - 45) < 0.5)
    }

    @Test func inaccurateFixesAreIgnored() {
        var tracer = CoverageTracer()
        #expect(tracer.add(fix(east: 0, at: 0, accuracy: 80)).samples.isEmpty)
        #expect(tracer.add(fix(east: 0, at: 0, accuracy: -1)).samples.isEmpty)
    }

    @Test func drivingDoesNotCount() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        let step = tracer.add(fix(east: 140, at: 10)) // 14 m/s
        #expect(step.samples.isEmpty)
        #expect(step.distance == 0)
    }

    @Test func bigGapsAreNotJoinedUp() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        let step = tracer.add(fix(east: 400, at: 300))
        #expect(step.samples.count == 1)
        #expect(step.distance == 0)
    }

    @Test func walkingAStreetUncoversTilesInsideTheCity() {
        let projection = LocalProjection(origin: start)
        let grid = HexGrid(projection: projection, size: 50)
        // A 1 km square city with the walk starting in the middle and heading east, out of it.
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map(projection.unproject), holes: [])])
        let shape = BoundaryShape(boundary, projection: projection)
        let inside = Set(grid.hexes(from: shape.lo, to: shape.hi))
        var city = City(name: "Test", detail: "", grid: grid, boundary: boundary, tiles: inside, visited: [])

        let walk = stride(from: 0.0, through: 900, by: 15).map { fix(east: $0, at: $0 / 1.4) }
        let fresh = city.visit(CoverageTracer.samples(for: walk), within: shape)

        // ~500 m inside the city on tiles ~87 m wide: about 6 tiles, none outside it.
        #expect((5...8).contains(fresh.count))
        #expect(fresh.isSubset(of: inside))
        #expect(city.visited == fresh)

        // Walking the same way again finds nothing new.
        #expect(city.visit(CoverageTracer.samples(for: walk), within: shape).isEmpty)
    }

    @Test func visitingAnUnlistedTileInsideTheBoundaryAddsIt() {
        let projection = LocalProjection(origin: start)
        let grid = HexGrid(projection: projection, size: 50)
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map(projection.unproject), holes: [])])
        // No tiles listed at all, as if it were beach with no mapped paths.
        var city = City(name: "Test", detail: "", grid: grid, boundary: boundary, tiles: [], visited: [])

        let fresh = city.visit([start], within: BoundaryShape(boundary, projection: projection))
        #expect(fresh.count == 1)
        #expect(city.tiles == fresh)
        #expect(city.progress == 1)
    }

    @Test func percentText() {
        #expect(0.0.percentText == "0%")
        #expect(0.004.percentText == "0.4%")
        #expect(0.237.percentText == "23%")
        #expect(1.0.percentText == "100%")
    }

    @Test func sampleAlongAWay() {
        let projection = LocalProjection(origin: start)
        let line = [SIMD2(0.0, 0.0), SIMD2(95, 0), SIMD2(95, 35)].map(projection.unproject)
        let samples = CityBuilder.samples(along: line)
        #expect(samples.count == 1 + 10 + 4)
    }
}
