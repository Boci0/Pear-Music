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
                val outputTemplate = call.argument<String>("outputTemplate")
                if (url == null || outputDir == null || processId == null) {
                    result.error("bad_args", "url/outputDir/processId required", null)
                    return
                }
                startDownload(ctx, url, outputDir, processId, outputTemplate, result)
            }
            "downloadAudioFast" -> {
                val url = call.argument<String>("url")
                val outputPath = call.argument<String>("outputPath")
                val processId = call.argument<String>("processId")
                if (url == null || outputPath == null || processId == null) {
                    result.error("bad_args", "url/outputPath/processId required", null)
                    return
                }
                startAudioFastDownload(ctx, url, outputPath, processId, result)
            }
            "getStreamUrl" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("bad_args", "url required", null)
                    return
                }
                getStreamUrl(ctx, url, result)
            }
            "canRequestPackageInstalls" -> {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    result.success(ctx.packageManager.canRequestPackageInstalls())
                } else {
                    result.success(true)
                }
            }
            "openInstallPermissionSettings" -> {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    val settingsIntent = android.content.Intent(
                        android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        android.net.Uri.parse("package:${ctx.packageName}")
                    ).apply {
                        addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    ctx.startActivity(settingsIntent)
                    result.success(true)
                } else {
                    result.success(true)
                }
            }
            "getSupportedAbis" -> {
                result.success(android.os.Build.SUPPORTED_ABIS.toList())
            }
            "cancel" -> {
                val processId = call.argument<String>("processId")
                if (processId != null) cancelProcess(processId)
                result.success(true)
            }
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_args", "path required", null)
                    return
                }
                try {
                    installApk(ctx, path)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("install_failed", e.message, null)
                }
            }
            "downloadApkWithNotification" -> {
                val url = call.argument<String>("url")
                val fileName = call.argument<String>("fileName") ?: "update.apk"
                val expectedSha256 = call.argument<String>("expectedSha256")
                if (url == null) {
                    result.error("bad_args", "url required", null)
                    return
                }
                startApkDownloadWithNotification(ctx, url, fileName, expectedSha256, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun startApkDownloadWithNotification(
        ctx: Context,
        url: String,
        fileName: String,
        expectedSha256: String?,
        result: MethodChannel.Result
    ) {
        val notificationManager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val channelId = "peerm_updates"
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                channelId,
                "App Updates",
                android.app.NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows progress when updating Pear Music"
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notificationId = 8801
        val builder = androidx.core.app.NotificationCompat.Builder(ctx, channelId)
            .setContentTitle("Downloading Pear Music update...")
            .setContentText("0%")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, 0, false)

        notificationManager.notify(notificationId, builder.build())

        val executor = Executors.newSingleThreadExecutor()
        executor.execute {
            try {
                val destFile = File(ctx.cacheDir, fileName)
                var currentUrl = url
                var connection: java.net.HttpURLConnection? = null
                var redirects = 0
                val maxRedirects = 6

                while (redirects < maxRedirects) {
                    val u = java.net.URL(currentUrl)
                    connection = (u.openConnection() as java.net.HttpURLConnection).apply {
                        connectTimeout = 15000
                        readTimeout = 30000
                        instanceFollowRedirects = true
                        setRequestProperty("User-Agent", "PearMusic-Updater (Android)")
                    }
                    val code = connection.responseCode
                    if (code == java.net.HttpURLConnection.HTTP_MOVED_PERM ||
                        code == java.net.HttpURLConnection.HTTP_MOVED_TEMP ||
                        code == java.net.HttpURLConnection.HTTP_SEE_OTHER ||
                        code == 307 || code == 308) {
                        val location = connection.getHeaderField("Location")
                        connection.disconnect()
                        if (location != null && location.isNotEmpty()) {
                            currentUrl = if (location.startsWith("http")) location else java.net.URL(u, location).toString()
                            redirects++
                            continue
                        }
                    }
                    if (code != java.net.HttpURLConnection.HTTP_OK) {
                        throw Exception("Server returned HTTP $code")
                    }
                    break
                }

                if (connection == null || connection.responseCode != java.net.HttpURLConnection.HTTP_OK) {
                    throw Exception("Failed to open connection to update package")
                }

                // Integrity gate: refuse to install without an expected hash.
                if (expectedSha256.isNullOrBlank()) {
                    destFile.delete()
                    notificationManager.cancel(notificationId)
                    mainHandler.post {
                        result.error("hash_missing", "Release has no SHA-256 verification data; update aborted.", null)
                    }
                    return@execute
                }
                val digest = java.security.MessageDigest.getInstance("SHA-256")

                val fileLength = connection.contentLength
                val input = java.io.BufferedInputStream(connection.inputStream)
                val output = java.io.FileOutputStream(destFile)

                val data = ByteArray(16384)
                var total: Long = 0
                var count: Int
                var lastProgress = 0

                while (input.read(data).also { count = it } != -1) {
                    total += count
                    digest.update(data, 0, count)
                    output.write(data, 0, count)
                    if (fileLength > 0) {
                        val progress = ((total * 100) / fileLength).toInt().coerceIn(0, 100)
                        if (progress - lastProgress >= 2 || progress == 100) {
                            lastProgress = progress
                            builder.setProgress(100, progress, false)
                                .setContentText("$progress%")
                            notificationManager.notify(notificationId, builder.build())
                        }
                    } else {
                        // Unknown total length: show indeterminate ticker
                        val mb = String.format("%.1f MB", total / (1024.0 * 1024.0))
                        builder.setProgress(0, 0, true)
                            .setContentText(mb)
                        notificationManager.notify(notificationId, builder.build())
                    }
                }
                output.flush()
                output.close()
                input.close()
                connection.disconnect()

                // Verify the streamed SHA-256 before handing off to the
                // package installer. Delete the file immediately on mismatch.
                val actualHash = digest.digest().joinToString("") { "%02x".format(it) }
                if (!actualHash.equals(expectedSha256.trim().lowercase(), ignoreCase = false)) {
                    android.util.Log.e(TAG, "APK checksum mismatch: $actualHash != $expectedSha256")
                    destFile.delete()
                    builder.setContentTitle("Update verification failed")
                        .setContentText("Checksum mismatch — download deleted.")
                        .setOngoing(false)
                        .setProgress(0, 0, false)
                        .setSmallIcon(android.R.drawable.stat_notify_error)
                    notificationManager.notify(notificationId, builder.build())
                    mainHandler.post {
                        result.error("hash_mismatch", "SHA-256 checksum mismatch; update aborted.", null)
                    }
                    return@execute
                }

                val apkUri = androidx.core.content.FileProvider.getUriForFile(
                    ctx,
                    "${ctx.packageName}.fileprovider",
                    destFile
                )
                val installIntent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                    setDataAndType(apkUri, "application/vnd.android.package-archive")
                    addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                }

                val pendingIntent = android.app.PendingIntent.getActivity(
                    ctx,
                    notificationId,
                    installIntent,
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                    } else {
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT
                    }
                )

                builder.setContentTitle("Pear Music update ready")
                    .setContentText("Tap to install")
                    .setOngoing(false)
                    .setProgress(0, 0, false)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                notificationManager.notify(notificationId, builder.build())

                mainHandler.post {
                    try {
                        installApk(ctx, destFile.absolutePath)
                        result.success(destFile.absolutePath)
                    } catch (err: Exception) {
                        result.error("install_error", err.message, null)
                    }
                }
            } catch (e: Exception) {
                builder.setContentTitle("Update download failed")
                    .setContentText(e.message ?: "Unknown error")
                    .setOngoing(false)
                    .setProgress(0, 0, false)
                    .setSmallIcon(android.R.drawable.stat_notify_error)
                notificationManager.notify(notificationId, builder.build())
                mainHandler.post {
                    result.error("download_failed", e.message, null)
                }
            } finally {
                executor.shutdown()
            }
        }
    }

    private fun installApk(ctx: Context, path: String) {
        val file = File(path)
        if (!file.exists()) throw Exception("APK file does not exist: $path")

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            if (!ctx.packageManager.canRequestPackageInstalls()) {
                val settingsIntent = android.content.Intent(
                    android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    android.net.Uri.parse("package:${ctx.packageName}")
                ).apply {
                    addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                ctx.startActivity(settingsIntent)
                return
            }
        }

        val apkUri = androidx.core.content.FileProvider.getUriForFile(
            ctx,
            "${ctx.packageName}.fileprovider",
            file
        )
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        ctx.startActivity(intent)
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
            Executors.newSingleThreadExecutor().execute {
                try {
                    android.util.Log.i(TAG, "Checking background yt-dlp update...")
                    YoutubeDL.getInstance().updateYoutubeDL(ctx, YoutubeDL.UpdateChannel.STABLE)
                    android.util.Log.i(TAG, "yt-dlp updated: " + YoutubeDL.getInstance().versionName(ctx))
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "Background yt-dlp update failed: ${e.message}")
                }
            }
        }
    }

    private fun startDownload(
        ctx: Context,
        url: String,
        outputDir: String,
        processId: String,
        outputTemplate: String?,
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
                    val template = outputTemplate ?: "%(title).80B [%(id)s].%(ext)s"
                    req.addOption(
                        "-o",
                        File(outputDir, template).absolutePath,
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

    private fun startAudioFastDownload(
        ctx: Context,
        url: String,
        outputPath: String,
        processId: String,
        result: MethodChannel.Result,
    ) {
        val executor = Executors.newSingleThreadExecutor()
        executors[processId] = executor
        executor.execute {
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
                ensureInit(ctx)
                fun makeAudioReq(useExtractorArgs: Boolean): YoutubeDLRequest {
                    val req = YoutubeDLRequest(url)
                    req.addOption("-f", "bestaudio[abr<=128][ext=m4a]/bestaudio[abr<=128]/bestaudio[ext=m4a]/bestaudio/ba/best")
                    req.addOption("-o", outputPath)
                    req.addOption("--no-playlist")
                    req.addOption("--no-part")
                    req.addOption("--no-mtime")
                    req.addOption("--no-warnings")
                    req.addOption("--force-ipv4")
                    req.addOption("--no-check-certificates")
                    req.addOption("--concurrent-fragments", "1")
                    req.addOption("--buffer-size", "16k")
                    req.addOption("--http-chunk-size", "10M")
                    req.addOption("--socket-timeout", "20")
                    req.addOption("--retries", "3")
                    req.addOption("--fragment-retries", "3")
                    if (useExtractorArgs) {
                        req.addOption("--extractor-args", "youtube:player_skip=configs,webpage;player_client=android,web,mweb")
                    }
                    return req
                }

                val response = try {
                    YoutubeDL.getInstance().execute(makeAudioReq(true), processId)
                } catch (firstErr: Exception) {
                    android.util.Log.w(TAG, "Fast audio download attempt 1 failed: ${firstErr.message}, trying without extra args...")
                    YoutubeDL.getInstance().execute(makeAudioReq(false), processId)
                }

                val outFile = File(outputPath)
                if (outFile.exists() && outFile.length() > 50000) {
                    mainHandler.post {
                        result.success(mapOf("ok" to true, "path" to outputPath, "size" to outFile.length()))
                    }
                } else {
                    mainHandler.post {
                        result.error("file_missing", "Downloaded audio file missing or empty", null)
                    }
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("download_failed", e.message, null) }
            } finally {
                executors.remove(processId)?.shutdown()
                System.gc()
            }
        }
    }

    private fun getStreamUrl(
        ctx: Context,
        url: String,
        result: MethodChannel.Result,
    ) {
        val executor = Executors.newSingleThreadExecutor()
        executor.execute {
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
                ensureInit(ctx)
                fun makeUrlReq(useExtractorArgs: Boolean): YoutubeDLRequest {
                    val req = YoutubeDLRequest(url)
                    req.addOption("-g")
                    req.addOption("-f", "bestaudio[ext=m4a]/bestaudio/best")
                    req.addOption("--no-playlist")
                    req.addOption("--no-warnings")
                    req.addOption("--no-check-certificates")
                    req.addOption("--force-ipv4")
                    if (useExtractorArgs) {
                        req.addOption("--extractor-args", "youtube:player_client=android,web,mweb")
                    }
                    return req
                }

                val response = try {
                    YoutubeDL.getInstance().execute(makeUrlReq(true))
                } catch (firstErr: Exception) {
                    android.util.Log.w(TAG, "getStreamUrl attempt 1 failed: ${firstErr.message}, trying without extra args...")
                    YoutubeDL.getInstance().execute(makeUrlReq(false))
                }

                val lines = response.out?.trim()?.split(Regex("[\r\n]+"))?.filter { it.startsWith("http") } ?: emptyList()
                val streamUrl = lines.lastOrNull() ?: lines.firstOrNull()
                if (streamUrl != null) {
                    mainHandler.post { result.success(streamUrl) }
                } else {
                    mainHandler.post { result.error("no_url", "Could not resolve stream URL", null) }
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("resolve_failed", e.message, null) }
            } finally {
                executor.shutdown()
                System.gc()
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
