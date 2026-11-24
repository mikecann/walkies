package com.mikecann.walkies

import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.LegacyFinish
import com.mikecann.walkies.model.LegacyNextWalk
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.WalkEndReason
import com.mikecann.walkies.model.WalkStage
import com.mikecann.walkies.store.Store
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import kotlin.coroutines.CoroutineContext
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * Walks ending around a relaunch: rides, the app stopping before steps come back, and
 * files older versions left open (docs/walk-lifecycle.md). Older versions held a finish
 * until its steps came in and carried the next outing inside it; those files are only
 * read now, and closed at launch.
 */
class FinishRelaunchTest {
    private fun point(x: Double, time: Double) = TrackPoint(12.345 + x / 111195, 45.678, time, 5.0, speed = 1.0)

    /** A dead process cannot keep writing into the relaunched process's files. */
    private fun snapshot(store: Store, root: File): Pair<Store, File> {
        store.flush()
        val (_, copy) = tempStore()
        root.copyRecursively(copy, overwrite = true)
        return Store(copy) to copy
    }

    private fun place() = City(
        name = "Lifecycle", detail = "Tests",
        boundary = Boundary(listOf(GeoPolygon(listOf(Coordinate(12.32, 45.65), Coordinate(12.37, 45.65),
            Coordinate(12.37, 45.70), Coordinate(12.32, 45.70)), emptyList()))),
        tiles = (0..180).map { HexGrid.hex(containing = point(it * 10.0, 0.0).coordinate) }.toSet(),
        visited = emptySet(), roads = emptyList(),
    )

