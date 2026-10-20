package com.mikecann.walkies.grid

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin
import kotlin.math.sqrt

/** A tile, in axial coordinates on a pointy-top hex grid. Saved as [q, r]. */
data class Hex(val q: Int, val r: Int) {
    val neighbours: List<Hex>
        get() = listOf(
            Hex(q + 1, r), Hex(q + 1, r - 1), Hex(q, r - 1),
            Hex(q - 1, r), Hex(q - 1, r + 1), Hex(q, r + 1),
        )
}

/** The one world grid, per design/grid.md. Matches HexGrid.swift and convex/grid.ts. */
object HexGrid {
    const val VERSION = 2
    val projection = WorldProjection
    /** Centre-to-corner distance in projected units, true metres at -33.65°. */
    const val SIZE = 50.0

    val tileArea = 3 * sqrt(3.0) / 2 * SIZE * SIZE

    fun hex(at: Vec2): Hex {
        val q = (sqrt(3.0) / 3 * at.x - at.y / 3) / SIZE
        val r = (2.0 / 3 * at.y) / SIZE
        return round(q, r)
    }

    fun hex(containing: Coordinate): Hex = hex(projection.project(containing))

    fun centre(h: Hex): Vec2 {
        val q = h.q.toDouble()
        val r = h.r.toDouble()
        return Vec2(SIZE * sqrt(3.0) * (q + r / 2), SIZE * 1.5 * r)
    }

    /** Counterclockwise in projected coordinates, beginning south-east. */
    fun corners(h: Hex): List<Coordinate> {
        val c = centre(h)
        return (0 until 6).map { i ->
            val angle = (60 * i.toDouble() - 30) * PI / 180
            projection.unproject(Vec2(c.x + SIZE * cos(angle), c.y + SIZE * sin(angle)))
        }
    }

    /** Every hex whose centre falls inside the rectangle, in projected metres. */
    fun hexes(lo: Vec2, hi: Vec2): List<Hex> {
        val rowHeight = SIZE * 1.5
        val colWidth = SIZE * sqrt(3.0)
        val out = ArrayList<Hex>()
        val r0 = floor(lo.y / rowHeight).toInt() - 1
        val r1 = ceil(hi.y / rowHeight).toInt() + 1
        for (r in r0..r1) {
            val shift = r.toDouble() / 2
            val q0 = floor(lo.x / colWidth - shift).toInt() - 1
            val q1 = ceil(hi.x / colWidth - shift).toInt() + 1
            for (q in q0..q1) {
                val h = Hex(q, r)
                val c = centre(h)
                if (c.x >= lo.x && c.x <= hi.x && c.y >= lo.y && c.y <= hi.y) out.add(h)
            }
        }
        return out
    }

    fun round(q: Double, r: Double): Hex {
        val s = -q - r
        var rq = roundAwayFromZero(q)
        var rr = roundAwayFromZero(r)
        val rs = roundAwayFromZero(s)
        val dq = abs(rq - q)
        val dr = abs(rr - r)
        val ds = abs(rs - s)
        if (dq > dr && dq > ds) {
            rq = -rr - rs
        } else if (dr > ds) {
            rr = -rq - rs
        }
        // + 0.0 turns -0.0 into 0.0.
        return Hex((rq + 0.0).toInt(), (rr + 0.0).toInt())
    }

    /** Swift's `.rounded()`: half ties away from zero. Kotlin's round() is half-even. */
    fun roundAwayFromZero(n: Double): Double {
        val a = abs(n)
        val whole = floor(a)
        val rounded = if (a - whole >= 0.5) whole + 1 else whole
        return if (n < 0) -rounded else rounded
    }
}
