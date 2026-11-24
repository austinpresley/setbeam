package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import com.setbeam.receiver.core.ReceiverControllerTest.FakeLoop;
import com.setbeam.receiver.core.ReceiverControllerTest.FakeMac;
import com.setbeam.receiver.core.ReceiverControllerTest.FakePlayer;
import com.setbeam.receiver.core.ReceiverControllerTest.SettlingExecutor;

import java.util.ArrayList;
import java.util.List;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;

/** Chat and pointers follow only the admitted pass, and vanish with any loss of access. */
public class SessionExtrasTest {
    FakeLoop loop;
    FakeMac mac;
    FakePlayer player;
    ReceiverController controller;
    SessionExtras extras;
    ReceiverController.View view;
    SessionExtras.Snapshot snapshot;
    final List<ChatLine> arrivals = new ArrayList<>();
    HostConfig host;

    @Before public void setUp() throws Exception {
        loop = new FakeLoop();
        mac = new FakeMac();
        mac.clock = loop;
        player = new FakePlayer(loop);
        host = HostConfig.parse("setbeam.local", "Stage TV");
        SettlingExecutor io = new SettlingExecutor();
        controller = new ReceiverController(loop, io, mac, new AccessStore(new AccessStoreTest.MemoryValues(), new AccessStoreTest.ReverseBox()),
                player, v -> view = v);
        extras = new SessionExtras(loop, io, mac, s -> { snapshot = s; arrivals.addAll(s.arrived); });
        controller.setExtras(extras);
    }

    @After public void tearDown() { controller.stop(); loop.advance(100); }

    void run(long ms) { loop.advance(ms); }

    void admit() {
        controller.start(host);
        run(1000);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        mac.decide("admitted");
        run(4000);
        assertEquals(ReceiverController.Phase.LIVE, view.phase);
    }

    @Test public void chatIsReadOnlyWithTheAdmittedPassAndNeverWhilePending() {
        mac.say("Director", "Before admission");
        controller.start(host);
        run(10_000);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        assertEquals("a pending request never reads chat", 0, mac.chatFetches);
        assertTrue(snapshot == null || !snapshot.bound);

        mac.decide("admitted");
        run(4000);
        assertTrue(snapshot.bound);
        assertEquals(1, snapshot.chat.size());
        assertEquals("Before admission", snapshot.chat.get(0).text);
        assertTrue("history is not announced as new", arrivals.isEmpty());
        for (String pass : mac.chatPasses) assertEquals("admitted", mac.passes.get(pass));

        int fetches = mac.chatFetches;
        run(30_000);
        assertEquals("unchanged chat is not fetched again while the panel is closed", fetches, mac.chatFetches);

        mac.say("Director", "Check focus");
        run(4000);
        assertEquals(2, snapshot.chat.size());
        assertEquals(1, arrivals.size());
        assertEquals("Check focus", arrivals.get(0).text);
    }

    @Test public void removalDropsChatAtOnceAndStopsReading() {
        mac.say("Director", "Hello");
        admit();
        assertEquals(1, snapshot.chat.size());
        mac.removeAdmitted();
        run(4000);
        assertEquals(ReceiverController.Phase.REMOVED, view.phase);
        assertFalse(snapshot.bound);
        assertTrue(snapshot.chat.isEmpty());
        int fetches = mac.chatFetches;
        mac.say("Director", "After removal");
        run(60_000);
        assertEquals("a removed session never reads chat again", fetches, mac.chatFetches);
    }

    @Test public void openPanelPollsAndANewShareStartsEmpty() {
        mac.say("Director", "Old share");
        admit();
        extras.setChatVisible(true);
        int fetches = mac.chatFetches;
        run(20_000);
        assertTrue("an open panel refreshes reactions and removals", mac.chatFetches >= fetches + 3);
        extras.setChatVisible(false);

        synchronized (mac) { mac.newShare("b".repeat(64)); mac.chatLines.clear(); mac.chatLastId = 0; }
        run(20_000);
        assertEquals(ReceiverController.Phase.WAITING, view.phase);
        assertFalse(snapshot.bound);
        assertTrue("nothing from the earlier share remains", snapshot.chat.isEmpty());
    }

