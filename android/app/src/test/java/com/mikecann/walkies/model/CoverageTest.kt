package com.mikecann.walkies.model

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.LocalProjection
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.BoundaryShape
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.CityBuilder
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.place.percentText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.random.Random

/** CoverageTests.swift, case for case. */
class CoverageTest {
    private val start = Coordinate(-33.638, 115.386)

    /** A fix [metres] east of the start, [seconds] after it. */
    private fun fix(east: Double, at: Double, accuracy: Double = 5.0): TrackPoint {
        val p = LocalProjection(start).unproject(Vec2(east, 0.0))
        return TrackPoint(p.lat, p.lon, 1_000_000 + at, accuracy)
    }

    @Test
    fun walkingFillsTheGapBetweenFixes() {
        val tracer = CoverageTracer()
        tracer.add(fix(0.0, 0.0))
        val step = tracer.add(fix(45.0, 36.0))
        assertEquals(5, step.samples.size)
        assertTrue(abs(step.distance - 45) < 0.5)
    }

    @Test
    fun inaccurateFixesAreIgnored() {
        val tracer = CoverageTracer()
        assertTrue(tracer.add(fix(0.0, 0.0, accuracy = 80.0)).samples.isEmpty())
        assertTrue(tracer.add(fix(0.0, 0.0, accuracy = -1.0)).samples.isEmpty())
    }

    @Test
    fun drivingDoesNotCount() {
        val tracer = CoverageTracer()
        tracer.add(fix(0.0, 0.0))
        val step = tracer.add(fix(140.0, 10.0)) // 14 m/s
        assertTrue(step.samples.isEmpty())
        assertEquals(0.0, step.distance, 0.0)
    }

    @Test
    fun cyclingSpeedDoesNotCount() {
        val tracer = CoverageTracer()
        tracer.add(fix(0.0, 0.0))
        // 4.5 m/s between fixes would pass on its own, but the GPS says you're doing 16 km/h.
        val ride = fix(9.0, 2.0).copy(speed = 4.5)
        assertTrue(tracer.add(ride).samples.isEmpty())
    }

    @Test
    fun joggingCounts() {
        val tracer = CoverageTracer()
        tracer.add(fix(0.0, 0.0))
        val jog = fix(30.0, 10.0).copy(speed = 3.0)
        assertFalse(tracer.add(jog).samples.isEmpty())
    }

    @Test
    fun motionChipSaysCarSoNothingCounts() {
        val tracer = CoverageTracer()
        assertTrue(tracer.add(fix(0.0, 0.0).copy(wheels = true)).samples.isEmpty())
        // 0.5 m/s in traffic, still in the car.
        assertTrue(tracer.add(fix(5.0, 10.0).copy(wheels = true)).samples.isEmpty())
        // Out of the car and walking again: counts from the first spot on foot.
        assertTrue(tracer.add(fix(15.0, 20.0)).samples.isEmpty())
        assertFalse(tracer.add(fix(30.0, 31.0)).samples.isEmpty())
    }

    @Test
    fun anHourIndoorsIsNotAWalk() {
        // What a phone left on the kitchen bench really logs: a fix a second or two,
        // wandering up to ~30 m around one spot, ~14 m accuracy, GPS speed ~0.1 m/s.
        val tracer = CoverageTracer()
        var total = 0.0
        var second = 0.0
        while (second <= 3600) {
            val east = Random.nextDouble(-20.0, 20.0)
            val point = fix(east, second, accuracy = 14.0).copy(speed = Random.nextDouble(0.0, 0.25))
            total += tracer.add(point).distance
            second += 2
        }
        assertEquals(0.0, total, 0.0)
    }

    @Test
    fun wobbleWithNoGPSSpeedIsCaughtByTheMotionChip() {
        val tracer = CoverageTracer()
        var total = 0.0
        var second = 0.0
        while (second <= 600) {
            val point = fix(second % 40 - 20, second, accuracy = 14.0).copy(still = true)
            total += tracer.add(point).distance
            second += 2
        }
        assertEquals(0.0, total, 0.0)
    }

    @Test
    fun slowDriftWithNoSpeedReadingDoesNotCount() {
        val tracer = CoverageTracer()
        tracer.add(fix(0.0, 0.0, accuracy = 6.0))
        // 18 minutes later the GPS has crept 10 m.
        assertTrue(tracer.add(fix(10.0, 1080.0, accuracy = 6.0)).samples.isEmpty())
    }

    @Test
    fun aRealWalkStillCountsInFull() {
        // A fix a second at 1.4 m/s for 500 m.
        val points = (0..357).map { second -> fix(second * 1.4, second.toDouble(), accuracy = 6.0).copy(speed = 1.4) }
        val tracer = CoverageTracer()
        val total = points.sumOf { tracer.add(it).distance }
        assertTrue(total > 480 && total <= 501)
        assertEquals(total, CoverageTracer.distance(points), 0.0)
    }

