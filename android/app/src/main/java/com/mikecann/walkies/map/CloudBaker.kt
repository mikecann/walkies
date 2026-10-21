package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.RectF
import android.os.Process
import android.util.Log
import java.util.concurrent.atomic.AtomicReference

/** What to bake: the clouds as [field] looks from [frame]'s camera, drifted to [clock]. */
class BakeJob(
    val frame: BakeFrame,
    val field: CloudField,
    val sprites: CloudSprites,
    val clock: Double,
    /** Also bake the honeycomb, for while you drag. */
    val honeycomb: Boolean,
    /** The field on screen when this was asked for, to work out which clouds clear. */
    val previous: CloudField?,
)

/**
 * A finished bake: pictures of [BakeJob]'s clouds and honeycomb, each covering the
 * frame's box of its camera's screen. Read on the main thread only once handed over.
 */
class CloudBake(
    val frame: BakeFrame,
    val field: CloudField,
    val sprites: CloudSprites,
    val clock: Double,
    val clouds: Bitmap,
    val honeycomb: Bitmap?,
    val previous: CloudField?,
    /** The clouds in [previous] that aren't in [field], and which clearings are new, if it's tiles clearing. */
    val leaving: List<CloudField.Puff>,
    val freshClearings: BooleanArray?,
) {
    /** The frame's box, for drawing the pictures into. */
    val rect = RectF(frame.left, frame.top, frame.right, frame.bottom)

    // The box round tiles clearing that's drawn live over this bake while they open,
    // in its own screen pixels and as map points. Worked out once per reveal.
    var patchFor: Any? = null
    val patch = RectF()
    var patchNear: DoubleArray? = null

    /**
     * Frees the pictures' GPU memory now rather than whenever the GC gets round to it
     * (they're 5 to 10 MB each). On the main thread, once nothing will draw them
     * again: frames already recorded keep their own hold on them, so that's safe.
     */
    fun recycle(withHoneycomb: Boolean) {
        clouds.recycle()
        if (withHoneycomb) honeycomb?.recycle()
    }
}

/**
 * Bakes the clouds on a thread of its own, so the main thread only ever draws a
 * finished picture or two. One job at a time; asking again while it's busy
 * replaces whatever was waiting, and the newest result replaces any not yet taken.
 */
class CloudBaker(density: Float) {
    private val painter = CloudPainter(density)
    private val lock = Object()
    private var waiting: BakeJob? = null
    private var working = false
    private var closed = false
    private val done = AtomicReference<CloudBake?>()

    // Drawn into, then copied to the GPU. Kept between bakes, and resized in place
    // when they're smaller, so baking doesn't allocate 10 MB each time.
    private var cloudScratch: Bitmap? = null
    private var honeycombScratch: Bitmap? = null
    private val canvas = Canvas()
    /**
     * The bake's camera, copied: projecting writes its results into the projection,
     * and the main thread may be using the frame's own at the same time.
     */
    private val projection = Projection()
    private var hardware = true

    private val thread = Thread({ run() }, "CloudBaker").apply {
        isDaemon = true
        start()
    }

    /** Nothing baking or waiting to. */
    val idle: Boolean get() = synchronized(lock) { waiting == null && !working }

    fun request(job: BakeJob) {
        synchronized(lock) {
            waiting = job
            lock.notifyAll()
        }
    }

    /** The newest finished bake, once. Yours to recycle. */
    fun take(): CloudBake? = done.getAndSet(null)

    fun close() {
        synchronized(lock) {
            closed = true
            waiting = null
            lock.notifyAll()
        }
        done.getAndSet(null)?.recycle(withHoneycomb = true)
    }

    private fun run() {
        while (true) {
            val job = synchronized(lock) {
                while (waiting == null && !closed) lock.wait()
                if (closed) return
                working = true
                waiting.also { waiting = null }
            } ?: continue
            try {
                // Well behind the main thread and the map's renderer for the big cores,
                // and a rough bake mid-pan further still: it's only there to keep up.
                Process.setThreadPriority(if (job.frame.draft) Process.THREAD_PRIORITY_LOWEST else Process.THREAD_PRIORITY_BACKGROUND)
                val bake = bake(job)
                // One the main thread never took: free it now.
                done.getAndSet(bake)?.recycle(withHoneycomb = true)
                if (synchronized(lock) { closed }) done.getAndSet(null)?.recycle(withHoneycomb = true)
            } catch (e: Throwable) {
                // Out of memory on a small phone, say: skip it, the next one may fit.
                Log.w(TAG, "Couldn't bake the clouds", e)
            } finally {
                synchronized(lock) { working = false }
            }
        }
    }

