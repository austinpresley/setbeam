# Setbeam Receiver for Google TV and Android TV

A native Android TV app that shows a Setbeam Mac's shared feed full screen on
a TV, for example from an inexpensive onn 4K box. After one-time pairing it
asks the Mac through the short address, waits for the operator's Admit, plays,
and reconnects. It is one more viewer session: it adds no endpoint,
credential, or admission rule to the Mac. The contract is
[`docs/receiver-protocol.md`](../docs/receiver-protocol.md).

**Status: software only.** Unit tests, lint, and APK builds run on the Mac.
Nothing here has run on an onn device, a 4K HDMI chain, or a cold power
cycle. Those results belong in [docs/hardware-qualification.md](docs/hardware-qualification.md)
and `docs/hardware-tests.md`, and only from watching the actual hardware.

## Layout

| Path | Owner / purpose |
| --- | --- |
| `android/` | The app (Java, no AndroidX). `app/src/main/java/com/setbeam/receiver/core` is plain Java with no Android imports and holds the protocol, policies, and state machine. JVM tests cover it. |
| `docs/native-dependencies.md` | WebRTC provenance, checksums, signature, licenses. |
| `docs/startup.md`, `scripts/` | Device provisioning and startup paths (separate tool). |
| `integration/` | End-to-end check against the real Mac stack on an emulator. |

## Build

Requirements: Android Studio's bundled JBR and the Android SDK at
`~/Library/Android/sdk` (platform 36). No Homebrew. Gradle 9.9.1 comes from
the checked-in wrapper, which verifies the distribution's SHA-256, and every
resolved dependency is verified against `android/gradle/verification-metadata.xml`.

```bash
receiver/android/build.sh          # unit tests, lint, debug APK, unsigned release APK
receiver/android/build.sh testDebugUnitTest
```

Outputs, all ignored by Git:

- `android/app/build/outputs/apk/debug/app-debug.apk`: signed with the local
  debug key, debuggable. Use it for testing.
- `android/app/build/outputs/apk/release/app-release-unsigned.apk`: needs a
  private signing key, kept outside Git, before it can be installed.

The APK bundles the WebRTC native library for `armeabi-v7a` and `arm64-v8a`.
It does not depend on anything installed on the Mac.

## Pairing

Pair once, by either of these:

- **On the TV**: choose a Mac on the first screen and press OK. This TV asks
  to join as **Setbeam TV**, or under its saved name. Each share needs Admit
  on the Mac. If your Mac is missing, choose **Enter address** and type its
  short address, such as `setbeam.local` or its local IPv4 address. You can
  name the TV on this screen. Later, open **TV options → Mac settings →
  Edit pairing** to change the name or address. A Mac appears in discovery
  while it advertises its short address. The list prefers its advertised
  `.local` name and uses the numeric address when needed.
- **By adb**, from the Mac:
  `adb shell am start -n com.setbeam.receiver/.ProvisionActivity -a com.setbeam.receiver.CONFIGURE --es setbeam_host http://setbeam.local/ --es setbeam_name "Stage TV"`.
  `receiver/scripts/setbeam-receiver provision` does this with checks and a
  receipt. Only callers holding `WRITE_SECURE_SETTINGS`, meaning the adb shell
  and the system, may start `CONFIGURE`. Other apps on the TV cannot repoint the
  receiver. Logcat tag `SetbeamProvision` records "Pairing accepted" or
  "Pairing refused", without the refused value.

Accepted hosts are an `http://` or `https://` base URL with path `/` only.
Viewing links (`/s/…`), user info, queries, and fragments are refused, so a
viewing code, which is also a media credential, is never saved. A custom port
is accepted for direct test hosts. The provisioning tool allows only port 80
for real devices. HTTPS keeps the platform's certificate and hostname checks.
Setbeam's short address is plain HTTP today, as for browsers.

