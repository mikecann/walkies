package com.mikecann.walkies.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import com.mapbox.bindgen.DataRef
import com.mapbox.maps.CanonicalTileID
import com.mapbox.maps.CustomRasterSourceClient
import com.mapbox.maps.CustomRasterSourceOptions
import com.mapbox.maps.CustomRasterSourceTileData
import com.mapbox.maps.CustomRasterSourceTileStatus
import com.mapbox.maps.CustomRasterSourceTileStatusChangedCallback
import com.mapbox.maps.Image
import com.mapbox.maps.MapboxExperimental
import com.mapbox.maps.Style
import com.mapbox.maps.extension.style.layers.addLayer
import com.mapbox.maps.extension.style.layers.generated.rasterLayer
import com.mapbox.maps.extension.style.layers.properties.generated.RasterResampling
import com.mapbox.maps.extension.style.sources.CustomRasterSource
import com.mapbox.maps.extension.style.sources.addSource
import com.mikecann.walkies.grid.Hex

/**
 * Paints one of the blanket's tiles: every puff of the tile's level that reaches into
 * it, undersides then tops as a place's clouds are (so the middle is one white and the
 * grey only shows round the edges), then your places cut out and soft holes over the
 * hexes you've walked, with the place clearings' own eraser and size.
 */
class BlanketTilePainter {
    private val bitmap = Bitmap.createBitmap(CloudBlanket.TILE_PIXELS, CloudBlanket.TILE_PIXELS, Bitmap.Config.ARGB_8888)
    private val canvas = Canvas(bitmap)
    private val sprite = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val eraser = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
    }
    private val cut = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
    }
    private val path = Path().apply { fillType = Path.FillType.EVEN_ODD }
    private val rect = RectF()

    /** The tile as Mapbox wants it: premultiplied RGBA, which is how an ARGB_8888 bitmap keeps its pixels. */
    fun paint(z: Int, x: Int, y: Int, sprites: CloudSprites, places: BlanketPlaces, walked: WalkedIndex): Image {
        val box = CloudBlanket.tileBox(z, x, y)
        val x0 = box[0]
        val y0 = box[1]
        val scale = CloudBlanket.TILE_PIXELS / (box[2] - box[0])
        bitmap.eraseColor(0)

        val puffs = CloudBlanket.puffs(CloudBlanket.level(z), box[0], box[1], box[2], box[3])
        for (layer in 0 until 2) {
            val art = if (layer == 0) sprites.bases else sprites.tops
            for (puff in puffs) {
                rect.set(
                    ((puff.x - puff.radius - x0) * scale).toFloat(), ((puff.y - puff.radius - y0) * scale).toFloat(),
                    ((puff.x + puff.radius - x0) * scale).toFloat(), ((puff.y + puff.radius - y0) * scale).toFloat(),
                )
                canvas.drawBitmap(art[puff.variant], null, rect, sprite)
            }
        }

        // Your places, which have clouds of their own. Each on its own, so where two
        // overlap they're still both cut out rather than cancelling.
        for (place in places.places) {
            val b = place.box
            if (b[2] < box[0] || b[0] > box[2] || b[3] < box[1] || b[1] > box[3]) continue
            path.rewind()
            for (ring in place.rings) addRing(ring, x0, y0, scale)
            canvas.drawPath(path, cut)
        }

        // Too small to see further out, and there could be thousands of them.
        val radius = CloudBlanket.clearingRadius
        if (radius * scale >= MIN_HOLE) {
            walked.forEach(box[0] - radius, box[1] - radius, box[2] + radius, box[3] + radius) { cx, cy ->
                rect.set(
                    ((cx - radius - x0) * scale).toFloat(), ((cy - radius - y0) * scale).toFloat(),
                    ((cx + radius - x0) * scale).toFloat(), ((cy + radius - y0) * scale).toFloat(),
                )
                canvas.drawBitmap(sprites.eraser, null, rect, eraser)
            }
        }

        val data = DataRef.allocateNative(bitmap.byteCount)
        data.buffer.rewind()
        bitmap.copyPixelsToBuffer(data.buffer)
        return Image(bitmap.width, bitmap.height, data)
    }

    /** One ring into [path] in tile pixels, leaving out points less than half a pixel on from the last, which zoomed out is most of them. */
    private fun addRing(ring: DoubleArray, x0: Double, y0: Double, scale: Double) {
        var lastX = 0f
        var lastY = 0f
        var i = 0
        while (i < ring.size) {
            val px = ((ring[i] - x0) * scale).toFloat()
            val py = ((ring[i + 1] - y0) * scale).toFloat()
            if (i == 0) {
                path.moveTo(px, py)
                lastX = px; lastY = py
            } else if (i == ring.size - 2 || kotlin.math.abs(px - lastX) + kotlin.math.abs(py - lastY) >= 0.5f) {
                path.lineTo(px, py)
                lastX = px; lastY = py
            }
            i += 2
        }
        path.close()
    }

    companion object {
        /** Holes smaller than this many pixels across the tile aren't worth drawing. */
        const val MIN_HOLE = 0.75
    }
}

