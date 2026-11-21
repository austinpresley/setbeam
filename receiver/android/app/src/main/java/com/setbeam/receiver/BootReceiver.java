package com.setbeam.receiver;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

/**
 * Opens the receiver after the device starts, when paired and allowed. Android 10 and later
 * allow this background start only when the user has let the app display over other apps;
 * otherwise the platform drops it silently. Vendors may also withhold BOOT_COMPLETED from
 * sideloaded apps. Neither is guaranteed; see receiver/docs/startup.md.
 */
public final class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "SetbeamBoot";

    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        Settings settings = new Settings(context);
        if (settings.host() == null || !settings.startAtBoot()) { Log.i(TAG, "Not starting: unpaired or turned off"); return; }
        boolean allowed = Build.VERSION.SDK_INT < 29 || android.provider.Settings.canDrawOverlays(context);
        Log.i(TAG, "Starting receiver after boot; background start " + (allowed ? "permitted" : "likely blocked without Display over other apps"));
        try {
            context.startActivity(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (RuntimeException e) {
            Log.w(TAG, "Start refused: " + e);
        }
    }
}
