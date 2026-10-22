package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.Walk
import java.util.UUID
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Tiles you walked but haven't walked again for a while go misty: a pale haze over
 * them, nothing more. Your %, tiles, shells, XP, quests and secrets never change
 * because of it. Walking through a misty tile clears it again. Mist.swift.
 *
 * When each tile was last walked is [City.lastWalked]: whole minutes since 1970 (UTC)
 * by tile, saved as `[[q, r, minute], ...]` like the iPhone.
 */
object Mist {
    const val DEFAULT_DAYS = 60.0

    /**
     * A tile walked within this many seconds isn't noted again as you walk round it,
     * so a walk doesn't change the place every few steps. Misty tiles always are.
     */
    const val REFRESH = 3600.0

    /** Whole minutes since 1970, from seconds since 1970. */
    fun minute(seconds: Double): Int = floor(seconds / 60).toInt()

    fun isMisty(minute: Int, now: Double, days: Double) = now - minute * 60.0 > days * 86_400

    /**
     * The misty tiles across all these places at [now] (seconds since 1970): walked, and
     * not walked again for [days]. A tile in two places goes by whichever saw you last.
     * Tiles with no walk on record (cleared for free beside one, or from before anything
     * was kept) never mist.
     */
    fun tiles(cities: List<City>, now: Double, days: Double): Set<Hex> {
        val latest = HashMap<Hex, Int>()
        for (city in cities) {
            val walked = city.lastWalked ?: continue
            for ((hex, minute) in walked) {
                if (hex !in city.visited) continue
                latest[hex] = max(latest[hex] ?: minute, minute)
            }
        }
        return latest.filterValues { isMisty(it, now, days) }.keys
    }

    /**
     * Changes as often as tiles could newly mist over while the app's open, for the
     * clouds to look again: hourly, or more often with a short `mistDays`.
     */
    fun epoch(now: Double, days: Double): Long {
        val step = min(3600.0, max(30.0, days * 86_400 / 4))
        return floor(now / step).toLong()
    }

    /**
     * When each place's tiles were last walked, worked out from the saved walks' routes
     * (the time each spot was passed) and the dated tile credits. Only tiles in
     * `visited` are noted: the ones cleared for free beside a walk never mist. Traces
     * each walk once for all the places. Slow for a long history: off the main thread.
     */
    fun lastWalked(cities: List<City>, walks: List<Walk>): Map<UUID, Map<Hex, Int>> {
        val out = cities.associate { it.id to HashMap<Hex, Int>() }
        for (city in cities) {
            val walked = out.getValue(city.id)
            for (credit in city.tileCredits.orEmpty()) {
                val minute = minute(credit.at.epochSeconds)
                for (hex in credit.hexes) if (hex in city.visited) record(walked, hex, minute)
            }
        }
        for (walk in walks) {
            val timed = CoverageTracer.timedSamples(walk.points)
            val latest = HashMap<Hex, Int>()
            for (i in timed.samples.indices) {
                val hex = HexGrid.hex(containing = timed.samples[i])
                val minute = minute(timed.times[i])
                latest[hex] = max(latest[hex] ?: Int.MIN_VALUE, minute)
            }
            for (city in cities) {
                val walked = out.getValue(city.id)
                for ((hex, minute) in latest) if (hex in city.visited) record(walked, hex, minute)
            }
        }
        return out
    }

    /** Keeps whichever is later. */
    fun record(into: MutableMap<Hex, Int>, hex: Hex, minute: Int) {
        val old = into[hex]
        if (old == null || minute > old) into[hex] = minute
    }

    /** Both, the later date for every tile. */
    fun merged(mine: Map<Hex, Int>?, theirs: Map<Hex, Int>?): Map<Hex, Int>? {
        if (theirs == null) return mine
        val out = LinkedHashMap(mine.orEmpty())
        for ((hex, minute) in theirs) record(out, hex, minute)
        return out
    }

    /** Any tile walked later in [mine] than in [theirs], or not there at all. */
    fun hasLater(mine: Map<Hex, Int>?, theirs: Map<Hex, Int>?): Boolean =
        mine.orEmpty().any { (hex, minute) -> theirs?.get(hex)?.let { minute > it } ?: true }
}

/** What [City.noteWalked] did: whether anything changed, and the misty tiles it cleared. */
data class Walked(val city: City, val changed: Boolean, val cleared: Set<Hex>)

/**
 * Notes the tiles under these points as walked at [time] (seconds since 1970), for
 * the mist. Call it after [City.visit], so only tiles that count are noted.
 */
fun City.noteWalked(points: List<Coordinate>, time: Double, mistDays: Double): Walked {
    val minute = Mist.minute(time)
    val walked = LinkedHashMap(lastWalked.orEmpty())
    var changed = false
    val cleared = LinkedHashSet<Hex>()
    val seen = HashSet<Hex>()
    for (point in points) {
        val hex = grid.hex(containing = point)
        if (!seen.add(hex) || hex !in visited) continue
        val old = walked[hex]
        if (old != null) {
            if (Mist.isMisty(old, time, mistDays)) {
                cleared.add(hex)
            } else if (time - old * 60.0 < Mist.REFRESH || old >= minute) {
                continue
            }
        }
        Mist.record(walked, hex, minute)
        changed = true
    }
    return Walked(if (changed) copy(lastWalked = walked) else this, changed, cleared)
}

/** Keeps the later date for every tile. */
fun City.mergingLastWalked(other: Map<Hex, Int>?): City =
    if (other == null) this else copy(lastWalked = Mist.merged(lastWalked, other))