Pairing changes, from setup or `CONFIGURE`, first stop a running receiver and
wait until it has stopped. Then they write the new pairing and restart the
receiver with it, including while the receiver is on screen. Pairing a
different address clears only the Bonjour id hint. Per-share records are never
cleared by re-pairing or Forget this Mac, and that includes refusals. The
records are keyed by each share's own ask path, so they can't affect another
Mac. Keeping them means a re-pair, or the same Mac typed under another alias,
can't produce a new request on a refused share. Every settings write is
checked; a failed write is reported, not assumed.

## How it finds the paired Mac

The configured host is always tried first: an IPv4 literal, or a name through
the system resolver with a 3-second bound. Android often can't resolve
`.local`, so `_setbeam._tcp` DNS-SD is a fallback after that, and the app uses
a service only if it matches the pairing:

- The service's TXT `host` must equal the configured name, or its address must
  equal the configured IPv4.
- If an installation `id` hint is recorded, only that `id` matches.
- An id is recorded as a hint only when the configured name, resolved by the
  system resolver, points to the same address the service advertises. An
  advertisement copied to another address can't make itself the hint, and it
  is never tried before the configured name's own address.

A matched service is reached at its IPv4 address with that address as `Host`,
so every later URL is numeric. Other Macs appear only in diagnostics as
"other Mac, ignored".

TXT names and ids are unverified hints. Anyone on the network can copy them.
They are not authentication, and nothing here claims to verify the Mac. The
operator's Admit on the Mac remains the access decision.

The root's `302` must name the same scheme and host that was sent and exactly
`/s/<64 hex>/`. Otherwise it is rejected. `config.json`'s WHEP URL must be the
numeric address the gateway was reached at, path `/live/whep`. Otherwise the
read-only media credential is not sent.

## Access rules

Per-share state is keyed by a SHA-256 of the ask path, never by host or IP. It
lives in app-private preferences, which are excluded from backup and device
transfer, and up to 1,024 records are kept. When the limit is reached, the
oldest non-refused records are evicted. A refusal is never evicted. If only
refusals remain, new records are refused and the receiver stops asking: it
fails closed. Passes are sealed with an Android Keystore AES-GCM key. Media
credentials stay in memory, and diagnostics never show codes, passes, or
credentials.

- **First request**: one `ask` per share. The count is written to disk and read
  back before the request is sent. If storage fails, rejects the write, or
  silently drops it, nothing is sent automatically. The screen shows Can't save
  request state, with Ask again for one explicit request.
- **Pending**: `join` with the stored pass every 2 seconds. That keeps the
  request alive and never asks again, including after an app or device
  restart.
- **Declined or removed**: media closes at once and the refusal is written to
  disk before anything else. Nothing asks on that path again, including after
  restarts, a cleared Mac ledger, or a corrupt record, which is read as
  refused. The app checks the root every 15 seconds and asks once when a
  different ask path appears, which means a new share.
- **Lapsed (`unknown`)**: shown as Asking again. The app sends at most one new
  `ask` per path every 30 seconds, checked on the persisted wall clock and on
  the monotonic clock, so a clock change cannot shorten it. After 5 requests
  on one path it waits for Ask again on the remote. A pass the Keystore could not
  seal, or can no longer open, is stored as unreadable. After a restart that
  share also waits for the remote instead of asking again.
- **Late replies**: a join, config, or heartbeat reply that arrives after a
  refusal, or for a pass that has since been replaced, changes nothing.
- **Lost contact**: after 3 consecutive failed requests, each bounded by its
  5-second deadline, the screen shows Waiting for the Mac (`searching`) instead
  of a stale pending or admitted state. This happens, for example, when Setbeam
  quits or the network drops. Refusals stay shown, and a picture still arriving
  stays Live.
  - **Kept:** the share's stored pass and admission stay as they were.
  - **Paused:** no new `ask` is sent until the Mac answers again, so failed
    attempts can't use up the share's limits.
  - **Continues:** joins with the stored pass, status polls, and rediscovery
    every 15 seconds at most.
  - **On return:** the same share resumes its request, a new share asks once,
    and a new publisher revision fetches playback details again.
