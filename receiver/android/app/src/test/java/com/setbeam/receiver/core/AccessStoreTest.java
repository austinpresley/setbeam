package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import org.junit.Test;

public class AccessStoreTest {
    static final String PASS = "0123456789abcdef0123456789abcdef0123456789abcdef";

    static final class MemoryValues implements AccessStore.KeyValue {
        final Map<String, String> map = new HashMap<>();
        /** commit() returns false and nothing is written. */
        boolean failWrites;
        /** commit() claims success but nothing is written (a lying or full disk). */
        boolean dropWrites;
        @Override public String get(String key) { return map.get(key); }
        @Override public boolean put(String key, String value) {
            if (failWrites) return false;
            if (!dropWrites) map.put(key, value);
            return true;
        }
        @Override public boolean remove(String key) { if (failWrites) return false; map.remove(key); return true; }
        @Override public Set<String> keys() { return new HashSet<>(map.keySet()); }
    }

    /** Reversible stand-in for the Keystore box, so tests can see the pass is not stored in clear. */
    static final class ReverseBox implements AccessStore.SecretBox {
        @Override public String seal(String plain) { return new StringBuilder(plain).reverse().toString(); }
        @Override public String open(String sealed) { return new StringBuilder(sealed).reverse().toString(); }
    }

    /** The Keystore cannot seal (for example, key generation fails). */
    static final class NoSealBox implements AccessStore.SecretBox {
        @Override public String seal(String plain) throws Exception { throw new Exception("keystore unavailable"); }
        @Override public String open(String sealed) { return sealed; }
    }

    static final class BrokenBox implements AccessStore.SecretBox {
        @Override public String seal(String plain) { return "x"; }
        @Override public String open(String sealed) throws Exception { throw new Exception("key lost"); }
    }

    @Test public void savesAndSealsPasses() {
        MemoryValues values = new MemoryValues();
        AccessStore store = new AccessStore(values, new ReverseBox());
        AccessStore.Record record = new AccessStore.Record();
        record.admission = AccessStore.Admission.PENDING; record.pass = PASS; record.number = 7; record.asks = 1; record.lastAskAt = 99;
        store.save("k", record, 1000);
        assertFalse(values.map.get("share.k").contains(PASS));
        AccessStore.Record loaded = new AccessStore(values, new ReverseBox()).load("k");
        assertEquals(AccessStore.Admission.PENDING, loaded.admission);
        assertEquals(PASS, loaded.pass);
        assertEquals(7, loaded.number);
        assertEquals(1, loaded.asks);
        assertEquals(99, loaded.lastAskAt);
    }

    @Test public void refusalIsStickyAndDropsThePass() {
        MemoryValues values = new MemoryValues();
        AccessStore store = new AccessStore(values, new ReverseBox());
        AccessStore.Record record = new AccessStore.Record();
        record.admission = AccessStore.Admission.ADMITTED; record.pass = PASS;
        store.save("k", record, 1);
        store.refuse("k", AccessStore.Admission.REMOVED, 2);
        AccessStore.Record after = store.load("k");
        assertEquals(AccessStore.Admission.REMOVED, after.admission);
        assertNull(after.pass);
        // Nothing can overwrite the refusal, including a fresh request record.
        AccessStore.Record fresh = new AccessStore.Record();
        fresh.admission = AccessStore.Admission.PENDING; fresh.pass = PASS;
        store.save("k", fresh, 3);
        assertEquals(AccessStore.Admission.REMOVED, store.load("k").admission);
        store.refuse("k", AccessStore.Admission.DECLINED, 4);
        assertEquals(AccessStore.Admission.REMOVED, store.load("k").admission);
    }

    @Test public void unreadablePassIsFlaggedNotDropped() {
        MemoryValues values = new MemoryValues();
        AccessStore.Record record = new AccessStore.Record();
        record.admission = AccessStore.Admission.PENDING; record.pass = PASS;
        new AccessStore(values, new ReverseBox()).save("k", record, 1);
        AccessStore.Record loaded = new AccessStore(values, new BrokenBox()).load("k");
        assertNull(loaded.pass);
        assertTrue(loaded.passUnreadable);
    }

