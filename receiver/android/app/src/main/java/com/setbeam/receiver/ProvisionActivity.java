package com.setbeam.receiver;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

import com.setbeam.receiver.core.HostConfig;

/**
 * {@code com.setbeam.receiver.CONFIGURE} with extras {@code setbeam_host} and {@code setbeam_name}.
 * The manifest limits callers to holders of WRITE_SECURE_SETTINGS (the adb shell), so another
 * app on the TV cannot repoint the receiver. A visible receiver is stopped before the change and
 * restarted with it. Per-share refusals are kept; a different Mac clears only the Bonjour id hint.
 * Values are logged only as accepted or refused.
 */
public final class ProvisionActivity extends Activity {
    static final String ACTION = "com.setbeam.receiver.CONFIGURE";
    private static final String TAG = "SetbeamProvision";

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        Intent intent = getIntent();
        if (intent == null || !ACTION.equals(intent.getAction())) { setResult(RESULT_CANCELED); finish(); return; }
        String host = intent.getStringExtra("setbeam_host"), name = intent.getStringExtra("setbeam_name");
        try {
            HostConfig config = HostConfig.parse(host, name);
            // Stops a visible receiver before the change and restarts it with the new pairing.
            if (!PairingChanges.apply(this, s -> s.pair(config))) {
                Log.w(TAG, "Pairing refused: could not be saved");
                setResult(RESULT_CANCELED);
                finish();
                return;
            }
            Log.i(TAG, "Pairing accepted for " + config.baseUrl());
            setResult(RESULT_OK);
            startActivity(new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP));
        } catch (HostConfig.Invalid e) {
            Log.w(TAG, "Pairing refused: " + e.getMessage());
            setResult(RESULT_CANCELED);
        }
        finish();
    }
}
