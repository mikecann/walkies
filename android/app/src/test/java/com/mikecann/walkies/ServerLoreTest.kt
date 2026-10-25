package com.mikecann.walkies

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.lore.ServerLore
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.store.Store
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Secrets the server writes for places without bundled ones (ServerLore.kt and
 * AppModel.updateLore): reading `lore:forPlace`, caching it, and hiding them next to
 * the bundled ones. ServerLoreTests.swift. The server's stood in for; nothing here goes
 * to the network.
 */
class ServerLoreTest {
    private val porlock = 2_676_434L
    private val somewhere = 4_242L
    private var now = 1_790_000_000.0
    private val clock = { now }

    /** A place 2 km across with a row of 100 street tiles through the middle. */
    private fun city(osmId: Long?, origin: Coordinate = Coordinate(12.345, 45.678)): City {
        val base = HexGrid.hex(containing = origin)
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(HexGrid.centre(base) + it) }
        return City(
            name = "Somewhere", detail = "Tests", osmId = osmId,
            boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = (0 until 100).mapTo(LinkedHashSet()) { Hex(base.q + it, base.r) },
            visited = emptySet(),
            roads = emptyList(),
        )
    }

    /** A server secret pinned [tile] tiles along the city's street. */
    private fun secret(slug: String, city: City, tile: Int? = null, art: Boolean = true): ServerLore.Entry {
        val base = HexGrid.hex(containing = city.boundary.centre)
        val place = tile?.let { i ->
            val point = HexGrid.projection.unproject(HexGrid.centre(Hex(base.q + i, base.r)))
            LoreEntry.Place(slug, point.lat, point.lon)
        }
        val entry = LoreEntry(
            id = "osm${city.osmId ?: 0}-$slug", title = slug, body = "A story.", category = "history",
            place = place, sources = listOf("https://example.org/$slug"), suburb = city.name,
        )
        return ServerLore.Entry(entry, if (art) "https://example.org/storage/$slug" else null)
    }

    /** The smallest PNG there is: just its signature, which is all the app checks. */
    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    /** Answers from [answers] and counts what it's asked. */
    private class FakeServer {
        val answers = HashMap<Long, ServerLore.Answer>()
        val asked = ArrayList<Long>()
        val downloads = ArrayList<String>()
    }

    private fun model(store: Store, server: FakeServer): AppModel {
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        model.askForLore = { osmId ->
            server.asked += osmId
            server.answers[osmId] ?: ServerLore.Answer(ServerLore.Status.NotStarted, 0, emptyList())
        }
        model.downloadSticker = { url ->
            server.downloads += url
            png
        }
        return model
    }

    @Test
    fun readsWhatForPlaceSaysAboutPorlock() {
        val json = File(repoRoot(), "shared/fixtures/lore/forPlace-porlock.json").readText()
        val answer = ServerLore.Answer.from(Codec.parse(json))
        assertEquals(ServerLore.Status.Ready, answer.status)
        assertEquals(1, answer.version)
        assertEquals(7, answer.entries.size)
        assertTrue(answer.entries.all { it.entry.id.startsWith("osm$porlock-") && it.entry.suburb == "Porlock" })
        assertTrue(answer.entries.all { it.entry.place != null && it.entry.sources.isNotEmpty() && it.entry.photos == null })
        val categories = setOf("history", "first-nations", "nature", "the-sea", "odd-records", "modern-life")
        assertTrue(answer.entries.all { it.entry.category in categories })
        // The fixture's first sticker is a made-up URL; the rest failed to draw.
        assertTrue(answer.entries[0].stickerUrl!!.startsWith("https://resolute-pig-177."))
        assertTrue(answer.entries.drop(1).all { it.stickerUrl == null })
        assertEquals("A Clock Without a Face", answer.entries[0].entry.title)
    }

    @Test
    fun readsAVersionTheServerSendsAsADouble() {
        // The Convex client hands every number back as a double, so a live answer says
        // "version": 8.0 even though the fixture above says 1.
        val answer = ServerLore.Answer.from(Codec.parse("""{"status":"ready","version":8.0,"entries":[]}"""))
        assertEquals(8, answer.version)
    }

    @Test
    fun aStatusFromANewerServerIsTakenAsNone() {
        val answer = ServerLore.Answer.from(Codec.parse("""{"status":"pondering","version":0,"entries":[]}"""))
        assertEquals(ServerLore.Status.NotStarted, answer.status)
    }

    @Test
    fun theCacheReadsBackTheSame() {
        val place = city(somewhere)
        val (lore, _) = ServerLore().taking(
            ServerLore.Answer(ServerLore.Status.Ready, 2, listOf(secret("the-jetty", place, tile = 10), secret("the-town", place, art = false))),
            somewhere, SwiftDate(800_000_000.5), emptyMap(),
        )
        val saved = lore.copy(savedStickers = mapOf("osm$somewhere-the-jetty" to "https://example.org/storage/the-jetty"))
        assertEquals(saved, ServerLore.from(Codec.parse(saved.toJson().toString())))
    }

    @Test
    fun bundledPlacesNeverAsk() = runBlocking {
        val (store, _) = tempStore()
        val server = FakeServer()
        // Geographe ships its own secrets, and a place without a relation can't have any.
        assertTrue(11_688_696L in LoreLibrary.bundledOsmIds)
        assertEquals(29, LoreLibrary.bundledOsmIds.size)
        val model = model(store, server)
        model.add(city(11_688_696L))
        model.add(city(null, Coordinate(13.345, 45.678)))
        model.updateLore()
        model.updateLore(now = 11_688_696L)
        assertTrue(server.asked.isEmpty())
        assertTrue(server.downloads.isEmpty())
    }

    @Test
    fun aNewPlaceIsAskedOnceThenWaits() = runBlocking {
        val (store, _) = tempStore()
        val server = FakeServer()
        val model = model(store, server)
        model.add(city(somewhere))
        server.answers[somewhere] = ServerLore.Answer(ServerLore.Status.Researching, 0, emptyList())
        model.updateLore()
        model.updateLore()
        assertEquals(listOf(somewhere), server.asked)
        assertEquals(somewhere, model.lookingForSecrets?.osmId)
        // A couple of minutes later it's due again.
        now += 120
        model.updateLore()
        assertEquals(listOf(somewhere, somewhere), server.asked)
        // Asking straight away, as after Mike approves one.
        model.updateLore(now = somewhere)
        assertEquals(3, server.asked.size)
    }

    @Test
    fun serverSecretsGoNextToBundledOnesWithoutMovingAnyPins() = runBlocking {
        val (store, root) = tempStore()
        val server = FakeServer()
        val model = model(store, server)
        // A place that isn't bundled but has a bundled story's spot inside it, so it gets both.
        val bundled = LoreLibrary.bundled.first { it.place != null }
        val place = city(somewhere, bundled.place!!.coordinate)
        model.add(place)
        val bundledHex = model.cities[0].stickers!!.getValue(bundled.id)

        server.answers[somewhere] = ServerLore.Answer(
            ServerLore.Status.Ready, 1,
            listOf(secret("the-jetty", place, tile = 40), secret("the-mill", place, tile = 70), secret("the-town", place, art = false)),
        )
        model.updateLore()
        val first = model.cities[0].stickers!!
        assertEquals(bundledHex, first[bundled.id])
        for (slug in listOf("the-jetty", "the-mill", "the-town")) assertNotNull(first["osm$somewhere-$slug"])
        assertEquals(first.size, first.values.toSet().size)
        assertEquals(AppModel.LoreNotice(place.id, "Somewhere", 3), model.loreNotice)
        assertNull(model.lookingForSecrets)
        // In the book and on the chip's count, and their art's saved for offline.
        assertTrue(model.stickersHere.any { it.first.id == "osm$somewhere-the-mill" })
        assertTrue(ServerLore.stickerFile("osm$somewhere-the-jetty", File(root, "server-stickers")).exists())
        assertEquals(2, server.downloads.size)

        // Mike approves another: the earlier ones stay where they were.
        val before = server.answers.getValue(somewhere)
        server.answers[somewhere] = before.copy(version = 2, entries = before.entries + secret("the-wreck", place, tile = 20))
        model.updateLore(now = somewhere)
        val second = model.cities[0].stickers!!
        for ((id, hex) in first) assertEquals(hex, second[id])
        assertNotNull(second["osm$somewhere-the-wreck"])
        assertEquals(1, model.loreNotice?.count)
        assertEquals(3, server.downloads.size)

        // And they're still there next launch, from the cache, without asking.
        val reopened = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        assertEquals(second, reopened.cities[0].stickers)
        assertEquals(second.size, reopened.stickersHere.size)
    }

    @Test
    fun anotherPhonesPinWaitsForTheServer() = runBlocking {
        val (store, _) = tempStore()
        // Synced from a phone that's already had the place's secrets.
        val bare = city(somewhere)
        val base = HexGrid.hex(containing = bare.boundary.centre)
        val theirs = Hex(base.q + 77, base.r)
        store.save(listOf(bare.copy(stickers = mapOf("osm$somewhere-the-jetty" to theirs))))
        val server = FakeServer()
        val model = model(store, server)
        assertEquals(theirs, model.cities[0].stickers?.get("osm$somewhere-the-jetty"))
        server.answers[somewhere] = ServerLore.Answer(ServerLore.Status.Ready, 1, listOf(secret("the-jetty", bare, tile = 10)))
        model.updateLore()
        // The tile the other phone gave it, not the one nearest its pin.
        assertEquals(theirs, model.cities[0].stickers?.get("osm$somewhere-the-jetty"))
    }

    @Test
    fun theSameVersionReusesTheCache() = runBlocking {
        val (store, _) = tempStore()
        val server = FakeServer()
        val model = model(store, server)
        val place = city(somewhere)
        model.add(place)
        server.answers[somewhere] = ServerLore.Answer(ServerLore.Status.Ready, 3, listOf(secret("the-jetty", place, tile = 10)))
        model.updateLore()
        assertEquals(1, server.downloads.size)
        model.dismissLoreNotice()

        // Same version: nothing new is taken, and no art is downloaded again.
        server.answers[somewhere] = ServerLore.Answer(
            ServerLore.Status.Ready, 3, listOf(secret("the-jetty", place, tile = 10), secret("the-mill", place, tile = 50)),
        )
        model.updateLore(now = somewhere)
        assertEquals(2, server.asked.size)
        assertEquals(1, server.downloads.size)
        assertEquals(listOf("osm$somewhere-the-jetty"), model.serverLore.place(somewhere)?.entries?.map { it.id })
        assertNull(model.loreNotice)
    }

    @Test
    fun artThatFailsToDownloadIsTriedAgain() {
        val place = city(somewhere)
        val answer = ServerLore.Answer(ServerLore.Status.Ready, 1, listOf(secret("the-jetty", place, tile = 10)))
        val (lore, first) = ServerLore().taking(answer, somewhere, SwiftDate.now(), emptyMap())
        assertEquals(1, first.stickers.size)
        // Nothing saved, so the same version still wants it.
        assertEquals(first.stickers, lore.taking(answer, somewhere, SwiftDate.now(), emptyMap()).second.stickers)
        val saved = lore.copy(savedStickers = first.stickers)
        assertTrue(saved.taking(answer, somewhere, SwiftDate.now(), emptyMap()).second.stickers.isEmpty())
    }

    @Test
    fun aSecretTakenDownGoesUnlessYouveFoundIt() = runBlocking {
        val (store, _) = tempStore()
        val server = FakeServer()
        val model = model(store, server)
        val place = city(somewhere)
        model.add(place)
        val found = secret("found-it", place, tile = 30)
        val unfound = secret("not-yet", place, tile = 60)
        val staying = secret("staying", place, tile = 90)
        server.answers[somewhere] = ServerLore.Answer(ServerLore.Status.Ready, 1, listOf(found, unfound, staying))
        model.updateLore()
        val pins = model.cities[0].stickers!!
        val foundAt = SwiftDate.epoch(1_790_000_000.0)
        model.addRemoteSecrets(mapOf(found.entry.id to foundAt))

        // Mike hides both.
        server.answers[somewhere] = ServerLore.Answer(ServerLore.Status.Ready, 2, listOf(staying))
        model.updateLore(now = somewhere)
        val after = model.cities[0].stickers!!
        assertNull(after[unfound.entry.id])
        assertEquals(pins[found.entry.id], after[found.entry.id])
        assertEquals(pins[staying.entry.id], after[staying.entry.id])
        assertEquals(foundAt, model.foundStickers[found.entry.id])
        // Still yours to read in the book.
        assertEquals(listOf(found.entry.id), model.serverLore.kept.map { it.id })
        assertTrue(model.stickersHere.any { it.first.id == found.entry.id })
        assertFalse(model.stickersHere.any { it.first.id == unfound.entry.id })
        assertEquals("found-it", LoreLibrary.entry(found.entry.id)?.title)
    }

    @Test
    fun aQuietPlaceSaysSoOnce() = runBlocking {
        val (store, _) = tempStore()
        val server = FakeServer()
        val model = model(store, server)
        val place = city(somewhere)
        model.add(place)
        server.answers[somewhere] = ServerLore.Answer(ServerLore.Status.Quiet, 0, emptyList())
        model.updateLore()
        assertEquals(AppModel.LoreNotice(place.id, "Somewhere", 0), model.loreNotice)
        model.dismissLoreNotice()
        model.updateLore(now = somewhere)
        assertNull(model.loreNotice)
    }

    @Test
    fun aDeletedPlaceIsForgottenButItsFoundSecretsStay() = runBlocking {
        val (store, _) = tempStore()
        val server = FakeServer()
        val model = model(store, server)
        val place = city(somewhere)
        model.add(place)
        val found = secret("found-it", place, tile = 30)
        server.answers[somewhere] = ServerLore.Answer(ServerLore.Status.Ready, 1, listOf(found, secret("not-yet", place, tile = 60)))
        model.updateLore()
        model.addRemoteSecrets(mapOf(found.entry.id to SwiftDate.now()))
        model.deleteCity(place.id)
        model.updateLore()
        assertTrue(model.serverLore.places.isEmpty())
        assertEquals(listOf(found.entry.id), model.serverLore.kept.map { it.id })
        assertEquals(listOf(found.entry.id), model.serverLore.savedStickers.keys.sorted())
        assertEquals(listOf(somewhere), server.asked)
    }
}
