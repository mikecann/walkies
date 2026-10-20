package com.mikecann.walkies

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.BoundaryShape
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.CityBuilder
import com.mikecann.walkies.place.NearbyPlaces
import com.mikecann.walkies.place.OSMClient
import com.mikecann.walkies.place.PlaceResult
import com.mikecann.walkies.store.Store
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID
import java.util.logging.Logger
import kotlin.math.cos
import kotlin.math.max

/** What the model needs to know about location permission. LocationTracker on the phone, a fake in tests. */
interface LocationAccess {
    enum class Authorization { NotDetermined, Denied, Allowed }

    val authorization: Authorization
    fun requestPermission()
}

/**
 * What the motion chip thinks you're doing (MotionMonitor.swift): ActivityMotion on the
 * phone. Until it's heard anything, the GPS speed does the filtering.
 */
interface Motion {
    val onWheels: Boolean
    val still: Boolean

    object Unknown : Motion {
        override val onWheels = false
        override val still = false
    }
}

/** Settings kept between launches (UserDefaults on iOS, SharedPreferences here). */
interface Settings {
    var alwaysOn: Boolean
    /** Seconds; zero means the usual ten minutes. Overridable for testing on the emulator. */
    var autoWalkGap: Double
    var selectedCity: String?
    /** Whether the first-run setup (location, activity, notifications, battery, always on) is done. */
    var setupDone: Boolean
}

/**
 * Places and walks, and turning GPS fixes into uncovered tiles: the walk side of
 * AppModel.swift. Lives on the main thread. Tells its listeners after anything changes,
 * so the UI can redraw and the notification can keep up.
 *
 * Also the places: adding them from search or the suburbs next door, deleting them,
 * and taking in what sync pulls down.
 *
 * Not ported yet: progression and recaps (stage 5), secrets placement and pop-ups
 * (stage 5). There's no world-grid rebuild: Android never wrote the old grid.
 */
