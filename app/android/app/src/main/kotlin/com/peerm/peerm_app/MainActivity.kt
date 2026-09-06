package com.peerm.peerm_app

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
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
}
