package com.mikecann.walkies.location

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat

/** What Walkies has been allowed to do, checked fresh each time. */
object Permissions {
    private fun has(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    fun location(context: Context) =
        has(context, Manifest.permission.ACCESS_FINE_LOCATION) || has(context, Manifest.permission.ACCESS_COARSE_LOCATION)

    /** "Allow all the time". */
    fun backgroundLocation(context: Context) =
        location(context) && has(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    /** Physical activity, for telling walking from cycling or driving. */
    fun activity(context: Context) = has(context, Manifest.permission.ACTIVITY_RECOGNITION)

    fun notifications(context: Context) =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || has(context, Manifest.permission.POST_NOTIFICATIONS)

    fun batteryUnrestricted(context: Context) =
        context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true

    /** Always on can't notice walks with the app closed without these. */
    fun missingForAlwaysOn(context: Context) = !backgroundLocation(context) || !activity(context)

    /** Anything the setup asks for that's missing, notifications aside: those are optional. */
    fun anythingMissing(context: Context) = missingForAlwaysOn(context) || !batteryUnrestricted(context)

    val isSamsung get() = Build.MANUFACTURER.equals("samsung", ignoreCase = true)
}
