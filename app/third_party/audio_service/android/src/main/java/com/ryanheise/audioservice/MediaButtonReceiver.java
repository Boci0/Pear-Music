package com.ryanheise.audioservice;

import android.content.Context;
import android.content.Intent;

public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";
    // PeerM patch: broadcast action + extra used by the notification buttons
    // that represent custom actions (REWIND / FAST_FORWARD on Android 13+).
    public static final String ACTION_CUSTOM_ACTION = "com.ryanheise.audioservice.intent.action.CUSTOM_ACTION";
    public static final String EXTRA_CUSTOM_ACTION = "custom_action";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent != null && AudioService.instance != null) {
            if (ACTION_NOTIFICATION_DELETE.equals(intent.getAction())) {
                AudioService.instance.handleDeleteNotification();
                return;
            }
            if (ACTION_CUSTOM_ACTION.equals(intent.getAction())) {
                AudioService.instance.dispatchCustomAction(
                        intent.getStringExtra(EXTRA_CUSTOM_ACTION));
                return;
            }
        }
        super.onReceive(context, intent);
    }
}
