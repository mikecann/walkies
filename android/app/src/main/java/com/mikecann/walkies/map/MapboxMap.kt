package com.mikecann.walkies.map

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnLayout
import com.mapbox.android.gestures.MoveGestureDetector
import com.mapbox.android.gestures.RotateGestureDetector
import com.mapbox.android.gestures.ShoveGestureDetector
import com.mapbox.android.gestures.StandardScaleGestureDetector
import com.mapbox.bindgen.Value
import com.mapbox.common.Cancelable
import com.mapbox.common.MapboxOptions
import com.mapbox.geojson.Point
import com.mapbox.maps.CameraOptions
import com.mapbox.maps.MapInitOptions
import com.mapbox.maps.MapView
import com.mapbox.maps.ScreenCoordinate
import com.mapbox.maps.Style
import com.mapbox.maps.plugin.animation.MapAnimationOptions
import com.mapbox.maps.plugin.animation.camera
import com.mapbox.maps.plugin.attribution.attribution
import com.mapbox.maps.plugin.compass.compass
import com.mapbox.maps.plugin.gestures.OnMapClickListener
import com.mapbox.maps.plugin.gestures.OnMoveListener
import com.mapbox.maps.plugin.gestures.OnRotateListener
import com.mapbox.maps.plugin.gestures.OnScaleListener
import com.mapbox.maps.plugin.gestures.OnShoveListener
import com.mapbox.maps.plugin.gestures.gestures
import com.mapbox.maps.plugin.logo.logo
import com.mapbox.maps.plugin.scalebar.scalebar
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.place.City

/**
 * The Mapbox satellite map, as a plain MapView rather than the Compose extension:
 * the clouds need its projection every frame, which a MapView gives directly.
 */
class MapboxController(private val view: MapView) : MapController {
    private val map = view.mapboxMap

    override fun measure(width: Float, height: Float, out: DoubleArray): Boolean {
        if (view.width <= 0 || view.height <= 0) return false
        for (i in 0 until 4) {
            val p = map.coordinateForPixel(
                ScreenCoordinate((Projection.SCREEN[i * 2] * width).toDouble(), (Projection.SCREEN[i * 2 + 1] * height).toDouble()),
            )
            out[i * 2] = MapPoints.x(p.longitude())
            out[i * 2 + 1] = MapPoints.y(p.latitude())
        }
        val centre = map.cameraState.center
        out[8] = MapPoints.x(centre.longitude())
        out[9] = MapPoints.y(centre.latitude())
        return true
    }

    override fun show(city: City, animated: Boolean) {
        val density = view.resources.displayMetrics.density
        if (view.width <= 0) return
        val fit = CameraMath.fit(city, view.width / density, view.height / density)
        val camera = CameraOptions.Builder()
            .center(Point.fromLngLat(MapPoints.lon(fit.centreX), MapPoints.lat(fit.centreY)))
            .zoom(fit.zoom)
            .pitch(CameraMath.PITCH)
            .bearing(0.0)
            .build()
        if (animated) {
            view.camera.flyTo(camera, MapAnimationOptions.mapAnimationOptions { duration(1200L) })
        } else {
            map.setCamera(camera)
        }
    }

    override val cameraDistance: Double
        get() {
            val heightDp = view.height / view.resources.displayMetrics.density
            val state = map.cameraState
            return CameraMath.distance(state.zoom, state.center.latitude(), heightDp)
        }

    override fun frame(x0: Double, y0: Double, x1: Double, y1: Double, padding: FloatArray, pitch: Double, animated: Boolean) {
        val density = view.resources.displayMetrics.density
        if (view.width <= 0) return
        val fit = CameraMath.fit(x0, y0, x1, y1, view.width / density, view.height / density, padding)
        val camera = CameraOptions.Builder()
            .center(Point.fromLngLat(MapPoints.lon(fit.centreX), MapPoints.lat(fit.centreY)))
            .zoom(fit.zoom)
            .pitch(pitch)
            .bearing(0.0)
            .build()
        if (animated) {
            view.camera.easeTo(camera, MapAnimationOptions.mapAnimationOptions { duration(800L) })
        } else {
            map.setCamera(camera)
        }
    }

