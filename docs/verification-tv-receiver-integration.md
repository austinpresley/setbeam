# TV receiver integration verification, 2026-11-17

Local end-to-end checks ran the native Android TV receiver (`receiver/android`)
against the real Mac stack: SetbeamCore `ViewerGateway`, the port 80
`ShortAddressListener`, and `MediaRuntime` with labeled Sample media. The
harness is in `receiver/integration`; see its README.

This is emulator software evidence only. Nothing here shows onn hardware, a
physical HDMI or 4K output, HDMI-CEC, cold power restoration, standby wake, or
Wi-Fi behavior. No physical device was attached or touched, and no hosted CI
ran.

## Inputs

| Input | SHA-256 |
| --- | --- |
| Final receiver APK (debug) | `26689524ef065a5e475e07b7f2bb7c7e135f735682371e229e721b7ba86aa372` |
| Behavior APK for the 13-case run | `5091aba6f7e5a51dfca88f24700250a16d9446a29a3978697a378240c25b6029` |
| Final provisioning tool | `67169b759a74cc21a15cbd4a01cf2d4a398b52e4ecfe808eee5468fe3eb347e2` |

Root reports that 26689524 differs from 5091aba6 only in SetupActivity help
text. The controller, gate, PictureView, player, and BootReceiver sources are
byte-identical. The 13 behavior cases were therefore not repeated on 26689524.
It received a smoke run, approval, Hold, removal, new share, 4K, privacy, and
startup.

Emulator setup:

- **AVD:** `Setbeam_TV_API36`, launched headless on emulator-5574 in its own
  process group.
- **Image:** `google/sdk_google_atv64_amati_arm64/emu64a:16/BT2A.260319.001/15058170:user/dev-keys`,
  SDK 36, arm64-v8a, 3840x2160 at density 640.
- **Network:** the emulator reached the Mac through its NAT at the Mac's en0
  LAN IPv4 (Mac A) and en1 IPv4 (Mac B), each with a real port 80 short
  address and an ask-only gateway.
- **Discovery:** mDNS was not exercised. Emulator NAT does not carry
  multicast, so the receiver used its configured host.

## Final results

Artifacts are in ignored `receiver/integration/artifacts/<run>/`: `run.log`,
`summary.json`, numbered screenshots, `ocr/*.png|txt`, fixture logs, and
provisioning output.

| Run | APK / tool | Result |
| --- | --- | --- |
| `20261117-195141` | 5091aba6 / 4c0ddc37 | All 13 behavior cases pass. startup-home fails, which became the boot-persistence finding below. |
| `20261117-201159` | 26689524 / 67169b75 | All 8 cases pass, including startup-home with a graceful reboot. |
| `20261117-201601` | 26689524 | 4K with a 1920x1080 UI: all 6 cases pass. |
| `20261117-201920` | 26689524 / 67169b75 | Graceful and hard reboot: all 5 cases pass. |

The behavior cases in `195141`:

- configure
- ask-pending
- admit-live
- hold-resume
- recovery (source helper, MediaMTX, gateway, airplane mode)
- remove-terminal (with app restart)
- newshare-decline (with app restart)
- newshare-admit
- stop-keeps-source
- unattended-ended
- unattended-searching
- reconfigure-live

### Approval, playback and refusal

- **Configuration:** a host with a code path is refused
  (`SetbeamProvision: Pairing refused`). Then `am start -n
  com.setbeam.receiver/.ProvisionActivity -a com.setbeam.receiver.CONFIGURE`
  pairs the receiver.
- **Waiting:** the receiver asks through the short address and shows "Waiting
  for the operator". While pending there are no media readers, no decoded
  frames, and a still, covered picture. The operator row is labeled "Desktop
  browser" with the receiver's chosen name.
- **Admit:**
  - Decoded counters advance (22.5 decoded fps, 24.6 shown) and the screen
    picture moves (814/960 blocks in 8 s), both in `195141`.
  - SAMPLE MEDIA is shown.
  - The operator row reports `playing` at the current revision.
- **Native rendering:**
  - The APK's only native library, `libjingle_peerconnection_so`
    (uncompressed), runs as an executable mapping of base.apk.
  - No WebView implementation library or renderer process is present.
  - A `SurfaceView[com.setbeam.receiver/...MainActivity](BLAST)` layer exists.
  - The decoder is `c2.goldfish.h264.decoder` (hardware, MediaCodec).
  - The negotiated codec is `profile-level-id=42e01f`, packetization-mode 1.
  - Opus audio packets arrive over UDP.
- **Hold:** media stops and an opaque blue "On hold" card is shown. Resume
  brings back advancing decode. The Mac's local source stayed fresh, under 3 s
  old, during Hold.
- **Remove, Decline and Stop:**
  - Remove and Decline close media and stay terminal for that share. There is
    no new ask for 20–25 s, including after `am force-stop` and a relaunch.
  - A new share (rotated ask path) asks once and plays only after Admit.
  - Stop shows "Sharing ended" with no media. Mac monitoring continued, and
    the next share needed a fresh Admit.
