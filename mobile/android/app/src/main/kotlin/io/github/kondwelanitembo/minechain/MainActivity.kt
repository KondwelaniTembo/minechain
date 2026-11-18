package io.github.kondwelanitembo.minechain

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var deviceKey: DeviceKeyPlugin? = null

    // Called once the Flutter engine exists: the place to connect our own
    // platform channels to it.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deviceKey = DeviceKeyPlugin(flutterEngine.dartExecutor.binaryMessenger)
    }

    // Disconnects the channel and stops its background thread, so nothing
    // keeps running for an engine that is gone.
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        deviceKey?.dispose()
        deviceKey = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
