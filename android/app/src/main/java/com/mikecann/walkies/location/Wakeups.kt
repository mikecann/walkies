package com.mikecann.walkies.location

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.Geofence as PlayGeofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.mikecann.walkies.WalkiesApplication
import com.mikecann.walkies.grid.Coordinate

private const val TAG = "Wakeups"
private const val ACTION_FENCE = "com.mikecann.walkies.FENCE"
private const val ACTION_MOTION = "com.mikecann.walkies.MOTION"

private fun wakeIntent(context: Context, action: String, code: Int): PendingIntent =
    PendingIntent.getBroadcast(
        context, code,
        Intent(context, WakeReceiver::class.java).setAction(action),
        // Mutable: Play services fills in the event.
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

/**
 * The stationary fence through the Geofencing API (MonitorFence in StationaryFence.swift).
 * Play services watches it with the app closed, and wakes [WakeReceiver] on the way out.
 * Fences don't survive a reboot or an update, so it's placed again at launch.
 */
class AndroidGeofence(private val context: Context) : Geofence {
    private val client = LocationServices.getGeofencingClient(context)
    private val intent get() = wakeIntent(context, ACTION_FENCE, 1)

    @SuppressLint("MissingPermission")
    override fun place(center: Coordinate, radius: Double) {
        if (!Permissions.backgroundLocation(context)) return
        val fence = PlayGeofence.Builder()
            .setRequestId(ID)
            .setCircularRegion(center.lat, center.lon, radius.toFloat())
            .setExpirationDuration(PlayGeofence.NEVER_EXPIRE)
            .setTransitionTypes(PlayGeofence.GEOFENCE_TRANSITION_EXIT)
            .build()
        val request = GeofencingRequest.Builder()
            // You're inside it already: only leaving counts.
            .setInitialTrigger(0)
            .addGeofence(fence)
            .build()
        // Adding with the same id replaces the old one.
        client.addGeofences(request, intent)
            .addOnSuccessListener { Log.i(TAG, "Fence placed at ${center.lat},${center.lon}") }
            .addOnFailureListener { Log.e(TAG, "Couldn't place the fence", it) }
    }

    override fun remove() {
        client.removeGeofences(listOf(ID))
    }

    companion object {
        private const val ID = "here"
    }
}

/** Activity Recognition transitions, which wake [WakeReceiver] even with the app closed. */
class ActivityTransitions(private val context: Context) {
    private val client = ActivityRecognition.getClient(context)
    private val intent get() = wakeIntent(context, ACTION_MOTION, 2)
    private var registered = false

    @SuppressLint("MissingPermission")
    fun start() {
        if (registered || !Permissions.activity(context)) return
        registered = true
        // ON_FOOT isn't offered as a transition; walking and running cover it.
        val types = listOf(
            DetectedActivity.WALKING, DetectedActivity.RUNNING, DetectedActivity.ON_BICYCLE,
            DetectedActivity.IN_VEHICLE, DetectedActivity.STILL,
        )
        val transitions = types.flatMap { type ->
            listOf(ActivityTransition.ACTIVITY_TRANSITION_ENTER, ActivityTransition.ACTIVITY_TRANSITION_EXIT).map {
                ActivityTransition.Builder().setActivityType(type).setActivityTransition(it).build()
            }
        }
        client.requestActivityTransitionUpdates(ActivityTransitionRequest(transitions), intent)
            .addOnFailureListener {
                registered = false
                Log.e(TAG, "Couldn't start Activity Recognition", it)
            }
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        if (!registered) return
        registered = false
        if (Permissions.activity(context)) client.removeActivityTransitionUpdates(intent)
    }

    companion object {
        fun activity(type: Int): MotionActivity? = when (type) {
            DetectedActivity.WALKING -> MotionActivity.Walking
            DetectedActivity.RUNNING -> MotionActivity.Running
            DetectedActivity.ON_FOOT -> MotionActivity.OnFoot
            DetectedActivity.IN_VEHICLE -> MotionActivity.InVehicle
            DetectedActivity.ON_BICYCLE -> MotionActivity.OnBicycle
            DetectedActivity.STILL -> MotionActivity.Still
            else -> null
        }
    }
}

/**
 * Leaving the fence, and activity transitions. Either one is allowed to start a
 * location foreground service from the background, as long as there's background
 * location permission.
 */
class WakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as WalkiesApplication
        when (intent.action) {
            ACTION_FENCE -> {
                val event = GeofencingEvent.fromIntent(intent) ?: return
                if (event.hasError()) {
                    Log.e(TAG, "Fence error ${event.errorCode}")
                    return
                }
                if (event.geofenceTransition == PlayGeofence.GEOFENCE_TRANSITION_EXIT) {
                    Log.i(TAG, "Left the fence")
                    app.leftFence()
                }
            }
            ACTION_MOTION -> {
                if (!ActivityTransitionResult.hasResult(intent)) return
                val result = ActivityTransitionResult.extractResult(intent) ?: return
                for (event in result.transitionEvents) {
                    val activity = ActivityTransitions.activity(event.activityType) ?: continue
                    val entered = event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
                    Log.i(TAG, "${if (entered) "Started" else "Stopped"} $activity")
                    app.motionChanged(activity, entered)
                }
            }
        }
    }
}

/**
 * After a reboot or an update, nothing's registered any more. Starting the process is
 * enough: [WalkiesApplication] puts the service, Activity Recognition and the fence back.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "Woke for ${intent.action}")
        (context.applicationContext as WalkiesApplication).refreshTracking()
    }
}
