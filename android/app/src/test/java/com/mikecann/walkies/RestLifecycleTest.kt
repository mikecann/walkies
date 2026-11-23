package com.mikecann.walkies

import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.WalkContinuation
import com.mikecann.walkies.model.WalkEndReason
import com.mikecann.walkies.store.Store
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import kotlin.coroutines.CoroutineContext

class RestLifecycleTest {
    private fun point(x: Double, time: Double) = TrackPoint(12.345 + x / 111195.0, 45.678, time, 5.0, speed = 1.0)

    @Test fun theFirstAnchorIsUsableAt120SecondsAndRebasedAfter120Seconds() {
        for (age in listOf(120.0, 120.001)) {
            val (store, root) = tempStore()
            try {
                var now = 100000.0
                val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                model.record(point(0.0, now))
                now += age
                model.record(point(50.0, now))
                if (age == 120.0) {
                    assertEquals(100000.0, model.activeWalk!!.startedAt.epochSeconds, 0.001)
                } else {
                    assertNull(model.activeWalk)
                    now += 40
                    model.record(point(100.0, now))
                    assertEquals(100000.0 + age, model.activeWalk!!.startedAt.epochSeconds, 0.001)
                }
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun historyAndStepCompletionsCannotAppendPostGapFixesToThePreviousWalk() = runBlocking {
        val (store, root) = tempStore()
        try {
            val queued = ArrayDeque<Runnable>()
            var holding = true
            val dispatcher = object : CoroutineDispatcher() {
                override fun dispatch(context: CoroutineContext, block: Runnable) {
                    if (holding) queued.add(block) else block.run()
                }
            }
            val points = (0..8).map { point(it * 50.0, 100000.0 + it * 40) }
            val original = Walk(startedAt = SwiftDate.epoch(points.first().time), points = points, automatic = true)
            store.save(original)
            var now = 100400.0
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                historyScope = CoroutineScope(dispatcher), stepQuery = { _, _, done -> reply = done })
            assertFalse(model.historyReady)
            now = points.last().time + 600
            model.record(point(450.0, now))
            now += 40
            model.record(point(500.0, now))
            assertEquals(original.points, model.activeWalk!!.points)
            holding = false
            while (queued.isNotEmpty()) queued.removeFirst().run()
            model.waitForHistory()
            assertNotNull(reply)
            assertTrue(model.walks.isEmpty())
            assertNull(Store(root).loadWalks().single().endedAt)
            reply!!(400)
            reply!!(9999)
            assertEquals(original.id, model.walks.single().id)
            assertEquals(original.points, model.walks.single().points)
            assertEquals(400, model.walks.single().steps)
            assertEquals(WalkEndReason.Gap, model.walks.single().endReason)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun legacyWalkAndContinuationRoundTrip() {
        val old = Codec.walk(Codec.parse("""{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"points":[],"distance":0,"newTiles":0}"""))
        assertEquals(WalkContinuation.Walking, old.continuationState)
        assertNull(old.resumeAnchor)
        assertNull(old.endReason)
        val riding = old.transition(WalkContinuation.Event.ObservedRide).copy(resumeAnchor = point(900.0, 1000.0))
        assertEquals(riding, Codec.walk(Codec.walk(riding)))
        val finished = riding.transition(WalkContinuation.Event.Finished).copy(endReason = WalkEndReason.Rode)
        assertNull(finished.resumeAnchor)
        assertEquals(finished, Codec.walk(Codec.walk(finished)))
    }

    @Test fun explicitEndKeepsPendingAndConfirmedShortWalks() {
        for (xs in listOf(listOf(0.0, 50.0), listOf(0.0, 50.0, 100.0, 150.0, 200.0))) {
            val (store, root) = tempStore()
            try {
                var now = 100000.0
                val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
                for ((i, x) in xs.withIndex()) {
                    now = 100000.0 + i * 40
                    model.record(point(x, now))
                }
                val original = requireNotNull(model.activeWalk)
                model.endAutoWalk()
                val saved = Store(root).loadWalks().single()
                assertEquals(original.id, saved.id)
                assertEquals(original.points, saved.points)
                assertEquals(WalkEndReason.You, saved.endReason)
                assertNotNull(saved.endedAt)
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun longLocalLoopBelowDisplacementThresholdStillDropsAutomatically() {
        val (store, root) = tempStore()
        try {
            var now = 100000.0
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            val xs = listOf(0.0, 50.0, 100.0, 140.0, 100.0, 50.0, 0.0, 50.0, 100.0, 140.0, 100.0, 50.0, 0.0)
            for ((i, x) in xs.withIndex()) {
                now = 100000.0 + i * 40
                model.record(point(x, now))
            }
            assertTrue(model.activeWalk!!.distance > 500)
            assertTrue(model.autoWalkPending)
            now += 600
            model.finishStaleAutoWalk()
            assertNull(model.activeWalk)
            assertTrue(model.walks.isEmpty())
            assertTrue(Store(root).loadWalks().isEmpty())
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun confirmationAndMinimumDistanceThresholdsSurviveRecovery() {
        // Straddle each boundary by centimetres, rather than relying on rounding a
        // latitude to exactly 150 or 300 metres.
        for ((maximum, total, kept) in listOf(Triple(149.99, 400.0, false), Triple(150.01, 299.99, false), Triple(150.01, 300.01, true))) {
            val (store, root) = tempStore()
            try {
                val remainder = total - maximum
                val positions = listOf(0.0, 50.0, 100.0, maximum, maximum - 50, maximum - 100, maximum - remainder)
                val points = positions.mapIndexed { i, x -> point(x, 100000.0 + i * 80) }
                val walk = Walk(startedAt = SwiftDate.epoch(points.first().time), automatic = true, points = points)
                store.save(walk)
                val model = AppModel(Store(root), FakeSettings(alwaysOn = false), FakeLocation(), clock = { points.last().time + 601 })
                assertEquals("maximum=$maximum total=$total", kept, model.walks.any { it.id == walk.id })
                assertEquals(kept, Store(root).loadWalks().any { it.id == walk.id })
                if (kept) assertEquals(WalkEndReason.Recovered, model.walks.single().endReason)
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun aRelaunchWhileStepsArePendingPreservesRideAndOriginalEnd() {
        val (store, root) = tempStore()
        try {
            var now = 100000.0
            var reply: ((Int?) -> Unit)? = null
            var model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now },
                stepQuery = { _, _, done -> reply = done })
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0, now)) }
            val original = model.activeWalk!!
            now += 20
            model.record(point(450.0, now).copy(wheels = true))
            now = 100720.0
            model.record(point(900.0, now))
            now += 40
            model.record(point(950.0, now))
            assertNotNull(reply)
            assertTrue(model.walks.isEmpty())
            assertNull(Store(root).loadWalks().single().endedAt)
            model = AppModel(Store(root), FakeSettings(alwaysOn = true), FakeLocation(), clock = { now })
            now += 40
            model.record(point(1000.0, now))
            val ended = model.walks.single()
            assertEquals(original.id, ended.id)
            assertEquals(original.points, ended.points)
            assertEquals(original.points.last().time, ended.endedAt!!.epochSeconds, 0.001)
            assertEquals(WalkEndReason.Rode, ended.endReason)
            assertNotEquals(original.id, model.activeWalk!!.id)
            assertEquals(900.0, (model.activeWalk!!.points.first().lat - 12.345) * 111195, 0.001)
        } finally { root.parentFile.deleteRecursively() }
    }
}
