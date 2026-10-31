package com.mikecann.walkies.location

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.model.TrackPoint

/** How hard the GPS works. */
enum class GpsMode {
    /** Nothing: Activity Recognition and the stationary fence wake it. */
    Off,
    /** Wi-Fi and cell towers, every minute or so: enough to notice you've left. */
    Low,
    /** Best accuracy, a fix a second: for walks, and while the app's on screen. */
    High,
}

/** The GPS, as far as the always-on logic is concerned. LocationTracker on the phone. */
interface Gps {
    var mode: GpsMode
}

enum class WalkState { None, Pending, Automatic, Manual }

/**
 * The always-on half of LocationTracker.swift, without the Android parts: where the
 * stationary fence goes and how hard the GPS works. Battery matters, so while you're
 * settled somewhere the GPS goes down or off, and leaving (the fence, or Activity
 * Recognition seeing you move) brings it straight back.
 */
class AlwaysOnTracking(
    private val gps: Gps,
    private val geofence: Geofence,
    private val motion: ActivityMotion,
    /** Seconds since 1970. */
    private val clock: () -> Double,
    /** Where the fence was left last time, so it survives the process. */
    fenceCenter: Coordinate? = null,
) {
    /** Called when the fence moves or goes, to save where it is. */
    var onFenceMoved: (Coordinate?) -> Unit = {}

    var alwaysOn = false
        private set
    var onScreen = false
        private set
    var walk = WalkState.None
        private set

    private val fence = StationaryFence(fenceCenter)
    private var lastFix: TrackPoint? = null
    /** After leaving the fence or starting to move, the GPS stays up until then, whatever else says. */
    private var awakeUntil = Double.NEGATIVE_INFINITY
    /** You've left the fence and haven't settled anywhere since. */
    private var outside = false

    val fenceCenter: Coordinate? get() = fence.center

    fun update(alwaysOn: Boolean, onScreen: Boolean, walk: WalkState) {
        val turnedOff = this.alwaysOn && !alwaysOn
        this.alwaysOn = alwaysOn
        this.onScreen = onScreen
        this.walk = walk
        if (turnedOff) removeFence()
        apply()
    }

    /** Puts the fence back where it was, say after a reboot, which clears it. */
    fun restoreFence() {
        val center = fence.center ?: return
        if (alwaysOn) geofence.place(center, StationaryFence.RADIUS)
    }

    fun fix(point: TrackPoint) {
        if (!alwaysOn) {
            apply()
            return
        }
        val center = fence.center
        // Out past the fence, even if the fence itself hasn't said so yet. Only if even the near
        // edge of the fix's accuracy circle is outside, so a vague Wi-Fi fix at home doesn't count.
        // Only the first one: each wake starts the settling clock again, so waking on every fix
        // out there meant you could only settle somewhere new by putting the phone down.
        if (!outside && center != null && center.distance(point.coordinate) - point.accuracy.coerceAtLeast(0.0) > StationaryFence.RADIUS) leave()
        // Not a cached fix from wherever you were when updates started.
        if (clock() - point.time <= 10) {
            lastFix = point
            settle(point, point.time)
        }
        apply()
    }

    /** Every minute or so: you may have settled without any new fixes coming in. */
    fun tick() {
        val last = lastFix
        if (alwaysOn && last != null) settle(last, clock())
        apply()
    }

    /** An Activity Recognition transition. */
    fun motionChanged(activity: MotionActivity, entered: Boolean) {
        val moving = motion.transition(activity, entered)
        // A new still transition is stronger evidence than the wake timer. A fence exit
        // can still wake GPS while the chip's old answer says still.
        if (activity == MotionActivity.Still && entered) awakeUntil = Double.NEGATIVE_INFINITY
        if (moving) {
            // Moving about inside the fence (round the house, picking the phone up) only needs a
            // light watch: leaving it is what brings the GPS up.
            if (insideFence) fence.unsettle() else wake()
        }
        apply()
    }

    /** You've left where you settled. */
    fun leftFence() {
        leave()
        apply()
    }

    /** Without the motion chip there's nothing to say you've stopped again, so this only counts with it. */
    private val insideFence get() = fence.center != null && !outside && motion.known

    private fun leave() {
        outside = true
        wake()
    }

    private fun wake() {
        awakeUntil = clock() + WAKE_TIME
        fence.unsettle()
    }

    private fun settle(point: TrackPoint, time: Double) {
        val center = fence.add(point.coordinate, time, point.accuracy, stationary = motion.known && motion.still, walking = walk != WalkState.None)
        if (center == null) {
            // Back where you were (home after a walk, say): inside again, though the fence stays put.
            if (fence.settledInPlace) outside = false
            return
        }
        outside = false
        geofence.place(center, StationaryFence.RADIUS)
        onFenceMoved(center)
    }

    private fun removeFence() {
        val had = fence.center != null
        fence.reset()
        outside = false
        lastFix = null
        awakeUntil = Double.NEGATIVE_INFINITY
        geofence.remove()
        if (had) onFenceMoved(null)
    }

    private fun apply() {
        val now = clock()
        val mode = decide(
            alwaysOn = alwaysOn,
            onScreen = onScreen,
            walk = walk,
            motionKnown = motion.known,
            still = motion.still,
            onWheels = motion.onWheels,
            settled = fence.center != null && fence.settled(now),
            awake = now < awakeUntil,
            insideFence = insideFence,
        )
        if (gps.mode != mode) gps.mode = mode
    }

    companion object {
        /** Seconds the GPS stays up after you leave the fence or start moving. */
        const val WAKE_TIME = 3 * 60.0

        fun decide(
            alwaysOn: Boolean,
            onScreen: Boolean,
            walk: WalkState,
            motionKnown: Boolean,
            still: Boolean,
            onWheels: Boolean,
            settled: Boolean,
            awake: Boolean,
            insideFence: Boolean = false,
        ): GpsMode = when {
            // The you-are-here dot, and walks you started yourself.
            onScreen || walk == WalkState.Manual -> GpsMode.High
            !alwaysOn -> GpsMode.Off
            // Not in a car or on a bike: every fix on the road is outside the fence and
            // wakes it again, which kept the GPS flat out for whole drives.
            awake && !onWheels -> GpsMode.High
            // Sitting still: the motion chip says when you're off again. A pending walk
            // ends by itself after the gap.
            motionKnown && still -> GpsMode.Off
            // Keep an automatic walk resumable through a pause without holding GPS on.
            // Moving again unsets the settling clock, even inside the same fence.
            onWheels -> GpsMode.Low
            walk == WalkState.Automatic -> if (settled) {
                if (motionKnown) GpsMode.Off else GpsMode.Low
            } else GpsMode.High
            // Pottering about where you settled. Low still gets a fix every minute or so, and one
            // past the fence (or the fence itself) wakes it. The first ~100 m of a walk from
            // here is coarse, which Mike accepted for the battery (28 Oct 2026).
            insideFence -> if (settled) GpsMode.Off else GpsMode.Low
            walk == WalkState.Pending -> GpsMode.High
            // Without the motion chip, keep a light watch rather than rely on the fence alone.
            settled -> if (motionKnown) GpsMode.Off else GpsMode.Low
            else -> GpsMode.High
        }
    }
}
