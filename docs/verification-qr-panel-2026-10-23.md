# Build 11 QR panel verification

Date: 2026-10-23. Version 0.2.0, build 11. Austin approved the existing numeric-IP viewing approach and a persistent Show/Hide QR codes panel beside the feed. The reviewed ImageGen concept remains an ignored local artifact; this record describes the actual native implementation.

## Behavior

Show QR codes expands the main window to the right by 252 points when space permits. A 232-point panel and 20-point gap preserve the existing picture size. The window shifts left as needed to remain on the current screen. Hide subtracts the width actually added. Full-screen presentation uses the existing available window area. Reduced-motion settings disable the explicit window animation.

Wi-Fi and viewing sections each occupy half the picture height. Both native codes resize with the picture and retain white quiet zones. Missing Wi-Fi details show Add viewing Wi-Fi. Editing uses the existing user-provided SSID/password form and returns directly to the panel on Save or Cancel. The protected password remains in Keychain for ordinary sessions; isolated integration demos retain their in-memory test details when the panel reopens.

The panel stays open through other controls, Hold, and Stop. Hold keeps the invitation usable while audience media stays held. Stop removes the feed invitation, keeps the Wi-Fi code visible, and leaves local monitoring available. Starting sharing again supplies the current viewing code. Copy viewing link and the existing menu-based join sheet remain available. Loopback-only sessions visibly say This Mac only.

Viewing still uses the current numeric-IP address, listener port, and session credential. There is no permanent invitation, online lookup, or new Bonjour requirement. Viewer access remains read-only, and sharing is not restored on relaunch.

## Packaged regression checks

`scripts/check.sh` passed against the final app's bundled helpers and fixtures:

- 75 Swift tests, comprising 47 core and 28 app tests, with zero failures.
- Five viewer-controller checks.
- Timestamped preview-bridge file and actual MediaMTX RTSP checks, including 1080p60 and synchronized-source PCM.
- Actual sample, authenticated RTSP/RTMP, silent Hold, guest access restrictions, source/server recovery, and process cleanup probes.
- Offline RTSP/RTMP starts and two reconnects for each, retaining sharing intent, Hold, and viewing credentials.
- Continuous-Hold source switching, failed replacement preflight, incoming-key rotation, and occupied incoming-port checks.
- Media-format checks for HEVC/H.264, B-frame removal, dimensions/cadence, optional audio, and one upstream reader.

The frozen source/test snapshot remained unchanged through packaging and checks. Strict signatures, bundled viewer bytes, and system-only dynamic dependencies pass. Logs and raw QA artifacts stay ignored under `build/qr-panel11` and `build/logs`.

## Native and browser sample checks

The QA app copies use distinct bundle identifiers and isolated preferences. Their executable instruction sections match the release executable after re-signing for those identifiers. The existing production app and saved hardware source were not operated.

- The 900 by 636 dark window expands to 1152 by 636 and returns to 900 when hidden. Its 868 by 488 picture remains intact. The compact 640 by 472 light window expands to 892 by 472 and returns to 640 when hidden. Both layouts were visually inspected.
- Native Vision barcode detection decodes both actual on-screen QR images at default and compact sizes. The results match the current session URL and the exact fictional Wi-Fi details, including escaped semicolon and colon characters in a protected password. Open-network Wi-Fi is also decoded correctly. Wi-Fi is above the feed code.
- Saving Wi-Fi changes returns directly to monitoring and retains the feed URL. Repeated Show/Hide retains the protected Wi-Fi payload and the same viewer link. Sound popovers do not dismiss the panel.
- The current displayed viewing URL opens the real local viewer. Chromium decodes advancing video and an audio track. Hold detaches and mutes browser playback while native frames continue; Resume restores advancing playback on the same page. Stop reports Sharing ended and mutes the viewer while native frames continue.
- Stop leaves only the Wi-Fi QR visible. Start supplies a newly verified current viewing URL without hiding the panel.
- A default dark window starting near the right display edge expands within the visible display bounds. The final native sample screenshot contains fictional Wi-Fi details, and its viewing session was expired after capture.
- Normal private Quit cleaned the app and all six owned monitoring descendants. Force Quit during sharing cleaned the app and all ten owned descendants.

Initial native-control attempts returned `Computer Use server error -10005: timeoutReached` twice. Binding the running isolated instance subsequently worked. Initial ad-hoc AX resize requests returned success without changing the frame; compact verification therefore launched the release QA with its own saved 640 by 472 frame. An early QR assertion used a stale session file from overlapping QA instances, and initial synthetic password input saved before all characters arrived. Final checks used one isolated release instance, fresh accessibility observations before Save, and exact current-session/payload comparisons. These harness failures are not recorded as passing app checks.

## Final package and remaining physical checks

The distribution app is `dist/Setbeam-0.2.0-build11-macOS-arm64/Setbeam.app`, targeting Apple Silicon and macOS 14 or later. It is ad-hoc signed and is not a notarized public release.

- Executable SHA256: `ddc5e7069ba63266f149400b49037b9a9e22bcd2f5681d6ee4dc9c6fc1b986e3`.
- Frozen source/test snapshot SHA256: `c582623e38dc4717a41b55cab020a9952e6c948c981a3f8692c4a2dd212a0328`.
- App archive SHA256: `04db379a01150329c70ab98ec5aa21afa2c972c246018cdf9a88e19819208f53`. ZIP integrity verification passes. The archive contains the finished app, build notes, and native sample screenshot.

Physical iPhone/Android camera scanning, actual Wi-Fi association using these codes, scanning distance, and display glare remain untested in this pass. Native audible synchronization, hardware endurance, range, and capacity retain the existing limits in `hardware-tests.md`. No new hardware compatibility is claimed.

## Private delivery

Delivery `20261024T013525Z--064035aabf43` completed remote verification through `agent-deliver`. It contains only the finished Build 11 archive, build notes, and native dark sample screenshot. Raw logs, QA copies, private session files, and runtime directories were excluded. All isolated QA apps and their owned helpers were closed before handoff. The private delivery URL stays outside the repository.
