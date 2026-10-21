package com.mikecann.walkies.map

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** The maths that lets a bake of the clouds stand in for drawing them every frame. */
class BakeFrameTest {
    private val width = 1200f
    private val height = 1920f

    /** The stand-in map's camera over Geographe, as the tablet would see it. */
    private fun camera(change: StandInCamera.() -> Unit = {}) = StandInCamera(1.5f).apply {
        width = this@BakeFrameTest.width
        height = this@BakeFrameTest.height
        zoom = 15.0
        change()
    }

    private fun projection(camera: StandInCamera): Projection {
        val ground = DoubleArray(10)
        assertTrue(camera.measure(camera.width, camera.height, ground))
        return Projection().apply { update(ground, camera.width, camera.height, ground[8], ground[9]) }.also { assertTrue(it.valid) }
    }

    /** Map points spread over the ground [camera] sees, and a bit past. */
    private fun samples(camera: StandInCamera): List<Pair<Double, Double>> {
        val p = projection(camera)
        val out = ArrayList<Pair<Double, Double>>()
        for (i in 0..8) for (j in 0..8) {
            if (p.unproject(width * (-0.1 + 1.2 * i / 8), height * (-0.1 + 1.2 * j / 8))) out.add(p.groundX to p.groundY)
        }
        return out
    }

    @Test
    fun invertingUndoes() {
        val m = doubleArrayOf(2.0, 0.3, 40.0, -0.1, 1.7, -12.0, 0.0002, 0.0004, 1.0)
        val inverse = DoubleArray(9)
        val product = DoubleArray(9)
        assertTrue(Mat3.invert(m, inverse))
        Mat3.multiply(m, inverse, product)
        for (i in 0 until 9) assertEquals(if (i % 4 == 0) 1.0 else 0.0, product[i], 1e-12)
        assertFalse(Mat3.invert(DoubleArray(9), inverse))
    }

    @Test
    fun unprojectingFindsTheGroundUnderAPixel() {
        val p = projection(camera())
        for (u in listOf(0.0, 300.0, 1200.0)) for (v in listOf(0.0, 960.0, 1920.0)) {
            assertTrue(p.unproject(u, v))
            p.point(p.groundX, p.groundY)
            assertEquals(u, p.x.toDouble(), 0.05)
            assertEquals(v, p.y.toDouble(), 0.05)
        }
    }

    /**
     * The heart of it: a cloud drawn at its spot from the bake's camera, then warped
     * by the matrix, lands where drawing it from today's camera would put it. Panned,
     * zoomed, turned and tilted, everywhere on screen, to within a pixel.
     */
    @Test
    fun theWarpPutsTheBakeWhereTheProjectionWould() {
        val bakeCamera = camera()
        val bake = projection(bakeCamera)
        val moves: List<StandInCamera.() -> Unit> = listOf(
            { pan(140f, -260f) },
            { zoomBy(1.3f) },
            { zoomBy(0.6f) },
            { rotate(25f) },
            { pitch = 30.0 },
            { pitch = 0.0; rotate(-90f); pan(-500f, 300f) },
        )
        val warp = BakeWarp()
        var checked = 0
        for (move in moves) {
            val now = projection(camera(move))
            val frame = BakeFrame.around(bake, width, height, draft = false)
            assertTrue(warp.update(now, frame))
            for ((x, y) in samples(bakeCamera)) {
                if (!now.isInFront(x, y)) continue
                bake.point(x, y)
                val bx = bake.x.toDouble()
                val by = bake.y.toDouble()
                now.point(x, y)
                // In doubles, as the matrix is worked out.
                assertTrue(warp.map(bx, by))
                assertEquals(now.x.toDouble(), warp.x, 1.0)
                assertEquals(now.y.toDouble(), warp.y, 1.0)
                // And in floats, as android.graphics.Matrix applies it.
                val v = warp.values
                val w = v[6] * bx.toFloat() + v[7] * by.toFloat() + v[8]
                assertTrue(w > 0)
                assertEquals(now.x, (v[0] * bx.toFloat() + v[1] * by.toFloat() + v[2]) / w, 1f)
                assertEquals(now.y, (v[3] * bx.toFloat() + v[4] * by.toFloat() + v[5]) / w, 1f)
                checked++
            }
        }
        assertTrue(checked > 300)
    }

