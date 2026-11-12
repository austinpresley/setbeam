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

PyroHDiscovery ports Holly Share's known `/live` RTSP connection into the native chooser. SystemConfiguration supplies only active Wi-Fi service IPv4 routers on the interface's actual private subnet. Each TCP probe binds that interface and local address and checks up to the three upstream ports, in order. A bounded DESCRIBE requires a complete, correctly framed H.264 SDP response; it never sends SETUP/PLAY. Polling runs off the main actor with deadlines, bounded input, owned file descriptors, and cancellation checks at most 50 ms apart. No shell tool, Wi-Fi association, Location grant, subnet scan, or streaming receiver is involved in discovery.

SourceBrowser owns the chooser-lifetime scan task and discards late results or results from a changed network. All network-source monitoring suspends Pyro H probes because the hardware can have a single-client limit. Source selection drains any in-flight probe before MediaRuntime opens its upstream stream. A discovered PyroHSource creates a normal network SourceSetup with optional `networkProfile: pyroH` metadata. The proven-setup gate and Keychain retain the exact selected URL, restoring privately; metadata does not establish a physical device identity. No additional source adapter or audience process is introduced. The existing RTSP path supplies one received feed to native/floating monitoring and sharing, preserving recovery, Hold and Stop. The original launcher remains a reference. Physical Pyro H qualification is separate from simulation tests.

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
AVSampleBufferDisplayLayer. Every allocation has an eight-buffer ceiling shared
across formats and decoder recovery for that NativePreview. A private,
non-propagating buffer attachment carries the allocation lease into renderers,
so destroying a PreviewPicture wrapper cannot reset the budget. Saturation drops
presentation frames; releasing renderer buffers permits new pictures again.
Display layers honor readiness and flush when detached, minimized, closed or
their window's occlusion changes. Detached, hidden and minimized monitors do not enqueue pictures.
The GPU compositor converts NV12 for display; there is
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

## Minimal floating monitor presentation

The floating picture still consumes that same decoded IOSurface-backed feed.
Its center action and dark Hold veil are presentation only; outgoing protection
continues to come from the runtime's independent holding output and silence.
The UI waits for observed outgoing readiness instead of equating intent with
successful Hold. A scoped requested target makes failures retry the same action.

The floating window applies saturation only to its viewport-sized picture layer
while held, with AppKit's Core Image compositing. It does not acquire or decode
another source, copy frames through CPU RGB, or filter the main monitor or the
encoded viewer output. The control layer stays separate from that picture
filter. Source-aspect changes are fitted to the active display; unusually extreme
shapes keep a usable window and fit the full source within a neutral surround.

Pointer use never requests key status. Explicit keyboard focus is a separate
menu action; native button activation and a guarded pointer Resume preserve the
working app's input. Viewer actions are an on-demand owned child panel whose
monitors and content are removed on dismissal. Its actions revalidate the viewing
link, session number, join time and admission before changing viewer access.

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

An active sharing session waits for its selected viewing interface through a temporary outage. It retains sharing, Hold, the viewer credential, and the gateway port. The gateway can restart on that port with a bounded startup deadline and ignores obsolete listener callbacks. If DHCP changes the Mac's address, Setbeam updates its viewing code and moves an active local address to the new address; an already-open numeric-IP URL cannot follow that change. Explicit Stop or an operator-selected different viewing network still ends sharing. Wi-Fi network selection stays under the user's control by default.

An opt-in transmitter rejoin covers the observed power-cycle case where macOS moves to another known network and does not return. For a saved Master 4K setup with a known transmitter Wi-Fi name, TransmitterRejoinPolicy waits until the transmitter has been missing from discovery for 15 seconds without a live picture. It then allows one CoreWLAN join, backing off from 20 seconds to two minutes, and resets when the transmitter or picture returns. It never runs while sharing depends on the Wi-Fi interface. The password is stored in Keychain. macOS reveals Wi-Fi names only to apps with Location access, so Setbeam asks for it when the option is enabled and never associates with a scan result it cannot identify by name. Attempts and results are written to the session log.

AccsoonDiscovery recognizes the Master 4K's observed product IDs 21 and 24 from passive UDP beacons and bounded read-only status queries. The same physically identified firmware-3.30 unit has reported both IDs, and direct product-24 reception was verified separately. It retains identity, SSID, firmware, and valid stream arrays, and discards credential-bearing custom fields. Other product IDs remain unverified and appear with an explanation in the chooser. The app waits for a real HDMI/SDI input when the transmitter advertises no streams.

