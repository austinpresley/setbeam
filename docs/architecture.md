# Architecture

Setbeam is a native macOS application built around one received video feed.
Holly Share provides the original RTSP-relay reference; its Bash launcher is
not the controller for the new app.

## Modules

- `SetbeamCore` owns source descriptions, session transitions, address validation,
  process ownership, and the media runtime. Its interface separates local monitoring
  from audience sharing. MediaRuntime is the authoritative owner of session intent
  and observed media health. Tests cross that same interface.
- `SetbeamApp` owns SwiftUI/AppKit presentation, saved settings, QR generation,
  local web hosting, native preview presentation, and native window lifetime. UI code observes the session
  state instead of constructing media commands.
- Bundled viewer resources own browser playback and accurate audience states.
  They use the received media rather than contacting the transmitter.

The source adapters are a labeled sample, a complete RTSP URL, an authenticated
incoming RTMP stream, a compatible capture device, and direct CineView Master 4K
RTMS4 reception. Support requires recorded physical connection evidence in
`hardware-tests.md`; generic adapters do not imply model compatibility.

Computer displays, including DigiTech applications such as Capture One, and
camera feeds are peer source use cases. The transport and input describe how
the feed reaches Setbeam, independently of what appears in it. Direct capture
of the receiving Mac's own screen is a separate feature and is not implemented.

## Media flow

The media runtime starts an app-owned MediaMTX instance and supervised FFmpeg
processes. Local monitoring has a private playable output. Audience sharing
uses a separate output so Hold and Stop can change audience media without
closing the source input.

The browser transport is WebRTC. External inputs normalize to H.264 Baseline
without B frames and optional 48 kHz stereo Opus. Encoding preserves source
dimensions and cadence, rounding odd dimensions to even values for 4:2:0.
Only the verified bundled sample copies its video. Observed media metadata must
satisfy this contract before an output is considered ready.

The separate bundled `setbeam-preview` helper links the pinned FFmpeg libraries
and decodes the private local RTSP relay once. A versioned, bounded pipe carries
NV12 video and stereo Float32 PCM with source presentation timestamps. The native
renderer presents shared pixel-buffer images in the main and floating windows;
there is no JPEG encode/decode or fixed 24 fps/1280-pixel main-preview limit.
Audio and video use one AVSampleBufferRenderSynchronizer clock. Bounded queues,
stale-frame dropping, timestamp discontinuity handling, and a decoder watchdog
keep playback current. Audio-device initialization stays off the UI thread and
has an operator-visible timeout. The main preview preserves source cadence;
the silent outgoing thumbnail explicitly requests its smaller size and rate.
Guest permission grants read access
only to the audience output. Control and publishing credentials are private.

Each run has a private directory and explicit process ownership. Packaged helpers run in owned process groups through a bundled supervisor that watches the app and terminates its group after parent exit, including Force Quit. The controller also cleans the group after an unexpected supervisor exit. Runtime
state stays outside the signed app bundle and repository. Dependency versions,
source provenance, and build flags are recorded with the bundle tooling.

## Session ownership

MediaRuntime owns sharing, Hold, monitoring, and media health. Its own watchdog
reconciles failed or stalled processes every 500 ms independently of the UI.
Lifecycle commands and recovery share a serialized operation queue, including
across actor suspension points. Shutdown cancels the watchdog and invalidates
its lifetime before removing owned processes.

`snapshot()` is a read of cached observations and has no repair or probing side
effects. `updates()` publishes snapshots through a bounded AsyncStream.
SessionModel observes this state and keeps presentation concerns and saved setup
metadata; it does not maintain a second mutable sharing/Hold state machine.
The native decoder and ViewerGateway supervise their own recovery too. The
remaining UI timer refreshes discovery, network selection, and viewer activity.
It is not required to keep media processes or the viewer listener alive.

## Evidence

Automated tests cover session behavior, input validation, access restrictions,
process lifetime, and actual bundled-media playback. Physical device support,
network range, viewer capacity, and end-to-end delay require separate records
in `hardware-tests.md`.

## Proven setup and recovery

SourceSetup is the persistent connection identity. ProvenSetupStore saves only when the app's readiness gate has observed sustained incoming video and native decoded playback. Settings store names, stable capture IDs, and a credential-free address summary. Complete addresses and incoming keys use Keychain. Audience intent and session secrets are never restored from preferences.

CaptureDiscovery supplies device names and persistent IDs. The bundled FFmpeg AVFoundation patch accepts exact IDs and resolves them inside the process, preventing a hot-plug enumeration race. Its pristine source archive, patch script, and build script ship with the app. Missing video or optional selected audio never falls back to a different device.

The runtime recovers its owned server and source/audience processes, including running processes with stale video. Server recovery preserves the current credentials and audience Hold. An audience-publisher revision tells browser viewers to establish a new peer when media restarts. Native windows share one decoder, which also restarts on stalled output.

