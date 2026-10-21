package com.mikecann.walkies.map

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Row-major 3x3 matrices in plain DoubleArrays, so nothing allocates. */
object Mat3 {
    fun set(out: DoubleArray, a: Double, b: Double, c: Double, d: Double, e: Double, f: Double, g: Double, h: Double, i: Double) {
        out[0] = a; out[1] = b; out[2] = c
        out[3] = d; out[4] = e; out[5] = f
        out[6] = g; out[7] = h; out[8] = i
    }

    /** [out] = [a] x [b]. [out] mustn't be either of them. */
    fun multiply(a: DoubleArray, b: DoubleArray, out: DoubleArray) {
        for (r in 0 until 3) {
            for (c in 0 until 3) {
                out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
            }
        }
    }

    /** False if [m] can't be inverted. */
    fun invert(m: DoubleArray, out: DoubleArray): Boolean {
        val a = m[0]; val b = m[1]; val c = m[2]
        val d = m[3]; val e = m[4]; val f = m[5]
        val g = m[6]; val h = m[7]; val i = m[8]
        val c0 = e * i - f * h
        val c1 = f * g - d * i
        val c2 = d * h - e * g
        val det = a * c0 + b * c1 + c * c2
        if (abs(det) < 1e-300 || !det.isFinite()) return false
        val s = 1 / det
        set(
            out,
            c0 * s, (c * h - b * i) * s, (b * f - c * e) * s,
            c1 * s, (a * i - c * g) * s, (c * d - a * f) * s,
            c2 * s, (b * g - a * h) * s, (a * e - b * d) * s,
        )
        return true
    }
}

/**
 * Where a baked picture of the clouds was drawn from: the camera's projection at
 * the time, and the box of its screen pixels the picture covers (the screen plus a
 * margin all round, stopping short of the horizon). The picture is [pixelWidth] x
 * [pixelHeight], [scale] bitmap pixels to a screen pixel.
 */
class BakeFrame(
    val projection: Projection,
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
    val scale: Float,
    /** Drawn rough and wide while the camera moved, to keep up. Redone sharp once it stops. */
    val draft: Boolean = false,
) {
    val pixelWidth = max(1, ceil((right - left) * scale).toInt())
    val pixelHeight = max(1, ceil((bottom - top) * scale).toInt())

    companion object {
        /** How far past each edge of the screen a bake reaches, as a fraction of its size. */
        const val MARGIN = 0.12f
        /**
         * A still bake's bitmap pixels per screen pixel. The clouds are soft, so a bit
         * under 1 looks the same and bakes and uploads in two thirds of the time.
         */
        const val SCALE = 0.8f
        /** While the map's moving: further, so a pan doesn't run off the edge before the next one's ready. */
        const val DRAFT_MARGIN = 0.45f
        /** While the map's moving, a bake is this sharp, as it takes a fraction of the time. */
        const val DRAFT_SCALE = 0.45f

        /**
         * The most pixels in a bake, a bit more than the tablet's still bake: bigger
         * phone screens bake a touch softer rather than slower. 4 bytes each.
         */
        const val MAX_PIXELS = 3_000_000
        /** No bigger than this either way, which every GPU can hold as one texture. */
        const val MAX_SIDE = 4096

        /**
         * The ground can be at most this many times as far from the camera as the 10%, 40%
         * spot before a bake stops: the horizon itself is infinitely far, and clouds
         * near it are specks.
         */
        const val FAR = 12.0

        /**
         * The frame for baking what [projection] sees on a [width] x [height] screen.
         * [projection] is copied, so the caller can keep updating its own.
         */
        fun around(projection: Projection, width: Float, height: Float, draft: Boolean): BakeFrame {
            val margin = if (draft) DRAFT_MARGIN else MARGIN
            val left = -width * margin
            val right = width * (1 + margin)
            var top = -height * margin
            val bottom = height * (1 + margin)
            // Stop where the ground's too far away: above that row there's only horizon.
            for (u in floatArrayOf(left, right)) {
                val row = projection.nearestRowWithin(u.toDouble(), FAR)
                if (row.isFinite() && row > top) top = min(row.toFloat(), bottom - 1)
            }
            var scale = if (draft) DRAFT_SCALE else SCALE
            val w = (right - left) * scale
            val h = (bottom - top) * scale
            if (w * h > MAX_PIXELS) scale *= sqrt(MAX_PIXELS / (w * h))
            scale = min(scale, MAX_SIDE / max(right - left, bottom - top))
            val copy = Projection().also { it.copyFrom(projection) }
            return BakeFrame(copy, left, top, right, bottom, scale, draft)
        }
    }
}

/**
 * How a bake has to be warped to sit on the map as it is now: one perspective
 * matrix from the bake's screen pixels to today's, through the same ground the
 * projection measures. Also says when a bake has gone stale. Allocates nothing.
 */
class BakeWarp {
    /** Bake screen pixels to screen pixels now, row-major. */
    val matrix = DoubleArray(9)
    private val inverse = DoubleArray(9)
    /** [matrix] as floats, for android.graphics.Matrix.setValues. */
    val values = FloatArray(9)

    var valid = false
        private set

    // The last point mapped by map().
    var x = 0.0
        private set
    var y = 0.0
        private set

