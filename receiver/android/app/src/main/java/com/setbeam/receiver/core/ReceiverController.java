package com.setbeam.receiver.core;

import java.io.IOException;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

/**
 * The receiver's single state machine: find the paired Mac's short address, ask once per share,
 * wait for the operator's Admit, play only while the audience state is live, and recover.
 *
 * <p>All state is confined to one loop thread. Network calls run on the I/O executor and post
 * their results back tagged with the context epoch; results for a replaced share, a stopped
 * receiver, or a newer request are discarded. Every timer is driven by {@link #tick()}.
 *
 * <p>Invariants (docs/receiver-protocol.md):
 * <ul>
 * <li>A declined or removed request is terminal for that ask path, persisted before anything else
 *     happens, and survives restarts. Only a different ask path (a new share) asks again.</li>
 * <li>A lapsed request (pass unknown) may ask again on the same path at most once every 30 s,
 *     visibly, and at most {@link #MAX_AUTO_ASKS} times before it waits for the TV user.</li>
 * <li>Media is closed at once for any audience state other than {@code live}, and on refusal,
 *     path retirement, or stop. Playback credentials are fetched for each publisher revision and
 *     kept in memory only.</li>
 * <li>Live is claimed only while rendered frames are fresh.</li>
 * </ul>
 */
public final class ReceiverController {
    public static final long TICK_MS = 250;
    public static final long FRESH_FRAME_MS = 2000;
    public static final long WATCHDOG_MS = 10_000;
    public static final long REASK_INTERVAL_MS = 30_000;
    public static final int MAX_AUTO_ASKS = 5;
    public static final long FULL_RETRY_MS = 10_000;
    public static final long PENDING_POLL_MS = 2000;
    public static final long HEARTBEAT_MS = 3000;
    public static final long STATE_POLL_MS = 1500;
    public static final long REFUSED_RECHECK_MS = 15_000;
    public static final long EVENTS_RETRY_MS = 15_000;
    public static final String COLOR = "teal";
    /** Consecutive failed requests (each bounded by its 5 s deadline) after which the Mac counts as lost. */
    public static final int LOST_AFTER_FAILURES = 3;

    public interface Loop {
        void post(Runnable task);
        void postDelayed(Runnable task, long delayMs);
        /** Thread-safe monotonic milliseconds. */
        long now();
        /** Wall-clock milliseconds, for persisted timestamps. */
        long wallNow();
    }

    /** Media playback. Calls arrive on the loop thread and must not block. */
    public interface Player {
        void play(int generation, Gateway.Playback playback);
        /** Detaches and mutes at once; releases asynchronously. Idempotent. */
        void stop();
        /** Thread-safe monotonic time of the last fresh frame the renderer swapped, or 0. */
        long lastFrameAt(int generation);
        default boolean negotiating(int generation) { return false; }
    }

    public interface Listener { void onView(View view); }

    public enum Phase {
        UNCONFIGURED, PAUSED, SEARCHING, ASKING, ASKING_AGAIN, WAITING, BUSY, NEEDS_ASK, NAME_REJECTED, STORAGE_PROBLEM,
        CONNECTING, LIVE, STALLED, HOLDING, AUDIENCE_RECONNECTING, ENDED, DECLINED, REMOVED
    }

    /** An immutable snapshot for presentation and diagnostics. Never contains passes, codes, or credentials. */
    public static final class View {
        public final Phase phase;
        public final String title;
        public final boolean sample;
        public final String host;
        public final String receiverName;
        public final int number;
        public final String reason;
        public final String route;
        public final String share;
        public final String audienceState;
        public final int revision;
        public final String admission;
        public final String stateFeed;
        public final boolean canAskAgain;
        public final int playerGeneration;
        View(Phase phase, String title, boolean sample, String host, String receiverName, int number, String reason, String route,
             String share, String audienceState, int revision, String admission, String stateFeed, boolean canAskAgain, int playerGeneration) {
            this.phase = phase; this.title = title; this.sample = sample; this.host = host; this.receiverName = receiverName;
            this.number = number; this.reason = reason; this.route = route; this.share = share; this.audienceState = audienceState;
            this.revision = revision; this.admission = admission; this.stateFeed = stateFeed; this.canAskAgain = canAskAgain;
            this.playerGeneration = playerGeneration;
        }
    }

    private final Loop loop;
    private final Executor io;
    private final Gateway gateway;
    private final AccessStore store;
    private final Player player;
    private final Listener listener;
    /** Chat and pointers, bound only to an admitted pass. Optional. */
    private SessionExtras extras;

