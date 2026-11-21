package com.setbeam.receiver;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.AttributeSet;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import org.webrtc.EglBase;
import org.webrtc.EglRenderer;
import org.webrtc.GlRectDrawer;
import org.webrtc.VideoFrame;

import com.setbeam.receiver.core.RenderGate;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Draws decoded WebRTC frames into a SurfaceView whose buffer is fixed to the decoded picture's
 * own pixel size, independent of the UI's (often 1920x1080) window size. WebRTC's
 * SurfaceViewRenderer limits its buffer to the view size, so a 3840x2160 frame would be drawn at
 * UI resolution and scaled back up; here the GL viewport is the full decoded size and the display
 * compositor scales the buffer into the view's aspect-fit rectangle.
 *
 * <p>The requested buffer size and the size the platform confirms in {@code surfaceChanged} are
 * reported separately; only the latter is what the GL renderer actually draws into.
 *
 * <p>Only one peer generation may draw ({@link RenderGate}). {@link #authorize} (a new peer, or 0
 * at stop) pauses the renderer and queues a clear under the same lock that admits frames, so a
 * replaced peer's frames are refused and any frame of it still waiting to be drawn is dropped by
 * the paused renderer. One bounded exception follows from the pinned EglRenderer: its render
 * thread takes a frame and checks for pause in separate steps, so a frame it already took can be
 * drawn if the thread stalls until the next generation resumes drawing. That frame is followed
 * by the clear queued behind it, and the activity's opaque cover hides the picture in every phase
 * except Live and Reconnecting. Rendering resumes only when the authorized generation's own
 * first frame arrives, after that frame has replaced anything pending.
 */
public final class PictureView extends SurfaceView implements SurfaceHolder.Callback {
    public interface Listener { void onDecodedSize(int width, int height); }

    private final EglRenderer renderer = new EglRenderer("setbeam-picture");
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicLong rendered = new AtomicLong();
    private volatile int decodedWidth, decodedHeight;
    private volatile int requestedWidth, requestedHeight;
    private volatile int bufferWidth, bufferHeight;
    private volatile boolean initialized;
    private Listener listener;
    private final RenderGate<VideoFrame> gate = new RenderGate<>(new RenderGate.Renderer<VideoFrame>() {
        @Override public void pause() {
            // Runs under the gate's lock, so no frame of a deauthorized generation can write its size back.
            decodedWidth = 0; decodedHeight = 0;
            if (initialized) renderer.pauseVideo();
        }
        @Override public void clear() { if (initialized) renderer.clearImage(); }
        @Override public void submit(VideoFrame frame) {
            int width = frame.getRotatedWidth(), height = frame.getRotatedHeight();
            if (width != decodedWidth || height != decodedHeight) {
                decodedWidth = width; decodedHeight = height;
                main.post(() -> requestBuffer(width, height));
            }
            renderer.onFrame(frame);
        }
        @Override public void resume() { renderer.disableFpsReduction(); }
    });

    public PictureView(Context context) { super(context); }
    public PictureView(Context context, AttributeSet attrs) { super(context, attrs); }

    public void init(EglBase.Context egl, Listener listener) {
        this.listener = listener;
        renderer.init(egl, EglBase.CONFIG_PLAIN, new GlRectDrawer());
        renderer.pauseVideo();
        renderer.addRenderListener(timestampNs -> rendered.incrementAndGet());
        getHolder().addCallback(this);
        initialized = true;
    }

    /**
     * Any thread. Makes {@code generation} the only one allowed to draw (0 for none), pausing the
     * renderer and clearing the picture at once. Frames of other generations are refused.
     */
    public void authorize(int generation) {
        gate.authorize(generation);
    }

    /** Decoder thread. Draws a frame only for the authorized generation; returns whether it was accepted. */
    public boolean render(int generation, VideoFrame frame) {
        return initialized && gate.offer(generation, frame);
    }

    /** Main thread: fixes the surface buffer to the decoded size. */
    private void requestBuffer(int width, int height) {
        if (width <= 0 || height <= 0) return;
        if (width != requestedWidth || height != requestedHeight) {
            requestedWidth = width; requestedHeight = height;
            getHolder().setFixedSize(width, height);
        }
        if (listener != null) listener.onDecodedSize(width, height);
    }

    public void release() {
        authorize(0);
        initialized = false;
        getHolder().removeCallback(this);
        renderer.release();
    }

    @Override public void surfaceCreated(SurfaceHolder holder) { renderer.createEglSurface(holder.getSurface()); }

    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        bufferWidth = width; bufferHeight = height;
    }

    @Override public void surfaceDestroyed(SurfaceHolder holder) {
        bufferWidth = 0; bufferHeight = 0;
        CountDownLatch released = new CountDownLatch(1);
        renderer.releaseEglSurface(released::countDown);
        try { released.await(2, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    int decodedWidth() { return decodedWidth; }
    int decodedHeight() { return decodedHeight; }
    int requestedWidth() { return requestedWidth; }
    int requestedHeight() { return requestedHeight; }
    /** The buffer size the platform confirmed in surfaceChanged, or 0 before it has. */
    int bufferWidth() { return bufferWidth; }
    int bufferHeight() { return bufferHeight; }
    long renderedFrames() { return rendered.get(); }
    static long now() { return SystemClock.elapsedRealtime(); }
}
