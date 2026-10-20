package com.mikecann.walkies

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.lore.placeStickers
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.Progression
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.WalkRecap
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
import kotlinx.coroutines.CompletableDeferred
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
 * Also the secrets: hiding them under each place's tiles, finding them as you walk
 * (a pop-up with the app open, a notification with it closed), and the recap the
 * end-of-walk celebration plays.
 *
 * Also progression (the progression part of AppModel.swift): shells, XP and quests
 * worked out from the walks, places and secrets, and the ledger of what's been bought,
 * claimed and equipped. Saved walks have their first-discovery tile counts worked out
 * once at launch ([historyScope], off the main thread on the phone, straight away in
 * tests), and kept up to date as walks end.
 *
 * There's no world-grid rebuild: Android never wrote the old grid.
 */
class AppModel(
    private val store: Store,
    private val settings: Settings,
    private val location: LocationAccess,
    private val motion: Motion = Motion.Unknown,
    /** Seconds since 1970. */
    private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
    private val osm: OSMClient = OSMClient(),
    /** Where the launch history backfill runs. Null works it out before the constructor returns. */
    private val historyScope: CoroutineScope? = null,
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
        private set(value) {
            field = value
            secretsRevision++
        }
    /** Stickers just found, waiting to pop up. */
    var stickerQueue: List<LoreEntry> = emptyList()
        private set
    /**
     * Secrets that turned up under tiles you'd already walked, say from an update or
     * a newly added place. Too many to pop up one by one, so the map just says how many.
     */
    var secretsAlreadyWalked = 0
        private set
    /** Set when a walk ends (or one's rewatched from history), to play the celebration. */
    var recap: WalkRecap? = null
        private set
    private var recapRequest = 0

    /**
     * Secrets just found by walking over them, for the notification when the app's
     * closed. Set by the app, which knows whether the map's on screen.
     */
    var secretsFound: ((List<LoreEntry>) -> Unit)? = null

    private var tracer = CoverageTracer()
    private val shapes = HashMap<UUID, BoundaryShape>()
    private var lastSave = Double.NEGATIVE_INFINITY
    private var startWhenAllowed = false
    private var addedTiles: Map<UUID, Set<Hex>> = emptyMap()
    private var loading = false
    /** Bumps when the phone's data is wiped, so work that started before can't put anything back. */
    private var dataGeneration = 0

    /** The shop and level-reward ledger: what's been bought, claimed and equipped. */
    var ledger = Ledger()
        private set

    /** The saved walks' tile counts have been worked out, so rewards can be trusted. */
    var historyReady = false
        private set
    private var historyDone = CompletableDeferred<Unit>()
    /** Walk endings waiting for the history, run as soon as it's ready. */
    private val afterHistory = ArrayList<() -> Unit>()
    private var batchingProgress = false
    private var historyRevision = 0
    private var placesRevision = 0
    private var secretsRevision = 0
    private var countingTilesByPlace: Map<UUID, Int> = emptyMap()
    private var questTileCounts: Map<UUID, Map<UUID, Int>> = emptyMap()
    private var cachedProgression: Pair<String, Progression.State>? = null
    private var cachedHistoricalRewards: Pair<String, Progression.HistoricalRewards>? = null
    /** How many times past weeks and streaks have been worked out, for tests. */
    var progressionHistoryBuilds = 0
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
        placeStickers()
        rebuildCountingTiles()
        // Never trace saved routes while opening the app or handling a location fix.
        prepareHistory()
    }

    private fun rebuildCountingTiles() {
        countingTilesByPlace = Progression.countingTiles(cities)
    }

    /** Waits until the saved walks' tile counts are worked out. */
    suspend fun waitForHistory() = historyDone.await()

    private fun prepareHistory() {
        val generation = dataGeneration
        val savedCities = cities
        val resumed = activeWalk?.takeIf { !autoWalkPending }?.let { active ->
            active.copy(endedAt = active.points.lastOrNull()?.let { SwiftDate.epoch(it.time) } ?: now())
        }
        val routes = walks + listOfNotNull(resumed)
        fun install(repaired: Progression.Backfill) {
            // Signed out meanwhile: there's no history left to install.
            if (generation == dataGeneration) installBackfill(repaired)
            historyReady = true
            historyRevision++
            historyDone.complete(Unit)
            refreshProgressPicks()
            val waiting = afterHistory.toList()
            afterHistory.clear()
            for (run in waiting) run()
            onChange()
        }
        val scope = historyScope
        if (scope == null) {
            install(Progression.backfill(routes, savedCities))
        } else {
            scope.launch { install(withContext(Dispatchers.Default) { Progression.backfill(routes, savedCities) }) }
        }
    }

    /** Saves walks whose tile identities were recovered, and keeps the counts for rewards. */
    private fun installBackfill(repaired: Progression.Backfill) {
        val byId = HashMap<UUID, Walk>()
        for (walk in repaired.walks) byId.putIfAbsent(walk.id, walk)
        walks = walks.map { walk ->
            val recovered = byId[walk.id] ?: return@map walk
            val newTiles = recovered.newTileHexesByPlace?.values?.sumOf { it.size } ?: recovered.newTiles
            if (walk.newTiles == newTiles && walk.newTilesByPlace == recovered.newTilesByPlace && walk.newTileHexesByPlace == recovered.newTileHexesByPlace) {
                walk
            } else {
                walk.copy(newTiles = newTiles, newTilesByPlace = recovered.newTilesByPlace, newTileHexesByPlace = recovered.newTileHexesByPlace)
                    .also { store.save(it) }
            }
        }
        val counts = HashMap(repaired.counts)
        for (walk in walks) if (walk.id !in counts) counts[walk.id] = Progression.countsByPlaceId(walk.newTilesByPlace)
        questTileCounts = counts
    }

    /** Runs [action] now if the history's ready, otherwise as soon as it is. */
    private fun whenHistoryReady(action: () -> Unit) {
        if (historyReady) action() else afterHistory.add(action)
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
        if (!historyReady) {
            val id = activeWalk?.id ?: return
            whenHistoryReady { if (activeWalk?.id == id) endWalk() }
            return
        }
        var walk = activeWalk ?: return
        walk = finishCoverage(walk.copy(endedAt = now()))
        val history = walks
        val fresh = freshTiles
        val counts = questTileCounts
        walks = walks + walk
        questTileCounts = questTileCounts + (walk.id to fresh.mapValues { it.value.size })
        historyRevision++
        activeWalk = null
        activePath = emptyList()
        freshTiles = emptyMap()
        addedTiles = emptyMap()
        tilesRevision++
        store.save(walk)
        store.save(cities)
        recapRequest++
        recap = WalkRecap.make(walk, cities, fresh, foundStickers, history, clock(), counts)
        refreshProgressPicks()
        requestSync?.invoke()
        onChange()
    }

    /** The celebration's closed. */
    fun dismissRecap() {
        if (recap == null) return
        recap = null
        onChange()
    }

    /**
     * Plays an old walk's replay again, from walk history. Which tiles were new on it
     * is worked out again: the tiles under its route that no earlier walk crossed.
     * It's marked as a rewatch, so it only recaps the walk and awards nothing.
     */
    fun replay(walk: Walk) {
        val earlier = walks.filter { it.id != walk.id && it.startedAt < walk.startedAt }
        val savedCities = cities
        val counts = questTileCounts
        val found = foundStickers
        val generation = dataGeneration
        val request = ++recapRequest
        val now = clock()
        fun work(): WalkRecap {
            val fresh = HashMap<UUID, Set<Hex>>()
            val before = savedCities.map { saved ->
                var city = saved.copy(visited = emptySet())
                val shape = city.shape()
                for (old in earlier) city = city.visit(CoverageTracer.samples(old.points), shape).first
                val (after, new) = city.visit(CoverageTracer.samples(walk.points), shape)
                if (new.isNotEmpty()) fresh[city.id] = new
                after
            }
            return WalkRecap.make(walk, before, fresh, found, earlier, now, counts)
                .copy(isRewatch = true, earnings = Progression.WalkEarnings())
        }
        fun show(result: WalkRecap) {
            if (generation != dataGeneration || request != recapRequest) return
            recap = result
            onChange()
        }
        val scope = services
        if (scope == null) {
            show(work())
        } else {
            scope.launch { show(withContext(Dispatchers.Default) { work() }) }
        }
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
        if (!historyReady) {
            // Only the walk that was due to end. A later one may have started by then.
            val id = activeWalk?.id ?: return
            whenHistoryReady { if (activeWalk?.id == id) finishAutoWalk(byYou) }
            return
        }
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
            val history = walks
            val counts = questTileCounts
            walks = walks + walk
            questTileCounts = questTileCounts + (walk.id to fresh.mapValues { it.value.size })
            historyRevision++
            store.save(walk)
            // If it ended by itself while the phone was in your pocket, this plays the
            // next time you open the app.
            recapRequest++
            recap = WalkRecap.make(walk, cities, fresh, foundStickers, history, clock(), counts)
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
            if (fresh.isNotEmpty()) {
                questTileCounts = questTileCounts + (walk.id to fresh.mapValues { it.value.size })
                historyRevision++
            }
            store.delete(walk)
        }
        store.save(cities)
        refreshProgressPicks()
        requestSync?.invoke()
        onChange()
    }

    private fun turnOnAlwaysOn() {
        // Hand over from a walk you started yourself, without the summary popping up.
        if (activeWalk != null) {
            endWalk()
            recap = null
        }
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
            countingTilesByPlace = countingTilesByPlace + (city.id to ((countingTilesByPlace[city.id] ?: 0) + fresh.size))
            tilesRevision++
            uncovered += fresh.size
            unlockStickers(city, fresh, notify = true, popUp = true)
        }
        cities = updated.toList()
        if (uncovered > 0) refreshProgressPicks()
        return uncovered
    }

    // Stickers

    /** Every sticker hidden in the selected city, found or not. */
    val stickersHere: List<Pair<LoreEntry, Hex>>
        get() = selectedCity?.stickers.orEmpty()
            .mapNotNull { (id, hex) -> LoreLibrary.entry(id)?.let { it to hex } }
            .sortedBy { it.first.title }

    /** The first sticker in the queue has been seen; on to the next. */
    fun popSticker() {
        if (stickerQueue.isEmpty()) return
        stickerQueue = stickerQueue.drop(1)
        onChange()
    }

    /** The "new secrets in places you've walked" card has been seen or closed. */
    fun dismissSecretsAlreadyWalked() {
        if (secretsAlreadyWalked == 0) return
        secretsAlreadyWalked = 0
        onChange()
    }

    /**
     * Hides each place's secrets under its tiles. A secret that now belongs to a
     * different place (say its suburb's just been added) moves there, unless you've
     * already found it, when it stays where you found it. Secrets under tiles you've
     * already walked are yours straight away.
     */
    private fun placeStickers() {
        val assigned = LoreLibrary.assign(LoreLibrary.all, cities) { city, point ->
            shape(city).contains(city.grid.projection.project(point))
        }
        var changed = false
        val updated = cities.toMutableList()
        for (i in updated.indices) {
            val wanted = assigned[updated[i].id].orEmpty().mapTo(HashSet()) { it.id }
            val placed = updated[i].stickers ?: continue
            val leaving = placed.keys.filter { it !in wanted && foundStickers[it] == null }
            if (leaving.isEmpty()) continue
            updated[i] = updated[i].copy(stickers = placed - leaving.toSet(), updatedAt = now())
            changed = true
        }
        val hidden = updated.flatMapTo(HashSet()) { it.stickers.orEmpty().keys }
        for (i in updated.indices) {
            val missing = assigned[updated[i].id].orEmpty().filter { it.id !in hidden }
            if (missing.isEmpty()) continue
            val placed = updated[i].stickers.orEmpty()
            // The ones already here stay where they are.
            updated[i] = updated[i].copy(
                stickers = updated[i].placeStickers(missing, placed.values.toSet()) + placed,
                updatedAt = now(),
            )
            changed = true
            secretsAlreadyWalked += unlockStickers(updated[i], updated[i].visited, notify = false, popUp = false)
        }
        if (changed) {
            cities = updated.toList()
            tilesRevision++
            store.save(cities)
        }
    }

    /**
     * Secrets hidden under these tiles are yours. [notify]: found by walking just now,
     * so it's dated now and gets a notification if the app's closed; otherwise it was
     * under a tile you'd already explored. [popUp]: queue it to pop up. Returns how many.
     */
    private fun unlockStickers(city: City, hexes: Set<Hex>, notify: Boolean, popUp: Boolean): Int {
        val placed = city.stickers ?: return 0
        val ids = placed.filter { it.value in hexes && foundStickers[it.key] == null }.keys.sorted()
        if (ids.isEmpty()) return 0
        val entries = ids.mapNotNull(LoreLibrary::entry)
        val at = if (notify) now() else SwiftDate.distantFuture
        foundStickers = foundStickers + entries.associate { it.id to at }
        store.saveStickers(foundStickers)
        if (popUp) stickerQueue = stickerQueue + entries
        if (notify && entries.isNotEmpty()) secretsFound?.invoke(entries)
        refreshProgressPicks()
        requestSync?.invoke()
        return entries.size
    }

    // Places

    fun add(city: City) {
        val added = city.copy(updatedAt = now())
        cities = cities + added
        placesRevision++
        rebuildCountingTiles()
        shapes[added.id] = added.shape()
        select(added.id)
        placeStickers()
        tilesRevision++
        store.save(cities)
        refreshProgressPicks()
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
        placesRevision++
        rebuildCountingTiles()
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
        placeStickers()
        store.save(cities)
        refreshProgressPicks()
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

    // Progression

    /** Shells, XP and this week's quests, worked out again only when something they depend on changes. */
    val progression: Progression.State
        get() {
            val now = now()
            val day = Progression.localDate(now, Progression.zone)
            val historyKey = "$historyRevision-$placesRevision-$secretsRevision-$day"
            val key = "$tilesRevision-$historyKey"
            cachedProgression?.let { (k, state) -> if (k == key) return state }
            var inputs = Progression.Inputs(
                cities = cities, walks = walks, foundSecrets = foundStickers, now = now,
                newTilesByWalk = questTileCounts, countingTilesByPlace = countingTilesByPlace,
                unrecordedTilesByPlace = if (activeWalk == null) emptyMap() else freshTiles.mapValues { it.value.size },
            )
            if (cachedHistoricalRewards?.first != historyKey) {
                progressionHistoryBuilds++
                cachedHistoricalRewards = historyKey to Progression.historicalRewards(inputs)
            }
            inputs = inputs.copy(historicalRewards = cachedHistoricalRewards?.second)
            val state = Progression.state(inputs)
            cachedProgression = key to state
            return state
        }

    val earnedBreakdown: Progression.Earned get() = progression.earned
    val balance: Int get() = ledger.balance(progression.earned.total)
    val xp: Int get() = progression.xp
    val level: Int get() = progression.level
    val nextLevelXP: Int get() = progression.nextLevelXP
    val xpToNextLevel: Int get() = nextLevelXP - xp
    /** Levels reached whose reward hasn't been chosen yet. */
    val pendingPicks: List<Int> get() = if (historyReady && !batchingProgress) Progression.pendingLevels(xp, ledger) else emptyList()
    val weeklyQuests: List<Progression.Quest> get() = progression.quests
    val owned: Set<String> get() = ledger.owned
    val equipped: Ledger.Equipped get() = ledger.resolvedEquipment
    val spyglasses: Int get() = ledger.spyglassesLeft

    /** Read again on a timer while the map's showing, so the ring goes when it expires. */
    val activeSpyglassRing: Progression.Ring?
        get() {
            val city = selectedCity ?: return null
            return Progression.activeRing(city, ledger, foundStickers, now())
        }

    fun picks(level: Int): List<String> = ledger.picks(level)

    /**
     * False means unknown item, already owned, or too few shells. Concurrent offline
     * spending is kept on merge; the resulting debt blocks purchases.
     */
    fun buy(itemId: String): Boolean {
        val item = Progression.item(itemId) ?: return false
        if (!historyReady || item.isFree || (item.group != null && itemId in owned) || balance < item.price) return false
        // Include levels reached since the last refresh before ownership changes.
        ledger = ledger.preparedPicks(xp)
        ledger = ledger.copy(purchases = ledger.purchases + Ledger.Purchase(item = itemId, cost = item.price, at = clock()))
        item.group?.let { setEquipped(itemId, it) }
        saveProgress()
        return true
    }

    fun equip(itemId: String): Boolean {
        val group = Progression.item(itemId)?.group ?: return false
        if (itemId !in owned) return false
        setEquipped(itemId, group)
        saveProgress()
        return true
    }

    fun claim(level: Int, choice: String): Boolean {
        if (level !in pendingPicks || choice !in picks(level)) return false
        // A frozen offer may have been bought in the meantime. Give the bag instead of
        // taking a level pick for something already owned.
        val reward = if (choice in owned) Progression.SHELL_BAG else choice
        ledger = ledger.copy(claims = ledger.claims + Ledger.Claim(level, reward))
        Progression.item(reward)?.group?.let { setEquipped(reward, it) }
        saveProgress()
        return true
    }

    fun useSpyglass(): Boolean {
        val city = selectedCity ?: return false
        if (spyglasses <= 0 || activeSpyglassRing != null) return false
        val use = Progression.spyglass(city, lastLocation?.coordinate, foundStickers, now()) ?: return false
        ledger = ledger.copy(spyglasses = ledger.spyglasses + use)
        saveProgress()
        return true
    }

    private fun setEquipped(itemId: String, group: Progression.Group) {
        val equipped = ledger.equipped.with(group, itemId)
        ledger = ledger.copy(equipped = equipped.copy(updatedAt = max(clock(), Math.nextUp(equipped.updatedAt))))
    }

    private fun refreshProgressPicks() {
        if (!historyReady || batchingProgress) return
        val old = ledger
        ledger = ledger.preparedPicks(xp)
        if (ledger != old) saveProgress()
    }

    private fun saveProgress() {
        if (historyReady && !batchingProgress) ledger = ledger.preparedPicks(xp)
        store.saveProgress(ledger)
        requestSync?.invoke()
        onChange()
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
        waitForHistory()
        if (generation != dataGeneration) return
        // Merge ownership before preparing any level menu, and refresh once at the end.
        batchingProgress = true
        try {
            addRemoteBatch(generation, remoteCities, remoteWalks, progress, secrets)
        } finally {
            batchingProgress = false
            if (generation == dataGeneration) {
                refreshProgressPicks()
                onChange()
            }
        }
    }

    private suspend fun addRemoteBatch(generation: Int, remoteCities: List<City>, remoteWalks: List<Walk>, progress: Ledger?, secrets: Map<String, SwiftDate>) {
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
        if (changedCities.isEmpty() && missing.isEmpty()) return
        placesRevision++
        tilesRevision++
        rebuildCountingTiles()
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
            out to Progression.backfill(snapshotWalks, out)
        }
        if (generation != dataGeneration) return
        // Location fixes can arrive while the worker runs. Union its result so no
        // live coverage is overwritten by the snapshot it started with.
        cities = cities.map { city ->
            val again = restored.first.firstOrNull { it.id == city.id } ?: return@map city
            city.copy(visited = city.visited + again.visited, tiles = city.tiles + again.tiles)
        }
        installBackfill(restored.second)
        historyRevision++
        placesRevision++
        tilesRevision++
        rebuildCountingTiles()
        placeStickers()
        for (city in cities) unlockStickers(city, city.visited, notify = false, popUp = false)
        store.save(cities)
        refreshNeighbours()
    }

    /**
     * Another phone's ledger, merged so both converge. The server accepted its first
     * claim for a level, so its copy goes first and two offline choices settle on one.
     */
    fun addRemoteProgress(remote: Ledger) {
        val merged = remote.merged(ledger)
        if (merged == ledger) return
        ledger = merged
        if (historyReady && !batchingProgress) ledger = ledger.preparedPicks(xp)
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
            refreshProgressPicks()
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
        stickerQueue = emptyList()
        secretsAlreadyWalked = 0
        recap = null
        recapRequest++
        ledger = Ledger()
        cachedProgression = null
        cachedHistoricalRewards = null
        questTileCounts = emptyMap()
        countingTilesByPlace = emptyMap()
        afterHistory.clear()
        historyRevision++
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
