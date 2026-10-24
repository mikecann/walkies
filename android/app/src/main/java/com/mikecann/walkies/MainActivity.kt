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
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import androidx.compose.ui.Modifier
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
import com.mikecann.walkies.ui.AppNavigation
import com.mikecann.walkies.ui.AppTab
import com.mikecann.walkies.ui.ProgressPage
import com.mikecann.walkies.ui.ProgressSection
import com.mikecann.walkies.ui.SettingsPage
import com.mikecann.walkies.ui.LocalTabBarClearance
import com.mikecann.walkies.ui.tabBarBottomGap
import com.mikecann.walkies.ui.TabBar
import com.mikecann.walkies.ui.Walkies
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

    /** The tabs, or something full-screen over them: the setup, or your places. */
    private enum class Screen { Tabs, FirstRun, FixPermissions, Places, AddPlace }

    private var screen by mutableStateOf(Screen.Tabs)
    private val navigation = AppNavigation()
    /** The walk open in the Walks tab. */
    private var walkDetail by mutableStateOf<UUID?>(null)
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
            if (!app.account.isSignedIn) screen = Screen.Tabs
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
            Screen.Places -> {
                BackHandler { screen = Screen.Tabs }
                PlacesScreen(app.model, onAddPlace = { screen = Screen.AddPlace }, onClose = { screen = Screen.Tabs })
            }
            Screen.AddPlace -> {
                BackHandler { screen = Screen.Places }
                AddPlaceScreen(app.model, app.scope, onAdded = { screen = Screen.Tabs }, onBack = { screen = Screen.Places })
            }
            Screen.Tabs -> Tabs()
        }
        if (screen == Screen.FixPermissions) BackHandler { finishSetup() }

        // The celebration plays over whichever tab's showing, as the iPhone's cover does.
        val recap = app.model.recap
        val celebrating = recap != null && screen == Screen.Tabs
        if (recap != null && celebrating) {
            key(recap.id, recap.isRewatch) {
                val model = app.model
                val others = remember { model.cities.filter { city -> recap.after.none { it.id == city.id } } }
                val equipped = model.equipped
                CelebrationScreen(
                    recap, others,
                    style = equipped.celebration, clouds = equipped.clouds,
                    endingXP = model.xp, hasReward = model.pendingPicks.isNotEmpty(),
                    // Over to the progress tab's rewards, with the map under it when you come back.
                    onReward = {
                        navigation.showProgress(ProgressSection.Level)
                        model.dismissRecap()
                    },
                    onSecret = { openSecret = it },
                    onDone = model::dismissRecap,
                )
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

    /**
     * The pages, with the tab bar along the bottom. The map stays underneath the others,
     * so it doesn't load again or lose its place; each page keeps its scroll position.
     */
    @androidx.compose.runtime.Composable
    private fun Tabs() {
        val tab = navigation.tab
        val pages = rememberSaveableStateHolder()
        // Back from another tab goes to the map; from a walk, back to the list.
        if (tab == AppTab.Walks && walkDetail != null) BackHandler { walkDetail = null }
        else if (tab != AppTab.Map) BackHandler { navigation.showMap() }

        val bottomGap = tabBarBottomGap()
        val clearance = bottomGap + 96.dp + 8.dp
        CompositionLocalProvider(LocalTabBarClearance provides clearance) {
            Box(Modifier.fillMaxSize().background(Walkies.cream)) {
                MapScreen(
                    app.model,
                    app.tracker,
                    liveSteps = app.steps.live,
                    alwaysOnWarning = alwaysOnWarning(),
                    name = app.account.displayName,
                    picture = app.account.picture,
                    scope = app.scope,
                    active = tab == AppTab.Map,
                    covered = openSecret != null,
                    onOpenSettings = ::openSettings,
                    onShowPlaces = { screen = Screen.Places },
                    onFixPermissions = { screen = Screen.FixPermissions },
                    onShowSecrets = { navigation.tab = AppTab.Secrets },
                    onShowProgress = { navigation.showProgress(ProgressSection.Level) },
                    onOpenSecret = { openSecret = it },
                )
                if (tab != AppTab.Map) {
                    // Taps on the page stop here rather than reaching the map underneath.
                    Box(Modifier.fillMaxSize().clickable(remember { MutableInteractionSource() }, indication = null) {}) {
                        val page = if (tab == AppTab.Walks && walkDetail != null) "walk" else tab.name
                        pages.SaveableStateProvider(page) { Page(tab) }
                    }
                }
                Box(Modifier.align(Alignment.BottomCenter).padding(bottom = bottomGap)) {
                    TabBar(tab, rewards = app.model.pendingPicks.size) { navigation.tab = it }
                }
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun Page(tab: AppTab) {
        when (tab) {
            AppTab.Map -> {}
            AppTab.Secrets -> SecretsBookScreen(app.model, onOpen = { openSecret = it })
            AppTab.Progress -> ProgressPage(app.model, navigation.progressSection, onSection = { navigation.progressSection = it })
            AppTab.Walks -> {
                val id = walkDetail
                if (id == null) {
                    WalkHistoryScreen(app.model, app.steps.today, app.steps::refreshToday, onOpen = { walkDetail = it.id })
                } else {
                    WalkDetailScreen(
                        app.model, id,
                        // Plays over the map, so go there first, as on the iPhone.
                        onWatch = {
                            navigation.showMap()
                            app.model.replay(it)
                        },
                        onOpenSecret = { openSecret = it },
                        onBack = { walkDetail = null },
                    )
                }
            }
            AppTab.Settings -> {
                @Suppress("UNUSED_VARIABLE") val syncRevision = rememberRevision(app.sync::listen)
                val sync = app.sync
                SettingsPage(
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
                        screen = Screen.Tabs
                        navigation.showMap()
                        app.signOut()
                    },
                    countSteps = app.model.countSteps,
                    onCountSteps = { app.model.countSteps = it; app.steps.refreshToday() },
                    motionDenied = !Permissions.activity(this),
                    alwaysOn = app.model.alwaysOn,
                    onAlwaysOn = {
                        app.model.alwaysOn = it
                        permissionsRevision++
                    },
                    locationWarning = app.model.alwaysOn && !Permissions.backgroundLocation(this),
                    onOpenSettings = ::openSettings,
                    permissionsMissing = Permissions.anythingMissing(this),
                    onFixPermissions = { screen = Screen.FixPermissions },
                )
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
        screen = Screen.Tabs
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
        // Looks at where you are now you're here, and stops once you've gone.
        app.model.foreground(true)
        app.model.refreshNeighbours()
        // Catches up on walks that ended with the app closed.
        app.model.addPlacesYouveBeen()
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
        app.refreshTracking()
        app.steps.refreshToday()
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
        app.model.foreground(false)
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
     * `--es mistDays 0.001` mists walked tiles after a minute and a half rather than 60 days (`--es mistDays 0` puts it back).
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
        if (intent.hasExtra("mistDays")) {
            val days = intent.getStringExtra("mistDays")?.toDoubleOrNull()
                ?: intent.getIntExtra("mistDays", 0).toDouble()
            app.prefs.mistDays = days
        }
        if (intent.hasExtra("setupDone")) {
            app.prefs.setupDone = intent.getBooleanExtra("setupDone", true)
            if (app.prefs.setupDone && screen == Screen.FirstRun) screen = Screen.Tabs
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
