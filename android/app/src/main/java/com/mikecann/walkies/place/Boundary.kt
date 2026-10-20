package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.GeoProjection
import com.mikecann.walkies.grid.LocalProjection
import com.mikecann.walkies.grid.Vec2
import kotlin.math.abs

data class GeoPolygon(val outer: List<Coordinate>, val holes: List<List<Coordinate>>)

/** A place's outline from OpenStreetMap. Can be several polygons (islands etc). */
data class Boundary(val polygons: List<GeoPolygon>) {
    data class Bounds(val south: Double, val west: Double, val north: Double, val east: Double)

    val bounds: Bounds
        get() {
            val all = polygons.flatMap { it.outer }
            return Bounds(
                all.minOfOrNull { it.lat } ?: 0.0, all.minOfOrNull { it.lon } ?: 0.0,
                all.maxOfOrNull { it.lat } ?: 0.0, all.maxOfOrNull { it.lon } ?: 0.0,
            )
        }

    val centre: Coordinate
        get() {
            val b = bounds
            return Coordinate((b.south + b.north) / 2, (b.west + b.east) / 2)
        }

    /**
     * Somewhere inside the place to put its name: the middle of its biggest piece,
     * or for a crescent or L shape whose middle is outside it, the nearest spot
     * that's inside.
     */
    val labelPoint: Coordinate
        get() {
            val projection = LocalProjection(centre)
            val shape = BoundaryShape(this, projection)
            val biggest = polygons.maxByOrNull { it.outer.size } ?: return centre
            val ring = biggest.outer.map(projection::project)
            var area = 0.0
            var sum = Vec2(0.0, 0.0)
            for (i in ring.indices) {
                val a = ring[i]
                val b = ring[(i + 1) % ring.size]
                val cross = a.x * b.y - b.x * a.y
                area += cross
                sum += (a + b) * cross
            }
            val middle = if (abs(area) > 1e-9) sum / (3 * area) else (shape.lo + shape.hi) / 2.0
            if (shape.contains(middle)) return projection.unproject(middle)
            var best: Vec2? = null
            for (i in 0..20) {
                for (j in 0..20) {
                    val p = Vec2(
                        shape.lo.x + (shape.hi.x - shape.lo.x) * i / 20.0,
                        shape.lo.y + (shape.hi.y - shape.lo.y) * j / 20.0,
                    )
                    if (!shape.contains(p)) continue
                    if (best == null || p.distance(middle) < best.distance(middle)) best = p
                }
            }
            return projection.unproject(best ?: middle)
        }
}

/** A boundary projected into local or world coordinates, for fast point-in-polygon tests. */
class BoundaryShape(boundary: Boundary, projection: GeoProjection) {
    private class Part(val outer: List<Vec2>, val holes: List<List<Vec2>>)

    private val parts = boundary.polygons.map { poly ->
        Part(poly.outer.map(projection::project), poly.holes.map { hole -> hole.map(projection::project) })
    }
    val lo: Vec2
    val hi: Vec2

    init {
        val all = parts.flatMap { it.outer }
        lo = Vec2(all.minOfOrNull { it.x } ?: 0.0, all.minOfOrNull { it.y } ?: 0.0)
        hi = Vec2(all.maxOfOrNull { it.x } ?: 0.0, all.maxOfOrNull { it.y } ?: 0.0)
    }

    fun contains(p: Vec2): Boolean {
        if (p.x < lo.x || p.x > hi.x || p.y < lo.y || p.y > hi.y) return false
        return parts.any { part -> ring(part.outer, p) && part.holes.none { ring(it, p) } }
    }

    /** Area in square metres. */
    val area: Double
        get() = parts.sumOf { part -> abs(signedArea(part.outer)) - part.holes.sumOf { abs(signedArea(it)) } }

    private companion object {
        fun ring(ring: List<Vec2>, p: Vec2): Boolean {
            if (ring.size <= 2) return false
            var inside = false
            var j = ring.size - 1
            for (i in ring.indices) {
                val a = ring[i]
                val b = ring[j]
                if ((a.y > p.y) != (b.y > p.y)) {
                    val x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                    if (p.x < x) inside = !inside
                }
                j = i
            }
            return inside
        }

        fun signedArea(ring: List<Vec2>): Double {
            if (ring.size <= 2) return 0.0
            var sum = 0.0
            var j = ring.size - 1
            for (i in ring.indices) {
                sum += ring[j].x * ring[i].y - ring[i].x * ring[j].y
                j = i
            }
            return sum / 2
        }
    }
}