The viewer controller replaces an open peer after ten seconds without decoded video, bounds configuration/state/heartbeat requests and body reads to five seconds, and ignores callbacks from replaced peers. Hold and Stop close playback and suppress watchdog reconnection. Publisher revisions also refresh playback configuration. A zero-frame FFmpeg progress report never establishes source health.

An active sharing session waits for its selected viewing interface through a temporary outage. It retains sharing, Hold, the viewer credential, and the gateway port. The gateway can restart on that port with a bounded startup deadline and ignores obsolete listener callbacks. If DHCP changes the Mac's address, Setbeam updates its viewing code; an already-open numeric-IP URL cannot follow that change. Explicit Stop or an operator-selected different viewing network still ends sharing. Wi-Fi network selection stays under the user's control; automatic Wi-Fi association is not implemented.

AccsoonDiscovery recognizes the Master 4K's observed product IDs 21 and 24 from passive UDP beacons and bounded read-only status queries. The same physically identified firmware-3.30 unit has reported both IDs, and direct product-24 reception was verified separately. It retains identity, SSID, firmware, and valid stream arrays, and discards credential-bearing custom fields. Other product IDs remain unverified and appear with an explanation in the chooser. The app waits for a real HDMI/SDI input when the transmitter advertises no streams.

AccsoonReceiver owns one UDP/TCP RTMS4 session for the selected unit. Bounded fragment assembly, acknowledgement, and retransmission feed standard loopback RTP HEVC and AAC. The HEVC packetizer caches at most 192 KiB of parameter sets and repeats missing sets at random-access pictures so a late local decoder can start. The bundled FFmpeg converts that one received feed to H.264 and Opus in the local relay. Native previews and sharing use the relay rather than opening additional transmitter sessions. Exact UID checks prevent substitution of another unit.

RuntimeSnapshot includes an observational ConnectionStage. Server readiness, discovery of the selected UID, a current receiver's connection acknowledgement, and fresh local relay video determine its stage. SessionModel keeps that stage visible until native decoded playback is also fresh. Generic inputs omit transmitter-only steps. Stage presentation does not start extra receivers or change retry timing, and old receiver counters cannot advance a disconnected session.

Incoming RTMP remains a generic authenticated adapter in Advanced. MediaMTX keeps
a stable, private loopback RTMP listener for the session. IncomingStreamRelay
binds the selected source interface and forwards a bounded number of TCP streams
to that listener, retaining source-subnet restrictions. Authentication remains
inside MediaMTX. An unavailable or occupied input binding therefore cannot
terminate the server used by local monitoring and audience viewing. Viewer
sharing can continue through Ethernet. The input credential can be restored
independently of private audience session credentials. The SEE bridge is
unverified; direct Master 4K reception is the physically tested route. No vendor
binary is bundled.

## Session safeguards

Changing inputs inside an existing session keeps the viewer gateway, numeric
viewing address, server process, ports, viewing credential, and an already-running
holding publisher. MediaRuntime establishes actual compatible holding output
before touching the source. It validates a replacement incoming binding before
closing the previous input, updates only source configuration and sender
authorization, and replaces the one received source. An offline replacement
leaves the holding publisher running; a fresh replacement never resumes sharing
automatically. A failed preflight retains the previous source, and the UI restores
its identity and local decoder. Returning to the previous input uses its in-memory
identity and private address, with the same Hold requirement. Relaunch restores
privately. In-flight UI continuations check shutdown before reopening playback.

The small audience preview decodes the actual `live` output through an authorized loopback publisher descriptor at 384 pixels and 8 fps. It is silent, supervised, and independent of the shared local decoder. It never contacts the transmitter and does not count as an audience browser. Frame freshness and outgoing publisher readiness hide stale outgoing pictures. Stop Sharing and Quit stop this decoder.

RuntimeSnapshot observes audio track presence from the local and outgoing MediaMTX path descriptions. These flags establish track presence, not audible sound. The main window distinguishes input audio, local speaker mute, and outgoing audience audio. Hold labels source audio as silenced even though the holding output has a silent encoded audio track.

The setup check requires a fresh native picture, a non-loopback running viewing address, and fresh playback reported by a browser at another network endpoint. Viewer heartbeats carry the current publisher revision, so an old source's playback cannot confirm its replacement. The gateway classifies local endpoints itself rather than accepting the browser's claim. When sound is expected, the operator must also confirm hearing it on the other device. These transient checks do not automatically establish a hardware compatibility record. Active sharing triggers a native Quit confirmation showing the current opened-browser count; private monitoring quits directly.

## Outgoing status presentation

SessionModel presents outgoing-media readiness separately from the thumbnail decoder. OutgoingTransition gives only an explicit Start, Hold, or Resume change a preparation state, bounded at ten seconds. The first fresh outgoing output clears it, so later loss is immediately eligible for recovery feedback. Stop and known failed audience actions cancel preparation. Holding-output health does not depend on the source picture; a cached thumbnail never establishes outgoing readiness. These are presentation observations and do not alter media commands or audience permissions.