/**
 * Puts the blanket on the Mapbox map as a raster layer on top of the satellite and its
 * labels (as the place clouds cover them), from a custom source whose tiles are painted
 * here. Mapbox says which tiles it wants as the camera moves; each is painted once on a
 * background thread and handed over, and Mapbox keeps it, warps it with the map and
 * draws it on the globe when zoomed out, so nothing's drawn per frame on our side.
 * A tile's only painted again when what's in it changes: all of them when a place is
 * added or removed or the cloud look changes, and just the ones round them when you
 * walk new hexes.
 *
 * Inputs come in on the main thread ([setPlaces], [setWalked], [setSprites]); Mapbox's
 * calls are made there too.
 */
@OptIn(MapboxExperimental::class)
class CloudBlanketSource {
    private val main = Handler(Looper.getMainLooper())
    /** The style the source is on, set and cleared on the main thread. */
    private var style: Style? = null

    /** What the tiles are painted from, replaced whole so the painter always sees one consistent lot. */
    private class Inputs(val places: BlanketPlaces, val walked: WalkedIndex, val sprites: CloudSprites?)

    // Everything below is shared with the painting thread, under the lock.
    private val lock = Object()
    private var inputs = Inputs(BlanketPlaces.none, WalkedIndex(emptySet()), null)
    /** The tiles Mapbox wants by key, true for the ones it needs now rather than might. */
    private val wanted = HashMap<Long, Boolean>()
    /** Tiles waiting to be painted, oldest ask first. */
    private val waiting = LinkedHashSet<Long>()
    /** The hexes walked, waiting for the painting thread to take them in. */
    private var pendingWalked: Set<Hex>? = null
    private var closed = true
    /** Bumped for each painting thread started, so one left over from before stops. */
    private var generation = 0

    /** Adds the source and its layer to the map's style, once it's loaded. On the main thread. */
    fun attach(style: Style) {
        if (style.styleSourceExists(SOURCE)) return
        val options = CustomRasterSourceOptions.Builder()
            .clientCallback(CustomRasterSourceClient.valueOf(CustomRasterSourceTileStatusChangedCallback { tile, status ->
                main.post { statusChanged(tile, status) }
            }))
            .tileSize(CloudBlanket.TILE_POINTS.toShort())
            .minZoom(0)
            .maxZoom(CloudBlanket.MAX_ZOOM.toByte())
            .build()
        try {
            style.addSource(CustomRasterSource(SOURCE, options))
            style.addLayer(rasterLayer(LAYER, SOURCE) {
                rasterResampling(RasterResampling.LINEAR)
                // A newly painted tile fades in quickly rather than popping.
                rasterFadeDuration(150.0)
            })
        } catch (e: Exception) {
            // Custom sources are still marked experimental in Mapbox: without one, the map
            // just has no blanket, rather than not working at all.
            Log.w(TAG, "Couldn't add the cloud blanket to the map", e)
            return
        }
        this.style = style
        synchronized(lock) {
            // A new style asks for its tiles afresh.
            wanted.clear()
            waiting.clear()
            if (closed) {
                closed = false
                val mine = ++generation
                Thread({ run(mine) }, "CloudBlanket").apply { isDaemon = true; start() }
            }
        }
    }

    /** The map's going: stop painting. */
    fun close() {
        style = null
        synchronized(lock) {
            closed = true
            wanted.clear()
            waiting.clear()
            lock.notifyAll()
        }
    }

    fun setPlaces(places: BlanketPlaces) {
        synchronized(lock) {
            inputs = Inputs(places, inputs.walked, inputs.sprites)
            repaintAll()
        }
    }

    fun setSprites(sprites: CloudSprites) {
        synchronized(lock) {
            if (inputs.sprites === sprites) return
            inputs = Inputs(inputs.places, inputs.walked, sprites)
            repaintAll()
        }
    }

    /**
     * The hexes you've walked, from [WalkedHexes]. Only the tiles round the ones that
     * changed are painted again, so a walk opening a new hole repaints a few tiles. The
     * index and the difference are worked out on the painting thread.
     */
    fun setWalked(hexes: Set<Hex>) {
        synchronized(lock) {
            pendingWalked = hexes
            lock.notifyAll()
        }
    }

