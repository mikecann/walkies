package com.mikecann.walkies.ui

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.AppModel
import com.mikecann.walkies.model.LevelMeter
import com.mikecann.walkies.model.Progression
import com.mikecann.walkies.model.SwiftDate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Your progress, a tab of its own (ProgressPage in ProgressView.swift): your level and
 * what's earned it, any level-up rewards to choose, this week's quests, the shell shop,
 * the wardrobe and the spyglass. One part at a time, picked from the row along the top,
 * and each keeps its own place as you scroll.
 */
@Composable
fun ProgressPage(model: AppModel, section: ProgressSection, onSection: (ProgressSection) -> Unit) {
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    @Suppress("UNUSED_VARIABLE") val revision = rememberRevision(model::listen)
    val sounds = remember { SoundFX(context) }
    DisposableEffect(sounds) { onDispose { sounds.release() } }
    LaunchedEffect(sounds) { withContext(Dispatchers.Default) { sounds.prepare() } }

    // The model has no timer. Keep quests and the ring's countdown current while this stays open.
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }

    var purchase by remember { mutableStateOf<Progression.Item?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var noticeId by remember { mutableIntStateOf(0) }
    LaunchedEffect(noticeId) {
        if (notice == null) return@LaunchedEffect
        delay(3000)
        notice = null
    }
    fun showNotice(text: String) {
        notice = text
        noticeId++
    }
    fun celebrate(text: String) {
        sounds.play(SoundFX.Sound.Chime)
        haptics.performHapticFeedback(HapticFeedbackType.Confirm)
        showNotice(text)
    }

    // One for each part, so each stays scrolled where you left it.
    val scrolls = ProgressSection.entries.map { rememberScrollState() }

    Box(Modifier.fillMaxSize().background(PAGE_BACKGROUND).statusBarsPadding()) {
        Column(Modifier.fillMaxSize()) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 10.dp, top = 8.dp, bottom = 4.dp)) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { ShellBalance(model.balance) }
                BasicText("Your progress", style = Type.headline)
                Spacer(Modifier.weight(1f))
            }
            SectionPicker(section, onSection)
            key(section) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(22.dp),
                    modifier = Modifier.fillMaxSize().verticalScroll(scrolls[section.ordinal]).padding(16.dp),
                ) {
                    val wear = { item: Progression.Item ->
                        if (model.equip(item.id)) {
                            haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                            showNotice("${item.name} equipped")
                        } else {
                            showNotice("Couldn't equip that just now.")
                        }
                    }
                    when (section) {
                        ProgressSection.Level -> LevelSection(model) { level, choice, reward ->
                            if (model.claim(level, choice)) celebrate("${rewardName(reward)} chosen")
                            else showNotice("That reward has already been chosen.")
                        }
                        ProgressSection.Quests -> QuestsSection(model, now)
                        ProgressSection.Shop -> ShopSection(model, onBuy = { purchase = it }, onWear = wear)
                        ProgressSection.Wardrobe -> WardrobeSection(model, wear)
                        ProgressSection.Spyglass -> SpyglassSection(model, now) {
                            if (model.useSpyglass()) celebrate("Your hint is on the map")
                            else showNotice("Couldn't use that just now. Check your selected place.")
                        }
                    }
                }
            }
        }

        // Keeps showing the last notice while it shrinks away.
        var shown by remember { mutableStateOf("") }
        notice?.let { shown = it }
        androidx.compose.animation.AnimatedVisibility(
            notice != null,
            enter = scaleIn(spring(dampingRatio = 0.8f, stiffness = 500f)) + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp),
        ) {
            BasicText(
                shown,
                style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center),
                modifier = Modifier.stickerCard(RoundedCornerShape(18.dp)).padding(16.dp),
            )
        }
    }

    purchase?.let { item ->
        WalkiesDialog(
            "Buy ${item.name} for ${item.price} shells?",
            if (item.group == null) "One hint for your next secret hunt." else "You'll own it and wear it straight away.",
            listOf(
                DialogButton("Buy for ${item.price} shells", bold = true) {
                    if (model.buy(item.id)) celebrate(if (item.group == null) "Spyglass added" else "${item.name} equipped")
                    else showNotice("Couldn't buy that just now. Check your shells and try again.")
                },
                DialogButton("Not now"),
            ),
            onDismiss = { purchase = null },
        )
    }
}

