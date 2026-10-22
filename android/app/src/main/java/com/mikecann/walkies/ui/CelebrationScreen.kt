package com.mikecann.walkies.ui

import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotateRad
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.BuildConfig
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.map.CloudField
import com.mikecann.walkies.map.CloudLayer
import com.mikecann.walkies.map.CloudSprites
import com.mikecann.walkies.map.CloudPainter
import com.mikecann.walkies.map.MapPoints
import com.mikecann.walkies.map.MapState
import com.mikecann.walkies.map.MapboxMap
import com.mikecann.walkies.map.Projection
import com.mikecann.walkies.map.SplitMix64
import com.mikecann.walkies.map.StandInMap
import com.mikecann.walkies.map.YouAreHere
import com.mikecann.walkies.model.LevelMeter
import com.mikecann.walkies.model.WalkRecap
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.percentText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The end-of-walk celebration (CelebrationView.swift). Your walk plays back over the
 * map: the route draws itself, the clouds clear tile by tile with a pop and a puff of
 * sparkles, and it stops for a moment on any secret you found. Then a summary of what
 * the walk did for each place, and roughly how many more it'll take to finish.
 * The summary also shows the shells and XP the walk earned and its quest progress,
 * filling the level bar a level at a time. Rewatched from history it's just the walk:
 * no rewards, and nothing changes.
 */
@Composable
fun CelebrationScreen(
    recap: WalkRecap,
    /** Your other places, unchanged by this walk, so they're still under cloud. */
    others: List<City>,
    /** The equipped celebration (confetti, bubbles or fireworks) and clouds. */
    style: String,
    clouds: String,
    /** Your lifetime XP now, after this walk. */
    endingXP: Int,
    /** A level-up reward is waiting to be chosen. */
    hasReward: Boolean,
    onReward: () -> Unit,
    onSecret: (LoreEntry) -> Unit,
    onDone: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val state = remember { MapState() }
    val player = remember(recap) { ReplayPlayer(recap, others) }
    val sounds = remember { SoundFX(context) }
    var sprites by remember { mutableStateOf<CloudSprites?>(null) }
    var mapReady by remember { mutableStateOf(false) }
    /** You've moved the map yourself, so offer to put it back on the walk. */
    var moved by remember { mutableStateOf(false) }
    val reduceMotion = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    state.onUserMove = { moved = true }
    player.sounds = sounds
    player.onPop = { haptics.performHapticFeedback(HapticFeedbackType.SegmentTick) }
    player.onSuccess = { haptics.performHapticFeedback(HapticFeedbackType.Confirm) }

    DisposableEffect(sounds) { onDispose { sounds.release() } }
    LaunchedEffect(Unit) {
        sprites = withContext(Dispatchers.Default) { CloudSprites.forTheme(clouds) }
        withContext(Dispatchers.Default) { sounds.prepare() }
    }
    LaunchedEffect(player.runs) { player.run() }

    /** Frames the walk, at least about 400 m across so a short one isn't zoomed right in. */
    fun frameWalk(animated: Boolean) {
        val points = recap.route.ifEmpty { recap.walk.points.map { it.coordinate } }
        val first = points.firstOrNull() ?: return
        var x0 = Double.POSITIVE_INFINITY
        var y0 = Double.POSITIVE_INFINITY
        var x1 = Double.NEGATIVE_INFINITY
        var y1 = Double.NEGATIVE_INFINITY
        for (p in points) {
            val x = MapPoints.x(p.lon)
            val y = MapPoints.y(p.lat)
            x0 = min(x0, x); x1 = max(x1, x)
            y0 = min(y0, y); y1 = max(y1, y)
        }
        val minimum = 400 * MapPoints.perMetre(first.lat)
        val growX = max(0.0, minimum - (x1 - x0)) / 2
        val growY = max(0.0, minimum - (y1 - y0)) / 2
        state.controller?.frame(x0 - growX, y0 - growY, x1 + growX, y1 + growY, floatArrayOf(130f, 40f, 280f, 40f), 45.0, animated)
    }
    LaunchedEffect(mapReady) { if (mapReady) frameWalk(animated = false) }
    BackHandler(onBack = onDone)

    Box(Modifier.fillMaxSize().background(Walkies.cream)) {
        if (BuildConfig.MAPBOX_ACCESS_TOKEN.isNotBlank()) {
            MapboxMap(state, onTap = {}, onReady = { mapReady = true }, modifier = Modifier.fillMaxSize())
        } else {
            StandInMap(state, onTap = {}, onReady = { mapReady = true })
        }
        CloudLayer(player.field, state, sprites, EMPTY_ROUTE, emptyList(), remember { YouAreHere() })
        ReplayEffects(recap, player, state, reduceMotion, style)

        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp),
        ) {
            TileCounter(player)
            Capsule {
                BasicText(
                    Format.duration(player.elapsed),
                    style = heavyRounded(22).copy(fontFamily = roundedFont(), fontFeatureSettings = "tnum"),
                    modifier = Modifier.semantics { contentDescription = "Time walked" },
                )
            }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (player.phase == ReplayPlayer.Phase.Replay) {
                    Capsule(Modifier.pressScale(player::skip)) {
                        BasicText("Skip", style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold), modifier = Modifier.padding(horizontal = 2.dp))
                    }
                }
                AnimatedVisibility(moved, enter = scaleIn() + fadeIn(), exit = scaleOut() + fadeOut()) {
                    HexBadge(BadgeIcon.Scope, "Back to the walk", fill = Walkies.badgeTeal) {
                        moved = false
                        frameWalk(animated = true)
                    }
                }
            }
        }

        // Keeps showing the last secret while it shrinks away.
        var lastSecret by remember { mutableStateOf<LoreEntry?>(null) }
        player.showingSecret?.let { lastSecret = it }
        AnimatedVisibility(
            player.showingSecret != null,
            enter = scaleIn(spring(dampingRatio = 0.75f, stiffness = 300f), initialScale = 0.4f) + fadeIn(),
            exit = scaleOut(targetScale = 0.4f) + fadeOut(),
            modifier = Modifier.align(Alignment.Center),
        ) {
            lastSecret?.let { SecretPop(it) }
        }

        AnimatedVisibility(
            player.phase == ReplayPlayer.Phase.Summary,
            enter = slideInVertically(spring(dampingRatio = 0.85f, stiffness = 300f)) { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            SummaryCard(
                recap, sounds, reduceMotion, endingXP, hasReward = hasReward && !recap.isRewatch,
                onReward = onReward, onSecret = onSecret, onReplay = player::replay, onDone = onDone,
            )
        }
    }
}

