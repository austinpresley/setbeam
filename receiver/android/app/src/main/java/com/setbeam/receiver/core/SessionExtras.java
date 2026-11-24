package com.setbeam.receiver.core;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Executor;

/**
 * Session chat and shared pointers for the admitted session, read-only.
 *
 * <p>{@link ReceiverController} binds this to the current ask path and pass only while that pass is
 * admitted, and unbinds it on any refusal, lapse, retirement, or stop. Unbinding cancels every
 * request and drops all chat text and pointers at once; nothing here is written to storage.
 * Chat is fetched when the heartbeat reports a different newest message id, and every few
 * seconds while the chat panel is open. The pointer channel opens only when the TV user turned on
 * Show pointers; it watches other participants' pointers and never sends a position.
 *
 * <p>Confined to the controller's loop thread, like the controller.
 */
public final class SessionExtras {
    public static final long TICK_MS = 250;
    public static final long CHAT_VISIBLE_POLL_MS = 5000;
    public static final long CHAT_RETRY_MS = 5000;
    public static final long POINTERS_OFF_RETRY_MS = 30_000;
    private static final long[] PRESENCE_BACKOFF_MS = {2000, 5000, 15_000, 30_000};

    public interface Listener { void onExtras(Snapshot snapshot); }

    /** Immutable. Never contains passes or codes. */
    public static final class Snapshot {
        public final boolean bound;
        public final List<ChatLine> chat;
        /** Messages that arrived since the previous chat update for this session; empty on its first load. */
        public final List<ChatLine> arrived;
        /** Other participants' pointers; {@link Pointer#expiresAt} is on the loop's monotonic clock. */
        public final List<Pointer> pointers;
        public final String chatStatus;
        public final String pointerStatus;
        Snapshot(boolean bound, List<ChatLine> chat, List<ChatLine> arrived, List<Pointer> pointers, String chatStatus, String pointerStatus) {
            this.bound = bound; this.chat = chat; this.arrived = arrived; this.pointers = pointers;
            this.chatStatus = chatStatus; this.pointerStatus = pointerStatus;
        }
    }

    private final ReceiverController.Loop loop;
    private final Executor io;
    private final Gateway gateway;
    private final Listener listener;

    private boolean pointersWanted;
    private boolean chatVisible;

    // Binding: the admitted session these belong to.
    private AskPath path;
    private String pass;
    private String name;
    private int epoch;
    private Gateway.Scope scope = new Gateway.Scope();
    private boolean tickScheduled;

    // Chat.
    private List<ChatLine> chat = Collections.emptyList();
    private boolean chatLoaded, fetching;
    private int hint = -1, fetchedForHint = -2;
    private long nextChatAt, lastChatAt;
    private String chatStatus = "not admitted";

    // Pointers.
    private int pictureRevision = -1;
    private Gateway.Scope presenceScope;
    private long nextPresenceAt;
    private int presenceFailures;
    private List<Pointer> pointers = Collections.emptyList();
    private String pointerStatus = "off";

    public SessionExtras(ReceiverController.Loop loop, Executor io, Gateway gateway, Listener listener) {
        this.loop = loop; this.io = io; this.gateway = gateway; this.listener = listener;
    }

    // ---- Commands (loop thread) ----

    /**
     * The admitted session to follow, or null. Called on every controller update; a call with the
     * same session changes nothing.
     */
    public void bind(AskPath next, String nextPass, String nextName) {
        if (next == null || nextPass == null) { if (path != null) { unbind(); publish(Collections.emptyList()); } return; }
        if (path != null && path.key.equals(next.key) && path.route.toString().equals(next.route.toString()) && nextPass.equals(pass)) { reconcile(); return; }
        unbind();
        path = next; pass = nextPass; name = nextName;
        long now = loop.now();
        nextChatAt = now; nextPresenceAt = now; presenceFailures = 0;
        chatStatus = "loading"; pointerStatus = pointersWanted ? "connecting" : "off";
        reconcile();
        publish(Collections.emptyList());
        scheduleTick();
    }

