package com.peerm.peerm_ytdlp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
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
            "installApk" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath == null) {
                    result.error("bad_args", "filePath required", null)
                    return
                }
                installApk(ctx, filePath, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun installApk(ctx: Context, filePath: String, result: MethodChannel.Result) {
        try {
            val file = File(filePath)
            if (!file.exists()) {
                result.error("file_not_found", "APK file does not exist at $filePath", null)
                return
            }
            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
            } else {
                Uri.fromFile(file)
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("install_failed", e.message, null)
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
        YoutubeDL.getInstance().init(ctx)
        FFmpeg.getInstance().init(ctx)
        initialized = true

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
                fun makeRequest(useExtractorArgs: Boolean): YoutubeDLRequest {
                    val req = YoutubeDLRequest(url)
                    req.addOption("-f", "bestaudio[ext=m4a]/bestaudio/best")
                    req.addOption(
                        "-o",
                        File(outputDir, "%(title).80B [%(id)s].%(ext)s").absolutePath,
                    )
                    req.addOption("--newline")
                    req.addOption("--no-playlist")
                    req.addOption("--no-part")
                    req.addOption("--no-mtime")
                    req.addOption("--write-thumbnail")
                    req.addOption("--no-warnings")
                    req.addOption("--force-ipv4")
                    req.addOption("--no-check-certificates")
                    req.addOption("--concurrent-fragments", "4")
                    if (useExtractorArgs) {
                        req.addOption("--extractor-args", "youtube:player_client=android,web,mweb")
                    }
                    return req
                }

                var response = try {
                    YoutubeDL.getInstance().execute(makeRequest(true), processId) { progress, eta, line ->
                        sendEvent(
                            mapOf(
                                "progress" to (progress ?: 0.0f),
                                "eta" to (eta ?: 0L),
                                "line" to (line ?: ""),
                            )
                        )
                    }
                } catch (firstErr: Exception) {
                    android.util.Log.w(TAG, "Attempt 1 failed: ${firstErr.message}, trying fallback...")
                    YoutubeDL.getInstance().execute(makeRequest(false), processId) { progress, eta, line ->
                        sendEvent(
                            mapOf(
                                "progress" to (progress ?: 0.0f),
                                "eta" to (eta ?: 0L),
                                "line" to (line ?: ""),
                            )
                        )
                    }
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
        mainHandler.post { eventSink?.success(data) }
    }

    companion object {
        private const val CHANNEL = "peerm/ytdlp"
        private const val EVENTS = "peerm/ytdlp/progress"
        private const val TAG = "peerm_ytdlp"
    }
}