private val EMPTY_ROUTE = DoubleArray(0)

private fun heavyRounded(size: Int) = Type.headline.copy(fontWeight = FontWeight.Black, fontSize = size.sp)

/** A cream sticker capsule, for the counters and Skip. */
@Composable
private fun Capsule(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(modifier.stickerCard(RoundedCornerShape(50)).padding(horizontal = 16.dp, vertical = 8.dp)) { content() }
}

@Composable
private fun TileCounter(player: ReplayPlayer) {
    val rounded = roundedFont()
    // Flips size on each pop, to nudge it, like the iPhone's.
    val scale by animateFloatAsState(
        if (player.bump % 2 == 1) 1.12f else 1f, spring(dampingRatio = 0.5f, stiffness = 1500f), label = "bump",
    )
    Capsule(Modifier.scale(scale)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            BasicText(
                "+${player.tilesShown}",
                style = heavyRounded(22).copy(fontFamily = rounded, color = Walkies.orange, fontFeatureSettings = "tnum"),
            )
            BasicText(if (player.tilesShown == 1) "tile" else "tiles", style = Type.headline.copy(color = Walkies.ink.copy(alpha = 0.7f)))
        }
    }
}

/**
 * Runs the replay's clock: where along the route it's got, which tiles have popped,
 * which secret is showing, and which step of the clouds to draw. ReplayPlayer in
 * CelebrationView.swift.
 */
class ReplayPlayer(private val recap: WalkRecap, private val others: List<City>) {
    enum class Phase { Replay, Summary }

