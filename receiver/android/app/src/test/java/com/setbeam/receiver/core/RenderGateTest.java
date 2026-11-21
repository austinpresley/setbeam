package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;

import org.junit.Test;

/**
 * RenderGate against a model of the pinned org.webrtc.EglRenderer (144.7559.15, read from its
 * bytecode). onFrame replaces and releases any pending frame and posts a draw. clearImage posts to
 * the front of the single render thread's queue. A draw takes the pending frame under frameLock,
 * releases that lock, and only later reads the pause state (minRenderPeriodNs == Long.MAX_VALUE
 * drops the frame); disableFpsReduction resumes drawing. The render thread can fall behind, and
 * can stall between taking a frame and checking for pause.
 */
public class RenderGateTest {
    static final String CLEAR = "<clear>";

    static final class ModelRenderer implements RenderGate.Renderer<String> {
        boolean paused = true;
        String pending;
        /** A frame the render thread has taken but not yet checked against pause. */
        String taken;
        /** Per-generation state the real renderer's pause callback resets (PictureView's decoded size). */
        String sizeSincePause;
        final Deque<Runnable> renderQueue = new ArrayDeque<>();
        final List<String> drawn = new ArrayList<>();
        @Override public synchronized void pause() { paused = true; sizeSincePause = null; }
        @Override public synchronized void clear() { renderQueue.addFirst(() -> drawn.add(CLEAR)); }
        @Override public synchronized void submit(String frame) { pending = frame; sizeSincePause = frame; renderQueue.addLast(this::draw); }
        /** When set, the render thread catches up the instant drawing resumes (a worst-case schedule). */
        boolean drainOnResume;
        @Override public synchronized void resume() { paused = false; if (drainOnResume) drain(); }
        private void draw() { take(); check(); }
        private void take() { taken = pending; pending = null; }
        private void check() {
            String frame = taken; taken = null;
            if (frame == null || paused) return;
            drawn.add(frame);
        }
        /** Runs the render thread's backlog. */
        synchronized List<String> drain() { while (!renderQueue.isEmpty()) renderQueue.pollFirst().run(); return drawn; }
        /** The render thread starts the next queued draw, takes its frame, and stalls before the pause check. */
        synchronized void takeAndStall() {
            assertFalse(renderQueue.isEmpty());
            renderQueue.pollFirst();
            take();
        }
        /** The stalled render thread continues: pause check, then the rest of its queue. */
        synchronized List<String> continueAfterStall() { check(); return drain(); }
    }

    static List<String> afterLastClear(List<String> drawn) {
        int i = drawn.lastIndexOf(CLEAR);
        return drawn.subList(i + 1, drawn.size());
    }

    @Test public void stoppedPeersPendingFrameIsNeverDrawnAfterTheClear() {
        ModelRenderer renderer = new ModelRenderer();
        RenderGate<String> gate = new RenderGate<>(renderer);
        gate.authorize(1);
        assertTrue(gate.offer(1, "old-1"));
        renderer.drain();
        assertTrue(gate.offer(1, "old-2")); // handed over, render thread behind
        gate.authorize(0);                    // Hold, removal, decline, end
        List<String> drawn = renderer.drain();
        assertTrue("the clear happened", drawn.contains(CLEAR));
        assertEquals("nothing drawn after the clear", List.of(), afterLastClear(drawn));
        assertFalse("old-2 was never drawn", drawn.contains("old-2"));
        assertFalse("later frames of the stopped peer are refused", gate.offer(1, "old-3"));
        assertEquals(List.of(), afterLastClear(renderer.drain()));
    }

    @Test public void newPeerResumesOnlyWithItsOwnFrame() {
        ModelRenderer renderer = new ModelRenderer();
        RenderGate<String> gate = new RenderGate<>(renderer);
        gate.authorize(1);
        gate.offer(1, "a1");
        gate.authorize(2);
        assertFalse("the replaced peer's late frame is refused", gate.offer(1, "a2"));
        assertTrue(renderer.paused);
        assertEquals(List.of(), afterLastClear(renderer.drain()));
        assertTrue(gate.offer(2, "b1"));
        assertFalse(renderer.paused);
        assertTrue(gate.offer(2, "b2"));
        List<String> after = afterLastClear(renderer.drain());
        assertFalse(after.contains("a1"));
        assertFalse(after.contains("a2"));
        assertTrue(after.contains("b2"));
    }