    /**
     * Works out the warp from [frame]'s camera to [now]. False (and [valid] false)
     * if some of the bake would be behind the camera now, which can't be drawn.
     */
    fun update(now: Projection, frame: BakeFrame): Boolean {
        valid = false
        if (!now.valid || !frame.projection.valid) return false
        now.relativeTo(frame.projection, matrix)
        if (!Mat3.invert(matrix, inverse)) return false
        // Every corner of the bake in front of the camera, so the GPU never has to cut
        // the picture where it wraps round behind it.
        if (w(matrix, frame.left, frame.top) <= 0 || w(matrix, frame.right, frame.top) <= 0 ||
            w(matrix, frame.right, frame.bottom) <= 0 || w(matrix, frame.left, frame.bottom) <= 0
        ) return false
        // Scaled so the last term is 1, as Skia likes it. Always by a positive number:
        // flipping the sign would put the picture behind the camera.
        val s = 1 / matrix[8]
        for (i in 0 until 9) values[i] = (matrix[i] * s).toFloat()
        valid = true
        return true
    }

    private fun w(m: DoubleArray, x: Float, y: Float) = m[6] * x + m[7] * y + m[8]

    /** A bake screen point to the screen now, into [x], [y]. False if it's behind the camera. */
    fun map(bx: Double, by: Double): Boolean = apply(matrix, bx, by)

    /** A screen point now back to the bake's screen, into [x], [y]. False if it's behind the bake's camera. */
    fun unmap(sx: Double, sy: Double): Boolean = apply(inverse, sx, sy)

    private fun apply(m: DoubleArray, px: Double, py: Double): Boolean {
        val w = m[6] * px + m[7] * py + m[8]
        if (w <= 0) return false
        x = (m[0] * px + m[1] * py + m[2]) / w
        y = (m[3] * px + m[4] * py + m[5]) / w
        return true
    }

    /**
     * Whether a [width] x [height] screen now is still well served by [frame] (after
     * [update]): all of it inside the bake, and nowhere stretched, squashed or turned
     * so much that the clouds would look off. Past these the bake's redone.
     *
     * While the map moves, [moving] lets it stretch and turn further (it's hard to see
     * mid-pan) but asks again once the screen's used up half the margin on any side,
     * so the next bake's ready before the edge shows.
     */
    fun fits(frame: BakeFrame, width: Float, height: Float, moving: Boolean = false): Boolean {
        if (!valid) return false
        val reach = if (moving) MOVING_REACH else 1f
        val left = frame.left * reach
        val right = width + (frame.right - width) * reach
        val top = if (frame.top < 0) frame.top * reach else frame.top
        val bottom = height + (frame.bottom - height) * reach
        val stretch = if (moving) MOVING_STRETCH else STRETCH
        val turn = if (moving) MOVING_TURN else TURN
        for (i in 0 until 5) {
            val sx = CHECK[i * 2] * width.toDouble()
            val sy = CHECK[i * 2 + 1] * height.toDouble()
            if (!unmap(sx, sy)) return false
            val bx = x
            val by = y
            if (bx < left || bx > right || by < top || by > bottom) return false
            if (!looksRight(bx, by, stretch, turn)) return false
        }
        return true
    }

    /**
     * The warp's local stretch and turn at a bake point: within [stretch] either way
     * along both axes, and turned less than [turn] radians.
     */
    private fun looksRight(bx: Double, by: Double, stretch: Double, turn: Double): Boolean {
        val m = matrix
        val w = m[6] * bx + m[7] * by + m[8]
        val px = (m[0] * bx + m[1] * by + m[2]) / w
        val py = (m[3] * bx + m[4] * by + m[5]) / w
        // The Jacobian of the perspective map.
        val a = (m[0] - px * m[6]) / w
        val b = (m[1] - px * m[7]) / w
        val c = (m[3] - py * m[6]) / w
        val d = (m[4] - py * m[7]) / w
        // Its two singular values, from the closed form for 2x2.
        val e = (a + d) / 2
        val f = (a - d) / 2
        val g = (c + b) / 2
        val h = (c - b) / 2
        val q = hypot(e, h)
        val r = hypot(f, g)
        val biggest = q + r
        val smallest = abs(q - r)
        if (biggest > stretch || smallest < 1 / stretch) return false
        return abs(atan2(c - b, a + d)) < turn
    }

    /**
     * Whether the bake already matches the screen now to within [pixels] everywhere
     * on it (after [update]), so redoing it wouldn't change anything.
     */
    fun exact(width: Float, height: Float, pixels: Double = 0.75): Boolean {
        if (!valid) return false
        for (i in 0 until 5) {
            val sx = CHECK[i * 2] * width.toDouble()
            val sy = CHECK[i * 2 + 1] * height.toDouble()
            if (!unmap(sx, sy)) return false
            if (abs(x - sx) > pixels || abs(y - sy) > pixels) return false
        }
        return true
    }

    companion object {
        /** Past this much bigger or smaller, a bake is redone. */
        const val STRETCH = 1.25
        /** Or turned past about 4°. */
        const val TURN = 0.07
        /** While the map moves: further either way before a new bake's asked for. */
        const val MOVING_STRETCH = 2.0
        /** About 9°. */
        const val MOVING_TURN = 0.15
        /** And half the margin used up on any side. */
        const val MOVING_REACH = 0.5f

        /** The screen's corners and middle, as fractions of its width and height. */
        private val CHECK = doubleArrayOf(0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.5, 0.5)
    }
}
