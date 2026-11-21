package com.setbeam.receiver.core;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * A small, bounded HTTP/1.1 client for the Setbeam gateway and WHEP endpoint.
 *
 * <p>It connects to an explicit address while sending an explicit {@code Host}, so a Mac found by
 * DNS-SD is reached at the address that was actually matched, and every later URL can be checked
 * against it. Every request has a total deadline, bounded headers and bodies, no redirects, no
 * connection reuse, and can be cancelled from another thread. HTTPS uses the platform trust store
 * and hostname verification; there is no way to disable either.
 */
public final class MiniHttp {
    public static final int MAX_HEADER = 16 * 1024;
    public static final String USER_AGENT = "SetbeamReceiver/0.2 (Android TV)";

    private MiniHttp() {}

    /** Verifies an HTTPS peer for a host name. Android supplies the platform verifier. */
    public interface HostnameCheck { boolean verify(String host, SSLSession session); }
    private static volatile HostnameCheck hostnameCheck = null;
    public static void setHostnameCheck(HostnameCheck check) { hostnameCheck = check; }

    /** Where to connect and what to call the server. */
    public static final class Route {
        public final String scheme;
        public final InetAddress address;
        public final int port;
        /** The {@code Host} header value, including a non-default port. */
        public final String hostHeader;
        /** The name HTTPS certificates are checked against. */
        public final String tlsHost;

        public Route(String scheme, InetAddress address, int port, String hostHeader, String tlsHost) {
            if (!scheme.equals("http") && !scheme.equals("https")) throw new IllegalArgumentException("scheme");
            this.scheme = scheme; this.address = address; this.port = port; this.hostHeader = hostHeader; this.tlsHost = tlsHost;
        }

        /** The same server and name on another port, as a redirect to the gateway requires. */
        public Route withPort(int newPort, String newHostHeader) { return new Route(scheme, address, newPort, newHostHeader, tlsHost); }

        @Override public String toString() { return scheme + "://" + address.getHostAddress() + ":" + port + " (Host: " + hostHeader + ")"; }
    }

    public static final class Response {
        public final int status;
        public final Map<String, String> headers;
        public final byte[] body;
        Response(int status, Map<String, String> headers, byte[] body) { this.status = status; this.headers = headers; this.body = body; }
        public String header(String name) { return headers.get(name.toLowerCase(Locale.ROOT)); }
        public String text() { return new String(body, StandardCharsets.UTF_8); }
    }

    /** A cancellable request. Cancelling closes its socket, which ends any blocked read at once. */
    public static final class Call implements Closeable {
        private Socket socket;
        private boolean cancelled;
        synchronized void attach(Socket value) throws IOException {
            if (cancelled) { closeQuietly(value); throw new InterruptedIOException("cancelled"); }
            socket = value;
        }
        public synchronized boolean isCancelled() { return cancelled; }
        public void cancel() {
            Socket current;
            synchronized (this) { cancelled = true; current = socket; socket = null; }
            closeQuietly(current);
        }
        @Override public void close() { cancel(); }
    }

    /** A response whose body is read incrementally, for server-sent events. */
    public static final class Stream implements Closeable {
        public final int status;
        public final Map<String, String> headers;
        private final Call call;
        private final InputStream in;
        private final int lineLimit;
        Stream(int status, Map<String, String> headers, Call call, InputStream in, int lineLimit) {
            this.status = status; this.headers = headers; this.call = call; this.in = in; this.lineLimit = lineLimit;
        }
        /** The next line without its terminator, or null at the end of the stream. */
        public String readLine() throws IOException {
            ByteArrayOutputStream line = new ByteArrayOutputStream();
            while (true) {
                int b = in.read();
                if (b < 0) return line.size() == 0 ? null : line.toString("UTF-8");
                if (b == '\n') {
                    String text = line.toString("UTF-8");
                    return text.endsWith("\r") ? text.substring(0, text.length() - 1) : text;
                }
                line.write(b);
                if (line.size() > lineLimit) throw new IOException("Line too long");
            }
        }
        @Override public void close() { call.cancel(); }
    }

    public static Response execute(Route route, String method, String target, Map<String, String> headers, byte[] body,
                                   int deadlineMs, int maxBody, Call call) throws IOException {
        long deadline = System.nanoTime() + deadlineMs * 1_000_000L;
        Socket socket = open(route, deadline, call);
        try {
            writeRequest(socket.getOutputStream(), route, method, target, headers, body);
            InputStream in = new BufferedInputStream(new DeadlineInput(socket, deadline));
            Head head = readHead(in);
            byte[] content;
            if (method.equals("HEAD") || head.status == 204 || head.status == 304 || head.status / 100 == 1) content = new byte[0];
            else content = readBody(in, head.headers, maxBody);
            return new Response(head.status, head.headers, content);
        } catch (IOException e) {
            if (call != null && call.isCancelled()) throw new InterruptedIOException("cancelled");
            throw e;
        } finally {
            closeQuietly(socket);
            if (call != null) call.cancel();
        }
    }

