package com.setbeam.receiver;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.os.Build;
import android.os.SystemClock;
import android.util.Base64;
import android.util.Log;

import com.setbeam.receiver.core.Gateway;
import com.setbeam.receiver.core.MiniHttp;
import com.setbeam.receiver.core.ReceiverController;
import com.setbeam.receiver.core.WhepTarget;

import org.webrtc.AudioTrack;
import org.webrtc.DataChannel;
import org.webrtc.EglBase;
import org.webrtc.HardwareVideoDecoderFactory;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.MediaStreamTrack;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.PlatformSoftwareVideoDecoderFactory;
import org.webrtc.RTCStats;
import org.webrtc.RtpReceiver;
import org.webrtc.RtpTransceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.SoftwareVideoDecoderFactory;
import org.webrtc.SoftwareVideoEncoderFactory;
import org.webrtc.VideoCodecInfo;
import org.webrtc.VideoDecoder;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.VideoDecoderFallback;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

/**
 * Native WebRTC WHEP playback of the Mac's audience output: one receive-only peer at a time,
 * MediaCodec decoding into a GL texture, drawn by {@link PictureView} at the decoded size, and
 * stereo Opus.
 *
 * <p>Each {@link #play} creates an immutable {@link Peer} for that generation. Its video sink,
 * audio track, frame clock, WHEP target and credentials belong to it alone. A peer is deactivated
 * on the caller's thread before anything else happens, so a replaced or stopped peer's frames are
 * never shown or counted and its sound never plays: the shared audio output is muted at once and
 * unmuted only on the RTC thread after every earlier peer has been closed, and only for the peer
 * that is still current. Closing a peer drops its target, authorization, session URL and tracks.
 */
final class WebRtcPlayer implements ReceiverController.Player {
    private static final String TAG = "SetbeamPlayer";

    interface Failure { void failed(int generation, String why); }

    private final ExecutorService rtc = Executors.newSingleThreadExecutor(r -> new Thread(r, "setbeam-rtc"));
    private final EglBase egl;
    private final JavaAudioDeviceModule audio;
    private final ObservedDecoderFactory decoders;
    private final PeerConnectionFactory factory;
    private final Failure failure;

    /** The only peer whose media may be shown or heard. Changed only under {@link #authority}. */
    private volatile Peer current;
    /** Serializes changes of {@link #current} with the decision to unmute. */
    private final Object authority = new Object();
    private volatile PictureView view;
    /** The TV user's Sound choice. Changed only under {@link #authority}. */
    private volatile boolean soundOn = true;

    /** One generation's connection. Fields other than the volatile ones are confined to the RTC thread. */
    private final class Peer {
        final int generation;
        volatile boolean active = true;
        final AtomicLong lastFrameAt = new AtomicLong();
        final AtomicLong frames = new AtomicLong();
        volatile MiniHttp.Call offerCall;
        volatile boolean hasAudio;
        /** Reached the point where its sound may play: every earlier peer is closed. */
        volatile boolean audible;
        volatile String connection = "new";
        PeerConnection pc;
        WhepTarget target;
        String authorization;
        String sessionPath;
        VideoTrack videoTrack;
        AudioTrack audioTrack;

        final VideoSink sink = new VideoSink() {
            @Override public void onFrame(VideoFrame frame) {
                PictureView target = view;
                if (!active || target == null) return;
                // The picture's own generation gate decides; only drawn-for frames count as fresh.
                if (!target.render(generation, frame)) return;
                lastFrameAt.set(SystemClock.elapsedRealtime());
                frames.incrementAndGet();
            }
        };

        Peer(int generation) { this.generation = generation; }

        boolean live() { return active && current == this; }

        void deactivate() {
            active = false;
            MiniHttp.Call call = offerCall;
            if (call != null) call.cancel();
        }
    }

