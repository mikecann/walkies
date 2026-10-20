package com.mikecann.walkies.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.BuildConfig
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.map.CloudField
import com.mikecann.walkies.map.CloudLayer
import com.mikecann.walkies.map.CloudSprites
import com.mikecann.walkies.map.MapPoints
import com.mikecann.walkies.map.MapState
import com.mikecann.walkies.map.MapboxMap
import com.mikecann.walkies.map.StandInMap
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.CityBuilder
import com.mikecann.walkies.place.PlaceData
import com.mikecann.walkies.place.SpikeWalk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The spike's place: Geographe from the shared street-cache fixture, with a pretend walk down two of its streets. */
private suspend fun loadSpikePlace(context: Context): Pair<City, List<Coordinate>> = withContext(Dispatchers.Default) {
    val text = context.assets.open("places/geographe.json").bufferedReader().use { it.readText() }
    val data = PlaceData.parse(text)
    val city = CityBuilder.build(
        name = "Geographe", detail = "Busselton, Western Australia, Australia", osmId = null,
        boundary = data.boundary, ways = data.ways,
    )
    SpikeWalk.walk(city)
}

/** The map with the clouds over it and the buttons on top: ContentView.swift, as far as stage 1 goes. */
@Composable
fun MapScreen() {
    val context = LocalContext.current
    val state = remember { MapState() }
    val hasToken = BuildConfig.MAPBOX_ACCESS_TOKEN.isNotBlank()

    var city by remember { mutableStateOf<City?>(null) }
    var route by remember { mutableStateOf(DoubleArray(0)) }
    var field by remember { mutableStateOf(CloudField.empty) }
    var sprites by remember { mutableStateOf<CloudSprites?>(null) }
    var mapReady by remember { mutableStateOf(false) }
    var shown by remember { mutableStateOf(false) }
    /** Debug: tap a tile to clear it, or tap a clear one to cloud it over again. */
    var tapToClear by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { sprites = withContext(Dispatchers.Default) { CloudSprites.build() } }
    LaunchedEffect(Unit) {
        val (place, walk) = loadSpikePlace(context)
        city = place
        route = DoubleArray(walk.size * 2) { i ->
            val p = walk[i / 2]
            if (i % 2 == 0) MapPoints.x(p.lon) else MapPoints.y(p.lat)
        }
    }
    LaunchedEffect(city) {
        val place = city ?: return@LaunchedEffect
        field = withContext(Dispatchers.Default) { CloudField(listOf(place)) }
    }
    LaunchedEffect(city != null, mapReady) {
        val place = city
        if (place != null && mapReady && !shown) {
            shown = true
            state.controller?.show(place, animated = false)
        }
    }

    val onTap: (Coordinate) -> Unit = tap@{ coordinate ->
        val place = city ?: return@tap
        if (!tapToClear) return@tap
        val hex = HexGrid.hex(containing = coordinate)
        city = if (hex in place.visited) {
            place.copy(visited = place.visited - hex)
        } else {
            place.visit(listOf(coordinate), place.shape()).first
        }
    }

    Box(Modifier.fillMaxSize()) {
        if (hasToken) {
            MapboxMap(state, onTap, onReady = { mapReady = true }, modifier = Modifier.fillMaxSize())
        } else {
            StandInMap(state, onTap, onReady = { mapReady = true })
        }
        CloudLayer(field, state, sprites, route)

        // Keeps the status bar readable over dark water.
        Box(
            Modifier
                .fillMaxWidth()
                .height(100.dp)
                .background(Brush.verticalGradient(listOf(Walkies.cream.copy(alpha = 0.85f), Walkies.cream.copy(alpha = 0f)))),
        )

        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 16.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PlaceChip(city, onChangePlace = {})
            }
            Spacer(Modifier.weight(1f).widthIn(min = 12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                HexBadge(BadgeIcon.Art("icon-gear"), "Settings") {}
                HexBadge(BadgeIcon.Art("icon-book"), "Secrets") {}
                HexBadge(BadgeIcon.Art("icon-idea"), "Suggest a feature") {}
            }
        }

        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        ) {
            if (!hasToken) MissingToken()
            Row(verticalAlignment = Alignment.Bottom) {
                StickerPill(if (tapToClear) "Tap tiles to clear: on" else "Tap tiles to clear: off", tapToClear) { tapToClear = !tapToClear }
                Spacer(Modifier.weight(1f))
                HexBadge(BadgeIcon.Location, "Where am I", fill = Walkies.badgeTeal) {
                    // No location until stage 2, so this goes back to the place.
                    city?.let { state.controller?.show(it, animated = true) }
                }
            }
        }
    }
}

@Composable
private fun MissingToken() {
    val rounded = roundedFont()
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .stickerCard(RoundedCornerShape(24.dp))
            .padding(horizontal = 18.dp, vertical = 14.dp),
    ) {
        BasicText(
            "No map yet",
            style = Type.headline.copy(fontFamily = rounded, fontWeight = FontWeight.Black, fontSize = 20.sp),
        )
        BasicText(
            "Add MAPBOX_ACCESS_TOKEN to android/local.properties, then build again.",
            style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.75f), textAlign = TextAlign.Center),
        )
    }
}
