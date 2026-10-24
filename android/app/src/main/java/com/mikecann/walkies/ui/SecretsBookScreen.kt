package com.mikecann.walkies.ui

import android.content.Context
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.border
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import com.mikecann.walkies.AppModel
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.lore.SecretsBook
import kotlin.math.max
import kotlin.math.min

/**
 * The secrets book, a tab of its own (StickerBookView in Stickers.swift): every secret in the library,
 * grouped by area, nearest first. Areas start collapsed except the one you're in,
 * and load six at a time as you scroll. Sort and filter stick between visits.
 */
@Composable
fun SecretsBookScreen(model: AppModel, onOpen: (LoreEntry) -> Unit) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("walkies", Context.MODE_PRIVATE) }
    var sort by remember { mutableStateOf(SecretsBook.Sort.from(prefs.getString("secretsBookSort", null))) }
    var filter by remember { mutableStateOf(SecretsBook.Filter.from(prefs.getString("secretsBookFilter", null))) }
    var expanded by rememberSaveable(stateSaver = listSaver<Set<String>, String>({ it.toList() }, { it.toSet() })) { mutableStateOf(emptySet<String>()) }
    var menuOpen by remember { mutableStateOf(false) }
    val revision = rememberRevision(model::listen)

    val entries = LoreLibrary.all
    val selectedName = model.selectedCity?.name
    val currentArea = remember(selectedName) { SecretsBook.currentAreaName(entries, selectedName) }
    LaunchedEffect(currentArea) { currentArea?.let { expanded = expanded + it } }
    val found = entries.count { model.foundStickers[it.id] != null }
    val areas = remember(revision, sort, filter) {
        SecretsBook.sections(
            entries, model.foundStickers, model.lastLocation?.coordinate, model.cities, model.selectedCity, sort, filter,
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Walkies.cream)
            .statusBarsPadding(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            Spacer(Modifier.weight(1f))
            BasicText("Secrets", style = Type.headline)
            Row(
                horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.weight(1f),
            ) {
                Box {
                    FilterIcon(
                        Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable(role = Role.Button) { menuOpen = true }
                            .semantics { contentDescription = "Sort and filter" }
                            .padding(6.dp)
                            .size(20.dp),
                    )
                    if (menuOpen) {
                        SortMenu(
                            sort, filter,
                            onSort = { sort = it; prefs.edit().putString("secretsBookSort", it.key).apply() },
                            onFilter = { filter = it; prefs.edit().putString("secretsBookFilter", it.key).apply() },
                            onDismiss = { menuOpen = false },
                        )
                    }
                }
            }
        }

        // A new sort or filter starts again from the top with the first six.
        key(sort, filter) {
            var visibleCount by rememberSaveable { mutableIntStateOf(6) }
            val shown = areas.take(visibleCount)
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(24.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 16.dp + LocalTabBarClearance.current),
                modifier = Modifier.fillMaxSize(),
            ) {
                item(key = "cover") {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth().secretsCover(model.equipped.cover).padding(20.dp),
                    ) {
                        BasicText("$found of ${entries.size} secrets found", style = heavy(22))
                        ProgressBar(if (entries.isEmpty()) 0.0 else found.toDouble() / entries.size, Modifier.fillMaxWidth())
                        BasicText(
                            "Each one is a story about the area, hidden somewhere under the clouds. Walk new streets to find them.",
                            style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.6f)),
                        )
                    }
                }
                items(shown, key = { it.id }) { area ->
                    // Append a batch when the last area scrolls into view.
                    if (area.id == shown.lastOrNull()?.id && visibleCount < areas.size) {
                        LaunchedEffect(area.id, visibleCount) { visibleCount = min(visibleCount + 6, areas.size) }
                    }
                    AreaSection(
                        area,
                        isExpanded = area.id in expanded,
                        isFound = { model.foundStickers[it.id] != null },
                        onToggle = { expanded = if (area.id in expanded) expanded - area.id else expanded + area.id },
                        onOpen = onOpen,
                    )
                }
                if (visibleCount < areas.size) {
                    item(key = "more") {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Spinner(18.dp, Walkies.burnt)
                            BasicText("Loading more…", style = Type.subheadline)
                        }
                    }
                }
                if (areas.isEmpty()) {
                    item(key = "empty") {
                        EmptyState(
                            if (filter == SecretsBook.Filter.Found) "No secrets found yet" else "No secrets to show",
                            if (filter == SecretsBook.Filter.Found) "Walk new streets to find your first secret."
                            else "Try another filter to see more secrets.",
                            Modifier.fillMaxWidth().padding(top = 24.dp),
                        )
                    }
                }
            }
        }
    }
}

private fun heavy(size: Int) = Type.headline.copy(fontWeight = FontWeight.Black, fontSize = size.sp)

/**
 * The book's cover card in the equipped cover (SecretsCover in CosmeticArt.swift). The
 * free red cover is the plain sticker card; the shop's covers show their art under a
 * cream wash, so the writing on it stays easy to read.
 */
@Composable
private fun Modifier.secretsCover(equipped: String): Modifier {
    val shape = RoundedCornerShape(24.dp)
    val art = when (equipped) {
        "cover.seashell" -> "progress-cover-seashell"
        "cover.map" -> "progress-cover-map"
        "cover.gold" -> "progress-cover-gold"
        else -> null
    }
    val image = art?.let { assetImage(it) } ?: return stickerCard(shape)
    return this
        .softShadow(shape, 8.dp, 3.dp, 0.18f, Walkies.cream)
        .clip(shape)
        .drawBehind {
            // Fill the card, cropping the art's overflow, as scaledToFill does.
            val scale = maxOf(size.width / image.width, size.height / image.height)
            val w = image.width * scale
            val h = image.height * scale
            drawImage(
                image,
                dstOffset = androidx.compose.ui.unit.IntOffset(((size.width - w) / 2).toInt(), ((size.height - h) / 2).toInt()),
                dstSize = androidx.compose.ui.unit.IntSize(w.toInt(), h.toInt()),
            )
            drawRect(Walkies.cream.copy(alpha = 0.68f))
        }
        .border(3.dp, Color.White, shape)
}

