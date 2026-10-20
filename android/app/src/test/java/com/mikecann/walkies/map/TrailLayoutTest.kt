package com.mikecann.walkies.map

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.hypot

/** TrailLayoutTests.swift. */
class TrailLayoutTest {
    private fun stamps(vararg points: Pair<Double, Double>, spacing: Double = 12.0, l: Double = -100.0, t: Double = -100.0, r: Double = 100.0, b: Double = 100.0) =
        TrailLayout.stamps(points.toList(), spacing, l, t, r, b)

    @Test
    fun evenlySpacedFeetAlternateSidesAndFaceForwards() {
        val stamps = stamps(0.0 to 0.0, 48.0 to 0.0)
        assertEquals(listOf(6.0, 18.0, 30.0, 42.0), stamps.map { it.x })
        assertEquals(listOf(true, false, true, false), stamps.map { it.isLeft })
        assertTrue(stamps.all { it.angle == 0.0 })
    }

    @Test
    fun spacingContinuesAroundCornersAndDuplicateFixes() {
        val stamps = stamps(0.0 to 0.0, 10.0 to 0.0, 10.0 to 0.0, 10.0 to 30.0)
        assertEquals(listOf(6.0 to 0.0, 10.0 to 8.0, 10.0 to 20.0), stamps.map { it.x to it.y })
        assertTrue(abs(stamps[1].angle - PI / 2) < 0.0001)
        assertEquals(listOf(0, 1, 2), stamps.map { it.index })
    }

    @Test
    fun sampleExactlyAtVertexIsOnlyDrawnOnce() {
        val stamps = stamps(0.0 to 0.0, 6.0 to 0.0, 6.0 to -20.0)
        assertEquals(listOf(6.0 to 0.0, 6.0 to -12.0), stamps.map { it.x to it.y })
        assertTrue(abs(stamps[1].angle + PI / 2) < 0.0001)
    }

    @Test
    fun clippingKeepsGlobalPhaseAndSkipsLongOffscreenSections() {
        val stamps = stamps(-12_000_000.0 to 0.0, 12_000_000.0 to 0.0, l = 0.0, t = -10.0, r = 48.0, b = 10.0)
        assertEquals(4, stamps.size)
        assertEquals(listOf(6.0, 18.0, 30.0, 42.0), stamps.map { it.x })
        assertEquals(listOf(1_000_000, 1_000_001, 1_000_002, 1_000_003), stamps.map { it.index })
        assertTrue(stamps(0.0 to 100.0, 50.0 to 100.0, l = 0.0, t = -10.0, r = 48.0, b = 10.0).isEmpty())
    }

    @Test
    fun reversedAndDiagonalSegmentsKeepTheirHeading() {
        val stamps = stamps(24.0 to 24.0, 0.0 to 0.0)
        assertTrue(abs(stamps[0].angle + 3 * PI / 4) < 0.0001)
        assertTrue(abs(hypot(stamps[1].x - stamps[0].x, stamps[1].y - stamps[0].y) - 12) < 0.0001)
    }

    @Test
    fun invalidOrEmptyInputProducesNoStamps() {
        assertTrue(stamps().isEmpty())
        assertTrue(stamps(0.0 to 0.0, 0.0 to 0.0).isEmpty())
        assertTrue(stamps(0.0 to 0.0, 20.0 to 0.0, spacing = 0.0).isEmpty())
        assertNull(TrailLayout.visibleRange(0.0, 0.0, Double.POSITIVE_INFINITY, 0.0, -100.0, -100.0, 100.0, 100.0))
    }
}
