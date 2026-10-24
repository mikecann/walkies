package com.mikecann.walkies.model

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.place.City
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.IsoFields
import java.time.temporal.TemporalAdjusters
import java.util.UUID
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Walking earns shells. The ledger only records choices and spending, never coverage.
 * A port of Progression.swift: the same catalogue, the same seeds and the same sums,
 * so both phones show the same shells, XP and quests for the same data.
 */
object Progression {
    enum class Group(val id: String) {
        Marker("marker"), Trail("trail"), Clouds("clouds"), Cover("cover"), Celebration("celebration");

        val displayName: String
            get() = when (this) {
                Marker -> "Map marker"
                Trail -> "Trail"
                Clouds -> "Clouds"
                Cover -> "Secrets book cover"
                Celebration -> "Celebration"
            }
    }

    data class Item(
        val id: String,
        val name: String,
        /** Null for the consumable spyglass. */
        val group: Group?,
        val price: Int,
    ) {
        val isFree: Boolean get() = price == 0
    }

    val catalog: List<Item> = listOf(
        Item("marker.dot", "Classic dot", Group.Marker, 0),
        Item("marker.sneaker", "Sneaker", Group.Marker, 150),
        Item("marker.boat", "Paper boat", Group.Marker, 200),
        Item("marker.hat", "Explorer hat", Group.Marker, 250),
        Item("marker.lighthouse", "Little lighthouse", Group.Marker, 300),
        Item("trail.teal", "Teal line", Group.Trail, 0),
        Item("trail.footprints", "Footprints", Group.Trail, 150),
        Item("trail.sparkles", "Sparkles", Group.Trail, 250),
        Item("trail.rainbow", "Rainbow", Group.Trail, 400),
        Item("clouds.classic", "Classic", Group.Clouds, 0),
        Item("clouds.sunset", "Sunset", Group.Clouds, 300),
        Item("clouds.storm", "Storm", Group.Clouds, 300),
        Item("clouds.candy", "Cotton candy", Group.Clouds, 400),
        Item("cover.red", "Red leather", Group.Cover, 0),
        Item("cover.seashell", "Seashell", Group.Cover, 200),
        Item("cover.map", "Old map", Group.Cover, 200),
        Item("cover.gold", "Gold", Group.Cover, 500),
        Item("celebration.confetti", "Confetti", Group.Celebration, 0),
        Item("celebration.bubbles", "Bubbles", Group.Celebration, 200),
        Item("celebration.fireworks", "Fireworks", Group.Celebration, 250),
        Item("spyglass", "Spyglass", null, 60),
    )

    fun item(id: String): Item? = catalog.firstOrNull { it.id == id }
    const val SHELL_BAG = "shells.50"
    const val SPYGLASS_PAIR = "spyglasses.2"

    /** History always uses home time, including streak days and the current week. This keeps lifetime XP stable when the phone travels. */
    val zone: ZoneId = ZoneId.of("Australia/Perth")

    /**
     * Found in previously explored coverage, rather than discovered on a walk.
     * A future sentinel travels through the existing secret wire format. A real
     * discovery wins the server's earliest-date merge on another phone.
     */
    val exploredSecretDate = SwiftDate.distantFuture

    data class Inputs(
        val cities: List<City> = emptyList(),
        val walks: List<Walk> = emptyList(),
        val foundSecrets: Map<String, SwiftDate> = emptyMap(),
        val now: SwiftDate = SwiftDate.now(),
        /** The calendar's time zone. Weeks always start on Monday, as ISO weeks. */
        val zone: ZoneId = Progression.zone,
        /** Optional cached route analysis; independent of visited tiles and spending. */
        val newTilesByWalk: Map<UUID, Map<UUID, Int>>? = null,
        /** Avoid intersecting every tile set on each GPS fix. */
        val countingTilesByPlace: Map<UUID, Int>? = null,
        /** A live walk isn't in history yet. Its tiles must not move the favourite. */
        val unrecordedTilesByPlace: Map<UUID, Int> = emptyMap(),
        val historicalRewards: HistoricalRewards? = null,
    )

