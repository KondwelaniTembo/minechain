package io.github.kondwelanitembo.minechain

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var deviceKey: DeviceKeyPlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Finding M1 (docs/security-review.md, Hardening Q1): in a release
        // build the screen is left out of the recent-apps picture,
        // screenshots and screen recordings, so names, licence numbers and
        // consignments cannot be read from them. Debug builds keep them, for
        // the thesis screenshots.
        //
        // BuildConfig.DEBUG is fixed when the app is BUILT (false in every
        // release build). The first version asked Android at run time
        // (ApplicationInfo.FLAG_DEBUGGABLE), and on the A57 the release build
        // came out without the flag (Hardening T4, window flags fl=81810100,
        // no 0x2000), so the choice must not depend on what the phone says.
        if (!BuildConfig.DEBUG) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }

        // Finding L1 (tapjacking, Hardening Q2): a touch is dropped when
        // another app's window covers this one where the finger lands, so a
        // see-through overlay cannot trick a tap onto our buttons. Android
        // 12+ already blocks most of these; this covers Android 8-11. Set on
        // the top view, which checks every touch before Flutter sees it.
        window.decorView.filterTouchesWhenObscured = true
    }

    // Called once the Flutter engine exists: the place to connect our own
    // platform channels to it.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deviceKey = DeviceKeyPlugin(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    // Disconnects the channel and stops its background thread, so nothing
    // keeps running for an engine that is gone.
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        deviceKey?.dispose()
        deviceKey = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
