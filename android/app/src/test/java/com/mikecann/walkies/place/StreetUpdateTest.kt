package com.mikecann.walkies.place

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.sync.FakeServer
import com.mikecann.walkies.tempStore
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * Places built before busy roads were left out get their street tiles redone once
 * (StreetUpdateTests in ProgressionIntegrationTests.swift), keeping what you've done.
 */
class StreetUpdateTest {
    private val origin = HexGrid.centre(HexGrid.hex(containing = Coordinate(12.345, 45.678)))
    private fun at(x: Double, y: Double) = HexGrid.projection.unproject(origin + Vec2(x, y))
    private val boundary = Boundary(listOf(GeoPolygon(listOf(at(-1000.0, -1000.0), at(1000.0, -1000.0), at(1000.0, 1000.0), at(-1000.0, 1000.0), at(-1000.0, -1000.0)), emptyList())))
    private fun line(y: Double) = (-800..800 step 50).map { at(it.toDouble(), y) }
    private val street = OSMWay(mapOf("highway" to "residential"), line(300.0))
    private val highway = OSMWay(mapOf("highway" to "trunk"), line(-300.0))

    /** A place from before the rule: the highway's tiles count, and some have been walked. */
    private fun oldPlace(): City {
        val built = CityBuilder.build("Busselton", "Tests", 123L, boundary, listOf(street, highway))
        val highwayTiles = CityBuilder.streetTiles(listOf(highway), City.hexes(BoundaryShape(boundary, HexGrid.projection), HexGrid)).sortedBy { it.q }
        return built.copy(
            id = UUID.fromString("6F1C2B4E-4D7A-4C1B-9E0A-1A2B3C4D5E6F"),
            visited = highwayTiles.take(3).toSet(),
            tileCredits = listOf(City.TileCredit(UUID.randomUUID(), SwiftDate.epoch(1_790_000_000.0), setOf(highwayTiles[2]))),
            updatedAt = SwiftDate.epoch(1_790_000_000.0),
        )
    }

    private fun file(): ByteArray {
        val ring = (boundary.polygons[0].outer).joinToString(",") { "[${it.lon},${it.lat}]" }
        val points = street.points.joinToString(",") { "[${it.lat},${it.lon}]" }
        return """{"boundary":[[[$ring]]],"ways":[{"highway":"residential","points":[$points]}]}""".toByteArray()
    }

    private fun server(version: Int?): FakeServer {
        val server = FakeServer()
        server.files["streets"] = file()
        server.answers["places:get"] = {
            buildJsonObject {
                put("url", "https://files.walkies.test/streets")
                put("fetchedAt", 1_790_000_000_000.0)
                version?.let { put("version", it) }
            }
        }
        return server
    }

    @Test
    fun oldPlacesLoseUnwalkableRoadTilesOnceAndKeepWhatYouveDone() = runBlocking {
        val (store, _) = tempStore()
        val old = oldPlace()
        store.save(listOf(old))
        val server = server(version = 2)
        val model = AppModel(store, FakeSettings(), FakeLocation())
        model.makePlaceClient = { ConvexClient(server.backend, "token", server) }
        var synced = 0
        model.requestSync = { synced++ }
        val before = model.cities[0]
        val visitedBefore = before.visited
        val progressBefore = before.progress

        model.updateStreets()
        val city = model.cities[0]
        val inside = City.hexes(BoundaryShape(boundary, HexGrid.projection), HexGrid)
        val streetTiles = CityBuilder.streetTiles(listOf(street), inside)
        assertEquals(2, city.streetsVersion)
        assertEquals(visitedBefore, city.visited)
        // Secrets are placed at launch; one hides on the highway and keeps its tile.
        assertEquals(before.stickers, city.stickers)
        assertTrue(before.stickers!!.values.any { it !in streetTiles })
        assertEquals(old.tileCredits, city.tileCredits)
        // The street's tiles, plus the walked, credited and secret highway tiles. No others.
        assertEquals(streetTiles + visitedBefore + before.stickers!!.values, city.tiles)
        assertTrue(city.tiles.size < before.tiles.size)
        assertTrue(city.progress > progressBefore)
        // The rest of the highway is no-path now, so it clears beside walked tiles.
        assertTrue(city.cloudCover().clear.size > visitedBefore.size)
        assertTrue(city.lastChanged > old.lastChanged)
        assertEquals(1, synced)
        store.flush()
        assertEquals(city.tiles, store.loadCities()[0].tiles)
        assertEquals(2, store.loadCities()[0].streetsVersion)

        // Once per place.
        model.updateStreets()
        assertEquals(1, server.paths.count { it == "places:get" })

        // A phone that hasn't updated yet can't bring the highway back.
        model.addRemote(listOf(old.copy(updatedAt = SwiftDate.epoch(1_800_000_000.0))), emptyList(), null, emptyMap())
        assertEquals(city.tiles, model.cities[0].tiles)
        assertEquals(2, model.cities[0].streetsVersion)
        // And an updated copy from another phone replaces an old one's street tiles.
        val other = AppModel(tempStore().first.also { it.save(listOf(old)) }, FakeSettings(), FakeLocation())
        other.addRemote(listOf(city.copy(updatedAt = SwiftDate.epoch(1_800_000_000.0))), emptyList(), null, emptyMap())
        assertEquals(city.tiles, other.cities[0].tiles)
        assertEquals(2, other.cities[0].streetsVersion)
    }

    @Test
    fun anOlderServerLeavesPlacesForLater() = runBlocking {
        val (store, _) = tempStore()
        store.save(listOf(oldPlace()))
        val server = server(version = null)
        val model = AppModel(store, FakeSettings(), FakeLocation())
        model.makePlaceClient = { ConvexClient(server.backend, "token", server) }
        val before = model.cities[0]
        model.updateStreets()
        assertEquals(before, model.cities[0])
        assertNull(model.cities[0].streetsVersion)
        assertFalse(server.paths.isEmpty())
    }
}
