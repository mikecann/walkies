package com.mikecann.walkies.model

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.ui.ReplayPlayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** WalkRecapTests.swift: the prediction, the replay's clock, and the recap of a walk. */
class WalkRecapTest {
    private val now = 1_800_000_000.0

    private fun walk(daysAgo: Double, tiles: Int, metres: Double = 2000.0): Walk {
        val start = SwiftDate.epoch(now - daysAgo * 24 * 3600)
        return Walk(startedAt = start, endedAt = start.plus(1800.0), distance = metres, newTiles = tiles)
    }

    private fun place(left: Int) = WalkRecap.Place(java.util.UUID.randomUUID(), "Geographe", 0.1, 0.12, 10, left)

    @Test
    fun predictsWalksFromYourAverage() {
        val history = listOf(walk(6.0, 20), walk(3.0, 10))
        val prediction = WalkRecap.prediction(place(300), walk(0.0, 30), history, now)!!
        // Averaging 20 a walk, 300 left.
        assertEquals(15, prediction.walks)
        assertEquals(3.0, prediction.walksPerWeek!!, 1e-9)
        assertEquals(5.0, prediction.weeks!!, 1e-9)
    }

    @Test
    fun shortPottersDontDragTheAverageDown() {
        val history = listOf(walk(2.0, 0, metres = 40.0), walk(1.0, 1, metres = 120.0))
        assertEquals(4, WalkRecap.prediction(place(100), walk(0.0, 25), history, now)?.walks)
    }

    @Test
    fun noPredictionWhenThereIsNothingToGoOn() {
        assertNull(WalkRecap.prediction(place(100), walk(0.0, 0), emptyList(), now))
        assertNull(WalkRecap.prediction(place(0), walk(0.0, 9), emptyList(), now))
        assertNull(WalkRecap.prediction(null, walk(0.0, 9), emptyList(), now))
    }

    @Test
    fun oneWalkGivesACountButNoPace() {
        val prediction = WalkRecap.prediction(place(50), walk(0.0, 10), emptyList(), now)!!
        assertEquals(5, prediction.walks)
        assertNull(prediction.walksPerWeek)
    }

    private fun recap(times: List<Double>, duration: Double = 1800.0): WalkRecap {
        val start = SwiftDate.epoch(now)
        val walk = Walk(startedAt = start, endedAt = start.plus(duration))
        return WalkRecap(
            walk = walk, route = times.map { Coordinate(0.0, 0.0) }, routeTimes = times,
            reveals = emptyList(), secrets = emptyList(), places = emptyList(), prediction = null, isBest = false,
            before = emptyList(), after = emptyList(),
        )
    }

    @Test
    fun elapsedFollowsTheWalksOwnClock() {
        // Five points along the route, with a ten-minute stop between the third and fourth.
        val recap = recap(listOf(0.0, 60.0, 120.0, 720.0, 780.0), duration = 800.0)
        assertEquals(0.0, recap.elapsed(0.0), 1e-9)
        assertEquals(60.0, recap.elapsed(0.25), 1e-9)
        assertEquals(120.0, recap.elapsed(0.5), 1e-9)
        // Halfway between the third and fourth points is halfway through the stop.
        assertEquals(420.0, recap.elapsed(0.625), 1e-9)
        assertEquals(720.0, recap.elapsed(0.75), 1e-9)
    }

    @Test
    fun elapsedEndsOnTheWalksFullTime() {
        val recap = recap(listOf(5.0, 60.0, 120.0), duration = 150.0)
        assertEquals(150.0, recap.elapsed(1.0), 1e-9)
        assertEquals(recap.walk.duration(), recap.elapsed(1.0), 1e-9)
        assertTrue(recap.elapsed(0.999) <= 150)
    }

    @Test
    fun elapsedWithoutTimesSpreadsTheWalkEvenly() {
        val recap = recap(emptyList(), duration = 600.0)
        assertEquals(300.0, recap.elapsed(0.5), 1e-9)
        assertEquals(600.0, recap.elapsed(1.0), 1e-9)
    }

