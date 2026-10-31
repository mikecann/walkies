package com.mikecann.walkies.lore

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.WorldProjection
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.BoundaryShape
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max

/**
 * Asks the server to start researching secrets for the suburbs round you
 * (`lore:prepare`, shared/lore-api.md), so they're more likely to be ready by the time
 * you walk into one: the suburb you're in and the ones next to it. Places add
 * themselves as you walk in, so without this you'd always arrive before the secrets.
 * This is the deciding part, kept apart from the network so it can be tested: which
 * suburbs, and whether it's time to ask. Only kept in memory, so a restart may ask
 * once more.
 */
data class LorePrep(
    /** What was last asked for, sorted. */
    val lastIds: List<Long> = emptyList(),
    /** When, in seconds since 1970. */
    val lastAt: Double = Double.NEGATIVE_INFINITY,
) {
    /** A suburb that could be asked about: one of your places, or one of the neighbours OpenStreetMap listed. */
    class Suburb(val osmId: Long?, val boundary: Boundary)

    /** Whether to ask for [ids] now: when they're not what was asked for last, or it was a while ago. */
    fun due(ids: List<Long>, now: Double): Boolean =
        ids.isNotEmpty() && (ids.sorted() != lastIds || now - lastAt >= SAME_SET_WAIT)

    fun asked(ids: List<Long>, now: Double) = LorePrep(ids.sorted(), now)

    companion object {
        /** The server takes at most this many at once. */
        const val MAX = 12
        /** Neighbours whose box comes within this many metres of the box of the suburb you're in. */
        const val NEAR = 500.0
        /** The same suburbs aren't asked about again for half an hour. */
        const val SAME_SET_WAIT = 30 * 60.0

        /**
         * The suburbs to ask about from [here]: the one you're in (your own places looked
         * at first, then the neighbours), if it has an OpenStreetMap relation, then the
         * [nearby] ones nearest it, at most [MAX] in all. None in [skip] (the ones the
         * app has bundled secrets for). Empty when you're in none of them.
         */
        fun around(here: Coordinate, places: List<Suburb>, nearby: List<Suburb>, skip: (Long) -> Boolean): List<Long> {
            val point = WorldProjection.project(here)
            val inside = (places + nearby).firstOrNull { suburb ->
                val b = suburb.boundary.bounds
                here.lat >= b.south && here.lat <= b.north && here.lon >= b.west && here.lon <= b.east &&
                    BoundaryShape(suburb.boundary, WorldProjection).contains(point)
            } ?: return emptyList()
            val ids = ArrayList<Long>()
            inside.osmId?.takeIf { !skip(it) }?.let(ids::add)
            val box = inside.boundary.bounds
            nearby
                .mapNotNull { suburb ->
                    val id = suburb.osmId ?: return@mapNotNull null
                    if (id in ids || id == inside.osmId || skip(id)) return@mapNotNull null
                    val gap = gap(box, suburb.boundary.bounds)
                    if (gap > NEAR) null else id to gap
                }
                .distinctBy { it.first }
                .sortedWith(compareBy({ it.second }, { it.first }))
                .forEach { (id, _) -> if (ids.size < MAX) ids.add(id) }
            return ids
        }

        /** How far apart two boxes are, in metres: none if they touch or overlap. */
        fun gap(a: Boundary.Bounds, b: Boundary.Bounds): Double {
            val dLat = max(0.0, max(b.south - a.north, a.south - b.north))
            val dLon = max(0.0, max(b.west - a.east, a.west - b.east))
            val lat = (max(a.south, b.south) + minOf(a.north, b.north)) / 2
            return hypot(dLat * METRES_PER_DEGREE, dLon * METRES_PER_DEGREE * cos(lat * PI / 180))
        }

        private const val METRES_PER_DEGREE = 111_320.0
    }
}
