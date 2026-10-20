package com.mikecann.walkies.map

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.WorldProjection
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.sin

/**
 * Apple's MKMapPoint: spherical Web Mercator over a 2^28 square world, y pointing
 * south. Kept in the same units as iOS so the cloud constants carry over unchanged.
 */
object MapPoints {
    const val WORLD = 268_435_456.0

    fun x(lon: Double) = (lon + 180) / 360 * WORLD

    fun y(lat: Double): Double {
        val s = sin(lat * PI / 180)
        return (0.5 - ln((1 + s) / (1 - s)) / (4 * PI)) * WORLD
    }

    fun lon(x: Double) = x / WORLD * 360 - 180

    fun lat(y: Double) = (2 * atan(exp((0.5 - y / WORLD) * 2 * PI)) - PI / 2) * 180 / PI

    fun coordinate(x: Double, y: Double) = Coordinate(lat(y), lon(x))

    /** Map points per projected world-grid unit, the same everywhere. */
    val perGridUnit = WORLD / (2 * PI * WorldProjection.radius)
}
