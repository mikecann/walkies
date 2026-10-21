package com.mikecann.walkies.map

import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.RoadLine
import java.util.UUID

/**
 * Everything the cloud layer draws, worked out in map points whenever the tiles change.
 * It covers every place you've added at once, on the same world grid. A port of
 * CloudField in Clouds.swift; tiles are plain hexes since there's only the world grid.
 */
class CloudField(cities: List<City>, walkTiles: Set<Hex> = emptySet()) {
    class Puff(
        val tile: Hex,
        val x: Double,
        val y: Double,
        /** Bigger than the hex, so neighbours merge into one blanket. */
        val radius: Double,
        val variant: Int,
        /** Where this cloud is in its drift, so they don't all bob in time. */
        val phase: Double,
    )

    class Clearing(val tile: Hex, val x: Double, val y: Double, val radius: Double)

    /** Interleaved x, y map points. */
    class Line(val points: DoubleArray, val kind: RoadLine.Kind)

    /** A tile for the colour-coded honeycomb that shows while you drag the map. */
    class Outline(val tile: Hex, val kind: Int, val x: Double, val y: Double, val corners: DoubleArray)

    /** Which places this covers, so the layer can tell tiles clearing from a place being added or removed. */
    val places: List<UUID> = cities.map { it.id }
    /** North first, so clouds further south sit in front of them. */
    val puffs: List<Puff>
    /** Where to cut the clouds away over walked hexes. */
    val clearings: List<Clearing>
    val lines: List<Line>
    /** The places' outlines, so the dotted roads stop at their edges. Interleaved x, y. */
    val outline: List<DoubleArray>
    /**
     * The edges of the tiles under cloud, drawn as a faint dashed grid. Each edge
     * once, as x0, y0, x1, y1, so shared edges don't double up their dashes.
     */
    val gridEdges: DoubleArray
    val outlines: List<Outline>

    init {
        val clouded = HashSet<Hex>()
        val clear = HashSet<Hex>()
        val kinds = HashMap<Hex, Int>()
        for (city in cities) {
            val cover = city.cloudCover()
            clouded.addAll(cover.clouded)
            clear.addAll(cover.clear)
            for (hex in cover.blocked) kinds.putIfAbsent(hex, BLOCKED)
            for (hex in city.tiles - city.visited) kinds[hex] = OPEN
            for (hex in cover.clear - city.visited) kinds[hex] = CLEARED
            for (hex in city.visited) kinds[hex] = VISITED
        }
        for (hex in walkTiles) if (hex in kinds) kinds[hex] = THIS_WALK
        // A border tile walked in one place is walked in the other too.
        clouded.removeAll(clear)

        val size = HexGrid.SIZE * MapPoints.perGridUnit
        clearings = clear.map { val c = centre(it); Clearing(it, c[0], c[1], size * CLEARING) }
        puffs = clouded
            .map { tile ->
                // Nudge and resize each cloud a little, always the same way for the same
                // hex, so the blanket doesn't sit on an obvious honeycomb.
                val rng = SplitMix64(hash(tile))
                val c = centre(tile)
                val x = c[0] + (rng.unit() - 0.5) * 0.5 * size
                val y = c[1] + (rng.unit() - 0.5) * 0.5 * size
                val radius = size * SPREAD * (0.88 + rng.unit() * 0.35)
                val variant = java.lang.Long.remainderUnsigned(rng.next(), SPRITE_COUNT.toLong()).toInt()
                Puff(tile, x, y, radius, variant, rng.unit() * 2 * Math.PI)
            }
            .sortedBy { it.y }
        // Neighbouring places fetch the same streets along their shared edges.
        val roads = cities.flatMap { it.roads.orEmpty() }.toSet()
        lines = roads.map { road ->
            Line(DoubleArray(road.points.size * 2) { i ->
                val p = road.points[i / 2]
                if (i % 2 == 0) MapPoints.x(p.lon) else MapPoints.y(p.lat)
            }, road.kind)
        }
        outline = cities.flatMap { city ->
            city.boundary.polygons.map { poly ->
                DoubleArray(poly.outer.size * 2) { i ->
                    val p = poly.outer[i / 2]
                    if (i % 2 == 0) MapPoints.x(p.lon) else MapPoints.y(p.lat)
                }
            }
        }
        outlines = kinds.map { (tile, kind) ->
            val c = centre(tile)
            Outline(tile, kind, c[0], c[1], corners(tile))
        }

        // Edge i runs between corners i and i + 1 and faces this neighbour.
        val facing = arrayOf(1 to 0, 0 to 1, -1 to 1, -1 to 0, 0 to -1, 1 to -1)
        val edges = ArrayList<Double>()
        for (hex in clouded) {
            val corners = corners(hex)
            for (i in 0 until 6) {
                val n = Hex(hex.q + facing[i].first, hex.r + facing[i].second)
                val first = hex.q < n.q || (hex.q == n.q && hex.r < n.r)
                if (n in clouded && !first) continue
                val j = (i + 1) % 6
                edges.add(corners[i * 2]); edges.add(corners[i * 2 + 1])
                edges.add(corners[j * 2]); edges.add(corners[j * 2 + 1])
            }
        }
        gridEdges = edges.toDoubleArray()
    }

