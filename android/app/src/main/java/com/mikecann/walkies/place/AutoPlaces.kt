package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.WorldProjection
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Places that add themselves (issue #2, AutoPlaces.swift): the suburb you're in when
 * you open the app, and any suburb your walks go into. Only spots you've actually
 * been count, never where you've moved the map to. This is the deciding part, kept
 * apart from the network so it can be tested: for some spots, add a suburb whose
 * outline is already known, ask OpenStreetMap about one spot, or do nothing.
 * OpenStreetMap asks apps to go easy, so it's one spot at a time, a spot with no
 * suburb at all (the sea, a national park) isn't asked about again for a month, and a
 * suburb whose streets won't download waits longer each time. Saved as
 * auto-places.json, in the iPhone's JSON.
 */
data class AutoPlaces(
    /** Squares about 200 m across ([CELL_SIZE] degrees each way) where a lookup found no suburb at all, and when they can be asked about again. */
    val missedUntil: Map<String, SwiftDate> = emptyMap(),
    /**
     * Suburbs found that aren't yours: ones waiting to be added (their streets wouldn't
     * download, say, or a walk only went along their edge), and ones you deleted, so
     * the spots in them needn't be asked about again.
     */
    val found: List<PlaceResult> = emptyList(),
    /** OSM ids of places you deleted on this phone. They don't add themselves again, though you can still add one by hand. */
    val declined: Set<Long> = emptySet(),
    /**
     * Places saved before OSM ids were kept that you deleted on this phone, by name and
     * a spot inside each. A suburb with that name around that spot is the same one, so
     * it doesn't add itself again either.
     */
    val declinedPlaces: List<DeclinedPlace> = emptyList(),
    /**
     * Walks that ended before this never add places. Set the first time the app runs
     * with this, so an update never adds places from walks done before it.
     */
    val walksSince: SwiftDate? = null,
    /**
     * Walks since then whose spots have all been dealt with, by id, with when each
     * ended so old ones can be forgotten. By id rather than up to a date, so an older
     * walk that downloads after a newer one still gets looked at.
     */
    val checkedWalks: Map<String, SwiftDate> = emptyMap(),
    /** After a lookup fails (offline, or OpenStreetMap's busy), no more until this. Saved, so a restart doesn't skip the wait. */
    val lookUpAgainAt: SwiftDate? = null,
    /** Suburbs whose streets wouldn't download, by OSM id: how many times in a row, and when to try again. */
    val buildFailures: Map<String, BuildFailure> = emptyMap(),
) {
    data class BuildFailure(val count: Int, val retryAt: SwiftDate)

    /**
     * A deleted place without an OSM id. Known by name, as `isYours` knows those, and a
     * spot inside it, so a suburb with the same name somewhere else can still add itself.
     */
    data class DeclinedPlace(val name: String, val point: Coordinate)

    /** Where you were when the app opened, and how sure the GPS was (metres). */
    data class Spot(val point: Coordinate, val accuracy: Double)

    /**
     * What a lookup at a spot came back with: the suburb there, or null if there isn't
     * one. [fallback]: Overpass was down and Nominatim's reverse lookup answered
     * instead, so finding nothing only rules the spot out for a day.
     */
    data class Lookup(val place: PlaceResult?, val fallback: Boolean = false)

    /** A boundary a spot is in, as Overpass's is_in describes it. [country] is the ISO 3166-1 code, which only a country has. */
    data class Relation(val id: Long, val adminLevel: String?, val country: String? = null)

    sealed interface Next {
        /** Every spot is in one of your places, too close to one, or somewhere already ruled out. */
        data object Nothing : Next
        /**
         * Nothing to do now, but some spots are waiting for OpenStreetMap or for a
         * suburb's streets to be tried again, so these walks aren't done with yet.
         */
        data object Later : Next
        /** The suburb at a spot, from an outline that's already known. */
        data class Add(val place: PlaceResult) : Next
        /** Ask OpenStreetMap which suburb this spot is in. */
        data class LookUp(val point: Coordinate) : Next
    }

    /** What to do with a known suburb someone's been in. */
    private enum class Use {
        Add,
        /** Its streets wouldn't download, and it's not time to try again yet. */
        Later,
        /** One of yours, or one you deleted. */
        Never,
    }

    private class Outline(val place: PlaceResult, val shape: BoundaryShape, val use: Use)

    /**
     * What to do about where you were when the app opened ([here]) and the samples
     * along some walks ([tracks]), taken in order. Adds the first suburb whose outline
     * is known (one found before, or a neighbour) and that you were in: [here] outside
     * your places ([places], world-projected) by more than the margin, or a walk
     * properly into it. Otherwise asks about the first spot that needs it, or skips it
     * when it's in a place you deleted, somewhere a lookup has already ruled out, or a
     * hex already asked about this time round ([asked]).
     */
    fun next(
        here: Spot?,
        tracks: List<List<Coordinate>>,
        places: List<BoundaryShape>,
        known: List<PlaceResult>,
        isYours: (PlaceResult) -> Boolean,
        asked: Set<Hex> = emptySet(),
        now: SwiftDate,
    ): Next {
        val projection = HexGrid.projection
        val outlines = (found + known).filter(::isSuburbSized).map { place ->
            val use = when {
                isYours(place) || isDeclined(place) -> Use.Never
                waitingToBuild(place, now) -> Use.Later
                else -> Use.Add
            }
            Outline(place, BoundaryShape(place.boundary, projection), use)
        }
        val canLookUp = lookUpAgainAt?.let { now >= it } ?: true
        var waiting = false

        if (here != null) {
            val p = projection.project(here.point)
            val margin = projected(max(here.accuracy, SPOT_MARGIN), here.point)
            if (places.none { it.contains(p) || it.isNear(p, margin) }) {
                val outline = outlines.firstOrNull { it.shape.contains(p) }
                if (outline != null) {
                    when (outline.use) {
                        Use.Add -> return Next.Add(outline.place)
                        Use.Later -> waiting = true
                        Use.Never -> Unit
                    }
                } else if (HexGrid.hex(containing = here.point) !in asked && !missed(here.point, now)) {
                    if (canLookUp) return Next.LookUp(here.point)
                    waiting = true
                }
            }
        }

        for (track in tracks) {
            // Hexes of this walk already dealt with, and whether it went properly into
            // each known suburb, so each is only worked out once.
            val seen = HashSet<Hex>()
            val deep = HashMap<Int, Boolean>()
            for (point in track) {
                val hex = HexGrid.hex(containing = point)
                if (hex in seen) continue
                val p = projection.project(point)
                if (places.any { it.contains(p) }) {
                    seen.add(hex)
                    continue
                }
                // Close to the edge of one of yours. Another sample in this hex may be
                // further out, so it's not done with.
                if (places.any { it.isNear(p, projected(WALK_DEPTH, point)) }) continue
                seen.add(hex)
                val i = outlines.indexOfFirst { it.shape.contains(p) }
                if (i >= 0) {
                    val outline = outlines[i]
                    if (outline.use != Use.Add) {
                        if (outline.use == Use.Later) waiting = true
                        continue
                    }
                    val went = deep.getOrPut(i) { wentInto(outline.shape, track) }
                    if (went) return Next.Add(outline.place)
                    continue
                }
                if (hex in asked || missed(point, now)) continue
                if (canLookUp) return Next.LookUp(point)
                waiting = true
            }
        }
        return if (waiting) Next.Later else Next.Nothing
    }

    /** A lookup at [point] came back with [lookup]. */
    fun looked(point: Coordinate, lookup: Lookup, isYours: (PlaceResult) -> Boolean, now: SwiftDate): AutoPlaces {
        val place = lookup.place
        if (place == null || !isSuburbSized(place)) {
            // No suburb here at all: the sea, or a national park.
            val days = if (lookup.fallback) FALLBACK_MISS_DAYS else MISS_DAYS
            return copy(missedUntil = missedUntil + (cell(point) to now.plus(days * 24 * 3600)))
        }
        // One of yours whose outline stops just short of the spot. Nothing's remembered,
        // so the suburb next door isn't ruled out around here; the run skips the hex.
        if (isYours(place)) return this
        // Even one you deleted, so its spots needn't be asked about again.
        return if (found.any { same(it, place) }) this else copy(found = found + place)
    }

    /** A lookup failed: wait before the next. */
    fun lookUpFailed(now: SwiftDate) = copy(lookUpAgainAt = now.plus(LOOK_UP_RETRY))

    /** This suburb's streets wouldn't download. It waits 5 minutes, then 10, 20 and so on up to a day, before it's tried again. */
    fun failedToBuild(place: PlaceResult, now: SwiftDate): AutoPlaces {
        val count = (buildFailures[key(place)]?.count ?: 0) + 1
        val wait = min(BUILD_RETRY * 2.0.pow(min(count, 20) - 1), BUILD_RETRY_CAP)
        return copy(buildFailures = buildFailures + (key(place) to BuildFailure(count, now.plus(wait))))
    }

    fun waitingToBuild(place: PlaceResult, now: SwiftDate): Boolean = buildFailures[key(place)]?.let { now < it.retryAt } ?: false

    fun added(place: PlaceResult) = copy(found = found.filterNot { same(it, place) }, buildFailures = buildFailures - key(place))

    /** You deleted this place, so it doesn't add itself again. Kept in [found], if it's there, so its spots aren't asked about again. */
    fun decline(city: City): AutoPlaces {
        city.osmId?.let { return decline(it) }
        val spot = DeclinedPlace(city.name, city.boundary.labelPoint)
        return if (spot in declinedPlaces) this else copy(declinedPlaces = declinedPlaces + spot)
    }

    fun decline(osmId: Long) = copy(declined = declined + osmId)

    /** One you deleted: the same OSM boundary, or for one saved before those were kept, the same name around where it was. */
    fun isDeclined(place: PlaceResult): Boolean {
        if (place.osmId != null && place.osmId in declined) return true
        val named = declinedPlaces.filter { it.name.equals(place.name, ignoreCase = true) }
        if (named.isEmpty()) return false
        val shape = BoundaryShape(place.boundary, HexGrid.projection)
        return named.any { shape.contains(HexGrid.projection.project(it.point)) }
    }

    /** The walks whose spots still need checking: ended since [walksSince], in the last [WALK_DAYS], and not done with yet. */
    fun due(walks: List<Walk>, now: SwiftDate): List<Walk> {
        val since = maxOf(walksSince ?: SwiftDate.distantFuture, now.plus(-WALK_DAYS * 24 * 3600))
        return walks.filter { walk ->
            val ended = walk.endedAt ?: return@filter false
            ended > since && walk.id.uuidString !in checkedWalks
        }
    }

    fun checked(walks: List<Walk>) = copy(checkedWalks = checkedWalks + walks.mapNotNull { walk -> walk.endedAt?.let { walk.id.uuidString to it } })

    fun missed(point: Coordinate, now: SwiftDate): Boolean {
        val until = missedUntil[cell(point)] ?: return false
        return now < until
    }

    /**
     * Drops what's run out, so the file doesn't grow forever: misses that can be asked
     * about again, walks too old to look at, and suburbs whose streets haven't been
     * tried for a month (which start again from 5 minutes).
     */
    fun tidied(now: SwiftDate): AutoPlaces {
        val old = now.plus(-WALK_DAYS * 24 * 3600)
        return copy(
            missedUntil = missedUntil.filterValues { now < it },
            checkedWalks = checkedWalks.filterValues { it > old },
            buildFailures = buildFailures.filterValues { it.retryAt > old },
        )
    }

    /** auto-places.json, in the iPhone's JSON. */
    fun toJson(): JsonObject = buildJsonObject {
        put("missedUntil", JsonObject(missedUntil.mapValues { Codec.number(it.value.sinceReference) }))
        put("found", JsonArray(found.map(NearbyPlaces::placeJson)))
        put("declined", JsonArray(declined.sorted().map(::JsonPrimitive)))
        put("declinedPlaces", JsonArray(declinedPlaces.map { place ->
            buildJsonObject {
                put("name", place.name)
                put("point", Codec.coordinate(place.point))
            }
        }))
        walksSince?.let { put("walksSince", Codec.number(it.sinceReference)) }
        put("checkedWalks", JsonObject(checkedWalks.mapValues { Codec.number(it.value.sinceReference) }))
        lookUpAgainAt?.let { put("lookUpAgainAt", Codec.number(it.sinceReference)) }
        put("buildFailures", JsonObject(buildFailures.mapValues { (_, failure) ->
            buildJsonObject {
                put("count", failure.count)
                put("retryAt", Codec.number(failure.retryAt.sinceReference))
            }
        }))
    }

    companion object {
        /** Anything missing (from a file an earlier build wrote, say) starts empty, rather than the whole file failing to read. */
        fun from(e: JsonElement): AutoPlaces {
            val o = e as JsonObject
            fun dates(key: String) = (o[key] as? JsonObject)?.mapValues { SwiftDate((it.value as JsonPrimitive).doubleOrNull ?: throw Codec.Invalid(key)) }.orEmpty()
            fun date(key: String) = (o[key] as? JsonPrimitive)?.doubleOrNull?.let(::SwiftDate)
            return AutoPlaces(
                missedUntil = dates("missedUntil"),
                found = (o["found"] as? JsonArray)?.map(NearbyPlaces::placeResult).orEmpty(),
                declined = (o["declined"] as? JsonArray)?.mapNotNullTo(HashSet()) { (it as? JsonPrimitive)?.longOrNull }.orEmpty(),
                declinedPlaces = (o["declinedPlaces"] as? JsonArray)?.map { e ->
                    val d = e as? JsonObject ?: throw Codec.Invalid("declinedPlaces")
                    DeclinedPlace(
                        name = (d["name"] as? JsonPrimitive)?.contentOrNull ?: throw Codec.Invalid("name"),
                        point = Codec.coordinate(d["point"] ?: throw Codec.Invalid("point")),
                    )
                }.orEmpty(),
                walksSince = date("walksSince"),
                checkedWalks = dates("checkedWalks"),
                lookUpAgainAt = date("lookUpAgainAt"),
                buildFailures = (o["buildFailures"] as? JsonObject)?.mapValues { (key, value) ->
                    val f = value as? JsonObject ?: throw Codec.Invalid(key)
                    BuildFailure(
                        count = (f["count"] as? JsonPrimitive)?.intOrNull ?: throw Codec.Invalid("count"),
                        retryAt = SwiftDate((f["retryAt"] as? JsonPrimitive)?.doubleOrNull ?: throw Codec.Invalid("retryAt")),
                    )
                }.orEmpty(),
            )
        }

        const val CELL_SIZE = 0.002
        const val MISS_DAYS = 30.0
        /**
         * A spot the fallback (Nominatim's reverse lookup, when Overpass is down) found
         * nothing at is only ruled out for a day, since Overpass never answered.
         */
        const val FALLBACK_MISS_DAYS = 1.0
        /**
         * Square metres. Smaller than this is a few streets rather than a suburb, so the
         * next boundary up is used instead. The biggest is [CityBuilder.MAX_AREA].
         */
        const val MIN_AREA = 100_000.0
        /**
         * The admin_levels that can be a suburb. In England 10 is a parish, 8 a district or
         * London borough, and 6 a city that runs itself (Bristol, which has no parishes) or
         * a county, which the size limit rules out. Regions, states and countries never
         * are, and nor are the neighbourhoods some countries map at 11.
         */
        val SUBURB_LEVELS = 6..10
        /**
         * In Australia, just the localities the neighbours use (9 in WA, 10 elsewhere), so
         * a walk out along a jetty never adds a whole city council.
         */
        val AUSTRALIAN_LEVELS = 9..10
        /** Lookups in one go. The rest wait for the next time the app opens or a walk ends. */
        const val LOOKUPS_PER_RUN = 10
        /** Metres. A fix vaguer than this when the app opens could be in the suburb next door. */
        const val SPOT_ACCURACY = 50.0
        /**
         * Metres. Where you are when the app opens only counts this far (or further, if
         * the fix is vaguer) outside your places, so opening it at home near the border
         * never adds the suburb over the road.
         */
        const val SPOT_MARGIN = 50.0
        /**
         * Metres. A walk only adds a suburb it went this far into, and only spots this far
         * out of your places are looked up, so GPS wobble either side of a street that's
         * the border doesn't count.
         */
        const val WALK_DEPTH = 30.0
        /**
         * Metres. How much of a walk has to be [WALK_DEPTH] inside a suburb in one go,
         * about five of its 10 m samples in a row, so one stray fix can't add it.
         */
        const val WALK_STRETCH = 50.0
        /** Seconds after a failed lookup before the next. */
        const val LOOK_UP_RETRY = 5 * 60.0
        /**
         * Seconds after a suburb's streets first won't download, doubling each time it
         * fails again up to [BUILD_RETRY_CAP], so a broken one doesn't rerun the heavy
         * streets query every few minutes forever.
         */
        const val BUILD_RETRY = 5 * 60.0
        const val BUILD_RETRY_CAP = 24 * 3600.0
        /**
         * Walks that ended longer ago than this aren't looked at, and their ids are
         * forgotten, so [checkedWalks] stays small. Plenty of time for one from another
         * phone to download.
         */
        const val WALK_DAYS = 30.0

        fun cell(point: Coordinate) = "${floor(point.lat / CELL_SIZE).toInt()},${floor(point.lon / CELL_SIZE).toInt()}"

        fun isSuburbSized(place: PlaceResult) = place.area >= MIN_AREA && place.area <= CityBuilder.MAX_AREA

        /** Metres on the ground as world-projected units at this spot. The world projection is Mercator, true to scale only at Busselton's latitude. */
        fun projected(metres: Double, at: Coordinate) = metres * WorldProjection.scale / max(0.01, cos(at.lat * PI / 180))

        /**
         * Whether a walk went properly into a suburb: [WALK_STRETCH] metres of it in a
         * row all at least [WALK_DEPTH] inside. Walking along a street that's the
         * border, with the GPS wobbling either side, never does.
         */
        fun wentInto(shape: BoundaryShape, track: List<Coordinate>): Boolean {
            var stretch = 0.0
            var previous: Coordinate? = null
            for (point in track) {
                val p = HexGrid.projection.project(point)
                if (!shape.contains(p) || shape.isNear(p, projected(WALK_DEPTH, point))) {
                    stretch = 0.0
                    previous = null
                    continue
                }
                if (previous != null) {
                    val step = previous.distance(point)
                    // Samples are 10 m apart along a stretch the GPS joined up. A bigger
                    // jump is a gap in the walk, which starts the count again.
                    stretch = if (step <= 2 * CoverageTracer.SPACING) stretch + step else 0.0
                }
                if (stretch >= WALK_STRETCH) return true
                previous = point
            }
            return false
        }

        private fun same(a: PlaceResult, b: PlaceResult): Boolean {
            if (a.osmId != null && b.osmId != null) return a.osmId == b.osmId
            return a.name == b.name && a.detail == b.detail
        }

        private fun key(place: PlaceResult) = place.osmId?.toString() ?: "${place.name}, ${place.detail}"

        /**
         * The boundaries a spot is in that could be its suburb, smallest first: the
         * highest admin_level allowed in that country, ties by relation id. [country] is
         * for when there's no country boundary among them (Nominatim's answer, say).
         */
        fun suburbCandidates(relations: List<Relation>, country: String? = null): List<Long> {
            val australia = country.equals("AU", ignoreCase = true) || relations.any { it.country.equals("AU", ignoreCase = true) }
            val levels = if (australia) AUSTRALIAN_LEVELS else SUBURB_LEVELS
            return relations
                .mapNotNull { r -> r.adminLevel?.toIntOrNull()?.takeIf { it in levels }?.let { r.id to it } }
                .sortedWith(compareByDescending<Pair<Long, Int>> { it.second }.thenBy { it.first })
                .map { it.first }
                .distinct()
        }

        /** The suburb from these outlines, in [order] (smallest first): the first that's a sensible size, so a tiny one gives way to the next one up. */
        fun pick(places: List<PlaceResult>, order: List<Long>): PlaceResult? {
            val rank = HashMap<Long, Int>()
            for ((i, id) in order.withIndex()) rank.putIfAbsent(id, i)
            return places
                .filter { it.osmId?.let(rank::containsKey) == true }
                .sortedBy { rank[it.osmId!!] }
                .firstOrNull(::isSuburbSized)
        }
    }
}
