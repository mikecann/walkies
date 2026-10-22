package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuffColorFilter
import android.graphics.Shader
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.place.RoadLine
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * What's equipped from the shell shop that shows on the map: the trail's style, the
 * marker's art, and the spyglass's ring while a hint's running. The art's loaded once
 * by whoever makes this.
 */
class MapCosmetics(
    val trail: String = "trail.teal",
    /** The equipped marker's picture, or null for the classic orange dot. */
    val marker: Bitmap? = null,
    val footprint: Bitmap? = null,
    val spyglass: Bitmap? = null,
    val ring: SpyglassRing? = null,
) {
    companion object {
        val none = MapCosmetics()
    }
}

/** A spyglass hint's gold ring on the ground, as 96 points round it in map points. */
class SpyglassRing(lat: Double, lon: Double, metres: Double) {
    val circle = DoubleArray(RING_POINTS * 2).also { out ->
        val cx = MapPoints.x(lon)
        val cy = MapPoints.y(lat)
        val r = metres * MapPoints.perMetre(lat)
        for (i in 0 until RING_POINTS) {
            val angle = i.toDouble() / RING_POINTS * 2 * Math.PI
            out[i * 2] = cx + cos(angle) * r
            out[i * 2 + 1] = cy + sin(angle) * r
        }
    }

    companion object {
        const val RING_POINTS = 96
    }
}

/**
 * Draws the clouds, the honeycomb and the bits of map that sit under the clouds
 * (the place outline and the walk's route), through the projection measured this
 * frame. A port of CloudPainter, Honeycomb and the map overlays in Clouds.swift and
 * FogMapView.swift. Sizes are iOS points, scaled by [density].
 *
 * Everything it needs per frame is allocated up front, so drawing allocates
 * nothing; the buffers only grow when the field does.
 */
