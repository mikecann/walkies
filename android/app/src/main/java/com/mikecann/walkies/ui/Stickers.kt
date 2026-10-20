package com.mikecann.walkies.ui

import android.content.Context
import android.graphics.Paint
import android.util.LruCache
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.mikecann.walkies.lore.LoreEntry
import com.mikecann.walkies.model.SwiftDate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URI
import java.text.DateFormat
import java.util.Date

/** Colour and icon for each kind of lore, used until a sticker has its own art (StickerStyle in Stickers.swift). */
class StickerStyle(category: String) {
    val glyph: String
    val colour: Color
    val label: String

    init {
        val (g, c, l) = when (category) {
            "history" -> Triple("🏛", Color(0.72f, 0.45f, 0.2f), "History")
            "first-nations" -> Triple("☀", Color(0.8f, 0.33f, 0.18f), "First Nations")
            "nature" -> Triple("🍃", Color(0.25f, 0.6f, 0.3f), "Nature")
            "the-sea" -> Triple("🌊", Color(0.12f, 0.5f, 0.75f), "The sea")
            "odd-records" -> Triple("★", Color(0.5f, 0.35f, 0.75f), "Odd records")
            else -> Triple("🏠", Walkies.orange, "Modern life")
        }
        glyph = g
        colour = c
        label = l
    }
}

/** Sticker art and photos, kept in memory while there's room. Small ones load at half size. */
object StickerImages {
    private val cache = object : LruCache<String, ImageBitmap>(48 * 1024) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4 / 1024
    }

    fun cached(name: String, sample: Int): ImageBitmap? = cache.get("$name@$sample")

    fun load(context: Context, name: String, sample: Int): ImageBitmap? {
        cached(name, sample)?.let { return it }
        val image = loadAssetImage(context, name, sample) ?: return null
        cache.put("$name@$sample", image)
        return image
    }
}

/** An image from assets, loaded off the main thread the first time. */
@Composable
fun rememberAssetImage(name: String, small: Boolean): ImageBitmap? {
    val context = LocalContext.current
    val sample = if (small) 2 else 1
    val image by produceState(StickerImages.cached(name, sample), name, sample) {
        if (value == null) value = withContext(Dispatchers.IO) { StickerImages.load(context.applicationContext, name, sample) }
    }
    return image
}

/** The sticker itself: its art if it has some, otherwise a badge for its kind (StickerArt in Stickers.swift). */
@Composable
fun StickerArt(entry: LoreEntry, size: Dp, modifier: Modifier = Modifier) {
    val image = rememberAssetImage("sticker-${entry.id}", small = size <= 110.dp)
    if (image != null) {
        val bitmap = remember(image) { image.asAndroidBitmap() }
        val paint = remember { Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG) }
        Canvas(modifier.size(size)) {
            // The shadow follows the sticker's own outline, as SwiftUI's .shadow does.
            paint.setShadowLayer(this.size.width * 0.04f, 0f, this.size.width * 0.03f, Color.Black.copy(alpha = 0.18f).toArgb())
            drawIntoCanvas {
                it.nativeCanvas.drawBitmap(bitmap, null, android.graphics.RectF(0f, 0f, this.size.width, this.size.height), paint)
            }
        }
    } else {
        val style = StickerStyle(entry.category)
        Box(
            contentAlignment = Alignment.Center,
            modifier = modifier
                .size(size)
                .softShadow(CircleShape, size * 0.04f, size * 0.03f, 0.18f, Color.White)
                .background(Color.White, CircleShape)
                .padding(size * 0.06f)
                .background(Brush.verticalGradient(listOf(lighter(style.colour), style.colour)), CircleShape),
        ) {
            BasicText(style.glyph, style = Type.body.copy(fontSize = (size.value * 0.38f).sp, color = Color.White))
        }
    }
}

/** A not-yet-found sticker as a grey silhouette, like the empty spaces in a sticker album. */
@Composable
fun StickerSilhouette(entry: LoreEntry, size: Dp) {
    val image = rememberAssetImage("sticker-${entry.id}", small = true)
    if (image != null) {
        Image(
            image, contentDescription = null,
            colorFilter = ColorFilter.tint(Walkies.ink.copy(alpha = 0.1f), BlendMode.SrcIn),
            modifier = Modifier.size(size),
        )
    } else {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(size).background(Walkies.ink.copy(alpha = 0.1f), CircleShape)) {
            BasicText(
                "?",
                style = Type.headline.copy(fontFamily = roundedFont(), fontWeight = FontWeight.Black, fontSize = 36.sp, color = Walkies.ink.copy(alpha = 0.3f)),
            )
        }
    }
}

