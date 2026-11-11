# Local suite reliability, 2026-11-04

Austin asked to address the timing and port-reuse failures reported after build 29. This pass preserves the existing organization and source-chooser changes and all product invariants. Tests, builds and packaging run locally on this Mac; no hosted CI, commit, push or PR is involved.

## Reproduction and causes

- The original one-shot port test passed 30 focused runs, but a tighter same-process test failed on its fourth immediate listener handoff with `unavailable(inUse)`. `NWListener.cancel()` releases its socket asynchronously. A new listener instance did not know that another instance was still retiring, and entered its five-second retry delay. The original full-suite failure waited only five seconds for that retry.
- The preview integration failed on its second repetition. The first RTCP sender report can align the separate audio/video RTP clocks after decoding begins, producing one small backward source-PTS adjustment. The check incorrectly required a positive interval there. Instrumentation also exposed an actual bridge defect: FFmpeg sometimes guessed the 90 kHz RTP clock as a video frame rate, emitting an initial duration of 11 microseconds. The revised duration regression fails against the installed build-29 helper.
- The original format probe failed again with a 50.066 ms outgoing interval and a measured 29.999996 fps. The H.264 fixture itself has alternating timestamp jitter of about 65 microseconds, introduced during its original 24-to-60 fps authoring. Bucket-based frame selection preserves those timestamps. The strict 50 ms comparison rejected a legitimate selected interval. A separate 60 fps failure came from judging finite-read B-frame flush output: the initial stream probe could report `has_b_frames = 0`, while the completed decode reports a reorder depth of 1.

Baseline logs, exact source snapshots, direct-fixture timing and the old-helper failure are under `build/suite-reliability/`. Temporary instrumentation was removed.

## Changes

- The listener gives an occupied port up to one second to clear cancellation before reporting the normal named error and slower retry. Endpoint reuse remains disabled. The retry belongs to its exact attempt; Stop invalidates it. A port another app holds remains unavailable and is never shared.
- The preview helper keeps a reasonable previous duration while the frame-rate guess is implausible. Positive source-PTS deltas still establish actual cadence. Source PTS, including RTCP alignment, are preserved. The integration check verifies bounded durations and exact positive deltas, allowing at most one bounded clock adjustment during startup. File decoding remains strict at 60 frames and 60 fps.
- The format probe reads reorder depth from the same completed frame decode it measures. It retains the existing two-second startup exclusion, rate accuracy requirement and half-frame gap bound, adding only measured fixture jitter and two RTP-clock rounding ticks plus microsecond serialization rounding. The H.264 allowance changes by less than 0.1 ms. A malformed or irregular fixture fails instead of widening the bound arbitrarily. Source-timing JSON is retained with relay evidence.
- New regressions cover 200 immediate listener handoffs, real HTTP requests during those handoffs, Stop during the fast retry, fixture validation, the recorded 50.067 ms interval, finite decode tails and an interior missing-frame gap. The full script has no retry wrapper and skips no stages.

## Validation

Targeted checks pass: seven listener cases, three cadence cases, ten consecutive real file/RTSP preview integrations, and the complete codec/format-transition probe. The complete `bash scripts/check.sh` run passed with exit 0 in 645.4 seconds on its first post-fix attempt: 246 Swift tests (155 core, 88 app, 3 probe), 55 browser/pointer tests, and every integration stage, with 60 probe/preview PASS lines. This includes source recovery, access, local/short addresses, source-switching safety, format/cadence, frame rates, and the 1,750 KB keyframe test (496 decoded frames in seven seconds, no decoder errors). Input hashes confirm the runtime/test source was unchanged during this full run. Logs are in `build/suite-reliability/full-check-stages/`; the command result is `full-check-result.json`.

A subsequent packaged-preview check exposed an overly strict new test assumption: the actual first RTCP alignment can produce a **positive 322-microsecond interval**, not only a backward adjustment. The helper correctly emitted the real positive delta. The assertion now applies the 1,000-microsecond lower bound only to the initial guessed duration, while later durations must remain positive and match every positive source-PTS delta exactly. Five deterministic Python cases cover both alignment directions, an 11-microsecond initial guess, mismatched positive duration, late/unbounded jumps and stalled/truncated output. They are part of `scripts/check.sh`; no existing stage was removed or retried. The packaged preview then passed. The final complete run against build 30's **packaged helpers and fixtures passed**, exit 0 in 643.967 seconds: all 246 Swift, 5 Python timing and 55 browser/pointer tests, plus every integration stage. The raw result is `build/suite-reliability/packaged-full-check-result.json`; the full log and the 15 stage logs are retained beside it. No stage retries or skips were added. Runtime/test input hashes still match the final sources.

These are local synthetic-media and socket checks, not physical transmitter, capture-device, phone, Wi-Fi or audible-synchronization qualification.


## Build 30 handoff

The local release build succeeds. Strict signatures pass; all six executables are arm64 and load only system libraries. The unchanged FFmpeg, ffprobe and MediaMTX binaries match build 29; the updated preview helper and Core listener are included. All 37 app files match the staged archive, and 155 source inputs are recorded. Build 30 is an ad-hoc signed developer archive, not notarized. The existing installed app was left running; this handoff provides the updated build as a ZIP. No UI source changed in this pass.

Private Austin Deliveries upload completed with remote verification: [Download build 30](https://drive.google.com/drive/folders/1Ak8IYwKOsfa7R2MNfnj3zNCL7N497BsN). Receipt `20261104T180132Z--41c457f828bf`. Archive SHA-256: `f37e3bc2c283b47084d698fb730a70319d50d476cf4bb820a125f14e796b929f`. The final packaged keyframe test decoded 498 frames in seven seconds from 1,749 KB keyframes without decoder errors.