    data class HistoricalRewards(val streaks: Int, val questsByWeek: Map<Week, Int>)

    data class Earned(
        val tiles: Int = 0,
        val secrets: Int = 0,
        val milestones: Int = 0,
        val streaks: Int = 0,
        val quests: Int = 0,
    ) {
        val total: Int get() = tiles + secrets + milestones + streaks + quests
    }

    enum class QuestKind(val id: String) {
        Tiles25("tiles25"), Tiles60("tiles60"), Secret("secret"), Days3("days3"), Metres5000("metres5000"), AnotherPlace("anotherPlace");

        val target: Double
            get() = when (this) {
                Tiles25 -> 25.0
                Tiles60 -> 60.0
                Secret, AnotherPlace -> 1.0
                Days3 -> 3.0
                Metres5000 -> 5000.0
            }

        val title: String
            get() = when (this) {
                Tiles25 -> "Uncover 25 new tiles"
                Tiles60 -> "Uncover 60 new tiles"
                Secret -> "Find a secret"
                Days3 -> "Walk on 3 different days"
                Metres5000 -> "Walk 5 km"
                AnotherPlace -> "Uncover tiles in another place"
            }
    }

    data class Week(val start: SwiftDate, val end: SwiftDate, val year: Int, val number: Int)

    data class Quest(val kind: QuestKind, val progress: Double) {
        val id: String get() = kind.id
        val name: String get() = kind.title
        val target: Double get() = kind.target
        val isComplete: Boolean get() = progress >= target
        val reward: Int get() = 40
    }

    data class QuestGain(val week: Week, val kind: QuestKind, val before: Double, val after: Double) {
        val target: Double get() = kind.target
        val gained: Double get() = after - before
        val completed: Boolean get() = before < target && after >= target
    }

    data class WalkEarnings(
        val shells: Int = 0,
        val xp: Int = 0,
        val breakdown: Earned = Earned(),
        val quests: List<QuestGain> = emptyList(),
    )

    data class State(val earned: Earned, val quests: List<Quest>) {
        val xp: Int get() = earned.total
        val level: Int get() = level(xp)
        /** Total XP threshold, rather than the amount still to earn. */
        val nextLevelXP: Int get() = xp(level + 1)
    }

    fun xp(level: Int): Int = 25 * max(0, level) * max(0, level - 1)

    fun level(xp: Int): Int {
        val estimate = ((1 + sqrt(1 + max(0, xp).toDouble() / 6.25)) / 2).toInt()
        return max(1, estimate)
    }

    fun pendingLevels(xp: Int, ledger: Ledger): List<Int> {
        val level = level(xp)
        if (level < 2) return emptyList()
        val claimed = ledger.claims.mapTo(HashSet()) { it.level }
        return (2..level).filter { it !in claimed }
    }

    /**
     * The seed and ordering are portable, unlike Swift's randomly seeded Hasher.
     * Ownership is a snapshot: the same level and wardrobe always give the same menu.
     * The price ceiling grows by 50 per level, starting with 150 at level 2.
     */
    fun picks(level: Int, owned: Set<String> = emptySet()): List<String> {
        val rng = Seed(max(0, level).toLong())
        val pool = catalog.filter { it.group != null && !it.isFree && it.price <= 50 * max(3, level + 1) && it.id !in owned }.toMutableList()
        val picks = ArrayList<String>()
        while (pool.isNotEmpty() && picks.size < 3) {
            picks.add(pool.removeAt(rng.nextIndex(pool.size)).id)
        }
        if (picks.size < 3) picks.add(SHELL_BAG)
        if (picks.size < 3) picks.add(SPYGLASS_PAIR)
        // With an exhausted wardrobe there are only two distinct rewards. A second
        // bag is represented by the same choice id, so either bag is the same claim.
        if (picks.size < 3) picks.add(SHELL_BAG)
        return picks
    }

