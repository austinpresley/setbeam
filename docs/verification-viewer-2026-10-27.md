# Build 14 browser viewer verification

Date: 2026-10-27. Version 0.2.0, build 14. Austin approved the interactive viewer mockup and requested implementation, delivery, and merge through the full-send workflow.

## Result

The viewer has one compact feed name/Sample/status strip, a source-proportioned picture, and an icon toolbar for local sound, help, keeping the screen on, PiP where supported, and full screen. F/M and double-click are supported. The full-screen target is the whole player, keeping the status strip and controls available without covering source pixels. Hold is blue, recovery amber, and first connection is distinct from reconnection. Blocked playback has one large Play button. Healthy playback does not repeat network instructions or rewrite unchanged live-region text.

The generic unavailable-link page is inline HTML/CSS and keeps HTTP 404. It contains no session name, source, sample flag, new code, or credential. Unknown configuration/state/event/asset requests remain denied. The page can only appear while the old address reaches the server; no permanent printed invitation or online lookup was added.

Build 12's SSE, polling fallback, heartbeat, watchdog, and keep-awake behavior remain in place. MediaRuntime and the native monitor UI are unchanged.

## Automated checks

The source `scripts/check.sh` run passed 90 Swift tests, the viewer checks, timestamped preview-bridge file and real-RTSP checks, and all bundled media, source-recovery, safe-switching, and format probes. The Swift test total is 60 core plus 30 app tests. The new gateway test reads the actual bundled error page and verifies the same HTML 404 with and without a session, no credential disclosure or external assets, denied API/event/asset access, and no viewer activity.

After the final browser-discovered audio correction, the focused viewer suite passes all 18 checks. It covers SSE/polling and stalled-peer recovery, stale callbacks, keep-awake, first connection, unchanged live text, decoded aspect ratio, changing audio tracks, a negotiated muted audio receiver, keyboard focus, whole-player full screen, PiP cleanup on Hold, and the autoplay-to-Hold transition.

## Native and browser evidence

All app instances used isolated bundle identifiers and preference suites with loopback-only sample sharing. The production app, its saved source, Wi-Fi, and physical devices were not operated.

- Chromium decoded advancing sample video and an audio track. At 1280 by 800 the picture was 1184 by 666, versus 490 pixels of height in the previous viewer. It remained uncropped.
- Native Chrome displayed the actual viewer and entered full screen with F. Feed name, Sample, live status, and all controls remained visible. Hold replaced the picture with the blue slate inside full screen. Resume recovered on the same page.
- Native Chrome entered real browser video PiP. Operator Hold exited PiP, detached the source, and muted playback. Stop showed Sharing ended while native local monitoring continued. Reloading the old viewing URL showed the generic styled 404 page.
- A MutationObserver on the live status saw zero text/child mutations while decoded video advanced for one second. This proves quiet DOM updates; physical VoiceOver speech was not tested.
- At 390 by 844, all visible icon buttons measured 44 by 44 and the page had no horizontal overflow. At 844 by 390, Sample and status remained visible and the page had no horizontal overflow. These are desktop-browser layout emulations, not physical phones.
- An injected browser `NotAllowedError` produced Ready to play, a neutral status class, one visible large Play button, and `display:none` on the small SVG symbol.
- A separate QA app copy used a synthetic 960 by 600 H.264 sample without audio. Only that copy's fixture differed from the distribution app. The browser decoded 960 by 600, and its picture ratio was 1.60003. The runtime reported no source/audience audio. WebRTC still exposed one muted audio receiver; after the final correction the sound control correctly stayed hidden.
- The final ordinary sample had an unmuted audio receiver and a visible sound control. Activating it changed the video's local mute flag and accessible action to Mute. This is browser track/control evidence, not a new physical listening or A/V sync result.
- Normal private Quit removed all seven processes owned by the first QA app. Deliberate termination of two later sharing QA instances removed all 22 owned app/helper processes.

## Findings and harness failures

Sol reviewed the change in three rounds using gpt-6.1-sol with xhigh reasoning effort. Round 1 found SVG `.hidden` did not set an HTML hidden attribute, leaving an extra spinning Play symbol. The fix uses `toggleAttribute`, gives blocked playback a neutral status class, and has a focused regression test. Four unused symbols were removed. Round 2 approved. The actual synthetic video-only stream then exposed WebRTC's negotiated muted receiver, so audio availability now follows mute/unmute events. Round 3 approved that final change with no new findings. Usage was not exposed. The first recorded implementation diff was 251 additions and 45 deletions; the final staged change, including the verification record and regression tests, is 358 additions and 49 deletions.

