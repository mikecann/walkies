package com.mikecann.walkies.map

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.place.City
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sin

/**
 * A blank stand-in for the map when there's no Mapbox token: a plain tilted camera
 * over nothing, so the clouds, gestures and chrome can still be seen and tried.
 * Same camera model as Mapbox (zoom, bearing, 55° pitch, camera 1.5 view-heights away).
 */
class StandInCamera(private val density: Float) : MapController {
    var centreX = MapPoints.x(115.37)
    var centreY = MapPoints.y(-33.64)
    var zoom = 14.0
    var bearing = 0.0
    var pitch = CameraMath.PITCH
    var width = 0f
    var height = 0f
    var onChange: () -> Unit = {}

    /** Map point under a screen pixel, into [outX], [outY]. False above the horizon. */
    private var outX = 0.0
    private var outY = 0.0

    private fun unproject(u: Double, v: Double): Boolean {
        val f = 1.5 * height
        val a = (u - width / 2) / f
        val b = (v - height / 2) / f
        val t = pitch * PI / 180
        val denominator = cos(t) + b * sin(t)
        if (denominator <= 1e-6) return false
        val y = b * f / denominator
        val x = a * (f - y * sin(t))
        val s = CameraMath.pointsPerMapPoint(zoom) * density
        val beta = bearing * PI / 180
        outX = centreX + (x * cos(beta) - y * sin(beta)) / s
        outY = centreY + (x * sin(beta) + y * cos(beta)) / s
        return true
    }

    override fun measure(width: Float, height: Float, out: DoubleArray): Boolean {
        if (this.width <= 0f || this.height <= 0f) return false
        for (i in 0 until 4) {
            if (!unproject((Projection.SCREEN[i * 2] * width).toDouble(), (Projection.SCREEN[i * 2 + 1] * height).toDouble())) return false
            out[i * 2] = outX
            out[i * 2 + 1] = outY
        }
        out[8] = centreX
        out[9] = centreY
        return true
    }

    fun coordinate(u: Float, v: Float): Coordinate? =
        if (unproject(u.toDouble(), v.toDouble())) MapPoints.coordinate(outX, outY) else null

    fun pan(dx: Float, dy: Float) {
        val s = CameraMath.pointsPerMapPoint(zoom) * density
        val beta = bearing * PI / 180
        // Drags up and down the tilted ground cover more of it.
        val y = dy / cos(pitch * PI / 180)
        centreX -= (dx * cos(beta) - y * sin(beta)) / s
        centreY -= (dx * sin(beta) + y * cos(beta)) / s
        onChange()
    }

    fun zoomBy(factor: Float) {
        zoom = (zoom + ln(max(0.01f, factor).toDouble()) / ln(2.0)).coerceIn(3.0, 20.0)
        onChange()
    }

    fun rotate(degrees: Float) {
        bearing -= degrees
        onChange()
    }

    override val cameraDistance: Double
        get() = CameraMath.distance(zoom, MapPoints.lat(centreY), height / density)

    override fun lookAt(coordinate: Coordinate, distance: Double?, animated: Boolean) {
        if (width <= 0f) return
        centreX = MapPoints.x(coordinate.lon)
        centreY = MapPoints.y(coordinate.lat)
        if (distance != null) zoom = CameraMath.zoom(distance, coordinate.lat, height / density)
        pitch = CameraMath.PITCH
        onChange()
    }

    override fun show(city: City, animated: Boolean) {
        if (width <= 0f) return
        val fit = CameraMath.fit(city, width / density, height / density)
        centreX = fit.centreX
        centreY = fit.centreY
        zoom = fit.zoom
        bearing = 0.0
        pitch = CameraMath.PITCH
        onChange()
    }
}

@Composable
fun StandInMap(state: MapState, onTap: (Coordinate) -> Unit, onReady: () -> Unit, modifier: Modifier = Modifier) {
    val density = LocalDensity.current.density
    val camera = remember(density) { StandInCamera(density) }
    DisposableEffect(camera) {
        camera.onChange = { state.cameraChanged() }
        state.controller = camera
        onDispose { if (state.controller === camera) state.controller = null }
    }
    Box(
        modifier
            .fillMaxSize()
            .background(Color(0xFF2F3B34))
            .onSizeChanged {
                val first = camera.width <= 0f
                camera.width = it.width.toFloat()
                camera.height = it.height.toFloat()
                state.cameraChanged()
                if (first) onReady()
            }
            .pointerInput(camera) {
                detectTransformGestures { _, pan, gestureZoom, rotation ->
                    state.dragging = true
                    camera.pan(pan.x, pan.y)
                    if (gestureZoom != 1f) camera.zoomBy(gestureZoom)
                    if (rotation != 0f) camera.rotate(rotation)
                }
            }
            .pointerInput(camera) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        if (event.changes.none { it.pressed }) state.dragging = false
                    }
                }
            }
            .pointerInput(camera) {
                detectTapGestures { offset -> camera.coordinate(offset.x, offset.y)?.let(onTap) }
            },
    )
}
