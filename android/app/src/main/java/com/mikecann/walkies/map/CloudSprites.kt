package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * A handful of cumulus puffs drawn once at launch. Each is a few big soft circles,
 * split into a blue-grey underside and a sunlit white top nudged towards the
 * north-west. Also a blurred silhouette of each for its shadow, and a soft eraser.
 * A port of CloudSprites in Clouds.swift, with the shop's cloud colours. Slow-ish:
 * build it off the main thread. Each look is built once and kept.
 */
class CloudSprites private constructor(
    val bases: List<Bitmap>,
    val tops: List<Bitmap>,
    val shadows: List<Bitmap>,
    val eraser: Bitmap,
    /** A soft pale disc for the mist, the same for every look. */
    val mist: Bitmap,
) {
    companion object {
        const val COUNT = CloudField.SPRITE_COUNT

        private class Palette(val top: Int, val alternate: Int, val edge: Int, val underside: Int)

        private fun rgb(r: Double, g: Double, b: Double) =
            Color.rgb((r * 255).roundToInt(), (g * 255).roundToInt(), (b * 255).roundToInt())

        private val classic = Palette(rgb(1.0, 1.0, 1.0), rgb(1.0, 1.0, 1.0), rgb(0.93, 0.945, 0.97), rgb(0.76, 0.8, 0.87))

        private fun palette(theme: String) = when (theme) {
            "clouds.sunset" -> Palette(rgb(1.0, 0.86, 0.74), rgb(1.0, 0.78, 0.84), rgb(0.96, 0.73, 0.8), rgb(0.66, 0.57, 0.79))
            "clouds.storm" -> Palette(rgb(0.69, 0.75, 0.83), rgb(0.69, 0.75, 0.83), rgb(0.54, 0.62, 0.73), rgb(0.32, 0.39, 0.51))
            "clouds.candy" -> Palette(rgb(1.0, 0.82, 0.92), rgb(0.78, 0.9, 1.0), rgb(0.84, 0.79, 0.94), rgb(0.65, 0.68, 0.85))
            else -> classic
        }

        private val built = HashMap<String, CloudSprites>()

        /** The sprites for an equipped cloud look, built the first time it's asked for. */
        fun forTheme(theme: String): CloudSprites {
            val key = if (theme in setOf("clouds.sunset", "clouds.storm", "clouds.candy")) theme else "clouds.classic"
            synchronized(built) { built[key]?.let { return it } }
            val sprites = build(key)
            synchronized(built) { return built.getOrPut(key) { sprites } }
        }

        fun build(theme: String = "clouds.classic"): CloudSprites {
            val palette = palette(theme)
            val bases = ArrayList<Bitmap>()
            val tops = ArrayList<Bitmap>()
            val shadows = ArrayList<Bitmap>()
            for (i in 0 until COUNT) {
                val circles = circles((i + 1).toLong())
                bases.add(base(circles, 384, palette.underside))
                tops.add(top(circles, 384, if (i % 2 == 0) palette.top else palette.alternate, palette.edge))
                shadows.add(shadow(circles, 160))
            }
            return CloudSprites(bases, tops, shadows, eraser(128), mist(128))
        }

        /** Circles as x, y, radius in a -1...1 square with y up. */
        private fun circles(seed: Long): List<DoubleArray> {
            val rng = SplitMix64(seed)
            val out = arrayListOf(doubleArrayOf(0.0, 0.0, 0.55))
            val ring = 4 + java.lang.Long.remainderUnsigned(rng.next(), 3).toInt()
            for (i in 0 until ring) {
                val angle = i.toDouble() / ring * 2 * Math.PI + rng.unit() * 0.8
                val distance = 0.28 + rng.unit() * 0.12
                out.add(doubleArrayOf(cos(angle) * distance, sin(angle) * distance, 0.33 + rng.unit() * 0.12))
            }
            return out
        }

        private fun base(circles: List<DoubleArray>, size: Int, shade: Int): Bitmap {
            val bitmap = bitmap(size)
            fill(circles, bitmap, scale = 1.0, shiftX = 0.0, shiftY = 0.0, colours = intArrayOf(shade, shade, transparent(shade)), hardness = 0.65f)
            return blur(bitmap, sigma = size * 0.01)
        }

        /** A touch greyer towards the edge, so overlapping tops leave faint billows. */
        private fun top(circles: List<DoubleArray>, size: Int, centre: Int, edge: Int): Bitmap {
            val bitmap = bitmap(size)
            fill(circles, bitmap, scale = 0.84, shiftX = -0.05, shiftY = 0.06, colours = intArrayOf(centre, edge, transparent(edge)), hardness = 0.5f)
            return blur(bitmap, sigma = size * 0.01)
        }

        /**
         * Soft-edged circles: the first colour in the middle, the second at `hardness`
         * of the radius, then fading to the third at the edge. The Swift version draws
         * in Core Graphics' y-up space, so y is flipped here.
         */
        private fun fill(
            circles: List<DoubleArray>, bitmap: Bitmap, scale: Double, shiftX: Double, shiftY: Double,
            colours: IntArray, hardness: Float,
        ) {
            val canvas = Canvas(bitmap)
            val s = bitmap.width.toDouble()
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            for (c in circles) {
                val x = ((c[0] * scale + shiftX + 1) / 2 * s).toFloat()
                val y = (s - (c[1] * scale + shiftY + 1) / 2 * s).toFloat()
                val r = (c[2] * scale / 2 * s).toFloat()
                paint.shader = RadialGradient(x, y, r, colours, floatArrayOf(0f, hardness, 1f), Shader.TileMode.CLAMP)
                canvas.drawCircle(x, y, r, paint)
            }
        }

        private fun shadow(circles: List<DoubleArray>, size: Int): Bitmap {
            val bitmap = bitmap(size)
            val canvas = Canvas(bitmap)
            val s = size.toDouble()
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK }
            for (c in circles) {
                canvas.drawCircle(((c[0] + 1) / 2 * s).toFloat(), (s - (c[1] + 1) / 2 * s).toFloat(), (c[2] / 2 * s).toFloat(), paint)
            }
            return blur(bitmap, sigma = s * 0.05)
        }

        /** Fully opaque in the middle, fading out over the outer third. */
        private fun eraser(size: Int): Bitmap {
            val bitmap = bitmap(size)
            val s = size / 2f
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(s, s, s, intArrayOf(Color.BLACK, Color.BLACK, Color.TRANSPARENT), floatArrayOf(0f, 0.68f, 1f), Shader.TileMode.CLAMP)
            }
            Canvas(bitmap).drawCircle(s, s, s, paint)
            return bitmap
        }

        /** Morning haze: a pale blue-white, even across the middle and fading out over the outer half. */
        private fun mist(size: Int): Bitmap {
            val bitmap = bitmap(size)
            val s = size / 2f
            val haze = rgb(0.93, 0.95, 0.99)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(s, s, s, intArrayOf(haze, haze, transparent(haze)), floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP)
            }
            Canvas(bitmap).drawCircle(s, s, s, paint)
            return bitmap
        }

        private fun transparent(colour: Int) = colour and 0x00FFFFFF

        private fun bitmap(size: Int) = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)

        /** A Gaussian blur in premultiplied colour, clamped at the edges like Core Image's. */
        private fun blur(bitmap: Bitmap, sigma: Double): Bitmap {
            val w = bitmap.width
            val h = bitmap.height
            val pixels = IntArray(w * h)
            bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
            // Four premultiplied channels, interleaved.
            val a = FloatArray(w * h * 4)
            for (i in pixels.indices) {
                val p = pixels[i]
                val alpha = (p ushr 24) / 255f
                a[i * 4] = ((p shr 16) and 0xFF) / 255f * alpha
                a[i * 4 + 1] = ((p shr 8) and 0xFF) / 255f * alpha
                a[i * 4 + 2] = (p and 0xFF) / 255f * alpha
                a[i * 4 + 3] = alpha
            }
            val radius = ceil(sigma * 3).toInt()
            val kernel = FloatArray(radius * 2 + 1) { exp(-((it - radius) * (it - radius)) / (2 * sigma * sigma)).toFloat() }
            val total = kernel.sum()
            for (k in kernel.indices) kernel[k] /= total
            val b = FloatArray(a.size)
            pass(a, b, w, h, kernel, radius, horizontal = true)
            pass(b, a, w, h, kernel, radius, horizontal = false)
            for (i in pixels.indices) {
                val alpha = min(1f, max(0f, a[i * 4 + 3]))
                if (alpha <= 0f) {
                    pixels[i] = 0
                    continue
                }
                fun channel(v: Float) = (min(1f, max(0f, v / alpha)) * 255).roundToInt()
                pixels[i] = ((alpha * 255).roundToInt() shl 24) or (channel(a[i * 4]) shl 16) or
                    (channel(a[i * 4 + 1]) shl 8) or channel(a[i * 4 + 2])
            }
            bitmap.setPixels(pixels, 0, w, 0, 0, w, h)
            return bitmap
        }

        private fun pass(src: FloatArray, dst: FloatArray, w: Int, h: Int, kernel: FloatArray, radius: Int, horizontal: Boolean) {
            for (y in 0 until h) {
                for (x in 0 until w) {
                    var r = 0f
                    var g = 0f
                    var bl = 0f
                    var al = 0f
                    for (k in -radius..radius) {
                        val sx = if (horizontal) min(w - 1, max(0, x + k)) else x
                        val sy = if (horizontal) y else min(h - 1, max(0, y + k))
                        val i = (sy * w + sx) * 4
                        val f = kernel[k + radius]
                        r += src[i] * f
                        g += src[i + 1] * f
                        bl += src[i + 2] * f
                        al += src[i + 3] * f
                    }
                    val o = (y * w + x) * 4
                    dst[o] = r
                    dst[o + 1] = g
                    dst[o + 2] = bl
                    dst[o + 3] = al
                }
            }
        }
    }
}
