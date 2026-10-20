package com.mikecann.walkies.ui

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** iOS's activity indicator: a spinning arc, since there's no Material here. */
@Composable
fun Spinner(size: Dp = 28.dp, colour: Color = Walkies.ink.copy(alpha = 0.55f)) {
    val turn by rememberInfiniteTransition(label = "spinner").animateFloat(
        0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Restart), label = "turn",
    )
    Canvas(Modifier.size(size)) {
        val stroke = this.size.width * 0.11f
        drawArc(
            colour, startAngle = turn, sweepAngle = 270f, useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(stroke / 2, stroke / 2),
            size = androidx.compose.ui.geometry.Size(this.size.width - stroke, this.size.height - stroke),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
    }
}

/** A button in a [WalkiesDialog]. */
class DialogButton(val title: String, val destructive: Boolean = false, val bold: Boolean = false, val action: () -> Unit = {})

/**
 * An alert or confirmation (SwiftUI's .alert and .confirmationDialog), as a cream
 * sticker card. Every button closes it.
 */
@Composable
fun WalkiesDialog(title: String, message: String?, buttons: List<DialogButton>, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .widthIn(max = 320.dp)
                .stickerCard(RoundedCornerShape(24.dp))
                .padding(top = 20.dp, bottom = 8.dp),
        ) {
            BasicText(
                title,
                style = Type.headline.copy(textAlign = TextAlign.Center),
                modifier = Modifier.padding(horizontal = 20.dp),
            )
            message?.let {
                BasicText(
                    it,
                    style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.7f), textAlign = TextAlign.Center),
                    modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 6.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            for (button in buttons) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Walkies.ink.copy(alpha = 0.08f)))
                BasicText(
                    button.title,
                    style = Type.body.copy(
                        color = if (button.destructive) Color(0.85f, 0.2f, 0.17f) else Walkies.burnt,
                        fontWeight = if (button.bold) FontWeight.SemiBold else FontWeight.Normal,
                        textAlign = TextAlign.Center,
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button) {
                            onDismiss()
                            button.action()
                        }
                        .padding(vertical = 12.dp),
                )
            }
        }
    }
}

/** The bar along the top of a full-screen sheet: a button each side and the title between. */
@Composable
fun SheetBar(title: String, leading: String?, onLeading: () -> Unit, trailing: String?, onTrailing: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            leading?.let { BarButton(it, bold = false, onLeading) }
        }
        BasicText(title, style = Type.headline)
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            trailing?.let { BarButton(it, bold = true, onTrailing) }
        }
    }
}

@Composable
private fun BarButton(title: String, bold: Boolean, onClick: () -> Unit) {
    BasicText(
        title,
        style = Type.body.copy(color = Walkies.burnt, fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal),
        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = onClick).padding(6.dp),
    )
}

/** A big empty-state message (ContentUnavailableView). */
@Composable
fun EmptyState(title: String, description: String, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.padding(horizontal = 32.dp),
    ) {
        BasicText(title, style = Type.headline.copy(fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center))
        BasicText(description, style = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.6f), textAlign = TextAlign.Center))
    }
}

/**
 * "MC" for Mike Cann, "M" for Mike, "?" with nothing to go on. An email works too.
 * Head.initials in Avatar.swift.
 */
fun initials(name: String?): String {
    var text = name?.trim().orEmpty()
    if (text.isEmpty()) return "?"
    text.indexOf('@').takeIf { it >= 0 }?.let { text = text.substring(0, it) }
    val words = text.split(Regex("[\\s._-]+")).mapNotNull { word -> word.firstOrNull { it.isLetterOrDigit() } }
    val first = words.firstOrNull() ?: return "?"
    val letters = if (words.size > 1) listOf(first, words.last()) else listOf(first)
    return letters.joinToString("") { it.uppercase() }
}

/** Head photos, kept in memory and in the cache folder so a head seen before doesn't flicker in (HeadImages in Avatar.swift). */
object HeadImages {
    private val memory = HashMap<String, ImageBitmap>()

    fun cached(url: String): ImageBitmap? = synchronized(memory) { memory[url] }

    suspend fun load(context: Context, url: String): ImageBitmap? = withContext(Dispatchers.IO) {
        cached(url)?.let { return@withContext it }
        val file = File(File(context.cacheDir, "heads").apply { mkdirs() }, hash(url))
        val bytes = runCatching { file.takeIf { it.exists() }?.readBytes() }.getOrNull() ?: runCatching {
            val connection = URL(url).openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 15_000
                connection.readTimeout = 15_000
                if (connection.responseCode !in 200..299) null else connection.inputStream.use { it.readBytes() }
            } finally {
                connection.disconnect()
            }
        }.getOrNull()?.also { runCatching { file.writeBytes(it) } } ?: return@withContext null
        val image = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap() ?: return@withContext null
        synchronized(memory) { memory[url] = image }
        image
    }

    private fun hash(url: String) = MessageDigest.getInstance("SHA-256").digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
}

/** Your photo, once it's loaded. */
@Composable
fun rememberHeadImage(url: String?): ImageBitmap? {
    val context = LocalContext.current
    var image by remember(url) { mutableStateOf(url?.let(HeadImages::cached)) }
    LaunchedEffect(url) {
        if (url != null && image == null) image = HeadImages.load(context.applicationContext, url)
    }
    return image
}