AccsoonReceiver owns one UDP/TCP RTMS4 session for the selected unit. Bounded fragment assembly, acknowledgement, and retransmission feed standard loopback RTP HEVC and AAC. The HEVC packetizer caches at most 192 KiB of parameter sets and repeats missing sets at random-access pictures so a late local decoder can start. The local relay carries that one received HEVC picture unchanged with Opus audio; the audience output converts it to H.264 only while sharing. Native previews and sharing use the relay rather than opening additional transmitter sessions. Exact UID checks prevent substitution of another unit.

RuntimeSnapshot includes an observational ConnectionStage. Server readiness, discovery of the selected UID, a current receiver's connection acknowledgement, and fresh local relay video determine its stage. SessionModel keeps that stage visible until native decoded playback is also fresh. Generic inputs omit transmitter-only steps. Stage presentation does not start extra receivers or change retry timing, and old receiver counters cannot advance a disconnected session.

Incoming RTMP remains a generic authenticated adapter in the CineView guide and its Accsoon SEE setup. MediaMTX keeps
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

VideoToolbox encodes H.264 without B frames, at least 40 Mbps, scaling the bitrate with pixel count and cadence, with a keyframe every second. ScreenEncoder keeps every picture within 6 MiB, below the 8 MiB that VideoPipeWriter and MediaMTX each accept. VideoToolbox's data-rate limits do not bound a single keyframe, and after one oversized keyframe it stopped emitting keyframes. An oversized picture is therefore withheld with the pictures that depend on it, and the encoder restarts with a minimum QP six steps higher; the restart begins with a keyframe. The floor steps back down when a keyframe is at most half the limit. Each restart is recorded as `screen.encoder`. Ordinary screens never reach the limit and keep the unrestricted encode. The screen publisher copies this monitoring-quality video to local like other received encodings, and browsers receive the audience output's own bounded encode. An Annex B pipe feeds the existing bundled FFmpeg H.264 demuxer. The pipe carries no timestamps, so FFmpeg stamps each frame on arrival from the constant-rate capture clock; generated timestamps advanced only one 90 kHz tick per frame under stream copy. ManagedChild accepts an explicit stdin handle while retaining its existing process group and supervisor. VideoPipeWriter drains nonblocking writes on pipe writability, independently of capture ticks, and cancels idle notifications. Its 8 MiB pending limit bounds backpressure. A write offset tracks consumed bytes; an emptied buffer is released, and an append copies only a partially drained tail into fresh storage. Data.removeFirst must not be used here: it retains the consumed allocation, so repeated append/drain cycles can retain all encoded bytes sent during a shoot even while the pending count is zero. A blocked/broken pipe closes capture output and enters existing recovery. Low-rate demuxing and native decoding allow a two-second picture-analysis window and skip the FPS/initial-DTS probes that can otherwise require dozens of frames when timing metadata is missing. Native freshness permits three frame intervals at 1 fps, bounded to six seconds. No new executable or external runtime dependency is required. Native monitoring, floating preview, sharing, Hold and Stop all continue to consume the single local relay.

## One application window

An application window is a peer of a whole display. MacScreenCapture captures it through the same in-app SCStream, ScreenEncoder, VideoPipeWriter, and supervised screen-input FFmpeg, so one capture supplies the local relay, native main and floating previews, and the audience encode. `SCContentFilter(desktopIndependentWindow:)` captures only that window, wherever it moves and whatever covers it, so the desktop, other windows, and Setbeam's own windows never enter the picture. The window's pixel size when capture starts, within the 3840 by 2160 bound, sets the stream size. A later resize is scaled to fit whole inside that size, never cropped; ScreenCaptureKit leaves the remainder black. Cadence follows the saved capture frame rate, up to 30 fps. The source has no sound.