class AppModel(
    private val store: Store,
    private val settings: Settings,
    private val location: LocationAccess,
    private val motion: Motion = Motion.Unknown,
    /** Seconds since 1970. */
    private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
    private val osm: OSMClient = OSMClient(),
) {
    private val listeners = ArrayList<() -> Unit>()

    /** Calls [listener] after anything changes. Returns a function that stops it. */
    fun listen(listener: () -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    private fun onChange() {
        for (listener in listeners.toList()) listener()
    }

    var cities: List<City> = emptyList()
        private set
    var walks: List<Walk> = emptyList()
        private set
    var selectedCityId: UUID? = null
        private set
    /**
     * Bumps when the map should fly to the selected place: when you pick or add one,
     * not when it changes because you've walked into it.
     */
    var flyToSelected = 0
        private set
    /** Where you were at the last GPS fix. */
    var lastLocation: TrackPoint? = null
        private set
    /**
     * Set when the app opens, so the next fix selects the place you're in. Otherwise the
     * selection only follows you on a walk, so looking at another place sticks.
     */
    var placeYouOnNextFix = true
    var activeWalk: Walk? = null
        private set
    /** Accepted fixes from the current walk, for drawing the line on the map. */
    var activePath: List<Coordinate> = emptyList()
        private set
    /** Tiles uncovered on the current walk, per city, so the map can make a fuss of them. */
    var freshTiles: Map<UUID, Set<Hex>> = emptyMap()
        private set
    /** Bumps whenever any city's tiles change. */
    var tilesRevision = 0
        private set
    /** Bumps for every newly uncovered tile, to drive haptics. */
    var revealCount = 0
        private set
    /**
     * True while an always-on walk has started but you haven't gone far enough yet to
     * be sure it's a real one. Nothing gets uncovered until it's sure.
     */
    var autoWalkPending = false
        private set
    /** When each sticker was found, by lore id. */
    var foundStickers: Map<String, SwiftDate> = emptyMap()
        private set

    private var tracer = CoverageTracer()
    private val shapes = HashMap<UUID, BoundaryShape>()
    private var lastSave = Double.NEGATIVE_INFINITY
    private var startWhenAllowed = false
    private var addedTiles: Map<UUID, Set<Hex>> = emptyMap()
    private var loading = false
    /** Bumps when the phone's data is wiped, so work that started before can't put anything back. */
    private var dataGeneration = 0

    /** The shop and level-reward ledger, kept and synced for the iPhone. The shop itself comes in stage 5. */
    var ledger = Ledger()
        private set

    /** Asks sync to push and pull shortly. Set by the app. */
    var requestSync: (() -> Unit)? = null
    /** Tells sync which places were deleted on purpose. Set by the sync engine. */
    var placesDeleted: ((List<UUID>) -> Unit)? = null
    /** A client for the server's street cache, from Account.client(), like sync. Tests leave it null. */
    var makePlaceClient: (suspend () -> ConvexClient?)? = null
    /** Where background place work runs (the main thread on the phone). Null in tests, which turns it off. */
    var services: CoroutineScope? = null

    /** Record walks by themselves, so there's no Start walk to press. */
    var alwaysOn = false
        set(value) {
            if (value == field) return
            field = value
            if (loading) return
            settings.alwaysOn = value
            if (value) turnOnAlwaysOn() else turnOffAlwaysOn()
            onChange()
        }

    /** In always-on mode, a walk ends after this long (seconds) without moving on foot. */
    val autoWalkGap: Double get() = settings.autoWalkGap.takeIf { it > 0 } ?: (10 * 60.0)

    init {
        load()
    }

    private fun load() {
        loading = true
        cities = store.loadCities()
        ledger = store.loadProgress()
        alwaysOn = settings.alwaysOn
        loading = false

        // A walk without an end means the app was killed mid-walk. If it's an always-on
        // walk that's still going, carry on with it; otherwise close it off.
        val loaded = ArrayList<Walk>()
        for (saved in store.loadWalks()) {
            var walk = saved
            if (walk.endedAt == null) {
                val last = walk.points.lastOrNull()
                if (alwaysOn && walk.isAutomatic && last != null && clock() - last.time < autoWalkGap) {
                    activeWalk = walk
                    autoWalkPending = displacement(walk.points) < AUTO_WALK_CONFIRM_DISTANCE
                    activePath = if (autoWalkPending) emptyList() else walk.points.map { it.coordinate }
                    continue
                }
                walk = walk.copy(endedAt = last?.let { SwiftDate.epoch(it.time) } ?: walk.startedAt)
                store.save(walk)
            }
            loaded.add(walk)
        }
        walks = loaded

        activeWalk?.let { active ->
            freshTiles = byPlaceId(active.newTileHexesByPlace)
            addedTiles = byPlaceId(active.addedTilesByPlace)
            val restored = active.copy(newTilesByPlace = countsByPlace(freshTiles), newTileHexesByPlace = hexesByPlace(freshTiles))
            activeWalk = restored
            store.save(restored)
        }

        val saved = settings.selectedCity
        selectedCityId = cities.firstOrNull { it.id.uuidString == saved }?.id ?: cities.firstOrNull()?.id
        foundStickers = store.loadStickers()
    }

    val selectedCity: City? get() = cities.firstOrNull { it.id == selectedCityId }

    // Walks

    fun startWalk() {
        if (activeWalk != null || alwaysOn) return
        when (location.authorization) {
            LocationAccess.Authorization.NotDetermined -> {
                startWhenAllowed = true
                location.requestPermission()
                return
            }
            LocationAccess.Authorization.Denied -> return
            LocationAccess.Authorization.Allowed -> Unit
        }
        activeWalk = Walk(startedAt = now(), newTilesByPlace = emptyMap(), newTileHexesByPlace = emptyMap(), addedTilesByPlace = emptyMap())
        activePath = emptyList()
        freshTiles = emptyMap()
        addedTiles = emptyMap()
        tracer = CoverageTracer()
        onChange()
    }

    fun endWalk() {
        var walk = activeWalk ?: return
        walk = finishCoverage(walk.copy(endedAt = now()))
        walks = walks + walk
        activeWalk = null
        activePath = emptyList()
        freshTiles = emptyMap()
        addedTiles = emptyMap()
        tilesRevision++
        store.save(walk)
        store.save(cities)
        requestSync?.invoke()
        onChange()
    }

    /** The End walk button on an always-on walk: ends it now. */
    fun endAutoWalk() = finishAutoWalk(byYou = true)

    private fun finishCoverage(walk: Walk) = walk.copy(
        newTilesByPlace = countsByPlace(freshTiles),
        newTileHexesByPlace = hexesByPlace(freshTiles),
        addedTilesByPlace = hexesByPlace(addedTiles),
    )

    /** Saves the walk so far and the places, say when the app goes into the background. */
    fun saveNow(waiting: Boolean = false) {
        activeWalk?.let { walk ->
            val finished = finishCoverage(walk)
            activeWalk = finished
            store.save(finished)
        }
        store.save(cities)
        lastSave = clock()
        if (waiting) store.flush()
    }

    /** A GPS fix. */
    fun record(fix: TrackPoint) {
        // A cached fix from wherever you last were when tracking starts.
        if (clock() - fix.time > 10) return
        lastLocation = fix
        var point = fix
        if (motion.onWheels) point = point.copy(wheels = true)
        if (motion.still) point = point.copy(still = true)
        if (alwaysOn) {
            recordAlwaysOn(point)
        } else if (activeWalk != null) {
            recordWalk(point)
        }
        if (activeWalk != null || placeYouOnNextFix) {
            placeYouOnNextFix = false
            followIntoPlace(point.coordinate)
        }
        onChange()
    }

    /**
     * On a walk, whichever of your places you're in becomes the selected one, so the
     * percentage is for where you are. The map doesn't jump to it.
     */
    private fun followIntoPlace(point: Coordinate) {
        selectedCity?.let { current -> if (shape(current).contains(current.grid.projection.project(point))) return }
        cities.firstOrNull { shape(it).contains(it.grid.projection.project(point)) }?.let {
            selectedCityId = it.id
            settings.selectedCity = it.id.uuidString
        }
    }

    /** Picks a place to look at, and flies the map there. */
    fun select(id: UUID) {
        selectedCityId = id
        settings.selectedCity = id.uuidString
        flyToSelected++
        onChange()
    }

    /** A walk you started yourself: keep every fix. */
    private fun recordWalk(point: TrackPoint) {
        var walk = activeWalk ?: return
        walk = walk.copy(points = walk.points + point)
        walk = apply(tracer.add(point), point, walk)
        activeWalk = walk
        saveIfDue()
    }

    /**
     * Always on: a walk starts the moment you're moving on foot and ends once you've
     * stopped for a while. Only on-foot fixes are kept, so drives don't fill the phone.
     */
    private fun recordAlwaysOn(point: TrackPoint) {
        val last = activeWalk?.points?.lastOrNull()
        if (last != null && point.time - last.time > autoWalkGap) {
            finishAutoWalk()
            // Leave these fixes out rather than run the next outing onto the end of this one.
            if (activeWalk != null) return
        }
        val anchor = tracer.anchor
        val step = tracer.add(point)
        if (step.samples.isEmpty()) return
        if (activeWalk == null) {
            activeWalk = Walk(
                startedAt = SwiftDate.epoch(anchor?.time ?: point.time),
                newTilesByPlace = emptyMap(), newTileHexesByPlace = emptyMap(), addedTilesByPlace = emptyMap(),
                automatic = true,
            )
            activePath = emptyList()
            freshTiles = emptyMap()
            addedTiles = emptyMap()
            autoWalkPending = true
        }
        var walk = activeWalk ?: return
        // The fix this step started from, so replaying the points gives the same
        // route, distance and tiles as recording them did.
        var points = walk.points
        if (anchor != null && points.lastOrNull() != anchor) points = points + anchor
        walk = walk.copy(points = points + point)
        if (autoWalkPending) {
            walk = walk.copy(distance = walk.distance + step.distance)
            if (displacement(walk.points) >= AUTO_WALK_CONFIRM_DISTANCE) {
                // It's a real walk: uncover everything since it started in one go.
                autoWalkPending = false
                val samples = CoverageTracer.samples(walk.points)
                activePath = samples
                val uncovered = visit(samples)
                walk = walk.copy(newTiles = walk.newTiles + uncovered)
                revealCount += uncovered
            }
        } else {
            walk = apply(step, point, walk)
        }
        activeWalk = walk
        saveIfDue()
    }

    /** How far a pending walk has got from where it started, in metres. */
    val pendingWalkDistance: Double get() = activeWalk?.let { displacement(it.points) } ?: 0.0

    private fun apply(step: CoverageTracer.Step, point: TrackPoint, walk: Walk): Walk {
        var result = walk.copy(distance = walk.distance + step.distance)
        if (step.samples.isEmpty()) return result
        val origin = step.origin
        if (origin != null && activePath.lastOrNull() != origin) activePath = activePath + origin
        activePath = activePath + point.coordinate
        val uncovered = visit(step.samples)
        if (uncovered > 0) {
            result = result.copy(newTiles = result.newTiles + uncovered)
            revealCount += uncovered
        }
        return result
    }

    private fun saveIfDue() {
        if (clock() - lastSave > 30) saveNow()
    }

    /**
     * Closes an always-on walk that's gone quiet. New fixes do this too, but there
     * may not be any for a while, so the app checks again whenever it comes back.
     */
    fun finishStaleAutoWalk() {
        val last = activeWalk?.points?.lastOrNull() ?: return
        if (clock() - last.time > autoWalkGap) finishAutoWalk()
    }

    /**
     * [byYou]: you pressed End walk, so it ends now and is kept however short.
     * Otherwise it ended by itself, at its last fix, and only counts if it's long enough.
     */
    private fun finishAutoWalk(byYou: Boolean = false) {
        var walk = activeWalk ?: return
        if (!walk.isAutomatic) return
        val wasPending = autoWalkPending
        walk = finishCoverage(walk)
        val fresh = freshTiles
        autoWalkPending = false
        activeWalk = null
        activePath = emptyList()
        freshTiles = emptyMap()
        addedTiles = emptyMap()
        tracer = CoverageTracer()
        tilesRevision++
        walk = walk.copy(endedAt = if (byYou) now() else walk.points.lastOrNull()?.let { SwiftDate.epoch(it.time) } ?: walk.startedAt)
        // Measure again by today's rules, so walks logged by older versions (or GPS
        // wobble at home) don't get kept as real ones. Tiles already uncovered stay.
        walk = walk.copy(distance = CoverageTracer.distance(walk.points))
        if (!wasPending && (byYou || walk.distance >= MINIMUM_AUTO_WALK)) {
            walks = walks + walk
            store.save(walk)
        } else {
            // Keep the dated tile credit even though this outing doesn't qualify
            // for walk history, distance/day quests or streak rewards.
            cities = cities.map { city ->
                val hexes = fresh[city.id]
                if (hexes.isNullOrEmpty()) city
                else city.copy(
                    tileCredits = city.tileCredits.orEmpty() + City.TileCredit(walk.id, walk.startedAt, hexes),
                    updatedAt = now(),
                )
            }
            store.delete(walk)
        }
        store.save(cities)
        requestSync?.invoke()
        onChange()
    }

    private fun turnOnAlwaysOn() {
        // Hand over from a walk you started yourself.
        if (activeWalk != null) endWalk()
        tracer = CoverageTracer()
    }

    private fun turnOffAlwaysOn() = finishAutoWalk()

    /** Location permission changed. Starts the walk that was waiting on it. */
    fun authorizationChanged() {
        if (!startWhenAllowed || location.authorization == LocationAccess.Authorization.NotDetermined) {
            onChange()
            return
        }
        startWhenAllowed = false
        startWalk()
        onChange()
    }

    /** Marks these points as visited in every city. Returns how many tiles were new. */
    private fun visit(points: List<Coordinate>): Int {
        var uncovered = 0
        val updated = cities.toMutableList()
        for (i in updated.indices) {
            val original = updated[i]
            val (visited, fresh) = original.visit(points, shape(original))
            if (fresh.isEmpty()) continue
            val city = visited.copy(updatedAt = now())
            updated[i] = city
            freshTiles = freshTiles + (city.id to (freshTiles[city.id].orEmpty() + fresh))
            addedTiles = addedTiles + (city.id to (addedTiles[city.id].orEmpty() + (fresh - original.tiles)))
            tilesRevision++
            uncovered += fresh.size
            unlockStickers(city, fresh, notify = true)
        }
        cities = updated.toList()
        return uncovered
    }

    /** Secrets hidden under these tiles are yours. The pop-ups come with the secrets book (stage 5). Returns how many. */
    private fun unlockStickers(city: City, hexes: Set<Hex>, notify: Boolean): Int {
        val placed = city.stickers ?: return 0
        val ids = placed.filter { it.value in hexes && foundStickers[it.key] == null }.keys.sorted()
        if (ids.isEmpty()) return 0
        val at = if (notify) now() else SwiftDate.distantFuture
        foundStickers = foundStickers + ids.associateWith { at }
        store.saveStickers(foundStickers)
        requestSync?.invoke()
        return ids.size
    }

    // Places

    fun add(city: City) {
        val added = city.copy(updatedAt = now())
        cities = cities + added
        shapes[added.id] = added.shape()
        select(added.id)
        tilesRevision++
        store.save(cities)
        requestSync?.invoke()
        refreshNeighbours()
        onChange()
    }

    /** Both the neighbour buttons and place search add to your own places, with your walks so far replayed into it. */
    suspend fun addPlace(place: PlaceResult, status: (String) -> Unit) {
        val generation = dataGeneration
        val city = CityBuilder.build(place, walks, makePlaceClient?.invoke(), osm, status)
        if (generation != dataGeneration) throw CancellationException("Signed out while adding ${place.name}")
        add(city)
    }

    /**
     * Deletes a place on purpose, so sync deletes it from the account too. Its walks
     * are kept. A place that's just missing, say from a file that wouldn't load,
     * is never deleted from the account.
     */
    fun deleteCity(id: UUID) {
        if (cities.none { it.id == id }) return
        placesDeleted?.invoke(listOf(id))
        cities = cities.filter { it.id != id }
        shapes.remove(id)
        if (selectedCityId == id) {
            val next = cities.firstOrNull()?.id
            if (next != null) {
                select(next)
            } else {
                selectedCityId = null
                settings.selectedCity = null
            }
        }
        tilesRevision++
        store.save(cities)
        requestSync?.invoke()
        onChange()
    }

    // Neighbours

    /** Suburbs around your places, fetched from OpenStreetMap. */
    var nearby: List<PlaceResult> = emptyList()
        private set
    private var fetchingNearby = false
    private var nearbyRetries = 0
    private var warmedNeighbourIds: List<Long>? = null
    private var warmingNeighbours = false

    /** Suburbs within reach of your places that you haven't added yet, for the map to offer. */
    val neighbours: List<PlaceResult>
        get() {
            val box = box(NEIGHBOURHOOD) ?: return emptyList()
            val have = cities.mapTo(HashSet()) { it.name.lowercase() }
            return nearby.filter { place ->
                val b = place.boundary.bounds
                place.name.lowercase() !in have && place.area <= CityBuilder.MAX_AREA &&
                    b.north >= box.south && b.south <= box.north && b.east >= box.west && b.west <= box.east
            }
        }

    /** The box around all your places, grown by this many metres each way. */
    private fun box(metres: Double): Boundary.Bounds? {
        val all = cities.map { it.boundary.bounds }
        if (all.isEmpty()) return null
        val south = all.minOf { it.south }
        val west = all.minOf { it.west }
        val north = all.maxOf { it.north }
        val east = all.maxOf { it.east }
        val dLat = metres / 111_320
        val dLon = dLat / max(0.1, cos((south + north) / 2 * Math.PI / 180))
        return Boundary.Bounds(south - dLat, west - dLon, north + dLat, east + dLon)
    }

    /**
     * Uses the saved list if it still covers your places and is under a month old.
     * Otherwise asks Overpass, which is quick when it's up, and falls back to asking
     * Nominatim point by point when it isn't. Tries again a few times if both fail,
     * and again whenever the app comes back.
     */
    fun refreshNeighbours() {
        val scope = services ?: return
        if (fetchingNearby) return
        val wanted = box(NEIGHBOURHOOD) ?: return
        val fetch = box(NEIGHBOURHOOD * 2) ?: return
        val saved = store.loadNearby()
        if (saved != null && saved.covers(wanted.south, wanted.west, wanted.north, wanted.east) &&
            clock() - saved.fetchedAt.epochSeconds < 30 * 24 * 3600
        ) {
            if (saved.places != nearby) {
                nearby = saved.places
                onChange()
            }
            warmNeighbours()
            return
        }
        fetchingNearby = true
        val generation = dataGeneration
        val points = samplePoints(wanted)
        scope.launch {
            var found: Pair<List<PlaceResult>, Boundary.Bounds>? = null
            try {
                found = osm.placesNear(fetch.south, fetch.west, fetch.north, fetch.east) to fetch
            } catch (e: CancellationException) {
                fetchingNearby = false
                throw e
            } catch (e: Exception) {
                log.info("Overpass couldn't list suburbs, asking Nominatim instead: $e")
                try {
                    found = osm.placesAt(points) to wanted
                } catch (e: CancellationException) {
                    fetchingNearby = false
                    throw e
                } catch (e: Exception) {
                    log.info("Nominatim couldn't list suburbs either: $e")
                }
            }
            fetchingNearby = false
            if (generation != dataGeneration) return@launch
            if (found == null) {
                if (nearbyRetries < 3) {
                    nearbyRetries++
                    delay(90_000)
                    refreshNeighbours()
                }
                return@launch
            }
            nearbyRetries = 0
            val (places, box) = found
            nearby = places
            warmNeighbours()
            store.saveNearby(NearbyPlaces(box.south, box.west, box.north, box.east, now(), places))
            onChange()
        }
    }

    /**
     * Asks the server to get the suburbs next door ready, so adding one is quick.
     * One warm per list. Failed or offline attempts retry on the next refresh, and
     * signing in can warm a list loaded before then.
     */
    private fun warmNeighbours() {
        val scope = services ?: return
        val makeClient = makePlaceClient ?: return
        val ids = nearby.mapNotNull { it.osmId }.distinct().sorted()
        if (ids.isEmpty() || ids == warmedNeighbourIds || warmingNeighbours) return
        warmingNeighbours = true
        scope.launch {
            try {
                val client = makeClient() ?: return@launch
                // Keep each request bounded for larger neighbourhoods.
                for (chunk in ids.chunked(100)) {
                    client.action("places:warm", buildJsonObject { put("osmIds", JsonArray(chunk.map(::JsonPrimitive))) })
                }
                warmedNeighbourIds = ids
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.info("Couldn't warm nearby streets: $e")
            } finally {
                warmingNeighbours = false
            }
            // A newer list may have arrived while this request was running.
            if (warmedNeighbourIds != null && ids != nearby.mapNotNull { it.osmId }.distinct().sorted()) warmNeighbours()
        }
    }

    /**
     * Points about 2.5 km apart across the box, leaving out the ones inside places
     * you've already got, for asking Nominatim which suburb each is in.
     */
    private fun samplePoints(box: Boundary.Bounds): List<Coordinate> {
        val step = 2500.0 / 111_320
        val lonStep = step / max(0.1, cos((box.south + box.north) / 2 * Math.PI / 180))
        val points = ArrayList<Coordinate>()
        var lat = box.south + step / 2
        while (lat < box.north) {
            var lon = box.west + lonStep / 2
            while (lon < box.east) {
                val point = Coordinate(lat, lon)
                if (cities.none { shape(it).contains(it.grid.projection.project(point)) }) points.add(point)
                lon += lonStep
            }
            lat += step
        }
        return points
    }

    // Sync

    /**
     * Takes in a batch from the account (addRemote in AppModel.swift): the ledger,
     * secrets, places and walks. Places merge with the ones here; walks this phone
     * hasn't got are added, then every place they touch has its coverage replayed
     * on a worker thread.
     */
    suspend fun addRemote(remoteCities: List<City>, remoteWalks: List<Walk>, progress: Ledger?, secrets: Map<String, SwiftDate>) {
        val generation = dataGeneration
        progress?.let(::addRemoteProgress)
        addRemoteSecrets(secrets)
        val changedCities = HashSet<UUID>()
        val merged = cities.toMutableList()
        for (remote in remoteCities) {
            changedCities.add(remote.id)
            val i = merged.indexOfFirst { it.id == remote.id }
            if (i >= 0) {
                val city = merged[i]
                val localCredits = city.tileCredits.orEmpty().mapTo(HashSet()) { it.id }
                val remoteCredits = remote.tileCredits.orEmpty().mapTo(HashSet()) { it.id }
                val hadMore = !remote.visited.containsAll(city.visited) || !remoteCredits.containsAll(localCredits)
                val credited = city.mergeTileCredits(remote)
                merged[i] = credited.copy(
                    visited = credited.visited + remote.visited,
                    tiles = credited.tiles + remote.tiles,
                    roads = credited.roads ?: remote.roads,
                    // Theirs win, as in Swift's merging(_:uniquingKeysWith:).
                    stickers = credited.stickers.orEmpty() + remote.stickers.orEmpty(),
                    updatedAt = if (hadMore) now() else maxOf(city.lastChanged, remote.lastChanged),
                )
            } else {
                merged.add(remote)
            }
            shapes.remove(remote.id)
        }
        cities = merged
        if (selectedCityId == null) cities.firstOrNull { it.id in changedCities }?.let { select(it.id) }

        val have = walks.mapTo(HashSet()) { it.id }
        val missing = remoteWalks.filter { it.endedAt != null && it.id != activeWalk?.id && it.id !in have }
        walks = (walks + missing).sortedBy { it.startedAt }
        for (walk in missing) store.save(walk)
        if (changedCities.isEmpty() && missing.isEmpty()) {
            onChange()
            return
        }
        tilesRevision++
        onChange()

        val snapshotCities = cities
        val snapshotWalks = walks
        val newIds = missing.mapTo(HashSet()) { it.id }
        val restored = withContext(Dispatchers.Default) {
            val out = snapshotCities.toMutableList()
            val shapes = out.map { it.shape() }
            for (walk in snapshotWalks) {
                val targets = out.indices.filter { out[it].id in changedCities || walk.id in newIds }
                if (targets.isEmpty()) continue
                val samples = CoverageTracer.samples(walk.points)
                for (i in targets) out[i] = out[i].visit(samples, shapes[i]).first
            }
            out
        }
        if (generation != dataGeneration) return
        // Location fixes can arrive while the worker runs. Union its result so no
        // live coverage is overwritten by the snapshot it started with.
        cities = cities.map { city ->
            val again = restored.firstOrNull { it.id == city.id } ?: return@map city
            city.copy(visited = city.visited + again.visited, tiles = city.tiles + again.tiles)
        }
        tilesRevision++
        for (city in cities) unlockStickers(city, city.visited, notify = false)
        store.save(cities)
        refreshNeighbours()
        onChange()
    }

    /** Another phone's ledger, merged so both converge. The server's copy goes first. */
    fun addRemoteProgress(remote: Ledger) {
        val merged = remote.merged(ledger)
        if (merged == ledger) return
        ledger = merged
        store.saveProgress(ledger)
        requestSync?.invoke()
    }

    /**
     * A genuine discovery beats the explored-coverage sentinel; otherwise the
     * earliest discovery wins, matching the server's secret merge.
     */
    fun addRemoteSecrets(remote: Map<String, SwiftDate>) {
        val found = foundStickers.toMutableMap()
        var changed = false
        for ((id, date) in remote) {
            val mine = found[id]
            if (mine == null || date < mine) {
                found[id] = date
                changed = true
            }
        }
        if (changed) {
            foundStickers = found
            store.saveStickers(foundStickers)
        }
    }

    /** Forgets everything on this phone, for signing out. It's all in the account. */
    fun wipeLocalData() {
        dataGeneration++
        // Dropped rather than finished, so turning always-on off below can't save it.
        activeWalk = null
        alwaysOn = false
        settings.setupDone = false
        autoWalkPending = false
        activePath = emptyList()
        freshTiles = emptyMap()
        addedTiles = emptyMap()
        tracer = CoverageTracer()
        cities = emptyList()
        walks = emptyList()
        shapes.clear()
        foundStickers = emptyMap()
        ledger = Ledger()
        nearby = emptyList()
        warmedNeighbourIds = null
        nearbyRetries = 0
        selectedCityId = null
        settings.selectedCity = null
        placeYouOnNextFix = true
        tilesRevision++
        store.wipe()
        onChange()
    }

    private fun shape(city: City): BoundaryShape = shapes.getOrPut(city.id) { city.shape() }

    private fun now() = SwiftDate.epoch(clock())

    companion object {
        /**
         * Shorter than this and it wasn't really a walk: pottering round the house, or
         * GPS drift. Any tiles it uncovered stay uncovered.
         */
        const val MINIMUM_AUTO_WALK = 300.0

        /**
         * An always-on walk only counts once you've got this far (metres, as the crow
         * flies) from where it started. GPS indoors can wander tens of metres back and
         * forth, which adds up as distance but never carries you this far away.
         */
        const val AUTO_WALK_CONFIRM_DISTANCE = 150.0

        /**
         * How far around your places to offer suburbs, in metres. Twice this is fetched
         * and kept, so adding the next suburb over doesn't mean fetching again.
         */
        const val NEIGHBOURHOOD = 5000.0

        private val log: Logger = Logger.getLogger("walkies.places")

        /** How far the furthest point gets from the first, in metres. */
        fun displacement(points: List<TrackPoint>): Double {
            val first = points.firstOrNull()?.coordinate ?: return 0.0
            return points.maxOf { first.distance(it.coordinate) }
        }

        private fun countsByPlace(tiles: Map<UUID, Set<Hex>>) = tiles.entries.associate { it.key.uuidString to it.value.size }
        private fun hexesByPlace(tiles: Map<UUID, Set<Hex>>) = tiles.entries.associate { it.key.uuidString to it.value }

        private fun byPlaceId(map: Map<String, Set<Hex>>?): Map<UUID, Set<Hex>> {
            val out = LinkedHashMap<UUID, Set<Hex>>()
            for ((key, hexes) in map.orEmpty()) {
                val id = runCatching { UUID.fromString(key) }.getOrNull() ?: continue
                out[id] = out[id].orEmpty() + hexes
            }
            return out
        }
    }
}