    @Test
    fun aBakeFitsUntilTheCameraMovesTooFar() {
        val bake = projection(camera())
        val frame = BakeFrame.around(bake, width, height, draft = false)
        val warp = BakeWarp()
        fun fits(move: StandInCamera.() -> Unit): Boolean {
            val now = projection(camera(move))
            return warp.update(now, frame) && warp.fits(frame, width, height)
        }
        fun exact(move: StandInCamera.() -> Unit): Boolean {
            val now = projection(camera(move))
            return warp.update(now, frame) && warp.exact(width, height)
        }
        assertTrue(fits {})
        assertTrue(exact {})
        // A small pan or zoom is just a warp of what's there.
        assertTrue(fits { pan(60f, 80f) })
        assertFalse(exact { pan(60f, 80f) })
        assertTrue(fits { zoomBy(1.1f) })
        // Off the edge, zoomed or turned too far, or tilted: baked again.
        assertFalse(fits { pan(400f, 0f) })
        assertFalse(fits { pan(0f, -700f) })
        assertFalse(fits { zoomBy(1.5f) })
        assertFalse(fits { zoomBy(0.65f) })
        assertFalse(fits { rotate(10f) })
        assertFalse(fits { pitch = 20.0 })
    }

    /** Mid-pan a rough bake is left alone longer, but asked for again before its edge shows. */
    @Test
    fun aRoughBakeLastsWhileTheMapMoves() {
        val frame = BakeFrame.around(projection(camera()), width, height, draft = true)
        val warp = BakeWarp()
        fun fits(moving: Boolean, move: StandInCamera.() -> Unit): Boolean {
            val now = projection(camera(move))
            return warp.update(now, frame) && warp.fits(frame, width, height, moving)
        }
        // Zoomed or turned further than a still map allows.
        assertFalse(fits(moving = false) { zoomBy(1.4f) })
        assertTrue(fits(moving = true) { zoomBy(1.4f) })
        assertTrue(fits(moving = true) { rotate(6f) })
        // A pan that's still on the bake, but past half its margin: asked for again while moving.
        val pan = width * BakeFrame.DRAFT_MARGIN * 0.75f
        assertFalse(fits(moving = true) { pan(pan, 0f) })
        assertTrue(fits(moving = true) { pan(pan / 3, 0f) })
    }

    @Test
    fun theFrameCoversTheScreenWithAMarginAndKeepsToItsBudget() {
        for (draft in listOf(false, true)) {
            val frame = BakeFrame.around(projection(camera()), width, height, draft)
            val margin = if (draft) BakeFrame.DRAFT_MARGIN else BakeFrame.MARGIN
            assertEquals(-width * margin, frame.left, 0.01f)
            assertEquals(width * (1 + margin), frame.right, 0.01f)
            assertEquals(height * (1 + margin), frame.bottom, 0.01f)
            assertTrue(frame.top <= 0f)
            assertTrue(frame.pixelWidth.toLong() * frame.pixelHeight <= BakeFrame.MAX_PIXELS * 1.01)
            assertTrue(frame.pixelWidth <= BakeFrame.MAX_SIDE && frame.pixelHeight <= BakeFrame.MAX_SIDE)
            assertEquals(draft, frame.draft)
        }
        // The tablet's screen plus its margin is under the budget: baked at the usual scale.
        val full = BakeFrame.around(projection(camera()), width, height, draft = false)
        assertEquals(BakeFrame.SCALE, full.scale, 0.001f)
        // A much bigger screen bakes softer rather than bigger.
        val big = BakeFrame.around(projection(camera { width = 2560f; height = 3200f }), 2560f, 3200f, draft = false)
        assertTrue(big.scale < 1f)
        assertTrue(big.pixelWidth.toLong() * big.pixelHeight <= BakeFrame.MAX_PIXELS * 1.01)
    }

    /** Tilted right up, the horizon's on screen: the bake stops short of it, so it can always be drawn. */
    @Test
    fun aSteepBakeStopsShortOfTheHorizon() {
        val p = projection(camera { pitch = 80.0 })
        val frame = BakeFrame.around(p, width, height, draft = false)
        assertTrue(frame.top > 0f)
        for (u in listOf(frame.left, frame.right)) {
            assertTrue(p.unproject(u.toDouble(), frame.top.toDouble() + 0.5))
            assertTrue(p.unproject(u.toDouble(), frame.bottom.toDouble()))
        }
        assertTrue(BakeWarp().update(p, frame))
        // Flat on, there's no horizon to stop for.
        val flat = BakeFrame.around(projection(camera { pitch = 0.0 }), width, height, draft = false)
        assertEquals(-height * BakeFrame.MARGIN, flat.top, 0.01f)
    }

    @Test
    fun copiesProjectTheSame() {
        val p = projection(camera { rotate(30f) })
        val copy = Projection().also { it.copyFrom(p) }
        for ((x, y) in samples(camera())) {
            p.point(x, y)
            copy.point(x, y)
            assertEquals(p.x, copy.x, 0f)
            assertEquals(p.y, copy.y, 0f)
        }
        assertEquals(p.centreScale, copy.centreScale, 0.0)
        assertTrue(abs(p.centreScale) > 0)
    }
}
