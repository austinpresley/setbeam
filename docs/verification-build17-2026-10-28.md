# Build 17 handoff verification

Date: 2026-10-28. Setbeam 0.2.0, build 17. Austin requested all pending project work on the fork's main branch and delivery of the app. The initial working files, including the new source and tests, matched commit `2d11a0a` from PR #8 byte for byte. No app source or test assertions were changed during this handoff. A generated root-level `auto.crt` remains local and is now ignored.

## Automated checks

`scripts/build-app.sh` produced the ad-hoc signed Apple Silicon bundle. `scripts/check.sh` ran with `SETBEAM_TEST_TOOLS` and `SETBEAM_TEST_FIXTURES` pointing into the frozen distribution bundle.

- All 118 Swift tests passed, comprising 84 core and 34 app tests. All 25 viewer-controller checks passed.
- Native file/loopback-RTSP preview, real-media sharing, silent Hold, Stop preserving monitoring, source/helper/server recovery, offline RTSP/RTMP reconnection, and safe source-switching checks passed.
- The full script stopped in the format probe with `The live relay changed decoded cadence: expected 30.0 fps, measured 29.99999340659485, largest frame interval 0.05006699999999986 seconds.` This was the 60 fps H.264 source being capped at 30 fps for viewers. Its saved timeline and failed log remain under ignored `build/main-handoff` and `build/logs`.
- An unchanged isolated `SetbeamProbe --format-test` rerun passed all HEVC/H.264 codec, size, 24/30/60 fps local cadence, capped viewer cadence, quality-change, audio, and continuous-Hold checks. The first failure was not reproduced or diagnosed as a product defect. No timing assertion was relaxed, and this record does not describe the complete script as passing in one run.
- The subsequently run `--frame-rate-test` passed 1 fps watchdog endurance, 5 fps, unchanged dimensions, source/viewing identity, live FPS/bitrate changes, audio-bearing Resume, silent Hold, a slower input under a higher viewer limit, Match source, and Stop/cleanup.
- The subsequent `--keyframe-test` passed with 1750 KB keyframes and 498 decoded frames in seven seconds, without decoder errors.

## Packaged native and browser check

The distribution's own app launched with an isolated preferences suite and the labeled sample. Both native and outgoing previews became ready. Native monitoring measured approximately 24 fps at 1280 by 720. A Chrome Guest window showed the actual sample and Live feed, followed by On hold, Live feed after Resume on the same page, and Sharing ended after Stop. Local monitoring remained live under Hold and after Stop, advancing from 2187 presented frames at the Hold observation to 3109 after Stop. Normal Quit removed all seven recorded private-monitoring app/helper processes. The temporary browser window and T3 verification tab were closed.

The T3 preview opened the viewer and reported playback to the app, but snapshot inspection twice failed with `Preview automation snapshot timed out after 15000ms.` Chrome was therefore inspected through native computer use. A smoke-check assertion initially required `audienceHasAudio` to be false under Hold. That expectation was incorrect: the holding output retains a silent audio track. The native observation check was corrected; the separate actual-media probe established outgoing silence.

## Package

Strict recursive signatures, system-only linked libraries, all six bundled viewer assets, fixtures, build scripts, notices, and the 103-file source/test/build manifest passed comparison. The archive passed ZIP integrity checks. Runtime configuration, logs, and the generated certificate are outside the app/archive.

- Archive: `dist/Setbeam-0.2.0-build17-macOS-arm64.zip`.
- Archive SHA256: `ae756857e9e3a85773b1408f8990fb4fe00772af43d9e830acf6235a61588bef`.
- Executable SHA256: `9fef08582ab85d6a9fe2bf51887a5c6e0ac2d738b5f9f8601f4bdee3da234671`.
- Source/test/build manifest SHA256: `5e632ebabb73dd6ba445a96488d58b1fac479c364d3c7d12cb1ec258d205d6b1`.

This is an ad-hoc signed developer preview for Apple Silicon and macOS 14 or later. It is not notarized. Physical transmitters, a physical 4K display, phones/iPads at 4K, Safari, audible synchronization, viewer capacity, and long sessions were not retested. Existing hardware evidence and the remaining work in `docs/status.md` still apply.
