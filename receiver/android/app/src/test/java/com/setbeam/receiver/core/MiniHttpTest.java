package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.Map;

import org.junit.Test;

public class MiniHttpTest {
    static MiniHttp.Route route(TestServer server, String host) throws Exception {
        return new MiniHttp.Route("http", InetAddress.getByName("127.0.0.1"), server.port(), host, host);
    }

    @Test public void sendsExplicitHostAndReadsFixedLengthBody() throws Exception {
        try (TestServer server = new TestServer((r, out) -> TestServer.respond(out, 200, "application/json", "{\"ok\":true}"))) {
            MiniHttp.Response response = MiniHttp.execute(route(server, "setbeam.local"), "POST", "/s/x/join",
                    Map.of("Content-Type", "application/json"), "{}".getBytes(StandardCharsets.UTF_8), 2000, 1024, new MiniHttp.Call());
            assertEquals(200, response.status);
            assertEquals("{\"ok\":true}", response.text());
            TestServer.Request seen = server.requests.get(0);
            assertEquals("setbeam.local", seen.header("host"));
            assertEquals("close", seen.header("connection"));
            assertEquals("2", seen.header("content-length"));
            assertNull("never chunked: the gateway rejects Transfer-Encoding", seen.header("transfer-encoding"));
        }
    }

    @Test public void neverFollowsRedirects() throws Exception {
        try (TestServer server = new TestServer((r, out) -> TestServer.respond(out, 302, null, "", "Location: http://evil.local:1/"))) {
            MiniHttp.Response response = MiniHttp.execute(route(server, "setbeam.local"), "GET", "/", null, null, 2000, 1024, new MiniHttp.Call());
            assertEquals(302, response.status);
            assertEquals("http://evil.local:1/", response.header("Location"));
            assertEquals(1, server.requests.size());
        }
    }

    @Test public void decodesChunkedBodies() throws Exception {
        try (TestServer server = new TestServer((r, out) -> out.write(("HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\nLocation: /live/whep/abc\r\n\r\n"
                + "4\r\nv=0\n\r\n5;x=y\r\nabcde\r\n0\r\n\r\n").getBytes(StandardCharsets.UTF_8)))) {
            MiniHttp.Response response = MiniHttp.execute(route(server, "h"), "POST", "/live/whep", null, new byte[0], 2000, 1024, new MiniHttp.Call());
            assertEquals(201, response.status);
            assertEquals("v=0\nabcde", response.text());
        }
    }

    @Test public void boundsBodiesAndHeaders() throws Exception {
        try (TestServer server = new TestServer((r, out) -> TestServer.respond(out, 200, "text/plain", "x".repeat(5000)))) {
            try { MiniHttp.execute(route(server, "h"), "GET", "/", null, null, 2000, 1024, new MiniHttp.Call()); fail(); }
            catch (IOException expected) { assertTrue(expected.getMessage().contains("too large")); }
        }
        try (TestServer server = new TestServer((r, out) -> out.write(("HTTP/1.1 200 OK\r\nX: " + "y".repeat(MiniHttp.MAX_HEADER) + "\r\n\r\n").getBytes(StandardCharsets.UTF_8)))) {
            try { MiniHttp.execute(route(server, "h"), "GET", "/", null, null, 2000, 1024, new MiniHttp.Call()); fail(); }
            catch (IOException expected) { assertTrue(expected.getMessage().contains("header too large")); }
        }
    }

    @Test public void enforcesTheTotalDeadline() throws Exception {
        try (TestServer server = new TestServer((r, out) -> {
            out.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".getBytes(StandardCharsets.UTF_8));
            out.flush();
            for (int i = 0; i < 40; i++) { try { Thread.sleep(50); } catch (InterruptedException e) { return; } out.write('x'); out.flush(); }
        })) {
            long started = System.nanoTime();
            try { MiniHttp.execute(route(server, "h"), "GET", "/", null, null, 500, 1024, new MiniHttp.Call()); fail(); }
            catch (IOException expected) { }
            long ms = (System.nanoTime() - started) / 1_000_000;
            assertTrue("trickled bytes must not extend the deadline: " + ms, ms < 1500);
        }
    }

    @Test public void cancelUnblocksAWaitingRequest() throws Exception {
        try (TestServer server = new TestServer((r, out) -> { try { Thread.sleep(5000); } catch (InterruptedException ignored) { } })) {
            MiniHttp.Call call = new MiniHttp.Call();
            new Thread(() -> { try { Thread.sleep(200); } catch (InterruptedException ignored) { } call.cancel(); }).start();
            long started = System.nanoTime();
            try { MiniHttp.execute(route(server, "h"), "GET", "/", null, null, 5000, 1024, call); fail(); }
            catch (InterruptedIOException expected) { }
            assertTrue((System.nanoTime() - started) / 1_000_000 < 2000);
        }
    }

    @Test public void refusesHeaderInjection() throws Exception {
        try (TestServer server = new TestServer((r, out) -> TestServer.respond(out, 200, null, ""))) {
            try { MiniHttp.execute(route(server, "h"), "GET", "/", Map.of("X-Setbeam-Pass", "a\r\nX: y"), null, 1000, 1024, new MiniHttp.Call()); fail(); }
            catch (IOException expected) { }
            try { MiniHttp.execute(route(server, "h"), "GET", "/a\r\nb", null, null, 1000, 1024, new MiniHttp.Call()); fail(); }
            catch (IOException expected) { }
        }
    }

    @Test public void closedWithoutReplyIsAFailure() throws Exception {
        try (TestServer server = new TestServer((r, out) -> { })) {
            try { MiniHttp.execute(route(server, "h"), "GET", "/", null, null, 1000, 1024, new MiniHttp.Call()); fail(); }
            catch (IOException expected) { assertTrue(expected.getMessage().contains("without a reply")); }
        }
    }
}
