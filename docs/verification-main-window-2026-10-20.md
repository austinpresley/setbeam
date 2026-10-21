# Main-window design verification

Date: 2026-10-20. Combined version 0.2.0, build 7. Native SwiftUI main window on the development Apple Silicon Mac running macOS 27.

## Presentation

The main window uses native system typography and semantic colors, 24-point content spacing, a 12-point preview radius, and a subtle divider before the sharing column. The viewing QR remains the first item under Scan to watch, with Copy link and join codes immediately below. Playback counts distinguish pages opened from players receiving fresh video. The actual outgoing thumbnail and setup test remain available below those invitation controls.

The header reports local Picture ready independently of audience Hold. The Hold notice is below the local picture so it does not obscure source content. The sample badge remains explicit; ordinary sources no longer have a redundant Your monitor badge. Pop out preview and Save frame use quiet native controls. The first-open window is 900 by 720 points; saved geometry continues to take precedence, and compact windows can scroll the secondary details. The native footer keeps Hold, Resume, and Stop sharing available independently of that scrolling area.

Audio status, source rollback, the outgoing decoder, setup checks, Quit protection, and floating-preview gestures are concurrent authorized changes. Their functional records are maintained separately; this record covers their placement in the main window.

## Native sample evidence

An isolated `SetbeamUIQA.app` with a distinct bundle identifier and preferences suite was launched from `/tmp`. It used sample media and a loopback viewer, leaving the existing physical-source app untouched.

- Light appearance at 900 by 720: local picture, QR-first sharing panel, viewer counts, outgoing thumbnail, and footer visually inspected.
- Copy link visibly changed to Link copied. Show join codes opened the full QR sheet during Hold.
- Hold retained the QR and fresh local frames. Picture ready stayed visible. Audience status and audio changed to Hold, the outgoing thumbnail changed to the holding picture, and Resume became the prominent native action.
- Stop sharing removed the QR, returned the sidebar to Private preview and Start sharing, and preserved advancing native frames. The app telemetry independently confirmed monitoring on, sharing off, and Hold off.
- Dark appearance at 760 by 560: the full local frame, QR, Copy link, and fixed footer fit without horizontal clipping. Secondary outgoing/setup details remain reachable by vertical scrolling.
- Native controls expose descriptive accessibility names. Full VoiceOver use and additional physical display configurations were not tested in this pass.

Ignored QA files and logs are under `build/main-window-polish` and `build/logs/main-window-*`. They are excluded from delivery and Git.

## Initial failures

An early compile caught the concurrent `AppSheet.setupCheck` addition before its view handler landed. The completed integration built successfully. A temporary trailing blank line in the concurrently edited PlayerView was removed before the whitespace check.

The first isolated launch did not retain its command arguments after its terminal process exited; the QA app was restarted with an independent process session. That isolated sample connection then reported `The video service could not start.` Reselecting Sample feed restored fresh local and outgoing media without a code change. A subsequent isolated dark launch started successfully. This single startup failure was not diagnosed as a new UI defect and is not claimed fixed by the design pass.

## Final package

The initial combined release build passes strict signature verification and a system-only dynamic-library audit across the app and four runtime helpers. Its packaged-helper check passed all suites and media probes. A source-snapshot check then caught a late saved-credential regression fix in SessionModel during the final refresh. A refreshed candidate including that regression and the corrected floating-window drag/resize paths passed 32 core and 9 app Swift tests, five viewer-controller tests, and all packaged-helper media/recovery/safety probes. Launched from `/tmp`, it displayed fresh local, actual outgoing, and floating sample pictures; Force Quit stopped all ten owned descendants. This candidate was set aside before upload when Austin confirmed the product-24 announcer is the same physical Master 4K, requiring a recognition regression fix. Final artifact and delivery evidence will be recorded after that fix is included and verified.

No hardware compatibility, audible-output, phone, or transmitter power-cycle result is established by these sample UI checks.

## Final build 7 result

The product-24 recognition correction and regression are included in the final frozen source. The fresh packaged-helper `scripts/check.sh` passed 33 core Swift tests, 9 app Swift tests, 5 viewer-controller tests, and all sample/RTSP/RTMP, Hold/audio, access, source/server recovery, source-switching, and cleanup probes. The source and test snapshot remained unchanged. Strict signature verification, bundled viewer hashes, and the system-only dynamic dependency audit pass.

The final distribution app is `dist/Setbeam-0.2.0-build7-macOS-arm64/Setbeam.app`. Its executable SHA256 is `65022564e8ff47aaf48dfeb8bf64ea1ece8dbe2a77136a4a64d1f5ce3de36f03`. The app archive SHA256 is `887b69e2fd11ee7991c49878777be6d043dc7c3352cded51c577a4a66a4637f7`.

Launched from `/tmp` with isolated sample preferences, the final distribution produced fresh native and actual outgoing frames and encoded audio tracks. Force Quit stopped all ten owned descendants. After the physical QA apps were closed, the old private build was quit normally and build 7 restored the saved physical Master 4K with Picture ready, setup remembered, and sharing/Hold off. Mac speakers remain muted. The finished app was left monitoring privately.

The [safeguard record](verification-safety-2026-10-20.md) and [hardware record](hardware-tests.md) distinguish the successful physical phone/real-feed and qualified power-cycle checks from the completed 120-second soak failure, which had 2 unavailable samples of 116. Power-cycle recovery required manual Wi-Fi rejoin after macOS changed networks. The two-hour check was explicitly deferred, and real-source audible sound/A/V timing remain open.

## Private delivery

Delivery `20261021T021320Z--b63d56f59848` completed through `agent-deliver` with remote verification. The private build 7 folder contains only the finished `Setbeam-0.2.0-build7-macOS-arm64.zip` and `BUILD-NOTES.txt`. Captures, session links, runtime files, test bundles, and credentials are excluded.

The delivered archive matches SHA256 `887b69e2fd11ee7991c49878777be6d043dc7c3352cded51c577a4a66a4637f7`. The notes include the completed short-soak failure, qualified manual-Wi-Fi power-cycle recovery, native-audio limitations, and the deferred two-hour check. The final production app remains on the physical picture privately, with sharing and Hold off.
