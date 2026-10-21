package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.RectF
import android.os.Process
import android.util.Log

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
    @Volatile private var done: CloudBake? = null

    // Drawn into, then copied to the GPU. Kept between bakes of the same size.
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

    /** The newest finished bake, once. */
    fun take(): CloudBake? {
        val bake = done ?: return null
        done = null
        return bake
    }

    fun close() {
        synchronized(lock) {
            closed = true
            waiting = null
            lock.notifyAll()
        }
    }

    private fun run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_DEFAULT + Process.THREAD_PRIORITY_LESS_FAVORABLE)
        while (true) {
            val job = synchronized(lock) {
                while (waiting == null && !closed) lock.wait()
                if (closed) return
                working = true
                waiting.also { waiting = null }
            } ?: continue
            try {
                done = bake(job)
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
     * it, then copies that to the GPU so the main thread doesn't have to upload it
     * mid-frame and the scratch can be drawn over again next time.
     */
    private inline fun render(width: Int, height: Int, frame: BakeFrame, scratch: Int, draw: (Canvas) -> Unit): Bitmap {
        var bitmap = if (scratch == 0) cloudScratch else honeycombScratch
        if (bitmap == null || bitmap.width != width || bitmap.height != height) {
            bitmap = null
            if (scratch == 0) cloudScratch = null else honeycombScratch = null
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
        bitmap.prepareToDraw()
        return bitmap
    }

    companion object {
        private const val TAG = "CloudBaker"

        /** The honeycomb's only lines and flat fills, faint and moving, so it bakes a bit softer. */
        const val HONEYCOMB_SCALE = 0.75f
    }
}