    private fun statusChanged(tile: CanonicalTileID, status: CustomRasterSourceTileStatus) {
        val key = key(tile.z.toInt(), tile.x, tile.y)
        synchronized(lock) {
            if (closed) return
            when (status) {
                CustomRasterSourceTileStatus.REQUIRED, CustomRasterSourceTileStatus.OPTIONAL -> {
                    wanted[key] = status == CustomRasterSourceTileStatus.REQUIRED
                    waiting.add(key)
                }
                CustomRasterSourceTileStatus.NOT_NEEDED -> {
                    wanted.remove(key)
                    waiting.remove(key)
                }
            }
            lock.notifyAll()
        }
        // Lets Mapbox drop what it was holding for this one.
        if (status == CustomRasterSourceTileStatus.NOT_NEEDED) send(tile, null)
    }

    /**
     * Hands a tile to Mapbox, on the main thread. Straight to the style rather than
     * through the source, which throws if anything's wrong: a cloud tile that doesn't
     * go in is only worth a line in the log.
     */
    private fun send(tile: CanonicalTileID, image: Image?) {
        val style = style ?: return
        if (!style.isValid()) return
        style.setStyleCustomRasterSourceTileData(SOURCE, listOf(CustomRasterSourceTileData(tile, image))).error?.let {
            Log.w(TAG, "Couldn't hand Mapbox a cloud tile: $it")
        }
    }

    /** Under the lock. */
    private fun repaintAll() {
        waiting.addAll(wanted.keys)
        lock.notifyAll()
    }

    /** One job at a time: taking in newly walked hexes before anything else, then painting a tile. */
    private fun run(mine: Int) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        val painter = BlanketTilePainter()
        while (true) {
            var walked: Set<Hex>? = null
            var tile = -1L
            synchronized(lock) {
                while (!closed && generation == mine && pendingWalked == null && waiting.isEmpty()) lock.wait()
                if (closed || generation != mine) return
                walked = pendingWalked
                pendingWalked = null
                if (walked == null) tile = next()
            }
            val hexes = walked
            if (hexes != null) walkedChanged(hexes) else paint(painter, tile)
        }
    }

    /** The next tile to paint: one Mapbox needs before one it might. Under the lock. */
    private fun next(): Long {
        val key = waiting.firstOrNull { wanted[it] == true } ?: waiting.first()
        waiting.remove(key)
        return key
    }

    /** On the painting thread, the only one that changes what's walked. */
    private fun walkedChanged(hexes: Set<Hex>) {
        val before = synchronized(lock) { inputs.walked.hexes }
        if (hexes == before) return
        val changed = (hexes - before) + (before - hexes)
        val index = WalkedIndex(hexes)
        synchronized(lock) {
            inputs = Inputs(inputs.places, index, inputs.sprites)
            for (key in wanted.keys) {
                // Zoomed out past where the holes show, nothing in the tile changes.
                val z = z(key)
                if (CloudBlanket.clearingRadius * CloudBlanket.TILE_PIXELS / (MapPoints.WORLD / (1L shl z)) < BlanketTilePainter.MIN_HOLE) continue
                if (CloudBlanket.touches(z, x(key), y(key), changed)) waiting.add(key)
            }
        }
    }

    private fun paint(painter: BlanketTilePainter, key: Long) {
        val now = synchronized(lock) { inputs }
        val sprites = now.sprites ?: return
        val image = try {
            painter.paint(z(key), x(key), y(key), sprites, now.places, now.walked)
        } catch (e: Throwable) {
            // Out of memory on a small phone, say: leave this tile, the next may fit.
            Log.w(TAG, "Couldn't paint a cloud tile", e)
            return
        }
        main.post {
            // Not wanted any more by the time it's done.
            if (synchronized(lock) { closed || key !in wanted }) return@post
            send(CanonicalTileID(z(key).toByte(), x(key), y(key)), image)
        }
    }

    private companion object {
        const val TAG = "CloudBlanket"
        const val SOURCE = "walkies-cloud-blanket"
        const val LAYER = "walkies-cloud-blanket-layer"

        fun key(z: Int, x: Int, y: Int): Long = (z.toLong() shl 50) or (x.toLong() shl 25) or y.toLong()
        fun z(key: Long) = (key ushr 50).toInt()
        fun x(key: Long) = ((key ushr 25) and 0x1FFFFFF).toInt()
        fun y(key: Long) = (key and 0x1FFFFFF).toInt()
    }
}