    private HostConfig host;
    private boolean running;
    private int epoch;
    private Gateway.Scope scope = new Gateway.Scope();
    private boolean tickScheduled;

    // Current share.
    private AskPath path;
    private String via = "";
    private AccessStore.Record record = new AccessStore.Record();
    private AccessStore.Admission admission = AccessStore.Admission.NONE;
    private String pass;
    private int number;
    private boolean ended;
    private boolean nameRejected;
    private boolean busy;
    private boolean askingAgain;
    private boolean manualAsk;
    /** Request state could not be stored or read back; automatic requests stop until the TV user acts. */
    private boolean storageProblem;
    private Gateway.StateResult state;
    private Gateway.Playback playback;
    private int playbackRevision = -1;
    private long stateUpdates, mediaVersion;
    private boolean routeStateConfirmed;
    private long lastAdmissionReply, nextAdmissionRequest;
    private boolean resumedRoute;
    private Consumer<Gateway.Resolution> onResolved = value -> {};
    private String reason = "";
    private String lastAskKey;
    private long lastAskMono;
    /** Ask count, time, and monotonic anchor before the request in flight, restored if it was not created. */
    private long[] askBefore;

    // Requests in flight and their timers.
    private boolean resolving, joining, polling, configuring, heartbeating, eventsOpen, eventsHeard;
    private Gateway.Scope eventsScope;
    private long eventsHeardAt, eventsOpenedAt, eventsRetryAt;
    private long nextResolveAt, nextJoinAt, nextPollAt, nextConfigAt, nextHeartbeatAt, nextPlayAt;
    private int resolveFailures, gatewayFailures, playerFailures;

    // Player.
    private int playerGeneration;
    private boolean playerActive;
    private long playerStartedAt;
    private int playingRevision = -1;
    private boolean everPlayed;
    private Boolean reportedPlaying;

    public ReceiverController(Loop loop, Executor io, Gateway gateway, AccessStore store, Player player, Listener listener) {
        this.loop = loop; this.io = io; this.gateway = gateway; this.store = store;
        this.player = player; this.listener = listener;
    }

    /** Attaches chat and pointers. They follow only the current admitted pass (see {@link #publish}). */
    public void setExtras(SessionExtras value) { extras = value; }

    public void setResolutionListener(Consumer<Gateway.Resolution> value) { onResolved = value; }

    // ---- Commands (loop thread) ----

    /** Starts or restarts with this pairing. A null host shows setup. */
    public void start(HostConfig config) {
        stop();
        host = config;
        running = config != null;
        nextResolveAt = loop.now();
        resolveFailures = 0;
        publish();
        if (running) scheduleTick(0);
    }

    /** Stops all requests and media. Per-share state stays persisted for the next start. */
    public void stop() {
        running = false;
        invalidate();
        stopPlayer();
        path = null; state = null; playback = null; admission = AccessStore.Admission.NONE; pass = null;
        ended = false;
        publish();
    }

    /** The TV user pressed Ask again. Never applies to a declined or removed share. */
    public void askAgain() {
        if (!running || path == null || admission != AccessStore.Admission.NONE || record.admission.refused()) return;
        if (joining) return;
        manualAsk = true; nameRejected = false; busy = false;
        nextJoinAt = loop.now();
        reconcile();
    }

    /** The network changed or the paired Mac's service appeared: look again soon. */
    public void nudge() {
        if (!running) return;
        long now = loop.now();
        if (path == null || admission.refused()) { nextResolveAt = Math.min(nextResolveAt, now); resolveFailures = 0; }
        else if (gatewayFailures > 0) { nextResolveAt = now; }
        // DNS-SD often arrives after a successful direct lookup. Revalidate the route once
        // the advertisement can corroborate the paired installation's hint.
        if (path != null && !admission.refused() && !resolving && now >= nextResolveAt) resolve();
        reconcile();
    }

    /** The player gave up on this generation (ICE failure, rejected offer, revoked credentials). */
    public void playerFailed(int generation, String why) {
        if (!running || generation != playerGeneration || !playerActive) return;
        reason = why;
        restartPlayer();
        reconcile();
    }

    public void tick() {
        tickScheduled = false;
        if (!running) return;
        reconcile();
        scheduleTick(TICK_MS);
    }

    // ---- Reconcile ----

