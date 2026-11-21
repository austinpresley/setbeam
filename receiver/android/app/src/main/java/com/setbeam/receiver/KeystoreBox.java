package com.setbeam.receiver;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import com.setbeam.receiver.core.AccessStore;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Seals per-share passes with a non-exportable AES-GCM key in the Android Keystore. If the key is
 * lost, a stored pass becomes unreadable; the controller then waits for the TV user instead of
 * sending a new request on its own. Refusals never depend on this key.
 */
final class KeystoreBox implements AccessStore.SecretBox {
    private static final String ALIAS = "setbeam-receiver-pass-v1";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";

    private static synchronized SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        KeyStore.Entry entry = store.getEntry(ALIAS, null);
        if (entry instanceof KeyStore.SecretKeyEntry) return ((KeyStore.SecretKeyEntry) entry).getSecretKey();
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return generator.generateKey();
    }

    @Override public String seal(String plain) throws Exception {
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.ENCRYPT_MODE, key());
        byte[] iv = cipher.getIV();
        byte[] sealed = cipher.doFinal(plain.getBytes(StandardCharsets.UTF_8));
        ByteBuffer out = ByteBuffer.allocate(1 + iv.length + sealed.length);
        out.put((byte) iv.length).put(iv).put(sealed);
        return Base64.encodeToString(out.array(), Base64.NO_WRAP);
    }

    @Override public String open(String value) throws Exception {
        ByteBuffer in = ByteBuffer.wrap(Base64.decode(value, Base64.NO_WRAP));
        int ivLength = in.get() & 0xff;
        if (ivLength < 12 || ivLength > 16) throw new IllegalArgumentException("iv");
        byte[] iv = new byte[ivLength];
        in.get(iv);
        byte[] sealed = new byte[in.remaining()];
        in.get(sealed);
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, iv));
        return new String(cipher.doFinal(sealed), StandardCharsets.UTF_8);
    }
}
