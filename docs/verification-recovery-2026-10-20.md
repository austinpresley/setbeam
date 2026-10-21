# Build 6 recovery verification

Date: 2026-10-20. Version 0.2.0, build 6. Apple Silicon, macOS 14 deployment target, tested on the development Mac running macOS 27.

## Corrected failures

`node --test scripts/check-viewer-recovery.js` reproduced two failures before the fixes. The frozen-peer assertion reported `1 !== 2`, because the controller never replaced a peer with stalled decoded video. The hung-fetch assertion reported `a stalled fetch must not lock polling forever`. State/configuration/heartbeat requests now have a five-second deadline, including response bodies. Ten seconds without decoded video triggers a new peer while live. Obsolete peer callbacks cannot reattach old media. Hold and Stop close playback and suppress automatic playback restart.

The same-port listener regression initially failed with `POSIXErrorCode(rawValue: 48): Address already in use`. Specifying the fixed port both in the local endpoint and listener initializer then produced `POSIXErrorCode(rawValue: 22): Invalid argument`. Keeping the address in the required local endpoint, specifying the port in the listener initializer, allowing local reuse, and waiting for cancellation fixed the regression. Listener startup now has a five-second deadline and obsolete listener callbacks cannot change the current running state.

An early check run reported `unexpected EOF while looking for matching` a double quote because the check script was edited while Bash was still executing it. The completed script passes `bash -n`; the full packaged check was rerun from the completed file.

## Automatic reconnect behavior

The selected source keeps retrying. A failed direct Accsoon receiver now triggers source recovery immediately rather than waiting for the FFmpeg stall threshold. A zero-frame FFmpeg progress report does not count as healthy video. The selected capture device identity never falls back to another device.

Temporary viewing-network loss retains sharing, Hold, the viewer credential, and viewer port. The app waits for the same viewing interface and restarts a failed viewer listener on its original port. It refreshes playback configuration after a publisher revision. A changed DHCP address produces an updated viewing code. A numeric-IP page at the old address cannot follow that change and needs the current code.

Wi-Fi selection remains user controlled. This build does not switch networks or implement automatic Wi-Fi association. Explicit Stop ends the audience session. Relaunch restores local monitoring privately, with sharing and Hold off.

## Automated and browser evidence

All 30 Swift tests and five deterministic viewer-controller tests pass. The new source recovery probe starts both authenticated RTMP and full-URL RTSP without an available sender, then receives actual media and recovers twice after sender loss. It asserts unavailable status during loss, unchanged sharing/Hold/credential through recovery, decoded audience frame capture, and owned-process cleanup. These checks join the existing sample, audio, silent Hold, guest access, helper stall/crash, and server-recovery checks in `scripts/check.sh`.

The packaged sample app showed fresh native frames and a live Chromium WebRTC audio/video track at readyState 4. Ending the browser's video track while leaving the peer and server revision unchanged recovered the same page automatically in 12.157 seconds. Injected hung `state.json` requests were aborted twice and the same page recovered in 14.120 seconds. These are injected browser failures, not a physical Wi-Fi or phone test.

Native Hold kept the private picture advancing while Chromium closed its media and muted. After killing only this test app's owned media server during Hold, Resume restored advancing browser playback on the same page. Force Quit stopped the sample app and all eight owned descendants. Test preferences used a separate suite.

Local logs are ignored under `build/logs/reconnect-*`, plus `source-recovery.log`, `viewer-recovery.log`, and `swift-tests.log`. Viewer tokens, private runtime configuration, and source captures are excluded from delivery and Git.

## Physical and distribution evidence

The build 6 receiver probe passed against the same Master 4K product ID 21, firmware 3.30 and live computer-display route in [hardware-tests.md](hardware-tests.md). Direct video decoded/exported, HEVC converted to H.264, AAC produced an Opus track, and local monitoring survived audience Hold and Stop. Three killed owned source helpers recovered automatically in 2.51, 2.97, and 3.01 seconds, retaining Hold and the viewing credential. The following 120.5-second check recorded 118 fresh source/audience samples with zero unavailable samples. Owned-process cleanup passed. Wi-Fi selection was unchanged. This is short physical-source evidence with injected software failures, not power cycling or a long-session qualification.

The final `scripts/check.sh` run passed with the build 6 app's bundled helpers and fixtures. The immutable distribution app is `dist/Setbeam-0.2.0-build6-macOS-arm64/Setbeam.app`. Strict signature verification passes, and the executable and helpers reference only macOS system/framework libraries. It is ad-hoc signed and not notarized. The main executable's SHA256 is `4c82ecf3258371b3aca8fa4b985c7f45b636e13578dbcf69d2e3e37f7d2633f1`.

Launched from `/tmp`, the distribution copy restored the same proven Master 4K setup with sharing and Hold off. Advancing native frames passed in the main and floating previews. The floating preview was then closed to restore its prior preference. The finished app was left monitoring the real source privately.

Private delivery completed through `agent-deliver`, ID `20261020T235241Z--03340ec3ab96`. The verified private delivery folder contains the finished build 6 app archive and `BUILD-NOTES.txt`. Runtime configuration, source captures, and session credentials were excluded.

Physical phone/Safari, another LAN device, transmitter power cycles, format changes, long sessions, audible native output, A/V timing, range, and capacity remain open. Physical USB capture and other transmitter models remain unverified. Automatic recovery in generic tests does not establish hardware compatibility.
