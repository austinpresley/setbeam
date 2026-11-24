package com.setbeam.receiver;

import android.app.Activity;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Display;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.graphics.Typeface;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.TextUtils;
import android.text.style.ForegroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.text.style.StyleSpan;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.setbeam.receiver.core.ChatLine;
import com.setbeam.receiver.core.HostConfig;
import com.setbeam.receiver.core.HttpGateway;
import com.setbeam.receiver.core.MiniHttp;
import com.setbeam.receiver.core.ReceiverController;
import com.setbeam.receiver.core.ReceiverController.Phase;
import com.setbeam.receiver.core.SessionExtras;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.List;

import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Full-screen receiver for a dedicated TV box. While it is in the foreground the screen stays on
 * in every state, so a later share is found and asked for without anyone touching the remote.
 * Leaving the foreground stops every request and closes media; returning resumes the same
 * per-share request without asking again. Pairing changes stop the controller before they are
 * written and restart it afterwards ({@link PairingChanges}).
 */
public final class MainActivity extends Activity implements PairingChanges.Receiver {
    private Settings settings;
    private Discovery discovery;
    private WebRtcPlayer player;
    private ReceiverController controller;
    private HandlerThread controlThread;
    private Handler control;
    private ExecutorService io;
    private final Handler main = new Handler(Looper.getMainLooper());
    private boolean started;

    private PictureView video;
    private AspectFitLayout frame;
    private View root, cover, dim, controls;
    private ViewGroup card;
    private ImageView cardIcon;
    private TextView cardTitle, cardMessage, cardDetail, sample, diagnostics;
    private android.widget.ScrollView diagnosticsPanel;
    private Button askAgain, openOptions, connectionInfo, macSettings, openChat, soundToggle, popupsToggle, pointersToggle;
    private PointerOverlay pointerView;
    private View chatPanel;
    private ScrollView chatScroll;
    private TextView chatText, chatStatus;
    private LinearLayout chatToasts;
    private SessionExtras extras;
    private SessionExtras.Snapshot lastExtras;
    private boolean chatOpen;
    /** New chat messages since the panel was last opened, while pop-ups are off. */
    private int unread;
    private boolean showDiagnostics;
    private long lastDiagnosticsAt;
    private ReceiverController.View lastView;
    private ConnectivityManager.NetworkCallback networkCallback;
    private int requestedModeId;
    private final Runnable dismissControls = this::hideControls;

