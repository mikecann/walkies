package com.mikecann.walkies.ui

import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.AppModel
import com.mikecann.walkies.BuildConfig
import com.mikecann.walkies.grid.LocalProjection
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.map.CloudPainter
import com.mikecann.walkies.map.MapPoints
import com.mikecann.walkies.map.MapState
import com.mikecann.walkies.map.MapboxMap
import com.mikecann.walkies.map.Projection
import com.mikecann.walkies.map.StandInMap
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.Walk
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/**
 * A full-screen page with a title, like a NavigationStack: pushed ones have a back
 * button, the Walks tab's own page doesn't.
 */
@Composable
private fun Page(back: String?, title: String, onBack: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Walkies.cream)
            .statusBarsPadding(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp)) {
            Box(Modifier.weight(1f)) {
                if (back != null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable(role = Role.Button, onClick = onBack)
                            .padding(6.dp),
                    ) {
                        // chevron.left: the right one, mirrored.
                        ChevronRight(Modifier.size(12.dp, 18.dp).graphicsLayer { scaleX = -1f }, Walkies.burnt)
                        BasicText(back, style = Type.body.copy(color = Walkies.burnt))
                    }
                }
            }
            BasicText(title, style = Type.headline, modifier = Modifier.padding(vertical = 6.dp))
            Spacer(Modifier.weight(1f))
        }
        content()
    }
}

private fun heavy(size: Int) = Type.headline.copy(fontWeight = FontWeight.Black, fontSize = size.sp)

private fun pattern(skeleton: String) = DateFormat.getBestDateTimePattern(Locale.getDefault(), skeleton)

private fun format(date: SwiftDate, skeleton: String): String =
    java.text.SimpleDateFormat(pattern(skeleton), Locale.getDefault()).format(Date((date.epochSeconds * 1000).toLong()))

/** The Walks tab (WalkHistoryView.swift): your totals, then every walk by month, newest first. */
@Composable
fun WalkHistoryScreen(model: AppModel, stepsToday: Int?, onRefreshSteps: () -> Unit, onOpen: (Walk) -> Unit) {
    androidx.compose.runtime.LaunchedEffect(Unit) { onRefreshSteps() }
    @Suppress("UNUSED_VARIABLE") val revision = rememberRevision(model::listen)
    val walks = model.walks
    val months = remember(walks) {
        val calendar = Calendar.getInstance()
        walks.groupBy { walk ->
            calendar.timeInMillis = (walk.startedAt.epochSeconds * 1000).toLong()
            calendar.get(Calendar.YEAR) * 12 + calendar.get(Calendar.MONTH)
        }.toSortedMap(compareByDescending { it }).map { (_, inMonth) -> inMonth.sortedByDescending { it.startedAt } }
    }
    val rounded = roundedFont()
    Page(null, "Past walks", onBack = {}) {
        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(20.dp),
            contentPadding = PaddingValues(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 16.dp + LocalTabBarClearance.current),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "totals") {
                Column(
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    modifier = Modifier.fillMaxWidth().stickerCard(RoundedCornerShape(24.dp)).padding(20.dp),
                ) {
                    stepsToday?.let { BasicText("Steps today: ${java.text.NumberFormat.getIntegerInstance().format(it)}", style = Type.headline) }
                    BasicText("Every walk adds up", style = heavy(22).copy(fontFamily = rounded))
                    WalkStats(
                        listOf(
                            "Walks" to "${walks.size}",
                            "Distance" to Format.distance(walks.sumOf { it.distance }),
                            "Time" to Format.duration(walks.sumOf { it.duration() }),
                            "Tiles uncovered" to "${walks.sumOf { it.newTiles }}",
                        ),
                    )
                }
            }
            if (walks.isEmpty()) {
                item(key = "empty") {
                    EmptyState(
                        "No walks yet",
                        "Head out for a walk and you'll find it here when you're done.",
                        Modifier.fillMaxWidth().padding(top = 24.dp),
                    )
                }
            }
            for (month in months) {
                val first = month.first()
                item(key = "month-${first.id}") {
                    BasicText(
                        format(first.startedAt, "MMMMyyyy"),
                        style = heavy(20).copy(fontFamily = rounded),
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
                items(month, key = { it.id.toString() }) { walk -> WalkRow(walk) { onOpen(walk) } }
            }
        }
    }
}