/** The row of pills along the top of the progress page. The one you're on is filled in. */
@Composable
private fun SectionPicker(selected: ProgressSection, onSelect: (ProgressSection) -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .selectableGroup(),
    ) {
        for (section in ProgressSection.entries) {
            val isSelected = section == selected
            BasicText(
                section.title,
                style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold, color = if (isSelected) Walkies.cream else Walkies.burnt),
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (isSelected) Walkies.burnt else Walkies.cream)
                    .selectable(isSelected, role = Role.Tab) { onSelect(section) }
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
    }
}

/** White under 45% sand, like the iPhone's page over its system background. */
private val PAGE_BACKGROUND = Color(0.963f, 0.937f, 0.889f)

private val ink70 = Walkies.ink.copy(alpha = 0.7f)
private val ink65 = Walkies.ink.copy(alpha = 0.65f)

@Composable
private fun ProgressCard(modifier: Modifier = Modifier, spacing: Dp = 16.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(
        verticalArrangement = Arrangement.spacedBy(spacing),
        modifier = modifier.fillMaxWidth().stickerCard(RoundedCornerShape(24.dp)).padding(18.dp),
        content = content,
    )
}

@Composable
private fun SheetTitle(text: String) {
    BasicText(text, style = Type.headline.copy(fontFamily = roundedFont(), fontWeight = FontWeight.Black, fontSize = 22.sp))
}

@Composable
private fun SectionTitle(text: String, art: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        ProgressArt(art, 52.dp)
        SheetTitle(text)
    }
}

@Composable
private fun LevelSection(model: AppModel, onClaim: (level: Int, choice: String, reward: String) -> Unit) {
    ProgressCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            ProgressArt("progress-level-star", 72.dp)
            Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                SheetTitle("Level ${model.level}")
                BasicText("${model.xp} XP earned by walking", style = Type.subheadline)
                ProgressBar(LevelMeter(model.xp).fraction, Modifier.fillMaxWidth())
                BasicText("${model.xpToNextLevel} XP to Level ${model.level + 1}", style = Type.caption)
            }
        }
        BasicText("Every shell you earn on a walk adds XP. Spending shells keeps your XP.", style = Type.footnote.copy(color = ink70))
        val earned = model.earnedBreakdown
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            EarnedRow("Tiles", earned.tiles)
            EarnedRow("Secrets", earned.secrets)
            EarnedRow("Place milestones", earned.milestones)
            EarnedRow("Walking streaks", earned.streaks)
            EarnedRow("Quests", earned.quests)
        }
        for (level in model.pendingPicks) RewardCard(model, level, onClaim)
    }
}

@Composable
private fun EarnedRow(text: String, value: Int) {
    Row(Modifier.fillMaxWidth()) {
        BasicText(text, style = Type.subheadline, modifier = Modifier.weight(1f))
        BasicText("$value", style = Type.subheadline.copy(fontFeatureSettings = "tnum"))
    }
}