    @Test
    fun routeSamplesCarryTheirFixesTimes() {
        val origin = Coordinate(-33.65, 115.35)
        val points = (0 until 3).map { i -> TrackPoint(origin.lat + i * 0.0002, origin.lon, 1000.0 + i * 20, 5.0, speed = 1.2) }
        val timed = CoverageTracer.timedSamples(points)
        assertEquals(timed.samples.size, timed.times.size)
        assertEquals(CoverageTracer.samples(points), timed.samples)
        assertEquals(timed.times.sorted(), timed.times)
        assertTrue(timed.times.first() > 1000 && timed.times.first() <= 1020)
        assertEquals(1040.0, timed.times.last(), 1e-9)
    }

    @Test
    fun rewatchIsOffByDefault() {
        assertFalse(recap(emptyList()).isRewatch)
    }

    @Test
    fun theReplayTakesTwoSecondsForEveryTenMinutesWalked() {
        assertEquals(5.0, ReplayPlayer.replayDuration(600.0), 1e-9)
        assertEquals(6.0, ReplayPlayer.replayDuration(1800.0), 1e-9)
        assertEquals(12.0, ReplayPlayer.replayDuration(3600.0), 1e-9)
        // A dash to the letterbox is still watchable; a day out doesn't drag.
        assertEquals(5.0, ReplayPlayer.replayDuration(60.0), 1e-9)
        assertEquals(12.0, ReplayPlayer.replayDuration(5 * 3600.0), 1e-9)
    }

    @Test
    fun tilesAndSecretsTurnUpInTheOrderYouWalkedToThem() {
        val base = HexGrid.hex(containing = Coordinate(-33.65, 115.35))
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(HexGrid.centre(base) + it) }
        val row = (0 until 10).map { Hex(base.q + it, base.r) }
        val secretHex = row[4]
        val before = City(
            name = "Geographe", detail = "Tests", boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = row.toSet(), visited = emptySet(), stickers = mapOf("jetty" to secretHex),
        )
        // East along the row, 50 m every 40 seconds.
        val start = now
        val points = (0..8).map { i ->
            val c = HexGrid.projection.unproject(HexGrid.centre(base) + Vec2(i * 50.0, 0.0))
            TrackPoint(c.lat, c.lon, start + i * 40, 5.0, speed = 1.25)
        }
        val (after, fresh) = before.visit(CoverageTracer.samples(points), before.shape())
        val walk = Walk(startedAt = SwiftDate.epoch(start), endedAt = SwiftDate.epoch(start + 320), points = points, newTiles = fresh.size)
        val entry = LoreEntry("jetty", "The jetty", "", "the-sea")
        val recap = WalkRecap.make(
            walk, listOf(after), mapOf(after.id to fresh), mapOf("jetty" to SwiftDate.epoch(start + 170)), emptyList(),
            now = start + 400, lookUp = { if (it == "jetty") entry else null },
        )
        assertEquals(fresh.size, recap.newTiles)
        assertEquals(recap.reveals.sortedBy { it.at }, recap.reveals)
        assertEquals(recap.reveals.sortedBy { it.hex.q }.map { it.hex }, recap.reveals.map { it.hex })
        assertEquals(listOf("jetty"), recap.secrets.map { it.entry.id })
        assertEquals(recap.reveals.first { it.hex == secretHex }.at, recap.secrets[0].at, 1e-9)
        assertEquals(0.0, recap.places[0].before, 1e-9)
        assertEquals(after.progress, recap.places[0].after, 1e-9)
        assertTrue(recap.before[0].visited.isEmpty())
        // Seconds into the walk, not since 1970.
        assertTrue(recap.routeTimes.first() > 0 && recap.routeTimes.last() <= 320)
        assertFalse(recap.isBest)
    }
}