    /**
     * Opens a long-lived GET. The connect and response header must arrive within
     * {@code headerDeadlineMs}; afterwards each read waits at most {@code idleMs}.
     */
    public static Stream openStream(Route route, String target, int headerDeadlineMs, int idleMs, Call call) throws IOException {
        long deadline = System.nanoTime() + headerDeadlineMs * 1_000_000L;
        Socket socket = open(route, deadline, call);
        try {
            writeRequest(socket.getOutputStream(), route, "GET", target, Map.of("Accept", "text/event-stream"), null);
            Head head = readHead(new DeadlineInput(socket, deadline));
            if (head.headers.containsKey("transfer-encoding")) throw new IOException("Unsupported stream encoding");
            socket.setSoTimeout(idleMs);
            return new Stream(head.status, head.headers, call, new BufferedInputStream(socket.getInputStream()), 16 * 1024);
        } catch (IOException e) {
            call.cancel();
            throw e;
        }
    }

    /** A connection that switched protocols (101), positioned after the response header. */
    static final class Upgraded {
        final Socket socket; final InputStream in; final OutputStream out; final Map<String, String> headers;
        Upgraded(Socket socket, InputStream in, OutputStream out, Map<String, String> headers) {
            this.socket = socket; this.in = in; this.out = out; this.headers = headers;
        }
    }

    /**
     * Sends a GET with upgrade headers. Returns the connection on 101, otherwise throws with the
     * status. The connect and response header must arrive within {@code deadlineMs}.
     */
    static Upgraded upgrade(Route route, String target, Map<String, String> headers, int deadlineMs, Call call) throws IOException {
        long deadline = System.nanoTime() + deadlineMs * 1_000_000L;
        Socket socket = open(route, deadline, call);
        try {
            writeRequest(socket.getOutputStream(), route, "GET", target, headers, null);
            InputStream in = new BufferedInputStream(socket.getInputStream());
            socket.setSoTimeout(remaining(deadline));
            Head head = readHead(in);
            if (head.status != 101) throw new UpgradeRefused(head.status);
            return new Upgraded(socket, in, new java.io.BufferedOutputStream(socket.getOutputStream()), head.headers);
        } catch (IOException e) {
            boolean cancelled = call.isCancelled();
            call.cancel();
            if (cancelled) throw new InterruptedIOException("cancelled");
            throw e;
        }
    }

    /** The server answered an upgrade with an ordinary status, such as 503 when the feature is off. */
    static final class UpgradeRefused extends IOException {
        final int status;
        UpgradeRefused(int status) { super("Upgrade refused: " + status); this.status = status; }
    }

    private static Socket open(Route route, long deadline, Call call) throws IOException {
        Socket plain = new Socket();
        if (call != null) call.attach(plain);
        try {
            plain.setTcpNoDelay(true);
            plain.connect(new InetSocketAddress(route.address, route.port), remaining(deadline));
            if (!route.scheme.equals("https")) return plain;
            SSLSocket tls = (SSLSocket) ((SSLSocketFactory) SSLSocketFactory.getDefault()).createSocket(plain, route.tlsHost, route.port, true);
            if (call != null) call.attach(tls);
            SSLParameters parameters = tls.getSSLParameters();
            parameters.setEndpointIdentificationAlgorithm("HTTPS");
            tls.setSSLParameters(parameters);
            tls.setSoTimeout(remaining(deadline));
            tls.startHandshake();
            HostnameCheck check = hostnameCheck;
            if (check != null && !check.verify(route.tlsHost, tls.getSession())) {
                closeQuietly(tls);
                throw new IOException("The HTTPS certificate does not match " + route.tlsHost);
            }
            return tls;
        } catch (IOException e) {
            closeQuietly(plain);
            throw e;
        }
    }

