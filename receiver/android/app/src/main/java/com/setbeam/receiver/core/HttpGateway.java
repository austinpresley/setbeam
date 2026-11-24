package com.setbeam.receiver.core;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/** {@link Gateway} over {@link MiniHttp}, following docs/receiver-protocol.md. */
public final class HttpGateway implements Gateway {
    public static final int DEADLINE_MS = 5000;
    static final int MAX_BODY = 16 * 1024;

    /** One address to try for the paired Mac's short address. */
    public static final class Candidate {
        public final InetAddress address;
        public final int port;
        public final String hostHeader;
        public final String via;
        public final String macId;
        public Candidate(InetAddress address, int port, String hostHeader, String via, String macId) {
            this.address = address; this.port = port; this.hostHeader = hostHeader; this.via = via; this.macId = macId;
        }
    }

    /** Addresses for the configured host, in the order to try them. Only the paired Mac's. */
    public interface Candidates {
        List<Candidate> find(HostConfig host) throws IOException;
    }

    private final Candidates candidates;

    public HttpGateway(Candidates candidates) { this.candidates = candidates; }

    @Override
    public Resolution resolve(HostConfig host, Scope scope) throws IOException, AskPath.Rejected {
        return resolve(host, null, scope);
    }

    @Override
    public Resolution resolve(HostConfig host, AskPath saved, Scope scope) throws IOException, AskPath.Rejected {
        List<Candidate> found = candidates.find(host);
        if (found.isEmpty()) throw new IOException("Looking for " + host.host);
        IOException lastFailure = null;
        AskPath.Rejected lastRejection = null;
        for (Candidate candidate : found) {
            MiniHttp.Route root = new MiniHttp.Route(host.scheme, candidate.address, candidate.port, candidate.hostHeader, host.host);
            MiniHttp.Response response;
            try {
                response = request(root, "GET", "/", Map.of("Accept", "text/html"), null, scope);
            } catch (IOException e) {
                if (scope.isCancelled()) throw e;
                lastFailure = e; continue;
            }
            if (response.status == 302) {
                try {
                    return new Resolution(AskPath.fromRedirect(root, response.status, response.header("location")), candidate.via, candidate.macId);
                } catch (AskPath.Rejected e) { lastRejection = e; continue; }
            }
            lastFailure = new Unanswered(response.status == 404
                    ? "The Mac answered, but is not offering its short address for " + candidate.hostHeader
                    : "The Mac answered with " + response.status);
        }
        // A saved pass may outlive the short address. Reuse only a route corroborated by
        // current resolution, and check its public state before any request carries the pass.
        if (saved != null && lastRejection == null) {
            for (Candidate candidate : found) {
                if (!candidate.address.equals(saved.route.address)) continue;
                try {
                    StateResult state = state(saved, scope);
                    if (state.status == Status.OK && !"stopped".equals(state.state)) return new Resolution(saved, "saved route via " + candidate.via, null, true);
                } catch (IOException e) {
                    if (scope.isCancelled()) throw e;
                }
                break;
            }
        }
        if (lastRejection != null) throw lastRejection;
        throw lastFailure != null ? lastFailure : new IOException("Not reachable");
    }

    @Override
    public JoinResult join(AskPath path, String pass, String name, boolean ask, String color, String requestID, Scope scope) throws IOException {
        JSONObject body = new JSONObject();
        try {
            if (pass != null) body.put("pass", pass);
            if (ask) {
                body.put("name", name); body.put("ask", true);
                if (requestID != null) body.put("requestID", requestID);
            }
            if (color != null) body.put("color", color);
            body.put("mobile", false);
        } catch (JSONException e) { throw new IOException(e); }
        MiniHttp.Response response = post(path, "join", body, scope);
        switch (response.status) {
            case 200: break;
            case 400: return JoinResult.of(Status.NAME_REQUIRED);
            case 503: return JoinResult.of(Status.FULL);
            case 404: return JoinResult.of(Status.GONE);
            default: return JoinResult.of(Status.ERROR);
        }
        JSONObject json = json(response);
        String issued = json.optString("pass", null);
        AccessStore.Admission admission = AccessStore.Admission.parse(json.optString("admission", null));
        if (!AccessStore.validPass(issued) || admission == null) throw new IOException("Unexpected join reply");
        return new JoinResult(Status.OK, issued, json.optInt("number", 0), admission, json.optBoolean("ready", false));
    }

