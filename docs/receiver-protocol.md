# Receiver protocol

This is the contract a native receiver, such as the Android TV app in
`receiver/android`, uses to ask a Setbeam Mac for its feed. It adds no new
gateway endpoint, credential, or admission rule. A receiver is one more viewer
session that asks through the **short address** and waits for the operator's
Admit, exactly like a browser that typed `setbeam.local`.

Facts here come from `ShortAddressListener`, `ViewerGateway`,
`ViewerAccessLedger`, `ReceiverDiscoveryPublisher`, and the bundled
`viewer.js`. If they disagree with this note, the code wins and this note is
out of date.

## When a Mac can be reached

The short address is open only while all of these hold on the Mac:

- Sharing is on, with the viewer gateway running.
- **Ask before viewers join** (viewer approval) is on.
- **Offer a local address** is on and its `.local` name is active.
- **Let viewers ask from the short address** is on.
- The viewing network is one other devices can join (not "This Mac only").
- The port 80 listener is bound and ready.

Otherwise the short address does not answer new visitors and no `_setbeam._tcp`
service is advertised. Closing it declines its pending requests and refuses
new asks. During the same share, an already admitted receiver can still use
its existing ask path and pass. Stop, a new share, or quitting retires that
path. The receiver cannot open or force any of these settings; it waits.

## Discovery

Setbeam advertises one DNS-SD service while, and only while, the short
address is answering (every condition above, including a ready listener):

| Field | Value |
| --- | --- |
| Service type | `_setbeam._tcp.` in `local.` |
| Instance name | The active local-address label, such as `setbeam`. DNS-SD may rename it on conflict, such as `setbeam (2)`. A label, not an identity. |
| SRV target | The active local-address name, such as `setbeam.local.` (the same A record viewers resolve). |
| Port | `80` |
| Interface | The Mac's selected viewing interface only |
| TXT `v` | `1`. Ignore services with another major version. |
| TXT `path` | `/`. The ask-only root on port 80. |
| TXT `host` | The active name, such as `setbeam.local`. Use it as the `Host` header or display text. |
| TXT `id` | 32 lowercase hex characters, random per Mac installation and stable across shares. A pairing hint, not authentication. Anyone on the network can copy it. |

The TXT record never contains the viewing-link code, the ask-path code, a
pass, a media user or password, a session title, or viewer names.

Withdrawal: Stop Sharing, turning approval, the local address, or the short
address off, a new viewing link, a viewing-network change, the listener losing
port 80, and Quit remove the service. A network change withdraws it while the
name is re-probed and re-adds it on the new interface. Expect a goodbye
(service lost) packet, but treat a missing service as "not reachable now",
never as a refusal. mDNS may be filtered on some networks; fall back to the
configured host.

### Choosing a host

1. Configured host: the provisioning extra `setbeam_host`, an `http://` base
   URL such as `http://setbeam.local/`. Port 80 and path `/` are implied.
   Setup uses action `com.setbeam.receiver.CONFIGURE` and extra `setbeam_name`
   for the receiver's unverified display label. The bundled Mac currently
   serves HTTP only. HTTPS addresses accepted by the app require a separately
   configured TLS endpoint; they are not a claim of bundled HTTPS support.
2. If the configured name does not resolve (Android often cannot resolve
   `.local` through the normal resolver), browse `_setbeam._tcp`, resolve the
   instance, and connect to its IPv4 address on the advertised port. Prefer
   the service whose TXT `id` matches the paired Mac, then whose `host`
   matches the configured name.
3. For the HTTP discovery fallback, connect by IPv4 address and send
   `Host: <that IPv4>`. The listener also accepts the TXT host, but repeats it
   in `Location`; sending the numeric address keeps later URLs resolvable on
   Android. Never downgrade a configured HTTPS destination through discovery.

## Step 1: root redirect (port 80)

```
GET / HTTP/1.1
Host: setbeam.local            (or the Mac's viewing IPv4, optionally :80)
```

Rules enforced by the listener:

- Only `GET` or `HEAD` for path `/` (a query string is ignored).
- `Host` must be the active `.local` name or the viewing IPv4 address,
  case-insensitive, optional `:80` and trailing dot.
- The TCP connection must arrive at the viewing address. Connections to any
  other local address of the Mac close with no reply.
- The whole header must fit in 4096 bytes. Each connection is closed after
  3 seconds. At most 16 are open at once.
- Every response has `Connection: close`, `Cache-Control: no-store`.

| Response | Meaning |
| --- | --- |
| `302 Found`, `Location: http://<same host>:<gateway port>/s/<ask code>/` | Open. The host in `Location` is the one you sent. |
| `404` | Wrong path or unknown `Host`. |
| `405` (`Allow: GET, HEAD`) | Wrong method. |
| `400` / `431` | Malformed or oversized header. |
| Connection refused, reset, or closed with no bytes | Not open now, or you reached the wrong address. Back off and retry. |

Do not let the HTTP client follow the redirect automatically. Read
`Location`, keep its path, and use it as the **ask path**. The ask code is 64
hex characters, distinct from the viewing link, and is never a media
credential. It changes with every new viewing link (every new share, and at
Stop). It does not change for Hold, a publisher revision, a viewing-address
change, or closing and reopening the short address during one share.

The gateway port is ephemeral and may differ between shares. Use the
`Location` URL, not a remembered port.

## Step 2: gateway endpoints (ask path)

All URLs below are `http://<host>:<gateway port><ask path><name>`. The
gateway accepts only `GET` and `POST`, a request line under 2048 bytes, a
header up to 8192 bytes, and `Content-Length` bodies up to 2048 bytes. A
`Transfer-Encoding` header is rejected with 400, so send a fixed-length body.
Every response is `Connection: close`, `Cache-Control: no-store`. A request
must finish within about 6 seconds. The browser uses a 5-second client
deadline; do the same.

An ask-path 404 means the path is retired, or, for a new `join`, the short
address is closed for new requests. Go back to Step 1 without discarding a
stored refusal for that path. Closing only the short address does not retire
an admitted receiver's existing pass or its state/media endpoints.

### `GET state.json`

Public, no pass needed. Never names viewers.

```json
{"state":"live","title":"My feed","sample":false,"revision":3,"sequence":8,
 "wifiSSID":"","approval":true,"pointers":false}
```

- `state`: `stopped`, `live`, `holding`, or `reconnecting`.
- `revision`: the publisher revision. It changes when the outgoing stream is
  republished (source change, approval change, recovery).
- `sequence`: orders state snapshots within a share, including changes that
  keep the same publisher revision. Ignore an older poll or event after a
  newer sequence. Older Macs omit this field.
- `sample`: true when the feed is labeled sample media. Show that label.

`GET events` is a server-sent-event stream of the same JSON: once on open, on
every change, and every 10 seconds as a keepalive (`retry: 3000`). At most 64
streams are open per Mac; a refused stream gets 503. Polling `state.json`
every 1.5 to 3 seconds is equivalent.

### `POST join`

`Content-Type: application/json`. Fields:

| Field | Type | Notes |
| --- | --- | --- |
| `pass` | string, 48 hex | Omit on the first request. Send the stored pass afterwards. |
| `name` | string | Required with `ask` for a new request. Control characters removed, whitespace collapsed, at most 40 characters. A label chosen by the device; the operator sees it as unverified. |
| `ask` | `true` | Required for a new request. Sent only when a new request is intended. |
| `requestID` | UUID string | Optional. Reuse it when retrying the same explicit Ask after an uncertain response. The Mac can return the existing record for 30 seconds. |
| `color` | string | Optional: `blue green orange pink purple yellow red teal cyan lime indigo brown`. |
| `mobile` | bool | Labels the operator row "Phone / tablet browser" when true, "Desktop browser" when false. |

Responses:

| Status | Body | Meaning |
| --- | --- | --- |
| 200 | `{"pass":"…48 hex…","number":7,"admission":"pending","ready":false,"color":"teal","name":"Stage TV"}` | New or resumed session. `admission` is `pending`, `admitted`, `declined`, or `removed`. `ready` is true once an admitted session's own media user is in effect. |
| 400 | `{"error":"name"}` | A new request needs `name` and `ask: true`, or a stored pass is no longer known and no `ask` was sent. |
| 503 | `{"error":"full"}` | 16 waiting requests, or 8 from the short address. Retry later. |
| 404 | `Session unavailable` | Short address closed for new requests, or path retired. |

A request through the short address is always `pending`, never admitted by
the link or by a previous share. Joining again with a known pass resumes it
and never creates a second request; a `declined` or `removed` pass stays
refused for that ask path.

### `POST heartbeat`

```json
{"pass":"…","mobile":false,"playing":true,"health":"playing",
 "revision":3,"color":"teal"}
```

`health` is one of `good struggling checking playing connecting reconnecting
paused background ready holding`. `revision` is the publisher revision the
receiver is actually playing, or `-1`. Include `name` only if it equals the
name already sent; under approval the gateway ignores renames.

Response is always 200 for valid JSON:
`{"ok":true,"admission":"admitted","chatLastID":12}` or
`{"ok":false,"admission":"unknown"}` for an unknown or malformed pass.

Heartbeats and joins with the pass keep a request alive. A `pending` request
with no join or heartbeat for 30 seconds lapses and its pass becomes
`unknown`. An admitted session stays admitted until removed or the share
ends; after 12 seconds without a heartbeat the operator row says No recent
update. The browser heartbeats every 2.5 to 3 seconds and immediately on
playing/paused changes.

### `GET config.json`

Header `X-Setbeam-Pass: <pass>`.

| Status | Body | Meaning |
| --- | --- | --- |
| 200 | `{"title":"…","sample":false,"revision":3,"sequence":8,"whepURL":"http://192.168.1.20:52001/live/whep","user":"viewer7x…","pass":"…"}` | Admitted and media access in effect. |
| 403 | `{"admission":"pending"}` (or `declined`, `removed`, `unknown`) | Not admitted. |
| 503 | empty | Admitted, but the media server has not yet accepted this session's user. Retry in about 1.5 s. |
| 404 | | Path retired. Step 1. |

`user`/`pass` are this session's own read-only media credentials, created at
Admit and deleted at removal. They are never the viewing-link token. Keep
them in memory only. Fetch `config.json` again on every new revision and
discard a result for a superseded revision, sequence, or viewing route.

### `GET chat` (optional, admitted only)

Header `X-Setbeam-Pass: <pass>`, no `Origin`. The same endpoint the browser
viewer reads; the receiver only reads it.

| Status | Body | Meaning |
| --- | --- | --- |
| 200 | `[{"id":4,"name":"DigiTech","color":"blue","operatorMessage":true,"text":"…","sentAt":1795000000.1,"replyTo":null,"hasFrame":false,"sampleFrame":false,"reactions":[{"reaction":"heart","count":2,"selected":false}],…}]` | Up to 100 messages, oldest first. |
| 403 | empty | This pass is not admitted (or sharing stopped). |
| 404 | | Path retired. |

An admitted heartbeat reply carries `chatLastID`, the newest message id. The
receiver fetches `chat` when that id changes, and every 5 s while its chat
panel is open so reactions and removals show. It does not fetch attached
frames (`chat/frame/<id>`) and never posts. Text is cleaned of control and
direction-override characters and kept in memory only.

### `GET presence` (optional, admitted only, WebSocket)

A WebSocket upgrade with `Origin: http://<the Host header>`. The first text
message must be `{"t":"hello","pass":"…","name":"…","color":"teal"}`.

- **Not offered**: `503` instead of `101` when the operator has shared
  pointers off, or the channel limit is reached. Retry after 30 s.
