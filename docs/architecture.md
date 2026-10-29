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
the feed reaches Setbeam, independently of what appears in it. This Mac's screen captures a selected display locally through ScreenCaptureKit.

## Media flow

The media runtime starts an app-owned MediaMTX instance and supervised FFmpeg
processes. Local monitoring has a private playable output. Audience sharing
uses a separate output so Hold and Stop can change audience media without
closing the source input.

The private `local` relay carries the received encoding. Network, incoming,
and Master 4K video is copied rather than re-encoded, so local monitoring shows
the source's own picture without a second generation or encoder delay. Raw
capture frames are encoded once at monitoring quality (H.264 High, 40 Mbps, no
B frames). Source audio normalizes to 48 kHz stereo Opus. The relay is ready
when MediaMTX observes exactly one H.264, H.265, or Motion JPEG picture with
nonzero dimensions and optional Opus; the bundled decoder and audience encoder
both accept those codecs.

Each keyframe reaches MediaMTX as one burst of RTP packets, and MediaMTX
discards packets for any reader whose queue is full. Its default 512-packet
reader queue holds about 750 KB, less than one detailed monitoring-quality
keyframe, so the runtime sets 8192 packets. That holds MediaMTX's largest
accepted 8 MiB access unit. MediaMTX drops a larger access unit at ingest for
every reader, whatever the queue size.

The browser transport is WebRTC. The audience `live` output is its own encode
of the relay, made only while sharing: H.264 Baseline without B frames,
preserving dimensions and, by default, cadence, and rounding odd dimensions to even values
for 4:2:0, with the relay's Opus copied. Each viewer receives a separate WebRTC
copy, so the operator chooses a per-viewer ceiling of 12, 6, or 3 Mbps; a change
restarts only the audience encode under the same viewing credential. That
allowance is also the encoder's one-second limit: an average alone let 4K
keyframes reach 4.5 MiB, three times the allowance at 1 fps and too large for
browsers' WebRTC stacks to assemble. The saved Viewer frame rate can match the
source up to 30 fps or cap it at 1, 5, 10, 15, 24, 25, or 30 fps. Nothing Setbeam
encodes exceeds 30 fps: two 4K60 encodes saturated the hardware encoder, and stills
and screens gain little from more. FFmpeg's bundled select filter keeps at most
one frame per rounded timestamp bucket before encoding. It preserves presentation timestamps and never
duplicates a slower input, including when RTSP frame-rate metadata is missing.
Dimensions and the bitrate allowance stay
unchanged. The sample uses this same audience encode so both settings apply to
every source. Observed `live` metadata
must satisfy this browser contract before the audience output is ready.

The separate bundled `setbeam-preview` helper links the pinned FFmpeg libraries
and decodes the private local RTSP relay once. A versioned, bounded pipe carries
NV12 video and stereo Float32 PCM with source presentation timestamps. Each
picture is copied into a pooled IOSurface pixel buffer that the main window,
floating preview, and setup-check thumbnail show through
AVSampleBufferDisplayLayer. The GPU compositor converts NV12 for display; there is
no CPU RGB conversion, per-frame CoreImage context, JPEG encode/decode, or fixed
24 fps/1280-pixel main-preview limit. Audio and video use one
AVSampleBufferRenderSynchronizer clock. Bounded queues, stale-frame dropping,
timestamp discontinuity handling, and a decoder watchdog keep playback current.
The 32 MB video queue holds only two 4K pictures, so a clock left behind by a
late arrival would otherwise evict every later picture before it is due. When
capacity evicts an unpresented picture, the shared clock restarts at the newest
one. Audio-device initialization stays off the UI thread and
has an operator-visible timeout. The main preview preserves source cadence;
the silent outgoing thumbnail explicitly requests its smaller size and rate.
Both the audience and native decoders use two slice threads instead of buffering
whole frames across automatic frame threads. That keeps a 1 fps input from
waiting many seconds for a decoder thread queue to fill.
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

CaptureDiscovery supplies device names, persistent IDs, and each device's
active size with the highest cadence that size offers. The capture input
requests exactly that mode, mirroring how the bundled AVFoundation input
activates formats, instead of a fixed 30 fps. The bundled FFmpeg AVFoundation patch accepts exact IDs and resolves them inside the process, preventing a hot-plug enumeration race. Its pristine source archive, patch script, and build script ship with the app. Missing video or optional selected audio never falls back to a different device.

The runtime recovers its owned server and source/audience processes, including running processes with stale video. Server recovery preserves the current credentials and audience Hold. An audience-publisher revision tells browser viewers to establish a new peer when media restarts. Native windows share one decoder, which also restarts on stalled output.

