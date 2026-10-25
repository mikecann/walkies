package com.mikecann.walkies.place

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.Motion
import com.mikecann.walkies.convex.Http
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.Progression
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.repoRoot
import com.mikecann.walkies.store.Store
import com.mikecann.walkies.tempStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.URLDecoder
import java.util.UUID
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot

/**
 * Places that add themselves (issue #2): what to look up or add for some spots, the
 * boundary rule, and the model adding them where you are and where you've walked.
 * AutoPlacesTests.swift checks the same on the iPhone.
 */
class AutoPlacesTest {
    private var now = 1_790_000_000.0
    private val clock = { now }
    private val origin = Coordinate(-33.65, 115.35)

    /** A square suburb [half] metres either side of [x] metres east of [origin]. */
    private fun place(name: String, osmId: Long, x: Double, half: Double = 1000.0): PlaceResult {
        val centre = HexGrid.projection.project(origin) + Vec2(x, 0.0)
        val ring = listOf(Vec2(-half, -half), Vec2(half, -half), Vec2(half, half), Vec2(-half, half), Vec2(-half, -half))
            .map { HexGrid.projection.unproject(centre + it) }
        return PlaceResult(osmId, name, "Tests", "suburb", Boundary(listOf(GeoPolygon(ring, emptyList()))), 4 * half * half, osmId)
    }

    private fun spot(x: Double, y: Double = 0.0) = HexGrid.projection.unproject(HexGrid.projection.project(origin) + Vec2(x, y))

    private fun here(x: Double, y: Double = 0.0, accuracy: Double = 5.0) = AutoPlaces.Spot(spot(x, y), accuracy)

    /** Samples every 10 m from one spot to another, as CoverageTracer gives them. */
    private fun track(from: Pair<Double, Double>, to: Pair<Double, Double>): List<Coordinate> {
        val n = maxOf(1, ceil(hypot(to.first - from.first, to.second - from.second) / 10).toInt())
        return (0..n).map { i ->
            val t = i.toDouble() / n
            spot(from.first + (to.first - from.first) * t, from.second + (to.second - from.second) * t)
        }
    }

    private fun shape(place: PlaceResult) = BoundaryShape(place.boundary, HexGrid.projection)

    private fun fix(c: Coordinate, accuracy: Double = 5.0, after: Double = 0.0, speed: Double = 1.0) =
        TrackPoint(c.lat, c.lon, now + after, accuracy, speed = speed)

    /** A finished walk east along the middle from [from] to [to] metres, a fix every 10 m. */
    private fun walk(from: Double, to: Double, endedAt: SwiftDate): Walk {
        val start = endedAt.plus(-600.0)
        val points = ArrayList<TrackPoint>()
        var x = from
        while (x <= to) {
            val c = spot(x)
            points.add(TrackPoint(c.lat, c.lon, start.epochSeconds + points.size * 8, 5.0, speed = 1.25))
            x += 10
        }
        return Walk(startedAt = start, endedAt = endedAt, points = points, distance = to - from)
    }

    private val nobody = { _: PlaceResult -> false }
    private val today get() = SwiftDate.epoch(now)

    /** Stands in for OpenStreetMap: the suburb whose square holds the spot, and a count. */
    private class FakeOSM {
        var suburbs: List<PlaceResult> = emptyList()
        val lookups = ArrayList<Coordinate>()
        var inFlight = 0
        var mostAtOnce = 0
        var pause = 0L

        suspend fun lookUp(spot: Coordinate): AutoPlaces.Lookup {
            lookups.add(spot)
            inFlight++
            mostAtOnce = maxOf(mostAtOnce, inFlight)
            try {
                if (pause > 0) delay(pause)
                val p = HexGrid.projection.project(spot)
                return AutoPlaces.Lookup(suburbs.firstOrNull { BoundaryShape(it.boundary, HexGrid.projection).contains(p) })
            } finally {
                inFlight--
            }
        }
    }

    private class FakeMotion(override var onWheels: Boolean = false, override var still: Boolean = false) : Motion

    private fun model(store: Store, osm: FakeOSM, scope: CoroutineScope, motion: Motion = Motion.Unknown): AppModel {
        // A list of neighbours that covers everywhere (and none nearby), so adding a place
        // doesn't go looking for them.
        store.saveNearby(NearbyPlaces(-90.0, -180.0, 90.0, 180.0, SwiftDate.epoch(now), emptyList()))
        val model = AppModel(store, FakeSettings(), FakeLocation(), motion = motion, clock = clock, osm = OSMClient(NoNetwork))
        model.services = scope
        model.lookUpSuburb = osm::lookUp
        model.buildPlace = { place, walks -> CityBuilder.build(place, emptyList(), walks) }
        // As if the map had just come on screen.
        model.foreground(true)
        return model
    }

    // What to do about a spot

    @Test
    fun aSpotInOneOfYourPlacesNeedsNothing() {
        val home = place("Home", 1, 0.0)
        assertEquals(AutoPlaces.Next.Nothing, AutoPlaces().next(here(100.0), emptyList(), listOf(shape(home)), emptyList(), nobody, now = today))
    }

    @Test
    fun aSpotInAKnownNeighbourAddsItWithoutALookup() {
        val home = place("Home", 1, 0.0)
        val next = place("Next door", 2, 2000.0)
        assertEquals(
            AutoPlaces.Next.Add(next),
            AutoPlaces().next(here(2100.0), emptyList(), listOf(shape(home)), listOf(home, next), { it.osmId == 1L }, now = today),
        )
        // A neighbour you deleted, or one that's far too big, doesn't count.
        assertEquals(AutoPlaces.Next.Nothing, AutoPlaces().decline(2).next(here(2100.0), emptyList(), emptyList(), listOf(next), nobody, now = today))
        val huge = place("Shire", 3, 2000.0, half = 15_000.0)
        assertEquals(AutoPlaces.Next.LookUp(spot(2100.0)), AutoPlaces().next(here(2100.0), emptyList(), emptyList(), listOf(huge), nobody, now = today))
    }

    @Test
    fun aDeletedPlaceWithoutAnOSMIdIsKnownByNameWhereItWas() {
        val old = CityBuilder.build(place("Abbey", 2, 2000.0), emptyList(), emptyList()).copy(osmId = null)
        val auto = AutoPlaces().decline(old)
        assertTrue(auto.declined.isEmpty())
        // OpenStreetMap's outline now, a little different from the one saved back then.
        val now = place("abbey", 2, 2100.0)
        assertTrue(auto.isDeclined(now))
        assertEquals(AutoPlaces.Next.Nothing, auto.next(here(2100.0), emptyList(), emptyList(), listOf(now), nobody, now = today))
        // Another suburb with that name somewhere else, or another suburb there, still can.
        assertFalse(auto.isDeclined(place("Abbey", 3, 20_000.0)))
        assertFalse(auto.isDeclined(place("Broadwater", 4, 2000.0)))
    }

