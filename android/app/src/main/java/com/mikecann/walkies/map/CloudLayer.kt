package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.util.Log
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import com.mikecann.walkies.BuildConfig
import kotlin.math.max
import kotlin.math.min

/**
 * Tiles that have just cleared: the clouds that were over them fading out as they
 * drift apart, and the holes opening. Only tiles clearing animate, not a whole place
 * being added or removed.
 */
private class Reveal(
    /** The field the tiles cleared in. */
    val field: CloudField,
    val leaving: List<CloudField.Puff>,
    val freshClearings: BooleanArray?,
    val startedAt: Long,
    /** Mist over tiles just walked again, fading under a few sparkles. */
    val leavingMist: List<CloudField.MistPatch> = emptyList(),
)

/**
 * Keeps the clouds on screen cheaply. Drawing every puff through the projection each
 * frame costs old phones 100 ms or more, so instead the clouds are baked on another
 * thread into a picture of what the camera sees (with a margin), and each frame just
 * draws that picture through one perspective matrix: the map moving is a warp of the
 * last bake, measured from the same four spots as the projection. Once the camera's
 * moved far enough that the warp would show (off the edge, zoomed, tilted or turned
 * past a little), it's baked again, roughly while moving and sharp once the map
 * stops, fading from one to the next. Still, the clouds' drift is baked again every
 * few seconds and faded in, rather than redrawn 30 times a second.
 *
 * While the map moves it's left alone as long as it can be: a rough bake is only
 * asked for once the screen's half way into the margin (or zoomed or turned well
 * past), with the drift held where it was so it swaps in with no fade. The sharp
 * one waits until the map's been still for a moment.
 *
 * Live each frame: the route, this walk's tiles, the spyglass's ring and where you
 * are, all a few paths; and for the second and a half that tiles take to clear, the
 * clouds round them, through the same warp so they line up with the bake exactly.
 */
private class CloudScene(private val density: Float) {
    val painter = CloudPainter(density)
    val baker = CloudBaker(density)
    val projection = Projection()
    private val ground = DoubleArray(10)
    private val warp = BakeWarp()
    private val matrix = Matrix()
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val plain = Paint(Paint.FILTER_BITMAP_FLAG)
    private val add = PorterDuffXfermode(PorterDuff.Mode.ADD)
    private var lastJob: BakeJob? = null

    /** The bake on screen, the one it's fading in over, and since when. */
    private var front: CloudBake? = null
    private var fading: CloudBake? = null
    private var fadeStart = 0L
    private var fadeTime = 0.0
    /** The newest honeycomb baked, and where from. Kept apart from its bake so that can go. */
    private var honeycomb: Bitmap? = null
    private var honeycombFrame: BakeFrame? = null
    private val honeycombRect = RectF()
    private var reveal: Reveal? = null

    private var lastTick = -1L
    private var movedAt = 0L
    private val stats = if (BuildConfig.DEBUG) FrameStats() else null

    fun draw(
        canvas: Canvas, width: Float, height: Float, state: MapState, tick: Long, dragging: Boolean, honeycombOpacity: Float,
        field: CloudField, sprites: CloudSprites, clock: Double, route: DoubleArray, fresh: List<DoubleArray>, you: YouAreHere, cosmetics: MapCosmetics,
    ) {
        val started = System.nanoTime()
        drawFrame(canvas, width, height, state, tick, dragging, honeycombOpacity, field, sprites, clock, route, fresh, you, cosmetics)
        stats?.frame(started, System.nanoTime())
    }

