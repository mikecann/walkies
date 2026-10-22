package com.mikecann.walkies.model

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.place.RoadLine
import com.mikecann.walkies.repoRoot
import com.mikecann.walkies.store.Store
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.math.BigDecimal
import java.nio.file.Files
import java.util.UUID

/**
 * The same values, written by literals only, as FixtureValues in
 * WalkiesTests/FixtureExportTests.swift. Change both together.
 */
object Fixtures {
    val placeA: UUID = UUID.fromString("0E5F6C1A-2B3C-4D5E-8F90-A1B2C3D4E5F6")
    val placeB: UUID = UUID.fromString("6A1B2C3D-4E5F-4061-8728-394A5B6C7D8E")
    val placeC: UUID = UUID.fromString("F0E1D2C3-B4A5-4697-8879-6A5B4C3D2E1F")
    val credit: UUID = UUID.fromString("11111111-2222-4333-8444-555555555555")
    val walk1: UUID = UUID.fromString("A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5")
    val walk2: UUID = UUID.fromString("B2B2B2B2-C3C3-4D4D-8E5E-F6F6F6F6F6F6")
    val walk3: UUID = UUID.fromString("C3C3C3C3-D4D4-4E5E-8F6F-070707070707")
    val deleted: UUID = UUID.fromString("DEADBEEF-0000-4000-8000-000000000001")

    private fun c(lat: Double, lon: Double) = Coordinate(lat, lon)
    private fun date(sinceReference: Double) = SwiftDate(sinceReference)

    val cities = listOf(
        City(
            id = placeA, name = "Geographe", detail = "Busselton, Western Australia, Australia", osmId = 11688696, gridVersion = 2,
            boundary = Boundary(listOf(GeoPolygon(
                outer = listOf(c(-33.6409, 115.3586), c(-33.6409, 115.3721), c(-33.6301, 115.3721), c(-33.6301, 115.3586)),
                holes = listOf(listOf(c(-33.637, 115.362), c(-33.637, 115.364), c(-33.635, 115.363))),
            ))),
            tiles = setOf(Hex(-3, -7), Hex(0, 0), Hex(145554, -44178), Hex(-145554, 44178), Hex(Int.MAX_VALUE, Int.MIN_VALUE)),
            visited = setOf(Hex(-3, -7), Hex(145554, -44178)),
            roads = listOf(
                RoadLine(RoadLine.Kind.Road, listOf(c(-33.639, 115.36), c(-33.638, 115.365))),
                RoadLine(RoadLine.Kind.Path, listOf(c(-33.6355, 115.3601), c(-33.6352, 115.3609), c(-33.6349, 115.3612))),
            ),
            stickers = mapOf("geographe-jetty" to Hex(-3, -7), "old-mill" to Hex(145554, -44178)),
            createdAt = date(800_000_000.5), updatedAt = date(812_345_678.25),
            tileCredits = listOf(City.TileCredit(credit, date(-31_535_999.875), setOf(Hex(-3, -7)))),
            lastWalked = linkedMapOf(Hex(-3, -7) to 29_833_340, Hex(145554, -44178) to -1),
        ),
        City(
            id = placeB, name = "Bare place", detail = "", osmId = null, gridVersion = null,
            boundary = Boundary(listOf(GeoPolygon(listOf(c(1.5, 2.5), c(1.5, 2.6), c(1.6, 2.6)), emptyList()))),
            tiles = emptySet(), visited = emptySet(), roads = null, stickers = null, createdAt = date(-1000.25), updatedAt = null, tileCredits = null,
        ),
        City(
            id = placeC, name = "Empty streets", detail = "Somewhere", osmId = 1, gridVersion = 2,
            boundary = Boundary(emptyList()),
            tiles = setOf(Hex(1, -1)), visited = emptySet(), roads = emptyList(), stickers = emptyMap(),
            createdAt = date(0.0), updatedAt = date(0.001), tileCredits = emptyList(),
        ),
    )

    val walks = listOf(
        Walk(
            id = walk1, startedAt = date(812_345_000.125), endedAt = date(812_348_600.5),
            points = listOf(
                TrackPoint(-33.6391, 115.3602, 1_790_000_000.25, 4.5, speed = 1.35),
                TrackPoint(-33.6389, 115.3611, 1_790_000_007.75, 12.0, speed = null, wheels = false, still = true),
                TrackPoint(-33.6387, 115.362, 1_790_000_015.0, -1.0, speed = 0.0, wheels = true, still = false),
            ),
            distance = 1234.5, gridVersion = 2, newTiles = 2,
            newTilesByPlace = mapOf(placeA.uuidString to 2),
            newTileHexesByPlace = mapOf(placeA.uuidString to setOf(Hex(-3, -7), Hex(145554, -44178))),
            addedTilesByPlace = mapOf(placeA.uuidString to setOf(Hex(-3, -7))),
            automatic = null,
        ),
        // 1 a.m. on 1 January 2000: before Swift's reference date, so negative.
        Walk(
            id = walk2, startedAt = date(-31_618_799.25), endedAt = date(-31_615_200.0),
            points = listOf(TrackPoint(51.5007, -0.1246, 946_688_400.75, 65.0)),
            distance = 0.0, gridVersion = null, newTiles = 0, automatic = false,
        ),
        // An always-on walk still going.
        Walk(
            id = walk3, startedAt = date(812_400_000.0), endedAt = null,
            points = listOf(TrackPoint(-33.64, 115.37, 1_790_054_800.0, 8.0, speed = 1.1)),
            distance = 42.0, gridVersion = 2, newTiles = 0,
            newTilesByPlace = emptyMap(), newTileHexesByPlace = emptyMap(), addedTilesByPlace = emptyMap(),
            automatic = true,
        ),
    )