    private void reconcile() {
        if (!running || host == null) { publish(); return; }
        long now = loop.now();
        if (path == null) {
            stopPlayer();
            if (!resolving && now >= nextResolveAt) resolve();
            publish();
            return;
        }
        if (admission.refused()) {
            stopPlayer(); closeEvents();
            if (!resolving && now >= nextResolveAt) resolve();
            publish();
            return;
        }
        if (lostContact() && !resolving && now >= nextResolveAt) resolve();
        switch (admission) {
            case NONE:
                // A new request waits for contact: failed attempts would count against this share's limits.
                if (!joining && now >= nextJoinAt && !lostContact()) maybeAsk(now);
                // Waiting on the TV user for this share: keep watching for a new share untouched.
                if (waitingOnTv() && !joining && !resolving && now >= nextResolveAt) resolve();
                break;
            case PENDING:
                if (!joining && now >= nextJoinAt) join(false);
                break;
            case ADMITTED:
                if (wantsConfig() && !configuring && now >= nextConfigAt) fetchConfig();
                boolean fresh = framesFresh(now);
                if (!heartbeating && (now >= nextHeartbeatAt || (reportedPlaying != null && reportedPlaying != fresh))) heartbeat(fresh);
                break;
            default:
                break;
        }
        feedState(now);
        reconcilePlayer(now);
        publish();
    }

    private boolean waitingOnTv() {
        return !manualAsk && (nameRejected || storageProblem || record.passUnreadable || record.asks >= MAX_AUTO_ASKS);
    }

    private boolean wantsConfig() {
        return admission == AccessStore.Admission.ADMITTED && routeStateConfirmed && state != null && state.live()
                && (playback == null || playbackRevision != state.revision);
    }

    private void maybeAsk(long now) {
        if (record.admission.refused()) { admission = record.admission; return; }
        if (nameRejected) return;
        long wall = loop.wallNow();
        if (!manualAsk && (record.passUnreadable || storageProblem)) return;
        if (!manualAsk && record.asks >= MAX_AUTO_ASKS) return;
        if (record.asks > 0) {
            // At most one request per path every 30 s, by the persisted wall clock and, within this
            // process, by the monotonic clock too, so a clock change cannot shorten the interval.
            if (!path.key.equals(lastAskKey)) {
                // First look at this path in this process: anchor the monotonic clock to the stored
                // time, or, if the wall clock is now earlier than that, to the full interval from now.
                lastAskKey = path.key;
                lastAskMono = wall >= record.lastAskAt ? now - (wall - record.lastAskAt) : now;
            }
            long wait = lastAskMono + REASK_INTERVAL_MS - now;
            if (wall >= record.lastAskAt) wait = Math.max(wait, record.lastAskAt + REASK_INTERVAL_MS - wall);
            if (wait > 0) { nextJoinAt = now + wait; askingAgain = true; return; }
            askingAgain = true;
        }
        // Count the request durably before sending it, so a crash cannot turn into repeated asks.
        askBefore = new long[]{record.asks, record.lastAskAt, lastAskMono};
        String previousID = record.requestID;
        if (record.requestID == null) record.requestID = UUID.randomUUID().toString();
        record.asks++;
        record.lastAskAt = wall;
        lastAskKey = path.key; lastAskMono = now;
        record.passUnreadable = false;
        if (!store.saveVerified(path.key, record, wall)) {
            storageProblem = true;
            reason = "This receiver could not save its request state";
            record.asks = (int) askBefore[0]; record.lastAskAt = askBefore[1]; lastAskMono = askBefore[2];
            record.requestID = previousID;
            manualAsk = false;
            nextJoinAt = now + REFUSED_RECHECK_MS;
            return;
        }
        storageProblem = false;
        manualAsk = false;
        join(true);
    }

    private void join(boolean ask) {
        final int e = epoch; final AskPath p = path; final String sentPass = ask ? null : pass;
        final String name = host.name;
        final String requestID = ask ? record.requestID : null;
        joining = true;
        Gateway.Scope s = scope;
        io.execute(() -> {
            Gateway.JoinResult result;
            try { result = gateway.join(p, sentPass, name, ask, COLOR, requestID, s); }
            catch (IOException ex) { result = null; }
            final Gateway.JoinResult r = result;
            loop.post(() -> joined(e, sentPass, ask, r));
        });
    }