    @Test public void generationZeroNeverDraws() {
        ModelRenderer renderer = new ModelRenderer();
        RenderGate<String> gate = new RenderGate<>(renderer);
        assertFalse(gate.offer(0, "x"));
        gate.authorize(0);
        assertFalse(gate.offer(0, "x"));
        assertTrue(renderer.paused);
        assertFalse(renderer.drain().contains("x"));
    }

    @Test public void concurrentDecoderCannotDrawAfterAuthorityCloses() throws Exception {
        for (int round = 0; round < 200; round++) {
            ModelRenderer renderer = new ModelRenderer();
            RenderGate<String> gate = new RenderGate<>(renderer);
            gate.authorize(7);
            Thread decoder = new Thread(() -> { for (int i = 0; i < 500; i++) gate.offer(7, "f" + i); });
            decoder.start();
            Thread.sleep(0, 50_000);
            gate.authorize(0);
            decoder.join();
            assertNull("round " + round + ": no refused frame wrote per-generation state after the pause", renderer.sizeSincePause);
            assertEquals("round " + round, List.of(), afterLastClear(renderer.drain()));
        }
    }

    @Test public void renderThreadCatchingUpAtResumeNeverDrawsTheOldPeer() {
        ModelRenderer renderer = new ModelRenderer();
        RenderGate<String> gate = new RenderGate<>(renderer);
        gate.authorize(1);
        gate.offer(1, "a1");
        renderer.drain();
        gate.offer(1, "a2");          // pending, render thread behind
        gate.authorize(2);            // new peer: pause and clear
        renderer.drainOnResume = true;
        assertTrue(gate.offer(2, "b1"));
        List<String> drawn = renderer.drain();
        assertFalse("the old peer's pending frame was never drawn", drawn.contains("a2"));
        assertEquals(List.of("b1"), afterLastClear(drawn));
    }

    @Test public void takenFrameIsDroppedWhenItsPauseCheckComesAfterTheStop() {
        ModelRenderer renderer = new ModelRenderer();
        RenderGate<String> gate = new RenderGate<>(renderer);
        gate.authorize(1);
        gate.offer(1, "a1");
        renderer.takeAndStall();       // render thread holds a1, has not checked pause yet
        gate.authorize(0);             // stop: pause and queue a clear
        List<String> drawn = renderer.continueAfterStall();
        assertFalse("checked while paused, so dropped", drawn.contains("a1"));
        assertEquals(CLEAR, drawn.get(drawn.size() - 1));
    }

    /**
     * The documented bound, not a guarantee the pinned API can give: if the render thread stalls
     * after taking an old frame until the next generation has resumed drawing, that one frame is
     * drawn, and the clear queued by the change is drawn right after it, before any new frame.
     */
    @Test public void alreadyTakenFrameIsAtMostOneAndIsFollowedByTheQueuedClear() {
        ModelRenderer renderer = new ModelRenderer();
        RenderGate<String> gate = new RenderGate<>(renderer);
        gate.authorize(1);
        gate.offer(1, "a1");
        renderer.takeAndStall();
        gate.authorize(0);
        assertFalse(gate.offer(1, "a2"));
        gate.authorize(2);
        assertTrue(gate.offer(2, "b1"));   // resumes drawing while the old frame is still held
        List<String> drawn = renderer.continueAfterStall();
        int old = 0;
        for (int i = 0; i < drawn.size(); i++) {
            if (!drawn.get(i).startsWith("a")) continue;
            old++;
            assertEquals("an old frame is always followed by the queued clear", CLEAR, drawn.get(i + 1));
        }
        assertTrue("at most the one frame already taken", old <= 1);
        assertFalse(drawn.contains("a2"));
        assertEquals(List.of("b1"), afterLastClear(drawn));
    }
}
