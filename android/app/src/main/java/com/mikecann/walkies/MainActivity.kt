package com.mikecann.walkies

import android.Manifest
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mikecann.walkies.location.Permissions
import com.mikecann.walkies.ui.MapScreen
import com.mikecann.walkies.ui.SettingsSheet
import com.mikecann.walkies.ui.SetupScreen

class MainActivity : ComponentActivity() {
    private val app get() = application as WalkiesApplication

    private enum class Screen { Map, FirstRun, FixPermissions, Settings }

    private var screen by mutableStateOf(Screen.Map)
    /** Bumps whenever permissions might have changed, so the warnings check again. */
    private var permissionsRevision by mutableIntStateOf(0)

    private val permission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        app.tracker.permissionAnswered()
        permissionsRevision++
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Dark status bar icons over the cream fade at the top of the map.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        if (!app.prefs.setupDone) screen = Screen.FirstRun
        applyLaunchOptions(intent)
        app.tracker.askForPermission = ::askForLocation
        setContent {
            @Suppress("UNUSED_EXPRESSION") permissionsRevision
            when (screen) {
                Screen.FirstRun, Screen.FixPermissions -> SetupScreen(
                    firstRun = screen == Screen.FirstRun,
                    onLocationAnswered = { app.tracker.permissionAnswered() },
                    onDone = ::finishSetup,
                )
                Screen.Settings -> {
                    BackHandler { screen = Screen.Map }
                    SettingsSheet(
                        alwaysOn = app.model.alwaysOn,
                        onAlwaysOn = {
                            app.model.alwaysOn = it
                            permissionsRevision++
                        },
                        permissionsMissing = Permissions.anythingMissing(this),
                        onFixPermissions = { screen = Screen.FixPermissions },
                        onClose = { screen = Screen.Map },
                    )
                }
                Screen.Map -> MapScreen(
                    app.model,
                    app.tracker,
                    alwaysOnWarning = alwaysOnWarning(),
                    onOpenSettings = ::openSettings,
                    onShowSettings = { screen = Screen.Settings },
                    onFixPermissions = { screen = Screen.FixPermissions },
                )
            }
            if (screen == Screen.FixPermissions) BackHandler { finishSetup() }
        }
    }

    /** Like the iPhone's, short: why walks won't be noticed with the app closed. */
    private fun alwaysOnWarning(): String? = when {
        !app.model.alwaysOn || !Permissions.location(this) -> null
        !Permissions.backgroundLocation(this) -> "Walkies can't notice walks while it's closed."
        !Permissions.activity(this) -> "Walkies can't tell walking from driving yet."
        else -> null
    }

    private fun finishSetup() {
        if (screen == Screen.FirstRun) {
            app.prefs.setupDone = true
            app.model.alwaysOn = true
        }
        screen = Screen.Map
        permissionsRevision++
        app.refreshTracking()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        applyLaunchOptions(intent)
    }

    override fun onStart() {
        super.onStart()
        // Location may have been allowed in Settings meanwhile.
        app.model.authorizationChanged()
        app.model.finishStaleAutoWalk()
        app.tracker.request()
        app.onScreen = true
    }

    override fun onResume() {
        super.onResume()
        permissionsRevision++
    }

    override fun onStop() {
        // The foreground service keeps recording, if there's anything to record.
        app.onScreen = false
        app.model.saveNow(waiting = true)
        super.onStop()
    }

    override fun onDestroy() {
        if (app.tracker.askForPermission == this::askForLocation) app.tracker.askForPermission = null
        super.onDestroy()
    }

    private fun askForLocation() {
        val asked = app.tracker.authorization != LocationAccess.Authorization.NotDetermined
        if (!asked || shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)) {
            permission.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        } else {
            openSettings()
        }
    }

    private fun openSettings() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
    }

    /**
     * Testing switches, like the iPhone's launch arguments:
     * `adb shell am start -n com.mikecann.walkies/.MainActivity --ez setupDone true --ez alwaysOn false --es autoWalkGap 60`
     */
    private fun applyLaunchOptions(intent: Intent?) {
        intent ?: return
        if (intent.hasExtra("autoWalkGap")) {
            val seconds = intent.getStringExtra("autoWalkGap")?.toDoubleOrNull()
                ?: intent.getIntExtra("autoWalkGap", 0).toDouble()
            app.prefs.autoWalkGap = seconds
        }
        if (intent.hasExtra("setupDone")) {
            app.prefs.setupDone = intent.getBooleanExtra("setupDone", true)
            if (app.prefs.setupDone && screen == Screen.FirstRun) screen = Screen.Map
        }
        if (intent.hasExtra("alwaysOn")) app.model.alwaysOn = intent.getBooleanExtra("alwaysOn", true)
    }
}