@Composable
private fun RewardCard(model: AppModel, level: Int, onClaim: (level: Int, choice: String, reward: String) -> Unit) {
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().background(Walkies.sand.copy(alpha = 0.6f), RoundedCornerShape(20.dp)).padding(12.dp),
    ) {
        BasicText(
            "Level $level reward: choose one",
            style = Type.headline.copy(fontFamily = roundedFont(), fontWeight = FontWeight.Black),
        )
        // Slot identity matters: the fallback menu can have two shell bags.
        val choices = model.picks(level)
        AdaptiveGrid(choices.size, minimum = 88.dp, spacing = 8.dp, rowSpacing = 8.dp) { i ->
            val choice = choices[i]
            val duplicate = choice in model.owned
            val reward = if (duplicate) Progression.SHELL_BAG else choice
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .pressScale({ onClaim(level, choice, reward) }, label = "Choose ${rewardName(reward)} for level $level")
                    .background(Walkies.cream, RoundedCornerShape(16.dp))
                    .border(1.dp, Walkies.burnt.copy(alpha = 0.4f), RoundedCornerShape(16.dp))
                    .padding(8.dp),
            ) {
                ProgressItemArt(reward, Modifier.fillMaxWidth().height(62.dp))
                Box(Modifier.fillMaxWidth().heightIn(min = 34.dp), contentAlignment = Alignment.Center) {
                    BasicText(rewardName(reward), style = Type.caption.copy(fontWeight = FontWeight.Bold, textAlign = TextAlign.Center))
                }
                if (duplicate) {
                    BasicText("Already owned, so a shell bag instead", style = Type.caption.copy(fontSize = 11.sp, textAlign = TextAlign.Center))
                }
            }
        }
    }
}

@Composable
private fun QuestsSection(model: AppModel, now: Long) {
    ProgressCard {
        SectionTitle("This week's quests", "progress-quest-scroll")
        for (quest in model.weeklyQuests) {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    BasicText(quest.name, style = Type.headline, modifier = Modifier.weight(1f))
                    ShellBalance(quest.reward, prefix = "+")
                    if (quest.isComplete) CheckCircle(Modifier.padding(start = 4.dp).size(20.dp), Walkies.badgeTeal, filled = true, label = "Complete")
                }
                ProgressBar(min(1.0, quest.progress / quest.target), Modifier.fillMaxWidth())
                BasicText(questProgressText(quest.progress, quest.kind), style = Type.caption)
            }
        }
        BasicText("New quests ${resetText(now)}", style = Type.footnote.copy(color = ink65))
    }
}

/** When this week's quests end, on the phone's own clock: "Monday 12:00 am". */
private fun resetText(now: Long): String {
    val zone = ZoneId.systemDefault()
    val end = Progression.week(SwiftDate.epoch(now / 1000.0), zone).end
    val time = Instant.ofEpochSecond(end.epochSeconds.toLong()).atZone(zone)
    return DateTimeFormatter.ofPattern("EEEE h:mm a", Locale.getDefault()).format(time)
}

@Composable
private fun ShopSection(model: AppModel, onBuy: (Progression.Item) -> Unit, onWear: (Progression.Item) -> Unit) {
    ProgressCard {
        SectionTitle("Shell shop", "progress-shop")
        BasicText(
            "A different look for your next walk. Shells buy looks and hints; walking uncovers the map. Tap Wear to switch to anything you own, free looks included.",
            style = Type.footnote.copy(color = ink70),
        )
        for (group in Progression.Group.entries) {
            BasicText(group.displayName, style = Type.headline, modifier = Modifier.padding(top = 4.dp))
            for (item in Progression.catalog.filter { it.group == group }) ShopRow(model, item, onBuy, onWear)
        }
        Progression.item("spyglass")?.let { item ->
            BasicText("Spyglasses · ${model.spyglasses} left", style = Type.headline)
            ShopRow(model, item, onBuy, onWear)
        }
    }
}

