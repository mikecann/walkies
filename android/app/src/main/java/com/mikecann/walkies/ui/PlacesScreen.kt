package com.mikecann.walkies.ui

import android.content.Context
import android.location.Geocoder
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.mikecann.walkies.AppModel
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.CityBuilder
import com.mikecann.walkies.place.OSMClient
import com.mikecann.walkies.place.PlaceResult
import com.mikecann.walkies.place.percentText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

private val red = Color(0.85f, 0.2f, 0.17f)

/** Redraws whenever the model says it's changed: it isn't Compose state. */
@Composable
fun rememberRevision(listen: (() -> Unit) -> () -> Unit): Int {
    var revision by remember { mutableIntStateOf(0) }
    DisposableEffect(listen) {
        val stop = listen { revision++ }
        onDispose { stop() }
    }
    return revision
}

/**
 * Your places, to pick one, delete one, or add another (MapsAndPlacesView.swift).
 * With none yet, it says so and offers to add one (CitiesView.swift's empty state).
 */
@Composable
fun PlacesScreen(model: AppModel, onAddPlace: () -> Unit, onClose: () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val revision = rememberRevision(model::listen)
    var editing by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<City?>(null) }
    val cities = model.cities

    Column(
        Modifier
            .fillMaxSize()
            .background(Color.White)
            .background(Walkies.sand.copy(alpha = 0.45f))
            .systemBarsPadding()
            .padding(horizontal = 16.dp),
    ) {
        SheetBar(
            "Places",
            leading = if (!editing && cities.isNotEmpty()) "Edit" else null, onLeading = { editing = true },
            trailing = "Done", onTrailing = { if (editing) editing = false else onClose() },
        )
        Column(
            verticalArrangement = Arrangement.spacedBy(22.dp),
            modifier = Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp).widthIn(max = 600.dp),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth().stickerCard(RoundedCornerShape(24.dp)).padding(18.dp),
            ) {
                BasicText("Places", style = Type.headline)
                if (cities.isEmpty()) {
                    BasicText("No places yet", style = Type.body.copy(fontWeight = FontWeight.SemiBold))
                    BasicText(
                        "Add your suburb or town, then go for a walk to start uncovering it.",
                        style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.65f)),
                    )
                }
                for (city in cities) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        val selected = model.selectedCityId == city.id
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .weight(1f)
                                .heightIn(min = 44.dp)
                                .clickable(enabled = !editing, role = Role.Button) {
                                    model.select(city.id)
                                    onClose()
                                }
                                .semantics { contentDescription = city.name + if (selected) ", selected" else "" },
                        ) {
                            BasicText(city.name, style = Type.body, modifier = Modifier.weight(1f))
                            BasicText(city.progress.percentText, style = Type.body.copy(fontFeatureSettings = "tnum"))
                            if (selected && !editing) {
                                BasicText("✓", style = Type.body.copy(color = Walkies.burnt, fontWeight = FontWeight.Bold), modifier = Modifier.padding(start = 8.dp))
                            }
                        }
                        if (editing) {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(34.dp)
                                    .clip(CircleShape)
                                    .background(red)
                                    .clickable(role = Role.Button) { deleting = city }
                                    .semantics { contentDescription = "Delete ${city.name}" },
                            ) { Bin(Modifier.size(15.dp)) }
                        }
                    }
                }
            }
            StickerButton(onClick = onAddPlace) {
                BasicText("＋  Add a place", style = Type.headline.copy(color = Color.White))
            }
        }
    }

    deleting?.let { city ->
        WalkiesDialog(
            title = "Delete ${city.name}?",
            message = "Its tiles and secrets come off this map, here and on your other phones. Your walks are kept.",
            buttons = listOf(
                DialogButton("Delete ${city.name}", destructive = true) {
                    model.deleteCity(city.id)
                    if (model.cities.isEmpty()) editing = false
                },
                DialogButton("Keep it", bold = true),
            ),
            onDismiss = { deleting = null },
        )
    }
}

/** SF Symbols' trash.fill, white. */
@Composable
private fun Bin(modifier: Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val body = Path().apply {
            moveTo(w * 0.2f, h * 0.3f)
            lineTo(w * 0.8f, h * 0.3f)
            lineTo(w * 0.72f, h * 0.95f)
            lineTo(w * 0.28f, h * 0.95f)
            close()
        }
        drawPath(body, Color.White)
        drawLine(Color.White, Offset(w * 0.08f, h * 0.18f), Offset(w * 0.92f, h * 0.18f), strokeWidth = h * 0.1f, cap = StrokeCap.Round)
        drawLine(Color.White, Offset(w * 0.38f, h * 0.06f), Offset(w * 0.62f, h * 0.06f), strokeWidth = h * 0.1f, cap = StrokeCap.Round)
    }
}