MacWindowIdentity is the window number, the owner process ID, and that process's kernel start time. Titles are labels only; they never select or match a window, and the session log and diagnostics record only "Application window". Every capture start resolves the exact triple and refuses Setbeam's own process. A reused window number or a relaunched owner with the same process ID does not match. On the tested macOS 27 build, minimizing a window or hiding its application sends one `suspended` status and then no frames, and CoreGraphics reports it off screen. A retained AppKit window that has been closed looks the same. Capture therefore stops repeating its last picture on `suspended`, `blank`, or `stopped`, and the source becomes unavailable. MacWindowLocator reads every window with `CGWindowList` `.optionAll`, because a targeted lookup omits minimized windows. A missing number or ended owner is `closed`; anything still listed but off screen is `hidden`. Restarts throw before any helper starts unless the exact window is visible. A new window, even with the same title in the same application, is never substituted. SessionModel shows the window's current title and distinguishes waiting from closed. If a hidden window returns and no frame newer than its return arrives within three seconds, it retries once instead of waiting for runtime backoff; cached availability can stay true for seconds after the last frame, so it is not used.

The chooser lists other applications' ordinary on-screen windows (layer 0, at least 64 by 48 points) only when Screen Recording access already exists. Without it, the chooser shows the existing Enable Previews action and never prompts. WindowSourcePreviews keeps chooser-lifetime state: it refreshes every two seconds, takes at most nine silent, shadowless single-window screenshots per pass, one at a time, for rows on screen, and fits each into 280 by 168 pixels shown in a 140 by 84 point frame. The monitored window shows the existing NativePreview picture instead of a screenshot. Closing the chooser invalidates in-flight screenshots and clears every image, icon, and handle. An identity lasts only as long as its owner process. A proven window setup restores privately after relaunch only if the same window of the same running process still exists; otherwise Setbeam asks the operator to choose again.

## Local address

LocalAddressPublisher publishes one IPv4 address record, `label.local`, for the viewing address while sharing. It uses the system DNS-SD responder: `DNSServiceCreateConnection`, then `DNSServiceRegisterRecord` with `kDNSServiceFlagsUnique` on the selected viewing interface's index, attached to the publisher's serial queue. No administrator rights are needed. The Mac's own name, other network settings, and DNS configuration are untouched, and no internet service is involved. The responder probes before answering. A conflict can be refused synchronously or reported in the callback, including after the name became active. DNS-SD leaves conflicts to the client, so the publisher tries `label-2` through `label-20` and then reports the name in use. A new viewing address keeps the label currently held; a new operator label starts again from the plain name. Responder failures and a missing interface retry every 5 s. Deallocating the connection on its queue removes the record and ends callbacks, so Stop Sharing, a failed start, a source reset, a loopback-only network, and Quit remove the name. Identical address data from another registrant is not a conflict (RFC 6762 §9), so two Setbeam sessions on one Mac and address share the name; their ports and private codes differ.

The name changes only the URL's host. The port, the `/s/<private code>/` path, admission, approval, and same-origin presence checks are unchanged, and the gateway still listens only on the selected address. Media stays on the IP address: `config.json` returns the numeric WHEP URL, so playback never depends on name resolution. Copy viewing link uses the name only once it is active. Join codes and the setup check's code always use the IP address, and Copy IP address link remains available. The operator's label is saved in preferences, validated as a portable host label of up to 40 characters, and lowercased. Settings shows the effective name, numbered alternatives, and failures. `.local` resolution depends on the viewer's device and on networks passing multicast; physical qualification is separate evidence.

## Browser viewer presentation

The viewer's full-screen element contains the feed name, Sample/status strip, picture, icon toolbar, and connection help. The picture fits its decoded `videoWidth`/`videoHeight` within the available viewport without cropping. First connection is separate from later recovery, Hold uses a neutral blue pause presentation, and blocked autoplay has a large play affordance. Only `NotAllowedError` counts as blocked; a play request aborted by a replaced source keeps the stale-peer watchdog running. Live-region text changes only when its value changes.

Audio control availability follows non-ended, unmuted incoming audio tracks and their add/remove/mute/unmute events. A negotiated WebRTC audio receiver alone does not establish that the source has audio. These observations affect only viewer presentation and its local mute choice. PiP is feature-detected; closing or replacing a peer exits PiP and detaches its video. Native video full screen on phones and native video PiP display the video rather than arbitrary page elements, so the page's Sample/status strip does not accompany those native views. Physical browser behavior remains separate evidence.

Unknown or rotated viewer navigation receives a bundled, self-contained generic HTML 404. It carries no current session data and does not authorize assets, state, configuration, events, or publishing. When the old numeric address or port no longer reaches Setbeam, an HTTP page cannot replace the browser's connection error.

## Viewer identity and playback health

