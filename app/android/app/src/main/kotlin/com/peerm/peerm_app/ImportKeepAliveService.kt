package com.peerm.peerm_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/// Lightweight foreground service used while a library profile import is
/// running. Keeps the process out of Android's cached-app freeze so the
/// import keeps fetching songs when the app is backgrounded; the low
/// importance notification shows the current progress.
class ImportKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Fetching your songs…"
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Importing library profile")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(
                android.app.PendingIntent.getActivity(
                    this,
                    0,
                    launch,
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                        android.app.PendingIntent.FLAG_IMMUTABLE,
                )
            )
        }
        val notification: Notification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    override fun onDestroy() {
        stopForeground(true)
        super.onDestroy()
    }

    companion object {
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "peerm_import"
        private const val NOTIFICATION_ID = 8802

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            "Library import",
                            NotificationManager.IMPORTANCE_LOW,
                        )
                    )
                }
            }
        }
    }
}