    @Test
    fun aRememberedMissIsntLookedUpAgainForAMonth() {
        val sea = spot(5000.0)
        val auto = AutoPlaces().looked(sea, AutoPlaces.Lookup(null), nobody, today)
        // Anywhere in the same square, about 200 m across.
        val nearby = Coordinate(sea.lat, floor(sea.lon / AutoPlaces.CELL_SIZE) * AutoPlaces.CELL_SIZE + 0.0001)
        assertEquals(AutoPlaces.Next.Nothing, auto.next(null, listOf(listOf(sea, nearby)), emptyList(), emptyList(), nobody, now = today))
        val later = today.plus(31 * 24 * 3600.0)
        assertEquals(AutoPlaces.Next.LookUp(sea), auto.next(null, listOf(listOf(sea)), emptyList(), emptyList(), nobody, now = later))
        assertTrue(auto.tidied(later).missedUntil.isEmpty())
    }

    @Test
    fun aMissOnlyCoversAbout200Metres() {
        val sea = spot(5000.0)
        val auto = AutoPlaces().looked(sea, AutoPlaces.Lookup(null), nobody, today)
        assertTrue(auto.missed(sea, today))
        // 300 m away, in any direction, is somewhere else.
        for (other in listOf(spot(5300.0), spot(4700.0), spot(5000.0, 300.0), spot(5000.0, -300.0))) assertFalse(auto.missed(other, today))
        assertTrue(AutoPlaces.CELL_SIZE * 111_320 < 250)
    }

    @Test
    fun onlyTheFirstSpotThatNeedsItIsLookedUp() {
        assertEquals(
            AutoPlaces.Next.LookUp(spot(5000.0)),
            AutoPlaces().next(null, listOf(listOf(spot(5000.0), spot(9000.0))), emptyList(), emptyList(), nobody, now = today),
        )
    }

    @Test
    fun aLookupThatFindsNoSuburbIsAMissButOneOfYoursIsnt() {
        val home = place("Home", 1, 0.0)
        val tiny = place("Tiny", 4, 0.0, half = 100.0)
        // One of yours: nothing's ruled out, so the suburb over the border still can be added.
        var auto = AutoPlaces().looked(spot(100.0), AutoPlaces.Lookup(home), { it.osmId == 1L }, today)
        assertTrue(auto.found.isEmpty())
        assertFalse(auto.missed(spot(100.0), today))
        auto = auto.looked(spot(3000.0), AutoPlaces.Lookup(tiny), nobody, today)
        assertTrue(auto.found.isEmpty())
        assertTrue(auto.missed(spot(3000.0), today))
        val found = place("Found", 5, 8000.0)
        auto = auto.looked(spot(8000.0), AutoPlaces.Lookup(found), nobody, today)
        assertEquals(listOf(found), auto.found)
        assertFalse(auto.missed(spot(8000.0), today))
        // A hex already asked about this time isn't asked again.
        assertEquals(
            AutoPlaces.Next.Nothing,
            auto.next(here(100.0), emptyList(), emptyList(), emptyList(), nobody, setOf(HexGrid.hex(containing = spot(100.0))), today),
        )
    }

    @Test
    fun theSmallestSuburbSizedBoundaryWins() {
        val tiny = place("Tiny", 10, 0.0, half = 100.0)
        val suburb = place("Suburb", 9, 0.0, half = 2000.0)
        val shire = place("Shire", 8, 0.0, half = 15_000.0)
        assertEquals(suburb, AutoPlaces.pick(listOf(shire, suburb, tiny), listOf(10, 9, 8)))
        assertNull(AutoPlaces.pick(listOf(shire), listOf(8)))
        assertNull(AutoPlaces.pick(emptyList(), emptyList()))
    }

    // Borders

    @Test
    fun openingTheAppJustOverTheBorderFromHomeDoesNothing() {
        val home = place("Home", 1, 0.0)
        val next = place("Next door", 2, 2000.0)
        fun decide(spot: AutoPlaces.Spot, known: List<PlaceResult> = emptyList()) =
            AutoPlaces().next(spot, emptyList(), listOf(shape(home)), known, { it.osmId == 1L }, now = today)
        // Home's edge is 1000 m east. 40 m over it is GPS wobble from home.
        assertEquals(AutoPlaces.Next.Nothing, decide(here(1040.0)))
        assertEquals(AutoPlaces.Next.Nothing, decide(here(1040.0), listOf(home, next)))
        // Far enough over to be sure.
        assertEquals(AutoPlaces.Next.LookUp(spot(1060.0)), decide(here(1060.0)))
        assertEquals(AutoPlaces.Next.Add(next), decide(here(1060.0), listOf(home, next)))
        // A vaguer fix needs to be further over.
        assertEquals(AutoPlaces.Next.Nothing, decide(here(1060.0, accuracy = 80.0)))
        assertEquals(AutoPlaces.Next.LookUp(spot(1100.0)), decide(here(1100.0, accuracy = 80.0)))
    }

    @Test
    fun walkingAlongABorderStreetAddsNothing() {
        val home = place("Home", 1, 0.0)
        val next = place("Next door", 2, 2000.0)
        val other = place("Other", 3, 4000.0)
        val mine = { p: PlaceResult -> p.osmId == 1L }
        // Up the street on home's border, the GPS wobbling 20 m either side of it.
        fun wobble(x: Double) = (0..160).map { i -> spot(x + if (i % 2 == 0) 20.0 else -20.0, -800.0 + i * 10) }
        val along = wobble(1000.0)
        val auto = AutoPlaces()
        fun decide(track: List<Coordinate>, known: List<PlaceResult>) = auto.next(null, listOf(track), listOf(shape(home)), known, mine, now = today)
        assertEquals(AutoPlaces.Next.Nothing, decide(along, emptyList()))
        assertEquals(AutoPlaces.Next.Nothing, decide(along, listOf(home, next)))
        // The same along a border between two suburbs that aren't yours.
        assertEquals(AutoPlaces.Next.Nothing, decide(wobble(3000.0), listOf(next, other)))
        // A stray fix well in, but only one, doesn't count either.
        val stray = along.toMutableList().apply { add(80, spot(1080.0, 0.0)) }
        assertEquals(AutoPlaces.Next.Nothing, decide(stray, listOf(home, next)))
        // Turning off it and walking 100 m in does.
        val into = track(1000.0 to 0.0, 1100.0 to 0.0)
        assertEquals(AutoPlaces.Next.Add(next), decide(along + into, listOf(home, next)))
        assertTrue(AutoPlaces.wentInto(shape(next), into))
        assertFalse(AutoPlaces.wentInto(shape(next), track(1000.0 to 0.0, 1060.0 to 0.0)))
    }

