package com.mikecann.walkies.sync

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.repoRoot
import com.mikecann.walkies.store.Store
import com.mikecann.walkies.tempStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Sync must never lose places or walks: not from a file that won't load, a bad
 * download, a sign-out mid-sync or someone else signing in on the same phone.
 * SyncSafetyTests.swift, plus the shape of what goes up.
 */
class SyncSafetyTest {
    private fun city(name: String = "Test place"): City {
        val base = HexGrid.hex(containing = Coordinate(12.345, 45.678))
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(HexGrid.centre(base) + it) }
        return City(
            name = name, detail = "Tests",
            boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = (0 until 20).mapTo(LinkedHashSet()) { Hex(base.q + it, base.r) },
            visited = setOf(base), roads = emptyList(),
        )
    }

    private fun walk(n: Int, city: City): Walk {
        val date = SwiftDate.now().plus(-(n + 1) * 86400.0)
        val centre = HexGrid.centre(HexGrid.hex(containing = city.boundary.centre))
        val points = listOf(0.0, 15.0, 30.0).mapIndexed { i, x ->
            val c = HexGrid.projection.unproject(centre + Vec2(x, 0.0))
            TrackPoint(c.lat, c.lon, date.epochSeconds + i * 20, 5.0, speed = 1.0)
        }
        return Walk(startedAt = date, endedAt = date.plus(600.0), points = points, distance = 300.0, newTiles = 1)
    }

    private fun model(store: Store) = AppModel(store, FakeSettings(), FakeLocation())

    private fun client(server: FakeServer) = ConvexClient(server.backend, "token", server)

    private fun CoroutineScope.engine(
        model: AppModel,
        store: Store,
        server: FakeServer,
        signedIn: () -> Boolean = { true },
        userId: () -> String? = { null },
    ) = SyncEngine(model, store, signedIn, userId, makeClient = { client(server) }, scope = this)

    @Test
    fun corruptCitiesFileNeverDeletesFromTheAccount() = runBlocking {
        val (store, root) = tempStore()
        val place = city()
        store.save(listOf(place))
        val server = FakeServer()
        val model = model(store)
        val engine = engine(model, store, server)
        engine.sync()
        assertEquals(SyncEngine.Status.Idle, engine.status)
        assertEquals(1, server.places.size)

        store.flush()
        File(root, "cities.json").writeText("not json")
        val relaunched = model(store)
        assertTrue(relaunched.cities.isEmpty())
        assertTrue(root.list()!!.any { it.startsWith("cities.corrupt-") })
        val again = engine(relaunched, store, server)
        again.sync()
        assertEquals(SyncEngine.Status.Idle, again.status)
        assertFalse("sync:deletePlace" in server.paths)
        assertEquals(1, server.places.size)
        // Pull brings it back.
        assertEquals(listOf(place.id), relaunched.cities.map { it.id })
        assertEquals(listOf(place.id), store.loadCities().map { it.id })
    }

    @Test
    fun deletedPlacesArePushedOnceAndNotPulledBack() = runBlocking {
        val (store, _) = tempStore()
        val keep = city("Keep")
        val gone = city("Gone")
        store.save(listOf(keep, gone))
        val server = FakeServer()
        val model = model(store)
        val engine = engine(model, store, server)
        engine.sync()
        assertEquals(2, server.places.size)

        model.deleteCity(gone.id)
        assertEquals(setOf(gone.id), store.loadSyncState().deletedPlaces)
        assertEquals(1, engine.waiting)
        // Survives a relaunch before there's signal.
        val relaunched = engine(model, store, server)
        relaunched.sync()
        assertEquals(SyncEngine.Status.Idle, relaunched.status)
        assertEquals(listOf(gone.id.uuidString), server.deleted)
        assertEquals(listOf(keep.id.uuidString), server.places.keys.sorted())
        assertTrue(store.loadSyncState().deletedPlaces.isNullOrEmpty())
        assertEquals(listOf(keep.id), model.cities.map { it.id })
        relaunched.sync()
        assertEquals(1, server.deleted.size)
        assertEquals(0, relaunched.waiting)
    }

    @Test
    fun aPlaceDeletedHereIsNotPulledBackBeforeTheDeleteIsSent() = runBlocking {
        val (store, _) = tempStore()
        val gone = city("Gone")
        store.save(listOf(gone))
        val server = FakeServer()
        val model = model(store)
        val engine = engine(model, store, server)
        engine.sync()
        model.deleteCity(gone.id)
        // The delete doesn't get through, but nothing may bring the place back meanwhile.
        server.failures["sync:deletePlace"] = """{"status":"error","errorMessage":"Server Error"}"""
        engine.sync()
        assertEquals(SyncEngine.Status.Failed("Server Error"), engine.status)
        assertTrue(model.cities.isEmpty())
        assertEquals(setOf(gone.id), store.loadSyncState().deletedPlaces)
    }

    @Test
    fun oneBadDownloadDoesNotHoldBackTheRest() = runBlocking {
        val (store, _) = tempStore()
        val place = city()
        val walks = (0 until 3).map { walk(it, place) }
        val server = FakeServer()
        server.seed(place)
        for (walk in walks) server.seed(walk)
        server.fail(walks[0].id)
        server.garble(walks[1].id)
        val model = model(store)
        val engine = engine(model, store, server)
        engine.sync()
        assertTrue("Expected the failed download to show", engine.status is SyncEngine.Status.Failed)
        assertEquals(listOf(place.id), model.cities.map { it.id })
        assertEquals(listOf(walks[2].id), model.walks.map { it.id })
        assertEquals(setOf(walks[2].id), store.loadSyncState().uploadedWalks)

        // The failed one comes next time; the unreadable one is skipped without failing the sync.
        server.fail(null)
        engine.sync()
        assertEquals(SyncEngine.Status.Idle, engine.status)
        assertEquals(setOf(walks[0].id, walks[2].id), model.walks.map { it.id }.toSet())
        // Links are only asked for the walks this phone hasn't got.
        assertEquals("false", server.calls.last { it.path == "sync:snapshot" }.args["walkUrls"]!!.jsonPrimitive.content)
    }

    @Test
    fun signingOutDuringAPullLeavesNothingBehind() = runBlocking {
        val (store, _) = tempStore()
        val place = city()
        val server = FakeServer()
        server.seed(place)
        for (n in 0 until 3) server.seed(walk(n, place))
        server.pauseDownloads()
        val model = model(store)
        var signedIn = true
        val engine = engine(model, store, server, signedIn = { signedIn })
        val syncing = launch { engine.sync() }
        withContext(Dispatchers.IO) { assertTrue(server.downloadStarted.await(10, TimeUnit.SECONDS)) }
        val wiping = launch { engine.wipe() }
        yield()
        server.resumeDownloads()
        wiping.join()
        signedIn = false
        syncing.join()
        delay(50)
        assertTrue(model.cities.isEmpty())
        assertTrue(model.walks.isEmpty())
        assertTrue(store.loadCities().isEmpty())
        assertTrue(store.loadWalks().isEmpty())
        assertTrue(store.loadSyncState().uploadedPlaces.isEmpty())
        assertEquals(SyncEngine.Status.Idle, engine.status)
    }

    @Test
    fun someoneElseSigningInStartsFromTheirOwnAccount() = runBlocking {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        store.save(walk(0, place))
        val server = FakeServer()

        // Data from before owners were recorded belongs to whoever syncs it first.
        val model = model(store)
        val alice = engine(model, store, server, userId = { "alice" })
        alice.sync()
        assertEquals("alice", store.loadOwner())
        assertEquals(1, model.cities.size)

        val relaunched = model(store)
        val bobServer = FakeServer()
        val bob = engine(relaunched, store, bobServer, userId = { "bob" })
        bob.sync()
        assertEquals(SyncEngine.Status.Idle, bob.status)
        assertTrue(relaunched.cities.isEmpty())
        assertTrue(relaunched.walks.isEmpty())
        assertTrue(store.loadCities().isEmpty())
        assertTrue(store.loadWalks().isEmpty())
        assertEquals("bob", store.loadOwner())
        assertFalse("sync:savePlace" in bobServer.paths)
        assertFalse("sync:saveWalk" in bobServer.paths)
    }

    @Test
    fun pushedBlobsAndArgumentsAreTheIPhonesShape() = runBlocking {
        val (store, _) = tempStore()
        val place = city()
        val saved = walk(0, place)
        store.save(listOf(place))
        store.save(saved)
        val server = FakeServer()
        val model = model(store)
        val engine = engine(model, store, server)
        engine.sync()
        assertEquals(SyncEngine.Status.Idle, engine.status)

        val saves = server.calls.filter { it.path.startsWith("sync:save") || it.path == "sync:deletePlace" }
        assertEquals(listOf("sync:savePlace", "sync:saveWalk", "sync:saveProgress"), saves.map { it.path })
        for (call in saves) assertEquals(2, call.args["gridVersion"]!!.jsonPrimitive.int)
        assertTrue(server.calls.all { it.token == "token" })

        val walkCall = saves[1]
        assertEquals(saved.id.uuidString, walkCall.args["clientId"]!!.jsonPrimitive.content)
        assertEquals(saved.startedAt.ms, walkCall.args["startedAt"]!!.jsonPrimitive.content.toDouble(), 0.0)
        assertEquals(saved.endedAt!!.ms, walkCall.args["endedAt"]!!.jsonPrimitive.content.toDouble(), 0.0)
        // The blob is exactly what the store writes, which the iPhone reads (see FixtureTest).
        val blob = server.files.getValue(walkCall.args["file"]!!.jsonPrimitive.content).decodeToString()
        assertEquals(Codec.walk(model.walks.single()).toString(), blob)
        assertEquals(model.walks.single(), Codec.walk(Codec.parse(blob)))

        val placeCall = saves[0]
        val cityBlob = server.files.getValue(placeCall.args["file"]!!.jsonPrimitive.content).decodeToString()
        assertEquals(model.cities.single(), Codec.city(Codec.parse(cityBlob)))
        assertEquals(model.cities.single().lastChanged.ms, placeCall.args["updatedAt"]!!.jsonPrimitive.content.toDouble(), 0.0)

        assertEquals(SyncEngine.progressJSON(Ledger()), saves[2].args["ledger"]!!.jsonPrimitive.content)
        // Nothing goes up twice.
        val before = server.calls.size
        engine.sync()
        assertEquals(listOf("sync:snapshot"), server.calls.drop(before).map { it.path })
        assertEquals(0, engine.waiting)
    }

    @Test
    fun offlineKeepsEverythingAndSaysSo() = runBlocking {
        val (store, _) = tempStore()
        store.save(listOf(city()))
        val server = FakeServer()
        server.offline = true
        val model = model(store)
        val engine = engine(model, store, server)
        engine.sync()
        assertEquals(SyncEngine.Status.Failed("Offline"), engine.status)
        assertEquals(1, model.cities.size)
        // The place and the empty ledger.
        assertEquals(2, engine.waiting)
        assertNull(engine.lastSynced)
    }

    @Test
    fun theLedgerIsComparedInTheIPhonesSortedKeyForm() {
        val ledger = Codec.ledger(Codec.parse(File(repoRoot(), "shared/fixtures/ios/progress.json").readText()))
        val expected = """{"claims":[{"choice":"shells.50","level":2},{"choice":"spyglasses.2","level":3}],""" +
            """"equipped":{"celebration":"celebration.confetti","clouds":"clouds.classic","cover":"cover.red","marker":"marker.paw","trail":"trail.teal","updatedAt":1790000200.75},""" +
            """"offers":[{"choices":["shells.50","marker.paw","spyglasses.2"],"level":2},{"choices":["spyglasses.2"],"level":3}],""" +
            """"purchases":[{"at":1790000000.5,"cost":60,"id":"9C1F2E3D-0000-4000-8000-00000000000A","item":"spyglass"},{"at":1790000001,"cost":120,"id":"P-2","item":"marker.paw"}],""" +
            """"spyglasses":[{"at":1790000100.125,"centre":[-33.6391,115.3602],"id":"S-1","secretId":"geographe-jetty"}]}"""
        assertEquals(expected, SyncEngine.progressJSON(ledger))
        // Slashes are escaped, as JSONEncoder does without .withoutEscapingSlashes.
        assertEquals("""{"a\/b":"c\"d"}""", Codec.sortedKeys(buildJsonObject { put("a/b", "c\"d") }))
    }

    @Test
    fun pulledProgressAndSecretsMergeWithWhatsHere() = runBlocking {
        val (store, _) = tempStore()
        val server = FakeServer()
        val remote = Ledger(claims = listOf(Ledger.Claim(2, "shells.50")))
        server.answers["sync:snapshot"] = {
            buildJsonObject {
                put("places", JsonArray(emptyList()))
                put("walks", JsonArray(emptyList()))
                put("secrets", buildJsonArray {
                    add(buildJsonObject {
                        put("secretId", "geographe-jetty")
                        put("foundAt", JsonPrimitive(1_790_000_000_000.0))
                    })
                })
                put("progress", SyncEngine.progressJSON(remote))
            }
        }
        val model = model(store)
        val engine = engine(model, store, server)
        engine.sync()
        assertEquals(SyncEngine.Status.Idle, engine.status)
        assertEquals(remote.claims, model.ledger.claims)
        assertEquals(1_790_000_000.0, model.foundStickers.getValue("geographe-jetty").epochSeconds, 1e-3)
        assertEquals(remote, store.loadProgress())
        assertEquals(0, engine.waiting)
    }
}
