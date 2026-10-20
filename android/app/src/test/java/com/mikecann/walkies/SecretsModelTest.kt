package com.mikecann.walkies

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Secrets and recaps through the model: ModelFixesTests.swift's secrets under old
 * tiles, and ProgressionIntegrationTests.swift's walk-end recap and rewatch.
 */
class SecretsModelTest {
    private var now = 1_790_000_000.0
    private val clock = { now }

    private fun city(visited: Int = 0, origin: Coordinate = Coordinate(12.345, 45.678)): City {
        val base = HexGrid.hex(containing = origin)
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(HexGrid.centre(base) + it) }
        return City(
            name = "Test place", detail = "Tests",
            boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = (0 until 100).mapTo(LinkedHashSet()) { Hex(base.q + it, base.r) },
            visited = (0 until visited).mapTo(LinkedHashSet()) { Hex(base.q + it, base.r) },
            roads = emptyList(),
        )
    }

    private val spotted: LoreEntry get() = LoreLibrary.all.first { it.place != null }

    @Test
    fun secretsUnderTilesYouveWalkedAreSummedUpNotPoppedUp() {
        val (store, _) = tempStore()
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        val notified = ArrayList<LoreEntry>()
        model.secretsFound = { notified += it }
        model.add(city(visited = 1, origin = spotted.place!!.coordinate))
        assertEquals(SwiftDate.distantFuture, model.foundStickers[spotted.id])
        assertTrue(model.stickerQueue.isEmpty())
        assertTrue(model.secretsAlreadyWalked >= 1)
        assertTrue(notified.isEmpty())
        model.dismissSecretsAlreadyWalked()
        assertEquals(0, model.secretsAlreadyWalked)
    }

    @Test
    fun stickersArePlacedOnceAndKeptAcrossLaunches() {
        val (store, _) = tempStore()
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        model.add(city(origin = spotted.place!!.coordinate))
        val placed = model.cities[0].stickers
        assertNotNull(placed?.get(spotted.id))
        val reopened = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        assertEquals(placed, reopened.cities[0].stickers)
    }

    @Test
    fun walkingOverASecretPopsItUpAndEndsWithARecap() {
        val (store, _) = tempStore()
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        val notified = ArrayList<LoreEntry>()
        model.secretsFound = { notified += it }
        model.add(city(origin = spotted.place!!.coordinate))
        val hex = model.cities[0].stickers!!.getValue(spotted.id)
        val target = HexGrid.centre(hex)
        model.startWalk()
        for (i in 0..6) {
            now += 40
            val c = HexGrid.projection.unproject(target + Vec2(-300.0 + i * 50, 0.0))
            model.record(TrackPoint(c.lat, c.lon, now, 5.0, speed = 1.25))
        }
        val found = model.foundStickers[spotted.id]
        assertNotNull(found)
        assertTrue(found!! < SwiftDate.distantFuture)
        assertTrue(model.stickerQueue.any { it.id == spotted.id })
        assertTrue(notified.any { it.id == spotted.id })

        model.endWalk()
        val recap = model.recap!!
        assertFalse(recap.isRewatch)
        assertTrue(recap.secrets.any { it.entry.id == spotted.id })
        assertTrue(recap.newTiles > 0)
        model.dismissRecap()
        assertNull(model.recap)

        // Seen the pop-ups.
        while (model.stickerQueue.isNotEmpty()) model.popSticker()
        assertTrue(model.stickerQueue.isEmpty())
    }

    @Test
    fun rewatchingAWalkFromHistoryChangesNothing() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        for (n in 0 until 3) {
            val start = now - (3 - n) * 24 * 3600.0
            val points = (0..6).map { i ->
                val c = HexGrid.projection.unproject(HexGrid.centre(HexGrid.hex(containing = place.boundary.centre)) + Vec2(n * 200.0 + i * 40, 0.0))
                TrackPoint(c.lat, c.lon, start + i * 30, 5.0, speed = 1.3)
            }
            store.save(Walk(startedAt = SwiftDate.epoch(start), endedAt = SwiftDate.epoch(start + 600), points = points, distance = 240.0, newTiles = 5))
        }
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        val walks = model.walks.map { it.id }
        val visited = model.cities.map { it.visited }
        val found = model.foundStickers
        val queue = model.stickerQueue
        val second = model.walks.sortedBy { it.startedAt }[1]
        model.replay(second)
        val recap = model.recap!!
        assertTrue(recap.isRewatch)
        assertEquals(second.id, recap.walk.id)
        assertEquals(walks, model.walks.map { it.id })
        assertEquals(visited, model.cities.map { it.visited })
        assertEquals(found, model.foundStickers)
        assertEquals(queue, model.stickerQueue)
    }

    @Test
    fun signingOutForgetsTheSecretsAndTheRecap() {
        val (store, _) = tempStore()
        val model = AppModel(store, FakeSettings(), FakeLocation(), clock = clock)
        model.add(city(visited = 1, origin = spotted.place!!.coordinate))
        model.wipeLocalData()
        assertTrue(model.foundStickers.isEmpty())
        assertEquals(0, model.secretsAlreadyWalked)
        assertNull(model.recap)
    }
}
