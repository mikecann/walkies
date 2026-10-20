package com.mikecann.walkies

import android.Manifest
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mikecann.walkies.auth.SignInCallback
import com.mikecann.walkies.auth.TestSignIn
import com.mikecann.walkies.auth.signInMessage
import com.mikecann.walkies.location.Permissions
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.ui.AccountRows
import com.mikecann.walkies.ui.CelebrationScreen
import com.mikecann.walkies.ui.LoreCard
import com.mikecann.walkies.ui.SecretsBookScreen
import com.mikecann.walkies.ui.WalkDetailScreen
import com.mikecann.walkies.ui.WalkHistoryScreen
import com.mikecann.walkies.ui.AddPlaceScreen
import com.mikecann.walkies.ui.MapScreen
import com.mikecann.walkies.ui.PlacesScreen
import com.mikecann.walkies.ui.ProgressSection
import com.mikecann.walkies.ui.ProgressionSheet
import com.mikecann.walkies.ui.SettingsSheet
import com.mikecann.walkies.ui.SetupScreen
import com.mikecann.walkies.ui.SignInProvider
import com.mikecann.walkies.ui.SignInScreen
import com.mikecann.walkies.ui.rememberRevision
import com.mikecann.walkies.ui.syncText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.UUID

class MainActivity : ComponentActivity() {
    private val app get() = application as WalkiesApplication

    private enum class Screen { Map, FirstRun, FixPermissions, Settings, Places, AddPlace, Secrets, History, WalkDetail }

