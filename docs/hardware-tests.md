# Physical hardware tests

Compatibility is limited to the exact route, format, firmware, and host recorded below. Other model names remain test targets.

## Physical iPad Safari Sample check, 2026-11-23

An iPad Pro 10.5-inch on iPadOS 17.7.11 joined the build 43 Sample share
over the local network. Safari WebDriver drove the test on the physical
iPad. It populated and submitted the join form after the automated keyboard
left the name empty. Safari decoded 1280 × 720 video, reported advancing
playback, and fit the page without horizontal overflow. The Mac recorded
one other-device viewer playing. Hold detached and muted playback, Resume
returned video in the same tab, and Stop ended playback while the Mac kept
monitoring. This check used muted browser playback. Physical keyboard
entry, rotation, screen lock, and audible output remain open for this build.

## Physical phone sample check, 2026-10-20

Austin scanned the sample session QR and followed the Safari viewing/sound workflow on a physical phone on the Mac's Ethernet LAN. He reported that sample video and the audible test tone both worked. The app independently recorded fresh playback from one other-device endpoint, distinct from the local Chromium browser. After a 30-second phone lock and return to the same Safari tab without reload, Austin reported automatic picture and tone recovery. He also confirmed a visible holding state with silence and automatic picture/tone return on the same page after Resume. Phone model and OS version were not supplied. These are sample-media browser results; real-feed viewing and power-cycle recovery are recorded in the build 7 section below. Native Mac speaker sound remains unverified. See [session safeguard verification](verification-safety-2026-10-20.md).

| Target | Candidate route | Current evidence | Next physical check |
| --- | --- | --- | --- |
| Hollyland Pyro H | Direct transmitter Wi-Fi RTSP `/live`, upstream ports 5554/554/8554 | Native software port and simulated H.264/AAC discovery/media checks pass; physical Setbeam test not run | Record exact model/firmware, actual endpoint/SDP, picture/audio, single-client behavior, reconnect, Hold/Resume/Stop and source formats |
| Hollyland Mars 300 Pro | Direct Wi-Fi investigation; receiver HDMI capture fallback | Vendor app monitoring documented; our input unverified | Confirm revision/firmware, vendor-app baseline, and usable Mac input |
| Accsoon CineView Master 4K, product IDs 21 and 24 observed on the same unit, firmware 3.30, hardware raw 256 | Direct RTMS4 Wi-Fi input | Passed real 1080p60 computer display, encoded audio, native/browser/physical-phone playback, Hold/Stop, restoration and recovery after a power cycle with manual Wi-Fi rejoin on Apple Silicon/macOS 27 | Camera content, format changes, audible source sound/A/V timing, long sessions and coexistence; short-run continuous criterion failed 2/116 samples |
| Original Hollyland Mars 300 | Receiver HDMI through compatible capture device | HDMI topology documented; no direct network input established | Confirm physical receiver output and captured picture/audio |
| onn 4K Google TV receiver candidate, exact SKU and firmware not recorded | Native Setbeam Receiver WebRTC viewing, HDMI to a display | Developer software only; no physical receiver or HDMI qualification | Record exact model/OS/build, startup path and energy-saver setting, cold power and CEC wake, Wi-Fi recovery, Mac admission/Hold/Remove/Stop, sustained 4K30 decode, buffer/composition memory and actual HDMI mode; use [receiver checklist](../receiver/docs/hardware-qualification.md) |

For every pass or failure, record model, variant, firmware, Mac architecture,
connection route, input format, audio, measured delay, source-loss recovery,
and interaction with other receivers or vendor apps. Record simultaneous
source operation separately.

## Source-content coverage

For each viable connection route, test both a computer display and camera video. A DigiTech screen such as Capture One is a primary workflow. The Master 4K computer-display result below covers a live clock/browser picture, small text, aspect ratio, and source-loss recovery. Capture One specifically, camera content, format changes, and display-sleep behavior still need testing.

Native screen and window capture are routes of their own. Generated display and
window fixtures exercise them in development. They do not cover a real Capture
One workstation or a display coming in through wireless or HDMI capture.

## Current manual rehearsals

Both gates are open. Run them on the candidate build before relying on either
workflow on set. Use a separate phone or tablet on the intended viewing network.
Record the Setbeam version and build, macOS and viewer OS/browser, source and
viewing routes, exact equipment and firmware, picture format, audio choice, and
what happened at each step. Save timestamps, recovery times and redacted evidence.
Use a test session and leave viewing links and Wi-Fi credentials out of the record.