    /** The newest chat message id from a heartbeat for the bound pass. */
    public void chatHint(int lastId) {
        if (path == null || lastId < 0) return;
        hint = lastId;
        if (hint != fetchedForHint) nextChatAt = Math.min(nextChatAt, loop.now());
        reconcile();
    }

    /** The chat panel is open: keep it current, including reactions and removals. */
    public void setChatVisible(boolean visible) {
        chatVisible = visible;
        if (visible && path != null) { nextChatAt = loop.now(); reconcile(); }
    }

    public void setPictureRevision(int revision) {
        if (pictureRevision == revision) return;
        pictureRevision = revision;
        closePresence(pointersWanted && revision >= 0 ? "connecting" : "off");
        nextPresenceAt = loop.now();
        presenceFailures = 0;
        // The next controller update binds or reconciles the same admitted session.
        if (path != null) publish(Collections.emptyList());
    }

    /** The TV user's Show pointers choice. Off closes the channel and clears pointers at once. */
    public void setPointersWanted(boolean wanted) {
        if (pointersWanted == wanted) return;
        pointersWanted = wanted;
        if (!wanted) closePresence("off");
        else if (path != null) { nextPresenceAt = loop.now(); presenceFailures = 0; pointerStatus = "connecting"; }
        reconcile();
        publish(Collections.emptyList());
    }

    public void tick() {
        tickScheduled = false;
        if (path == null) return;
        long now = loop.now();
        boolean expired = false;
        if (!pointers.isEmpty()) {
            List<Pointer> live = new ArrayList<>();
            for (Pointer pointer : pointers) if (pointer.expiresAt > now) live.add(pointer);
            if (live.size() != pointers.size()) { pointers = Collections.unmodifiableList(live); expired = true; }
        }
        reconcile();
        if (expired) publish(Collections.emptyList());
        scheduleTick();
    }

    // ---- Internals ----

    private void reconcile() {
        if (path == null) return;
        long now = loop.now();
        boolean wantChat = hint != fetchedForHint || !chatLoaded || (chatVisible && now - lastChatAt >= CHAT_VISIBLE_POLL_MS);
        if (!fetching && wantChat && now >= nextChatAt) fetchChat();
        if (pointersWanted && pictureRevision >= 0 && presenceScope == null && now >= nextPresenceAt) openPresence();
    }

    private void unbind() {
        epoch++;
        scope.cancel();
        scope = new Gateway.Scope();
        closePresence("off");
        path = null; pass = null; name = null;
        chat = Collections.emptyList(); chatLoaded = false; fetching = false;
        hint = -1; fetchedForHint = -2; lastChatAt = 0;
        chatStatus = "not admitted";
    }

    private void fetchChat() {
        final int e = epoch; final AskPath p = path; final String sentPass = pass; final int forHint = hint;
        final Gateway.Scope s = scope;
        fetching = true;
        io.execute(() -> {
            Gateway.ChatResult result;
            try { result = gateway.chat(p, sentPass, s); } catch (IOException ex) { result = null; }
            final Gateway.ChatResult r = result;
            loop.post(() -> chatFetched(e, forHint, r));
        });
    }

    private void chatFetched(int e, int forHint, Gateway.ChatResult result) {
        if (e != epoch || path == null) return;
        fetching = false;
        long now = loop.now();
        lastChatAt = now;
        List<ChatLine> arrived = Collections.emptyList();
        if (result == null || result.status == Gateway.Status.ERROR) {
            chatStatus = "update failed; retrying";
            nextChatAt = now + CHAT_RETRY_MS;
        } else if (result.status != Gateway.Status.OK) {
            // This pass lost chat access. The controller learns the admission from its own requests.
            chat = Collections.emptyList();
            chatStatus = "no access";
            fetchedForHint = forHint;
            nextChatAt = now + CHAT_RETRY_MS;
        } else {
            int previousNewest = chat.isEmpty() ? 0 : chat.get(chat.size() - 1).id;
            if (chatLoaded) {
                List<ChatLine> fresh = new ArrayList<>();
                for (ChatLine line : result.messages) if (line.id > previousNewest) fresh.add(line);
                arrived = Collections.unmodifiableList(fresh);
            }
            if (!chat.equals(result.messages)) chat = result.messages;
            chatLoaded = true;
            fetchedForHint = forHint;
            chatStatus = chat.size() + (chat.size() == 1 ? " message" : " messages");
            nextChatAt = now;
        }
        publish(arrived);
        reconcile();
    }

