package com.mikecann.walkies.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.mikecann.walkies.LocationAccess
import com.mikecann.walkies.model.TrackPoint

/**
 * GPS for walks, from the fused location provider (LocationTracker.swift). For now it
 * runs while the app's on screen; stage 3 keeps it going from a foreground service.
 */
class LocationTracker(private val context: Context) : LocationAccess {
    var onLocation: ((TrackPoint) -> Unit)? = null
    var onAuthorizationChange: (() -> Unit)? = null
    /** Set by the activity, which owns the permission prompt. */
    var askForPermission: (() -> Unit)? = null

    private val client = LocationServices.getFusedLocationProviderClient(context)
    private val prefs = context.getSharedPreferences("walkies", Context.MODE_PRIVATE)
    private var running = false

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            for (location in result.locations) onLocation?.invoke(location.trackPoint())
        }
    }

    override val authorization: LocationAccess.Authorization
        get() = when {
            granted -> LocationAccess.Authorization.Allowed
            prefs.getBoolean(ASKED, false) -> LocationAccess.Authorization.Denied
            else -> LocationAccess.Authorization.NotDetermined
        }

    val isDenied get() = authorization == LocationAccess.Authorization.Denied

    private val granted: Boolean
        get() = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    override fun requestPermission() {
        askForPermission?.invoke()
    }

    /** The prompt's been answered, either way. */
    fun permissionAnswered() {
        prefs.edit().putBoolean(ASKED, true).apply()
        onAuthorizationChange?.invoke()
        if (running) {
            running = false
            start()
        }
    }

    /** Best accuracy, every 5 m like the iPhone's distance filter. */
    @SuppressLint("MissingPermission")
    fun start() {
        if (running) return
        running = true
        if (!granted) return
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(500L)
            .setMinUpdateDistanceMeters(5f)
            .build()
        client.requestLocationUpdates(request, callback, Looper.getMainLooper())
            .addOnFailureListener { Log.e(TAG, "Couldn't start location updates", it) }
    }

    fun stop() {
        running = false
        client.removeLocationUpdates(callback)
    }

    companion object {
        private const val TAG = "LocationTracker"
        private const val ASKED = "askedForLocation"
    }
}

fun Location.trackPoint() = TrackPoint(
    lat = latitude,
    lon = longitude,
    time = time / 1000.0,
    accuracy = if (hasAccuracy()) accuracy.toDouble() else -1.0,
    speed = if (hasSpeed() && speed >= 0) speed.toDouble() else null,
)