    private final Runnable refreshDiagnostics = new Runnable() {
        @Override public void run() {
            if (showDiagnostics && player != null) player.collect(snapshot -> main.post(() -> renderDiagnostics(snapshot)));
            main.postDelayed(this, 1000);
        }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_main);
        // A dedicated receiver: awake in every state while in front, including searching and refused.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        MiniHttp.setHostnameCheck((host, session) -> javax.net.ssl.HttpsURLConnection.getDefaultHostnameVerifier().verify(host, session));
        settings = new Settings(this);
        frame = findViewById(R.id.video_frame);
        video = findViewById(R.id.video);
        root = findViewById(R.id.receiver_root);
        cardIcon = findViewById(R.id.card_icon);
        cover = findViewById(R.id.cover);
        dim = findViewById(R.id.dim);
        card = findViewById(R.id.card);
        controls = findViewById(R.id.controls);
        cardTitle = findViewById(R.id.card_title);
        cardMessage = findViewById(R.id.card_message);
        cardDetail = findViewById(R.id.card_detail);
        sample = findViewById(R.id.sample);
        diagnostics = findViewById(R.id.diagnostics);
        diagnosticsPanel = findViewById(R.id.diagnostics_panel);
        askAgain = findViewById(R.id.ask_again);
        openOptions = findViewById(R.id.open_options);
        connectionInfo = findViewById(R.id.connection_info);
        macSettings = findViewById(R.id.mac_settings);
        openChat = findViewById(R.id.open_chat);
        soundToggle = findViewById(R.id.sound_toggle);
        popupsToggle = findViewById(R.id.popups_toggle);
        pointersToggle = findViewById(R.id.pointers_toggle);
        pointerView = findViewById(R.id.pointers);
        chatPanel = findViewById(R.id.chat_panel);
        chatScroll = findViewById(R.id.chat_scroll);
        chatText = findViewById(R.id.chat_text);
        chatStatus = findViewById(R.id.chat_status);
        chatToasts = findViewById(R.id.chat_toasts);
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            controls.setAccessibilityPaneTitle(getText(R.string.receiver_options));
            diagnosticsPanel.setAccessibilityPaneTitle(getText(R.string.connection_info));
            chatPanel.setAccessibilityPaneTitle(getText(R.string.chat_button));
        }

        controlThread = new HandlerThread("setbeam-control");
        controlThread.start();
        control = new Handler(controlThread.getLooper());
        io = Executors.newFixedThreadPool(6, r -> new Thread(r, "setbeam-io"));

        player = new WebRtcPlayer(this, (generation, why) -> control.post(() -> controller.playerFailed(generation, why)));
        video.init(player.eglContext(), (width, height) -> {
            frame.setPicture(width, height);
            requestDisplayMode(width, height);
        });
        player.attach(video);

        discovery = new Discovery(this, settings, () -> control.post(() -> controller.nudge()));
        ReceiverController.Loop loop = new ReceiverController.Loop() {
            @Override public void post(Runnable task) { control.post(task); }
            @Override public void postDelayed(Runnable task, long delayMs) { control.postDelayed(task, delayMs); }
            @Override public long now() { return SystemClock.elapsedRealtime(); }
            @Override public long wallNow() { return System.currentTimeMillis(); }
        };
        HttpGateway gateway = new HttpGateway(discovery);
        controller = new ReceiverController(loop, io, gateway, settings.store(), player, view -> main.post(() -> render(view)));
        extras = new SessionExtras(loop, io, gateway, snapshot -> main.post(() -> renderExtras(snapshot)));
        controller.setExtras(extras);
        controller.setResolutionListener(resolution -> settings.pinMacId(resolution.macId));
        player.setSound(settings.sound());
        boolean pointersWanted = settings.pointers();
        control.post(() -> extras.setPointersWanted(pointersWanted));

        askAgain.setOnClickListener(v -> control.post(() -> controller.askAgain()));
        openOptions.setOnClickListener(v -> showControls());
        root.setAccessibilityDelegate(new View.AccessibilityDelegate() {
            @Override public void onInitializeAccessibilityNodeInfo(View view, android.view.accessibility.AccessibilityNodeInfo info) {
                super.onInitializeAccessibilityNodeInfo(view, info);
                if (view.isClickable()) info.setClassName(Button.class.getName());
            }
        });
        root.setContentDescription(getText(R.string.receiver_options));
        root.setOnClickListener(v -> { if (!overlayOpen() && card.getVisibility() != View.VISIBLE) showControls(); });
        updateCardInteraction();
        connectionInfo.setOnClickListener(v -> { hideControls(); setDiagnostics(true); });
        macSettings.setOnClickListener(v -> {
            hideControls();
            startActivity(new Intent(this, SetupActivity.class));
        });
        openChat.setOnClickListener(v -> { hideControls(); showChat(); });
        soundToggle.setOnClickListener(v -> {
            boolean on = !settings.sound();
            if (settings.setSound(on)) player.setSound(on);
            renderToggles();
        });
        popupsToggle.setOnClickListener(v -> {
            boolean on = !settings.chatPopups();
            settings.setChatPopups(on);
            if (!on) chatToasts.removeAllViews();
            renderToggles();
        });
        pointersToggle.setOnClickListener(v -> {
            boolean on = !settings.pointers();
            if (settings.setPointers(on)) control.post(() -> extras.setPointersWanted(on));
            if (!on) pointerView.setPointers(Collections.emptyList());
            renderToggles();
        });
        renderToggles();
        PairingChanges.register(this);
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        // A pairing change already restarted the controller through PairingChanges; nothing else to do.
    }

    @Override protected void onStart() {
        super.onStart();
        started = true;
        begin();
    }

    private void begin() {
        HostConfig host = settings.host();
        if (host == null) {
            control.post(() -> controller.stop());
            startActivity(new Intent(this, SetupActivity.class));
            return;
        }
        player.setSound(settings.sound());
        discovery.start();
        watchNetwork(true);
        control.post(() -> controller.start(host));
        main.removeCallbacks(refreshDiagnostics);
        main.post(refreshDiagnostics);
    }

    @Override protected void onStop() {
        started = false;
        player.setSound(false);
        hideControls();
        hideChat();
        chatToasts.removeAllViews();
        setDiagnostics(false);
        main.removeCallbacks(refreshDiagnostics);
        watchNetwork(false);
        discovery.stop();
        control.post(() -> controller.stop());
        clearDisplayMode();
        super.onStop();
    }

    @Override protected void onDestroy() {
        player.detach(video);
        video.release();
        control.post(() -> {
            controller.stop();
            main.post(() -> PairingChanges.unregister(this));
            player.release();
            io.shutdownNow();
        });
        controlThread.quitSafely();
        super.onDestroy();
    }

    // ---- PairingChanges.Receiver (main thread) ----

    @Override public boolean stopForChange() {
        CountDownLatch stopped = new CountDownLatch(1);
        if (!control.post(() -> { controller.stop(); stopped.countDown(); })) return false;
        try {
            if (!stopped.await(3, TimeUnit.SECONDS)) return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
        discovery.stop();
        return true;
    }

    @Override public void resumeAfterChange() {
        if (started) begin();
    }

    private void watchNetwork(boolean on) {
        ConnectivityManager connectivity = getSystemService(ConnectivityManager.class);
        if (connectivity == null) return;
        if (on && networkCallback == null) {
            networkCallback = new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network network) { control.post(() -> controller.nudge()); }
            };
            try { connectivity.registerDefaultNetworkCallback(networkCallback); } catch (RuntimeException e) { networkCallback = null; }
        } else if (!on && networkCallback != null) {
            try { connectivity.unregisterNetworkCallback(networkCallback); } catch (RuntimeException ignored) { }
            networkCallback = null;
        }
    }

    // ---- Display mode ----

    private Display display() {
        return android.os.Build.VERSION.SDK_INT >= 30 ? getDisplay() : getWindowManager().getDefaultDisplay();
    }

    /**
     * Asks for a display mode at least as large as the decoded picture (for example 3840x2160)
     * when the current mode is smaller and the display offers one. Prefers the current refresh
     * rate. This is a request; the platform and the TV decide what HDMI actually carries.
     */
    private void requestDisplayMode(int width, int height) {
        Display display = display();
        if (display == null) return;
        Display.Mode current = display.getMode();
        if (current.getPhysicalWidth() >= width && current.getPhysicalHeight() >= height) return;
        Display.Mode best = null;
        for (Display.Mode mode : display.getSupportedModes()) {
            if (mode.getPhysicalWidth() < width || mode.getPhysicalHeight() < height) continue;
            if (best == null || better(mode, best, current.getRefreshRate())) best = mode;
        }
        if (best == null || best.getModeId() == requestedModeId) return;
        requestedModeId = best.getModeId();
        WindowManager.LayoutParams attributes = getWindow().getAttributes();
        attributes.preferredDisplayModeId = requestedModeId;
        getWindow().setAttributes(attributes);
    }

    private static boolean better(Display.Mode candidate, Display.Mode best, float rate) {
        boolean candidateRate = Math.abs(candidate.getRefreshRate() - rate) < 0.5f, bestRate = Math.abs(best.getRefreshRate() - rate) < 0.5f;
        if (candidateRate != bestRate) return candidateRate;
        long candidatePixels = (long) candidate.getPhysicalWidth() * candidate.getPhysicalHeight();
        long bestPixels = (long) best.getPhysicalWidth() * best.getPhysicalHeight();
        if (candidatePixels != bestPixels) return candidatePixels < bestPixels;
        return candidate.getRefreshRate() > best.getRefreshRate();
    }

    private void clearDisplayMode() {
        if (requestedModeId == 0) return;
        requestedModeId = 0;
        WindowManager.LayoutParams attributes = getWindow().getAttributes();
        attributes.preferredDisplayModeId = 0;
        getWindow().setAttributes(attributes);
    }

    // ---- Keys ----

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        // Button key events are consumed before onKeyDown, so refresh the timeout here.
        if (event.getAction() == KeyEvent.ACTION_DOWN && controls.getVisibility() == View.VISIBLE) {
            scheduleControlsDismissal();
        }
        return super.dispatchKeyEvent(event);
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_MENU:
                if (event.getRepeatCount() == 0) {
                    if (controls.getVisibility() == View.VISIBLE) hideControls();
                    else showControls();
                }
                return true;
            case KeyEvent.KEYCODE_SETTINGS:
                if (event.getRepeatCount() == 0) startActivity(new Intent(this, SetupActivity.class));
                return true;
            case KeyEvent.KEYCODE_INFO:
            case KeyEvent.KEYCODE_PROG_BLUE:
                if (event.getRepeatCount() == 0) { hideControls(); setDiagnostics(!showDiagnostics); }
                return true;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                if (chatOpen || showDiagnostics) return true;
                if (controls.getVisibility() != View.VISIBLE && card.getVisibility() != View.VISIBLE) {
                    if (event.getRepeatCount() == 0) showControls();
                    return true;
                }
                break;
            default:
                break;
        }
        return super.onKeyDown(keyCode, event);
    }

    @SuppressWarnings("deprecation")
    @Override public void onBackPressed() {
        if (controls.getVisibility() == View.VISIBLE) { hideControls(); return; }
        if (chatOpen) { hideChat(); return; }
        if (showDiagnostics) { setDiagnostics(false); return; }
        super.onBackPressed();
    }

    private void showControls() {
        setDiagnostics(false);
        hideChat();
        renderToggles();
        controls.setVisibility(View.VISIBLE);
        updateCardInteraction();
        (card.getVisibility() == View.VISIBLE ? macSettings : soundToggle).requestFocus();
        scheduleControlsDismissal();
    }

    private boolean spokenNavigation() {
        android.view.accessibility.AccessibilityManager accessibility = getSystemService(android.view.accessibility.AccessibilityManager.class);
        return accessibility != null && accessibility.isEnabled() && (accessibility.isTouchExplorationEnabled()
                || !accessibility.getEnabledAccessibilityServiceList(android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_SPOKEN).isEmpty());
    }

    private void scheduleControlsDismissal() {
        main.removeCallbacks(dismissControls);
        if (!spokenNavigation()) main.postDelayed(dismissControls, 10_000);
    }

    private void hideControls() {
        main.removeCallbacks(dismissControls);
        if (controls.getVisibility() != View.VISIBLE) return;
        controls.setVisibility(View.GONE);
        restorePlaybackFocus();
    }

    private void setDiagnostics(boolean visible) {
        if (visible) hideChat();
        showDiagnostics = visible;
        diagnosticsPanel.setVisibility(visible ? View.VISIBLE : View.GONE);
        if (visible) {
            updateCardInteraction();
            diagnostics.setText(R.string.connection_info);
            diagnosticsPanel.scrollTo(0, 0);
            diagnosticsPanel.requestFocus();
            if (player != null) player.collect(snapshot -> main.post(() -> renderDiagnostics(snapshot)));
        } else restorePlaybackFocus();
    }

    private boolean overlayOpen() {
        return controls.getVisibility() == View.VISIBLE || showDiagnostics || chatOpen;
    }

    private void updateCardInteraction() {
        boolean overlay = overlayOpen();
        boolean playbackAction = !overlay && card.getVisibility() != View.VISIBLE;
        root.setClickable(playbackAction);
        root.setImportantForAccessibility(playbackAction ? View.IMPORTANT_FOR_ACCESSIBILITY_YES : View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        card.setDescendantFocusability(overlay ? ViewGroup.FOCUS_BLOCK_DESCENDANTS : ViewGroup.FOCUS_BEFORE_DESCENDANTS);
        card.setImportantForAccessibility(overlay ? View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS : View.IMPORTANT_FOR_ACCESSIBILITY_AUTO);
    }

    private void restorePlaybackFocus() {
        updateCardInteraction();
        if (!started || overlayOpen()) return;
        if (card.getVisibility() != View.VISIBLE) root.requestFocus();
        else if (!card.hasFocus()) (askAgain.getVisibility() == View.VISIBLE ? askAgain : openOptions).requestFocus();
    }

    // ---- Presentation ----

    private static boolean idle(Phase phase) {
        switch (phase) {
            case SEARCHING: case ENDED: case DECLINED: case REMOVED: case NEEDS_ASK: case NAME_REJECTED:
            case STORAGE_PROBLEM: case BUSY: case PAUSED: case UNCONFIGURED:
                return true;
            default:
                return false;
        }
    }

    private void render(ReceiverController.View view) {
        boolean phaseChanged = lastView == null || lastView.phase != view.phase;
        lastView = view;
        int icon = R.drawable.ic_mac;
        int title = 0;
        String message = "", detail = "";
        String name = view.receiverName;
        switch (view.phase) {
            case UNCONFIGURED:
                title = R.string.status_unconfigured;
                message = getString(R.string.status_unconfigured_detail);
                break;
            case PAUSED:
                title = R.string.status_paused;
                icon = R.drawable.ic_pause;
                break;
            case SEARCHING:
                title = R.string.status_searching;
                String host = android.net.Uri.parse(view.host).getAuthority();
                message = getString(R.string.status_searching_detail, host == null ? view.host : host);
                break;
            case ASKING:
            case ASKING_AGAIN:
                title = view.phase == Phase.ASKING ? R.string.status_asking : R.string.status_asking_again;
                icon = R.drawable.ic_request;
                message = getString(R.string.status_asking_detail, name);
                break;
            case WAITING:
                title = R.string.status_waiting;
                icon = R.drawable.ic_wait;
                message = getString(R.string.status_waiting_detail, name);
                if (view.number > 0) detail = getString(R.string.status_request_number, view.number);
                break;
            case BUSY:
                title = R.string.status_busy;
                icon = R.drawable.ic_wait;
                message = getString(R.string.status_busy_detail);
                break;
            case NEEDS_ASK:
                title = R.string.status_ask;
                icon = R.drawable.ic_request;
                message = getString(R.string.status_ask_detail);
                break;
            case NAME_REJECTED:
                title = R.string.status_name_rejected;
                icon = R.drawable.ic_warning;
                message = getString(R.string.status_name_rejected_detail);
                break;
            case STORAGE_PROBLEM:
                title = R.string.status_storage;
                icon = R.drawable.ic_warning;
                message = getString(R.string.status_storage_detail);
                break;
            case CONNECTING:
                title = R.string.status_connecting;
                icon = R.drawable.ic_wait;
                break;
            case STALLED:
            case AUDIENCE_RECONNECTING:
                title = R.string.status_stalled;
                icon = R.drawable.ic_retry;
                break;
            case HOLDING:
                title = R.string.status_hold;
                icon = R.drawable.ic_pause;
                message = getString(R.string.status_hold_detail);
                break;
            case ENDED:
            case DECLINED:
            case REMOVED:
                title = view.phase == Phase.ENDED ? R.string.status_ended
                        : view.phase == Phase.DECLINED ? R.string.status_declined : R.string.status_removed;
                icon = R.drawable.ic_end;
                message = getString(R.string.status_next_share);
                break;
            case LIVE:
                break;
        }
        boolean live = view.phase == Phase.LIVE;
        card.setVisibility(live ? View.GONE : View.VISIBLE);
        if (phaseChanged) {
            card.setBackgroundResource(view.phase == Phase.HOLDING ? R.drawable.hold_background : R.drawable.card_background);
            cardIcon.setImageResource(icon);
            cardTitle.setText(title == 0 ? "" : getString(title));
        }
        // Shift the unattended card slowly while keeping its controls and copy readable.
        boolean quiet = idle(view.phase) && !overlayOpen();
        long step = SystemClock.elapsedRealtime() / 60_000;
        float density = getResources().getDisplayMetrics().density;
        card.setTranslationX(quiet ? ((step % 5) - 2) * 16 * density : 0);
        card.setTranslationY(quiet ? (((step / 5) % 5) - 2) * 12 * density : 0);
        // The picture is visible only while Live, or dimmed and labeled while Reconnecting. Every
        // other phase (Hold, removed, declined, ended, waiting, searching...) covers it opaquely,
        // independent of whether the renderer has finished clearing.
        boolean showPicture = (live || view.phase == Phase.STALLED) && player.hasRendered(view.playerGeneration);
        cover.setVisibility(showPicture ? View.GONE : View.VISIBLE);
        dim.setVisibility(view.phase == Phase.STALLED ? View.VISIBLE : View.GONE);
        setStatusText(cardMessage, message);
        setStatusText(cardDetail, detail);
        boolean showAsk = view.canAskAgain && view.phase != Phase.NAME_REJECTED;
        boolean newAsk = showAsk && askAgain.getVisibility() != View.VISIBLE;
        askAgain.setVisibility(showAsk ? View.VISIBLE : View.GONE);
        if (newAsk && !overlayOpen()) askAgain.requestFocus();
        if (!overlayOpen() && (phaseChanged || !live && !card.hasFocus())) restorePlaybackFocus();
        sample.setVisibility(view.sample ? View.VISIBLE : View.GONE);
        if (!live && view.playerGeneration == 0) frame.setPicture(0, 0);
    }

    private static void setStatusText(TextView label, String value) {
        if (!TextUtils.equals(label.getText(), value)) label.setText(value);
        label.setVisibility(value.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private void renderDiagnostics(WebRtcPlayer.Snapshot s) {
        if (!showDiagnostics || !player.isCurrent(s) || s.sampledAt < lastDiagnosticsAt) return;
        ReceiverController.View v = lastView;
        if (v != null && s.generation != v.playerGeneration) return;
        lastDiagnosticsAt = s.sampledAt;
        StringBuilder text = new StringBuilder();
        if (v != null) {
            if (!v.title.isEmpty()) text.append("Session ").append(v.title).append('\n');
            text.append("Phase ").append(v.phase.name().toLowerCase(Locale.ROOT).replace('_', ' '))
                    .append("   admission ").append(v.admission).append(v.number > 0 ? " #" + v.number : "").append('\n');
            text.append("Paired ").append(v.host).append(" as \"").append(v.receiverName).append("\" (unverified label)\n");
            if (!v.route.isEmpty()) text.append("Mac ").append(v.route).append("   share ").append(v.share).append('\n');
            text.append("Audience ").append(v.audienceState.isEmpty() ? "unknown" : v.audienceState)
                    .append("   revision ").append(v.revision).append("   updates ").append(v.stateFeed).append('\n');
            if (!v.reason.isEmpty()) text.append("Last issue ").append(v.reason).append('\n');
        }
        SessionExtras.Snapshot e = lastExtras;
        text.append("Chat ").append(e == null ? "not admitted" : e.chatStatus)
                .append("   pointers ").append(!settings.pointers() ? "off on this TV" : e == null ? "off" : e.pointerStatus + (e.pointers.isEmpty() ? "" : ", " + e.pointers.size() + " shown"))
                .append("   sound ").append(settings.sound() ? "on" : "off").append('\n');
        String pinned = settings.pinnedMacId();
        text.append("Bonjour id hint ").append(pinned == null ? "none" : pinned.substring(0, 8) + "… (unverified, not authentication)").append('\n');
        text.append("Discovery ").append(discovery.status()).append('\n');
        text.append("Video ").append(s.decodedWidth > 0 ? s.decodedWidth + "x" + s.decodedHeight : "no picture")
                .append(String.format(Locale.ROOT, "   sink %.1f fps   rendered %.1f fps", s.sinkFps, s.renderedFps)).append('\n');
        text.append("Buffer requested ").append(size(s.requestedWidth, s.requestedHeight))
                .append("   surface confirmed ").append(size(s.bufferWidth, s.bufferHeight))
                .append("   view ").append(size(video.getWidth(), video.getHeight())).append('\n');
        Display display = display();
        if (display != null) {
            Display.Mode mode = display.getMode();
            text.append(String.format(Locale.ROOT, "Display mode %dx%d@%.2f (id %d)   requested %s   HDMI output not verified",
                    mode.getPhysicalWidth(), mode.getPhysicalHeight(), mode.getRefreshRate(), mode.getModeId(),
                    requestedModeId == 0 ? "none" : "id " + requestedModeId)).append('\n');
        }
        Map<String, Object> m = s.video;
        if (!m.isEmpty()) {
            text.append("Decoded ").append(m.get("framesDecoded")).append("   dropped ").append(m.get("framesDropped"))
                    .append("   received ").append(m.get("framesReceived")).append("   keyframes ").append(m.get("keyFramesDecoded"))
                    .append("   decoder fps ").append(m.get("framesPerSecond")).append('\n');
            text.append("Decoder ").append(m.get("decoderImplementation")).append("   power efficient ").append(m.get("powerEfficientDecoder")).append('\n');
            text.append("Packets lost ").append(m.get("packetsLost")).append("   jitter ").append(m.get("jitter"))
                    .append("   freezes ").append(m.get("freezeCount")).append("   NACK ").append(m.get("nackCount"))
                    .append("   PLI ").append(m.get("pliCount")).append('\n');
        }
        if (!s.codec.isEmpty()) text.append("Codec ").append(s.codec.trim()).append('\n');
        Map<String, Object> a = s.audio;
        text.append("Audio ").append(a.isEmpty() ? (s.hasAudio ? "track, no stats" : "none negotiated")
                : "packets " + a.get("packetsReceived") + "   concealed " + a.get("concealedSamples") + "   level " + a.get("audioLevel")).append('\n');
        text.append("Connection ").append(s.connection).append(s.candidatePair.isEmpty() ? "" : "   " + s.candidatePair).append('\n');
        text.append("Receiver ").append(version()).append("   this TV ").append(localAddresses());
        diagnostics.setText(text.toString());
    }

    @SuppressWarnings("deprecation")
    private String version() {
        try {
            android.content.pm.PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            return info.versionName + " (" + info.versionCode + ")";
        } catch (android.content.pm.PackageManager.NameNotFoundException e) { return "unknown"; }
    }

    /** This TV's own IPv4 addresses, for matching it against the Mac's viewer list. */
    private static String localAddresses() {
        StringBuilder text = new StringBuilder();
        try {
            for (NetworkInterface face : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!face.isUp() || face.isLoopback()) continue;
                for (InetAddress address : Collections.list(face.getInetAddresses())) {
                    if (!(address instanceof Inet4Address)) continue;
                    if (text.length() > 0) text.append(", ");
                    text.append(address.getHostAddress()).append(" (").append(face.getName()).append(')');
                }
            }
        } catch (java.net.SocketException | RuntimeException ignored) { }
        return text.length() == 0 ? "no network address" : text.toString();
    }

    // ---- Chat, pointers and TV choices ----

    private void renderToggles() {
        renderToggle(soundToggle, settings.sound(), R.string.sound_on, R.drawable.ic_sound_on, R.string.sound_off, R.drawable.ic_sound_off);
        renderToggle(popupsToggle, settings.chatPopups(), R.string.popups_on, R.drawable.ic_popups_on, R.string.popups_off, R.drawable.ic_popups_off);
        renderToggle(pointersToggle, settings.pointers(), R.string.pointers_on, R.drawable.ic_pointers_on, R.string.pointers_off, R.drawable.ic_pointers_off);
    }

    private void renderToggle(Button button, boolean on, int onLabel, int onIcon, int offLabel, int offIcon) {
        button.setText(on ? onLabel : offLabel);
        button.setCompoundDrawablesRelativeWithIntrinsicBounds(0, on ? onIcon : offIcon, 0, 0);
        button.setCompoundDrawableTintList(button.getTextColors());
    }

    private void renderChatBadge() {
        String label = unread > 0 ? getString(R.string.chat_unread, Math.min(unread, 99)) : getString(R.string.chat_button);
        if (!TextUtils.equals(openChat.getText(), label)) openChat.setText(label);
    }

    private void renderExtras(SessionExtras.Snapshot snapshot) {
        SessionExtras.Snapshot previous = lastExtras;
        lastExtras = snapshot;
        pointerView.setPointers(settings.pointers() && snapshot.bound ? snapshot.pointers : Collections.<com.setbeam.receiver.core.Pointer>emptyList());
        if (!snapshot.bound) {
            // Access ended or changed: nothing from the earlier session stays on screen.
            unread = 0;
            chatToasts.removeAllViews();
        } else if (!snapshot.arrived.isEmpty()) {
            if (chatOpen) { /* already reading */ }
            else if (settings.chatPopups() && started) for (ChatLine line : snapshot.arrived) addToast(line);
            else unread += snapshot.arrived.size();
        }
        renderChatBadge();
        if (chatOpen && (previous == null || previous.chat != snapshot.chat || previous.bound != snapshot.bound
                || !previous.chatStatus.equals(snapshot.chatStatus))) renderChat();
    }

    private void showChat() {
        setDiagnostics(false);
        chatOpen = true;
        unread = 0;
        chatToasts.removeAllViews();
        chatPanel.setVisibility(View.VISIBLE);
        updateCardInteraction();
        renderChat();
        renderChatBadge();
        chatScroll.requestFocus();
        chatScroll.post(() -> chatScroll.fullScroll(View.FOCUS_DOWN));
        control.post(() -> extras.setChatVisible(true));
    }

    private void hideChat() {
        if (!chatOpen) return;
        chatOpen = false;
        chatPanel.setVisibility(View.GONE);
        control.post(() -> extras.setChatVisible(false));
        restorePlaybackFocus();
    }

    private void renderChat() {
        SessionExtras.Snapshot snapshot = lastExtras;
        List<ChatLine> lines = snapshot == null ? Collections.<ChatLine>emptyList() : snapshot.chat;
        if (snapshot == null || !snapshot.bound) chatStatus.setText(R.string.chat_unavailable);
        else if (lines.isEmpty()) chatStatus.setText(R.string.chat_empty);
        else chatStatus.setText(snapshot.chatStatus);
        boolean atBottom = !chatScroll.canScrollVertically(1);
        SpannableStringBuilder text = new SpannableStringBuilder();
        java.text.DateFormat time = android.text.format.DateFormat.getTimeFormat(this);
        for (ChatLine line : lines) {
            if (text.length() > 0) text.append("\n\n");
            appendAuthor(text, line);
            if (line.sentAt > 0) appendMuted(text, "  " + time.format(new java.util.Date((long) (line.sentAt * 1000))));
            if (line.replyTo > 0) {
                ChatLine original = null;
                for (ChatLine other : lines) if (other.id == line.replyTo) original = other;
                appendMuted(text, "\n\u21A9 " + (original == null ? "Reply" : original.name + ": " + snippet(original.display(), 60)));
            }
            text.append('\n').append(line.display());
            if (!line.reactions.isEmpty()) appendMuted(text, "\n" + line.reactions);
        }
        chatText.setText(text);
        if (atBottom) chatScroll.post(() -> chatScroll.fullScroll(View.FOCUS_DOWN));
    }

    private void addToast(ChatLine line) {
        SpannableStringBuilder text = new SpannableStringBuilder();
        appendAuthor(text, line);
        text.append('\n').append(snippet(line.display(), 280));
        TextView toast = new TextView(this);
        toast.setText(text);
        toast.setTextColor(getColor(R.color.ink));
        toast.setTextSize(18);
        toast.setMaxLines(4);
        toast.setEllipsize(TextUtils.TruncateAt.END);
        toast.setBackgroundResource(R.drawable.card_background);
        int pad = (int) (14 * getResources().getDisplayMetrics().density);
        toast.setPadding(pad + pad / 2, pad, pad + pad / 2, pad);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = pad / 2;
        toast.setLayoutParams(params);
        while (chatToasts.getChildCount() >= 3) chatToasts.removeViewAt(0);
        chatToasts.addView(toast);
        main.postDelayed(() -> chatToasts.removeView(toast), 8000);
    }

    private void appendAuthor(SpannableStringBuilder text, ChatLine line) {
        int start = text.length();
        text.append(line.name);
        text.setSpan(new StyleSpan(Typeface.BOLD), start, text.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        text.setSpan(new ForegroundColorSpan(readable(com.setbeam.receiver.core.Pointer.rgb(line.color))), start, text.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        if (line.operator && !line.name.equalsIgnoreCase("DigiTech")) appendMuted(text, " \u00B7 DigiTech");
    }

    private void appendMuted(SpannableStringBuilder text, String value) {
        int start = text.length();
        text.append(value);
        text.setSpan(new ForegroundColorSpan(getColor(R.color.ink_muted)), start, text.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        text.setSpan(new RelativeSizeSpan(0.85f), start, text.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
    }

    /** Lightens a palette color until it reads on the dark card. */
    private static int readable(int rgb) {
        int r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
        double luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
        if (luma < 0.55) { double mix = 0.55 - luma + 0.15; r += (int) ((255 - r) * mix); g += (int) ((255 - g) * mix); b += (int) ((255 - b) * mix); }
        return 0xFF000000 | (Math.min(255, r) << 16) | (Math.min(255, g) << 8) | Math.min(255, b);
    }

    private static String snippet(String value, int max) {
        String single = value.replace('\n', ' ');
        int[] points = single.codePoints().toArray();
        return points.length <= max ? single : new String(points, 0, max - 1) + "\u2026";
    }

    private static String size(int width, int height) { return width > 0 && height > 0 ? width + "x" + height : "none"; }
}
