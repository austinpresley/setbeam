package com.setbeam.receiver.core;

import java.io.IOException;
import java.util.function.Consumer;

/**
 * The existing Setbeam short address and viewer gateway, as a receiver uses them. Every call is
 * blocking, bounded, and cancellable through its {@link Scope}. See docs/receiver-protocol.md.
 */
public interface Gateway {

    /** Cancels every request started under it, including ones that have not begun yet. */
    final class Scope {
        private final java.util.Set<MiniHttp.Call> calls = new java.util.HashSet<>();
        private boolean cancelled;
        public synchronized MiniHttp.Call newCall() throws java.io.InterruptedIOException {
            if (cancelled) throw new java.io.InterruptedIOException("cancelled");
            MiniHttp.Call call = new MiniHttp.Call();
            calls.add(call);
            return call;
        }
        public synchronized void done(MiniHttp.Call call) { calls.remove(call); }
        public void cancel() {
            java.util.List<MiniHttp.Call> open;
            synchronized (this) { cancelled = true; open = new java.util.ArrayList<>(calls); calls.clear(); }
            for (MiniHttp.Call call : open) call.cancel();
        }
        public synchronized boolean isCancelled() { return cancelled; }
    }

    /** The short address answered with an ask path. */
    final class Resolution {
        public final AskPath path;
        /** How the Mac was reached, for diagnostics: "configured address" or "Bonjour". */
        public final String via;
        /** The advertised installation hint of the service used, if found by DNS-SD. Not authentication. */
        public final String macId;
        public final boolean resumed;
        public Resolution(AskPath path, String via, String macId) { this(path, via, macId, false); }
        public Resolution(AskPath path, String via, String macId, boolean resumed) {
            this.path = path; this.via = via; this.macId = macId; this.resumed = resumed;
        }
    }

    /** The Mac answered, but not with an ask path (for example 404 for an unknown name). */
    final class Unanswered extends IOException {
        public Unanswered(String message) { super(message); }
    }

    enum Status { OK, NAME_REQUIRED, FULL, GONE, NOT_ADMITTED, NOT_READY, ERROR }

    final class JoinResult {
        public final Status status;
        public final String pass;
        public final int number;
        public final AccessStore.Admission admission;
        public final boolean ready;
        public JoinResult(Status status, String pass, int number, AccessStore.Admission admission, boolean ready) {
            this.status = status; this.pass = pass; this.number = number; this.admission = admission; this.ready = ready;
        }
        public static JoinResult of(Status status) { return new JoinResult(status, null, 0, null, false); }
    }

    final class StateResult {
        public final Status status;
        public final String state;
        public final String title;
        public final boolean sample;
        public final int revision;
        public final boolean approval;
        public final long sequence;
        public StateResult(Status status, String state, String title, boolean sample, int revision, boolean approval) {
            this(status, state, title, sample, revision, approval, -1);
        }
        public StateResult(Status status, String state, String title, boolean sample, int revision, boolean approval, long sequence) {
            this.status = status; this.state = state; this.title = title; this.sample = sample;
            this.revision = revision; this.approval = approval; this.sequence = sequence;
        }
        public static StateResult of(Status status) { return new StateResult(status, null, null, false, -1, false); }
        public boolean live() { return "live".equals(state); }
    }

    /** An admitted session's own read-only media access. Kept in memory only. */
    final class Playback {
        public final WhepTarget target;
        public final String user;
        public final String password;
        public final String title;
        public final boolean sample;
        public Playback(WhepTarget target, String user, String password, String title, boolean sample) {
            this.target = target; this.user = user; this.password = password; this.title = title; this.sample = sample;
        }
    }

    final class ConfigResult {
        public final Status status;
        public final Playback playback;
        /** For NOT_ADMITTED: the gateway's admission word, such as "removed" or "unknown". */
        public final String admission;
        public ConfigResult(Status status, Playback playback, String admission) { this.status = status; this.playback = playback; this.admission = admission; }
    }

    final class HeartbeatResult {
        public final Status status;
        /** "pending", "admitted", "declined", "removed", or "unknown". */
        public final String admission;
        /** The newest session-chat message id, sent only to admitted sessions; -1 when absent. */
        public final int chatLastId;
        public HeartbeatResult(Status status, String admission) { this(status, admission, -1); }
        public HeartbeatResult(Status status, String admission, int chatLastId) {
            this.status = status; this.admission = admission; this.chatLastId = chatLastId;
        }
    }

    /** The session chat as this admitted session may read it. Text only; frames are not fetched. */
    final class ChatResult {
        public final Status status;
        public final java.util.List<ChatLine> messages;
        public ChatResult(Status status, java.util.List<ChatLine> messages) { this.status = status; this.messages = messages; }
    }

    /** What a presence channel reports. Pointers are other participants' only; this receiver never moves one. */
    interface PresenceEvents {
        void welcome();
        /** The latest pointers; here each {@link Pointer#expiresAt} is its remaining time in ms. */
        void pointers(int revision, java.util.List<Pointer> pointers);
        /** The Mac refused the channel: "access", "name", "full", or "off" when pointers are not offered. */
        void denied(String reason);
    }

    Resolution resolve(HostConfig host, Scope scope) throws IOException, AskPath.Rejected;
    default Resolution resolve(HostConfig host, AskPath saved, Scope scope) throws IOException, AskPath.Rejected {
        return resolve(host, scope);
    }
    JoinResult join(AskPath path, String pass, String name, boolean ask, String color, String requestID, Scope scope) throws IOException;
    StateResult state(AskPath path, Scope scope) throws IOException;
    ConfigResult config(AskPath path, String pass, Scope scope) throws IOException;
    HeartbeatResult heartbeat(AskPath path, String pass, boolean playing, String health, int revision, String color, Scope scope) throws IOException;
    /** Blocks delivering pushed states until the stream ends, fails, or is cancelled. */
    void events(AskPath path, Scope scope, Consumer<StateResult> onState) throws IOException;

    /** Reads the session chat with this admitted session's pass. */
    default ChatResult chat(AskPath path, String pass, Scope scope) throws IOException {
        throw new IOException("Chat is not available");
    }

    /**
     * Opens the shared-pointer presence channel and blocks delivering events until it ends, fails,
     * or is cancelled. The receiver only watches: it never sends a pointer position.
     */
    default void presence(AskPath path, String pass, String name, String color, Scope scope, PresenceEvents events) throws IOException {
        throw new IOException("Pointers are not available");
    }
}
