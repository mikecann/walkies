package com.mikecann.walkies.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.expandVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.percentText

/** What goes on a hex badge: one of the illustrated icons, or the location arrow. */
sealed interface BadgeIcon {
    data class Art(val name: String) : BadgeIcon
    data object Location : BadgeIcon
}

/** A round map control as a hexagon badge (HexBadge in Theme.swift). */
@Composable
fun HexBadge(icon: BadgeIcon, label: String, fill: Color = Walkies.sand, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.92f else 1f, label = "press")
    val hexagon = remember { Hexagon() }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .scale(scale)
            .size(54.dp, 60.dp)
            .softShadow(hexagon, 6.dp, 3.dp, 0.2f, fill)
            .clip(hexagon)
            .background(fill)
            .border(3.dp, Color.White, hexagon)
            .clickable(interaction, indication = null, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
    ) {
        when (icon) {
            is BadgeIcon.Art -> AssetIcon(icon.name, 34.dp)
            BadgeIcon.Location -> LocationArrow(Modifier.size(22.dp))
        }
    }
}

/** SF Symbols' location.fill: a white arrow pointing up and to the right. */
@Composable
private fun LocationArrow(modifier: Modifier) {
    Canvas(modifier) {
        val s = size.width / 22f
        val path = Path().apply {
            moveTo(19.5f * s, 2.5f * s)
            lineTo(2.5f * s, 10f * s)
            lineTo(11f * s, 11f * s)
            lineTo(12f * s, 19.5f * s)
            close()
        }
        drawPath(path, Color.White)
        drawPath(path, Color.White, style = Stroke(width = 1.5f * s, join = StrokeJoin.Round))
    }
}

/** A round head with a white sticker edge (Avatar.swift): their photo, or their initials on their colour. */
@Composable
fun Avatar(initials: String, colour: Color, image: ImageBitmap? = null, size: Float = 30f, border: Float = 2.5f) {
    val rounded = roundedFont()
    if (image != null) {
        Image(
            image, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier
                .softShadow(CircleShape, 2.dp, 1.dp, 0.15f, colour)
                .size(size.dp)
                .clip(CircleShape)
                .border(border.dp, Color.White, CircleShape),
        )
        return
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .softShadow(CircleShape, 2.dp, 1.dp, 0.15f, colour)
            .size(size.dp)
            .clip(CircleShape)
            // SwiftUI's Color.gradient: a touch lighter at the top.
            .background(Brush.verticalGradient(listOf(lighten(colour, 0.12f), colour)))
            .border(border.dp, Color.White, CircleShape),
    ) {
        BasicText(
            initials,
            style = Type.headline.copy(fontFamily = rounded, fontWeight = FontWeight.Bold, fontSize = (size * 0.4f).sp, color = Color.White),
        )
    }
}

private fun lighten(c: Color, amount: Float) =
    Color(c.red + (1 - c.red) * amount, c.green + (1 - c.green) * amount, c.blue + (1 - c.blue) * amount, c.alpha)

/**
 * The place you're exploring, kept small: your head, the place and percentage.
 * Tap it for the details and to change place. PlaceChip in ContentView.swift.
 * [name] and [picture] are whoever's signed in.
 */
@Composable
fun PlaceChip(city: City?, name: String?, picture: String?, onChangePlace: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    val chevron by animateFloatAsState(if (open) 180f else 0f, label = "chevron")
    val shape = RoundedCornerShape(if (open) 22.dp else 24.dp)
    Column(
        modifier = Modifier
            .stickerCard(shape)
            .widthIn(min = if (open) 250.dp else 0.dp)
            .animateContentSize(spring(stiffness = 600f)),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .clip(shape)
                .clickable(role = Role.Button) { open = !open }
                .padding(start = 8.dp, end = 16.dp, top = 7.dp, bottom = 7.dp)
                .semantics {
                    contentDescription = city?.let { "${it.name}, ${it.progress.percentText.replace("%", " percent")}" } ?: "Places"
                },
        ) {
            Avatar(initials = initials(name), colour = Walkies.orange, image = rememberHeadImage(picture))
            BasicText(city?.name ?: "Places", style = Type.headline, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (city != null) {
                BasicText(city.progress.percentText, style = Type.headline.copy(color = Walkies.orange, fontFeatureSettings = "tnum"))
            }
            Chevron(Modifier.size(10.dp, 10.dp).rotate(chevron))
        }
        AnimatedVisibility(open, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 14.dp),
            ) {
                val text = Type.subheadline.copy(color = Walkies.ink.copy(alpha = 0.75f))
                if (city != null) {
                    ProgressBar(city.progress, Modifier.fillMaxWidth())
                    BasicText("${city.visited.size} of ${city.tiles.size} tiles explored", style = text)
                }
                BasicText(
                    "Change place",
                    style = Type.subheadline.copy(color = Walkies.burnt, fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.padding(top = 2.dp).clickable(role = Role.Button, onClick = onChangePlace),
                )
            }
        }
    }
}

/** SF Symbols' chevron.down, small and bold. */
@Composable
private fun Chevron(modifier: Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val path = Path().apply {
            moveTo(w * 0.1f, h * 0.32f)
            lineTo(w * 0.5f, h * 0.72f)
            lineTo(w * 0.9f, h * 0.32f)
        }
        drawPath(path, Walkies.ink.copy(alpha = 0.5f), style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

@Composable
fun ProgressBar(value: Double, modifier: Modifier = Modifier) {
    val shown by animateFloatAsState(value.toFloat(), label = "progress")
    Canvas(modifier.height(6.dp)) {
        val r = size.height / 2
        drawRoundRect(Walkies.sand, cornerRadius = androidx.compose.ui.geometry.CornerRadius(r))
        val w = maxOf(6.dp.toPx(), size.width * minOf(1f, shown))
        drawRoundRect(Walkies.orange, size = size.copy(width = w), cornerRadius = androidx.compose.ui.geometry.CornerRadius(r))
    }
}
