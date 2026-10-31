package com.mikecann.walkies.map

import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.place.Boundary
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The clouds over the rest of the world: everywhere outside your places is under
 * cloud, so the whole globe starts covered and walking anywhere clears it, a park or
 * a beach that never becomes a suburb as much as a street. Your places keep their own
 * clouds, drawn by [CloudLayer]; this blanket stops at their edges, where their own
 * puffs spill over it and hide the join.
 *
 * Mapbox draws it, from tiles painted on a thread of their own (CloudBlanketSource.kt),
 * so it costs nothing a frame however much of it is on screen, follows the map onto
 * the globe zoomed right out, and only paints a tile again when your walks or places
 * change. This is the part that decides what goes in a tile, apart from Android so
 * it can be tested.
 *
 * The puffs sit on a coarser copy of the world hex grid, 2^level times the size, so
 * they're always about 40 to 80 points across and a tile only ever holds a few hundred
 * for every 256 points of it, from street level out to the whole world. Each one's always nudged the
 * same way for the same hex, so they don't swim about as you pan, and tiles meet
 * without a seam. At street level it's the world grid itself, with exactly the puff
 * a place would put on each hex.
 */
object CloudBlanket {
    /** How many points across Mapbox draws each tile at the zoom it's for. */
    const val TILE_POINTS = 512
    /**
     * And how many pixels it's painted with. Mapbox refuses a tile image that isn't
     * exactly its tile size (seen on the emulator, 31 Oct 2026), so it's one to a point:
     * softer than the place clouds' bake, which soft puffs get away with.
     */
    const val TILE_PIXELS = TILE_POINTS
    /**
     * The tile zoom at which the puffs are the world grid's own, the same size as a
     * place's: about 42 points across at that zoom, growing to 84 just before Mapbox
     * swaps to the next zoom's tiles. Each zoom further out doubles the hexes. With
     * 512-point tiles Mapbox asks for one zoom less than it would with 256.
     */
    const val FINEST_ZOOM = 14
    /** Mapbox stretches this zoom's tiles beyond it. Puffs are big and soft by then, so it doesn't show. */
    const val MAX_ZOOM = 20

    /**
     * How far a puff's sprite can reach from its hex's centre, as a multiple of the
     * hex size: its nudge plus the biggest radius ([CloudField.SPREAD] × 1.23).
     */
    private const val REACH = 0.25 + CloudField.SPREAD * 1.23

    /** Keeps the levels' layouts apart, so a coarse hex doesn't copy the fine one with the same q, r. */
    private const val LEVEL_SALT = 0x2545F4914F6CDD1DL

    private val SQRT3 = sqrt(3.0)
    private const val HALF = MapPoints.WORLD / 2

    /** The hex grid level for a tile at [zoom]: 0 (the world grid) from [FINEST_ZOOM] in, one more for each zoom out. */
    fun level(zoom: Int): Int = max(0, FINEST_ZOOM - zoom)

    /** A level's hex size, centre to corner, in map points. */
    fun hexSize(level: Int): Double = HexGrid.SIZE * MapPoints.perGridUnit * (1L shl level)

    /** The box a tile covers, as min x, min y, max x, max y in map points. */
    fun tileBox(z: Int, x: Int, y: Int): DoubleArray {
        val span = MapPoints.WORLD / (1L shl z)
        return doubleArrayOf(x * span, y * span, (x + 1) * span, (y + 1) * span)
    }

    /** One cloud of the blanket, in map points. */
    class Puff(val x: Double, val y: Double, val radius: Double, val variant: Int)

