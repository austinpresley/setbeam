# Receiver integration check

Local end-to-end check of the native Android TV receiver
(`receiver/android`) against the real Mac stack. Nothing here runs in hosted
CI. Emulator results are software evidence. They do not show onn hardware,
HDMI output, or cold-power behavior.

## Pieces

- `Sources/SetbeamReceiverFixture`: a Swift executable linking the root
  package's `SetbeamCore`. It runs a real `MediaRuntime` with the labeled
  Sample source, a real `ViewerGateway` under viewer approval, and a real
  `ShortAddressListener` on port 80 for one chosen LAN viewing address. It
  wires them in the same order as `SessionModel`: it applies admitted readers
  to the media server before the gateway confirms them, publishes each
  runtime snapshot to the gateway, and retires the ask path with each new
  link. Nothing is advertised by mDNS.
  The fixture has a bounded lifetime (`--lifetime`). It exits when its
  controller exits, and it shuts down the runtime, which ends owned media
  processes, before it exits.
- `tv_e2e.py`: drives the fixture and one emulator through adb.
- `tv_emulator.py`: starts and stops the dedicated `Setbeam_TV_API36` AVD
  headless on an explicit console port in its own process group. It records
  the PID under `.build/emulator/`.

## Control files

Write `runtime/<run>/commands/<n>.json`, such as
`{"command":"admit","name":"Stage TV Test"}`, numbered from 1. Then read
`acks/<n>.json`. The fixture rewrites `status.json` about every 250 ms with
sharing, Hold, revision, listener state, monitoring freshness, and one row per
viewer: name, admission, heartbeat playing/health/revision, and short-address
origin.

Commands:

- `admit`, `decline`, `remove`: select the viewer by `name` or `number`.
- `hold`, `resume`.
- `stop`: Stop Sharing; local monitoring continues.
- `start`.
- `newshare`: Stop, then Start, which creates a new link and ask path.
- `close-short`, `open-short`.
- `source-outage`: kills the owned source helper.
- `server-outage`: kills the owned MediaMTX.
- `gateway-outage` with `seconds`: restarts the gateway on the same port.
- `chat` with `text`: posts an operator (DigiTech) message, as the Mac's Chat
  panel does.
- `pointers` with `on`: turns shared pointers on or off; approval stays on.
- `quit`.

Status and logs never contain the viewing code, ask code, passes, or media
credentials. Ask paths appear only as 6-byte SHA-256 fingerprints.

## Observation

- Static setup uses Android's UIAutomator hierarchy for screen and field
  assertions. The same run takes screenshots for visual review.
- `Sources/ScreenText`: a Vision OCR tool that reads the receiver's diagnostics
  overlay from screenshots. KEYCODE_INFO toggles the overlay. UIAutomator
  cannot dump the UI while video plays because it never goes idle. With
  `--grid`, the tool prints 960 luma block means of the band between the top
  labels and the overlay.
- Picture checks:
  - Live: the picture must change.
  - Not live: the picture must stay still.
  - Privacy: fewer than half of the blocks that were lit in the last live
    frame may match it.
- Generated sources are rotating `testsrc2` patterns with a tone, served as the
  labeled Sample. The bundled Demo clip barely moves in the sampled band, so
  `--source demo` skips the motion requirement.
- Screenshots go through `screencap <file>` followed by `adb pull`.
  `adb exec-out` with large output crashed the adb server.
- The controller owns a private adb server on `--adb-port` (5137) with
  `ADB_MDNS=0`. The shared server's mDNS bridge aborted repeatedly on this
  network.

## Run

```bash
python3 receiver/integration/tv_emulator.py start            # emulator-5574, own process group
python3 receiver/integration/tv_e2e.py --serial emulator-5574 --fresh --reboot
python3 receiver/integration/tv_e2e.py --serial emulator-5574 --source 4k --ui-size 1920x1080 \
    --cases configure,ask-pending,admit-live,hold-resume,remove-terminal --skip-startup
python3 receiver/integration/tv_emulator.py stop
```

Options:

- `--viewer-address`: Mac A's LAN IPv4, from en0 by default.
- `--second-address`: Mac B, from en1 by default. Both use port 80, because the
  short address only answers there.
- `--source pattern|4k|demo`
- `--ui-size`: a temporary `wm size`, restored at the end.
- `--reboot --reboot-mode graceful|hard|both`
- `--provision-tool`: the tool file is copied and hashed for each run.
- `--flush-appops`: an explicit `cmd appops write-settings`, for diagnosis.
- `--cases`: a comma list of case names.
- `--check-remote-setup`: opt into the first-run D-pad and DNS-SD test. Requires
  `--fresh` and a network that carries Bonjour to the emulator.

The controller copies the APK into the run's artifacts and records its
SHA-256. It accepts only `emulator-*` serials whose device reports
`ro.kernel.qemu=1`. It restores sleep settings, `wm` size/density and airplane
mode, and checks HOME against the captured baseline. It exits nonzero if any
case fails or any restore differs. SIGINT and SIGTERM stop the fixtures and
the adb server.

## Cases

- `configure`: rejects a host with a code path, then pairs with an explicit
  CONFIGURE component. With `--fresh --check-remote-setup`, it also opens first-run setup with the remote,
  checks manual address entry and Back, and publishes a temporary DNS-SD
  advertisement for the fixture. One OK on the Mac row must reach a pending
  short-address request with zero media readers.
- `ask-pending`: no reader, no decoded frames, a still picture.
- `admit-live`:
  - Decoded frames advance and the picture moves.
  - SAMPLE MEDIA is visible and the decoded size is as expected.
  - The operator row shows this receiver playing the current revision.
  - Native evidence: an executable mapping of base.apk, no WebView library or
    renderer, a SurfaceView layer, and a MediaCodec decoder.
  - With 4K, the SurfaceView buffer must be 3840x2160.
- `remote-controls`: OK opens TV options. Left and Right reach each control
  on the strip. Back dismisses each overlay without leaving playback. Video continues beneath the menu. It hides after 10 seconds
  idle and navigation resets the timeout. Clean playback has no title/Live badge
  while SAMPLE MEDIA stays visible. Setup returns to the same admitted share.
- `chat-pointers`: with the remote only, turns on Pop-ups and Pointers in
  the menu strip, and checks that Sound toggles both ways. An operator chat message pops up over playback and
  then leaves. The Chat panel shows it with video continuing beneath, and Back
  closes it. A second, browser-like viewer (`PointerBot`) asks through the
  short address, is admitted, and moves a shared pointer. Its name must appear
  over the TV picture and fade after it stops. The receiver's own request is
  unchanged, and playback is still live afterwards.
- `hold-resume`: no media and the privacy cover while held; the Mac's local
  source stays fresh.
- `recovery`: source helper, MediaMTX, a ledger-preserving gateway outage, and
  device airplane mode.
- `remove-terminal`: includes an app restart.
- `newshare-decline`: includes an app restart.
- `newshare-admit`
- `stop-keeps-source`
- `unattended-ended`: 45 s idle with a 20 s screen timeout, then a new share
  with no input.
- `unattended-searching`: a 14 s outage while pending, then the Mac quits,
  then a new share asks exactly once.
- `reconfigure-live`: CONFIGURE to Mac B while A plays, with no force-stop.
- `startup-home`: provisioning-tool HOME and boot-start grant, emulator
  reboot(s), live playback after boot with no input, then restore.

Artifacts, runtime state, and build output stay under ignored `artifacts/`,
`runtime/`, and `.build/`.