    private fun bake(job: BakeJob): CloudBake {
        val started = System.nanoTime()
        val frame = job.frame
        val bounds = RectF(frame.left, frame.top, frame.right, frame.bottom)
        projection.copyFrom(frame.projection)

        var leaving = emptyList<CloudField.Puff>()
        var freshClearings: BooleanArray? = null
        val old = job.previous
        if (old != null && old !== job.field && old.places == job.field.places) {
            val still = job.field.puffs.mapTo(HashSet()) { it.tile }
            leaving = old.puffs.filter { it.tile !in still }
            val gone = leaving.mapTo(HashSet()) { it.tile }
            freshClearings = BooleanArray(job.field.clearings.size) { job.field.clearings[it].tile in gone }
        }

        val clouds = render(frame.pixelWidth, frame.pixelHeight, frame, scratch = 0) { c ->
            painter.drawClouds(c, job.field, emptyList(), null, 1.0, projection, job.sprites, bounds, job.clock)
        }
        val drewClouds = System.nanoTime()
        val honeycomb = if (!job.honeycomb) null else {
            val w = (frame.pixelWidth * HONEYCOMB_SCALE).toInt().coerceAtLeast(1)
            val h = (frame.pixelHeight * HONEYCOMB_SCALE).toInt().coerceAtLeast(1)
            render(w, h, frame, scratch = 1) { c ->
                painter.drawHoneycomb(c, job.field, projection, bounds, 1f)
            }
        }
        val finished = System.nanoTime()
        Log.d(
            TAG,
            "Baked ${frame.pixelWidth}x${frame.pixelHeight}${if (frame.draft) " draft" else ""}: clouds " +
                "${(drewClouds - started) / 1_000_000} ms" +
                (if (honeycomb != null) ", honeycomb ${(finished - drewClouds) / 1_000_000} ms" else ""),
        )
        return CloudBake(frame, job.field, job.sprites, job.clock, clouds, honeycomb, old, leaving, freshClearings)
    }

    /**
     * Draws into a [width] x [height] scratch bitmap, scaled so [frame]'s box fills
     * it, then copies that to an immutable hardware bitmap: uploaded to the GPU once,
     * here, and drawn as a texture every frame after, never uploaded again. The
     * scratch is drawn over again next time.
     */
    private inline fun render(width: Int, height: Int, frame: BakeFrame, scratch: Int, draw: (Canvas) -> Unit): Bitmap {
        var bitmap = if (scratch == 0) cloudScratch else honeycombScratch
        if (bitmap != null && (bitmap.width != width || bitmap.height != height)) {
            if (bitmap.allocationByteCount >= width * height * 4) {
                bitmap.reconfigure(width, height, Bitmap.Config.ARGB_8888)
            } else {
                bitmap.recycle()
                bitmap = null
                if (scratch == 0) cloudScratch = null else honeycombScratch = null
            }
        }
        if (bitmap == null) {
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        } else {
            bitmap.eraseColor(0)
        }
        canvas.setBitmap(bitmap)
        canvas.save()
        canvas.scale(width / (frame.right - frame.left), height / (frame.bottom - frame.top))
        canvas.translate(-frame.left, -frame.top)
        draw(canvas)
        canvas.restore()
        canvas.setBitmap(null)

        val copy = if (hardware) bitmap.copy(Bitmap.Config.HARDWARE, false) else null
        if (copy != null) {
            if (scratch == 0) cloudScratch = bitmap else honeycombScratch = bitmap
            return copy
        }
        // No hardware bitmaps here: hand this one over as it is (never to be drawn into
        // again, as the screen's using it), and start the upload now.
        hardware = false
        if (scratch == 0) cloudScratch = null else honeycombScratch = null
        bitmap.prepareToDraw()
        return bitmap
    }

    companion object {
        private const val TAG = "CloudBaker"

        /** The honeycomb's only lines and flat fills, faint and moving, so it bakes a bit softer. */
        const val HONEYCOMB_SCALE = 0.75f
    }
}
