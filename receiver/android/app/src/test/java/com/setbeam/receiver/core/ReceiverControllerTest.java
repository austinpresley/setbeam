package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import java.io.IOException;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.PriorityQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.Executor;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;

import org.junit.Before;
import org.junit.Test;

/** Recovery and access semantics of the receiver state machine, with a fake clock and Mac. */
public class ReceiverControllerTest {

    // ---- Fakes ----

    /** A manual clock. Tasks may be posted from I/O threads; they run only inside advance(). */
    static final class FakeLoop implements ReceiverController.Loop {
        volatile long now = 1000, wall = 1_800_000_000_000L;
        long seq;
        long posted;
        final PriorityQueue<long[]> order = new PriorityQueue<>((a, b) -> a[0] != b[0] ? Long.compare(a[0], b[0]) : Long.compare(a[1], b[1]));
        final Map<Long, Runnable> tasks = new HashMap<>();
        @Override public void post(Runnable task) { postDelayed(task, 0); }
        @Override public synchronized void postDelayed(Runnable task, long delayMs) {
            long id = seq++; order.add(new long[]{now + delayMs, id}); tasks.put(id, task); posted++; notifyAll();
        }
        @Override public long now() { return now; }
        @Override public long wallNow() { return wall; }
        synchronized long posted() { return posted; }
        /** Waits (real time) until something has been posted since {@code mark}. */
        synchronized void awaitPostedAfter(long mark) throws InterruptedException {
            long until = System.currentTimeMillis() + 3000;
            while (posted <= mark && System.currentTimeMillis() < until) wait(50);
            assertTrue("nothing was posted to the loop", posted > mark);
        }
        void advance(long ms) {
            long target = now + ms;
            while (true) {
                Runnable task;
                synchronized (this) {
                    if (order.isEmpty() || order.peek()[0] > target) break;
                    long[] next = order.poll();
                    wall += next[0] - now; now = next[0];
                    task = tasks.remove(next[1]);
                }
                task.run();
            }
            synchronized (this) { wall += target - now; now = target; }
        }
    }

    /**
     * Runs each I/O task on its own thread and returns when it has finished or has parked in a
     * deliberately blocking fake call (an open event stream, a held reply), so ordinary calls stay
     * deterministic while long-lived ones behave as on a device.
     */
    static final class SettlingExecutor implements Executor {
        private static final ThreadLocal<Semaphore> SETTLED = new ThreadLocal<>();
        @Override public void execute(Runnable task) {
            Semaphore settled = new Semaphore(0);
            Thread thread = new Thread(() -> { SETTLED.set(settled); try { task.run(); } finally { settled.release(); } });
            thread.setDaemon(true);
            thread.start();
            try { assertTrue("I/O task neither finished nor parked", settled.tryAcquire(5, TimeUnit.SECONDS)); }
            catch (InterruptedException e) { throw new AssertionError(e); }
        }
        /** Called by a fake on an I/O thread just before it blocks. */
        static void parkCurrent() { Semaphore settled = SETTLED.get(); if (settled != null) settled.release(); }
    }

    /** An in-memory Mac following the gateway's admission ledger. */
    static final class FakeMac implements Gateway {
        final Map<String, String> passes = new HashMap<>();
        final Map<String, Boolean> ready = new HashMap<>();
        String currentCode = "a".repeat(64);
        volatile boolean reachable = true;
        String state = "live"; int revision = 1; boolean sample = false;
        int asks, joins, configs, heartbeats, resolves, statePolls, eventStreams;
        boolean reportedPlaying;
        int reportedRevision = -1;
        /** When true, events() opens a stream that delivers pushes until END or cancellation. */
        volatile boolean pushMode;
        final BlockingQueue<StateResult> pushes = new LinkedBlockingQueue<>();
        static final StateResult END = StateResult.of(Status.ERROR);
        /** When true, config() parks until a permit is released, then answers from the state at that time. */
        volatile boolean holdConfig;
        Gateway.StateResult heldPoll;
        final Semaphore releasePoll = new Semaphore(0);
        HeartbeatResult heldHeartbeat;
        Scope heldHeartbeatScope;
        final Semaphore releaseHeartbeat = new Semaphore(0);
        ConfigResult capturedConfig;
        boolean failStateUntilResolve;
        int gatewayPort = 52001;
        boolean loseAskResponse;
        final List<String> requestIDs = new ArrayList<>();
        final Semaphore releaseConfig = new Semaphore(0);
        final List<String> askedCodes = new ArrayList<>();
        final List<Long> askWalls = new ArrayList<>();
        final List<Long> fullAt = new ArrayList<>();
        FakeLoop clock;
        int nextPass = 1;
        int fullReplies;
        final InetAddress address;
        FakeMac() throws IOException { address = InetAddress.getByName("192.168.1.20"); }

