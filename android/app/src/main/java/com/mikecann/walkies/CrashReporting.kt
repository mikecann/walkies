package com.mikecann.walkies

import android.content.Context
import android.os.Build
import io.sentry.SentryOptions
import io.sentry.android.core.SentryAndroid

/**
 * Crash and error reports to Sentry (org `mikec`, project `walkies`), read by Mike's
 * Sentry watcher (CrashReporting.swift on the iPhone). Only release builds on a real
 * phone start it: debug builds, the emulator and the JVM tests never do, so the agents
 * testing Walkies all day don't send anything and every report is a real person's crash.
 * Auto-init is off in the manifest, so this is the only way it starts.
 *
 * Errors and crashes only: no tracing, sessions or screenshots. Walkies is a location
 * app, so nothing that could carry a coordinate leaves the phone: Walkies makes its
 * requests with HttpURLConnection, which Sentry doesn't record, and [scrubbed] blanks
 * anything that looks like a coordinate as a backstop. No user is set, and Sentry's own
 * per-install ID is dropped too, so a report isn't linked to anyone.
 */
object CrashReporting {
    private const val DSN = "https://b264d3607772b3385f0cd8a14c4d1f7a@o4508736647266304.ingest.us.sentry.io/4512336956751872"

    // isSendDefaultPii is deprecated in favour of dataCollection, but false is still what it says.
    @Suppress("DEPRECATION")
    fun start(context: Context) {
        if (BuildConfig.DEBUG || isEmulator) return
        SentryAndroid.init(context) { options ->
            options.dsn = DSN
            options.environment = "production"
            options.release = "com.mikecann.walkies@${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}"
            options.isSendDefaultPii = false
            options.tracesSampleRate = null
            options.isEnableAutoActivityLifecycleTracing = false
            // Release health pings every launch; that's usage data, not crash data.
            options.isEnableAutoSessionTracking = false
            options.isAttachScreenshot = false
            options.isAttachViewHierarchy = false
            options.setTag("component", "android")
            options.beforeBreadcrumb = SentryOptions.BeforeBreadcrumbCallback { crumb, _ ->
                crumb.message = crumb.message?.let(::scrubbed)
                for ((key, value) in crumb.data.toMap()) if (value is String) crumb.setData(key, scrubbed(value))
                crumb
            }
            options.beforeSend = SentryOptions.BeforeSendCallback { event, _ ->
                event.user = null
                event.exceptions?.forEach { it.value = it.value?.let(::scrubbed) }
                event.message?.let { it.formatted = it.formatted?.let(::scrubbed) }
                event.breadcrumbs?.forEach { crumb ->
                    crumb.message = crumb.message?.let(::scrubbed)
                    for ((key, value) in crumb.data.toMap()) if (value is String) crumb.setData(key, scrubbed(value))
                }
                event
            }
        }
    }

    private val isEmulator: Boolean
        get() = Build.FINGERPRINT.startsWith("generic") || Build.HARDWARE in setOf("goldfish", "ranchu") ||
            Build.PRODUCT.contains("sdk")

    /** Decimal degrees have four or more decimal places (`-33.6512`, `115.34567`), so any
     *  number like that is blanked. Times and counts in messages are left alone. */
    private val coordinate = Regex("""-?\d{1,3}\.\d{4,}""")

    fun scrubbed(text: String): String = text.replace(coordinate, "[coord]")
}
