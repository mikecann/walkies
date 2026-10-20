package com.mikecann.walkies.map

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.ui.StickerArt
import com.mikecann.walkies.ui.pressScale

/** A found sticker, pinned where you found it (StickerPin in FogMapView.swift). */
data class StickerPin(val entry: LoreEntry, val coordinate: Coordinate)

/**
 * Found secrets, as their stickers on the tiles they were under. Tap one to read it
 * again. They stay the same size however the map's tilted or zoomed, like MapKit's
 * annotation views, and are placed again on every camera change (a layout-only read).
 */
@Composable
fun StickerPinLayer(pins: List<StickerPin>, state: MapState, onPick: (LoreEntry) -> Unit, modifier: Modifier = Modifier) {
    val points = remember(pins) { pins.map { MapPoints.x(it.coordinate.lon) to MapPoints.y(it.coordinate.lat) } }
    val projection = remember { Projection() }
    val ground = remember { DoubleArray(10) }
    Layout(
        content = {
            for (pin in pins) {
                Box(Modifier.pressScale({ onPick(pin.entry) }, label = pin.entry.title).padding(3.dp)) {
                    StickerArt(pin.entry, 40.dp)
                }
            }
        },
        modifier = modifier.fillMaxSize(),
    ) { measurables, constraints ->
        val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
        val width = constraints.maxWidth
        val height = constraints.maxHeight
        layout(width, height) {
            state.cameraTick.longValue
            val controller = state.controller ?: return@layout
            if (!controller.measure(width.toFloat(), height.toFloat(), ground)) return@layout
            projection.update(ground, width.toFloat(), height.toFloat(), ground[8], ground[9])
            if (!projection.valid) return@layout
            for ((i, placeable) in placeables.withIndex()) {
                val (x, y) = points.getOrNull(i) ?: continue
                if (!projection.isInFront(x, y)) continue
                projection.point(x, y)
                placeable.place(IntOffset((projection.x - placeable.width / 2f).toInt(), (projection.y - placeable.height / 2f).toInt()))
            }
        }
    }
}