        AskPath pathFor(String code) {
            try {
                MiniHttp.Route root = new MiniHttp.Route("http", address, 80, "192.168.1.20", "192.168.1.20");
                return AskPath.fromRedirect(root, 302, "http://192.168.1.20:" + gatewayPort + "/s/" + code + "/");
            } catch (AskPath.Rejected e) { throw new AssertionError(e); }
        }
        boolean current(AskPath path) { return path.sameShare(pathFor(currentCode)); }
        String passFor(String admission) { for (Map.Entry<String, String> e : passes.entrySet()) if (e.getValue().equals(admission)) return e.getKey(); return null; }
        synchronized void decide(String admission) { String pass = passFor("pending"); assertNotNull("a pending request", pass); passes.put(pass, admission); if (admission.equals("admitted")) ready.put(pass, true); }
        synchronized void removeAdmitted() { String pass = passFor("admitted"); assertNotNull(pass); passes.put(pass, "removed"); }
        /** A new share: new code, cleared ledger. */
        synchronized void newShare(String code) { currentCode = code; passes.clear(); ready.clear(); revision++; }

        @Override public synchronized Resolution resolve(HostConfig host, Scope scope) throws IOException {
            resolves++;
            failStateUntilResolve = false;
            if (!reachable) throw new IOException("refused");
            return new Resolution(pathFor(currentCode), "configured address", null);
        }
        @Override public synchronized JoinResult join(AskPath path, String pass, String name, boolean ask, String color, String requestID, Scope scope) throws IOException {
            if (!reachable) throw new IOException("refused");
            joins++;
            if (!current(path)) return JoinResult.of(Status.GONE);
            if (pass != null && passes.containsKey(pass)) {
                String admission = passes.get(pass);
                return new JoinResult(Status.OK, pass, 1, AccessStore.Admission.parse(admission), ready.getOrDefault(pass, false));
            }
            if (!ask || name == null) return JoinResult.of(Status.NAME_REQUIRED);
            if (fullReplies > 0) { fullReplies--; fullAt.add(clock.now); return JoinResult.of(Status.FULL); }
            requestIDs.add(requestID);
            if (loseAskResponse) { loseAskResponse = false; throw new IOException("response lost"); }
            asks++; askedCodes.add(currentCode); if (clock != null) askWalls.add(clock.wall);
            String issued = String.format("%048x", nextPass++);
            passes.put(issued, "pending");
            return new JoinResult(Status.OK, issued, passes.size(), AccessStore.Admission.PENDING, false);
        }
        @Override public StateResult state(AskPath path, Scope scope) throws IOException {
            StateResult delayed;
            synchronized (this) {
                if (!reachable || failStateUntilResolve) throw new IOException("refused");
                statePolls++;
                delayed = heldPoll;
                heldPoll = null;
                if (delayed == null) return current(path)
                        ? new StateResult(Status.OK, state, "Feed", sample, revision, true) : StateResult.of(Status.GONE);
            }
            waitFor(releasePoll);
            return delayed;
        }
        @Override public ConfigResult config(AskPath path, String pass, Scope scope) throws IOException {
            ConfigResult delayed = capturedConfig;
            capturedConfig = null;
            if (holdConfig) waitFor(releaseConfig);
            return delayed == null ? configNow(path, pass) : delayed;
        }
        private static void waitFor(Semaphore release) throws IOException {
            SettlingExecutor.parkCurrent();
            try { release.acquire(); } catch (InterruptedException e) { throw new IOException(e); }
        }
        synchronized ConfigResult configNow(AskPath path, String pass) throws IOException {
            if (!reachable) throw new IOException("refused");
            configs++;
            if (!current(path)) return new ConfigResult(Status.GONE, null, null);
            String admission = passes.getOrDefault(pass, "unknown");
            if (!admission.equals("admitted")) return new ConfigResult(Status.NOT_ADMITTED, null, admission);
            if (!ready.getOrDefault(pass, false)) return new ConfigResult(Status.NOT_READY, null, null);
            try {
                return new ConfigResult(Status.OK, new Playback(WhepTarget.validate("http://192.168.1.20:8889/live/whep", path.route),
                        "viewer1x0", "p" + revision, "Feed", sample), null);
            } catch (AskPath.Rejected e) { throw new IOException(e); }
        }
        @Override public HeartbeatResult heartbeat(AskPath path, String pass, boolean playing, String health, int rev, String color, Scope scope) throws IOException {
            HeartbeatResult delayed;
            synchronized (this) {
                if (!reachable) throw new IOException("refused");
                heartbeats++;
                reportedPlaying = playing;
                reportedRevision = rev;
                if (!current(path)) return new HeartbeatResult(Status.GONE, null);
                delayed = heldHeartbeat;
                if (delayed == null) {
                    String admission = passes.getOrDefault(pass, "unknown");
                    return new HeartbeatResult(Status.OK, admission, admission.equals("admitted") ? chatLastId : -1);
                }
                heldHeartbeat = null;
                heldHeartbeatScope = scope;
            }
            waitFor(releaseHeartbeat);
            return delayed;
        }

