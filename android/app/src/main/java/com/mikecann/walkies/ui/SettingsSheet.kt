package com.mikecann.walkies.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import android.text.format.DateUtils
import com.mikecann.walkies.sync.SyncEngine
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Who's signed in and how sync's going, for Settings' Account section. */
class AccountRows(
    val signedInAs: String,
    val email: String?,
    val sync: String,
    val syncing: Boolean,
    /** Things on this phone the account hasn't got yet. */
    val waiting: Int,
    /** A walk's going, so signing out would lose it. */
    val walking: Boolean,
)

/** Settings' Sync line (syncText in SettingsView.swift). [lastSynced] is seconds since 1970. */
fun syncText(status: SyncEngine.Status, waiting: Int, lastSynced: Double?): String = when (status) {
    SyncEngine.Status.Syncing -> "Syncing…"
    is SyncEngine.Status.Failed -> if (waiting > 0) "$waiting waiting (${status.reason})" else "Couldn't check (${status.reason})"
    SyncEngine.Status.Idle -> when {
        waiting > 0 -> "$waiting waiting to upload"
        lastSynced == null -> "Not synced yet"
        else -> {
            val now = System.currentTimeMillis()
            val then = (lastSynced * 1000).toLong()
            val ago = if (now - then < 60_000) "just now"
            else DateUtils.getRelativeTimeSpanString(then, now, DateUtils.MINUTE_IN_MILLIS).toString()
            "Up to date, $ago"
        }
    }
}

/**
 * Settings (SettingsView.swift): the account and sync, past walks, the Always on switch,
 * a warning when location isn't allowed all the time, and a way back into the setup
 * when something's missing. Laid out like the iPhone's grouped Form. The iPhone's
 * "Suggest a feature" (Chef) is iPhone-only, so it isn't here.
 */
@Composable
fun SettingsSheet(
    account: AccountRows,
    onSyncNow: () -> Unit,
    /** Sync stops first, so nothing from this account comes back after the wipe. */
    onSignOut: () -> Unit,
    alwaysOn: Boolean,
    onAlwaysOn: (Boolean) -> Unit,
    /** Always on is on but location isn't allowed all the time, so walks won't record with the app closed. */
    locationWarning: Boolean,
    /** The app's page in the phone's Settings. */
    onOpenSettings: () -> Unit,
    /** Something the setup asks for is missing. */
    permissionsMissing: Boolean,
    onFixPermissions: () -> Unit,
    /** How many walks there are, for the Past walks row. */
    walkCount: Int,
    onShowHistory: () -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Walkies.cream)
            .clickable(remember { MutableInteractionSource() }, indication = null) {}
            .systemBarsPadding()
            .padding(horizontal = 16.dp),
    ) {
        SheetBar("Settings", leading = null, onLeading = {}, trailing = "Done", onTrailing = onClose)
        Spacer(Modifier.height(12.dp))
        var confirmingSignOut by remember { mutableStateOf(false) }
        var cantSignOut by remember { mutableStateOf<String?>(null) }
        var notUploaded by remember { mutableStateOf<Int?>(null) }
        Column(
            verticalArrangement = Arrangement.spacedBy(24.dp),
            // Centred on a tablet, like a grouped Form on an iPad.
            modifier = Modifier.align(Alignment.CenterHorizontally).widthIn(max = 600.dp).fillMaxWidth().verticalScroll(rememberScrollState()),
        ) {
            Section(footer = null, header = "Account") {
                Labeled("Signed in as", account.signedInAs)
                if (account.email != null && account.email != account.signedInAs) {
                    Divider()
                    Labeled("Email", account.email)
                }
                Divider()
                Labeled("Sync", account.sync)
                Divider()
                RowButton("Sync now", Walkies.burnt, enabled = !account.syncing, onClick = onSyncNow)
                Divider()
                RowButton("Sign out", red, enabled = true) {
                    when {
                        account.walking -> cantSignOut = "Finish your walk first."
                        account.waiting > 0 -> notUploaded = account.waiting
                        else -> confirmingSignOut = true
                    }
                }
            }
            Section(footer = null, header = "History") {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button, onClick = onShowHistory)
                        .padding(horizontal = 16.dp, vertical = 11.dp),
                ) {
                    BasicText("Past walks", style = Type.body, modifier = Modifier.weight(1f))
                    BasicText("$walkCount", style = Type.body.copy(color = Walkies.ink.copy(alpha = 0.5f)))
                    ChevronRight(Modifier.size(8.dp, 13.dp), Walkies.ink.copy(alpha = 0.3f))
                }
            }
            Section(footer = "Records walks in the background. Walking and jogging count; bikes and cars don't.") {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Switch) { onAlwaysOn(!alwaysOn) }
                        .semantics { contentDescription = "Always on" }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    BasicText("Always on", style = Type.body, modifier = Modifier.weight(1f))
                    Toggle(alwaysOn)
                }
            }
            if (locationWarning) {
                Section(footer = null) {
                    Row(
                        verticalAlignment = Alignment.Top,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
                    ) {
                        WarningTriangle(Modifier.padding(top = 2.dp).size(18.dp, 16.dp))
                        BasicText(
                            "Set Location to \"Allow all the time\" so walks record when the app's closed.",
                            style = Type.body.copy(color = SYSTEM_ORANGE),
                        )
                    }
                    Divider()
                    RowButton("Open Settings", Walkies.burnt, enabled = true, onClick = onOpenSettings)
                }
            }
            if (permissionsMissing) {
                Section(footer = if (locationWarning) null else "Walkies is missing a permission or two, so walks may not record with it closed.") {
                    RowButton("Fix permissions", Walkies.burnt, enabled = true, onClick = onFixPermissions)
                }
            }
        }
        if (confirmingSignOut) {
            WalkiesDialog(
                "Sign out of Walkies?",
                "This clears Walkies off this phone. Everything's saved in your account and comes back when you sign in again.",
                listOf(DialogButton("Sign out", destructive = true, action = onSignOut), DialogButton("Cancel", bold = true)),
                onDismiss = { confirmingSignOut = false },
            )
        }
        cantSignOut?.let {
            WalkiesDialog("Not yet", it, listOf(DialogButton("OK", bold = true)), onDismiss = { cantSignOut = null })
        }
        notUploaded?.let { count ->
            WalkiesDialog(
                "Not uploaded yet",
                "$count things haven't uploaded to your account yet. If you sign out now, they'll be lost.",
                listOf(DialogButton("Wait", bold = true), DialogButton("Sign out anyway", destructive = true, action = onSignOut)),
                onDismiss = { notUploaded = null },
            )
        }
    }
}