    private void openPresence() {
        final int e = epoch; final AskPath p = path; final String sentPass = pass; final String label = name;
        final Gateway.Scope s = new Gateway.Scope();
        presenceScope = s;
        pointerStatus = "connecting";
        io.execute(() -> {
            String failure = null;
            try {
                gateway.presence(p, sentPass, label, ReceiverController.COLOR, s, new Gateway.PresenceEvents() {
                    @Override public void welcome() { loop.post(() -> presenceWelcome(e, s)); }
                    @Override public void pointers(int revision, List<Pointer> items) {
                        loop.post(() -> presencePointers(e, s, revision, items));
                    }
                    @Override public void denied(String reason) { loop.post(() -> presenceDenied(e, s, reason)); }
                });
            } catch (IOException ex) { failure = "lost"; }
            final String f = failure;
            loop.post(() -> presenceEnded(e, s, f));
        });
    }

    private boolean current(int e, Gateway.Scope s) { return e == epoch && s == presenceScope && path != null; }

    private void presenceWelcome(int e, Gateway.Scope s) {
        if (!current(e, s)) return;
        presenceFailures = 0;
        pointerStatus = "watching";
        publish(Collections.emptyList());
    }

    private void presencePointers(int e, Gateway.Scope s, int revision, List<Pointer> items) {
        if (!current(e, s) || revision != pictureRevision) return;
        long now = loop.now();
        List<Pointer> rebased = new ArrayList<>();
        // The gateway reports each pointer's remaining time; place it on this loop's clock.
        for (Pointer item : items) rebased.add(new Pointer(item.number, item.label, item.color, item.x, item.y, now + item.expiresAt));
        pointers = Collections.unmodifiableList(rebased);
        publish(Collections.emptyList());
    }

    private void presenceDenied(int e, Gateway.Scope s, String reason) {
        if (!current(e, s)) return;
        pointerStatus = "off".equals(reason) ? "not offered by the Mac" : "refused (" + reason + ")";
        nextPresenceAt = loop.now() + POINTERS_OFF_RETRY_MS;
        presenceFailures = 0;
        pointers = Collections.emptyList();
        publish(Collections.emptyList());
    }

    private void presenceEnded(int e, Gateway.Scope s, String failure) {
        if (!current(e, s)) return;
        presenceScope = null;
        pointers = Collections.emptyList();
        long now = loop.now();
        if (nextPresenceAt <= now) {
            // Not denied: reconnect with backoff.
            presenceFailures++;
            nextPresenceAt = now + PRESENCE_BACKOFF_MS[Math.min(PRESENCE_BACKOFF_MS.length - 1, presenceFailures - 1)];
            pointerStatus = failure != null ? "reconnecting" : "closed by the Mac; reconnecting";
        }
        publish(Collections.emptyList());
        reconcile();
    }

    private void closePresence(String status) {
        if (presenceScope != null) presenceScope.cancel();
        presenceScope = null;
        pointers = Collections.emptyList();
        pointerStatus = status;
    }

    private void publish(List<ChatLine> arrived) {
        listener.onExtras(new Snapshot(path != null, chat, arrived, pointers, chatStatus, pointerStatus));
    }

    private void scheduleTick() {
        if (tickScheduled || path == null) return;
        tickScheduled = true;
        loop.postDelayed(this::tick, TICK_MS);
    }
}