    /** Sparkles where a tile clears ([secret] false, at map point [x], [y]), or confetti for a secret. */
    class Burst(val secret: Boolean, val x: Double, val y: Double, val start: Long, val seed: Long)

    var phase by mutableStateOf(Phase.Replay)
        private set
    var progress by mutableDoubleStateOf(0.0)
        private set
    var tilesShown by mutableIntStateOf(0)
        private set
    var showingSecret by mutableStateOf<LoreEntry?>(null)
        private set
    /** The clouds start empty and fill in as soon as they're worked out, off the main thread. */
    var field by mutableStateOf(CloudField.empty)
        private set
    /** Goes up on each pop, to nudge the counter. */
    var bump by mutableIntStateOf(0)
        private set
    /** Goes up to start the replay again. */
    var runs by mutableIntStateOf(0)
        private set
    /** Read by the effects every frame, so not Compose state. */
    val bursts = ArrayList<Burst>()

    var sounds: SoundFX? = null
    var onPop: () -> Unit = {}
    var onSuccess: () -> Unit = {}

    private var fields: List<CloudField> = emptyList()
    private var cuts: List<Int> = emptyList()
    private var step = -1
    private var nextReveal = 0
    private var nextSecret = 0
    private var pausedUntil = 0L
    private var combo = 0
    private var lastPop = 0L
    private var lastHaptic = 0L
    private var generation = 0

    /**
     * Seconds for the route to draw: 5 for every 10 minutes walked. At least 2, so a
     * short walk is still watchable, and at most 30, so a long one doesn't drag.
     */
    val duration: Double get() = replayDuration(recap.walk.duration())

    /** Time into the walk at the replay's current point. */
    val elapsed: Double get() = recap.elapsed(progress)

    /** Plays it through. Stops early if [skip] or [replay] are called. */
    suspend fun run() {
        val thisRun = ++generation
        prepareClouds()
        delay(800)
        var last = System.nanoTime()
        while (thisRun == generation && phase == Phase.Replay) {
            val now = System.nanoTime()
            val dt = (now - last) / 1e9
            last = now
            if (now >= pausedUntil) {
                if (showingSecret != null) showingSecret = null
                progress = min(1.0, progress + dt / duration)
                fire(progress, now)
                if (progress >= 1 && nextSecret >= recap.secrets.size) {
                    delay(600)
                    if (thisRun != generation) return
                    finish()
                    return
                }
            }
            bursts.removeAll { (now - it.start) / 1e9 > 2.5 }
            withFrameNanos { }
        }
    }

    fun skip() {
        generation++
        progress = 1.0
        nextReveal = recap.reveals.size
        nextSecret = recap.secrets.size
        tilesShown = recap.reveals.size
        showingSecret = null
        if (fields.isNotEmpty()) show(fields.size - 1)
        finish()
    }

    fun replay() {
        generation++
        phase = Phase.Replay
        progress = 0.0
        nextReveal = 0
        nextSecret = 0
        tilesShown = 0
        combo = 0
        bursts.clear()
        pausedUntil = 0L
        if (fields.isNotEmpty()) show(0)
        runs++
    }

    private fun finish() {
        phase = Phase.Summary
        bursts.add(Burst(true, 0.0, 0.0, System.nanoTime(), 42_791))
        sounds?.play(SoundFX.Sound.Fanfare)
        onSuccess()
    }

    private fun fire(progress: Double, now: Long) {
        while (nextReveal < recap.reveals.size && recap.reveals[nextReveal].at <= progress) {
            val reveal = recap.reveals[nextReveal]
            nextReveal++
            tilesShown = nextReveal
            bump++
            combo = if (now - lastPop < 600_000_000L) combo + 1 else 0
            lastPop = now
            sounds?.play(SoundFX.Sound.Pop(combo))
            if (now - lastHaptic > 70_000_000L) {
                onPop()
                lastHaptic = now
            }
            bursts.add(Burst(false, MapPoints.x(reveal.coordinate.lon), MapPoints.y(reveal.coordinate.lat), now, nextReveal.toLong()))
            val next = cuts.indexOfLast { it <= nextReveal }
            if (next >= 0 && next < fields.size && next != step) show(next)
        }
        if (nextSecret < recap.secrets.size && recap.secrets[nextSecret].at <= progress) {
            val secret = recap.secrets[nextSecret]
            nextSecret++
            showingSecret = secret.entry
            pausedUntil = now + 2_400_000_000L
            sounds?.play(SoundFX.Sound.Chime)
            onSuccess()
            bursts.add(Burst(true, 0.0, 0.0, now, nextSecret.toLong() * 7919))
        }
    }

