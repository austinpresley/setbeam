package com.setbeam.receiver.core;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ConcurrentHashMap;

/** A loopback HTTP/1.1 server whose responses tests script per request. */
final class TestServer implements AutoCloseable {
    static final class Request {
        String method, target; Map<String, String> headers = new ConcurrentHashMap<>(); byte[] body = new byte[0];
        String header(String name) { return headers.get(name.toLowerCase(Locale.ROOT)); }
        String text() { return new String(body, StandardCharsets.UTF_8); }
    }
    interface Handler { void handle(Request request, OutputStream out) throws Exception; }

    final ServerSocket socket;
    final List<Request> requests = new CopyOnWriteArrayList<>();
    private volatile Handler handler;

    TestServer(Handler handler) throws IOException {
        this.handler = handler;
        socket = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
        Thread accept = new Thread(() -> {
            while (!socket.isClosed()) {
                try {
                    Socket client = socket.accept();
                    new Thread(() -> serve(client)).start();
                } catch (IOException e) { return; }
            }
        });
        accept.setDaemon(true);
        accept.start();
    }

    void setHandler(Handler value) { handler = value; }
    int port() { return socket.getLocalPort(); }

    private void serve(Socket client) {
        try (Socket c = client) {
            InputStream in = c.getInputStream();
            ByteArrayOutputStream head = new ByteArrayOutputStream();
            int matched = 0;
            while (matched < 4) {
                int b = in.read();
                if (b < 0) return;
                head.write(b);
                matched = (b == (matched % 2 == 0 ? '\r' : '\n')) ? matched + 1 : (b == '\r' ? 1 : 0);
            }
            String[] lines = head.toString("ISO-8859-1").split("\r\n");
            Request request = new Request();
            String[] first = lines[0].split(" ");
            request.method = first[0]; request.target = first[1];
            for (int i = 1; i < lines.length; i++) {
                int colon = lines[i].indexOf(':');
                if (colon > 0) request.headers.put(lines[i].substring(0, colon).trim().toLowerCase(Locale.ROOT), lines[i].substring(colon + 1).trim());
            }
            String length = request.header("content-length");
            if (length != null) {
                byte[] body = new byte[Integer.parseInt(length)];
                int read = 0;
                while (read < body.length) { int n = in.read(body, read, body.length - read); if (n < 0) break; read += n; }
                request.body = body;
            }
            requests.add(request);
            handler.handle(request, c.getOutputStream());
            c.getOutputStream().flush();
        } catch (Exception ignored) { }
    }

    static void respond(OutputStream out, int status, String contentType, String body, String... headers) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        StringBuilder text = new StringBuilder("HTTP/1.1 " + status + " X\r\n");
        if (contentType != null) text.append("Content-Type: ").append(contentType).append("\r\n");
        text.append("Content-Length: ").append(bytes.length).append("\r\nConnection: close\r\n");
        for (String header : headers) text.append(header).append("\r\n");
        text.append("\r\n");
        out.write(text.toString().getBytes(StandardCharsets.UTF_8));
        out.write(bytes);
    }

    @Override public void close() throws IOException { socket.close(); }
}
