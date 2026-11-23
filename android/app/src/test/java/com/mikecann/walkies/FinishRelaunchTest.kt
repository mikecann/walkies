package com.mikecann.walkies

import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.WalkEndReason
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.WalkContinuation
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.store.Store
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.coroutines.CompletableDeferred
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.sync.FakeServer
import com.mikecann.walkies.sync.SyncEngine
import com.mikecann.walkies.convex.ConvexClient
import kotlin.coroutines.CoroutineContext
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class FinishRelaunchTest {
    private fun point(x: Double, time: Double) = TrackPoint(12.345 + x / 111195, 45.678, time, 5.0, speed = 1.0)

    /** A dead process cannot keep writing into the relaunched process's files. */
    private fun snapshot(root: File): Pair<Store, File> {
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
                val claimed = com.mikecann.walkies.model.CoverageTracer.samples(previousPoints)
                    .map { city.grid.hex(containing = it) }.toSet().intersect(city.tiles)
                val previous = Walk(startedAt = SwiftDate.epoch(100000.0), endedAt = SwiftDate.epoch(100320.0),
                    automatic = true, points = previousPoints, distance = 400.0, newTiles = claimed.size,
                    newTileHexesByPlace = mapOf(city.id.toString().uppercase() to claimed),
                    newTilesByPlace = mapOf(city.id.toString().uppercase() to claimed.size))
                store.save(listOf(city.copy(visited = claimed, tileCredits = if (creditOnly)
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

    @Test fun aClosedGapLegContinuesItsOpenLeafWhileItsOwnStepsAreHeld() {
        val (store, root) = tempStore()
        try {
            var now = 100000.0
            val replies = ArrayList<(Int?) -> Unit>()
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> replies += done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            for (i in 0..8) { now = 100720.0 + i * 40; model.record(point(900.0 + i * 50, now)) }
            val childId = model.activeWalk!!.pendingFinish!!.successor!!.id
            now = 101640.0; model.record(point(1350.0, now))
            now = 101680.0; model.record(point(1390.0, now))
            val nextId = model.activeWalk!!.pendingFinish!!.successor!!.id
            replies[0](400)
            assertEquals(2, replies.size)
            assertEquals(WalkEndReason.Gap, model.activeWalk!!.pendingFinish!!.reason)
            now = 101720.0; model.record(point(1430.0, now))
            assertEquals(3, model.activeWalk!!.pendingFinish!!.successor!!.walk().points.size)
            replies[1](400)
            assertEquals(WalkEndReason.Gap, model.walks.single { it.id == childId }.endReason)
            assertEquals(nextId, model.activeWalk!!.id)
            assertEquals(101640.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
            assertEquals(3, model.activeWalk!!.points.size)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aTenMinuteGapInsideAHeldHandoffStartsAnotherIdentityAtTheNewFix() {
        val (store, root) = tempStore()
        try {
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            for (i in 0..8) { now = 100720.0 + i * 40; model.record(point(900.0 + i * 50, now)) }
            val childId = model.activeWalk!!.pendingFinish!!.successor!!.id
            now = 101640.0; model.record(point(1350.0, now))
            now = 101680.0; model.record(point(1390.0, now))
            val nextId = model.activeWalk!!.pendingFinish!!.successor!!.id
            assertNotEquals(childId, nextId)
            model.querySteps = null
            reply!!(400)
            val closed = model.walks.single { it.id == childId }
            assertEquals(101040.0, closed.endedAt!!.epochSeconds, 0.001)
            assertEquals(WalkEndReason.Gap, closed.endReason)
            assertEquals(9, closed.points.size)
            assertEquals(nextId, model.activeWalk!!.id)
            assertEquals(101640.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
            assertEquals(2, model.activeWalk!!.points.size)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun drainingAClosedLegKeepsTheOpenLegsCursorWhileItsStepQueryIsHeld() {
        val (store, root) = tempStore()
        var copy: File? = null
        try {
            var now = 100000.0
            val replies = ArrayList<(Int?) -> Unit>()
            var model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> replies += done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            for (i in 0..8) { now = 100720.0 + i * 40; model.record(point(900.0 + i * 50, now)) }
            now = 101060.0; model.record(point(1350.0, now).copy(wheels = true))
            now = 101080.0; model.record(point(1800.0, now))
            now = 101120.0; model.record(point(1850.0, now))
            val openId = model.activeWalk!!.pendingFinish!!.successor!!.id
            replies[0](400)
            assertEquals(2, replies.size)
            now = 101160.0; model.record(point(1900.0, now))
            assertEquals(3, model.activeWalk!!.pendingFinish!!.successor!!.walk().points.size)
            replies[1](400)
            assertEquals(openId, model.activeWalk!!.id)
            assertEquals(3, model.activeWalk!!.points.size)
            val (reopened, copiedRoot) = snapshot(root); copy = copiedRoot
            model = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            assertEquals(openId, model.activeWalk!!.id)
            assertEquals(3, model.activeWalk!!.points.size)
            assertEquals(100.0, model.activeWalk!!.distance, 0.01)
        } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
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

    @Test fun aWildSpeedFixDuringABlockedConfirmedSuccessorKeepsItsIdentity() {
        val (store, root) = tempStore()
        try {
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            val original = model.activeWalk!!
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            now = 100720.0; model.record(point(900.0, now))
            now = 100760.0; model.record(point(950.0, now))
            val childId = model.activeWalk!!.pendingFinish!!.successor!!.id
            val blocked = File(root, "walks/.${childId.toString().uppercase()}.json.tmp")
            assertTrue(blocked.mkdir())
            reply!!(400); model.querySteps = null
            for (i in 0..6) { now = 100800.0 + i * 40; model.record(point(1000.0 + i * 50, now)) }
            now = 101045.0; model.record(point(1600.0, now).copy(speed = 9.0))
            now = 101085.0; model.record(point(1350.0, now))
            now = 101125.0; model.record(point(1400.0, now))
            val pending = model.activeWalk!!.pendingFinish!!
            assertEquals(childId, pending.successor!!.id)
            assertTrue(pending.closedSuccessors.isNullOrEmpty())
            assertEquals(11, pending.successor!!.walk().points.size)
            assertTrue(blocked.delete())
            model.finishStaleAutoWalk()
            assertEquals(childId, model.activeWalk!!.id)
            assertEquals(11, model.activeWalk!!.points.size)
            assertEquals(original.id, model.walks.single().id)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun confirmedSuccessorRideCursorSurvivesHandoffAndRelaunchBeforeConfirmation() {
        val (store, root) = tempStore()
        var copy: File? = null
        try {
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            var model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            for (i in 0..8) { now = 100720.0 + i * 40; model.record(point(900.0 + i * 50, now)) }
            val childId = model.activeWalk!!.pendingFinish!!.successor!!.id
            now = 101060.0; model.record(point(1350.0, now).copy(wheels = true))
            now = 101080.0; model.record(point(1800.0, now))
            val pending = model.activeWalk!!.pendingFinish!!.successor!!
            assertEquals(WalkContinuation.Rode, pending.continuation)
            assertEquals(point(1800.0, now), pending.resumeAnchor)
            reply!!(400)
            val (reopened, copiedRoot) = snapshot(root); copy = copiedRoot
            model = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            now = 101120.0; model.record(point(1850.0, now))
            val ended = model.walks.single { it.id == childId }
            assertEquals(101040.0, ended.endedAt!!.epochSeconds, 0.001)
            assertEquals(9, ended.points.size)
            assertEquals(101080.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
            assertEquals(2, model.activeWalk!!.points.size)
        } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
    }

    @Test fun disabledOrExpiredBlockedHandoffsFinishTheirChildInsteadOfResumingIt() {
        for (alwaysOn in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                val seed = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0),
                    following = (0..6).map { point(1000.0 + it * 50, 100800.0 + it * 40) })
                val original = Walk(startedAt = SwiftDate.epoch(100000.0), automatic = true, distance = 400.0,
                    points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, pendingFinish =
                        com.mikecann.walkies.model.PendingWalkFinish(SwiftDate.epoch(100320.0), WalkEndReason.Rode, false, seed))
                store.save(original)
                val blocked = File(root, "walks/.${seed.id.toString().uppercase()}.json.tmp")
                assertTrue(blocked.mkdir())
                val now = if (alwaysOn) 102000.0 else 101060.0
                val model = AppModel(store, FakeSettings(alwaysOn = alwaysOn), FakeLocation(), clock = { now })
                assertEquals(original.id, model.activeWalk!!.id)
                assertTrue(blocked.delete())
                if (alwaysOn) model.finishStaleAutoWalk() else model.record(point(1400.0, now))
                assertNull(model.activeWalk)
                assertEquals(setOf(original.id, seed.id), model.walks.map { it.id }.toSet())
                val child = model.walks.single { it.id == seed.id }
                assertEquals(101040.0, child.endedAt!!.epochSeconds, 0.001)
                assertEquals(seed.walk().points, child.points)
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun expiredOrDisabledConfirmedSeedsStillRevealTilesAndCreditShortOutings() {
        for (steps in listOf(4, 8)) for (alwaysOn in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                val place = place()
                store.save(listOf(place)); store.flush()
                val seed = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0),
                    following = (2..steps).map { point(900.0 + it * 50, 100720.0 + it * 40) })
                store.save(seed.walk())
                val model = AppModel(store, FakeSettings(alwaysOn = alwaysOn), FakeLocation(), clock = { if (alwaysOn) 102000.0 else 101060.0 })
                val savedCity = Store(root).loadCities().single()
                assertTrue(savedCity.visited.isNotEmpty())
                if (steps == 4) {
                    assertTrue(model.walks.isEmpty())
                    assertTrue(savedCity.tileCredits!!.single { it.id == seed.id }.hexes.isNotEmpty())
                } else {
                    assertEquals(seed.id, model.walks.single().id)
                    assertTrue(model.walks.single().newTileHexesByPlace!!.values.any { it.isNotEmpty() })
                }
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun legacyResumedVisitedRouteRecoversItsOriginalWalkCredit() {
        val (store, root) = tempStore()
        try {
            val points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }
            val original = Walk(startedAt = SwiftDate.epoch(points.first().time), points = points, automatic = true, distance = 400.0)
            val city = place()
            val visited = com.mikecann.walkies.model.CoverageTracer.samples(points).map { city.grid.hex(containing = it) }.toSet()
            store.save(listOf(city.copy(visited = visited))); store.save(original)
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { 100340.0 })
            assertTrue(model.activeWalk!!.newTileHexesByPlace!!.values.any { it.isNotEmpty() })
            assertTrue(model.questTileCounts.getValue(original.id).values.sum() > 0)
            model.endAutoWalk()
            assertTrue(store.loadWalks().single().newTileHexesByPlace!!.values.any { it.isNotEmpty() })
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun firstArrivalAfterAnotherRideSurvivesCompletionOrProcessDeath() {
        for (relaunch in listOf(false, true)) {
            val (store, root) = tempStore()
            var copy: File? = null
            try {
                var now = 100000.0
                var reply: ((Int?) -> Unit)? = null
                var model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                    stepQuery = { _, _, done -> reply = done })
                for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
                now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
                now = 100720.0; model.record(point(900.0, now))
                now = 100760.0; model.record(point(950.0, now))
                now = 100770.0; model.record(point(1000.0, now).copy(wheels = true))
                now = 100800.0; model.record(point(2000.0, now))
                val seed = model.activeWalk!!.pendingFinish!!.successor!!
                assertEquals(1, seed.walk().points.size)
                if (relaunch) {
                    val (reopened, copiedRoot) = snapshot(root); copy = copiedRoot
                    reply!!(400)
                    model = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                } else reply!!(400)
                now = 100840.0; model.record(point(2050.0, now))
                now = 100880.0; model.record(point(2100.0, now))
                assertEquals(seed.id, model.activeWalk!!.id)
                assertEquals(100800.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
                assertEquals(3, model.activeWalk!!.points.size)
                assertEquals(100.0, model.activeWalk!!.distance, 0.01)
            } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
        }
    }

    @Test fun aSinglePointSeedRebasesAgainAfterAnotherLongPause() {
        for (held in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                var now = 100000.0
                var reply: ((Int?) -> Unit)? = null
                val query: ((SwiftDate, SwiftDate, (Int?) -> Unit) -> Unit)? = if (held) ({ _, _, done -> reply = done }) else null
                val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now }, stepQuery = query)
                for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
                now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
                now = 100400.0; model.record(point(900.0, now))
                now = 100700.0; model.record(point(950.0, now))
                val id = if (held) model.activeWalk!!.pendingFinish!!.successor!!.id else model.activeWalk!!.id
                now = 100950.0; model.record(point(1000.0, now))
                now = 100990.0; model.record(point(1050.0, now))
                if (held) reply!!(400)
                assertEquals(id, model.activeWalk!!.id)
                assertEquals(100950.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
                assertEquals(2, model.activeWalk!!.points.size)
                assertEquals(50.0, model.activeWalk!!.distance, 0.01)
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test(timeout = 10000) fun manualEndDuringHeldHistoryFreezesTheRouteAtItsRequestedTime() = runBlocking {
        val (store, root) = tempStore()
        try {
            val queue = ArrayDeque<Runnable>()
            var held = true
            val dispatcher = object : CoroutineDispatcher() {
                override fun dispatch(context: CoroutineContext, block: Runnable) { if (held) queue.add(block) else block.run() }
            }
            var now = 100000.0
            val model = AppModel(store, FakeSettings(alwaysOn = false), FakeLocation(), clock = { now }, historyScope = CoroutineScope(dispatcher))
            model.startWalk()
            model.record(point(0.0, now)); now += 40; model.record(point(50.0, now))
            val original = model.activeWalk!!
            now = 100060.0; model.endWalk()
            now = 100080.0; model.record(point(100.0, now))
            now = 100120.0; model.record(point(150.0, now))
            assertEquals(original.points, model.activeWalk!!.points)
            val finished = CompletableDeferred<Unit>()
            val stop = model.listen { if (model.walks.any { it.id == original.id }) finished.complete(Unit) }
            held = false
            while (queue.isNotEmpty()) queue.removeFirst().run()
            finished.await(); stop()
            assertEquals(original.points, model.walks.single().points)
            assertEquals(100060.0, model.walks.single().endedAt!!.epochSeconds, 0.001)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun enablingAlwaysOnAfterAManualFinishWriteFailureCanRetryThatManualFinish() {
        val (store, root) = tempStore()
        try {
            var now = 100000.0
            val model = AppModel(store, FakeSettings(alwaysOn = false), FakeLocation(), clock = { now })
            model.startWalk(); model.record(point(0.0, now)); now += 40; model.record(point(50.0, now))
            val original = model.activeWalk!!
            model.saveNow(waiting = true)
            val blocked = File(root, "walks/.${original.id.toString().uppercase()}.json.tmp")
            assertTrue(blocked.mkdir())
            now = 100060.0; model.alwaysOn = true
            now = 100080.0; model.record(point(100.0, now))
            assertEquals(original.points, model.activeWalk!!.points)
            assertTrue(blocked.delete())
            now = 100120.0; model.record(point(150.0, now))
            assertEquals(original.id, model.walks.single().id)
            assertEquals(original.points, model.walks.single().points)
            assertEquals(100060.0, model.walks.single().endedAt!!.epochSeconds, 0.001)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun predecessorRecapExcludesTheSuccessorsCityProgress() {
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
            reply!!(400)
            assertEquals(original.id, model.recap!!.walk.id)
            assertEquals(beforeSuccessor, model.recap!!.after.single().visited)
            assertTrue(model.cities.single().visited.size > beforeSuccessor.size)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aFrozenConfirmedShortLegKeepsTileCreditAndDoesNotPolluteTheNextActiveLeg() {
        val (store, root) = tempStore()
        try {
            store.save(listOf(place())); store.flush()
            val short = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0),
                following = (0..2).map { point(1000.0 + it * 50, 100800.0 + it * 40) })
            val next = com.mikecann.walkies.model.NextWalk(arrival = point(1800.0, 100900.0), point = point(1850.0, 100940.0))
            val request = com.mikecann.walkies.model.PendingWalkFinish(SwiftDate.epoch(100320.0), WalkEndReason.Rode, false,
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

    @Test fun aSecondRideCannotEraseAQualifiedSuccessorWhoseFileWriteIsBlocked() {
        val (store, root) = tempStore()
        var copy: File? = null
        try {
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            val original = model.activeWalk!!
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            now = 100720.0; model.record(point(900.0, now))
            now = 100760.0; model.record(point(950.0, now))
            val successorId = model.activeWalk!!.pendingFinish!!.successor!!.id
            val blocked = File(root, "walks/.${successorId.toString().uppercase()}.json.tmp")
            assertTrue(blocked.mkdir())
            reply!!(400)
            model.querySteps = null
            for (i in 0..6) { now = 100800.0 + i * 40; model.record(point(1000.0 + i * 50, now)) }
            assertEquals(9, model.activeWalk!!.pendingFinish!!.successor!!.walk().points.size)
            now = 101060.0; model.record(point(1350.0, now).copy(wheels = true, accuracy = 80.0))
            now = 101080.0; model.record(point(1800.0, now))
            now = 101120.0; model.record(point(1850.0, now))
            val nextId = model.activeWalk!!.pendingFinish!!.successor!!.id
            model.saveNow(waiting = true)
            assertTrue(blocked.delete())
            val (reopened, copiedRoot) = snapshot(root)
            copy = copiedRoot
            val recovered = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            val saved = recovered.walks.single { it.id == successorId }
            assertEquals(9, saved.points.size)
            assertEquals(100720.0, saved.startedAt.epochSeconds, 0.001)
            assertEquals(101040.0, saved.endedAt!!.epochSeconds, 0.001)
            assertEquals(400.0, saved.distance, 0.01)
            assertEquals(WalkEndReason.Rode, saved.endReason)
            assertEquals(original.points, recovered.walks.single { it.id == original.id }.points)
            assertEquals(nextId, recovered.activeWalk!!.id)
            assertEquals(101080.0, recovered.activeWalk!!.startedAt.epochSeconds, 0.001)
            assertEquals(2, recovered.activeWalk!!.points.size)
        } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
    }

    @Test fun backgroundCheckpointDuringHeldRecoveryKeepsUnknownSuccessorCoverage() {
        val (store, root) = tempStore()
        try {
            val place = place()
            store.save(listOf(place)); store.flush()
            val seed = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0),
                following = (0..6).map { point(1000.0 + it * 50, 100800.0 + it * 40) })
            val original = Walk(startedAt = SwiftDate.epoch(100000.0), automatic = true,
                points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, pendingFinish =
                    com.mikecann.walkies.model.PendingWalkFinish(SwiftDate.epoch(100320.0), WalkEndReason.Rode, false, seed))
            store.save(original); store.save(seed.walk())
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { 101050.0 },
                stepQuery = { _, _, done -> reply = done })
            assertFalse(model.historyReady)
            model.saveNow(waiting = true)
            assertNull(store.loadWalks().single { it.id == seed.id }.newTileHexesByPlace)
            reply!!(400)
            val fresh = model.activeWalk!!.newTileHexesByPlace!!.getValue(place.id.toString().uppercase())
            assertTrue(fresh.isNotEmpty())
            assertTrue(Store(root).loadCities().single().visited.containsAll(fresh))
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun launchBlockedHandoffRetriesAndUploadsWithinTheSameModel() = runBlocking {
        val (store, root) = tempStore()
        try {
            val seed = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0))
            val original = Walk(startedAt = SwiftDate.epoch(100000.0), automatic = true,
                points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, pendingFinish =
                    com.mikecann.walkies.model.PendingWalkFinish(SwiftDate.epoch(100320.0), WalkEndReason.Rode, false, seed))
            store.save(original)
            val blocked = File(root, "walks/.${seed.id.toString().uppercase()}.json.tmp")
            assertTrue(blocked.mkdir())
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { 100780.0 })
            assertEquals(original.id, model.activeWalk?.id)
            assertTrue(blocked.delete())
            model.finishStaleAutoWalk()
            assertEquals(seed.id, model.activeWalk!!.id)
            assertEquals(original.id, model.walks.single().id)
            val server = FakeServer()
            val client = ConvexClient(server.backend, http = server)
            val engine = SyncEngine(model, store, isSignedIn = { true }, makeClient = { client }, scope = this)
            engine.sync()
            assertTrue(original.id.toString().uppercase() in server.walks)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test(timeout = 10000) fun heldHistoryNeverMergesOrReanchorsTheSuccessorAsMoreWalkingArrives() = runBlocking {
        for (xs in listOf(listOf(560.0, 520.0, 480.0), listOf(900.0, 950.0, 1000.0))) {
            val (store, root) = tempStore()
            try {
                val queue = ArrayDeque<Runnable>()
                var held = true
                val dispatcher = object : CoroutineDispatcher() {
                    override fun dispatch(context: CoroutineContext, block: Runnable) {
                        if (held) queue.add(block) else block.run()
                    }
                }
                val original = Walk(startedAt = SwiftDate.epoch(100000.0), automatic = true,
                    points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, continuation = WalkContinuation.Rode)
                store.save(original)
                var now = 100400.0
                val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                    historyScope = CoroutineScope(dispatcher))
                for ((i, x) in xs.withIndex()) { now = 100720.0 + i * 40; model.record(point(x, now)) }
                assertEquals(original.points, model.activeWalk!!.points)
                val seed = model.activeWalk!!.pendingFinish!!.successor!!
                val finished = CompletableDeferred<Unit>()
                val stop = model.listen {
                    if (model.walks.any { it.id == original.id } && model.activeWalk?.id == seed.id) finished.complete(Unit)
                }
                held = false
                while (queue.isNotEmpty()) queue.removeFirst().run()
                model.waitForHistory()
                finished.await()
                stop()
                assertEquals(original.points, model.walks.single().points)
                assertEquals(100320.0, model.walks.single().endedAt!!.epochSeconds, 0.001)
                assertEquals(seed.id, model.activeWalk!!.id)
                assertEquals(100720.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
                assertEquals(xs, model.activeWalk!!.points.map { kotlin.math.round((it.lat - 12.345) * 111195) })
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun aConfirmedSeedSavedBeforeCityCreditReplaysItsWholeRouteAtLaunch() {
        val (store, root) = tempStore()
        try {
            val place = place()
            store.save(listOf(place))
            store.flush()
            val seed = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0),
                following = (0..4).map { point(1000.0 + it * 50, 100800.0 + it * 40) })
            val original = Walk(startedAt = SwiftDate.epoch(100000.0), automatic = true,
                points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, pendingFinish =
                    com.mikecann.walkies.model.PendingWalkFinish(SwiftDate.epoch(100320.0), WalkEndReason.Rode, false, seed))
            store.save(original)
            store.save(seed.walk())
            assertNull(seed.walk().newTileHexesByPlace)
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { 100970.0 })
            assertEquals(seed.id, model.activeWalk!!.id)
            assertFalse(model.autoWalkPending)
            val fresh = model.activeWalk!!.newTileHexesByPlace!!.getValue(place.id.toString().uppercase())
            assertTrue(fresh.isNotEmpty())
            assertTrue(Store(root).loadCities().single().visited.containsAll(fresh))
            assertEquals(fresh.size, model.activeWalk!!.newTiles)
            val again = AppModel(Store(root), FakeSettings(alwaysOn = true), FakeLocation(), clock = { 100980.0 })
            assertEquals(fresh.size, again.activeWalk!!.newTiles)
            assertEquals(fresh, again.activeWalk!!.newTileHexesByPlace!!.getValue(place.id.toString().uppercase()))
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun walkingDuringTheStepWaitIsSavedAndCreditedWhenItsSuccessorIsAlreadyConfirmed() {
        val (store, root) = tempStore()
        try {
            val place = place()
            store.save(listOf(place))
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            val original = model.activeWalk!!
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            for (i in 0..6) { now = 100720.0 + i * 40; model.record(point(900.0 + i * 50, now)) }
            val seed = model.activeWalk!!.pendingFinish!!.successor!!
            assertEquals(original.points, model.activeWalk!!.points)
            reply!!(400)
            assertEquals(original.points, model.walks.single().points)
            assertEquals(seed.id, model.activeWalk!!.id)
            assertEquals(7, model.activeWalk!!.points.size)
            assertEquals(100720.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
            assertFalse(model.autoWalkPending)
            assertTrue(model.activeWalk!!.newTiles > 0)
            assertEquals(model.activeWalk!!.newTiles, model.activeWalk!!.newTileHexesByPlace!!.values.sumOf { it.size })
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun pendingFinishAndSuccessorRoundTripWithoutARecursiveWalk() {
        val seed = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 720.0), point = point(950.0, 760.0),
            following = listOf(point(1000.0, 800.0)))
        val original = Walk(startedAt = SwiftDate.epoch(0.0), pendingFinish =
            com.mikecann.walkies.model.PendingWalkFinish(SwiftDate.epoch(320.0), WalkEndReason.Rode, false, seed))
        assertEquals(original, Codec.walk(Codec.walk(original)))
        assertEquals(3, seed.walk().points.size)
        assertEquals(100.0, seed.walk().distance, 0.01)
    }

    @Test(timeout = 10000) fun anotherRideDuringHeldHistoryCannotResurrectThePreviousArrival() = runBlocking {
        val (store, root) = tempStore()
        var copy: File? = null
        try {
            val queue = ArrayDeque<Runnable>()
            var held = true
            val dispatcher = object : CoroutineDispatcher() {
                override fun dispatch(context: CoroutineContext, block: Runnable) {
                    if (held) queue.add(block) else block.run()
                }
            }
            val points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }
            val original = Walk(startedAt = SwiftDate.epoch(points.first().time), points = points, automatic = true,
                continuation = WalkContinuation.Rode, resumeAnchor = point(900.0, 100720.0))
            store.save(original)
            var now = 100760.0
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                historyScope = CoroutineScope(dispatcher))
            model.record(point(950.0, now))
            assertNotNull(model.activeWalk!!.pendingFinish?.successor)
            now = 100770.0
            model.record(point(960.0, now).copy(wheels = true, accuracy = 80.0))
            model.saveNow(waiting = true)
            assertNull(store.loadWalks().single().resumeAnchor)
            assertNull(store.loadWalks().single().pendingFinish!!.successor)
            val (reopened, copiedRoot) = snapshot(root)
            copy = copiedRoot
            held = false
            while (queue.isNotEmpty()) queue.removeFirst().run()
            model.waitForHistory()
            val relaunched = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            now = 100800.0; relaunched.record(point(950.0, now))
            now = 100840.0; relaunched.record(point(1000.0, now))
            val next = relaunched.activeWalk!!
            assertEquals(100800.0, next.startedAt.epochSeconds, 0.001)
            assertEquals(2, next.points.size)
            assertEquals(50.0, next.distance, 0.01)
        } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
    }

    @Test fun explicitShortEndSurvivesProcessDeathBeforeTheStepReply() {
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
                assertNull(store.loadWalks().single().endedAt)
                val (reopened, copiedRoot) = snapshot(root)
                copy = copiedRoot
                reply!!(50)
                now += delay
                val next = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                assertNull("A requested finish is never resumed (delay=$delay)", next.activeWalk)
                val saved = reopened.loadWalks().single()
                assertEquals(original.id, saved.id)
                assertEquals(original.points, saved.points)
                assertEquals(requestedEnd, saved.endedAt!!.epochSeconds, 0.001)
                assertEquals(WalkEndReason.You, saved.endReason)
                assertTrue(saved.newTiles > 0)
                assertTrue(saved.newTileHexesByPlace!!.values.any { it.isNotEmpty() })
                assertTrue(reopened.loadCities().single().visited.isNotEmpty())
                assertEquals(saved.newTiles, next.questTileCounts.getValue(saved.id).values.sum())
            } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
        }
    }

    @Test fun rideSuccessorOwnsArrivalAndConfirmationAcrossBothStepCrashPoints() {
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
                val successorId = model.activeWalk!!.pendingFinish!!.successor!!.id
                if (afterSteps) reply!!(400)
                val (reopened, copiedRoot) = snapshot(root)
                copy = copiedRoot
                if (!afterSteps) reply!!(400)
                model = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                now = 100800.0; model.record(point(1000.0, now))
                now = 100840.0; model.record(point(1050.0, now))
                val ended = model.walks.single()
                assertEquals(original.id, ended.id)
                assertEquals(original.points, ended.points)
                assertEquals(original.points.last().time, ended.endedAt!!.epochSeconds, 0.001)
                val successor = model.activeWalk!!
                assertEquals(successorId, successor.id)
                assertNotEquals(original.id, successor.id)
                assertEquals(100720.0, successor.startedAt.epochSeconds, 0.001)
                assertEquals(listOf(900.0, 950.0, 1000.0, 1050.0), successor.points.map { (it.lat - 12.345) * 111195 }.map { kotlin.math.round(it) })
                assertEquals(150.0, successor.distance, 0.01)
            } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
        }
    }

    @Test fun aFailedSuccessorWriteLeavesThePredecessorPendingUntilTheHandoffCanRetry() {
        val (store, root) = tempStore()
        var copy: File? = null
        try {
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            val original = model.activeWalk!!
            now = 100340.0; model.record(point(450.0, now).copy(wheels = true))
            now = 100720.0; model.record(point(900.0, now))
            now = 100760.0; model.record(point(950.0, now))
            val successor = model.activeWalk!!.pendingFinish!!.successor!!
            val blocked = File(root, "walks/.${successor.id.toString().uppercase()}.json.tmp")
            assertTrue(blocked.mkdir())
            reply!!(400)
            assertEquals(original.id, model.activeWalk!!.id)
            assertNull(store.loadWalks().single().endedAt)
            assertEquals(successor.id, store.loadWalks().single().pendingFinish!!.successor!!.id)
            val (reopened, copiedRoot) = snapshot(root)
            copy = copiedRoot
            AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            assertNull(reopened.loadWalks().single().endedAt)
            assertTrue(blocked.delete())
            model.querySteps = null
            model.finishStaleAutoWalk()
            assertEquals(successor.id, model.activeWalk!!.id)
            assertEquals(original.id, model.walks.single().id)
            assertTrue(File(copiedRoot, "walks/${blocked.name}").delete())
            val recovered = AppModel(reopened, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            assertEquals(successor.id, recovered.activeWalk!!.id)
            assertEquals(100720.0, recovered.activeWalk!!.startedAt.epochSeconds, 0.001)
        } finally { root.parentFile.deleteRecursively(); copy?.parentFile?.deleteRecursively() }
    }

    @Test fun aPreexistingSuccessorWithMorePointsIsNeverReplacedByItsOlderSeed() {
        val (store, root) = tempStore()
        try {
            val original = Walk(startedAt = SwiftDate.epoch(100000.0), points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }, automatic = true)
            val seed = com.mikecann.walkies.model.NextWalk(arrival = point(900.0, 100720.0), point = point(950.0, 100760.0))
            store.save(original.copy(pendingFinish = com.mikecann.walkies.model.PendingWalkFinish(
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