    @Test
    fun stoppingForASniffDoesNotBreakTheWalk() {
        val tracer = CoverageTracer()
        tracer.add(fix(0.0, 0.0))
        assertFalse(tracer.add(fix(20.0, 15.0)).samples.isEmpty())
        // A minute sniffing a fence post.
        var second = 16.0
        while (second <= 75) {
            assertTrue(tracer.add(fix(21.0, second).copy(speed = 0.1)).samples.isEmpty())
            second += 3
        }
        // Walking on picks up from the last spot that counted.
        val step = tracer.add(fix(40.0, 90.0).copy(speed = 1.3))
        assertTrue(abs(step.distance - 20) < 0.5)
    }

    @Test
    fun bigGapsAreNotJoinedUp() {
        val tracer = CoverageTracer()
        tracer.add(fix(0.0, 0.0))
        assertTrue(tracer.add(fix(400.0, 300.0)).samples.isEmpty())
        // Counting picks up again from where it landed.
        assertFalse(tracer.add(fix(415.0, 310.0)).samples.isEmpty())
    }

    @Test
    fun aLoneFirstFixDoesNotCount() {
        assertTrue(CoverageTracer().add(fix(0.0, 0.0)).samples.isEmpty())
    }

    private fun square(): Boundary {
        val projection = LocalProjection(start)
        val corners = listOf(Vec2(-500.0, -500.0), Vec2(500.0, -500.0), Vec2(500.0, 500.0), Vec2(-500.0, 500.0))
        return Boundary(listOf(GeoPolygon(corners.map(projection::unproject), emptyList())))
    }

    @Test
    fun walkingAStreetUncoversTilesInsideTheCity() {
        // A 1 km square city with the walk starting in the middle and heading east, out of it.
        val boundary = square()
        val shape = BoundaryShape(boundary, HexGrid.projection)
        val inside = HexGrid.hexes(shape.lo, shape.hi).toSet()
        val city = City(name = "Test", detail = "", boundary = boundary, tiles = inside, visited = emptySet())

        val walk = (0..60).map { fix(it * 15.0, it * 15.0 / 1.4) }
        val (walked, fresh) = city.visit(CoverageTracer.samples(walk), shape)

        // ~500 m inside the city on tiles ~87 m wide: about 6 tiles, none outside it.
        assertTrue(fresh.size in 5..8)
        assertTrue(inside.containsAll(fresh))
        assertEquals(fresh, walked.visited)

        // Walking the same way again finds nothing new.
        assertTrue(walked.visit(CoverageTracer.samples(walk), shape).second.isEmpty())
    }

    @Test
    fun visitingAnUnlistedTileInsideTheBoundaryAddsIt() {
        val boundary = square()
        // No tiles listed at all, as if it were beach with no mapped paths.
        val city = City(name = "Test", detail = "", boundary = boundary, tiles = emptySet(), visited = emptySet())
        val (walked, fresh) = city.visit(listOf(start), BoundaryShape(boundary, HexGrid.projection))
        assertEquals(1, fresh.size)
        assertEquals(fresh, walked.tiles)
        assertEquals(1.0, walked.progress, 0.0)
    }

    @Test
    fun percentText() {
        assertEquals("0%", 0.0.percentText)
        assertEquals("0.4%", 0.004.percentText)
        assertEquals("23%", 0.237.percentText)
        assertEquals("100%", 1.0.percentText)
    }

    @Test
    fun sampleAlongAWay() {
        val projection = LocalProjection(start)
        val line = listOf(Vec2(0.0, 0.0), Vec2(95.0, 0.0), Vec2(95.0, 35.0)).map(projection::unproject)
        assertEquals(1 + 10 + 4, CityBuilder.samples(line).size)
    }
}

/** PendingWalkTests in CoverageTests.swift. */
class PendingWalkTest {
    private val home = LocalProjection(Coordinate(-33.638, 115.386))

    private fun point(x: Double, y: Double, at: Double): TrackPoint {
        val c = home.unproject(Vec2(x, y))
        return TrackPoint(c.lat, c.lon, at, 10.0)
    }

    @Test
    fun gpsWobbleAtHomeNeverGetsFarEnoughToCount() {
        // Bouncing 40 m either way for ten minutes adds up to kilometres of "distance".
        val wobble = (0 until 120).map { index ->
            val x = if (index % 2 == 0) -40.0 else 40.0
            val y = (index % 3) * 20.0 - 20
            point(x, y, index * 5.0)
        }
        assertTrue(AppModel.displacement(wobble) < AppModel.AUTO_WALK_CONFIRM_DISTANCE)
    }

    @Test
    fun aRealWalkDoes() {
        val walk = (0 until 40).map { point(it * 6.0, 0.0, it * 5.0) }
        assertTrue(AppModel.displacement(walk) >= AppModel.AUTO_WALK_CONFIRM_DISTANCE)
    }
}