@Composable
private fun WalkRow(walk: Walk, onClick: () -> Unit) {
    val context = LocalContext.current
    val rounded = roundedFont()
    val shape = RoundedCornerShape(22.dp)
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .pressScale(onClick)
            .stickerCard(shape)
            .padding(16.dp),
    ) {
        Box(
            Modifier
                .background(Walkies.sand.copy(alpha = 0.4f), RoundedCornerShape(16.dp))
                .padding(8.dp)
                .size(56.dp),
        ) {
            RouteSketch(walk, Modifier.fillMaxSize())
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
            BasicText(format(walk.startedAt, "EEEdMMM"), style = heavy(17).copy(fontFamily = rounded))
            BasicText(
                DateFormat.getTimeFormat(context).format(Date((walk.startedAt.epochSeconds * 1000).toLong())),
                style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                val strong = Type.subheadline.copy(fontWeight = FontWeight.SemiBold)
                BasicText(Format.distance(walk.distance), style = strong)
                BasicText(Format.duration(walk.duration()), style = strong)
            }
            BasicText(
                "${walk.newTiles} new ${if (walk.newTiles == 1) "tile" else "tiles"}",
                style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)),
            )
            walk.steps?.let { BasicText(Format.steps(it), style = Type.subheadline) }
            if (walk.isAutomatic) {
                BasicText(
                    "Always on",
                    style = Type.caption.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.background(Walkies.badgeGreen.copy(alpha = 0.4f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        }
        ChevronRight(Modifier.padding(top = 6.dp).size(10.dp, 14.dp), Walkies.badgeTeal)
    }
}

/**
 * The route's shape in local metres, north at the top. A straight line or a single
 * fix still fits without dividing by zero. RouteSketch in WalkHistoryView.swift.
 */
@Composable
private fun RouteSketch(walk: Walk, modifier: Modifier) {
    val first = walk.points.firstOrNull()
    if (first == null) {
        Box(modifier, contentAlignment = Alignment.Center) { AssetIcon("icon-walk", 32.dp) }
        return
    }
    val projected = remember(walk.id) {
        val projection = LocalProjection(first.coordinate)
        walk.points.map { projection.project(it.coordinate) }
    }
    Canvas(modifier.padding(3.dp)) {
        val minX = projected.minOf { it.x }
        val maxX = projected.maxOf { it.x }
        val minY = projected.minOf { it.y }
        val maxY = projected.maxOf { it.y }
        val scale = min(size.width, size.height) / max(max(maxX - minX, maxY - minY), 1.0)
        fun at(i: Int) = Offset(
            (size.width / 2 + (projected[i].x - (minX + maxX) / 2) * scale).toFloat(),
            (size.height / 2 - (projected[i].y - (minY + maxY) / 2) * scale).toFloat(),
        )
        val path = Path()
        val start = at(0)
        path.moveTo(start.x, start.y)
        for (i in 1 until projected.size) at(i).let { path.lineTo(it.x, it.y) }
        drawPath(path, Walkies.burnt, style = Stroke(3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        drawCircle(Walkies.burnt, 2.5.dp.toPx(), start)
    }
}

/** Two columns of big numbers with their labels underneath (WalkStats in WalkHistoryView.swift). */
@Composable
private fun WalkStats(items: List<Pair<String, String>>) {
    val rounded = roundedFont()
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        for (row in items.chunked(2)) {
            Row {
                for ((label, value) in row) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.weight(1f)) {
                        BasicText(value, style = heavy(20).copy(fontFamily = rounded, fontFeatureSettings = "tnum"))
                        BasicText(label, style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)))
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/**
 * One walk (WalkDetailView in WalkHistoryView.swift): a small map of the route, the
 * stats, a button to watch it again, and the secrets found on it.
 */
@Composable
fun WalkDetailScreen(model: AppModel, walkId: UUID, onWatch: (Walk) -> Unit, onOpenSecret: (LoreEntry) -> Unit, onBack: () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val revision = rememberRevision(model::listen)
    val walk = model.walks.firstOrNull { it.id == walkId }
    LaunchedEffect(walk == null) { if (walk == null) onBack() }
    walk ?: return
    val rounded = roundedFont()
    val context = LocalContext.current
    val secrets = remember(walk.id, model.foundStickers) {
        val end = walk.endedAt
        if (end == null) emptyList() else LoreLibrary.all.filter { entry ->
            val date = model.foundStickers[entry.id] ?: return@filter false
            date >= walk.startedAt && date <= end
        }.sortedWith(compareBy<LoreEntry>({ model.foundStickers[it.id] ?: SwiftDate.distantPast }, { it.id }))
    }

    Page("Past walks", "Your walk", onBack) {
        Column(
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 16.dp + LocalTabBarClearance.current),
        ) {
            if (walk.points.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxWidth().height(260.dp).stickerCard(RoundedCornerShape(24.dp)),
                ) {
                    EmptyState("No route saved", "This walk's stats are here, but it hasn't got any route points.")
                }
            } else {
                RouteMap(walk)
            }

            Column(
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxWidth().stickerCard(RoundedCornerShape(24.dp)).padding(20.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    BasicText(format(walk.startedAt, "EEEEdMMMMyyyy"), style = heavy(22).copy(fontFamily = rounded))
                    BasicText(
                        DateFormat.getTimeFormat(context).format(Date((walk.startedAt.epochSeconds * 1000).toLong())),
                        style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.6f)),
                    )
                }
                WalkStats(
                    listOf(
                        "Distance" to Format.distance(walk.distance),
                        "Time" to Format.duration(walk.duration()),
                        "New tiles" to "${walk.newTiles}",
                        "Recording" to if (walk.isAutomatic) "Always on" else "Started by you",
                    ),
                )
            }

            StickerButton(onClick = { onWatch(walk) }) {
                BasicText("▶  Watch this walk again", style = Type.headline.copy(color = Color.White))
            }

            if (secrets.isNotEmpty()) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    modifier = Modifier.fillMaxWidth().stickerCard(RoundedCornerShape(24.dp)).padding(20.dp),
                ) {
                    BasicText("Secrets found", style = heavy(22).copy(fontFamily = rounded))
                    StickerGrid(secrets, isFound = { true }, onOpen = onOpenSecret, rowSpacing = 16)
                }
            }
        }
    }
}

