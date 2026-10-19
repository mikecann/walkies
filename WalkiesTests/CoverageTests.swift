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

    @Test func cyclingSpeedDoesNotCount() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        var ride = fix(east: 9, at: 2) // 4.5 m/s between fixes would pass on its own...
        ride.speed = 4.5                // ...but the GPS says you're doing 16 km/h
        #expect(tracer.add(ride).samples.isEmpty)
    }

    @Test func joggingCounts() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        var jog = fix(east: 30, at: 10)
        jog.speed = 3.0
        #expect(!tracer.add(jog).samples.isEmpty)
    }

    @Test func motionChipSaysCarSoNothingCounts() {
        var tracer = CoverageTracer()
        var parked = fix(east: 0, at: 0)
        parked.wheels = true
        #expect(tracer.add(parked).samples.isEmpty)
        var crawling = fix(east: 5, at: 10) // 0.5 m/s in traffic, still in the car
        crawling.wheels = true
        #expect(tracer.add(crawling).samples.isEmpty)
        // Out of the car and walking again.
        #expect(!tracer.add(fix(east: 15, at: 20)).samples.isEmpty)
    }

    @Test func gpsJitterAtWalkingPaceStillCounts() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        var step = fix(east: 4, at: 1) // 4 m in a second looks quick, but the GPS speed is a stroll
        step.speed = 1.4
        #expect(!tracer.add(step).samples.isEmpty)
    }

    @Test func bigGapsAreNotJoinedUp() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        #expect(tracer.add(fix(east: 400, at: 300)).samples.isEmpty)
        // Counting picks up again from where it landed.
        #expect(!tracer.add(fix(east: 415, at: 310)).samples.isEmpty)
    }

    @Test func aLoneFirstFixDoesNotCount() {
        var tracer = CoverageTracer()
        #expect(tracer.add(fix(east: 0, at: 0)).samples.isEmpty)
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