class CloudPainter(private val density: Float) {
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val eraserPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
    }
    private val rect = RectF()
    private val path = Path()
    private val clip = Path()
    private val honeycombPaths = Array(5) { Path() }
    private val honeycombUsed = BooleanArray(5)

    private fun stroke(width: Float, colour: Int, dash: FloatArray? = null, round: Boolean = true) =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = width * density
            color = colour
            if (round) {
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
            }
            if (dash != null) pathEffect = DashPathEffect(FloatArray(dash.size) { dash[it] * density }, 0f)
        }

    private val gridPaint = stroke(1.2f, rgb(0.42, 0.5, 0.62), floatArrayOf(3f, 4f))
    private val roadPaint = stroke(1.8f, rgb(0.36, 0.45, 0.6, 0.6), floatArrayOf(6f, 5f))
    private val pathPaint = stroke(1.4f, rgb(0.36, 0.45, 0.6, 0.45), floatArrayOf(3f, 4f))
    /** The place's outline on the map: MapKit's white dashed polygon. */
    private val boundaryPaint = stroke(2f, rgb(1.0, 1.0, 1.0, 0.85), floatArrayOf(6f, 5f), round = false)
    /** Teal, so the route stands apart from this walk's orange tiles. */
    private val routePaint = stroke(TRAIL_WIDTH, TEAL)
    // Under every trail, so it reads over grass, trees, water and roads alike: a soft
    // light halo, then a thin dark edge, like the route lines in map apps (TrailContrast
    // in Clouds.swift).
    private val haloPaint = stroke(TRAIL_WIDTH + HALO_EXTRA, HALO)
    private val edgePaint = stroke(TRAIL_WIDTH + EDGE_EXTRA, EDGE)
    private val markHalo = stroke(3.5f, HALO).apply { strokeCap = Paint.Cap.BUTT }
    private val markEdge = stroke(1.4f, EDGE).apply { strokeCap = Paint.Cap.BUTT }
    private val footprintPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply {
        colorFilter = PorterDuffColorFilter(FOOTPRINT, PorterDuff.Mode.SRC_IN)
    }
    private val footprintEdge = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply {
        colorFilter = PorterDuffColorFilter(EDGE, PorterDuff.Mode.SRC_IN)
    }
    private val footprintHalo = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply {
        colorFilter = PorterDuffColorFilter(rgb(1.0, 1.0, 1.0, HALO_ALPHA + 0.15), PorterDuff.Mode.SRC_IN)
    }
    // Mist (Mist.kt): the haze on a layer of its own, and the sparkles as it clears.
    private val mistPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val sparkleFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val sparkleEdge = stroke(1f, Color.BLACK).apply { strokeCap = Paint.Cap.BUTT }
    /** Tiles uncovered this walk: MapKit's orange polygons under the clouds. */
    private val freshFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = rgb(1.0, 0.47, 0.18, 0.18) }
    private val freshStroke = stroke(2f, rgb(1.0, 0.47, 0.18), round = false)
    // Where you are (YouAreHere in Clouds.swift).
    private val accuracyFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = rgb(1.0, 0.47, 0.18, 0.12) }
    private val pulsePaint = stroke(3f, rgb(1.0, 0.47, 0.18))
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.WHITE
        setShadowLayer(4 * density, 0f, 2 * density, rgb(0.0, 0.0, 0.0, 0.3))
    }
    private val centrePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = rgb(1.0, 0.47, 0.18) }
    private val honeycombFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val honeycombStroke = stroke(1.2f, Color.WHITE)
    // The shop's trails, marker and spyglass ring (CosmeticTrail, YouAreHere and SpyglassRing in Clouds.swift).
    private val rainbowPaint = stroke(TRAIL_WIDTH, Color.WHITE)
    private val sparklePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val markerPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply {
        setShadowLayer(3 * density, 0f, 2 * density, rgb(0.0, 0.0, 0.0, 0.25))
    }
    private val ringFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = rgb(1.0, 0.79, 0.3, 0.09) }
    private val ringEdge = stroke(2f, rgb(1.0, 0.79, 0.3, 0.85), floatArrayOf(6f, 6f)).apply {
        setShadowLayer(4 * density, 0f, 0f, rgb(1.0, 0.79, 0.3, 0.5))
    }
    private val star = Path()
    private var run = FloatArray(256)

    // Where each cloud is this frame: its rect, its top's rect, its fade and its sprite.
    private var placedRect = FloatArray(0)
    private var placedTop = FloatArray(0)
    private var placedFade = FloatArray(0)
    private var placedVariant = IntArray(0)

    // The result of capped(): a rect, or nothing.
    private var cl = 0f
    private var ct = 0f
    private var cr = 0f
    private var cb = 0f

    /**
     * Everything, live, straight onto a [width] x [height] screen through this frame's
     * projection. Slow on old phones (thousands of sprites a frame), so the layer only
     * does this until its first bake is ready; after that it's [drawUnder], a baked
     * picture of [drawClouds] and [drawHoneycomb], then [drawOver].
     */
    fun draw(
        canvas: Canvas,
        field: CloudField,
        leaving: List<CloudField.Puff>,
        /** Which of the field's clearings have just opened, to grow them. */
        freshClearings: BooleanArray?,
        /** 0 to 1 through the latest tiles clearing. */
        reveal: Double,
        projection: Projection,
        sprites: CloudSprites,
        width: Float,
        height: Float,
        clock: Double,
        honeycomb: Float,
        route: DoubleArray,
        /** Tiles uncovered this walk, six corners each as interleaved x, y map points. */
        fresh: List<DoubleArray>,
        you: YouAreHere,
        cosmetics: MapCosmetics = MapCosmetics.none,
    ) {
        drawUnder(canvas, projection, width, height, clock, route, fresh, cosmetics)
        liveBounds.set(-width * 0.2f, -height * 0.2f, width * 1.2f, height * 1.2f)
        liveLayer.set(0f, 0f, width, height)
        drawClouds(canvas, field, leaving, freshClearings, reveal, projection, sprites, liveBounds, clock, liveLayer)
        if (honeycomb > 0) drawHoneycomb(canvas, field, projection, liveLayer, honeycomb)
        drawOver(canvas, projection, clock, you, cosmetics)
    }
    private val liveBounds = RectF()
    private val liveLayer = RectF()

    /**
     * What sits under the clouds and changes as you walk, drawn live each frame:
     * this walk's orange tiles and the route, in the equipped trail.
     */
    fun drawUnder(
        canvas: Canvas, projection: Projection, width: Float, height: Float, clock: Double,
        route: DoubleArray, fresh: List<DoubleArray>, cosmetics: MapCosmetics,
    ) {
        drawFresh(canvas, fresh, projection)
        // Footprints and the rainbow replace the teal line; sparkles go along it.
        if (cosmetics.trail != "trail.footprints" && cosmetics.trail != "trail.rainbow") drawRoute(canvas, route, projection, width, height)
        drawCosmeticTrail(canvas, route, projection, width, height, clock, cosmetics)
    }

    /** What goes over the clouds, live each frame: the spyglass's ring and where you are. */
    fun drawOver(canvas: Canvas, projection: Projection, clock: Double, you: YouAreHere, cosmetics: MapCosmetics) {
        cosmetics.ring?.let { drawRing(canvas, it, cosmetics.spyglass, projection) }
        drawYouAreHere(canvas, you, projection, clock, cosmetics.marker)
    }

    /**
     * The place's outline, the clouds with their shadows, the faint honeycomb and the
     * hidden streets, with soft holes over walked tiles: everything that only changes
     * when the tiles or the camera do, so it can be baked into a picture. Draws what
     * falls in [bounds] (screen pixels of [projection]); the clouds' own layer is
     * [layer]. With [near] (min x, min y, max x, max y in map points), it skips
     * whatever's nowhere near that box, for redrawing just the bit round tiles
     * clearing; everything else is drawn exactly as for the whole, so the two match.
     */
    fun drawClouds(
        canvas: Canvas,
        field: CloudField,
        leaving: List<CloudField.Puff>,
        freshClearings: BooleanArray?,
        reveal: Double,
        projection: Projection,
        sprites: CloudSprites,
        bounds: RectF,
        clock: Double,
        layer: RectF = bounds,
        near: DoubleArray? = null,
        /** Mist over tiles just walked again, fading under a few sparkles. */
        leavingMist: List<CloudField.MistPatch> = emptyList(),
    ) {
        val scale = projection.centreScale / density
        drawBoundary(canvas, field, projection, near)

        val visibleL = bounds.left
        val visibleT = bounds.top
        val visibleR = bounds.right
        val visibleB = bounds.bottom
        val ease = 1 - (1 - reveal).pow(3)

        val capacity = field.puffs.size + leaving.size
        if (placedFade.size < capacity) {
            placedRect = FloatArray(capacity * 4)
            placedTop = FloatArray(capacity * 4)
            placedFade = FloatArray(capacity)
            placedVariant = IntArray(capacity)
        }

        // Where each cloud is this frame: bobbing gently around its tile and swelling a touch.
        var n = 0
        for (i in field.puffs.indices) {
            val puff = field.puffs[i]
            if (away(near, puff.x, puff.y, puff.radius * PUFF_REACH)) continue
            if (!capped(projection, puff.x, puff.y, puff.radius)) continue
            if (cr < visibleL || cl > visibleR || cb < visibleT || ct > visibleB) continue
            place(n++, puff.phase, 1f, puff.variant, clock)
        }
        if (reveal < 1) {
            for (i in leaving.indices) {
                val puff = leaving[i]
                val radius = puff.radius * (1 + 0.5 * ease)
                if (away(near, puff.x, puff.y, radius * PUFF_REACH)) continue
                if (!capped(projection, puff.x, puff.y, radius)) continue
                if (cr < visibleL || cl > visibleR || cb < visibleT || ct > visibleB) continue
                place(n++, puff.phase, (1 - ease).toFloat(), puff.variant, clock)
            }
        }
        if (n > 0) {
            // Zoomed out, a puff is only a few points across and its shadow and underside
            // barely show, so they fade away and only the tops are drawn.
            val first = field.puffs.firstOrNull() ?: leaving.firstOrNull()
            val puffSize = (first?.radius ?: 0.0) * 2 * scale
            val detail = min(1.0, max(0.0, (puffSize - SIMPLE_PUFF) / SIMPLE_PUFF)).toFloat()

            // Shadows on the ground, with the sun to the north-west. Straight onto the
            // map rather than through a layer of their own, which costs a whole extra
            // screen of drawing.
            if (detail > 0) {
                for (i in 0 until n) {
                    bitmapPaint.alpha = alpha(0.35f * placedFade[i] * detail)
                    val w = placedRect[i * 4 + 2] - placedRect[i * 4]
                    val h = placedRect[i * 4 + 3] - placedRect[i * 4 + 1]
                    rect.set(placedRect[i * 4], placedRect[i * 4 + 1], placedRect[i * 4 + 2], placedRect[i * 4 + 3])
                    rect.offset(w * 0.15f, h * 0.18f)
                    canvas.drawBitmap(sprites.shadows[placedVariant[i]], null, rect, bitmapPaint)
                }
            }

            val saved = canvas.saveLayer(layer, null)
            // Every shaded underside first, then every sunlit top, so the middle of the
            // blanket is one continuous white and the grey only shows round its edges.
            if (detail > 0) {
                for (i in 0 until n) {
                    bitmapPaint.alpha = alpha(placedFade[i] * detail)
                    rect.set(placedRect[i * 4], placedRect[i * 4 + 1], placedRect[i * 4 + 2], placedRect[i * 4 + 3])
                    canvas.drawBitmap(sprites.bases[placedVariant[i]], null, rect, bitmapPaint)
                }
            }
            for (i in 0 until n) {
                bitmapPaint.alpha = alpha(placedFade[i])
                rect.set(placedTop[i * 4], placedTop[i * 4 + 1], placedTop[i * 4 + 2], placedTop[i * 4 + 3])
                canvas.drawBitmap(sprites.tops[placedVariant[i]], null, rect, bitmapPaint)
            }
            bitmapPaint.alpha = 255
            drawGrid(canvas, field, projection, scale, bounds, near)
            // Leaves the canvas clipped to the place outlines, as in Swift, so the
            // clearings below are too.
            drawRoads(canvas, field, projection, scale, bounds, near)

            // Soft holes over walked tiles. New ones open up rather than just appearing.
            for (i in field.clearings.indices) {
                val clearing = field.clearings[i]
                val grow = if (freshClearings != null && i < freshClearings.size && freshClearings[i]) 0.3 + 0.7 * ease else 1.0
                if (away(near, clearing.x, clearing.y, clearing.radius * 1.5)) continue
                if (!capped(projection, clearing.x, clearing.y, clearing.radius * grow)) continue
                if (cr < visibleL || cl > visibleR || cb < visibleT || ct > visibleB) continue
                rect.set(cl, ct, cr, cb)
                canvas.drawBitmap(sprites.eraser, null, rect, eraserPaint)
            }
            canvas.restoreToCount(saved)
        }
        drawMist(canvas, field, leavingMist, reveal, ease, projection, sprites, bounds, layer, near)
    }

    /**
     * The haze over misty tiles, on a layer of its own so where patches overlap it stays
     * one even wash, then the sparkles over mist just cleared: a lighter touch than
     * clouds parting. As drawMist in CloudScene.swift.
     */
    private fun drawMist(
        canvas: Canvas, field: CloudField, leavingMist: List<CloudField.MistPatch>, reveal: Double, ease: Double,
        projection: Projection, sprites: CloudSprites, bounds: RectF, layer: RectF, near: DoubleArray?,
    ) {
        val fading = reveal < 1 && leavingMist.isNotEmpty()
        if (field.mist.isEmpty() && !fading) return
        var saved = -1
        fun patch(p: CloudField.MistPatch, fade: Float) {
            if (away(near, p.x, p.y, p.radius * 1.5)) return
            if (!capped(projection, p.x, p.y, p.radius)) return
            if (cr < bounds.left || cl > bounds.right || cb < bounds.top || ct > bounds.bottom) return
            // Only once there's something to show: a layer costs a whole screen of drawing.
            if (saved < 0) saved = canvas.saveLayerAlpha(layer, alpha(MIST_OPACITY))
            mistPaint.alpha = alpha(fade)
            rect.set(cl, ct, cr, cb)
            canvas.drawBitmap(sprites.mist, null, rect, mistPaint)
        }
        for (p in field.mist) patch(p, 1f)
        if (fading) for (p in leavingMist) patch(p, (1 - ease).toFloat())
        if (saved >= 0) canvas.restoreToCount(saved)
        if (!fading) return
        for (p in leavingMist) {
            if (away(near, p.x, p.y, p.radius * 1.5)) continue
            if (!capped(projection, p.x, p.y, p.radius)) continue
            if (cr < bounds.left || cl > bounds.right || cb < bounds.top || ct > bounds.bottom) continue
            drawSparkles(canvas, p.tile, cl, ct, cr, cb, reveal)
        }
    }

    /**
     * A handful of stars over a tile whose mist is clearing, each twinkling in and out
     * at its own moment as it drifts up, always the same way for the same tile (and the
     * same as the iPhone's). None when the tile's too small on screen to see them.
     */
    private fun drawSparkles(canvas: Canvas, tile: Hex, l: Float, t: Float, r: Float, b: Float, reveal: Double) {
        // The patch is bigger than the tile; the tile's about three quarters of it.
        val size = min(r - l, b - t) / CloudField.MIST_SPREAD
        if (size < SPARKLE_TILE * density) return
        val rng = SplitMix64(CloudField.hash(tile))
        val cx = (l + r) / 2.0
        val cy = (t + b) / 2.0
        repeat(5) {
            val start = rng.unit() * 0.45
            val f = (reveal - start) / 0.5
            val x = cx + (rng.unit() - 0.5) * size * 0.8
            val y = cy + (rng.unit() - 0.5) * size * 0.6
            val scale = 0.8 + rng.unit() * 0.5
            if (f <= 0 || f >= 1) return@repeat
            val pulse = sin(f * Math.PI)
            starPath(x, y - f * size * 0.15, (2.5 + 3.5 * pulse) * scale * density)
            sparkleEdge.color = rgb(0.0, 0.0, 0.0, 0.35 * pulse)
            canvas.drawPath(star, sparkleEdge)
            sparkleFill.color = rgb(1.0, 0.97, 0.82, pulse)
            canvas.drawPath(star, sparkleFill)
        }
    }

    /** A four-pointed star round [x], [y], into [star]. */
    private fun starPath(x: Double, y: Double, radius: Double) {
        val r = radius.toFloat()
        val inner = r * 0.3f
        val cx = x.toFloat()
        val cy = y.toFloat()
        star.rewind()
        star.moveTo(cx, cy - r)
        star.lineTo(cx + inner, cy - inner)
        star.lineTo(cx + r, cy)
        star.lineTo(cx + inner, cy + inner)
        star.lineTo(cx, cy + r)
        star.lineTo(cx - inner, cy + inner)
        star.lineTo(cx - r, cy)
        star.lineTo(cx - inner, cy - inner)
        star.close()
    }

    /**
     * The box of screen pixels (of [projection]) that tiles clearing change as they
     * open: the clearings growing and the clouds drifting off them, with room for
     * their shadows. Into [out]; false if there's nothing.
     */
    fun revealBounds(
        field: CloudField, leaving: List<CloudField.Puff>, freshClearings: BooleanArray?, projection: Projection, out: RectF,
        leavingMist: List<CloudField.MistPatch> = emptyList(),
    ): Boolean {
        out.setEmpty()
        var any = false
        fun add(x: Double, y: Double, radius: Double) {
            if (!capped(projection, x, y, radius)) return
            // Drift, swell and the shadow's offset all reach past the cloud itself.
            val padX = (cr - cl) * 0.4f
            val padY = (cb - ct) * 0.4f
            if (!any) out.set(cl - padX, ct - padY, cr + padX, cb + padY) else out.union(cl - padX, ct - padY, cr + padX, cb + padY)
            any = true
        }
        for (puff in leaving) add(puff.x, puff.y, puff.radius * 1.5)
        // Room for the sparkles drifting up off it.
        for (patch in leavingMist) add(patch.x, patch.y, patch.radius)
        if (freshClearings != null) {
            for (i in field.clearings.indices) {
                if (i < freshClearings.size && freshClearings[i]) add(field.clearings[i].x, field.clearings[i].y, field.clearings[i].radius)
            }
        }
        return any
    }

    /** True if a circle of [reach] round [x], [y] can't touch the [near] box. Never without one. */
    private fun away(near: DoubleArray?, x: Double, y: Double, reach: Double) =
        near != null && (x + reach < near[0] || x - reach > near[2] || y + reach < near[1] || y - reach > near[3])

    private fun away(near: DoubleArray?, bounds: DoubleArray, i: Int) =
        near != null && (bounds[i * 4 + 2] < near[0] || bounds[i * 4] > near[2] || bounds[i * 4 + 3] < near[1] || bounds[i * 4 + 1] > near[3])

    /**
     * The decorated trails, a fixed size on screen: footprints, twinkling sparkles, or
     * a rainbow line. Projected into runs of screen points, split where the route
     * goes behind the camera.
     */
    private fun drawCosmeticTrail(canvas: Canvas, route: DoubleArray, projection: Projection, width: Float, height: Float, clock: Double, cosmetics: MapCosmetics) {
        val style = cosmetics.trail
        if (style != "trail.footprints" && style != "trail.sparkles" && style != "trail.rainbow") return
        if (route.size < 4) return
        val pad = 16 * density
        val left = -pad.toDouble()
        val top = -pad.toDouble()
        val right = (width + pad).toDouble()
        val bottom = (height + pad).toDouble()
        if (style == "trail.rainbow") path.rewind()
        var minX = Float.POSITIVE_INFINITY
        var minY = Float.POSITIVE_INFINITY
        var maxX = Float.NEGATIVE_INFINITY
        var maxY = Float.NEGATIVE_INFINITY
        var n = 0
        fun flush() {
            if (n < 2) {
                n = 0
                return
            }
            if (style == "trail.rainbow") {
                for (i in 1 until n) {
                    val ax = run[(i - 1) * 2].toDouble()
                    val ay = run[(i - 1) * 2 + 1].toDouble()
                    val bx = run[i * 2].toDouble()
                    val by = run[i * 2 + 1].toDouble()
                    val low = TrailLayout.visibleLow(ax, ay, bx, by, left, top, right, bottom)
                    if (low.isNaN()) continue
                    val high = TrailLayout.visibleHigh(ax, ay, bx, by, left, top, right, bottom)
                    val sx = (ax + (bx - ax) * low).toFloat()
                    val sy = (ay + (by - ay) * low).toFloat()
                    val ex = (ax + (bx - ax) * high).toFloat()
                    val ey = (ay + (by - ay) * high).toFloat()
                    path.moveTo(sx, sy)
                    path.lineTo(ex, ey)
                    minX = min(minX, min(sx, ex)); maxX = max(maxX, max(sx, ex))
                    minY = min(minY, min(sy, ey)); maxY = max(maxY, max(sy, ey))
                }
            } else {
                val footprints = style == "trail.footprints"
                TrailLayout.forEachStamp(run, n, (if (footprints) 12 else 26) * density.toDouble(), left, top, right, bottom) { x, y, angle, index ->
                    if (footprints) drawFootprint(canvas, cosmetics.footprint, x, y, angle, index % 2 == 0)
                    else drawSparkle(canvas, x, y, clock, index)
                }
            }
            n = 0
        }
        var j = 2
        while (j < route.size) {
            if (projection.segment(route[j - 2], route[j - 1], route[j], route[j + 1])) {
                if (n == 0 || run[(n - 1) * 2] != projection.x || run[(n - 1) * 2 + 1] != projection.y) {
                    flush()
                    add(projection.x, projection.y, n++)
                }
                add(projection.x2, projection.y2, n++)
            } else {
                flush()
            }
            j += 2
        }
        flush()
        if (style == "trail.rainbow" && minX.isFinite()) {
            // One gradient stroke keeps even a long route cheap to paint. Along its longest
            // screen axis, so a north-south or diagonal walk gets every colour.
            val horizontal = maxX - minX >= maxY - minY
            if (max(maxX - minX, maxY - minY) <= 0f) return
            rainbowPaint.shader = LinearGradient(
                minX, minY, if (horizontal) maxX else minX, if (horizontal) minY else maxY,
                RAINBOW, null, Shader.TileMode.CLAMP,
            )
            canvas.drawPath(path, haloPaint)
            canvas.drawPath(path, edgePaint)
            canvas.drawPath(path, rainbowPaint)
        }
    }

    private fun add(x: Float, y: Float, i: Int) {
        if (run.size < (i + 1) * 2) run = run.copyOf(run.size * 2)
        run[i * 2] = x
        run[i * 2 + 1] = y
    }

    private fun drawFootprint(canvas: Canvas, footprint: Bitmap?, x: Double, y: Double, angle: Double, isLeft: Boolean) {
        footprint ?: return
        canvas.save()
        canvas.translate(x.toFloat(), y.toFloat())
        canvas.rotate(Math.toDegrees(angle).toFloat())
        canvas.translate(0f, (if (isLeft) -2.5f else 2.5f) * density)
        // The toes in the art point up. Turn them forwards, then mirror every other
        // print for a left and a right foot.
        canvas.rotate(90f)
        if (!isLeft) canvas.scale(-1f, 1f)
        // A light halo, a dark edge, then the print itself in a stronger green than the picture's.
        rect.set(-6.2f * density, -7.95f * density, 6.2f * density, 7.95f * density)
        canvas.drawBitmap(footprint, null, rect, footprintHalo)
        rect.set(-5f * density, -6.75f * density, 5f * density, 6.75f * density)
        canvas.drawBitmap(footprint, null, rect, footprintEdge)
        rect.set(-4f * density, -5.75f * density, 4f * density, 5.75f * density)
        canvas.drawBitmap(footprint, null, rect, footprintPaint)
        canvas.restore()
    }

    private fun drawSparkle(canvas: Canvas, x: Double, y: Double, clock: Double, index: Int) {
        val twinkle = 0.5 + 0.5 * sin(clock * 2.4 + index * 2.399)
        starPath(x, y, (2 + twinkle * 1.8) * density)
        val a = 0.5 + twinkle * 0.5
        markHalo.alpha = alpha((HALO_ALPHA * a).toFloat())
        canvas.drawPath(star, markHalo)
        markEdge.alpha = alpha((EDGE_ALPHA * a).toFloat())
        canvas.drawPath(star, markEdge)
        sparklePaint.color = rgb(1.0, 0.81, 0.25, a)
        canvas.drawPath(star, sparklePaint)
    }

    /**
     * The spyglass's gold ring. The circle itself is projected, so the camera's heading
     * and tilt both show in it, rather than an upright oval on screen.
     */
    private fun drawRing(canvas: Canvas, ring: SpyglassRing, spyglass: Bitmap?, projection: Projection) {
        val circle = ring.circle
        path.rewind()
        var points = 0
        projection.polygon(circle) { x, y, first ->
            if (first) path.moveTo(x, y) else path.lineTo(x, y)
            points++
        }
        if (points < 3) return
        path.close()
        canvas.drawPath(path, ringFill)
        path.rewind()
        val n = circle.size / 2
        var lastX = Float.NaN
        var lastY = Float.NaN
        for (i in 0 until n) {
            val k = (i + 1) % n
            if (!projection.segment(circle[i * 2], circle[i * 2 + 1], circle[k * 2], circle[k * 2 + 1])) continue
            if (projection.x != lastX || projection.y != lastY) path.moveTo(projection.x, projection.y)
            path.lineTo(projection.x2, projection.y2)
            lastX = projection.x2
            lastY = projection.y2
        }
        canvas.drawPath(path, ringEdge)
        if (spyglass != null && projection.isInFront(circle[24], circle[25])) {
            projection.point(circle[24], circle[25])
            rect.set(projection.x - 12 * density, projection.y - 12 * density, projection.x + 12 * density, projection.y + 12 * density)
            canvas.drawBitmap(spyglass, null, rect, bitmapPaint)
        }
    }

    private fun drawFresh(canvas: Canvas, fresh: List<DoubleArray>, projection: Projection) {
        if (fresh.isEmpty()) return
        path.rewind()
        for (tile in fresh) {
            projection.polygon(tile) { x, y, first -> if (first) path.moveTo(x, y) else path.lineTo(x, y) }
            path.close()
        }
        canvas.drawPath(path, freshFill)
        canvas.drawPath(path, freshStroke)
    }

    /** An orange dot in a white ring with a slow pulse, drawn over the clouds, or the equipped marker. */
    private fun drawYouAreHere(canvas: Canvas, you: YouAreHere, projection: Projection, clock: Double, marker: Bitmap?) {
        if (!you.visible || !projection.isInFront(you.x, you.y)) return
        // How sure the GPS is, as a faint patch on the ground.
        if (you.radius > 0 && projection.ellipse(you.x, you.y, you.radius) && projection.rx * 2 > 30 * density) {
            rect.set(projection.ex - projection.rx, projection.ey - projection.ry, projection.ex + projection.rx, projection.ey + projection.ry)
            canvas.drawOval(rect, accuracyFill)
        }
        projection.point(you.x, you.y)
        val cx = projection.x
        val cy = projection.y
        val pulse = ((clock / 2) % 1 + 1) % 1
        pulsePaint.alpha = alpha((0.55 * (1 - pulse)).toFloat())
        canvas.drawCircle(cx, cy, ((11 + 22 * pulse) * density).toFloat(), pulsePaint)
        canvas.drawCircle(cx, cy, 11 * density, dotPaint)
        if (marker != null) {
            val scale = 34 * density / max(marker.width, marker.height)
            val w = marker.width * scale
            val h = marker.height * scale
            rect.set(cx - w / 2, cy - h / 2 - 3 * density, cx + w / 2, cy + h / 2 - 3 * density)
            canvas.drawBitmap(marker, null, rect, markerPaint)
            return
        }
        canvas.drawCircle(cx, cy, 7.5f * density, centrePaint)
    }

    private fun place(i: Int, phase: Double, fade: Float, variant: Int, clock: Double) {
        drift(placedRect, i, phase, clock)
        drift(placedTop, i, phase + 0.7, clock)
        placedFade[i] = fade
        placedVariant[i] = variant
    }

    /** Writes the capped rect, drifted by this phase, into [out] at [i]. */
    private fun drift(out: FloatArray, i: Int, phase: Double, clock: Double) {
        val w = cr - cl
        val h = cb - ct
        val dx = (sin(clock * 0.23 + phase) * 0.07 * w).toFloat()
        val dy = (cos(clock * 0.19 + phase * 1.7) * 0.06 * h).toFloat()
        val swell = (1 + 0.05 * sin(clock * 0.31 + phase * 2.3)).toFloat()
        val mx = (cl + cr) / 2 + dx
        val my = (ct + cb) / 2 + dy
        out[i * 4] = mx - w * swell / 2
        out[i * 4 + 1] = my - h * swell / 2
        out[i * 4 + 2] = mx + w * swell / 2
        out[i * 4 + 3] = my + h * swell / 2
    }

    /**
     * A circle on the ground as it looks on screen, into [cl], [ct], [cr], [cb].
     * Clouds right by a tilted camera would balloon to fill the screen, so none get
     * more than twice the size they'd be mid-screen. False if it's behind the camera.
     */
    private fun capped(projection: Projection, x: Double, y: Double, radius: Double): Boolean {
        if (!projection.ellipse(x, y, radius)) return false
        var rx = projection.rx
        var ry = projection.ry
        val limit = (radius * 2 * projection.centreScale * 2).toFloat()
        val biggest = max(rx, ry) * 2
        if (limit > 0 && biggest > limit) {
            val f = limit / biggest
            rx *= f
            ry *= f
        }
        cl = projection.ex - rx
        cr = projection.ex + rx
        ct = projection.ey - ry
        cb = projection.ey + ry
        return true
    }

    /** A faint dashed honeycomb over the clouds, fading in as you zoom closer. */
    private fun drawGrid(canvas: Canvas, field: CloudField, projection: Projection, scale: Double, bounds: RectF, near: DoubleArray?) {
        if (scale <= 0.15 || field.gridEdges.isEmpty()) return
        val pad = 40 * density
        val l = bounds.left - pad
        val t = bounds.top - pad
        val r = bounds.right + pad
        val b = bounds.bottom + pad
        path.rewind()
        val edges = field.gridEdges
        var i = 0
        while (i < edges.size) {
            if (near != null) {
                val reach = abs(edges[i + 2] - edges[i]) + abs(edges[i + 3] - edges[i + 1])
                if (away(near, edges[i], edges[i + 1], reach)) {
                    i += 4
                    continue
                }
            }
            if (projection.segment(edges[i], edges[i + 1], edges[i + 2], edges[i + 3])) {
                val aIn = projection.x >= l && projection.x <= r && projection.y >= t && projection.y <= b
                val bIn = projection.x2 >= l && projection.x2 <= r && projection.y2 >= t && projection.y2 <= b
                if (aIn || bIn) {
                    path.moveTo(projection.x, projection.y)
                    path.lineTo(projection.x2, projection.y2)
                }
            }
            i += 4
        }
        val fade = min(1.0, (scale - 0.15) / 0.2)
        gridPaint.alpha = alpha((0.5 * fade).toFloat())
        canvas.drawPath(path, gridPaint)
    }

    /** The hidden streets as light dashed lines, inside the place only. */
    private fun drawRoads(canvas: Canvas, field: CloudField, projection: Projection, scale: Double, bounds: RectF, near: DoubleArray?) {
        if (scale <= 0.05) return
        clip.rewind()
        for (r in field.outline.indices) {
            if (away(near, field.outlineBounds, r)) continue
            projection.polygon(field.outline[r]) { x, y, first -> if (first) clip.moveTo(x, y) else clip.lineTo(x, y) }
            clip.close()
        }
        canvas.clipPath(clip)

        // Only the bits on screen. Zoomed in, every street in every place adds up to
        // hundreds of thousands of points of dashed line, which is slow to dash.
        val pad = 20 * density
        val left = bounds.left - pad
        val top = bounds.top - pad
        val right = bounds.right + pad
        val bottom = bounds.bottom + pad
        for (kind in KINDS) {
            if (kind == RoadLine.Kind.Path && scale <= 0.12) continue
            path.rewind()
            for (l in field.lines.indices) {
                val line = field.lines[l]
                if (line.kind != kind) continue
                if (away(near, field.lineBounds, l)) continue
                val points = line.points
                var drawing = false
                var j = 2
                while (j < points.size) {
                    if (!projection.segment(points[j - 2], points[j - 1], points[j], points[j + 1])) {
                        drawing = false
                        j += 2
                        continue
                    }
                    val ax = projection.x
                    val ay = projection.y
                    val bx = projection.x2
                    val by = projection.y2
                    val visible = max(ax, bx) >= left && min(ax, bx) <= right && max(ay, by) >= top && min(ay, by) <= bottom
                    if (visible) {
                        if (!drawing) path.moveTo(ax, ay)
                        path.lineTo(bx, by)
                    }
                    drawing = visible
                    j += 2
                }
            }
            canvas.drawPath(path, if (kind == RoadLine.Kind.Road) roadPaint else pathPaint)
        }
    }

    /** The place's outline, which MapKit draws as a map overlay under the clouds. */
    private fun drawBoundary(canvas: Canvas, field: CloudField, projection: Projection, near: DoubleArray?) {
        path.rewind()
        for (r in field.outline.indices) {
            if (away(near, field.outlineBounds, r)) continue
            projection.polygon(field.outline[r]) { x, y, first -> if (first) path.moveTo(x, y) else path.lineTo(x, y) }
            path.close()
        }
        canvas.drawPath(path, boundaryPaint)
    }

    /** The walk's route, a map overlay under the clouds on iOS. Interleaved x, y map points. */
    private fun drawRoute(canvas: Canvas, route: DoubleArray, projection: Projection, width: Float, height: Float) {
        if (route.size < 4) return
        path.rewind()
        var drawing = false
        var j = 2
        while (j < route.size) {
            if (projection.segment(route[j - 2], route[j - 1], route[j], route[j + 1])) {
                if (!drawing) path.moveTo(projection.x, projection.y)
                path.lineTo(projection.x2, projection.y2)
                drawing = true
            } else {
                drawing = false
            }
            j += 2
        }
        canvas.drawPath(path, haloPaint)
        canvas.drawPath(path, edgePaint)
        canvas.drawPath(path, routePaint)
    }

    /**
     * The colour-coded tiles that show while you drag the map: green where you've
     * walked, orange where you walked this time, white outlines still to walk, and grey
     * where there's no street or path (those clear when you walk beside them).
     */
    fun drawHoneycomb(canvas: Canvas, field: CloudField, projection: Projection, bounds: RectF, opacity: Float) {
        val pad = 60 * density
        val left = bounds.left - pad
        val top = bounds.top - pad
        val right = bounds.right + pad
        val bottom = bounds.bottom + pad
        for (k in honeycombPaths.indices) {
            honeycombPaths[k].rewind()
            honeycombUsed[k] = false
        }
        for (o in field.outlines.indices) {
            val outline = field.outlines[o]
            if (!projection.isInFront(outline.x, outline.y)) continue
            projection.point(outline.x, outline.y)
            if (projection.x < left || projection.x > right || projection.y < top || projection.y > bottom) continue
            val p = honeycombPaths[outline.kind]
            honeycombUsed[outline.kind] = true
            val c = outline.corners
            for (i in 0 until 6) {
                projection.point(c[i * 2], c[i * 2 + 1])
                if (i == 0) p.moveTo(projection.x, projection.y) else p.lineTo(projection.x, projection.y)
            }
            p.close()
        }
        for (k in honeycombPaths.indices) {
            if (!honeycombUsed[k]) continue
            honeycombFill.color = HONEYCOMB_COLOURS[k]
            honeycombFill.alpha = alpha(HONEYCOMB_FILL[k] * opacity)
            canvas.drawPath(honeycombPaths[k], honeycombFill)
            honeycombStroke.color = HONEYCOMB_COLOURS[k]
            honeycombStroke.alpha = alpha(HONEYCOMB_STROKE[k] * opacity)
            canvas.drawPath(honeycombPaths[k], honeycombStroke)
        }
    }

    private fun alpha(a: Float) = (min(1f, max(0f, a)) * 255).roundToInt()

    companion object {
        /** Below this many points across, a puff is drawn as just its top. Its shadow and underside fade in up to twice this. */
        const val SIMPLE_PUFF = 8.0

        /**
         * How far a puff's sprite, shadow and drift can reach on the ground, as a
         * multiple of its radius, for leaving out the ones that can't touch a patch.
         */
        private const val PUFF_REACH = 2.5

        private val KINDS = arrayOf(RoadLine.Kind.Road, RoadLine.Kind.Path)

        fun rgb(r: Double, g: Double, b: Double, a: Double = 1.0) =
            Color.argb((a * 255).roundToInt(), (r * 255).roundToInt(), (g * 255).roundToInt(), (b * 255).roundToInt())

        /** The rainbow's colours: SwiftUI's, but a brighter, yellower green that grass can't swallow. */
        private val RAINBOW = intArrayOf(
            rgb(1.0, 0.23, 0.19), rgb(1.0, 0.58, 0.0), rgb(1.0, 0.8, 0.0), rgb(0.45, 0.93, 0.3),
            rgb(0.2, 0.78, 1.0), rgb(0.0, 0.48, 1.0), rgb(0.69, 0.32, 0.87),
        )

        // TrailContrast in Clouds.swift.
        /** The plain line, brighter and bluer than it was so it doesn't sink into grass and water. */
        val TEAL = rgb(0.1, 0.85, 0.95)
        /** This walk's line, in points. */
        const val TRAIL_WIDTH = 5.5f
        const val HALO_ALPHA = 0.45
        /** How much wider than the line the halo is, in all. */
        const val HALO_EXTRA = 6f
        const val EDGE_ALPHA = 0.6
        const val EDGE_EXTRA = 2.5f
        private val HALO = rgb(1.0, 1.0, 1.0, HALO_ALPHA)
        private val EDGE = rgb(0.05, 0.12, 0.16, EDGE_ALPHA)
        /** The footprints' green, lighter and stronger than the shop's picture of them. */
        private val FOOTPRINT = rgb(0.56, 0.93, 0.42)

        /** Morning haze: paler and far more see-through than the clouds, so a misty tile still reads as cleared. */
        const val MIST_OPACITY = 0.42f
        /** Sparkles only once a tile's at least this many points across. */
        const val SPARKLE_TILE = 10f

        private val green = rgb(0.36, 0.72, 0.4)
        private val grey = rgb(0.35, 0.37, 0.42)
        private val orange = rgb(1.0, 0.47, 0.18)

        // Visited, cleared, open, blocked, this walk.
        private val HONEYCOMB_COLOURS = intArrayOf(green, green, Color.WHITE, grey, orange)
        private val HONEYCOMB_FILL = floatArrayOf(0.3f, 0.12f, 0.06f, 0.35f, 0.35f)
        private val HONEYCOMB_STROKE = floatArrayOf(0.9f, 0.45f, 0.85f, 0.5f, 1f)
    }
}
