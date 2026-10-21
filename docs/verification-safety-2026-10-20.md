# Session safeguards verification

Date: 2026-10-20. These safeguards join the main-window and floating-preview work for combined build 7. Automated checks and the physical phone/power-cycle checks below are complete. Austin deferred the two-hour qualification to the next session.

## Implemented behavior

- Source changes keep the same viewing credential, media ports, gateway, and viewer URL. Viewers enter Hold before the source is replaced and stay held until explicit Resume. A missing new input cannot expose source picture or audio. Return to previous source retains its private address in memory.
- The audience thumbnail decodes the actual outgoing relay, including the holding media, with no extra upstream reception and no local sound output. Stale outgoing frames are hidden. Stop and Quit stop its owned decoder.
- Test my setup observes local picture, non-loopback viewing address, and fresh playback from another network endpoint. Local Chromium playback cannot complete the other-device check. Old publisher revisions cannot count as current playback. Sound, when expected, also needs an explicit listening confirmation.
- Input audio track presence, Mac speaker mute, and outgoing audio are displayed independently. Hold explicitly reports outgoing source audio as silenced.
- Quit while sharing requires a choice between Keep Sharing and Quit and End Sharing. Private monitoring quits directly.

## Automated checks

`scripts/check.sh` passed with Vendor helpers and fixtures, and the final product-24-inclusive candidate passed it again using its packaged Helpers and Fixtures. The final run includes 33 core Swift tests, 9 app Swift tests, 5 viewer-controller tests, standard actual-media integration, repeated RTSP/RTMP outage recovery, and the new actual-media `--safety-test`.

The safety probe rejects an invalid candidate before interrupting live sharing, replaces the sample with an authenticated incoming input while its sender is absent, captures actual silent outgoing Hold, then receives a video-only replacement privately. Fresh video does not resume sharing. Explicit Resume produces a live output without an invented audio track. Returning to the sample retains the original playback descriptor, viewing credential, and private relay address, stays held, and restores measurable source audio only after Resume. Captured private and outgoing holding pictures differ. All owned processes exit.

Gateway tests prove that a local browser advertising itself as mobile still counts as this Mac, and a heartbeat for an old publisher revision cannot confirm current playback. Setup-check tests distinguish encoded track presence from confirmed audible sound.

The app tests include 8 viewport tests from the concurrent PiP work and a saved-credential regression. The latter proves that selecting a saved network input whose credential is unavailable preserves the currently displayed source, monitoring, and sharing. The app explains how to reconnect that saved input instead of relabeling the live source.

Logs are ignored under `build/logs/safety-*`, `source-switching.log`, and the standard check logs. Captures and runtime files are not delivery artifacts.

## Native and Chromium checks

An isolated `SetbeamSafetyQA.app` used a separate preferences suite and telemetry under `build/safety-qa`. Main native frames advanced, and the actual outgoing thumbnail reported fresh playback. Sample input audio and outgoing audio were present while local speakers stayed muted.

Chromium decoded advancing WebRTC video at readyState 4 with one audio track. The app reported one playing viewer and zero other-device viewers, leaving the setup check incomplete. Choosing another sample input held the same browser page and credential; the browser had no attached media and was muted during Hold. Native local and outgoing holding playback recovered. Explicit Resume restored advancing Chromium playback on the same URL.

Quit displayed the connected-browser count. Keep Sharing preserved the session. Confirming Quit stopped the app and all ten owned descendants, including the outgoing decoder and its supervisor.

The first QA launch failed because its requested UserDefaults suite equaled the QA bundle identifier, producing `Fatal error: Unexpectedly found nil while unwrapping an Optional value`. A distinct QA preferences suite fixed the invocation. This was an isolated test-launch configuration error. An initial compile also caught the concurrent floating-preview hosting initializer's missing `required` modifier, which its owner corrected before the passing test run.

## Physical checks

Austin made the transmitter, source, and Mac Wi-Fi available. The Mac has 10.0.1.10/24 over Wi-Fi while Ethernet retains 192.168.1.238/24. A bounded read-only status diagnostic reached the announcing transmitter at 10.0.1.1 and reported UID 1902711000, product ID 24, firmware raw 798/3.30, and three advertised streams. This UID and Accsoon_11D5 match the saved proven setup, while the retained earlier redacted status JSON reports product ID 21 at the same firmware. Austin confirmed this is the same exact physical unit. The product-field discrepancy's cause is unknown. The product-21-only gate hid the unit; recognition now accepts both observed values. Unrecognized products now appear in the chooser with an explanation instead of an empty wireless section.