    /**
     * Every puff of [level] whose sprite could reach into the box, north first (and
     * west first on the same row) so the ones further south sit in front, the same
     * way in every tile they're drawn in.
     */
    fun puffs(level: Int, x0: Double, y0: Double, x1: Double, y1: Double): List<Puff> {
        val size = hexSize(level)
        val reach = size * REACH
        val out = ArrayList<Puff>()
        forEachHex(size, x0 - reach, y0 - reach, x1 + reach, y1 + reach) { q, r, cx, cy ->
            // As CloudField nudges and sizes a place's puffs, so at level 0 they're the same puffs.
            val hex = Hex(q, r)
            val rng = SplitMix64(if (level == 0) CloudField.hash(hex) else CloudField.hash(hex) xor (level * LEVEL_SALT))
            val x = cx + (rng.unit() - 0.5) * 0.5 * size
            val y = cy + (rng.unit() - 0.5) * 0.5 * size
            val radius = size * CloudField.SPREAD * (0.88 + rng.unit() * 0.35)
            val variant = java.lang.Long.remainderUnsigned(rng.next(), CloudField.SPRITE_COUNT.toLong()).toInt()
            if (x + radius >= x0 && x - radius <= x1 && y + radius >= y0 && y - radius <= y1) out.add(Puff(x, y, radius, variant))
        }
        out.sortWith(compareBy<Puff>({ it.y }, { it.x }))
        return out
    }

    /** The centre of a world-grid hex in map points, worked out straight from the grid (no trip through latitude and longitude). */
    fun centreX(hex: Hex, size: Double = hexSize(0)) = HALF + size * SQRT3 * (hex.q + hex.r / 2.0)
    fun centreY(hex: Hex, size: Double = hexSize(0)) = HALF - size * 1.5 * hex.r

    /**
     * Calls [action] with every hex of a grid [size] map points across whose centre is
     * in the box, and that centre. The world grid's y points north and map points' y
     * south, hence the flip.
     */
    private inline fun forEachHex(size: Double, x0: Double, y0: Double, x1: Double, y1: Double, action: (Int, Int, Double, Double) -> Unit) {
        val rowHeight = size * 1.5
        val colWidth = size * SQRT3
        // Rows by grid y, which runs the other way to map points.
        val r0 = floor((HALF - y1) / rowHeight).toInt() - 1
        val r1 = ceil((HALF - y0) / rowHeight).toInt() + 1
        for (r in r0..r1) {
            val cy = HALF - rowHeight * r
            if (cy < y0 || cy > y1) continue
            val shift = r / 2.0
            val q0 = floor((x0 - HALF) / colWidth - shift).toInt() - 1
            val q1 = ceil((x1 - HALF) / colWidth - shift).toInt() + 1
            for (q in q0..q1) {
                val cx = HALF + colWidth * (q + shift)
                if (cx >= x0 && cx <= x1) action(q, r, cx, cy)
            }
        }
    }

    /** Radius of the soft hole over each walked hex, in map points: a place's clearing. */
    val clearingRadius: Double get() = hexSize(0) * CloudField.CLEARING

    /**
     * Whether any of [hexes] has its hole reaching into the tile, so it needs painting
     * again when they're walked.
     */
    fun touches(z: Int, x: Int, y: Int, hexes: Collection<Hex>): Boolean {
        val box = tileBox(z, x, y)
        val pad = clearingRadius
        return hexes.any { hex ->
            val cx = centreX(hex)
            val cy = centreY(hex)
            cx + pad >= box[0] && cx - pad <= box[2] && cy + pad >= box[1] && cy - pad <= box[3]
        }
    }

    /**
     * Every world-grid hex these walks went through on foot: the same accepted points,
     * filled in every 10 m, that walking into a place or replaying your walks into a
     * new one uses, so what clears here is what would clear there.
     */
    fun walkedHexes(walks: Iterable<Walk>): Set<Hex> {
        val out = HashSet<Hex>()
        for (walk in walks) addWalked(walk, out)
        return out
    }

    fun addWalked(walk: Walk, into: MutableSet<Hex>) {
        for (point in CoverageTracer.samples(walk.points)) into.add(HexGrid.hex(containing = point))
    }
}

/**
 * The hexes your walks have been through, for the blanket's holes. The saved walks'
 * are worked out again only when the list of them changes; the walk you're on is added
 * on top each time, as it's short. Called off the main thread, one at a time.
 */
