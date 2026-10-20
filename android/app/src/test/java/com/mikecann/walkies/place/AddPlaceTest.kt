package com.mikecann.walkies.place

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.convex.Http
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.repoRoot
import com.mikecann.walkies.sync.FakeServer
import com.mikecann.walkies.tempStore
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Adding a place (AddCityView, CityBuilder, CachedPlaceData) and the suburbs next door. */
class AddPlaceTest {
    private val geographe = File(repoRoot(), "shared/fixtures/places/geographe.json").readBytes()

    private fun place(osmId: Long? = 11688696) = PlaceResult(
        id = 1, name = "Geographe", detail = "Busselton, Western Australia, Australia", kind = "suburb",
        boundary = PlaceData.parse(geographe.decodeToString()).boundary, area = 5_000_000.0, osmId = osmId,
    )

    /** Along Geographe Bay Road, which runs through the suburb. */
    private fun walk(): Walk {
        val start = Coordinate(-33.6385, 115.3800)
        val points = (0 until 40).map { i ->
            TrackPoint(start.lat, start.lon + i * 0.0002, 1_790_000_000.0 + i * 15, 5.0, speed = 1.3)
        }
        return Walk(startedAt = SwiftDate.epoch(1_790_000_000.0), endedAt = SwiftDate.epoch(1_790_000_600.0), points = points, distance = 700.0)
    }

    @Test
    fun aPlaceComesFromTheStreetCacheWithYourWalksReplayed() = runBlocking {
        val (store, _) = tempStore()
        store.save(walk())
        val server = FakeServer()
        server.files["geographe"] = geographe
        server.answers["places:get"] = { args ->
            assertEquals(11688696L, args["osmId"]!!.jsonPrimitive.long)
            buildJsonObject {
                put("url", "https://files.walkies.test/geographe")
                put("fetchedAt", 1_790_000_000_000.0)
            }
        }
        val model = AppModel(store, FakeSettings(), FakeLocation(), osm = OSMClient(NoNetwork))
        model.makePlaceClient = { ConvexClient(server.backend, "token", server) }
        var synced = 0
        model.requestSync = { synced++ }
        val statuses = ArrayList<String>()
        model.addPlace(place()) { statuses.add(it) }

        val city = model.cities.single()
        assertEquals("Geographe", city.name)
        assertEquals(11688696L, city.osmId)
        assertEquals(city.id, model.selectedCityId)
        assertTrue(city.tiles.size > 100)
        // The walk you'd already done counts here.
        assertTrue(city.visited.isNotEmpty())
        assertTrue(city.tiles.containsAll(city.visited))
        assertEquals(listOf("Getting Geographe ready…", "Laying out the tiles…"), statuses)
        assertEquals(1, synced)
        assertEquals(listOf(city.id), store.loadCities().map { it.id })
    }

    @Test
    fun withoutTheCacheItAsksOverpassItself() = runBlocking {
        val (store, _) = tempStore()
        var asked: String? = null
        val overpass = object : Http {
            override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response {
                asked = url
                return Http.Response(200, """{"elements":[{"type":"way","id":1,"tags":{"highway":"residential"},"geometry":[{"lat":-33.6385,"lon":115.38},{"lat":-33.6385,"lon":115.385}]}]}""".toByteArray())
            }
        }
        val model = AppModel(store, FakeSettings(), FakeLocation(), osm = OSMClient(overpass))
        val statuses = ArrayList<String>()
        model.addPlace(place(osmId = null)) { statuses.add(it) }
        assertEquals(OSMClient.OVERPASS.first(), asked)
        assertEquals(listOf("Finding the streets and paths…", "Laying out the tiles…"), statuses)
        val city = model.cities.single()
        assertEquals(1, city.roads!!.size)
        assertTrue(city.visited.isEmpty())
    }

