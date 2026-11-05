package com.mikecann.walkies.map

import org.junit.Assert.assertTrue
import org.junit.Test

/** The world's clouds round the camera, laid out live rather than by Mapbox's tiles. */
class WorldCloudTilesTest {
    private val width = 1080f
    private val height = 2400f
    private val density = 2.75f

    private fun projection(change: StandInCamera.() -> Unit): Projection {
        val camera = StandInCamera(density).apply {
            width = this@WorldCloudTilesTest.width
            height = this@WorldCloudTilesTest.height
            change()
        }
        val ground = DoubleArray(10)
        assertTrue(camera.measure(width, height, ground))
        return Projection().apply { update(ground, width, height, ground[8], ground[9]) }.also { assertTrue(it.valid) }
    }

    /** The share of a grid of spots across the screen that some puff covers. */
    private fun covered(tiles: WorldCloudTiles, p: Projection, from: Float, to: Float): Double {
        var hit = 0
        var total = 0
        for (i in 0..10) for (j in 0..10) {
            val u = width * i / 10f
            val v = height * (from + (to - from) * j / 10f)
            total++
            if (tiles.puffs.any { puff ->
                    p.ellipse(puff.x, puff.y, puff.radius) && run {
                        // Inside the ellipse, not just its box. The sprite's soft edge is
                        // about two thirds of the way out, so only that far counts.
                        val dx = (u - p.ex) / (p.rx * 0.66f)
                        val dy = (v - p.ey) / (p.ry * 0.66f)
                        dx * dx + dy * dy <= 1
                    }
                }) hit++
        }
        return hit.toDouble() / total
    }

    @Test
    fun aTiltedCameraIsCoveredToTheBottomOfTheScreenWithoutTooManyPuffs() {
        for (zoom in listOf(13.0, 15.0, 17.0)) {
            for (pitch in listOf(0.0, 45.0, 60.0)) {
                val p = projection { this.zoom = zoom; this.pitch = pitch }
                val tiles = WorldCloudTiles()
                val started = System.nanoTime()
                tiles.update(p, width, height, density)
                val ms = (System.nanoTime() - started) / 1e6
                // It used to split tiles near the horizon without end, and hang the app.
                assertTrue("zoom $zoom pitch $pitch: ${tiles.puffs.size} puffs", tiles.puffs.size in 1..14000)
                assertTrue("zoom $zoom pitch $pitch: took $ms ms", ms < 2000)
                // And to leave the ground right in front of a tilted camera bare. (Up by the
                // horizon the puffs are smaller and thinner, and the gaps between show more.)
                val bottom = covered(tiles, p, 0.6f, 1f)
                val middle = covered(tiles, p, 0.3f, 0.6f)
                assertTrue("zoom $zoom pitch $pitch: only $bottom of the bottom of the screen under cloud", bottom > 0.95)
                assertTrue("zoom $zoom pitch $pitch: only $middle of the middle of the screen under cloud", middle > 0.9)
                println("zoom $zoom pitch $pitch: ${tiles.puffs.size} puffs, bottom $bottom middle $middle, $ms ms")
            }
        }
    }

    @Test
    fun theSameCameraGivesTheSamePuffs() {
        val p = projection { zoom = 15.0; pitch = 45.0 }
        val a = WorldCloudTiles().apply { update(p, width, height, density) }.puffs
        val b = WorldCloudTiles().apply { update(p, width, height, density) }.puffs
        assertTrue(a.size == b.size && a.indices.all { a[it].x == b[it].x && a[it].y == b[it].y })
    }
}