ViewerGateway assigns an increasing session number to each browser ID, sorts by that number, and accepts a bounded plain-text name and one of twelve preset colors. A new tab chooses its name and color on the join card before it joins, with or without approval. That one identity is saved in the tab's session storage when available, sent with `join` and every heartbeat, and labels the operator's viewer row and any shared pointer. Connection help and the pointer panel show it and reopen the same card; they have no name fields of their own. A tab restored with a pass resumes its state without the card. The color can change at any time; under approval the name cannot. Without shared pointers only the operator sees the name. There is no roster endpoint and no new publishing or administration capability. A browser session is not a unique physical device.

The existing WebRTC reader exposes an observational getStats call on its current peer. The controller samples only while receiving visible playback, using packet-loss deltas, jitter, round-trip delay, and dropped-frame deltas. Two consecutive bad or clean samples change the health indicator; it does not assume a target FPS or interpret low bitrate as a fault. Missing measurements fall back to confirmed playback. Replaced peers invalidate pending measurements. The operator resolves reported health against fresh heartbeats, current publisher revision, and authoritative Hold state. Neutral background, paused, and blocked-playback states stay distinct from connection failure. Health never changes the stream or opens another receiver, and is not a Wi-Fi signal-strength measurement.

## Viewer admission and shared pointers

Each browser tab joins through `POST join` and receives a gateway-issued secret pass. The pass, not a browser-chosen ID or name, identifies the session; operator rows show Setbeam's session number. `ViewerAccessLedger` keeps every pass for the current viewing link and is reset when the link changes. Names are bounded plain-text labels and never verified identities. Under approval a session's name is fixed once it has one; a session admitted unnamed before approval can set one first label through the join card's editor.

Viewer approval is an optional session choice. When it is off, every holder of the link is admitted and plays with the link's shared read credential, as before. When it is on, a new tab must send a name with an explicit `ask`, which the page sends only when the viewer presses Ask to join; a name saved in the tab only pre-fills the form. The tab then waits as a pending request and receives playback details only after the operator admits it and MediaMTX has accepted that session's own read-only user. Until it is admitted, the page shows a join card in place of the picture. MediaRuntime removes the shared `guest` user under approval, so the viewing-link token alone cannot read media. Removal makes the pass refused at once, so `config.json`, heartbeats, and presence stop working for it. The runtime then deletes that session's user before kicking every WebRTC and RTSP session MediaMTX reports for it, so a reconnect fails authorization while other readers continue. Reloading a pending, removed, or declined tab keeps that state without a new request. A request that lapsed, or a pass the gateway no longer knows, returns to the form rather than asking again by itself. A new tab is a new request. Turning approval on during sharing gives already-admitted sessions their own users, disconnects shared-credential readers, and advances the publisher revision so pages reconnect with their own credentials. Requests and sessions are bounded (16 pending, 128 passes). Hold keeps admissions; Stop Sharing rotates the link and clears every admission and reader. A future session password would gate `join` before this same admission step.

Approved sessions stay in the operator roster until removed or the sharing
session ends, even without heartbeats. After twelve seconds without an update,
the row says No recent update and retains Remove; it never claims fresh
playback. Ordinary link-only sessions retain their twelve-second visibility
window. Pending requests stay visible until their thirty-second request expiry.
The 128-pass bound cannot evict an approved reader to admit a new request.

Enabling approval stops the old shared audience publisher before applying
credentials and disconnecting shared readers. It starts the audience again only
after both steps succeed. A failed credential or disconnect request ends
sharing synchronously, rotates the link, and clears readers while retaining the
source and private monitoring. An uncertain controller response never rolls an
requested access policy back, including failures during private monitoring.
Unconfirmed updates remain pending for retry, and an immediate Start uses the
requested policy before publishing. The app retires invitations
and explains why sharing stopped. A later explicit Start must apply the current
authorization successfully before any audience output starts.

Shared pointers are a separate operator option. An admitted page opts in with its existing name and color, then opens the `presence` WebSocket on the existing gateway. The handshake requires a same-origin `Origin`; the first message must carry an admitted pass. The channel is a small RFC 6455 subset: masked, unfragmented text frames of at most 512 bytes, no more than 120 frames per second, a three-second hello deadline, and a 20-second silence limit. It carries only picture-relative positions in, and other participants' number, label, color, position, and remaining time out. It cannot reach media control, publishing, administration, or the operator roster.

