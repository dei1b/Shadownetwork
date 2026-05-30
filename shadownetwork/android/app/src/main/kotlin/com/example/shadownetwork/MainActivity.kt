package com.example.shadownetwork

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var androidTransport: AndroidTransportBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        androidTransport = AndroidTransportBridge(this)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AndroidTransportBridge.CHANNEL_NAME,
        )
        androidTransport.attachChannel(channel)
        channel.setMethodCallHandler(androidTransport::handle)
    }

    override fun onDestroy() {
        if (::androidTransport.isInitialized) {
            androidTransport.stop()
        }
        super.onDestroy()
    }
}