    private fun drawFrame(
        canvas: Canvas, width: Float, height: Float, state: MapState, tick: Long, dragging: Boolean, honeycombOpacity: Float,
        field: CloudField, sprites: CloudSprites, clock: Double, route: DoubleArray, fresh: List<DoubleArray>, you: YouAreHere, cosmetics: MapCosmetics,
    ) {
        if (!state.measure(width, height, ground)) return
        projection.update(ground, width, height, ground[8], ground[9])
        if (!projection.valid) return
        val now = System.nanoTime()
        if (tick != lastTick) {
            lastTick = tick
            movedAt = now
        }
        val moving = dragging || now - movedAt < SETTLE
        baker.take()?.let { accept(it, now) }
        ask(width, height, field, sprites, clock, moving, dragging)

        val front = front
        // Nothing baked yet, a place added or removed or a new look not baked yet, or the
        // camera's swung so far the bake is partly behind it: draw it all live rather
        // than show the map bare for a moment.
        if (front == null || front.field.places != field.places || front.sprites !== sprites || !warp.update(projection, front.frame)) {
            stats?.let { it.live++ }
            painter.draw(canvas, field, emptyList(), null, 1.0, projection, sprites, width, height, clock, honeycombOpacity, route, fresh, you, cosmetics)
            return
        }

        painter.drawUnder(canvas, projection, width, height, clock, route, fresh, cosmetics)
        val reveal = reveal
        val progress = if (reveal == null) 1.0 else min(1.0, (now - reveal.startedAt) / 1e9 / REVEAL_TIME)
        if (progress >= 1) this.reveal = null
        if (progress < 1) stats?.let { it.reveals++ }

        val old = fading
        val t = if (old == null || fadeTime <= 0) 1.0 else (now - fadeStart) / 1e9 / fadeTime
        if (old != null && t < 1) {
            // A crossfade: the sum of both, weighted, so it never shows more of either than
            // one full bake (layered one over the other, the shadows would darken).
            stats?.let { it.fades++ }
            val layer = canvas.saveLayer(0f, 0f, width, height, null)
            drawBake(canvas, old, 1 - t, false, progress)
            drawBake(canvas, front, t, true, progress)
            canvas.restoreToCount(layer)
        } else {
            if (old != null) {
                fading = null
                old.recycle(withHoneycomb = false)
            }
            drawBake(canvas, front, 1.0, false, progress)
        }

        // Only while it shows: it's a whole screen of texture to draw.
        val honey = honeycomb
        val honeyFrame = honeycombFrame
        val honeyAlpha = (honeycombOpacity * 255).toInt().coerceIn(0, 255)
        if (honeyAlpha > 0 && honey != null && honeyFrame != null && warp.update(projection, honeyFrame)) {
            stats?.let { it.honeycombs++ }
            matrix.setValues(warp.values)
            paint.alpha = honeyAlpha
            paint.xfermode = null
            canvas.save()
            canvas.concat(matrix)
            canvas.drawBitmap(honey, null, honeycombRect, paint)
            canvas.restore()
        }
        painter.drawOver(canvas, projection, clock, you, cosmetics)
    }

    /** One bake through the warp, at [alpha], added onto what's there if [plus]; with tiles clearing over it while they do. */
    private fun drawBake(canvas: Canvas, bake: CloudBake, alpha: Double, plus: Boolean, progress: Double) {
        // Partly behind the camera: it's being baked again, so skip it for now.
        if (!warp.update(projection, bake.frame)) return
        matrix.setValues(warp.values)
        paint.alpha = (alpha * 255).toInt().coerceIn(0, 255)
        paint.xfermode = if (plus) add else null
        canvas.save()
        canvas.concat(matrix)
        val reveal = reveal
        if (progress >= 1 || reveal == null || reveal.field !== bake.field || !patch(bake, reveal)) {
            canvas.drawBitmap(bake.clouds, null, bake.rect, paint)
            canvas.restore()
            return
        }
        // Tiles clearing: the bake everywhere but round them, and there the clouds
        // drawn live as they part, in the bake's own pixels, drift and camera so the
        // two meet without a seam.
        val layer = if (paint.alpha < 255 || plus) canvas.saveLayer(bake.rect, paint) else -1
        canvas.save()
        canvas.clipOutRect(bake.patch)
        canvas.drawBitmap(bake.clouds, null, bake.rect, if (layer >= 0) plain else paint)
        canvas.restore()
        canvas.save()
        canvas.clipRect(bake.patch)
        painter.drawClouds(
            canvas, bake.field, reveal.leaving, reveal.freshClearings, progress, bake.frame.projection, bake.sprites,
            bake.rect, bake.clock, bake.patch, bake.patchNear, reveal.leavingMist,
        )
        canvas.restore()
        if (layer >= 0) canvas.restoreToCount(layer)
        canvas.restore()
    }

