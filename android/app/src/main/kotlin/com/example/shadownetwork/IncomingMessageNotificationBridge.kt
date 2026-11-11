package com.example.shadownetwork

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Posts local inbox notifications from the shared engine, even without an activity. */
internal class IncomingMessageNotificationBridge(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannels(
                listOf(
                    NotificationChannel(SOS_CHANNEL, "SOS alerts", NotificationManager.IMPORTANCE_HIGH),
                    NotificationChannel(CHAT_CHANNEL, "Chat messages", NotificationManager.IMPORTANCE_DEFAULT),
                ),
            )
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "show") {
            result.notImplemented()
            return
        }
        val hash = call.argument<String>("messageHash")
        val isSos = call.argument<Boolean>("isSos")
        if (hash.isNullOrBlank() || isSos == null) {
            result.error("INVALID_MESSAGE", "Missing notification message identity or type.", null)
            return
        }
        try {
            show(hash, isSos)
            result.success(null)
        } catch (_: SecurityException) {
            // The permission can change between checking it and posting.
            result.success(null)
        } catch (error: RuntimeException) {
            result.error("NOTIFICATION_FAILED", error.message, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun show(hash: String, isSos: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        if (!manager.areNotificationsEnabled()) return

        val intent = Intent(context, MainActivity::class.java).apply {
            action = "com.example.shadownetwork.action.OPEN_INCOMING_MESSAGE"
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openApp = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, if (isSos) SOS_CHANNEL else CHAT_CHANNEL)
        } else {
            Notification.Builder(context)
                .setPriority(if (isSos) Notification.PRIORITY_HIGH else Notification.PRIORITY_DEFAULT)
                .setDefaults(Notification.DEFAULT_ALL)
        }
        manager.notify(
            hash,
            0,
            builder
                .setSmallIcon(R.drawable.ic_stat_shadow_network)
                .setContentTitle(if (isSos) "New SOS alert" else "New message")
                .setContentText("Open ShadowNetwork to view it.")
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setOnlyAlertOnce(true)
                .setAutoCancel(true)
                .setContentIntent(openApp)
                .build(),
        )
    }

    companion object {
        private const val SOS_CHANNEL = "shadow_network_sos_alerts"
        private const val CHAT_CHANNEL = "shadow_network_chat_messages"
    }
}
