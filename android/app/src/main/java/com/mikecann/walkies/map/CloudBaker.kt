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
    /** Someone's waiting to see this one, the map having just stopped: not behind everything else. */
    val urgent: Boolean = false,
    /**
     * The bake to take the lines from, when they'd come out the same: the clouds drift
     * but the streets don't, so a drift bake only has the clouds to do.
     */
    val linesFrom: CloudBake? = null,
)

/** A honeycomb, for [frame]. Comes after its bake, as the clouds shouldn't wait for it. */
class BakedHoneycomb(val frame: BakeFrame, val rect: RectF, val bitmap: Bitmap)

/**
 * A finished bake: pictures of [BakeJob]'s soft clouds and of the crisp lines over
 * them, each covering the frame's box of its camera's screen. Read on the main thread
 * only once handed over.
 */
class CloudBake(
    val frame: BakeFrame,
    val field: CloudField,
    val sprites: CloudSprites,
    val clock: Double,
    val clouds: Bitmap,
    /** The streets, grid and outline, cut by the same holes. */
    val lines: Bitmap,
    /** Whether [lines] is this bake's to free, rather than still the bake's it came from. */
    var ownsLines: Boolean,
    val previous: CloudField?,
    /** The clouds in [previous] that aren't in [field], and which clearings are new, if it's tiles clearing. */
    val leaving: List<CloudField.Puff>,
    val freshClearings: BooleanArray?,
    /** Mist in [previous] that's gone from [field]: tiles walked again, to sparkle. */
    val leavingMist: List<CloudField.MistPatch> = emptyList(),
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
     * (they're a few MB each). On the main thread, once nothing will draw them again:
     * frames already recorded keep their own hold on them, so that's safe.
     */
    fun recycle() {
        clouds.recycle()
        if (ownsLines) lines.recycle()
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
    private val doneHoneycomb = AtomicReference<BakedHoneycomb?>()

    // Drawn into, then copied to the GPU. Kept between bakes, and resized in place
    // when they're smaller, so baking doesn't allocate 10 MB each time.
    private val scratches = arrayOfNulls<Bitmap>(3)
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

    /** The newest honeycomb finished, once. Yours to recycle. */
    fun takeHoneycomb(): BakedHoneycomb? = doneHoneycomb.getAndSet(null)

    fun close() {
        synchronized(lock) {
            closed = true
            waiting = null
            lock.notifyAll()
        }
        done.getAndSet(null)?.recycle()
        doneHoneycomb.getAndSet(null)?.bitmap?.recycle()
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
                // The sharp one you're waiting for once it stops needn't be, nor the drift
                // hurry, which nobody's waiting for and goes on as long as the map's open.
                Process.setThreadPriority(
                    when {
                        job.frame.draft -> Process.THREAD_PRIORITY_LOWEST
                        job.urgent -> Process.THREAD_PRIORITY_DEFAULT
                        else -> Process.THREAD_PRIORITY_BACKGROUND
                    },
                )
                val bake = bake(job)
                // One the main thread never took: free it now.
                done.getAndSet(bake)?.recycle()
                // After handing the clouds over: it only shows while you drag.
                if (job.honeycomb) {
                    val honeycomb = honeycomb(job)
                    doneHoneycomb.getAndSet(honeycomb)?.bitmap?.recycle()
                }
                if (synchronized(lock) { closed }) {
                    done.getAndSet(null)?.recycle()
                    doneHoneycomb.getAndSet(null)?.bitmap?.recycle()
                }
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
        var leavingMist = emptyList<CloudField.MistPatch>()
        val old = job.previous
        if (old != null && old !== job.field && old.places == job.field.places) {
            val still = job.field.puffs.mapTo(HashSet()) { it.tile }
            leaving = old.puffs.filter { it.tile !in still }
            val gone = leaving.mapTo(HashSet()) { it.tile }
            freshClearings = BooleanArray(job.field.clearings.size) { job.field.clearings[it].tile in gone }
            leavingMist = CloudField.clearedMist(old, job.field)
        }

        val clouds = render(frame.cloudPixelWidth, frame.cloudPixelHeight, frame, scratch = 0) { c ->
            painter.drawClouds(c, job.field, emptyList(), null, 1.0, projection, job.sprites, bounds, job.clock, part = CloudPainter.Part.Clouds)
        }
        val drewClouds = System.nanoTime()
        val kept = job.linesFrom?.lines
        val lines = kept ?: render(frame.pixelWidth, frame.pixelHeight, frame, scratch = 1) { c ->
            painter.drawClouds(c, job.field, emptyList(), null, 1.0, projection, job.sprites, bounds, job.clock, part = CloudPainter.Part.Lines)
        }
        val finished = System.nanoTime()
        Log.d(
            TAG,
            "Baked ${frame.cloudPixelWidth}x${frame.cloudPixelHeight}${if (frame.draft) " draft" else ""}: clouds " +
                "${(drewClouds - started) / 1_000_000} ms" +
                (if (kept == null) ", lines ${frame.pixelWidth}x${frame.pixelHeight} ${(finished - drewClouds) / 1_000_000} ms" else ""),
        )
        return CloudBake(frame, job.field, job.sprites, job.clock, clouds, lines, kept == null, old, leaving, freshClearings, leavingMist)
    }

    private fun honeycomb(job: BakeJob): BakedHoneycomb {
        val started = System.nanoTime()
        val frame = job.frame
        val bounds = RectF(frame.left, frame.top, frame.right, frame.bottom)
        val bitmap = render(frame.pixelWidth, frame.pixelHeight, frame, scratch = 2) { c ->
            painter.drawHoneycomb(c, job.field, projection, bounds, 1f)
        }
        Log.d(TAG, "Honeycomb ${frame.pixelWidth}x${frame.pixelHeight}: ${(System.nanoTime() - started) / 1_000_000} ms")
        return BakedHoneycomb(frame, bounds, bitmap)
    }

    /**
     * Draws into a [width] x [height] scratch bitmap, scaled so [frame]'s box fills
     * it, then copies that to an immutable hardware bitmap: uploaded to the GPU once,
     * here, and drawn as a texture every frame after, never uploaded again. The
     * scratch is drawn over again next time.
     */
    private inline fun render(width: Int, height: Int, frame: BakeFrame, scratch: Int, draw: (Canvas) -> Unit): Bitmap {
        var bitmap = scratches[scratch]
        if (bitmap != null && (bitmap.width != width || bitmap.height != height)) {
            if (bitmap.allocationByteCount >= width * height * 4) {
                bitmap.reconfigure(width, height, Bitmap.Config.ARGB_8888)
            } else {
                bitmap.recycle()
                bitmap = null
                scratches[scratch] = null
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
            scratches[scratch] = bitmap
            return copy
        }
        // No hardware bitmaps here: hand this one over as it is (never to be drawn into
        // again, as the screen's using it), and start the upload now.
        hardware = false
        scratches[scratch] = null
        bitmap.prepareToDraw()
        return bitmap
    }

    companion object {
        private const val TAG = "CloudBaker"
    }
}
