package com.setbeam.receiver;

import android.content.Context;
import android.content.SharedPreferences;

import com.setbeam.receiver.core.AccessStore;
import com.setbeam.receiver.core.HostConfig;

import java.util.HashSet;
import java.util.Set;

/**
 * App-private pairing and per-share request state. Nothing here is backed up or transferred
 * (see data_extraction_rules.xml). Writes use commit() and report failure, so a refusal or a
 * request count is on disk before the receiver acts on it.
 *
 * <p>Per-share records, including refusal tombstones, are never cleared by re-pairing or Forget:
 * they are keyed by the share's own ask path, so they cannot affect a different Mac, and keeping
 * them stops a re-pair from producing a new request on a share that was refused. Pairing changes
 * go through {@link PairingChanges} so a running receiver stops before they are applied.
 */
@android.annotation.SuppressLint("ApplySharedPref") // commit(): durability is checked, not assumed.
final class Settings {
    private static final String PAIRING = "pairing";
    private static final String ACCESS = "access";
    private static final String HOST = "host";
    private static final String NAME = "name";
    private static final String PINNED_ID = "pinned_mac_id";
    private static final String START_AT_BOOT = "start_at_boot";
    private static final String DISPLAY = "display";
    private static final String SOUND = "sound";
    private static final String CHAT_POPUPS = "chat_popups";
    private static final String POINTERS = "pointers";

    private final Context context;
    private final SharedPreferences pairing;
    private final SharedPreferences access;
    /** This TV's presentation choices. Not pairing or access state; never cleared by Forget. */
    private final SharedPreferences display;

    Settings(Context context) {
        this.context = context.getApplicationContext();
        pairing = this.context.getSharedPreferences(PAIRING, Context.MODE_PRIVATE);
        access = this.context.getSharedPreferences(ACCESS, Context.MODE_PRIVATE);
        display = this.context.getSharedPreferences(DISPLAY, Context.MODE_PRIVATE);
    }

    /** Play the feed's sound on this TV. On by default. */
    boolean sound() { return display.getBoolean(SOUND, true); }
    boolean setSound(boolean value) { return display.edit().putBoolean(SOUND, value).commit(); }

    /** Show new session-chat messages over the picture. Off by default, so playback stays clean. */
    boolean chatPopups() { return display.getBoolean(CHAT_POPUPS, false); }
    boolean setChatPopups(boolean value) { return display.edit().putBoolean(CHAT_POPUPS, value).commit(); }

    /** Show other viewers' shared pointers over the picture. Off by default, as on the Mac. */
    boolean pointers() { return display.getBoolean(POINTERS, false); }
    boolean setPointers(boolean value) { return display.edit().putBoolean(POINTERS, value).commit(); }

    /** The paired Mac, or null before setup or if the saved value no longer validates. */
    HostConfig host() {
        String host = pairing.getString(HOST, null), name = pairing.getString(NAME, null);
        if (host == null || name == null) return null;
        try { return HostConfig.parse(host, name); } catch (HostConfig.Invalid e) { return null; }
    }

    /**
     * Saves a pairing; call through {@link PairingChanges#apply}. A different base URL forgets the
     * pinned Bonjour id hint. Returns whether it reached storage.
     */
    boolean pair(HostConfig config) { return pair(config, null); }

    boolean pair(HostConfig config, String selectedId) {
        HostConfig previous = host();
        SharedPreferences.Editor editor = pairing.edit().putString(HOST, config.baseUrl()).putString(NAME, config.name);
        boolean differentId = selectedId != null && !selectedId.equals(pinnedMacId());
        if (selectedId != null) editor.putString(PINNED_ID, selectedId);
        else if (previous == null || !previous.baseUrl().equals(config.baseUrl())) editor.remove(PINNED_ID);
        boolean saved = editor.commit();
        if (saved && (differentId || previous == null || !previous.baseUrl().equals(config.baseUrl()))) store().clearAdmittedRoute();
        return saved;
    }

    /** Forgets the paired Mac and its id hint. Per-share refusals are kept. */
    boolean forget() {
        boolean saved = pairing.edit().remove(HOST).remove(NAME).remove(PINNED_ID).commit();
        if (saved) store().clearAdmittedRoute();
        return saved;
    }

    /** An unverified Bonjour installation-id hint, used only to filter discovery. */
    String pinnedMacId() {
        String id = pairing.getString(PINNED_ID, null);
        return id != null && id.matches("[0-9a-f]{32}") ? id : null;
    }
    void pinMacId(String id) {
        if (id != null && pinnedMacId() == null) pairing.edit().putString(PINNED_ID, id).commit();
    }

    boolean startAtBoot() { return pairing.getBoolean(START_AT_BOOT, true); }
    boolean setStartAtBoot(boolean value) { return pairing.edit().putBoolean(START_AT_BOOT, value).commit(); }

    /** True when this app holds the HOME role. Holding it does not guarantee HOME resolves here. */
    boolean holdsHomeRole() {
        if (android.os.Build.VERSION.SDK_INT < 29) return false;
        android.app.role.RoleManager roles = context.getSystemService(android.app.role.RoleManager.class);
        return roles != null && roles.isRoleAvailable(android.app.role.RoleManager.ROLE_HOME) && roles.isRoleHeld(android.app.role.RoleManager.ROLE_HOME);
    }

    AccessStore store() {
        return new AccessStore(new AccessStore.KeyValue() {
            @Override public String get(String key) { return access.getString(key, null); }
            @Override public boolean put(String key, String value) { return access.edit().putString(key, value).commit(); }
            @Override public boolean remove(String key) { return access.edit().remove(key).commit(); }
            @Override public Set<String> keys() { return new HashSet<>(access.getAll().keySet()); }
        }, new KeystoreBox());
    }
}
