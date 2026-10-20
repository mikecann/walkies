package com.mikecann.walkies.grid

import kotlin.math.PI
import kotlin.math.asin
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

data class Coordinate(val lat: Double, val lon: Double) {
    /** Great-circle distance in metres. */
    fun distance(other: Coordinate): Double {
        val rad = PI / 180
        val dLat = (other.lat - lat) * rad
        val dLon = (other.lon - lon) * rad
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat * rad) * cos(other.lat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * LocalProjection.EARTH_RADIUS * asin(min(1.0, sqrt(a)))
    }

    fun lerp(other: Coordinate, t: Double) = Coordinate(lat + (other.lat - lat) * t, lon + (other.lon - lon) * t)
}

/** Swift's SIMD2<Double>, for projected metres. */
data class Vec2(val x: Double, val y: Double) {
    operator fun plus(o: Vec2) = Vec2(x + o.x, y + o.y)
    operator fun minus(o: Vec2) = Vec2(x - o.x, y - o.y)
    operator fun times(k: Double) = Vec2(x * k, y * k)
    operator fun div(k: Double) = Vec2(x / k, y / k)
    fun distance(o: Vec2) = kotlin.math.hypot(x - o.x, y - o.y)
}

interface GeoProjection {
    fun project(c: Coordinate): Vec2
    fun unproject(p: Vec2): Coordinate
}

/**
 * Spherical Web Mercator, scaled to ground metres at Busselton's latitude.
 * This has no local origin: a projected point means the same thing everywhere.
 */
object WorldProjection : GeoProjection {
    const val EARTH_RADIUS = 6_378_137.0
    const val REFERENCE_LATITUDE = -33.65
    val scale = cos(REFERENCE_LATITUDE * PI / 180)
    val radius = EARTH_RADIUS * scale

    override fun project(c: Coordinate): Vec2 {
        val lat = c.lat * PI / 180
        return Vec2(radius * c.lon * PI / 180, radius * ln(tan(PI / 4 + lat / 2)))
    }

    override fun unproject(p: Vec2) = Coordinate(
        lat = (2 * atan(exp(p.y / radius)) - PI / 2) * 180 / PI,
        lon = p.x / radius * 180 / PI,
    )
}

/** Flat east/north metres around an origin, for local boundary and route geometry. */
data class LocalProjection(val origin: Coordinate) : GeoProjection {
    private val metresPerDegreeLat get() = EARTH_RADIUS * PI / 180
    private val metresPerDegreeLon get() = metresPerDegreeLat * cos(origin.lat * PI / 180)

    override fun project(c: Coordinate) =
        Vec2((c.lon - origin.lon) * metresPerDegreeLon, (c.lat - origin.lat) * metresPerDegreeLat)

    override fun unproject(p: Vec2) =
        Coordinate(origin.lat + p.y / metresPerDegreeLat, origin.lon + p.x / metresPerDegreeLon)

    companion object {
        const val EARTH_RADIUS = 6_371_008.8
    }
}