class WalkedHexes {
    private var from: List<Walk>? = null
    private var saved: Set<Hex> = emptySet()

    @Synchronized
    fun of(walks: List<Walk>, active: Walk?): Set<Hex> {
        if (walks !== from) {
            saved = CloudBlanket.walkedHexes(walks)
            from = walks
        }
        if (active == null || active.points.isEmpty()) return saved
        val all = HashSet(saved)
        CloudBlanket.addWalked(active, all)
        return all
    }
}

/**
 * Walked hexes' centres in map points, bucketed into squares about 3 km across so a
 * tile can find the ones under it without looking at them all.
 */
class WalkedIndex(val hexes: Set<Hex>) {
    private val buckets = HashMap<Long, DoubleArray>()

    init {
        val lists = HashMap<Long, ArrayList<Double>>()
        for (hex in hexes) {
            val x = CloudBlanket.centreX(hex)
            val y = CloudBlanket.centreY(hex)
            lists.getOrPut(key(cell(x), cell(y))) { ArrayList() }.apply { add(x); add(y) }
        }
        for ((k, list) in lists) buckets[k] = list.toDoubleArray()
    }

    /** Calls [action] with the centre of each walked hex in the box. */
    fun forEach(x0: Double, y0: Double, x1: Double, y1: Double, action: (Double, Double) -> Unit) {
        forEachBucket(x0, y0, x1, y1) { centres ->
            var i = 0
            while (i < centres.size) {
                val x = centres[i]
                val y = centres[i + 1]
                if (x >= x0 && x <= x1 && y >= y0 && y <= y1) action(x, y)
                i += 2
            }
        }
    }

    /** The buckets the box could have hexes in: just those it overlaps, or all of them for a box bigger than that. */
    private inline fun forEachBucket(x0: Double, y0: Double, x1: Double, y1: Double, action: (DoubleArray) -> Unit) {
        val bx0 = cell(x0)
        val bx1 = cell(x1)
        val by0 = cell(y0)
        val by1 = cell(y1)
        val span = (bx1 - bx0 + 1).toDouble() * (by1 - by0 + 1)
        if (span > buckets.size) {
            for (centres in buckets.values) action(centres)
            return
        }
        for (bx in bx0..bx1) for (by in by0..by1) buckets[key(bx, by)]?.let(action)
    }

    private fun cell(v: Double): Int = floor(v / BUCKET).toInt()

    private fun key(bx: Int, by: Int): Long = (bx.toLong() shl 32) or (by.toLong() and 0xFFFFFFFFL)

    private companion object {
        val BUCKET = CloudBlanket.hexSize(0) * 64
    }
}

/**
 * Your places' outlines in map points, outer rings and holes alike, each with its
 * box, for cutting them out of the blanket. A hole in a place (a suburb inside it
 * that isn't yours) stays under the blanket.
 */
class BlanketPlaces(boundaries: List<Boundary>) {
    class Place(val rings: List<DoubleArray>, val box: DoubleArray)

    val places: List<Place> = boundaries.flatMap { boundary ->
        boundary.polygons.map { polygon ->
            val rings = (listOf(polygon.outer) + polygon.holes).filter { it.size >= 3 }.map { ring ->
                DoubleArray(ring.size * 2) { i ->
                    val c = ring[i / 2]
                    if (i % 2 == 0) MapPoints.x(c.lon) else MapPoints.y(c.lat)
                }
            }
            val box = doubleArrayOf(Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY)
            rings.firstOrNull()?.let { outer ->
                var i = 0
                while (i < outer.size) {
                    box[0] = min(box[0], outer[i]); box[2] = max(box[2], outer[i])
                    box[1] = min(box[1], outer[i + 1]); box[3] = max(box[3], outer[i + 1])
                    i += 2
                }
            }
            Place(rings, box)
        }
    }.filter { it.rings.isNotEmpty() }

    companion object {
        val none = BlanketPlaces(emptyList())
    }
}