    private void joined(int e, String sentPass, boolean ask, Gateway.JoinResult result) {
        if (e != epoch || !running) return;
        joining = false;
        // A late reply never undoes a refusal, and a reply for a pass already replaced is stale.
        if (admission.refused() || (!ask && sentPass != null && !sentPass.equals(pass))) { reconcile(); return; }
        long now = loop.now();
        if (result == null || result.status == Gateway.Status.ERROR) { gatewayFailure("Connection to the Mac failed"); nextJoinAt = now + backoff(gatewayFailures); reconcile(); return; }
        gatewayFailures = 0;
        switch (result.status) {
            case OK:
                busy = false;
                if (result.admission.refused()) { refuse(result.admission); break; }
                if (!ask && sentPass != null && !sentPass.equals(result.pass)) { lapsed(); break; }
                askingAgain = false;
                record.requestID = null;
                pass = result.pass; number = result.number; admission = result.admission;
                lastAdmissionReply = ++nextAdmissionRequest;
                record.pass = pass; record.number = number; record.admission = admission; record.passUnreadable = false;
                if (!store.save(path.key, record, loop.wallNow())) { storageProblem = true; reason = "This receiver could not save its request state"; }
                if (admission == AccessStore.Admission.PENDING) { playback = null; stopPlayer(); }
                else if (admission == AccessStore.Admission.ADMITTED) store.saveAdmittedRoute(host, path);
                nextJoinAt = now + (admission == AccessStore.Admission.PENDING ? PENDING_POLL_MS : HEARTBEAT_MS);
                break;
            case NAME_REQUIRED:
                if (sentPass != null) lapsed();
                else {
                    record.requestID = null;
                    store.save(path.key, record, loop.wallNow());
                    nameRejected = true; reason = "The Mac did not accept this receiver's request";
                }
                break;
            case FULL:
                // The Mac created no request, so this attempt does not count toward the re-ask limits.
                if (ask && askBefore != null) {
                    record.asks = (int) askBefore[0]; record.lastAskAt = askBefore[1]; lastAskMono = askBefore[2];
                    if (!store.save(path.key, record, loop.wallNow())) storageProblem = true;
                }
                busy = true; nextJoinAt = now + FULL_RETRY_MS;
                break;
            case GONE:
                retire("This share ended");
                break;
            default:
                break;
        }
        reconcile();
    }

    /** The gateway no longer knows this pass. Not a refusal: the share may be asked again, slowly. */
    private void lapsed() {
        if (admission.refused() || record.admission.refused()) return;
        stopPlayer();
        pass = null; playback = null; admission = AccessStore.Admission.NONE;
        record.pass = null; record.admission = AccessStore.Admission.NONE;
        if (!store.save(path.key, record, loop.wallNow())) storageProblem = true;
        if (resumedRoute) { retire("The request lapsed"); return; }
        reason = "The request lapsed";
        nextJoinAt = loop.now();
    }

    /** Declined or removed: persist first, then close media at once. Terminal for this ask path. */
    private void refuse(AccessStore.Admission refusal) {
        boolean saved = store.refuse(path.key, refusal, loop.wallNow());
        record = store.load(path.key);
        record.admission = refusal; record.pass = null;
        if (!saved) { storageProblem = true; reason = "This receiver could not save the refusal"; }
        admission = refusal; pass = null; playback = null;
        stopPlayer(); closeEvents();
        nextResolveAt = loop.now() + REFUSED_RECHECK_MS;
    }

    /** The ask path returned 404: the share ended or the short address closed. Look again. */
    private void retire(String why) {
        boolean wasAdmitted = admission == AccessStore.Admission.ADMITTED;
        if (path != null) store.clearAdmittedRoute();
        invalidate();
        stopPlayer();
        path = null; state = null; playback = null; pass = null; admission = AccessStore.Admission.NONE;
        ended = wasAdmitted;
        reason = why;
        resolveFailures = 0;
        nextResolveAt = loop.now() + 1000;
    }

    private void gatewayFailure(String why) {
        gatewayFailures++;
        reason = lostContact() ? "Lost contact with the Mac; looking for it again" : why;
        if (gatewayFailures == LOST_AFTER_FAILURES) nextResolveAt = loop.now();
    }

    /**
     * The Mac stopped answering this share's gateway (for example it quit, or the network went
     * away). The share's stored pass and admission are kept; any successful reply ends this.
     */
    private boolean lostContact() { return gatewayFailures >= LOST_AFTER_FAILURES; }

    // ---- Resolve ----

    private void resolve() {
        final int e = epoch; final HostConfig h = host;
        final AskPath saved = store.admittedRoute(h);
        resolving = true;
        Gateway.Scope s = scope;
        io.execute(() -> {
            Gateway.Resolution resolution = null; String failure = null;
            try { resolution = gateway.resolve(h, saved, s); }
            catch (Gateway.Unanswered ex) { failure = ex.getMessage(); }
            catch (IOException ex) { failure = "Looking for " + h.host; }
            catch (AskPath.Rejected ex) { failure = "Unexpected reply: " + ex.getMessage(); }
            final Gateway.Resolution r = resolution; final String f = failure;
            loop.post(() -> resolved(e, r, f));
        });
    }