/** A suggestion as you type, from the phone's geocoder (Apple's MKLocalSearchCompleter on the iPhone). */
data class PlaceSuggestion(val title: String, val subtitle: String)

/**
 * Suburbs, towns and cities matching what you've typed so far, from Android's
 * Geocoder, which (unlike Nominatim) is fine to ask as you type. Empty when the
 * phone hasn't got one.
 */
suspend fun suggestPlaces(context: Context, text: String): List<PlaceSuggestion> = withContext(Dispatchers.IO) {
    val query = text.trim()
    if (query.isEmpty() || !Geocoder.isPresent()) return@withContext emptyList()
    @Suppress("DEPRECATION")
    val addresses = runCatching { Geocoder(context, Locale.getDefault()).getFromLocationName(query, 10) }.getOrNull().orEmpty()
    addresses.mapNotNull { a ->
        val title = a.subLocality ?: a.locality ?: a.subAdminArea ?: a.adminArea ?: return@mapNotNull null
        val rest = listOfNotNull(a.locality, a.adminArea, a.countryName).filter { it != title }.distinct()
        PlaceSuggestion(title, rest.joinToString(", "))
    }.distinct().take(8)
}

/**
 * Finding a place to add (AddCityView.swift). Suggestions come up as you type, from
 * the phone's geocoder (OpenStreetMap's Nominatim asks apps not to search as you
 * type). Picking one looks up its boundary on OpenStreetMap, and if there's one
 * clear match it's added straight away; otherwise you choose. Search asks
 * OpenStreetMap directly.
 */
@Composable
fun AddPlaceScreen(model: AppModel, scope: CoroutineScope, onAdded: () -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val osm = remember { OSMClient() }
    var query by remember { mutableStateOf("") }
    var suggestions by remember { mutableStateOf<List<PlaceSuggestion>>(emptyList()) }
    /** Boundaries from OpenStreetMap, once you've picked a suggestion or pressed Search. */
    var results by remember { mutableStateOf<List<PlaceResult>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var buildStatus by remember { mutableStateOf<String?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }

    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    LaunchedEffect(query) {
        if (query.isBlank()) {
            suggestions = emptyList()
            return@LaunchedEffect
        }
        delay(350)
        suggestions = suggestPlaces(context.applicationContext, query)
    }

    fun add(place: PlaceResult) {
        errorMessage = null
        buildStatus = "Getting ${place.name} ready…"
        scope.launch {
            try {
                model.addPlace(place) { buildStatus = it }
                buildStatus = null
                onAdded()
            } catch (e: CancellationException) {
                buildStatus = null
            } catch (e: Exception) {
                buildStatus = null
                errorMessage = "Couldn't load the streets for ${place.name}. OpenStreetMap might be busy, so try again in a minute."
            }
        }
    }

    fun search(text: String, then: (List<PlaceResult>) -> Unit = {}) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        searching = true
        errorMessage = null
        scope.launch {
            try {
                val found = osm.searchPlaces(trimmed)
                results = found
                then(found)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                results = emptyList()
                errorMessage = "Search didn't work. Check your connection and try again."
            }
            searching = false
        }
    }

    /** A suggestion: find its boundary, and add it if it's clearly the one. */
    fun pick(suggestion: PlaceSuggestion) {
        val text = listOf(suggestion.title, suggestion.subtitle).filter { it.isNotEmpty() }.joinToString(", ")
        search(text) { found ->
            val name = suggestion.title.split(",").first().trim().lowercase()
            val usable = found.filter { it.area <= CityBuilder.MAX_AREA }
            val first = usable.firstOrNull()
            if (first != null && first.name.lowercase() == name && usable.drop(1).none { it.name.lowercase() == name }) add(first)
        }
    }

    Box(Modifier.fillMaxSize().background(Walkies.cream).systemBarsPadding().imePadding()) {
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.padding(horizontal = 16.dp)) {
                SheetBar("Add a place", leading = "‹ Places", onLeading = onBack, trailing = null, onTrailing = {})
                SearchField(
                    query,
                    onChange = {
                        query = it
                        results = null
                        errorMessage = null
                    },
                    onSearch = { search(query) },
                    modifier = Modifier.focusRequester(focus),
                )
            }
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                errorMessage?.let { message ->
                    item { BasicText("⚠︎ $message", style = Type.subheadline.copy(color = red), modifier = Modifier.padding(horizontal = 4.dp)) }
                }
                val found = results
                if (found != null) {
                    items(found, key = { it.id }) { place ->
                        val tooBig = place.area > CityBuilder.MAX_AREA
                        ResultRow(
                            title = place.name,
                            detail = place.detail,
                            note = if (tooBig) "${place.summary} · too big, try a suburb" else place.summary,
                            plus = true,
                            enabled = !tooBig && buildStatus == null,
                            dimmed = tooBig,
                        ) { add(place) }
                    }
                } else {
                    items(suggestions, key = { it.title + "|" + it.subtitle }) { suggestion ->
                        ResultRow(
                            title = suggestion.title, detail = suggestion.subtitle, note = null, plus = false,
                            enabled = !searching && buildStatus == null, dimmed = false,
                        ) { pick(suggestion) }
                    }
                }
            }
        }

        val found = results
        when {
            searching -> Box(Modifier.align(Alignment.Center)) { Spinner(36.dp) }
            found != null && found.isEmpty() && errorMessage == null -> EmptyState(
                "Nothing with a boundary",
                "OpenStreetMap doesn't have an outline for that. Try the suburb or town name on its own.",
                Modifier.align(Alignment.Center),
            )
            found == null && suggestions.isEmpty() && buildStatus == null -> EmptyState(
                "Find your patch",
                "Search for a suburb, town or city. Start small: a suburb is a few weeks of walks, a whole city is years.",
                Modifier.align(Alignment.Center),
            )
        }
        buildStatus?.let { BuildingCard(it, "This can take up to a minute for a big place.", Modifier.align(Alignment.Center)) }
    }
}

