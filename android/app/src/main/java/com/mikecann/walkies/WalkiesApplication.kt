package com.mikecann.walkies

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.mikecann.walkies.auth.Account
import com.mikecann.walkies.auth.GoogleSignIn
import com.mikecann.walkies.auth.KeystoreVault
import com.mikecann.walkies.convex.Backend
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.location.ActivityMotion
import com.mikecann.walkies.location.ActivityTransitions
import com.mikecann.walkies.location.AlwaysOnTracking
import com.mikecann.walkies.location.AndroidGeofence
import com.mikecann.walkies.location.LocationTracker
import com.mikecann.walkies.location.MotionActivity
import com.mikecann.walkies.location.Permissions
import com.mikecann.walkies.location.TrackingService
import com.mikecann.walkies.location.WalkState
import com.mikecann.walkies.store.Store
import com.mikecann.walkies.sync.SyncEngine
import com.mikecann.walkies.sync.SyncPrefs
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import java.io.File

/**
 * Owns the model, the store and the GPS for the whole process, so the always-on
 * service can record walks with no activity on screen. A boot, a fence exit or an
 * activity transition starts the process, and [onCreate] picks everything back up,
 * including a walk that was going when the process was killed. It also owns the
 * account and sync (WalkiesApp.swift's AppDelegate).
 */
class WalkiesApplication : Application() {
    lateinit var model: AppModel
        private set
    lateinit var tracker: LocationTracker
        private set
    lateinit var prefs: Prefs
        private set
    lateinit var account: Account
        private set
    lateinit var sync: SyncEngine
        private set
    lateinit var googleSignIn: GoogleSignIn
        private set
    /** Main-thread work that outlives any one screen: sync, sign-in, adding places. */
    val scope = MainScope()
    private lateinit var motion: ActivityMotion
    private lateinit var tracking: AlwaysOnTracking
    private lateinit var transitions: ActivityTransitions

    /** Whether the map's showing. */
    var onScreen = false
        set(value) {
            field = value
            refreshTracking()
        }

    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            model.finishStaleAutoWalk()
            tracking.tick()
            handler.postDelayed(this, TICK_MILLIS)
        }
    }
    private var ticking = false

    override fun onCreate() {
        super.onCreate()
        tracker = LocationTracker(this)
        prefs = Prefs(this)
        motion = ActivityMotion()
        tracking = AlwaysOnTracking(tracker, AndroidGeofence(this), motion, ::now, prefs.fenceCenter)
        tracking.onFenceMoved = { prefs.fenceCenter = it }
        transitions = ActivityTransitions(this)
        account = Account(KeystoreVault(this), Backend(BuildConfig.CONVEX_CLOUD_URL, BuildConfig.CONVEX_SITE_URL))
        googleSignIn = GoogleSignIn(this, account)
        // Application Support/Walkies on the iPhone.
        val store = Store(File(filesDir, "Walkies"))
        model = AppModel(store, prefs, tracker, motion)
        model.services = scope
        model.makePlaceClient = { account.client() }
        sync = SyncEngine(
            model, store,
            isSignedIn = { account.isSignedIn },
            userId = { account.userId },
            makeClient = { account.client() },
            scope = scope,
            prefs = prefs,
        )
        model.requestSync = { sync.schedule() }
        tracker.onLocation = { fix ->
            model.record(fix)
            tracking.fix(fix)
        }
        tracker.onAuthorizationChange = {
            model.authorizationChanged()
            refreshTracking()
        }
        model.listen { refreshTracking() }
        refreshTracking()
        // Fences go on a reboot or an update, so put it back.
        tracking.restoreFence()
        if (account.isSignedIn) {
            model.refreshNeighbours()
            sync.schedule()
        }
    }

    /** Just signed in: sync, and offer the suburbs nearby. */
    fun signedIn() {
        sync.schedule()
        model.refreshNeighbours()
        scope.launch { account.refreshProfile() }
    }

    /** Sync stops first, so nothing from this account comes back after the wipe. */
    fun signOut() {
        scope.launch {
            sync.wipe()
            account.signOut()
            googleSignIn.forget()
            refreshTracking()
        }
    }

    /**
     * Brings the service, Activity Recognition and the GPS in line with always-on, any
     * walk going, the permissions and whether the map's showing. Cheap enough to call
     * whenever anything changes.
     */
    fun refreshTracking() {
        val located = Permissions.location(this)
        val alwaysOn = model.alwaysOn && located
        val walk = when {
            model.activeWalk == null -> WalkState.None
            model.autoWalkPending -> WalkState.Pending
            else -> WalkState.Walking
        }
        tracking.update(alwaysOn, onScreen, walk)

        if (alwaysOn) transitions.start() else transitions.stop()

        if (alwaysOn || (located && model.activeWalk != null)) {
            TrackingService.start(this, inBackground = !onScreen)
            TrackingService.update(this, model)
        } else {
            TrackingService.stop(this)
        }

        val tick = alwaysOn || model.activeWalk != null
        if (tick && !ticking) handler.postDelayed(this.tick, TICK_MILLIS)
        if (!tick && ticking) handler.removeCallbacks(this.tick)
        ticking = tick
    }

    fun leftFence() {
        tracking.leftFence()
        refreshTracking()
    }

    fun motionChanged(activity: MotionActivity, entered: Boolean) {
        tracking.motionChanged(activity, entered)
        refreshTracking()
    }

    private fun now() = System.currentTimeMillis() / 1000.0

    companion object {
        private const val TICK_MILLIS = 60_000L
    }
}

/** UserDefaults on the iPhone. */
class Prefs(context: Context) : Settings, SyncPrefs {
    private val prefs = context.getSharedPreferences("walkies", Context.MODE_PRIVATE)

    /** Off until the first-run setup switches it on, like the iPhone. */
    override var alwaysOn: Boolean
        get() = prefs.getBoolean("alwaysOn", false)
        set(value) = prefs.edit().putBoolean("alwaysOn", value).apply()

    override var autoWalkGap: Double
        get() = prefs.getFloat("autoWalkGap", 0f).toDouble()
        set(value) = prefs.edit().putFloat("autoWalkGap", value.toFloat()).apply()

    override var selectedCity: String?
        get() = prefs.getString("selectedCity", null)
        set(value) = prefs.edit().putString("selectedCity", value).apply()

    /** Whether the first-run setup (location, activity, notifications, battery, always on) is done. */
    override var setupDone: Boolean
        get() = prefs.getBoolean("setupDone", false)
        set(value) = prefs.edit().putBoolean("setupDone", value).apply()

    override var lastSynced: Double?
        get() = if (prefs.contains("lastSynced")) Double.fromBits(prefs.getLong("lastSynced", 0)) else null
        set(value) {
            if (value == null) prefs.edit().remove("lastSynced").apply()
            else prefs.edit().putLong("lastSynced", value.toRawBits()).apply()
        }

    /** Where the stationary fence is, so it can go back after a reboot. */
    var fenceCenter: Coordinate?
        get() {
            if (!prefs.contains("fenceLat")) return null
            return Coordinate(
                Double.fromBits(prefs.getLong("fenceLat", 0)),
                Double.fromBits(prefs.getLong("fenceLon", 0)),
            )
        }
        set(value) {
            val edit = prefs.edit()
            if (value == null) {
                edit.remove("fenceLat").remove("fenceLon")
            } else {
                edit.putLong("fenceLat", value.lat.toRawBits()).putLong("fenceLon", value.lon.toRawBits())
            }
            edit.apply()
        }
}
