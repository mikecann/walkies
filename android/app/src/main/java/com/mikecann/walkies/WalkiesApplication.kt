package com.mikecann.walkies

import android.app.Application
import android.content.Context
import com.mikecann.walkies.location.LocationTracker
import com.mikecann.walkies.store.Store
import java.io.File

/**
 * Owns the model, the store and the GPS for the whole process, so the always-on
 * service in stage 3 can record walks with no activity on screen.
 */
class WalkiesApplication : Application() {
    lateinit var model: AppModel
        private set
    lateinit var tracker: LocationTracker
        private set
    lateinit var prefs: Prefs
        private set

    override fun onCreate() {
        super.onCreate()
        tracker = LocationTracker(this)
        prefs = Prefs(this)
        // Application Support/Walkies on the iPhone.
        model = AppModel(Store(File(filesDir, "Walkies")), prefs, tracker)
        tracker.onLocation = model::record
        tracker.onAuthorizationChange = model::authorizationChanged
    }
}

/** UserDefaults on the iPhone. */
class Prefs(context: Context) : Settings {
    private val prefs = context.getSharedPreferences("walkies", Context.MODE_PRIVATE)

    /** On by default until the setup in stage 3 asks: walks just get picked up while the app's open. */
    override var alwaysOn: Boolean
        get() = prefs.getBoolean("alwaysOn", true)
        set(value) = prefs.edit().putBoolean("alwaysOn", value).apply()

    override var autoWalkGap: Double
        get() = prefs.getFloat("autoWalkGap", 0f).toDouble()
        set(value) = prefs.edit().putFloat("autoWalkGap", value.toFloat()).apply()

    override var selectedCity: String?
        get() = prefs.getString("selectedCity", null)
        set(value) = prefs.edit().putString("selectedCity", value).apply()
}
