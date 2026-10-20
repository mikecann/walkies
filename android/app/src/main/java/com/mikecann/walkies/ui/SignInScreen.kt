package com.mikecann.walkies.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Which sign-in is under way, for its spinner. */
enum class SignInProvider { Google, Test }

/**
 * Signing in (SignInView.swift). Apple sign-in isn't on Android, so it's just Google,
 * plus test sign-in on debug builds.
 */
@Composable
fun SignInScreen(
    working: SignInProvider?,
    errorMessage: String?,
    showTestSignIn: Boolean,
    onGoogle: () -> Unit,
    onTest: () -> Unit,
) {
    val rounded = roundedFont()
    Box(
        contentAlignment = Alignment.TopCenter,
        modifier = Modifier
            .fillMaxSize()
            .background(Walkies.cream)
            .verticalScroll(rememberScrollState())
            .systemBarsPadding(),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(28.dp),
            modifier = Modifier.widthIn(max = 480.dp).fillMaxWidth().padding(24.dp),
        ) {
            Stickers(Modifier.padding(top = 48.dp))

            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                BasicText("Walkies", style = TextStyle(fontFamily = rounded, fontWeight = FontWeight.ExtraBold, fontSize = 44.sp, color = Walkies.ink))
                BasicText(
                    "Clear the clouds off your suburb one street at a time, and find the secrets hiding underneath.",
                    style = Type.body.copy(color = Walkies.ink.copy(alpha = 0.65f), textAlign = TextAlign.Center),
                )
            }

            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                StickerButton(onClick = { if (working == null) onGoogle() }, fill = Color.White) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (working == SignInProvider.Google) Spinner(20.dp) else GoogleG()
                        BasicText("Continue with Google", style = Type.headline.copy(color = Walkies.ink))
                    }
                }

                if (showTestSignIn) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier
                            .clickable(role = Role.Button) { if (working == null) onTest() }
                            .padding(vertical = 4.dp, horizontal = 8.dp),
                    ) {
                        if (working == SignInProvider.Test) Spinner(14.dp)
                        BasicText("Test sign-in (debug builds only)", style = Type.footnote.copy(color = Walkies.burnt))
                    }
                }

                errorMessage?.let {
                    BasicText("⚠︎ $it", style = Type.subheadline.copy(color = Color(0.85f, 0.2f, 0.17f)))
                }
            }

            BasicText(
                "Your walks are kept on your phone and backed up to your account. Walkies uses your email to let you know about things like new secrets.",
                style = Type.footnote.copy(color = Walkies.ink.copy(alpha = 0.6f), textAlign = TextAlign.Center),
            )
        }
    }
}

@Composable
private fun Stickers(modifier: Modifier) {
    Box(contentAlignment = Alignment.Center, modifier = modifier.fillMaxWidth().height(170.dp)) {
        Sticker("sticker-a-rest-stop-for-whales", 120.dp, -9f, (-78).dp, 10.dp)
        Sticker("sticker-the-sundial-in-the-scrub", 110.dp, 8f, 82.dp, 18.dp)
        Sticker("sticker-baudins-crew-lives-here", 130.dp, -2f, 0.dp, (-14).dp)
    }
}

@Composable
private fun Sticker(name: String, size: Dp, angle: Float, x: Dp, y: Dp) {
    val image = assetImage(name) ?: return
    Image(
        image, contentDescription = null,
        modifier = Modifier
            .offset(x, y)
            .rotate(angle)
            .size(size),
    )
}

/** Google's "G", in its four colours. */
@Composable
private fun GoogleG() {
    BasicText(
        "G",
        style = TextStyle(
            fontFamily = roundedFont(),
            fontWeight = FontWeight.Bold,
            fontSize = 20.sp,
            brush = Brush.sweepGradient(
                listOf(Color(0xFFEA4335), Color(0xFFFBBC05), Color(0xFF34A853), Color(0xFF4285F4), Color(0xFF4285F4), Color(0xFFEA4335)),
            ),
        ),
    )
}
