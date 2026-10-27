package com.notificador.notificador

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "camera_native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // Só pode começar com o app visível (regra do Android 14+).
                        val intent = Intent(this, CameraService::class.java)
                            .setAction(CameraService.ACTION_START)
                            .putExtra(CameraService.EXTRA_GROUP, call.argument<String>("groupCode"))
                            .putExtra(CameraService.EXTRA_DEVICE, call.argument<String>("deviceId"))
                            .putExtra(CameraService.EXTRA_FACING, call.argument<String>("facing"))
                            .putExtra(CameraService.EXTRA_TITLE, call.argument<String>("title"))
                            .putExtra(CameraService.EXTRA_TEXT, call.argument<String>("text"))
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    }
                    "stop" -> {
                        startService(Intent(this, CameraService::class.java).setAction(CameraService.ACTION_STOP))
                        result.success(null)
                    }
                    "switch" -> {
                        startService(Intent(this, CameraService::class.java).setAction(CameraService.ACTION_SWITCH))
                        result.success(null)
                    }
                    "isRunning" -> result.success(CameraService.running)
                    "batteryExemption" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            )
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