@Composable
private fun ShopRow(model: AppModel, item: Progression.Item, onBuy: (Progression.Item) -> Unit, onWear: (Progression.Item) -> Unit) {
    val balance = model.balance
    val owned = item.id in model.owned
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
    ) {
        ProgressItemArt(item.id, Modifier.size(54.dp, 58.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.weight(1f)) {
            BasicText(item.name, style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold))
            if (item.isFree) BasicText("Free", style = Type.caption) else ShellBalance(item.price)
            if (!owned && balance < item.price) {
                BasicText("${item.price - balance} more shells needed", style = Type.caption.copy(fontSize = 11.sp, color = ink65))
            }
        }
        val group = item.group
        when {
            group != null && model.equipped[group] == item.id -> Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Tick(Modifier.size(11.dp), Walkies.badgeTeal)
                BasicText("Equipped", style = Type.caption.copy(fontWeight = FontWeight.SemiBold, color = Walkies.badgeTeal))
            }
            // Owned looks are worn from here too, not only from the Wardrobe.
            owned && group != null -> BasicText(
                "Wear",
                style = Type.subheadline.copy(fontWeight = FontWeight.Bold, color = Walkies.burnt),
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(Walkies.badgeGreen.copy(alpha = 0.3f))
                    .clickable(role = Role.Button, onClickLabel = "Wear ${item.name}") { onWear(item) }
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            )
            owned -> BasicText("Owned", style = Type.caption.copy(fontWeight = FontWeight.SemiBold))
            else -> {
                val affordable = balance >= item.price
                BasicText(
                    "Buy",
                    style = Type.subheadline.copy(fontWeight = FontWeight.Bold, color = Walkies.burnt),
                    modifier = Modifier
                        .alpha(if (affordable) 1f else 0.5f)
                        .clip(RoundedCornerShape(50))
                        .background(Walkies.sand)
                        .clickable(enabled = affordable, role = Role.Button) { onBuy(item) }
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
        }
    }
}

@Composable
private fun WardrobeSection(model: AppModel, onEquip: (Progression.Item) -> Unit) {
    ProgressCard {
        SheetTitle("Your wardrobe")
        BasicText("Tap something you own to wear it.", style = Type.footnote)
        for (group in Progression.Group.entries) {
            BasicText(group.displayName, style = Type.headline)
            val items = Progression.catalog.filter { it.group == group && it.id in model.owned }
            AdaptiveGrid(items.size, minimum = 100.dp, spacing = 8.dp, rowSpacing = 10.dp) { i ->
                val item = items[i]
                val equipped = model.equipped[group] == item.id
                val shape = RoundedCornerShape(16.dp)
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
                    modifier = Modifier
                        .fillMaxWidth()
                        .pressScale({ onEquip(item) })
                        .background(if (equipped) Walkies.badgeGreen.copy(alpha = 0.25f) else Walkies.sand.copy(alpha = 0.35f), shape)
                        .border(2.dp, if (equipped) Walkies.badgeTeal else Color.Transparent, shape)
                        .heightIn(min = 128.dp)
                        .padding(8.dp)
                        .semantics(mergeDescendants = true) {},
                ) {
                    ProgressItemArt(item.id, Modifier.fillMaxWidth().height(58.dp))
                    BasicText(item.name, style = Type.caption.copy(fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center))
                    BasicText(
                        if (equipped) "Equipped" else "Wear this",
                        style = Type.caption.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = if (equipped) Walkies.badgeTeal else Walkies.burnt),
                    )
                }
            }
        }
    }
}

@Composable
private fun SpyglassSection(model: AppModel, now: Long, onUse: () -> Unit) {
    val ring = model.activeSpyglassRing
    val city = model.selectedCity
    val hasSecret = city?.stickers?.keys?.any { model.foundStickers[it] == null } == true
    ProgressCard(spacing = 12.dp) {
        SectionTitle("Spyglass", "progress-spyglass")
        BasicText("${model.spyglasses} left", style = Type.headline)
        BasicText(
            "Shows a gold ring somewhere round an unfound secret in your selected place. It lasts for 3 hours, or until you find the secret. You'll still need to walk there.",
            style = Type.subheadline,
        )
        if (ring != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ClockMark(Modifier.size(15.dp))
                BasicText(
                    "Hint active · ${Format.duration(max(0.0, ring.expiresAt.epochSeconds - now / 1000.0))} left",
                    style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                )
            }
        } else {
            val usable = model.spyglasses > 0 && hasSecret
            StickerButton(onClick = { if (usable) onUse() }, modifier = Modifier.alpha(if (usable) 1f else 0.5f)) {
                BasicText("Use a spyglass", style = Type.headline.copy(color = Color.White))
            }
            val hint = when {
                city == null -> "Add or select a place on the map first."
                !hasSecret -> "No unfound secrets in ${city.name}."
                model.spyglasses <= 0 -> "Pick one up in the Shop."
                else -> "Looking in ${city.name}"
            }
            BasicText(hint, style = Type.footnote)
        }
    }
}