The viewer controller replaces an open peer after ten seconds without decoded video, bounds configuration/state/heartbeat requests and body reads to five seconds, and ignores callbacks from replaced peers. Hold and Stop close playback and suppress watchdog reconnection. Publisher revisions also refresh playback configuration. A zero-frame FFmpeg progress report never establishes source health.

An active sharing session waits for its selected viewing interface through a temporary outage. It retains sharing, Hold, the viewer credential, and the gateway port. The gateway can restart on that port with a bounded startup deadline and ignores obsolete listener callbacks. If DHCP changes the Mac's address, Setbeam updates its viewing code; an already-open numeric-IP URL cannot follow that change. Explicit Stop or an operator-selected different viewing network still ends sharing. Wi-Fi network selection stays under the user's control by default.

An opt-in transmitter rejoin covers the observed power-cycle case where macOS moves to another known network and does not return. For a saved Master 4K setup with a known transmitter Wi-Fi name, TransmitterRejoinPolicy waits until the transmitter has been missing from discovery for 15 seconds without a live picture. It then allows one CoreWLAN join, backing off from 20 seconds to two minutes, and resets when the transmitter or picture returns. It never runs while sharing depends on the Wi-Fi interface. The password is stored in Keychain. macOS reveals Wi-Fi names only to apps with Location access, so Setbeam asks for it when the option is enabled and never associates with a scan result it cannot identify by name. Attempts and results are written to the session log.

AccsoonDiscovery recognizes the Master 4K's observed product IDs 21 and 24 from passive UDP beacons and bounded read-only status queries. The same physically identified firmware-3.30 unit has reported both IDs, and direct product-24 reception was verified separately. It retains identity, SSID, firmware, and valid stream arrays, and discards credential-bearing custom fields. Other product IDs remain unverified and appear with an explanation in the chooser. The app waits for a real HDMI/SDI input when the transmitter advertises no streams.

AccsoonReceiver owns one UDP/TCP RTMS4 session for the selected unit. Bounded fragment assembly, acknowledgement, and retransmission feed standard loopback RTP HEVC and AAC. The HEVC packetizer caches at most 192 KiB of parameter sets and repeats missing sets at random-access pictures so a late local decoder can start. The local relay carries that one received HEVC picture unchanged with Opus audio; the audience output converts it to H.264 only while sharing. Native previews and sharing use the relay rather than opening additional transmitter sessions. Exact UID checks prevent substitution of another unit.

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

## Session log and power

SessionLog writes a private, size-bounded JSON-lines timeline to
`~/Library/Logs/Setbeam/session.log`, rotating at 1 MB and keeping three older
files. It records lifecycle commands, process restarts with the decoded exit
status and a redacted error tail, connection stages, viewer counts, and each
source or audience readiness change with the inputs behind it: relay
availability, decodable metadata, receiver state, and frame age. MediaMTX
warnings and errors, such as reader discards and rejected input, are recorded as
`server.warning`; repeats of one kind within ten seconds are counted into the
next entry. Every string
passes through Redaction, which removes URL credentials, query secrets,
key/pass parameters, viewing-link tokens, and long secret-like runs. Nothing is
written until the app or probe configures a directory; the probe writes under
`build/probe/session-log`.

SessionModel holds a display-sleep assertion while a live local picture is
visible in the main window or floating preview, and the system-sleep assertion
while sharing. Hiding the monitor, losing the picture, or quitting releases them.

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

## This Mac's screen

MacScreenCapture owns one in-app ScreenCaptureKit stream. The display filter excludes the running Setbeam application, including windows opened after capture starts, so the main and floating previews cannot create a mirror. Capture refuses to start if ScreenCaptureKit cannot identify Setbeam for exclusion. AVFoundation screen capture cannot provide this exclusion. Keeping SCStream in the app also attributes Screen Recording permission to Setbeam rather than a separately launched helper. Choosing this source or explicitly enabling chooser previews requests permission. Denial uses the existing recovery UI and links to Screen Recording settings.

The chooser lists localized display names and native pixel dimensions without requesting recording permission. SourceSetup persists the CG display UUID in videoID, never an enumeration index. Every retry resolves that UUID again. A disconnected display remains the selected source; another connected display is never substituted. Proven setup confirmation and private relaunch use the existing readiness gate.

DisplaySourcePreviews supplies small, rounded chooser thumbnails. With an existing Screen Recording grant, it takes one bounded SCScreenshotManager picture per unselected display every two seconds while the chooser is open. Pictures fit a 120 by 72 point frame without cropping, exclude Setbeam's own windows, contain no audio, and stay in memory. The currently monitored display instead uses the existing NativePreview picture and never opens another capture stream. Permission denial offers an explicit Enable Previews action; opening the chooser alone never requests access. Closing the chooser cancels refresh and clears its images. Cancellation checks discard late screenshots, failed capture clears the affected picture, and display changes refresh the UUID list.

