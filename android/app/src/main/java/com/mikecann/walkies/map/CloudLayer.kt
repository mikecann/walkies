package com.mikecann.walkies.map

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import kotlin.math.min

/**
 * Clouds that just cleared, fading out as they drift apart. Only tiles clearing
 * animate, not a whole place being added or removed.
 */
private class Reveal {
    var shown: CloudField? = null
    var leaving: List<CloudField.Puff> = emptyList()
    var freshClearings: BooleanArray? = null
    var changedAt = 0L

    fun update(field: CloudField) {
        val old = shown
        if (old != null && old !== field && old.places == field.places) {
            val still = field.puffs.mapTo(HashSet()) { it.tile }
            leaving = old.puffs.filter { it.tile !in still }
            val gone = leaving.mapTo(HashSet()) { it.tile }
            freshClearings = BooleanArray(field.clearings.size) { field.clearings[it].tile in gone }
            changedAt = System.nanoTime()
        } else if (old !== field) {
            leaving = emptyList()
            freshClearings = null
        }
        shown = field
    }
}

/**
 * The clouds, drawn on top of the map about 30 times a second so they can drift
 * and breathe, and every frame while the map moves. They follow the map by asking
 * it where the ground is on screen. CloudLayer in Clouds.swift.
 */
@Composable
fun CloudLayer(
    field: CloudField,
    state: MapState,
    sprites: CloudSprites?,
    /** The walk's route, interleaved x, y map points. */
    route: DoubleArray,
    /** Tiles uncovered this walk, six corners each as interleaved x, y map points. */
    fresh: List<DoubleArray>,
    you: YouAreHere,
    modifier: Modifier = Modifier,
    /** What's equipped from the shop: the trail, the marker and the spyglass's ring. */
    cosmetics: MapCosmetics = MapCosmetics.none,
) {
    val density = LocalDensity.current.density
    val painter = remember(density) { CloudPainter(density) }
    val projection = remember { Projection() }
    val ground = remember { DoubleArray(10) }
    val reveal = remember { Reveal() }
    reveal.update(field)

    // Drift at 30 frames a second while the map's still. Camera changes redraw on top.
    var clock by remember { mutableDoubleStateOf(0.0) }
    LaunchedEffect(Unit) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                if (now - last >= 33_000_000L) {
                    last = now
                    clock = now / 1e9
                }
            }
        }
    }

    Spacer(
        modifier.fillMaxSize().drawBehind {
            state.cameraTick.longValue
            val now = clock
            val controller = state.controller ?: return@drawBehind
            if (sprites == null) return@drawBehind
            if (!controller.measure(size.width, size.height, ground)) return@drawBehind
            projection.update(ground, size.width, size.height, ground[8], ground[9])
            if (!projection.valid) return@drawBehind
            val nanos = System.nanoTime()
            val progress = min(1.0, (nanos - reveal.changedAt) / 1e9 / REVEAL_TIME)
            drawIntoCanvas { canvas ->
                painter.draw(
                    canvas.nativeCanvas, field, reveal.leaving, reveal.freshClearings, progress,
                    projection, sprites, size.width, size.height, now, state.honeycomb(nanos), route, fresh, you, cosmetics,
                )
            }
        },
    )
}

const val REVEAL_TIME = 1.6
