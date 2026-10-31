package com.mikecann.walkies.map

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.floor

/** The clouds over the rest of the world (CloudBlanket.kt): what goes in each of its tiles. */
class CloudBlanketTest {
    private val busselton = Coordinate(-33.65, 115.35)

    /** The tile at [z] with Busselton in it. */
    private fun tile(z: Int): Pair<Int, Int> {
        val n = (1L shl z).toDouble()
        return floor(MapPoints.x(busselton.lon) / MapPoints.WORLD * n).toInt() to floor(MapPoints.y(busselton.lat) / MapPoints.WORLD * n).toInt()
    }

    private fun puffsIn(z: Int, x: Int, y: Int): List<CloudBlanket.Puff> {
        val box = CloudBlanket.tileBox(z, x, y)
        return CloudBlanket.puffs(CloudBlanket.level(z), box[0], box[1], box[2], box[3])
    }

    @Test
    fun coarserHexesFurtherOutAndTheWorldGridFromStreetLevelIn() {
        assertEquals(CloudBlanket.FINEST_ZOOM, CloudBlanket.level(0))
        assertEquals(1, CloudBlanket.level(CloudBlanket.FINEST_ZOOM - 1))
        assertEquals(0, CloudBlanket.level(CloudBlanket.FINEST_ZOOM))
        assertEquals(0, CloudBlanket.level(CloudBlanket.MAX_ZOOM))
        assertEquals(HexGrid.SIZE * MapPoints.perGridUnit, CloudBlanket.hexSize(0), 1e-9)
        assertEquals(CloudBlanket.hexSize(0) * 8, CloudBlanket.hexSize(3), 1e-6)
    }

    @Test
    fun puffsStayAbout40To80PointsAcrossAtEveryZoomOutToTheWorld() {
        for (z in 0..CloudBlanket.FINEST_ZOOM) {
            val (x, y) = tile(z)
            val puffs = puffsIn(z, x, y)
            val span = MapPoints.WORLD / (1L shl z)
            // As Mapbox first draws the tile, and just before it swaps to the next zoom's, twice the size.
            val across = puffs.map { it.radius * 2 / span * CloudBlanket.TILE_POINTS }.average()
            assertTrue("zoom $z: $across points", across in 38.0..46.0)
            assertTrue("zoom $z: ${across * 2} points", across * 2 in 76.0..92.0)
        }
    }

    @Test
    fun aTileOnlyEverHoldsAFewHundredPuffs() {
        // A few hundred for every 256 points of tile, the same on screen whatever the tile size.
        val most = 400 * (CloudBlanket.TILE_POINTS / 256) * (CloudBlanket.TILE_POINTS / 256)
        for (z in 0..CloudBlanket.MAX_ZOOM) {
            val (x, y) = tile(z)
            val n = puffsIn(z, x, y).size
            assertTrue("zoom $z: $n puffs", n in 1..most)
        }
        // The whole world in one tile, zoomed right out, still covered.
        val world = puffsIn(0, 0, 0)
        assertTrue(world.size in 100..most)
        assertTrue(world.minOf { it.x - it.radius } <= 0 && world.maxOf { it.x + it.radius } >= MapPoints.WORLD)
        assertTrue(world.minOf { it.y - it.radius } <= 0 && world.maxOf { it.y + it.radius } >= MapPoints.WORLD)
    }

    @Test
    fun puffsAreAnchoredToTheWorldSoNeighbouringTilesAgree() {
        val z = 13
        val (x, y) = tile(z)
        val edge = CloudBlanket.tileBox(z, x, y)[2]
        fun key(p: CloudBlanket.Puff) = listOf(p.x, p.y, p.radius, p.variant.toDouble())
        // Puffs across the edge between two tiles are in both, exactly the same.
        val west = puffsIn(z, x, y).filter { it.x - it.radius < edge && it.x + it.radius > edge }.map(::key)
        val east = puffsIn(z, x + 1, y).filter { it.x - it.radius < edge && it.x + it.radius > edge }.map(::key)
        assertTrue(west.isNotEmpty())
        assertEquals(west, east)
        // And a bigger box has every puff a smaller one has, in the same order.
        val box = CloudBlanket.tileBox(z, x, y)
        val small = CloudBlanket.puffs(2, box[0], box[1], box[2], box[3]).map(::key)
        val big = CloudBlanket.puffs(2, box[0] - 1e5, box[1] - 1e5, box[2] + 1e5, box[3] + 1e5).map(::key)
        assertEquals(small, big.filter { it in small })
        assertTrue(big.zipWithNext().all { (a, b) -> a[1] <= b[1] })
    }

    @Test
    fun atStreetLevelThePuffsAreTheOnesAPlaceWouldHave() {
        val base = HexGrid.hex(containing = busselton)
        val corners = listOf(Vec2(-300.0, -300.0), Vec2(300.0, -300.0), Vec2(300.0, 300.0), Vec2(-300.0, 300.0))
        val boundary = Boundary(listOf(GeoPolygon(corners.map { HexGrid.projection.unproject(HexGrid.centre(base) + it) }, emptyList())))
        val tiles = (-2..2).flatMap { q -> (-2..2).map { r -> Hex(base.q + q, base.r + r) } }.toSet()
        val field = CloudField(listOf(City(name = "Test", detail = "", boundary = boundary, tiles = tiles, visited = emptySet())))
        val x = MapPoints.x(busselton.lon)
        val y = MapPoints.y(busselton.lat)
        val blanket = CloudBlanket.puffs(0, x - 3000, y - 3000, x + 3000, y + 3000)
        for (puff in field.puffs) {
            val same = blanket.minBy { abs(it.x - puff.x) + abs(it.y - puff.y) }
            assertEquals(puff.x, same.x, 1e-3)
            assertEquals(puff.y, same.y, 1e-3)
            assertEquals(puff.radius, same.radius, 1e-6)
            assertEquals(puff.variant, same.variant)
        }
    }

