package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.LocalProjection
import com.mikecann.walkies.grid.Vec2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

class BoundaryTest {
    private val square = Boundary(listOf(GeoPolygon(
        outer = listOf(
            Coordinate(-33.640, 115.380),
            Coordinate(-33.640, 115.390),
            Coordinate(-33.630, 115.390),
            Coordinate(-33.630, 115.380),
        ),
        holes = listOf(listOf(
            Coordinate(-33.636, 115.384),
            Coordinate(-33.636, 115.386),
            Coordinate(-33.634, 115.386),
            Coordinate(-33.634, 115.384),
        )),
    )))

    @Test
    fun containsRespectsHoles() {
        val projection = LocalProjection(square.centre)
        val shape = BoundaryShape(square, projection)
        assertTrue(shape.contains(projection.project(Coordinate(-33.638, 115.382))))
        assertFalse(shape.contains(projection.project(Coordinate(-33.635, 115.385))))
        assertFalse(shape.contains(projection.project(Coordinate(-33.620, 115.385))))
    }

    @Test
    fun areaIsAboutRight() {
        val shape = BoundaryShape(square, LocalProjection(square.centre))
        // 0.01° x 0.01° at this latitude is about 926 m x 1112 m, minus a ~185 m x 222 m hole.
        val expected = 926.0 * 1112 - 185.3 * 222.4
        assertTrue(abs(shape.area - expected) / expected < 0.01)
    }
}

/** The cloud cover rules, from CloudTests.swift. */
class CloudCoverTest {
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
    fun wholeSuburbStartsUnderCloud() {
        val test = city(setOf(hex(0, 0), hex(1, 0)), emptySet())
        val cover = test.cloudCover()
        assertTrue(cover.clear.isEmpty())
        assertEquals(City.hexes(test.shape()), cover.clouded)
    }

    @Test
    fun walkingBesideBushClearsTheWholePatch() {
        // Two lone street tiles at opposite sides of the suburb; everything else is bush.
        val west = hex(-3, 0)
        val east = hex(4, 0)
        val test = city(setOf(west, east), setOf(west))
        val cover = test.cloudCover()
        assertTrue(west in cover.clear)
        assertTrue(hex(-4, 1) in cover.clear) // bush next to the walked street
        assertTrue(hex(4, 1) in cover.clear) // and all the bush it joins up with
        assertEquals(setOf(east), cover.clouded)
        assertTrue(cover.blocked.isEmpty())
        // Clearing bush doesn't change the score: only street tiles count.
        assertEquals(0.5, test.progress, 0.0)
    }

    @Test
    fun bushWalledInByUnwalkedStreetsStaysClouded() {
        // A pocket of bush with a ring of streets round it, and a walked street outside.
        val pocket = hex(0, 0)
        val ring = pocket.neighbours.toSet()
        val walked = hex(-3, 0)
        val cover = city(ring + walked, setOf(walked)).cloudCover()
        assertEquals(setOf(pocket), cover.blocked)
        assertTrue(pocket in cover.clouded)
        assertTrue(hex(3, 0) in cover.clear) // the bush outside the ring
    }

    @Test
    fun roadLinesDropClutter() {
        val line = listOf(Coordinate(-33.63, 115.38), Coordinate(-33.631, 115.381))
        val ways = listOf(
            OSMWay(mapOf("highway" to "residential"), line),
            OSMWay(mapOf("highway" to "footway"), line),
            OSMWay(mapOf("highway" to "footway", "footway" to "sidewalk"), line),
            OSMWay(mapOf("highway" to "footway", "footway" to "crossing"), line),
            OSMWay(mapOf("highway" to "service", "service" to "driveway"), line),
            OSMWay(mapOf("highway" to "service"), line),
            OSMWay(mapOf("highway" to "path"), listOf(line[0])),
        )
        assertEquals(
            listOf(RoadLine.Kind.Road, RoadLine.Kind.Path, RoadLine.Kind.Road),
            CityBuilder.roadLines(ways).map { it.kind },
        )
    }

    @Test
    fun percentText() {
        assertEquals("0%", 0.0.percentText)
        assertEquals("0.4%", 0.004.percentText)
        assertEquals("23%", 0.239.percentText)
    }
}

/** The shared street-cache fixture, the same blob the server's places:get returns. */
class PlaceDataTest {
    private fun fixture(name: String): String {
        val folder = System.getProperty("walkies.fixtures") ?: "../../shared/fixtures"
        return File(folder, "places/$name").readText()
    }

    @Test
    fun geographeBuildsAPlaceWithStreetsAndClouds() {
        val data = PlaceData.parse(fixture("geographe.json"))
        assertEquals(1, data.boundary.polygons.size)
        assertEquals(377, data.ways.size)
        // GeoJSON [lon, lat] for the boundary, [lat, lon] for streets: both should land in Busselton.
        val first = data.boundary.polygons[0].outer[0]
        assertEquals(-33.640964, first.lat, 1e-9)
        assertEquals(115.358643, first.lon, 1e-9)
        assertTrue(data.ways.all { way -> way.points.all { it.lat in -34.0..-33.0 && it.lon in 115.0..116.0 } })

        val city = CityBuilder.build("Geographe", "", null, data.boundary, data.ways)
        val inside = City.hexes(city.shape())
        assertTrue(city.tiles.isNotEmpty())
        assertTrue(city.tiles.size < inside.size)
        assertTrue(inside.containsAll(city.tiles))
        assertTrue(city.roads!!.isNotEmpty())
        assertEquals(inside, city.cloudCover().clouded)
        assertTrue(city.boundary.labelPoint.let { city.shape().contains(HexGrid.projection.project(it)) })
    }

    @Test
    fun theSpikeWalkClearsAStripAlongTheStreets() {
        val data = PlaceData.parse(fixture("geographe.json"))
        val city = CityBuilder.build("Geographe", "", null, data.boundary, data.ways)
        val (walked, route) = SpikeWalk.walk(city)
        assertTrue(route.size > 2)
        assertTrue(walked.visited.size > 10)
        assertTrue(walked.progress > 0 && walked.progress < 0.5)
        assertNotEquals(city.cloudCover().clouded, walked.cloudCover().clouded)
    }

    @Test(expected = PlaceData.Invalid::class)
    fun malformedFilesAreRejected() {
        PlaceData.parse("""{"boundary": [[[[115.38, -33.64], [115.39, -33.64]]]], "ways": []}""")
    }
}