    /** Works out [bake]'s patch round the tiles clearing, once per reveal. False if they're nowhere on it. */
    private fun patch(bake: CloudBake, reveal: Reveal): Boolean {
        if (bake.patchFor !== reveal) {
            bake.patchFor = reveal
            val any = painter.revealBounds(bake.field, reveal.leaving, reveal.freshClearings, bake.frame.projection, bake.patch, reveal.leavingMist) &&
                bake.patch.intersect(bake.rect)
            if (!any) bake.patch.setEmpty()
            // The ground under the patch, to skip everything nowhere near it.
            val p = bake.frame.projection
            val near = doubleArrayOf(Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY)
            var under = true
            for (i in 0 until 4) {
                val u = if (i == 0 || i == 3) bake.patch.left else bake.patch.right
                val v = if (i < 2) bake.patch.top else bake.patch.bottom
                // Past the horizon: no box, so nothing's skipped.
                if (!p.unproject(u.toDouble(), v.toDouble())) under = false
                near[0] = min(near[0], p.groundX); near[1] = min(near[1], p.groundY)
                near[2] = max(near[2], p.groundX); near[3] = max(near[3], p.groundY)
            }
            bake.patchNear = if (under) near else null
        }
        return !bake.patch.isEmpty
    }

    private fun accept(bake: CloudBake, now: Long) {
        stats?.let { it.bakes++ }
        if (bake.honeycomb != null) {
            // The scene owns the honeycomb from here; the bake only ever frees its clouds.
            honeycomb?.let { if (it !== bake.honeycomb) it.recycle() }
            honeycomb = bake.honeycomb
            honeycombFrame = bake.frame
            honeycombRect.set(bake.rect)
        }
        val shown = front
        // Tiles clearing since what's on screen: open them up.
        if (shown != null && bake.previous === shown.field && bake.field !== shown.field && bake.freshClearings != null) {
            reveal = Reveal(bake.field, bake.leaving, bake.freshClearings, now, bake.leavingMist)
        } else if (shown == null || shown.field.places != bake.field.places) {
            reveal = null
        }
        fadeTime = when {
            shown == null || shown.sprites !== bake.sprites || shown.field.places != bake.field.places -> 0.0
            // Same drift, just tiles changing or a rough bake from a moving camera: the same
            // picture, so nothing to fade (and no layer for it to cost mid-pan).
            bake.clock == shown.clock -> 0.0
            bake.frame === shown.frame -> DRIFT_FADE
            else -> CAMERA_FADE
        }
        // Whatever's no longer drawn, freed now: a crossfade cut short, or the one replaced.
        val wasFading = fading
        fading = if (fadeTime > 0) shown else null
        if (wasFading != null && wasFading !== fading) wasFading.recycle(withHoneycomb = false)
        if (shown != null && shown !== fading) shown.recycle(withHoneycomb = false)
        fadeStart = now
        front = bake
    }

    /** Asks for a new bake if the one on screen needs it, one at a time. */
    private fun ask(width: Float, height: Float, field: CloudField, sprites: CloudSprites, clock: Double, moving: Boolean, dragging: Boolean) {
        if (!baker.idle) return
        val shown = front
        // Just taken, the newest bake's on screen: check against that.
        val usable = shown != null && warp.update(projection, shown.frame)
        val fits = usable && warp.fits(shown!!.frame, width, height, moving)
        val job = when {
            shown == null || shown.field !== field || shown.sprites !== sprites -> {
                // New tiles or a new look. From the same camera and drift as what's on
                // screen if that still fits, so the new bake drops straight in; mid-pan,
                // the same drift at least.
                val frame = if (fits) shown!!.frame else newFrame(width, height, moving)
                val sameDrift = shown != null && (fits || moving)
                BakeJob(frame, field, sprites, if (sameDrift) shown!!.clock else clock, honeycomb = true, previous = shown?.field)
            }
            // Moving: only once the picture's about to run out, roughly, with the drift held.
            moving -> if (fits || sameAsRequested(width, height)) null else
                BakeJob(newFrame(width, height, true), field, sprites, shown.clock, honeycomb = dragging, previous = field)
            // Stopped: sharpen a rough bake, or one from a camera a little off.
            !fits || shown.frame.draft || !warp.exact(width, height) || honeycombFrame !== shown.frame ->
                if (sameAsRequested(width, height) && lastJob?.let { !it.frame.draft && it.honeycomb } == true) null else
                    BakeJob(newFrame(width, height, false), field, sprites, clock, honeycomb = true, previous = field)
            // The clouds drifting on.
            clock - shown.clock >= DRIFT_PERIOD -> BakeJob(shown.frame, field, sprites, clock, honeycomb = false, previous = field)
            else -> null
        } ?: return
        lastJob = job
        baker.request(job)
    }

