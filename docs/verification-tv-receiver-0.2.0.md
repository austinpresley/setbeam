# TV receiver 0.2.0 verification

Date: 2026-11-18. Austin asked to fully build out the Android TV app,
unattended. Receiver 0.2.0, version code 4, adds the viewer features an
admitted session already has, read-only, plus setup and display choices:

- **Session chat**: read-only panel from the menu, and optional pop-ups
  (off by default).
- **Shared pointers**: other admitted viewers' pointers over the picture,
  optional (off by default).
- **Sound**: an On/Off choice for this TV.
- **Setup**: lists Macs on this network to fill in the address.
- **Menu**: a second row and simple icons on every menu button.
- **Connection info**: adds chat/pointer state, the version and this TV's
  addresses.

No Mac source, endpoint, credential or admission rule changed. The receiver
uses the existing `chat` and `presence` endpoints the browser viewer uses
([protocol](receiver-protocol.md)). It never posts chat, reacts, or sends a
pointer.

All results below are software evidence from the Mac and the Google TV
emulator. Nothing here ran on onn hardware, and no hardware claim changed.

## Frozen inputs

- Developer APK SHA-256:
  `1878a8187967d97d049d6a2652bf0d79df57affcc29f39bd67f0a2dee3b22614`,
  20,254,590 bytes.
- Version 0.2.0, code 4, debuggable, signed with the existing developer
  certificate `2216d2895332572f9b98fe0fa8e46a2d5c9e94c13adb1e7de137edd3a37d1eb7`.
- Final emulator run: `receiver/integration/artifacts/20261118-043240`
  (ignored).

## Design

- `core/SessionExtras` holds chat and pointers.
  `ReceiverController.publish()` binds it only while the current pass is
  admitted and the share is not stopped. Refusal, removal, lapse, a new
  share, Stop Sharing or stopping the receiver unbinds it. Unbinding cancels
  its requests and clears chat and pointers before the next screen update.
- Chat is fetched when an admitted heartbeat's `chatLastID` changes. While
  the panel is open, it is also refreshed every 5 s. Messages are kept in
  memory only, and attached frames are not downloaded.
- Pointers use a small RFC 6455 client (`core/WebSocket`) on `presence`, sent
  with the `Origin` the Mac expects. The receiver sends only `hello` and
  pings. Pointers draw inside the picture's aspect-fit frame and under the
  opaque cover, so none show during Hold or any other covered state.
- Sound mutes under the same lock as the existing rule: sound plays only for
  the current peer, after every earlier peer has closed.
- The setup list uses `_setbeam._tcp` and fills in the advertised `.local`
  name. It falls back to the IPv4 address only when the name is unusable, and
  ignores services not on port 80. Saving is still explicit.

## Review and corrections

An independent Opus 5.5 review of the full diff found these issues, each now
fixed with a regression test:

1. **Pointer keepalive.** The first client pinged only after 8 s without
   receiving anything. The Mac closes a channel it hasn't heard from in 20 s.
   So while another viewer kept the Mac sending, the TV never pinged and lost
   its channel about every 20 s. Pings now follow the receiver's own sending.
   - Unit test: a server sends pointers every 100 ms and requires pings.
   - Emulator: the case requires the pointer to still be shown after 25 s.
2. **Stop Sharing.** Chat from a stopped share stayed bound until the next
   reply. Binding now also requires a share that is not stopped.
3. **Repeatable e2e case.** The case toggled settings blindly. It now reads
   each On/Off label first and restores the defaults at the end.
4. **Chat panel focus.** D-pad focus could leave the panel. It now stays in
   the panel, and Ask again no longer takes focus while chat is open.
5. **Other ports.** Nearby services on ports other than 80 are now ignored.
6. **Denial reason.** An empty denial reason now reads as `access`.

## Local results

