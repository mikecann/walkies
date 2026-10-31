package com.mikecann.walkies.lore

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.place.NearbyPlaces
import com.mikecann.walkies.place.PlaceResult
import com.mikecann.walkies.tempStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Asking the server to get secrets ready for the suburbs round you (LorePrep.kt, `lore:prepare`). */
class LorePrepTest {
    // Somewhere with no bundled secrets, so nothing's skipped unless a test says so.
    private val lat = 12.0
    private val lon = 45.0

    /** A square suburb about 2.2 km across, [east] and [north] of the one you're in, in hundredths of a degree. */
    private fun square(east: Double, north: Double = 0.0): Boundary {
        val s = lat + north / 100
        val w = lon + east / 100
        return Boundary(listOf(GeoPolygon(listOf(
            Coordinate(s, w), Coordinate(s, w + 0.02), Coordinate(s + 0.02, w + 0.02), Coordinate(s + 0.02, w),
        ), emptyList())))
    }

    private val here = Coordinate(lat + 0.01, lon + 0.01)
    private fun suburb(id: Long?, east: Double, north: Double = 0.0) = LorePrep.Suburb(id, square(east, north))

    @Test
    fun theSuburbYoureInThenTheOnesNextToItNearestFirst() {
        val places = listOf(suburb(1, 0.0))
        val nearby = listOf(
            // Right next door, a little further (about 330 m of gap), and too far (about 1.1 km).
            suburb(4, 2.0), suburb(3, 2.3), suburb(5, 3.0),
            suburb(2, -2.0), suburb(1, 0.0),
            // Diagonally, about 470 m corner to corner.
            suburb(6, 2.3, north = 2.3),
        )
        assertEquals(listOf(1L, 2L, 4L, 3L, 6L), LorePrep.around(here, places, nearby) { false })
    }

    @Test
    fun bundledSuburbsAreLeftOutButTheirNeighboursStillCount() {
        val nearby = listOf(suburb(2, 2.0), suburb(3, -2.0))
        assertEquals(listOf(3L), LorePrep.around(here, listOf(suburb(1, 0.0)), nearby) { it == 1L || it == 2L })
        // A place saved before it had an OSM id still has neighbours.
        assertEquals(listOf(2L, 3L), LorePrep.around(here, listOf(suburb(null, 0.0)), nearby) { false })
    }

    @Test
    fun theSuburbYoureInCanBeANeighbourYouHaventAdded() {
        val nearby = listOf(suburb(7, 0.0), suburb(8, 2.0))
        assertEquals(listOf(7L, 8L), LorePrep.around(here, emptyList(), nearby) { false })
    }

    @Test
    fun nothingWhenYoureInNoSuburbAtAll() {
        assertTrue(LorePrep.around(Coordinate(lat - 1, lon), listOf(suburb(1, 0.0)), listOf(suburb(2, 2.0))) { false }.isEmpty())
    }

    @Test
    fun atMostTwelve() {
        val nearby = (0 until 20).map { suburb(100L + it, 2.0, north = (it - 10) * 0.1) }
        val ids = LorePrep.around(here, listOf(suburb(1, 0.0)), nearby) { false }
        assertEquals(LorePrep.MAX, ids.size)
        assertEquals(1L, ids.first())
    }

    @Test
    fun theSameSuburbsAreOnlyAskedForEveryHalfHour() {
        val asked = LorePrep().asked(listOf(3, 1, 2), now = 1000.0)
        assertFalse(asked.due(listOf(1, 2, 3), now = 1000.0 + 29 * 60))
        assertTrue(asked.due(listOf(1, 2, 3), now = 1000.0 + 30 * 60))
        // A different lot straight away.
        assertTrue(asked.due(listOf(1, 2), now = 1001.0))
        assertTrue(asked.due(listOf(1, 2, 3, 4), now = 1001.0))
        assertFalse(LorePrep().due(emptyList(), now = 1000.0))
    }

    @Test
    fun theAppAsksAsYouGoAndNotOnEveryFix() {
        var now = 1_790_000_000.0
        val (store, _) = tempStore()
        store.save(listOf(City(name = "Home", detail = "", osmId = 1, boundary = square(0.0), tiles = emptySet(), visited = emptySet())))
        fun result(id: Long, east: Double) = PlaceResult(id = id, name = "N$id", detail = "", kind = "suburb", boundary = square(east), area = 4e6, osmId = id)
        store.saveNearby(NearbyPlaces(-90.0, -180.0, 90.0, 180.0, SwiftDate.epoch(now), listOf(result(2, 2.0), result(3, 6.0))))
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = { now })
        model.services = CoroutineScope(Dispatchers.Unconfined)
        val calls = ArrayList<List<Long>>()
        model.prepareLore = { calls.add(it) }
        model.refreshNeighbours()
        fun fix(c: Coordinate) = model.record(TrackPoint(c.lat, c.lon, now, 5.0, speed = 1.3))

        fix(here)
        assertEquals(listOf(listOf(1L, 2L)), calls)
        // Walking about the same suburb asks nothing more for half an hour.
        now += 600
        fix(Coordinate(here.lat, here.lon + 0.002))
        now += 1000
        fix(Coordinate(here.lat, here.lon + 0.004))
        assertEquals(1, calls.size)
        // Into the suburb next door: a different lot, straight away. Its neighbours come
        // from OpenStreetMap's list, which here hasn't got Home in it.
        now += 60
        fix(Coordinate(here.lat, lon + 0.03))
        assertEquals(listOf(listOf(1L, 2L), listOf(2L)), calls)
        // After half an hour there, the same lot again.
        now += 31 * 60
        fix(Coordinate(here.lat, lon + 0.031))
        assertEquals(3, calls.size)
    }

    @Test
    fun failuresAreJustLogged() {
        var now = 1_790_000_000.0
        val (store, _) = tempStore()
        store.save(listOf(City(name = "Home", detail = "", osmId = 1, boundary = square(0.0), tiles = emptySet(), visited = emptySet())))
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = { now })
        model.services = CoroutineScope(Dispatchers.Unconfined)
        var calls = 0
        model.prepareLore = { calls++; error("No such function lore:prepare") }
        model.record(TrackPoint(here.lat, here.lon, now, 5.0, speed = 1.3))
        assertEquals(1, calls)
        // And it doesn't keep trying on every fix.
        now += 60
        model.record(TrackPoint(here.lat, here.lon + 0.002, now, 5.0, speed = 1.3))
        assertEquals(1, calls)
    }
}