The first autoplay/Hold assertion failed with `false !== true` because the Play affordance's boolean condition was wrong; it was corrected before review approval. The initial isolated app launch used its bundle identifier as the preferences suite and aborted with `Using your own bundle identifier as an NSUserDefaults suite name does not make sense and will not work`; the successful launches used distinct suite names. The first synthetic-fixture command failed with `Unrecognized option 'preset'` because the bundled FFmpeg does not include libx264. That QA launch was discarded. The successful fixture used bundled `h264_videotoolbox`.

The T3 browser screenshot tool failed twice with `Preview automation snapshot timed out after 15000ms.` Its click tool also timed out once. Native Chrome computer use supplied the actual visual/full-screen/PiP/expired-page proof; T3 page evaluation supplied decoded playback and DOM measurements. One native click used an accessibility ID that expired during automatic playback startup; a fresh state read resolved it. These harness failures are not recorded as passing checks.

## Limits

Physical iPhone/Android, native phone full screen, Safari-specific PiP, VoiceOver speech, audible synchronization, screen-sleep prevention, hardware endurance, range, and capacity were not newly qualified. Native video full screen and PiP do not carry arbitrary DOM badges. Existing hardware evidence and Build 12's keep-awake limits remain unchanged. The distribution remains an ad-hoc signed Apple Silicon developer preview for macOS 14 or later, not a notarized public release.

## Pre-rebase package evidence

The packaged-helper/fixture `scripts/check.sh` repeat also passed all 90 Swift tests and the complete preview/media/recovery/switching/format probes. It ran the 17-check viewer suite before the final negotiated-audio correction; that final controller has a separate passing 18-check run and actual silent/audio-bearing browser evidence above. No Swift, native runtime, or helper code changed in that correction.

Before the rebase, the frozen source/test manifest and all six bundled viewer resources matched the candidate app. Strict recursive code signatures and system-only linked libraries pass. That candidate was superseded when the screen-source PR merged as Build 13.

- Pre-rebase candidate executable SHA256: `9ceb61f652a4ae7f38527892f2548a8dfec6d4bbb29d03854946a0efa1a2cfde`.
- Pre-rebase candidate source/test manifest SHA256: `f4ff342fe599b8dec956a988d37be68bcecef7f535f26de74b6b5bf435d554cd`.

The source checks, isolated QA, and packaging do not add physical hardware compatibility claims.

## Rebase onto the screen source

While packaging, PR #3 merged as `8979d42`, introducing This Mac's screen and taking Build 13. The viewer change was rebased onto it and moved to Build 14. Only the status header and appended architecture notes conflicted. Both product changes and the existing screen-source evidence were preserved; no screen-capture behavior was changed by this PR. The combined build receives fresh automated and packaged verification below. Earlier 90-test and browser results above describe the pre-rebase candidate.

## Final Build 14 evidence

The combined `scripts/check.sh` run against Build 14's packaged helpers and fixtures passed 96 Swift tests, all 18 final viewer checks, the timestamped native bridge/file/RTSP checks, and every sample/RTSP/RTMP, Hold, credential, recovery, source-switching, and media-format probe. The total is 66 core and 30 app tests, including the inherited Mac screen-source tests. No thresholds or runtime behavior were changed to obtain these results.

The rebased viewer resources and tests are byte-identical to the final Sol-approved candidate. The final packaged app was separately launched with isolated preferences. Actual native Chrome and Chromium sample playback passed; M toggled sound, F and double-click entered full screen, and Sample/status remained present during Hold. Resume restored the same page. Stop retained fresh private native monitoring, and refreshing the old URL displayed the generic 404. Normal Quit removed all 11 recorded app/helper processes. Screen capture and physical phones were not newly operated.

Strict recursive signatures, system-only linked libraries, the frozen source/test snapshot, and exact matches for all six bundled viewer assets passed. The finished app is `dist/Setbeam-0.2.0-build14-macOS-arm64/Setbeam.app`.

- Final executable SHA256: `571a679d0fb989d40f4cac60888bf6e155d5ad11e59e8caca29414edd3c3bdad`.
- Final source/test manifest SHA256: `e2655f359bd851bbd283d4ca4ecc43728a4da5cd73e809b9cfd46cba92360382`.

The pre-rebase Build 13 candidate was moved out of `dist` and is not the delivered build.
