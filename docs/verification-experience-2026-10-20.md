# Build 3 experience verification

Date: 2026-10-20. Version 0.2.0, build 3. Host: Apple M6, macOS 27, Swift 6.4. Build target: Apple Silicon, macOS 14 or later. This extends the historical prototype record in [verification-2026-10-20.md](verification-2026-10-20.md).

## Automated and packaged checks

`scripts/check.sh` passed using the helpers and fixtures inside the finished app. All 26 Swift tests pass, including source/session transitions, redaction, sustained readiness, preservation of a proven setup, exact Accsoon identity/status parsing, bounded fragment assembly, progressing-gap expiry, HEVC parameter replay, AAC packetization, and viewer access restrictions.

The actual-media integration probe passed:

- Flowing sample H.264 video and Opus audio.
- Authenticated full-URL RTSP and authenticated incoming RTMP, including stable restored input destination.
- Rejected anonymous administration and guest publishing.
- Actual outgoing Hold video replacement and decoded silent audio while the local source continues.
- Stop sharing preserving local monitoring.
- Crashed and running-but-stalled source recovery with fresh-frame readiness.
- Media-server recovery retaining the viewing credential and silent in-session Hold.
- Shutdown of owned media processes.

Separate direct physical Master 4K probes passed HEVC-to-H.264 decoding, AAC-to-Opus, frame export, local/audience playback, Hold, and Stop. Generic RTMP results do not stand in for these hardware tests.

Local ignored logs include `build/logs/experience-final-packaged.log`, `swift-tests.log`, `accsoon-live-probe.log`, `accsoon-live-audio-probe.log`, `accsoon-helper-recovery.json`, `accsoon-network-recovery.json`, and `experience-final-force-quit.log`. Runtime captures, session links, and diagnostics remain private and are excluded from Git and delivery.

## Native and browser checks

The native chooser identifies the discovered CineView Master 4K and Accsoon_11D5 network with an illustration. Selection requires no stream address. Two seconds of sustained real reception plus native decoded playback confirm and save the setup. Real input loss produced physical source guidance. Technical controls are in Advanced.

Sample and physical-source checks passed main/floating playback, remembered floating visibility, native source/settings shortcuts, Save Frame, light/dark appearance, readable status labels, and accessible control names. The local sound preference remains saved even when the host device timeout remutes actual playback. Geometry restoration is implemented with off-screen correction. Full VoiceOver and exhaustive display/sleep combinations remain open.

T3 Chromium displayed the actual physical feed with readyState 4, advancing playback, and live video/audio tracks. Opened versus playing counts matched. Hold muted and closed audience playback; Resume reconnected on the same page; Stop showed Sharing ended while native/floating frames continued. The 390×844 and 1280×800 layouts fit without overflow. Copied-link feedback appeared. Saving and clearing temporary viewing Wi-Fi join details preserved the same live link and advancing player. Temporary details were removed afterward.

A deliberately killed owned input helper recovered fresh physical-source native frames in 4.3 seconds, using the same saved identity and retaining private state. Deliberate Wi-Fi off/rejoin also recovered the same unit automatically, with Ethernet retaining internet access and sharing off. The 48.97-second recorded interruption includes the deliberate off interval and manual rejoin, so it is not a reconnect-latency result.

Normal Quit from an active held physical-source session stopped the app and all eight owned descendants. The immutable distribution copy was launched with `/tmp` as working directory; it restored the same saved real source and floating preview, with sharing and Hold off. Advancing native-frame telemetry passed. A separate Force Quit check on that copy also stopped all eight owned descendants.

## Distribution

`dist/Setbeam-0.2.0-build3-macOS-arm64/Setbeam.app` is the verified app. `codesign --verify --deep --strict` passes. `otool -L` for the main executable, FFmpeg, FFprobe, MediaMTX, and supervisor contains only macOS system/framework libraries. The app includes fixtures, viewer assets, runtime helpers, dependency notices, matching FFmpeg/Opus source archives, and the AVFoundation patch/build scripts. It has no Homebrew runtime dependency.

The app is ad-hoc signed and not notarized. macOS 14 is a deployment target; physical testing was on macOS 27.

