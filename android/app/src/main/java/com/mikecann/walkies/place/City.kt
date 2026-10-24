package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.uuidString
import java.util.UUID
import kotlin.math.floor

/** A place you're exploring (City.swift). Saved in the same JSON as the iPhone app. */
data class City(
    val id: UUID = UUID.randomUUID(),
    val name: String,
    /** The rest of the place name, e.g. "Busselton, Western Australia, Australia". */
    val detail: String,
    val osmId: Long? = null,
    val gridVersion: Int? = HexGrid.VERSION,
    val boundary: Boundary,
    /**
     * Tiles that count towards completion: every tile in the boundary with a street or
     * path through it, plus any other tile in the boundary you've actually been to.
     */
    val tiles: Set<Hex>,
    val visited: Set<Hex>,
    /**
     * Streets and paths drawn as dotted lines over the clouds. Null for cities
     * saved before we kept them.
     */
    val roads: List<RoadLine>? = null,
    /** Which tile each lore sticker is hidden under, by lore id. */
    val stickers: Map<String, Hex>? = null,
    val createdAt: SwiftDate = SwiftDate.now(),
    /** When anything about it last changed on this phone, so sync knows to send it. */
    val updatedAt: SwiftDate? = null,
    /**
     * Coverage from confirmed automatic outings too short to keep in walk history.
     * These records travel with the place so tile quests retain their date and identity.
     */
    val tileCredits: List<TileCredit>? = null,
    /**
     * The WalkableRule.VERSION its street tiles were worked out with. Null for places
     * built before busy roads were left out; the app redoes their tiles once.
     */
    val streetsVersion: Int? = null,
    /**
     * When each walked tile was last walked, in whole minutes since 1970, for the mist
     * (Mist.kt). Null for places saved before it was kept; the app works it out once
     * from the saved walks.
     */
    val lastWalked: Map<Hex, Int>? = null,
) {
    data class TileCredit(val id: UUID, val at: SwiftDate, val hexes: Set<Hex>)

    fun mergeTileCredits(other: City): City {
        val credits = LinkedHashMap<UUID, TileCredit>()
        for (credit in tileCredits.orEmpty()) credits.putIfAbsent(credit.id, credit)
        for (credit in other.tileCredits.orEmpty()) {
            val old = credits[credit.id]
            credits[credit.id] = if (old != null) {
                old.copy(hexes = old.hexes + credit.hexes, at = minOf(old.at, credit.at))
            } else {
                credit
            }
        }
        if (credits.isEmpty()) return this
        return copy(tileCredits = credits.values.sortedBy { it.id.uuidString })
    }

    val lastChanged: SwiftDate get() = updatedAt ?: createdAt

    /**
     * New street tiles from a newer WalkableRule, keeping everything you've done: the
     * tiles you've been to (credits included) and the ones hiding a secret stay tiles.
     * The rest of the place becomes no-path, so the clouds and % follow.
     */
    fun replacingStreetTiles(streetTiles: Set<Hex>, roads: List<RoadLine>?, version: Int): City {
        val kept = HashSet(streetTiles)
        kept.addAll(visited)
        for (credit in tileCredits.orEmpty()) kept.addAll(credit.hexes)
        kept.addAll(stickers.orEmpty().values)
        return copy(tiles = kept, roads = roads ?: this.roads, streetsVersion = version)
    }

    /** All places and all users use the world grid. */
    val grid get() = HexGrid

    val progress: Double get() = if (tiles.isEmpty()) 0.0 else visited.size.toDouble() / tiles.size

    fun shape() = BoundaryShape(boundary, grid.projection)

    data class Cover(val clouded: Set<Hex>, val clear: Set<Hex>, val blocked: Set<Hex>)

    /**
     * Which tiles in the boundary are under cloud and which are clear. Tiles with no
     * street or path (bush, wetland, canals) don't count towards 100%, and can't be
     * walked to. Instead, a whole patch of them clears at once the moment you walk a
     * tile beside it, spreading through every no-path tile it touches.
     * `blocked` is the no-path tiles still under cloud.
     */
    fun cloudCover(): Cover {
        val inside = InsideTiles.hexes(this)
        val noPath = inside - tiles
        val clear = visited.toHashSet()
        val queue = ArrayDeque(visited)
        while (queue.isNotEmpty()) {
            val hex = queue.removeLast()
            for (n in hex.neighbours) {
                if (n in noPath && n !in clear) {
                    clear.add(n)
                    queue.addLast(n)
                }
            }
        }
        return Cover((inside + tiles) - clear, clear, noPath - clear)
    }

    /** Marks the tiles under these points as visited. Returns the city and the tiles that are new. */
    fun visit(points: List<Coordinate>, within: BoundaryShape): Pair<City, Set<Hex>> {
        val fresh = LinkedHashSet<Hex>()
        for (point in points) {
            val h = grid.hex(containing = point)
            if (h in visited || h in fresh) continue
            if (h !in tiles && !within.contains(grid.centre(h))) continue
            fresh.add(h)
        }
        return copy(visited = visited + fresh, tiles = tiles + fresh) to fresh
    }

    /**
     * Takes in another copy of the same place, from the account or another phone:
     * every tile either has walked, credits, secrets and mist dates (the merge in
     * City.swift). Street tiles come from the copy with the newer WalkableRule, so a
     * phone that hasn't updated can't bring busy roads back. Tiles you've been to stay.
     * Also says whether this copy had anything the other didn't, so it should be sent
     * back up. Keeps this one's id and updatedAt.
     */
    fun merged(other: City): Pair<City, Boolean> {
        val localCredits = tileCredits.orEmpty().mapTo(HashSet()) { it.id }
        val otherCredits = other.tileCredits.orEmpty().mapTo(HashSet()) { it.id }
        val localStreets = streetsVersion ?: 0
        val otherStreets = other.streetsVersion ?: 0
        val hadMore = !other.visited.containsAll(visited) || !otherCredits.containsAll(localCredits) ||
            localStreets > otherStreets || Mist.hasLater(lastWalked, other.lastWalked)
        val credited = mergeTileCredits(other).mergingLastWalked(other.lastWalked).copy(
            visited = visited + other.visited,
            // Theirs win, as in Swift's merging(_:uniquingKeysWith:).
            stickers = stickers.orEmpty() + other.stickers.orEmpty(),
        )
        val streets = when {
            otherStreets > localStreets -> credited.replacingStreetTiles(other.tiles, other.roads, otherStreets)
            otherStreets < localStreets -> credited.replacingStreetTiles(credited.tiles, null, localStreets)
            else -> credited.copy(tiles = credited.tiles + other.tiles)
        }
        return streets.copy(roads = streets.roads ?: other.roads) to hadMore
    }

    companion object {
        fun hexes(inside: BoundaryShape, grid: HexGrid = HexGrid): Set<Hex> =
            grid.hexes(inside.lo, inside.hi).filterTo(HashSet()) { inside.contains(grid.centre(it)) }

        /**
         * The id a place gets from its OSM relation, the same on every phone, so a
         * suburb added on two phones before they've synced (say by adding itself on
         * both) is one place in the account rather than two. City.id(forOSM:) on the
         * iPhone makes the same name-based UUID.
         */
        fun idForOsm(osmId: Long): UUID = UUID.nameUUIDFromBytes("walkies:osm-relation:$osmId".toByteArray())
    }
}

/**
 * Every tile inside each place's boundary. Testing each one against the outline is
 * the slow part of working out the clouds, and it only changes with the boundary.
 */
object InsideTiles {
    private val places = HashMap<UUID, Pair<Boundary, Set<Hex>>>()

    @Synchronized
    fun hexes(city: City): Set<Hex> {
        places[city.id]?.let { (boundary, hexes) -> if (boundary == city.boundary) return hexes }
        val hexes = City.hexes(city.shape(), city.grid)
        places[city.id] = city.boundary to hexes
        return hexes
    }
}

data class RoadLine(val kind: Kind, val points: List<Coordinate>) {
    enum class Kind { Road, Path }
}

/** "23%", or "0.4%" while you're just getting started. */
val Double.percentText: String
    get() {
        val pct = this * 100
        if (pct > 0 && pct < 10) return String.format(java.util.Locale.US, "%.1f%%", pct)
        return "${floor(pct).toInt()}%"
    }
