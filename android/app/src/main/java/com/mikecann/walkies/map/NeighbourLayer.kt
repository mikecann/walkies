package com.mikecann.walkies.map

import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.place.PlaceResult
import com.mikecann.walkies.ui.Type
import com.mikecann.walkies.ui.Walkies
import com.mikecann.walkies.ui.roundedFont
import com.mikecann.walkies.ui.softShadow
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** Camera distance in metres beyond which the suburbs next door show (FogMapView.swift). */
const val NEIGHBOUR_DISTANCE = 2500.0

/**
 * Where a neighbour's label goes: where it is on the map, unless that's under one of
 * the app's buttons or off the edge of the screen, when it's nudged the shortest way
 * clear. LabelPlacement in FogMapView.swift.
 */
object LabelPlacement {
    fun clear(frame: Rect, buttons: List<Rect>, bounds: Rect): Rect {
        val x = max(bounds.left, min(frame.left, bounds.right - frame.width))
        val y = max(bounds.top, min(frame.top, bounds.bottom - frame.height))
        val start = Rect(x, y, x + frame.width, y + frame.height)
        val under = buttons.filter { it.overlaps(start) }
        if (under.isEmpty()) return start
        val moves = under.flatMap { b ->
            listOf(
                start.translate(0f, b.top - start.bottom),
                start.translate(0f, b.bottom - start.top),
                start.translate(b.left - start.right, 0f),
                start.translate(b.right - start.left, 0f),
            )
        }
        val roomy = bounds.inflate(0.5f)
        return moves
            .filter { move -> roomy.contains(move.topLeft) && roomy.contains(move.bottomRight) && buttons.none { it.overlaps(move) } }
            .minByOrNull { hypot(it.center.x - start.center.x, it.center.y - start.center.y) } ?: start
    }
}

/**
 * The suburbs next to yours, outlined and labelled with a button to add them, once
 * you've zoomed out far enough to see past your own. [avoid] is where the app's
 * buttons are on screen, in pixels, so the labels keep out from under them.
 */
@Composable
fun NeighbourLayer(
    neighbours: List<PlaceResult>,
    state: MapState,
    avoid: List<Rect>,
    onPick: (PlaceResult) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current.density
    val outlines = remember(neighbours) {
        neighbours.flatMap { place ->
            place.boundary.polygons.map { polygon ->
                DoubleArray(polygon.outer.size * 2) { i ->
                    val c = polygon.outer[i / 2]
                    if (i % 2 == 0) MapPoints.x(c.lon) else MapPoints.y(c.lat)
                }
            }
        }
    }
    val labels = remember(neighbours) {
        neighbours.map { val c = it.boundary.labelPoint; MapPoints.x(c.lon) to MapPoints.y(c.lat) }
    }
    val outlineProjection = remember { Projection() }
    val labelProjection = remember { Projection() }
    val ground = remember { DoubleArray(10) }
    val path = remember { Path() }
    val fill = remember { Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL } }
    val stroke = remember(density) {
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.5f * density
            pathEffect = DashPathEffect(floatArrayOf(3 * density, 5 * density), 0f)
        }
    }

    Box(modifier.fillMaxSize()) {
        // Outlines, redrawn whenever the camera moves.
        Spacer(
            Modifier.fillMaxSize().drawBehind {
                state.cameraTick.longValue
                val controller = state.controller ?: return@drawBehind
                if (outlines.isEmpty() || controller.cameraDistance <= NEIGHBOUR_DISTANCE) return@drawBehind
                if (!state.measure(size.width, size.height, ground)) return@drawBehind
                outlineProjection.update(ground, size.width, size.height, ground[8], ground[9])
                if (!outlineProjection.valid) return@drawBehind
                path.rewind()
                for (outline in outlines) {
                    outlineProjection.polygon(outline) { x, y, first -> if (first) path.moveTo(x, y) else path.lineTo(x, y) }
                    path.close()
                }
                fill.color = Color.White.copy(alpha = 0.07f).toArgb()
                stroke.color = Color.White.copy(alpha = 0.6f).toArgb()
                drawIntoCanvas {
                    it.nativeCanvas.drawPath(path, fill)
                    it.nativeCanvas.drawPath(path, stroke)
                }
            },
        )
        // The labels, placed again on every camera change (a layout-only read).
        Layout(
            content = { for (place in neighbours) Pill(place.name) { onPick(place) } },
            modifier = Modifier.fillMaxSize(),
        ) { measurables, constraints ->
            val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
            val width = constraints.maxWidth
            val height = constraints.maxHeight
            layout(width, height) {
                state.cameraTick.longValue
                val controller = state.controller ?: return@layout
                if (controller.cameraDistance <= NEIGHBOUR_DISTANCE) return@layout
                if (!state.measure(width.toFloat(), height.toFloat(), ground)) return@layout
                labelProjection.update(ground, width.toFloat(), height.toFloat(), ground[8], ground[9])
                if (!labelProjection.valid) return@layout
                val bounds = Rect(0f, 0f, width.toFloat(), height.toFloat())
                val blocked = avoid.map { it.inflate(6 * density) }
                for ((i, placeable) in placeables.withIndex()) {
                    val (mx, my) = labels.getOrNull(i) ?: continue
                    if (!labelProjection.isInFront(mx, my)) continue
                    labelProjection.point(mx, my)
                    val cx = labelProjection.x
                    val cy = labelProjection.y
                    // Off the screen, it stays where it is, and so off the screen.
                    var frame = Rect(cx - placeable.width / 2f, cy - placeable.height / 2f, cx + placeable.width / 2f, cy + placeable.height / 2f)
                    if (bounds.contains(androidx.compose.ui.geometry.Offset(cx, cy))) frame = LabelPlacement.clear(frame, blocked, bounds)
                    placeable.place(IntOffset(frame.left.toInt(), frame.top.toInt()))
                }
            }
        }
    }
}

/** The neighbour's label: a cream sticker pill with an orange plus. */
@Composable
private fun Pill(name: String, onClick: () -> Unit) {
    val capsule = RoundedCornerShape(50)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        modifier = Modifier
            .softShadow(capsule, 4.dp, 2.dp, 0.25f, Walkies.cream)
            .clip(capsule)
            .background(Walkies.cream)
            .border(2.5.dp, Color.White, capsule)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Add $name" }
            .padding(start = 5.dp, end = 13.dp, top = 5.dp, bottom = 5.dp),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(22.dp).clip(CircleShape).background(Walkies.burnt)) {
            BasicText("+", style = Type.headline.copy(color = Color.White, fontWeight = FontWeight.Black, fontSize = 15.sp))
        }
        BasicText(name, style = Type.headline.copy(fontFamily = roundedFont(), fontSize = 15.sp, fontWeight = FontWeight.SemiBold))
    }
}
