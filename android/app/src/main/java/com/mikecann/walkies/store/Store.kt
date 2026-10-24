package com.mikecann.walkies.store

import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.SyncState
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.AutoPlaces
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.NearbyPlaces
import com.mikecann.walkies.place.RoadLine
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.Executors
import java.util.logging.Logger

/**
 * Plain JSON files, laid out exactly like the iPhone's Store.swift: cities.json with
 * their streets in roads.json, one file per walk in walks/, stickers.json, progress.json,
 * sync.json, owner.json, nearby.json, auto-places.json and data-version.json.
 */
class Store(private val root: File) {
    private val citiesFile = File(root, "cities.json")
    private val roadsFile = File(root, "roads.json")
    private val walksDir = File(root, "walks")
    private val versionFile = File(root, "data-version.json")
    private val stickersFile = File(root, "stickers.json")
    private val progressFile = File(root, "progress.json")
    private val syncFile = File(root, "sync.json")
    private val ownerFile = File(root, "owner.json")
    private val nearbyFile = File(root, "nearby.json")
    private val autoPlacesFile = File(root, "auto-places.json")
    private val cityFiles = CityFiles.at(citiesFile, roadsFile)

    init {
        val isNew = !root.exists()
        walksDir.mkdirs()
        if (isNew) write(JsonPrimitive(HexGrid.VERSION), versionFile)
    }

    /**
     * True when the files were written for an older grid. Only the iPhone ever wrote
     * those, so unlike Store.swift there's nothing here to rebuild them.
     */
    val needsWorldGridReset: Boolean
        get() = read(versionFile) { (it as JsonPrimitive).int } != HexGrid.VERSION

    /**
     * A file that won't read is moved aside rather than saved over, and sync brings
     * the places back from the account.
     */
    fun loadCities(): List<City> {
        cityFiles.flush()
        if (!citiesFile.exists()) return emptyList()
        return try {
            val cities = Codec.cities(Codec.parse(citiesFile.readText())).toMutableList()
            // Older saves kept the streets in cities.json. Missing ones are fetched again.
            val roads = read(roadsFile, Codec::roadsByCity) ?: emptyMap()
            val fromFile = HashMap<UUID, List<RoadLine>?>()
            for (i in cities.indices) {
                if (cities[i].roads != null) continue
                cities[i] = cities[i].copy(roads = roads[cities[i].id.uuidString])
                fromFile[cities[i].id] = cities[i].roads
            }
            cityFiles.loaded(fromFile)
            cities
        } catch (e: Exception) {
            val aside = File(root, "cities.corrupt-${System.currentTimeMillis() / 1000}.json")
            log.severe("Couldn't read cities.json, moving it to ${aside.name}: $e")
            citiesFile.renameTo(aside)
            emptyList()
        }
    }

    /** Written in the background, newest last. Reading the cities waits for it. */
    fun save(cities: List<City>) = cityFiles.save(cities)

    /** Waits for any cities still being written, say before the app is stopped. */
    fun flush() = cityFiles.flush()

    /** When each sticker was found, by lore id. */
    fun loadStickers(): Map<String, SwiftDate> = read(stickersFile, Codec::stickers) ?: emptyMap()
    fun saveStickers(stickers: Map<String, SwiftDate>) = write(Codec.stickers(stickers), stickersFile)

    fun loadSyncState(): SyncState = read(syncFile, Codec::syncState) ?: SyncState()
    fun saveSyncState(state: SyncState) = write(Codec.syncState(state), syncFile)

    fun loadProgress(): Ledger = read(progressFile, Codec::ledger) ?: Ledger()
    fun saveProgress(ledger: Ledger) = write(Codec.ledger(ledger), progressFile)

    /** The user id of the account this phone's data belongs to. */
    fun loadOwner(): String? = read(ownerFile) { (it as JsonPrimitive).content }
    fun saveOwner(owner: String) = write(JsonPrimitive(owner), ownerFile)

    /** Suburbs around your places, so the map can offer them without asking OpenStreetMap every launch. */
    fun loadNearby(): NearbyPlaces? = read(nearbyFile, NearbyPlaces::from)
    fun saveNearby(nearby: NearbyPlaces) = write(nearby.toJson(), nearbyFile)

    /** What places that add themselves have looked up so far. Null the first time, before there's been anything to look up. */
    fun loadAutoPlaces(): AutoPlaces? = read(autoPlacesFile, AutoPlaces::from)
    fun saveAutoPlaces(auto: AutoPlaces) = write(auto.toJson(), autoPlacesFile)

    /** Deletes everything the app has saved, for signing out. */
    fun wipe() {
        cityFiles.replace {
            root.deleteRecursively()
            walksDir.mkdirs()
        }
        write(JsonPrimitive(HexGrid.VERSION), versionFile)
    }