    WebRtcPlayer(Context context, Failure failure) {
        this.failure = failure;
        Context app = context.getApplicationContext();
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(app).createInitializationOptions());
        egl = EglBase.create();
        decoders = new ObservedDecoderFactory(egl.getEglBaseContext());
        audio = JavaAudioDeviceModule.builder(app)
                .setUseStereoOutput(true)
                .setUseHardwareAcousticEchoCanceler(false)
                .setUseHardwareNoiseSuppressor(false)
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .createAudioDeviceModule();
        audio.setSpeakerMute(true);
        factory = PeerConnectionFactory.builder()
                .setAudioDeviceModule(audio)
                .setVideoDecoderFactory(decoders)
                .setVideoEncoderFactory(new SoftwareVideoEncoderFactory())
                .createPeerConnectionFactory();
    }

    EglBase.Context eglContext() { return egl.getEglBaseContext(); }

    /**
     * The TV user's Sound choice. Off mutes at once. On unmutes only a current peer that already
     * passed the point where its sound may play, decided under the same lock as play() and stop().
     */
    void setSound(boolean on) {
        synchronized (authority) {
            soundOn = on;
            Peer peer = current;
            audio.setSpeakerMute(!(on && peer != null && peer.live() && peer.audible));
        }
    }

    boolean soundOn() { return soundOn; }

    void attach(PictureView picture) { view = picture; }

    void detach(PictureView picture) { if (view == picture) view = null; }

    @Override public long lastFrameAt(int generation) {
        Peer peer = current;
        return peer != null && peer.active && peer.generation == generation ? peer.lastFrameAt.get() : 0;
    }

    @Override public void play(int generation, Gateway.Playback playback) {
        Peer previous, next = new Peer(generation);
        synchronized (authority) {
            previous = current;
            if (previous != null) previous.deactivate();
            current = next;
            audio.setSpeakerMute(true);
        }
        // Only this generation may draw from now on; the old picture is paused and cleared at once.
        PictureView picture = view;
        if (picture != null) picture.authorize(generation);
        if (!rtc.isShutdown()) rtc.execute(() -> { close(previous); open(next, playback); });
    }

    @Override public void stop() {
        Peer previous;
        synchronized (authority) {
            previous = current;
            current = null;
            if (previous != null) previous.deactivate();
            audio.setSpeakerMute(true);
        }
        PictureView picture = view;
        if (picture != null) picture.authorize(0);
        if (!rtc.isShutdown()) rtc.execute(() -> close(previous));
    }

    /** Releases everything. The player cannot be used afterwards. */
    void release() {
        stop();
        view = null;
        rtc.execute(() -> {
            factory.dispose();
            audio.release();
            egl.release();
        });
        rtc.shutdown();
    }

    // ---- RTC thread ----

    private void open(Peer peer, Gateway.Playback playback) {
        if (!peer.live()) return;
        peer.target = playback.target;
        peer.authorization = "Basic " + Base64.encodeToString((playback.user + ":" + playback.password).getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
        PeerConnection.RTCConfiguration config = new PeerConnection.RTCConfiguration(new ArrayList<>());
        config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
        config.bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE;
        config.rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE;
        config.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE;
        config.tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.ENABLED;
        CountDownLatch gathered = new CountDownLatch(1);
        PeerConnection pc = factory.createPeerConnection(config, new Observer(peer, gathered));
        if (pc == null) { fail(peer, "Could not create a media connection"); return; }
        peer.pc = pc;
        RtpTransceiver video = pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
                new RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY));
        RtpTransceiver sound = pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO,
                new RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY));
        MediaStreamTrack track = video.getReceiver().track();
        if (track instanceof VideoTrack) { peer.videoTrack = (VideoTrack) track; peer.videoTrack.addSink(peer.sink); }
        MediaStreamTrack heard = sound.getReceiver().track();
        if (heard instanceof AudioTrack) { peer.audioTrack = (AudioTrack) heard; peer.audioTrack.setEnabled(true); }

        SessionDescription offer = awaitSdp(observer -> pc.createOffer(observer, new MediaConstraints()));
        if (offer == null || !peer.live()) { fail(peer, "Could not prepare the media request"); return; }
        if (!awaitSet(observer -> pc.setLocalDescription(observer, offer)) || !peer.live()) { fail(peer, "Could not prepare the media request"); return; }
        try { gathered.await(3, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); return; }
        if (!peer.live() || pc.getLocalDescription() == null) return;

        String answer;
        MiniHttp.Call call = new MiniHttp.Call();
        peer.offerCall = call;
        try {
            if (!peer.live()) return;
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("Authorization", peer.authorization);
            headers.put("Content-Type", "application/sdp");
            headers.put("Accept", "application/sdp");
            MiniHttp.Response response = MiniHttp.execute(peer.target.route, "POST", peer.target.path, headers,
                    pc.getLocalDescription().description.getBytes(StandardCharsets.UTF_8), 5000, 64 * 1024, call);
            if (response.status == 401 || response.status == 403) { fail(peer, "The Mac refused media access"); return; }
            if (response.status == 404) { fail(peer, "The Mac's media output is not available"); return; }
            if (response.status != 201) { fail(peer, "Media request failed (" + response.status + ")"); return; }
            peer.sessionPath = peer.target.sessionPath(response.header("location"));
            answer = response.text();
        } catch (IOException e) {
            fail(peer, "Media request failed");
            return;
        } finally {
            peer.offerCall = null;
        }
        if (!peer.live()) return;
        if (!answer.startsWith("v=0")) { fail(peer, "Unexpected media answer"); return; }
        if (!awaitSet(observer -> pc.setRemoteDescription(observer, new SessionDescription(SessionDescription.Type.ANSWER, answer)))) {
            fail(peer, "The media answer was not accepted");
            return;
        }
        // Every earlier peer is closed (this thread closes before it opens), so sound may resume,
        // and only if this peer is still the current one. Decided under the same lock that
        // play() and stop() use, so a stop cannot land between the check and the unmute.
        synchronized (authority) {
            if (peer.live()) {
                peer.audible = true;
                if (soundOn) audio.setSpeakerMute(false);
            }
        }
    }

    private void fail(Peer peer, String why) {
        if (!peer.live()) return;
        Log.w(TAG, "Playback " + peer.generation + ": " + why);
        failure.failed(peer.generation, why);
    }

    /** Closes a peer and drops everything it held, including its media credentials. */
    private void close(Peer peer) {
        if (peer == null) return;
        peer.deactivate();
        PeerConnection pc = peer.pc;
        String path = peer.sessionPath, auth = peer.authorization;
        WhepTarget where = peer.target;
        if (peer.audioTrack != null) { peer.audioTrack.setEnabled(false); peer.audioTrack = null; }
        if (peer.videoTrack != null) { peer.videoTrack.removeSink(peer.sink); peer.videoTrack = null; }
        peer.pc = null; peer.sessionPath = null; peer.authorization = null; peer.target = null;
        peer.hasAudio = false; peer.connection = "closed";
        if (pc == null) return;
        pc.close();
        pc.dispose();
        if (path != null && where != null && auth != null) {
            // Ends the WHEP session on the Mac promptly; failure only means it times out there.
            try { MiniHttp.execute(where.route, "DELETE", path, Map.of("Authorization", auth), null, 2000, 4096, new MiniHttp.Call()); }
            catch (IOException ignored) { }
        }
    }

    private interface SdpCall { void run(SdpObserver observer); }

    private static SessionDescription awaitSdp(SdpCall call) {
        final SessionDescription[] result = new SessionDescription[1];
        CountDownLatch done = new CountDownLatch(1);
        call.run(new SdpObserver() {
            @Override public void onCreateSuccess(SessionDescription description) { result[0] = description; done.countDown(); }
            @Override public void onSetSuccess() { done.countDown(); }
            @Override public void onCreateFailure(String error) { done.countDown(); }
            @Override public void onSetFailure(String error) { done.countDown(); }
        });
        try { if (!done.await(5, TimeUnit.SECONDS)) return null; } catch (InterruptedException e) { Thread.currentThread().interrupt(); return null; }
        return result[0];
    }

    private static boolean awaitSet(SdpCall call) {
        final boolean[] ok = new boolean[1];
        CountDownLatch done = new CountDownLatch(1);
        call.run(new SdpObserver() {
            @Override public void onCreateSuccess(SessionDescription description) { done.countDown(); }
            @Override public void onSetSuccess() { ok[0] = true; done.countDown(); }
            @Override public void onCreateFailure(String error) { done.countDown(); }
            @Override public void onSetFailure(String error) { Log.w(TAG, "SDP: " + error); done.countDown(); }
        });
        try { if (!done.await(5, TimeUnit.SECONDS)) return false; } catch (InterruptedException e) { Thread.currentThread().interrupt(); return false; }
        return ok[0];
    }

    private final class Observer implements PeerConnection.Observer {
        private final Peer peer; private final CountDownLatch gathered;
        Observer(Peer peer, CountDownLatch gathered) { this.peer = peer; this.gathered = gathered; }
        @Override public void onSignalingChange(PeerConnection.SignalingState state) { }
        @Override public void onIceConnectionChange(PeerConnection.IceConnectionState state) {
            if (state == PeerConnection.IceConnectionState.FAILED) fail(peer, "The media connection failed");
        }
        @Override public void onConnectionChange(PeerConnection.PeerConnectionState state) {
            peer.connection = state.name().toLowerCase(Locale.ROOT);
            if (state == PeerConnection.PeerConnectionState.FAILED || state == PeerConnection.PeerConnectionState.CLOSED) {
                fail(peer, "The media connection closed");
            }
        }
        @Override public void onIceConnectionReceivingChange(boolean receiving) { }
        @Override public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
            if (state == PeerConnection.IceGatheringState.COMPLETE) gathered.countDown();
        }
        @Override public void onIceCandidate(IceCandidate candidate) { }
        @Override public void onIceCandidatesRemoved(IceCandidate[] candidates) { }
        @Override public void onAddStream(MediaStream stream) { }
        @Override public void onRemoveStream(MediaStream stream) { }
        @Override public void onDataChannel(DataChannel channel) { }
        @Override public void onRenegotiationNeeded() { }
        @Override public void onAddTrack(RtpReceiver receiver, MediaStream[] streams) {
            if (receiver.track() != null && MediaStreamTrack.AUDIO_TRACK_KIND.equals(receiver.track().kind())) peer.hasAudio = true;
        }
    }

    // ---- Diagnostics ----

    /** Observed playback facts. Nothing here is a credential. */
    static final class Snapshot {
        int decodedWidth, decodedHeight, requestedWidth, requestedHeight, bufferWidth, bufferHeight;
        double sinkFps, renderedFps;
        long framesShown;
        Map<String, Object> video = Map.of();
        Map<String, Object> audio = Map.of();
        String codec = "";
        String candidatePair = "";
        String connection = "";
        boolean hasAudio;
        String createdDecoder = "";
        String decoderKind = "";
    }

    private long fpsAtMs, fpsFrames, fpsRendered;
    private int fpsGeneration;
    private double sinkFps, renderedFps;

    /** Collects a snapshot and delivers it on an arbitrary thread. */
    void collect(Consumer<Snapshot> done) {
        Peer peer = current;
        PictureView picture = view;
        long now = SystemClock.elapsedRealtime();
        long frames = peer == null ? 0 : peer.frames.get();
        long rendered = picture == null ? 0 : picture.renderedFrames();
        int generation = peer == null ? 0 : peer.generation;
        synchronized (this) {
            if (fpsAtMs > 0 && now > fpsAtMs && generation == fpsGeneration) {
                sinkFps = (frames - fpsFrames) * 1000.0 / (now - fpsAtMs);
                renderedFps = (rendered - fpsRendered) * 1000.0 / (now - fpsAtMs);
            } else { sinkFps = 0; renderedFps = 0; }
            fpsAtMs = now; fpsFrames = frames; fpsRendered = rendered; fpsGeneration = generation;
        }
        Snapshot snapshot = new Snapshot();
        boolean showing = peer != null && peer.active && now - peer.lastFrameAt.get() < 2000;
        if (picture != null) {
            snapshot.decodedWidth = showing ? picture.decodedWidth() : 0;
            snapshot.decodedHeight = showing ? picture.decodedHeight() : 0;
            snapshot.requestedWidth = picture.requestedWidth(); snapshot.requestedHeight = picture.requestedHeight();
            snapshot.bufferWidth = picture.bufferWidth(); snapshot.bufferHeight = picture.bufferHeight();
        }
        snapshot.sinkFps = showing ? sinkFps : 0;
        snapshot.renderedFps = showing ? renderedFps : 0;
        snapshot.framesShown = frames;
        snapshot.hasAudio = peer != null && peer.hasAudio;
        snapshot.connection = peer == null ? "none" : peer.connection;
        snapshot.createdDecoder = decoders.created;
        snapshot.decoderKind = decoders.kind;
        if (rtc.isShutdown()) { done.accept(snapshot); return; }
        rtc.execute(() -> {
            PeerConnection pc = peer != null && peer.live() ? peer.pc : null;
            if (pc == null) { done.accept(snapshot); return; }
            pc.getStats(report -> {
                Map<String, RTCStats> stats = report.getStatsMap();
                String codecId = null, pairId = null;
                for (RTCStats s : stats.values()) {
                    Map<String, Object> m = s.getMembers();
                    if ("inbound-rtp".equals(s.getType()) && "video".equals(m.get("kind"))) { snapshot.video = m; codecId = (String) m.get("codecId"); }
                    else if ("inbound-rtp".equals(s.getType()) && "audio".equals(m.get("kind"))) snapshot.audio = m;
                    else if ("transport".equals(s.getType())) pairId = (String) m.get("selectedCandidatePairId");
                }
                RTCStats codec = codecId == null ? null : stats.get(codecId);
                if (codec != null) snapshot.codec = codec.getMembers().get("mimeType") + " " + codec.getMembers().getOrDefault("sdpFmtpLine", "");
                RTCStats pair = pairId == null ? null : stats.get(pairId);
                if (pair != null) {
                    RTCStats local = stats.get((String) pair.getMembers().get("localCandidateId"));
                    RTCStats remote = stats.get((String) pair.getMembers().get("remoteCandidateId"));
                    if (local != null && remote != null) {
                        snapshot.candidatePair = local.getMembers().get("protocol") + " " + local.getMembers().get("candidateType")
                                + " → " + remote.getMembers().get("address") + ":" + remote.getMembers().get("port");
                    }
                }
                done.accept(snapshot);
            });
        });
    }

    /** Decoder selection as WebRTC's default factory does it, recording what was actually created. */
    static final class ObservedDecoderFactory implements VideoDecoderFactory {
        private final VideoDecoderFactory hardware;
        private final VideoDecoderFactory platformSoftware;
        private final VideoDecoderFactory software = new SoftwareVideoDecoderFactory();
        volatile String created = "";
        volatile String kind = "";

        ObservedDecoderFactory(EglBase.Context context) {
            hardware = new HardwareVideoDecoderFactory(context);
            platformSoftware = new PlatformSoftwareVideoDecoderFactory(context);
        }

        @Override public VideoDecoder createDecoder(VideoCodecInfo info) {
            VideoDecoder fallback = software.createDecoder(info);
            VideoDecoder primary = hardware.createDecoder(info);
            if (primary == null) primary = platformSoftware.createDecoder(info);
            String name = primary != null ? primary.getImplementationName() : fallback != null ? "libwebrtc software" : "none";
            created = info.name + ": " + name;
            kind = classify(name);
            Log.i(TAG, "Decoder for " + info.name + ": " + name + " (" + kind + ")");
            if (primary != null && fallback != null) return new VideoDecoderFallback(fallback, primary);
            return primary != null ? primary : fallback;
        }

        @Override public VideoCodecInfo[] getSupportedCodecs() {
            LinkedHashSet<VideoCodecInfo> codecs = new LinkedHashSet<>();
            codecs.addAll(Arrays.asList(software.getSupportedCodecs()));
            codecs.addAll(Arrays.asList(hardware.getSupportedCodecs()));
            codecs.addAll(Arrays.asList(platformSoftware.getSupportedCodecs()));
            return codecs.toArray(new VideoCodecInfo[0]);
        }

        /** Reports what the platform says about this MediaCodec decoder, without guessing hardware support. */
        static String classify(String codecName) {
            if (codecName == null || codecName.isEmpty()) return "unknown";
            try {
                for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
                    if (info.isEncoder() || !info.getName().equals(codecName)) continue;
                    if (Build.VERSION.SDK_INT >= 29) {
                        if (info.isHardwareAccelerated()) return "hardware (MediaCodec)";
                        if (info.isSoftwareOnly()) return "software (MediaCodec)";
                        return "MediaCodec";
                    }
                    String lower = codecName.toLowerCase(Locale.ROOT);
                    return lower.startsWith("omx.google.") || lower.startsWith("c2.android.") ? "software (MediaCodec)" : "MediaCodec, vendor";
                }
            } catch (RuntimeException ignored) { }
            return "libwebrtc";
        }
    }
}
