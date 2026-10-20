package com.mikecann.walkies.location

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.model.TrackPoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos

private class FakeGps : Gps {
    override var mode = GpsMode.Off
}

private class FakeGeofence : Geofence {
    val placed = ArrayList<Coordinate>()
    var removed = 0
    override fun place(center: Coordinate, radius: Double) {
        placed.add(center)
    }
    override fun remove() {
        removed++
    }
}

private val home = Coordinate(-33.65, 115.35)

/** [metres] east of home. */
private fun east(metres: Double) = Coordinate(home.lat, home.lon + metres / (111_320.0 * cos(Math.toRadians(home.lat))))

class StationaryFenceTest {
    @Test
    fun theFirstGoodFixPlacesItWhenYoureNotOnAWalk() {
        val fence = StationaryFence()
        assertEquals(home, fence.add(home, 0.0, 10.0, stationary = false, walking = false))
        assertEquals(home, fence.center)
    }

    @Test
    fun vagueFixesAreIgnored() {
        val fence = StationaryFence()
        assertNull(fence.add(home, 0.0, 80.0, stationary = true, walking = false))
        assertNull(fence.add(home, 0.0, -1.0, stationary = true, walking = false))
        assertNull(fence.center)
    }

    @Test
    fun onAWalkItWaitsUntilYouStayPut() {
        val fence = StationaryFence()
        assertNull(fence.add(home, 0.0, 10.0, stationary = false, walking = true))
        assertNull(fence.add(east(10.0), 60.0, 10.0, stationary = false, walking = true))
        assertEquals(east(20.0), fence.add(east(20.0), 120.0, 10.0, stationary = false, walking = true))
        assertTrue(fence.settled(120.0))
    }

    @Test
    fun movingOnStartsTheClockAgain() {
        val fence = StationaryFence()
        fence.add(home, 0.0, 10.0, stationary = false, walking = true)
        assertNull(fence.add(east(200.0), 130.0, 10.0, stationary = false, walking = true))
        assertFalse(fence.settled(130.0))
        assertTrue(fence.settled(250.0))
    }

    @Test
    fun beingStillPlacesItStraightAway() {
        val fence = StationaryFence(home)
        assertEquals(east(500.0), fence.add(east(500.0), 0.0, 10.0, stationary = true, walking = true))
    }

    @Test
    fun itDoesntMoveForWobbleAroundTheSameSpot() {
        val fence = StationaryFence(home)
        assertNull(fence.add(east(20.0), 0.0, 10.0, stationary = true, walking = false))
        assertEquals(home, fence.center)
    }

    @Test
    fun resetForgetsIt() {
        val fence = StationaryFence(home)
        fence.add(home, 0.0, 10.0, stationary = false, walking = false)
        fence.reset()
        assertNull(fence.center)
        assertFalse(fence.settled(1000.0))
    }
}

class ActivityMotionTest {
    @Test
    fun nothingsKnownAtFirst() {
        val motion = ActivityMotion()
        assertFalse(motion.known)
        assertFalse(motion.onWheels)
        assertFalse(motion.still)
    }

    @Test
    fun carsAndBikesAreOnWheels() {
        for (activity in listOf(MotionActivity.InVehicle, MotionActivity.OnBicycle)) {
            val motion = ActivityMotion()
            assertTrue(motion.transition(activity, entered = true))
            assertTrue(motion.onWheels)
            assertFalse(motion.still)
        }
    }

    @Test
    fun onFootClearsWheels() {
        for (activity in listOf(MotionActivity.Walking, MotionActivity.Running, MotionActivity.OnFoot)) {
            val motion = ActivityMotion()
            motion.transition(MotionActivity.InVehicle, entered = true)
            assertTrue(motion.transition(activity, entered = true))
            assertFalse(motion.onWheels)
        }
    }

    @Test
    fun sittingAtTheLightsIsStillDriving() {
        val motion = ActivityMotion()
        motion.transition(MotionActivity.InVehicle, entered = true)
        assertFalse(motion.transition(MotionActivity.Still, entered = true))
        assertTrue(motion.still)
        assertTrue(motion.onWheels)
        assertTrue(motion.transition(MotionActivity.Still, entered = false))
        assertFalse(motion.still)
        assertTrue(motion.onWheels)
    }

    @Test
    fun leavingAnythingButStillChangesNothing() {
        val motion = ActivityMotion()
        motion.transition(MotionActivity.InVehicle, entered = true)
        assertFalse(motion.transition(MotionActivity.InVehicle, entered = false))
        assertTrue(motion.onWheels)
        assertFalse(motion.transition(MotionActivity.Walking, entered = false))
    }
}

class AlwaysOnTrackingTest {
    private var now = 1_000_000.0
    private val gps = FakeGps()
    private val geofence = FakeGeofence()
    private val motion = ActivityMotion()

    private fun tracking(center: Coordinate? = null) = AlwaysOnTracking(gps, geofence, motion, { now }, center)

    private fun fix(at: Coordinate, accuracy: Double = 10.0) = TrackPoint(at.lat, at.lon, now, accuracy)

    @Test
    fun offWhenAlwaysOnIsOffAndTheAppsClosed() {
        val t = tracking()
        t.update(alwaysOn = false, onScreen = false, walk = WalkState.None)
        assertEquals(GpsMode.Off, gps.mode)
    }