    private void resolved(int e, Gateway.Resolution resolution, String failure) {
        if (e != epoch || !running) return;
        resolving = false;
        long now = loop.now();
        if (resolution == null) {
            resolveFailures++;
            if (path == null) reason = failure;
            else if (lostContact()) reason = "Lost contact with the Mac; looking for it again";
            nextResolveAt = now + (path != null && admission.refused() ? REFUSED_RECHECK_MS : resolveBackoff(resolveFailures));
            reconcile();
            return;
        }
        resolveFailures = 0;
        via = resolution.via;
        onResolved.accept(resolution);
        if (path != null && path.sameShare(resolution.path)) {
            // Same share, possibly at a new address after a DHCP move. Keep the request.
            boolean moved = !path.route.toString().equals(resolution.path.route.toString());
            path = resolution.path;
            resumedRoute = resolution.resumed;
            gatewayFailures = 0;
            if (moved) {
                invalidate();
                stopPlayer();
                // Keep the sequence watermark for this share, but require a state reply from this route.
                routeStateConfirmed = false;
                playback = null;
                if (admission == AccessStore.Admission.PENDING) nextJoinAt = now;
                nextPollAt = now; nextConfigAt = now; nextHeartbeatAt = now; nextPlayAt = now;
                eventsRetryAt = now;
                if (admission == AccessStore.Admission.ADMITTED) store.saveAdmittedRoute(host, path);
            }
            nextResolveAt = now + REFUSED_RECHECK_MS;
            reconcile();
            return;
        }
        resumedRoute = resolution.resumed;
        beginShare(resolution.path);
        reconcile();
    }

    private void beginShare(AskPath next) {
        invalidate();
        stopPlayer();
        path = next;
        record = store.load(next.key);
        admission = record.admission;
        pass = record.pass;
        number = record.number;
        state = null; playback = null; playbackRevision = -1;
        routeStateConfirmed = false;
        stateUpdates = 0;
        if (admission == AccessStore.Admission.ADMITTED) store.saveAdmittedRoute(host, path);
        ended = false; nameRejected = false; busy = false; manualAsk = false; askingAgain = false; everPlayed = false; storageProblem = false;
        gatewayFailures = 0; playerFailures = 0; reason = "";
        long now = loop.now();
        nextJoinAt = now; nextPollAt = now; nextConfigAt = now; nextHeartbeatAt = now; nextPlayAt = now;
        eventsRetryAt = now;
        if (admission.refused()) nextResolveAt = now + REFUSED_RECHECK_MS;
        else if (pass == null && admission != AccessStore.Admission.NONE) admission = AccessStore.Admission.NONE;
    }

    /** Cancels every request of the current context; their late results are ignored. */
    private void invalidate() {
        epoch++;
        scope.cancel();
        scope = new Gateway.Scope();
        closeEvents();
        resolving = joining = polling = configuring = heartbeating = false;
    }

    // ---- State feed ----

    private void feedState(long now) {
        boolean healthy = eventsOpen && now - (eventsHeard ? eventsHeardAt : eventsOpenedAt) <= (eventsHeard ? 25_000 : 5000);
        if (eventsOpen && !healthy) { closeEvents(); eventsRetryAt = now + EVENTS_RETRY_MS; }
        if (!eventsOpen && now >= eventsRetryAt) openEvents(now);
        if (!healthy && !polling && now >= nextPollAt) poll();
    }

    private void openEvents(long now) {
        final int e = epoch; final AskPath p = path;
        final Gateway.Scope s = new Gateway.Scope();
        eventsScope = s; eventsOpen = true; eventsHeard = false; eventsOpenedAt = now;
        io.execute(() -> {
            try { gateway.events(p, s, result -> loop.post(() -> pushed(e, s, result))); }
            catch (IOException ignored) { }
            loop.post(() -> eventsEnded(e, s));
        });
    }

    private void pushed(int e, Gateway.Scope s, Gateway.StateResult result) {
        if (e != epoch || s != eventsScope || !running) return;
        eventsHeard = true; eventsHeardAt = loop.now();
        applyState(result);
        reconcile();
    }

    private void eventsEnded(int e, Gateway.Scope s) {
        if (e != epoch || s != eventsScope) return;
        eventsOpen = false; eventsScope = null;
        eventsRetryAt = loop.now() + EVENTS_RETRY_MS;
        reconcile();
    }