private fun lighter(c: Color) = Color(c.red + (1 - c.red) * 0.12f, c.green + (1 - c.green) * 0.12f, c.blue + (1 - c.blue) * 0.12f)

/** Shrinks a touch while pressed (PressScale in Theme.swift). */
@Composable
fun Modifier.pressScale(onClick: () -> Unit, enabled: Boolean = true, label: String? = null): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.95f else 1f, label = "press")
    return this
        .scale(scale)
        .clickable(interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
        .then(if (label != null) Modifier.semantics { contentDescription = label } else Modifier)
}

/**
 * A sheet that slides up over everything, on cream, like SwiftUI's .sheet. [medium]
 * starts it half height (a medium detent); drag the grabber up for all of it, or
 * down to close. Tap outside or go back to close.
 */
@Composable
fun Sheet(
    onDismiss: () -> Unit,
    medium: Boolean = false,
    background: Color = Walkies.cream,
    content: @Composable ColumnScope.(close: () -> Unit) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val hidden = remember { Animatable(1f) }
    var large by remember { mutableStateOf(!medium) }
    var closing by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { hidden.animateTo(0f, spring(dampingRatio = 0.86f, stiffness = 420f)) }
    val close: () -> Unit = {
        if (!closing) {
            closing = true
            scope.launch {
                hidden.animateTo(1f, tween(220))
                onDismiss()
            }
        }
    }
    BackHandler(onBack = close)
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val height by animateDpAsState(if (large) maxHeight * 0.94f else maxHeight * 0.56f, label = "detent")
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = 1 - hidden.value }
                .background(Color.Black.copy(alpha = 0.3f))
                .clickable(remember { MutableInteractionSource() }, indication = null, onClick = close),
        )
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(height)
                .graphicsLayer { translationY = size.height * hidden.value }
                .clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                .background(background)
                .clickable(remember { MutableInteractionSource() }, indication = null) {},
        ) {
            var dragged by remember { mutableFloatStateOf(0f) }
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(22.dp)
                    .pointerInput(medium) {
                        detectVerticalDragGestures(
                            onDragStart = { dragged = 0f },
                            onDragEnd = {
                                when {
                                    dragged < -40 -> large = true
                                    dragged > 60 && large && medium -> large = false
                                    dragged > 60 -> close()
                                }
                            },
                        ) { _, dy -> dragged += dy }
                    },
            ) {
                Box(Modifier.size(36.dp, 5.dp).background(Walkies.ink.copy(alpha = 0.2f), RoundedCornerShape(50)))
            }
            Column(Modifier.weight(1f).navigationBarsPadding()) { content(close) }
        }
    }
}

/**
 * A secret's story (LoreCardView in Stickers.swift): the sticker, its title and kind,
 * the story, its photos, when you found it and the sources. [isNew] when it's just
 * been found, with a "Nice one" to close it.
 */
