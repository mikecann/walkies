package com.mikecann.walkies.map

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class CloudFieldTest {
    private val start = Coordinate(-33.638, 115.386)

    private fun hex(q: Int, r: Int): Hex {
        val base = HexGrid.hex(containing = start)
        return Hex(base.q + q, base.r + r)
    }

    private fun city(tiles: Set<Hex>, visited: Set<Hex>): City {
        val base = HexGrid.centre(hex(0, 0))
        val corners = listOf(Vec2(-500.0, -500.0), Vec2(500.0, -500.0), Vec2(500.0, 500.0), Vec2(-500.0, 500.0))
        val boundary = Boundary(listOf(GeoPolygon(corners.map { HexGrid.projection.unproject(base + it) }, emptyList())))
        return City(name = "Test", detail = "", boundary = boundary, tiles = tiles, visited = visited)
    }

    @Test
    fun aPuffForEveryCloudedTileNorthFirst() {
        val test = city(setOf(hex(0, 0), hex(1, 0)), emptySet())
        val field = CloudField(listOf(test))
        assertEquals(test.cloudCover().clouded.size, field.puffs.size)
        assertTrue(field.puffs.zipWithNext().all { (a, b) -> a.y <= b.y })
        assertTrue(field.clearings.isEmpty())
    }

    @Test
    fun cloudsAreTheSameEveryTime() {
        val tiles = setOf(hex(0, 0), hex(3, -2), hex(-4, 1))
        val a = CloudField(listOf(city(tiles, emptySet())))
        val b = CloudField(listOf(city(tiles.reversed().toSet(), emptySet())))
        val numbers = { field: CloudField -> field.puffs.flatMap { listOf(it.x, it.y, it.radius, it.phase) }.toDoubleArray() }
        assertArrayEquals(numbers(a), numbers(b), 0.0)
        assertEquals(a.puffs.map { it.variant }, b.puffs.map { it.variant })
    }

    @Test
    fun splitMixMatchesTheReference() {
        // SplitMix64 seeded with 1, from the reference C implementation.
        val rng = SplitMix64(1)
        assertEquals(0x910a2dec89025cc1uL.toLong(), rng.next())
        assertEquals(0xbeeb8da1658eec67uL.toLong(), rng.next())
    }

    @Test
    fun puffsAreAboutTheRightSize() {
        val field = CloudField(listOf(city(setOf(hex(0, 0)), emptySet())))
        val size = HexGrid.SIZE * MapPoints.perGridUnit
        for (puff in field.puffs) {
            assertTrue(puff.radius >= size * CloudField.SPREAD * 0.88 && puff.radius <= size * CloudField.SPREAD * 1.23)
            assertTrue(puff.variant in 0 until CloudField.SPRITE_COUNT)
        }
    }

    @Test
    fun walkedTilesBecomeClearings() {
        val walked = hex(0, 0)
        val field = CloudField(listOf(city(setOf(walked, hex(1, 0)), setOf(walked))))
        assertTrue(field.clearings.any { it.tile == walked })
        assertTrue(field.puffs.none { it.tile == walked })
        assertEquals(CloudField.VISITED, field.outlines.first { it.tile == walked }.kind)
        assertEquals(CloudField.OPEN, field.outlines.first { it.tile == hex(1, 0) }.kind)
    }

    @Test
    fun mapPointsMatchMapKit() {
        // MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 0)) is the middle of the world.
        assertEquals(MapPoints.WORLD / 2, MapPoints.x(0.0), 1e-6)
        assertEquals(MapPoints.WORLD / 2, MapPoints.y(0.0), 1e-6)
        val lat = -33.638
        assertEquals(lat, MapPoints.lat(MapPoints.y(lat)), 1e-9)
        assertEquals(115.386, MapPoints.lon(MapPoints.x(115.386)), 1e-9)
    }

    @Test
    fun theHomographyRecoversAFlatMap() {
        // A flat, north-up map 1000 pixels wide showing 2000 map points across.
        val projection = Projection()
        val w = 1000f
        val h = 2000f
        val ox = 1_000_000.0
        val oy = 2_000_000.0
        val ground = DoubleArray(10)
        for (i in 0 until 4) {
            ground[i * 2] = ox + Projection.SCREEN[i * 2] * w * 2
            ground[i * 2 + 1] = oy + Projection.SCREEN[i * 2 + 1] * h * 2
        }
        ground[8] = ox + w
        ground[9] = oy + h
        projection.update(ground, w, h, ground[8], ground[9])
        assertTrue(projection.valid)
        projection.point(ox + 600.0, oy + 400.0)
        assertEquals(300f, projection.x, 0.01f)
        assertEquals(200f, projection.y, 0.01f)
        assertEquals(0.5, projection.centreScale, 1e-6)
        assertTrue(abs(projection.rx - 500f) < 0.01f)
    }
}