/**
 * SwiftUI's LazyVGrid with adaptive columns: as many columns of at least [minimum]
 * as fit, sharing the width. On a small phone three reward picks wrap onto two rows.
 */
@Composable
private fun AdaptiveGrid(count: Int, minimum: Dp, spacing: Dp, rowSpacing: Dp, cell: @Composable (Int) -> Unit) {
    if (count == 0) return
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = max(1, floor((maxWidth + spacing) / (minimum + spacing)).toInt())
        Column(verticalArrangement = Arrangement.spacedBy(rowSpacing)) {
            for (start in 0 until count step columns) {
                Row(horizontalArrangement = Arrangement.spacedBy(spacing), modifier = Modifier.fillMaxWidth()) {
                    for (i in start until start + columns) {
                        Box(Modifier.weight(1f)) { if (i < count) cell(i) }
                    }
                }
            }
        }
    }
}

/** What a reward is called on its card. */
fun rewardName(id: String): String = when (id) {
    Progression.SHELL_BAG -> "50 shells"
    Progression.SPYGLASS_PAIR -> "2 spyglasses"
    else -> Progression.item(id)?.name ?: "Reward"
}

/** "1.20 km of 5 km", "Another place explored", or "12 of 25" (QuestProgressText in ProgressView.swift). */
fun questProgressText(progress: Double, kind: Progression.QuestKind): String = when (kind) {
    Progression.QuestKind.Metres5000 -> "${Format.distance(min(progress, kind.target))} of 5 km"
    Progression.QuestKind.AnotherPlace -> if (progress >= 1) "Another place explored" else "Try a place beyond your usual one"
    else -> "${min(progress, kind.target).toInt()} of ${kind.target.toInt()}"
}

/** A shell and how many (ShellBalance in ProgressView.swift). */
@Composable
fun ShellBalance(balance: Int, prefix: String = "") {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier.padding(horizontal = 4.dp).semantics(mergeDescendants = true) { contentDescription = "$prefix$balance shells" },
    ) {
        ProgressArt("progress-shell", 23.dp)
        BasicText("$prefix$balance", style = Type.subheadline.copy(fontWeight = FontWeight.Bold, fontFeatureSettings = "tnum"), maxLines = 1, softWrap = false)
    }
}

/** Under the place chip: your shells, your level, and a dot when a reward's waiting (ShellsChip). */
@Composable
fun ShellsChip(balance: Int, level: Int, rewardWaiting: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .pressScale(onClick, label = "$balance shells, level $level${if (rewardWaiting) ", reward waiting" else ""}")
            .stickerCard(RoundedCornerShape(50))
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        ShellBalance(balance)
        BasicText("Lv $level", style = Type.caption.copy(fontWeight = FontWeight.Black))
        if (rewardWaiting) Box(Modifier.size(7.dp).background(Walkies.orange, CircleShape))
    }
}

@Composable
fun ProgressArt(name: String, size: Dp) {
    val image = assetImage(name)
    if (image == null) {
        Spacer(Modifier.size(size))
        return
    }
    Image(image, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.size(size))
}

