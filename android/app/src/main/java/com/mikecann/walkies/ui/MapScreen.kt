package com.mikecann.walkies.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.AppModel
import com.mikecann.walkies.BuildConfig
import com.mikecann.walkies.LocationAccess
import com.mikecann.walkies.location.LocationTracker
import com.mikecann.walkies.map.CloudField
import com.mikecann.walkies.map.CloudLayer
import com.mikecann.walkies.map.CloudSprites
import com.mikecann.walkies.map.MapCosmetics
import com.mikecann.walkies.map.SpyglassRing
import com.mikecann.walkies.model.Progression
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalContext
import com.mikecann.walkies.map.MapPoints
import com.mikecann.walkies.map.MapState
import com.mikecann.walkies.map.MapboxMap
import com.mikecann.walkies.map.NeighbourLayer
import com.mikecann.walkies.map.StandInMap
import com.mikecann.walkies.map.StickerPin
import com.mikecann.walkies.map.StickerPinLayer
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.map.YouAreHere
import com.mikecann.walkies.place.Mist
import com.mikecann.walkies.place.PlaceResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The map with the clouds over it and the buttons on top: MapScreen in ContentView.swift,
 * with found secrets pinned on it. The first tab, and it stays put under the others. With no places yet the map's just the world, and the place chip
 * leads to adding one, as on the iPhone.
 */
