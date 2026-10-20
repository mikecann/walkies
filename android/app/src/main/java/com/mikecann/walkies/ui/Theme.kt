package com.mikecann.walkies.ui

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Paint
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** The colours from Theme.swift. */
object Walkies {
    val orange = Color(1.0f, 0.47f, 0.18f)
    val teal = Color(0.13f, 0.65f, 0.6f)

    // The look picked from the concept art: cream die-cut cards like the secret
    // stickers, on top of the satellite map and clouds.
    /** Card paper. */
    val cream = Color(0.984f, 0.957f, 0.902f)
    /** The darker cream of hex badges and progress tracks. */
    val sand = Color(0.918f, 0.859f, 0.753f)
    /** Text on cream: a warm near-black rather than pure black. */
    val ink = Color(0.231f, 0.192f, 0.169f)
    /** Main buttons: Start walk, End walk. */
    val burnt = Color(0.79f, 0.34f, 0.23f)
    val badgeGreen = Color(0.62f, 0.77f, 0.58f)
    val badgeTeal = Color(0.29f, 0.58f, 0.58f)
}

/**
 * Nunito, the closest free match for SF Rounded, from assets/fonts if it's there
 * (`./gradlew fetchFonts`), or the system font.
 */
@Composable
fun roundedFont(): FontFamily {
    val context = LocalContext.current
    return remember {
        val bundled = runCatching { context.assets.list("fonts")?.contains("Nunito.ttf") == true }.getOrDefault(false)
        if (!bundled) {
            FontFamily.SansSerif
        } else {
            FontFamily(
                Font("fonts/Nunito.ttf", context.assets, FontWeight.Bold),
                Font("fonts/Nunito.ttf", context.assets, FontWeight.ExtraBold),
                Font("fonts/Nunito.ttf", context.assets, FontWeight.Black),
            )
        }
    }
}

/** iOS's default text styles, at their default sizes. SF Pro's nearest here is the system font. */
object Type {
    val headline = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Walkies.ink)
    val subheadline = TextStyle(fontSize = 15.sp, color = Walkies.ink)
    val caption = TextStyle(fontSize = 12.sp, color = Walkies.ink)
    val footnote = TextStyle(fontSize = 13.sp, color = Walkies.ink)
    val body = TextStyle(fontSize = 17.sp, color = Walkies.ink)
    val title3 = TextStyle(fontSize = 20.sp, color = Walkies.ink)
}

/** One of the iPhone app's illustrated images, copied into assets/images at build time. */
@Composable
fun assetImage(name: String): ImageBitmap? {
    val context = LocalContext.current
    return remember(name) { loadAssetImage(context, name) }
}

fun loadAssetImage(context: Context, name: String): ImageBitmap? = runCatching {
    context.assets.open("images/$name.png").use { BitmapFactory.decodeStream(it)?.asImageBitmap() }
}.getOrNull()

@Composable
fun AssetIcon(name: String, size: Dp) {
    val image = assetImage(name) ?: return
    Image(image, contentDescription = null, modifier = Modifier.size(size))
}

/**
 * A soft drop shadow like SwiftUI's `.shadow(color:radius:y:)`, which Compose's
 * elevation shadows can't do.
 */
fun Modifier.softShadow(shape: Shape, radius: Dp, y: Dp, alpha: Float, fill: Color) = drawWithCache {
    val path = Path().apply { addOutline(shape.createOutline(size, layoutDirection, this@drawWithCache)) }.asAndroidPath()
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = fill.toArgb()
        setShadowLayer(radius.toPx(), 0f, y.toPx(), Color.Black.copy(alpha = alpha).toArgb())
    }
    onDrawBehind { drawIntoCanvas { it.nativeCanvas.drawPath(path, paint) } }
}

/** A cream card with a white die-cut edge and a soft shadow, like a sticker. */
fun Modifier.stickerCard(shape: Shape) = this
    .softShadow(shape, 8.dp, 3.dp, 0.18f, Walkies.cream)
    .background(Walkies.cream, shape)
    .border(3.dp, Color.White, shape)

/** A pointy-topped hexagon, matching the map's tiles. */
class Hexagon(private val inset: Float = 0f) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val r = min(size.width / sqrt(3f), size.height / 2) - inset
        val cx = size.width / 2
        val cy = size.height / 2
        val path = Path()
        for (i in 0 until 6) {
            val a = (60 * i - 90) * Math.PI / 180
            val x = cx + r * cos(a).toFloat()
            val y = cy + r * sin(a).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        return Outline.Generic(path)
    }
}