    @Test
    fun hexCentresInMapPointsMatchTheGrid() {
        val hex = HexGrid.hex(containing = busselton)
        val c = HexGrid.projection.unproject(HexGrid.centre(hex))
        assertEquals(MapPoints.x(c.lon), CloudBlanket.centreX(hex), 1e-3)
        assertEquals(MapPoints.y(c.lat), CloudBlanket.centreY(hex), 1e-3)
    }

    /** About [metres] east from [start], a fix a second at walking pace (or [speed]). */
    private fun walk(start: Coordinate, metres: Int, speed: Double = 1.4): Walk {
        val dLon = 1.0 / (111_320 * kotlin.math.cos(start.lat * Math.PI / 180))
        val points = (0..(metres / speed).toInt()).map { i ->
            TrackPoint(start.lat, start.lon + i * speed * dLon, 1_790_000_000.0 + i, 5.0, speed = speed)
        }
        return Walk(startedAt = SwiftDate.epoch(1_790_000_000.0), points = points)
    }

    @Test
    fun walkedHexesAreTheOnesTheReplayWouldUncoverOnFootOnly() {
        val stroll = walk(busselton, 400)
        val hexes = CloudBlanket.walkedHexes(listOf(stroll))
        assertEquals(CoverageTracer.samples(stroll.points).map { HexGrid.hex(containing = it) }.toSet(), hexes)
        // 400 m east crosses a handful of hexes about 87 m across.
        assertTrue(hexes.size in 4..12)
        // Driving doesn't clear anything.
        assertTrue(CloudBlanket.walkedHexes(listOf(walk(Coordinate(-33.7, 115.2), 2000, speed = 15.0))).isEmpty())
    }

    @Test
    fun theWalkYoureOnGoesOnTopOfTheSavedOnes() {
        val walked = WalkedHexes()
        val saved = listOf(walk(busselton, 300))
        val before = walked.of(saved, null)
        val now = walk(Coordinate(-33.66, 115.36), 300)
        val during = walked.of(saved, now)
        assertTrue(during.containsAll(before))
        assertEquals(before + CloudBlanket.walkedHexes(listOf(now)), during)
        // Once it's saved, it's in the saved ones.
        assertEquals(during, walked.of(saved + now, null))
    }

    @Test
    fun theIndexFindsExactlyTheWalkedHexesInABox() {
        val base = HexGrid.hex(containing = busselton)
        // Two clusters 30 km apart, so they're in different buckets.
        val hexes = (0 until 40).flatMap { i -> listOf(Hex(base.q + i, base.r - i / 2), Hex(base.q + 400 + i, base.r)) }.toSet()
        val index = WalkedIndex(hexes)
        fun found(x0: Double, y0: Double, x1: Double, y1: Double): Set<Pair<Double, Double>> {
            val out = HashSet<Pair<Double, Double>>()
            index.forEach(x0, y0, x1, y1) { x, y -> out.add(x to y) }
            return out
        }
        val x = CloudBlanket.centreX(base)
        val y = CloudBlanket.centreY(base)
        val boxes = listOf(
            doubleArrayOf(x - 5000, y - 5000, x + 5000, y + 5000),
            doubleArrayOf(x + 1000, y - 20000, x + 300_000, y + 20000),
            doubleArrayOf(0.0, 0.0, MapPoints.WORLD, MapPoints.WORLD),
        )
        for (b in boxes) {
            val expected = hexes.map { CloudBlanket.centreX(it) to CloudBlanket.centreY(it) }
                .filter { (cx, cy) -> cx >= b[0] && cx <= b[2] && cy >= b[1] && cy <= b[3] }.toSet()
            assertEquals(expected, found(b[0], b[1], b[2], b[3]))
        }
        assertEquals(hexes.size, found(0.0, 0.0, MapPoints.WORLD, MapPoints.WORLD).size)
    }

    @Test
    fun aNewlyWalkedHexRepaintsTheTilesItsHoleReaches() {
        val z = 16
        val (x, y) = tile(z)
        val box = CloudBlanket.tileBox(z, x, y)
        // A hex right on the tile's east edge reaches into the tile next door too.
        val onEdge = HexGrid.hex(containing = MapPoints.coordinate(box[2], (box[1] + box[3]) / 2))
        assertTrue(CloudBlanket.touches(z, x, y, listOf(onEdge)))
        assertTrue(CloudBlanket.touches(z, x + 1, y, listOf(onEdge)))
        assertFalse(CloudBlanket.touches(z, x + 3, y, listOf(onEdge)))
        assertFalse(CloudBlanket.touches(z, x, y, emptyList()))
    }

    @Test
    fun placesAreKeptAsRingsWithTheirHoles() {
        val outer = listOf(Coordinate(-33.6, 115.3), Coordinate(-33.6, 115.4), Coordinate(-33.7, 115.4), Coordinate(-33.7, 115.3))
        val hole = listOf(Coordinate(-33.64, 115.34), Coordinate(-33.64, 115.36), Coordinate(-33.66, 115.36))
        val places = BlanketPlaces(listOf(Boundary(listOf(GeoPolygon(outer, listOf(hole))))))
        val place = places.places.single()
        assertEquals(2, place.rings.size)
        assertEquals(MapPoints.x(115.3), place.box[0], 1e-6)
        assertEquals(MapPoints.y(-33.6), place.box[1], 1e-6)
        assertEquals(MapPoints.x(115.4), place.box[2], 1e-6)
        assertEquals(MapPoints.y(-33.7), place.box[3], 1e-6)
    }
}