    override fun lookAt(coordinate: Coordinate, distance: Double?, animated: Boolean) {
        val heightDp = view.height / view.resources.displayMetrics.density
        if (heightDp <= 0) return
        val state = map.cameraState
        val camera = CameraOptions.Builder()
            .center(Point.fromLngLat(coordinate.lon, coordinate.lat))
            .zoom(distance?.let { CameraMath.zoom(it, coordinate.lat, heightDp) } ?: state.zoom)
            .pitch(CameraMath.PITCH)
            .bearing(state.bearing)
            .build()
        if (animated) {
            view.camera.easeTo(camera, MapAnimationOptions.mapAnimationOptions { duration(800L) })
        } else {
            map.setCamera(camera)
        }
    }
}

@Composable
fun MapboxMap(
    state: MapState,
    onTap: (Coordinate) -> Unit,
    onReady: () -> Unit,
    modifier: Modifier = Modifier,
    /** Draw into a TextureView, so it can be clipped to rounded corners (the small map in walk history). */
    textureView: Boolean = false,
    /** Lift the logo and attribution clear of the phone's navigation bar. Off when the map stops above a tab bar. */
    systemBarInset: Boolean = true,
) {
    val subscriptions = remember { ArrayList<Cancelable>() }
    val tap by rememberUpdatedState(onTap)
    val ready by rememberUpdatedState(onReady)
    DisposableEffect(Unit) {
        onDispose {
            subscriptions.forEach { it.cancel() }
            subscriptions.clear()
            state.controller = null
        }
    }
    AndroidView(
        modifier = modifier,
        factory = { context ->
            MapboxOptions.accessToken = com.mikecann.walkies.BuildConfig.MAPBOX_ACCESS_TOKEN
            val view = MapView(context, MapInitOptions(context, textureView = textureView))
            val map = view.mapboxMap
            // Apple's hybrid map with points of interest turned off.
            map.loadStyle(Style.SATELLITE_STREETS) { style ->
                for (layer in style.styleLayers) {
                    if ("poi" in layer.id) style.setStyleLayerProperty(layer.id, "visibility", Value.valueOf("none"))
                }
            }
            view.scalebar.enabled = false
            view.compass.enabled = false
            val margin = 4 * view.resources.displayMetrics.density
            view.logo.marginBottom = margin
            view.attribution.marginBottom = margin
            if (systemBarInset) ViewCompat.setOnApplyWindowInsetsListener(view) { _, insets ->
                val bottom = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom.toFloat()
                view.logo.marginBottom = bottom + margin
                view.attribution.marginBottom = bottom + margin
                insets
            }

            subscriptions += map.subscribeCameraChanged { state.cameraChanged() }
            // The honeycomb shows while a finger's on the map, however it's moving it.
            var gestures = 0
            fun begin() { gestures++; state.dragging = true }
            fun end() { gestures = maxOf(0, gestures - 1); if (gestures == 0) state.dragging = false }
            view.gestures.addOnMoveListener(object : OnMoveListener {
                override fun onMoveBegin(detector: MoveGestureDetector) = begin()
                override fun onMove(detector: MoveGestureDetector) = false
                override fun onMoveEnd(detector: MoveGestureDetector) = end()
            })
            view.gestures.addOnScaleListener(object : OnScaleListener {
                override fun onScaleBegin(detector: StandardScaleGestureDetector) = begin()
                override fun onScale(detector: StandardScaleGestureDetector) {}
                override fun onScaleEnd(detector: StandardScaleGestureDetector) = end()
            })
            view.gestures.addOnRotateListener(object : OnRotateListener {
                override fun onRotateBegin(detector: RotateGestureDetector) = begin()
                override fun onRotate(detector: RotateGestureDetector) {}
                override fun onRotateEnd(detector: RotateGestureDetector) = end()
            })
            view.gestures.addOnShoveListener(object : OnShoveListener {
                override fun onShoveBegin(detector: ShoveGestureDetector) = begin()
                override fun onShove(detector: ShoveGestureDetector) {}
                override fun onShoveEnd(detector: ShoveGestureDetector) = end()
            })
            view.gestures.addOnMapClickListener(OnMapClickListener { point ->
                tap(Coordinate(point.latitude(), point.longitude()))
                false
            })

            state.controller = MapboxController(view)
            view.doOnLayout { ready() }
            view
        },
    )
}