@Composable
fun MapScreen(
    model: AppModel,
    tracker: LocationTracker,
    /** Why always-on can't notice walks with the app closed, if it can't. */
    alwaysOnWarning: String?,
    /** Whoever's signed in, for your head on the place chip. */
    name: String?,
    picture: String?,
    /** Where adding a neighbour runs, so it carries on if the screen goes. */
    scope: CoroutineScope,
    /** The map's tab is showing. Under another tab the clouds stop drifting. */
    active: Boolean,
    onOpenSettings: () -> Unit,
    onShowPlaces: () -> Unit,
    onFixPermissions: () -> Unit,
    /** The "new secrets in places you've walked" card: the secrets tab. */
    onShowSecrets: () -> Unit,
    /** The shells chip: the progress tab. */
    onShowProgress: () -> Unit,
    /** A found secret's pin on the map, tapped to read it again. */
    onOpenSecret: (LoreEntry) -> Unit,
) {
    val state = remember { MapState() }
    val hasToken = BuildConfig.MAPBOX_ACCESS_TOKEN.isNotBlank()
    val haptics = LocalHapticFeedback.current

    // The model isn't Compose state, so it says when it's changed.
    var revision by remember { mutableIntStateOf(0) }
    DisposableEffect(model) {
        val stop = model.listen { revision++ }
        onDispose { stop() }
    }
    @Suppress("UNUSED_EXPRESSION") revision

    var field by remember { mutableStateOf(CloudField.empty) }
    var sprites by remember { mutableStateOf<CloudSprites?>(null) }
    var mapReady by remember { mutableStateOf(false) }
    /** Keeping you mid-screen as you walk, until you move the map yourself. */
    var following by remember { mutableStateOf(false) }
    /** Opening the app goes to where you are, once there's a fix. */
    var arriving by remember { mutableStateOf(true) }
    var flown by remember { mutableIntStateOf(model.flyToSelected) }
    val you = remember { YouAreHere() }
    state.onUserMove = { following = false }

    // The equipped look from the shop: the clouds' colours, the trail, the marker.
    val equipped = model.equipped
    LaunchedEffect(equipped.clouds) { sprites = withContext(Dispatchers.Default) { CloudSprites.forTheme(equipped.clouds) } }
    // The spyglass's ring, checked every second so it goes when it runs out.
    var ring by remember { mutableStateOf(model.activeSpyglassRing) }
    LaunchedEffect(Unit) {
        while (true) {
            val now = model.activeSpyglassRing
            if (now != ring) ring = now
            delay(1000)
        }
    }
    val context = LocalContext.current
    val cosmetics = remember(equipped.trail, equipped.marker, ring) { mapCosmetics(context, equipped.trail, equipped.marker, ring) }

    /** A suburb next door you've tapped, waiting for you to confirm adding it. */
    var pickedNeighbour by remember { mutableStateOf<PlaceResult?>(null) }
    /** What's happening while a suburb from the map is being added. */
    var addingStatus by remember { mutableStateOf<String?>(null) }
    var addingError by remember { mutableStateOf<String?>(null) }
    /** Where the buttons over the map are, so the neighbour labels keep out from under them. */
    val buttonFrames = remember { mutableStateMapOf<String, Rect>() }

    /** Fetches a neighbouring suburb's streets and adds it on the world grid. */
    fun add(place: PlaceResult) {
        addingStatus = "Getting ${place.name} ready…"
        scope.launch {
            try {
                model.addPlace(place) { addingStatus = it }
            } catch (e: CancellationException) {
                // Signed out meanwhile.
            } catch (e: Exception) {
                addingError = "Couldn't load the streets for ${place.name}. OpenStreetMap might be busy, so try again in a minute."
            }
            addingStatus = null
        }
    }

    val cities = model.cities
    val fresh = model.freshTiles
    // Ticks over as often as walked tiles could newly mist over while the map's open.
    val mistDays = model.mistDays
    var mistEpoch by remember { mutableLongStateOf(Mist.epoch(System.currentTimeMillis() / 1000.0, mistDays)) }
    LaunchedEffect(mistDays) {
        while (true) {
            mistEpoch = Mist.epoch(System.currentTimeMillis() / 1000.0, mistDays)
            delay(15_000)
        }
    }
    LaunchedEffect(model.tilesRevision, cities.size, mistEpoch) {
        val walkTiles = fresh.values.flatten().toSet()
        val now = System.currentTimeMillis() / 1000.0
        field = withContext(Dispatchers.Default) { CloudField(cities, walkTiles, mistAt = now, mistDays = mistDays) }
    }
    LaunchedEffect(model.revealCount) {
        if (model.revealCount > 0) haptics.performHapticFeedback(HapticFeedbackType.Confirm)
    }

    val path = model.activePath
    val route = remember(path) {
        DoubleArray(path.size * 2) { i ->
            val p = path[i / 2]
            if (i % 2 == 0) MapPoints.x(p.lon) else MapPoints.y(p.lat)
        }
    }
    // Tiles uncovered this walk, outlined in orange under the clouds.
    val freshOutlines = remember(fresh, model.tilesRevision) {
        cities.flatMap { city -> fresh[city.id].orEmpty().filter { it in city.visited } }.distinct().map { CloudField.corners(it) }
    }
    // Found secrets in every place, pinned on the tile they were under.
    val pins = remember(model.tilesRevision, model.foundStickers) {
        cities.flatMap { city ->
            city.stickers.orEmpty()
                .filter { model.foundStickers[it.key] != null }
                .toSortedMap()
                .mapNotNull { (id, hex) ->
                    LoreLibrary.entry(id)?.let { StickerPin(it, city.grid.projection.unproject(city.grid.centre(hex))) }
                }
        }
    }
    val here = model.lastLocation
    you.set(here?.lat, here?.lon, here?.accuracy ?: 0.0)

    // Opening the app goes to where you are, or the selected place if there's no fix in a few seconds.
    LaunchedEffect(mapReady) {
        if (!mapReady) return@LaunchedEffect
        val waitUntil = System.nanoTime() + 4_000_000_000L
        while (arriving && tracker.authorization == LocationAccess.Authorization.Allowed && System.nanoTime() < waitUntil) {
            val fix = model.lastLocation
            if (fix != null) {
                arriving = false
                state.controller?.lookAt(fix.coordinate, 1500.0, animated = false)
                return@LaunchedEffect
            }
            delay(200)
        }
        if (arriving) {
            arriving = false
            model.selectedCity?.let { state.controller?.show(it, animated = false) }
        }
    }
    // Picking or adding a place flies there.
    LaunchedEffect(model.flyToSelected, mapReady) {
        if (!mapReady || model.flyToSelected == flown) return@LaunchedEffect
        flown = model.flyToSelected
        following = false
        arriving = false
        model.selectedCity?.let { state.controller?.show(it, animated = true) }
    }
    LaunchedEffect(here) {
        if (following && here != null) state.controller?.lookAt(here.coordinate, null, animated = true)
    }

    /** Where am I: street level, where you can see the dotted roads to head for, and keep following. */
    fun focusOnYou() {
        following = true
        arriving = false
        val fix = model.lastLocation ?: return
        val controller = state.controller ?: return
        controller.lookAt(fix.coordinate, if (controller.cameraDistance > 900) 900.0 else null, animated = true)
    }

    Box(Modifier.fillMaxSize()) {
        if (hasToken) {
            // It ends at the tab bar, so its logo goes along the bottom with no room for the phone's bar.
            MapboxMap(state, onTap = {}, onReady = { mapReady = true }, modifier = Modifier.fillMaxSize(), systemBarInset = false)
        } else {
            StandInMap(state, onTap = {}, onReady = { mapReady = true })
        }
        CloudLayer(field, state, sprites, route, freshOutlines, you, cosmetics = cosmetics, animate = active)
        StickerPinLayer(pins, state, onPick = onOpenSecret)
        NeighbourLayer(
            neighbours = if (addingStatus == null) model.neighbours else emptyList(),
            state = state,
            avoid = buttonFrames.values.toList(),
            onPick = { pickedNeighbour = it },
        )

        // Keeps the status bar readable over dark water.
        Box(
            Modifier
                .fillMaxWidth()
                .height(100.dp)
                .background(Brush.verticalGradient(listOf(Walkies.cream.copy(alpha = 0.85f), Walkies.cream.copy(alpha = 0f)))),
        )

        // Settings and the secrets book are tabs now, and Chef is iPhone-only, so it's just the chips up here.
        Box(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(start = 16.dp, end = 28.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.mapButton("top leading", buttonFrames)) {
                val hidden = model.stickersHere
                val secrets = if (hidden.isEmpty()) null else hidden.count { model.foundStickers[it.first.id] != null } to hidden.size
                PlaceChip(model.selectedCity, name, picture, secrets, onChangePlace = onShowPlaces)
                LiveShellsChip(model, onShowProgress)
            }
        }

        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                // Clear of the Mapbox logo and attribution along the bottom of the map.
                .padding(start = 16.dp, end = 16.dp, bottom = 32.dp)
                .mapButton("bottom", buttonFrames),
        ) {
            if (!hasToken) MissingToken()
            AnimatedVisibility(
                model.secretsAlreadyWalked > 0,
                enter = fadeIn() + scaleIn(initialScale = 0.8f),
                exit = fadeOut() + scaleOut(targetScale = 0.8f),
            ) {
                // Keeps showing the last count while it shrinks away.
                var count by remember { mutableIntStateOf(model.secretsAlreadyWalked) }
                if (model.secretsAlreadyWalked > 0) count = model.secretsAlreadyWalked
                NewSecretsBadge(
                    count,
                    onOpen = {
                        model.dismissSecretsAlreadyWalked()
                        onShowSecrets()
                    },
                    onClose = model::dismissSecretsAlreadyWalked,
                )
            }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                WalkControls(
                    walk = model.activeWalk,
                    pendingDistance = if (model.autoWalkPending) model.pendingWalkDistance else null,
                    alwaysOn = model.alwaysOn,
                    locationDenied = tracker.isDenied,
                    alwaysOnWarning = alwaysOnWarning,
                    onStart = {
                        model.startWalk()
                        focusOnYou()
                    },
                    onEnd = { if (model.activeWalk?.isAutomatic == true) model.endAutoWalk() else model.endWalk() },
                    onOpenSettings = onOpenSettings,
                    onFixPermissions = onFixPermissions,
                    modifier = Modifier.weight(1f),
                )
                HexBadge(BadgeIcon.Location, "Where am I", fill = Walkies.badgeTeal) { focusOnYou() }
            }
        }

        addingStatus?.let { BuildingCard(it, "This can take up to a minute.", Modifier.align(Alignment.Center)) }
    }

    pickedNeighbour?.let { place ->
        WalkiesDialog(
            "Add ${place.name}?",
            "${place.summary}. It'll go under the clouds next to your other places, and any walks you've already done there count.",
            listOf(DialogButton("Add ${place.name}", bold = true) { add(place) }, DialogButton("Not now")),
            onDismiss = { pickedNeighbour = null },
        )
    }
    addingError?.let {
        WalkiesDialog("Couldn't add it", it, listOf(DialogButton("OK", bold = true)), onDismiss = { addingError = null })
    }
}