@Composable
fun LoreCard(entry: LoreEntry, foundAt: SwiftDate?, isNew: Boolean = false, onClose: () -> Unit) {
    Sheet(onDismiss = onClose, medium = isNew) { close ->
        val style = StickerStyle(entry.category)
        val uri = LocalUriHandler.current
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(start = 24.dp, end = 24.dp, bottom = 24.dp, top = 2.dp),
        ) {
            if (isNew) {
                BasicText("SECRET FOUND", style = Type.subheadline.copy(fontWeight = FontWeight.Bold, color = Walkies.orange))
            }
            StickerArt(entry, 170.dp, Modifier.padding(top = if (isNew) 0.dp else 8.dp))
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                BasicText(entry.title, style = Type.title3.copy(fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    BasicText(
                        "${style.glyph} ${style.label}",
                        style = Type.caption.copy(fontWeight = FontWeight.SemiBold, color = style.colour),
                        modifier = Modifier.background(style.colour.copy(alpha = 0.15f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                    entry.place?.let { place ->
                        BasicText(
                            "📍 ${place.name}",
                            style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)),
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                    }
                }
            }
            BasicText(entry.body, style = Type.body, modifier = Modifier.fillMaxWidth())
            for (photo in entry.photos.orEmpty()) LorePhoto(photo)
            foundAt?.let {
                BasicText(
                    if (it == SwiftDate.distantFuture) "Found in your explored tiles" else "Found ${foundText(it)}",
                    style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (entry.sources.isNotEmpty()) {
                var open by remember { mutableStateOf(false) }
                val turn by animateFloatAsState(if (open) 90f else 0f, label = "chevron")
                Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { open = !open }.padding(vertical = 4.dp),
                    ) {
                        BasicText("Sources", style = Type.subheadline, modifier = Modifier.weight(1f))
                        ChevronRight(Modifier.size(10.dp).rotate(turn), Walkies.burnt)
                    }
                    if (open) {
                        for (source in entry.sources) {
                            val host = runCatching { URI(source).takeIf { it.scheme != null }?.host }.getOrNull()
                            BasicText(
                                host ?: source,
                                style = Type.caption.copy(color = if (host != null) Walkies.burnt else Walkies.ink.copy(alpha = 0.6f)),
                                modifier = if (host != null) Modifier.clickable { runCatching { uri.openUri(source) } } else Modifier,
                            )
                        }
                    }
                }
            }
            if (isNew) {
                StickerButton(onClick = close) {
                    BasicText("Nice one", style = Type.headline.copy(color = Color.White))
                }
            }
        }
    }
}

/** "20 Oct 2026, 11:34 am", like Swift's abbreviated date and shortened time. */
fun foundText(date: SwiftDate): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date((date.epochSeconds * 1000).toLong()))

/**
 * A photo under a secret's story: the picture, what it shows, and who took it, which
 * links to its page on Wikimedia Commons. Tap the picture to see it full screen.
 */
@Composable
private fun LorePhoto(photo: LoreEntry.Photo) {
    val image = rememberAssetImage(photo.asset, small = false) ?: return
    val uri = LocalUriHandler.current
    var enlarged by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
        // A neat band, whatever shape the photo is; tap for all of it.
        Image(
            image, contentDescription = photo.caption.ifEmpty { "Photo" }, contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxWidth()
                .height(230.dp)
                .pressScale({ enlarged = true })
                .softShadow(shape, 6.dp, 3.dp, 0.15f, Color.White)
                .clip(shape)
                .border(3.dp, Color.White, shape),
        )
        if (photo.caption.isNotEmpty()) {
            BasicText(photo.caption, style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.8f)))
        }
        if (photo.source.isNotEmpty()) {
            BasicText(
                "Photo: ${photo.credit.ifEmpty { "Wikimedia Commons" }}",
                style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.5f)),
                modifier = Modifier.clickable { runCatching { uri.openUri(photo.source) } },
            )
        }
    }
    if (enlarged) ZoomablePhoto(image) { enlarged = false }
}

/** A photo filling the screen on black, pinch to zoom, tap to close. */
@Composable
private fun ZoomablePhoto(image: ImageBitmap, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        var scale by remember { mutableFloatStateOf(1f) }
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black)
                .pointerInput(Unit) { detectTransformGestures { _, _, zoom, _ -> scale = (scale * zoom).coerceIn(1f, 4f) } }
                .pointerInput(Unit) { detectTapGestures { onClose() } },
        ) {
            Image(
                image, contentDescription = null, contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().graphicsLayer { scaleX = scale; scaleY = scale },
            )
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .statusBarsPadding()
                    .padding(16.dp)
                    .size(32.dp)
                    .background(Color.White.copy(alpha = 0.25f), CircleShape)
                    .clickable(role = Role.Button, onClick = onClose)
                    .semantics { contentDescription = "Close" },
            ) {
                Cross(Modifier.size(12.dp), Color.White)
            }
        }
    }
}

/** SF Symbols' chevron.right. */
@Composable
fun ChevronRight(modifier: Modifier, colour: Color = Walkies.ink.copy(alpha = 0.5f)) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val path = Path().apply {
            moveTo(w * 0.32f, h * 0.1f)
            lineTo(w * 0.72f, h * 0.5f)
            lineTo(w * 0.32f, h * 0.9f)
        }
        drawPath(path, colour, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/** SF Symbols' xmark. */
@Composable
fun Cross(modifier: Modifier, colour: Color) {
    Canvas(modifier) {
        val stroke = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round)
        drawPath(Path().apply { moveTo(0f, 0f); lineTo(size.width, size.height) }, colour, style = stroke)
        drawPath(Path().apply { moveTo(size.width, 0f); lineTo(0f, size.height) }, colour, style = stroke)
    }
}