/** What's happening while a place is added, over everything else. */
@Composable
fun BuildingCard(status: String, note: String, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
        modifier = modifier
            .clickable(remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) {}
            .stickerCard(RoundedCornerShape(24.dp))
            .padding(28.dp),
    ) {
        Spinner(36.dp)
        BasicText(status, style = Type.headline)
        BasicText(note, style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)))
    }
}

@Composable
private fun SearchField(text: String, onChange: (String) -> Unit, onSearch: () -> Unit, modifier: Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Walkies.ink.copy(alpha = 0.07f))
            .padding(horizontal = 10.dp, vertical = 9.dp),
    ) {
        Magnifier(Modifier.size(17.dp))
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) BasicText("Suburb, town or city", style = Type.body.copy(color = Walkies.ink.copy(alpha = 0.4f)))
            BasicTextField(
                text, onChange,
                singleLine = true,
                textStyle = Type.body,
                cursorBrush = SolidColor(Walkies.burnt),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { onSearch() }),
                modifier = modifier.fillMaxWidth(),
            )
        }
        if (text.isNotEmpty()) {
            BasicText(
                "✕",
                style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.45f)),
                modifier = Modifier.clickable(role = Role.Button) { onChange("") }.semantics { contentDescription = "Clear" },
            )
        }
    }
}

@Composable
private fun Magnifier(modifier: Modifier) {
    Canvas(modifier) {
        val w = size.width
        val colour = Walkies.ink.copy(alpha = 0.45f)
        drawCircle(colour, radius = w * 0.32f, center = Offset(w * 0.42f, w * 0.42f), style = Stroke(w * 0.12f))
        drawLine(colour, Offset(w * 0.66f, w * 0.66f), Offset(w * 0.92f, w * 0.92f), strokeWidth = w * 0.13f, cap = StrokeCap.Round)
    }
}

/** One place to pick, as a full-width card that's easy to hit. */
@Composable
private fun ResultRow(title: String, detail: String, note: String?, plus: Boolean, enabled: Boolean, dimmed: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (dimmed) 0.5f else 1f)
            .stickerCard(shape)
            .clip(shape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(14.dp),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(44.dp, 48.dp).clip(Hexagon()).background(Walkies.badgeTeal)) {
            MapGlyph(Modifier.size(22.dp))
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
            BasicText(title, style = Type.headline)
            if (detail.isNotEmpty()) BasicText(detail, style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.65f)), maxLines = 2)
            note?.let { BasicText(it, style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.5f))) }
        }
        BasicText(if (plus) "＋" else "›", style = Type.headline.copy(color = Walkies.burnt, fontWeight = FontWeight.Bold))
    }
}

/** SF Symbols' map.fill: a folded map, white. */
@Composable
private fun MapGlyph(modifier: Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val fold = Path().apply {
            moveTo(w * 0.05f, h * 0.2f)
            lineTo(w * 0.35f, h * 0.08f)
            lineTo(w * 0.65f, h * 0.2f)
            lineTo(w * 0.95f, h * 0.08f)
            lineTo(w * 0.95f, h * 0.8f)
            lineTo(w * 0.65f, h * 0.92f)
            lineTo(w * 0.35f, h * 0.8f)
            lineTo(w * 0.05f, h * 0.92f)
            close()
        }
        drawPath(fold, Color.White)
        val crease = Walkies.badgeTeal
        drawLine(crease, Offset(w * 0.35f, h * 0.1f), Offset(w * 0.35f, h * 0.8f), strokeWidth = w * 0.06f)
        drawLine(crease, Offset(w * 0.65f, h * 0.2f), Offset(w * 0.65f, h * 0.9f), strokeWidth = w * 0.06f)
        drawPath(fold, Color.White, style = Stroke(w * 0.04f, join = StrokeJoin.Round))
    }
}