- **Android build** (offline, with the checked-in Gradle and dependency
  verification):
  - 86 JVM tests pass: the 69 earlier tests, plus 17 for chat, pointers, the
    WebSocket and nearby Macs.
  - Lint: zero errors and 18 warnings, the same count as 0.1.2.
  - Debug and unsigned release APKs assemble.
  - A mutation that bound chat while the request was pending failed five of
    the new tests, as intended.
  - The new suite passed three consecutive reruns after a race in the test
    itself was fixed (it read the loop's post count after queuing a pointer).
- **APK check**: `setbeam-receiver verify-apk --expect-signer` passes. It
  confirms the guarded CONFIGURE activity, the overlay declaration and the boot
  receiver.
- **Full local `scripts/check.sh`**: exit 0 in 12 min 8 s.
  - 310 Swift tests, with one opt-in soak skipped.
  - Five Python preview cases and 59 Node cases (47 recovery, 12 pointers).
  - Every media stage passes. The 1,750 KB keyframe stage decodes 523 frames
    in 7 s without errors.

## Emulator, real Mac stack

`tv_e2e.py` drove the `Setbeam_TV_API36` Google TV emulator (3840x2160
display) against the real `ViewerGateway`, short address and MediaMTX in the
fixture. The run used `--fresh --skip-startup`, and all eight steps pass:
preflight, configure, ask-pending, admit-live, remote-controls,
chat-pointers, hold-resume and remove-terminal.

The new `chat-pointers` case uses the remote only:

- OK, Down, Right, OK turns on Pop-ups, and Right, OK turns on Pointers.
- A fixture operator message pops up over live video and leaves by itself.
- The Chat panel shows it. Video keeps moving beneath it, SAMPLE MEDIA stays
  visible, and Back closes it without leaving the app.
- `PointerBot`, a second, browser-like viewer, asks through the short address.
  It is admitted and moves a pointer 576 times. The pointer's name shows over
  the TV picture, is still shown after 25 s, and fades after the bot stops.
- The receiver's own request row is unchanged, diagnostics report chat and
  pointers, and playback is live afterwards at 26.6 decoded fps.

Hold and removal still cover the picture, which now includes pointers.

Captures: menu with icons, chat pop-up, chat panel and shared pointer.

The fixture's owned media processes exited, and settings and HOME match the
baseline. The receiver was uninstalled afterwards. The emulator and private
adb servers are stopped, with no leftover fixture, adb or emulator process.

### Failures on the way

- **Runs 1 and 2**: `remote-controls` and `chat-pointers` failed.
  - The 4K screenshots took 14.1 s, longer than the menu's 10 s idle timeout,
    so the menu closed before OK. The harness now reopens the menu when the
    observation outlasts the timeout. The timeout itself is still tested in
    the same case.
  - OCR read the larger menu's "Connection info" as "Connection into". Menu
    detection accepts both readings.
- **Runs 3 and 4**: one OCR read over moving video dropped a diagnostics line
  ("Decoded", then "Video"). The final live read now retries until those
  fields are legible.
- No app behavior changed for these. The menu and diagnostics worked when
  driven by hand on the emulator. Those runs show what the harness checked,
  not missing UI.

## Not verified

- **Mac list in setup**: the fixture doesn't advertise Bonjour, so the list
  is covered by unit tests only. On the emulator it showed its empty
  "Looking…" state.
- **Chat at scale**: long chats, reactions and replies render only in unit
  parsing tests. The emulator showed one operator message.
- **Physical hardware**: onn hardware, HDMI, sound through a real TV, and
  pointer timing over Wi-Fi are open, as before.

## Delivery

The [APK, five screenshots, guide, this record and checksums](https://drive.google.com/drive/folders/1JWAD4wLfm9KGshqXK7gOPmKDtP0J6KOW)
are delivered with remote verification, delivery `20261118T094113Z--5199e96d8b69`.
Local copies are under ignored `build/deliveries/tv-receiver-0.2.0/`.