private val ROUTE_TEAL = Color(CloudPainter.TEAL)
private val ROUTE_HALO = Color(1f, 1f, 1f, CloudPainter.HALO_ALPHA.toFloat())
private val ROUTE_EDGE = Color(0.05f, 0.12f, 0.16f, CloudPainter.EDGE_ALPHA.toFloat())

/** The route on a small flat map, start in green and finish in orange. */
@Composable
private fun RouteMap(walk: Walk) {
    val state = remember { MapState() }
    var ready by remember { mutableStateOf(false) }
    val route = remember(walk.id) {
        DoubleArray(walk.points.size * 2) { i ->
            val p = walk.points[i / 2]
            if (i % 2 == 0) MapPoints.x(p.lon) else MapPoints.y(p.lat)
        }
    }
    LaunchedEffect(ready) {
        if (!ready) return@LaunchedEffect
        // Like the iPhone's region: the route with some room round it, and never closer than about 200 m.
        val lats = walk.points.map { it.lat }
        val lons = walk.points.map { it.lon }
        val south = lats.min()
        val north = lats.max()
        val west = lons.min()
        val east = lons.max()
        val latSpan = max(0.002, (north - south) * 1.3) / 2
        val lonSpan = max(0.002, (east - west) * 1.3) / 2
        val midLat = (south + north) / 2
        val midLon = (west + east) / 2
        state.controller?.frame(
            MapPoints.x(midLon - lonSpan), MapPoints.y(midLat + latSpan), MapPoints.x(midLon + lonSpan), MapPoints.y(midLat - latSpan),
            floatArrayOf(0f, 0f, 0f, 0f), 0.0, animated = false,
        )
    }
    val projection = remember { Projection() }
    val ground = remember { DoubleArray(10) }
    val path = remember { Path() }
    val shape = RoundedCornerShape(24.dp)
    Box(
        Modifier
            .fillMaxWidth()
            .height(300.dp)
            .clip(shape)
            .border(3.dp, Color.White, shape)
            .semantics { contentDescription = "Route for this walk" },
    ) {
        if (BuildConfig.MAPBOX_ACCESS_TOKEN.isNotBlank()) {
            MapboxMap(state, onTap = {}, onReady = { ready = true }, modifier = Modifier.fillMaxSize(), textureView = true)
        } else {
            StandInMap(state, onTap = {}, onReady = { ready = true })
        }
        Box(
            Modifier.fillMaxSize().drawBehind {
                state.cameraTick.longValue
                if (state.controller == null) return@drawBehind
                if (!state.measure(size.width, size.height, ground)) return@drawBehind
                projection.update(ground, size.width, size.height, ground[8], ground[9])
                if (!projection.valid || route.size < 2) return@drawBehind
                path.reset()
                for (i in 0 until route.size / 2) {
                    projection.point(route[i * 2], route[i * 2 + 1])
                    if (i == 0) path.moveTo(projection.x, projection.y) else path.lineTo(projection.x, projection.y)
                }
                // A light halo and a dark edge under the teal, so it shows over grass and water.
                drawPath(path, ROUTE_HALO, style = Stroke((5 + CloudPainter.HALO_EXTRA).dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                drawPath(path, ROUTE_EDGE, style = Stroke((5 + CloudPainter.EDGE_EXTRA).dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                drawPath(path, ROUTE_TEAL, style = Stroke(5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                fun dot(i: Int, colour: Color) {
                    projection.point(route[i * 2], route[i * 2 + 1])
                    val at = Offset(projection.x, projection.y)
                    drawCircle(Color.White, 8.5.dp.toPx(), at)
                    drawCircle(colour, 5.5.dp.toPx(), at)
                }
                dot(0, Walkies.badgeGreen)
                if (route.size >= 4) dot(route.size / 2 - 1, Walkies.burnt)
            },
        )
    }
}
