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
class YtDlpPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, android.content.ComponentCallbacks2, io.flutter.embedding.engine.plugins.activity.ActivityAware {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var messenger: BinaryMessenger? = null
    private var context: Context? = null
    private var activity: android.app.Activity? = null
    private var eventSink: EventChannel.EventSink? = null
    private val executors = mutableMapOf<String, ExecutorService>()
    private val audioDownloadExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    @Volatile
    private var currentAudioProcessId: String? = null
    @Volatile
    private var initialized = false
    @Volatile
    private var ffmpegInitialized = false

    /// Set once per process so we only hit the GitHub API once per launch;
    /// after the first run the refreshed yt-dlp persists on disk and
    /// updateYoutubeDL returns ALREADY_UP_TO_DATE quickly.
    @Volatile
    private var updateChecked = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        messenger = binding.binaryMessenger
        context = binding.applicationContext
        context?.registerComponentCallbacks(this)
        MethodChannel(messenger!!, CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger!!, EVENTS).setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context?.unregisterComponentCallbacks(this)
        MethodChannel(messenger!!, CHANNEL).setMethodCallHandler(null)
        EventChannel(messenger!!, EVENTS).setStreamHandler(null)
        messenger = null
        context = null
        eventSink = null
        executors.values.forEach { it.shutdownNow() }
        executors.clear()
        audioDownloadExecutor.shutdownNow()
        currentAudioProcessId = null
        initialized = false
        ffmpegInitialized = false
    }

    override fun onAttachedToActivity(binding: io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onTrimMemory(level: Int) {
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
            level >= android.content.ComponentCallbacks2.TRIM_MEMORY_COMPLETE) {
            // Under critical memory pressure, purge idle completed executors and hint GC
            val idleKeys = executors.filter { it.value.isTerminated }.keys
            idleKeys.forEach { executors.remove(it) }
            System.gc()
        }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {}

    override fun onLowMemory() {
        val idleKeys = executors.filter { it.value.isTerminated }.keys
        idleKeys.forEach { executors.remove(it) }
        System.gc()
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
                val format = call.argument<String>("format")
                if (url == null || outputPath == null || processId == null) {
                    result.error("bad_args", "url/outputPath/processId required", null)
                    return
                }
                startAudioFastDownload(ctx, url, outputPath, processId, format, result)
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
            val powerManager = ctx.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            var wakeLock: android.os.PowerManager.WakeLock? = null

            // Slow connections can outlive the initial lock window, so the
            // lock is released and re-acquired during the transfer instead of
            // expiring mid-flight (which would let the CPU suspend and stall
            // the socket).
            fun refreshWakeLock() {
                try {
                    if (wakeLock == null) {
                        wakeLock = powerManager?.newWakeLock(
                            android.os.PowerManager.PARTIAL_WAKE_LOCK,
                            "peerm:apk_update_wakelock"
                        )?.apply { setReferenceCounted(false) }
                    }
                    val lock = wakeLock ?: return
                    if (lock.isHeld) lock.release()
                    lock.acquire(WAKE_LOCK_TIMEOUT_MS)
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "Wake lock refresh failed: ${e.message}")
                }
            }

            refreshWakeLock()

            try {
                val destFile = File(ctx.cacheDir, fileName)
                val partFile = File(ctx.cacheDir, "$fileName.part")
                val metaFile = File(ctx.cacheDir, "$fileName.part.meta")

                // Reuse already downloaded and verified APK if present
                if (!expectedSha256.isNullOrBlank() && destFile.exists() && destFile.length() > 0) {
                    try {
                        if (sha256OfFile(destFile).equals(expectedSha256.trim().lowercase(), ignoreCase = false)) {
                            android.util.Log.i(TAG, "Cached APK already verified: ${destFile.absolutePath}")
                            handleApkReady(ctx, destFile, notificationId, result)
                            return@execute
                        }
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "Cached APK verification failed: ${e.message}")
                    }
                }

                // Integrity gate: refuse to install without an expected hash.
                if (expectedSha256.isNullOrBlank()) {
                    destFile.delete()
                    partFile.delete()
                    metaFile.delete()
                    notificationManager.cancel(notificationId)
                    mainHandler.post {
                        result.error("hash_missing", "Release has no SHA-256 verification data; update aborted.", null)
                    }
                    return@execute
                }

                val expected = expectedSha256.trim().lowercase()

                // A partial download only counts for the exact asset it came
                // from. Anything else (newer release, re-uploaded asset) is
                // discarded so a resume can never mix two different files.
                val identity = "$expected\n$url"
                val existingIdentity = try {
                    if (metaFile.exists()) metaFile.readText() else null
                } catch (_: Exception) {
                    null
                }
                if (existingIdentity != identity) {
                    partFile.delete()
                    metaFile.delete()
                }

                var attempt = 0
                var lastError: Exception? = null
                while (attempt < MAX_DOWNLOAD_ATTEMPTS) {
                    attempt++
                    if (attempt > 1) {
                        builder.setContentTitle("Resuming update download...")
                            .setContentText("Retrying (attempt $attempt of $MAX_DOWNLOAD_ATTEMPTS)")
                        notificationManager.notify(notificationId, builder.build())
                        try {
                            Thread.sleep((attempt - 1) * 2000L)
                        } catch (_: InterruptedException) {
                        }
                        refreshWakeLock()
                    }
                    try {
                        downloadApkToPartFile(
                            url = url,
                            partFile = partFile,
                            metaFile = metaFile,
                            identity = identity,
                            expected = expected,
                            notificationManager = notificationManager,
                            notificationId = notificationId,
                            builder = builder,
                            refreshWakeLock = { refreshWakeLock() },
                        )
                        lastError = null
                        break
                    } catch (e: Exception) {
                        lastError = e
                        android.util.Log.w(TAG, "APK download attempt $attempt failed: ${e.message}")
                    }
                }

                lastError?.let { throw it }

                // Move the verified download into place so the Dart side can
                // reuse it for a direct install.
                if (destFile.exists()) destFile.delete()
                if (!partFile.renameTo(destFile)) {
                    partFile.copyTo(destFile, overwrite = true)
                    partFile.delete()
                }
                metaFile.delete()

                handleApkReady(ctx, destFile, notificationId, result)
            } catch (e: Exception) {
                val failedChecksum = e is ApkUpdateException && e.code == UPDATE_ERROR_HASH_MISMATCH
                builder.setContentTitle(if (failedChecksum) "Update verification failed" else "Update download failed")
                    .setContentText(e.message ?: "Unknown error")
                    .setOngoing(false)
                    .setProgress(0, 0, false)
                    .setSmallIcon(android.R.drawable.stat_notify_error)
                notificationManager.notify(notificationId, builder.build())
                mainHandler.post {
                    result.error(
                        if (failedChecksum) UPDATE_ERROR_HASH_MISMATCH else UPDATE_ERROR_DOWNLOAD_FAILED,
                        e.message,
                        null
                    )
                }
            } finally {
                try {
                    val lock = wakeLock
                    if (lock?.isHeld == true) {
                        lock.release()
                    }
                } catch (_: Exception) {}
                executor.shutdown()
            }
        }
    }

    /// Downloads (or resumes) the update into [partFile] and verifies it
    /// against [expected]. Throws on any failure; the part file is kept for a
    /// later resume except when its contents are proven wrong.
    private fun downloadApkToPartFile(
        url: String,
        partFile: File,
        metaFile: File,
        identity: String,
        expected: String,
        notificationManager: android.app.NotificationManager,
        notificationId: Int,
        builder: androidx.core.app.NotificationCompat.Builder,
        refreshWakeLock: () -> Unit,
    ) {
        if (!metaFile.exists()) {
            metaFile.writeText(identity)
        }
        var existingBytes = if (partFile.exists()) partFile.length() else 0L

        // Follow redirects manually so the Range header survives the
        // github.com -> CDN hop on resumed downloads.
        var connection: java.net.HttpURLConnection? = null
        var currentUrl = url
        var redirects = 0
        var code = 0
        while (redirects <= MAX_REDIRECTS) {
            val u = java.net.URL(currentUrl)
            val conn = (u.openConnection() as java.net.HttpURLConnection).apply {
                connectTimeout = 15000
                readTimeout = 30000
                instanceFollowRedirects = false
                setRequestProperty("User-Agent", "PearMusic-Updater (Android)")
                if (existingBytes > 0) {
                    setRequestProperty("Range", "bytes=$existingBytes-")
                }
            }
            code = conn.responseCode
            if (code == java.net.HttpURLConnection.HTTP_MOVED_PERM ||
                code == java.net.HttpURLConnection.HTTP_MOVED_TEMP ||
                code == java.net.HttpURLConnection.HTTP_SEE_OTHER ||
                code == 307 || code == 308) {
                val location = conn.getHeaderField("Location")
                conn.disconnect()
                if (location.isNullOrEmpty()) break
                currentUrl = if (location.startsWith("http")) location else java.net.URL(u, location).toString()
                redirects++
                continue
            }
            connection = conn
            break
        }

        if (connection == null ||
            (code != java.net.HttpURLConnection.HTTP_OK && code != 206 && code != 416)) {
            connection?.disconnect()
            throw Exception("Server returned HTTP $code")
        }

        // 416: the offset we asked for is at or past the end of the remote
        // file. If the part file already hashes correctly it simply finished
        // in an earlier run (the app died before it was renamed); otherwise it
        // is unusable and the next attempt starts over.
        if (code == 416) {
            connection.disconnect()
            if (partFile.exists() && sha256OfFile(partFile).equals(expected, ignoreCase = false)) {
                return
            }
            partFile.delete()
            metaFile.delete()
            throw Exception("Partial download out of range; restarting")
        }

        if (code == 200 && existingBytes > 0) {
            // The server ignored the Range request: start clean.
            existingBytes = 0L
        }

        val remainingBytes = connection.contentLength.toLong()
        val totalBytes = if (remainingBytes > 0) existingBytes + remainingBytes else -1L

        val digest = java.security.MessageDigest.getInstance("SHA-256")
        if (existingBytes > 0) {
            // Seed the digest with the bytes already on disk so the running
            // hash still covers the whole file.
            java.io.FileInputStream(partFile).use { fin ->
                val buf = ByteArray(DOWNLOAD_BUFFER_SIZE)
                var n: Int
                while (fin.read(buf).also { n = it } != -1) {
                    digest.update(buf, 0, n)
                }
            }
        }

        val input = java.io.BufferedInputStream(connection.inputStream, DOWNLOAD_BUFFER_SIZE)
        val output = java.io.BufferedOutputStream(
            java.io.FileOutputStream(partFile, existingBytes > 0),
            DOWNLOAD_BUFFER_SIZE
        )

        var received = 0L
        var written = existingBytes
        var lastProgress = -1
        var lastWakeCheck = android.os.SystemClock.elapsedRealtime()
        try {
            val data = ByteArray(DOWNLOAD_BUFFER_SIZE)
            while (true) {
                val count = input.read(data)
                if (count == -1) break
                received += count
                written += count
                digest.update(data, 0, count)
                output.write(data, 0, count)

                if (totalBytes > 0) {
                    val progress = ((written * 100) / totalBytes).toInt().coerceIn(0, 100)
                    if (progress - lastProgress >= 2 || progress == 100) {
                        lastProgress = progress
                        builder.setProgress(100, progress, false)
                            .setContentText("$progress%")
                        notificationManager.notify(notificationId, builder.build())
                    }
                } else {
                    val mb = String.format("%.1f MB", written / (1024.0 * 1024.0))
                    builder.setProgress(0, 0, true)
                        .setContentText(mb)
                    notificationManager.notify(notificationId, builder.build())
                }

                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastWakeCheck > WAKE_REFRESH_INTERVAL_MS) {
                    lastWakeCheck = now
                    refreshWakeLock()
                }
            }
        } finally {
            try { output.flush() } catch (_: Exception) {}
            try { output.close() } catch (_: Exception) {}
            try { input.close() } catch (_: Exception) {}
            try { connection.disconnect() } catch (_: Exception) {}
        }

        if (remainingBytes > 0 && received < remainingBytes) {
            // Clean EOF before the promised byte count: the transfer was cut
            // short. Keep the bytes so the next attempt can resume.
            throw Exception("Connection closed early (${received} of ${remainingBytes} bytes)")
        }

        val actualHash = digest.digest().joinToString("") { "%02x".format(it) }
        if (!actualHash.equals(expected, ignoreCase = false)) {
            android.util.Log.e(TAG, "APK checksum mismatch: $actualHash != $expected")
            partFile.delete()
            metaFile.delete()
            throw ApkUpdateException(
                UPDATE_ERROR_HASH_MISMATCH,
                "Checksum mismatch; the partial download was deleted and will restart."
            )
        }
    }

    private fun sha256OfFile(file: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        java.io.FileInputStream(file).use { stream ->
            val buf = ByteArray(DOWNLOAD_BUFFER_SIZE)
            var n: Int
            while (stream.read(buf).also { n = it } != -1) {
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private class ApkUpdateException(val code: String, message: String) : Exception(message)

    private fun handleApkReady(
        ctx: Context,
        destFile: File,
        notificationId: Int,
        result: MethodChannel.Result?
    ) {
        val notificationManager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val channelId = "peerm_updates"
        val apkUri = androidx.core.content.FileProvider.getUriForFile(
            ctx,
            "${ctx.packageName}.fileprovider",
            destFile
        )

        val canInstall = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            ctx.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

        val launchIntent = if (!canInstall && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            android.content.Intent(
                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                android.net.Uri.parse("package:${ctx.packageName}")
            ).apply {
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
                clipData = android.content.ClipData.newRawUri("", apkUri)
                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
        }

        val resInfoList = ctx.packageManager.queryIntentActivities(
            android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
            },
            android.content.pm.PackageManager.MATCH_DEFAULT_ONLY
        )
        for (resolveInfo in resInfoList) {
            val packageName = resolveInfo.activityInfo.packageName
            try {
                ctx.grantUriPermission(packageName, apkUri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) {}
        }

        val pendingFlags = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        } else {
            android.app.PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = android.app.PendingIntent.getActivity(
            ctx,
            notificationId,
            launchIntent,
            pendingFlags
        )

        val builder = androidx.core.app.NotificationCompat.Builder(ctx, channelId)
            .setContentTitle("Pear Music update ready")
            .setContentText(if (canInstall) "Tap to install" else "Tap to allow installs from unknown sources")
            .setOngoing(false)
            .setProgress(0, 0, false)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_HIGH)
        notificationManager.notify(notificationId, builder.build())

        mainHandler.post {
            result?.success(destFile.absolutePath)
            if (activity != null) {
                try {
                    installApk(activity ?: ctx, destFile.absolutePath)
                } catch (err: Exception) {
                    android.util.Log.e(TAG, "Foreground installApk error: ${err.message}")
                }
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
                val target = activity ?: ctx
                target.startActivity(settingsIntent)
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
            clipData = android.content.ClipData.newRawUri("", apkUri)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

        val resInfoList = ctx.packageManager.queryIntentActivities(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
        for (resolveInfo in resInfoList) {
            val packageName = resolveInfo.activityInfo.packageName
            try {
                ctx.grantUriPermission(packageName, apkUri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) {}
        }

        val target = activity ?: ctx
        target.startActivity(intent)
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

    @Synchronized
    private fun ensureFFmpegInit(ctx: Context) {
        if (ffmpegInitialized) return
        try {
            FFmpeg.getInstance().init(ctx)
            ffmpegInitialized = true
        } catch (e: Exception) {
            android.util.Log.w(TAG, "FFmpeg init failed/unavailable: ${e.message}")
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
                ensureFFmpegInit(ctx)
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
        format: String?,
        result: MethodChannel.Result,
    ) {
        // Supersede and cancel any previous in-flight audio download to free native Python memory
        val previousProcessId = currentAudioProcessId
        if (previousProcessId != null && previousProcessId != processId) {
            cancelProcess(previousProcessId)
        }
        currentAudioProcessId = processId

        audioDownloadExecutor.execute {
            try {
                if (currentAudioProcessId != processId) {
                    mainHandler.post { result.error("cancelled", "Superseded by newer audio download", null) }
                    return@execute
                }
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DEFAULT)
                ensureInit(ctx)
                fun makeAudioReq(): YoutubeDLRequest {
                    val req = YoutubeDLRequest(url)
                    req.addOption("-f", format ?: "140/bestaudio[ext=m4a]/bestaudio[abr<=128]/bestaudio/ba")
                    req.addOption("-o", outputPath)
                    req.addOption("--no-playlist")
                    req.addOption("--no-part")
                    req.addOption("--no-mtime")
                    req.addOption("--no-warnings")
                    req.addOption("--force-ipv4")
                    req.addOption("--no-check-certificates")
                    req.addOption("--extractor-args", "youtube:skip=webpage,authcheck,translated_subs,hls")
                    req.addOption("--concurrent-fragments", "2")
                    req.addOption("--http-chunk-size", "5M")
                    req.addOption("--buffer-size", "64k")
                    req.addOption("--socket-timeout", "10")
                    req.addOption("--retries", "2")
                    req.addOption("--extractor-retries", "1")
                    req.addOption("--fragment-retries", "2")
                    // Print the chosen format's direct link (and the headers
                    // to fetch it with) as soon as it is picked, before the
                    // download starts, so the app can play while the file is
                    // still being cached. --print implies a dry run without
                    // --no-simulate.
                    req.addOption("--no-simulate")
                    req.addOption("--print", "video:$STREAM_LINE_PREFIX%(.{url,http_headers,ext})j")
                    return req
                }

                var linkSent = false
                val response = YoutubeDL.getInstance().execute(makeAudioReq(), processId) { _, _, line ->
                    if (!linkSent && line.startsWith(STREAM_LINE_PREFIX)) {
                        linkSent = true
                        mainHandler.post {
                            messenger?.let {
                                MethodChannel(it, CHANNEL).invokeMethod(
                                    "streamResolved",
                                    mapOf("processId" to processId, "line" to line),
                                )
                            }
                        }
                    }
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
                if (currentAudioProcessId != processId) {
                    mainHandler.post { result.error("cancelled", "Audio download was cancelled", null) }
                } else {
                    mainHandler.post { result.error("download_failed", e.message, null) }
                }
            } finally {
                if (currentAudioProcessId == processId) {
                    currentAudioProcessId = null
                }
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
                    req.addOption("-f", "140/bestaudio[ext=m4a]/bestaudio[abr<=128]/bestaudio/ba")
                    req.addOption("--no-playlist")
                    req.addOption("--no-warnings")
                    req.addOption("--no-check-certificates")
                    req.addOption("--force-ipv4")
                    req.addOption("--socket-timeout", "10")
                    if (useExtractorArgs) {
                        req.addOption("--extractor-args", "youtube:player_skip=configs,webpage;player_client=android,web,mweb")
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
        if (currentAudioProcessId == processId) {
            currentAudioProcessId = null
        }
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
        /// Must match StreamCacheManager.streamLinePrefix on the Dart side.
        private const val STREAM_LINE_PREFIX = "PEARSTREAM "
        private const val EVENTS = "peerm/ytdlp/progress"
        private const val TAG = "peerm_ytdlp"

        // APK updater: resume, retry and wake lock tuning.
        private const val MAX_DOWNLOAD_ATTEMPTS = 4
        private const val MAX_REDIRECTS = 6
        private const val DOWNLOAD_BUFFER_SIZE = 64 * 1024
        private const val WAKE_LOCK_TIMEOUT_MS = 30 * 60 * 1000L
        private const val WAKE_REFRESH_INTERVAL_MS = 10 * 60 * 1000L
        private const val UPDATE_ERROR_HASH_MISMATCH = "hash_mismatch"
        private const val UPDATE_ERROR_DOWNLOAD_FAILED = "download_failed"
    }
}
