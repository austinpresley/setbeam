package com.setbeam.receiver;

import android.content.Context;

/**
 * Applies a pairing change atomically with respect to a running receiver: the visible receiver's
 * controller is stopped (and confirmed stopped) before settings change, and restarted with the
 * new pairing afterwards. Without a running receiver the change is applied directly.
 */
final class PairingChanges {
    interface Receiver {
        /** Stops all requests and media and returns once the controller has stopped. */
        void stopForChange();
        /** Restarts with the current settings if the receiver is in the foreground. */
        void resumeAfterChange();
    }

    interface Change { boolean apply(Settings settings); }

    private static Receiver receiver;

    private PairingChanges() {}

    static synchronized void register(Receiver value) { receiver = value; }
    static synchronized void unregister(Receiver value) { if (receiver == value) receiver = null; }

    /** Main thread. Returns whether the change reached storage. */
    static synchronized boolean apply(Context context, Change change) {
        Receiver running = receiver;
        if (running != null) running.stopForChange();
        boolean saved;
        try { saved = change.apply(new Settings(context)); }
        finally { if (running != null) running.resumeAfterChange(); }
        return saved;
    }
}
