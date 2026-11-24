package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import org.json.JSONArray;
import org.junit.Test;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Collections;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Chat parsing, pointer parsing, nearby-Mac choices, and the presence WebSocket on the wire. */
public class ExtrasProtocolTest {

    // ---- Chat ----

    @Test public void chatParsesCleansAndBounds() throws Exception {
        JSONArray array = new JSONArray("[" +
                "{\"id\":2,\"name\":\"Dir\\u202Eector\",\"color\":\"red\",\"operatorMessage\":false,\"text\":\"Look \\u202Eleft\\r\\nnow\",\"sentAt\":1,\"hasFrame\":false,\"reactions\":[{\"reaction\":\"heart\",\"count\":2,\"selected\":false},{\"reaction\":\"bogus\",\"count\":1}]}," +
                "{\"id\":1,\"name\":\"DigiTech\",\"color\":\"nope\",\"operatorMessage\":true,\"text\":\"\",\"hasFrame\":true,\"sampleFrame\":true}," +
                "{\"id\":0,\"text\":\"no id\"}," +
                "{\"id\":3,\"text\":\"\",\"hasFrame\":false}," +
                "\"junk\"]");
        List<ChatLine> lines = ChatLine.parse(array);
        assertEquals(2, lines.size());
        assertEquals("sorted by id", 1, lines.get(0).id);
        assertEquals("blue", lines.get(0).color);
        assertTrue(lines.get(0).operator);
        assertEquals("[Shared a SAMPLE MEDIA frame]", lines.get(0).display());
        ChatLine second = lines.get(1);
        assertEquals("Director", second.name);
        assertEquals("Look left\nnow", second.text);
        assertEquals("❤️ 2", second.reactions);

        StringBuilder many = new StringBuilder("[");
        for (int i = 1; i <= 150; i++) many.append(i > 1 ? "," : "").append("{\"id\":").append(i).append(",\"text\":\"").append("x".repeat(2000)).append("\"}");
        List<ChatLine> bounded = ChatLine.parse(new JSONArray(many.append("]").toString()));
        assertEquals(ChatLine.MAX_MESSAGES, bounded.size());
        assertEquals(51, bounded.get(0).id);
        assertEquals(ChatLine.MAX_TEXT, bounded.get(0).text.length());
    }

    @Test public void chatKeepsEvictedAttachmentsAndReadsLegacyArraysNearTheBodyLimit() throws Exception {
        JSONArray messages = new JSONArray();
        for (int i = 1; i <= 97; i++) {
            messages.put(new org.json.JSONObject().put("id", i).put("text", "x".repeat(10_000)));
        }
        messages.put(new org.json.JSONObject().put("id", 98).put("hasFrame", false).put("hadFrame", true));
        messages.put(new org.json.JSONObject().put("id", 99).put("hasFrame", false).put("hadFrame", true).put("sampleFrame", true));
        messages.put(new org.json.JSONObject().put("id", 100).put("hasFrame", true));
        String body = messages.toString();
        assertTrue(body.length() > HttpGateway.MAX_CHAT_BODY * 0.9);
        try (TestServer server = new TestServer((request, out) -> TestServer.respond(out, 200, "application/json", body))) {
            AskPath path = askPath(server.port());
            Gateway.ChatResult result = new HttpGateway(h -> List.of()).chat(path, HttpGatewayTest.PASS, new Gateway.Scope());
            assertEquals(Gateway.Status.OK, result.status);
            assertEquals(100, result.messages.size());
            assertEquals("[Shared frame no longer available]", result.messages.get(97).display());
            assertEquals("[SAMPLE MEDIA frame no longer available]", result.messages.get(98).display());
            assertEquals("[Shared a frame]", result.messages.get(99).display());
            assertEquals("GET", server.requests.get(0).method);
            assertEquals(path.endpoint("chat"), server.requests.get(0).target);
        }
    }

    // ---- Pointers ----