        // ---- Session chat and pointers ----
        volatile int chatLastId = 0;
        final List<ChatLine> chatLines = new ArrayList<>();
        int chatFetches;
        final List<String> chatPasses = new ArrayList<>();
        volatile boolean pointersOffered = true;
        volatile int pointerRevisionOverride = -1;
        int presenceOpens;
        final List<String> presencePasses = new ArrayList<>();
        final BlockingQueue<List<Pointer>> pointerPushes = new LinkedBlockingQueue<>();
        final List<Scope> presenceScopes = new ArrayList<>();
        synchronized void say(String name, String text) {
            chatLastId++;
            chatLines.add(new ChatLine(chatLastId, name, "blue", false, text, 0, false, false, 0, ""));
        }
        @Override public synchronized ChatResult chat(AskPath path, String pass, Scope scope) throws IOException {
            if (!reachable) throw new IOException("refused");
            chatFetches++; chatPasses.add(pass);
            if (!current(path)) return new ChatResult(Status.GONE, List.of());
            if (!"admitted".equals(passes.get(pass))) return new ChatResult(Status.NOT_ADMITTED, List.of());
            return new ChatResult(Status.OK, List.copyOf(chatLines));
        }
        @Override public void presence(AskPath path, String pass, String name, String color, Scope scope, PresenceEvents events) throws IOException {
            synchronized (this) {
                presenceOpens++; presencePasses.add(pass); presenceScopes.add(scope);
                if (!reachable) throw new IOException("refused");
                if (!pointersOffered) { events.denied("off"); return; }
                if (!"admitted".equals(passes.get(pass))) { events.denied("access"); return; }
            }
            events.welcome();
            SettlingExecutor.parkCurrent();
            while (!scope.isCancelled()) {
                List<Pointer> next;
                try { next = pointerPushes.poll(20, TimeUnit.MILLISECONDS); } catch (InterruptedException e) { return; }
                if (next != null && !scope.isCancelled()) events.pointers(pointerRevisionOverride < 0 ? revision : pointerRevisionOverride, next);
            }
        }
        @Override public void events(AskPath path, Scope scope, Consumer<StateResult> onState) throws IOException {
            if (!pushMode) throw new IOException("no stream; polling is the fallback");
            StateResult first;
            synchronized (this) {
                eventStreams++;
                first = current(path) ? new StateResult(Status.OK, state, "Feed", sample, revision, true) : StateResult.of(Status.GONE);
            }
            onState.accept(first);
            if (first.status == Status.GONE) return;
            SettlingExecutor.parkCurrent();
            while (!scope.isCancelled()) {
                if (!reachable) return; // the Mac quit: its stream drops
                StateResult next;
                try { next = pushes.poll(20, TimeUnit.MILLISECONDS); } catch (InterruptedException e) { return; }
                if (next == END) return;
                if (next != null && !scope.isCancelled()) onState.accept(next);
            }
        }
        StateResult pushed(String newState) {
            synchronized (this) { state = newState; return new StateResult(Status.OK, state, "Feed", sample, revision, true); }
        }
    }

    static final class FakePlayer implements ReceiverController.Player {
        final FakeLoop loop;
        int playing; int plays; int stops; boolean frames = true;
        Gateway.Playback last;
        FakePlayer(FakeLoop loop) { this.loop = loop; }
        @Override public void play(int generation, Gateway.Playback playback) { playing = generation; plays++; last = playback; }
        @Override public void stop() { if (playing != 0) stops++; playing = 0; }
        @Override public long lastFrameAt(int generation) { return frames && generation != 0 && generation == playing ? loop.now : 0; }
    }

    FakeLoop loop;
    Executor io = Runnable::run;
    AccessStore.SecretBox box = new AccessStoreTest.ReverseBox();
    FakeMac mac;
    FakePlayer player;
    AccessStoreTest.MemoryValues values;
    ReceiverController controller;
    ReceiverController.View view;
    HostConfig host;

    @Before public void setUp() throws Exception {
        loop = new FakeLoop();
        mac = new FakeMac();
        mac.clock = loop;
        player = new FakePlayer(loop);
        values = new AccessStoreTest.MemoryValues();
        host = HostConfig.parse("setbeam.local", "Stage TV");
        controller = newController();
    }

