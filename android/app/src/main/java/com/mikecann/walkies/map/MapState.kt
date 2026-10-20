package com.mikecann.walkies.map

import androidx.compose.runtime.mutableLongStateOf
import com.mikecann.walkies.place.City
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/** Whichever map is showing: Mapbox, or the stand-in when there's no access token. */
interface MapController {
    /**
     * Fills [out] with the map point x, y under each of the four [Projection.SCREEN]
     * spots of a [width] x [height] pixel view, then the map point mid-screen
     * (10 values). False if the map can't say yet.
     */
    fun measure(width: Float, height: Float, out: DoubleArray): Boolean

    /** Fits the place on screen, tilted, like zoomToCity in FogMapView.swift. */
    fun show(city: City, animated: Boolean)
}

/**
 * Lets the cloud layer ask the map where things are on screen right now, and
 * redraw whenever the camera moves. MapHandle in Clouds.swift.
 */
class MapState {
    var controller: MapController? = null

    /** Bumped on every camera change, so the clouds redraw every frame while the map moves. */
    val cameraTick = mutableLongStateOf(0L)

    /** True while your finger's moving the map, for the colour-coded honeycomb. */
    var dragging = false
        set(value) {
            if (value != field) {
                field = value
                draggingChangedAt = System.nanoTime()
            }
        }
    private var draggingChangedAt = System.nanoTime() - 10_000_000_000L

    fun cameraChanged() {
        cameraTick.longValue++
    }

    /** How much of the honeycomb to show: fades in as you drag and out after. */
    fun honeycomb(now: Long): Float {
        val since = (now - draggingChangedAt) / 1e9
        return if (dragging) min(1.0, since / 0.15).toFloat() else max(0.0, 1 - since / 0.6).toFloat()
    }
}

/** Camera numbers shared by the Mapbox map and the stand-in. */
object CameraMath {
    /** The isometric angle the iPhone app uses. */
    const val PITCH = 55.0

    /** Mapbox's tiles are 512 points across at zoom 0. */
    private const val TILE = 512.0

    /** Mapbox's default vertical field of view puts the camera 1.5 view-heights from the centre. */
    private const val CAMERA_HEIGHTS = 1.5

    class Fit(val centreX: Double, val centreY: Double, val zoom: Double)

    /**
     * Fits the place's outline flat with the iPhone's padding (150 top and bottom,
     * 20 either side), then keeps that zoom when tilted. MapKit does the same: fit
     * flat, note the camera distance, tilt.
     */
    fun fit(city: City, widthDp: Float, heightDp: Float): Fit {
        val b = city.boundary.bounds
        val x0 = MapPoints.x(b.west)
        val x1 = MapPoints.x(b.east)
        val y0 = MapPoints.y(b.north)
        val y1 = MapPoints.y(b.south)
        val w = max(1.0, widthDp - 40.0)
        val h = max(1.0, heightDp - 300.0)
        val pointsPerMapPoint = min(w / max(1e-9, x1 - x0), h / max(1e-9, y1 - y0))
        val zoom = ln(pointsPerMapPoint * MapPoints.WORLD / TILE) / ln(2.0)
        return Fit((x0 + x1) / 2, (y0 + y1) / 2, zoom)
    }

    /** The Mapbox zoom that puts the camera [distance] metres from the ground, like MKMapCamera's centerCoordinateDistance. */
    fun zoom(distance: Double, latitude: Double, heightDp: Float): Double {
        val metresPerPointAtZoom0 = 40_075_016.686 * cos(latitude * PI / 180) / TILE
        return ln(metresPerPointAtZoom0 * CAMERA_HEIGHTS * heightDp / distance) / ln(2.0)
    }

    /** Points on screen per map point at this zoom, mid-screen. */
    fun pointsPerMapPoint(zoom: Double) = TILE * Math.pow(2.0, zoom) / MapPoints.WORLD
}