    @Override
    public StateResult state(AskPath path, Scope scope) throws IOException {
        MiniHttp.Response response = request(path.route, "GET", path.endpoint("state.json"), Map.of("Accept", "application/json"), null, scope);
        if (response.status == 404) return StateResult.of(Status.GONE);
        if (response.status != 200) return StateResult.of(Status.ERROR);
        return parseState(json(response));
    }

    static StateResult parseState(JSONObject json) throws IOException {
        String state = json.optString("state", "");
        if (!state.equals("live") && !state.equals("holding") && !state.equals("stopped") && !state.equals("reconnecting"))
            throw new IOException("Unexpected state");
        String title = HostConfig.cleanLabel(json.optString("title", ""), 120);
        return new StateResult(Status.OK, state, title == null ? "" : title, json.optBoolean("sample", false),
                json.optInt("revision", -1), json.optBoolean("approval", false), optionalSequence(json));
    }

    private static long optionalSequence(JSONObject json) {
        Object value = json.opt("sequence");
        return value instanceof Integer || value instanceof Long ? Math.max(-1, ((Number) value).longValue()) : -1;
    }

    @Override
    public ConfigResult config(AskPath path, String pass, Scope scope) throws IOException {
        MiniHttp.Response response = request(path.route, "GET", path.endpoint("config.json"),
                Map.of("Accept", "application/json", "X-Setbeam-Pass", pass), null, scope);
        switch (response.status) {
            case 200: break;
            case 403: {
                String admission = "unknown";
                try { admission = new JSONObject(response.text()).optString("admission", "unknown"); } catch (JSONException ignored) { }
                return new ConfigResult(Status.NOT_ADMITTED, null, admission);
            }
            case 503: return new ConfigResult(Status.NOT_READY, null, null);
            case 404: return new ConfigResult(Status.GONE, null, null);
            default: return new ConfigResult(Status.ERROR, null, null);
        }
        JSONObject json = json(response);
        WhepTarget target;
        try { target = WhepTarget.validate(json.optString("whepURL", null), path.route); }
        catch (AskPath.Rejected e) { throw new IOException(e.getMessage()); }
        String user = json.optString("user", "");
        String password = json.optString("pass", "");
        if (user.isEmpty() || user.length() > 128 || password.length() > 256 || user.contains(":")) throw new IOException("Unexpected media credentials");
        String title = HostConfig.cleanLabel(json.optString("title", ""), 120);
        return new ConfigResult(Status.OK, new Playback(target, user, password, title == null ? "" : title, json.optBoolean("sample", false)), null);
    }

    @Override
    public HeartbeatResult heartbeat(AskPath path, String pass, boolean playing, String health, int revision, String color, Scope scope) throws IOException {
        JSONObject body = new JSONObject();
        try {
            body.put("pass", pass); body.put("mobile", false); body.put("playing", playing);
            body.put("health", health); body.put("revision", revision);
            if (color != null) body.put("color", color);
        } catch (JSONException e) { throw new IOException(e); }
        MiniHttp.Response response = post(path, "heartbeat", body, scope);
        if (response.status == 404) return new HeartbeatResult(Status.GONE, null);
        if (response.status != 200) return new HeartbeatResult(Status.ERROR, null);
        JSONObject reply = json(response);
        Object last = reply.opt("chatLastID");
        int chatLastId = last instanceof Number ? Math.max(0, ((Number) last).intValue()) : -1;
        return new HeartbeatResult(Status.OK, reply.optString("admission", "unknown"), chatLastId);
    }

    static final int MAX_CHAT_BODY = 1024 * 1024;
    /**
     * A ping goes out when the receiver has sent nothing for this long. The Mac closes a channel it
     * has not heard from in 20 s, however much it is sending itself, so this follows what the
     * receiver sent, not what it received. Not final for tests.
     */
    static int presencePingMs = 8000;
    /** How long one read waits before the send clock is checked again. */
    static int presenceReadMs = 2000;
    /** Without any frame from the Mac for this long, the channel is treated as lost. */
    static final long PRESENCE_SILENCE_MS = 30_000;

    @Override
    public ChatResult chat(AskPath path, String pass, Scope scope) throws IOException {
        MiniHttp.Call call = scope.newCall();
        MiniHttp.Response response;
        try {
            response = MiniHttp.execute(path.route, "GET", path.endpoint("chat"),
                    Map.of("Accept", "application/json", "X-Setbeam-Pass", pass), null, DEADLINE_MS, MAX_CHAT_BODY, call);
        } finally { scope.done(call); }
        switch (response.status) {
            case 200: break;
            case 403: return new ChatResult(Status.NOT_ADMITTED, java.util.List.of());
            case 404: return new ChatResult(Status.GONE, java.util.List.of());
            default: return new ChatResult(Status.ERROR, java.util.List.of());
        }
        try { return new ChatResult(Status.OK, ChatLine.parse(new org.json.JSONArray(response.text()))); }
        catch (JSONException e) { throw new IOException("Invalid chat reply"); }
    }

