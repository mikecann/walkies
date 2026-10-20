package com.mikecann.walkies.grid

import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.CityBuilder
import com.mikecann.walkies.place.GeoPolygon
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

class HexGridTest {
    private val grid = HexGrid
    private val geographe = Coordinate(-33.638, 115.386)

    // Kept identical to HexGridTests.swift, convex/grid.test.ts and design/grid.md.
    private val examples = listOf(
        listOf(0.0, 0.0, 0.0, 0.0),
        listOf(-33.65, 115.35, 145525.0, -44196.0),
        listOf(-33.638, 115.386, 145554.0, -44178.0),
        listOf(51.5074, -0.1278, -37383.0, 74493.0),
        listOf(0.0, 30.0, 32101.0, 0.0),
        listOf(-33.65, -115.35, -101329.0, -44196.0),
        listOf(40.7128, -74.006, -106770.0, 55164.0),
        listOf(85.0, 179.9, 81661.0, 221671.0),
        listOf(-85.0, -179.9, -81661.0, -221671.0),
    )

    @Test
    fun worldExamplesAndCoordinateHexCentreRoundTrips() {
        for ((lat, lon, q, r) in examples) {
            val coordinate = Coordinate(lat, lon)
            val hex = Hex(q.toInt(), r.toInt())
            assertEquals("($lat, $lon)", hex, grid.hex(containing = coordinate))
            assertEquals("($lat, $lon) centre", hex, grid.hex(containing = grid.projection.unproject(grid.centre(hex))))
            val back = grid.projection.unproject(grid.projection.project(coordinate))
            assertEquals(lat, back.lat, 1e-9)
            assertEquals(lon, back.lon, 1e-9)
        }
    }

    @Test
    fun busseltonProjectsToTheDocumentedPoint() {
        val p = grid.projection.project(Coordinate(-33.65, 115.35))
        assertEquals(10689089.322164, p.x, 1e-5)
        assertEquals(-3314686.399223, p.y, 1e-5)
        assertEquals(0.8324379983891649, WorldProjection.scale, 1e-15)
    }

    @Test
    fun neighboursAndHalfTiesHaveAStableOrder() {
        assertEquals(
            listOf(Hex(1, 0), Hex(1, -1), Hex(0, -1), Hex(-1, 0), Hex(-1, 1), Hex(0, 1)),
            Hex(0, 0).neighbours,
        )
        assertEquals(Hex(1, 0), HexGrid.round(0.5, 0.0))
        assertEquals(Hex(-1, 0), HexGrid.round(-0.5, 0.0))
        assertEquals(Hex(1, 0), HexGrid.round(0.5, 0.5))
        assertEquals(Hex(-1, 0), HexGrid.round(-0.5, -0.5))
        assertEquals(Hex(0, 1), HexGrid.round(0.4, 0.4))
    }

    @Test
    fun negativeZeroIsCanonical() {
        val hex = HexGrid.round(-0.1, -0.1)
        assertEquals(Hex(0, 0), hex)
        assertEquals("Hex(q=0, r=0)", hex.toString())
    }

    @Test
    fun cornerOrderAndInclusiveCentreBounds() {
        val h = grid.hex(containing = Coordinate(-33.65, 115.35))
        val c = grid.centre(h)
        assertEquals(h, grid.hex(at = c))
        assertEquals(listOf(h), grid.hexes(c, c))
        grid.corners(h).map(grid.projection::project).forEachIndexed { i, p ->
            assertEquals(50.0, p.distance(c), 1e-6)
            val angle = (60 * i - 30) * PI / 180
            assertEquals(50 * cos(angle), p.x - c.x, 1e-6)
            assertEquals(50 * sin(angle), p.y - c.y, 1e-6)
        }
    }