### Capture One computer display

1. Open a test Capture One session with fine text, a detailed image and a crop.
   Select the actual shoot route in Setbeam. For an on-Mac workflow, use
   **Window → Capture One**. For a separate DigiTech workstation, select its
   wireless transmitter or capture input and record that route separately.
2. Confirm the full image and readable text in the private and floating
   monitors. Set the viewer output to **Best** and **1 fps** for still review.
   Run **Test My Setup** with viewer approval on and sound not required for a
   silent capture. Scan the Watch code from the separate device. Match its
   session and route in People, admit it and wait for fresh video.
3. Change the selected image and crop. Check that text stays readable and the
   new image reaches the viewer without clipping. For window capture, move,
   cover, resize and minimize the chosen window. Restore it and check that
   only that window returns. Close it with a same-titled window still open and
   check that Setbeam offers **Choose a Window** without switching. For an external route, interrupt the input
   or sleep the source display, then verify the same feed returns.
4. Confirm Hold conceals the source on the viewer while the operator can
   keep working. Resume in the same tab, then Stop Sharing and verify the
   test link expires while private monitoring continues.

### Camera feed

1. Use the camera and capture device or wireless transmitter planned for the
   shoot. Record the exact camera mode, cable and the capture device or
   transmitter model, firmware and connection route. Use a moving subject
   and a deliberate sound cue if the feed will carry sound. For a local
   capture input, choose the exact sound input in Source Details.
2. Run **Test My Setup** on the intended viewing network. Admit the test
   device if approval is on. Confirm motion and the full frame locally and
   on the device. For a sound feed, enable sound on the device and check
   audibility and sync against the cue. Record audio track presence separately.
3. Put viewers on Hold. Check source video and sound are suppressed on the
   test device while the local picture continues. Resume and confirm the
   same page recovers. Disconnect and reconnect the input. Verify it
   recovers the exact source and record how long recovery takes. Repeat for
   any mode change required during the shoot.
4. Stop Sharing and verify the local monitor continues and the viewing link
   expires. Record any failed or skipped step with the observed behavior.

## CineView Master 4K live investigation, 2026-10-20

Austin powered the unit and authorized autonomous network discovery and Wi-Fi connection. System Settings showed Accsoon_11D5 and the companion accsoon-2.4g-grp1 / accsoon-6g-grp1 networks. Joining the documented 5 GHz network succeeded. The Mac obtained 10.0.1.10/24 and could ping the gateway at 10.0.1.1. Ethernet remained the default internet route. No firmware or transmitter settings were changed.

The bounded TCP checks for HTTP/HTTPS, common RTSP/RTMP ports, and candidate control ports 28100/28101 did not connect. This does not prove there is no proprietary or UDP input. No video protocol was inferred from the SSID or IP address.

Austin completed App Store authentication and explicitly authorized accepting SEE's agreement. Accsoon SEE 1.9.3 was installed, but its Master 4K device list stayed empty on this Ethernet-plus-Wi-Fi Mac. A vendor-picture baseline therefore did not pass. SEE was quit before direct testing because both apps use UDP 28001. The integration research is recorded under docs/research. The generic RTMP test remains separate from the physically proven direct route.

### Direct input result

The direct RTMS4 input passed on this CineView Master 4K, product ID 21, firmware 3.30/raw 798, hardware version raw 256/0x0100, on the Apple M6 development Mac running macOS 27. No separate receiver or capture device was used. No vendor binary is bundled. Discovery and status came from the unit, not a guessed stream address.

The transmitter advertised a real computer display at 1920×1080p60, and the local export is 1920×1080. Encoded HEVC was reassembled and decoded, then converted to H.264 for the local relay and browser compatibility. The live clock and fine page/menu text are legible in the exported 1920×1080 frame. The observed AAC 48 kHz stereo input also produced an Opus track and a live browser audio track. Native audible output and A/V timing remain unverified because this Mac's audio device did not respond; video and controls continued through the explained mute fallback. Source HDMI versus SDI wiring was not independently inspected.

The real-source probe exported local, audience, and holding pictures. Local reception continued through Hold and Stop. Native/browser playback and automatic restoration also passed below.