    private fun show(next: Int) {
        step = next
        field = fields[next]
    }

    /**
     * The clouds at a dozen or so points along the walk, worked out off the main
     * thread up front so the replay doesn't stutter.
     */
    private suspend fun prepareClouds() {
        if (fields.isNotEmpty()) return
        val steps = max(1, min(recap.reveals.size, 14))
        val cuts = (0..steps).map { (it.toDouble() / steps * recap.reveals.size).roundToInt() }
        this.cuts = cuts
        fields = withContext(Dispatchers.Default) {
            cuts.map { cut ->
                val shown = recap.reveals.take(cut)
                val cities = recap.before.map { city ->
                    city.copy(visited = city.visited + shown.filter { it.place == city.id }.map { it.hex })
                }
                CloudField(others + cities)
            }
        }
        // Skipped while they were being worked out: straight to the end.
        show(if (phase == Phase.Summary) fields.size - 1 else 0)
    }

    companion object {
        fun replayDuration(walkSeconds: Double) = min(30.0, max(2.0, walkSeconds / 600 * 5))
    }
}

/** The route drawing itself, a walker at its head, and the bursts: sparkles where a tile clears, confetti for a secret. */
@Composable
private fun ReplayEffects(recap: WalkRecap, player: ReplayPlayer, state: MapState, reduceMotion: Boolean, style: String) {
    val route = remember(recap) {
        DoubleArray(recap.route.size * 2) { i ->
            val p = recap.route[i / 2]
            if (i % 2 == 0) MapPoints.x(p.lon) else MapPoints.y(p.lat)
        }
    }
    val projection = remember { Projection() }
    val ground = remember { DoubleArray(10) }
    val path = remember { Path() }
    var frame by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        while (true) withFrameNanos { frame = it }
    }
    Canvas(Modifier.fillMaxSize()) {
        @Suppress("UNUSED_EXPRESSION") frame
        state.cameraTick.longValue
        if (state.controller == null) return@Canvas
        if (!state.measure(size.width, size.height, ground)) return@Canvas
        projection.update(ground, size.width, size.height, ground[8], ground[9])
        if (!projection.valid) return@Canvas
        val now = System.nanoTime()
        drawRoute(route, player, projection, path)
        for (burst in player.bursts.toList()) {
            val t = (now - burst.start) / 1e9
            if (!burst.secret) {
                if (!projection.isInFront(burst.x, burst.y)) continue
                projection.point(burst.x, burst.y)
                sparkles(Offset(projection.x, projection.y), t, burst.seed)
            } else if (!reduceMotion) {
                when (style) {
                    "celebration.bubbles" -> bubbles(t, burst.seed)
                    "celebration.fireworks" -> fireworks(t, burst.seed)
                    else -> confetti(t, burst.seed)
                }
            }
        }
    }
}

private val TEAL = Color(CloudPainter.TEAL)
private val GOLD = Color(1f, 0.82f, 0.3f)