`PointerPresence` keeps only each participant's latest position for the current publisher revision. Positions must be finite and inside the picture (0...1). Updates for another revision, while the audience is not live, or above 30 per second are dropped. A pointer stays visible for four seconds after meaningful movement (0.3% of the picture) or an explicit tap. Repeated or tiny updates do not extend it, and the server needs no final hide. Hold, Stop, a new publisher revision, a source change, removal, a closed channel, and turning pointers off clear positions. Each receiver has at most one send in flight; changes during it coalesce into the newest snapshot, and a send stuck for five seconds closes that channel. Receivers also expire each pointer locally from its remaining time.

The browser maps pointer events through the video's `object-fit: contain` rectangle, so letterboxing, resizing, and browser full screen are excluded from the picture, and controls outside it are not shared. Touch pointing turns off touch scrolling only on the picture while sharing is on. Names render with `textContent`. The native main monitor draws the same pointers over its aspect-fit picture only after the operator turns on Show pointers on this Mac. That view choice is separate from letting viewers point, is never saved, and resets when sharing stops. The floating preview's overlay covers the zoomed image rectangle, so zoom and pan move pointers with the picture. Overlays take no mouse events, never enter encoded media, and use no extra receiver. Native video full screen on phones and video picture in picture show only the video, so page pointers are absent there. Different viewers can be on different frames of moving footage, so pointers are not frame-synchronized annotations.

## Transmitter setup and permissions

Choose a source always shows a model card for the Accsoon CineView Master 4K and the Hollyland Pyro H. A card opens that model's guide inside the same sheet, so the chooser's discovery keeps running: steps for the source, the transmitter's Wi-Fi, and, for Pyro H, closing other viewers. Discovered units connect through the existing direct RTMS4 or `/live` RTSP paths. The CineView guide also offers the unverified Accsoon SEE stream bridge, alongside direct Enter Stream Address in the chooser for generic RTSP sources. Cards use drawn artwork, not product photos, and state each model's recorded evidence from `hardware-tests.md`.

Permissions, shown once on first run when no working setup exists and reopened from the Feed and settings menus, explains access by the sources the operator chooses. It reads Screen Recording, Camera, Microphone, and Location status without prompting and asks only from an Allow button, through the same calls a source uses when it starts. Local Network has no status API; its Allow button runs the chooser's own discovery for four seconds so macOS can ask. Location is never requested there, because only the transmitter Wi-Fi rejoin option needs it.

## Bare local address

A viewer who types only `setbeam.local` reaches port 80 on this Mac. The gateway itself listens on an ephemeral port on the viewing address, and every page sits under `/s/<64-character code>/`. That code is also the shared `guest` media password, so it must never be published to people who only typed a name. On the tested macOS 27 build, an unprivileged process can bind port 80 only on the wildcard address; binding it to a specific address returns `EACCES`. Without the short address, nothing listens on port 80 and the settings, invitation note, and generic unavailable page say viewers need the whole link or QR code.

## Short address

The short address is opt-in (Sharing > Options > Let viewers ask from setbeam.local, saved, off by default). It is open only while sharing, with viewer approval on, the local address offered, and a viewing network other devices can join. Turning any of those off, Stop Sharing, a new link, or Quit closes it.

ViewerGateway keeps a second path code per viewing link, 32 random bytes, distinct from the link's code and rotated with every new link and at Stop. Requests under `/s/<short-address code>/` reach the same viewer page, pass-based admission, playback, Hold, and presence code as the link. Their difference is in `ViewerAccessLedger`: a new pass from the short address needs the short address open and approval on, a name, and an explicit `ask`, and is always pending; it has its own bound of 8 of the 16 pending requests so link holders keep room. Closing the short address declines its waiting requests, and turning approval off declines them instead of admitting them with the shared credential. Sessions the operator already admitted keep their pass and playback, as do link sessions. A closed short address answers new requests with the generic 404, so the page shows the link as no longer active. Admitted short-address sessions play with their own read-only MediaMTX user under approval, exactly as link sessions do. Operator rows mark them, and the session log records only that a decision concerned the short address.

