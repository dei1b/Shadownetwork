package com.example.shadownetwork

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One engine and one radio owner per process, shared by the activity and relay service. */
internal object RelayEngineHost {
    private var engine: FlutterEngine? = null
    private var transport: AndroidTransportBridge? = null

    fun getOrCreate(context: Context): FlutterEngine {
        engine?.let { return it }
        val created = FlutterEngine(context.applicationContext)
        engine = created
        val bridge = AndroidTransportBridge(context.applicationContext)
        transport = bridge
        val channel = MethodChannel(created.dartExecutor.binaryMessenger, AndroidTransportBridge.CHANNEL_NAME)
        bridge.attachChannel(channel)
        channel.setMethodCallHandler(bridge::handle)
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    fun attachActivity(activity: FlutterActivity?) {
        transport?.attachActivity(activity)
    }
}