    val ledger = Ledger(
        purchases = listOf(
            Ledger.Purchase("9C1F2E3D-0000-4000-8000-00000000000A", "spyglass", 60, 1_790_000_000.5),
            Ledger.Purchase("P-2", "marker.paw", 120, 1_790_000_001.0),
        ),
        claims = listOf(Ledger.Claim(2, "shells.50"), Ledger.Claim(3, "spyglasses.2")),
        spyglasses = listOf(Ledger.Spyglass("S-1", "geographe-jetty", listOf(-33.6391, 115.3602), 1_790_000_100.125)),
        equipped = Ledger.Equipped("marker.paw", "trail.teal", "clouds.classic", "cover.red", "celebration.confetti", 1_790_000_200.75),
        offers = listOf(Ledger.Offer(2, listOf("shells.50", "marker.paw", "spyglasses.2")), Ledger.Offer(3, listOf("spyglasses.2"))),
    )

    val stickers = mapOf(
        "geographe-jetty" to date(812_345_678.5),
        "old-mill" to SwiftDate.distantFuture,
        "busselton-jetty" to date(-86_400.5),
    )

    val syncState = SyncState(
        uploadedWalks = setOf(walk1), uploadedPlaces = mapOf(placeA to date(812_345_678.25)), uploadedSecrets = setOf("geographe-jetty"),
        uploadedProgress = """{"claims":[],"equipped":{}}""", deletedPlaces = setOf(deleted),
    )

    const val OWNER = "fixture-user"

    /** Writes them with the real Store, exactly as the app saves them. */
    fun write(root: File) {
        val store = Store(root)
        store.save(cities)
        store.flush()
        for (walk in walks) store.save(walk)
        store.saveStickers(stickers)
        store.saveProgress(ledger)
        store.saveSyncState(syncState)
        store.saveOwner(OWNER)
    }
}

/**
 * Golden files both ways (design/android.md): what the iPhone wrote must read here and
 * write back the same, and what this writes goes to shared/fixtures/android for the
 * iPhone's tests to read. Run with -PwriteFixtures to write them.
 */
class FixtureTest {
    private val ios = File(repoRoot(), "shared/fixtures/ios")

    private fun files(folder: File): List<String> =
        folder.walkTopDown().filter { it.isFile && it.extension == "json" }.map { it.relativeTo(folder).path }.sorted().toList()

    /** Reads a file as its type and writes it back, as the store would. */
    private fun roundTrip(name: String, json: JsonElement): JsonElement = when {
        name == "cities.json" -> Codec.cities(Codec.cities(json))
        name == "roads.json" -> Codec.roadsByCity(Codec.roadsByCity(json))
        name == "stickers.json" -> Codec.stickers(Codec.stickers(json))
        name == "progress.json" -> Codec.ledger(Codec.ledger(json))
        name == "sync.json" -> Codec.syncState(Codec.syncState(json))
        name == "owner.json" -> JsonPrimitive((json as JsonPrimitive).content.also { assertEquals(true, json.isString) })
        name == "data-version.json" -> JsonPrimitive((json as JsonPrimitive).int)
        name.startsWith("walks/") -> Codec.walk(Codec.walk(json))
        else -> throw AssertionError("Nothing reads $name: add it to Codec and this test")
    }

    private fun skipIfNoIosFixtures() =
        assumeTrue("No iPhone fixtures in shared/fixtures/ios yet: see shared/fixtures/README.md", files(ios).isNotEmpty())

    @Test
    fun iPhoneFilesReadAndWriteBackTheSame() {
        skipIfNoIosFixtures()
        for (name in files(ios)) {
            val original = Codec.parse(File(ios, name).readText())
            val again = roundTrip(name, original)
            assertNull("$name differs after reading and writing it again", difference(original, again, name))
        }
    }

