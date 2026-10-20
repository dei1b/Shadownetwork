package com.example.shadownetwork

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.content.Context

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = RelayEngineHost.getOrCreate(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        RelayEngineHost.attachActivity(this)
    }

    override fun onPause() {
        RelayEngineHost.attachActivity(null)
        super.onPause()
    }

    override fun onDestroy() {
        // The connected-device service owns the engine and radios after the UI closes.
        super.onDestroy()
    }
}
