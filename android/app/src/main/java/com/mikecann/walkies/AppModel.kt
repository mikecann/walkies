package com.mikecann.walkies

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.BoundaryShape
import com.mikecann.walkies.place.City
import com.mikecann.walkies.store.Store
import java.util.UUID

/** What the model needs to know about location permission. LocationTracker on the phone, a fake in tests. */
interface LocationAccess {
    enum class Authorization { NotDetermined, Denied, Allowed }

    val authorization: Authorization
    fun requestPermission()
}

/**
 * What the motion chip thinks you're doing (MotionMonitor.swift). Activity Recognition
 * comes with stage 3; until then nothing's known and the GPS speed does the filtering.
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
}

/**
 * Places and walks, and turning GPS fixes into uncovered tiles: the walk side of
 * AppModel.swift. Lives on the main thread. Calls [onChange] after anything changes,
 * so the UI can redraw.
 *
 * Not ported yet: progression and recaps (stage 5), secrets placement and pop-ups
 * (stage 5), sync and the world-grid rebuild (stage 4).
 */
class AppModel(
    private val store: Store,
    private val settings: Settings,
    private val location: LocationAccess,
    private val motion: Motion = Motion.Unknown,
    /** Seconds since 1970. */
    private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
) {
    var onChange: () -> Unit = {}

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