    @Override
    public void presence(AskPath path, String pass, String name, String color, Scope scope, PresenceEvents events) throws IOException {
        MiniHttp.Call call = scope.newCall();
        try {
            WebSocket socket;
            try {
                socket = WebSocket.connect(path.route, path.endpoint("presence"), path.route.scheme + "://" + path.route.hostHeader, DEADLINE_MS, call);
            } catch (MiniHttp.UpgradeRefused e) {
                // 503: the operator has not turned on shared pointers, or the channel limit is reached.
                if (e.status == 503) { events.denied("off"); return; }
                throw e;
            }
            try {
                JSONObject hello = new JSONObject();
                try { hello.put("t", "hello"); hello.put("pass", pass); hello.put("name", name); if (color != null) hello.put("color", color); }
                catch (JSONException e) { throw new IOException(e); }
                socket.sendText(hello.toString());
                socket.setReadTimeout(Math.min(presenceReadMs, presencePingMs));
                while (true) {
                    String message;
                    try { message = socket.readText(); }
                    catch (java.net.SocketTimeoutException e) { message = ""; }
                    long now = System.nanoTime();
                    if ((now - socket.lastFrameNanos()) / 1_000_000L > PRESENCE_SILENCE_MS) throw new IOException("Pointer channel went silent");
                    if ((now - socket.lastSentNanos()) / 1_000_000L >= presencePingMs) socket.sendPing();
                    if (message == null) return;
                    if (message.isEmpty()) continue;
                    JSONObject json;
                    try { json = new JSONObject(message); } catch (JSONException e) { continue; }
                    switch (json.optString("t", "")) {
                        case "welcome": events.welcome(); break;
                        case "pointers": events.pointers(json.optInt("r", -1), Pointer.parse(json.optJSONArray("items"), 0)); break;
                        case "denied": {
                            String reason = HostConfig.cleanLabel(json.optString("reason", "access"), 16);
                            events.denied(reason == null ? "access" : reason);
                            return;
                        }
                        default: break;
                    }
                }
            } finally {
                socket.close();
            }
        } finally {
            scope.done(call);
            call.cancel();
        }
    }

    @Override
    public void events(AskPath path, Scope scope, Consumer<StateResult> onState) throws IOException {
        MiniHttp.Call call = scope.newCall();
        try (MiniHttp.Stream stream = MiniHttp.openStream(path.route, path.endpoint("events"), DEADLINE_MS, 25_000, call)) {
            if (stream.status == 404) { onState.accept(StateResult.of(Status.GONE)); return; }
            if (stream.status != 200) throw new IOException("Events refused: " + stream.status);
            StringBuilder data = new StringBuilder();
            String line;
            while ((line = stream.readLine()) != null) {
                if (line.isEmpty()) {
                    if (data.length() > 0) {
                        try { onState.accept(parseState(new JSONObject(data.toString()))); }
                        catch (JSONException e) { throw new IOException("Invalid event"); }
                        data.setLength(0);
                    }
                } else if (line.startsWith("data:")) {
                    if (data.length() > 0) data.append('\n');
                    data.append(line.substring(5).trim());
                    if (data.length() > 8192) throw new IOException("Event too large");
                }
            }
        } finally {
            scope.done(call);
        }
    }

    private MiniHttp.Response post(AskPath path, String endpoint, JSONObject body, Scope scope) throws IOException {
        return request(path.route, "POST", path.endpoint(endpoint), Map.of("Content-Type", "application/json", "Accept", "application/json"),
                body.toString().getBytes(StandardCharsets.UTF_8), scope);
    }

    private static MiniHttp.Response request(MiniHttp.Route route, String method, String target, Map<String, String> headers,
                                             byte[] body, Scope scope) throws IOException {
        MiniHttp.Call call = scope.newCall();
        try { return MiniHttp.execute(route, method, target, headers, body, DEADLINE_MS, MAX_BODY, call); }
        finally { scope.done(call); }
    }

    private static JSONObject json(MiniHttp.Response response) throws IOException {
        try { return new JSONObject(response.text()); } catch (JSONException e) { throw new IOException("Invalid reply"); }
    }
}