private fun DrawScope.drawRoute(route: DoubleArray, player: ReplayPlayer, projection: Projection, path: Path) {
    val n = route.size / 2
    if (n < 2) return
    val end = player.progress * (n - 1)
    val whole = end.toInt()
    path.reset()
    projection.point(route[0], route[1])
    path.moveTo(projection.x, projection.y)
    for (i in 1..min(whole, n - 1)) {
        projection.point(route[i * 2], route[i * 2 + 1])
        path.lineTo(projection.x, projection.y)
    }
    val last = min(whole, n - 1)
    projection.point(route[last * 2], route[last * 2 + 1])
    var head = Offset(projection.x, projection.y)
    if (whole < n - 1) {
        projection.point(route[(whole + 1) * 2], route[(whole + 1) * 2 + 1])
        val f = (end - whole).toFloat()
        head = Offset(head.x + (projection.x - head.x) * f, head.y + (projection.y - head.y) * f)
        path.lineTo(head.x, head.y)
    }
    drawPath(path, Color.White.copy(alpha = 0.9f), style = Stroke(8.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    drawPath(path, Color(0.05f, 0.12f, 0.16f, CloudPainter.EDGE_ALPHA.toFloat()), style = Stroke((4.5f + CloudPainter.EDGE_EXTRA).dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    drawPath(path, TEAL, style = Stroke(4.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    if (player.phase == ReplayPlayer.Phase.Replay) {
        drawCircle(Color.White, 10.dp.toPx(), head)
        drawCircle(Walkies.orange, 6.5.dp.toPx(), head)
    }
}

/** A puff of white cloud bits and orange and gold sparks flying out from a tile. */
private fun DrawScope.sparkles(origin: Offset, t: Double, seed: Long) {
    val life = 0.9
    if (t < 0 || t >= life) return
    val pt = density
    val rng = SplitMix64(seed * 2_654_435_761L)
    val fade = (1 - t / life).toFloat()
    // A quick ring expanding out from the tile.
    val ring = ((10 + 70 * (1 - (1 - t / life).pow(3))) * pt).toFloat()
    drawOval(
        Color.White.copy(alpha = 0.7f * fade),
        topLeft = Offset(origin.x - ring, origin.y - ring * 0.7f),
        size = Size(ring * 2, ring * 1.4f),
        style = Stroke(3 * pt * fade),
    )
    for (i in 0 until 14) {
        val angle = rng.unit() * 2 * PI
        val speed = (50 + rng.unit() * 90) * pt
        val x = origin.x + cos(angle) * speed * t
        val y = origin.y + sin(angle) * speed * t * 0.75 + 40 * pt * t * t
        val r = (if (i < 6) 5 + rng.unit() * 4 else 2.5 + rng.unit() * 2.5) * (0.6 + 0.4 * fade) * pt
        val colour = if (i < 6) Color.White else if (i % 2 == 0) Walkies.orange else GOLD
        drawCircle(colour.copy(alpha = fade), r.toFloat(), Offset(x.toFloat(), y.toFloat()))
    }
}

/** Confetti thrown up from the bottom of the screen and fluttering down. */
private fun DrawScope.confetti(t: Double, seed: Long) {
    val life = 2.4
    if (t < 0 || t >= life) return
    val pt = density
    val rng = SplitMix64(seed)
    val colours = listOf(Walkies.orange, GOLD, TEAL, Walkies.badgeGreen, Color(0.95f, 0.45f, 0.6f), Color.White)
    val fade = min(1.0, (life - t) / 0.5).toFloat()
    val w = size.width
    val h = size.height
    for (i in 0 until 60) {
        val fromLeft = i % 2 == 0
        val startX = if (fromLeft) w * 0.15 else w * 0.85
        val angle = (if (fromLeft) -1.2 else -1.94) + (rng.unit() - 0.5) * 0.9
        val speed = (520 + rng.unit() * 380) * pt
        val x = startX + cos(angle) * speed * t
        val y = h * 0.78 + sin(angle) * speed * t + 520 * pt * t * t
        val spin = rng.unit() * 10 * t
        val colour = colours[java.lang.Long.remainderUnsigned(rng.next(), colours.size.toLong()).toInt()]
        translate(x.toFloat(), y.toFloat()) {
            rotateRad(spin.toFloat(), pivot = Offset.Zero) {
                drawRect(colour.copy(alpha = fade), topLeft = Offset(-5 * pt, -3 * pt), size = Size(10 * pt, 6 * pt))
            }
        }
    }
}

/** Soft bubbles drift up, then leave a brief expanding ring as they pop. */
private fun DrawScope.bubbles(t: Double, seed: Long) {
    if (t < 0 || t >= 2.5) return
    val pt = density
    val rng = SplitMix64(seed)
    val colours = listOf(Color.White, Walkies.badgeTeal, Walkies.badgeGreen, SystemColours.pink)
    for (i in 0 until 30) {
        val delay = rng.unit() * 0.55
        val life = 1.1 + rng.unit() * 0.85
        val age = t - delay
        val x = size.width * rng.unit() + sin(age * 2 + i) * 18 * pt
        val bottom = size.height * (0.75 + rng.unit() * 0.2)
        val speed = (100 + rng.unit() * 150) * pt
        val radius = (7 + rng.unit() * 18) * pt
        if (age < 0 || age >= life + 0.18) continue
        val popping = max(0.0, (age - life) / 0.18)
        val r = (radius * (1 + popping * 0.5)).toFloat()
        val y = bottom - speed * min(age, life)
        val centre = Offset(x.toFloat(), y.toFloat())
        val colour = colours[i % colours.size]
        val fade = (min(1.0, age * 6) * (1 - popping)).toFloat()
        if (popping == 0.0) {
            drawCircle(colour.copy(alpha = 0.16f * fade), r, centre)
            drawOval(
                Color.White.copy(alpha = 0.65f * fade),
                topLeft = Offset(centre.x - r * 0.45f, centre.y - r * 0.5f),
                size = Size(r * 0.4f, r * 0.25f),
            )
        }
        drawCircle(colour.copy(alpha = 0.65f * fade), r, centre, style = Stroke(1.5f * pt))
    }
}

/** Three staggered bursts, with short glowing trails falling under gravity. */
private fun DrawScope.fireworks(t: Double, seed: Long) {
    if (t < 0 || t >= 2.5) return
    val pt = density
    val rng = SplitMix64(seed)
    val colours = listOf(Walkies.orange, Walkies.badgeTeal, SystemColours.pink, SystemColours.yellow, Color.White)
    for (burst in 0 until 3) {
        val ox = size.width * (0.2 + burst * 0.3)
        val oy = size.height * (0.2 + rng.unit() * 0.2)
        val age = t - burst * 0.35
        for (i in 0 until 32) {
            val angle = i / 32.0 * 2 * PI + rng.unit() * 0.1
            val speed = (70 + rng.unit() * 140) * pt
            if (age < 0 || age >= 1.5) continue
            val fade = (min(1.0, age * 12) * max(0.0, 1 - age / 1.5)).toFloat()
            fun point(time: Double) = Offset(
                (ox + cos(angle) * speed * time).toFloat(),
                (oy + sin(angle) * speed * time + 70 * pt * time * time).toFloat(),
            )
            drawLine(colours[(i + burst) % colours.size].copy(alpha = fade), point(max(0.0, age - 0.08)), point(age), 2.5f * pt, StrokeCap.Round)
        }
    }
}

/** A found secret, held up big with a slow sunburst behind it. */
@Composable
private fun SecretPop(entry: LoreEntry) {
    val spin by rememberInfiniteTransition(label = "sunburst").animateFloat(
        0f, 360f, infiniteRepeatable(tween(12_000, easing = LinearEasing), RepeatMode.Restart), label = "spin",
    )
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.padding(30.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(300.dp).rotate(spin)) {
                val r = size.width / 2
                val rays = Brush.radialGradient(
                    0f to GOLD_RAY, 40f / 150f to GOLD_RAY, 1f to Color.Transparent,
                    center = center, radius = r,
                )
                for (i in 0 until 8) {
                    drawArc(rays, startAngle = i * 45f, sweepAngle = 22.5f, useCenter = true)
                }
            }
            StickerArt(entry, 170.dp)
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.stickerCard(RoundedCornerShape(20.dp)).padding(horizontal = 20.dp, vertical = 12.dp),
        ) {
            BasicText("Secret found", style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold, color = Walkies.burnt))
            BasicText(entry.title, style = heavyRounded(22).copy(fontFamily = roundedFont(), textAlign = TextAlign.Center))
        }
    }
}

private val GOLD_RAY = Color(1f, 0.85f, 0.4f, 0.55f)

/** What the walk did, once the replay's over (SummaryCard in CelebrationView.swift). */
@Composable
private fun SummaryCard(
    recap: WalkRecap,
    sounds: SoundFX,
    reduceMotion: Boolean,
    endingXP: Int,
    hasReward: Boolean,
    onReward: () -> Unit,
    onSecret: (LoreEntry) -> Unit,
    onReplay: () -> Unit,
    onDone: () -> Unit,
) {
    var counted by remember { mutableIntStateOf(0) }
    var countedShells by remember { mutableIntStateOf(0) }
    var filled by remember { mutableStateOf(false) }
    val before = max(0, endingXP - recap.xp)
    var xpLevel by remember { mutableIntStateOf(LevelMeter(before).level) }
    val xpFill = remember { Animatable(LevelMeter(before).fraction.toFloat()) }
    val rounded = roundedFont()
    // Count tiles and shells up together, ticking as they go, then fill each place's
    // bar, then each level this walk crossed. A rewatch only counts the tiles.
    LaunchedEffect(recap) {
        val total = max(recap.newTiles, recap.shells)
        val steps = if (reduceMotion) 1 else min(max(total, 1), 30)
        for (i in 1..steps) {
            delay(max(18, 700 / steps).toLong())
            counted = (recap.newTiles.toDouble() * i / steps).toInt()
            countedShells = (recap.shells.toDouble() * i / steps).toInt()
            if (total > 0 && (i % 2 == 0 || steps == 1)) sounds.play(SoundFX.Sound.Tick)
        }
        filled = true
        if (recap.isRewatch) return@LaunchedEffect
        val fills = LevelMeter.fills(before, endingXP)
        val duration = if (reduceMotion) 0 else (min(0.65, 1.8 / fills.size) * 1000).toInt()
        for (fill in fills) {
            // Start each level's bar again without animating backwards.
            xpLevel = fill.level
            xpFill.snapTo(fill.from.toFloat())
            delay(30)
            xpFill.animateTo(fill.to.toFloat(), tween(duration, easing = EaseOut))
        }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp),
        modifier = Modifier
            .navigationBarsPadding()
            .padding(12.dp)
            .fillMaxWidth()
            .heightIn(max = 600.dp)
            .stickerCard(RoundedCornerShape(28.dp))
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            BasicText(
                if (recap.newTiles == 0) "Walk done" else "+$counted new ${if (recap.newTiles == 1) "tile" else "tiles"}",
                style = heavyRounded(38).copy(fontFamily = rounded, fontFeatureSettings = "tnum", textAlign = TextAlign.Center),
            )
            BasicText(summaryHeadline(recap), style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.7f), textAlign = TextAlign.Center))
        }

        Row(Modifier.fillMaxWidth()) {
            SummaryStat(Format.distance(recap.walk.distance), "Distance")
            SummaryStat(Format.duration(recap.walk.duration()), "Time")
            SummaryStat("${recap.secrets.size}", if (recap.secrets.size == 1) "Secret" else "Secrets")
        }

        if (!recap.isRewatch) {
            ProgressionSummary(recap, countedShells, xpLevel, xpFill.value.toDouble(), endingXP, filled, hasReward, onReward)
        }

        if (recap.secrets.isNotEmpty()) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp),
            ) {
                for (secret in recap.secrets) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier.pressScale({ onSecret(secret.entry) }),
                    ) {
                        StickerArt(secret.entry, 72.dp)
                        BasicText(
                            secret.entry.title,
                            style = Type.caption.copy(fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center),
                            maxLines = 2, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.width(96.dp),
                        )
                    }
                }
            }
        }

        for (place in recap.places) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                Row {
                    BasicText(place.name, style = Type.headline, modifier = Modifier.weight(1f))
                    BasicText(
                        (if (filled) place.after else place.before).percentText,
                        style = Type.headline.copy(color = Walkies.orange, fontFeatureSettings = "tnum"),
                    )
                }
                ProgressBar(if (filled) place.after else place.before, Modifier.fillMaxWidth())
                BasicText(
                    "+${String.format(Locale.US, "%.1f", (place.after - place.before) * 100)}% this walk · ${place.tilesLeft} tiles left",
                    style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)),
                )
            }
        }

        val prediction = recap.prediction
        if (!recap.isRewatch && prediction != null) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Walkies.sand.copy(alpha = 0.5f), RoundedCornerShape(16.dp))
                    .padding(12.dp),
            ) {
                BasicText(
                    "About ${prediction.walks} more ${if (prediction.walks == 1) "walk" else "walks"} like these to finish ${prediction.place}",
                    style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center),
                )
                val weeks = prediction.weeks
                val perWeek = prediction.walksPerWeek
                if (weeks != null && perWeek != null) {
                    BasicText(
                        "At your pace of about ${perWeek.roundToInt()} a week, that's ${weeksText(weeks)}.",
                        style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.65f), textAlign = TextAlign.Center),
                    )
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            StickerButton(onClick = onReplay, modifier = Modifier.weight(1f), fill = Color.White) {
                BasicText("↺  Watch again", style = Type.headline, maxLines = 1)
            }
            StickerButton(onClick = onDone, modifier = Modifier.weight(1f)) {
                BasicText("Done", style = Type.headline.copy(color = Color.White))
            }
        }
    }
}