A real source-loss event occurred during the investigation: the transmitter remained reachable while its advertised media-stream arrays became empty. The app now uses those arrays, rather than the outer valid flags, to show that a camera/computer picture is needed. Austin restored the physical source and live reception then passed. That event is distinct from an automated helper-failure check.

Native and Chromium checks also passed with this real feed: one-click selection of the discovered model/SSID, private main/floating playback, sustained confirmation and saved setup, opened versus playing viewer counts, live browser audio/video tracks, Hold/Resume on the same page, and Stop preserving native/floating frames. The 390×844 and 1280×800 browser layouts fit without overflow. This is Chromium on the development Mac, not a physical phone or Safari test.

The app recovered from a deliberately killed, owned Accsoon input helper in 4.3 seconds. The test observed the unavailable state, then fresh native frames on the same saved setup, with sharing still off. This is a physical-source test with an injected software failure, not a transmitter power-cycle test.

Wi-Fi was deliberately switched off, then the saved Accsoon_11D5 network was rejoined. Fresh main/floating frames returned automatically on the same saved setup and sharing remained off. Ethernet retained the default internet route throughout. The recorded 48.97-second interruption includes the deliberate off interval and manual network selection; it is not a reconnect-latency measurement.

Normal Quit from an active held session stopped all eight owned descendants. The distribution copy launched from `/tmp` restored the same physical source and floating monitor, with sharing/Hold off. Final HEVC parameter replay supports a decoder that misses initial parameter packets, with bounded cache tests and clean native startup verified.

Remaining physical coverage includes camera content, another firmware, source format changes, transmitter power cycles, actual audible sound and A/V synchronization, latency, range, long sessions, second-device viewing, phone QR scanning/Safari, and coexistence with receivers or SEE. These results do not establish 4K input/output support despite the model name.

### Build 6 recovery check, 2026-10-20

The updated receiver was retested against the same product ID 21, firmware 3.30 unit and live computer-display source, using the finished build's bundled media helpers and fixtures. Wi-Fi selection was left unchanged. Direct video decoded/exported, HEVC converted to H.264, and AAC produced an Opus track. Local monitoring survived audience Hold and Stop.

Three deliberately killed owned source helpers recovered fresh video automatically in 2.51, 2.97, and 3.01 seconds, retaining the active audience Hold and viewing credential. A following 120.5-second check recorded 118 fresh local-source and holding-audience samples with zero unavailable samples. The probe verified owned-process cleanup afterward. This is a short physical-source check with injected software failures, not transmitter power cycling, Wi-Fi loss, a long-session qualification, or a latency measurement. Logs are ignored under `build/logs/reconnect-accsoon-live.log`.

### Build 7 same-unit product-status check, 2026-10-20

The saved Master 4K UID and Accsoon_11D5 were observed reporting product ID 24 at firmware 3.30/raw 798. The earlier retained status JSON reports product ID 21. Austin confirmed this is the same exact physical unit. No firmware or transmitter settings were changed by this pass, and the reason for the differing product field is not established. The old product-21-only filter hid the unit. A regression failed on the observed product-24 status before recognition was updated to accept both observed values; unrelated product 999 remains unrecognized.

Direct reception with product 24 passed real 1920×1080 computer-display export, HEVC-to-H.264 conversion, an Opus audio track, outgoing live and holding picture capture, silent encoded Hold, and local monitoring through Hold/Stop. Three forced source-helper failures recovered in 2.37, 2.60, and 2.32 seconds with Hold and viewing credential retained. The following 120-second continuous-run criterion **failed** with 2 unavailable samples among 116. This is not a clean continuous pass, and the unavailable readings' cause and duration were not independently measured. Logs are ignored under `build/logs/safety-product24-physical.log`.

In the updated native app, Austin scanned the real-feed QR and confirmed that Safari showed the transmitter's computer display. App telemetry independently confirmed fresh playback on the other device. Austin then physically powered the transmitter off and back on while the viewing page stayed open. During loss, source/native/outgoing readiness cleared, the last native picture was marked stale, and the viewer reconnected with playback closed and muted. macOS switched the Mac's Wi-Fi to its regular LAN during the outage. After Austin manually rejoined Accsoon_11D5, the same saved source, fresh native and outgoing frames, and other-device playback returned without an app Retry or browser reload. The viewing link/credential stayed unchanged. Austin confirmed the real phone picture returned without reload. This pass includes a manual Wi-Fi rejoin; automatic Wi-Fi association is not implemented. The two-hour qualification was explicitly deferred to Austin's next session.