    fun loadWalks(): List<Walk> =
        (walksDir.listFiles { f -> f.extension == "json" } ?: emptyArray())
            .mapNotNull { read(it, Codec::walk) }
            .sortedBy { it.startedAt }

    fun save(walk: Walk) = write(Codec.walk(walk), file(walk))

    fun delete(walk: Walk) {
        file(walk).delete()
    }

    private fun file(walk: Walk) = File(walksDir, "${walk.id.uuidString}.json")

    private fun <T> read(file: File, decode: (JsonElement) -> T): T? {
        if (!file.exists()) return null
        return try {
            decode(Codec.parse(file.readText()))
        } catch (e: Exception) {
            log.severe("Couldn't read ${file.name}: $e")
            null
        }
    }

    private fun write(json: JsonElement, file: File) {
        try {
            writeAtomically(file, json.toString().toByteArray())
        } catch (e: Exception) {
            log.severe("Couldn't save ${file.name}: $e")
        }
    }

    companion object {
        internal val log: Logger = Logger.getLogger("walkies.store")

        internal fun writeAtomically(file: File, bytes: ByteArray) {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, ".${file.name}.tmp")
            temp.writeBytes(bytes)
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        }
    }
}

/**
 * Writes the cities off the main thread, one save at a time, so saving during a walk
 * doesn't stall the map. Only the latest of several waiting saves is written. Each
 * city is only encoded again once it's changed, and the streets, which never change
 * once a place is built, live in their own file that's only written when they do.
 */
private class CityFiles private constructor(private val citiesFile: File, private val roadsFile: File) {
    private val queue = Executors.newSingleThreadExecutor { Thread(it, "walkies-cities").apply { isDaemon = true } }
    private val lock = Object()
    private var waiting: List<City>? = null
    // Only used on the queue.
    private var encoded = HashMap<UUID, Pair<City, String>>()
    private var savedRoads: Map<UUID, List<RoadLine>>? = null

    fun save(cities: List<City>) {
        val queued: Boolean
        synchronized(lock) {
            queued = waiting != null
            waiting = cities
        }
        if (!queued) queue.execute { writeWaiting() }
    }

    fun flush() {
        queue.submit { writeWaiting() }.get()
    }

    /** For changing the files some other way: after anything waiting is written, and forgetting what's on disk. */
    fun replace(change: () -> Unit) {
        queue.submit {
            writeWaiting()
            encoded = HashMap()
            savedRoads = null
            change()
        }.get()
    }

    /** The streets just read from roads.json, so the next save needn't write them again. */
    fun loaded(roads: Map<UUID, List<RoadLine>?>) {
        queue.submit { savedRoads = roads.filterValues { it != null }.mapValues { it.value!! } }.get()
    }

    private fun writeWaiting() {
        val cities = synchronized(lock) { waiting.also { waiting = null } } ?: return
        try {
            writeFiles(cities)
        } catch (e: Exception) {
            Store.log.severe("Couldn't save cities.json: $e")
        }
    }

    /** On the queue. Streets first, so cities.json never points at streets that aren't saved. */
    private fun writeFiles(cities: List<City>) {
        val roads = LinkedHashMap<UUID, List<RoadLine>>()
        for (city in cities) city.roads?.let { roads.putIfAbsent(city.id, it) }
        var inline = false
        if (roads != savedRoads) {
            try {
                val byId = roads.entries.associate { it.key.uuidString to it.value }
                Store.writeAtomically(roadsFile, Codec.roadsByCity(byId).toString().toByteArray())
                savedRoads = roads
            } catch (e: Exception) {
                Store.log.severe("Couldn't save roads.json, keeping the streets in cities.json: $e")
                savedRoads = null
                inline = true
            }
        }
        val next = HashMap<UUID, Pair<City, String>>()
        val file = StringBuilder("[")
        for ((i, city) in cities.withIndex()) {
            val bare = if (inline) city else city.copy(roads = null)
            val old = encoded[city.id]
            val text = if (old != null && old.first == bare) old.second else Codec.city(bare).toString()
            next[city.id] = bare to text
            if (i > 0) file.append(',')
            file.append(text)
        }
        file.append(']')
        Store.writeAtomically(citiesFile, file.toString().toByteArray())
        encoded = next
    }

    companion object {
        private val all = HashMap<String, CityFiles>()

        /** One per folder, so every Store on the same files writes in turn. */
        @Synchronized
        fun at(cities: File, roads: File): CityFiles =
            all.getOrPut(cities.absolutePath) { CityFiles(cities, roads) }
    }
}
