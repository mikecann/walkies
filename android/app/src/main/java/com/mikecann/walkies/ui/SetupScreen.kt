package com.mikecann.walkies.ui

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikecann.walkies.location.Permissions

/** One page of the setup, each asking for one thing. */
enum class SetupStep { Location, AllTheTime, Activity, Secrets, Battery, Samsung }

/**
 * The pages to show. The first time it's all of them, as on the iPhone; from Settings
 * it's just what's missing.
 */
fun setupSteps(context: Context, firstRun: Boolean): List<SetupStep> = buildList {
    if (firstRun || !Permissions.location(context)) add(SetupStep.Location)
    if (!Permissions.backgroundLocation(context)) add(SetupStep.AllTheTime)
    if (!Permissions.activity(context)) add(SetupStep.Activity)
    if (!Permissions.notifications(context)) add(SetupStep.Secrets)
    val battery = Permissions.batteryUnrestricted(context)
    if (!battery) add(SetupStep.Battery)
    if (Permissions.isSamsung && (firstRun || !battery)) add(SetupStep.Samsung)
}

/**
 * First run (SetupView.swift). Walkies only really works always on, so this asks for
 * what that needs one prompt at a time, with a line on what each is for: location,
 * then all the time, physical activity, notifications for secrets, and the battery.
 * Every page after the first can be skipped, and Settings can bring back what's missing.
 */
@Composable
fun SetupScreen(firstRun: Boolean, onLocationAnswered: () -> Unit, onDone: () -> Unit) {
    val context = LocalContext.current
    val steps = remember { setupSteps(context, firstRun) }
    var index by remember { mutableIntStateOf(0) }
    if (steps.isEmpty()) {
        LaunchedEffect(Unit) { onDone() }
        return
    }
    val step = steps[index.coerceAtMost(steps.lastIndex)]

    fun next() {
        var i = index + 1
        // No point asking for all the time without while using.
        while (i < steps.size && steps[i] == SetupStep.AllTheTime && !Permissions.location(context)) i++
        if (i >= steps.size) onDone() else index = i
    }

    val location = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        onLocationAnswered()
        next()
    }
    val settingsPage = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { next() }
    // Android stops showing a prompt once it's been turned down twice, and answers
    // straight away. Then the only way is the settings page.
    var askedAt by remember { mutableLongStateOf(0L) }
    val single = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted && SystemClock.elapsedRealtime() - askedAt < 400) {
            settingsPage.launch(appDetails(context))
        } else {
            next()
        }
    }
    fun ask(permission: String) {
        askedAt = SystemClock.elapsedRealtime()
        single.launch(permission)
    }

    fun act() {
        when (step) {
            SetupStep.Location ->
                if (Permissions.location(context)) next()
                else location.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
            // On Android 11 and up this goes straight to the location settings page.
            SetupStep.AllTheTime -> ask(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            SetupStep.Activity -> ask(Manifest.permission.ACTIVITY_RECOGNITION)
            SetupStep.Secrets ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) ask(Manifest.permission.POST_NOTIFICATIONS) else next()
            SetupStep.Battery -> {
                val ask = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
                try {
                    settingsPage.launch(ask)
                } catch (e: ActivityNotFoundException) {
                    settingsPage.launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                }
            }
            SetupStep.Samsung -> openSamsungBattery(context)
        }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxSize()
            .background(Walkies.cream)
            .systemBarsPadding()
            .padding(24.dp),
    ) {
        Crossfade(step, label = "setup", modifier = Modifier.weight(1f).widthIn(max = 480.dp)) { page ->
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxSize()) {
                Spacer(Modifier.weight(1f))
                Box(contentAlignment = Alignment.Center, modifier = Modifier.height(190.dp).fillMaxWidth()) { Art(page) }
                Spacer(Modifier.height(28.dp))
                Words(page)
                Spacer(Modifier.weight(1f))
            }
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.widthIn(max = 480.dp),
        ) {
            footnote(step)?.let {
                BasicText(it, style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.6f), textAlign = TextAlign.Center))
            }
            StickerButton(onClick = { act() }) {
                BasicText(buttonTitle(step, context), style = Type.title3.copy(fontWeight = FontWeight.SemiBold, color = Color.White))
            }
            if (step != SetupStep.Location) {
                BasicText(
                    if (step == SetupStep.Samsung) "Done" else "Not now",
                    style = Type.subheadline.copy(fontWeight = FontWeight.SemiBold, color = Walkies.ink.copy(alpha = 0.6f)),
                    modifier = Modifier.clickable(role = Role.Button) { next() }.padding(4.dp),
                )
            }
            if (steps.size > 1) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 4.dp)) {
                    steps.forEachIndexed { i, _ ->
                        Box(Modifier.size(10.dp, 11.dp).background(if (i == index) Walkies.burnt else Walkies.ink.copy(alpha = 0.2f), Hexagon()))
                    }
                }
            }
        }
    }
}

