import Foundation
import Sentry

/// Crash and error reports to Sentry (org `mikec`, project `walkies`), read by Mike's
/// Sentry watcher. Only Release builds on a real phone start it: Debug builds, the
/// simulator and the tests never do, so the agents testing Walkies all day don't send
/// anything and every report is a real person's crash.
///
/// Errors and crashes only: no tracing, sessions, screenshots or network breadcrumbs.
/// Walkies is a location app, so nothing that could carry a coordinate leaves the
/// phone. Network breadcrumbs are off because OpenStreetMap URLs have the lat/lon in
/// them, and `scrubbed` blanks anything that looks like a coordinate as a backstop.
/// No user is set, and Sentry's own per-install ID is dropped too, so a report isn't
/// linked to anyone (the App Privacy label's Crash Data, not linked to you, not used
/// for tracking, and no Device ID).
nonisolated enum CrashReporting {
    static let dsn = "https://b264d3607772b3385f0cd8a14c4d1f7a@o4508736647266304.ingest.us.sentry.io/4512336956751872"

    static func start() {
        #if !DEBUG && !targetEnvironment(simulator)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "production"
            options.releaseName = "com.mikecann.walkies@\(version)+\(build)"
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            // Release health pings every launch; that's usage data, not crash data.
            options.enableAutoSessionTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            // Kept on: iOS killing the app for memory or a frozen main thread is a crash to us.
            options.enableWatchdogTerminationTracking = true
            // Off: a 2-second hang while the clouds bake isn't a crash, and would eat the quota.
            options.enableAppHangTracking = false
            options.beforeBreadcrumb = { crumb in
                crumb.message = crumb.message.map(scrubbed)
                crumb.data = crumb.data?.mapValues { ($0 as? String).map(scrubbed) ?? $0 }
                return crumb
            }
            options.beforeSend = { event in
                event.user = nil
                event.exceptions?.forEach { $0.value = $0.value.map(scrubbed) }
                if let message = event.message?.formatted { event.message = SentryMessage(formatted: scrubbed(message)) }
                event.breadcrumbs?.forEach { crumb in
                    crumb.message = crumb.message.map(scrubbed)
                    crumb.data = crumb.data?.mapValues { ($0 as? String).map(scrubbed) ?? $0 }
                }
                return event
            }
            options.initialScope = { scope in
                scope.setTag(value: "ios", key: "component")
                return scope
            }
        }
        #endif
    }

    /// Decimal degrees have four or more decimal places (`-33.6512`, `115.34567`), so
    /// any number like that is blanked. Times and counts in messages are left alone.
    static func scrubbed(_ text: String) -> String {
        text.replacing(#/-?\d{1,3}\.\d{4,}/#, with: "[coord]")
    }
}
