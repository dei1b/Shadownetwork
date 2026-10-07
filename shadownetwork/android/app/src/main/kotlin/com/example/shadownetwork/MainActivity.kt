package com.example.shadownetwork

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.maplibre.android.MapLibre

class MainActivity : FlutterActivity() {
    private lateinit var androidTransport: AndroidTransportBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MapLibre.getInstance(applicationContext)
        // Bundled tiles use loopback HTTP, which remains reachable with all radios off.
        MapLibre.setConnected(true)
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
