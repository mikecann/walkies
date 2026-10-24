package com.mikecann.walkies.sync

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.convex.ConvexException
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.SyncState
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.OSMException
import com.mikecann.walkies.store.Store
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.UUID
import java.util.logging.Logger

/** When the last sync finished, kept between launches (UserDefaults' lastSynced on the iPhone). */
interface SyncPrefs {
    /** Seconds since 1970. */
    var lastSynced: Double?

    class Memory(override var lastSynced: Double? = null) : SyncPrefs
}

/**
 * Keeps this phone and the account in step (SyncEngine in Sync.swift). The phone is
 * the source of truth and works offline; this pushes up anything new and pulls down
 * anything missing whenever there's a connection. Everything only ever grows, so
 * there's nothing to reconcile beyond adding, apart from places you delete, which are
 * written down when you delete them. A sync that fails halfway just carries on next time.
 *
 * Lives on the main thread, with the network on IO. Team sync isn't here yet: teams
 * aren't on Android.
 */
class SyncEngine(
    private val model: AppModel,
    private val store: Store,
    private val isSignedIn: () -> Boolean,
    private val userId: () -> String? = { null },
    private val makeClient: suspend () -> ConvexClient?,
    /** Where [schedule] runs its syncs (the main thread on the phone). */
    private val scope: CoroutineScope,
    private val prefs: SyncPrefs = SyncPrefs.Memory(),
    /** Seconds since 1970. */
    private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
) {
    sealed interface Status {
        data object Idle : Status
        data object Syncing : Status
        data class Failed(val reason: String) : Status
    }

    var status: Status = Status.Idle
        private set(value) {
            if (field == value) return
            field = value
            changed()
        }

    /** Seconds since 1970. */
    var lastSynced: Double? = prefs.lastSynced
        private set(value) {
            field = value
            prefs.lastSynced = value
            changed()
        }

    /** Walks, places, secrets and deletions on this phone that the server hasn't got yet. */
    var waiting = 0
        private set(value) {
            if (field == value) return
            field = value
            changed()
        }

    private var state = store.loadSyncState()
    private var scheduled: Job? = null
    private var current: Job? = null
    private var running = false
    private var pending = false
    private var resetRevision = 0
    private val listeners = ArrayList<() -> Unit>()

    init {
        model.placesDeleted = ::deleted
        model.walksChanged = ::changed
        countWaiting()
    }

    /** Calls [listener] when the status, the count waiting or the last sync changes. Returns a function that stops it. */
    fun listen(listener: () -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    private fun changed() {
        for (listener in listeners.toList()) listener()
    }

    /** Syncs a moment from now. Several requests in a row become one sync. */
    fun schedule() {
        countWaiting()
        if (running) {
            pending = true
            return
        }
        scheduled?.cancel()
        scheduled = scope.launch {
            delay(2_000)
            sync()
        }
    }

    suspend fun sync() {
        if (!isSignedIn()) return
        if (running) {
            pending = true
            return
        }
        running = true
        coroutineScope {
            val job = launch { run() }
            current = job
            job.join()
        }
    }

    private suspend fun run() {
        val revision = resetRevision
        pending = false
        status = Status.Syncing
        try {
            claimLocalData()
            val client = makeClient()
            if (client == null) {
                status = if (isSignedIn()) Status.Failed("Offline") else Status.Idle
                return
            }
            try {
                check(revision)
                push(client, revision)
                pull(client, revision)
                lastSynced = clock()
                status = Status.Idle
                // After the pull, so any place another phone already updated arrives first.
                model.refreshStreets()
            } catch (e: CancellationException) {
                status = Status.Idle
            } catch (e: Exception) {
                log.warning("Sync failed: $e")
                status = Status.Failed(reason(e))
            }
        } finally {
            running = false
            current = null
            countWaiting()
            if (pending) {
                pending = false
                schedule()
            }
        }
    }

    /** Forgets what was sent, for signing out. */
    fun reset() {
        resetRevision++
        scheduled?.cancel()
        pending = false
        state = SyncState()
        lastSynced = null
        status = Status.Idle
        countWaiting()
    }

    /**
     * Stops any sync in flight, then clears this phone, for signing out. A sync
     * that was running can't put anything back afterwards.
     */
    suspend fun wipe() {
        reset()
        current?.let {
            it.cancel()
            it.join()
        }
        model.wipeLocalData()
        reset()
    }

    /** Places deleted on this phone, so the next push deletes them from the account too. */
    private fun deleted(ids: List<UUID>) {
        state = state.copy(deletedPlaces = state.deletedPlaces.orEmpty() + ids)
        save()
        countWaiting()
    }

    /**
     * How many times each walk has changed since the app started, so an upload that was
     * already on its way with the older copy isn't taken as the latest.
     */
    private val walkEdits = HashMap<UUID, Int>()

    /**
     * Walks that changed after they went up (a place that added itself since counted
     * their tiles), so they go up again. Saving a walk replaces its copy in the account.
     */
    private fun changed(ids: List<UUID>) {
        for (id in ids) walkEdits[id] = (walkEdits[id] ?: 0) + 1
        state = state.copy(uploadedWalks = state.uploadedWalks - ids.toSet())
        save()
        countWaiting()
    }

    /**
     * This phone's data belongs to whoever it first synced for. Someone else signing in,
     * say after a session ran out, starts from their own account instead. Anything the
     * last account hadn't uploaded yet is lost here, but that's rare: their session
     * would have to end with things still waiting.
     */
    private fun claimLocalData() {
        val user = userId() ?: return
        val owner = store.loadOwner()
        if (owner == user) return
        if (owner != null) {
            model.wipeLocalData()
            state = SyncState()
            lastSynced = null
        }
        store.saveOwner(user)
    }

    /** Throws when a sign-out or reset has happened since the sync started. */
    private suspend fun check(revision: Int) {
        if (!isSignedIn() || resetRevision != revision || !currentCoroutineContext().isActive) {
            throw CancellationException("Signed out or reset during sync")
        }
    }

    // Push

    private suspend fun push(client: ConvexClient, revision: Int) {
        // Only places deleted on purpose. A place that's just missing, say from a file
        // that wouldn't load, must never be deleted from the account.
        for (id in state.deletedPlaces.orEmpty().toList()) {
            client.mutation("sync:deletePlace", args { put("clientId", id.uuidString) })
            check(revision)
            state = state.copy(deletedPlaces = state.deletedPlaces.orEmpty() - id, uploadedPlaces = state.uploadedPlaces - id)
            save()
        }

        for (city in model.cities.toList()) {
            val changed = city.lastChanged
            val sent = state.uploadedPlaces[city.id]
            if (sent != null && sent >= changed) continue
            val file = upload(Codec.city(city), client)
            check(revision)
            client.mutation("sync:savePlace", args {
                put("clientId", city.id.uuidString)
                put("name", city.name)
                put("createdAt", Codec.number(city.createdAt.ms))
                put("updatedAt", Codec.number(changed.ms))
                put("file", file)
            })
            check(revision)
            state = state.copy(uploadedPlaces = state.uploadedPlaces + (city.id to changed))
            save()
        }

        for (walk in model.walks.toList()) {
            if (walk.id in state.uploadedWalks) continue
            val endedAt = walk.endedAt ?: continue
            val edit = walkEdits[walk.id]
            val file = upload(Codec.walk(walk), client)
            check(revision)
            client.mutation("sync:saveWalk", args {
                put("clientId", walk.id.uuidString)
                put("startedAt", Codec.number(walk.startedAt.ms))
                put("endedAt", Codec.number(endedAt.ms))
                put("distance", Codec.number(walk.distance))
                put("newTiles", Codec.number(walk.newTiles.toDouble()))
                put("file", file)
            })
            check(revision)
            // Credited again while this copy was on its way up: the next push sends the new one.
            if (walkEdits[walk.id] != edit) continue
            state = state.copy(uploadedWalks = state.uploadedWalks + walk.id)
            save()
        }

        val secrets = model.foundStickers.filterKeys { it !in state.uploadedSecrets }
        if (secrets.isNotEmpty()) {
            client.mutation("sync:saveSecrets", args {
                put("secrets", JsonArray(secrets.map { (id, at) ->
                    buildJsonObject {
                        put("secretId", id)
                        put("foundAt", Codec.number(at.ms))
                    }
                }))
            })
            check(revision)
            state = state.copy(uploadedSecrets = state.uploadedSecrets + secrets.keys)
            save()
        }
        // A rejected ledger must never hold secret uploads behind it.
        val progress = progressJSON(model.ledger)
        if (state.uploadedProgress != progress) {
            client.mutation("sync:saveProgress", args { put("ledger", progress) })
            check(revision)
            state = state.copy(uploadedProgress = progress)
            save()
        }
    }

    private suspend fun upload(json: JsonElement, client: ConvexClient): String {
        val url = (client.mutation("sync:generateUploadUrl") as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: throw ConvexException.Server("Bad upload URL")
        val bytes = withContext(Dispatchers.Default) { json.toString().toByteArray() }
        return client.upload(bytes, url)
    }

    // Pull

    private class Batch {
        val cities = ArrayList<City>()
        val walks = ArrayList<Walk>()
        val rebuiltWalks = HashSet<UUID>()
        val count get() = cities.size + walks.size
    }

    /** The first download that failed, which fails the sync once everything else is in. */
    private class Failure {
        var error: Exception? = null
    }

    /**
     * Downloads are applied a batch at a time, so one bad file can't hold back the
     * rest and a pull that's cut short keeps what it got. The first batch carries the
     * ledger, so ownership is merged before anything else.
     */
    private suspend fun pull(client: ConvexClient, revision: Int) {
        val snapshot = Snapshot.from(client.query("sync:snapshot", buildJsonObject { put("walkUrls", false) }))
        check(revision)

        var progress = snapshot.progress?.let { Codec.ledger(Codec.parse(it)) }
        var secrets: Map<String, SwiftDate> = HashMap<String, SwiftDate>().also { found ->
            for ((id, at) in snapshot.secrets) {
                val date = SwiftDate.epoch(at / 1000)
                found[id] = found[id]?.let { minOf(it, date) } ?: date
            }
        }
        var batch = Batch()
        val failure = Failure()
        // A place in the account that isn't here after all: it didn't download, or it
        // won't read on this version.
        var placesMissing = false

        suspend fun flush() {
            apply(batch, progress, secrets, revision)
            batch = Batch()
            progress = null
            secrets = emptyMap()
        }

        for (place in snapshot.places) {
            val id = uuid(place.clientId) ?: continue
            val remoteChanged = SwiftDate.epoch(place.updatedAt / 1000)
            val local = model.cities.firstOrNull { it.id == id }
            if (local != null) {
                if (local.lastChanged >= remoteChanged) continue
            } else if (state.deletedPlaces?.contains(id) == true) {
                continue
            }
            val city = place.url?.let { fetch(it, client, revision, failure, Codec::city) }
            if (city == null) {
                placesMissing = true
                continue
            }
            if (city.gridVersion != HexGrid.VERSION) {
                if (failure.error == null) failure.error = ConvexException.Server("The server still has places from the old grid.")
                continue
            }
            batch.cities.add(city)
            if (batch.count >= BATCH_SIZE) flush()
        }
        // Links only for the walks this phone hasn't got, so a sync doesn't sign one per walk.
        val have = model.walks.mapTo(HashSet()) { it.id }
        val missing = snapshot.walks.filter { uuid(it)?.let { id -> id !in have } ?: false }
        val links = ArrayList<Snapshot.Remote>()
        for (chunk in missing.chunked(100)) {
            val found = client.query("sync:walkUrls", buildJsonObject { put("clientIds", JsonArray(chunk.map(::JsonPrimitive))) })
            links += (found as? JsonArray ?: throw ConvexException.Server("Bad walk links")).map(Snapshot::remote)
            check(revision)
        }
        for (remote in links) {
            val id = uuid(remote.clientId) ?: continue
            if (id in have) continue
            val url = remote.url ?: continue
            var walk = fetch(url, client, revision, failure, Codec::walk) ?: continue
            if (walk.gridVersion != HexGrid.VERSION) {
                walk = walk.resetGridCoverage()
                batch.rebuiltWalks.add(walk.id)
            }
            batch.walks.add(walk)
            if (batch.count >= BATCH_SIZE) flush()
        }
        flush()
        // Anything that didn't download is tried again next sync.
        failure.error?.let { throw it }
        // Places add themselves only once every place in the account is here, so one
        // can't be a second copy of a place that just didn't come down this time. One
        // that won't read keeps them waiting too, until a later sync can read it.
        if (placesMissing) return
        model.pulledAccount()
    }

    private suspend fun apply(batch: Batch, progress: Ledger?, secrets: Map<String, SwiftDate>, revision: Int) {
        check(revision)
        model.addRemote(batch.cities, batch.walks, progress, secrets)
        check(revision)
        var uploaded = state.uploadedPlaces
        for (city in batch.cities) {
            val sent = uploaded[city.id]
            uploaded = uploaded + (city.id to if (sent != null && sent > city.lastChanged) sent else city.lastChanged)
        }
        state = state.copy(
            uploadedPlaces = uploaded,
            uploadedWalks = state.uploadedWalks + batch.walks.map { it.id }.filter { it !in batch.rebuiltWalks },
            uploadedProgress = progress?.let(::progressJSON) ?: state.uploadedProgress,
            uploadedSecrets = state.uploadedSecrets + secrets.keys,
        )
        // A retained server walk can still contain old hexes. Replace its blob on
        // the next push, after addRemote has rebuilt coverage from the raw GPS.
        if (batch.rebuiltWalks.isNotEmpty()) pending = true
        save()
    }

    /**
     * Null when the file wouldn't download, which is tried again next sync, or wouldn't
     * read, which is skipped so it can't stop every pull after it.
     */
    private suspend fun <T> fetch(url: String, client: ConvexClient, revision: Int, failure: Failure, decode: (JsonElement) -> T): T? {
        val data = try {
            client.download(url)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            check(revision)
            if (failure.error == null) failure.error = e
            return null
        }
        check(revision)
        return try {
            withContext(Dispatchers.Default) { decode(Codec.parse(data.decodeToString())) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.severe("Skipping ${url.substringAfterLast('/')} from the account, it won't read: $e")
            null
        }
    }

    private fun save() = store.saveSyncState(state)

    private fun countWaiting() {
        val deletes = state.deletedPlaces?.size ?: 0
        waiting = deletes +
            model.walks.count { it.endedAt != null && it.id !in state.uploadedWalks } +
            model.cities.count { (state.uploadedPlaces[it.id] ?: SwiftDate.distantPast) < it.lastChanged } +
            model.foundStickers.keys.count { it !in state.uploadedSecrets } +
            (if (progressJSON(model.ledger) == state.uploadedProgress) 0 else 1)
    }

    /** What the server sent back for `sync:snapshot`. Walks come without links (`walkUrls: false`). */
    private class Snapshot(
        val walks: List<String>,
        val places: List<Place>,
        val secrets: List<Pair<String, Double>>,
        val progress: String?,
    ) {
        class Place(val clientId: String, val updatedAt: Double, val url: String?)
        class Remote(val clientId: String, val url: String?)

        companion object {
            fun from(e: JsonElement): Snapshot {
                val o = e as? JsonObject ?: throw ConvexException.Server("Bad snapshot")
                fun list(key: String) = o[key] as? JsonArray ?: throw ConvexException.Server("Bad snapshot")
                return Snapshot(
                    walks = list("walks").map { remote(it).clientId },
                    places = list("places").map {
                        val p = it as? JsonObject ?: throw ConvexException.Server("Bad snapshot")
                        Place(string(p["clientId"]), (p["updatedAt"] as? JsonPrimitive)?.doubleOrNull ?: throw ConvexException.Server("Bad snapshot"), optString(p["url"]))
                    },
                    secrets = list("secrets").map {
                        val s = it as? JsonObject ?: throw ConvexException.Server("Bad snapshot")
                        string(s["secretId"]) to ((s["foundAt"] as? JsonPrimitive)?.doubleOrNull ?: throw ConvexException.Server("Bad snapshot"))
                    },
                    progress = optString(o["progress"]),
                )
            }

            fun remote(e: JsonElement): Remote {
                val o = e as? JsonObject ?: throw ConvexException.Server("Bad snapshot")
                return Remote(string(o["clientId"]), optString(o["url"]))
            }

            private fun string(e: JsonElement?) = (e as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ConvexException.Server("Bad snapshot")
            private fun optString(e: JsonElement?) = if (e == null || e is JsonNull) null else string(e)
        }
    }

    companion object {
        private const val BATCH_SIZE = 25
        private val log: Logger = Logger.getLogger("walkies.sync")

        /** The ledger as the iPhone sends it: sorted keys, so both phones agree on when it's changed. */
        fun progressJSON(ledger: Ledger): String = Codec.sortedKeys(Codec.ledger(ledger))

        /** Every sync argument carries the grid version, so an old app can't write old hexes. */
        private fun args(build: JsonObjectBuilder.() -> Unit) = buildJsonObject {
            put("gridVersion", HexGrid.VERSION)
            build()
        }

        private fun uuid(s: String): UUID? = if (s.length != 36) null else runCatching { UUID.fromString(s) }.getOrNull()

        /** Short, for Settings' "Couldn't check (…)". */
        private fun reason(e: Exception): String = when (e) {
            is SocketTimeoutException -> "Timed out"
            is OSMException -> e.message ?: "OpenStreetMap is busy"
            is IOException -> "Offline"
            else -> e.message ?: "Something went wrong"
        }
    }
}