ShortAddressListener binds IPv4 `0.0.0.0:80` without address reuse, so it never shares the port with another app. It answers only once the local address is active, and only connections whose local destination (`NWConnection.currentPath.localEndpoint`) is the selected viewing address; all others close without a reply. The destination is checked again, against the same route the reply is built from, once the header has arrived, and a new viewing address closes every open request, so a request begun while the old address was selected is never answered. Each connection has a 3-second deadline and at most 16 are open at once. The header may total 4 KB however it is split into packets: reads never ask for more than what remains, and a longer header gets `431` before any of it is parsed. Only `GET /` or `HEAD /` with a `Host` that is the active `.local` name or the viewing address gets a `302 Found`, `Cache-Control: no-store`, to `http://<that host>:<gateway port>/s/<short-address code>/`. Every other method, path, or host gets 400, 404, 405, or 431 without either code. The page then runs on the gateway's own origin, so same-origin presence checks are unchanged. A new listener gives `EADDRINUSE` up to one second to clear an asynchronously cancelled socket, including a handoff between listener instances, without enabling endpoint reuse. A port that remains in use, refusal (`EACCES`/`EPERM`), and other failures are reported to the operator by name and retried every 10 seconds while the short address should be open. Stop invalidates both the short handoff retries and the ordinary retry. A new name or path updates the route in place and keeps open requests. Media still uses the numeric WHEP URL.

## Join request card

Requests under approval are announced by JoinRequestCenter, from any route. JoinRequestTracker announces each request once per viewing link by session number: heartbeats, list refreshes, a reloaded waiting tab, or a row that briefly drops out never announce it again, and a new link starts over. The card is a borderless, non-activating `NSPanel` at status-bar level in the top-trailing corner of the screen being watched: the main window's while Setbeam is in front, otherwise the floating preview's. It joins all Spaces and full-screen apps, cannot become key, and its buttons accept the first click, so other apps keep focus and keystrokes. It lists up to three requests with Admit and Decline, then a Review link to Sharing > Viewers. Truncated titles, names, routes, and devices have tooltips with the full value, shown while another app is in front. The card draws its own buttons, because system bordered buttons dim while Setbeam is inactive. Admit uses the resolved accent color, deepened under white text or lightened under dark text until the label reaches 7:1. Hover and press move the fill further from the text and add a stroke, so they never lower contrast. It hides after 20 seconds unless the pointer is over it, on dismiss, when nothing waits, and at Stop or Quit. A new request also posts a VoiceOver announcement and, when Setbeam is in the background, one informational Dock bounce. The Dock badge counts waiting requests.

A card's request is identified by its viewing link, session number, and join time. Admit or Decline from the card re-reads the gateway and acts only if that exact request is still pending on the current link, so a request decided elsewhere, lapsed, or from an earlier link does nothing. Waiting requests stay in the sharing bar, Sharing > Viewers, the floating preview's controls, the menu bar menu (with Admit and Decline), and Sharing > Show Join Requests. macOS notifications are not used: they need a permission the operator grants, a denial or Focus silences them with no working path inside the alert, and a prompt shown while nobody is at the Mac records a denial. The card needs no permission.

## Contextual setup and sharing presentation

The main window remains a local monitor. Source Details stages source name, capture rate, capture sound, saved-setup intent, and transmitter rejoin changes for one Save action. Its typed draft never publishes media. A sound-input change requires an explicit reconnect, and active viewers go on Hold through the existing source-replacement path. An empty rejoin-password draft cannot remove a stored password; open transmitter Wi-Fi is an explicit choice. RTSP entry pre-fills only network-source addresses, never incoming RTMP keys.

Sharing has one optional Invite/Viewers/Options/Chat panel and a separate native window. Source sheets remain open when the operator reviews viewers in the separate window. A focus-request counter raises an already-selected destination. Native window-close notifications retire its presentation state, rather than assuming SwiftUI removes the content view when a window closes. Presentation decisions never start or stop sharing or change Hold. Source capture remains one received feed for both monitor windows and sharing.

Unapplied address, viewer-output, network, and viewing-Wi-Fi drafts live in the UI model, so switching tabs or closing Sharing does not discard them. Applying a different viewing interface has an explicit stop-sharing confirmation; Wi-Fi QR metadata remains independent of that interface. The status control exposes outgoing-picture confirmation and audio facts through help and accessibility; Sharing has no second live thumbnail. AudiencePresentation derives operator status, target-specific actions and output facts from pending/failed control targets and observed audience availability. Main controls, menus, outgoing summaries and setup copy use that presentation. Intent alone does not confirm holding output or silence; outgoing decoder playback remains distinct from publisher readiness. Source replacement begins and completes the same Hold presentation without changing runtime ownership. The detached Sharing window has its own essential commands, while the status action opens/focuses one Sharing detail home and preserves its selected tab.

