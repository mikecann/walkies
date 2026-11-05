package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Xfermode

/**
 * Sprites added up into one hardware draw each, rather than a bitmap call apiece. Every
 * cloud sprite of a look is packed into one mipmapped picture, and each puff is a quad of
 * it, so the clouds can be drawn again every frame: on a hardware canvas the GPU does the
 * drawing, and recording thousands of separate bitmap draws was what made drawing them
 * live take 100 ms a frame on an old tablet. The iPhone's GPUClouds does the same in Metal.
 *
 * Quads go in with [add] and are drawn when the paint they need changes (a different
 * alpha or blend), when it's full, or at [flush], which must be called before anything
 * else is drawn on the canvas so the order stays right.
 */
class SpriteBatch {
    /** The look's sprites in one picture, made the first time it's drawn. */
    private class Atlas(val sprites: CloudSprites) {
        val bitmap: Bitmap = Bitmap.createBitmap(COLUMNS * STRIDE, ROWS * STRIDE, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)

        init {
            val canvas = Canvas(bitmap)
            val draw = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
            val all = sprites.bases + sprites.tops + sprites.shadows + listOf(sprites.eraser, sprites.mist)
            val r = RectF()
            for ((i, sprite) in all.withIndex()) {
                cell(i, r)
                canvas.drawBitmap(sprite, null, r, draw)
            }
            // Small puffs read a small copy of their sprite, as they would on the iPhone.
            bitmap.setHasMipMap(true)
            bitmap.prepareToDraw()
            paint.shader = BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
    }

    private var atlas: Atlas? = null
    private val verts = FloatArray(MAX_QUADS * 8)
    private val texs = FloatArray(MAX_QUADS * 8)
    private var quads = 0
    private var alpha = 255
    private var mode: Xfermode? = null
    private val cellRect = RectF()

    /** One sprite (see [cell] for the order) stretched over [l], [t], [r], [b]. */
    fun add(canvas: Canvas, sprites: CloudSprites, sprite: Int, l: Float, t: Float, r: Float, b: Float, alpha: Int, mode: Xfermode?) {
        if (atlas?.sprites !== sprites) {
            flush(canvas)
            atlas?.bitmap?.recycle()
            atlas = Atlas(sprites)
        }
        if (quads > 0 && (alpha != this.alpha || mode !== this.mode)) flush(canvas)
        if (quads == MAX_QUADS) flush(canvas)
        this.alpha = alpha
        this.mode = mode
        cell(sprite, cellRect)
        val v = quads * 8
        verts[v] = l; verts[v + 1] = t
        verts[v + 2] = r; verts[v + 3] = t
        verts[v + 4] = r; verts[v + 5] = b
        verts[v + 6] = l; verts[v + 7] = b
        texs[v] = cellRect.left; texs[v + 1] = cellRect.top
        texs[v + 2] = cellRect.right; texs[v + 3] = cellRect.top
        texs[v + 4] = cellRect.right; texs[v + 5] = cellRect.bottom
        texs[v + 6] = cellRect.left; texs[v + 7] = cellRect.bottom
        quads++
    }

    /** Draws whatever's waiting. */
    fun flush(canvas: Canvas) {
        val atlas = atlas
        if (quads == 0 || atlas == null) {
            quads = 0
            return
        }
        atlas.paint.alpha = alpha
        atlas.paint.xfermode = mode
        canvas.drawVertices(
            Canvas.VertexMode.TRIANGLES, quads * 8, verts, 0, texs, 0, null, 0, INDICES, 0, quads * 6, atlas.paint,
        )
        quads = 0
    }

    fun close() {
        atlas?.bitmap?.recycle()
        atlas = null
    }

    companion object {
        /** In the atlas: the eight undersides, the eight tops, the eight shadows, the eraser, the mist. */
        const val BASES = 0
        const val TOPS = CloudField.SPRITE_COUNT
        const val SHADOWS = CloudField.SPRITE_COUNT * 2
        const val ERASER = CloudField.SPRITE_COUNT * 3
        const val MIST = ERASER + 1

        private const val SIZE = 256
        /** Clear space round each, so the small copies don't bleed into their neighbours. */
        private const val PAD = 8
        private const val STRIDE = SIZE + PAD * 2
        private const val COLUMNS = 6
        private const val ROWS = 5

        /** Quads per draw: their corners have to fit a short's index. */
        private const val MAX_QUADS = 16_000

        private val INDICES = ShortArray(MAX_QUADS * 6).also {
            for (q in 0 until MAX_QUADS) {
                val i = q * 6
                val v = q * 4
                it[i] = v.toShort(); it[i + 1] = (v + 1).toShort(); it[i + 2] = (v + 2).toShort()
                it[i + 3] = v.toShort(); it[i + 4] = (v + 2).toShort(); it[i + 5] = (v + 3).toShort()
            }
        }

        private fun cell(i: Int, out: RectF) {
            val x = (i % COLUMNS) * STRIDE + PAD
            val y = (i / COLUMNS) * STRIDE + PAD
            out.set(x.toFloat(), y.toFloat(), (x + SIZE).toFloat(), (y + SIZE).toFloat())
        }
    }
}