ScreenCaptureKit includes the cursor and captures video only, labeled No sound. Pixels are preserved up to a 3840 by 2160 bounding box, maintaining aspect ratio and even dimensions. By default cadence follows the display mode rounded to the nearest whole frame rate up to 30 fps; a variable or unspecified refresh rate uses 30. The separate saved Screen capture frame rate can reduce that cadence, including to 1 fps, without changing pixel dimensions. Its resolved rate drives ScreenCaptureKit, the encoding timer, VideoToolbox, and the pipe demuxer together. Changing it restarts only the selected screen source and any live audience encode, retaining the server, viewer credential, sharing intent, and any running holding output. Viewer-only FPS changes leave the source publisher and local decoder alone. A timer encodes the latest complete screen frame even while the desktop is unchanged. ScreenCaptureKit errors clear that picture and close the publisher input so normal runtime recovery retries the selected display.

VideoToolbox encodes H.264 without B frames, at least 40 Mbps, scaling the bitrate with pixel count and cadence, with a keyframe every second. ScreenEncoder keeps every picture within 6 MiB, below the 8 MiB that VideoPipeWriter and MediaMTX each accept. VideoToolbox's data-rate limits do not bound a single keyframe, and after one oversized keyframe it stopped emitting keyframes. An oversized picture is therefore withheld with the pictures that depend on it, and the encoder restarts with a minimum QP six steps higher; the restart begins with a keyframe. The floor steps back down when a keyframe is at most half the limit. Each restart is recorded as `screen.encoder`. Ordinary screens never reach the limit and keep the unrestricted encode. The screen publisher copies this monitoring-quality video to local like other received encodings, and browsers receive the audience output's own bounded encode. An Annex B pipe feeds the existing bundled FFmpeg H.264 demuxer. The pipe carries no timestamps, so FFmpeg stamps each frame on arrival from the constant-rate capture clock; generated timestamps advanced only one 90 kHz tick per frame under stream copy. ManagedChild accepts an explicit stdin handle while retaining its existing process group and supervisor. VideoPipeWriter drains nonblocking writes on pipe writability, independently of capture ticks, and cancels idle notifications. Its 8 MiB pending limit bounds backpressure; a blocked/broken pipe closes capture output and enters existing recovery. Low-rate demuxing and native decoding allow a two-second picture-analysis window and skip the FPS/initial-DTS probes that can otherwise require dozens of frames when timing metadata is missing. Native freshness permits three frame intervals at 1 fps, bounded to six seconds. No new executable or external runtime dependency is required. Native monitoring, floating preview, sharing, Hold and Stop all continue to consume the single local relay.

## Browser viewer presentation

The viewer's full-screen element contains the feed name, Sample/status strip, picture, icon toolbar, and connection help. The picture fits its decoded `videoWidth`/`videoHeight` within the available viewport without cropping. First connection is separate from later recovery, Hold uses a neutral blue pause presentation, and blocked autoplay has a large play affordance. Only `NotAllowedError` counts as blocked; a play request aborted by a replaced source keeps the stale-peer watchdog running. Live-region text changes only when its value changes.

Audio control availability follows non-ended, unmuted incoming audio tracks and their add/remove/mute/unmute events. A negotiated WebRTC audio receiver alone does not establish that the source has audio. These observations affect only viewer presentation and its local mute choice. PiP is feature-detected; closing or replacing a peer exits PiP and detaches its video. Native video full screen on phones and native video PiP display the video rather than arbitrary page elements, so the page's Sample/status strip does not accompany those native views. Physical browser behavior remains separate evidence.

Unknown or rotated viewer navigation receives a bundled, self-contained generic HTML 404. It carries no current session data and does not authorize assets, state, configuration, events, or publishing. When the old numeric address or port no longer reaches Setbeam, an HTTP page cannot replace the browser's connection error.

## Viewer identity and playback health

ViewerGateway assigns an increasing session number to each browser ID, sorts by that number, and accepts an optional bounded plain-text name. Names are saved in that browser tab's session storage when available, sent through the existing heartbeat, and displayed only to the operator. There is no roster endpoint and no new publishing or administration capability. A browser session is not a unique physical device.

The existing WebRTC reader exposes an observational getStats call on its current peer. The controller samples only while receiving visible playback, using packet-loss deltas, jitter, round-trip delay, and dropped-frame deltas. Two consecutive bad or clean samples change the health indicator; it does not assume a target FPS or interpret low bitrate as a fault. Missing measurements fall back to confirmed playback. Replaced peers invalidate pending measurements. The operator resolves reported health against fresh heartbeats, current publisher revision, and authoritative Hold state. Neutral background, paused, and blocked-playback states stay distinct from connection failure. Health never changes the stream or opens another receiver, and is not a Wi-Fi signal-strength measurement.