    private static void writeRequest(OutputStream out, Route route, String method, String target,
                                     Map<String, String> headers, byte[] body) throws IOException {
        if (!target.startsWith("/") || target.length() > 2000 || hasLineBreak(target)) throw new IOException("Invalid request target");
        StringBuilder request = new StringBuilder();
        request.append(method).append(' ').append(target).append(" HTTP/1.1\r\n");
        request.append("Host: ").append(route.hostHeader).append("\r\n");
        request.append("User-Agent: ").append(USER_AGENT).append("\r\n");
        if (headers == null || !headers.containsKey("Connection")) request.append("Connection: close\r\n");
        if (headers != null) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                if (hasLineBreak(entry.getKey()) || hasLineBreak(entry.getValue())) throw new IOException("Invalid header");
                request.append(entry.getKey()).append(": ").append(entry.getValue()).append("\r\n");
            }
        }
        if (body != null) request.append("Content-Length: ").append(body.length).append("\r\n");
        request.append("\r\n");
        out.write(request.toString().getBytes(StandardCharsets.UTF_8));
        if (body != null) out.write(body);
        out.flush();
    }

    private static boolean hasLineBreak(String value) { return value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0; }

    private static final class Head {
        final int status; final Map<String, String> headers;
        Head(int status, Map<String, String> headers) { this.status = status; this.headers = headers; }
    }

    private static Head readHead(InputStream in) throws IOException {
        ByteArrayOutputStream raw = new ByteArrayOutputStream();
        int matched = 0;
        while (matched < 4) {
            int b = in.read();
            if (b < 0) throw new IOException(raw.size() == 0 ? "Closed without a reply" : "Incomplete response");
            raw.write(b);
            if (raw.size() > MAX_HEADER) throw new IOException("Response header too large");
            matched = (b == (matched % 2 == 0 ? '\r' : '\n')) ? matched + 1 : (b == '\r' ? 1 : 0);
        }
        String[] lines = raw.toString("ISO-8859-1").split("\r\n");
        String[] status = lines[0].split(" ", 3);
        if (status.length < 2 || !status[0].startsWith("HTTP/1.")) throw new IOException("Not an HTTP response");
        int code;
        try { code = Integer.parseInt(status[1]); } catch (NumberFormatException e) { throw new IOException("Invalid status"); }
        if (code < 100 || code > 599) throw new IOException("Invalid status");
        Map<String, String> headers = new LinkedHashMap<>();
        for (int i = 1; i < lines.length; i++) {
            int colon = lines[i].indexOf(':');
            if (colon <= 0) continue;
            headers.put(lines[i].substring(0, colon).trim().toLowerCase(Locale.ROOT), lines[i].substring(colon + 1).trim());
        }
        return new Head(code, headers);
    }

    private static byte[] readBody(InputStream in, Map<String, String> headers, int maxBody) throws IOException {
        String encoding = headers.get("transfer-encoding");
        if (encoding != null) {
            if (!encoding.equalsIgnoreCase("chunked")) throw new IOException("Unsupported transfer encoding");
            return readChunked(in, maxBody);
        }
        String length = headers.get("content-length");
        if (length != null) {
            long size;
            try { size = Long.parseLong(length.trim()); } catch (NumberFormatException e) { throw new IOException("Invalid length"); }
            if (size < 0 || size > maxBody) throw new IOException("Response too large");
            byte[] body = new byte[(int) size];
            int read = 0;
            while (read < size) {
                int n = in.read(body, read, body.length - read);
                if (n < 0) throw new IOException("Response ended early");
                read += n;
            }
            return body;
        }
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int n;
        while ((n = in.read(buffer)) >= 0) {
            body.write(buffer, 0, n);
            if (body.size() > maxBody) throw new IOException("Response too large");
        }
        return body.toByteArray();
    }

    private static byte[] readChunked(InputStream in, int maxBody) throws IOException {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        while (true) {
            String sizeLine = readCrlfLine(in, 256);
            int semicolon = sizeLine.indexOf(';');
            String hex = (semicolon >= 0 ? sizeLine.substring(0, semicolon) : sizeLine).trim();
            long size;
            try { size = Long.parseLong(hex, 16); } catch (NumberFormatException e) { throw new IOException("Invalid chunk"); }
            if (size < 0 || body.size() + size > maxBody) throw new IOException("Response too large");
            if (size == 0) {
                // Trailers, if any, end with an empty line.
                while (!readCrlfLine(in, 1024).isEmpty()) { /* skip */ }
                return body.toByteArray();
            }
            for (long i = 0; i < size; i++) {
                int b = in.read();
                if (b < 0) throw new IOException("Response ended early");
                body.write(b);
            }
            if (!readCrlfLine(in, 2).isEmpty()) throw new IOException("Invalid chunk");
        }
    }

    private static String readCrlfLine(InputStream in, int limit) throws IOException {
        StringBuilder line = new StringBuilder();
        while (true) {
            int b = in.read();
            if (b < 0) throw new IOException("Response ended early");
            if (b == '\n') {
                int end = line.length();
                if (end > 0 && line.charAt(end - 1) == '\r') line.setLength(end - 1);
                return line.toString();
            }
            line.append((char) b);
            if (line.length() > limit) throw new IOException("Invalid chunk");
        }
    }

    static int remaining(long deadline) throws SocketTimeoutException {
        long ms = (deadline - System.nanoTime()) / 1_000_000L;
        if (ms <= 0) throw new SocketTimeoutException("Request deadline passed");
        return (int) Math.min(Integer.MAX_VALUE, ms);
    }

    /** Applies the request's total deadline to every read. */
    private static final class DeadlineInput extends InputStream {
        private final Socket socket; private final InputStream in; private final long deadline;
        private final byte[] one = new byte[1];
        DeadlineInput(Socket socket, long deadline) throws IOException { this.socket = socket; this.in = socket.getInputStream(); this.deadline = deadline; }
        @Override public int read() throws IOException { int n = read(one, 0, 1); return n < 0 ? -1 : (one[0] & 0xff); }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            socket.setSoTimeout(remaining(deadline));
            return in.read(b, off, len);
        }
    }

    static void closeQuietly(Closeable closeable) {
        if (closeable == null) return;
        try { closeable.close(); } catch (IOException ignored) { }
    }
}
