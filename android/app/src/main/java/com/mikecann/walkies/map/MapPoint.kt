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

    /** Map points per metre on the ground at this latitude, like MKMapPointsPerMeterAtLatitude. */
    fun perMetre(lat: Double) = WORLD / (40_075_016.686 * kotlin.math.cos(lat * PI / 180))

    /** Map points per projected world-grid unit, the same everywhere. */
    val perGridUnit = WORLD / (2 * PI * WorldProjection.radius)
}

/** Where you are, for the cloud layer to draw on top of the clouds. In map points. */
class YouAreHere {
    var visible = false
        private set
    var x = 0.0
        private set
    var y = 0.0
        private set
    /** How far out the GPS could be, in map points. Zero when it doesn't say. */
    var radius = 0.0
        private set

    fun set(lat: Double?, lon: Double?, accuracy: Double) {
        visible = lat != null && lon != null
        if (lat == null || lon == null) return
        x = MapPoints.x(lon)
        y = MapPoints.y(lat)
        radius = if (accuracy > 0) accuracy * MapPoints.perMetre(lat) else 0.0
    }
}