The labeled sample was shared through the Mac's Ethernet LAN while transmitter identity was checked. Chromium on this same Mac decoded advancing video through the actual LAN-address viewer URL at readyState 4. The gateway still classified it as this Mac and left the other-device setup check incomplete. The setup sheet visibly showed its picture and viewing-address checks passed, with other-device playback incomplete.

Austin completed the physical phone/Safari QR workflow and reported that both sample video and its audible test tone worked. Gateway telemetry recorded two playing browsers with exactly one other-device browser, and the video-only setup check passed. Phone model and OS version were not supplied. After locking the phone for 30 seconds and returning to the same Safari tab without reload, Austin reported that both picture and tone returned automatically. The explicit listening checkbox was marked using that report. Source/audience audio remained present while Mac speakers stayed muted. Austin then scanned HardwareQA's new QR and confirmed the real transmitter computer-display feed played on the phone; its app independently reported one other-device browser with fresh video. Audible source audio and A/V timing on that real feed were not tested.

A focused regression first failed on product 24 while product 21 passed. Recognition now accepts both observed statuses and keeps unknown product 999 unverified. The physical probe decoded/exported a real 1920×1080 computer display and observed H.264 conversion and an Opus audio track. Its first outgoing capture attempted RTSP DESCRIBE before the outgoing path was ready and received 404. The capture helper now waits up to 20 seconds for observed fresh outgoing frames instead of relying on a fixed 1.5-second delay. The rerun captured live and holding pictures and verified silent Hold.

The physical sample phone Hold check was repeated with Hold left on until Austin confirmed the holding message and silence. After explicit Resume, Austin confirmed both picture and tone returned automatically on the same phone page without reload or another sound gesture. The first timed attempt was missed and is not counted as a result.

The product-24 probe rerun passed live incoming/outgoing video, audio track conversion, outgoing Hold silence, Hold/Stop preserving local monitoring, and three source-helper recoveries in 2.37, 2.60, and 2.32 seconds. Its 120-second continuous-run assertion failed with 2 unavailable samples of 116. The failure is retained as a stability limitation. Source classification was verified against actual media; no claim of a flawless or long session is made.

Austin powered the real transmitter off and left it off for observation. The app retained sharing intent, marked the last picture as stale, removed fresh source/native/outgoing status, and showed Reconnecting. The browser closed playback and muted. The transmitter was then powered on. macOS had switched Wi-Fi to the regular LAN at 192.168.1.233 while the transmitter was unavailable, so it could not receive the source automatically from that different network. At our request, Austin manually rejoined Accsoon_11D5. Ethernet and the phone's existing viewing page were retained throughout.

After rejoining, no app Retry or browser reload was used. The same saved source, advancing native frames, actual outgoing thumbnail, encoded audio tracks, and fresh other-device playback all returned. The gateway URL and viewing credential were unchanged. Austin independently confirmed the real picture returned on the same phone page without reload. The off observation was recorded at 02:03:37 UTC and full source/native/outgoing/phone recovery at 02:07:35 UTC on October 21. This interval includes deliberate power-off time, boot, operator responses, and manual Wi-Fi selection; it is not a reconnect-latency measurement. This establishes recovery after a physical power cycle with a manual network rejoin, not automatic Wi-Fi association.

Austin explicitly left the two-hour session check for the next session. Camera content, format changes, audible native Mac output, real-source audible sound/A/V timing, range, capacity, and longer reliability remain open. The completed sample and real-feed phone checks do not establish all phone models or OS versions.

A local-sound-unavailable notice appeared during the post-recovery native inspection. Mac speakers were muted while source and audience audio tracks remained present. Audible native output remains unverified. The finished sample and hardware QA sessions were stopped and quit; all observed owned descendants exited and the discovery socket was released.

## Packaging

The combined build 7 passed final packaged-helper checks, strict signature verification, system-only dependency checks, and source/test freeze verification. Its final executable SHA256 is `65022564e8ff47aaf48dfeb8bf64ea1ece8dbe2a77136a4a64d1f5ce3de36f03`. The main-window thread delivered the finished versioned app archive and build notes through Austin's private inbox, with remote verification, under delivery ID `20261021T021320Z--b63d56f59848`. The private delivery folder and final production launch are also recorded in [main-window verification](verification-main-window-2026-10-20.md). Build 7 was left monitoring the saved physical source privately, with sharing/Hold off and Mac speakers muted. No competing intermediate build was delivered.