- **Privacy:** pending, Hold, removed, declined, and stopped screens show an
  opaque cover with no source picture.
  - At most 0.06 of the blocks lit in the last live frame match it; the same
    frame scores 1.00.
  - Screenshots: `20261117-201601/03-hold.png`, `04-removed.png`, and
    `01-pending.png`.

### Recovery and re-pairing

Each of these returned to advancing decode with no input:

- killing the source helper (revision 3→4);
- killing MediaMTX;
- a 12 s gateway outage on the same port with the ledger kept;
- 15 s of emulator airplane mode.

**Mac unreachable while pending (fixed in 5091aba6):**

- During a 14 s outage the receiver moved from waiting to searching ("Waiting
  for the Mac").
- After the outage it resumed the same pass and request number, with one row
  and no duplicate.
- After the Mac quit entirely it showed searching within 60 s.
- When sharing restarted, exactly one request reached the new share, with no
  input.

**Visible re-pairing:**

- Mac A was playing and its short address was closed, so Mac B could own
  port 80.
- CONFIGURE to Mac B, sent while MainActivity was in front, stopped A's
  heartbeats; A's row went stale.
- B received one pending request. The receiver showed waiting with B's route
  and no media.
- After Admit on B, playback was live from B.

**Idle:** in the ended and searching phases with a 20 s screen timeout, the
receiver kept the screen on (`FLAG_KEEP_SCREEN_ON`). After 45 s idle the
device stayed `Awake`, with no dream and the receiver in front. It then asked
for the next share with no input.

The Android TV attentive timeout and energy-saver behavior on real firmware
still need qualification.

### Decode figures

Measured on the emulator, `c2.goldfish.h264.decoder`, baseline 42e01f:

| Source | Decoded / shown | Buffer requested / confirmed | View | Decoded fps | Dropped |
| --- | --- | --- | --- | --- | --- |
| 1280x720 30 fps rotating pattern | 1280x720 | 1280x720 / 1280x720 | 3840x2160 | 17.9–24.8 | 91/461 to 185/525 |
| 3840x2160 30 fps rotating pattern, `wm size 1920x1080` | 3840x2160 | 3840x2160 / 3840x2160 | 1920x1080 | 10.7–10.8 | 267/450 |

- **4K buffer:** for 4K, SurfaceFlinger's BLAST consumer buffer for the
  receiver's SurfaceView is 3840x2160, while the view is 1920x1080. The buffer
  follows the decoded size, not the view.
- **Display mode:** reported as 3840x2160@60 (virtual display). HDMI output
  is not verified.
- **Speed:** the decode and drop rates are emulator limits, not a TV
  prediction. Sustained 4K on onn hardware remains a physical test.

## Startup and boot

On this Google TV image, the stock launcher's HOME priority outranks any
sideloaded app:

- `com.google.android.apps.tv.launcherx/.home.HomeActivity` has priority 2.
- `FallbackHome` has priority -1000.

`provision --allow-background-start --apply` therefore exits 3: "higher-priority
HOME activities are present…". It rolls back the HOME role. **HOME itself was
never honored**; HOME resolved to launcherx before, during, and after.

The receiver's own route is `BOOT_COMPLETED` plus the `SYSTEM_ALERT_WINDOW`
app-op. With tool 67169b75 it worked across both reboot modes, with no input
(`20261117-201920`):

| Check | Graceful (`svc power reboot`) | Hard (`adb reboot`, no framework shutdown) |
| --- | --- | --- |
| boot_id | 62026fcd… → 28d1bf69… | 28d1bf69… → 8dc7f9a1… |
| user / uid | 0 / 10104 | 0 / 10104 |
| App-op before → after boot | allow → allow | allow → allow |
| BootReceiver | `background start permitted` | `background start permitted` |
| ActivityTaskManager | `START … from uid 10104 (BAL_ALLOW_SAW_PERMISSION) result code=0` | same |
| Front after boot | `com.setbeam.receiver/.MainActivity` | same |
| Before any input | Picture changed 903/960 blocks; operator row playing, admitted session #1 | 713/960; playing |
| After INFO pressed to read stats | 23.3 decoded fps, 1022 received | 23.0 decoded fps, 1094 received |

- **Restore:** the tool restored the app-op to `default` ("Restored and
  verified"), and HOME was unchanged.
- **Cleanup:** the receiver was then uninstalled. HOME, screen and sleep
  settings, `wm` size and density, and airplane mode match the baseline
  captured before setup.
- **Not a cold-start result:** these are emulator reboots. Not tested:
  - removing and restoring power;
  - CEC wake;
  - standby resume;
  - whether onn firmware delivers `BOOT_COMPLETED` to a sideloaded app.

Earlier red evidence, kept for attribution:

- **Tool 4c0ddc37 / APK 5091aba6 and 26689524, `195141` and `200527`:**
  - The app-op was `allow` after the grant and `default` after a graceful
    reboot. BootReceiver logged "likely blocked".
  - ATM logged `Background activity launch blocked! … callingUidProcState:
    RECEIVER … result code=102`, and launcherx stayed in front.
  - In `200527`, a manual `cmd appops write-settings` returned `Current
    settings written.`, yet the grant was still lost across the graceful
    reboot.
  - With tool 67169b75, which flushes and reads back, the grant persisted.
    Why the earlier manual flush did not help was not investigated further.
- **Before 4c0ddc37:** the tool refused `--allow-background-start` "before any
  change". On this image `appops get com.setbeam.receiver
  SYSTEM_ALERT_WINDOW` prints `No operations.` / `Default mode: default`. The
  refusal was safe, with no receipt and HOME unchanged.

## Defects found in the app and tool

| Found on | Defect | Status |
| --- | --- | --- |
| APK 4190f97b, 87dfb74b, 045d775c | After the Mac became unreachable while a request was pending, the receiver kept "Waiting for the operator… admit (session 1)", `Phase waiting`, `Connection none` for over 60 s. It never searched. | Fixed in 5091aba6. Searching, same pass, one ask per new share. |
| Tool before 4c0ddc37 | The two-line `No operations.` / `Default mode: default` app-op output was not parsed. The tool refused the overlay grant before any change. | Fixed in 4c0ddc37. |
| Tool 4c0ddc37 | The app-op grant did not survive an emulator reboot, so the boot start was blocked by BAL. | Fixed in 67169b75 (flush and readback). Persisted across graceful and hard reboots. |

## Harness corrections

Each was found by reading the evidence, then corrected. None weakens a
picture or privacy assertion.

- **Picture motion:** the bundled Demo clip is 8 s and nearly still in the
  sampled band (≤1/960 blocks change), so pixel motion could not be required
  for it. Generated sources now rotate `testsrc2`.
- **Privacy metric:** the first stale-picture metric counted black-on-black
  blocks and reported 583/960 on a correct opaque cover. It now compares only
  blocks lit in the last live frame.
- **Gateway outage:** it used `ViewerGateway.stop()`, which resets the ledger
  and ask path, so it amounted to a new share. It now uses
  `gateway.start(address:port:)` as SessionModel's network recovery does.
- **Mac B on port 8080:** the receiver correctly sent `Host: ip:8080`, and the
  listener correctly answered 404, because only the bare IP or `:80` is
  accepted. Mac B now uses a second Mac address on port 80.
- **Smaller fixes:**
  - The native-library check wrongly expected a library path and treated the
    system WebView loader stubs as a WebView.
  - Decoder statistics were read before a new peer reported them.
  - The INFO overlay toggle could flip back on a single OCR miss.
  - The app-op was compared by raw text instead of by mode.
  - A parameter-name clash and a remove-precondition IndexError.

## Environment findings

- **adb server crashes:** the host adb server repeatedly aborted (SIGABRT in
  `adbmdns_bridge` … `FQServiceName::try_from`; about 40 crash reports) and
  dropped every client. `ADB_MDNS=0` stopped it. The harness runs its own adb
  server on port 5137 with mDNS off.
- **Large `adb exec-out` output:** screencap and streamed install took the
  server down. The harness uses `screencap <file>` + `pull`, and `push` +
  `pm install`.
- **UIAutomator:** it reports `could not get idle state` while video plays.
  Diagnostics are read by Vision OCR from screenshots instead.

## Remaining qualification

- **Physical onn tests:** these need recorded evidence in
  `docs/hardware-tests.md` or `receiver/docs/hardware-qualification.md`:
  - the exact model and firmware;
  - HOME priorities on the device;
  - `BOOT_COMPLETED` delivery and the SAW boot start after a real power cut;
  - CEC wake and standby resume;
  - sustained 4K30 H.264 hardware decode;
  - true 3840x2160 HDMI output and display-mode switching;
  - Wi-Fi recovery;
  - attentive timeout and energy saver.
- **Not run on the emulator:** mDNS discovery of `_setbeam._tcp` and `.local`
  resolution, because NAT carries no multicast.
- **No long-duration soak** was run.

## Commands

```bash
python3 receiver/integration/tv_emulator.py start
python3 receiver/integration/tv_e2e.py --serial emulator-5574 --fresh --reboot \
  --apk <hashed copy> --provision-tool <hashed copy>
python3 receiver/integration/tv_e2e.py --serial emulator-5574 --source 4k --ui-size 1920x1080 \
  --cases configure,ask-pending,admit-live,hold-resume,remove-terminal --skip-startup --apk <hashed copy>
python3 receiver/integration/tv_e2e.py --serial emulator-5574 --cases configure,ask-pending,admit-live,startup-home \
  --reboot --reboot-mode both --apk <hashed copy> --provision-tool <hashed copy>
python3 receiver/integration/tv_emulator.py stop
```

Cleanup:

- The emulator was stopped (owned PID only), and the private adb server
  stopped.
- Fixtures confirmed `CLEANUP owned media processes exited` in every run.
- Port 80 and port 5137 are free.
- The receiver was uninstalled, and the AVD's HOME and settings match the
  baseline.
- Runtime state was deleted. Artifacts remain in ignored directories.
