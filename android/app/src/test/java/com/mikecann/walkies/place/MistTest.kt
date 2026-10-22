package com.mikecann.walkies.place

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.map.CloudField
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.Progression
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.tempStore
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * Walked tiles not walked again for a while go misty (MistTests.swift). Mist is only
 * a look: it never changes tiles, %, shells, XP, levels or quests.
 */
class MistTest {
    private val origin = Coordinate(-22.5, 133.75)
    private val day = 86_400.0
    private var now = 1_790_000_000.0

    private fun hex(q: Int, r: Int = 0): Hex {
        val base = HexGrid.hex(containing = origin)
        return Hex(base.q + q, base.r + r)
    }

    /** Street tiles q 0 to 19 along one row, the first [visited] of them walked. */
    private fun city(visited: Int = 10): City {
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(HexGrid.centre(hex(0)) + it) }
        return City(
            name = "Misty", detail = "Tests",
            boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = (0 until 20).mapTo(LinkedHashSet()) { hex(it) },
            visited = (0 until visited).mapTo(LinkedHashSet()) { hex(it) },
            roads = emptyList(),
        )
    }

    /** A point [x] metres east of the middle of tile [q]. */
    private fun point(q: Int, x: Double = 0.0): Coordinate = HexGrid.projection.unproject(HexGrid.centre(hex(q)) + Vec2(x, 0.0))

    /** A walk across tile [q], [daysAgo] days ago. */
    private fun walk(q: Int, daysAgo: Double): Walk {
        val start = now - daysAgo * day
        val points = listOf(-20.0, 0.0, 20.0).mapIndexed { i, x ->
            val c = point(q, x)
            TrackPoint(c.lat, c.lon, start + i * 15, 5.0, speed = 1.3)
        }
        return Walk(startedAt = SwiftDate.epoch(start), endedAt = SwiftDate.epoch(start + 60), points = points, distance = 40.0)
    }

    private fun minute(daysAgo: Double) = Mist.minute(now - daysAgo * day)

    // The record

    @Test
    fun savedAsTriplesAndOldSavesHaveNone() {
        val city = city().copy(lastWalked = linkedMapOf(hex(1) to 29_000_000, hex(0) to 28_999_999))
        val json = Codec.city(city)
        val saved = json["lastWalked"] as JsonArray
        assertEquals(2, saved.size)
        assertTrue(saved.all { (it as JsonArray).size == 3 })
        assertEquals(setOf(29_000_000, 28_999_999), saved.map { (it as JsonArray)[2].jsonPrimitive.int }.toSet())
        assertEquals(city, Codec.city(json))
        val old = JsonObject(json - "lastWalked")
        assertNull(Codec.city(old).lastWalked)
    }

    @Test
    fun walkingNotesOnlyTilesThatCountAndClearsMist() {
        val start = city(visited = 3).copy(lastWalked = mapOf(hex(0) to minute(90.0), hex(1) to minute(0.01)))
        // Tile 0 was misty, tile 1 walked a quarter of an hour ago, tile 2 never noted,
        // and the point off the end of the row isn't a tile you've visited.
        val points = listOf(point(0), point(1), point(2), point(-5))
        val result = start.noteWalked(points, now, 60.0)
        assertTrue(result.changed)
        assertEquals(setOf(hex(0)), result.cleared)
        val walked = result.city.lastWalked!!
        assertEquals(Mist.minute(now), walked[hex(0)])
        assertEquals(minute(0.01), walked[hex(1)])
        assertEquals(Mist.minute(now), walked[hex(2)])
        assertNull(walked[hex(-5)])
        assertEquals(3, result.city.visited.size)
        assertEquals(20, result.city.tiles.size)

        assertFalse(result.city.noteWalked(points, now + 60, 60.0).changed)
    }

    @Test
    fun mergingKeepsTheLaterDateForEachTile() {
        val mine = mapOf(hex(0) to 100, hex(1) to 500)
        val theirs = mapOf(hex(0) to 300, hex(1) to 200, hex(2) to 50)
        assertTrue(Mist.hasLater(mine, theirs))
        val merged = city().copy(lastWalked = mine).mergingLastWalked(theirs).lastWalked
        assertEquals(mapOf(hex(0) to 300, hex(1) to 500, hex(2) to 50), merged)
        assertTrue(Mist.hasLater(merged, theirs))
        assertFalse(Mist.hasLater(theirs, merged))
        assertNull(city().mergingLastWalked(null).lastWalked)
    }

    @Test
    fun filledInFromTheWalksAndCredits() {
        val creditAt = SwiftDate.epoch(now - 10 * day)
        val city = city(visited = 6).copy(tileCredits = listOf(City.TileCredit(UUID.randomUUID(), creditAt, setOf(hex(4)))))
        val older = walk(2, 40.0)
        val newer = walk(2, 5.0)
        val other = walk(3, 70.0)
        val found = Mist.lastWalked(listOf(city), listOf(newer, older, other))[city.id]!!
        // When the walk passed it, not when it started or the older walk did.
        val crossed = found.getValue(hex(2))
        assertTrue(crossed >= Mist.minute(newer.points[0].time) && crossed <= Mist.minute(newer.points[2].time))
        val long = found.getValue(hex(3))
        assertTrue(long >= Mist.minute(other.points[0].time) && long <= Mist.minute(other.points[2].time))
        assertEquals(Mist.minute(creditAt.epochSeconds), found[hex(4)])
        // Tiles nobody walked, on record or at all, have no date.
        assertNull(found[hex(0)])
        assertNull(found[hex(10)])
    }

    @Test
    fun noPathTilesClearedForFreeNeverMist() {
        // One street tile, walked long ago, surrounded by bush that cleared beside it.
        val bare = city(visited = 1).copy(tiles = setOf(hex(0)))
        val city = bare.copy(lastWalked = Mist.lastWalked(listOf(bare), listOf(walk(0, 100.0)))[bare.id])
        assertTrue(hex(1) in city.cloudCover().clear)
        assertEquals(setOf(hex(0)), Mist.tiles(listOf(city), now, 60.0))
        val field = CloudField(listOf(city), mistAt = now, mistDays = 60.0)
        assertEquals(setOf(hex(0)), field.mist.map { it.tile }.toSet())
    }

    @Test
    fun mistyTilesForADateAndThreshold() {
        val a = city(visited = 4).copy(lastWalked = mapOf(hex(0) to minute(61.0), hex(1) to minute(59.0), hex(2) to minute(200.0)))
        assertEquals(setOf(hex(0), hex(2)), Mist.tiles(listOf(a), now, 60.0))
        assertEquals(setOf(hex(2)), Mist.tiles(listOf(a), now, 100.0))
        assertEquals(setOf(hex(0), hex(1), hex(2)), Mist.tiles(listOf(a), now + 2 * day, 60.0))
        // About a minute and a half: `--es mistDays 0.001`.
        val b = city(visited = 2).copy(lastWalked = mapOf(hex(0) to minute(0.002), hex(1) to Mist.minute(now)))
        assertEquals(setOf(hex(0)), Mist.tiles(listOf(b), now, 0.001))
        // A tile on the border of two places goes by whichever saw you last.
        val c = city(visited = 1).copy(id = UUID.randomUUID(), lastWalked = mapOf(hex(0) to minute(1.0)))
        assertEquals(setOf(hex(2)), Mist.tiles(listOf(a, c), now, 60.0))
        // Without a visit, never misty; without a time to check against, no mist drawn.
        val d = city(visited = 0).copy(lastWalked = mapOf(hex(0) to minute(300.0)))
        assertTrue(Mist.tiles(listOf(d), now, 60.0).isEmpty())
        assertTrue(CloudField(listOf(a)).mist.isEmpty())
    }

    @Test
    fun mistNeverChangesProgress() {
        val walks = listOf(walk(1, 90.0), walk(2, 3.0))
        val plain = city()
        val misty = plain.copy(lastWalked = Mist.lastWalked(listOf(plain), walks)[plain.id])
        assertTrue(Mist.tiles(listOf(misty), now, 60.0).isNotEmpty())
        assertEquals(plain.progress, misty.progress, 0.0)
        assertEquals(plain.cloudCover(), misty.cloudCover())
        val at = SwiftDate.epoch(now)
        val before = Progression.state(Progression.Inputs(cities = listOf(plain), walks = walks, now = at))
        val after = Progression.state(Progression.Inputs(cities = listOf(misty), walks = walks, now = at))
        assertEquals(before, after)
        assertEquals(Progression.countingTiles(listOf(plain)), Progression.countingTiles(listOf(misty)))
    }

    // The app

    private fun model(store: com.mikecann.walkies.store.Store, mistDays: Double = 0.0) =
        AppModel(store, FakeSettings(alwaysOn = false, mistDays = mistDays), FakeLocation(), clock = { now })

    @Test
    fun launchFillsInDatesFromSavedWalksOnce() {
        val (store, _) = tempStore()
        val city = city()
        store.save(listOf(city))
        val old = walk(3, 80.0)
        store.save(old)
        val model = model(store)
        val walked = model.cities[0].lastWalked
        assertNotNull(walked)
        assertTrue(walked!!.getValue(hex(3)) >= Mist.minute(old.startedAt.epochSeconds))
        assertNull(walked[hex(5)])
        assertEquals(city.visited, model.cities[0].visited)
        store.flush()
        assertEquals(walked, store.loadCities().first().lastWalked)
        assertEquals(walked, model(store).cities[0].lastWalked)
    }

    @Test
    fun walkingThroughMistClearsItAndChangesNothingElse() {
        val (store, _) = tempStore()
        val city = city().copy(lastWalked = (0 until 10).associate { hex(it) to minute(100.0) })
        store.save(listOf(city))
        val model = model(store)
        val xp = model.xp
        val progress = model.cities[0].progress
        val revision = model.tilesRevision
        assertTrue(hex(0) in Mist.tiles(model.cities, now, model.mistDays))
        model.startWalk()
        for ((i, x) in listOf(-20.0, 0.0, 20.0).withIndex()) {
            val c = point(0, x)
            model.record(TrackPoint(c.lat, c.lon, now + i * 15, 5.0, speed = 1.3))
        }
        val misty = Mist.tiles(model.cities, now + 30, model.mistDays)
        assertFalse(hex(0) in misty)
        assertTrue(hex(5) in misty)
        assertTrue(model.tilesRevision > revision)
        assertEquals(city.visited, model.cities[0].visited)
        assertEquals(city.tiles, model.cities[0].tiles)
        assertEquals(progress, model.cities[0].progress, 0.0)
        assertEquals(xp, model.xp)
    }

    @Test
    fun aShortMistDaysOverridesTheSixty() {
        val (store, _) = tempStore()
        store.save(listOf(city()))
        assertEquals(60.0, model(store).mistDays, 0.0)
        assertEquals(0.001, model(store, mistDays = 0.001).mistDays, 0.0)
    }

    @Test
    fun pullingAPlaceKeepsTheLaterDates() = runBlocking {
        val (store, _) = tempStore()
        val city = city().copy(lastWalked = mapOf(hex(0) to 1000, hex(1) to 5000))
        store.save(listOf(city))
        val model = model(store)
        model.addRemote(listOf(city.copy(lastWalked = mapOf(hex(0) to 2000, hex(1) to 4000, hex(2) to 3000))), emptyList(), null, emptyMap())
        val expected = mapOf(hex(0) to 2000, hex(1) to 5000, hex(2) to 3000)
        assertEquals(expected, model.cities[0].lastWalked)
        model.addRemote(listOf(city.copy(lastWalked = null)), emptyList(), null, emptyMap())
        assertEquals(expected, model.cities[0].lastWalked)
    }
}