@Composable
private fun AreaSection(
    area: SecretsBook.Area,
    isExpanded: Boolean,
    isFound: (LoreEntry) -> Boolean,
    onToggle: () -> Unit,
    onOpen: (LoreEntry) -> Unit,
) {
    val rounded = roundedFont()
    val turn by animateFloatAsState(if (isExpanded) 90f else 0f, tween(200), label = "chevron")
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .stickerCard(RoundedCornerShape(20.dp))
                .clip(RoundedCornerShape(20.dp))
                .clickable(role = Role.Button, onClick = onToggle)
                .semantics { stateDescription = if (isExpanded) "Expanded" else "Collapsed" }
                .padding(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BasicText(area.name, style = heavy(22).copy(fontFamily = rounded), modifier = Modifier.weight(1f))
                ChevronRight(Modifier.size(12.dp).rotate(turn))
            }
            Row {
                val small = Type.caption.copy(fontWeight = FontWeight.SemiBold, color = Walkies.ink.copy(alpha = 0.6f))
                BasicText("${area.found} of ${area.total} found", style = small, modifier = Modifier.weight(1f))
                area.distance?.let { BasicText("${Format.distance(it)} away", style = small) }
            }
            ProgressBar(area.progress, Modifier.fillMaxWidth())
            if (!area.isAdded) {
                BasicText(
                    "Not one of your places yet. Add it from the map to start finding these.",
                    style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.6f)),
                )
            }
        }
        // Don't build the tiles or load their images until this area is opened.
        if (isExpanded) StickerGrid(area.entries, isFound, onOpen)
    }
}

/** Sticker tiles, as many across as fit at 100 dp or more each (an adaptive LazyVGrid). */
@Composable
fun StickerGrid(entries: List<LoreEntry>, isFound: (LoreEntry) -> Boolean, onOpen: (LoreEntry) -> Unit, rowSpacing: Int = 20) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val spacing = 12.dp
        val columns = max(1, ((maxWidth + spacing) / (100.dp + spacing)).toInt())
        Column(verticalArrangement = Arrangement.spacedBy(rowSpacing.dp)) {
            for (row in entries.chunked(columns)) {
                Row(horizontalArrangement = Arrangement.spacedBy(spacing), verticalAlignment = Alignment.Top) {
                    for (entry in row) {
                        val found = isFound(entry)
                        Box(Modifier.weight(1f)) {
                            StickerTile(entry, found, Modifier.pressScale({ onOpen(entry) }, enabled = found))
                        }
                    }
                    repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun StickerTile(entry: LoreEntry, found: Boolean, modifier: Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        if (found) StickerArt(entry, 88.dp) else StickerSilhouette(entry, 88.dp)
        BasicText(
            if (found) entry.title else "???",
            style = Type.caption.copy(
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                color = if (found) Walkies.ink else Walkies.ink.copy(alpha = 0.3f),
            ),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** SF Symbols' line.3.horizontal.decrease. */
@Composable
private fun FilterIcon(modifier: Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val stroke = 2.dp.toPx()
        drawLine(Walkies.burnt, androidx.compose.ui.geometry.Offset(0f, h * 0.2f), androidx.compose.ui.geometry.Offset(w, h * 0.2f), stroke, StrokeCap.Round)
        drawLine(Walkies.burnt, androidx.compose.ui.geometry.Offset(w * 0.18f, h * 0.5f), androidx.compose.ui.geometry.Offset(w * 0.82f, h * 0.5f), stroke, StrokeCap.Round)
        drawLine(Walkies.burnt, androidx.compose.ui.geometry.Offset(w * 0.36f, h * 0.8f), androidx.compose.ui.geometry.Offset(w * 0.64f, h * 0.8f), stroke, StrokeCap.Round)
    }
}

/** The Sort and Show pickers, as a menu card under the button (a SwiftUI Menu). */
@Composable
private fun SortMenu(
    sort: SecretsBook.Sort,
    filter: SecretsBook.Filter,
    onSort: (SecretsBook.Sort) -> Unit,
    onFilter: (SecretsBook.Filter) -> Unit,
    onDismiss: () -> Unit,
) {
    val below = with(LocalDensity.current) { 36.dp.roundToPx() }
    Popup(alignment = Alignment.TopEnd, offset = IntOffset(0, below), onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .width(230.dp)
                .stickerCard(RoundedCornerShape(16.dp))
                .padding(vertical = 6.dp),
        ) {
            MenuHeader("Sort")
            for (option in SecretsBook.Sort.entries) MenuRow(option.title, option == sort) { onSort(option); onDismiss() }
            Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).height(1.dp).background(Walkies.ink.copy(alpha = 0.08f)))
            MenuHeader("Show")
            for (option in SecretsBook.Filter.entries) MenuRow(option.title, option == filter) { onFilter(option); onDismiss() }
        }
    }
}

@Composable
private fun MenuHeader(title: String) {
    BasicText(
        title,
        style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.5f)),
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
}

@Composable
private fun MenuRow(title: String, checked: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .widthIn(min = 200.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        BasicText(if (checked) "✓" else "", style = Type.body.copy(color = Walkies.burnt), modifier = Modifier.width(22.dp))
        BasicText(title, style = Type.body)
    }
}
