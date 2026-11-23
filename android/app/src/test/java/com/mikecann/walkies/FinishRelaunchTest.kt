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
