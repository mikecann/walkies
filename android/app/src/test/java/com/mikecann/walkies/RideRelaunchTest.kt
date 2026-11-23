package com.mikecann.walkies

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.model.TrackPoint
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RideRelaunchTest {
    private fun fix(x: Double, time: Double, wheels: Boolean = false) =
        TrackPoint(12.345 + x / 111195.0, 45.678, time, 5.0, speed = 1.0, wheels = wheels)

    private fun ride(relaunch: Boolean) = runBlocking {
        val (store, root) = tempStore()
        try {
            val start = 100000.0
            var now = start
            val settings = FakeSettings(alwaysOn = true)
            var model = AppModel(store, settings, FakeLocation(), clock = { now })
            model.waitForHistory()
            for (i in 0..8) {
                now = start + i * 40
                model.record(fix(i * 50.0, now))
            }
            val old = requireNotNull(model.activeWalk)
            val last = old.points.last()
            assertFalse(model.autoWalkPending)
            now = last.time + 20
            model.record(fix(450.0, now, wheels = true))
            model.saveNow(waiting = true)
            if (relaunch) {
                model = AppModel(store, settings, FakeLocation(), clock = { now })
                model.waitForHistory()
                assertEquals(old.id, model.activeWalk?.id)
            }
            now = last.time + 400
            model.record(fix(900.0, now))
            now += 40
            model.record(fix(950.0, now))
            val kept = model.walks.any { it.id == old.id }
            val split = model.activeWalk?.id != old.id
            println("RIDE_RELAUNCH relaunch=$relaunch savedOld=$kept newIdentity=$split oldPoints=${old.points.size} currentPoints=${model.activeWalk?.points?.size}")
            assertTrue("The pre-ride walk must end even across relaunch", kept)
            assertTrue("Walking after a known ride must start a new walk", split)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun uninterruptedKnownRideSplitsTheWalk() = ride(false)
    @Test fun knownRideStillSplitsAfterRelaunch() = ride(true)
}
