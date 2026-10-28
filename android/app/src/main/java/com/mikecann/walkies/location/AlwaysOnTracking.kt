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

enum class WalkState { None, Pending, Walking }

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
        // Out past the fence, even if the fence itself hasn't said so yet.
        if (center != null && center.distance(point.coordinate) > StationaryFence.RADIUS) wake()
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
        if (motion.transition(activity, entered)) wake()
        apply()
    }

    /** You've left where you settled. */
    fun leftFence() {
        wake()
        apply()
    }

    private fun wake() {
        awakeUntil = clock() + WAKE_TIME
        fence.unsettle()
    }

    private fun settle(point: TrackPoint, time: Double) {
        val center = fence.add(point.coordinate, time, point.accuracy, stationary = motion.known && motion.still, walking = walk != WalkState.None)
            ?: return
        geofence.place(center, StationaryFence.RADIUS)
        onFenceMoved(center)
    }

    private fun removeFence() {
        val had = fence.center != null
        fence.reset()
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
        ): GpsMode = when {
            // The you-are-here dot, and walks you started yourself.
            onScreen || walk == WalkState.Walking -> GpsMode.High
            !alwaysOn -> GpsMode.Off
            // Not in a car or on a bike: every fix on the road is outside the fence and
            // wakes it again, which kept the GPS flat out for whole drives.
            awake && !onWheels -> GpsMode.High
            // Sitting still: the motion chip says when you're off again. A pending walk
            // ends by itself after the gap.
            motionKnown && still -> GpsMode.Off
            walk == WalkState.Pending -> GpsMode.High
            // Bikes and cars don't count, but notice when you get out.
            onWheels -> GpsMode.Low
            // Without the motion chip, keep a light watch rather than rely on the fence alone.
            settled -> if (motionKnown) GpsMode.Off else GpsMode.Low
            else -> GpsMode.High
        }
    }
}
