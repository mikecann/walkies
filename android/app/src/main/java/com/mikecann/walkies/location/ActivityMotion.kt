package com.mikecann.walkies.location

import com.mikecann.walkies.Motion

/** Activity Recognition's activities, as plain Kotlin so the mapping can be tested. */
enum class MotionActivity { Walking, Running, OnFoot, InVehicle, OnBicycle, Still }

/**
 * Whether you're on foot, on wheels or still, from Activity Recognition transitions
 * (MotionMonitor.swift's job on the iPhone). Transitions are already high confidence,
 * so there's no low-confidence case to skip.
 */
class ActivityMotion : Motion {
    override var onWheels = false
        private set
    override var still = false
        private set
    /** Whether any transition has arrived since the process started. */
    var known = false
        private set

    /** Returns true when this means you've started moving. */
    fun transition(activity: MotionActivity, entered: Boolean): Boolean {
        known = true
        if (!entered) {
            // Leaving the other activities comes paired with entering the next one.
            if (activity != MotionActivity.Still || !still) return false
            still = false
            return true
        }
        when (activity) {
            MotionActivity.Walking, MotionActivity.Running, MotionActivity.OnFoot -> onWheels = false
            MotionActivity.InVehicle, MotionActivity.OnBicycle -> onWheels = true
            // Keep onWheels: sitting at the lights is still driving.
            MotionActivity.Still -> {
                still = true
                return false
            }
        }
        still = false
        return true
    }
}
