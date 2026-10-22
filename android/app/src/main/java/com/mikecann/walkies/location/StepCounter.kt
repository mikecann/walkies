package com.mikecann.walkies.location

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.fitness.FitnessLocal
import com.google.android.gms.fitness.LocalRecordingClient
import com.google.android.gms.fitness.data.LocalDataType
import com.google.android.gms.fitness.data.LocalField
import com.google.android.gms.fitness.request.LocalDataReadRequest
import com.google.android.gms.tasks.Task
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.Walk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/** Play services keeps the low-power subscription running even when Walkies is closed. */
class StepCounter(private val context: Context, private val scope: CoroutineScope) {
    var live: Int? by mutableStateOf(null)
        private set
    var today: Int? by mutableStateOf(null)
        private set
    private val prefs = context.getSharedPreferences("walkies", Context.MODE_PRIVATE)
    private var recordingSince: Long? = prefs.getLong("stepRecordingSince", 0).takeIf { it > 0 }
    private var enabled = false
    private var permitted = false
    private var subscribed = false
    private var revision = 0
    private var todayRequest = 0
    private var liveRequest = 0
    private var liveWalk: java.util.UUID? = null
    private val subscription = Mutex()
    private val client by lazy { FitnessLocal.getLocalRecordingClient(context) }

    private fun available(): Boolean = Permissions.activity(context) &&
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(
            context, LocalRecordingClient.LOCAL_RECORDING_CLIENT_MIN_VERSION_CODE,
        ) == ConnectionResult.SUCCESS &&
        (context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager)
            ?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null

    /** Serialise subscription changes so a quick off/on can't leave recording off. */
    fun configure(countSteps: Boolean) {
        val access = available()
        if (enabled == countSteps && permitted == access) return
        enabled = countSteps
        permitted = access
        revision++
        todayRequest++
        liveRequest++
        live = null
        today = null
        if (!countSteps || !access) {
            recordingSince = null
            prefs.edit().remove("stepRecordingSince").apply()
        }
        scope.launch {
            subscription.withLock {
                if (enabled && permitted) {
                    subscribed = subscribe()
                } else {
                    runCatching { client.unsubscribe(LocalDataType.TYPE_STEP_COUNT_DELTA).succeeded() }
                    subscribed = false
                }
            }
        }
    }

    private suspend fun subscribe(): Boolean {
        val success = runCatching { client.subscribe(LocalDataType.TYPE_STEP_COUNT_DELTA).succeeded() }.getOrDefault(false)
        if (success && enabled && permitted && recordingSince == null) {
            recordingSince = System.currentTimeMillis()
            prefs.edit().putLong("stepRecordingSince", recordingSince!!).apply()
        }
        return success
    }

    /** Nil means unavailable, including a permission change, failed request or timeout. */
    fun count(start: SwiftDate, end: SwiftDate, done: (Int?) -> Unit) {
        val request = revision
        scope.launch {
            val count = try {
                withTimeoutOrNull(2_000) {
                    if (!enabled || !available() || end <= start) return@withTimeoutOrNull null
                    subscription.withLock {
                        if (!subscribed) {
                            subscribed = subscribe()
                        }
                    }
                    if (!subscribed) return@withTimeoutOrNull null
                    // Recording starts with the subscription. Don't label a partial
                    // walk or part of today as the full count for that time range.
                    val since = recordingSince ?: return@withTimeoutOrNull null
                    if (start.epochSeconds * 1000 < since) return@withTimeoutOrNull null
                    val read = LocalDataReadRequest.Builder()
                        .aggregate(LocalDataType.TYPE_STEP_COUNT_DELTA)
                        .bucketByTime(1, TimeUnit.DAYS)
                        .setTimeRange((start.epochSeconds * 1000).toLong(), (end.epochSeconds * 1000).toLong(), TimeUnit.MILLISECONDS)
                        .build()
                    val response = client.readData(read).resultOrNull() ?: return@withTimeoutOrNull null
                    val points = response.buckets.flatMap { it.dataSets }.flatMap { it.dataPoints }
                    // An empty response isn't proof of zero steps (e.g. no sensor history yet).
                    points.takeIf { it.isNotEmpty() }?.sumOf { it.getValue(LocalField.FIELD_STEPS).asInt() }
                }
            } catch (_: Exception) { null }
            done(if (request == revision && enabled) count else null)
        }
    }

    fun refreshToday() {
        val request = ++todayRequest
        val start = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli() / 1000.0
        count(SwiftDate.epoch(start), SwiftDate.now()) { if (request == todayRequest) today = it }
    }

    fun refreshLive(walk: Walk?) {
        if (liveWalk != walk?.id) { liveWalk = walk?.id; live = null }
        val id = walk?.id ?: return
        val request = ++liveRequest
        count(walk.startedAt, SwiftDate.now()) { if (liveWalk == id && request == liveRequest) live = it }
    }

    fun stopLive() { liveRequest++; liveWalk = null; live = null }
}

/** Tasks complete on the main thread; a timed-out read ignores its late callback. */
private suspend fun <T> Task<T>.resultOrNull(): T? = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { if (continuation.isActive) continuation.resume(it) }
    addOnFailureListener { if (continuation.isActive) continuation.resume(null) }
    addOnCanceledListener { if (continuation.isActive) continuation.resume(null) }
}

private suspend fun Task<Void>.succeeded(): Boolean = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { if (continuation.isActive) continuation.resume(true) }
    addOnFailureListener { if (continuation.isActive) continuation.resume(false) }
    addOnCanceledListener { if (continuation.isActive) continuation.resume(false) }
}