    @Test
    fun deletingAPlaceKeepsTheWalksAndPicksAnother() {
        val (store, _) = tempStore()
        val data = PlaceData.parse(geographe.decodeToString())
        val a = CityBuilder.build(place(), data.ways, emptyList())
        val b = CityBuilder.build(place().copy(name = "Other"), data.ways, emptyList())
        store.save(listOf(a, b))
        store.save(walk())
        val model = AppModel(store, FakeSettings(selectedCity = null), FakeLocation())
        val deleted = ArrayList<java.util.UUID>()
        model.placesDeleted = { deleted += it }
        model.select(a.id)
        model.deleteCity(a.id)
        assertEquals(listOf(a.id), deleted)
        assertEquals(listOf(b.id), model.cities.map { it.id })
        assertEquals(b.id, model.selectedCityId)
        assertEquals(1, model.walks.size)
        model.deleteCity(b.id)
        assertNull(model.selectedCityId)
        assertTrue(store.loadCities().isEmpty())
    }

    @Test
    fun nominatimResultsBecomePlaces() {
        val item = Json.parseToJsonElement(
            """{"place_id":123,"osm_type":"relation","osm_id":11688696,"name":"Geographe","addresstype":"suburb",
            "display_name":"Geographe, Busselton, City Of Busselton, Western Australia, 6280, Australia",
            "geojson":{"type":"MultiPolygon","coordinates":[[[[115.38,-33.64],[115.39,-33.64],[115.39,-33.63],[115.38,-33.63],[115.38,-33.64]]]]}}""",
        ).jsonObject
        val place = OSMClient.place(item)!!
        assertEquals(123L, place.id)
        assertEquals(11688696L, place.osmId)
        assertEquals("Geographe", place.name)
        assertEquals("Busselton, City Of Busselton, Western Australia, 6280, Australia", place.detail)
        assertEquals("suburb", place.kind)
        assertEquals(-33.64, place.boundary.polygons.single().outer.first().lat, 0.0)
        assertTrue(place.area in 800_000.0..1_200_000.0)
        assertEquals("Suburb · 1.0 km²", place.summary)
        // A node (no outline) isn't a place you can add.
        assertNull(OSMClient.place(Json.parseToJsonElement("""{"place_id":1,"geojson":{"type":"Point","coordinates":[1,2]}}""").jsonObject))
        assertEquals("12 km²", PlaceResult.areaText(12_400_000.0))
    }

    @Test
    fun nearbyPlacesAreKeptInTheIPhonesNearbyJson() {
        val (store, root) = tempStore()
        val nearby = NearbyPlaces(-34.0, 115.0, -33.0, 116.0, SwiftDate(812345678.25), listOf(place(), place(osmId = null).copy(id = 2)))
        store.saveNearby(nearby)
        assertEquals(nearby, store.loadNearby())
        val json = Json.parseToJsonElement(File(root, "nearby.json").readText()).jsonObject
        assertEquals("812345678.25", json["fetchedAt"]!!.jsonPrimitive.content)
        assertTrue(nearby.covers(-33.9, 115.1, -33.1, 115.9))
        assertFalse(nearby.covers(-34.1, 115.1, -33.1, 115.9))
    }

    @Test
    fun neighboursLeaveOutYourPlacesAndTheTooBig() {
        val (store, _) = tempStore()
        val data = PlaceData.parse(geographe.decodeToString())
        store.save(listOf(CityBuilder.build(place(), data.ways, emptyList())))
        val c = place().boundary.centre
        fun square(name: String, dLon: Double, area: Double) = PlaceResult(
            id = name.hashCode().toLong(), name = name, detail = "", kind = "suburb", area = area, osmId = 1,
            boundary = Boundary(listOf(GeoPolygon(listOf(
                Coordinate(c.lat - 0.01, c.lon + dLon), Coordinate(c.lat - 0.01, c.lon + dLon + 0.02),
                Coordinate(c.lat + 0.01, c.lon + dLon + 0.02), Coordinate(c.lat + 0.01, c.lon + dLon),
            ), emptyList()))),
        )
        store.saveNearby(NearbyPlaces(-90.0, -180.0, 90.0, 180.0, SwiftDate.now(), listOf(
            square("Next door", 0.03, 4e6), square("geographe", 0.03, 4e6), square("Huge", 0.03, 5e8), square("Far away", 2.0, 4e6),
        )))
        val model = AppModel(store, FakeSettings(), FakeLocation())
        model.services = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)
        model.refreshNeighbours()
        assertEquals(listOf("Next door"), model.neighbours.map { it.name })
    }

    private object NoNetwork : Http {
        override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response =
            throw AssertionError("Didn't expect to go to $url")
    }
}