    private void closeEvents() {
        if (eventsScope != null) eventsScope.cancel();
        eventsScope = null; eventsOpen = false;
    }

    private void poll() {
        final int e = epoch; final AskPath p = path;
        final long observed = stateUpdates;
        polling = true;
        Gateway.Scope s = scope;
        io.execute(() -> {
            Gateway.StateResult result;
            try { result = gateway.state(p, s); } catch (IOException ex) { result = null; }
            final Gateway.StateResult r = result;
            loop.post(() -> polled(e, observed, r));
        });
    }

    private void polled(int e, long observed, Gateway.StateResult result) {
        if (e != epoch || !running) return;
        polling = false;
        long now = loop.now();
        nextPollAt = now + STATE_POLL_MS;
        // Legacy state and unsequenced failures cannot supersede a push received in flight.
        if (observed != stateUpdates && (result == null || result.sequence < 0)) { reconcile(); return; }
        if (result == null || result.status == Gateway.Status.ERROR) { gatewayFailure("Status updates from the Mac failed"); nextPollAt = now + backoff(gatewayFailures); reconcile(); return; }
        gatewayFailures = 0;
        applyState(result);
        reconcile();
    }

    private void applyState(Gateway.StateResult result) {
        if (result.status == Gateway.Status.GONE) { retire("This share ended"); return; }
        if (result.status != Gateway.Status.OK) return;
        if (state != null) {
            if (result.sequence >= 0 && state.sequence >= 0 && result.sequence <= state.sequence) {
                if (result.sequence == state.sequence && result.revision == state.revision && result.state.equals(state.state)) {
                    routeStateConfirmed = true;
                    stateUpdates++;
                }
                return;
            }
            if (state.sequence >= 0 && result.sequence < 0) return;
            if (result.sequence < 0 && result.revision >= 0 && result.revision < state.revision) return;
        }
        stateUpdates++;
        routeStateConfirmed = true;
        if (state == null || !state.state.equals(result.state) || state.revision != result.revision) {
            mediaVersion++;
            nextConfigAt = loop.now();
        }
        if ("stopped".equals(result.state) && (state == null || !"stopped".equals(state.state))) store.clearAdmittedRoute();
        else if (result.live() && state != null && "stopped".equals(state.state)
                && admission == AccessStore.Admission.ADMITTED) store.saveAdmittedRoute(host, path);
        state = result;
        // Authoritative non-live state: detach and mute now. Hold already suppresses outgoing media.
        // Playback details are fetched again when live returns.
        if (!result.live()) { stopPlayer(); playback = null; }
        else if (playerActive && playingRevision != result.revision) stopPlayer();
    }

    // ---- Config and playback ----

    private void fetchConfig() {
        final int e = epoch; final AskPath p = path; final String sentPass = pass; final int revision = state.revision;
        configuring = true;
        final long version = mediaVersion;
        final long request = ++nextAdmissionRequest;
        Gateway.Scope s = scope;
        io.execute(() -> {
            Gateway.ConfigResult result; String failure = null;
            try { result = gateway.config(p, sentPass, s); } catch (IOException ex) { result = null; failure = ex.getMessage(); }
            final Gateway.ConfigResult r = result; final String f = failure;
            loop.post(() -> configured(e, sentPass, revision, version, request, r, f));
        });
    }

    private void configured(int e, String sentPass, int revision, long version, long request, Gateway.ConfigResult result, String failure) {
        if (e != epoch || !running) return;
        configuring = false;
        // Like heartbeats: a reply that arrives after a refusal or for a replaced pass changes nothing.
        if (admission != AccessStore.Admission.ADMITTED || !Objects.equals(sentPass, pass)) { reconcile(); return; }
        AccessStore.Admission told = result == null ? null : AccessStore.Admission.parse(result.admission);
        if (told != null && told.refused()) { refuse(told); reconcile(); return; }
        if (result != null && result.status == Gateway.Status.GONE) { retire("This share ended"); reconcile(); return; }
        if (version != mediaVersion || state == null || !state.live()) { reconcile(); return; }
        long now = loop.now();
        if (result == null || result.status == Gateway.Status.ERROR) {
            gatewayFailure(failure != null ? failure : "Playback details failed");
            nextConfigAt = now + backoff(gatewayFailures);
            reconcile(); return;
        }
        gatewayFailures = 0;
        switch (result.status) {
            case OK:
                lastAdmissionReply = Math.max(lastAdmissionReply, request);
                playback = result.playback; playbackRevision = revision;
                break;
            case NOT_READY:
                nextConfigAt = now + 1500;
                break;
            case NOT_ADMITTED: {
                if (request < lastAdmissionReply) break;
                lastAdmissionReply = request;
                if (told == AccessStore.Admission.PENDING) pending(now);
                else if (told == null) lapsed();
                else nextConfigAt = now + 1500;
                break;
            }
            default:
                break;
        }
        reconcile();
    }

