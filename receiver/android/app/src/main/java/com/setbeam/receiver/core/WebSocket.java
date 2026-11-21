package com.setbeam.receiver.core;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The small client side of RFC 6455 the Mac's presence channel needs: one text message at a time,
 * masked client frames, ping/pong and close. Bounded: a message larger than {@link #MAX_MESSAGE}
 * ends the connection.
 */
final class WebSocket implements Closeable {
    static final int MAX_MESSAGE = 16 * 1024;
    private static final String GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private static final SecureRandom RANDOM = new SecureRandom();

    private final MiniHttp.Upgraded connection;
    private final MiniHttp.Call call;
    private final InputStream in;
    private final OutputStream out;
    private boolean closeSent;
    /** System.nanoTime() of the last complete frame received, including pongs. */
    private volatile long lastFrameNanos = System.nanoTime();
    /** System.nanoTime() of the last frame sent. */
    private volatile long lastSentNanos = System.nanoTime();

    private WebSocket(MiniHttp.Upgraded connection, MiniHttp.Call call) {
        this.connection = connection; this.call = call; this.in = connection.in; this.out = connection.out;
    }

    /** Opens a channel. {@code origin} is sent as the page origin the Mac expects for its own host. */
    static WebSocket connect(MiniHttp.Route route, String target, String origin, int deadlineMs, MiniHttp.Call call) throws IOException {
        byte[] nonce = new byte[16];
        RANDOM.nextBytes(nonce);
        String key = Base64.getEncoder().encodeToString(nonce);
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Upgrade", "websocket");
        headers.put("Connection", "Upgrade");
        headers.put("Sec-WebSocket-Version", "13");
        headers.put("Sec-WebSocket-Key", key);
        headers.put("Origin", origin);
        MiniHttp.Upgraded upgraded = MiniHttp.upgrade(route, target, headers, deadlineMs, call);
        String accept = upgraded.headers.get("sec-websocket-accept");
        if (accept == null || !accept.equals(acceptKey(key))) {
            call.cancel();
            throw new IOException("Invalid WebSocket handshake");
        }
        return new WebSocket(upgraded, call);
    }

    static String acceptKey(String key) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-1").digest((key + GUID).getBytes(StandardCharsets.ISO_8859_1));
            return Base64.getEncoder().encodeToString(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** How long one read may wait before {@link SocketTimeoutException}. */
    void setReadTimeout(int ms) throws IOException { connection.socket.setSoTimeout(ms); }

    /**
     * The next text message, or null when the server closed the channel. Pings are answered;
     * pongs and binary messages are skipped. {@link SocketTimeoutException} is thrown only while
     * waiting between messages, so the caller may send a ping and read again.
     */
    String readText() throws IOException {
        ByteArrayOutputStream message = new ByteArrayOutputStream();
        boolean collecting = false, text = false;
        while (true) {
            int first;
            try { first = in.read(); }
            catch (SocketTimeoutException e) { if (collecting) throw new IOException("Timed out mid-message"); throw e; }
            if (first < 0) return null;
            int second = readByte();
            boolean fin = (first & 0x80) != 0;
            if ((first & 0x70) != 0) throw new IOException("Unexpected WebSocket extension");
            int opcode = first & 0x0F;
            if ((second & 0x80) != 0) throw new IOException("Masked server frame");
            long length = second & 0x7F;
            if (length == 126) length = (readByte() << 8) | readByte();
            else if (length == 127) {
                length = 0;
                for (int i = 0; i < 8; i++) length = (length << 8) | readByte();
            }
            if (length < 0 || length > MAX_MESSAGE) throw new IOException("WebSocket message too large");
            byte[] payload = readFully((int) length);
            lastFrameNanos = System.nanoTime();
            switch (opcode) {
                case 0x8:
                    sendClose();
                    return null;
                case 0x9:
                    if (length > 125) throw new IOException("Invalid ping");
                    send(0xA, payload);
                    continue;
                case 0xA:
                    continue;
                case 0x0:
                    if (!collecting) throw new IOException("Unexpected continuation");
                    break;
                case 0x1: case 0x2:
                    if (collecting) throw new IOException("Interleaved message");
                    collecting = true; text = opcode == 0x1;
                    break;
                default:
                    throw new IOException("Unknown WebSocket opcode");
            }
            message.write(payload);
            if (message.size() > MAX_MESSAGE) throw new IOException("WebSocket message too large");
            if (fin) {
                if (text) return message.toString("UTF-8");
                message.reset(); collecting = false;
            }
        }
    }

    long lastFrameNanos() { return lastFrameNanos; }

    long lastSentNanos() { return lastSentNanos; }

    void sendText(String text) throws IOException { send(0x1, text.getBytes(StandardCharsets.UTF_8)); }

    void sendPing() throws IOException { send(0x9, new byte[0]); }

    private synchronized void send(int opcode, byte[] payload) throws IOException {
        if (closeSent) throw new IOException("closed");
        if (payload.length > MAX_MESSAGE) throw new IOException("WebSocket message too large");
        ByteArrayOutputStream frame = new ByteArrayOutputStream(payload.length + 14);
        frame.write(0x80 | opcode);
        if (payload.length < 126) frame.write(0x80 | payload.length);
        else { frame.write(0x80 | 126); frame.write(payload.length >> 8); frame.write(payload.length & 0xFF); }
        byte[] mask = new byte[4];
        RANDOM.nextBytes(mask);
        frame.write(mask, 0, 4);
        for (int i = 0; i < payload.length; i++) frame.write(payload[i] ^ mask[i & 3]);
        out.write(frame.toByteArray());
        out.flush();
        lastSentNanos = System.nanoTime();
        if (opcode == 0x8) closeSent = true;
    }

    private void sendClose() {
        try { send(0x8, new byte[0]); } catch (IOException ignored) { }
    }

    private int readByte() throws IOException {
        int b;
        try { b = in.read(); } catch (SocketTimeoutException e) { throw new IOException("Timed out mid-frame"); }
        if (b < 0) throw new EOFException("Closed mid-frame");
        return b;
    }

    private byte[] readFully(int length) throws IOException {
        byte[] data = new byte[length];
        int read = 0;
        while (read < length) {
            int n;
            try { n = in.read(data, read, length - read); } catch (SocketTimeoutException e) { throw new IOException("Timed out mid-frame"); }
            if (n < 0) throw new EOFException("Closed mid-frame");
            read += n;
        }
        return data;
    }

    @Override public void close() {
        sendClose();
        call.cancel();
    }
}
