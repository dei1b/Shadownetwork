package com.example.shadownetwork

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.os.IBinder
import android.util.Log

class RelayForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent == null && !wasEnabled(this)) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (!isForeground) {
            try {
                startForeground(NOTIFICATION_ID, buildNotification())
                isForeground = true
            } catch (error: RuntimeException) {
                Log.w(TAG, "Could not bring relay service to the foreground", error)
                stopSelf(startId)
                return START_NOT_STICKY
            }
        }
        RelayEngineHost.getOrCreate(applicationContext, resumeRelay = true)
        return START_STICKY
    }

    override fun onDestroy() {
        isForeground = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Shadow Network Relay",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps offline peer discovery and message relay active."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(R.drawable.ic_stat_shadow_network)
            .setLargeIcon(BitmapFactory.decodeResource(resources, R.drawable.ic_notification_logo))
            .setColor(Color.rgb(181, 43, 50))
            .setContentTitle("Shadow Network relay active")
            .setContentText("Listening for nearby peers and queued messages.")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val TAG = "ShadowRelayService"
        private const val CHANNEL_ID = "shadow_network_relay"
        private const val NOTIFICATION_ID = 4208
        private const val ACTION_STOP = "com.example.shadownetwork.action.STOP_RELAY"
        private var isForeground = false

        fun wasEnabled(context: Context): Boolean =
            context.getSharedPreferences("relay_runtime", Context.MODE_PRIVATE).getBoolean("enabled", false)

        fun start(context: Context): Boolean {
            if (isForeground) return true
            val intent = Intent(context, RelayForegroundService::class.java)
            return runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                context.getSharedPreferences("relay_runtime", Context.MODE_PRIVATE).edit().putBoolean("enabled", true).apply()
            }.onFailure { Log.w(TAG, "Could not request relay service startup", it) }.isSuccess
        }

        fun stop(context: Context) {
            context.getSharedPreferences("relay_runtime", Context.MODE_PRIVATE).edit().putBoolean("enabled", false).apply()
            runCatching { context.stopService(Intent(context, RelayForegroundService::class.java)) }
        }
    }
}
