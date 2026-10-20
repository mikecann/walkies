package com.mikecann.walkies

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.Progression
import com.mikecann.walkies.model.Progression.QuestKind
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.store.Store
import com.mikecann.walkies.sync.FakeServer
import com.mikecann.walkies.sync.SyncEngine
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * ProgressionIntegrationTests.swift: progression through the model, with real saving
 * and the fake server for sync. No location, account or network.
 */
class ProgressionModelTest {
    private var now = SwiftDate.now().epochSeconds
    private val clock = { now }

    private fun hex(q: Int, r: Int, origin: Coordinate = Coordinate(12.345, 45.678)): Hex {
        val base = HexGrid.hex(containing = origin)
        return Hex(base.q + q, base.r + r)
    }

    private fun offset(city: City): Vec2 = HexGrid.centre(HexGrid.hex(containing = city.boundary.centre))

    private fun city(visited: Int = 10, origin: Coordinate = Coordinate(12.345, 45.678)): City {
        val centre = HexGrid.centre(HexGrid.hex(containing = origin))
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(centre + it) }
        return City(
            name = "Test place", detail = "Tests",
            boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = (0 until 100).mapTo(LinkedHashSet()) { hex(it, 0, origin) },
            visited = (0 until visited).mapTo(LinkedHashSet()) { hex(it, 0, origin) },
            roads = emptyList(),
        )
    }

    private fun legacyWalk(n: Int, city: City): Walk {
        val date = SwiftDate.epoch(now - (n + 1) * 86400.0)
        val points = listOf(0.0, 15.0, 30.0).mapIndexed { i, x ->
            val c = city.grid.projection.unproject(offset(city) + Vec2(x, 0.0))
            TrackPoint(c.lat, c.lon, date.epochSeconds + i * 20, 5.0, speed = 1.0)
        }
        return Walk(startedAt = date, endedAt = date.plus(600.0), points = points, distance = 300.0, newTiles = 1)
    }

    private fun visit(model: AppModel, x: Double, seconds: Double) {
        val city = model.cities[0]
        val c = city.grid.projection.unproject(offset(city) + Vec2(x, 0.0))
        now = start + seconds
        model.record(TrackPoint(c.lat, c.lon, now, 5.0, speed = 1.0))
    }

    /** Fixes are timed from here, like the Swift tests' Date.now + seconds. */
    private val start = now

    private fun model(store: Store, alwaysOn: Boolean = false) = AppModel(store, FakeSettings(alwaysOn = alwaysOn), FakeLocation(), clock = clock)

    @Test
    fun legacyWalksAreRecoveredOnceAtLaunchAndNotAgainAtWalkEndOrRelaunch() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        repeat(20) { store.save(legacyWalk(it, place)) }
        val model = model(store)
        assertTrue(model.historyReady)
        store.flush()
        assertTrue(store.loadWalks().all { it.newTilesByPlace != null && it.newTileHexesByPlace != null })
        model.startWalk()
        visit(model, -200.0, 0.0)
        visit(model, -100.0, 40.0)
        model.balance
        model.endWalk()
        assertNotNull(model.recap)
        assertFalse(model.recap!!.isRewatch)
        store.flush()
        // Saved with their tiles, so nothing needs replaying again.
        val replays = ArrayList<UUID>()
        Progression.backfill(store.loadWalks(), store.loadCities()) { replays.add(it) }
        assertTrue(replays.isEmpty())
    }

    @Test
    fun rewatchingAWalkFromHistoryAwardsAndChangesNothing() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        repeat(3) { store.save(legacyWalk(it, place)) }
        val model = model(store)
        val ledger = model.ledger
        val xp = model.xp
        val balance = model.balance
        val picks = model.pendingPicks
        val earned = model.earnedBreakdown.total
        val stickers = model.stickerQueue.size
        val walks = model.walks.map { it.id }
        val visited = model.cities.map { it.visited }
        model.replay(model.walks.first())
        val recap = model.recap!!
        assertTrue(recap.isRewatch)
        assertEquals(0, recap.shells)
        assertEquals(0, recap.xp)
        assertTrue(recap.questProgress.isEmpty())
        assertEquals(ledger, model.ledger)
        assertEquals(xp, model.xp)
        assertEquals(balance, model.balance)
        assertEquals(picks, model.pendingPicks)
        assertEquals(earned, model.earnedBreakdown.total)
        assertEquals(stickers, model.stickerQueue.size)
        assertEquals(walks, model.walks.map { it.id })
        assertEquals(visited, model.cities.map { it.visited })
    }

    @Test
    fun uncoveringNonCountingTilesReusesHistoricalQuestRewards() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        repeat(52) { store.save(legacyWalk(it * 7, place)) }
        val model = model(store)
        val before = model.earnedBreakdown
        val builds = model.progressionHistoryBuilds
        model.startWalk()
        assertNotNull(model.activeWalk)
        assertFalse(model.autoWalkPending)
        visit(model, -300.0, 0.0)
        visit(model, -200.0, 40.0)
        val after = model.earnedBreakdown
        assertTrue(after.tiles > before.tiles)
        assertTrue(model.cities[0].tiles.size > place.tiles.size)
        assertEquals(builds, model.progressionHistoryBuilds)
        visit(model, -100.0, 80.0)
        model.balance
        assertEquals(builds, model.progressionHistoryBuilds)
        model.endWalk()
        model.balance
        assertEquals(builds + 1, model.progressionHistoryBuilds)
    }

    @Test
    fun resumedWalkKeepsFreshHexesAndCountingGridDenominator() {
        val (store, _) = tempStore()
        val fresh = setOf(hex(-1, 0))
        val place = city().let { it.copy(tiles = it.tiles + fresh, visited = it.visited + fresh) }
        store.save(listOf(place))
        val begin = now - 300
        val points = listOf(-200.0, 0.0).mapIndexed { i, x ->
            val c = place.grid.projection.unproject(offset(place) + Vec2(x, 0.0))
            TrackPoint(c.lat, c.lon, begin + i * 80, 5.0, speed = 1.0)
        }
        val walk = Walk(
            startedAt = SwiftDate.epoch(begin), points = points, distance = 200.0, newTiles = 1,
            newTilesByPlace = mapOf(place.id.uuidString to 1), newTileHexesByPlace = mapOf(place.id.uuidString to fresh),
            addedTilesByPlace = mapOf(place.id.uuidString to fresh), automatic = true,
        )
        store.save(walk)
        store.flush()
        val model = model(store, alwaysOn = true)
        assertEquals(walk.id, model.activeWalk?.id)
        model.endAutoWalk()
        assertEquals(0, model.recap?.earnings?.breakdown?.milestones)
        assertEquals(1, model.recap?.shells)
        assertEquals(0.1, model.recap!!.places.first().before, 1e-12)
        assertEquals(1, model.walks.first().newTilesByPlace?.get(place.id.uuidString))
        assertEquals(fresh, model.walks.first().addedTilesByPlace?.get(place.id.uuidString))
    }

    @Test
    fun confirmedShortAutomaticOutingPersistsOnlyTileCredit() {
        val (store, _) = tempStore()
        store.save(listOf(city(visited = 0)))
        val model = model(store, alwaysOn = true)
        // Each segment is within accuracy, speed and gap limits. Displacement from the
        // first stored fix reaches 150 m, but traced distance stays below 300 m.
        for ((i, x) in listOf(-400.0, -350.0, -300.0, -250.0, -200.0, -150.0).withIndex()) visit(model, x, i * 40.0)
        assertNotNull(model.activeWalk)
        assertFalse(model.autoWalkPending)
        val fresh = model.freshTiles[model.cities[0].id].orEmpty()
        assertTrue(fresh.isNotEmpty())
        // The next fix closes the old outing through the normal inactivity path.
        visit(model, -100.0, 1000.0)
        assertEquals(null, model.activeWalk)
        assertTrue(model.walks.isEmpty())
        assertEquals(null, model.recap)
        store.flush()
        assertTrue(store.loadWalks().isEmpty())
        assertEquals(fresh, model.cities[0].tileCredits?.first()?.hexes)
        val reopened = model(store)
        val credit = reopened.cities[0].tileCredits!!.first()
        val week = Progression.week(credit.at, Progression.zone)
        val input = Progression.Inputs(cities = reopened.cities, walks = reopened.walks, now = credit.at.plus(1000.0))
        assertEquals(fresh.size.toDouble(), Progression.questProgress(QuestKind.Tiles25, week, input), 0.0)
        assertEquals(0.0, Progression.questProgress(QuestKind.Days3, week, input), 0.0)
        assertEquals(0.0, Progression.questProgress(QuestKind.Metres5000, week, input), 0.0)
    }

    @Test
    fun midWalkLevelOfferFreezesBeforePurchaseAndOwnedChoiceBecomesBag() {
        val (store, _) = tempStore()
        val place = city(visited = 149).copy(tiles = (0 until 10000).mapTo(HashSet()) { hex(it, 0) })
        store.save(listOf(place))
        val model = model(store)
        assertEquals(149, model.xp)
        // A prior shell bag funds the purchase without itself changing XP.
        assertTrue(model.claim(2, Progression.SHELL_BAG))
        model.startWalk()
        visit(model, -300.0, 0.0)
        visit(model, -200.0, 40.0)
        assertEquals(3, model.level)
        val offer = model.ledger.offers!!.first { it.level == 3 }
        val cosmetic = offer.choices.first { Progression.item(it)?.group != null }
        assertTrue(model.buy(cosmetic))
        assertNotNull(model.activeWalk)
        assertEquals(offer.choices, model.picks(3))
        assertTrue(model.claim(3, cosmetic))
        assertEquals(Progression.SHELL_BAG, model.ledger.claims.first { it.level == 3 }.choice)
    }

    @Test
    fun buyingEquipsAndEquippingNeedsOwnership() {
        val (store, _) = tempStore()
        store.save(listOf(city(visited = 100)))
        val model = model(store)
        assertTrue(model.balance >= 150)
        assertFalse(model.equip("marker.sneaker"))
        assertFalse(model.buy("marker.dot"))
        assertTrue(model.buy("marker.sneaker"))
        assertEquals("marker.sneaker", model.equipped.marker)
        assertFalse(model.buy("marker.sneaker"))
        assertTrue(model.equip("marker.dot"))
        assertEquals("marker.dot", model.equipped.marker)
        store.flush()
        assertEquals(model.ledger, store.loadProgress())
        assertFalse(model.buy("cover.gold") && model.balance < 0)
    }

    @Test
    fun remoteTileCreditsMergeAndDeduplicateWithoutReplayingRoutes() = runBlocking {
        val (store, _) = tempStore()
        val id = UUID.randomUUID()
        val at = SwiftDate.epoch(now - 60)
        val place = city(visited = 10).copy(tileCredits = listOf(City.TileCredit(id, at, setOf(hex(0, 0)))))
        store.save(listOf(place))
        val model = model(store)
        val remote = place.copy(tileCredits = listOf(City.TileCredit(UUID.randomUUID(), at, setOf(hex(0, 0), hex(1, 0)))))
        model.addRemote(listOf(remote), emptyList(), null, emptyMap())
        assertEquals(2, model.cities[0].tileCredits?.size)
        val input = Progression.Inputs(cities = model.cities)
        assertEquals(2.0, Progression.questProgress(QuestKind.Tiles25, Progression.week(at, Progression.zone), input), 0.0)
        store.flush()
        assertTrue(id in store.loadCities().first().tileCredits.orEmpty().map { it.id })
    }

    @Test
    fun pullMergesOwnershipBeforeFreezingMenusAndRefreshesOnce() = runBlocking {
        val (store, _) = tempStore()
        val model = model(store)
        val place = city(visited = 100)
        val server = FakeServer()
        server.seed(place)
        repeat(20) { server.seed(legacyWalk(it, place)) }
        server.ledger = Ledger(
            purchases = listOf(Ledger.Purchase(item = "marker.sneaker", cost = 150, at = 0.0), Ledger.Purchase(item = "trail.footprints", cost = 150, at = 0.0)),
            claims = listOf(Ledger.Claim(2, Progression.SHELL_BAG)),
        )
        val builds = model.progressionHistoryBuilds
        val engine = SyncEngine(model, store, { true }, { null }, makeClient = { ConvexClient(server.backend, "token", server) }, scope = this)
        engine.sync()
        assertEquals(SyncEngine.Status.Idle, engine.status)
        assertEquals(20, model.walks.size)
        assertFalse(2 in model.pendingPicks)
        assertEquals(builds + 1, model.progressionHistoryBuilds)
        for (level in model.pendingPicks) {
            assertFalse("marker.sneaker" in model.picks(level))
            assertFalse("trail.footprints" in model.picks(level))
        }
        store.flush()
        assertTrue(store.loadWalks().all { it.newTilesByPlace != null })
    }

    @Test
    fun overlappingPlaceFindsSecretsWithoutShellsAndSentinelSurvivesSync() = runBlocking {
        val (store, _) = tempStore()
        val entry = LoreLibrary.all.first { it.place != null }
        val origin = Coordinate(entry.place!!.lat, entry.place!!.lon)
        val model = model(store)
        model.add(city(visited = 1, origin = origin))
        assertEquals(Progression.exploredSecretDate, model.foundStickers[entry.id])
        assertEquals(0, model.earnedBreakdown.secrets)
        val week = Progression.week(SwiftDate.epoch(now), Progression.zone)
        assertEquals(0.0, Progression.questProgress(QuestKind.Secret, week, Progression.Inputs(foundSecrets = model.foundStickers, now = SwiftDate.epoch(now))), 0.0)
        val server = FakeServer()
        val engine = SyncEngine(model, store, { true }, { null }, makeClient = { ConvexClient(server.backend, "token", server) }, scope = this)
        engine.sync()
        assertEquals(SyncEngine.Status.Idle, engine.status)
        assertEquals(Progression.exploredSecretDate, model.foundStickers[entry.id])
        assertEquals(0, model.earnedBreakdown.secrets)
        // A real discovery from another phone still wins the earliest-date merge.
        model.addRemoteSecrets(mapOf(entry.id to SwiftDate.epoch(now)))
        assertEquals(10, model.earnedBreakdown.secrets)
    }

    @Test
    fun aSpyglassRingAppearsOverTheSelectedPlaceAndUsesOneUp() {
        val (store, _) = tempStore()
        val entry = LoreLibrary.all.first { it.place != null }
        val origin = Coordinate(entry.place!!.lat, entry.place!!.lon)
        store.save(listOf(city(visited = 0, origin = origin).copy(roads = emptyList())))
        val model = model(store)
        val hidden = model.selectedCity?.stickers.orEmpty().keys.filter { model.foundStickers[it] == null }
        assertTrue(hidden.isNotEmpty())
        assertFalse(model.useSpyglass())
        model.addRemoteProgress(Ledger(claims = listOf(Ledger.Claim(2, Progression.SPYGLASS_PAIR))))
        assertEquals(2, model.spyglasses)
        assertTrue(model.useSpyglass())
        assertEquals(1, model.spyglasses)
        val ring = model.activeSpyglassRing!!
        assertTrue(ring.secretId in hidden)
        // One ring at a time.
        assertFalse(model.useSpyglass())
        now += 3 * 3600.0
        assertEquals(null, model.activeSpyglassRing)
    }
}
