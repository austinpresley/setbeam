package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import java.io.IOException;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import org.json.JSONObject;
import org.junit.Test;

/** HttpGateway against a loopback stand-in that follows docs/receiver-protocol.md. */
public class HttpGatewayTest {
    static final String CODE = "c".repeat(64);
    static final String PASS = "ab".repeat(24);

    static final class FakeSetbeam implements AutoCloseable {
        final TestServer gateway, root;
        volatile String admission = "pending";
        volatile boolean ready = false;
        volatile String state = "live";
        volatile int revision = 3;
        volatile boolean shortAddressOpen = true;
        FakeSetbeam() throws IOException {
            gateway = new TestServer((r, out) -> {
                String prefix = "/s/" + CODE + "/";
                if (!r.target.startsWith(prefix)) { TestServer.respond(out, 404, "text/plain", "Session unavailable"); return; }
                String suffix = r.target.substring(prefix.length());
                JSONObject body = r.body.length > 0 ? new JSONObject(r.text()) : new JSONObject();
                switch (suffix) {
                    case "join":
                        if (!body.has("pass") && !(body.optBoolean("ask") && body.has("name"))) { TestServer.respond(out, 400, "application/json", "{\"error\":\"name\"}"); return; }
                        if (body.has("pass") && !PASS.equals(body.getString("pass"))) { TestServer.respond(out, 400, "application/json", "{\"error\":\"name\"}"); return; }
                        TestServer.respond(out, 200, "application/json", new JSONObject().put("pass", PASS).put("number", 7)
                                .put("admission", admission).put("ready", ready).put("color", "teal").put("name", "Stage TV").toString());
                        return;
                    case "state.json":
                        TestServer.respond(out, 200, "application/json", stateJson());
                        return;
                    case "config.json":
                        if (!PASS.equals(r.header("x-setbeam-pass")) || !"admitted".equals(admission)) {
                            TestServer.respond(out, 403, "application/json", "{\"admission\":\"" + (PASS.equals(r.header("x-setbeam-pass")) ? admission : "unknown") + "\"}"); return;
                        }
                        if (!ready) { TestServer.respond(out, 503, "text/plain", ""); return; }
                        TestServer.respond(out, 200, "application/json", new JSONObject().put("title", "My feed").put("sample", true)
                                .put("whepURL", "http://127.0.0.1:52999/live/whep").put("user", "viewer7xabcdef01").put("pass", "f".repeat(48)).toString());
                        return;
                    case "heartbeat":
                        TestServer.respond(out, 200, "application/json", PASS.equals(body.optString("pass"))
                                ? "{\"ok\":true,\"admission\":\"" + admission + "\",\"chatLastID\":2}" : "{\"ok\":false,\"admission\":\"unknown\"}");
                        return;
                    case "events":
                        out.write(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\nretry: 3000\n\n"
                                + "data: " + stateJson() + "\n\n").getBytes(StandardCharsets.UTF_8));
                        out.flush();
                        state = "holding";
                        out.write(("data: " + stateJson() + "\n\n").getBytes(StandardCharsets.UTF_8));
                        return;
                    default:
                        TestServer.respond(out, 404, "text/plain", "");
                }
            });
            root = new TestServer((r, out) -> {
                String host = r.header("host");
                if (!shortAddressOpen || !r.method.equals("GET") || !r.target.equals("/")) { TestServer.respond(out, 404, null, ""); return; }
                TestServer.respond(out, 302, null, "", "Location: http://" + host.substring(0, host.indexOf(':')) + ":" + gateway.port() + "/s/" + CODE + "/",
                        "Cache-Control: no-store");
            });
        }
        String stateJson() {
            return "{\"state\":\"" + state + "\",\"title\":\"My feed\",\"sample\":true,\"revision\":" + revision
                    + ",\"wifiSSID\":\"\",\"approval\":true,\"pointers\":false}";
        }
        HostConfig host() throws Exception { return HostConfig.parse("http://127.0.0.1:" + root.port() + "/", "Stage TV"); }
        HttpGateway client() {
            return new HttpGateway(h -> List.of(new HttpGateway.Candidate(InetAddress.getByName("127.0.0.1"), h.port, h.hostHeader(), "configured address", null)));
        }
        @Override public void close() throws IOException { gateway.close(); root.close(); }
    }

    @Test public void fullAskAdmitPlayRoundtrip() throws Exception {
        try (FakeSetbeam mac = new FakeSetbeam()) {
            Gateway.Scope scope = new Gateway.Scope();
            Gateway.Resolution resolution = mac.client().resolve(mac.host(), scope);
            AskPath path = resolution.path;
            assertEquals(mac.gateway.port(), path.route.port);

            String id = "a8459b78-e14a-4400-8c61-742047405426";
            Gateway.JoinResult asked = mac.client().join(path, null, "Stage TV", true, "teal", id, scope);
            assertEquals(Gateway.Status.OK, asked.status);
            assertEquals(AccessStore.Admission.PENDING, asked.admission);
            JSONObject sent = new JSONObject(mac.gateway.requests.get(0).text());
            assertTrue(sent.getBoolean("ask"));
            assertEquals("Stage TV", sent.getString("name"));
            assertFalse(sent.getBoolean("mobile"));
            assertFalse(sent.has("pass"));
            assertEquals(id, sent.getString("requestID"));

            Gateway.JoinResult resumed = mac.client().join(path, PASS, "Stage TV", false, "teal", null, scope);
            JSONObject resent = new JSONObject(mac.gateway.requests.get(1).text());
            assertFalse("a resumed request never asks again", resent.has("ask"));
            assertFalse(resent.has("name"));
            assertFalse(resent.has("requestID"));
            assertEquals(PASS, resumed.pass);

            assertEquals(Gateway.Status.NOT_ADMITTED, mac.client().config(path, PASS, scope).status);
            mac.admission = "admitted";
            assertEquals(Gateway.Status.NOT_READY, mac.client().config(path, PASS, scope).status);
            mac.ready = true;
            Gateway.ConfigResult config = mac.client().config(path, PASS, scope);
            assertEquals(Gateway.Status.OK, config.status);
            assertEquals(52999, config.playback.target.route.port);
            assertTrue(config.playback.sample);

            Gateway.StateResult state = mac.client().state(path, scope);
            assertTrue(state.live());
            assertEquals(3, state.revision);
            assertTrue(state.sample);

            Gateway.HeartbeatResult beat = mac.client().heartbeat(path, PASS, true, "playing", 3, "teal", scope);
            assertEquals("admitted", beat.admission);
            JSONObject hb = new JSONObject(mac.gateway.requests.get(mac.gateway.requests.size() - 1).text());
            assertEquals(3, hb.getInt("revision"));
            assertFalse(hb.has("name"));
            assertEquals("unknown", mac.client().heartbeat(path, "00".repeat(24), false, "connecting", -1, "teal", scope).admission);

            mac.admission = "removed";
            Gateway.ConfigResult removed = mac.client().config(path, PASS, scope);
            assertEquals(Gateway.Status.NOT_ADMITTED, removed.status);
            assertEquals("removed", removed.admission);
        }
    }

    @Test public void optionalStateSequenceAcceptsOnlyIntegers() throws Exception {
        JSONObject state = new JSONObject().put("state", "live").put("revision", 3);
        assertEquals(-1, HttpGateway.parseState(state).sequence);
        assertEquals(4_294_967_296L, HttpGateway.parseState(state.put("sequence", 4_294_967_296L)).sequence);
        assertEquals(-1, HttpGateway.parseState(state.put("sequence", 1.5)).sequence);
        assertEquals(-1, HttpGateway.parseState(state.put("sequence", "10")).sequence);
    }

    @Test public void savedAdmittedRouteNeedsACurrentlyCorroboratedAddressAndAnActiveShare() throws Exception {
        try (FakeSetbeam mac = new FakeSetbeam()) {
            Gateway.Scope scope = new Gateway.Scope();
            HostConfig host = mac.host();
            AskPath path = mac.client().resolve(host, scope).path;
            AccessStore.KeyValue values = new AccessStoreTest.MemoryValues();
            AccessStore.SecretBox box = new AccessStoreTest.ReverseBox();
            AccessStore store = new AccessStore(values, box);
            AccessStore.Record record = new AccessStore.Record();
            record.admission = AccessStore.Admission.ADMITTED;
            record.pass = PASS;
            assertTrue(store.save(path.key, record, 5));
            store.saveAdmittedRoute(host, path);
            AskPath saved = new AccessStore(values, box).admittedRoute(host);
            assertEquals(path.key, saved.key);
            assertNull("pairing changed", store.admittedRoute(HostConfig.parse("backup.local", "Stage TV")));

            mac.shortAddressOpen = false;
            Gateway.Resolution resumed = mac.client().resolve(host, saved, scope);
            assertTrue(resumed.resumed);
            assertEquals(path.route.toString(), resumed.path.route.toString());
            assertEquals("public state only", path.endpoint("state.json"), mac.gateway.requests.get(0).target);
            assertNull(mac.gateway.requests.get(0).header("x-setbeam-pass"));
            try {
                new HttpGateway(h -> List.of()).resolve(host, saved, scope);
                fail("uncorroborated address");
            } catch (IOException expected) { }

            mac.state = "stopped";
            try {
                mac.client().resolve(host, saved, scope);
                fail("stopped route");
            } catch (Gateway.Unanswered expected) { }
            assertTrue(store.refuse(path.key, AccessStore.Admission.REMOVED, 6));
            assertNull(store.admittedRoute(host));
        }
    }

    @Test public void unknownPassAndRetiredPath() throws Exception {
        try (FakeSetbeam mac = new FakeSetbeam()) {
            Gateway.Scope scope = new Gateway.Scope();
            AskPath path = mac.client().resolve(mac.host(), scope).path;
            assertEquals(Gateway.Status.NAME_REQUIRED, mac.client().join(path, "00".repeat(24), "Stage TV", false, "teal", null, scope).status);
            AskPath retired = AskPath.fromRedirect(path.route.withPort(80, "127.0.0.1"), 302, "http://127.0.0.1:" + mac.gateway.port() + "/s/" + "d".repeat(64) + "/");
            assertEquals(Gateway.Status.GONE, mac.client().join(retired, null, "Stage TV", true, "teal", null, scope).status);
            assertEquals(Gateway.Status.GONE, mac.client().state(retired, scope).status);
        }
    }

    @Test public void pushedStatesArrive() throws Exception {
        try (FakeSetbeam mac = new FakeSetbeam()) {
            Gateway.Scope scope = new Gateway.Scope();
            AskPath path = mac.client().resolve(mac.host(), scope).path;
            List<String> states = new ArrayList<>();
            mac.client().events(path, scope, s -> states.add(s.state));
            assertEquals(List.of("live", "holding"), states);
        }
    }

    @Test public void cancelledScopeStopsRequests() throws Exception {
        try (FakeSetbeam mac = new FakeSetbeam()) {
            Gateway.Scope scope = new Gateway.Scope();
            scope.cancel();
            try { mac.client().resolve(mac.host(), scope); fail(); } catch (IOException expected) { }
            assertTrue(mac.root.requests.isEmpty());
        }
    }

    @Test public void rootThatDoesNotRedirectIsReported() throws Exception {
        try (TestServer root = new TestServer((r, out) -> TestServer.respond(out, 404, null, ""))) {
            HostConfig host = HostConfig.parse("http://127.0.0.1:" + root.port() + "/", "TV");
            HttpGateway client = new HttpGateway(h -> List.of(new HttpGateway.Candidate(InetAddress.getByName("127.0.0.1"), h.port, h.hostHeader(), "configured address", null)));
            try { client.resolve(host, new Gateway.Scope()); fail(); } catch (Gateway.Unanswered expected) { }
        }
    }
}