- **Refused**: `{"t":"denied","reason":"access"|"name"|"full"}`, then close.
- **Welcome**: `{"t":"welcome","n":3,"r":<revision>,…}`.
- **Pointers**: `{"t":"pointers","r":…,"items":[{"n":2,"label":"…","color":"red","x":0.25,"y":0.5,"ttl":3200}]}`
  carries every other participant's latest pointer, relative to the picture
  (0..1). Each fades after `ttl` ms.

The Mac closes a channel silent for 20 s, so the receiver pings after 8 s
without a message and gives up after 30 s with no frame at all. The receiver
only watches: it never sends `move`, `tap`, or `hide`. It opens the channel
only while admitted and only when the TV user turned on Pointers. Any refusal,
lapse, new share or stop closes it and clears the pointers.

## Media

- `whepURL` is always numeric (the viewing IPv4 and the media server's own
  ephemeral port). It never depends on `.local` resolution.
- WHEP (MediaMTX): `POST whepURL`, `Content-Type: application/sdp`,
  `Authorization: Basic base64(user:pass)`, body = SDP offer with recvonly
  video and audio. Success is `201 Created` with the SDP answer and a
  `Location` for the session (`PATCH` trickle ICE, `DELETE` to end).
  `401` means the credentials were revoked or replaced: fetch `config.json`.
- ICE: host candidates on the viewing address over UDP or TCP; no STUN or TURN
  is needed on one LAN.
- Video: H.264 Baseline profile, VideoToolbox, no B-frames, a keyframe every
  second, the source's size up to 3840 x 2160, at most 30 fps. Audio: Opus,
  48 kHz, stereo, 96 kbit/s, when the source has sound. A source without
  sound negotiates no live audio track.
- Viewer media is read-only. There is no publish, control, or administration
  path for a receiver.

## State machine

```
            ┌──────────── 404 anywhere / connection refused ─────────────┐
            v                                                            │
 [Find host] ── GET / → 302 ──> [Ask path known]                         │
            │                       │ stored pass for this path?         │
            │                       ├─ none, never asked → POST join ask │
            │                       ├─ pass → POST join {pass}           │
            v                       v                                    │
      backoff 2..30 s        pending ── poll join/heartbeat 1.5–3 s ─────┤
                                    │                                    │
                                    ├─ admitted, ready → config.json → WHEP play
                                    ├─ declined / removed → stop asking for THIS path
                                    └─ unknown (lapsed) → see below
```

Per ask path, store `{path, pass, admission}`. Key it by the ask path, not
by the host or IP, so a DHCP move keeps the session.

- **Admitted**: fetch `config.json`, play while `state == "live"`. On
  `holding`, `stopped`, or `reconnecting`, close the WHEP session and show a
  neutral holding screen (Hold suppresses outgoing video and audio). When
  `live` returns, or `revision` changes while live, fetch `config.json` again
  and open a new WHEP session. Heartbeat every 3 seconds. Replace a peer that
  decodes no video for 10 seconds.
- **Declined or removed**: close media at once. Turning the short address
  or approval off also declines requests still waiting from the short
  address; admitted sessions keep playing. Do not send `ask` again on
  this ask path. Keep polling Step 1 slowly (every 10 to 30 seconds); when the
  redirect yields a **different** ask path (a new share), ask again once.
  A stored refusal remains final even if a later response says `unknown`:
  the gateway may eventually evict older refused records at its capacity bound.
- **Unknown** after being pending (the request lapsed, for example during a
  network outage longer than 30 seconds): this is not a refusal. A Mac restart
  instead retires the old path. Unless this path has a stored refusal, a
  receiver may send one new `ask` for the same path, at most once
  every 30 seconds, and must show that it is asking again.
- **Full** (503): retry the ask no faster than every 10 seconds.
- A new share always requires a fresh Admit. There is no trusted-device
  auto-admission.

## What the operator sees

The receiver appears in the operator's join request card and Sharing >
Viewers as "Typed `<name>.local`", with its chosen name marked unverified and
its session number. Admit, Decline, and Remove behave exactly as for browser
sessions. Remove deletes the session's media user and disconnects its WebRTC
session; a reconnect then fails authorization.
