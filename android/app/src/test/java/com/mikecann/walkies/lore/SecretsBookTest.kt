package com.mikecann.walkies.lore

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.LocalProjection
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** SecretsBookTests.swift: grouping, sorting, filtering and the area you're in. */
class SecretsBookTest {
    private val origin = Coordinate(-33.638, 115.386)
    private val foundAt = SwiftDate.epoch(1000.0)

    private fun entry(id: String, area: String? = null, east: Double? = null): LoreEntry {
        val coordinate = east?.let { LocalProjection(origin).unproject(Vec2(it, 0.0)) }
        return LoreEntry(
            id = id, title = id, body = "", category = "history",
            place = coordinate?.let { LoreEntry.Place(id, it.lat, it.lon) },
            sticker = "", sources = emptyList(), suburb = area,
        )
    }

    private fun city(name: String, east: Double = 0.0): City {
        val projection = LocalProjection(origin)
        val corners = listOf(Vec2(east - 100, -100.0), Vec2(east + 100, -100.0), Vec2(east + 100, 100.0), Vec2(east - 100, 100.0))
        return City(
            name = name, detail = "Busselton",
            boundary = Boundary(listOf(GeoPolygon(corners.map(projection::unproject), emptyList()))),
            tiles = emptySet(), visited = emptySet(),
        )
    }

    private fun near(expected: Double, actual: Double?) = actual != null && abs(actual - expected) < 1

    @Test
    fun groupsEveryEntryAndKeepsOverallCounts() {
        val entries = listOf(entry("one", "Geographe"), entry("two", "Geographe"), entry("three", "Ludlow"))
        val sections = SecretsBook.sections(entries, mapOf("one" to foundAt), null, listOf(city("geographe")))
        assertEquals(listOf("Geographe", "Ludlow"), sections.map { it.name })
        assertEquals(2, sections[0].total)
        assertEquals(1, sections[0].found)
        assertEquals(0.5, sections[0].progress, 0.0)
        assertTrue(sections[0].isAdded)
        assertFalse(sections[1].isAdded)
        assertEquals(entries.size, sections.flatMap { it.entries }.size)
    }

    @Test
    fun missingSuburbGoesAroundBusselton() {
        val sections = SecretsBook.sections(listOf(entry("general"), entry("jetty", east = 100.0)), emptyMap(), null, emptyList())
        assertEquals(1, sections.size)
        assertEquals("Around Busselton", sections.first().name)
        assertEquals(2, sections.first().total)
    }

    @Test
    fun currentAreaMatchesSelectedCityIgnoringCase() {
        val entries = listOf(entry("one", "Geographe"), entry("two", "Ludlow"))
        assertEquals("Geographe", SecretsBook.currentAreaName(entries, "geographe"))
        assertEquals("Ludlow", SecretsBook.currentAreaName(entries, "Ludlow"))
    }

    @Test
    fun noCurrentAreaWithoutMatchingCity() {
        val entries = listOf(entry("one", "Geographe"))
        assertNull(SecretsBook.currentAreaName(entries, null))
        assertNull(SecretsBook.currentAreaName(entries, "Ludlow"))
        assertNull(SecretsBook.currentAreaName(emptyList(), "Geographe"))
    }

    @Test
    fun currentAreaUsesTheSameFallbackNameAsSections() {
        assertEquals("Around Busselton", SecretsBook.currentAreaName(listOf(entry("general")), "Around Busselton"))
    }

    @Test
    fun currentAreaStillMatchesWhenFilterHidesIt() {
        val entries = listOf(entry("one", "Geographe"), entry("two", "Ludlow"))
        val sections = SecretsBook.sections(entries, mapOf("two" to foundAt), null, emptyList(), filter = SecretsBook.Filter.Found)
        assertEquals(listOf("Ludlow"), sections.map { it.name })
        assertEquals("Geographe", SecretsBook.currentAreaName(entries, "Geographe"))
    }

    @Test
    fun nearestUsesClosestPinAndLeavesUnpinnedAreasLast() {
        val entries = listOf(
            entry("far", "Zebra", 2000.0), entry("near", "Zebra", 100.0),
            entry("middle", "Bay", 500.0), entry("no-pin", "Apple"),
        )
        val sections = SecretsBook.sections(entries, emptyMap(), origin, emptyList())
        assertEquals(listOf("Zebra", "Bay", "Apple"), sections.map { it.name })
        assertTrue(near(100.0, sections[0].distance))
        assertNull(sections.last().distance)
    }

