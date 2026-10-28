package com.mikecann.walkies.location

import com.mikecann.walkies.grid.Coordinate

/**
 * Decides where the stationary fence goes (StationaryFence.swift). Always on keeps a
 * circle around wherever you've settled, so leaving it wakes tracking straight away,
 * even if the app's been killed.
 */
class StationaryFence(center: Coordinate? = null) {
    /** Where the fence is now, if there is one. */
    var center: Coordinate? = center
        private set
    /** The last fix settled you back inside the fence where it already is, so it didn't move. */
    var settledInPlace = false
        private set
    private var settlingPoint: Coordinate? = null
    private var settlingTime = 0.0

    /**
     * Returns where to put the fence when this fix means you've settled somewhere new.
     * [stationary]: the phone says you've stopped moving. [walking]: a walk is in
     * progress, so the first fix isn't necessarily where you'll stop.
     */
    fun add(point: Coordinate, time: Double, accuracy: Double, stationary: Boolean, walking: Boolean): Coordinate? {
        settledInPlace = false
        if (accuracy < 0 || accuracy > WORST_ACCURACY) return null
        val settling = settlingPoint
        if (settling == null || settling.distance(point) > SETTLE_RADIUS || time < settlingTime) {
            settlingPoint = point
            settlingTime = time
        }
        val stayed = time - settlingTime >= SETTLE_TIME
        if (!stationary && !stayed && !(center == null && !walking)) return null
        center?.let {
            if (it.distance(point) <= SETTLE_RADIUS) {
                settledInPlace = true
                return null
            }
        }
        center = point
        return point
    }

    /** You've stayed within [SETTLE_RADIUS] of one spot for [SETTLE_TIME], as of [now]. */
    fun settled(now: Double): Boolean = settlingPoint != null && now - settlingTime >= SETTLE_TIME

    /** You've moved off, so the clock on settling starts again. The fence stays put. */
    fun unsettle() {
        settlingPoint = null
    }

    fun reset() {
        center = null
        settlingPoint = null
    }

    companion object {
        const val RADIUS = 100.0
        /** Fixes within this of each other count as staying put. */
        const val SETTLE_RADIUS = 30.0
        /** Staying put this long (seconds) counts as settled, even if the phone doesn't say you're still. */
        const val SETTLE_TIME = 2 * 60.0
        /** Fixes vaguer than this, in metres, are no good for placing it. */
        const val WORST_ACCURACY = 50.0
    }
}

/** A circle Play services watches for us, even while the app isn't running. */
interface Geofence {
    fun place(center: Coordinate, radius: Double)
    fun remove()
}
