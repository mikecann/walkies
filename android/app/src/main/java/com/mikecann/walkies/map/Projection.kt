package com.mikecann.walkies.map

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

/**
 * Turns map points into screen pixels. The ground is flat, so wherever the camera
 * is, flat or tilted, one perspective transform (a homography) maps it onto the
 * screen. It's measured each frame from four spots spread across the screen: far
 * enough apart that the map's rounding doesn't make the clouds wobble when you're
 * zoomed out. A port of Projection in Clouds.swift.
 *
 * Nothing here allocates once built: results land in [x] and [y] (and [x2], [y2]
 * for segments), since the grid and streets call it tens of thousands of times a frame.
 */
class Projection {
    /** Ground to screen, h33 = 1. Ground is in map points relative to the origin, over `unit`. */
    private val h = DoubleArray(8)
    private val m = Array(8) { DoubleArray(9) }
    private var originX = 0.0
    private var originY = 0.0
    private var unit = 1.0
    private var width = 1.0
    var valid = false
        private set

    /** Screen pixels per map point mid-screen, worked out once a frame. */
    var centreScale = 0.0
        private set

    var x = 0f
        private set
    var y = 0f
        private set
    var x2 = 0f
        private set
    var y2 = 0f
        private set

    // The last homogeneous point, and a second one for segments.
    private var hx = 0.0
    private var hy = 0.0
    private var hz = 0.0
    private var bx = 0.0
    private var by = 0.0
    private var bz = 0.0

    /**
     * Measures the homography from the map points under [SCREEN] spots of a
     * [width] x [height] view. [ground] holds x, y for each of the four spots.
     */
    fun update(ground: DoubleArray, width: Float, height: Float, centreX: Double, centreY: Double) {
        val w = max(1.0, width.toDouble())
        this.width = w
        originX = ground[0]
        originY = ground[1]
        unit = max(1.0, hypot(ground[4] - originX, ground[5] - originY))
        for (i in 0 until 4) {
            val gx = (ground[i * 2] - originX) / unit
            val gy = (ground[i * 2 + 1] - originY) / unit
            val u = SCREEN[i * 2] * width / w
            val v = SCREEN[i * 2 + 1] * height / w
            val a = m[i * 2]
            a[0] = gx; a[1] = gy; a[2] = 1.0; a[3] = 0.0; a[4] = 0.0; a[5] = 0.0
            a[6] = -gx * u; a[7] = -gy * u; a[8] = u
            val b = m[i * 2 + 1]
            b[0] = 0.0; b[1] = 0.0; b[2] = 0.0; b[3] = gx; b[4] = gy; b[5] = 1.0
            b[6] = -gx * v; b[7] = -gy * v; b[8] = v
        }
        valid = ground.all { it.isFinite() } && solve()
        centreScale = if (valid) ellipseWidth(centreX, centreY, 1000.0) / 2000 else 0.0
    }

    /** Screen position before dividing by depth (z), which is about 1 everywhere on a flat map. */
    private fun homogeneous(px: Double, py: Double) {
        val gx = (px - originX) / unit
        val gy = (py - originY) / unit
        hx = h[0] * gx + h[1] * gy + h[2]
        hy = h[3] * gx + h[4] * gy + h[5]
        hz = h[6] * gx + h[7] * gy + 1
    }

    /** Projects a map point into [x], [y]. */
    fun point(px: Double, py: Double) {
        homogeneous(px, py)
        val z = max(hz, NEAR)
        x = (hx / z * width).toFloat()
        y = (hy / z * width).toFloat()
    }

    fun isInFront(px: Double, py: Double): Boolean {
        homogeneous(px, py)
        return hz >= NEAR
    }

    /**
     * One straight line on screen into [x], [y] to [x2], [y2], cut where it passes
     * behind the camera. False if it's wholly behind.
     */
    fun segment(ax: Double, ay: Double, cx: Double, cy: Double): Boolean {
        homogeneous(cx, cy)
        bx = hx; by = hy; bz = hz
        homogeneous(ax, ay)
        val aIn = hz >= NEAR
        val bIn = bz >= NEAR
        if (!aIn && !bIn) return false
        if (!aIn) {
            val t = (NEAR - hz) / (bz - hz)
            hx += (bx - hx) * t; hy += (by - hy) * t; hz += (bz - hz) * t
        }
        if (!bIn) {
            val t = (NEAR - hz) / (bz - hz)
            bx = hx + (bx - hx) * t; by = hy + (by - hy) * t; bz = hz + (bz - hz) * t
        }
        x = (hx / max(hz, NEAR) * width).toFloat()
        y = (hy / max(hz, NEAR) * width).toFloat()
        x2 = (bx / max(bz, NEAR) * width).toFloat()
        y2 = (by / max(bz, NEAR) * width).toFloat()
        return true
    }

    /**
     * A closed outline on screen, with any part behind the camera cut off.
     * Calls [add] with each screen point in turn.
     */
    inline fun polygon(points: DoubleArray, add: (Float, Float, Boolean) -> Unit) {
        val n = points.size / 2
        var first = true
        for (i in 0 until n) {
            val p = (i + n - 1) % n
            if (segment(points[p * 2], points[p * 2 + 1], points[i * 2], points[i * 2 + 1])) {
                val wasIn = isInFront(points[p * 2], points[p * 2 + 1])
                if (!wasIn) { add(x, y, first); first = false }
                add(x2, y2, first); first = false
            }
        }
    }

    // Results of ellipse(): its centre and radii in pixels.
    var ex = 0f
        private set
    var ey = 0f
        private set
    var rx = 0f
        private set
    var ry = 0f
        private set

    /** A circle on the ground as it looks on screen: squashed when the map is tilted. False if behind the camera. */
    fun ellipse(cx: Double, cy: Double, radius: Double): Boolean {
        if (!isInFront(cx, cy)) return false
        point(cx, cy)
        val px = x
        val py = y
        point(cx + radius, cy)
        val eastX = x - px
        val eastY = y - py
        point(cx, cy + radius)
        val southX = x - px
        val southY = y - py
        ex = px
        ey = py
        rx = hypot(eastX, eastY)
        ry = hypot(southX, southY)
        return true
    }

    private fun ellipseWidth(cx: Double, cy: Double, radius: Double): Double =
        if (ellipse(cx, cy, radius)) rx * 2.0 else 0.0

    /** The eight unknowns of the homography, by Gaussian elimination. */
    private fun solve(): Boolean {
        for (col in 0 until 8) {
            var pivot = col
            for (row in col + 1 until 8) if (abs(m[row][col]) > abs(m[pivot][col])) pivot = row
            if (abs(m[pivot][col]) <= 1e-12) return false
            val swap = m[col]; m[col] = m[pivot]; m[pivot] = swap
            for (row in 0 until 8) {
                if (row == col) continue
                val f = m[row][col] / m[col][col]
                if (f == 0.0) continue
                for (k in col..8) m[row][k] -= f * m[col][k]
            }
        }
        for (i in 0 until 8) h[i] = m[i][8] / m[i][i]
        return true
    }

    companion object {
        /**
         * How close to the camera's own plane the ground can come before it's treated
         * as behind the camera. 1 is the ground at the 10%, 40% spot on screen.
         */
        const val NEAR = 0.02

        /** Where on screen the four spots are, as fractions of its width and height. */
        val SCREEN = floatArrayOf(0.1f, 0.4f, 0.9f, 0.4f, 0.9f, 0.95f, 0.1f, 0.95f)
    }
}