    private var screen by mutableStateOf(Screen.Map)
    /** The walk open in walk history. */
    private var walkDetail by mutableStateOf<UUID?>(null)
    /** The progression sheet, and where it opened, while it's up. */
    private var progress by mutableStateOf<ProgressSection?>(null)
    /** Opened from the celebration's "Level up", so it sits over the celebration. */
    private var progressOverCelebration = false
    /** A secret being read again: from a pin, the book, a past walk or the celebration. */
    private var openSecret by mutableStateOf<LoreEntry?>(null)
    /** Bumps whenever permissions might have changed, so the warnings check again. */
    private var permissionsRevision by mutableIntStateOf(0)
    /** The sign-in under way, for its spinner, and what went wrong with the last one. */
    private var signingIn by mutableStateOf<SignInProvider?>(null)
    private var signInError by mutableStateOf<String?>(null)
    /** True from the moment Google's sign-in comes back until it's finished. */
    private var completingSignIn = false
    /** Test sign-in from a launch extra, once a launch, so signing out doesn't sign straight back in. */
    private var testSignInRequested = false
    private var testUserName: String? = null
    private var periodicSync: Job? = null
    private val handler = Handler(Looper.getMainLooper())
    private var stopListening: (() -> Unit)? = null

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
        handleSignInCallback(intent)
        app.tracker.askForPermission = ::askForLocation
        stopListening = app.account.listen {
            // Signed in: the setup comes next if it hasn't been done (signing out undoes it).
            if (app.account.isSignedIn && !app.prefs.setupDone) screen = Screen.FirstRun
            if (!app.account.isSignedIn) screen = Screen.Map
        }
        setContent {
            @Suppress("UNUSED_EXPRESSION") permissionsRevision
            @Suppress("UNUSED_VARIABLE") val accountRevision = rememberRevision(app.account::listen)
            if (!app.account.isSignedIn) {
                SignInScreen(
                    working = signingIn,
                    errorMessage = signInError,
                    showTestSignIn = TestSignIn.AVAILABLE,
                    onGoogle = ::signInWithGoogle,
                    onTest = { signInForTesting(testUserName) },
                )
            } else {
                Screens()
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun Screens() {
        // None of these are Compose state, so read what says they've changed.
        @Suppress("UNUSED_EXPRESSION") permissionsRevision
        @Suppress("UNUSED_VARIABLE") val accountRevision = rememberRevision(app.account::listen)
        @Suppress("UNUSED_VARIABLE") val modelRevision = rememberRevision(app.model::listen)
        when (screen) {
            Screen.FirstRun, Screen.FixPermissions -> SetupScreen(
                firstRun = screen == Screen.FirstRun,
                onLocationAnswered = { app.tracker.permissionAnswered() },
                onDone = ::finishSetup,
            )
            Screen.Settings -> {
                BackHandler { screen = Screen.Map }
                @Suppress("UNUSED_VARIABLE") val syncRevision = rememberRevision(app.sync::listen)
                @Suppress("UNUSED_VARIABLE") val modelRevision = rememberRevision(app.model::listen)
                val sync = app.sync
                SettingsSheet(
                    account = AccountRows(
                        signedInAs = app.account.displayName ?: "you",
                        email = app.account.email,
                        sync = syncText(sync.status, sync.waiting, sync.lastSynced),
                        syncing = sync.status == com.mikecann.walkies.sync.SyncEngine.Status.Syncing,
                        waiting = sync.waiting,
                        walking = app.model.activeWalk != null,
                    ),
                    onSyncNow = { app.scope.launch { app.sync.sync() } },
                    onSignOut = {
                        screen = Screen.Map
                        app.signOut()
                    },
                    alwaysOn = app.model.alwaysOn,
                    onAlwaysOn = {
                        app.model.alwaysOn = it
                        permissionsRevision++
                    },
                    locationWarning = app.model.alwaysOn && !Permissions.backgroundLocation(this),
                    onOpenSettings = ::openSettings,
                    permissionsMissing = Permissions.anythingMissing(this),
                    onFixPermissions = { screen = Screen.FixPermissions },
                    walkCount = app.model.walks.size,
                    onShowHistory = { screen = Screen.History },
                    onClose = { screen = Screen.Map },
                )
            }
            Screen.History -> {
                BackHandler { screen = Screen.Settings }
                WalkHistoryScreen(
                    app.model,
                    onOpen = {
                        walkDetail = it.id
                        screen = Screen.WalkDetail
                    },
                    onBack = { screen = Screen.Settings },
                )
            }
            Screen.WalkDetail -> {
                BackHandler { screen = Screen.History }
                val id = walkDetail
                if (id == null) {
                    LaunchedEffect(Unit) { screen = Screen.History }
                } else {
                    WalkDetailScreen(
                        app.model, id,
                        // Rewatching closes Settings and plays over the map, as on the iPhone.
                        onWatch = {
                            app.model.replay(it)
                            screen = Screen.Map
                        },
                        onOpenSecret = { openSecret = it },
                        onBack = { screen = Screen.History },
                    )
                }
            }
            Screen.Secrets -> {
                BackHandler { screen = Screen.Map }
                SecretsBookScreen(app.model, onOpen = { openSecret = it }, onClose = { screen = Screen.Map })
            }
            Screen.Places -> {
                BackHandler { screen = Screen.Map }
                PlacesScreen(app.model, onAddPlace = { screen = Screen.AddPlace }, onClose = { screen = Screen.Map })
            }
            Screen.AddPlace -> {
                BackHandler { screen = Screen.Places }
                AddPlaceScreen(app.model, app.scope, onAdded = { screen = Screen.Map }, onBack = { screen = Screen.Places })
            }
            Screen.Map -> MapScreen(
                app.model,
                app.tracker,
                alwaysOnWarning = alwaysOnWarning(),
                name = app.account.displayName,
                picture = app.account.picture,
                scope = app.scope,
                onOpenSettings = ::openSettings,
                onShowSettings = { screen = Screen.Settings },
                onShowPlaces = { screen = Screen.Places },
                onFixPermissions = { screen = Screen.FixPermissions },
                onShowSecrets = { screen = Screen.Secrets },
                onShowProgress = {
                    progressOverCelebration = false
                    progress = ProgressSection.Level
                },
                onOpenSecret = { openSecret = it },
            )
        }
        if (screen == Screen.FixPermissions) BackHandler { finishSetup() }

        // The celebration plays over the map. One that's ready while another screen's
        // open, or the progression sheet, waits for you to come back to the map.
        val recap = app.model.recap
        val celebrating = recap != null && screen == Screen.Map && (progress == null || progressOverCelebration)
        if (recap != null && celebrating) {
            key(recap.id, recap.isRewatch) {
                val model = app.model
                val others = remember { model.cities.filter { city -> recap.after.none { it.id == city.id } } }
                val equipped = model.equipped
                CelebrationScreen(
                    recap, others,
                    style = equipped.celebration, clouds = equipped.clouds,
                    endingXP = model.xp, hasReward = model.pendingPicks.isNotEmpty(),
                    onReward = {
                        progressOverCelebration = true
                        progress = ProgressSection.Level
                    },
                    onSecret = { openSecret = it },
                    onDone = model::dismissRecap,
                )
            }
        }
        progress?.let { section ->
            if (screen == Screen.Map) {
                key(section) {
                    ProgressionSheet(app.model, section, onClose = {
                        progress = null
                        progressOverCelebration = false
                    })
                }
            }
        }

        val haptics = LocalHapticFeedback.current
        val queued = app.model.stickerQueue.size
        var lastQueued by remember { mutableIntStateOf(queued) }
        LaunchedEffect(queued) {
            if (queued > lastQueued) haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            lastQueued = queued
        }
        val reading = openSecret
        val fresh = app.model.stickerQueue.firstOrNull()
        when {
            reading != null -> key(reading.id) {
                LoreCard(reading, app.model.foundStickers[reading.id], onClose = { openSecret = null })
            }
            // Secrets just found pop up one at a time, but not over the celebration.
            fresh != null && !celebrating -> key("new-" + fresh.id) {
                LoreCard(fresh, app.model.foundStickers[fresh.id], isNew = true, onClose = app.model::popSticker)
            }
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
        setIntent(intent)
        applyLaunchOptions(intent)
        handleSignInCallback(intent)
    }

    // Signing in

    private fun signInWithGoogle() {
        signingIn = SignInProvider.Google
        signInError = null
        app.scope.launch {
            try {
                app.googleSignIn.start(this@MainActivity)
                // Carries on in handleSignInCallback, or onResume if the tab's closed.
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                signInFailed(e)
            }
        }
    }

    /** Google's sign-in coming back on walkies://signed-in?convexAuthCode=... */
    private fun handleSignInCallback(intent: Intent?) {
        val link = intent?.dataString ?: return
        if (!SignInCallback.matches(link)) return
        // Only once, even if the activity's recreated with the same intent.
        intent.data = null
        completingSignIn = true
        signingIn = SignInProvider.Google
        signInError = null
        app.scope.launch {
            try {
                app.googleSignIn.complete(link)
                signingIn = null
                app.signedIn()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                signInFailed(e)
            } finally {
                completingSignIn = false
            }
        }
    }

    private fun signInForTesting(name: String?) {
        if (!TestSignIn.AVAILABLE) return
        signingIn = SignInProvider.Test
        signInError = null
        app.scope.launch {
            try {
                TestSignIn.signIn(app.account, name)
                signingIn = null
                app.signedIn()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                signInFailed(e)
            }
        }
    }

    private fun signInFailed(e: Exception) {
        android.util.Log.e("Walkies", "Sign-in failed", e)
        signingIn = null
        signInError = signInMessage(e)
    }

    override fun onStart() {
        super.onStart()
        // Location may have been allowed in Settings meanwhile.
        app.model.authorizationChanged()
        app.model.finishStaleAutoWalk()
        app.tracker.request()
        app.onScreen = true
        app.model.placeYouOnNextFix = true
        app.model.refreshNeighbours()
        app.sync.schedule()
        // While you're looking, a sync every few minutes picks up the other phone's walks.
        periodicSync?.cancel()
        periodicSync = app.scope.launch {
            while (isActive) {
                delay(180_000)
                app.sync.sync()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        permissionsRevision++
        // Back from the Custom Tab without a sign-in: closed it, which needs no message.
        if (signingIn == SignInProvider.Google && !completingSignIn) {
            handler.postDelayed({
                if (signingIn == SignInProvider.Google && !completingSignIn) signingIn = null
            }, 1000)
        }
        if (testSignInRequested && !app.account.isSignedIn && signingIn == null) {
            testSignInRequested = false
            signInForTesting(testUserName)
        }
    }

    override fun onStop() {
        // The foreground service keeps recording, if there's anything to record.
        periodicSync?.cancel()
        periodicSync = null
        app.onScreen = false
        app.model.saveNow(waiting = true)
        super.onStop()
    }

    override fun onDestroy() {
        stopListening?.invoke()
        handler.removeCallbacksAndMessages(null)
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
     * Debug builds also take `--ez testSignIn true --es testUserName "Emu"`, a fresh
     * test account on the dev deployment.
     */
    private fun applyLaunchOptions(intent: Intent?) {
        intent ?: return
        if (TestSignIn.AVAILABLE && intent.getBooleanExtra("testSignIn", false)) {
            testUserName = intent.getStringExtra("testUserName")?.takeIf { !it.startsWith("-") }
            testSignInRequested = !app.account.isSignedIn
            intent.removeExtra("testSignIn")
        }
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
        // A secret's notification: it pops up anyway if it's still waiting to, otherwise open it.
        intent.getStringExtra(EXTRA_STICKER)?.let { id ->
            intent.removeExtra(EXTRA_STICKER)
            if (app.model.stickerQueue.none { it.id == id }) openSecret = LoreLibrary.entry(id)
        }
    }

    companion object {
        /** On a found secret's notification: which one. */
        const val EXTRA_STICKER = "sticker"
    }
}