    @Test public void pointersAreClampedValidatedAndBounded() throws Exception {
        JSONArray items = new JSONArray("[" +
                "{\"n\":2,\"label\":\"A\",\"color\":\"lime\",\"x\":1.5,\"y\":-1,\"ttl\":60000}," +
                "{\"n\":3,\"label\":\"B\",\"color\":\"x\",\"x\":\"0.5\",\"y\":0.5,\"ttl\":1000}," +
                "{\"n\":4,\"label\":\"C\",\"x\":0.5,\"y\":0.5,\"ttl\":0}," +
                "{\"n\":5,\"label\":\"\",\"x\":0.1,\"y\":0.2,\"ttl\":500}]");
        List<Pointer> pointers = Pointer.parse(items, 100);
        assertEquals(2, pointers.size());
        assertEquals(1.0, pointers.get(0).x, 0);
        assertEquals(0.0, pointers.get(0).y, 0);
        assertEquals("ttl is capped", 100 + Pointer.MAX_TTL_MS, pointers.get(0).expiresAt);
        assertTrue(Pointer.darkText("lime"));
        assertEquals("Viewer", pointers.get(1).label);
        assertEquals("blue", Pointer.validColor("x"));

        StringBuilder many = new StringBuilder("[");
        for (int i = 0; i < 40; i++) many.append(i > 0 ? "," : "").append("{\"n\":").append(i).append(",\"x\":0.5,\"y\":0.5,\"ttl\":1000}");
        assertEquals(Pointer.MAX_POINTERS, Pointer.parse(new JSONArray(many.append("]").toString()), 0).size());
    }

    // ---- Nearby Macs ----

    static HostMatcher.Service service(String instance, String ipv4, String host, String v, String path) {
        Map<String, String> txt = new HashMap<>();
        if (host != null) txt.put("host", host);
        if (v != null) txt.put("v", v);
        if (path != null) txt.put("path", path);
        return new HostMatcher.Service(instance, ipv4, 80, txt);
    }

    @Test public void nearbyMacsPreferTheAdvertisedNameAndDropOthers() {
        List<NearbyMacs.Choice> choices = NearbyMacs.choices(List.of(
                service("Stage", "192.168.1.20", "stage-mac.local", "1", "/"),
                service("Stage copy", "192.168.1.21", "stage-mac.local", "1", "/"),
                service("Bad name", "192.168.1.30", "bad name!", "1", "/"),
                service("Old version", "192.168.1.40", "old.local", "2", "/"),
                service("Other path", "192.168.1.41", "path.local", "1", "/s/x/"),
                service("No address", null, "Edit-Bay.local", "1", "/"),
                new HostMatcher.Service("Other port", "192.168.1.50", 8080, Map.of("v", "1", "path", "/", "host", "port.local"))));
        assertEquals(3, choices.size());
        assertEquals("192.168.1.30", choices.get(0).title);
        assertEquals("http://192.168.1.30/", choices.get(0).address);
        assertEquals("edit-bay.local", choices.get(1).title);
        assertEquals("http://edit-bay.local/", choices.get(1).address);
        assertEquals("", choices.get(1).detail);
        assertEquals("http://stage-mac.local/", choices.get(2).address);
        assertEquals("192.168.1.20", choices.get(2).detail);
        for (NearbyMacs.Choice choice : choices) {
            try { HostConfig.parse(choice.address, "TV"); } catch (HostConfig.Invalid e) { fail(choice.address); }
        }
    }

    // ---- Presence channel on the wire ----

