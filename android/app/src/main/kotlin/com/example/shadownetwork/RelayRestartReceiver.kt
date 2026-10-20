package com.example.shadownetwork

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restore an already enabled relay after reboot or an in-place APK update. */
class RelayRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (RelayForegroundService.wasEnabled(context)) RelayForegroundService.start(context)
    }
}
