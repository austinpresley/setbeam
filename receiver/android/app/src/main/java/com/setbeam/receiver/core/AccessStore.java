package com.setbeam.receiver.core;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * Per-share request state, keyed by a digest of the ask path (never by host or IP, so a DHCP move
 * or a different alias for the same Mac keeps the session). It survives app and device restarts
 * and re-pairing; nothing in the app clears it.
 *
 * <p>Refusals are tombstones: once a share's request is declined or removed, nothing stores a
 * different admission for that ask path, and the bound never evicts one. When the bound is
 * reached with nothing evictable, new records are refused (fail closed), so the receiver stops
 * asking rather than forgetting a refusal. A pass that cannot be sealed is stored as an
 * unreadable marker, so a restart waits for the TV user instead of asking again. Every write
 * reports whether it reached storage.
 */
public final class AccessStore {
    /** Records of any kind. Refusals are never evicted to make room. */
    public static final int MAX_RECORDS = 1024;
    static final String PREFIX = "share.";
    static final String UNSEALED = "!";

    public interface KeyValue {
        String get(String key);
        /** Returns true only when the value is durably stored. */
        boolean put(String key, String value);
        boolean remove(String key);
        Set<String> keys();
    }

    public interface SecretBox {
        String seal(String plain) throws Exception;
        String open(String sealed) throws Exception;
    }

    public enum Admission {
        NONE, PENDING, ADMITTED, DECLINED, REMOVED;
        public boolean refused() { return this == DECLINED || this == REMOVED; }
        public static Admission parse(String value) {
            if (value == null) return null;
            switch (value) {
                case "pending": return PENDING;
                case "admitted": return ADMITTED;
                case "declined": return DECLINED;
                case "removed": return REMOVED;
                default: return null;
            }
        }
    }

    /** One share's request. Mutable copy; save it to persist. */
    public static final class Record {
        public Admission admission = Admission.NONE;
        public String pass;
        public int number;
        /** Requests sent with {@code ask} on this path, and when the last one was sent (wall clock). */
        public int asks;
        public long lastAskAt;
        public long updatedAt;
        /** A pass was stored but cannot be read back on this device, or could not be sealed. */
        public boolean passUnreadable;
    }

    private final KeyValue values;
    private final SecretBox box;

    public AccessStore(KeyValue values, SecretBox box) { this.values = values; this.box = box; }

    public synchronized Record load(String key) {
        Record record = new Record();
        String raw = values.get(PREFIX + key);
        if (raw == null) return record;
        String[] parts = raw.split("\\|", -1);
        if (parts.length != 7 || !parts[0].equals("v1")) {
            // An unreadable record must never become a fresh request if it might have been a refusal.
            record.admission = Admission.DECLINED;
            return record;
        }
        Admission admission;
        try { admission = Admission.valueOf(parts[1]); } catch (IllegalArgumentException e) { admission = Admission.DECLINED; }
        record.admission = admission;
        record.number = parseInt(parts[2]);
        record.asks = parseInt(parts[3]);
        record.lastAskAt = parseLong(parts[4]);
        record.updatedAt = parseLong(parts[5]);
        if (!parts[6].isEmpty() && !admission.refused()) {
            if (parts[6].equals(UNSEALED)) record.passUnreadable = true;
            else {
                try { record.pass = box.open(parts[6]); } catch (Exception e) { record.passUnreadable = true; }
                if (record.pass != null && !validPass(record.pass)) { record.pass = null; record.passUnreadable = true; }
            }
        }
        return record;
    }

    /**
     * Persists a record. Returns false if nothing durable was written: a storage failure, or the
     * bound is full of refusals. A stored refusal for this key is never replaced (returns true:
     * the refusal stands).
     */
    public synchronized boolean save(String key, Record record, long now) {
        String existing = values.get(PREFIX + key);
        if (existing != null && load(key).admission.refused()) return true;
        String sealed = "";
        if (record.pass != null && !record.admission.refused()) {
            try { sealed = box.seal(record.pass); } catch (Exception e) { sealed = UNSEALED; }
            if (sealed == null || sealed.isEmpty() || sealed.contains("|")) sealed = UNSEALED;
        } else if (record.passUnreadable && !record.admission.refused()) {
            sealed = UNSEALED;
        }
        if (existing == null && !makeRoom(key)) return false;
        record.updatedAt = now;
        return values.put(PREFIX + key, "v1|" + record.admission.name() + "|" + record.number + "|" + record.asks + "|"
                + record.lastAskAt + "|" + now + "|" + sealed);
    }

    /** Saves and reads back the fields that guard against repeated requests. */
    public synchronized boolean saveVerified(String key, Record record, long now) {
        if (!save(key, record, now)) return false;
        Record back = load(key);
        return back.admission == record.admission && back.asks == record.asks && back.lastAskAt == record.lastAskAt;
    }

    /** Marks this share refused and forgets its pass. Returns whether the refusal is on disk. */
    public synchronized boolean refuse(String key, Admission admission, long now) {
        if (!admission.refused()) throw new IllegalArgumentException("not a refusal");
        if (values.get(PREFIX + key) != null && load(key).admission.refused()) return true;
        Record record = load(key);
        record.admission = admission; record.pass = null; record.passUnreadable = false;
        // A refusal may always replace this key's own record, and evicts others before failing.
        if (values.get(PREFIX + key) == null && !makeRoom(key)) return false;
        record.updatedAt = now;
        return values.put(PREFIX + key, "v1|" + admission.name() + "|" + record.number + "|" + record.asks + "|"
                + record.lastAskAt + "|" + now + "|");
    }

    /** Evicts the oldest non-refused records until one more fits. False when only refusals remain. */
    private boolean makeRoom(String keep) {
        List<String> keys = new ArrayList<>();
        for (String key : values.keys()) if (key.startsWith(PREFIX)) keys.add(key);
        while (keys.size() >= MAX_RECORDS) {
            String oldest = null; long oldestAt = Long.MAX_VALUE;
            for (String key : keys) {
                if (key.equals(PREFIX + keep)) continue;
                String raw = values.get(key);
                if (raw == null || isRefusal(raw)) continue;
                long at = updatedAt(raw);
                if (at < oldestAt) { oldestAt = at; oldest = key; }
            }
            if (oldest == null || !values.remove(oldest)) return false;
            keys.remove(oldest);
        }
        return true;
    }

    private static boolean isRefusal(String raw) {
        String[] parts = raw.split("\\|", -1);
        if (parts.length != 7 || !parts[0].equals("v1")) return true;
        return !parts[1].equals(Admission.NONE.name()) && !parts[1].equals(Admission.PENDING.name()) && !parts[1].equals(Admission.ADMITTED.name());
    }

    private static long updatedAt(String raw) {
        String[] parts = raw.split("\\|", -1);
        return parts.length == 7 ? parseLong(parts[5]) : 0;
    }

    public static boolean validPass(String value) {
        if (value == null || value.length() != 48) return false;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
        }
        return true;
    }

    private static int parseInt(String value) { try { return Integer.parseInt(value); } catch (NumberFormatException e) { return 0; } }
    private static long parseLong(String value) { try { return Long.parseLong(value); } catch (NumberFormatException e) { return 0; } }
}