    // Waiting and backing off

    @Test
    fun aSuburbWhoseStreetsWontDownloadWaitsLongerEachTime() {
        val abbey = place("Abbey", 21, 2000.0)
        var auto = AutoPlaces()
        val waits = ArrayList<Double>()
        repeat(12) {
            auto = auto.failedToBuild(abbey, today)
            waits.add(Math.round(auto.buildFailures.getValue("21").retryAt.sinceReference - today.sinceReference).toDouble())
        }
        assertEquals(listOf(300.0, 600.0, 1200.0, 2400.0), waits.take(4))
        assertEquals(24 * 3600.0, waits.last(), 0.0)
        // Waiting, it's skipped and the walks wait with it; then it's tried again.
        val walk = listOf(track(1100.0 to 0.0, 2000.0 to 0.0))
        assertEquals(AutoPlaces.Next.Later, auto.next(here(2000.0), walk, emptyList(), listOf(abbey), nobody, now = today))
        assertEquals(AutoPlaces.Next.Add(abbey), auto.next(here(2000.0), walk, emptyList(), listOf(abbey), nobody, now = today.plus(24 * 3600.0 + 1)))
        // Added in the end: it starts from scratch.
        assertTrue(auto.added(abbey).buildFailures.isEmpty())
    }

    @Test
    fun aFailedLookupWaitsAndOtherSpotsCarryOn() {
        val next = place("Next door", 2, 2000.0)
        val auto = AutoPlaces().lookUpFailed(today)
        // Nothing's asked for five minutes, but a suburb whose outline is known still adds.
        assertEquals(AutoPlaces.Next.Later, auto.next(here(9000.0), emptyList(), emptyList(), emptyList(), nobody, now = today))
        assertEquals(AutoPlaces.Next.Add(next), auto.next(here(2000.0), emptyList(), emptyList(), listOf(next), nobody, now = today))
        assertEquals(AutoPlaces.Next.LookUp(spot(9000.0)), auto.next(here(9000.0), emptyList(), emptyList(), emptyList(), nobody, now = today.plus(301.0)))
    }

    // The fallback

    @Test
    fun theFallbacksAnswerFollowsTheSameRule() {
        // Nominatim's reverse lookup gives one boundary, and the country it's in.
        assertEquals(listOf(11688696L), AutoPlaces.suburbCandidates(listOf(AutoPlaces.Relation(11688696, "9")), "au"))
        // In Australia, never the council.
        assertTrue(AutoPlaces.suburbCandidates(listOf(AutoPlaces.Relation(11688682, "6")), "au").isEmpty())
        assertEquals(listOf(57539L), AutoPlaces.suburbCandidates(listOf(AutoPlaces.Relation(57539, "6")), "gb"))
        assertTrue(AutoPlaces.suburbCandidates(listOf(AutoPlaces.Relation(8005, "11")), "nl").isEmpty())
        assertTrue(AutoPlaces.suburbCandidates(listOf(AutoPlaces.Relation(8004, null)), "gb").isEmpty())
        // Finding nothing only rules a spot out for a day, since Overpass never answered.
        val spot = spot(5000.0)
        val auto = AutoPlaces().looked(spot, AutoPlaces.Lookup(null, fallback = true), nobody, today)
        assertTrue(auto.missed(spot, today.plus(23 * 3600.0)))
        assertFalse(auto.missed(spot, today.plus(25 * 3600.0)))
    }

    @Test
    fun withOverpassDownTheFallbackNeverAddsTheCouncil() = runBlocking {
        val asked = ArrayList<String>()
        val http = object : Http {
            override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response {
                asked.add(url)
                return when {
                    url in OSMClient.OVERPASS -> Http.Response(200, """{"remark":"runtime error: Query timed out","elements":[]}""".toByteArray())
                    url.startsWith("https://nominatim.openstreetmap.org/reverse") -> {
                        assertTrue(url.contains("extratags=1"))
                        // The City of Busselton is the council, not a suburb.
                        Http.Response(200, """{"osm_type":"relation","osm_id":11688682,"extratags":{"admin_level":"6"},"address":{"country_code":"au"}}""".toByteArray())
                    }
                    else -> throw AssertionError("Didn't expect to go to $url")
                }
            }
        }
        assertEquals(AutoPlaces.Lookup(null, fallback = true), OSMClient(http, OSMLane(0)).suburb(Coordinate(-33.635, 115.385)))
        // Overpass, then the reverse lookup at every zoom (the council each time), and no outline to fetch.
        assertEquals(AutoPlaces.FALLBACK_ZOOMS, zooms(asked))
        assertEquals(1 + AutoPlaces.FALLBACK_ZOOMS.size, asked.size)
    }

    private val fallback by lazy { Json.parseToJsonElement(File(repoRoot(), "shared/fixtures/places/reverse-fallback.json").readText()).jsonObject }

    /** A spot in shared/fixtures/places/reverse-fallback.json: what Nominatim really answered there, at each zoom. */
    private fun fallbackCase(prefix: String) =
        fallback["cases"]!!.jsonArray.map { it.jsonObject }.first { it["name"]!!.jsonPrimitive.content.startsWith(prefix) }

    /** The zooms the reverse lookups asked at, in order. */
    private fun zooms(asked: List<String>) = asked
        .filter { it.startsWith("https://nominatim.openstreetmap.org/reverse") }
        .map { Regex("[?&]zoom=(\\d+)").find(it)!!.groupValues[1].toInt() }

    /** OpenStreetMap with Overpass down, and Nominatim answering as it did at this spot. */
    private fun overpassDown(case: JsonObject, asked: MutableList<String>) = object : Http {
        override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response {
            asked.add(url)
            fun query(name: String) = Regex("[?&]$name=([^&]*)").find(url)?.groupValues?.get(1)?.let { URLDecoder.decode(it, "UTF-8") }
            return when {
                url in OSMClient.OVERPASS -> Http.Response(504, ByteArray(0))
                url.startsWith("https://nominatim.openstreetmap.org/reverse") -> {
                    val answer = case["reverse"]!!.jsonObject[query("zoom")] ?: throw AssertionError("Didn't expect to ask at zoom ${query("zoom")}")
                    Http.Response(200, answer.toString().toByteArray())
                }
                url.startsWith("https://nominatim.openstreetmap.org/lookup") -> {
                    val ids = query("osm_ids")!!.split(",")
                    val found = fallback["lookup"]!!.jsonArray.filter { "R${it.jsonObject["osm_id"]!!.jsonPrimitive.long}" in ids }
                    Http.Response(200, JsonArray(found).toString().toByteArray())
                }
                else -> throw AssertionError("Didn't expect to go to $url")
            }
        }
    }

