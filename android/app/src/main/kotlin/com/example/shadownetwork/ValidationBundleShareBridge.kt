package com.example.shadownetwork

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Only exposes generated metrics files, with a temporary read grant. */
internal class ValidationBundleShareBridge(private val context: Context) {
    var activity: Activity? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "shareFile") {
            result.notImplemented()
            return
        }
        val foreground = activity
        if (foreground == null || foreground.isFinishing || foreground.isDestroyed) {
            result.error("NO_ACTIVITY", "Open Shadow Network before sharing.", null)
            return
        }
        try {
            val path = call.argument<String>("path")
                ?: throw IllegalArgumentException("Missing export path.")
            val folder = File(context.filesDir, "validation_exports").canonicalFile
            val file = File(path).canonicalFile
            require(file.parentFile == folder && file.name.startsWith("shadow-network-") &&
                file.extension == "json" && file.isFile && file.length() > 0) {
                "Only generated validation JSON files may be shared."
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.validation_exports", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newRawUri("Validation data", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            foreground.startActivity(Intent.createChooser(send, "Share validation file").apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
            // Only the chooser launch is known. No delivery/import claim.
            result.success(null)
        } catch (_: Exception) {
            result.error("SHARE_UNAVAILABLE", "Unable to open the validation share sheet.", null)
        }
    }
}