    ReceiverController newController() {
        return newController(Runnable::run, new AccessStoreTest.ReverseBox());
    }

    ReceiverController newController(Executor io, AccessStore.SecretBox box) {
        this.io = io; this.box = box;
        return new ReceiverController(loop, io, mac, new AccessStore(values, box), player, v -> view = v);
    }

    /** Simulates an app or device restart: a new controller over the same persisted store. */
    void restart() {
        controller.stop();
        loop.advance(10);
        controller = newController(io, box);
        controller.start(host);
    }

    void run(long ms) { loop.advance(ms); }

    // ---- Tests ----

    @Test public void asksOnceThenWaitsWithoutAskingAgain() {
        controller.start(host);
        run(1000);
        assertEquals(1, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        run(60_000);
        assertEquals("pending requests are kept alive with the pass, never re-asked", 1, mac.asks);
        assertTrue("joins with the pass keep the request alive", mac.joins > 20);
        assertEquals(0, player.plays);
    }

    @Test public void admittedPlaysOnlyWhileLiveAndClaimsLiveOnlyWithFreshFrames() {
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        assertEquals(1, player.plays);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        player.frames = false;
        run(3000);
        assertEquals(ReceiverController.Phase.STALLED, view.phase);
        assertTrue(player.playing != 0);
        run(8000);
        assertTrue("watchdog replaced the silent peer", player.plays >= 2);
        player.frames = true;
        run(15_000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
    }

    @Test public void heartbeatOnlyReportsPlayingAfterAnAuthorizedFrame() {
        player.frames = false;
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        assertEquals(ReceiverController.Phase.CONNECTING, view.phase);
        assertFalse(mac.reportedPlaying);
        assertEquals(-1, mac.reportedRevision);

        player.frames = true;
        run(1000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        assertTrue(mac.reportedPlaying);
        assertEquals(mac.revision, mac.reportedRevision);

        player.frames = false;
        run(1000);
        assertEquals(ReceiverController.Phase.STALLED, view.phase);
        assertFalse(mac.reportedPlaying);
        assertEquals(-1, mac.reportedRevision);
    }

    @Test public void holdClosesMediaAtOnceAndLiveRefetchesConfig() {
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        int configs = mac.configs;
        mac.state = "holding";
        run(2000);
        assertEquals(0, player.playing);
        assertEquals(ReceiverController.Phase.HOLDING, view.phase);
        for (String other : new String[]{"reconnecting", "stopped"}) {
            mac.state = other;
            run(2000);
            assertEquals("no media for " + other, 0, player.playing);
        }
        mac.state = "live";
        run(3000);
        assertNotEquals(0, player.playing);
        assertTrue("config fetched again after live returned", mac.configs > configs);
    }

    @Test public void newRevisionFetchesConfigAndOpensANewPeer() {
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        int plays = player.plays, configs = mac.configs;
        mac.revision++;
        run(3000);
        assertEquals(plays + 1, player.plays);
        assertTrue(mac.configs > configs);
        assertEquals("p" + mac.revision, player.last.password);
    }

    @Test public void declineIsTerminalAcrossRestartsAndANewShareAsksOnce() {
        controller.start(host);
        run(1000);
        mac.decide("declined");
        run(3000);
        assertEquals(ReceiverController.Phase.DECLINED, view.phase);
        run(120_000);
        assertEquals(1, mac.asks);
        restart();
        run(120_000);
        assertEquals("a restart never asks again on a declined path", 1, mac.asks);
        assertEquals(ReceiverController.Phase.DECLINED, view.phase);
        // Even if the Mac forgets the pass, the stored refusal stands for that path.
        mac.passes.clear();
        restart();
        run(60_000);
        assertEquals(1, mac.asks);

        mac.newShare("b".repeat(64));
        run(20_000);
        assertEquals("a new share asks once", 2, mac.asks);
        assertEquals("b".repeat(64), mac.askedCodes.get(1));
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
    }

    @Test public void removalClosesMediaAtOnceAndStaysRemovedAfterRestart() {
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        assertNotEquals(0, player.playing);
        mac.removeAdmitted();
        run(3500);
        assertEquals(0, player.playing);
        assertEquals(ReceiverController.Phase.REMOVED, view.phase);
        restart();
        run(60_000);
        assertEquals(1, mac.asks);
        assertEquals(0, player.playing);
        assertEquals(ReceiverController.Phase.REMOVED, view.phase);
    }

    @Test public void restartWhilePendingResumesTheSameRequest() {
        controller.start(host);
        run(1000);
        restart();
        run(5000);
        assertEquals(1, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        mac.decide("admitted");
        run(3000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
    }

    @Test public void lapsedRequestAsksAgainNoFasterThanEvery30Seconds() {
        controller.start(host);
        run(1000);
        assertEquals(1, mac.asks);
        // The Mac forgets every pass repeatedly, as during long outages.
        for (int i = 0; i < 12; i++) {
            mac.passes.clear();
            int before = mac.asks;
            for (int t = 0; t < 400 && mac.asks == before; t++) run(250);
        }
        List<Long> askTimes = mac.askWalls;
        for (int i = 1; i < askTimes.size(); i++) {
            assertTrue("asks " + (askTimes.get(i) - askTimes.get(i - 1)) + " ms apart", askTimes.get(i) - askTimes.get(i - 1) >= ReceiverController.REASK_INTERVAL_MS);
        }
        assertEquals("automatic re-asks are capped", ReceiverController.MAX_AUTO_ASKS, mac.asks);
        run(300_000);
        assertEquals(ReceiverController.MAX_AUTO_ASKS, mac.asks);
        assertEquals(ReceiverController.Phase.NEEDS_ASK, view.phase);
        assertTrue(view.canAskAgain);
        controller.askAgain();
        run(1000);
        assertEquals(ReceiverController.MAX_AUTO_ASKS + 1, mac.asks);
    }

    @Test public void lapseIntervalSurvivesRestartAndBackwardsClock() {
        controller.start(host);
        run(1000);
        mac.passes.clear();
        restart();
        loop.wall -= 3_600_000; // the device clock jumps back an hour
        run(5000);
        assertEquals("a backwards clock does not allow an early re-ask", 1, mac.asks);
        run(40_000);
        assertEquals(2, mac.asks);
    }

    @Test public void retiredPathFindsTheNewShare() {
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        assertNotEquals(0, player.playing);
        mac.reachable = false;
        mac.newShare("c".repeat(64));
        run(5000);
        mac.reachable = true;
        run(20_000);
        assertEquals("the old share's 404 or failure leads to the new share", 2, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        assertEquals(0, player.playing);
    }

    @Test public void unreachableMacShowsSearchingAndBacksOff() {
        mac.reachable = false;
        controller.start(host);
        run(60_000);
        assertEquals(ReceiverController.Phase.SEARCHING, view.phase);
        assertTrue("backoff bounds attempts: " + mac.resolves, mac.resolves <= 8);
        mac.reachable = true;
        controller.nudge();
        run(1000);
        assertEquals(1, mac.asks);
    }

    @Test public void sampleLabelFollowsTheSession() {
        mac.sample = true;
        controller.start(host);
        run(3000);
        assertTrue(view.sample);
        mac.decide("admitted");
        run(3000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        assertTrue(view.sample);
    }

    @Test public void busyMacIsRetriedEvery10SecondsWithoutCountingAsAnAsk() {
        mac.fullReplies = 3;
        controller.start(host);
        run(1000);
        assertEquals(ReceiverController.Phase.BUSY, view.phase);
        run(40_000);
        assertEquals(3, mac.fullAt.size());
        for (int i = 1; i < mac.fullAt.size(); i++) assertTrue(mac.fullAt.get(i) - mac.fullAt.get(i - 1) >= ReceiverController.FULL_RETRY_MS);
        assertEquals("the request is created once the Mac has room", 1, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        AccessStore.Record stored = new AccessStore(values, new AccessStoreTest.ReverseBox()).load(mac.pathFor(mac.currentCode).key);
        assertEquals("only the created request counts", 1, stored.asks);
    }

    @Test public void stopClosesEverything() {
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        controller.stop();
        assertEquals(0, player.playing);
        int joins = mac.joins, beats = mac.heartbeats;
        run(30_000);
        assertEquals(joins, mac.joins);
        assertEquals(beats, mac.heartbeats);
        assertEquals(ReceiverController.Phase.PAUSED, view.phase);
    }

    @Test public void viewNeverExposesSecrets() {
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        String everything = view.route + view.share + view.reason + view.host + view.title;
        assertFalse(everything.contains(mac.currentCode.substring(0, 16)));
        for (String pass : mac.passes.keySet()) assertFalse(everything.contains(pass));
    }

    // ---- Round 2 regressions ----

    void useThreads() {
        controller.stop();
        controller = newController(new SettlingExecutor(), box);
    }

    void push(String state) throws InterruptedException {
        long mark = loop.posted();
        mac.pushes.add(mac.pushed(state));
        loop.awaitPostedAfter(mark);
    }

    @Test public void pushedHoldStopsMediaWithoutWaitingForAPoll() throws Exception {
        mac.pushMode = true;
        useThreads();
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        assertEquals("pushed updates replace polling", "pushed", view.stateFeed);
        int polls = mac.statePolls;
        push("holding");
        run(10);
        assertEquals("Hold detaches within one loop turn", 0, player.playing);
        assertEquals(ReceiverController.Phase.HOLDING, view.phase);
        assertEquals("no poll was needed", polls, mac.statePolls);
        push("live");
        run(3000);
        assertNotEquals(0, player.playing);
        push("stopped");
        run(10);
        assertEquals(0, player.playing);
        controller.stop();
    }

    @Test public void endedStreamFallsBackToPollingAndReopens() throws Exception {
        mac.pushMode = true;
        useThreads();
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        int streams = mac.eventStreams, polls = mac.statePolls;
        long mark = loop.posted();
        mac.pushes.add(FakeMac.END);
        loop.awaitPostedAfter(mark);
        run(5000);
        assertTrue("polling resumes while the stream is down", mac.statePolls > polls);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        run(15_000);
        assertTrue("the stream is opened again", mac.eventStreams > streams);
        controller.stop();
    }

    @Test public void pushedRetirementFindsTheNewShare() throws Exception {
        mac.pushMode = true;
        useThreads();
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        mac.pushes.add(FakeMac.END);
        mac.newShare("d".repeat(64));
        run(20_000);
        assertEquals("the retired share's media is closed", 0, player.playing);
        assertEquals("the new share is asked for once, untouched", 2, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        controller.stop();
    }

    @Test public void lateConfigReplyAfterRemovalNeverAsksAgain() throws Exception {
        useThreads();
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        // A new revision makes the receiver fetch playback details; the Mac holds that reply.
        mac.holdConfig = true;
        synchronized (mac) { mac.revision++; }
        run(2000);
        // Meanwhile the operator removes the receiver and a heartbeat reports it.
        mac.removeAdmitted();
        run(3500);
        assertEquals(ReceiverController.Phase.REMOVED, view.phase);
        // Then the Mac forgets the pass, and the held reply finally says "unknown".
        long mark = loop.posted();
        synchronized (mac) { mac.passes.clear(); }
        mac.releaseConfig.release();
        loop.awaitPostedAfter(mark);
        run(120_000);
        assertEquals("a late reply cannot turn a removal into a lapse", 1, mac.asks);
        assertEquals(ReceiverController.Phase.REMOVED, view.phase);
        assertEquals(0, player.playing);
        controller.stop();
    }

    @Test public void unsequencedPollCannotUndoHoldPushedWhileItWasInFlight() throws Exception {
        useThreads();
        mac.pushMode = true;
        mac.state = "holding";
        mac.heldPoll = new Gateway.StateResult(Gateway.Status.OK, "live", "Stale", false, mac.revision, true);
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(3000);
        assertEquals(ReceiverController.Phase.HOLDING, view.phase);
        long mark = loop.posted();
        mac.releasePoll.release();
        loop.awaitPostedAfter(mark);
        run(100);
        assertEquals(ReceiverController.Phase.HOLDING, view.phase);
        assertEquals(0, player.plays);
        controller.stop();
    }

    @Test public void sequenceOrdersPushedUpdatesWithinOnePublisherRevision() throws Exception {
        useThreads();
        mac.pushMode = true;
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        sendState("holding", 12);
        sendState("live", 11);
        assertEquals(ReceiverController.Phase.HOLDING, view.phase);
        sendState("live", 13);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        controller.stop();
    }

    private void sendState(String state, long sequence) throws InterruptedException {
        long mark = loop.posted();
        mac.pushes.add(new Gateway.StateResult(Gateway.Status.OK, state, "Feed", false, mac.revision, true, sequence));
        loop.awaitPostedAfter(mark);
        run(300);
    }

    @Test public void configFromBeforeHoldCannotStartAnOldPeerAfterResume() throws Exception {
        useThreads();
        mac.pushMode = true;
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        int plays = player.plays;
        mac.revision++;
        mac.holdConfig = true;
        mac.capturedConfig = mac.configNow(controller.pathForTest(), mac.passFor("admitted"));
        push("live");
        run(250);
        push("holding");
        run(250);
        push("live");
        run(250);
        mac.holdConfig = false;
        long mark = loop.posted();
        mac.releaseConfig.release();
        loop.awaitPostedAfter(mark);
        int configs = mac.configs;
        run(500);
        assertEquals("resume fetched a fresh config despite unchanged publisher revision", configs + 1, mac.configs);
        assertEquals(plays + 1, player.plays);
        controller.stop();
    }

    @Test public void olderHeartbeatCannotLapseAPassConfirmedByNewerConfig() throws Exception {
        useThreads();
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        mac.heldHeartbeat = new Gateway.HeartbeatResult(Gateway.Status.OK, "unknown");
        run(3500);
        assertNotNull(mac.heldHeartbeatScope);
        int configs = mac.configs;
        mac.revision++;
        run(2000);
        assertEquals(configs + 1, mac.configs);
        long mark = loop.posted();
        mac.releaseHeartbeat.release();
        loop.awaitPostedAfter(mark);
        run(500);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        assertEquals(1, mac.asks);
        controller.stop();
    }

    @Test public void sameShareRouteMoveCancelsOldHeartbeatAndPreservesThePass() throws Exception {
        useThreads();
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        mac.heldHeartbeat = new Gateway.HeartbeatResult(Gateway.Status.OK, "removed");
        run(4000);
        Gateway.Scope old = mac.heldHeartbeatScope;
        assertNotNull(old);

        mac.gatewayPort++;
        mac.failStateUntilResolve = true;
        run(20_000);
        assertEquals(mac.gatewayPort, controller.pathForTest().route.port);
        assertTrue(old.isCancelled());
        assertEquals(ReceiverController.Phase.LIVE, view.phase);

        long mark = loop.posted();
        mac.releaseHeartbeat.release();
        loop.awaitPostedAfter(mark);
        run(4000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        assertEquals(1, mac.asks);
        assertEquals(mac.gatewayPort, new AccessStore(values, box).admittedRoute(host).route.port);
        controller.stop();
    }

    @Test public void ambiguousAskReusesItsDurableIdAcrossRestartAndLapseGetsANewId() {
        mac.loseAskResponse = true;
        controller.start(host);
        run(1000);
        String first = mac.requestIDs.get(0);
        assertNotNull(first);
        assertEquals(first, new AccessStore(values, box).load(controller.pathForTest().key).requestID);
        restart();
        run(35_000);
        assertEquals(List.of(first, first), mac.requestIDs);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        mac.passes.clear();
        run(35_000);
        assertEquals(3, mac.requestIDs.size());
        assertNotEquals(first, mac.requestIDs.get(2));
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
    }

    @Test public void sealFailureWaitsForTheTvUserAfterRestart() {
        controller = newController(Runnable::run, new AccessStoreTest.NoSealBox());
        controller.start(host);
        run(1000);
        assertEquals(1, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        restart();
        run(120_000);
        assertEquals("a pass that could not be stored never becomes a fresh request", 1, mac.asks);
        assertEquals(ReceiverController.Phase.NEEDS_ASK, view.phase);
        controller.askAgain();
        run(1000);
        assertEquals(2, mac.asks);
    }

    @Test public void storageFailurePreventsAutomaticRequests() {
        values.failWrites = true;
        controller.start(host);
        run(60_000);
        assertEquals("nothing is asked when the count cannot be stored", 0, mac.asks);
        assertEquals(ReceiverController.Phase.STORAGE_PROBLEM, view.phase);
        assertTrue(view.canAskAgain);
        controller.askAgain();
        run(1000);
        assertEquals("a request ID must be durable even for an explicit request", 0, mac.asks);
        values.failWrites = false;
        controller.askAgain();
        run(1000);
        assertEquals(1, mac.asks);
    }

    @Test public void silentlyDroppedWritesAreCaughtBeforeAsking() {
        values.dropWrites = true;
        controller.start(host);
        run(60_000);
        assertEquals(0, mac.asks);
        assertEquals(ReceiverController.Phase.STORAGE_PROBLEM, view.phase);
    }

    @Test public void storeFullOfRefusalsFailsClosed() {
        AccessStore store = new AccessStore(values, box);
        for (int i = 0; i < AccessStore.MAX_RECORDS; i++) assertTrue(store.refuse("old" + i, AccessStore.Admission.DECLINED, i));
        controller.start(host);
        run(60_000);
        assertEquals("no request without room to remember it", 0, mac.asks);
        assertEquals(ReceiverController.Phase.STORAGE_PROBLEM, view.phase);
    }

    @Test public void refusalSurvivesManyLaterShares() {
        controller.start(host);
        run(1000);
        mac.decide("declined");
        run(3000);
        String refusedCode = mac.currentCode;
        for (int i = 0; i < 40; i++) {
            mac.newShare(String.format("%064x", 1000 + i));
            run(20_000);
        }
        assertEquals(41, mac.asks);
        mac.newShare(refusedCode);
        run(60_000);
        assertEquals("a refused share's path is still refused after 40 newer shares", 41, mac.asks);
        assertEquals(ReceiverController.Phase.DECLINED, view.phase);
    }

    @Test public void laterShareIsFoundWithoutTouchesWhileWaitingOnTheTv() {
        controller.start(host);
        run(1000);
        for (int i = 0; i < 10; i++) { mac.passes.clear(); run(31_000); }
        assertEquals(ReceiverController.Phase.NEEDS_ASK, view.phase);
        int asks = mac.asks;
        mac.newShare("e".repeat(64));
        run(20_000);
        assertEquals("a new share is asked for with no remote", asks + 1, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
    }

    @Test public void longOutageStillFindsTheMacWithinFifteenSeconds() {
        mac.reachable = false;
        controller.start(host);
        run(600_000);
        mac.reachable = true;
        run(16_000);
        assertEquals("no nudge or remote needed", 1, mac.asks);
    }

    @Test public void restartingWithAnotherPairingCancelsTheOldOne() throws Exception {
        controller.start(host);
        run(1000);
        controller.start(HostConfig.parse("other.local", "Stage TV"));
        assertEquals(ReceiverController.Phase.SEARCHING, view.phase);
        assertEquals("http://other.local/", view.host);
        run(1000);
        assertEquals("same share (the fake ignores hosts): its request is resumed, not repeated", 1, mac.asks);
    }

    // ---- Lost contact (real-stack finding: Mac quits while a request is pending) ----

    @Test public void pendingThenMacQuitsShowsSearchingAndResumesTheSameShareWithoutAsking() {
        controller.start(host);
        run(1000);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        mac.reachable = false;                       // port 80 and the gateway refuse
        run(15_000);
        assertEquals("no stale 'waiting for the operator'", ReceiverController.Phase.SEARCHING, view.phase);
        assertTrue(view.reason.contains("Lost contact"));
        assertFalse(view.canAskAgain);
        run(60_000);
        assertEquals(ReceiverController.Phase.SEARCHING, view.phase);
        assertEquals("connection failure never creates a request", 1, mac.asks);
        int joins = mac.joins;
        mac.reachable = true;                        // the same share answers again
        run(16_000);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        assertEquals("the stored pass is resumed", 1, mac.asks);
        assertTrue(mac.joins > joins);
        mac.decide("admitted");
        run(4000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
    }

    @Test public void pendingThenMacRestartsWithANewShareAsksOnce() {
        controller.start(host);
        run(1000);
        mac.reachable = false;
        run(60_000);
        assertEquals(ReceiverController.Phase.SEARCHING, view.phase);
        mac.newShare("f".repeat(64));                // Setbeam relaunched: new link, old ledger gone
        mac.reachable = true;
        run(20_000);
        assertEquals(2, mac.asks);
        assertEquals("f".repeat(64), mac.askedCodes.get(1));
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        run(120_000);
        assertEquals(2, mac.asks);
    }

    @Test public void liveSessionLosingTheMacShowsSearchingAndRecoversWithFreshConfig() throws Exception {
        mac.pushMode = true;
        useThreads();
        controller.start(host);
        run(1000);
        mac.decide("admitted");
        run(4000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        mac.reachable = false;                       // the Mac's gateway and media go away
        player.frames = false;
        run(15_000);
        assertEquals(ReceiverController.Phase.SEARCHING, view.phase);
        int configs = mac.configs;
        synchronized (mac) { mac.revision++; }       // publisher recovered with a new revision
        mac.reachable = true;
        player.frames = true;
        run(25_000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
        assertTrue("playback details fetched again", mac.configs > configs);
        assertEquals("p" + mac.revision, player.last.password);
        assertEquals(1, mac.asks);
        controller.stop();
    }

    @Test public void refusalStaysShownWhileTheMacIsUnreachable() {
        controller.start(host);
        run(1000);
        mac.decide("declined");
        run(3000);
        mac.reachable = false;
        run(90_000);
        assertEquals(ReceiverController.Phase.DECLINED, view.phase);
        mac.reachable = true;
        run(30_000);
        assertEquals(ReceiverController.Phase.DECLINED, view.phase);
        assertEquals(1, mac.asks);
    }

    @Test public void lapseDuringALongOutageAsksOnceOnReturnInsteadOfExhaustingTheShare() {
        controller.start(host);
        run(1000);
        synchronized (mac) { mac.passes.clear(); }   // the request lapsed on the Mac
        run(3000);                                    // the receiver learns it and waits out the 30 s interval
        assertEquals(ReceiverController.Phase.ASKING_AGAIN, view.phase);
        mac.reachable = false;                        // the Mac goes away during that wait
        run(600_000);
        assertEquals(ReceiverController.Phase.SEARCHING, view.phase);
        mac.reachable = true;
        run(20_000);
        assertEquals("one new request after contact, not a stack of failed ones", 2, mac.asks);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        AccessStore.Record stored = new AccessStore(values, box).load(mac.pathFor(mac.currentCode).key);
        assertEquals(2, stored.asks);
    }
}
