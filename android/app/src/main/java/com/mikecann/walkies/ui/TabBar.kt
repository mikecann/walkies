package com.mikecann.walkies.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The map continues this far under the sheet, so it shows through the corners. */
val TabBarCornerRadius = 22.dp

/**
 * The tabs along the bottom, laid out like Material 3's NavigationBar (an indicator
 * pill behind the selected icon, the label under it) in the app's cream and orange,
 * with the app's own art for the icons. [rewardWaiting] puts the orange dot on Progress,
 * like the one on the shells chip.
 */
@Composable
fun TabBar(selected: AppTab, rewardWaiting: Boolean, onSelect: (AppTab) -> Unit) {
    val sheet = RoundedCornerShape(topStart = TabBarCornerRadius, topEnd = TabBarCornerRadius)
    Column(
        Modifier
            .fillMaxWidth()
            // The other pages end above the bar; keep the map beneath them covered.
            .then(if (selected != AppTab.Map) Modifier.background(Walkies.cream) else Modifier)
            .softShadow(sheet, 12.dp, (-3).dp, 0.24f, Walkies.cream)
            .background(Walkies.cream, sheet)
            .drawWithCache {
                val radius = TabBarCornerRadius.toPx()
                val stroke = 2.dp.toPx()
                val inset = stroke / 2
                val rim = Path().apply {
                    arcTo(Rect(inset, inset, radius * 2 - inset, radius * 2 - inset), 180f, 90f, true)
                    lineTo(size.width - radius, inset)
                    arcTo(Rect(size.width - radius * 2 + inset, inset, size.width - inset, radius * 2 - inset), 270f, 90f, false)
                }
                onDrawBehind { drawPath(rim, Color.White, style = Stroke(stroke)) }
            }
            .navigationBarsPadding()
            // Keep the row exactly where it was when the divider occupied this space.
            .padding(top = 1.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().height(72.dp).selectableGroup(),
        ) {
            for (tab in AppTab.entries) {
                val isSelected = tab == selected
                val badge = tab == AppTab.Progress && rewardWaiting
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier
                        .weight(1f)
                        .selectable(isSelected, role = Role.Tab) { onSelect(tab) }
                        .semantics { contentDescription = if (badge) "${tab.title}, reward waiting" else tab.title }
                        .padding(vertical = 6.dp),
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(56.dp, 32.dp)
                            .background(if (isSelected) Walkies.orange.copy(alpha = 0.18f) else Walkies.cream, RoundedCornerShape(50)),
                    ) {
                        assetImage(tab.art)?.let {
                            Image(it, contentDescription = null, modifier = Modifier.size(26.dp).alpha(if (isSelected) 1f else 0.55f))
                        }
                        if (badge) {
                            Box(
                                Modifier
                                    .align(Alignment.TopEnd)
                                    .offset(x = (-10).dp, y = 3.dp)
                                    .size(8.dp)
                                    .background(Walkies.orange, CircleShape),
                            )
                        }
                    }
                    BasicText(
                        tab.title,
                        style = Type.caption.copy(
                            fontSize = 12.sp,
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
                            color = if (isSelected) Walkies.orange else Walkies.ink.copy(alpha = 0.6f),
                        ),
                    )
                }
            }
        }
    }
}
