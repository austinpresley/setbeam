package com.setbeam.receiver.core;

/**
 * Admits frames for exactly one peer generation and keeps a replaced peer's frames off screen.
 *
 * <p>{@link #authorize} pauses and clears the renderer under the same lock that admits frames, so
 * once it returns no frame of another generation is handed over, and the renderer's per-generation
 * state (reset in its pause callback) cannot be written back by one. A renderer such as WebRTC's
 * EglRenderer drops frames while paused and replaces any pending frame when a new one is handed
 * over, so a replaced peer's frame that is still waiting is dropped. Rendering resumes only after
 * the authorized generation's own first frame has been handed over.
 *
 * <p>Limit: the pinned EglRenderer takes a frame and checks for pause in separate steps on its
 * render thread. A frame it has already taken can still be drawn if that thread stalls until the
 * next generation resumes drawing: at most one such frame, always followed by the clear queued
 * behind it. The public API offers no draw-time check to close this, so the UI also covers the
 * picture opaquely in every phase that must not show it.
 */
public final class RenderGate<F> {
    /** The renderer's thread-safe controls. */
    public interface Renderer<F> {
        /** Stop drawing; frames handed over while paused are dropped. */
        void pause();
        /** Blank the output ahead of any queued drawing. */
        void clear();
        /** Hand a frame over, replacing any frame not yet drawn. */
        void submit(F frame);
        void resume();
    }

    private final Renderer<F> renderer;
    private int authorized, resumed;

    public RenderGate(Renderer<F> renderer) { this.renderer = renderer; }

    /** Makes {@code generation} the only one that may draw (0: none), pausing and clearing at once. */
    public synchronized void authorize(int generation) {
        authorized = generation;
        resumed = 0;
        renderer.pause();
        renderer.clear();
    }

    /** Returns whether the frame was handed to the renderer. */
    public synchronized boolean offer(int generation, F frame) {
        if (generation == 0 || generation != authorized) return false;
        renderer.submit(frame);
        if (resumed != generation) {
            resumed = generation;
            renderer.resume();
        }
        return true;
    }

    public synchronized int authorized() { return authorized; }
}