Private delivery completed through `agent-deliver` on 2026-10-20. Delivery ID is `20261020T163527Z--b7902a9fc1c1`; the private build folder contains the finished app archive and build notes. The delivery tool verified remote files before returning success. The reopened distribution app was left monitoring the proven physical source and floating preview privately, with sharing and Hold off.

## Build 4 icon correction

The build 3 screenshots revealed that About displayed the generic macOS app placeholder. Both the development and distribution bundles contained the approved Silver ICNS with matching SHA256 hashes. The affected call was `NSApplication.shared.applicationIconImage`; About now reads `Setbeam.icns` from the app's resources directly, and startup assigns that image to the application icon as well.

Packaged native About screenshots in light appearance reproduce the original symptom and verify the correction. Comparing the 64-pixel icon area against the decoded bundled icon produced a mean per-channel pixel error of 19.46 before and 1.78 after, passing the threshold of 12. The corrected About screenshot replaces screenshot 18 in the local screenshot package. All 26 Swift tests, `scripts/check.sh` and its actual-media probe, and strict app signature verification pass. No additional physical compatibility or sound-output claim is made.

The corrected app is `dist/Setbeam-0.2.0-build4-macOS-arm64/Setbeam.app`. Build 3 remains preserved as the earlier checkpoint.

Private delivery completed through `agent-deliver`, ID `20261020T171712Z--4fd3a28e69aa`. The build 4 delivery folder contains the app archive, corrected About PNG, and updated screenshot ZIP. Remote verification passed. The distribution build was reopened with the saved physical source and floating preview, with sharing off.

## Build 5 connection feedback

The main and floating previews now show observed connection stages. Direct Accsoon reception distinguishes preparation, discovery of the selected transmitter, its actual connection acknowledgement, waiting for picture, and native preview startup. Other input routes show preparation, waiting for picture, and opening preview. No estimated percentages or timed stage advancement are used. Native accessibility exposes the current label and step count. A missing HDMI/SDI picture retains the existing physical guidance.

All 28 Swift tests and `scripts/check.sh` passed with the bundled helpers and actual-media integration. The two new tests cover stage transitions, stale acknowledgement rejection after a receiver stops, server loss, and generic input routes. The build 5 release bundle passes strict signature verification. This pass adds no physical hardware compatibility evidence. The existing live Master 4K sharing session was left running throughout.

An isolated sample app with separate preferences verified that the stage indicator disappears during live playback, returns as "Waiting for picture, Step 2 of 3" after its own source group is suspended, labels the retained image as the last received picture, and clears after automatic recovery. Native inspection initially found that the overlay could shrink the main preview. Giving the preview an explicit geometry-based frame corrected the layout; a repeated interrupted-feed capture shows the full 16:9 picture area. The compact five-stage view also fits a 220×124 floating-preview surface. Native captures are under the ignored `build/connection-stages` directory.

One initial QA launch exited 133 because its preferences-suite argument matched its own test bundle ID. macOS reported `Using your own bundle identifier as an NSUserDefaults suite name does not make sense and will not work`. The isolated run passed after using a distinct preferences-suite name. SwiftUI's offscreen ImageRenderer could not draw the AppKit activity indicator, so main-view appearance was verified with native window captures instead.

The finished build 5 archive was delivered through `agent-deliver`, ID `20261020T234241Z--c091dff23e42`. The private delivery folder contains `Setbeam-0.2.0-build5-macOS-arm64.zip`, with verified SHA256 `fd019b80de377e60d8e3b5164abd129a3a0e0434ea456058d1e8522a2baade13`. The packaged executable was built at 19:40 local time. Subsequent concurrent network-recovery source edits are outside this artifact and its 28-test record.

## Known limits

Native audible output did not pass. The Mac's audio device failed to respond during asynchronous startup; the app explains the problem and returns actual playback to mute while video and controls continue. The physical source's encoded AAC and outgoing Opus/browser audio track passed, but listening and A/V synchronization remain open.

SEE 1.9.3 was installed and its agreement accepted with Austin's authorization. It did not list the transmitter on this dual-network Mac, so its vendor-picture baseline remains unverified. Setbeam's passing route is direct RTMS4.

Physical phone/Safari, another LAN device, QR scanning, long sessions, latency/range/capacity, camera content, other input formats/firmware, transmitter power cycles, receiver coexistence, physical capture hardware, Hollyland models, Intel, older macOS, and public signing/notarization remain open. The model name does not establish a tested 4K format.
