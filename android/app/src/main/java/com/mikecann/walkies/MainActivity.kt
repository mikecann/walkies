package com.mikecann.walkies

import android.Manifest
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import com.mikecann.walkies.ui.MapScreen

class MainActivity : ComponentActivity() {
    private val app get() = application as WalkiesApplication

    private val permission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        app.tracker.permissionAnswered()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Dark status bar icons over the cream fade at the top of the map.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        applyLaunchOptions(intent)
        app.tracker.askForPermission = ::askForLocation
        // The first-run setup comes in stage 3. Until then, ask straight away.
        if (app.tracker.authorization == LocationAccess.Authorization.NotDetermined) askForLocation()
        setContent { MapScreen(app.model, app.tracker, onOpenSettings = ::openSettings) }
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
        app.tracker.start()
    }

    override fun onStop() {
        // Stage 3's foreground service keeps recording once the app's closed.
        app.tracker.stop()
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
     * `adb shell am start -n com.mikecann.walkies/.MainActivity --ez alwaysOn false --es autoWalkGap 60`
     */
    private fun applyLaunchOptions(intent: Intent?) {
        intent ?: return
        if (intent.hasExtra("autoWalkGap")) {
            val seconds = intent.getStringExtra("autoWalkGap")?.toDoubleOrNull()
                ?: intent.getIntExtra("autoWalkGap", 0).toDouble()
            app.prefs.autoWalkGap = seconds
        }
        if (intent.hasExtra("alwaysOn")) app.model.alwaysOn = intent.getBooleanExtra("alwaysOn", true)
    }
}