    /** A one-connection WebSocket server that runs a scripted exchange. */
    static final class WsServer implements AutoCloseable {
        final ServerSocket socket = new ServerSocket(0, 5, InetAddress.getByName("127.0.0.1"));
        final Map<String, String> headers = new HashMap<>();
        final List<String> received = Collections.synchronizedList(new ArrayList<>());
        final AtomicReference<Throwable> error = new AtomicReference<>();
        final CountDownLatch done = new CountDownLatch(1);
        interface Script { void run(InputStream in, OutputStream out) throws Exception; }
        WsServer(int status, Script script) throws IOException {
            Thread thread = new Thread(() -> {
                try (Socket client = socket.accept()) {
                    InputStream in = client.getInputStream(); OutputStream out = client.getOutputStream();
                    ByteArrayOutputStream head = new ByteArrayOutputStream();
                    int matched = 0;
                    while (matched < 4) { int b = in.read(); if (b < 0) return; head.write(b); matched = (b == (matched % 2 == 0 ? '\r' : '\n')) ? matched + 1 : (b == '\r' ? 1 : 0); }
                    String[] lines = head.toString("ISO-8859-1").split("\r\n");
                    headers.put(":target", lines[0].split(" ")[1]);
                    for (int i = 1; i < lines.length; i++) { int c = lines[i].indexOf(':'); if (c > 0) headers.put(lines[i].substring(0, c).trim().toLowerCase(Locale.ROOT), lines[i].substring(c + 1).trim()); }
                    if (status != 101) { out.write(("HTTP/1.1 " + status + " X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.UTF_8)); out.flush(); return; }
                    out.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
                            + WebSocket.acceptKey(headers.get("sec-websocket-key")) + "\r\n\r\n").getBytes(StandardCharsets.UTF_8));
                    out.flush();
                    script.run(in, out);
                } catch (Throwable t) { error.set(t); }
                finally { done.countDown(); }
            });
            thread.setDaemon(true);
            thread.start();
        }
        int port() { return socket.getLocalPort(); }
        @Override public void close() throws IOException { socket.close(); }

        /** Reads one client frame; asserts it is masked. Returns opcode in [0] and text in [1]. */
        static Object[] readFrame(InputStream in) throws IOException {
            int first = in.read(), second = in.read();
            if (first < 0 || second < 0) return null;
            assertTrue("client frames are masked", (second & 0x80) != 0);
            int length = second & 0x7F;
            if (length == 126) length = (in.read() << 8) | in.read();
            byte[] mask = in.readNBytes(4), payload = in.readNBytes(length);
            for (int i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
            return new Object[]{first & 0x0F, new String(payload, StandardCharsets.UTF_8)};
        }
        static void writeText(OutputStream out, String text) throws IOException {
            byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
            out.write(0x81);
            if (bytes.length < 126) out.write(bytes.length); else { out.write(126); out.write(bytes.length >> 8); out.write(bytes.length & 0xFF); }
            out.write(bytes); out.flush();
        }
    }

    static AskPath askPath(int port) throws Exception {
        MiniHttp.Route root = new MiniHttp.Route("http", InetAddress.getByName("127.0.0.1"), port, "127.0.0.1", "127.0.0.1");
        return AskPath.fromRedirect(root, 302, "http://127.0.0.1:" + port + "/s/" + "c".repeat(64) + "/");
    }

    static final class Recorder implements Gateway.PresenceEvents {
        int welcomes;
        final List<List<Pointer>> pointers = new ArrayList<>();
        final List<Integer> revisions = new ArrayList<>();
        String denied;
        @Override public void welcome() { welcomes++; }
        @Override public void pointers(int revision, List<Pointer> items) { revisions.add(revision); pointers.add(items); }
        @Override public void denied(String reason) { denied = reason; }
    }

    @Test public void presenceSendsOnlyHelloAndReadsPointers() throws Exception {
        try (WsServer server = new WsServer(101, (in, out) -> {
            Object[] hello = WsServer.readFrame(in);
            assertEquals(1, hello[0]);
            WsServer.writeText(out, "{\"t\":\"welcome\",\"n\":3,\"r\":1}");
            // A ping from the Mac must be answered with a pong.
            out.write(new byte[]{(byte) 0x89, 0x02, 'h', 'i'}); out.flush();
            Object[] pong = WsServer.readFrame(in);
            assertEquals(0xA, pong[0]);
            assertEquals("hi", pong[1]);
            WsServer.writeText(out, "{\"t\":\"pointers\",\"r\":1,\"items\":[{\"n\":2,\"label\":\"Director\",\"color\":\"red\",\"x\":0.25,\"y\":0.5,\"ttl\":3000}]}");
            out.write(new byte[]{(byte) 0x88, 0x00}); out.flush();
            Object[] close = WsServer.readFrame(in);
            assertEquals(0x8, close[0]);
            WsServerHolder.hello = (String) hello[1];
        })) {
            AskPath path = askPath(server.port());
            Recorder events = new Recorder();
            new HttpGateway(h -> List.of()).presence(path, "p".repeat(48), "Stage TV", "teal", new Gateway.Scope(), events);
            assertTrue(server.done.await(5, TimeUnit.SECONDS));
            assertNull(server.error.get());
            assertEquals("/s/" + "c".repeat(64) + "/presence", server.headers.get(":target"));
            assertEquals("websocket", server.headers.get("upgrade"));
            assertEquals("Upgrade", server.headers.get("connection"));
            assertEquals("http://127.0.0.1:" + server.port(), server.headers.get("origin"));
            org.json.JSONObject hello = new org.json.JSONObject(WsServerHolder.hello);
            assertEquals("hello", hello.getString("t"));
            assertEquals("p".repeat(48), hello.getString("pass"));
            assertFalse("the receiver never sends a position", hello.has("x"));
            assertEquals(1, events.welcomes);
            assertEquals(1, events.pointers.size());
            assertEquals(List.of(1), events.revisions);
            Pointer pointer = events.pointers.get(0).get(0);
            assertEquals("Director", pointer.label);
            assertEquals("relative ttl until the caller rebases it", 3000, pointer.expiresAt);
        }
    }

    static final class WsServerHolder { static volatile String hello; }

    @Test public void keepsPingingWhileTheMacKeepsSendingPointers() throws Exception {
        // The Mac closes a channel it has not heard from, however busy it is itself. Pings must follow
        // the receiver's own sending, not quiet periods from the Mac.
        int ping = HttpGateway.presencePingMs, read = HttpGateway.presenceReadMs;
        HttpGateway.presencePingMs = 600; HttpGateway.presenceReadMs = 200;
        java.util.concurrent.atomic.AtomicInteger pings = new java.util.concurrent.atomic.AtomicInteger();
        try (WsServer server = new WsServer(101, (in, out) -> {
            WsServer.readFrame(in);
            WsServer.writeText(out, "{\"t\":\"welcome\"}");
            Thread reader = new Thread(() -> {
                try { while (true) { Object[] frame = WsServer.readFrame(in); if (frame == null) return; if ((int) frame[0] == 0x9) pings.incrementAndGet(); } }
                catch (Exception ignored) { }
            });
            reader.setDaemon(true); reader.start();
            long end = System.currentTimeMillis() + 2600;
            while (System.currentTimeMillis() < end) {
                WsServer.writeText(out, "{\"t\":\"pointers\",\"items\":[]}");
                Thread.sleep(100);
            }
            out.write(new byte[]{(byte) 0x88, 0x00}); out.flush();
            Thread.sleep(200);
        })) {
            Recorder events = new Recorder();
            new HttpGateway(h -> List.of()).presence(askPath(server.port()), "p".repeat(48), "TV", "teal", new Gateway.Scope(), events);
            assertTrue(server.done.await(5, TimeUnit.SECONDS));
            assertTrue("busy pointers still left room for pings: " + pings.get(), pings.get() >= 3);
            assertTrue(events.pointers.size() > 10);
        } finally {
            HttpGateway.presencePingMs = ping; HttpGateway.presenceReadMs = read;
        }
    }

    @Test public void presenceReportsPointersOffAndDenials() throws Exception {
        try (WsServer server = new WsServer(503, (in, out) -> { })) {
            Recorder events = new Recorder();
            new HttpGateway(h -> List.of()).presence(askPath(server.port()), "p".repeat(48), "TV", "teal", new Gateway.Scope(), events);
            assertEquals("off", events.denied);
        }
        try (WsServer server = new WsServer(101, (in, out) -> {
            WsServer.readFrame(in);
            WsServer.writeText(out, "{\"t\":\"denied\",\"reason\":\"access\"}");
            out.write(new byte[]{(byte) 0x88, 0x00}); out.flush();
        })) {
            Recorder events = new Recorder();
            new HttpGateway(h -> List.of()).presence(askPath(server.port()), "p".repeat(48), "TV", "teal", new Gateway.Scope(), events);
            assertEquals("access", events.denied);
            assertEquals(0, events.welcomes);
        }
    }

    @Test public void presenceRejectsAWrongHandshakeAndMaskedServerFrames() throws Exception {
        try (ServerSocket raw = new ServerSocket(0, 5, InetAddress.getByName("127.0.0.1"))) {
            Thread thread = new Thread(() -> {
                try (Socket client = raw.accept()) {
                    client.getInputStream().read(new byte[2048]);
                    client.getOutputStream().write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n".getBytes(StandardCharsets.UTF_8));
                    client.getOutputStream().flush();
                    Thread.sleep(500);
                } catch (Exception ignored) { }
            });
            thread.setDaemon(true); thread.start();
            try {
                new HttpGateway(h -> List.of()).presence(askPath(raw.getLocalPort()), "p".repeat(48), "TV", "teal", new Gateway.Scope(), new Recorder());
                fail("accepted a wrong handshake");
            } catch (IOException expected) { }
        }
        try (WsServer server = new WsServer(101, (in, out) -> {
            WsServer.readFrame(in);
            out.write(new byte[]{(byte) 0x81, (byte) 0x82, 1, 2, 3, 4, 'a' ^ 1, 'b' ^ 2}); out.flush();
            Thread.sleep(200);
        })) {
            try {
                new HttpGateway(h -> List.of()).presence(askPath(server.port()), "p".repeat(48), "TV", "teal", new Gateway.Scope(), new Recorder());
                fail("accepted a masked server frame");
            } catch (IOException expected) { }
        }
    }

    @Test public void cancellingTheScopeEndsAWaitingChannel() throws Exception {
        CountDownLatch release = new CountDownLatch(1);
        try (WsServer server = new WsServer(101, (in, out) -> {
            WsServer.readFrame(in);
            WsServer.writeText(out, "{\"t\":\"welcome\"}");
            release.await(5, TimeUnit.SECONDS);
        })) {
            Gateway.Scope scope = new Gateway.Scope();
            Recorder events = new Recorder();
            Thread canceller = new Thread(() -> { try { Thread.sleep(300); } catch (InterruptedException ignored) { } scope.cancel(); });
            canceller.start();
            long started = System.nanoTime();
            try { new HttpGateway(h -> List.of()).presence(askPath(server.port()), "p".repeat(48), "TV", "teal", scope, events); }
            catch (IOException expected) { }
            assertTrue("returned promptly after cancel", (System.nanoTime() - started) / 1_000_000L < 3000);
            assertEquals(1, events.welcomes);
            release.countDown();
        }
    }

    // ---- Chat and heartbeat over HTTP ----

    @Test public void chatSendsThePassAndHeartbeatCarriesTheNewestId() throws Exception {
        try (TestServer server = new TestServer((request, out) -> {
            if (request.target.endsWith("/chat")) TestServer.respond(out, 200, "application/json", "[{\"id\":4,\"name\":\"Dir\",\"text\":\"Hi\"}]");
            else TestServer.respond(out, 200, "application/json", "{\"ok\":true,\"admission\":\"admitted\",\"chatLastID\":4}");
        })) {
            AskPath path = askPath(server.port());
            HttpGateway gateway = new HttpGateway(h -> List.of());
            Gateway.ChatResult chat = gateway.chat(path, "p".repeat(48), new Gateway.Scope());
            assertEquals(Gateway.Status.OK, chat.status);
            assertEquals(1, chat.messages.size());
            TestServer.Request sent = server.requests.get(0);
            assertEquals("GET", sent.method);
            assertEquals("p".repeat(48), sent.header("x-setbeam-pass"));
            Gateway.HeartbeatResult beat = gateway.heartbeat(path, "p".repeat(48), true, "playing", 1, "teal", new Gateway.Scope());
            assertEquals(4, beat.chatLastId);
        }
        try (TestServer server = new TestServer((request, out) -> TestServer.respond(out, 403, "text/plain", ""))) {
            assertEquals(Gateway.Status.NOT_ADMITTED, new HttpGateway(h -> List.of()).chat(askPath(server.port()), "p".repeat(48), new Gateway.Scope()).status);
        }
        try (TestServer server = new TestServer((request, out) -> TestServer.respond(out, 200, "application/json", "{\"ok\":true,\"admission\":\"pending\"}"))) {
            assertEquals(-1, new HttpGateway(h -> List.of()).heartbeat(askPath(server.port()), "p".repeat(48), false, "connecting", -1, "teal", new Gateway.Scope()).chatLastId);
        }
    }
}
