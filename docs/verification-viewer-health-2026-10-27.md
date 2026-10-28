# Viewer names and playback health verification

Date: 2026-10-27. Version 0.2.0, build 16. Austin approved optional names, distinguishable viewer sessions, and playback health, followed by full-send delivery and merge.

## Behavior

The operator's Picture and viewers list assigns a number to each browser session in arrival order. Viewers can optionally save a 40-character plain-text name in Connection help without interrupting playback. Names persist in that tab's session storage where available. Duplicate or unnamed sessions remain distinguishable by their number. The roster explains that each row is a browser session. It stays private to the Mac and scrolls when necessary.

Good and Struggling use the existing peer's packet-loss deltas, jitter, round-trip delay, and dropped-frame deltas. Two bad samples are required for Struggling and two clean samples for Good. The initial thresholds are over 3% packet loss, 80 ms jitter, 300 ms round trip, or 10% dropped frames. These are playback-health heuristics, not calibrated Wi-Fi signal bars. There is no expected-FPS or minimum-bitrate requirement. Unsupported or failed measurements fall back to confirmed Playing. Background, Paused, Ready to play, Connecting, Reconnecting, Checking, and authoritative operator Hold are distinct states. Current publisher revision and heartbeat freshness gate the reported result; abandoned sessions expire after 12 seconds. Replaced peers and reset measurements ignore pending old statistics.

Measurements never change the media stream, recovery policy, viewer permissions, or quality, and never open another receiver. No names or health details are added to session logs, guest state, or guest configuration. A token rotation or Stop clears the roster.

## Observed checks

- All 24 deterministic browser-controller checks pass. New checks exercise optional names and storage, sustained loss and recovery, jitter/round-trip/dropped-frame warnings, one decoded frame per sampling interval, missing/failed statistics, background/paused/blocked/stalled states, and stale peer results.
- All 109 Swift tests pass, including two new tests for private names, stable arrival-order numbering, sanitization/bounds, unknown health values, heartbeat age, current revision, Hold, and the read-only guest boundary.
- An isolated packaged QA app supplied real sample media to Chromium and native Chrome. The native roster showed the saved name and Good, and a second default browser had a distinct numbered row.
- Real 1280 by 720 browser playback at 1 fps decoded five frames in 5.1009 seconds and remained Live feed. Both operator rows showed Good. Local monitoring continued.
- Injecting 150 ms jitter into diagnostic readings alone produced Struggling in the native roster while video continued. Restoring original getStats readings returned Good. This is failure injection, not a physical range test.
- Native Chrome moving to another tab produced In background in the native operator list. Hold showed On hold for every row, Resume retained the name and same browser page, and Stop preserved local monitoring.
- Native Chrome displayed and accepted the optional name form. Reloading retained its name; Chrome briefly reported Ready to play before playback resumed. Portrait 390 by 844 and landscape 844 by 390 DOM layout measurements had no horizontal overflow, and the help panel stayed within the viewport. These are browser emulations, not physical phones.

## Final regression, review, and package

The complete `scripts/check.sh` run against the candidate's bundled helpers/fixtures passed all 109 Swift tests, 24 viewer-controller checks, preview-bridge file/RTSP checks, and all sample/RTSP/RTMP, silent Hold, guest restrictions, receiver/server recovery, safe source switching, codec/dimension/cadence/audio, and FPS probes. The final measurement-reset guard and 44-pixel name controls have a separate passing 24-check browser run. No Swift, helper, or media-flow behavior changed after the complete regression run.

An isolated archive of the feature commit, excluding the earlier uncommitted FPS work, independently passed all 103 Swift tests and the same 24 browser checks. This confirms that the PR does not depend on that local work.

Sol reviewed the committed feature diff in one round using gpt-6.1-sol with xhigh reasoning effort and default service tier. Verdict APPROVE, no blocker, should, or nit findings. It independently ran all 24 viewer checks. No review fixes were requested; usage was not exposed. The initial reviewed diff was 379 additions and 14 deletions. Subsequent changes only finish this verification record and status evidence.

The final immutable distribution includes the approved viewer resources and previously delivered FPS source work. Its exact six bundled viewer assets match the repository. Strict recursive signatures and system-only linked libraries pass. It was launched again with isolated preferences and actual 1280 by 720 sample playback. The native list showed Final viewer and Good. Stop detached and muted browser media while local monitoring remained fresh. The first QA app's 11 owned processes all exited normally; the final QA cleanup is verified before delivery.

- App: `dist/Setbeam-0.2.0-build16-macOS-arm64/Setbeam.app`.
- Executable SHA256: `ee71d49a16669b5edf24b4f72149a4c388cbb3802de6844d850b5680561d6c13`.
- Source/test manifest SHA256: `8b3178bf9ace5d8b7e67c000b3ca65f012465f518a74c7e3700fef8cfc84faec`.

The app remains an ad-hoc signed Apple Silicon developer preview for macOS 14 or later.

## Findings and limits

The first Swift run failed the new name normalization assertion: `Optional("Sam  iPad")` differed from `Optional("Sam iPad")`. Removing an invisible direction character after normalizing whitespace left an extra space. Sanitization now removes controls before collapsing whitespace. The same assertion and complete Swift suite pass after the correction.

T3 browser snapshots failed twice with `Preview automation snapshot timed out after 15000ms.` T3 browser navigation, interaction, page evaluation, decoding measurements, and layout emulation remained available. Native Chrome and native Setbeam supplied actual visual checks. An expired native accessibility ID was refreshed before continuing. These tool failures are not passing product checks.

The checkout already contained the separately delivered Build 15 FPS changes, uncommitted at task start. They are preserved in the local working tree and combined developer app; this feature's PR excludes those changes. The combined source/test manifest records exactly what was packaged. Physical phones, Safari-specific behavior, physical transmitters, network range, many simultaneous viewers, and endurance were not newly qualified. No hardware compatibility claim is added.