/** The shells chip, read again every 30 seconds so a new week's quests or a new day show. */
@Composable
private fun LiveShellsChip(model: AppModel, onClick: () -> Unit) {
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            tick++
        }
    }
    @Suppress("UNUSED_EXPRESSION") tick
    ShellsChip(model.balance, model.level, model.pendingPicks.isNotEmpty(), onClick)
}

/** The map's cosmetics, with the equipped marker's art and the trail's footprint loaded from the assets. */
fun mapCosmetics(context: android.content.Context, trail: String, marker: String, ring: Progression.Ring?): MapCosmetics {
    val art = when (marker) {
        "marker.sneaker" -> "progress-marker-sneaker"
        "marker.boat" -> "progress-marker-boat"
        "marker.hat" -> "progress-marker-hat"
        "marker.lighthouse" -> "progress-marker-lighthouse"
        else -> null
    }
    return MapCosmetics(
        trail = trail,
        marker = art?.let { loadAssetImage(context, it)?.asAndroidBitmap() },
        footprint = if (trail == "trail.footprints") loadAssetImage(context, "progress-footprint")?.asAndroidBitmap() else null,
        spyglass = ring?.let { loadAssetImage(context, "progress-spyglass")?.asAndroidBitmap() },
        ring = ring?.let { SpyglassRing(it.centre.lat, it.centre.lon, it.radius) },
    )
}

/**
 * Secrets that turned up under tiles you'd already walked, all at once (issue #10).
 * Tap to see them in the book. NewSecretsBadge in ContentView.swift.
 */
@Composable
private fun NewSecretsBadge(count: Int, onOpen: () -> Unit, onClose: () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.stickerCard(shape).padding(end = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .weight(1f, fill = false)
                .pressScale(onOpen)
                .padding(start = 8.dp, top = 7.dp, bottom = 7.dp),
        ) {
            AssetIcon("icon-book", 26.dp)
            BasicText(
                if (count == 1) "A new secret in places you've walked" else "$count new secrets in places you've walked",
                style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold),
            )
        }
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .clickable(role = Role.Button, onClick = onClose)
                .semantics { contentDescription = "Dismiss" },
        ) {
            Cross(Modifier.size(10.dp), Walkies.ink.copy(alpha = 0.5f))
        }
    }
}

/** Tells the map where this button sits, so the labels on the map keep clear of it. */
private fun Modifier.mapButton(key: String, frames: MutableMap<String, Rect>) =
    onGloballyPositioned { frames[key] = it.boundsInRoot() }

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
