package com.mikecann.walkies.sync

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.location.ActivityMotion
import com.mikecann.walkies.location.AlwaysOnTracking
import com.mikecann.walkies.location.Geofence
import com.mikecann.walkies.location.Gps
import com.mikecann.walkies.location.GpsMode
import com.mikecann.walkies.location.MotionActivity
import com.mikecann.walkies.location.WalkState
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.store.Store
import com.mikecann.walkies.tempStore
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.SwiftDate
import org.junit.Assert.*
import org.junit.Test

/** Sensor/service callbacks are fake; model, fence policy, disk and HTTP sync are real. */
class RestRelaunchSyncTest {
    @Test(timeout = 10000) fun recoveredWalkWaitsForHistoryAndStepsBeforeReachingTheServer() = runBlocking {
        val (store, root) = tempStore()
        try {
            val points = (0..8).map { TrackPoint(12.345 + it * 50 / 111195.0, 45.678, 100000.0 + it * 40, 5.0, speed = 1.0) }
            val original = Walk(startedAt = SwiftDate.epoch(points.first().time), points = points, automatic = true)
            store.save(original)
            var reply: ((Int?) -> Unit)? = null
            val model = AppModel(store, FakeSettings(alwaysOn = false), FakeLocation(), clock = { 101000.0 },
                stepQuery = { _, _, done -> reply = done })
            val server = FakeServer()
            val client = ConvexClient(server.backend, http = server)
            val engine = SyncEngine(model, store, isSignedIn = { true }, makeClient = { client }, scope = this)
            val job = launch { engine.sync() }
            while (engine.status != SyncEngine.Status.Syncing) yield()
            yield()
            assertFalse(job.isCompleted)
            assertTrue(server.walks.isEmpty())
            reply!!(432)
            job.join()
            val uploaded = Codec.walk(Codec.parse(server.files.getValue(server.walks.getValue(original.id.uuidString)).decodeToString()))
            assertEquals(original.points, uploaded.points)
            assertEquals(432, uploaded.steps)
            assertEquals(SwiftDate.epoch(points.last().time), uploaded.endedAt)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aRestoredStopExitContinuesTheRouteThroughStepsDiskAndSync() = runBlocking {
        val (store, root) = tempStore()
        try {
            var now = 100000.0
            val settings = FakeSettings(alwaysOn = true)
            var motion = ActivityMotion()
            var model = AppModel(store, settings, FakeLocation(), motion = motion, clock = { now })
            fun point(x: Double) = TrackPoint(12.345 + x / 111195, 45.678, now, 5.0, speed = 1.0)
            val home = Coordinate(12.345, 45.678)
            for (i in 0..8) { now = 100000.0 + i * 40; model.record(point(i * 50.0)) }
            val original = model.activeWalk!!
            motion.transition(MotionActivity.Still, true)
            model.saveNow(waiting = true)
            now += 180
            var reply: ((Int?) -> Unit)? = null
            motion = ActivityMotion()
            motion.transition(MotionActivity.Still, true)
            model = AppModel(Store(root), settings, FakeLocation(), motion = motion, clock = { now },
                stepQuery = { _, _, done -> reply = done })
            val gps = object : Gps { override var mode = GpsMode.Off }
            val placements = mutableListOf<Coordinate>()
            val fence = object : Geofence {
                override fun place(center: Coordinate, radius: Double) { placements += center }
                override fun remove() = Unit
            }
            val tracker = AlwaysOnTracking(gps, fence, motion, { now }, fenceCenter = home)
            tracker.update(alwaysOn = true, onScreen = false, walk = WalkState.Automatic)
            // An early still fix on the away stop must not move the restored home fence.
            tracker.fix(point(400.0).copy(speed = 0.0))
            tracker.restoreFence()
            assertEquals(listOf(home), placements)
            assertEquals(home, tracker.fenceCenter)
            tracker.leftFence()
            tracker.motionChanged(MotionActivity.Walking, true)
            assertEquals(GpsMode.High, gps.mode)
            for (i in 0..4) {
                now = 100520.0 + i * 40
                val p = point(450.0 + i * 50)
                tracker.fix(p)
                model.record(p)
            }
            assertEquals(original.id, model.activeWalk?.id)
            val route = model.activeWalk!!.points
            assertEquals(original.points + route.drop(original.points.size), route)
            assertEquals(home, tracker.fenceCenter)
            now += 600
            model.finishStaleAutoWalk()
            val server = FakeServer()
            val client = ConvexClient(server.backend, http = server)
            var engine = SyncEngine(model, Store(root), isSignedIn = { true }, makeClient = { client }, scope = this)
            engine.sync()
            assertTrue(server.walks.isEmpty())
            assertNull(Store(root).loadWalks().single().endedAt)
            reply!!(800)
            val finished = Store(root).loadWalks().single()
            assertEquals(original.id, finished.id)
            assertEquals(route.last().time, finished.endedAt!!.epochSeconds, 0.001)
            server.offline = true
            engine.sync()
            assertTrue(engine.status is SyncEngine.Status.Failed)
            model = AppModel(Store(root), settings, FakeLocation(), clock = { now })
            engine = SyncEngine(model, Store(root), isSignedIn = { true }, makeClient = { client }, scope = this)
            server.offline = false
            engine.sync()
            val uploaded = Codec.walk(Codec.parse(server.files.getValue(server.walks.getValue(original.id.uuidString)).decodeToString()))
            assertEquals(route, uploaded.points)
            assertEquals(original.startedAt, uploaded.startedAt)
            assertEquals(finished.endedAt, uploaded.endedAt)
            assertEquals(800, uploaded.steps)
            assertTrue(original.id in Store(root).loadSyncState().uploadedWalks)
            assertEquals(0, engine.waiting)
        } finally { root.parentFile.deleteRecursively() }
    }
}
