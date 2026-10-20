package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import com.mikecann.walkies.place.RoadLine
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
    private val routePaint = stroke(4f, rgb(0.16, 0.72, 0.78))
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
    private val rainbowPaint = stroke(4f, Color.WHITE)
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
        val scale = projection.centreScale / density
        drawBoundary(canvas, field, projection)
        drawFresh(canvas, fresh, projection)
        // Footprints and the rainbow replace the teal line; sparkles go along it.
        if (cosmetics.trail != "trail.footprints" && cosmetics.trail != "trail.rainbow") drawRoute(canvas, route, projection, width, height)
        drawCosmeticTrail(canvas, route, projection, width, height, clock, cosmetics)

        val visibleL = -width * 0.2f
        val visibleT = -height * 0.2f
        val visibleR = width * 1.2f
        val visibleB = height * 1.2f
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
            if (!capped(projection, puff.x, puff.y, puff.radius)) continue
            if (cr < visibleL || cl > visibleR || cb < visibleT || ct > visibleB) continue
            place(n++, puff.phase, 1f, puff.variant, clock)
        }
        if (reveal < 1) {
            for (i in leaving.indices) {
                val puff = leaving[i]
                val radius = puff.radius * (1 + 0.5 * ease)
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
            // screen of drawing every frame.
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

            val layer = canvas.saveLayer(0f, 0f, width, height, null)
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
            drawGrid(canvas, field, projection, scale, width, height)
            // Leaves the canvas clipped to the place outlines, as in Swift, so the
            // clearings below are too.
            drawRoads(canvas, field, projection, scale, width, height)

            // Soft holes over walked tiles. New ones open up rather than just appearing.
            for (i in field.clearings.indices) {
                val clearing = field.clearings[i]
                val grow = if (freshClearings != null && i < freshClearings.size && freshClearings[i]) 0.3 + 0.7 * ease else 1.0
                if (!capped(projection, clearing.x, clearing.y, clearing.radius * grow)) continue
                if (cr < visibleL || cl > visibleR || cb < visibleT || ct > visibleB) continue
                rect.set(cl, ct, cr, cb)
                canvas.drawBitmap(sprites.eraser, null, rect, eraserPaint)
            }
            canvas.restoreToCount(layer)
        }

        if (honeycomb > 0) drawHoneycomb(canvas, field, projection, width, height, honeycomb)
        cosmetics.ring?.let { drawRing(canvas, it, cosmetics.spyglass, projection) }
        drawYouAreHere(canvas, you, projection, clock, cosmetics.marker)
    }

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
        rect.set(-3.5f * density, -5f * density, 3.5f * density, 5f * density)
        canvas.drawBitmap(footprint, null, rect, bitmapPaint)
        canvas.restore()
    }

    private fun drawSparkle(canvas: Canvas, x: Double, y: Double, clock: Double, index: Int) {
        val twinkle = 0.5 + 0.5 * sin(clock * 2.4 + index * 2.399)
        val r = ((2 + twinkle * 1.8) * density).toFloat()
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
        sparklePaint.color = rgb(1.0, 0.81, 0.25, 0.5 + twinkle * 0.5)
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
    private fun drawGrid(canvas: Canvas, field: CloudField, projection: Projection, scale: Double, width: Float, height: Float) {
        if (scale <= 0.15 || field.gridEdges.isEmpty()) return
        val pad = 40 * density
        path.rewind()
        val edges = field.gridEdges
        var i = 0
        while (i < edges.size) {
            if (projection.segment(edges[i], edges[i + 1], edges[i + 2], edges[i + 3])) {
                val aIn = projection.x >= -pad && projection.x <= width + pad && projection.y >= -pad && projection.y <= height + pad
                val bIn = projection.x2 >= -pad && projection.x2 <= width + pad && projection.y2 >= -pad && projection.y2 <= height + pad
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
    private fun drawRoads(canvas: Canvas, field: CloudField, projection: Projection, scale: Double, width: Float, height: Float) {
        if (scale <= 0.05) return
        clip.rewind()
        for (r in field.outline.indices) {
            projection.polygon(field.outline[r]) { x, y, first -> if (first) clip.moveTo(x, y) else clip.lineTo(x, y) }
            clip.close()
        }
        canvas.clipPath(clip)

        // Only the bits on screen. Zoomed in, every street in every place adds up to
        // hundreds of thousands of points of dashed line, which is slow to dash.
        val pad = 20 * density
        for (kind in KINDS) {
            if (kind == RoadLine.Kind.Path && scale <= 0.12) continue
            path.rewind()
            for (l in field.lines.indices) {
                val line = field.lines[l]
                if (line.kind != kind) continue
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
                    val visible = max(ax, bx) >= -pad && min(ax, bx) <= width + pad && max(ay, by) >= -pad && min(ay, by) <= height + pad
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
    private fun drawBoundary(canvas: Canvas, field: CloudField, projection: Projection) {
        path.rewind()
        for (r in field.outline.indices) {
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
        canvas.drawPath(path, routePaint)
    }

    /**
     * The colour-coded tiles that show while you drag the map: green where you've
     * walked, orange where you walked this time, white outlines still to walk, and grey
     * where there's no street or path (those clear when you walk beside them).
     */
    private fun drawHoneycomb(canvas: Canvas, field: CloudField, projection: Projection, width: Float, height: Float, opacity: Float) {
        val pad = 60 * density
        for (k in honeycombPaths.indices) {
            honeycombPaths[k].rewind()
            honeycombUsed[k] = false
        }
        for (o in field.outlines.indices) {
            val outline = field.outlines[o]
            if (!projection.isInFront(outline.x, outline.y)) continue
            projection.point(outline.x, outline.y)
            if (projection.x < -pad || projection.x > width + pad || projection.y < -pad || projection.y > height + pad) continue
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

        private val KINDS = arrayOf(RoadLine.Kind.Road, RoadLine.Kind.Path)

        fun rgb(r: Double, g: Double, b: Double, a: Double = 1.0) =
            Color.argb((a * 255).roundToInt(), (r * 255).roundToInt(), (g * 255).roundToInt(), (b * 255).roundToInt())

        /** SwiftUI's red, orange, yellow, green, cyan, blue and purple. */
        private val RAINBOW = intArrayOf(
            rgb(1.0, 0.231, 0.188), rgb(1.0, 0.584, 0.0), rgb(1.0, 0.8, 0.0), rgb(0.204, 0.78, 0.349),
            rgb(0.196, 0.678, 0.902), rgb(0.0, 0.478, 1.0), rgb(0.686, 0.322, 0.871),
        )

        private val green = rgb(0.36, 0.72, 0.4)
        private val grey = rgb(0.35, 0.37, 0.42)
        private val orange = rgb(1.0, 0.47, 0.18)

        // Visited, cleared, open, blocked, this walk.
        private val HONEYCOMB_COLOURS = intArrayOf(green, green, Color.WHITE, grey, orange)
        private val HONEYCOMB_FILL = floatArrayOf(0.3f, 0.12f, 0.06f, 0.35f, 0.35f)
        private val HONEYCOMB_STROKE = floatArrayOf(0.9f, 0.45f, 0.85f, 0.5f, 1f)
    }
}