    @Test public void corruptRecordsAreTreatedAsRefused() {
        MemoryValues values = new MemoryValues();
        values.put("share.k", "garbage");
        assertEquals(AccessStore.Admission.DECLINED, new AccessStore(values, new ReverseBox()).load("k").admission);
        values.put("share.j", "v1|NOT_A_STATE|0|0|0|0|");
        assertEquals(AccessStore.Admission.DECLINED, new AccessStore(values, new ReverseBox()).load("j").admission);
    }

    @Test public void sealFailureIsStoredAsUnreadableNotAsNoPass() {
        MemoryValues values = new MemoryValues();
        AccessStore.Record record = new AccessStore.Record();
        record.admission = AccessStore.Admission.PENDING; record.pass = PASS; record.asks = 1;
        assertTrue(new AccessStore(values, new NoSealBox()).save("k", record, 1));
        assertFalse(values.map.get("share.k").contains(PASS));
        AccessStore.Record loaded = new AccessStore(values, new ReverseBox()).load("k");
        assertNull(loaded.pass);
        assertTrue("a pass that could not be sealed must read back as unreadable", loaded.passUnreadable);
    }

    @Test public void failedWritesAreReported() {
        MemoryValues values = new MemoryValues();
        AccessStore store = new AccessStore(values, new ReverseBox());
        AccessStore.Record record = new AccessStore.Record();
        record.asks = 1; record.lastAskAt = 5;
        values.failWrites = true;
        assertFalse(store.save("k", record, 1));
        assertFalse(store.refuse("k", AccessStore.Admission.DECLINED, 2));
        values.failWrites = false;
        values.dropWrites = true;
        assertTrue("the write itself claims success", store.save("k", record, 3));
        assertFalse("reading back catches a write that did not land", store.saveVerified("k", record, 4));
        values.dropWrites = false;
        assertTrue(store.saveVerified("k", record, 5));
    }

    @Test public void boundEvictsOnlyOldNonRefusals() {
        MemoryValues values = new MemoryValues();
        AccessStore store = new AccessStore(values, new ReverseBox());
        assertTrue(store.refuse("refused-first", AccessStore.Admission.DECLINED, 1));
        for (int i = 0; i < AccessStore.MAX_RECORDS + 10; i++) {
            AccessStore.Record record = new AccessStore.Record();
            record.asks = 1;
            assertTrue(store.save("k" + i, record, 1000 + i));
        }
        assertEquals(AccessStore.MAX_RECORDS, values.keys().size());
        assertEquals("a refusal survives any number of newer shares", AccessStore.Admission.DECLINED, store.load("refused-first").admission);
        assertNull("the oldest ordinary record went first", values.get("share.k0"));
        assertNotNull(values.get("share.k" + (AccessStore.MAX_RECORDS + 9)));
    }

    @Test public void boundFailsClosedWhenOnlyRefusalsRemain() {
        MemoryValues values = new MemoryValues();
        AccessStore store = new AccessStore(values, new ReverseBox());
        for (int i = 0; i < AccessStore.MAX_RECORDS; i++) assertTrue(store.refuse("r" + i, AccessStore.Admission.REMOVED, i));
        AccessStore.Record fresh = new AccessStore.Record();
        fresh.asks = 1;
        assertFalse("no room without evicting a refusal: refuse the write", store.save("new", fresh, 99_999));
        assertFalse(store.saveVerified("new", fresh, 99_999));
        assertNull(values.get("share.new"));
        for (int i = 0; i < AccessStore.MAX_RECORDS; i++) assertEquals(AccessStore.Admission.REMOVED, store.load("r" + i).admission);
        assertTrue("an existing record can still be updated", store.refuse("r0", AccessStore.Admission.REMOVED, 100_000));
    }
}
