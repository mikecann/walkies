package com.mikecann.walkies.location

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.mikecann.walkies.AppModel
import com.mikecann.walkies.MainActivity
import com.mikecann.walkies.R
import com.mikecann.walkies.WalkiesApplication
import com.mikecann.walkies.ui.Format

/**
 * Keeps the process and the GPS going with the app closed, for always-on walks and
 * walks you started yourself. All the walk logic stays in the one AppModel; this is
 * just the ongoing notification that Android insists on.
 */
class TrackingService : Service() {
    private val app get() = application as WalkiesApplication

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_END_WALK) {
            val walk = app.model.activeWalk
            if (walk?.isAutomatic == true) app.model.endAutoWalk() else app.model.endWalk()
        }
        try {
            ServiceCompat.startForeground(this, ID, notification(this, app.model), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } catch (e: Exception) {
            // Not allowed from here (no background location, say). The fence and
            // Activity Recognition try again later.
            Log.e(TAG, "Couldn't start in the foreground", e)
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        app.refreshTracking()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val TAG = "TrackingService"
        private const val ID = 1
        private const val CHANNEL = "walks"
        private const val ACTION_END_WALK = "com.mikecann.walkies.END_WALK"

        var running = false
            private set
        private var shown: String? = null

        /** [inBackground]: only try if Android allows a location service to start from there. */
        fun start(context: Context, inBackground: Boolean) {
            if (running) return
            if (inBackground && !Permissions.backgroundLocation(context)) return
            channel(context)
            try {
                ContextCompat.startForegroundService(context, Intent(context, TrackingService::class.java))
                running = true
            } catch (e: Exception) {
                Log.e(TAG, "Couldn't start", e)
            }
        }

        fun stop(context: Context) {
            if (!running) return
            running = false
            shown = null
            context.stopService(Intent(context, TrackingService::class.java))
        }

        /** Keeps the notification up to date, without redrawing it for every fix. */
        @SuppressLint("MissingPermission")
        fun update(context: Context, model: AppModel) {
            if (!running || !Permissions.notifications(context)) return
            val key = summary(model)
            if (key == shown) return
            shown = key
            NotificationManagerCompat.from(context).notify(ID, notification(context, model))
        }

        private fun summary(model: AppModel): String {
            val walk = model.activeWalk ?: return "idle"
            if (model.autoWalkPending) return "pending ${model.pendingWalkDistance.toInt() / 10}"
            return "walk ${walk.id} ${walk.distance.toInt() / 10} ${walk.newTiles}"
        }

        private fun channel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Walks", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shows while Walkies is looking out for walks"
                    setShowBadge(false)
                },
            )
        }

        private fun notification(context: Context, model: AppModel): Notification {
            channel(context)
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(0xFFC9573A.toInt())
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            val walk = model.activeWalk
            when {
                walk == null -> builder
                    .setContentTitle("Walkies is keeping an eye out for walks")
                    .setContentText("Just head out. The clouds clear as you go.")
                    .setShowWhen(false)
                model.autoWalkPending -> builder
                    .setContentTitle("Walk pending, ${model.pendingWalkDistance.toInt()} m so far")
                    .setContentText("Counts once you're ${AppModel.AUTO_WALK_CONFIRM_DISTANCE.toInt()} m from where you started")
                    .setShowWhen(false)
                else -> {
                    val end = PendingIntent.getService(
                        context, 1,
                        Intent(context, TrackingService::class.java).setAction(ACTION_END_WALK),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    val tiles = if (walk.newTiles == 1) "1 new tile" else "${walk.newTiles} new tiles"
                    builder
                        .setContentTitle("On a walk")
                        .setContentText("${Format.distance(walk.distance)} · $tiles")
                        // The time ticks by itself.
                        .setWhen(walk.startedAt.ms.toLong())
                        .setShowWhen(true)
                        .setUsesChronometer(true)
                        .addAction(0, "End walk", end)
                }
            }
            return builder.build()
        }
    }
}
