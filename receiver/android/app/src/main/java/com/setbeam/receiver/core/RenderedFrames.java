package com.setbeam.receiver.core;

/** Attributes a successful buffer swap to the generation and surface that submitted the frame. */
public final class RenderedFrames {
    private int generation;
    private long cutoffNs, lastNs, count;
    private boolean surface;

    public synchronized void authorize(int value, long nowNs) {
        generation = value;
        reset(nowNs);
    }

    public synchronized void surface(boolean available, long nowNs) {
        surface = available;
        reset(nowNs);
    }

    private void reset(long nowNs) {
        cutoffNs = nowNs;
        lastNs = 0;
        count = 0;
    }

    public synchronized void swapped(long submittedNs, long nowNs) {
        if (!surface || generation == 0 || submittedNs <= cutoffNs || submittedNs <= lastNs
                || submittedNs > nowNs || nowNs - submittedNs >= ReceiverController.FRESH_FRAME_MS * 1_000_000L) return;
        lastNs = submittedNs;
        count++;
    }

    public synchronized long lastFrameAt(int value) { return value == generation ? lastNs / 1_000_000L : 0; }
    public synchronized long count(int value) { return value == generation ? count : 0; }
}
