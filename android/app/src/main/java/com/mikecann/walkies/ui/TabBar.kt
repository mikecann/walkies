package com.mikecann.walkies.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Space for a page's last row to scroll above the dock and its raised hex. */
val LocalTabBarClearance = staticCompositionLocalOf { 0.dp }

/** The pill sits above either gesture navigation or the three-button navigation bar. */
@Composable
fun tabBarBottomGap() = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 12.dp

/** The B2 dock, with the current tab lifted out of the pill into an orange hex. */
@Composable
fun TabBar(selected: AppTab, rewards: Int, onSelect: (AppTab) -> Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        Box(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(64.dp)
                .softShadow(CircleShape, 24.dp, 10.dp, 0.16f, Walkies.cream)
                .softShadow(CircleShape, 8.dp, 3.dp, 0.18f, Walkies.cream)
                .background(Walkies.cream, CircleShape)
                .border(3.dp, Color.White, CircleShape),
        )
        Row(Modifier.fillMaxWidth().height(96.dp).padding(horizontal = 5.dp).selectableGroup()) {
            for (tab in AppTab.entries) {
                val isSelected = tab == selected
                val badge = if (tab == AppTab.Progress && rewards > 0) rewards else null
                // Compose's animation clock respects the system animation duration scale,
                // including disabled animations in accessibility settings.
                val pop by animateFloatAsState(
                    if (isSelected) 1f else 0.7f,
                    spring(dampingRatio = 0.65f, stiffness = 700f), label = "tab pop",
                )
                Box(Modifier.weight(1f).height(96.dp)) {
                    // Taps above the pill reach the page, except on the raised hex.
                    Box(
                        Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(if (isSelected) 96.dp else 64.dp)
                            .selectable(isSelected, role = Role.Tab) { if (!isSelected) onSelect(tab) }
                            .semantics {
                                contentDescription = if (badge != null) "${tab.title}, $badge ${if (badge == 1) "reward" else "rewards"} waiting" else tab.title
                            },
                    )
                    if (isSelected) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier.align(Alignment.TopCenter).offset(y = 1.dp)
                                .size(56.dp, 64.dp).scale(pop)
                                .softShadow(Hexagon(), 5.dp, 3.dp, 0.28f, Walkies.orange)
                                .background(Walkies.orange, Hexagon())
                                .border(3.5.dp, Color.White, Hexagon()),
                        ) {
                            TabIcon(tab, true, badge)
                        }
                    } else {
                        TabIcon(tab, false, badge, Modifier.align(Alignment.TopCenter).offset(y = 40.5.dp))
                    }
                    BasicText(
                        tab.title,
                        style = Type.caption.copy(
                            fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
                            color = if (isSelected) Walkies.orange else Walkies.ink.copy(alpha = 0.6f),
                        ),
                        maxLines = 1,
                        modifier = Modifier.align(Alignment.TopCenter).offset(y = 72.dp).clearAndSetSemantics {},
                    )
                }
            }
        }
    }
}

@Composable
private fun TabIcon(tab: AppTab, selected: Boolean, badge: Int?, modifier: Modifier = Modifier) {
    Box(modifier.size(27.dp)) {
        assetImage(tab.art)?.let {
            Image(
                it, contentDescription = null, modifier = Modifier.size(27.dp),
                alpha = if (selected) 1f else 0.85f,
                colorFilter = if (selected) ColorFilter.tint(Color.White) else null,
            )
        }
        if (badge != null) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.align(Alignment.TopEnd).offset(x = 11.dp, y = (-5).dp)
                    .widthIn(min = 18.dp).height(18.dp)
                    .background(Walkies.orange, CircleShape).border(1.5.dp, Color.White, CircleShape)
                    .padding(horizontal = 4.dp),
            ) {
                BasicText(
                    "$badge", style = Type.caption.copy(color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.clearAndSetSemantics {},
                )
            }
        }
    }
}
