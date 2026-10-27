# Architecture pass

Date: 2026-10-23. Version 0.2.0, build 10. Austin approved independent session ownership, timestamped native playback, an explicit media contract, and uninterrupted audience infrastructure during input changes.

## Changes

MediaRuntime owns session intent and health, serializes lifecycle commands across actor suspension points, and runs its own recovery task. Snapshot reads are observational. The UI consumes bounded snapshot updates and retains presentation and saved-setup concerns. Native playback and the viewer gateway supervise their own recovery. Shutdown checks prevent suspended UI actions from reopening decoders after cleanup. Source identity comes from the runtime when a failed replacement leaves the previous input active.

The separate supervised preview executable decodes video and audio from one private RTSP input. A bounded versioned protocol retains presentation timestamps, NV12 video, sample aspect ratio, color-matrix/range information, and stereo PCM. Main and floating views share the presented image. Audio and video use one native playback clock, with bounded queues and stale-frame dropping. The main preview preserves input dimensions and cadence. The outgoing thumbnail explicitly uses a smaller silent decode. The helper, pinned source materials, build script, and system-only dependency evidence ship in the app.

External inputs normalize to H.264 Baseline without B frames and optional Opus. Only verified bundled sample video is copied. Readiness requires observed compatible media metadata. Source changes establish actual holding output, retain the media server and existing holding publisher, and update only the selected input. A private stable RTMP listener plus a bounded interface/subnet-restricted TCP ingress relay isolates input-binding failure from audience infrastructure. Sender-key changes disconnect the previous input sender.

## Regression evidence

The ownership regression first failed because killing the input did not produce a replacement without a status request. After the refactor, RuntimeOwnershipTests passed recovery without status reads and shutdown without resurrection. Hold and the viewing credential remained intact.

Actual bridge checks decode a generated 1920 by 1080, 60 fps source, verify all 60 frames and presentation timestamp spacing, and verify matching-source stereo PCM. The silent 384-pixel, 8 fps thumbnail is checked separately. File checks initially missed an RTSP-specific duration bug. The actual MediaMTX regression reproduced incorrect decoded duration metadata, and the correction sets the decoder packet timebase and derives cadence from decoded timestamps. The native RTSP check measured 1280 by 720 at 24.000 fps, 63 presented frames over 2.5 seconds, and a maximum frame/shared-clock difference of 10.14 ms. This is internal presentation timing, not glass-to-glass latency or audible synchronization evidence.

The media-format probe exercises HEVC Main with B frames, H.264 High with B frames, different dimensions and 24/30/60 fps cadences, video-only input, and AAC input. It checks actual decoded timestamp cadence over at least one second, H.264 profile, B-frame absence, pixel format, dimensions, and optional Opus. An early combined check failed because RTSP r_frame_rate metadata was guessed as 48000/1001 for a 24 fps source; cadence assertions now measure decoded frame timestamps instead. The format cases passed after this correction. The upstream reader count remains one.

Continuous decoded audience video survives incoming-key rotation, an offline incoming input, an offline RTSP input, return to incoming, and a deliberately occupied incoming port. The probe asserts that the media server and holding publisher retain their process IDs and that the holding publisher revision does not change. Hold stays silent, local monitoring remains private, and returning to live output requires explicit Resume. Generic RTSP/RTMP input-loss and restoration checks passed independently.

Viewer gateway tests cover autonomous real-listener recovery on the same port and session, failed startup retry, deadline handling, replacement of pending work, Stop cancelling retries, and deallocation. UI review also found and corrected stale continuations after shutdown, preview controls enabled by an unprepared port-zero snapshot, and previous-source identity/local-preview restoration after failed replacement preflight.

The staged configuration test injects failures before credential and path updates while the previous upstream remains healthy. Repeated autonomous retries cannot start a source publisher under the new identity until configuration succeeds. The same server and holding publisher continue running; recovery then decodes the visibly different replacement picture. MediaMTX intentionally redacts credential bytes on readback, so verification checks successful serialized updates and the exact non-secret user access scopes and path, rather than comparing redacted passwords.

The first combined packaged test run found a race in the gateway deallocation test: its resumed async caller could assert before the active callback released its temporary receiver. The test now waits up to one second for the weak reference to clear and still requires no recovery listener to be created. No production change was needed for that test correction.

## Final native and package checks

The final packaged-runtime `scripts/check.sh` passed all 75 Swift tests, comprising 47 core and 28 app tests, five viewer-controller checks, and the file/RTSP bridge, sample/RTSP/RTMP, recovery, source-switching, and codec/format probes. The frozen source/test snapshot remained unchanged through packaging and these checks, with SHA256 `e096555f9835d31f8ba1276072f8d49fb545b717ca3fffa6cc3efe06f5f37e0c`. Logs are ignored under `build/logs/architecture-packaged-check-final.log` and the individual check logs.

The release package is version 0.2.0, build 10 for Apple Silicon, targeting macOS 14 or later and checked on this macOS 27 host. Strict bundle signature verification and system-only dynamic dependencies pass for the app and all five helpers. Bundled viewer resources and preview source match their repository bytes. The app executable SHA256 is `30c00d8c04da68fcf8853af617bf7d788b191db9b664a078e79379987c4e74ba`.

The archive is `dist/Setbeam-0.2.0-build10-macOS-arm64.zip`, with SHA256 `ba450753495073efcfb44aedde75e5b77646a4195d220a527e032e5e27e5d0fb`. It contains the self-contained app and finished build notes; ZIP integrity verification passes.

An isolated copy with its own bundle identifier and preferences displayed the actual native sample picture and advancing shared floating preview. Start, Hold, Resume, and Stop followed the same Chromium page. During Hold the browser was muted with playback detached, while native frames continued. Resume restored actual advancing video and audio tracks. Stop ended the browser session while main/floating monitoring continued. Native checks required correct dimensions/cadence, a shared playback clock, and presentation error below 80 ms.

A separate isolated copy used a generated, explicitly labeled 1920 by 1080, 60 fps test pattern. Its actual main-window picture was inspected, and advancing native/floating playback passed the 1080p60 and clock checks. Normal private Quit stopped the app and all six owned descendants; Force Quit during sharing stopped the app and all ten owned descendants. The production app and its saved source were not operated.

Local unmute reached the device-start timeout on this host, returned to the explained muted state, and left video and audience controls working. Native audible output is not established by the encoded PCM or shared-clock tests. This preserves the earlier physical audio limitation.

## Private delivery

Delivery `20261023T042217Z--34baea49b2b8` completed remote verification. It contains the finished Build 10 archive and build notes. Raw QA copies, generated patterns, telemetry, runtime directories, and session credentials were excluded. The private delivery URL is kept outside the repository.

## Verification limits

All media above is labeled sample or synthetic fixture media. This pass does not extend hardware compatibility. Existing physical Master 4K evidence, the failed short continuous-run criterion, and the deferred long-session check remain recorded in hardware-tests.md. Transmitter-to-screen latency, audible source sound and synchronization, physical format changes, range, capacity, and coexistence still require physical tests.

Ad-hoc developer signing does not establish Developer ID signing, notarization, or a public release. Raw logs, private session files, generated media, runtime directories, and build products stay ignored.