    /** The Monday-to-Monday (ISO) week holding [date] in [zone]. */
    fun week(containing: SwiftDate, zone: ZoneId): Week {
        val day = localDate(containing, zone)
        val monday = day.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
        return Week(
            start = startOf(monday, zone),
            end = startOf(monday.plusDays(7), zone),
            year = day.get(IsoFields.WEEK_BASED_YEAR),
            number = day.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR),
        )
    }

    /** Three different quests for the week. The two tile quests are the same quest at two sizes, so a week never gets both. */
    fun questKinds(week: Week): List<QuestKind> {
        val rng = Seed(week.year.toLong() * 100 + week.number.toLong())
        val pool = QuestKind.entries.toMutableList()
        val picked = ArrayList<QuestKind>()
        while (picked.size < 3 && pool.isNotEmpty()) {
            val kind = pool.removeAt(rng.nextIndex(pool.size))
            picked.add(kind)
            if (kind == QuestKind.Tiles25) pool.remove(QuestKind.Tiles60)
            if (kind == QuestKind.Tiles60) pool.remove(QuestKind.Tiles25)
        }
        return picked
    }

    /**
     * Finished walks belong to the local week they started in. Secret dates are
     * independent, so a discovery just after midnight goes in its actual week.
     */
    fun quests(week: Week, inputs: Inputs): List<Quest> = quests(week, inputs, inputs.newTilesByWalk ?: placeTileCounts(inputs))

    private fun quests(week: Week, inputs: Inputs, counts: Map<UUID, Map<UUID, Int>>): List<Quest> =
        questKinds(week).map { Quest(it, questProgress(it, week, inputs, counts)) }

    fun questProgress(kind: QuestKind, week: Week, inputs: Inputs): Double =
        questProgress(kind, week, inputs, inputs.newTilesByWalk ?: placeTileCounts(inputs))

    private fun inWeek(walk: Walk, week: Week, now: SwiftDate) =
        walk.endedAt != null && walk.startedAt >= week.start && walk.startedAt < week.end && walk.startedAt <= now

    private fun questProgress(kind: QuestKind, week: Week, inputs: Inputs, counts: Map<UUID, Map<UUID, Int>>): Double {
        val walks = inputs.walks.filter { inWeek(it, week, inputs.now) }
        val coverage = tileRecords(inputs.walks, inputs.cities)
        val weeklyCoverage = coverage.filter { inWeek(it, week, inputs.now) }
        return when (kind) {
            QuestKind.Tiles25, QuestKind.Tiles60 ->
                weeklyCoverage.sumOf { walk -> counts[walk.id].orEmpty().values.sum() }.toDouble()
            QuestKind.Secret ->
                inputs.foundSecrets.values.count { it >= week.start && it < week.end && it <= inputs.now }.toDouble()
            QuestKind.Days3 -> walks.mapTo(HashSet()) { localDate(it.startedAt, inputs.zone) }.size.toDouble()
            QuestKind.Metres5000 -> weeklyDistance(week, inputs.walks, inputs.now)
            QuestKind.AnotherPlace -> {
                // Freeze the favourite at the start of the week. Otherwise finding tiles
                // elsewhere could change the favourite and undo a completed quest.
                val before = HashMap(inputs.countingTilesByPlace ?: countingTiles(inputs.cities))
                for ((id, n) in inputs.unrecordedTilesByPlace) before[id] = (before[id] ?: 0) - n
                for (walk in coverage) {
                    if (walk.startedAt < week.start) continue
                    for ((id, n) in counts[walk.id].orEmpty()) before[id] = (before[id] ?: 0) - n
                }
                val favourite = inputs.cities.sortedWith { a, b ->
                    val na = max(0, before[a.id] ?: 0)
                    val nb = max(0, before[b.id] ?: 0)
                    if (na == nb) a.id.uuidString.compareTo(b.id.uuidString) else nb.compareTo(na)
                }.firstOrNull()?.id
                if (weeklyCoverage.any { walk -> counts[walk.id].orEmpty().any { it.key != favourite && it.value > 0 } }) 1.0 else 0.0
            }
        }
    }

    /**
     * Deduplicate before filtering the week, including an outing recorded on either
     * side of midnight on Monday by two phones. Only walks within a day of the week
     * can overlap one in it, so the rest are left out of the (quadratic) deduplication.
     */
    fun weeklyDistance(week: Week, walks: List<Walk>, now: SwiftDate): Double {
        val from = week.start.plus(-24 * 3600.0)
        val to = week.end.plus(24 * 3600.0)
        val nearby = walks.filter { walk ->
            val end = walk.endedAt ?: return@filter false
            walk.startedAt <= now && end >= from && walk.startedAt < to
        }
        return distinctOutings(nearby)
            .filter { it.startedAt >= week.start && it.startedAt < week.end }
            .fold(0.0) { total, walk -> total + walk.distance }
    }

    /**
     * When two devices record most of the same outing, use the longer distance.
     * More than half the shorter time range must overlap. Exactly half stays separate.
     */
    fun distinctOutings(walks: List<Walk>): List<Walk> {
        val ordered = walks.sortedWith { a, b ->
            when {
                a.distance != b.distance -> b.distance.compareTo(a.distance)
                a.startedAt != b.startedAt -> a.startedAt.compareTo(b.startedAt)
                else -> a.id.uuidString.compareTo(b.id.uuidString)
            }
        }
        fun overlaps(walk: Walk, other: Walk): Boolean {
            if (walk.id == other.id) return true
            val end = walk.endedAt ?: return false
            val otherEnd = other.endedAt ?: return false
            val duration = min(end.sinceReference - walk.startedAt.sinceReference, otherEnd.sinceReference - other.startedAt.sinceReference)
            val overlap = minOf(end, otherEnd).sinceReference - maxOf(walk.startedAt, other.startedAt).sinceReference
            return duration > 0 && overlap > duration / 2
        }
        val kept = ArrayList<Walk>()
        val grouped = HashSet<Int>()
        for (index in ordered.indices) {
            if (index in grouped) continue
            // The first member has the greatest distance. Follow all overlaps so
            // a third phone cannot add the same outing through a shorter bridge.
            kept.add(ordered[index])
            grouped.add(index)
            val pending = arrayListOf(index)
            while (pending.isNotEmpty()) {
                val member = pending.removeAt(pending.size - 1)
                for (candidate in ordered.indices) {
                    if (candidate in grouped || !overlaps(ordered[member], ordered[candidate])) continue
                    grouped.add(candidate)
                    pending.add(candidate)
                }
            }
        }
        return kept
    }

    /**
     * Tile-only outings share the existing coverage calculation, but never enter
     * walk history or the distance, day and streak calculations.
     */
    private fun tileRecords(walks: List<Walk>, cities: List<City>): List<Walk> {
        val credits = LinkedHashMap<UUID, Walk>()
        val savedIds = walks.mapTo(HashSet()) { it.id }
        for (city in cities) {
            val key = city.id.uuidString
            for (credit in city.tileCredits.orEmpty()) {
                if (credit.id in savedIds) continue
                val record = credits[credit.id] ?: Walk(
                    id = credit.id, startedAt = credit.at, endedAt = credit.at,
                    newTilesByPlace = emptyMap(), newTileHexesByPlace = emptyMap(),
                )
                val hexes = record.newTileHexesByPlace.orEmpty()[key].orEmpty() + credit.hexes
                credits[credit.id] = record.copy(
                    newTileHexesByPlace = record.newTileHexesByPlace.orEmpty() + (key to hexes),
                    newTilesByPlace = record.newTilesByPlace.orEmpty() + (key to hexes.size),
                )
            }
        }
        return walks + credits.values
    }

    fun placeTileCounts(inputs: Inputs, onReplay: (UUID) -> Unit = {}): Map<UUID, Map<UUID, Int>> =
        backfill(inputs.walks, inputs.cities, onReplay).counts

    data class Backfill(
        val walks: List<Walk>,
        /** Effective first-discovery counts, deduplicated across devices and credits. The original per-walk records are retained for future merges. */
        val counts: Map<UUID, Map<UUID, Int>>,
    )

    /**
     * Run on a worker at load or after a batch download, then persist recovered
     * identities. Ordinary state/recap reads use the returned counts without replay.
     */
    fun backfill(walks: List<Walk>, cities: List<City>, onReplay: (UUID) -> Unit = {}): Backfill {
        val ordered = tileRecords(walks, cities).filter { it.endedAt != null }.sortedWith(walkedFirst)
        val savedIds = walks.mapTo(HashSet()) { it.id }
        val seen = HashMap<UUID, MutableSet<Hex>>()
        val result = HashMap<UUID, Map<UUID, Int>>()
        val repaired = ArrayList<Walk>()
        for (original in ordered) {
            var walk = original
            if (walk.newTileHexesByPlace == null && (walk.newTilesByPlace == null || walk.points.isNotEmpty())) {
                onReplay(walk.id)
                val samples = CoverageTracer.samples(walk.points)
                val fresh = LinkedHashMap<String, Set<Hex>>()
                for (city in cities) {
                    val tiles = samples.mapTo(HashSet()) { city.grid.hex(containing = it) }.apply { retainAll(city.tiles) }
                    fresh[city.id.uuidString] = tiles - seen[city.id].orEmpty()
                }
                walk = walk.copy(newTileHexesByPlace = fresh)
            }
            val hexes = walk.newTileHexesByPlace
            if (walk.newTilesByPlace == null && hexes != null) {
                walk = walk.copy(newTilesByPlace = hexes.mapValues { it.value.size })
            }
            if (hexes != null) {
                val counts = HashMap<UUID, Int>()
                for ((key, tiles) in hexes) {
                    val id = parseUUID(key) ?: continue
                    val already = seen.getOrPut(id) { HashSet() }
                    counts[id] = tiles.count { it !in already }
                    already.addAll(tiles)
                }
                result[walk.id] = counts
            } else {
                // Very old count-only records without route data cannot recover
                // identities. Retain their saved credit rather than deleting it.
                result[walk.id] = countsByPlaceId(walk.newTilesByPlace)
            }
            if (walk.id in savedIds) repaired.add(walk)
        }
        return Backfill(repaired, result)
    }

    /** The order tiles are first found in: by when each walk started. */
    val walkedFirst = Comparator<Walk> { a, b ->
        if (a.startedAt == b.startedAt) a.id.uuidString.compareTo(b.id.uuidString) else a.startedAt.compareTo(b.startedAt)
    }

    /**
     * Each walk's (and short outing's) first-discovery count in one place, worked out
     * as [backfill] does, for when a place that's just been added credits its tiles to
     * some walks.
     */
    fun placeCounts(placeId: UUID, walks: List<Walk>, cities: List<City>): Map<UUID, Int> {
        val key = placeId.uuidString
        val seen = HashSet<Hex>()
        val counts = HashMap<UUID, Int>()
        for (walk in tileRecords(walks, cities).filter { it.endedAt != null }.sortedWith(walkedFirst)) {
            val tiles = walk.newTileHexesByPlace?.get(key) ?: continue
            counts[walk.id] = tiles.count { it !in seen }
            seen.addAll(tiles)
        }
        return counts
    }

    /**
     * Past weeks and streaks are independent of GPS tile revisions. AppModel
     * keeps this until walks, secrets, places or the home day change.
     */
    fun historicalRewards(inputs: Inputs): HistoricalRewards {
        val input = if (inputs.countingTilesByPlace == null) inputs.copy(countingTilesByPlace = countingTiles(inputs.cities)) else inputs
        val walks = input.walks.filter { it.endedAt != null && it.startedAt <= input.now }
        val days = walks.filter { it.distance >= 300 }.mapTo(HashSet()) { localDate(it.startedAt, input.zone) }.sorted()
        var previous: LocalDate? = null
        var streak = 0
        var streaks = 0
        for (day in days) {
            streak = if (previous != null && day.toEpochDay() - previous.toEpochDay() == 1L) streak + 1 else 1
            streaks += min(25, 5 * (streak - 1))
            previous = day
        }
        val current = week(input.now, input.zone)
        val weeks = HashSet<Week>()
        for (walk in tileRecords(walks, input.cities)) if (walk.startedAt <= input.now) weeks.add(week(walk.startedAt, input.zone))
        for (date in input.foundSecrets.values) if (date <= input.now) weeks.add(week(date, input.zone))
        val counts = input.newTilesByWalk ?: placeTileCounts(input)
        val rewards = HashMap<Week, Int>()
        for (week in weeks) {
            if (week == current) continue
            rewards[week] = quests(week, input, counts).count { it.isComplete } * 40
        }
        return HistoricalRewards(streaks, rewards)
    }

    private val milestones = listOf(0.1 to 20, 0.25 to 30, 0.5 to 50, 0.75 to 75, 0.9 to 100, 1.0 to 250)

    fun state(inputs: Inputs): State {
        var input = inputs
        if (input.newTilesByWalk == null) input = input.copy(newTilesByWalk = placeTileCounts(input))
        if (input.countingTilesByPlace == null) input = input.copy(countingTilesByPlace = countingTiles(input.cities))
        var tiles = 0
        var milestoneShells = 0
        for (city in input.cities) {
            val count = input.countingTilesByPlace?.get(city.id) ?: 0
            tiles += count
            if (city.tiles.isNotEmpty()) {
                val fraction = count.toDouble() / city.tiles.size
                milestoneShells += milestones.filter { fraction >= it.first }.sumOf { it.second }
            }
        }
        val secrets = input.foundSecrets.values.count { it <= input.now } * 10
        val history = input.historicalRewards ?: historicalRewards(input)
        val counts = input.newTilesByWalk ?: placeTileCounts(input)
        val quests = quests(week(input.now, input.zone), input, counts)
        val questShells = history.questsByWeek.values.sum() + quests.count { it.isComplete } * 40
        return State(Earned(tiles, secrets, milestoneShells, history.streaks, questShells), quests)
    }

    fun walkEarnings(before: Inputs, after: Inputs): WalkEarnings {
        val beforeCounts = before.newTilesByWalk ?: placeTileCounts(before)
        val afterCounts = after.newTilesByWalk ?: placeTileCounts(after)
        val b = before.copy(newTilesByWalk = beforeCounts)
        val a = after.copy(newTilesByWalk = afterCounts)
        val old = state(b).earned
        val new = state(a).earned
        val delta = Earned(
            tiles = new.tiles - old.tiles, secrets = new.secrets - old.secrets,
            milestones = new.milestones - old.milestones, streaks = new.streaks - old.streaks,
            quests = new.quests - old.quests,
        )
        val beforeIds = b.walks.mapTo(HashSet()) { it.id }
        val weeks = HashSet<Week>()
        for (walk in a.walks) if (walk.id !in beforeIds) weeks.add(week(walk.startedAt, a.zone))
        weeks.add(week(a.now, a.zone))
        val gains = weeks.sortedBy { it.start }.flatMap { week ->
            questKinds(week).mapNotNull { kind ->
                val x = questProgress(kind, week, b, beforeCounts)
                val y = questProgress(kind, week, a, afterCounts)
                if (y > x) QuestGain(week, kind, x, y) else null
            }
        }
        return WalkEarnings(delta.total, delta.total, delta, gains)
    }

    data class Ring(val secretId: String, val centre: Coordinate, val expiresAt: SwiftDate) {
        val radius: Double get() = 125.0
    }

    /** [now] is when it's used. Times in the ledger are seconds since 1970. */
    fun spyglass(city: City, from: Coordinate?, found: Map<String, SwiftDate>, now: SwiftDate, id: String = UUID.randomUUID().uuidString): Ledger.Spyglass? {
        val origin = from ?: city.boundary.centre
        val candidates = city.stickers.orEmpty().filter { found[it.key] == null }
        fun distance(hex: Hex) = origin.distance(city.grid.projection.unproject(city.grid.centre(hex)))
        val nearest = candidates.entries.sortedWith { a, b ->
            val da = distance(a.value)
            val db = distance(b.value)
            if (da == db) a.key.compareTo(b.key) else da.compareTo(db)
        }.firstOrNull() ?: return null
        val rng = Seed(hash(nearest.key))
        val angle = java.lang.Long.remainderUnsigned(rng.next(), 1_000_000).toDouble() / 1_000_000 * 2 * PI
        val distance = sqrt(java.lang.Long.remainderUnsigned(rng.next(), 1_000_000).toDouble() / 1_000_000) * 120
        val centre = city.grid.projection.unproject(city.grid.centre(nearest.value) + Vec2(cos(angle), sin(angle)) * distance)
        return Ledger.Spyglass(id, nearest.key, listOf(centre.lat, centre.lon), now.epochSeconds)
    }

    fun activeRing(city: City, ledger: Ledger, found: Map<String, SwiftDate>, now: SwiftDate): Ring? =
        ledger.spyglasses
            .sortedWith { a, b -> if (a.at == b.at) b.id.compareTo(a.id) else b.at.compareTo(a.at) }
            .firstNotNullOfOrNull { use ->
                val expiry = use.at + 3 * 3600
                val usable = city.stickers?.get(use.secretId) != null && found[use.secretId] == null &&
                    use.at <= now.epochSeconds && now.epochSeconds < expiry && use.centre.size == 2
                if (usable) Ring(use.secretId, Coordinate(use.centre[0], use.centre[1]), SwiftDate.epoch(expiry)) else null
            }

    /** FNV-1a over the UTF-8 bytes. */
    private fun hash(value: String): Long =
        value.toByteArray(Charsets.UTF_8).fold(-3750763034362895579L) { h, byte -> (h xor (byte.toLong() and 0xff)) * 1_099_511_628_211L }

    /** The same 64-bit LCG as Swift's, with wrapping arithmetic and unsigned remainders. */
    private class Seed(private var value: Long) {
        fun next(): Long {
            value = value * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
            return value
        }

        fun nextIndex(count: Int) = java.lang.Long.remainderUnsigned(next(), count.toLong()).toInt()
    }

    // Helpers

    fun countingTiles(cities: List<City>): Map<UUID, Int> {
        val out = HashMap<UUID, Int>()
        for (city in cities) {
            val n = if (city.tiles.size < city.visited.size) city.tiles.count { it in city.visited } else city.visited.count { it in city.tiles }
            out[city.id] = max(out[city.id] ?: 0, n)
        }
        return out
    }

    fun countsByPlaceId(byKey: Map<String, Int>?): Map<UUID, Int> {
        val out = HashMap<UUID, Int>()
        for ((key, n) in byKey.orEmpty()) {
            val id = parseUUID(key) ?: continue
            out[id] = (out[id] ?: 0) + n
        }
        return out
    }

    private fun parseUUID(key: String): UUID? = runCatching { UUID.fromString(key) }.getOrNull()

    fun localDate(date: SwiftDate, zone: ZoneId): LocalDate = instant(date).atZone(zone).toLocalDate()

    private fun instant(date: SwiftDate): Instant {
        val seconds = date.epochSeconds
        val whole = floor(seconds)
        return Instant.ofEpochSecond(whole.toLong(), ((seconds - whole) * 1e9).toLong())
    }

    private fun startOf(day: LocalDate, zone: ZoneId): SwiftDate = SwiftDate.epoch(day.atStartOfDay(zone).toEpochSecond().toDouble())
}

/** Presentation values for a level bar. XP remains lifetime earnings, even after spending. LevelMeter.swift. */
class LevelMeter(xp: Int) {
    val xp: Int = max(0, xp)
    val level: Int get() = Progression.level(xp)
    val start: Int get() = Progression.xp(level)
    val end: Int get() = Progression.xp(level + 1)
    val fraction: Double get() = (xp - start).toDouble() / (end - start)

    data class Fill(val level: Int, val from: Double, val to: Double)

    companion object {
        /**
         * Fill each crossed level before starting the next bar. An exact threshold
         * ends on the new level's empty bar, rather than leaving the old one full.
         */
        fun fills(from: Int, to: Int): List<Fill> {
            val first = LevelMeter(from)
            val last = LevelMeter(max(from, to))
            return (first.level..last.level).map { level ->
                Fill(level, if (level == first.level) first.fraction else 0.0, if (level == last.level) last.fraction else 1.0)
            }
        }
    }
}
