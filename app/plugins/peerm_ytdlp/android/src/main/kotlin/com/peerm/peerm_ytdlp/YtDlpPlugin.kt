package com.peerm.peerm_ytdlp

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Bridges the bundled yt-dlp (via `youtubedl-android`, the same engine Seal
 * uses) to Flutter through a MethodChannel. Lets the phone rip YouTube/Spotify
 * audio reliably even when YouTube IP-rate-limits the built-in downloader,
 * without depending on public proxy instances.
 *
 * Registered as a normal Flutter plugin so it works with whichever Activity
 * hosts the engine (AudioServiceActivity) — no launcher-activity changes
 * needed.
 */
class YtDlpPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var messenger: BinaryMessenger? = null
    private var context: Context? = null
    private var eventSink: EventChannel.EventSink? = null
    private val executors = mutableMapOf<String, ExecutorService>()
    @Volatile
    private var initialized = false

    /// Set once per process so we only hit the GitHub API once per launch;
    /// after the first run the refreshed yt-dlp persists on disk and
    /// updateYoutubeDL returns ALREADY_UP_TO_DATE quickly.
    @Volatile
    private var updateChecked = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        messenger = binding.binaryMessenger
        context = binding.applicationContext
        MethodChannel(messenger!!, CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger!!, EVENTS).setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        MethodChannel(messenger!!, CHANNEL).setMethodCallHandler(null)
        EventChannel(messenger!!, EVENTS).setStreamHandler(null)
        messenger = null
        context = null
        eventSink = null
        executors.values.forEach { it.shutdownNow() }
        executors.clear()
        initialized = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("no_context", "plugin not attached", null)
            return
        }
        when (call.method) {
            "init" -> {
                // yt-dlp init extracts libpython/ffmpeg (tens of MB) — run off
                // the main thread, then reply on the main thread.
                val executor = Executors.newSingleThreadExecutor()
                executor.execute {
                    try {
                        ensureInit(ctx)
                        mainHandler.post {
                            result.success(YoutubeDL.getInstance().versionName(ctx) ?: "yt-dlp")
                        }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("init_failed", e.message, null) }
                    } finally {
                        executor.shutdown()
                    }
                }
            }
            "download" -> {
                val url = call.argument<String>("url")
                val outputDir = call.argument<String>("outputDir")
                val processId = call.argument<String>("processId")
                if (url == null || outputDir == null || processId == null) {
                    result.error("bad_args", "url/outputDir/processId required", null)
                    return
                }
                startDownload(ctx, url, outputDir, processId, result)
            }
            "cancel" -> {
                val processId = call.argument<String>("processId")
                if (processId != null) cancelProcess(processId)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    @Synchronized
    private fun ensureInit(ctx: Context) {
        if (initialized) return
        // Downloads the raw audio stream (bestaudio m4a/webm), so no ffmpeg
        // conversion is needed day-to-day, but including + initializing it
        // makes `--ffmpeg-location` resolve and keeps fallbacks safe.
        YoutubeDL.getInstance().init(ctx)
        FFmpeg.getInstance().init(ctx)
        initialized = true
        // The bundled yt-dlp goes stale as YouTube changes (it starts returning
        // 403 / "format not available"). Refresh it from the stable channel so
        // downloads keep working. Python 3.12 is bundled, so the latest yt-dlp
        // runs fine. Only touches the network once per process. NOTE: must run
        // AFTER init() (updateYoutubeDL asserts the instance is initialized).
        if (!updateChecked) {
            updateChecked = true
            try {
                YoutubeDL.getInstance()
                    .updateYoutubeDL(ctx, YoutubeDL.UpdateChannel.STABLE)
                android.util.Log.i(
                    TAG,
                    "yt-dlp ready: " + YoutubeDL.getInstance().versionName(ctx)
                )
            } catch (e: Exception) {
                android.util.Log.w(
                    TAG,
                    "yt-dlp update failed (using bundled): ${e.message}"
                )
            }
        }
    }

    private fun startDownload(
        ctx: Context,
        url: String,
        outputDir: String,
        processId: String,
        result: MethodChannel.Result,
    ) {
        val executor = Executors.newSingleThreadExecutor()
        executors[processId] = executor
        executor.execute {
            try {
                ensureInit(ctx)
                val request = YoutubeDLRequest(url)
                request.addOption("-f", "bestaudio[ext=m4a]/bestaudio")
                // NOTE: no --extractor-args here. Forcing a specific player
                // client (e.g. android) fails with "Requested format is not
                // available" (YouTube's SABR experiment). The DEFAULT client
                // works with the CURRENT yt-dlp, which ensureInit() refreshes
                // from the stable channel.
                request.addOption(
                    "-o",
                    File(outputDir, "%(title).80B [%(id)s].%(ext)s").absolutePath,
                )
                request.addOption("--newline")
                request.addOption("--no-playlist")
                request.addOption("--no-part")
                request.addOption("--no-mtime")
                request.addOption("--write-thumbnail")
                request.addOption("--no-warnings")
                val response = YoutubeDL.getInstance().execute(request, processId) { progress, eta, line ->
                    sendEvent(
                        mapOf(
                            "progress" to (progress ?: 0.0f),
                            "eta" to (eta ?: 0L),
                            "line" to (line ?: ""),
                        )
                    )
                }
                sendEvent(mapOf("done" to true))
                mainHandler.post {
                    result.success(mapOf("ok" to true, "exitCode" to response.exitCode))
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("download_failed", e.message, null) }
            } finally {
                executors.remove(processId)?.shutdown()
            }
        }
    }

    private fun cancelProcess(processId: String) {
        try {
            YoutubeDL.getInstance().destroyProcessById(processId)
        } catch (_: Exception) {
            // Nothing to destroy.
        }
        executors.remove(processId)?.shutdownNow()
    }

    private fun sendEvent(data: Map<String, Any?>) {
        // EventSink.success must run on the main thread; the yt-dlp progress
        // callback fires on the downloader thread.
        mainHandler.post { eventSink?.success(data) }
    }

    companion object {
        private const val CHANNEL = "peerm/ytdlp"
        private const val EVENTS = "peerm/ytdlp/progress"
        private const val TAG = "peerm_ytdlp"
    }
}
