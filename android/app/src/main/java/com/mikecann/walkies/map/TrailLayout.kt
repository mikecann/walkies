package com.mikecann.walkies.map

import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Where the footprints and sparkles go along a route on screen (TrailLayout.swift).
 * Samples in screen points, so footsteps stay legible at every map zoom. The phase
 * carries on across corners and offscreen stretches instead of restarting at each fix.
 */
object TrailLayout {
    data class Stamp(val x: Double, val y: Double, val angle: Double, val index: Int) {
        val isLeft: Boolean get() = index % 2 == 0
    }

    /** The visible part of a segment, as a range of 0 to 1 along it. */
    data class Range(val low: Double, val high: Double)

    /** [points] are interleaved x, y. For tests and anything else that wants a list. */
    fun stamps(points: List<Pair<Double, Double>>, spacing: Double = 12.0, left: Double, top: Double, right: Double, bottom: Double): List<Stamp> {
        val flat = FloatArray(points.size * 2) { i -> (if (i % 2 == 0) points[i / 2].first else points[i / 2].second).toFloat() }
        val out = ArrayList<Stamp>()
        forEachStamp(flat, points.size, spacing, left, top, right, bottom) { x, y, angle, index -> out.add(Stamp(x, y, angle, index)) }
        return out
    }

    /**
     * Calls [stamp] with each one's spot, direction of travel (radians from the x
     * axis, in screen coordinates) and number along the route. Allocates nothing.
     */
    inline fun forEachStamp(
        points: FloatArray, count: Int, spacing: Double,
        left: Double, top: Double, right: Double, bottom: Double,
        stamp: (x: Double, y: Double, angle: Double, index: Int) -> Unit,
    ) {
        if (count < 2 || !spacing.isFinite() || spacing <= 0) return
        var distance = 0.0
        for (i in 1 until count) {
            val ax = points[(i - 1) * 2].toDouble()
            val ay = points[(i - 1) * 2 + 1].toDouble()
            val bx = points[i * 2].toDouble()
            val by = points[i * 2 + 1].toDouble()
            val dx = bx - ax
            val dy = by - ay
            val length = hypot(dx, dy)
            if (!length.isFinite() || length <= 0) continue
            val low = visibleLow(ax, ay, bx, by, left, top, right, bottom)
            if (!low.isNaN()) {
                val high = visibleHigh(ax, ay, bx, by, left, top, right, bottom)
                val first = max(0, ceil((distance + length * low - spacing / 2) / spacing).toInt())
                val end = distance + length * high
                var index = first
                val angle = atan2(dy, dx)
                while (index * spacing + spacing / 2 <= end) {
                    val offset = index * spacing + spacing / 2 - distance
                    // A sample at a vertex belongs to the incoming segment only.
                    if (offset > 0 || i == 1) stamp(ax + dx * offset / length, ay + dy * offset / length, angle, index)
                    index++
                }
            }
            distance += length
        }
    }

    /**
     * Liang-Barsky clipping, which avoids making millions of offscreen footsteps when
     * the tilted camera puts a distant stretch of route near the horizon.
     */
    fun visibleRange(ax: Double, ay: Double, bx: Double, by: Double, left: Double, top: Double, right: Double, bottom: Double): Range? {
        val low = visibleLow(ax, ay, bx, by, left, top, right, bottom)
        if (low.isNaN()) return null
        return Range(low, visibleHigh(ax, ay, bx, by, left, top, right, bottom))
    }

    /** The start of the visible range, or NaN when none of it shows. */
    fun visibleLow(ax: Double, ay: Double, bx: Double, by: Double, left: Double, top: Double, right: Double, bottom: Double): Double =
        clip(ax, ay, bx, by, left, top, right, bottom, wantHigh = false)

    fun visibleHigh(ax: Double, ay: Double, bx: Double, by: Double, left: Double, top: Double, right: Double, bottom: Double): Double =
        clip(ax, ay, bx, by, left, top, right, bottom, wantHigh = true)

    private fun clip(ax: Double, ay: Double, bx: Double, by: Double, left: Double, top: Double, right: Double, bottom: Double, wantHigh: Boolean): Double {
        if (!ax.isFinite() || !ay.isFinite() || !bx.isFinite() || !by.isFinite()) return Double.NaN
        val dx = bx - ax
        val dy = by - ay
        var low = 0.0
        var high = 1.0
        for (k in 0 until 4) {
            val p = when (k) { 0 -> -dx; 1 -> dx; 2 -> -dy; else -> dy }
            val q = when (k) { 0 -> ax - left; 1 -> right - ax; 2 -> ay - top; else -> bottom - ay }
            if (p == 0.0) {
                if (q < 0) return Double.NaN
            } else {
                val t = q / p
                if (p < 0) low = max(low, t) else high = min(high, t)
                if (low > high) return Double.NaN
            }
        }
        return if (wantHigh) high else low
    }
}
