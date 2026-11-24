package com.setbeam.receiver;

import org.junit.Test;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.fail;

public class PairingChangesTest {
    @Test public void failedRetirementBlocksPairingEvenWhenAnotherActivityHasRegistered() {
        PairingChanges.Receiver old = new PairingChanges.Receiver() {
            @Override public boolean stopForChange() { return false; }
            @Override public void resumeAfterChange() { fail("unconfirmed receiver resumed"); }
        };
        PairingChanges.Receiver next = new PairingChanges.Receiver() {
            @Override public boolean stopForChange() { fail("old controller must retire first"); return true; }
            @Override public void resumeAfterChange() { fail("another receiver resumed"); }
        };
        PairingChanges.register(old);
        PairingChanges.register(next);
        try {
            assertFalse(PairingChanges.apply(null, settings -> { fail("pairing changed"); return true; }));
        } finally {
            PairingChanges.unregister(old);
            PairingChanges.unregister(next);
        }
    }
}