@Composable
private fun Art(step: SetupStep) {
    when (step) {
        SetupStep.Location -> Picture("icon-walk", 190.dp, -8f)
        SetupStep.AllTheTime -> Picture("icon-map", 180.dp, 6f)
        SetupStep.Activity -> Box(contentAlignment = Alignment.Center) {
            Picture("sticker-a-piano-on-a-truck", 120.dp, 10f, x = 70.dp, y = 20.dp)
            Picture("icon-walk", 150.dp, -8f, x = (-36).dp, y = (-6).dp)
        }
        SetupStep.Secrets -> Box(contentAlignment = Alignment.Center) {
            Picture("sticker-the-sundial-in-the-scrub", 120.dp, 9f, x = 70.dp, y = 16.dp)
            Picture("sticker-a-rest-stop-for-whales", 120.dp, -10f, x = (-72).dp, y = 22.dp)
            Picture("icon-book", 130.dp, 0f, y = (-12).dp)
        }
        SetupStep.Battery -> Picture("icon-gear", 170.dp, -6f)
        SetupStep.Samsung -> Picture("icon-idea", 170.dp, 6f)
    }
}

@Composable
private fun Picture(name: String, size: Dp, angle: Float, x: Dp = 0.dp, y: Dp = 0.dp) {
    val image = assetImage(name) ?: return
    Image(image, contentDescription = null, modifier = Modifier.offset(x, y).size(size).rotate(angle))
}

@Composable
private fun Words(step: SetupStep) {
    val (title, body) = when (step) {
        SetupStep.Location -> "Just head out" to
            "Walkies runs quietly in the background. Whenever you're out on foot, it clears the clouds as you go, so there's nothing to start or stop."
        SetupStep.AllTheTime -> "Even when it's closed" to
            "For walks to count with Walkies closed and your phone in your pocket, it needs your location all the time."
        SetupStep.Activity -> "Walking, not driving" to
            "Physical activity lets Walkies tell walking from cycling or driving, and rest the GPS while you're sitting still."
        SetupStep.Secrets -> "Secrets hide under the clouds" to
            "Local history and odd little stories are tucked under some of the tiles. Walkies can give you a ping when you walk over one."
        SetupStep.Battery -> "Keep Walkies awake" to
            "Android puts apps to sleep to save battery, and a sleeping Walkies misses walks. It rests the GPS while you're sitting still, so it hardly uses any."
        SetupStep.Samsung -> "One more for Samsung" to
            "Samsung phones put apps to sleep on their own too. In Battery settings:"
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        BasicText(
            title,
            style = Type.headline.copy(fontFamily = roundedFont(), fontWeight = FontWeight.Black, fontSize = 34.sp, lineHeight = 38.sp, textAlign = TextAlign.Center),
        )
        BasicText(body, style = Type.body.copy(color = Walkies.ink.copy(alpha = 0.7f), textAlign = TextAlign.Center))
        if (step == SetupStep.Samsung) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 4.dp)) {
                for (line in listOf(
                    "1. Tap Background usage limits.",
                    "2. Open Never sleeping apps and add Walkies.",
                    "3. If Walkies is in Sleeping apps or Deep sleeping apps, take it out.",
                )) {
                    BasicText(line, style = Type.body.copy(color = Walkies.ink.copy(alpha = 0.8f)))
                }
            }
        }
    }
}

private fun footnote(step: SetupStep): String? = when (step) {
    SetupStep.Location -> "Android asks a few things, one at a time. For location, tap While using the app."
    SetupStep.AllTheTime ->
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) "On the next screen, pick Allow all the time, then come back."
        else "Pick Allow all the time."
    SetupStep.Battery -> "Tap Allow on the next screen."
    else -> null
}

private fun buttonTitle(step: SetupStep, context: Context) = when (step) {
    SetupStep.Location -> if (Permissions.location(context)) "Carry on" else "Allow location"
    SetupStep.AllTheTime -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) "Open location settings" else "Allow all the time"
    SetupStep.Activity -> "Allow physical activity"
    SetupStep.Secrets -> "Allow notifications"
    SetupStep.Battery -> "Allow"
    SetupStep.Samsung -> "Open battery settings"
}

private fun appDetails(context: Context) =
    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))

/**
 * Samsung's battery page, where Background usage limits lives. Its address has moved
 * between One UI versions, so try each, then the usual battery page, then the app's own.
 */
private fun openSamsungBattery(context: Context) {
    val candidates = listOf(
        Intent().setComponent(ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity")),
        Intent().setComponent(ComponentName("com.samsung.android.sm", "com.samsung.android.sm.battery.ui.BatteryActivity")),
        Intent(Intent.ACTION_POWER_USAGE_SUMMARY),
        appDetails(context),
    )
    for (intent in candidates) {
        try {
            context.startActivity(intent)
            return
        } catch (e: ActivityNotFoundException) {
            continue
        } catch (e: SecurityException) {
            continue
        }
    }
}
