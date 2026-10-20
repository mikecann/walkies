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
        // Out of the car and walking again: counts from the first spot on foot.
        #expect(tracer.add(fix(east: 15, at: 20)).samples.isEmpty)
        #expect(!tracer.add(fix(east: 30, at: 31)).samples.isEmpty)
    }

    @Test func anHourIndoorsIsNotAWalk() {
        // What a phone left on the kitchen bench really logs: a fix a second or two,
        // wandering up to ~30 m around one spot, ~14 m accuracy, GPS speed ~0.1 m/s.
        var rng = SystemRandomNumberGenerator()
        var tracer = CoverageTracer()
        var total = 0.0
        for second in stride(from: 0.0, through: 3600, by: 2) {
            let east = Double.random(in: -20...20, using: &rng)
            var point = fix(east: east, at: second, accuracy: 14)
            point.speed = Double.random(in: 0...0.25, using: &rng)
            total += tracer.add(point).distance
        }
        #expect(total == 0)
    }

    @Test func wobbleWithNoGPSSpeedIsCaughtByTheMotionChip() {
        var tracer = CoverageTracer()
        var total = 0.0
        for second in stride(from: 0.0, through: 600, by: 2) {
            var point = fix(east: second.truncatingRemainder(dividingBy: 40) - 20, at: second, accuracy: 14)
            point.still = true
            total += tracer.add(point).distance
        }
        #expect(total == 0)
    }

    @Test func slowDriftWithNoSpeedReadingDoesNotCount() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0, accuracy: 6))
        // 18 minutes later the GPS has crept 10 m.
        #expect(tracer.add(fix(east: 10, at: 1080, accuracy: 6)).samples.isEmpty)
    }

    @Test func aRealWalkStillCountsInFull() {
        // A fix a second at 1.4 m/s for 500 m.
        var tracer = CoverageTracer()
        var total = 0.0
        for second in stride(from: 0.0, through: 357, by: 1) {
            var point = fix(east: second * 1.4, at: second, accuracy: 6)
            point.speed = 1.4
            total += tracer.add(point).distance
        }
        #expect(total > 480 && total <= 501)
        #expect(CoverageTracer.distance(for: (0...357).map { second in
            var point = fix(east: Double(second) * 1.4, at: Double(second), accuracy: 6)
            point.speed = 1.4
            return point
        }) == total)
    }

    @Test func stoppingForASniffDoesNotBreakTheWalk() {
        var tracer = CoverageTracer()
        _ = tracer.add(fix(east: 0, at: 0))
        #expect(!tracer.add(fix(east: 20, at: 15)).samples.isEmpty)
        // A minute sniffing a fence post.
        for second in stride(from: 16.0, through: 75, by: 3) {
            var point = fix(east: 21, at: second)
            point.speed = 0.1
            #expect(tracer.add(point).samples.isEmpty)
        }
        // Walking on picks up from the last spot that counted.
        var walkingOn = fix(east: 40, at: 90)
        walkingOn.speed = 1.3
        let step = tracer.add(walkingOn)
        #expect(abs(step.distance - 20) < 0.5)
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
        let grid = HexGrid.world
        // A 1 km square city with the walk starting in the middle and heading east, out of it.
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map(projection.unproject), holes: [])])
        let shape = BoundaryShape(boundary, projection: grid.projection)
        let inside = Set(grid.hexes(from: shape.lo, to: shape.hi))
        var city = City(name: "Test", detail: "", boundary: boundary, tiles: inside, visited: [])

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
        let grid = HexGrid.world
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map(projection.unproject), holes: [])])
        // No tiles listed at all, as if it were beach with no mapped paths.
        var city = City(name: "Test", detail: "", boundary: boundary, tiles: [], visited: [])

        let fresh = city.visit([start], within: BoundaryShape(boundary, projection: grid.projection))
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

struct PendingWalkTests {
    let home = LocalProjection(origin: Coordinate(lat: -33.638, lon: 115.386))

    func point(_ x: Double, _ y: Double, at t: Double) -> TrackPoint {
        let c = home.unproject(SIMD2(x, y))
        return TrackPoint(lat: c.lat, lon: c.lon, time: t, accuracy: 10)
    }

    @Test func gpsWobbleAtHomeNeverGetsFarEnoughToCount() {
        // Bouncing 40 m either way for ten minutes adds up to kilometres of "distance".
        let wobble = (0..<120).map { index in
            let x: Double = index % 2 == 0 ? -40 : 40
            let y = Double(index % 3) * 20 - 20
            return point(x, y, at: Double(index) * 5)
        }
        #expect(AppModel.displacement(of: wobble) < AppModel.autoWalkConfirmDistance)
    }

    @Test func aRealWalkDoes() {
        let walk = (0..<40).map { point(Double($0) * 6, 0, at: Double($0) * 5) }
        #expect(AppModel.displacement(of: walk) >= AppModel.autoWalkConfirmDistance)
    }
}
