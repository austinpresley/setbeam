package com.setbeam.receiver;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.ScrollView;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.setbeam.receiver.core.HostConfig;
import com.setbeam.receiver.core.NearbyMacs;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.List;

/**
 * One-time pairing with a D-pad: the Mac's short address and this receiver's label, plus the
 * optional startup choices. Each choice is a request the platform may refuse; this screen reports
 * the actual state rather than assuming it.
 */
public final class SetupActivity extends Activity {
    private enum Page { MACS, MANUAL, TV }
    private static final int REQUEST_HOME = 1;
    private Settings settings;
    private EditText host, name;
    private CheckBox home, boot;
    private TextView title, error, homeDetail, bootDetail, pairedMac, nearbyStatus;
    private Button editPairing, startup, forget, allowStartup;
    private ScrollView scroll;
    private View chooseMac, manualPairing, startupPanel;
    private Discovery nearby;
    private LinearLayout nearbyList;
    private final Map<String, Button> nearbyRows = new LinkedHashMap<>();
    private Page page = Page.MACS;
    private boolean navigatedMacs;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_setup);
        settings = new Settings(this);
        scroll = findViewById(R.id.setup_scroll);
        title = findViewById(R.id.setup_title);
        chooseMac = findViewById(R.id.choose_mac);
        manualPairing = findViewById(R.id.manual_pairing);
        startupPanel = findViewById(R.id.startup_panel);
        pairedMac = findViewById(R.id.paired_mac);
        editPairing = findViewById(R.id.edit_pairing);
        startup = findViewById(R.id.startup_options);
        host = findViewById(R.id.host);
        name = findViewById(R.id.name);
        home = findViewById(R.id.home);
        boot = findViewById(R.id.boot);
        error = findViewById(R.id.error);
        homeDetail = findViewById(R.id.home_detail);
        bootDetail = findViewById(R.id.boot_detail);
        forget = findViewById(R.id.forget);
        allowStartup = findViewById(R.id.allow_startup);
        nearbyList = findViewById(R.id.nearby);
        nearbyStatus = findViewById(R.id.nearby_status);
        nearby = new Discovery(this, settings, () -> { });
        nearby.setOnChange(this::renderNearby);

        loadPairing();
        editPairing.setOnClickListener(v -> showPage(Page.MANUAL, host));
        startup.setOnClickListener(v -> showPage(Page.TV, boot));
        View save = findViewById(R.id.save);
        save.setOnClickListener(v -> connect(host.getText().toString(), name.getText().toString(), null));
        // A single-line EditText can consume an arrow to move its cursor. Outside the TV
        // keyboard, vertical arrows should always move between the form's controls.
        host.setOnKeyListener((v, key, event) -> moveFieldFocus(key, event, null, name));
        name.setOnKeyListener((v, key, event) -> moveFieldFocus(key, event, host, save));
        findViewById(R.id.tv_settings).setOnClickListener(v -> showTvSettings());
        forget.setOnClickListener(v -> {
            if (!PairingChanges.apply(this, Settings::forget)) {
                showError(R.string.setup_save_error);
                return;
            }
            loadPairing();
            showPage(Page.MACS, editPairing);
        });
        home.setOnClickListener(v -> requestHome());
        allowStartup.setOnClickListener(v -> requestOverlay());
        findViewById(R.id.notices).setOnClickListener(v -> showNotices());
        boot.setOnClickListener(v -> {
            showError(null);
            if (!settings.setStartAtBoot(boot.isChecked())) showError(R.string.setup_save_error);
            else if (boot.isChecked()) requestOverlay();
            refresh();
        });
        Page initial = state == null ? Page.MACS : Page.valueOf(state.getString("page", Page.MACS.name()));
        showPage(initial, initial == Page.MANUAL ? host : initial == Page.TV ? boot : editPairing);
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString("page", page.name());
    }

    @Override protected void onResume() {
        super.onResume();
        refresh();
        nearby.start();
        renderNearby();
    }

    @Override protected void onPause() {
        nearby.stop();
        super.onPause();
    }

    @Override protected void onDestroy() {
        nearby.setOnChange(null);
        super.onDestroy();
    }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if (page == Page.MACS && event.getAction() == KeyEvent.ACTION_DOWN) navigatedMacs = true;
        return super.dispatchKeyEvent(event);
    }

    private static boolean moveFieldFocus(int key, KeyEvent event, View up, View down) {
        if (key != KeyEvent.KEYCODE_DPAD_UP && key != KeyEvent.KEYCODE_DPAD_DOWN) return false;
        View target = key == KeyEvent.KEYCODE_DPAD_UP ? up : down;
        if (target != null && event.getAction() == KeyEvent.ACTION_DOWN) target.requestFocus();
        return true;
    }

    private void loadPairing() {
        HostConfig current = settings.host();
        host.setText(current == null ? "" : current.scheme.equals("http") ? current.hostHeader() : current.baseUrl());
        name.setText(current == null ? getString(R.string.default_receiver_name) : current.name);
        pairedMac.setVisibility(current == null ? View.GONE : View.VISIBLE);
        if (current != null) pairedMac.setText(getString(R.string.setup_paired, current.hostHeader(), current.name));
        editPairing.setText(current == null ? R.string.setup_manual : R.string.setup_edit);
        forget.setVisibility(current == null ? View.GONE : View.VISIBLE);
    }

    private void showPage(Page value, View focus) {
        page = value;
        showError(null);
        title.setText(value == Page.MANUAL ? R.string.setup_manual_title
                : value == Page.TV ? R.string.setup_startup : R.string.setup_title);
        chooseMac.setVisibility(value == Page.MACS ? View.VISIBLE : View.GONE);
        manualPairing.setVisibility(value == Page.MANUAL ? View.VISIBLE : View.GONE);
        startupPanel.setVisibility(value == Page.TV ? View.VISIBLE : View.GONE);
        scroll.scrollTo(0, 0);
        focus.requestFocus();
    }

    /** A nearby Mac is paired only when the viewer presses OK on its row. */
    private void renderNearby() {
        List<NearbyMacs.Choice> choices = NearbyMacs.choices(nearby.seen());
        View focused = nearbyList.getFocusedChild();
        int previousIndex = nearbyList.indexOfChild(focused);
        Map<String, Button> next = new LinkedHashMap<>();
        for (NearbyMacs.Choice choice : choices) {
            Button row = nearbyRows.get(choice.address);
            if (row == null) row = nearbyButton();
            if (!TextUtils.equals(row.getText(), choice.title)) row.setText(choice.title);
            String label = choice.detail.isEmpty() ? choice.title : choice.title + ", " + choice.detail;
            if (!TextUtils.equals(row.getContentDescription(), label)) row.setContentDescription(label);
            row.setOnClickListener(v -> {
                HostConfig current = settings.host();
                connect(choice.address, current == null ? getString(R.string.default_receiver_name) : current.name, choice.id);
            });
            next.put(choice.address, row);
        }
        for (Button previous : nearbyRows.values()) if (!next.containsValue(previous)) nearbyList.removeView(previous);
        int index = 0;
        for (Button row : next.values()) {
            if (nearbyList.getChildAt(index) != row) {
                if (row.getParent() == nearbyList) nearbyList.removeView(row);
                nearbyList.addView(row, index);
            }
            index++;
        }
        boolean hadRows = !nearbyRows.isEmpty();
        nearbyRows.clear();
        nearbyRows.putAll(next);
        nearbyStatus.setText(choices.isEmpty() ? R.string.setup_nearby_looking : R.string.setup_nearby);
        findViewById(R.id.discovery_help).setVisibility(choices.isEmpty() ? View.VISIBLE : View.GONE);
        if (page != Page.MACS) return;
        View fallback = choices.isEmpty() ? editPairing
                : nearbyList.getChildAt(Math.min(Math.max(0, previousIndex), choices.size() - 1));
        if (focused != null && !focused.hasFocus()) {
            (next.containsValue(focused) ? focused : fallback).requestFocus();
        } else if (!hadRows && !choices.isEmpty() && !navigatedMacs && settings.host() == null
                && !editPairing.isAccessibilityFocused()) {
            fallback.requestFocus();
        }
    }

    private Button nearbyButton() {
        Button button = new Button(this, null, 0, R.style.Tv_Button);
        button.setId(View.generateViewId());
        button.setSingleLine();
        button.setEllipsize(TextUtils.TruncateAt.END);
        button.setCompoundDrawablesRelativeWithIntrinsicBounds(R.drawable.ic_mac, 0, 0, 0);
        button.setCompoundDrawableTintList(getColorStateList(R.color.button_text));
        button.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(60));
        params.topMargin = dp(8);
        button.setLayoutParams(params);
        return button;
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private void refresh() {
        boolean holdsHome = settings.holdsHomeRole();
        boolean allowed = android.provider.Settings.canDrawOverlays(this);
        home.setChecked(holdsHome);
        boot.setChecked(settings.startAtBoot());
        boolean needsPermission = boot.isChecked() && !allowed;
        boolean permissionHadFocus = allowStartup.hasFocus();
        allowStartup.setVisibility(needsPermission ? View.VISIBLE : View.GONE);
        boot.setNextFocusDownId(needsPermission ? R.id.allow_startup : R.id.home);
        home.setNextFocusUpId(needsPermission ? R.id.allow_startup : R.id.boot);
        if (permissionHadFocus && !needsPermission) boot.requestFocus();
        homeDetail.setText(holdsHome ? R.string.setup_home_on : R.string.setup_home_off);
        bootDetail.setText(!boot.isChecked() ? R.string.setup_boot_off
                : allowed ? R.string.setup_boot_on : R.string.setup_boot_permission);
    }

    private void connect(String address, String label, String selectedId) {
        HostConfig config;
        try { config = HostConfig.parse(address, label); }
        catch (HostConfig.Invalid e) { showError(e.getMessage()); return; }
        boolean changed = !config.equals(settings.host()) || selectedId != null && !selectedId.equals(settings.pinnedMacId());
        if (changed && !PairingChanges.apply(this, s -> s.pair(config, selectedId))) {
            showError(R.string.setup_save_error);
            return;
        }
        showError(null);
        Intent intent = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(intent);
        finish();
    }

    private void showTvSettings() {
        try { startActivity(new Intent(android.provider.Settings.ACTION_SETTINGS)); }
        catch (ActivityNotFoundException e) { showError(R.string.setup_settings_unavailable); }
    }

    private void showError(int message) { showError(getText(message)); }

    private void showError(CharSequence message) {
        error.setText(message);
        error.setVisibility(message == null ? View.GONE : View.VISIBLE);
        if (message != null) error.post(() -> error.requestRectangleOnScreen(
                new android.graphics.Rect(0, 0, error.getWidth(), error.getHeight())));
    }

    @SuppressWarnings("deprecation")
    @Override public void onBackPressed() {
        if (page != Page.MACS) {
            showPage(Page.MACS, page == Page.MANUAL ? editPairing : startup);
        } else if (settings.host() != null) {
            finish();
        } else if (!settings.holdsHomeRole()) {
            finishAffinity();
        } else {
            // When Setbeam is Home, finishing here can just reopen the unpaired receiver.
            showTvSettings();
        }
    }

    private void requestHome() {
        home.setChecked(settings.holdsHomeRole());
        if (Build.VERSION.SDK_INT < 29) { showError(R.string.setup_home_unavailable); return; }
        android.app.role.RoleManager roles = getSystemService(android.app.role.RoleManager.class);
        if (roles == null || !roles.isRoleAvailable(android.app.role.RoleManager.ROLE_HOME)) { showError(R.string.setup_home_unavailable); return; }
        if (roles.isRoleHeld(android.app.role.RoleManager.ROLE_HOME)) {
            showError(R.string.setup_home_change);
            return;
        }
        try { startActivityForResult(roles.createRequestRoleIntent(android.app.role.RoleManager.ROLE_HOME), REQUEST_HOME); }
        catch (ActivityNotFoundException e) { showError(R.string.setup_home_unavailable); }
    }

    private void requestOverlay() {
        if (android.provider.Settings.canDrawOverlays(this)) return;
        Intent intent = new Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getPackageName()));
        try { startActivity(intent); }
        catch (ActivityNotFoundException e) { showError(R.string.setup_overlay_unavailable); }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_HOME) {
            showError(settings.holdsHomeRole() ? null : getText(R.string.setup_home_refused));
            refresh();
        }
    }

    /** The bundled WebRTC and third-party license notices (assets/third_party_notices.txt). */
    private void showNotices() {
        String text;
        try (java.io.InputStream in = getAssets().open("third_party_notices.txt")) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            for (int n; (n = in.read(buffer)) > 0 && bytes.size() < 1 << 20; ) bytes.write(buffer, 0, n);
            text = bytes.toString("UTF-8");
        } catch (java.io.IOException e) { text = "Notices are missing from this build."; }
        TextView body = new TextView(this);
        body.setText(text); body.setTextSize(13); body.setPadding(32, 32, 32, 32); body.setFocusable(true);
        android.widget.ScrollView scroll = new android.widget.ScrollView(this);
        scroll.addView(body);
        new android.app.AlertDialog.Builder(this).setTitle(R.string.notices).setView(scroll).setPositiveButton(android.R.string.ok, null).show();
    }

}