- **Full (`503`)**: retried every 10 seconds. It is not counted, because the
  Mac created no request.
- **New share**: always a fresh Admit. There is no trusted-device
  auto-admission. While waiting, refused, or blocked on the remote, the
  receiver keeps checking for a new share without anyone touching the remote:
  a retired ask path's 404, the root every 15 seconds, and Bonjour arrivals.
  Searching backs off to at most 15 seconds between attempts.

## Playback

- The audience must be `live`. For `holding`, `reconnecting`, and `stopped`,
  the picture detaches and sound mutes at once, and the peer and its WHEP
  session close. Hold already suppresses outgoing media on the Mac.
- `config.json` is fetched again whenever live returns and on every publisher
  revision. Each fetch opens a new peer.
- **Transport**: native WebRTC with receive-only video and audio. ICE
  candidates are gathered first and sent in one offer to WHEP with Basic auth,
  and the WHEP session is deleted on close. A WHEP address must use the
  gateway's scheme, so an https pairing can never send credentials over http.
- **Peers**: each play is its own peer object. Its video sink, audio track,
  frame clock, WHEP target, and credentials belong to that one generation. A
  replaced or stopped peer is switched off first, so its frames are never shown
  or counted and its sound never plays. Shared audio is muted at once and
  unmuted only after every earlier peer has closed, and only for the peer that
  is still current. That decision is made under the same lock that play and
  stop use, so a stop can't land between the check and the unmute. Closing a
  peer drops its target, credentials, and session URL.