    private fun newFrame(width: Float, height: Float, draft: Boolean) = BakeFrame.around(projection, width, height, draft)

    /** Whether the camera's where it was for the last bake asked for, so asking again would get the same. */
    private fun sameAsRequested(width: Float, height: Float): Boolean {
        val job = lastJob ?: return false
        return sameWarp.update(projection, job.frame) && sameWarp.exact(width, height)
    }
    private val sameWarp = BakeWarp()

    fun close() {
        baker.close()
        front?.recycle(withHoneycomb = false)
        fading?.recycle(withHoneycomb = false)
        honeycomb?.recycle()
        front = null
        fading = null
        honeycomb = null
    }

    companion object {
        /** The camera's still once it hasn't moved for this long. */
        const val SETTLE = 250_000_000L
        /** How often the clouds' drift is baked again while the map's still, in seconds. */
        const val DRIFT_PERIOD = 2.5
        const val DRIFT_FADE = 1.0
        const val CAMERA_FADE = 0.2
    }
}

/**
 * The clouds, on top of the map, following it by asking it where the ground is on
 * screen each frame, and redrawn about 30 times a second so where you are can pulse
 * and the clouds drift. CloudLayer in Clouds.swift; see [CloudScene] for how it
 * keeps that cheap.
 */
@Composable
fun CloudLayer(
    field: CloudField,
    state: MapState,
    sprites: CloudSprites?,
    /** The walk's route, interleaved x, y map points. */
    route: DoubleArray,
    /** Tiles uncovered this walk, six corners each as interleaved x, y map points. */
    fresh: List<DoubleArray>,
    you: YouAreHere,
    modifier: Modifier = Modifier,
    /** What's equipped from the shop: the trail, the marker and the spyglass's ring. */
    cosmetics: MapCosmetics = MapCosmetics.none,
) {
    val density = LocalDensity.current.density
    val scene = remember(density) { CloudScene(density) }
    DisposableEffect(scene) { onDispose { scene.close() } }

    // 30 frames a second while the map's still, for the drift and the pulse. Camera changes redraw on top.
    var clock by remember { mutableDoubleStateOf(0.0) }
    LaunchedEffect(Unit) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                if (now - last >= 33_000_000L) {
                    last = now
                    clock = now / 1e9
                }
            }
        }
    }

    Spacer(
        modifier.fillMaxSize().drawBehind {
            val tick = state.cameraTick.longValue
            val now = clock
            if (state.controller == null || sprites == null) return@drawBehind
            drawIntoCanvas { canvas ->
                scene.draw(
                    canvas.nativeCanvas, size.width, size.height, state, tick, state.dragging, state.honeycomb(System.nanoTime()),
                    field, sprites, now, route, fresh, you, cosmetics,
                )
            }
        },
    )
}

const val REVEAL_TIME = 1.6

/**
 * Debug builds: how long the cloud layer takes to record each frame on the main
 * thread, logged every 60 frames (`adb logcat -s CloudLayer CloudBaker`), with what
 * it drew. The GPU's side of it isn't counted: `adb shell dumpsys gfxinfo` has that.
 */
private class FrameStats {
    private var frames = 0
    private var total = 0L
    private var worst = 0L
    private var since = 0L
    var live = 0
    var fades = 0
    var honeycombs = 0
    var reveals = 0
    var bakes = 0

    fun frame(started: Long, finished: Long) {
        if (frames == 0) since = started
        val took = finished - started
        frames++
        total += took
        worst = max(worst, took)
        if (frames < 60) return
        val seconds = (finished - since) / 1e9
        Log.d(
            "CloudLayer",
            "%d frames in %.1f s (%.0f fps): draw %.1f ms avg, %.1f ms worst; live %d, crossfading %d, honeycomb %d, tiles clearing %d; bakes taken %d".format(
                frames, seconds, frames / seconds, total / frames / 1e6, worst / 1e6, live, fades, honeycombs, reveals, bakes,
            ),
        )
        frames = 0; total = 0; worst = 0; live = 0; fades = 0; honeycombs = 0; reveals = 0; bakes = 0
    }
}
