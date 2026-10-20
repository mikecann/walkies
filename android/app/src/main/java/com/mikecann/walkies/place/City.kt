package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import java.util.UUID
import kotlin.math.floor

/** A place you're exploring. Only what the map needs so far; City.swift has the rest. */
data class City(
    val id: UUID = UUID.randomUUID(),
    val name: String,
    /** The rest of the place name, e.g. "Busselton, Western Australia, Australia". */
    val detail: String,
    val osmId: Long? = null,
    val boundary: Boundary,
    /**
     * Tiles that count towards completion: every tile in the boundary with a street or
     * path through it, plus any other tile in the boundary you've actually been to.
     */
    val tiles: Set<Hex>,
    val visited: Set<Hex>,
    /** Streets and paths drawn as dotted lines over the clouds. */
    val roads: List<RoadLine>? = null,
) {
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

    companion object {
        fun hexes(inside: BoundaryShape, grid: HexGrid = HexGrid): Set<Hex> =
            grid.hexes(inside.lo, inside.hi).filterTo(HashSet()) { inside.contains(grid.centre(it)) }
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