    // After init, which they're worked out from.
    /** Each line's box of map points, as min x, min y, max x, max y, for skipping the ones nowhere near. */
    val lineBounds: DoubleArray = bounds(lines.map { it.points })
    /** The same for each of [outline]. */
    val outlineBounds: DoubleArray = bounds(outline)

    companion object {
        /** Cloud sprite radius as a multiple of the hex size. */
        const val SPREAD = 1.6
        /**
         * Radius of the soft hole cut over each walked hex, as a multiple of the hex size.
         * Clouds spill well past their own hex, so without this a walk down a single
         * street gets swallowed by the clouds either side of it.
         */
        const val CLEARING = 1.25
        const val SPRITE_COUNT = 8

        // Honeycomb kinds, in drawing order.
        /** Walked. */
        const val VISITED = 0
        /** No street or path, cleared because you walked beside it. */
        const val CLEARED = 1
        /** Has a street or path, not walked yet. */
        const val OPEN = 2
        /** No street or path, still under cloud. */
        const val BLOCKED = 3
        /** Uncovered on this walk. */
        const val THIS_WALK = 4

        val empty = CloudField(emptyList())

        private fun centre(tile: Hex): DoubleArray {
            val c = HexGrid.projection.unproject(HexGrid.centre(tile))
            return doubleArrayOf(MapPoints.x(c.lon), MapPoints.y(c.lat))
        }

        /** The six corners of a tile, interleaved x, y map points. */
        fun corners(tile: Hex): DoubleArray {
            val corners = HexGrid.corners(tile)
            return DoubleArray(12) { i ->
                val c = corners[i / 2]
                if (i % 2 == 0) MapPoints.x(c.lon) else MapPoints.y(c.lat)
            }
        }

        private fun bounds(polylines: List<DoubleArray>): DoubleArray {
            val out = DoubleArray(polylines.size * 4)
            for (i in polylines.indices) {
                val p = polylines[i]
                var x0 = Double.POSITIVE_INFINITY
                var y0 = Double.POSITIVE_INFINITY
                var x1 = Double.NEGATIVE_INFINITY
                var y1 = Double.NEGATIVE_INFINITY
                var j = 0
                while (j + 1 < p.size) {
                    x0 = minOf(x0, p[j]); x1 = maxOf(x1, p[j])
                    y0 = minOf(y0, p[j + 1]); y1 = maxOf(y1, p[j + 1])
                    j += 2
                }
                out[i * 4] = x0; out[i * 4 + 1] = y0; out[i * 4 + 2] = x1; out[i * 4 + 3] = y1
            }
            return out
        }

        private fun hash(hex: Hex): Long = (hex.q.toLong() * 73_856_093L) xor (hex.r.toLong() * 19_349_663L)
    }
}

class SplitMix64(private var state: Long) {
    fun next(): Long {
        state += -0x61c8864680b583ebL // 0x9E3779B97F4A7C15
        var z = state
        z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L // 0xBF58476D1CE4E5B9
        z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L // 0x94D049BB133111EB
        return z xor (z ushr 31)
    }

    /** 0 until 1. */
    fun unit(): Double = (next() ushr 11).toDouble() / (1L shl 53).toDouble()
}