    @Test
    fun projectedSizeIsGroundMetresAtBusselton() {
        val c = Coordinate(-33.65, 115.35)
        val p = grid.projection.project(c)
        // Ground distance uses the same spherical radius as the specified projection.
        // Coordinate.distance uses the mean Earth radius, about 0.056 m different here.
        for (direction in listOf(Vec2(50.0, 0.0), Vec2(0.0, 50.0))) {
            val ground = c.distance(grid.projection.unproject(p + direction)) *
                WorldProjection.EARTH_RADIUS / LocalProjection.EARTH_RADIUS
            assertEquals(50.0, ground, 0.001)
        }
    }

    @Test
    fun adjacentPlacesUseTheSameBorderTilesRegardlessOfBuildOrder() {
        val base = grid.centre(grid.hex(containing = geographe))
        fun place(west: Double, east: Double): Boundary {
            val points = listOf(Vec2(west, -300.0), Vec2(east, -300.0), Vec2(east, 300.0), Vec2(west, 300.0))
                .map { grid.projection.unproject(base + it) }
            return Boundary(listOf(GeoPolygon(points, emptyList())))
        }
        // The border cuts a hex 20 projected metres east of its centre.
        val east = CityBuilder.build("Neighbour", "", 1, place(20.0, 300.0), emptyList())
        val west = CityBuilder.build("Neighbour", "", 1, place(-300.0, 20.0), emptyList())
        val whole = CityBuilder.build("Neighbour", "", 1, place(-300.0, 300.0), emptyList())
        assertTrue(west.tiles.intersect(east.tiles).isEmpty())
        assertEquals(whole.tiles, west.tiles + east.tiles)
        val a = grid.projection.unproject(base + Vec2(15.0, 0.0))
        val b = grid.projection.unproject(base + Vec2(25.0, 0.0))
        val hex = grid.hex(containing = a)
        assertEquals(hex, grid.hex(containing = b))
        assertTrue(hex in west.tiles)
        assertFalse(hex in east.tiles) // Membership follows the centre, not the GPS point.
        assertEquals(setOf(hex), west.visit(listOf(b), west.shape()).second)
    }

    @Test
    fun projectionRoundTrips() {
        val point = Coordinate(-33.63, 115.40)
        val back = grid.projection.unproject(grid.projection.project(point))
        assertTrue(back.distance(point) < 0.01)
    }

    @Test
    fun projectionMatchesRealDistance() {
        val a = Coordinate(-33.640, 115.380)
        val b = Coordinate(-33.632, 115.392)
        val flat = grid.projection.project(a).distance(grid.projection.project(b))
        assertTrue(abs(flat - a.distance(b)) < 2)
    }

    @Test
    fun centreOfAHexIsInThatHex() {
        for (q in -20..20) for (r in -20..20) {
            val hex = Hex(q, r)
            assertEquals(hex, grid.hex(at = grid.centre(hex)))
        }
    }

    @Test
    fun cornersAreTheRightDistanceFromTheCentre() {
        val hex = grid.hex(containing = Coordinate(-33.65, 115.35))
        val centre = grid.projection.unproject(grid.centre(hex))
        for (corner in grid.corners(hex)) assertEquals(50.0, corner.distance(centre), 0.5)
    }

    @Test
    fun pointsMapToTheNearestCentre() {
        // Every point is closer to its own hex's centre than to any neighbour's.
        val random = Random(42)
        repeat(2000) {
            val p = Vec2(random.nextDouble(-2000.0, 2000.0), random.nextDouble(-2000.0, 2000.0))
            val hex = grid.hex(at = p)
            val own = p.distance(grid.centre(hex))
            assertTrue(own <= 50.001)
            for (n in hex.neighbours) assertTrue(own <= p.distance(grid.centre(n)) + 0.001)
        }
    }

    @Test
    fun rectangleCountMatchesArea() {
        val hexes = grid.hexes(Vec2(-1000.0, -1000.0), Vec2(1000.0, 1000.0))
        val expected = 4_000_000 / grid.tileArea
        assertTrue(abs(hexes.size - expected) / expected < 0.05)
        assertEquals(hexes.size, hexes.toSet().size)
    }
}