/** An item's picture: its artwork, or a drawn sample for styles without any (ProgressItemArt). */
@Composable
fun ProgressItemArt(id: String, modifier: Modifier = Modifier) {
    val artwork = when (id) {
        Progression.SHELL_BAG -> "progress-shell-bag"
        Progression.SPYGLASS_PAIR, "spyglass" -> "progress-spyglass"
        "marker.sneaker" -> "progress-marker-sneaker"
        "marker.boat" -> "progress-marker-boat"
        "marker.hat" -> "progress-marker-hat"
        "marker.lighthouse" -> "progress-marker-lighthouse"
        "cover.seashell" -> "progress-cover-seashell"
        "cover.map" -> "progress-cover-map"
        "cover.gold" -> "progress-cover-gold"
        else -> null
    }
    if (artwork != null) {
        val image = assetImage(artwork)
        if (image != null) Image(image, contentDescription = null, contentScale = ContentScale.Fit, modifier = modifier)
        else Spacer(modifier)
        return
    }
    val footprint = if (id == "trail.footprints") assetImage("progress-footprint") else null
    Canvas(modifier) {
        val pt = density
        val c = Offset(size.width / 2, size.height / 2)
        when (Progression.item(id)?.group) {
            Progression.Group.Marker -> {
                drawCircle(Color.White, 11 * pt, c)
                drawCircle(Walkies.orange, 7 * pt, c)
            }
            Progression.Group.Trail -> drawTrailSample(id, footprint)
            Progression.Group.Clouds -> {
                val colours = when (id) {
                    "clouds.sunset" -> listOf(SystemColours.orange, SystemColours.pink, SystemColours.yellow)
                    "clouds.storm" -> listOf(SystemColours.gray, SystemColours.indigo, SystemColours.gray)
                    "clouds.candy" -> listOf(SystemColours.pink, SystemColours.cyan, SystemColours.purple)
                    else -> listOf(Color.White, Color.White, Color.White)
                }
                for (i in 0 until 3) {
                    drawOval(
                        colours[i].copy(alpha = 0.8f),
                        topLeft = Offset(c.x + (-26 + i * 12) * pt, c.y + (-8 - if (i == 1) 9 else 0) * pt),
                        size = Size(28 * pt, 25 * pt),
                    )
                }
            }
            Progression.Group.Cover -> {
                val left = c.x - 18 * pt
                val top = c.y - 24 * pt
                drawRoundRect(Walkies.burnt, Offset(left, top), Size(36 * pt, 48 * pt), CornerRadius(5 * pt))
                drawRect(Walkies.sand, Offset(left + 6 * pt, top + 3 * pt), Size(27 * pt, 42 * pt), style = Stroke(1 * pt))
            }
            Progression.Group.Celebration -> drawCelebrationSample(id, c)
            null -> Unit
        }
    }
}

private fun DrawScope.drawTrailSample(id: String, footprint: androidx.compose.ui.graphics.ImageBitmap?) {
    val pt = density
    val colours = if (id == "trail.rainbow") listOf(Walkies.burnt, Walkies.orange, Walkies.badgeGreen, Walkies.badgeTeal, SystemColours.purple) else listOf(Walkies.badgeTeal)
    for (i in 0 until 7) {
        val p = Offset(size.width * (0.14f + i * 0.12f), size.height * (0.5f + sin(i.toDouble()).toFloat() * 0.2f))
        when (id) {
            "trail.footprints" -> footprint?.let {
                drawImage(it, srcOffset = androidx.compose.ui.unit.IntOffset.Zero, srcSize = androidx.compose.ui.unit.IntSize(it.width, it.height),
                    dstOffset = androidx.compose.ui.unit.IntOffset((p.x - 6 * pt).toInt(), (p.y - 7 * pt).toInt()),
                    dstSize = androidx.compose.ui.unit.IntSize((12 * pt).toInt(), (14 * pt).toInt()))
            }
            "trail.sparkles" -> drawIntoCanvas { canvas ->
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Walkies.orange.toArgb()
                    textSize = 14 * pt
                    textAlign = Paint.Align.CENTER
                    typeface = Typeface.DEFAULT
                }
                canvas.nativeCanvas.drawText("✦", p.x, p.y - (paint.ascent() + paint.descent()) / 2, paint)
            }
            else -> drawOval(colours[i % colours.size], Offset(p.x - 5 * pt, p.y - 3 * pt), Size(10 * pt, 6 * pt))
        }
    }
}

