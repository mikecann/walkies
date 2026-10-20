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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Settings, as far as stage 3 goes: the Always on switch, and a way back into the
 * setup when something's missing. Laid out like the iPhone's grouped Form.
 */
@Composable
fun SettingsSheet(
    alwaysOn: Boolean,
    onAlwaysOn: (Boolean) -> Unit,
    /** Something the setup asks for is missing. */
    permissionsMissing: Boolean,
    onFixPermissions: () -> Unit,
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
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
            Spacer(Modifier.weight(1f))
            BasicText(
                "Done",
                style = Type.body.copy(fontWeight = FontWeight.SemiBold, color = Walkies.burnt),
                modifier = Modifier.clickable(role = Role.Button, onClick = onClose).padding(6.dp),
            )
        }
        BasicText(
            "Settings",
            style = Type.headline.copy(fontFamily = roundedFont(), fontWeight = FontWeight.Black, fontSize = 34.sp),
            modifier = Modifier.padding(start = 4.dp, bottom = 16.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(24.dp), modifier = Modifier.widthIn(max = 600.dp)) {
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
            if (permissionsMissing) {
                Section(footer = null) {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(role = Role.Button, onClick = onFixPermissions)
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    ) {
                        BasicText(
                            "⚠︎ Walkies is missing a permission or two, so walks may not record with it closed.",
                            style = Type.subheadline.copy(color = Walkies.orange),
                        )
                        BasicText("Fix permissions", style = Type.body.copy(color = Walkies.burnt, fontWeight = FontWeight.SemiBold))
                    }
                }
            }
        }
    }
}

@Composable
private fun Section(footer: String?, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
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

/** An iOS switch: green when it's on. */
@Composable
private fun Toggle(on: Boolean) {
    val track by animateColorAsState(if (on) Color(0.2f, 0.78f, 0.35f) else Walkies.ink.copy(alpha = 0.15f), label = "track")
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