Large join codes present the same active payloads, without editors. Clicking either small code or Enlarge Codes opens the existing sheet at a larger, screen-bounded size; Done/Escape only closes presentation. Native viewer circles read ViewerActivity.color for pending and admitted rows, and the existing gateway updates that chosen color in place. The browser keeps sound in its header and discloses secondary controls on request, pointer movement or keyboard focus. Idle never hides a focused control or open editor; active shared-pointing gestures do not reveal the controls group. Permissions and diagnostics have one Settings destination, including their Help-menu shortcuts.


## Session collaboration and invitation tools

Austin's 2026-11-10 chat request narrows read-only viewer access to media. Admitted passes can write bounded session chat and shared pointers only. Publishing, source and audience controls, administration and local source frames remain private.

SessionChat keeps 100 plain-text messages, 1,200 characters per message, at most eight JPEGs of 128 KiB each and one emoji reaction per participant, capped at 128 participants per message. Replacing or removing your own reaction never adds a participant. Six reaction kinds are accepted. Message and reaction token budgets are separate, bounded per author. Legacy heart-like requests and heart counts remain compatible. The server projects own-message and selected-reaction flags for the authenticated participant, never from the display name. Replies reference message IDs. Older content and frames are evicted; removed viewers' existing messages remain until session end. Content lives in memory only and never enters SessionLog. The gateway authenticates every chat and frame request using the admitted pass. POST requires the page's exact Origin and JSON content type. Pending, refused and removed passes have no collaboration access. A new viewing token, Stop and Quit clear the store. Chat and frames use the existing plain HTTP LAN listener; both native and browser UI state that chat is not encrypted. The existing public state and SSE channel carry no chat content.

Browser attachments capture the actual displayed audience video to a bounded JPEG canvas, then preview it before Send. ImageIO checks JPEG type, dimensions, decoded pixel count and compressed size, and re-encodes without metadata. The native attachment uses the already-decoded outgoing preview, never MediaRuntime.saveFrame or the local relay. The gateway checks live audience state, a separate frame permission gate and the captured publisher revision before accepting an attachment. Hold/Resume requests and Stop close that gate immediately; source replacement and changed revisions invalidate attachments. Previously sent images remain in the conversation through Hold.

SourceDisplayPointers owns a transparent nonactivating click-through panel on the selected display UUID's full NSScreen.frame. It runs in Setbeam's own process and is therefore excluded by the existing ScreenCaptureKit application filter. It starts off, is not saved, is limited to This Mac's screen, and hides during non-live audience output. Display changes, sleep and session deactivation reset it. The operator separately chooses pointers in native previews.

ViewingWiFiBrowser can only read current/cached names or explicitly scan. It cannot associate. The editor requests Location only by operator action, keeps manual entry usable after denial, deduplicates SSIDs and marks unsupported security. Fresh scans are disabled while sharing or receiving network video. Password format feedback is separate from a real association test. A phone joining from the saved code supplies physical evidence; a current Mac connection does not validate the typed password.

JoinCodeWindow is an independent native window with optional floating level and single-code views. It observes current invitation state, loads the Wi-Fi secret explicitly and refuses unavailable passwords. Export uses synchronous QR images to make a dated PDF/print snapshot, with quiet zones, nearest-neighbor QR scaling, expiry and access labels. Save checks the session identity again after the native panel returns. Printed output calls itself a snapshot and never claims that the session is still active.

The app delegate handles Finder/Dock reopen explicitly and raises the main monitor even when other windows are visible. MainView retains an OpenWindowAction for a closed scene. The first Window scene supplies normal cold-launch presentation. Media intent is unchanged by reopening.


## Native picture and conversation presentation, build 36

The main monitor is the only persistent picture in the main window. Sharing
has no live thumbnail in either native presentation. Its status control exposes
outgoing decoder confirmation and source-audio availability through help and
accessibility. The outgoing decoder remains running for readiness checks and
chat capture; it reads the existing Mac feed and never receives the source a
second time. Hold still keeps the local picture and suppresses outgoing source
picture/audio.

Native chat uses bounded cached images as compact attachments, with enlargement
on request. Message menus and row AX actions expose reply, like and private
operator moderation. The composer keeps text and optional reply/image drafts
while secondary identity and information editors open from their own controls.
The separate window clears initial typing focus once on first presentation;
explicit Reply then focuses the draft. Chat fills the remaining panel height,
including its sharing-off state, while command bars keep their intrinsic size.
