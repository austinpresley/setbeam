package com.setbeam.receiver.core;

import org.junit.Test;

import static org.junit.Assert.assertEquals;

public class RenderedFramesTest {
    private static long ns(long ms) { return ms * 1_000_000L; }

    @Test public void onlyFreshSwapsOnTheAuthorizedSurfaceCount() {
        RenderedFrames frames = new RenderedFrames();
        frames.authorize(1, ns(10));
        frames.swapped(ns(11), ns(12));
        assertEquals(0, frames.lastFrameAt(1));
        frames.surface(true, ns(20));
        frames.swapped(ns(11), ns(21));
        assertEquals(0, frames.count(1));
        frames.swapped(ns(23), ns(24));
        assertEquals(23, frames.lastFrameAt(1));
        assertEquals(1, frames.count(1));

        frames.authorize(2, ns(30));
        frames.swapped(ns(29), ns(31));
        frames.swapped(ns(32), ns(32 + ReceiverController.FRESH_FRAME_MS));
        assertEquals(0, frames.count(2));
        assertEquals(0, frames.lastFrameAt(1));
        frames.swapped(ns(2400), ns(2402));
        assertEquals(2400, frames.lastFrameAt(2));

        frames.surface(false, ns(2410));
        assertEquals(0, frames.lastFrameAt(2));
        frames.surface(true, ns(2420));
        frames.swapped(ns(2411), ns(2421));
        assertEquals(0, frames.lastFrameAt(2));
    }
}