/** The shells and XP the walk earned, the level bar, and the quests it moved on (progressionSummary). */
@Composable
private fun ProgressionSummary(
    recap: WalkRecap,
    shells: Int,
    level: Int,
    fill: Double,
    endingXP: Int,
    filled: Boolean,
    hasReward: Boolean,
    onReward: () -> Unit,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth().background(Walkies.sand.copy(alpha = 0.35f), RoundedCornerShape(16.dp)).padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { ShellBalance(shells, prefix = "+") }
            BasicText("+${recap.xp} XP", style = Type.subheadline.copy(fontWeight = FontWeight.Bold))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            BasicText("Level $level", style = Type.headline, modifier = Modifier.weight(1f))
            BasicText("$endingXP total XP", style = Type.caption)
        }
        ProgressBar(
            fill, Modifier.fillMaxWidth().semantics { contentDescription = "Level $level progress, ${(fill * 100).toInt()} percent" },
            animated = false,
        )
        for (quest in recap.questProgress) {
            val done = filled && quest.completed
            val bounce by animateFloatAsState(if (filled) 1f else 0.85f, spring(dampingRatio = 0.4f, stiffness = 600f), label = "bounce")
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CheckCircle(
                    Modifier.size(20.dp).scale(bounce),
                    if (filled) Walkies.badgeTeal else Walkies.ink.copy(alpha = 0.4f),
                    filled = done,
                )
                Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
                    val progress = if (filled) quest.after else quest.before
                    BasicText(quest.kind.title, style = Type.caption.copy(fontWeight = FontWeight.SemiBold))
                    BasicText(questProgressText(progress, quest.kind), style = Type.caption.copy(fontSize = 11.sp, color = Walkies.ink.copy(alpha = 0.65f)))
                    ProgressBar(min(1.0, progress / quest.target), Modifier.fillMaxWidth())
                }
                if (done) BasicText("+40 shells", style = Type.caption.copy(fontWeight = FontWeight.SemiBold))
            }
        }
        if (hasReward) {
            StickerButton(onClick = onReward) {
                BasicText("Level up, choose a reward", style = Type.headline.copy(color = Color.White))
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.SummaryStat(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
        BasicText(value, style = Type.title3.copy(fontWeight = FontWeight.Bold, fontFeatureSettings = "tnum"))
        BasicText(label, style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)))
    }
}

/** The line under the tile count. */
fun summaryHeadline(recap: WalkRecap): String = when {
    recap.newTiles == 0 -> "No new tiles this time. Next time, try a street you haven't been down yet."
    recap.isBest -> "Your best walk yet. That's a lot of sky cleared."
    recap.secrets.isNotEmpty() -> "And you turned up ${if (recap.secrets.size == 1) "a secret" else "some secrets"} on the way."
    recap.newTiles >= 30 -> "What a haul. A big chunk of cloud gone."
    else -> "Nice one. A few more clouds gone."
}

fun weeksText(weeks: Double): String {
    if (weeks < 1.5) return "about a week"
    if (weeks < 9) return "about ${weeks.roundToInt()} weeks"
    val months = weeks / 4.35
    return if (months < 1.5) "about a month" else "about ${months.roundToInt()} months"
}
