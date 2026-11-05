package com.mikecann.walkies.map

import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/**
 * Which of the world's puffs ([CloudBlanket]) are on screen now, for drawing them live
 * with the place clouds. Mapbox used to draw them from tiles painted in the background,
 * which came in late as you scrolled, in squares.
 *
 * Laid out the way those tiles were: the world split into Mapbox's tile pyramid, each
 * tile split again until it's no more than [CloudBlanket.TILE_POINTS] across on screen,
 * and each tile's puffs from its zoom's [CloudBlanket.level]. As the tiles are fixed to
 * the world, the same ground always gets the same puffs while you pan, and they only
 * change level where a tile crosses that size, as Mapbox's did. Each tile's puffs are
 * worked out once and kept, as there can be a few hundred.
 */
class WorldCloudTiles {
    /** The puffs to draw, north first, and how many. Valid after [update]. */
    var puffs: Array<CloudBlanket.Puff> = emptyArray()
        private set
    /** The ground the tiles cover, for which walked holes to cut: min x, min y, max x, max y. */
    val area = DoubleArray(4)

    private val cache = object : LinkedHashMap<Long, List<CloudBlanket.Puff>>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, List<CloudBlanket.Puff>>?) = size > 96
    }
    private val tiles = ArrayList<Long>()
    val tileCount get() = tiles.size
    val tileKeys get() = tiles.joinToString { "z${it ushr 50}" }
    private var lastTiles: List<Long> = emptyList()
    private val box = FloatArray(4)
    private var top = 0f
    private var coarsest = 0

    /** Works out the tiles on a [width] x [height] pixel screen through [projection]. */
    fun update(projection: Projection, width: Float, height: Float, density: Float) {
        tiles.clear()
        // Stop short of the horizon, as a bake does: past it there's only sky, and the
        // ground's so far off that tiles there are specks, and endless.
        top = -height * MARGIN
        for (u in floatArrayOf(0f, width)) {
            val row = projection.nearestRowWithin(u.toDouble(), BakeFrame.FAR)
            if (row.isFinite() && row > top) top = row.toFloat()
        }
        area[0] = Double.POSITIVE_INFINITY; area[1] = Double.POSITIVE_INFINITY
        area[2] = Double.NEGATIVE_INFINITY; area[3] = Double.NEGATIVE_INFINITY
        // Mapbox's zoom in the middle of the screen. Tiles far coarser than that are out
        // by the horizon, small on screen but each a vast stretch of ground with thousands
        // of puffs: they're left out.
        val worldPixels = MapPoints.WORLD * projection.centreScale
        coarsest = if (worldPixels > 0) (ln(worldPixels / (CloudBlanket.TILE_POINTS * density)) / ln(2.0)).toInt() - COARSER else 0
        visit(projection, 0, 0, 0, width, height, CloudBlanket.TILE_POINTS * density)
        if (tiles == lastTiles) return
        lastTiles = ArrayList(tiles)
        val seen = HashSet<Long>()
        val out = ArrayList<CloudBlanket.Puff>()
        for (key in tiles) {
            val list = cache.getOrPut(key) {
                val z = (key ushr 50).toInt()
                val x = ((key ushr 25) and 0x1FFFFFF).toInt()
                val y = (key and 0x1FFFFFF).toInt()
                val b = CloudBlanket.tileBox(z, x, y)
                CloudBlanket.puffs(CloudBlanket.level(z), b[0], b[1], b[2], b[3])
            }
            // A puff reaching into two tiles of the same level is in both: once is enough.
            if (out.size >= MAX_PUFFS) break
            for (p in list) if (seen.add(java.lang.Double.doubleToLongBits(p.x) * 31 + java.lang.Double.doubleToLongBits(p.y))) out.add(p)
        }
        out.sortWith(compareBy<CloudBlanket.Puff>({ it.y }, { it.x }))
        puffs = out.toTypedArray()
    }

    private fun visit(projection: Projection, z: Int, x: Int, y: Int, width: Float, height: Float, limit: Float) {
        val b = CloudBlanket.tileBox(z, x, y)
        var inFront = 0
        box[0] = Float.POSITIVE_INFINITY; box[1] = Float.POSITIVE_INFINITY
        box[2] = Float.NEGATIVE_INFINITY; box[3] = Float.NEGATIVE_INFINITY
        for (i in 0 until 4) {
            val px = if (i == 0 || i == 3) b[0] else b[2]
            val py = if (i < 2) b[1] else b[3]
            if (!projection.isInFront(px, py)) continue
            inFront++
            projection.point(px, py)
            box[0] = min(box[0], projection.x); box[1] = min(box[1], projection.y)
            box[2] = max(box[2], projection.x); box[3] = max(box[3], projection.y)
        }
        if (inFront == 0 || tiles.size >= MAX_TILES) return
        val onScreen = box[2] >= -width * MARGIN && box[0] <= width * (1 + MARGIN) && box[3] >= top && box[1] <= height * (1 + MARGIN)
        // Partly behind the camera: only some of it can be on screen, so look closer, but
        // only so far, as the ground right under a tilted camera is off the bottom anyway.
        if (inFront < 4) {
            if (z < PARTLY_BEHIND_ZOOM) split(projection, z, x, y, width, height, limit)
            return
        }
        if (!onScreen) return
        if (max(box[2] - box[0], box[3] - box[1]) > limit && z < CloudBlanket.MAX_ZOOM) {
            split(projection, z, x, y, width, height, limit)
            return
        }
        if (z < coarsest) return
        tiles.add((z.toLong() shl 50) or (x.toLong() shl 25) or y.toLong())
        area[0] = min(area[0], b[0]); area[1] = min(area[1], b[1])
        area[2] = max(area[2], b[2]); area[3] = max(area[3], b[3])
    }

    private companion object {
        /** How far past each edge of the screen tiles are kept, as a share of its size. */
        const val MARGIN = 0.2f
        /** Deepest a tile partly behind the camera is split. */
        const val PARTLY_BEHIND_ZOOM = 12
        /** Never more than this many, whatever the camera: each holds a few hundred puffs. */
        const val MAX_TILES = 64
        /** How many zooms coarser than the middle of the screen a tile can be. */
        const val COARSER = 3
        /** And never more puffs than this a frame. */
        const val MAX_PUFFS = 6000
    }

    private fun split(projection: Projection, z: Int, x: Int, y: Int, width: Float, height: Float, limit: Float) {
        for (dy in 0..1) for (dx in 0..1) visit(projection, z + 1, x * 2 + dx, y * 2 + dy, width, height, limit)
    }
}