private fun DrawScope.drawCelebrationSample(id: String, c: Offset) {
    val pt = density
    val colours = listOf(Walkies.orange, Walkies.badgeTeal, Walkies.badgeGreen, SystemColours.pink)
    for (i in 0 until 12) {
        val angle = i * Math.PI / 6
        val radius = (i % 3 + 1) * 7.0 * pt
        val p = Offset((c.x + cos(angle) * radius).toFloat(), (c.y + sin(angle) * radius).toFloat())
        when (id) {
            "celebration.bubbles" -> {
                drawCircle(colours[i % 4].copy(alpha = 0.25f), 5 * pt, p)
                drawCircle(colours[i % 4].copy(alpha = 0.6f), 5 * pt, p, style = Stroke(1 * pt))
            }
            "celebration.fireworks" -> drawLine(
                colours[i % 4],
                Offset((c.x + cos(angle) * 10 * pt).toFloat(), (c.y + sin(angle) * 10 * pt).toFloat()),
                Offset((c.x + cos(angle) * 25 * pt).toFloat(), (c.y + sin(angle) * 25 * pt).toFloat()),
                2 * pt, StrokeCap.Round,
            )
            else -> drawRect(colours[i % 4], Offset(p.x - 3 * pt, p.y - 2 * pt), Size(6 * pt, 4 * pt))
        }
    }
}

/** SwiftUI's system colours in light mode, which the iPhone's samples and effects use. */
object SystemColours {
    val red = Color(1f, 0.231f, 0.188f)
    val orange = Color(1f, 0.584f, 0f)
    val yellow = Color(1f, 0.8f, 0f)
    val green = Color(0.204f, 0.78f, 0.349f)
    val cyan = Color(0.196f, 0.678f, 0.902f)
    val blue = Color(0f, 0.478f, 1f)
    val indigo = Color(0.345f, 0.337f, 0.839f)
    val purple = Color(0.686f, 0.322f, 0.871f)
    val pink = Color(1f, 0.176f, 0.333f)
    val gray = Color(0.557f, 0.557f, 0.576f)
}

/** SF Symbols' checkmark.circle(.fill). */
@Composable
fun CheckCircle(modifier: Modifier, colour: Color, filled: Boolean, label: String? = null) {
    Canvas(modifier.then(if (label != null) Modifier.semantics { contentDescription = label } else Modifier)) {
        val r = size.minDimension / 2
        val stroke = size.minDimension * 0.08f
        val tickColour = if (filled) Color.White else colour
        if (filled) drawCircle(colour, r) else drawCircle(colour, r - stroke / 2, style = Stroke(stroke))
        val path = Path().apply {
            moveTo(size.width * 0.3f, size.height * 0.52f)
            lineTo(size.width * 0.44f, size.height * 0.66f)
            lineTo(size.width * 0.71f, size.height * 0.36f)
        }
        drawPath(path, tickColour, style = Stroke(size.minDimension * 0.1f, cap = StrokeCap.Round, join = androidx.compose.ui.graphics.StrokeJoin.Round))
    }
}

/** SF Symbols' checkmark. */
@Composable
private fun Tick(modifier: Modifier, colour: Color) {
    Canvas(modifier) {
        val path = Path().apply {
            moveTo(size.width * 0.08f, size.height * 0.55f)
            lineTo(size.width * 0.38f, size.height * 0.85f)
            lineTo(size.width * 0.92f, size.height * 0.15f)
        }
        drawPath(path, colour, style = Stroke(size.minDimension * 0.18f, cap = StrokeCap.Round, join = androidx.compose.ui.graphics.StrokeJoin.Round))
    }
}

/** SF Symbols' clock. */
@Composable
private fun ClockMark(modifier: Modifier) {
    Canvas(modifier) {
        val stroke = size.minDimension * 0.1f
        val c = Offset(size.width / 2, size.height / 2)
        drawCircle(Walkies.ink, size.minDimension / 2 - stroke / 2, style = Stroke(stroke))
        drawLine(Walkies.ink, c, Offset(c.x, c.y - size.height * 0.28f), stroke, StrokeCap.Round)
        drawLine(Walkies.ink, c, Offset(c.x + size.width * 0.2f, c.y + size.height * 0.08f), stroke, StrokeCap.Round)
    }
}