    @Test
    fun theFallbackMatchesTheSharedFixture() = runBlocking {
        val outlines = fallback["lookup"]!!.jsonArray.mapNotNull { OSMClient.place(it.jsonObject) }
        for (case in fallback["cases"]!!.jsonArray.map { it.jsonObject }) {
            val name = case["name"]!!.jsonPrimitive.content
            val asked = ArrayList<Int>()
            val candidates = AutoPlaces.fallbackCandidates { zoom ->
                asked.add(zoom)
                OSMClient.reverseAnswer(case["reverse"]!!.jsonObject[zoom.toString()]?.jsonObject ?: throw AssertionError("$name asked at zoom $zoom"))
            }
            assertEquals(name, case["asked"]!!.jsonArray.map { it.jsonPrimitive.int }, asked)
            assertEquals(name, case["candidates"]!!.jsonArray.map { it.jsonPrimitive.long }, candidates)
            assertEquals(name, case["osmId"]!!.jsonPrimitive.longOrNull, AutoPlaces.pick(outlines, candidates)?.osmId)
        }
    }

    @Test
    fun inEnglandTheFallbackFindsTheParishPastTheCounty() = runBlocking {
        val asked = ArrayList<String>()
        val found = OSMClient(overpassDown(fallbackCase("Porlock"), asked), OSMLane(0)).suburb(Coordinate(51.2092, -3.5953))
        // Somerset at zoom 12 is far too big, so it asks again closer in.
        assertEquals(2676434L, found.place?.osmId)
        assertEquals("Porlock", found.place?.name)
        assertTrue(found.fallback)
        assertEquals(listOf(12, 14), zooms(asked))
        assertEquals(1, asked.count { it.startsWith("https://nominatim.openstreetmap.org/lookup") })
    }

    @Test
    fun whenEveryZoomFindsNothingTheSpotIsRuledOutForADay() = runBlocking {
        val asked = ArrayList<String>()
        val point = Coordinate(-33.6, 115.38)
        val found = OSMClient(overpassDown(fallbackCase("Out in Geographe Bay"), asked), OSMLane(0)).suburb(point)
        // Busselton's name pin at every zoom, and never a boundary to look up.
        assertEquals(AutoPlaces.Lookup(null, fallback = true), found)
        assertEquals(AutoPlaces.FALLBACK_ZOOMS, zooms(asked))
        assertFalse(asked.any { it.startsWith("https://nominatim.openstreetmap.org/lookup") })
        val auto = AutoPlaces().looked(point, found, nobody, today)
        assertTrue(auto.missed(point, today.plus(23 * 3600.0)))
        assertFalse(auto.missed(point, today.plus(25 * 3600.0)))
    }

    @Test
    fun oneRequestAtATimeToOpenStreetMap() = runBlocking {
        val lane = OSMLane(100)
        var inFlight = 0
        var mostAtOnce = 0
        val starts = ArrayList<Long>()
        (0 until 3).map {
            async {
                lane.run {
                    inFlight++
                    mostAtOnce = maxOf(mostAtOnce, inFlight)
                    starts.add(System.nanoTime())
                    delay(20)
                    inFlight--
                }
            }
        }.awaitAll()
        assertEquals(1, mostAtOnce)
        assertTrue(starts.zipWithNext().all { (a, b) -> (b - a) / 1_000_000 >= 99 })
    }

    // The rule both phones share

    private val rule by lazy { Json.parseToJsonElement(File(repoRoot(), "shared/fixtures/places/suburb-rule.json").readText()).jsonObject }

    @Test
    fun theSuburbRuleMatchesTheSharedFixture() {
        for (case in rule["cases"]!!.jsonArray.map { it.jsonObject }) {
            val relations = case["relations"]!!.jsonArray.map { r ->
                val o = r.jsonObject
                fun text(key: String) = o[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.contentOrNull
                AutoPlaces.Relation(o["id"]!!.jsonPrimitive.long, text("admin_level"), text("ISO3166-1"))
            }
            val expected = case["expected"]!!.jsonArray.map { it.jsonPrimitive.long }
            assertEquals(case["name"]!!.jsonPrimitive.content, expected, AutoPlaces.suburbCandidates(relations))
        }
    }

    @Test
    fun aPlaceGetsTheSameIdFromItsBoundaryOnEveryPhone() {
        for (expected in rule["placeIds"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(expected["id"]!!.jsonPrimitive.content, City.idForOsm(expected["osmId"]!!.jsonPrimitive.long).uuidString)
        }
        assertEquals("B57E647F-BA14-30F9-82D7-B1F6F899A740", CityBuilder.build(place("Built", 123, 0.0), emptyList(), emptyList()).id.uuidString)
        val drawn = place("Drawn", 0, 0.0).copy(osmId = null)
        assertNotEquals(CityBuilder.build(drawn, emptyList(), emptyList()).id, CityBuilder.build(drawn, emptyList(), emptyList()).id)
    }

    // The model

    @Test
    fun aFreshAccountGetsTheSuburbItsIn() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Geographe", 11688696, 0.0))
        val model = model(store, osm, this)
        var findingWhileLooking = false
        model.lookUpSuburb = { spot ->
            findingWhileLooking = model.findingFirstPlace
            osm.lookUp(spot)
        }
        // Nothing until the account's places have come down.
        model.record(fix(spot(100.0)))
        model.waitForPlacesYouveBeen()
        assertTrue(osm.lookups.isEmpty())
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        // The place chip says it's finding your suburb meanwhile.
        assertTrue(findingWhileLooking)
        assertEquals(listOf(spot(100.0)), osm.lookups)
        assertEquals(listOf("Geographe"), model.cities.map { it.name })
        assertEquals(City.idForOsm(11688696), model.cities.first().id)
        assertEquals(model.cities.first().id, model.selectedCityId)
        assertEquals(1, model.flyToSelected)
        assertNull(model.addedPlaceNotice)
        assertFalse(model.findingFirstPlace)
        assertTrue(model.showWalkHint)
        // Saved, so the next launch doesn't ask again.
        assertTrue(store.loadAutoPlaces()!!.found.isEmpty())
    }

    @Test
    fun openingTheAppAtHomeDoesNothing() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        val home = CityBuilder.build(place("Home", 1, 0.0), emptyList(), emptyList())
        store.save(listOf(home))
        val model = model(store, osm, this)
        model.pulledAccount()
        model.record(fix(spot(300.0)))
        model.waitForPlacesYouveBeen()
        // Just over the border from home, which is GPS wobble from inside it.
        model.foreground(true)
        model.record(fix(spot(1040.0)))
        model.waitForPlacesYouveBeen()
        // A vague fix somewhere else is passed over too.
        model.foreground(true)
        model.record(fix(spot(9000.0), accuracy = 60.0))
        model.waitForPlacesYouveBeen()
        assertTrue(osm.lookups.isEmpty())
        assertEquals(listOf(home.id), model.cities.map { it.id })
        assertEquals(0, model.flyToSelected)
        // Still waiting for a good one, which then counts.
        assertTrue(model.checkSpotOnNextFix)
        model.record(fix(spot(9000.0), accuracy = 20.0))
        model.waitForPlacesYouveBeen()
        assertEquals(listOf(spot(9000.0)), osm.lookups)
    }

