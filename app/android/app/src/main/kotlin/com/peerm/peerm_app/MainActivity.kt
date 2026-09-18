package com.peerm.peerm_app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.*

class MainActivity : AudioServiceActivity() {
    private val BATTERY_CHANNEL = "com.peerm.peerm_app/battery"
    private val MEMORY_CHANNEL = "com.peerm.peerm_app/memory"
    private val VISUALIZER_CHANNEL = "com.peerm.peerm_app/visualizer"
    private val VISUALIZER_STREAM_CHANNEL = "com.peerm.peerm_app/visualizer_stream"

    private var memoryChannel: MethodChannel? = null
    private var visualizer: Visualizer? = null
    private var visualizerSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VISUALIZER_STREAM_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    android.util.Log.w("PearVisualizer", "EventChannel onListen")
                    visualizerSink = events
                }

                override fun onCancel(arguments: Any?) {
                    android.util.Log.w("PearVisualizer", "EventChannel onCancel")
                    visualizerSink = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VISUALIZER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sessionId = call.argument<Int>("sessionId") ?: 0
                    val ok = startVisualizer(sessionId)
                    result.success(ok)
                }
                "stop" -> {
                    stopVisualizer()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private var fftFrameCount = 0
    private val prevBins = DoubleArray(64)

    private fun startVisualizer(sessionId: Int): Boolean {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.w("PearVisualizer", "RECORD_AUDIO permission not granted")
            return false
        }
        stopVisualizer()

        val sessionsToTry = mutableListOf<Int>()
        if (sessionId > 0) {
            sessionsToTry.add(sessionId)
        }
        sessionsToTry.add(0)

        for (targetSession in sessionsToTry) {
            var v: Visualizer? = null
            try {
                v = Visualizer(targetSession)
            } catch (e: Throwable) {
                android.util.Log.w("PearVisualizer", "Failed to create Visualizer($targetSession)", e)
                continue
            }

            try {
                val range = Visualizer.getCaptureSizeRange()
                val captureSize = 1024.coerceIn(range[0], range[1])
                val capRes = v.setCaptureSize(captureSize)
                if (capRes != Visualizer.SUCCESS) {
                    android.util.Log.w("PearVisualizer", "setCaptureSize returned code: $capRes")
                }

                val maxRate = Visualizer.getMaxCaptureRate()
                val rate = maxRate

                val lisRes = v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(visualizer: Visualizer?, waveform: ByteArray?, samplingRate: Int) {}

                    override fun onFftDataCapture(visualizer: Visualizer?, fft: ByteArray?, samplingRate: Int) {
                        if (fft == null || fft.isEmpty()) return
                        val n = fft.size
                        val half = n / 2
                        val mags = DoubleArray(half)
                        mags[0] = abs(fft[0].toDouble())
                        var maxMag = 1e-12
                        for (i in 1 until half) {
                            val r = fft[2 * i].toDouble()
                            val im = fft[2 * i + 1].toDouble()
                            val mag = hypot(r, im)
                            mags[i] = mag
                            if (mag > maxMag) maxMag = mag
                        }

                        val outBinsCount = 64
                        val bins = DoubleArray(outBinsCount)

                        if (maxMag < 2.0) {
                            mainHandler.post {
                                visualizerSink?.success(bins.toList())
                            }
                            return
                        }

                        // Logarithmic (octave-style) band spacing, mirroring the Windows plugin
                        // (fft_processor.cpp): output bin b spans [half^(b/64), half^((b+1)/64)],
                        // i.e. equal musical steps from ~30 Hz up to Nyquist. This is what keeps
                        // the right half of the visualizer alive on mobile instead of compressing
                        // all real audio energy into the first few low bars (a linear mapping
                        // puts bar 0 at ~1 kHz and the rest in the dead 5-20 kHz rolloff region).
                        for (b in 0 until outBinsCount) {
                            val low = half.toDouble().pow(b.toDouble() / outBinsCount)
                            val high = half.toDouble().pow((b + 1).toDouble() / outBinsCount)
                            val ilo = max(0, floor(low).toInt())
                            val ihi = min(half - 1, ceil(high).toInt())
                            var sum = 0.0
                            val count = max(1, ihi - ilo + 1)
                            for (k in ilo..ihi) {
                                sum += mags[k]
                            }
                            val avg = sum / count
                            val valNorm = (avg / (maxMag + 1e-12)).coerceIn(0.0, 1.0)
                            // Mild log compression lifts quiet treble bands into visible range
                            // (same curve as the Windows plugin so both platforms feel identical).
                            val compressed = log10(1.0 + 9.0 * valNorm).coerceIn(0.0, 1.0)
                            val smoothed = 0.80 * compressed + 0.20 * prevBins[b]
                            prevBins[b] = smoothed
                            bins[b] = smoothed.coerceIn(0.0, 1.0)
                        }

                        if (++fftFrameCount % 60 == 0) {
                            android.util.Log.w("PearVisualizer", "FFT frame #$fftFrameCount: maxMag=$maxMag, hasSink=${visualizerSink != null}")
                        }

                        mainHandler.post {
                            visualizerSink?.success(bins.toList())
                        }
                    }
                }, rate, true, true)

                if (lisRes != Visualizer.SUCCESS) {
                    android.util.Log.w("PearVisualizer", "setDataCaptureListener returned code: $lisRes")
                }

                val enableRes = v.setEnabled(true)
                if (enableRes != Visualizer.SUCCESS || !v.enabled) {
                    android.util.Log.w("PearVisualizer", "setEnabled(true) returned $enableRes, enabled=${v.enabled}")
                    v.release()
                    continue
                }

                visualizer = v
                android.util.Log.w("PearVisualizer", "Native Visualizer successfully ACTIVE on session $targetSession, captureSize: $captureSize, rate: $rate mHz")
                return true
            } catch (e: Throwable) {
                android.util.Log.w("PearVisualizer", "Failed to configure Visualizer($targetSession)", e)
                try {
                    v.enabled = false
                    v.release()
                } catch (_: Throwable) {}
            }
        }

        visualizer = null
        android.util.Log.w("PearVisualizer", "Failed to initialize Visualizer on all attempted sessions")
        return false
    }

    private fun stopVisualizer() {
        try {
            visualizer?.enabled = false
            visualizer?.release()
        } catch (_: Throwable) {
        } finally {
            visualizer = null
            prevBins.fill(0.0)
        }
    }

    override fun onDestroy() {
        stopVisualizer()
        super.onDestroy()
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
