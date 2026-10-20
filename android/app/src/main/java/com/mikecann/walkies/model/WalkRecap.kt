package com.mikecann.walkies.model

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.place.City
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * Everything the end-of-walk celebration needs: the order tiles and secrets turned
 * up along the route, how each place moved on, and a guess at how long until
 * you've finished, and the shells, XP and quest progress the walk earned. Worked
 * out once, the moment the walk ends, so the animation never recalculates rewards.
 * WalkRecap.swift.
 */
data class WalkRecap(
    val walk: Walk,
    /** The route, as evenly spaced points. */
    val route: List<Coordinate>,
    /** Seconds into the walk at each point of [route]. */
    val routeTimes: List<Double> = emptyList(),
    val reveals: List<Reveal>,
    val secrets: List<Secret>,
    val places: List<Place>,
    val prediction: Prediction?,
    /** More new tiles than any walk before it. */
    val isBest: Boolean,
    /** The places this walk touched, as they were before it and after it. */
    val before: List<City>,
    val after: List<City>,
    /** Watching an old walk again from history: just the walk, no rewards. */
    val isRewatch: Boolean = false,
    /** Computed with the recap, so the animation never recalculates rewards. */
    val earnings: Progression.WalkEarnings = Progression.WalkEarnings(),
) {
    val shells: Int get() = earnings.shells
    val xp: Int get() = earnings.xp
    val questProgress: List<Progression.QuestGain> get() = earnings.quests

    /** A tile uncovered on the walk. [at] is how far along the route (0 to 1) you got to it. */
    data class Reveal(val place: UUID, val hex: Hex, val coordinate: Coordinate, val at: Double)

    data class Secret(val entry: LoreEntry, val coordinate: Coordinate, val at: Double)

    data class Place(
        val id: UUID,
        val name: String,
        val before: Double,
        val after: Double,
        val newTiles: Int,
        val tilesLeft: Int,
    )

    data class Prediction(
        val place: String,
        /** Walks like your recent ones it'd take to uncover every tile left. */
        val walks: Int,
        /** How often you've been walking lately, if there's enough to go on. */
        val walksPerWeek: Double?,
    ) {
        val weeks: Double? get() = walksPerWeek?.let { walks / max(it, 0.1) }
    }

    val id: UUID get() = walk.id
    val newTiles: Int get() = reveals.size

    /**
     * How long you'd been walking when the replay has drawn this far (0 to 1) along
     * the route. Read from the fixes' own times, so a stop shows up as a jump. Ends
     * on the walk's full time.
     */
    fun elapsed(progress: Double): Double {
        val total = walk.duration()
        if (progress <= 0) return 0.0
        if (progress >= 1) return total
        if (routeTimes.size <= 1) return total * progress
        val end = progress * (routeTimes.size - 1)
        val whole = end.toInt()
        val a = routeTimes[whole]
        val b = routeTimes[min(whole + 1, routeTimes.size - 1)]
        return min(total, max(0.0, a + (b - a) * (end - whole)))
    }

    companion object {
        /**
         * [cities]: every place, as it is now the walk's over. [fresh]: the tiles this
         * walk uncovered, per place. [found]: when each secret was found. [history]:
         * your other finished walks. [now] is seconds since 1970. [counts]: the model's
         * cached first-discovery tile counts per walk, before this one.
         */
        fun make(
            walk: Walk,
            cities: List<City>,
            fresh: Map<UUID, Set<Hex>>,
            found: Map<String, SwiftDate>,
            history: List<Walk>,
            now: Double = System.currentTimeMillis() / 1000.0,
            counts: Map<UUID, Map<UUID, Int>>? = null,
            lookUp: (String) -> LoreEntry? = LoreLibrary::entry,
        ): WalkRecap {
            val timed = CoverageTracer.timedSamples(walk.points)
            val route = timed.samples
            val touched = cities.filter { !fresh[it.id].isNullOrEmpty() }

            // When the route first reaches each new tile.
            val reveals = ArrayList<Reveal>()
            for (city in touched) {
                val new = fresh[city.id].orEmpty()
                val firstSeen = HashMap<Hex, Int>()
                for ((i, point) in route.withIndex()) {
                    val hex = city.grid.hex(containing = point)
                    if (hex in new && hex !in firstSeen) firstSeen[hex] = i
                }
                for (hex in new) {
                    val at = firstSeen[hex]?.let { it.toDouble() / max(route.size - 1, 1) } ?: 1.0
                    reveals.add(Reveal(city.id, hex, city.grid.projection.unproject(city.grid.centre(hex)), at))
                }
            }
            reveals.sortWith(compareBy<Reveal>({ it.at }, { it.hex.q }, { it.hex.r }))

            // Secrets found during the walk, at the moment you reached their tile.
            val end = (walk.endedAt ?: SwiftDate.epoch(now)).plus(60.0)
            val secrets = ArrayList<Secret>()
            for (city in touched) {
                for ((id, hex) in city.stickers.orEmpty()) {
                    val date = found[id] ?: continue
                    if (date < walk.startedAt || date > end) continue
                    val entry = lookUp(id) ?: continue
                    val at = reveals.firstOrNull { it.place == city.id && it.hex == hex }?.at ?: 1.0
                    secrets.add(Secret(entry, city.grid.projection.unproject(city.grid.centre(hex)), at))
                }
            }
            secrets.sortWith(compareBy<Secret>({ it.at }, { it.entry.id }))

            val before = touched.map { city ->
                city.copy(
                    visited = city.visited - fresh[city.id].orEmpty(),
                    tiles = city.tiles - walk.addedTilesByPlace?.get(city.id.uuidString).orEmpty(),
                )
            }
            val places = before.zip(touched) { old, now ->
                Place(
                    id = now.id, name = now.name,
                    before = old.progress, after = now.progress,
                    newTiles = fresh[now.id].orEmpty().size, tilesLeft = now.tiles.size - now.visited.size,
                )
            }.sortedByDescending { it.newTiles }

            val finished = history.filter { it.endedAt != null && it.id != walk.id }
            val beforeCities = cities.map { city ->
                city.copy(
                    visited = city.visited - fresh[city.id].orEmpty(),
                    tiles = city.tiles - walk.addedTilesByPlace?.get(city.id.uuidString).orEmpty(),
                )
            }
            val beforeFound = found.filterValues { it < walk.startedAt }
            val afterFound = found.filterValues { it <= end }
            // Secret timestamps are assigned while processing the last fix, slightly
            // after its GPS timestamp. Use the same inclusive window as the list above.
            val rewardDate = end
            val beforeCounts = counts ?: Progression.placeTileCounts(Progression.Inputs(cities = beforeCities, walks = finished))
            val walkCounts = walk.newTilesByPlace ?: fresh.entries.associate { it.key.uuidString to it.value.size }
            val afterCounts = beforeCounts + (walk.id to Progression.countsByPlaceId(walkCounts))
            val earnings = Progression.walkEarnings(
                Progression.Inputs(cities = beforeCities, walks = finished, foundSecrets = beforeFound, now = rewardDate, newTilesByWalk = beforeCounts),
                Progression.Inputs(cities = cities, walks = finished + walk, foundSecrets = afterFound, now = rewardDate, newTilesByWalk = afterCounts),
            )
            val elapsedTimes = timed.times.map { it - walk.startedAt.epochSeconds }
            return WalkRecap(
                walk = walk, route = route, routeTimes = elapsedTimes, reveals = reveals, secrets = secrets, places = places,
                prediction = prediction(places.firstOrNull(), walk, finished, now),
                isBest = finished.isNotEmpty() && reveals.size > (finished.maxOfOrNull { it.newTiles } ?: 0),
                before = before, after = touched, earnings = earnings,
            )
        }

        /**
         * Tiles left over the new tiles your last ten real walks averaged, and how often
         * you walk, from the last four weeks. Walks under 300 m (a dash to the letterbox)
         * don't count towards either, unless that's all there is. [now] is seconds since 1970.
         */
        fun prediction(place: Place?, walk: Walk, history: List<Walk>, now: Double): Prediction? {
            if (place == null || place.tilesLeft <= 0) return null
            val all = (history + walk).sortedBy { it.startedAt }
            val real = all.filter { it.distance >= 300 }
            val pool = real.ifEmpty { all }
            val recent = pool.takeLast(10)
            val average = recent.sumOf { it.newTiles }.toDouble() / recent.size
            if (average < 1) return null
            val walks = ceil(place.tilesLeft / average).toInt()

            val week = 7 * 24 * 3600.0
            val monthAgo = now - 28 * 24 * 3600.0
            val lately = pool.filter { it.startedAt.epochSeconds >= monthAgo }
            var perWeek: Double? = null
            val first = lately.minOfOrNull { it.startedAt.epochSeconds }
            if (lately.size >= 2 && first != null) {
                val span = max(now - first, week)
                perWeek = lately.size / (span / week)
            }
            return Prediction(place.name, walks, perWeek)
        }
    }
}
