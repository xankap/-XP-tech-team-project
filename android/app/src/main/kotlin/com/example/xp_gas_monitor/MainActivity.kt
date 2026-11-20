package com.example.xp_gas_monitor

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets Dart pick the right Bluetooth permissions (Android 12+ vs older).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xp/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "sdkInt") result.success(Build.VERSION.SDK_INT) else result.notImplemented()
            }
    }
}
