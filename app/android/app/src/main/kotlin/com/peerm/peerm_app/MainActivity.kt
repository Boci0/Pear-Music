package com.peerm.peerm_app

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val BATTERY_CHANNEL = "com.peerm.peerm_app/battery"
    private val MEMORY_CHANNEL = "com.peerm.peerm_app/memory"
    private var memoryChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        memoryChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEMORY_CHANNEL)
        memoryChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getPssMemoryInfo") {
                val memInfo = android.os.Debug.MemoryInfo()
                android.os.Debug.getMemoryInfo(memInfo)
                val pssMb = memInfo.totalPss / 1024.0
                result.success(mapOf(
                    "pssMb" to pssMb
                ))
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getBatteryInfo") {
                val batteryStatus: Intent? = IntentFilter(Intent.ACTION_BATTERY_CHANGED).let { filter ->
                    context.registerReceiver(null, filter)
                }
                val level: Int = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale: Int = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                val status: Int = batteryStatus?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                val plugged: Int = batteryStatus?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
                val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                                 status == BatteryManager.BATTERY_STATUS_FULL ||
                                 plugged > 0
                val batteryPct = if (level >= 0 && scale > 0) (level * 100 / scale.toFloat()).toInt() else -1
                result.success(mapOf(
                    "percent" to batteryPct,
                    "isCharging" to isCharging,
                    "isAc" to (plugged == BatteryManager.BATTERY_PLUGGED_AC)
                ))
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableHighRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        enableHighRefreshRate()
    }

    override fun onPause() {
        super.onPause()
        resetRefreshRate()
    }

    private fun enableHighRefreshRate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (powerManager?.isPowerSaveMode == true) {
                resetRefreshRate()
                return
            }
            val win = window ?: return
            @Suppress("DEPRECATION")
            val display = win.windowManager?.defaultDisplay ?: return
            val modes = display.supportedModes ?: return
            val highestMode = modes.maxByOrNull { it.refreshRate }
            if (highestMode != null && highestMode.refreshRate >= 90.0f) {
                val params = win.attributes
                params.preferredDisplayModeId = highestMode.modeId
                win.attributes = params
            }
        }
    }

    private fun resetRefreshRate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val win = window ?: return
            val params = win.attributes
            if (params.preferredDisplayModeId != 0) {
                params.preferredDisplayModeId = 0
                win.attributes = params
            }
        }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_RUNNING_LOW || level == TRIM_MEMORY_UI_HIDDEN) {
            memoryChannel?.invokeMethod("onTrimMemory", level)
        }
    }

    override fun onLowMemory() {
        super.onLowMemory()
        memoryChannel?.invokeMethod("onTrimMemory", 80)
    }
}