    @Test
    fun iPhoneFilesMeanTheSameAsOurValues() {
        skipIfNoIosFixtures()
        val root = File(Files.createTempDirectory("walkies-fixtures").toFile(), "Walkies")
        ios.copyRecursively(root)
        val store = Store(root)
        assertEquals(Fixtures.cities, store.loadCities())
        assertEquals(Fixtures.walks.sortedBy { it.startedAt }, store.loadWalks())
        assertEquals(Fixtures.stickers, store.loadStickers())
        assertEquals(Fixtures.ledger, store.loadProgress())
        assertEquals(Fixtures.syncState, store.loadSyncState())
        assertEquals(Fixtures.OWNER, store.loadOwner())
        assertFalse(store.needsWorldGridReset)
        root.parentFile.deleteRecursively()
    }

    @Test
    fun ourFilesHaveTheSameShapeAsTheIPhones() {
        skipIfNoIosFixtures()
        val root = File(Files.createTempDirectory("walkies-fixtures").toFile(), "Walkies")
        Fixtures.write(root)
        assertEquals(files(ios), files(root))
        // Sets come out in any order on the iPhone, so compare with arrays sorted.
        for (name in files(ios)) {
            val theirs = sorted(Codec.parse(File(ios, name).readText()))
            val ours = sorted(Codec.parse(File(root, name).readText()))
            assertNull("$name differs from the iPhone's", difference(theirs, ours, name))
        }
        root.parentFile.deleteRecursively()
    }

    @Test
    fun numbersAreWrittenTheWaySwiftWritesThem() {
        assertEquals("1", Codec.number(1.0).toString())
        assertEquals("-31615200", Codec.number(-31_615_200.0).toString())
        assertEquals("63113904000", Codec.number(SwiftDate.distantFuture.sinceReference).toString())
        assertEquals("812345678.25", Codec.number(812_345_678.25).toString())
        assertEquals("-33.6391", Codec.number(-33.6391).toString())
        assertEquals("0.001", Codec.number(0.001).toString())
    }

    /** Writes shared/fixtures/android when asked, for WalkiesTests/FixtureExportTests.swift to read. */
    @Test
    fun writeAndroidFixtures() {
        val wanted = System.getProperty("walkies.writeFixtures")
        assumeTrue("Run with -PwriteFixtures to write shared/fixtures/android", !wanted.isNullOrEmpty() && wanted != "false")
        val out = File(repoRoot(), "shared/fixtures/android")
        val root = File(Files.createTempDirectory("walkies-fixtures").toFile(), "Walkies")
        Fixtures.write(root)
        File(out, "walks").listFiles { f -> f.extension == "json" }?.forEach { it.delete() }
        for (name in files(root)) File(root, name).copyTo(File(out, name), overwrite = true)
        root.parentFile.deleteRecursively()
    }

    companion object {
        /**
         * The first place two JSON trees differ, or null if they're the same: the same
         * keys, the same values, numbers compared by value (Swift writes 1, we write 1.0).
         */
        fun difference(a: JsonElement, b: JsonElement, path: String = ""): String? = when {
            a is JsonObject && b is JsonObject -> {
                if (a.keys != b.keys) "$path: keys ${a.keys.sorted()} vs ${b.keys.sorted()}"
                else a.keys.firstNotNullOfOrNull { difference(a.getValue(it), b.getValue(it), "$path.$it") }
            }
            a is JsonArray && b is JsonArray -> {
                if (a.size != b.size) "$path: ${a.size} items vs ${b.size}"
                else a.indices.firstNotNullOfOrNull { difference(a[it], b[it], "$path[$it]") }
            }
            a is JsonNull || b is JsonNull -> if (a == b) null else "$path: $a vs $b"
            a is JsonPrimitive && b is JsonPrimitive -> when {
                a.isString != b.isString -> "$path: $a vs $b"
                a.isString -> if (a.content == b.content) null else "$path: $a vs $b"
                a.content == "true" || a.content == "false" || b.content == "true" || b.content == "false" ->
                    if (a.content == b.content) null else "$path: $a vs $b"
                else -> if (BigDecimal(a.content).compareTo(BigDecimal(b.content)) == 0) null else "$path: $a vs $b"
            }
            else -> "$path: $a vs $b"
        }

        /** Every array sorted by its text, for comparing files whose sets can come out in any order. */
        fun sorted(e: JsonElement): JsonElement = when (e) {
            is JsonObject -> JsonObject(e.mapValues { sorted(it.value) })
            is JsonArray -> JsonArray(e.map(::sorted).sortedBy { canonical(it) })
            else -> e
        }

        /** Numbers by value, so 1 and 1.0 sort together. */
        private fun canonical(e: JsonElement): String = when (e) {
            is JsonObject -> e.entries.sortedBy { it.key }.joinToString(",", "{", "}") { "${it.key}:${canonical(it.value)}" }
            is JsonArray -> e.joinToString(",", "[", "]") { canonical(it) }
            is JsonPrimitive -> if (e.isString || e is JsonNull || e.content == "true" || e.content == "false") e.toString()
                else BigDecimal(e.content).stripTrailingZeros().toPlainString()
        }
    }
}