    @Test
    fun goingToTheBackgroundStopsTheSpotCheck() = runBlocking {
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 0.0))
        val model = model(tempStore().first, osm, this)
        // Opened indoors with no good fix, then closed: a fix from later, in a car on the
        // way somewhere, say, doesn't count.
        model.foreground(false)
        assertFalse(model.checkSpotOnNextFix)
        model.record(fix(spot(100.0)))
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        assertTrue(osm.lookups.isEmpty())
        // A spot taken but not checked yet (the account hadn't come down) is dropped too.
        val other = model(tempStore().first, osm, this)
        other.record(fix(spot(100.0)))
        other.foreground(false)
        other.pulledAccount()
        other.waitForPlacesYouveBeen()
        assertTrue(osm.lookups.isEmpty())
        assertTrue(model.cities.isEmpty())
    }

    @Test
    fun aFixFromACarIsPassedOver() = runBlocking {
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 0.0))
        val motion = FakeMotion()
        val model = model(tempStore().first, osm, this, motion)
        model.pulledAccount()
        // Faster than a walk.
        model.record(fix(spot(100.0), speed = 15.0))
        model.waitForPlacesYouveBeen()
        // Slow, but the motion chip says it's in a car: in traffic, say.
        motion.onWheels = true
        model.record(fix(spot(100.0), speed = 1.0))
        model.waitForPlacesYouveBeen()
        assertTrue(osm.lookups.isEmpty())
        assertTrue(model.checkSpotOnNextFix)
        // Out of the car and on foot, with the app still open.
        motion.onWheels = false
        model.record(fix(spot(100.0), speed = 1.0))
        model.waitForPlacesYouveBeen()
        assertEquals(1, osm.lookups.size)
        assertEquals(listOf("Abbey"), model.cities.map { it.name })
    }

    @Test
    fun signingOutInTheBackgroundDoesntArmTheSpotCheck() = runBlocking {
        val model = model(tempStore().first, FakeOSM(), this)
        model.foreground(false)
        model.wipeLocalData()
        assertFalse(model.checkSpotOnNextFix)
        model.foreground(true)
        model.wipeLocalData()
        assertTrue(model.checkSpotOnNextFix)
    }

    @Test
    fun aWalkAcrossTwoNewSuburbsAddsEachOnce() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 2000.0), place("Broadwater", 22, 4000.0))
        val home = CityBuilder.build(place("Home", 20, 0.0), emptyList(), emptyList())
        store.save(listOf(home))
        val model = model(store, osm, this)
        model.checkSpotOnNextFix = false
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        model.startWalk()
        // From home, through Abbey and into Broadwater, 50 m every 40 seconds. Clear of
        // the borders, so no spot is exactly on one.
        var x = 505.0
        var seconds = 0.0
        while (x <= 3605.0) {
            model.record(fix(spot(x), after = seconds))
            x += 50
            seconds += 40
        }
        now += seconds
        model.endWalk()
        model.waitForPlacesYouveBeen()
        assertEquals(listOf("Abbey", "Broadwater", "Home"), model.cities.map { it.name }.sorted())
        assertEquals(2, osm.lookups.size)
        // The walk's tiles count in both.
        assertTrue(model.cities.all { it.visited.isNotEmpty() })
        // You were already looking at home, so that stays and a note says what's new.
        assertEquals(home.id, model.selectedCityId)
        assertEquals("Broadwater", model.addedPlaceNotice?.name)
        // Done with that walk: opening the app again asks nothing.
        model.addPlacesYouveBeen()
        model.waitForPlacesYouveBeen()
        assertEquals(2, osm.lookups.size)
    }

    @Test
    fun theWalkYoureOnCountsInAPlaceThatAddsItselfPartway() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 2000.0))
        val home = CityBuilder.build(place("Home", 20, 0.0), emptyList(), emptyList())
        store.save(listOf(home))
        val model = model(store, osm, this)
        model.checkSpotOnNextFix = false
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        model.startWalk()
        // Ten minutes into a walk from home into Abbey, the app's opened.
        var x = 505.0
        while (x <= 2005.0) {
            model.record(fix(spot(x)))
            x += 50
            now += 20
        }
        val walked = CoverageTracer.samples(model.activeWalk!!.points).mapTo(HashSet()) { HexGrid.hex(containing = it) }
        model.foreground(true)
        model.record(fix(spot(2005.0)))
        model.waitForPlacesYouveBeen()
        val abbey = model.cities.first { it.name == "Abbey" }
        val inAbbey = walked.filter { BoundaryShape(abbey.boundary, HexGrid.projection).contains(HexGrid.centre(it)) }
        assertTrue(inAbbey.isNotEmpty())
        assertTrue(abbey.visited.containsAll(inAbbey))
        // New on this walk, so the summary and quests see them.
        assertTrue(model.freshTiles[abbey.id].orEmpty().isNotEmpty())
        model.endWalk()
        model.waitForPlacesYouveBeen()
        val walk = model.walks.last()
        assertTrue(walk.newTileHexesByPlace?.get(abbey.id.uuidString).orEmpty().isNotEmpty())
        assertEquals(walk.newTileHexesByPlace?.get(abbey.id.uuidString)?.size, model.questTileCounts[walk.id]?.get(abbey.id))
        // The walk's end finds nothing more to add.
        assertEquals(1, osm.lookups.size)
    }

    @Test
    fun aWalkIntoANewSuburbCountsItsTilesThereForQuestsOnce() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        val abbeyPlace = place("Abbey", 21, 2000.0)
        osm.suburbs = listOf(abbeyPlace)
        val home = CityBuilder.build(place("Home", 20, 0.0), emptyList(), emptyList())
        store.save(listOf(home))
        val model = model(store, osm, this)
        val reuploaded = ArrayList<UUID>()
        model.walksChanged = { reuploaded += it }
        model.checkSpotOnNextFix = false
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        model.startWalk()
        var x = 505.0
        var seconds = 0.0
        while (x <= 2505.0) {
            model.record(fix(spot(x), after = seconds))
            x += 50
            seconds += 40
        }
        now += seconds
        model.endWalk()
        model.waitForPlacesYouveBeen()
        val abbey = model.cities.single { it.name == "Abbey" }
        val walk = model.walks.last()
        assertTrue(abbey.visited.isNotEmpty())
        // Abbey's tiles are new on the walk that's just ended, once each.
        assertEquals(abbey.visited, walk.newTileHexesByPlace?.get(abbey.id.uuidString))
        assertEquals(abbey.visited.size, walk.newTilesByPlace?.get(abbey.id.uuidString))
        assertEquals(walk.newTileHexesByPlace!!.values.sumOf { it.size }, walk.newTiles)
        assertEquals(abbey.visited.size, model.questTileCounts[walk.id]?.get(abbey.id))
        assertEquals(walk.newTileHexesByPlace!![home.id.uuidString]?.size, model.questTileCounts[walk.id]?.get(home.id))
        // The same as the next launch works out, and it goes up again.
        assertEquals(model.questTileCounts[walk.id], Progression.backfill(model.walks, model.cities).counts[walk.id])
        assertEquals(walk.newTileHexesByPlace, store.loadWalks().single { it.id == walk.id }.newTileHexesByPlace)
        assertEquals(listOf(walk.id), reuploaded)

        // Deleted and added again by hand, the walk still counts them once.
        model.deleteCity(abbey.id)
        model.addPlace(abbeyPlace) {}
        assertEquals(abbey.visited, model.cities.single { it.id == abbey.id }.visited)
        assertEquals(walk.newTileHexesByPlace, model.walks.last().newTileHexesByPlace)
        assertEquals(abbey.visited.size, model.questTileCounts[walk.id]?.get(abbey.id))
        assertEquals(listOf(walk.id), reuploaded)
        store.flush()
        val restarted = model(store, FakeOSM(), this)
        assertEquals(model.questTileCounts[walk.id], restarted.questTileCounts[walk.id])
    }

    @Test
    fun aWalkThatEndsWhileAPlaceIsBuildingCountsForQuests() = runBlocking {
        val model = model(tempStore().first, FakeOSM(), this)
        model.startWalk()
        var x = 1505.0
        while (x <= 2505.0) {
            model.record(fix(spot(x)))
            x += 50
            now += 20
        }
        model.buildPlace = { place, walks ->
            model.endWalk()
            CityBuilder.build(place, emptyList(), walks)
        }
        model.addPlace(place("Abbey", 21, 2000.0)) {}
        val abbey = model.cities.single()
        val walk = model.walks.last()
        assertTrue(abbey.visited.isNotEmpty())
        assertEquals(abbey.visited, walk.newTileHexesByPlace?.get(abbey.id.uuidString))
        assertEquals(abbey.visited.size, model.questTileCounts[walk.id]?.get(abbey.id))
    }

    @Test
    fun aPlaceAddedByHandLeavesOlderWalksQuestsAlone() = runBlocking {
        val model = model(tempStore().first, FakeOSM(), this)
        val since = model.autoPlaces.walksSince!!
        // A walk from before places added themselves, so it was never looked at.
        val old = walk(1500.0, 2500.0, since.plus(-3600.0)).copy(newTilesByPlace = emptyMap(), newTileHexesByPlace = emptyMap())
        model.addRemote(emptyList(), listOf(old), null, emptyMap())
        model.addPlace(place("Abbey", 21, 2000.0)) {}
        val abbey = model.cities.single()
        // Its tiles are explored, as they always were, but it's not new on that walk.
        assertTrue(abbey.visited.isNotEmpty())
        assertNull(model.walks.single().newTileHexesByPlace?.get(abbey.id.uuidString))
        assertNull(model.questTileCounts[old.id]?.get(abbey.id))
    }

    @Test
    fun addingAPlaceByHandPartwayThroughAWalkCountsTheWalk() = runBlocking {
        val abbey = place("Abbey", 21, 2000.0)
        fun walkInto(model: AppModel) {
            model.startWalk()
            var x = 1505.0
            while (x <= 2505.0) {
                model.record(fix(spot(x)))
                x += 50
                now += 20
            }
        }
        val model = model(tempStore().first, FakeOSM(), this)
        walkInto(model)
        model.addPlace(abbey) {}
        val added = model.cities.single()
        assertTrue(added.visited.isNotEmpty())
        assertEquals(added.visited, model.freshTiles[added.id])

        // A walk that ends while the place is being built counts too.
        val other = model(tempStore().first, FakeOSM(), this)
        walkInto(other)
        other.buildPlace = { place, walks ->
            other.endWalk()
            CityBuilder.build(place, emptyList(), walks)
        }
        other.addPlace(abbey) {}
        assertNull(other.activeWalk)
        assertTrue(other.cities.single().visited.isNotEmpty())
    }

    @Test
    fun anOlderWalkThatDownloadsLaterIsStillLookedAt() = runBlocking {
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 2000.0), place("Broadwater", 22, -2000.0))
        val model = model(tempStore().first, osm, this)
        model.checkSpotOnNextFix = false
        val since = model.autoPlaces.walksSince!!
        // The 11:00 walk comes down first, then the 10:00 one.
        val later = walk(1500.0, 2500.0, since.plus(120.0))
        val earlier = walk(-2500.0, -1500.0, since.plus(60.0))
        now += 300
        model.addRemote(emptyList(), listOf(later), null, emptyMap())
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        assertEquals(listOf("Abbey"), model.cities.map { it.name })
        model.addRemote(emptyList(), listOf(earlier), null, emptyMap())
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        assertEquals(listOf("Abbey", "Broadwater"), model.cities.map { it.name }.sorted())
        assertEquals(setOf(later.id.uuidString, earlier.id.uuidString), model.autoPlaces.checkedWalks.keys)
        // A walk from before the update never adds anything, however late it comes.
        osm.suburbs = osm.suburbs + place("Carbunup", 23, 6000.0)
        model.addRemote(emptyList(), listOf(walk(5500.0, 6500.0, since.plus(-60.0))), null, emptyMap())
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        assertEquals(2, model.cities.size)
        assertEquals(2, osm.lookups.size)
    }

    @Test
    fun oneLookupAtATime() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        osm.pause = 50
        val model = model(store, osm, this)
        model.pulledAccount()
        model.record(fix(spot(50_000.0)))
        model.addPlacesYouveBeen()
        model.pulledAccount()
        model.addPlacesYouveBeen()
        model.waitForPlacesYouveBeen()
        assertEquals(1, osm.mostAtOnce)
        // Nothing there: the sea, say. Remembered, so it isn't asked about again.
        assertEquals(1, osm.lookups.size)
        model.foreground(true)
        model.record(fix(spot(50_000.0)))
        model.waitForPlacesYouveBeen()
        assertEquals(1, osm.lookups.size)
        assertTrue(model.cities.isEmpty())
    }

    @Test
    fun aFailedLookupWaitsBeforeTryingAgainEvenAfterARestart() = runBlocking {
        val (store, _) = tempStore()
        val model = model(store, FakeOSM(), this)
        var calls = 0
        val failing: suspend (Coordinate) -> AutoPlaces.Lookup = {
            calls++
            throw IOException("Offline")
        }
        model.lookUpSuburb = failing
        model.pulledAccount()
        model.record(fix(spot(0.0)))
        model.waitForPlacesYouveBeen()
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        assertEquals(1, calls)
        assertFalse(model.findingFirstPlace)
        assertTrue(model.autoPlaces.missedUntil.isEmpty())
        // Starting again doesn't skip the wait.
        val restarted = model(store, FakeOSM(), this)
        restarted.lookUpSuburb = failing
        restarted.pulledAccount()
        restarted.record(fix(spot(0.0)))
        restarted.waitForPlacesYouveBeen()
        assertEquals(1, calls)
        // It tries again once the wait's over.
        now += AutoPlaces.LOOK_UP_RETRY + 1
        restarted.foreground(true)
        restarted.record(fix(spot(0.0)))
        restarted.waitForPlacesYouveBeen()
        assertEquals(2, calls)
    }

    @Test
    fun aSuburbThatWontBuildWaitsItsTurnEvenAfterARestart() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 0.0))
        val model = model(store, osm, this)
        var builds = 0
        val failing: suspend (PlaceResult, List<Walk>) -> City = { _, _ ->
            builds++
            throw IOException("Timed out")
        }
        model.buildPlace = failing
        model.pulledAccount()
        model.record(fix(spot(100.0)))
        model.waitForPlacesYouveBeen()
        assertEquals(1, builds)
        assertEquals(listOf(21L), model.autoPlaces.found.map { it.osmId })
        assertEquals(1, model.autoPlaces.buildFailures["21"]?.count)
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        assertEquals(1, builds)
        val restarted = model(store, osm, this)
        restarted.buildPlace = failing
        restarted.pulledAccount()
        restarted.record(fix(spot(100.0)))
        restarted.waitForPlacesYouveBeen()
        assertEquals(1, builds)
        // Found once: no more lookups while it waits.
        assertEquals(1, osm.lookups.size)
        // Five minutes on, it's tried again; then ten.
        now += AutoPlaces.BUILD_RETRY + 1
        restarted.pulledAccount()
        restarted.waitForPlacesYouveBeen()
        assertEquals(2, builds)
        assertEquals(2, restarted.autoPlaces.buildFailures["21"]?.count)
    }

    @Test
    fun aPlaceYouDeleteDoesntAddItselfAgain() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 0.0))
        val model = model(store, osm, this)
        model.pulledAccount()
        model.record(fix(spot(100.0)))
        model.waitForPlacesYouveBeen()
        model.deleteCity(model.cities.single().id)
        repeat(2) {
            model.foreground(true)
            model.record(fix(spot(100.0)))
            model.waitForPlacesYouveBeen()
        }
        assertTrue(model.cities.isEmpty())
        assertEquals(setOf(21L), model.autoPlaces.declined)
        // One more look to learn the spot's in a place you deleted, and then no more.
        assertEquals(2, osm.lookups.size)
    }

    @Test
    fun anOlderPlaceYouDeleteDoesntAddItselfAgainEither() = runBlocking {
        val (store, _) = tempStore()
        val osm = FakeOSM()
        val abbey = place("Abbey", 21, 0.0)
        osm.suburbs = listOf(abbey, place("Abbey", 31, 20_000.0))
        // Saved before OSM ids were kept: a random id and none from OpenStreetMap.
        val old = CityBuilder.build(abbey, emptyList(), emptyList()).copy(id = UUID.randomUUID(), osmId = null)
        store.save(listOf(old))
        val model = model(store, osm, this)
        model.pulledAccount()
        model.waitForPlacesYouveBeen()
        model.deleteCity(old.id)
        assertEquals(listOf("Abbey"), model.autoPlaces.declinedPlaces.map { it.name })
        repeat(2) {
            model.foreground(true)
            model.record(fix(spot(100.0)))
            model.waitForPlacesYouveBeen()
        }
        assertTrue(model.cities.isEmpty())
        // One more look to learn the spot's in the place you deleted, and then no more.
        assertEquals(1, osm.lookups.size)
        // The Abbey somewhere else still adds itself.
        model.foreground(true)
        model.record(fix(spot(20_000.0)))
        model.waitForPlacesYouveBeen()
        assertEquals(listOf(31L), model.cities.map { it.osmId })
    }

    @Test
    fun aPlaceDeletedWhileItsBuildingIsntAdded() = runBlocking {
        val osm = FakeOSM()
        osm.suburbs = listOf(place("Abbey", 21, 0.0))
        val model = model(tempStore().first, osm, this)
        // Meanwhile it comes down from the account and you delete it.
        model.buildPlace = { place, walks ->
            val city = CityBuilder.build(place, emptyList(), walks)
            model.add(city)
            model.deleteCity(city.id)
            city
        }
        model.pulledAccount()
        model.record(fix(spot(100.0)))
        model.waitForPlacesYouveBeen()
        assertTrue(model.cities.isEmpty())
        assertEquals(setOf(21L), model.autoPlaces.declined)
        assertNull(model.addedPlaceNotice)
    }

    @Test
    fun twoCopiesOfOneSuburbBothStay() = runBlocking {
        val (store, _) = tempStore()
        val built = CityBuilder.build(place("Abbey", 21, 0.0), emptyList(), emptyList())
        val hexes = built.tiles.toList()
        val mine = built.copy(id = UUID.randomUUID(), visited = setOf(hexes[0]))
        val theirs = built.copy(id = UUID.randomUUID(), visited = setOf(hexes[1]))
        store.save(listOf(mine))
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        val deleted = ArrayList<UUID>()
        model.placesDeleted = { deleted += it }
        model.addRemote(listOf(theirs), emptyList(), null, emptyMap())
        // An older version added it on another phone with its own id. Both stay, as they
        // were: nothing's deleted from the account that you didn't delete.
        assertEquals(setOf(mine.id, theirs.id), model.cities.mapTo(HashSet()) { it.id })
        assertEquals(setOf(hexes[0]), model.cities.single { it.id == mine.id }.visited)
        assertEquals(setOf(hexes[1]), model.cities.single { it.id == theirs.id }.visited)
        assertTrue(deleted.isEmpty())
        store.flush()
        assertEquals(2, store.loadCities().size)
    }

    @Test
    fun addingASuburbYouHaveJustGoesThere() {
        val (store, _) = tempStore()
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        model.add(CityBuilder.build(place("Home", 1, 0.0), emptyList(), emptyList()))
        model.add(CityBuilder.build(place("Home", 1, 0.0), emptyList(), emptyList()))
        assertEquals(1, model.cities.size)
    }

    @Test
    fun whatsBeenLookedUpIsKeptInTheIPhonesJson() {
        val (store, root) = tempStore()
        val walkId = UUID.fromString("0E1D3A52-6E5B-4C77-9C5F-5C2C2C9E7A10")
        val auto = AutoPlaces(
            missedUntil = mapOf("-16825,57675" to SwiftDate(812345678.25)),
            found = listOf(place("Abbey", 21, 0.0)),
            declined = setOf(7, 3),
            declinedPlaces = listOf(AutoPlaces.DeclinedPlace("Busselton", Coordinate(-33.65, 115.35))),
            walksSince = SwiftDate(812345600.0),
            checkedWalks = mapOf(walkId.uuidString to SwiftDate(812345700.0)),
            lookUpAgainAt = SwiftDate(812346000.0),
            buildFailures = mapOf("21" to AutoPlaces.BuildFailure(2, SwiftDate(812346600.0))),
        )
        store.saveAutoPlaces(auto)
        assertEquals(auto, store.loadAutoPlaces())
        val json = Json.parseToJsonElement(File(root, "auto-places.json").readText()).jsonObject
        assertEquals("812345678.25", (json["missedUntil"] as JsonObject)["-16825,57675"]!!.jsonPrimitive.content)
        assertEquals(listOf(3L, 7L), (json["declined"] as JsonArray).map { it.jsonPrimitive.long })
        val declinedPlace = (json["declinedPlaces"] as JsonArray).single().jsonObject
        assertEquals("Busselton", declinedPlace["name"]!!.jsonPrimitive.content)
        assertEquals("-33.65", declinedPlace["point"]!!.jsonObject["lat"]!!.jsonPrimitive.content)
        assertEquals(21L, (json["found"] as JsonArray).single().jsonObject["osmId"]!!.jsonPrimitive.long)
        assertEquals("812345600", json["walksSince"]!!.jsonPrimitive.content)
        assertEquals("812345700", (json["checkedWalks"] as JsonObject)["0E1D3A52-6E5B-4C77-9C5F-5C2C2C9E7A10"]!!.jsonPrimitive.content)
        assertEquals("812346000", json["lookUpAgainAt"]!!.jsonPrimitive.content)
        val failure = (json["buildFailures"] as JsonObject)["21"]!!.jsonObject
        assertEquals("2", failure["count"]!!.jsonPrimitive.content)
        assertEquals("812346600", failure["retryAt"]!!.jsonPrimitive.content)
        // One from before most of this was kept still reads.
        val old = AutoPlaces.from(Json.parseToJsonElement("""{"declined":[3],"found":[]}"""))
        assertEquals(setOf(3L), old.declined)
        assertTrue(old.declinedPlaces.isEmpty())
        assertNull(old.walksSince)
    }

    // The real lookup, with OpenStreetMap faked

    @Test
    fun overpassSaysWhichBoundariesAndNominatimBringsTheOutline() = runBlocking {
        val asked = ArrayList<String>()
        val http = object : Http {
            override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response {
                asked.add(url)
                return when {
                    url in OSMClient.OVERPASS -> {
                        assertTrue(body!!.decodeToString().contains("is_in"))
                        Http.Response(200, """{"elements":[
                            {"type":"relation","id":80500,"tags":{"admin_level":"2","boundary":"administrative","ISO3166-1":"AU"}},
                            {"type":"relation","id":11688682,"tags":{"admin_level":"6","boundary":"administrative"}},
                            {"type":"relation","id":11688696,"tags":{"admin_level":"9","boundary":"administrative"}}]}""".toByteArray())
                    }
                    url.startsWith("https://nominatim.openstreetmap.org/lookup") -> {
                        assertTrue(url.contains("R11688696"))
                        // Not the city council: this is Australia.
                        assertFalse(url.contains("R11688682"))
                        Http.Response(200, """[{"place_id":5,"osm_type":"relation","osm_id":11688696,"name":"Geographe","addresstype":"suburb",
                            "display_name":"Geographe, Busselton, Western Australia, Australia",
                            "geojson":{"type":"Polygon","coordinates":[[[115.38,-33.64],[115.39,-33.64],[115.39,-33.63],[115.38,-33.63],[115.38,-33.64]]]}}]""".toByteArray())
                    }
                    else -> throw AssertionError("Didn't expect to go to $url")
                }
            }
        }
        val found = OSMClient(http).suburb(Coordinate(-33.635, 115.385))
        assertEquals(11688696L, found.place?.osmId)
        assertEquals("Geographe", found.place?.name)
        assertFalse(found.fallback)
        assertEquals(2, asked.size)
    }

    @Test
    fun withOverpassDownNominatimSaysWhichSuburb() = runBlocking {
        val asked = ArrayList<String>()
        val http = object : Http {
            override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response {
                asked.add(url)
                return when {
                    // One server's down and the other times out, which still comes back 200.
                    url == OSMClient.OVERPASS.first() -> Http.Response(504, ByteArray(0))
                    url in OSMClient.OVERPASS -> Http.Response(200, """{"remark":"runtime error: Query timed out","elements":[]}""".toByteArray())
                    url.startsWith("https://nominatim.openstreetmap.org/reverse") ->
                        Http.Response(200, """{"osm_type":"relation","osm_id":11688696,"extratags":{"admin_level":"9"},"address":{"country_code":"au"}}""".toByteArray())
                    url.startsWith("https://nominatim.openstreetmap.org/lookup") ->
                        Http.Response(200, """[{"place_id":5,"osm_type":"relation","osm_id":11688696,"name":"Geographe",
                            "geojson":{"type":"Polygon","coordinates":[[[115.38,-33.64],[115.39,-33.64],[115.39,-33.63],[115.38,-33.63],[115.38,-33.64]]]}}]""".toByteArray())
                    else -> throw AssertionError("Didn't expect to go to $url")
                }
            }
        }
        val found = OSMClient(http).suburb(Coordinate(-33.635, 115.385))
        assertEquals(11688696L, found.place?.osmId)
        assertTrue(found.fallback)
        assertEquals(OSMClient.OVERPASS.size + 2, asked.size)
        // The locality is as small as it gets in Australia, so no other zoom is asked.
        assertEquals(listOf(12), zooms(asked))
    }

    private object NoNetwork : Http {
        override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response =
            throw AssertionError("Didn't expect to go to $url")
    }
}