    private void pending(long now) {
        admission = AccessStore.Admission.PENDING;
        mediaVersion++;
        record.admission = admission;
        if (!store.save(path.key, record, loop.wallNow())) storageProblem = true;
        playback = null;
        stopPlayer();
        if (resumedRoute) retire("The request is no longer admitted");
        else nextJoinAt = now;
    }

    private void reconcilePlayer(long now) {
        boolean want = admission == AccessStore.Admission.ADMITTED && routeStateConfirmed && state != null && state.live()
                && playback != null && playbackRevision == state.revision;
        if (!want) { stopPlayer(); return; }
        if (!playerActive) {
            if (now >= nextPlayAt) {
                playerGeneration++;
                playerActive = true; playerStartedAt = now; playingRevision = playbackRevision;
                player.play(playerGeneration, playback);
            }
            return;
        }
        if (player.negotiating(playerGeneration)) playerStartedAt = now;
        long last = player.lastFrameAt(playerGeneration);
        long since = now - Math.max(last, playerStartedAt);
        if (since > WATCHDOG_MS) {
            reason = last == 0 ? "No video arrived" : "Video stopped arriving";
            restartPlayer();
            return;
        }
        if (last > 0 && now - last < FRESH_FRAME_MS) {
            everPlayed = true;
            if (now - playerStartedAt > 5000) playerFailures = 0;
        }
    }

    private void restartPlayer() {
        stopPlayer();
        playerFailures++;
        // Credentials may have been revoked or replaced; fetch them again before the next peer.
        playback = null;
        nextPlayAt = loop.now() + Math.min(10_000, 1000L << Math.min(4, playerFailures - 1));
        nextConfigAt = nextPlayAt;
    }

    private void stopPlayer() {
        if (!playerActive) return;
        playerActive = false;
        playingRevision = -1;
        player.stop();
    }

    private boolean framesFresh(long now) {
        if (!playerActive) return false;
        long last = player.lastFrameAt(playerGeneration);
        return last > 0 && now - last < FRESH_FRAME_MS;
    }

    // ---- Heartbeat ----

    private void heartbeat(boolean playing) {
        final int e = epoch; final AskPath p = path; final String sentPass = pass;
        final String health = playing ? "playing" : state != null && "holding".equals(state.state) ? "holding" : everPlayed ? "reconnecting" : "connecting";
        final int revision = playing ? playingRevision : -1;
        final int generation = playerGeneration;
        final long request = ++nextAdmissionRequest;
        final long version = mediaVersion;
        heartbeating = true;
        reportedPlaying = playing;
        nextHeartbeatAt = loop.now() + HEARTBEAT_MS;
        Gateway.Scope s = scope;
        io.execute(() -> {
            Gateway.HeartbeatResult result;
            long last = playing ? player.lastFrameAt(generation) : 0;
            boolean freshAtSend = last > 0 && loop.now() - last < FRESH_FRAME_MS;
            try {
                result = gateway.heartbeat(p, sentPass, freshAtSend,
                        playing && !freshAtSend ? "reconnecting" : health, freshAtSend ? revision : -1, COLOR, s);
            } catch (IOException ex) { result = null; }
            final Gateway.HeartbeatResult r = result;
            loop.post(() -> heartbeatDone(e, sentPass, version, request, r));
        });
    }

    private void heartbeatDone(int e, String sentPass, long version, long request, Gateway.HeartbeatResult result) {
        if (e != epoch || !running) return;
        heartbeating = false;
        if (admission.refused() || sentPass == null || !sentPass.equals(pass)) { reconcile(); return; }
        AccessStore.Admission told = result == null ? null : AccessStore.Admission.parse(result.admission);
        if (told != null && told.refused()) { refuse(told); reconcile(); return; }
        if (result != null && result.status == Gateway.Status.GONE) { retire("This share ended"); reconcile(); return; }
        if (admission != AccessStore.Admission.ADMITTED || request < lastAdmissionReply) { reconcile(); return; }
        if (result == null || result.status == Gateway.Status.ERROR) {
            if (version == mediaVersion) gatewayFailure("Connection to the Mac failed");
            reconcile();
            return;
        }
        gatewayFailures = 0;
        lastAdmissionReply = request;
        if (told == AccessStore.Admission.PENDING) pending(loop.now());
        else if (told == null) lapsed();
        else if (told == AccessStore.Admission.ADMITTED && extras != null) extras.chatHint(result.chatLastId);
        reconcile();
    }

