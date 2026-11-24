package com.setbeam.receiver;

import android.content.Context;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Applies a pairing change atomically with respect to a running receiver: the visible receiver's
 * controller is stopped (and confirmed stopped) before settings change, and restarted with the
 * new pairing afterwards. Without a running receiver the change is applied directly.
 */
final class PairingChanges {
    interface Receiver {
        /** Stops all requests and media and returns once the controller has stopped. */
        boolean stopForChange();
        /** Restarts with the current settings if the receiver is in the foreground. */
        void resumeAfterChange();
    }

    interface Change { boolean apply(Settings settings); }

    private static final Set<Receiver> receivers = new LinkedHashSet<>();

    private PairingChanges() {}

    static synchronized void register(Receiver value) { receivers.add(value); }
    static synchronized void unregister(Receiver value) { receivers.remove(value); }

    /** Main thread. Returns whether the change reached storage. */
    static synchronized boolean apply(Context context, Change change) {
        List<Receiver> running = new ArrayList<>(receivers);
        int stopped = 0;
        try {
            for (Receiver receiver : running) {
                if (!receiver.stopForChange()) return false;
                stopped++;
            }
            return change.apply(new Settings(context));
        } finally {
            for (int i = 0; i < stopped; i++) running.get(i).resumeAfterChange();
        }
    }
}