private val red = Color(0.85f, 0.2f, 0.17f)

/** SwiftUI's .orange, which the iPhone's warning uses. */
private val SYSTEM_ORANGE = Color(1f, 0.584f, 0f)

/** SF Symbols' exclamationmark.triangle.fill, in orange. */
@Composable
private fun WarningTriangle(modifier: Modifier) {
    androidx.compose.foundation.Canvas(modifier) {
        val w = size.width
        val h = size.height
        val triangle = androidx.compose.ui.graphics.Path().apply {
            moveTo(w / 2, 0f)
            lineTo(w, h)
            lineTo(0f, h)
            close()
        }
        drawPath(triangle, SYSTEM_ORANGE, style = androidx.compose.ui.graphics.drawscope.Fill)
        drawPath(triangle, SYSTEM_ORANGE, style = androidx.compose.ui.graphics.drawscope.Stroke(w * 0.12f, join = androidx.compose.ui.graphics.StrokeJoin.Round))
        val stroke = w * 0.12f
        drawLine(Color.White, androidx.compose.ui.geometry.Offset(w / 2, h * 0.36f), androidx.compose.ui.geometry.Offset(w / 2, h * 0.66f), stroke, androidx.compose.ui.graphics.StrokeCap.Round)
        drawCircle(Color.White, stroke * 0.6f, androidx.compose.ui.geometry.Offset(w / 2, h * 0.84f))
    }
}

/** A row with its value on the right in grey (LabeledContent). */
@Composable
private fun Labeled(label: String, value: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
    ) {
        BasicText(label, style = Type.body)
        BasicText(
            value,
            style = Type.body.copy(color = Walkies.ink.copy(alpha = 0.5f), textAlign = TextAlign.End),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun RowButton(title: String, colour: Color, enabled: Boolean, onClick: () -> Unit) {
    BasicText(
        title,
        style = Type.body.copy(color = if (enabled) colour else colour.copy(alpha = 0.4f)),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 11.dp),
    )
}

@Composable
private fun Divider() {
    Box(Modifier.fillMaxWidth().padding(start = 16.dp).height(1.dp).background(Walkies.ink.copy(alpha = 0.08f)))
}

@Composable
private fun Section(footer: String?, header: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        header?.let {
            BasicText(it.uppercase(), style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.6f)), modifier = Modifier.padding(horizontal = 16.dp))
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Color.White),
            content = content,
        )
        footer?.let {
            BasicText(it, style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.6f)), modifier = Modifier.padding(horizontal = 16.dp))
        }
    }
}

/** An iOS switch, in the app's burnt orange when it's on (the iPhone tints everything with it). */
@Composable
private fun Toggle(on: Boolean) {
    val track by animateColorAsState(if (on) Walkies.burnt else Walkies.ink.copy(alpha = 0.15f), label = "track")
    val knob by animateDpAsState(if (on) 22.dp else 2.dp, label = "knob")
    Box(Modifier.size(51.dp, 31.dp).clip(RoundedCornerShape(50)).background(track)) {
        Box(
            Modifier
                .padding(start = knob, top = 2.dp)
                .size(27.dp)
                .softShadow(CircleShape, 2.dp, 1.dp, 0.2f, Color.White)
                .background(Color.White, CircleShape),
        )
    }
}