    // ---- Presentation ----

    private void publish() {
        if (extras != null) {
            // Chat and pointers exist only for an admitted pass. Any refusal, lapse, new share, or stop
            // unbinds them first, which cancels their requests and drops their content.
            // Stop Sharing ends the session chat on the Mac; drop it here at once rather than on the next reply.
            boolean admitted = running && path != null && pass != null && admission == AccessStore.Admission.ADMITTED
                    && routeStateConfirmed && state != null && !"stopped".equals(state.state);
            extras.setPictureRevision(admitted && state.live() ? state.revision : -1);
            extras.bind(admitted ? path : null, admitted ? pass : null, host == null ? null : host.name);
        }
        long now = loop.now();
        Phase phase;
        if (host == null) phase = Phase.UNCONFIGURED;
        else if (!running) phase = Phase.PAUSED;
        else if (path == null) phase = ended ? Phase.ENDED : Phase.SEARCHING;
        else {
            switch (admission) {
                case DECLINED: phase = Phase.DECLINED; break;
                case REMOVED: phase = Phase.REMOVED; break;
                case PENDING: phase = Phase.WAITING; break;
                case ADMITTED:
                    if (state == null) phase = Phase.CONNECTING;
                    else if ("stopped".equals(state.state)) phase = Phase.ENDED;
                    else if ("holding".equals(state.state)) phase = Phase.HOLDING;
                    else if ("reconnecting".equals(state.state)) phase = Phase.AUDIENCE_RECONNECTING;
                    else if (framesFresh(now)) phase = Phase.LIVE;
                    else phase = everPlayed ? Phase.STALLED : Phase.CONNECTING;
                    break;
                default:
                    if (nameRejected) phase = Phase.NAME_REJECTED;
                    else if (storageProblem && !joining && !manualAsk) phase = Phase.STORAGE_PROBLEM;
                    else if (busy) phase = Phase.BUSY;
                    else if (!joining && !manualAsk && (record.passUnreadable || record.asks >= MAX_AUTO_ASKS)) phase = Phase.NEEDS_ASK;
                    else phase = askingAgain || record.asks > 0 ? Phase.ASKING_AGAIN : Phase.ASKING;
            }
            // Contact lost: say so rather than showing a stale pending or admitted state. Refusals stay
            // shown as refusals, and a picture that is still arriving stays Live.
            if (lostContact() && !admission.refused() && phase != Phase.LIVE) phase = Phase.SEARCHING;
        }
        boolean canAsk = phase == Phase.NEEDS_ASK || phase == Phase.NAME_REJECTED || phase == Phase.BUSY || phase == Phase.STORAGE_PROBLEM;
        String title = state != null ? state.title : playback != null ? playback.title : "";
        boolean sample = (state != null && state.sample) || (playback != null && playback.sample);
        String feed = eventsOpen && eventsHeard ? "pushed" : "polled";
        View view = new View(phase, title == null ? "" : title, sample, host == null ? "" : host.baseUrl(), host == null ? "" : host.name,
                number, reason == null ? "" : reason, path == null ? "" : via + " " + path.route.address.getHostAddress() + ":" + path.route.port,
                path == null ? "" : path.label(), state == null ? "" : state.state, state == null ? -1 : state.revision,
                admission.name().toLowerCase(java.util.Locale.ROOT), feed, canAsk, playerActive ? playerGeneration : 0);
        listener.onView(view);
    }

    private void scheduleTick(long delay) {
        if (tickScheduled) return;
        tickScheduled = true;
        loop.postDelayed(this::tick, delay);
    }

    private static long backoff(int failures) { return Math.min(5000, 1500L * Math.max(1, failures)); }
    private static long resolveBackoff(int failures) {
        // A dedicated receiver keeps looking: at most 15 s between attempts, with no remote needed.
        long[] steps = {2000, 4000, 8000, 15_000};
        return steps[Math.min(steps.length - 1, Math.max(0, failures - 1))];
    }

    // ---- Test visibility ----
    AccessStore.Admission admissionForTest() { return admission; }
    boolean playerActiveForTest() { return playerActive; }
    AskPath pathForTest() { return path; }
}