- **Picture**: decoding uses MediaCodec into a GL texture. The app's own
  `PictureView` (a `SurfaceView` with WebRTC's `EglRenderer`) fixes the surface
  buffer to the decoded size, for example 3840x2160, whatever the UI window
  size. WebRTC's `SurfaceViewRenderer` was not used: in the pinned build it
  limits its buffer to the view's size, which would draw 4K at a 1080p UI's
  size. The view has the picture's aspect ratio, so the whole frame shows
  without cropping.
- **Drawing gate**: only the current peer's generation may draw (`RenderGate`).
  A new peer or a stop first pauses the renderer, then clears it, under the
  lock that admits frames.
  - **Old frames:** from then on, the old peer's frames are refused. In the
    pinned build a paused `EglRenderer` drops a frame of the old peer that is
    still waiting to be drawn.
  - **Resume:** drawing resumes only after the new generation's own first
    frame has replaced anything pending.
  - **Exception:** the pinned renderer takes a frame and checks for pause in
    separate steps. So one frame it had already taken can still be drawn if its
    thread stalls until the next generation resumes. That's at most one frame,
    followed at once by the clear queued behind it. The public API has no
    draw-time check to prevent it.
- **Cover**: in every phase except Live and Reconnecting, an opaque layer covers
  the picture. Hold, removed, declined, ended, waiting, and searching can't
  show any earlier pixels, whatever the renderer has done.
- **Display mode**: when the current mode is smaller than the picture, the
  app requests a display mode at least as large through `preferredDisplayModeId`,
  keeping the current refresh rate if it can. This is only a request.
- **Diagnostics**: the decoded size, the requested buffer, the buffer
  `surfaceChanged` confirmed, the view size, and the current and requested
  display mode are shown separately, marked "HDMI output not verified".
- **Audio**: Opus plays in stereo through `USAGE_MEDIA`.
- **Live** appears only while decoded frames are under 2 seconds old.
  Otherwise the last frame is dimmed under Reconnecting. A peer that decodes
  nothing for 10 seconds is replaced, with backoff, and its credentials are
  fetched again.
- **SAMPLE MEDIA** shows whenever the session's state or config says
  `sample`, including over live video.
- State arrives over `events`, the server-sent events stream. Polling
  `state.json` every 1.5 s is the fallback. Heartbeats go every 3 s, and at
  once when playing changes.
- The app runs only while it is in front. Leaving it closes media and requests.
  Returning resumes the same request without asking again.

## On screen

Normal playback has no session-name or Live badge. The session name is available
in diagnostics. SAMPLE MEDIA remains visible for sample sources only.

The status card shows the current state and the next action. For example,
**Waiting for approval** tells the Mac operator which TV to admit and gives
the request number.

Press **OK** during playback to open **TV options**. Left and Right move
through one row. The white tile shows focus.

- **Sound** is focused first, so a second OK toggles mute. One Right reaches
  **Chat**. **Pop-ups** and **Pointers** follow, with icons and text that show
  their state. These choices are saved on this TV across restarts and re-pairing.
- **Mac settings** opens pairing and TV setup. **Info** opens connection
  diagnostics.

Back closes the menu, and it hides after 10 idle seconds. Playback continues
beneath it. The **TV options** button on a status card opens the same row
with Mac settings focused. The Chat label shows the unread count when pop-ups
are off.

## Chat, pointers and sound

These follow the existing viewer rules: an admitted session may read session
chat and see other participants' pointers. The receiver only reads; it never
posts, reacts, or moves a pointer. Everything here is bound to the current
admitted pass. Any refusal, removal, lapse, new share or stop cancels its
requests and clears it from the screen at once. Nothing is written to
storage.

- **Chat** opens a read-only panel on the right with the session's messages,
  replies and reaction counts. Up/Down scrolls, and Back closes it. Video
  continues beneath. Attached feed frames are not downloaded; the panel says
  "Shared a frame", with SAMPLE MEDIA when the frame came from sample media.
- **Pop-ups** (off by default) shows each new message in the lower left
  for 8 seconds, at most three at a time. Messages already in the session when
  the receiver was admitted do not pop up.
- **Pointers** (off by default) draws other admitted viewers' shared pointers
  over the picture, with their names, if the operator has shared pointers on.
  The pointers sit under the opaque cover, so none show during Hold or any
  other covered state. When the Mac doesn't offer pointers, the receiver tries
  again every 30 seconds.
- **Sound** (on by default) mutes this TV's playback without affecting other
  apps. It composes with the existing rule: sound plays only for the current
  peer after every earlier peer has closed.

Connection info adds the chat and pointer state, the Sound choice, the
receiver's version, and this TV's own IPv4 addresses.

Connection info opens diagnostics until Back closes them. An optional Info
key also toggles them directly:

- session name
- phase, admission and session number
- route and share fingerprint
- audience state, revision, and whether updates are pushed or polled
- discovery results
- shown size and frame rate
- decoded, dropped, and received frames, keyframes, decoder fps
- `decoderImplementation` and `powerEfficientDecoder`
- the MediaCodec decoder actually created, and whether `MediaCodecInfo` reports
  it as hardware
- codec and fmtp, packet loss, jitter, freezes, NACK, PLI
- audio packets
- connection state and candidate pair

With a standard TV remote, the direction pad moves between setup fields and
buttons, and OK selects the focused control. On a status card, OK activates
Ask again or TV options. Back goes up one setup screen or closes the active
overlay. At the root it uses Android’s normal behavior and can leave the app.
When an unpaired receiver holds the Home role, Back opens the TV’s settings
as a way out. An optional Menu key opens or closes TV options. An app-delivered Settings
key opens Mac settings directly; a remote's system Settings button may be
handled by the TV instead. Home, volume, and power remain system controls.
The receiver does not send Hold, Stop, or playback seeking commands to the Mac.

This is a dedicated, always-ready receiver: while it's in front, it requests
screen-on in every state, including Waiting for the Mac, Sharing ended,
declined, and removed. Otherwise a screensaver would stop the app before a
later share arrived. Those idle states show a neutral status card on an opaque
black screen that drifts a little every minute to spare the panel.

The request can't override the device's own energy-saver or inactivity sleep
(`attentive_timeout` on Android 11 and later). At setup, inspect that setting
and choose Never or off where the firmware permits; see
[docs/startup.md](docs/startup.md) and qualification row P5.

## Startup after power-on

See [docs/startup.md](docs/startup.md). The app supports these paths, and
guarantees none of them on a given TV build:

- **HOME**: `MainActivity` declares `MAIN`+`HOME`+`DEFAULT`. Declaring it
  changes nothing until the HOME role is granted, through the Home app checkbox in TV setup
  (`RoleManager` request) or the provisioning tool. A higher-priority Google TV
  launcher can still win.
- **Boot receiver**: on `BOOT_COMPLETED`, if paired and Open after restart is
  on (default), it starts `MainActivity`. Android 10 and later allow that only
  when Display over other apps (`SYSTEM_ALERT_WINDOW`) is granted. Setup links
  to that screen where the TV has one, or the tool grants it with explicit
  opt-in. Logcat tag `SetbeamBoot` records the attempt. Whether the onn
  delivers `BOOT_COMPLETED` to a sideloaded app is untested.

## Limits and open work

- **Chat and pointers**: read-only on the TV. There is no on-screen keyboard
  chat, reaction, or pointer of the receiver's own. Chat frames are not shown.
  Pointer and chat behavior is verified only on the emulator against the real
  gateway.
- **Physical**: not tested on onn hardware, through HDMI at 4K, on a cold
  power cycle, with CEC wake, for end-to-end delay, or over long runs.
  Whether a given onn decoder handles the Mac's 3840x2160 30 fps H.264 Baseline
  stream in real time is unmeasured.
- **H.264 profile negotiation**: Android's WebRTC offers H.264 Constrained
  Baseline (`42e01f`) and, where the hardware supports it, High. The integration
  run against the real MediaMTX confirms whether MediaMTX's answer matches.
- **Id hint**: if Setbeam is reinstalled on the Mac (new id), Bonjour fallback
  ignores it until the receiver is re-paired. The configured name still works
  wherever it resolves directly. A pairing to a fixed IPv4 address can't
  follow a DHCP change. Before Android 14, NSD may report only an IPv6
  address; the app retries the lookup three times, then the service is
  unusable.
- **Unattended sleep**: the screen-on request doesn't stop the device's own
  energy-saver or inactivity sleep from putting the box into standby. That
  setting is the operator's to inspect and set at setup, and whether a given
  build honors the request is unverified. The app and the provisioning tool
  don't change it.
- **Storage limits**: refusals are stored only in this app's private data.
  - **Lost on wipe**: they don't survive the loss of that data, such as
    `pm clear`, uninstalling, a factory reset, a profile or storage wipe, or a
    corrupt preferences file. Android loads a corrupt preferences file as
    empty, silently, so every refusal is lost. After such a loss, a share still
    in progress that was refused can get one new automatic request; the Mac
    shows it as a new pending request.
  - **Write failures**: if writing a refusal fails, the refusal holds only in
    memory and the screen says so. If storage recovers before a restart, that
    share may be asked once more.
  - **No expiry**: refusal records never expire, even for shares that ended.
    If 1,024 refusals accumulate, new requests stop (fail closed) until the
    app's data is cleared with `adb shell pm clear`.
- **Release signing**: the release APK is unsigned until a signing key and its
  storage are chosen.
- **Display mode and graphics memory**: the request and the confirmed buffer
  are software facts. Whether HDMI actually carries 3840x2160, whether the
  hardware composer composes a 3840x2160 layer without GPU fallback, and
  whether 4K buffers fit the box's graphics memory need the physical chain
  (qualification P1 and P6).
- **Unpaired Home**: if Setbeam holds Home before it is paired, setup stays on
  screen. Back opens the TV’s settings.
- **Audio**: audio-only stalls are not detected separately. The watchdog
  follows video.
