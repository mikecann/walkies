package com.mikecann.walkies

import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.ui.Format
import org.junit.Assert.*
import org.junit.Test

class StepTest {
    @Test fun oldJSONAndAbsentSteps() {
        val old = Codec.parse("""{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"points":[],"distance":0,"newTiles":0}""")
        val walk = Codec.walk(old)
        assertNull(walk.steps)
        assertFalse(Codec.walk(walk).containsKey("steps"))
    }

    @Test fun stepsRoundTripIncludingZero() {
        for (count in listOf(0, 1234)) {
            val walk = Walk(startedAt = SwiftDate(100.0), steps = count)
            assertEquals(walk, Codec.walk(Codec.parse(Codec.walk(walk).toString())))
        }
    }

    @Test fun stepFormattingUsesThousandsSeparators() {
        val locale = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.US)
            assertEquals("1,234 steps", Format.steps(1234))
            assertEquals("0 steps", Format.steps(0))
        } finally { java.util.Locale.setDefault(locale) }
    }

    @Test fun finishedWalkIsNotPublishedBeforeStepsAndRepeatedEndIsIgnored() {
        val (store, root) = tempStore()
        try {
            var reply: ((Int?) -> Unit)? = null
            var requests = 0
            val model = AppModel(store, FakeSettings(), FakeLocation(), stepQuery = { _, _, done -> requests++; reply = done })
            var synced: Int? = null
            model.requestSync = { synced = model.walks.lastOrNull()?.steps }
            model.startWalk()
            val id = model.activeWalk!!.id
            model.endWalk()
            model.endWalk()
            model.startWalk()
            assertEquals(id, model.activeWalk?.id)
            assertTrue(model.walks.isEmpty())
            assertEquals(1, requests)
            reply!!(1234)
            reply!!(9999)
            assertEquals(1, model.walks.size)
            assertEquals(1234, model.walks.single().steps)
            assertEquals(1234, model.recap?.walk?.steps)
            assertEquals(1234, synced)
            assertEquals(1234, store.loadWalks().single().steps)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun countingOffIgnoresLateReply() {
        val (store, root) = tempStore()
        try {
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(), FakeLocation(), stepQuery = { _, _, done -> reply = done })
            model.startWalk()
            model.endWalk()
            model.countSteps = false
            reply!!(1234)
            assertNull(model.walks.single().steps)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun replyAfterWipeCannotFinishAnotherWalk() {
        val (store, root) = tempStore()
        try {
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(), FakeLocation(), stepQuery = { _, _, done -> reply = done })
            model.startWalk()
            model.endWalk()
            model.wipeLocalData()
            model.startWalk()
            val next = model.activeWalk!!.id
            reply!!(1234)
            assertTrue(model.walks.isEmpty())
            assertEquals(next, model.activeWalk?.id)
            assertNull(model.activeWalk?.steps)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun unavailableCountFinishesWithoutSteps() {
        val (store, root) = tempStore()
        try {
            val model = AppModel(store, FakeSettings(), FakeLocation(), stepQuery = { _, _, done -> done(null) })
            model.startWalk()
            model.endWalk()
            assertNull(model.walks.single().steps)
            assertNotNull(model.walks.single().endedAt)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun automaticWalkEndingInBackgroundUsesItsLastFix() {
        val (store, root) = tempStore()
        try {
            var now = 405.0
            val walk = Walk(
                startedAt = SwiftDate.epoch(100.0), automatic = true,
                points = listOf(TrackPoint(0.0, 0.0, 100.0, 5.0, speed = 1.0),
                    TrackPoint(0.0, 0.001, 200.0, 5.0, speed = 1.0),
                    TrackPoint(0.0, 0.002, 300.0, 5.0, speed = 1.0),
                    TrackPoint(0.0, 0.003, 400.0, 5.0, speed = 1.0)),
            )
            store.save(walk)
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = { now }, stepQuery = { from, to, done ->
                assertEquals(SwiftDate.epoch(100.0), from)
                assertEquals(SwiftDate.epoch(400.0), to)
                reply = done
            })
            now = 1100.0
            model.finishStaleAutoWalk()
            assertTrue(model.walks.isEmpty())
            reply!!(450)
            assertEquals(450, model.walks.single().steps)
            assertEquals(SwiftDate.epoch(400.0), model.walks.single().endedAt)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun recoveredWalkUsesLastFixAndWaitsForSteps() {
        val (store, root) = tempStore()
        try {
            val walk = Walk(startedAt = SwiftDate.epoch(100.0), points = listOf(TrackPoint(1.0, 1.0, 400.0, 5.0)))
            store.save(walk)
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(), FakeLocation(), stepQuery = { from, to, done ->
                assertEquals(walk.startedAt, from)
                assertEquals(SwiftDate.epoch(400.0), to)
                reply = done
            })
            assertNull(model.walks.single().endedAt)
            assertFalse(model.historyReady)
            reply!!(400)
            assertTrue(model.historyReady)
            assertEquals(400, model.walks.single().steps)
            assertEquals(SwiftDate.epoch(400.0), store.loadWalks().single().endedAt)
        } finally { root.parentFile.deleteRecursively() }
    }
}