    @Test fun recoveredRetracesCannotReclaimAnEarlierWalksOrDroppedOutingsTiles() {
        for (steps in listOf(4, 8)) for (creditOnly in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                val city = place()
                val previousPoints = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }
                val visited = city.visit(CoverageTracer.samples(previousPoints), city.shape())
                val claimed = visited.second
                val previous = Walk(startedAt = SwiftDate.epoch(100000.0), endedAt = SwiftDate.epoch(100320.0),
                    automatic = true, points = previousPoints, distance = 400.0, newTiles = claimed.size,
                    newTileHexesByPlace = mapOf(city.id.toString().uppercase() to claimed),
                    newTilesByPlace = mapOf(city.id.toString().uppercase() to claimed.size))
                store.save(listOf(visited.first.copy(tileCredits = if (creditOnly)
                    listOf(City.TileCredit(previous.id, previous.startedAt, claimed)) else null)))
                if (!creditOnly) store.save(previous)
                val current = Walk(startedAt = SwiftDate.epoch(200000.0), automatic = true,
                    points = (0..steps).map { point(it * 50.0, 200000.0 + it * 40) }, distance = steps * 50.0)
                store.save(current)
                val model = AppModel(store, FakeSettings(alwaysOn = false), FakeLocation(), clock = { 201000.0 })
                if (steps == 4) assertTrue(model.walks.none { it.id == current.id }) else {
                    val saved = model.walks.single { it.id == current.id }
                    assertEquals(0, saved.newTiles)
                    assertTrue(saved.newTileHexesByPlace!!.values.all { it.isEmpty() })
                    assertEquals(0, model.questTileCounts.getValue(current.id).values.sum())
                }
                assertTrue(Store(root).loadCities().single().tileCredits.orEmpty().none { it.id == current.id })
            } finally { root.parentFile.deleteRecursively() }
        }
    }


    @Test fun expiredSeedRecoveryUnlocksAndPersistsCrossedStickersWithoutAPopup() {
        val (store, root) = tempStore()
        try {
            val entry = com.mikecann.walkies.lore.LoreLibrary.bundled.first { it.place != null }
            val origin = entry.place!!.coordinate
            fun fix(x: Double, time: Double) = TrackPoint(origin.lat + x / 111195, origin.lon, time, 5.0, speed = 1.0)
            val points = (0..8).map { fix(-200.0 + it * 50, 100000.0 + it * 40) }
            val city = City(name = entry.suburb ?: "Recovery", detail = "Tests",
                boundary = Boundary(listOf(GeoPolygon(listOf(Coordinate(origin.lat - 0.01, origin.lon - 0.01),
                    Coordinate(origin.lat + 0.01, origin.lon - 0.01), Coordinate(origin.lat + 0.01, origin.lon + 0.01),
                    Coordinate(origin.lat - 0.01, origin.lon + 0.01)), emptyList()))),
                tiles = (0..40).map { HexGrid.hex(containing = fix(-200.0 + it * 10, 0.0).coordinate) }.toSet(),
                visited = emptySet(), roads = emptyList(), stickers = mapOf(entry.id to HexGrid.hex(containing = origin)))
            store.save(listOf(city)); store.flush()
            store.save(Walk(startedAt = SwiftDate.epoch(points.first().time), automatic = true, points = points, distance = 400.0))
            val model = AppModel(store, FakeSettings(alwaysOn = false), FakeLocation(), clock = { 101000.0 })
            assertTrue(entry.id in model.foundStickers)
            assertTrue(entry.id in Store(root).loadStickers())
            assertTrue(model.stickerQueue.isEmpty())
        } finally { root.parentFile.deleteRecursively() }
    }


    @Test fun anOpenOutingFromAnOlderVersionRevealsItsTilesAndCreditsAShortOneAtLaunch() {
        for (steps in listOf(4, 8)) for (alwaysOn in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                store.save(listOf(place())); store.flush()
                // A next outing an older version had written to its own file before its tiles reached the places.
                val points = (0..steps).map { point(900.0 + it * 50, 100720.0 + it * 40) }
                val outing = Walk(startedAt = SwiftDate.epoch(100720.0), points = points, distance = CoverageTracer.distance(points),
                    automatic = true)
                store.save(outing)
                val model = AppModel(store, FakeSettings(alwaysOn = alwaysOn), FakeLocation(), clock = { if (alwaysOn) 102000.0 else 101060.0 })
                assertNull(model.activeWalk)
                val savedCity = Store(root).loadCities().single()
                assertTrue(savedCity.visited.isNotEmpty())
                if (steps == 4) {
                    assertTrue(model.walks.isEmpty())
                    assertTrue(Store(root).loadWalks().isEmpty())
                    assertTrue(savedCity.tileCredits!!.single { it.id == outing.id }.hexes.isNotEmpty())
                } else {
                    assertEquals(outing.id, model.walks.single().id)
                    assertTrue(model.walks.single().newTileHexesByPlace!!.values.any { it.isNotEmpty() })
                    assertEquals(WalkStage.Done, Store(root).loadWalks().single().stage)
                }
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun theFirstArrivalAfterAnotherRideStartsTheNextWalkAcrossARelaunch() {
        for (relaunch in listOf(false, true)) {
            val (store, root) = tempStore()
            var copy: File? = null
            try {
                var now = 100000.0
                var reply: ((Int?) -> Unit)? = null
                var model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                    stepQuery = { _, _, done -> reply = done })
                for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
                val first = model.activeWalk!!.id
                now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
                now = 100720.0; model.record(point(900.0, now))
                now = 100760.0; model.record(point(950.0, now))
                // The ride closed the first walk; a tentative one started where you turned up.
                assertEquals(listOf(first), model.walks.map { it.id })
                val second = model.activeWalk!!.id
                assertTrue(model.autoWalkPending)
                now = 100770.0; model.record(point(1000.0, now).copy(wheels = true))
                now = 100800.0; model.record(point(2000.0, now))
                assertEquals(second, model.activeWalk!!.id)
                assertEquals(true, model.activeWalk!!.rideSeen)
                if (relaunch) {
                    val (reopened, copiedRoot) = snapshot(store, root); copy = copiedRoot
                    reply?.invoke(400)
                    model = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                    assertEquals(second, model.activeWalk!!.id)
                } else reply?.invoke(400)
                now = 100840.0; model.record(point(2050.0, now))
                now = 100880.0; model.record(point(2100.0, now))
                // The tentative one never counted, so it's dropped; the next starts at the arrival.
                assertEquals("relaunch=$relaunch", listOf(first), model.walks.map { it.id })
                val next = model.activeWalk!!
                assertNotEquals(second, next.id)
                assertEquals(100800.0, next.startedAt.epochSeconds, 0.001)
                assertEquals(3, next.points.size)
                assertEquals(100.0, next.distance, 0.01)
            } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
        }
    }

    @Test fun aRideArrivalThatGoesStaleStartsTheNextWalkFromAFreshFix() {
        for (counting in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                var now = 100000.0
                val query: ((SwiftDate, SwiftDate, (Int?) -> Unit) -> Unit)? = if (counting) ({ _, _, _ -> }) else null
                val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now }, stepQuery = query)
                for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
                val first = model.activeWalk!!.id
                now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
                now = 100400.0; model.record(point(900.0, now))
                now = 100700.0; model.record(point(950.0, now))
                assertEquals(listOf(first), model.walks.map { it.id })
                now = 100950.0; model.record(point(1000.0, now))
                now = 100990.0; model.record(point(1050.0, now))
                assertEquals(100950.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
                assertEquals(2, model.activeWalk!!.points.size)
                assertEquals(50.0, model.activeWalk!!.distance, 0.01)
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test(timeout = 10000) fun aManualEndClosesAtItsTimeWhileHistoryIsHeld() = runBlocking {
        val (store, root) = tempStore()
        try {
            val queue = ArrayDeque<Runnable>()
            var held = true
            val dispatcher = object : CoroutineDispatcher() {
                override fun dispatch(context: CoroutineContext, block: Runnable) { if (held) queue.add(block) else block.run() }
            }
            var now = 100000.0
            val model = AppModel(store, FakeSettings(alwaysOn = false), FakeLocation(), clock = { now }, historyScope = CoroutineScope(dispatcher))
            assertFalse(model.historyReady)
            model.startWalk()
            model.record(point(0.0, now)); now += 40; model.record(point(50.0, now))
            val original = model.activeWalk!!
            now = 100060.0; model.endWalk()
            assertNull(model.activeWalk)
            now = 100080.0; model.record(point(100.0, now))
            now = 100120.0; model.record(point(150.0, now))
            assertEquals(original.points, model.walks.single().points)
            assertEquals(100060.0, model.walks.single().endedAt!!.epochSeconds, 0.001)
            held = false
            while (queue.isNotEmpty()) queue.removeFirst().run()
            model.waitForHistory()
            assertEquals(original.points, model.walks.single().points)
            assertEquals(100060.0, Store(root).loadWalks().single().endedAt!!.epochSeconds, 0.001)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aRideRecapExcludesTheNextWalksCityProgress() {
        val (store, root) = tempStore()
        try {
            store.save(listOf(place()))
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            val beforeSuccessor = model.cities.single().visited
            val original = model.activeWalk!!
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            for (i in 0..6) { now = 100720.0 + i * 40; model.record(point(900.0 + i * 50, now)) }
            reply?.invoke(400)
            assertEquals(original.id, model.recap!!.walk.id)
            assertEquals(beforeSuccessor, model.recap!!.after.single().visited)
            assertTrue(model.cities.single().visited.size > beforeSuccessor.size)
        } finally { root.parentFile.deleteRecursively() }
    }


    @Test fun aShortOutingAnOlderVersionCarriedKeepsTileCreditAndStaysOutOfTheNextWalk() {
        val (store, root) = tempStore()
        try {
            store.save(listOf(place())); store.flush()
            val short = LegacyNextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0),
                following = (0..2).map { point(1000.0 + it * 50, 100800.0 + it * 40) })
            val next = LegacyNextWalk(arrival = point(1800.0, 100900.0), point = point(1850.0, 100940.0))
            val request = LegacyFinish(SwiftDate.epoch(100320.0), WalkEndReason.Rode, false,
                successor = next, closedSuccessors = listOf(short))
            val original = Walk(startedAt = SwiftDate.epoch(100000.0), automatic = true, distance = 400.0,
                points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, pendingFinish = request)
            assertEquals(original, Codec.walk(Codec.walk(original)))
            store.save(original)
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { 100970.0 })
            assertEquals(next.id, model.activeWalk!!.id)
            assertTrue(model.autoWalkPending)
            assertTrue(model.freshTiles.isEmpty())
            assertTrue(model.walks.none { it.id == short.id })
            val credit = Store(root).loadCities().single().tileCredits!!.single { it.id == short.id }
            assertTrue(credit.hexes.isNotEmpty())
            assertTrue(Store(root).loadCities().single().visited.containsAll(credit.hexes))
        } finally { root.parentFile.deleteRecursively() }
    }


    @Test fun anExplicitShortEndSurvivesProcessDeathBeforeTheStepReply() {
        for (delay in listOf(40.0, 700.0)) {
            val (store, root) = tempStore()
            var copy: File? = null
            try {
                store.save(listOf(place())); store.flush()
                var now = 100000.0
                var reply: ((Int?) -> Unit)? = null
                val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                    stepQuery = { _, _, done -> reply = done })
                for (i in 0..2) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
                val original = model.activeWalk!!
                now += 20
                val requestedEnd = now
                model.endAutoWalk()
                assertNotNull(reply)
                // Closed and in the saved places before the steps come back.
                assertEquals(requestedEnd, store.loadWalks().single().endedAt!!.epochSeconds, 0.001)
                val (reopened, copiedRoot) = snapshot(store, root)
                copy = copiedRoot
                reply!!(50)
                now += delay
                val next = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                assertNull("A closed walk is never resumed (delay=$delay)", next.activeWalk)
                val saved = reopened.loadWalks().single()
                assertEquals(original.id, saved.id)
                assertEquals(original.points, saved.points)
                assertEquals(requestedEnd, saved.endedAt!!.epochSeconds, 0.001)
                assertEquals(WalkEndReason.You, saved.endReason)
                assertEquals(WalkStage.Done, saved.stage)
                assertEquals(true, saved.stepsPending)
                assertTrue(saved.newTiles > 0)
                assertTrue(saved.newTileHexesByPlace!!.values.any { it.isNotEmpty() })
                assertTrue(reopened.loadCities().single().visited.isNotEmpty())
                assertEquals(saved.newTiles, next.questTileCounts.getValue(saved.id).values.sum())
            } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
        }
    }

    @Test fun walkingOnWhileTheStepsComeInIsCreditedToTheNextWalk() {
        val (store, root) = tempStore()
        try {
            store.save(listOf(place()))
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            val original = model.activeWalk!!
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            for (i in 0..6) { now = 100720.0 + i * 40; model.record(point(900.0 + i * 50, now)) }
            assertEquals(original.points, model.walks.single().points)
            assertNotEquals(original.id, model.activeWalk!!.id)
            reply!!(400)
            assertEquals(400, model.walks.single().steps)
            assertEquals(7, model.activeWalk!!.points.size)
            assertEquals(100720.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
            assertFalse(model.autoWalkPending)
            model.saveNow()
            assertTrue(model.activeWalk!!.newTiles > 0)
            assertEquals(model.activeWalk!!.newTiles, model.activeWalk!!.newTileHexesByPlace!!.values.sumOf { it.size })
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aRideClosesTheWalkAndTheNextOneOwnsTheArrivalAcrossBothStepCrashPoints() {
        for (afterSteps in listOf(false, true)) {
            val (store, root) = tempStore()
            var copy: File? = null
            try {
                var now = 100000.0
                var reply: ((Int?) -> Unit)? = null
                var model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                    stepQuery = { _, _, done -> reply = done })
                for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
                val original = model.activeWalk!!
                now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
                now = 100720.0; model.record(point(900.0, now))
                now = 100760.0; model.record(point(950.0, now))
                assertNotNull(reply)
                val successorId = model.activeWalk!!.id
                assertNotEquals(original.id, successorId)
                if (afterSteps) reply!!(400)
                val (reopened, copiedRoot) = snapshot(store, root)
                copy = copiedRoot
                if (!afterSteps) reply!!(400)
                model = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                now = 100800.0; model.record(point(1000.0, now))
                now = 100840.0; model.record(point(1050.0, now))
                val ended = model.walks.single()
                assertEquals(original.id, ended.id)
                assertEquals(original.points, ended.points)
                assertEquals(original.points.last().time, ended.endedAt!!.epochSeconds, 0.001)
                assertEquals(if (afterSteps) 400 else null, ended.steps)
                val successor = model.activeWalk!!
                assertEquals(successorId, successor.id)
                assertEquals(100720.0, successor.startedAt.epochSeconds, 0.001)
                assertEquals(listOf(900.0, 950.0, 1000.0, 1050.0), successor.points.map { (it.lat - 12.345) * 111195 }.map { kotlin.math.round(it) })
                assertEquals(150.0, successor.distance, 0.01)
            } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
        }
    }

    @Test fun anOutingAnOlderVersionCarriedThatAlreadyHasItsOwnFileKeepsItsLaterPoints() {
        val (store, root) = tempStore()
        try {
            val original = Walk(startedAt = SwiftDate.epoch(100000.0), points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, automatic = true)
            val seed = LegacyNextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0))
            store.save(original.copy(pendingFinish = LegacyFinish(
                SwiftDate.epoch(100320.0), WalkEndReason.Rode, false, seed)))
            val progressed = seed.walk().copy(points = seed.walk().points + point(1000.0, 100800.0), resumeAnchor = point(1000.0, 100800.0))
            store.save(progressed)
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { 100820.0 })
            assertEquals(seed.id, model.activeWalk!!.id)
            assertEquals(progressed.points, model.activeWalk!!.points)
            assertEquals(progressed.points, store.loadWalks().single { it.id == seed.id }.points)
            assertEquals(original.id, model.walks.single().id)
        } finally { root.parentFile.deleteRecursively() }
    }
}
