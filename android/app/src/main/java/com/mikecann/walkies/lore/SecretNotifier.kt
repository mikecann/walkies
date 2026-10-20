package com.mikecann.walkies.lore

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.mikecann.walkies.MainActivity
import com.mikecann.walkies.R
import com.mikecann.walkies.location.Permissions

/**
 * Notifications for secrets found while the phone's in your pocket (Notifier.swift).
 * With the app on screen the secret pops up in the app instead. A channel of their
 * own, since the walk notification's is silent and these should make a sound.
 */
object SecretNotifier {
    private const val CHANNEL = "secrets"

    @SuppressLint("MissingPermission")
    fun stickersFound(context: Context, entries: List<LoreEntry>) {
        if (!Permissions.notifications(context)) return
        channel(context)
        val manager = NotificationManagerCompat.from(context)
        for (entry in entries) {
            val open = PendingIntent.getActivity(
                context, entry.id.hashCode(),
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra(MainActivity.EXTRA_STICKER, entry.id),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(0xFFC9573A.toInt())
                .setContentTitle("Secret found: ${entry.title}")
                .setContentText(entry.body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(entry.body))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            // The sticker art, as iOS attaches it, at half size (256 px is plenty here).
            val half = BitmapFactory.Options().apply { inSampleSize = 2 }
            runCatching {
                context.assets.open("images/sticker-${entry.id}.png").use { BitmapFactory.decodeStream(it, null, half) }
            }.getOrNull()?.let(builder::setLargeIcon)
            manager.notify("sticker-${entry.id}", 0, builder.build())
        }
    }

    private fun channel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Secrets found", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "A ping when you walk over a secret with Walkies closed"
            },
        )
    }
}