    @Test
    fun alphabeticalIgnoresDistanceAndFinds() {
        val entries = listOf(entry("z", "Zebra", 10.0), entry("a", "Apple", 2000.0))
        val sections = SecretsBook.sections(entries, mapOf("z" to foundAt), origin, emptyList(), sort = SecretsBook.Sort.Alphabetical)
        assertEquals(listOf("Apple", "Zebra"), sections.map { it.name })
    }

    @Test
    fun mostFoundUsesCountThenName() {
        val entries = listOf(
            entry("z1", "Zebra"), entry("z2", "Zebra"), entry("z3", "Zebra"),
            entry("a", "Apple"), entry("b", "Bay"), entry("c", "Creek"),
        )
        val sections = SecretsBook.sections(
            entries, mapOf("z1" to foundAt, "z2" to foundAt, "a" to foundAt, "b" to foundAt),
            null, emptyList(), sort = SecretsBook.Sort.MostFound,
        )
        assertEquals(listOf("Zebra", "Apple", "Bay", "Creek"), sections.map { it.name })
    }

    @Test
    fun foundFilterHidesEmptyAreasButKeepsFullProgressAndDistance() {
        val entries = listOf(entry("found", "Bay", 500.0), entry("hidden", "Bay", 100.0), entry("elsewhere", "Creek"))
        val sections = SecretsBook.sections(entries, mapOf("found" to foundAt), origin, emptyList(), filter = SecretsBook.Filter.Found)
        assertEquals(1, sections.size)
        assertEquals(listOf("found"), sections[0].entries.map { it.id })
        assertEquals(1, sections[0].found)
        assertEquals(2, sections[0].total)
        // Changing the filter mustn't make an area's distance point to a different spot.
        assertTrue(near(100.0, sections[0].distance))
    }

    @Test
    fun notFoundFilterHidesCompletedAreas() {
        val entries = listOf(entry("found", "Bay"), entry("hidden", "Bay"), entry("done", "Creek"))
        val sections = SecretsBook.sections(
            entries, mapOf("found" to foundAt, "done" to foundAt), null, emptyList(), filter = SecretsBook.Filter.NotFound,
        )
        assertEquals(listOf("Bay"), sections.map { it.name })
        assertEquals(listOf("hidden"), sections[0].entries.map { it.id })
        assertEquals(1, sections[0].found)
        assertEquals(2, sections[0].total)
    }

    @Test
    fun noFixFallsBackToSelectedBoundaryCentre() {
        val entries = listOf(entry("a", "Apple", 100.0), entry("z", "Zebra", 1900.0))
        val selected = city("Home", east = 2000.0)
        val sections = SecretsBook.sections(entries, emptyMap(), null, listOf(selected), selected)
        assertEquals(listOf("Zebra", "Apple"), sections.map { it.name })
        assertTrue(near(100.0, sections[0].distance))
        val withFix = SecretsBook.sections(entries, emptyMap(), origin, listOf(selected), selected)
        assertEquals(listOf("Apple", "Zebra"), withFix.map { it.name })
    }

    @Test
    fun noFixOrSelectionFallsBackToNamesEvenWithPlaces() {
        val entries = listOf(entry("z", "Zebra", 10.0), entry("a", "Apple", 2000.0))
        val sections = SecretsBook.sections(entries, emptyMap(), null, listOf(city("Home")))
        assertEquals(listOf("Apple", "Zebra"), sections.map { it.name })
        assertTrue(sections.all { it.distance == null })
    }

    @Test
    fun findsAreNewestFirstWithMysteriesAfterwards() {
        val entries = listOf(entry("a"), entry("b"), entry("c"), entry("d"))
        val sections = SecretsBook.sections(entries, mapOf("c" to foundAt, "b" to foundAt.plus(10.0)), null, emptyList())
        assertEquals(listOf("b", "c", "a", "d"), sections[0].entries.map { it.id })
    }

    @Test
    fun emptyLibraryAndEmptyFiltersHaveNoSections() {
        assertTrue(SecretsBook.sections(emptyList(), emptyMap(), origin, emptyList()).isEmpty())
        assertTrue(SecretsBook.sections(listOf(entry("hidden")), emptyMap(), null, emptyList(), filter = SecretsBook.Filter.Found).isEmpty())
    }

    @Test
    fun savedSortAndFilterUseTheIphonesNames() {
        assertEquals(SecretsBook.Sort.MostFound, SecretsBook.Sort.from("mostFound"))
        assertEquals(SecretsBook.Filter.NotFound, SecretsBook.Filter.from("notFound"))
        assertEquals(SecretsBook.Sort.Nearest, SecretsBook.Sort.from(null))
    }
}