    @Test
    fun highWhileOnScreenOrOnAWalkYouStarted() {
        val t = tracking()
        t.update(alwaysOn = false, onScreen = true, walk = WalkState.None)
        assertEquals(GpsMode.High, gps.mode)
        t.update(alwaysOn = false, onScreen = false, walk = WalkState.Walking)
        assertEquals(GpsMode.High, gps.mode)
    }

    @Test
    fun alwaysOnStartsHighAndPlacesTheFenceAtTheFirstFix() {
        val t = tracking()
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        assertEquals(GpsMode.High, gps.mode)
        t.fix(fix(home))
        assertEquals(listOf(home), geofence.placed)
        assertEquals(home, t.fenceCenter)
    }

    @Test
    fun settlingWithoutTheMotionChipTurnsTheGpsDown() {
        val t = tracking()
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.fix(fix(home))
        now += 60
        t.tick()
        assertEquals(GpsMode.High, gps.mode)
        now += 61
        t.tick()
        assertEquals(GpsMode.Low, gps.mode)
    }

    @Test
    fun settlingWithTheMotionChipTurnsTheGpsOff() {
        val t = tracking()
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.motionChanged(MotionActivity.Walking, entered = true)
        t.fix(fix(home))
        now += StationaryFence.SETTLE_TIME + AlwaysOnTracking.WAKE_TIME
        t.tick()
        assertEquals(GpsMode.Off, gps.mode)
    }

    @Test
    fun beingStillTurnsItOffAndMovingTurnsItBackOn() {
        val t = tracking()
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.motionChanged(MotionActivity.Still, entered = true)
        assertEquals(GpsMode.Off, gps.mode)
        t.motionChanged(MotionActivity.Walking, entered = true)
        assertEquals(GpsMode.High, gps.mode)
    }

    @Test
    fun leavingTheFenceWakesItEvenIfTheChipStillSaysStill() {
        val t = tracking(home)
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.motionChanged(MotionActivity.Still, entered = true)
        assertEquals(GpsMode.Off, gps.mode)
        t.leftFence()
        assertEquals(GpsMode.High, gps.mode)
        // Stays up long enough to find out where you're going.
        now += AlwaysOnTracking.WAKE_TIME - 1
        t.tick()
        assertEquals(GpsMode.High, gps.mode)
        now += 2
        t.tick()
        assertEquals(GpsMode.Off, gps.mode)
    }

    @Test
    fun aFixOutsideTheFenceWakesItToo() {
        val t = tracking(home)
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.fix(fix(home))
        now += StationaryFence.SETTLE_TIME
        t.tick()
        assertEquals(GpsMode.Low, gps.mode)
        t.fix(fix(east(300.0), accuracy = 100.0))
        assertEquals(GpsMode.High, gps.mode)
    }

    @Test
    fun drivingKeepsALightWatch() {
        val t = tracking()
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.motionChanged(MotionActivity.InVehicle, entered = true)
        now += AlwaysOnTracking.WAKE_TIME
        t.tick()
        assertEquals(GpsMode.Low, gps.mode)
        t.motionChanged(MotionActivity.Walking, entered = true)
        assertEquals(GpsMode.High, gps.mode)
    }

    @Test
    fun aPendingWalkStaysHighUnlessYoureStill() {
        val t = tracking()
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.Pending)
        assertEquals(GpsMode.High, gps.mode)
        t.motionChanged(MotionActivity.Still, entered = true)
        assertEquals(GpsMode.Off, gps.mode)
        // A real walk keeps going through a stop at the lights.
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.Walking)
        assertEquals(GpsMode.High, gps.mode)
    }

    @Test
    fun theFenceMovesWhenYouSettleSomewhereNew() {
        val t = tracking()
        var saved: Coordinate? = null
        t.onFenceMoved = { saved = it }
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.fix(fix(home))
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.Walking)
        val park = east(1000.0)
        now += 600
        t.fix(fix(park))
        assertEquals(1, geofence.placed.size)
        now += StationaryFence.SETTLE_TIME
        t.tick()
        assertEquals(listOf(home, park), geofence.placed)
        assertEquals(park, saved)
    }

    @Test
    fun cachedFixesDontPlaceIt() {
        val t = tracking()
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.fix(TrackPoint(home.lat, home.lon, now - 60, 10.0))
        assertTrue(geofence.placed.isEmpty())
    }

    @Test
    fun turningAlwaysOnOffRemovesTheFence() {
        val t = tracking(home)
        var saved: Coordinate? = home
        t.onFenceMoved = { saved = it }
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.update(alwaysOn = false, onScreen = false, walk = WalkState.None)
        assertEquals(1, geofence.removed)
        assertNull(t.fenceCenter)
        assertNull(saved)
        assertEquals(GpsMode.Off, gps.mode)
    }

    @Test
    fun theFenceGoesBackAfterARestart() {
        val t = tracking(home)
        t.restoreFence()
        assertTrue(geofence.placed.isEmpty())
        t.update(alwaysOn = true, onScreen = false, walk = WalkState.None)
        t.restoreFence()
        assertEquals(listOf(home), geofence.placed)
        assertNotNull(t.fenceCenter)
    }
}
