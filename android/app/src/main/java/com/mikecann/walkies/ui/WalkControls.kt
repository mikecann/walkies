package com.mikecann.walkies.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.AppModel
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.Walk
import kotlinx.coroutines.delay
import java.util.Locale

/** Format in Theme.swift. */
object Format {
    fun distance(metres: Double): String =
        if (metres < 1000) "${metres.toInt()} m" else String.format(Locale.US, "%.2f km", metres / 1000)

    /** 4:05, or 1:04:05 once it's past an hour. */
    fun duration(seconds: Double): String {
        val total = maxOf(0, seconds.toInt())
        val h = total / 3600
        val m = total % 3600 / 60
        val s = total % 60
        return if (h > 0) String.format(Locale.US, "%d:%02d:%02d", h, m, s) else String.format(Locale.US, "%d:%02d", m, s)
    }
}

/**
 * What sits at the bottom of the map: a pending walk's badge, the walk you're on,
 * a nudge to allow location, Start walk, or nothing in always-on mode (unless it's
 * missing a permission it needs).
 * WalkControls in ContentView.swift.
 */
@Composable
fun WalkControls(
    walk: Walk?,
    /** How far a pending always-on walk has got, while it's pending. */
    pendingDistance: Double?,
    alwaysOn: Boolean,
    locationDenied: Boolean,
    /** Why always-on can't do its job with the app closed, if it can't. */
    alwaysOnWarning: String?,
    onStart: () -> Unit,
    onEnd: () -> Unit,
    onOpenSettings: () -> Unit,
    onFixPermissions: () -> Unit,
    modifier: Modifier = Modifier,
) {
    when {
        pendingDistance != null -> Box(modifier.fillMaxWidth()) { PendingWalkBadge(pendingDistance) }
        walk != null -> Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = modifier
                .fillMaxWidth()
                .stickerCard(RoundedCornerShape(26.dp))
                .padding(14.dp),
        ) {
            // Ticks every second while the walk's going.
            var now by remember { mutableDoubleStateOf(SwiftDate.now().sinceReference) }
            LaunchedEffect(walk.id) {
                while (true) {
                    now = SwiftDate.now().sinceReference
                    delay(1000)
                }
            }
            Row(Modifier.fillMaxWidth()) {
                Stat(Format.duration(walk.duration(SwiftDate(now))), "Time")
                Stat(Format.distance(walk.distance), "Distance")
                Stat("${walk.newTiles}", "New tiles", tint = Walkies.orange)
            }
            StickerButton(onClick = onEnd) {
                BasicText("End walk", style = Type.headline.copy(color = Color.White))
            }
        }
        locationDenied -> Nudge("Walkies needs your location to uncover tiles.", "Open Settings", onOpenSettings, modifier)
        alwaysOn && alwaysOnWarning != null -> Nudge(alwaysOnWarning, "Fix permissions", onFixPermissions, modifier)
        // Nothing to press: walks get picked up by themselves.
        alwaysOn -> Spacer(modifier.fillMaxWidth().height(1.dp))
        else -> StickerButton(onClick = onStart, modifier = modifier) {
            AssetIcon("icon-walk", 26.dp)
            Spacer(Modifier.width(8.dp))
            BasicText("Start walk", style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Color.White))
        }
    }
}

/** A short line and a button, on a card. */
@Composable
private fun Nudge(text: String, button: String, onClick: () -> Unit, modifier: Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .fillMaxWidth()
            .stickerCard(RoundedCornerShape(26.dp))
            .padding(14.dp),
    ) {
        BasicText(text, style = Type.subheadline.copy(textAlign = TextAlign.Center))
        StickerButton(onClick = onClick) {
            BasicText(button, style = Type.headline.copy(color = Color.White))
        }
    }
}

/**
 * A walk that might just be GPS wandering about at home: a small shoe and how far
 * you've got. Tap it and it says what that means, then shrinks back.
 */
@Composable
private fun PendingWalkBadge(distance: Double) {
    var explaining by remember { mutableStateOf(false) }
    LaunchedEffect(explaining) {
        if (!explaining) return@LaunchedEffect
        delay(5000)
        explaining = false
    }
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.92f else 1f, label = "press")
    val shape = RoundedCornerShape(20.dp)
    val metres = distance.toInt()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .scale(scale)
            .stickerCard(shape)
            .clip(shape)
            .clickable(interaction, indication = null, role = Role.Button) { explaining = !explaining }
            .semantics { contentDescription = "Walk pending, $metres metres so far" }
            .animateContentSize()
            .padding(start = 8.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
    ) {
        AssetIcon("icon-walk", 24.dp)
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            BasicText(
                if (explaining) "Walk pending, $metres m so far" else "$metres m",
                style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"),
            )
            if (explaining) {
                BasicText(
                    "Counts once you're ${AppModel.AUTO_WALK_CONFIRM_DISTANCE.toInt()} m from where you started",
                    style = Type.caption.copy(color = Walkies.ink.copy(alpha = 0.6f)),
                )
            }
        }
    }
}

@Composable
private fun RowScope.Stat(value: String, label: String, tint: Color = Walkies.ink) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
        BasicText(value, style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold, color = tint, fontFeatureSettings = "tnum"))
        BasicText(label, style = Type.caption.copy(color = if (tint == Walkies.ink) Walkies.ink.copy(alpha = 0.6f) else tint))
    }
}

/** A burnt-orange capsule with a white sticker edge (StickerButtonStyle in Theme.swift). */
@Composable
fun StickerButton(onClick: () -> Unit, modifier: Modifier = Modifier, fill: Color = Walkies.burnt, content: @Composable RowScope.() -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, label = "press")
    val capsule = RoundedCornerShape(50)
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .scale(scale)
            .softShadow(capsule, 6.dp, 3.dp, 0.2f, fill)
            .clip(capsule)
            .background(fill)
            .border(3.dp, Color.White, capsule)
            .clickable(interaction, indication = null, role = Role.Button, onClick = onClick)
            .padding(vertical = 14.dp),
        content = content,
    )
}
