package com.mikecann.walkies

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.lore.LorePrep
import com.mikecann.walkies.lore.ServerLore
import com.mikecann.walkies.lore.placeStickers
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.Progression
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.WalkRecap
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.AutoPlaces
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.BoundaryShape
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.CityBuilder
import com.mikecann.walkies.place.Mist
import com.mikecann.walkies.place.NearbyPlaces
import com.mikecann.walkies.place.OSMClient
import com.mikecann.walkies.place.OSMWay
import com.mikecann.walkies.place.PlaceData
import com.mikecann.walkies.place.PlaceResult
import com.mikecann.walkies.place.WalkableRule
import com.mikecann.walkies.place.mergingLastWalked
import com.mikecann.walkies.place.noteWalked
import com.mikecann.walkies.store.Store
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
    var countSteps: Boolean
    /** Seconds; zero means the usual ten minutes. Overridable for testing on the emulator. */
    var autoWalkGap: Double
    var selectedCity: String?
    /** Whether the first-run setup (location, activity, notifications, battery, always on) is done. */
    var setupDone: Boolean
    /** Days until a walked tile mists over; zero means the usual 60. Overridable for testing on the emulator. */
    var mistDays: Double
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
    stepQuery: ((SwiftDate, SwiftDate, (Int?) -> Unit) -> Unit)? = null,
) {
    var countSteps: Boolean
        get() = settings.countSteps
        set(value) {
            settings.countSteps = value
            stepSettingRevision++
            onChange()
        }
    /** Wired to the phone service. Tests may return a delayed count. */
    var querySteps: ((SwiftDate, SwiftDate, (Int?) -> Unit) -> Unit)? = stepQuery
    private var finishingWalkId: UUID? = null
    private var stepSettingRevision = 0

    private fun withSteps(walk: Walk, end: SwiftDate, finish: (Walk) -> Unit) {
        if (finishingWalkId != null) return
        val snapshot = walk.copy(endedAt = end)
        val query = querySteps
        if (!countSteps || query == null) { finish(snapshot); return }
        finishingWalkId = walk.id
        saveNow(waiting = true)
        val generation = dataGeneration
        val setting = stepSettingRevision
        query(walk.startedAt, end) { count ->
            if (generation != dataGeneration || activeWalk?.id != walk.id || finishingWalkId != walk.id) return@query
            finishingWalkId = null
            finish(snapshot.copy(steps = count.takeIf { countSteps && setting == stepSettingRevision }))
        }
    }

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
    private var rodeSinceLastPoint = false
    /** Where you got off the ride that's ending the current walk. The next walk picks up from here. */
    private var rideArrival: TrackPoint? = null
    private val shapes = HashMap<UUID, BoundaryShape>()
    private var lastSave = Double.NEGATIVE_INFINITY
    private var startWhenAllowed = false
    private var addedTiles: Map<UUID, Set<Hex>> = emptyMap()
    private var loading = false
    /** Bumps when the phone's data is wiped, so work that started before can't put anything back. */
    private var dataGeneration = 0
    /** Places whose last-walked dates (for the mist) haven't been worked out from the saved walks yet. */
    private val lastWalkedPending = HashSet<UUID>()
    private var fillingLastWalked = false

    /** The shop and level-reward ledger: what's been bought, claimed and equipped. */
    var ledger = Ledger()
        private set

    /**
     * What places that add themselves have looked up so far, saved in auto-places.json.
     * Up here with the rest of what [load] reads, so it's set before load runs.
     */
    var autoPlaces = AutoPlaces()
        private set

    /**
     * What the server's said about your places that have no bundled secrets, saved in
     * server-lore.json (ServerLore, shared/lore-api.md). Up here for the same reason.
     */
    var serverLore = ServerLore()
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
    var questTileCounts: Map<UUID, Map<UUID, Int>> = emptyMap()
        private set
    private var cachedProgression: Pair<String, Progression.State>? = null
    private var cachedHistoricalRewards: Pair<String, Progression.HistoricalRewards>? = null
    /** How many times past weeks and streaks have been worked out, for tests. */
    var progressionHistoryBuilds = 0
        private set

    /** Asks sync to push and pull shortly. Set by the app. */
    var requestSync: (() -> Unit)? = null
    /** Tells sync which places were deleted on purpose. Set by the sync engine. */
    var placesDeleted: ((List<UUID>) -> Unit)? = null
    /** Tells sync which walks changed after they were saved, so they go up again. Set by the sync engine. */
    var walksChanged: ((List<UUID>) -> Unit)? = null
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

    /** How long until a walked tile mists over, in days (`--es mistDays 0.001` to see it today). */
    val mistDays: Double get() = settings.mistDays.takeIf { it > 0 } ?: Mist.DEFAULT_DAYS

    init {
        load()
    }

    private fun load() {
        loading = true
        cities = store.loadCities()
        autoPlaces = store.loadAutoPlaces() ?: AutoPlaces()
        if (autoPlaces.walksSince == null) {
            // Walks from before this version are left alone.
            autoPlaces = autoPlaces.copy(walksSince = now())
            store.saveAutoPlaces(autoPlaces)
        }
        ledger = store.loadProgress()
        alwaysOn = settings.alwaysOn
        loading = false

        // A walk without an end means the app was killed mid-walk. If it's an always-on
        // walk that's still going, carry on with it; otherwise close it off.
        val loaded = ArrayList<Walk>()
        val recovered = ArrayList<Walk>()
        for (saved in store.loadWalks()) {
            val walk = saved
            if (walk.endedAt == null) {
                val last = walk.points.lastOrNull()
                if (alwaysOn && walk.isAutomatic && last != null && clock() - last.time < autoWalkGap) {
                    activeWalk = walk
                    autoWalkPending = displacement(walk.points) < AUTO_WALK_CONFIRM_DISTANCE
                    activePath = if (autoWalkPending) emptyList() else walk.points.map { it.coordinate }
                    continue
                }
                recovered.add(walk)
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
        // Before placing stickers, so the server's secrets are still wanted.
        serverLore = store.loadServerLore() ?: ServerLore()
        LoreLibrary.useServer(serverLore, store.serverStickers)
        placeStickers()
        rebuildCountingTiles()
        // Never trace saved routes while opening the app or handling a location fix.
        finishRecovered(recovered, 0, dataGeneration)
        fillInLastWalked()
    }

    /** Recovered files keep their nil end until steps are attached, so sync can't upload early. */
    private fun finishRecovered(recovered: List<Walk>, index: Int, generation: Int) {
        if (generation != dataGeneration) return
        val walk = recovered.getOrNull(index)
        if (walk == null) { prepareHistory(); return }
        val end = walk.points.lastOrNull()?.let { SwiftDate.epoch(it.time) } ?: walk.startedAt
        val setting = stepSettingRevision
        val done: (Int?) -> Unit = { count ->
            if (generation == dataGeneration) {
                val finished = walk.copy(endedAt = end, steps = count.takeIf { countSteps && setting == stepSettingRevision })
                walks = walks.map { if (it.id == walk.id) finished else it }
                store.save(finished)
                finishRecovered(recovered, index + 1, generation)
                onChange()
            }
        }
        val query = querySteps
        if (countSteps && query != null) query(walk.startedAt, end, done) else done(null)
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
        val walk = activeWalk ?: return
        withSteps(walk, now(), ::completeWalk)
    }

    private fun completeWalk(finished: Walk) {
        val walk = finishCoverage(finished)
        val history = walks
        val fresh = freshTiles
        val counts = questTileCounts
        walks = walks + walk
        questTileCounts = questTileCounts + (walk.id to fresh.mapValues { it.value.size })
        historyRevision++
        activeWalk = null
        rodeSinceLastPoint = false
        activePath = emptyList()
        freshTiles = emptyMap()
        addedTiles = emptyMap()
        tilesRevision++
        store.save(walk)
        store.save(cities)
        recapRequest++
        if (!alwaysOn) recap = WalkRecap.make(walk, cities, fresh, foundStickers, history, clock(), counts)
        refreshProgressPicks()
        requestSync?.invoke()
        addPlacesYouveBeen()
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
        if (finishingWalkId != null) return
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
        noteWhereYouAre(point)
        prepareLoreNear(fix.coordinate, onlyIfMoved = true)
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
     * stopped for a while or ridden somewhere. Only on-foot fixes are kept, so drives
     * don't fill the phone.
     */
    private fun recordAlwaysOn(point: TrackPoint) {
        val last = activeWalk?.points?.lastOrNull()
        if (last != null && point.time - last.time > autoWalkGap) {
            finishAutoWalk()
            // Leave these fixes out rather than run the next outing onto the end of this one.
            if (activeWalk != null) return
        }
        // In a car or on a bike, by the motion chip or a trustworthy GPS speed.
        if (activeWalk != null && (point.wheels == true ||
                (point.accuracy >= 0 && point.accuracy <= CoverageTracer.MAX_ACCURACY && (point.speed ?: 0.0) > CoverageTracer.MAX_SPEED))
        ) {
            rodeSinceLastPoint = true
        }
        val anchor = tracer.anchor
        var step = tracer.add(point)
        if (step.samples.isEmpty()) return
        // The tracer's last spot can be hours old when the GPS has been off (the first fix
        // after a restart, then nothing until you head out). Start from this fix instead, or
        // the walk says it began back then: Dad's 16:20 walk on 30 Oct 2026 ran from 11:00.
        if (activeWalk == null && anchor != null && point.time - anchor.time > FRESH_START) return
        // Only decided once you're walking on from the new spot, so one bad fix can't
        // end a walk.
        val walkEnd = activeWalk?.points?.lastOrNull()
        if (walkEnd != null && anchor != null && rode(walkEnd, anchor)) {
            rideArrival = anchor
            finishAutoWalk()
            // Still waiting on its step count. The next walk starts from the arrival
            // once that's in.
            if (activeWalk != null) return
            // Finishing started the tracer again from the arrival, so this is the same step.
            step = tracer.add(point)
        }
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
        rodeSinceLastPoint = false
        if (autoWalkPending) {
            walk = walk.copy(distance = walk.distance + step.distance)
            if (displacement(walk.points) >= AUTO_WALK_CONFIRM_DISTANCE) {
                // It's a real walk: uncover everything since it started in one go.
                autoWalkPending = false
                val samples = CoverageTracer.samples(walk.points)
                activePath = samples
                val uncovered = visit(samples, point.time)
                walk = walk.copy(newTiles = walk.newTiles + uncovered)
                revealCount += uncovered
            }
        } else {
            walk = apply(step, point, walk)
        }
        activeWalk = walk
        saveIfDue()
    }

    /**
     * You've turned up somewhere you can't have walked to from the walk's last spot:
     * too far too fast, or the phone saw you riding in between.
     */
    private fun rode(last: TrackPoint, start: TrackPoint): Boolean {
        val distance = last.coordinate.distance(start.coordinate)
        if (distance <= CoverageTracer.MAX_GAP) return false
        val elapsed = start.time - last.time
        return rodeSinceLastPoint || elapsed <= 0 || distance / elapsed > CoverageTracer.MAX_SPEED
    }

    /** How far a pending walk has got from where it started, in metres. */
    val pendingWalkDistance: Double get() = activeWalk?.let { displacement(it.points) } ?: 0.0

    private fun apply(step: CoverageTracer.Step, point: TrackPoint, walk: Walk): Walk {
        var result = walk.copy(distance = walk.distance + step.distance)
        if (step.samples.isEmpty()) return result
        val origin = step.origin
        if (origin != null && activePath.lastOrNull() != origin) activePath = activePath + origin
        activePath = activePath + point.coordinate
        val uncovered = visit(step.samples, point.time)
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
        val walk = activeWalk ?: return
        if (!walk.isAutomatic) return
        val end = if (byYou) now() else walk.points.lastOrNull()?.let { SwiftDate.epoch(it.time) } ?: walk.startedAt
        withSteps(walk, end) { completeAutoWalk(it, byYou) }
    }

    private fun completeAutoWalk(finished: Walk, byYou: Boolean) {
        var walk = finished
        val wasPending = autoWalkPending
        walk = finishCoverage(walk)
        val fresh = freshTiles
        autoWalkPending = false
        activeWalk = null
        rodeSinceLastPoint = false
        activePath = emptyList()
        freshTiles = emptyMap()
        addedTiles = emptyMap()
        tracer = CoverageTracer()
        tracer.restart(from = rideArrival)
        rideArrival = null
        tilesRevision++
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
        addPlacesYouveBeen()
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

    /**
     * Marks these points as visited in every city, walked at [time] (seconds since
     * 1970). Returns how many tiles were new.
     */
    private fun visit(points: List<Coordinate>, time: Double): Int {
        var uncovered = 0
        val updated = cities.toMutableList()
        val mistDays = mistDays
        for (i in updated.indices) {
            val original = updated[i]
            val (visitedCity, fresh) = original.visit(points, shape(original))
            // Every tile walked gets today's date, clearing any mist over it. That
            // changes nothing else: no tiles, %, shells or quests.
            val walked = visitedCity.noteWalked(points, time, mistDays)
            val visited = walked.city
            if (walked.changed && fresh.isEmpty()) {
                updated[i] = visited.copy(updatedAt = now())
                if (walked.cleared.isNotEmpty()) tilesRevision++
            }
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
            .mapNotNull { (id, hex) -> loreEntry(id)?.let { it to hex } }
            .sortedBy { it.first.title }

    /**
     * A pin another phone put down for one of the server's secrets, before this phone
     * has heard from the server about that place. It stays, so the secret keeps the
     * same tile on every phone.
     */
    private fun waitingForServer(id: String, city: City): Boolean {
        val osmId = city.osmId ?: return false
        return id.startsWith("osm$osmId-") && !serverLore.hasAnswered(osmId)
    }

    /**
     * A secret by id, bundled or from the server. This model's own server secrets,
     * rather than what LoreLibrary was last handed (loreEntry in AppModel.swift).
     */
    private fun loreEntry(id: String): LoreEntry? = LoreLibrary.bundledEntry(id) ?: serverLore.entry(id)

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
        val assigned = LoreLibrary.assign(LoreLibrary.bundled, cities, serverLore.byPlace) { city, point ->
            shape(city).contains(city.grid.projection.project(point))
        }
        var changed = false
        val updated = cities.toMutableList()
        for (i in updated.indices) {
            val wanted = assigned[updated[i].id].orEmpty().mapTo(HashSet()) { it.id }
            val placed = updated[i].stickers ?: continue
            val leaving = placed.keys.filter { it !in wanted && foundStickers[it] == null && !waitingForServer(it, updated[i]) }
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
        val entries = ids.mapNotNull(::loreEntry)
        val at = if (notify) now() else SwiftDate.distantFuture
        foundStickers = foundStickers + entries.associate { it.id to at }
        store.saveStickers(foundStickers)
        if (popUp) stickerQueue = stickerQueue + entries
        if (notify && entries.isNotEmpty()) secretsFound?.invoke(entries)
        refreshProgressPicks()
        requestSync?.invoke()
        return entries.size
    }

    // Secrets from the server

    /** Secrets that have just come from the server, or a place that's turned out quiet, for a note on the map. */
    var loreNotice: LoreNotice? = null
        private set

    /** [count] is how many arrived; none means there wasn't much to find there. */
    data class LoreNotice(val id: UUID, val name: String, val count: Int)

    private var refreshingLore = false
    /** Places to ask about straight after the ask that's going. */
    private val loreAgain = HashSet<Long>()
    /** Tests stand in for lore:forPlace and the sticker download. */
    var askForLore: (suspend (Long) -> ServerLore.Answer)? = null
    var downloadSticker: (suspend (String) -> ByteArray)? = null

    /** One of your places the server's still looking for secrets in, the selected one first, for a line on the map. */
    val lookingForSecrets: City?
        get() {
            val looking = cities.filter { city -> city.osmId?.let { serverLore.place(it)?.status?.isLooking } == true }
            return looking.firstOrNull { it.id == selectedCityId } ?: looking.firstOrNull()
        }

    /** The note's been seen or tapped. */
    fun dismissLoreNotice() {
        if (loreNotice == null) return
        loreNotice = null
        onChange()
    }

    /**
     * Asks the server about your places without bundled secrets that are due a look
     * ([ServerLore.due]), and [now] straight away. Called when the app opens, after
     * each sync and every couple of minutes while it's open. With none of those places,
     * or none due, it makes no calls at all.
     */
    fun refreshLore(now: Long? = null) {
        val scope = services ?: return
        lastLocation?.let { prepareLoreNear(it.coordinate) }
        scope.launch { updateLore(now) }
    }

    // Secrets for the suburbs round you

    private var lorePrep = LorePrep()
    private var preparingLore = false
    /** Where and when the suburbs round you were last looked at, so it isn't on every fix. */
    private var lorePrepSpot: Coordinate? = null
    private var lorePrepCheckedAt = Double.NEGATIVE_INFINITY
    /** Tests stand in for lore:prepare. */
    var prepareLore: (suspend (List<Long>) -> Unit)? = null

    /**
     * Asks the server to start on secrets for the suburb you're in and the ones next to
     * it ([LorePrep]), when that list changes, or again after half an hour for the same
     * list. Only signed in, and fire-and-forget: if it fails, it's just logged. Called
     * when the app opens and after each sync, and as you move about ([onlyIfMoved]:
     * once you've gone 100 m or a few minutes have passed since the last look).
     */
    private fun prepareLoreNear(here: Coordinate, onlyIfMoved: Boolean = false) {
        val scope = services ?: return
        if (prepareLore == null && makePlaceClient == null) return
        val now = clock()
        val last = lorePrepSpot
        if (onlyIfMoved && last != null && last.distance(here) < LORE_PREP_MOVE && now - lorePrepCheckedAt < LORE_PREP_CHECK) return
        lorePrepSpot = here
        lorePrepCheckedAt = now
        if (preparingLore) return
        val ids = LorePrep.around(
            here,
            cities.map { LorePrep.Suburb(it.osmId, it.boundary) },
            nearby.map { LorePrep.Suburb(it.osmId, it.boundary) },
        ) { id -> id in LoreLibrary.bundledOsmIds || serverLore.place(id)?.status == ServerLore.Status.Bundled }
        if (!lorePrep.due(ids, now)) return
        preparingLore = true
        val generation = dataGeneration
        scope.launch {
            try {
                val send = prepareLore ?: run {
                    // Signed out: nothing's noted as asked, so it asks once you've signed in.
                    val client = makePlaceClient?.invoke() ?: return@launch
                    val call: suspend (List<Long>) -> Unit = { list ->
                        client.mutation("lore:prepare", buildJsonObject { put("osmIds", JsonArray(list.map(::JsonPrimitive))) })
                    }
                    call
                }
                if (generation != dataGeneration) return@launch
                // Noted before asking, so a server that keeps failing isn't asked again on every fix.
                lorePrep = lorePrep.asked(ids, clock())
                send(ids)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.info("Couldn't ask the server to get secrets ready nearby: $e")
            } finally {
                preparingLore = false
            }
        }
    }

    suspend fun updateLore(now: Long? = null) {
        now?.let { loreAgain.add(it) }
        if (refreshingLore) return
        val (trimmed, unused) = serverLore.keepingOnly(cities.mapNotNullTo(HashSet()) { it.osmId }, foundStickers)
        serverLore = trimmed
        if (unused.isNotEmpty()) {
            for (id in unused) store.deleteServerSticker(id)
            loreChanged(emptyList())
        }
        val askable = serverLore.askable(cities)
        val due = serverLore.due(askable, now()) + loreAgain.filter { it in askable }.sorted()
        loreAgain.clear()
        if (due.isEmpty()) return
        refreshingLore = true
        try {
            val generation = dataGeneration
            val client = if (askForLore == null || downloadSticker == null) makePlaceClient?.invoke() ?: return else null
            val ask: suspend (Long) -> ServerLore.Answer = askForLore ?: { osmId ->
                ServerLore.Answer.from(client!!.query("lore:forPlace", buildJsonObject { put("osmId", osmId) }))
            }
            val download: suspend (String) -> ByteArray = downloadSticker ?: { url -> client!!.download(url) }
            val arrived = ArrayList<Pair<Long, ServerLore.Change>>()
            var changed = false
            for (osmId in due.distinct()) {
                if (generation != dataGeneration) return
                val answer = try {
                    ask(osmId)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (generation != dataGeneration) return
                    log.info("Couldn't ask about secrets for $osmId: $e")
                    serverLore = serverLore.asked(osmId, now())
                    continue
                }
                if (generation != dataGeneration) return
                val version = serverLore.place(osmId)?.version
                val (taken, change) = serverLore.taking(answer, osmId, now(), foundStickers)
                serverLore = taken
                if (serverLore.place(osmId)?.version != version) changed = true
                for ((id, url) in change.stickers.toSortedMap()) {
                    // One that won't download is tried again on the next ask.
                    val png = try {
                        download(url)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        null
                    }
                    if (png == null || !ServerLore.isPng(png)) continue
                    if (generation != dataGeneration) return
                    store.saveServerSticker(png, id)
                    serverLore = serverLore.copy(savedStickers = serverLore.savedStickers + (id to url))
                    changed = true
                }
                if (change.arrived.isNotEmpty() || change.quiet) arrived += osmId to change
            }
            store.saveServerLore(serverLore)
            // Most asks just say it's the same as before, and change nothing on the map.
            if (changed || arrived.isNotEmpty()) loreChanged(arrived)
            onChange()
        } finally {
            refreshingLore = false
        }
        if (loreAgain.isNotEmpty()) refreshLore()
    }

    /**
     * The server's secrets have changed: hand them to the views, hide the new ones
     * under their place's tiles (leaving every sticker already placed where it is, and
     * dropping any taken down that you hadn't found), and say what's arrived.
     */
    private fun loreChanged(arrived: List<Pair<Long, ServerLore.Change>>) {
        LoreLibrary.useServer(serverLore, store.serverStickers)
        placeStickers()
        unlockArrivedSecrets()
        for ((osmId, change) in arrived) {
            val city = cities.firstOrNull { it.osmId == osmId } ?: continue
            loreNotice = LoreNotice(city.id, city.name, change.arrived.size)
            break
        }
    }

    /**
     * Pins already down for server secrets that hadn't arrived yet (say another phone
     * placed them) on tiles you've walked. Walking there couldn't find a secret this
     * phone didn't have, and [placeStickers] keeps the pin rather than placing it again,
     * so they're yours now, counted like newly placed ones.
     */
    private fun unlockArrivedSecrets() {
        for (city in cities) {
            val arrived = city.stickers.orEmpty().filter { (id, hex) ->
                foundStickers[id] == null && hex in city.visited &&
                    LoreLibrary.bundledEntry(id) == null && serverLore.entry(id) != null
            }
            if (arrived.isEmpty()) continue
            // Just these pins, so a bundled one under a walked tile is left as it was.
            secretsAlreadyWalked += unlockStickers(city.copy(stickers = arrived), city.visited, notify = false, popUp = false)
        }
    }

    // Places

    /**
     * [selecting]: pick it and fly there. Places that add themselves while you've got
     * others don't take you away from what you're looking at. [builtFrom]: the walks it
     * was built with ([walksToBuildWith]). The rest, ones that have ended since and ones
     * the auto-add hadn't finished with, are walked into it here, and the tiles they
     * uncover are new on them, so they count for those walks' quests too.
     */
    fun add(city: City, selecting: Boolean = true, builtFrom: List<Walk>? = null) {
        // Already one of yours: the same suburb added by hand and found by itself, or
        // added on another phone and synced meanwhile. Just go there.
        val have = cities.firstOrNull { it.id == city.id || (city.osmId != null && it.osmId == city.osmId) }
        if (have != null) {
            if (selecting) select(have.id)
            return
        }
        val shape = city.shape()
        var walked = city
        val uncovered = HashMap<UUID, Pair<Set<Hex>, Set<Hex>>>()
        if (builtFrom != null) {
            val had = builtFrom.mapTo(HashSet()) { it.id }
            // In the order they were walked, so a tile two of them crossed is the first one's.
            for (walk in walks.filter { it.id !in had }.sortedWith(Progression.walkedFirst)) {
                val (visited, fresh) = walked.visit(CoverageTracer.samples(walk.points), shape)
                if (fresh.isNotEmpty()) uncovered[walk.id] = fresh to (fresh - walked.tiles)
                walked = visited
            }
        }
        val added = walkActiveWalk(walked, shape).copy(updatedAt = now())
        cities = cities + added
        placesRevision++
        rebuildCountingTiles()
        credit(uncovered, added.id)
        shapes[added.id] = shape
        // Its dates for the mist come from your walks, even if the walk you're on gave it some.
        lastWalkedPending.add(added.id)
        if (selecting) select(added.id)
        placeStickers()
        tilesRevision++
        store.save(cities)
        refreshProgressPicks()
        requestSync?.invoke()
        refreshNeighbours()
        fillInLastWalked()
        onChange()
    }

    /**
     * The walks a place is built with: all but the ones the auto-add hasn't finished
     * with yet, the walk that's just ended say, which [add] walks into it afterwards so
     * the tiles they uncover there count for their quests. Older walks only uncover its
     * tiles, as they always have for a place added by hand, rather than changing quests
     * from weeks ago.
     */
    private fun walksToBuildWith(): List<Walk> {
        val due = autoPlaces.due(walks, now()).mapTo(HashSet()) { it.id }
        return walks.filter { it.id !in due }
    }

    /**
     * Tiles a place that's just been added uncovered on finished walks it wasn't built
     * with ([uncovered]: each walk's new tiles, and those it added to the place's tiles).
     * They're new on those walks, as if it had been one of your places when you walked
     * them, so they count for their quests. A tile a walk already had for this place (it
     * was deleted and added again, say) isn't counted twice.
     */
    private fun credit(uncovered: Map<UUID, Pair<Set<Hex>, Set<Hex>>>, placeId: UUID) {
        val key = placeId.uuidString
        val changed = ArrayList<UUID>()
        walks = walks.map { walk ->
            val (tiles, added) = uncovered[walk.id] ?: return@map walk
            val hexes = walk.newTileHexesByPlace ?: return@map walk
            val had = hexes[key].orEmpty()
            val all = had + tiles
            if (all.size == had.size) return@map walk
            val before = walk.addedTilesByPlace
            val grew = if (added.isEmpty()) before else before.orEmpty() + (key to (before?.get(key).orEmpty() + added))
            val credited = walk.copy(
                newTileHexesByPlace = hexes + (key to all),
                newTilesByPlace = walk.newTilesByPlace.orEmpty() + (key to all.size),
                addedTilesByPlace = grew,
                newTiles = walk.newTiles + all.size - had.size,
            )
            store.save(credited)
            changed.add(walk.id)
            credited
        }
        if (changed.isEmpty()) return
        // Deduplicated against every other walk the way the next launch's backfill does,
        // so the two always agree.
        val counts = questTileCounts.toMutableMap()
        for ((id, n) in Progression.placeCounts(placeId, walks, cities)) counts[id] = counts[id].orEmpty() + (placeId to n)
        questTileCounts = counts
        historyRevision++
        // Already uploaded, most likely, so they go up again with the new tiles.
        walksChanged?.invoke(changed)
    }

    /**
     * A place added partway through a walk gets the walk so far, as if it had been
     * there all along: its tiles count, and are new on this walk.
     */
    private fun walkActiveWalk(city: City, shape: BoundaryShape): City {
        // A walk that adds itself uncovers everything since it started once it's sure
        // it's a walk, and this place will be among them then.
        val walk = activeWalk ?: return city
        if (autoWalkPending) return city
        val timed = CoverageTracer.timedSamples(walk.points)
        val (visited, fresh) = city.visit(timed.samples, shape)
        val dated = timed.times.lastOrNull()?.let { visited.noteWalked(timed.samples, it, mistDays).city } ?: visited
        if (fresh.isEmpty()) return dated
        freshTiles = freshTiles + (city.id to (freshTiles[city.id].orEmpty() + fresh))
        addedTiles = addedTiles + (city.id to (addedTiles[city.id].orEmpty() + (fresh - city.tiles)))
        activeWalk = walk.copy(newTiles = walk.newTiles + fresh.size)
        return dated
    }

    /** Place search adds to your own places, with your walks so far replayed into it. */
    suspend fun addPlace(place: PlaceResult, status: (String) -> Unit) {
        // Already one of yours, say it added itself: no need to fetch it again.
        val have = place.osmId?.let { osmId -> cities.firstOrNull { it.osmId == osmId } }
        if (have != null) {
            select(have.id)
            return
        }
        val generation = dataGeneration
        val builtFrom = walksToBuildWith()
        val build = buildPlace
        val city = if (build != null) build(place, builtFrom) else CityBuilder.build(place, builtFrom, makePlaceClient?.invoke(), osm, status)
        if (generation != dataGeneration) throw CancellationException("Signed out while adding ${place.name}")
        add(city, builtFrom = builtFrom)
        autoPlaces = autoPlaces.added(place)
        saveAutoPlaces()
    }

    /**
     * Deletes a place on purpose, so sync deletes it from the account too. Its walks
     * are kept. A place that's just missing, say from a file that wouldn't load,
     * is never deleted from the account.
     */
    fun deleteCity(id: UUID) {
        val deleting = cities.firstOrNull { it.id == id } ?: return
        // Deleted on purpose, so it doesn't add itself again next time you walk there.
        autoPlaces = autoPlaces.decline(deleting)
        saveAutoPlaces()
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

    /**
     * The box around your places, grown by this many metres each way. When they're
     * spread far apart (a holiday suburb that added itself, say), it's just the ones
     * near the selected place, so the suburbs nearby are looked up for one area at a
     * time rather than for everywhere in between.
     */
    private fun box(metres: Double): Boundary.Bounds? {
        val all = neighbourhoodPlaces().map { it.boundary.bounds }
        if (all.isEmpty()) return null
        val south = all.minOf { it.south }
        val west = all.minOf { it.west }
        val north = all.maxOf { it.north }
        val east = all.maxOf { it.east }
        val dLat = metres / 111_320
        val dLon = dLat / max(0.1, cos((south + north) / 2 * Math.PI / 180))
        return Boundary.Bounds(south - dLat, west - dLon, north + dLat, east + dLon)
    }

    /** Your places close enough together to share one list of neighbours. */
    private fun neighbourhoodPlaces(): List<City> {
        val all = cities.map { it.boundary.bounds }
        if (all.isEmpty()) return cities
        val corner = Coordinate(all.minOf { it.south }, all.minOf { it.west })
        val across = corner.distance(Coordinate(all.maxOf { it.north }, all.maxOf { it.east }))
        val centre = (selectedCity ?: cities.first()).boundary.centre
        if (across <= NEIGHBOURHOOD_SPAN) return cities
        return cities.filter { it.boundary.centre.distance(centre) <= NEIGHBOURHOOD_SPAN / 2 }
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
                lastLocation?.let { prepareLoreNear(it.coordinate) }
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
            // The suburbs next to you may be in it now.
            lastLocation?.let { prepareLoreNear(it.coordinate) }
            onChange()
        }
    }

    private var refreshingStreets = false

    /**
     * Places built before the current WalkableRule (busy roads used to count) get
     * their street tiles worked out again, once each, quietly in the background
     * (refreshStreets in AppModel.swift). Visited tiles, credits, stickers and secrets
     * are kept; only which tiles count, and so the clouds and %, change. Waits for a
     * server that has the new streets. Walks carry on recording meanwhile: only the
     * tile sets are swapped at the end.
     */
    fun refreshStreets() {
        val scope = services ?: return
        scope.launch { updateStreets() }
    }

    suspend fun updateStreets() {
        val makeClient = makePlaceClient ?: return
        if (refreshingStreets || cities.none { (it.streetsVersion ?: 0) < WalkableRule.VERSION }) return
        refreshingStreets = true
        try {
            val generation = dataGeneration
            val client = makeClient() ?: return
            for (id in cities.filter { (it.streetsVersion ?: 0) < WalkableRule.VERSION }.map { it.id }) {
                if (generation != dataGeneration) return
                val city = cities.firstOrNull { it.id == id } ?: continue
                val ways: List<OSMWay>
                val version: Int
                try {
                    val osmId = city.osmId
                    if (osmId != null) {
                        val cached = PlaceData.fetch(osmId, client)
                        // An older server's streets aren't filtered yet. Try again another time.
                        version = cached.streetsVersion ?: return
                        ways = cached.ways
                    } else {
                        val b = city.boundary.bounds
                        ways = osm.walkableWays(b.south, b.west, b.north, b.east)
                        version = WalkableRule.VERSION
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    log.info("Couldn't update the streets for ${city.name}: $e")
                    continue
                }
                val (tiles, roads) = withContext(Dispatchers.Default) {
                    val inside = City.hexes(BoundaryShape(city.boundary, HexGrid.projection), HexGrid)
                    CityBuilder.streetTiles(ways, inside) to CityBuilder.roadLines(ways)
                }
                if (generation != dataGeneration) return
                val i = cities.indexOfFirst { it.id == id }
                if (i < 0 || (cities[i].streetsVersion ?: 0) >= version) continue
                cities = cities.toMutableList().also {
                    it[i] = it[i].replacingStreetTiles(tiles, roads, version).copy(updatedAt = now())
                }
                placesRevision++
                tilesRevision++
                rebuildCountingTiles()
                store.save(cities)
                requestSync?.invoke()
                onChange()
            }
        } finally {
            refreshingStreets = false
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

    // Places that add themselves

    /**
     * Whether the map's on screen. Only a fix while it is can add where you are: one in
     * the background could be from a car.
     */
    var inForeground = false
        private set
    /**
     * Set when the map comes on screen, so the next good fix is checked for a suburb to
     * add, and cleared when it goes. Never when the process starts in the background
     * for always-on: only walks add places then.
     */
    var checkSpotOnNextFix = false
    /** Where you were when the app opened, until it's been checked. */
    private var spotToCheck: AutoPlaces.Spot? = null
    /**
     * Every place in the account has come down since the app opened or you signed in,
     * so a suburb that adds itself can't be a second copy of one the account has.
     */
    var accountPulled = false
        private set
    private var autoAdding = false
    private var autoAddAgain = false
    private var autoAddJob: Job? = null
    /** While your first place is being found and built, for the place chip. */
    var findingFirstPlace = false
        private set
    /** A place that's just added itself while you had others, for a note on the map. */
    var addedPlaceNotice: AddedPlace? = null
        private set

    data class AddedPlace(val id: UUID, val name: String)

    /** Tests stand in for OpenStreetMap and the street download (for adding by hand too). */
    var lookUpSuburb: (suspend (Coordinate) -> AutoPlaces.Lookup)? = null
    var buildPlace: (suspend (PlaceResult, List<Walk>) -> City)? = null

    /**
     * Until your first tile clears, the map says to go for a walk. Tiles only ever get
     * uncovered, so once one has this never shows again.
     */
    val showWalkHint: Boolean get() = cities.isNotEmpty() && cities.none { it.visited.isNotEmpty() }

    /** The note's been seen or tapped. */
    fun dismissAddedPlaceNotice() {
        if (addedPlaceNotice == null) return
        addedPlaceNotice = null
        onChange()
    }

    /**
     * The map's come on screen, or gone from it. Coming back looks again at where you
     * are; going clears that, so a fix from later (in a car, say) can't count.
     */
    fun foreground(active: Boolean) {
        inForeground = active
        checkSpotOnNextFix = active
        if (!active) spotToCheck = null
    }

    /**
     * The first good fix after the map comes on screen. If it's not in one of your
     * places, or near one, its suburb adds itself. Fixes moving faster than a walk, or
     * that the motion chip says are on wheels, are passed over for the next.
     */
    fun noteWhereYouAre(fix: TrackPoint) {
        if (!checkSpotOnNextFix || !inForeground || clock() - fix.time > 60) return
        if (fix.accuracy < 0 || fix.accuracy > AutoPlaces.SPOT_ACCURACY) return
        if (fix.wheels == true || motion.onWheels || (fix.speed ?: 0.0) > CoverageTracer.MAX_SPEED) return
        checkSpotOnNextFix = false
        spotToCheck = AutoPlaces.Spot(fix.coordinate, fix.accuracy)
        addPlacesYouveBeen()
    }

    /** Sync has pulled every place in the account, so a suburb that adds itself now won't be one the account already had. */
    fun pulledAccount() {
        accountPulled = true
        addPlacesYouveBeen()
    }

    /**
     * Adds the suburbs you've been in that aren't one of your places yet: where you
     * were when the app opened, and wherever walks since the last check went on foot.
     * Called when the app opens, when a walk ends and after each sync, never from
     * moving the map about. One run at a time, and one lookup at a time within it.
     */
    fun addPlacesYouveBeen() {
        val scope = services ?: return
        if (!accountPulled) return
        if (autoAdding) {
            autoAddAgain = true
            return
        }
        autoAdding = true
        autoAddAgain = false
        val generation = dataGeneration
        autoAddJob = scope.launch {
            try {
                addPlacesYouveBeen(generation)
            } finally {
                // Signing out resets all this itself.
                if (generation == dataGeneration) {
                    autoAdding = false
                    findingFirstPlace = false
                    onChange()
                    if (autoAddAgain) addPlacesYouveBeen()
                }
            }
        }
    }

    /** Waits for any run of [addPlacesYouveBeen], for tests. */
    suspend fun waitForPlacesYouveBeen() {
        while (autoAdding) autoAddJob?.join() ?: return
    }

    private suspend fun addPlacesYouveBeen(generation: Int) {
        val due = autoPlaces.due(walks, now())
        val tracks = withContext(Dispatchers.Default) { due.map { CoverageTracer.samples(it.points) } }
        var lookups = 0
        // Hexes asked about this time, so one whose answer was one of your own places
        // isn't asked about again straight away.
        val asked = HashSet<Hex>()
        // Every round adds a place, asks about a spot or stops, so this is only a backstop.
        repeat(100) {
            if (generation != dataGeneration) return
            val auto = autoPlaces
            val here = spotToCheck
            val known = nearby
            val skip = HashSet(asked)
            val places = cities.map(::shape)
            val isYours = isYours(cities)
            val now = now()
            val next = withContext(Dispatchers.Default) { auto.next(here, tracks, places, known, isYours, skip, now) }
            if (generation != dataGeneration) return
            when (next) {
                AutoPlaces.Next.Nothing -> {
                    if (spotToCheck == here) spotToCheck = null
                    autoPlaces = autoPlaces.checked(due)
                    saveAutoPlaces()
                    return
                }
                AutoPlaces.Next.Later -> return
                is AutoPlaces.Next.Add -> {
                    finding(cities.isEmpty())
                    // Whether it's added or its streets wouldn't download (and it waits its
                    // turn), round again for the rest.
                    autoAdd(next.place, generation)
                }
                is AutoPlaces.Next.LookUp -> {
                    if (lookups >= AutoPlaces.LOOKUPS_PER_RUN) return
                    lookups++
                    asked.add(HexGrid.hex(containing = next.point))
                    finding(cities.isEmpty())
                    val found = try {
                        val look = lookUpSuburb
                        if (look != null) look(next.point) else osm.suburb(next.point)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        if (generation != dataGeneration) return
                        log.info("Couldn't find the suburb at a spot, trying again later: $e")
                        autoPlaces = autoPlaces.lookUpFailed(now())
                        saveAutoPlaces()
                        return
                    }
                    if (generation != dataGeneration) return
                    autoPlaces = autoPlaces.looked(next.point, found, isYours(cities), now())
                    saveAutoPlaces()
                }
            }
        }
    }

    private fun finding(first: Boolean) {
        if (findingFirstPlace == first) return
        findingFirstPlace = first
        onChange()
    }

    /**
     * Builds and adds a suburb that's added itself. Your first place is selected and
     * the map flies there. Otherwise it's only selected if you're standing in it, and
     * a note on the map says it's been added. If its streets won't download, it waits
     * longer each time before it's tried again.
     */
    private suspend fun autoAdd(place: PlaceResult, generation: Int) {
        val builtFrom = walksToBuildWith()
        val city = try {
            val build = buildPlace
            if (build != null) build(place, builtFrom) else CityBuilder.build(place, builtFrom, makePlaceClient?.invoke(), osm) {}
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (generation != dataGeneration) return
            log.info("Couldn't add ${place.name} by itself, trying again later: $e")
            autoPlaces = autoPlaces.failedToBuild(place, now())
            saveAutoPlaces()
            return
        }
        if (generation != dataGeneration) return
        // Deleted while this one was downloading: it stays in `found`, so its spots
        // aren't asked about again, and isn't added.
        if (autoPlaces.isDeclined(place)) return
        autoPlaces = autoPlaces.added(place)
        saveAutoPlaces()
        // Added by hand, or pulled from the account, while this one was downloading.
        if (isYours(place)) return
        val first = cities.isEmpty()
        add(city, selecting = first, builtFrom = builtFrom)
        if (!first) {
            val spot = spotToCheck?.point
            if (spot != null && shape(city).contains(city.grid.projection.project(spot))) {
                selectedCityId = city.id
                settings.selectedCity = city.id.uuidString
            }
            addedPlaceNotice = AddedPlace(city.id, city.name)
            onChange()
        }
    }

    /** One of your places already: the same OSM boundary, or for places saved before those were kept, the same name. */
    private fun isYours(place: PlaceResult): Boolean = isYours(cities)(place)

    private fun saveAutoPlaces() {
        autoPlaces = autoPlaces.tidied(now())
        store.saveAutoPlaces(autoPlaces)
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
                val (streets, hadMore) = city.merged(remote)
                merged[i] = streets.copy(updatedAt = if (hadMore) now() else maxOf(city.lastChanged, remote.lastChanged))
            } else {
                merged.add(remote)
                if (remote.lastWalked == null) lastWalkedPending.add(remote.id)
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
            val walkedBy = HashMap<UUID, MutableList<Walk>>()
            for (walk in snapshotWalks) {
                val targets = out.indices.filter { out[it].id in changedCities || walk.id in newIds }
                if (targets.isEmpty()) continue
                val samples = CoverageTracer.samples(walk.points)
                for (i in targets) {
                    out[i] = out[i].visit(samples, shapes[i]).first
                    walkedBy.getOrPut(out[i].id) { ArrayList() }.add(walk)
                }
            }
            // When the walks just pulled (from a phone that doesn't keep dates yet, say)
            // last crossed each tile, for the mist.
            val lastWalked = HashMap<UUID, Map<Hex, Int>>()
            for (city in out) {
                val walks = walkedBy[city.id] ?: continue
                Mist.lastWalked(listOf(city), walks)[city.id]?.let { lastWalked[city.id] = it }
            }
            Triple(out, Progression.backfill(snapshotWalks, out), lastWalked)
        }
        if (generation != dataGeneration) return
        // Location fixes can arrive while the worker runs. Union its result so no
        // live coverage is overwritten by the snapshot it started with.
        cities = cities.map { city ->
            val again = restored.first.firstOrNull { it.id == city.id } ?: return@map city
            // Only the visited ones: the rest of its tiles are the snapshot's, which a
            // street update since then may have changed.
            val walked = restored.third[city.id]?.takeIf { it.isNotEmpty() }
            city.copy(visited = city.visited + again.visited, tiles = city.tiles + again.visited).mergingLastWalked(walked)
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
        fillInLastWalked()
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
        finishingWalkId = null
        dataGeneration++
        // Dropped rather than finished, so turning always-on off below can't save it.
        activeWalk = null
        rodeSinceLastPoint = false
        rideArrival = null
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
        lastWalkedPending.clear()
        afterHistory.clear()
        historyRevision++
        nearby = emptyList()
        warmedNeighbourIds = null
        nearbyRetries = 0
        lorePrep = LorePrep()
        lorePrepSpot = null
        selectedCityId = null
        settings.selectedCity = null
        placeYouOnNextFix = true
        autoPlaces = AutoPlaces(walksSince = now())
        spotToCheck = null
        // Ready for whoever signs in next, if you're looking. Not when a sync in the
        // background has found someone else signed in: that fix could be from anywhere.
        checkSpotOnNextFix = inForeground
        accountPulled = false
        autoAdding = false
        autoAddAgain = false
        findingFirstPlace = false
        addedPlaceNotice = null
        serverLore = ServerLore()
        loreNotice = null
        loreAgain.clear()
        LoreLibrary.useServer(serverLore, store.serverStickers)
        tilesRevision++
        store.wipe()
        onChange()
    }

    // Mist

    /**
     * Works out when each tile was last walked from the saved walks, once for each
     * place saved before that was kept (or added since), in the background
     * ([historyScope]; straight away in tests). Walks carry on recording meanwhile:
     * the dates are merged in, the later one winning.
     */
    private fun fillInLastWalked() {
        for (city in cities) if (city.lastWalked == null) lastWalkedPending.add(city.id)
        lastWalkedPending.retainAll(cities.mapTo(HashSet()) { it.id })
        if (fillingLastWalked || lastWalkedPending.isEmpty()) return
        fillingLastWalked = true
        val ids = HashSet(lastWalkedPending)
        val generation = dataGeneration
        val places = cities.filter { it.id in ids }
        val routes = walks
        fun install(found: Map<UUID, Map<Hex, Int>>) {
            fillingLastWalked = false
            if (generation != dataGeneration) return
            cities = cities.map { city -> found[city.id]?.let { city.mergingLastWalked(it) } ?: city }
            lastWalkedPending.removeAll(ids)
            if (found.values.any { it.isNotEmpty() }) tilesRevision++
            // Not marked as changed: the other phone works out the same from the same
            // walks, and it goes up with the place's next change.
            store.save(cities)
            fillInLastWalked()
            onChange()
        }
        val scope = historyScope
        if (scope == null) {
            install(Mist.lastWalked(places, routes))
        } else {
            scope.launch { install(withContext(Dispatchers.Default) { Mist.lastWalked(places, routes) }) }
        }
    }

    private fun shape(city: City): BoundaryShape = shapes.getOrPut(city.id) { city.shape() }

    private fun now() = SwiftDate.epoch(clock())

    companion object {
        /**
         * Shorter than this and it wasn't really a walk: pottering round the house, or
         * GPS drift. Any tiles it uncovered stay uncovered.
         */
        const val MINIMUM_AUTO_WALK = 300.0

        /** Seconds the tracer's last spot can be old and still start a new always-on walk. */
        const val FRESH_START = 120.0

        /**
         * An always-on walk only counts once you've got this far (metres, as the crow
         * flies) from where it started. GPS indoors can wander tens of metres back and
         * forth, which adds up as distance but never carries you this far away.
         */
        const val AUTO_WALK_CONFIRM_DISTANCE = 150.0

        /**
         * How far around your places to look for suburbs, in metres, for adding themselves
         * as you walk in. Twice this is fetched and kept, so walking on into the next
         * suburb over doesn't mean fetching again.
         */
        const val NEIGHBOURHOOD = 5000.0

        /** Metres corner to corner. Places spread wider than this get neighbours only around the selected one. */
        const val NEIGHBOURHOOD_SPAN = 60_000.0

        /** The suburbs round you are looked at again once you've moved this many metres... */
        const val LORE_PREP_MOVE = 100.0
        /** ...or this many seconds have passed. */
        const val LORE_PREP_CHECK = 300.0

        private val log: Logger = Logger.getLogger("walkies.places")

        /** [isYours] for these places, to take off the main thread. */
        private fun isYours(cities: List<City>): (PlaceResult) -> Boolean {
            val mine = cities.map { it.osmId to it.name }
            return { place ->
                mine.any { (osmId, name) ->
                    if (place.osmId != null && osmId != null) place.osmId == osmId else name.equals(place.name, ignoreCase = true)
                }
            }
        }

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
