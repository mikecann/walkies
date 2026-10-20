package com.mikecann.walkies.store

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.place.RoadLine
import com.mikecann.walkies.tempStore
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** StoreTests.swift: cities are written in the background, with their streets in a file of their own. */
class StoreTest {
    private fun city(name: String, roads: List<RoadLine>?): City {
        val base = HexGrid.hex(containing = Coordinate(-33.638, 115.386))
        val ring = listOf(Vec2(-300.0, -300.0), Vec2(300.0, -300.0), Vec2(300.0, 300.0), Vec2(-300.0, 300.0))
            .map { HexGrid.projection.unproject(HexGrid.centre(base) + it) }
        return City(
            name = name, detail = "Tests", boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = setOf(base), visited = emptySet(), roads = roads,
        )
    }

    private val street = listOf(RoadLine(RoadLine.Kind.Road, listOf(Coordinate(-33.63, 115.38), Coordinate(-33.631, 115.381))))

    @Test
    fun streetsGoInTheirOwnFileAndComeBack() {
        val (store, root) = tempStore()
        val cities = listOf(city("A", street), city("B", emptyList()), city("C", null))
        store.save(cities)
        assertEquals(cities, store.loadCities())
        val saved = Codec.parse(File(root, "cities.json").readText()) as JsonArray
        assertTrue(saved.all { "roads" !in it.jsonObject })
        assertTrue(File(root, "roads.json").exists())
    }

    @Test
    fun oldSingleFileStillLoadsAndMovesItsStreets() {
        val (store, root) = tempStore()
        val cities = listOf(city("A", street), city("B", null))
        File(root, "cities.json").writeText(Codec.cities(cities).toString())
        val loaded = store.loadCities()
        assertEquals(cities, loaded)
        store.save(loaded)
        assertEquals(cities, Store(root).loadCities())
    }

    @Test
    fun savesMatchEncodingEverythingAndTheLastOneWins() {
        val (store, root) = tempStore()
        val cities = mutableListOf(city("A", street), city("B", street))
        store.save(cities)
        for (n in 0 until 20) {
            val c = cities[n % 2]
            cities[n % 2] = c.copy(visited = c.visited + Hex(n, 0), updatedAt = SwiftDate.epoch(n.toDouble()))
            store.save(cities.toList())
        }
        store.flush()
        val disk = Codec.parse(File(root, "cities.json").readText())
        val whole = Codec.cities(cities.map { it.copy(roads = null) })
        assertEquals(whole, disk)
        assertEquals(cities, store.loadCities())
    }

    @Test
    fun wipingAfterASaveLeavesNothingBehind() {
        val (store, root) = tempStore()
        store.save(listOf(city("A", street)))
        store.wipe()
        store.flush()
        assertTrue(store.loadCities().isEmpty())
        assertFalse(File(root, "roads.json").exists())
    }

    @Test
    fun aNewStoreIsMarkedWithTheGridVersion() {
        val (store, root) = tempStore()
        assertEquals("2", File(root, "data-version.json").readText())
        assertFalse(store.needsWorldGridReset)
    }

    @Test
    fun aCitiesFileThatWontReadIsMovedAsideNotSavedOver() {
        val (store, root) = tempStore()
        File(root, "cities.json").writeText("""[{"id": "nope"}]""")
        assertTrue(store.loadCities().isEmpty())
        assertFalse(File(root, "cities.json").exists())
        assertTrue(root.listFiles()!!.any { it.name.startsWith("cities.corrupt-") })
    }
}
