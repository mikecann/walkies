package com.mikecann.walkies.lore

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.LocalProjection
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.BoundaryShape
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.repoRoot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/** LoreTests.swift: which place gets each secret, and which tile it hides under. */
class LoreTest {
    private val start = Coordinate(-33.638, 115.386)

    /** A 1 km square suburb where every tile has a street, [east] metres east of the start. */
    private fun city(visited: Set<com.mikecann.walkies.grid.Hex> = emptySet(), east: Double = 0.0, detail: String = "Busselton", name: String = "Test"): City {
        val projection = LocalProjection(start)
        val corners = listOf(Vec2(-500.0, -500.0), Vec2(500.0, -500.0), Vec2(500.0, 500.0), Vec2(-500.0, 500.0)).map { it + Vec2(east, 0.0) }
        val boundary = Boundary(listOf(GeoPolygon(corners.map(projection::unproject), emptyList())))
        val tiles = City.hexes(BoundaryShape(boundary, HexGrid.projection), HexGrid)
        return City(name = name, detail = detail, boundary = boundary, tiles = tiles, visited = visited)
    }

    private fun assign(entries: List<LoreEntry>, cities: List<City>): Map<UUID, List<String>> =
        LoreLibrary.assign(entries, cities) { city, point -> city.shape().contains(city.grid.projection.project(point)) }
            .mapValues { (_, list) -> list.map { it.id } }

    private fun entry(id: String, at: Vec2? = null, suburb: String? = null): LoreEntry {
        val coordinate = at?.let { LocalProjection(start).unproject(it) }
        return LoreEntry(
            id = id, title = id, body = "", category = "history",
            place = coordinate?.let { LoreEntry.Place(id, it.lat, it.lon) },
            sticker = "", sources = emptyList(), suburb = suburb,
        )
    }

    @Test
    fun storiesAboutASpotGoUnderIt() {
        val test = city()
        val placed = test.placeStickers(listOf(entry("jetty", Vec2(200.0, -150.0))))
        val hex = placed["jetty"]
        assertNotNull(hex)
        val spot = test.grid.projection.project(LocalProjection(start).unproject(Vec2(200.0, -150.0)))
        assertTrue(test.grid.centre(hex!!).distance(spot) < 60)
    }

    @Test
    fun spotsOutsideTheSuburbGetScatteredInstead() {
        val test = city()
        val placed = test.placeStickers(listOf(entry("far-away", Vec2(5000.0, 5000.0))))
        assertTrue(placed["far-away"] in test.tiles)
    }

    @Test
    fun everyStickerGetsItsOwnTileSpreadOut() {
        val test = city()
        val placed = test.placeStickers((0 until 12).map { entry("story-$it") })
        assertEquals(12, placed.size)
        assertEquals(12, placed.values.toSet().size)
        // Twelve stickers in a square kilometre shouldn't need to sit right next to each other.
        val centres = placed.values.map { test.grid.centre(it) }
        val closest = centres.indices.flatMap { i -> (i + 1 until centres.size).map { centres[i].distance(centres[it]) } }.min()
        assertTrue("closest $closest", closest > 120)
    }

    @Test
    fun scatteredStickersAvoidTilesYouveWalked() {
        val q = HexGrid.hex(containing = start).q
        val walked = city().tiles.filterTo(HashSet()) { it.q < q }
        val test = city(visited = walked)
        val placed = test.placeStickers((0 until 8).map { entry("story-$it") })
        assertTrue(placed.values.none { it in walked })
    }

    @Test
    fun placementIsTheSameEveryTime() {
        val entries = (0 until 8).map { entry("story-$it") } + entry("spot", Vec2(-100.0, 100.0))
        assertEquals(city().placeStickers(entries), city().placeStickers(entries.reversed()))
    }

    @Test
    fun storiesBelongToThePlaceTheyHappened() {
        val home = city()
        val nextDoor = city(east = 1000.0)
        val assigned = assign(listOf(entry("here", Vec2(0.0, 0.0)), entry("there", Vec2(1000.0, 0.0))), listOf(home, nextDoor))
        assertEquals(listOf("here"), assigned[home.id])
        assertEquals(listOf("there"), assigned[nextDoor.id])
    }

    @Test
    fun storiesSomewhereYouHaventAddedWaitForIt() {
        assertTrue(assign(listOf(entry("far-away", Vec2(5000.0, 5000.0))), listOf(city())).isEmpty())
    }

    @Test
    fun storiesWithoutASpotGoToYourFirstPlaceInTheArea() {
        val elsewhere = city(east = 3000.0, detail = "Perth")
        val home = city()
        val later = city(east = 1000.0)
        val assigned = assign(listOf(entry("general")), listOf(elsewhere, home, later))
        assertEquals(listOf("general"), assigned[home.id])
        assertEquals(1, assigned.size)
    }

    @Test
    fun storiesAboutAWholeSuburbGoToThatSuburb() {
        val ludlow = city(east = 1000.0, name = "Ludlow")
        val assigned = assign(listOf(entry("forestry-school", suburb = "Ludlow")), listOf(city(), ludlow))
        assertEquals(listOf("forestry-school"), assigned[ludlow.id])
        assertEquals(1, assigned.size)
    }

    @Test
    fun newStickersSkipTilesThatAlreadyHaveOne() {
        val test = city()
        val first = test.placeStickers((0 until 6).map { entry("old-$it") })
        val second = test.placeStickers((0 until 6).map { entry("new-$it") }, first.values.toSet())
        assertTrue(first.values.toSet().intersect(second.values.toSet()).isEmpty())
    }

    @Test
    fun shippedLoreLoadsWithUniqueIdsAndArt() {
        val all = LoreLibrary.all
        assertTrue("${all.size} entries", all.size > 100)
        assertEquals(all.size, all.map { it.id }.toSet().size)
        val assets = File(repoRoot(), "Walkies/Assets.xcassets")
        for (entry in all) {
            assertTrue("no sticker for ${entry.id}", File(assets, "Stickers/sticker-${entry.id}.imageset").isDirectory)
            for (photo in entry.photos.orEmpty()) {
                assertTrue("no photo ${photo.asset}", File(assets, "Photos/${photo.asset}.imageset").isDirectory)
                assertTrue(
                    "photo ${photo.asset} needs a credit and its Commons page",
                    photo.credit.isNotEmpty() && photo.source.startsWith("https://commons.wikimedia.org/"),
                )
            }
        }
    }

    @Test
    fun stableHashDoesNotChangeBetweenLaunches() {
        // The published FNV-1a value for "a". If this changes, every saved sticker would move.
        assertEquals(java.lang.Long.parseUnsignedLong("af63dc4c8601ec8c", 16), stableHash("a"))
    }
}