    @Test public void pointersOpenOnlyWhenWantedAndOnlyForTheAdmittedPass() throws Exception {
        controller.start(host);
        extras.setPointersWanted(true);
        run(10_000);
        assertEquals("no channel while pending", 0, mac.presenceOpens);
        mac.decide("admitted");
        run(4000);
        assertEquals(1, mac.presenceOpens);
        assertEquals("admitted", mac.passes.get(mac.presencePasses.get(0)));
        assertEquals("watching", snapshot.pointerStatus);

        long mark = loop.posted();
        mac.pointerPushes.put(List.of(new Pointer(2, "Director", "red", 0.25, 0.75, 3000)));
        loop.awaitPostedAfter(mark);
        run(10);
        assertEquals(1, snapshot.pointers.size());
        assertEquals(0.25, snapshot.pointers.get(0).x, 1e-9);
        run(3500);
        assertTrue("a pointer fades after its reported time", snapshot.pointers.isEmpty());

        mark = loop.posted();
        mac.pointerPushes.put(List.of(new Pointer(2, "Director", "red", 0.5, 0.5, 4000)));
        loop.awaitPostedAfter(mark);
        run(10);
        assertEquals(1, snapshot.pointers.size());
        extras.setPointersWanted(false);
        assertTrue("turning pointers off clears them at once", snapshot.pointers.isEmpty());
        assertTrue("and closes the channel", mac.presenceScopes.get(0).isCancelled());
        run(30_000);
        assertEquals(1, mac.presenceOpens);
    }

    @Test public void pointerRevisionsStayWithTheirPictureAndReuseTheTranscript() throws Exception {
        mac.say("Director", "Hello");
        extras.setPointersWanted(true);
        admit();
        List<ChatLine> transcript = snapshot.chat;
        List<Pointer> items = List.of(new Pointer(2, "Director", "red", 0.25, 0.75, 3000));

        long mark = loop.posted();
        mac.pointerRevisionOverride = mac.revision + 1;
        mac.pointerPushes.put(items);
        // A mismatched event posts to the loop but cannot alter the snapshot.
        loop.awaitPostedAfter(mark);
        run(10);
        assertTrue(snapshot.pointers.isEmpty());

        mark = loop.posted();
        mac.pointerRevisionOverride = mac.revision;
        mac.pointerPushes.put(items);
        loop.awaitPostedAfter(mark);
        run(10);
        assertEquals(1, snapshot.pointers.size());
        assertSame(transcript, snapshot.chat);

        mac.state = "holding";
        run(1600);
        assertTrue(snapshot.pointers.isEmpty());
        assertTrue(mac.presenceScopes.get(0).isCancelled());
        assertSame(transcript, snapshot.chat);
    }

    @Test public void refusalClosesThePointerChannel() throws Exception {
        extras.setPointersWanted(true);
        admit();
        assertEquals(1, mac.presenceOpens);
        mac.removeAdmitted();
        run(4000);
        assertEquals(ReceiverController.Phase.REMOVED, view.phase);
        assertTrue(mac.presenceScopes.get(0).isCancelled());
        assertTrue(snapshot.pointers.isEmpty());
        run(60_000);
        assertEquals("never reopened after removal", 1, mac.presenceOpens);
    }

    @Test public void pointersNotOfferedRetryAtMostEvery30Seconds() {
        mac.pointersOffered = false;
        extras.setPointersWanted(true);
        admit();
        assertEquals(1, mac.presenceOpens);
        assertEquals("not offered by the Mac", snapshot.pointerStatus);
        run(25_000);
        assertEquals(1, mac.presenceOpens);
        mac.pointersOffered = true;
        run(10_000);
        assertEquals(2, mac.presenceOpens);
        assertEquals("watching", snapshot.pointerStatus);
    }

    @Test public void stopSharingDropsChatAtOnce() {
        mac.say("Director", "Wrapping");
        admit();
        assertEquals(1, snapshot.chat.size());
        mac.state = "stopped";
        run(2000);
        assertEquals(ReceiverController.Phase.ENDED, view.phase);
        assertFalse("an ended share's chat is not kept on screen", snapshot.bound);
        assertTrue(snapshot.chat.isEmpty());
    }

    @Test public void holdKeepsChatButMediaStops() {
        mac.say("Director", "Hold coming");
        admit();
        mac.state = "holding";
        run(3000);
        assertEquals(ReceiverController.Phase.HOLDING, view.phase);
        assertEquals(0, player.playing);
        assertTrue("chat is not media; it stays during Hold", snapshot.bound);
        assertEquals(1, snapshot.chat.size());
    }
}
