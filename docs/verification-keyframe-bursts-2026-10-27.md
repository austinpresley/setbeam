# Screen-sharing stability verification

Date: 2026-10-27. Version 0.2.0, build 17. Austin reported that sharing This Mac's screen periodically entered the reconnecting loop and supplied a Build 15 session log. He then provided a 3840 by 2160 virtual display for testing.

## Report

Sharing started at 00:07:10Z. At 00:07:24Z the native preview reported H.264 bitstream errors such as `out of range intra chroma pred mode`, `corrupted macroblock`, and `cbp too large`. It then alternated between stopped and playing. 50 of the session's 55 `preview.stopped` events carry decoder errors, the last at 00:25:23Z. The errors address macroblock column 239 and row 126, so the captured picture was 3840 pixels wide. The same decoder instance appears across consecutive stops: the decoder process stayed running while presented frames went stale for the two-second freshness interval.

## Causes and changes

### Keyframe bursts discarded by the relay

MediaMTX keeps a per-reader RTP queue and discards packets when it is full, logging `reader is too slow, discarding N frames`. The default `writeQueueSize` is 512 packets, about 750 KB of 1,460-byte payloads. A detailed screen produces keyframes of several megabytes. Each one reaches MediaMTX as one burst and overflows the queue of any reader that is not draining at that moment. The native preview and the audience relay both read `local`, so both decoded truncated pictures until the next keyframe.

`MediaRuntime` now sets `writeQueueSize` to 8192, enough for MediaMTX's largest accepted 8 MiB access unit. MediaMTX v1.21.2 exits with `'writeQueueSize' must be a power of two` for a value such as 5000; a unit test guards both properties.

A throwaway harness ran the bundled MediaMTX, FFmpeg, and `setbeam-preview` with the app's exact Screen input, audience relay, and thumbnail arguments, fed by real-time VideoToolbox fixtures. An early harness run fed fixtures at about 33 times real time because a remux collapsed their timestamps; those results were discarded.

| Fixture | Sharing | Queue | Duration | H.264 error lines | MediaMTX warnings |
|---|---|---|---|---|---|
| 4K60 desktop-like, 170 Mbps, 6.3 MB average keyframe | yes | 512 | 10 s, three runs | 18, 18, 18 | 28, 29, 31 |
| 1080p60 desktop-like, 42 Mbps, 1.5 MB keyframe, two runs | no | 512 | 10 s | 20, 20 | 10 reader discards each |
| same | yes | 4096, 8192, 16384 | 10 s | 0 | 0 |

`SetbeamProbe --keyframe-test`, now in `scripts/check.sh`, relays a static random-luma 1080p60 Baseline picture through a real runtime while sharing and decodes `local` with `setbeam-preview`. Before the change it failed three of three runs, for example `Keyframes of 1021 KB reached local monitoring damaged while sharing: 494 frames, 18 decoder errors`. After it, three of three passed with 1,749 KB keyframes. Keyframes measured on `local` before the change were 980 to 1,468 KB, which shows the mid-picture discards directly.

### Native preview stalls without decoder errors

The real app, run from a shell with Screen Recording access on the 4K display, reproduced the reconnecting loop after the queue change. Sharing a detailed full-screen picture stopped presented frames for 7.5 s, after which the decoder watchdog restarted the decoder. Telemetry showed about 50 decoded frames a second throughout, with none presented and every one evicted from the playback inbox. The newest decoded picture was 0.13 to 0.17 s ahead of the playback clock.

The clock re-anchors when a picture arrives late, which leaves it at the pipeline's worst latency. Later pictures are then early. The inbox's 32 MB bound holds two 12.4 MB 4K pictures, and the early-frame re-anchor threshold is 0.25 s, so every picture between those bounds was evicted before it was due. Any 4K source could do this.

`PreviewInbox` now reports an overrun when capacity evicts a picture, and `PreviewPlaybackTiming.needsAnchor` restarts the clock at the newest picture. A deterministic test feeds 4K pictures 150 ms ahead of the clock: 0 of 120 were presented before the change and more than 100 after. In the real app, the same 40-second share went from 7.5 s stale with 1 to 5 presented frames a second to no stale samples and about 32 presented frames a second.

### CPU colour conversion in every native window

The app used about two cores at 4K and presented 38 of 60 decoded frames while only monitoring. A sampled profile showed CoreImage loading Metal kernel libraries for each frame and vImage converting YUV to RGB on the CPU (`vConvert_PermuteChannels_ARGB8888` and related functions led the non-idle samples). Each frame was an `NSImage` wrapping `NSCIImageRep`.

Frames are now pooled IOSurface NV12 pixel buffers shown through `AVSampleBufferDisplayLayer` in the main window, floating preview, and setup-check thumbnail. Measured on the 4K display:

| Case | Before | After |
|---|---|---|
| Monitoring, low-detail timer | 38.4 of 60.3 fps presented, app 202% CPU | 59.5 of 59.6 fps, app 26% CPU |
| Sharing, detailed picture | about 32 fps presented, app about 180% CPU | 46.6 fps presented of 50.8 decoded, app 25% CPU |

Window captures confirmed the main picture at the correct aspect and colours, and the floating preview at full picture, zoomed to 173%, and reset.

### Oversized 4K keyframes stopped the screen source

Full-range random RGB on the 4K display never produced a picture. The Screen input restarted seven times with `dimensions not set`. VideoToolbox emitted a keyframe of 11.6 MB at the app's settings; `VideoPipeWriter` closed the pipe because one picture exceeded its 8 MiB bound, and MediaMTX also refuses access units above 8 MiB.

`ScreenEncoder` now owns the VideoToolbox session and Annex B conversion that `MacScreenCapture` used, and applies `KeyframeBudget`. `MaxH264SliceBytes` was rejected by the hardware encoder (`-12900`). A one-frame `DataRateLimits` window did not bound keyframes. After one oversized keyframe, VideoToolbox emitted no further keyframes even when forced. A minimum QP set at session start did bound them: on full-range random 4K, QP 20, 26, 32, and 38 gave 10.7, 8.4, 6.7, and 5.1 MB.

`ScreenPipeProbeTests` encodes full-range random 4K through the real encoder at real-time pace, then requires every access unit within 6 MiB and a first picture carrying its parameter sets. The bundled FFmpeg must decode the stream through `screenInputArguments` with no H.264 errors. Before the budget it failed with an 11,904,893-byte access unit. In the real app afterwards, extreme content settled after two restarts (8.12 MiB at no floor, then 7.21 MiB at QP 20) with 5.91 MiB keyframes at QP 26 and no source restarts. Photo-like grain needed one restart and then kept 4.10 MiB keyframes.

### MediaMTX warnings in the session log

The original log could not show relay discards. MediaMTX's stdout warnings and errors are now `server.warning` entries, with repeats of one kind within ten seconds counted.

## 4K results after all changes

Each row is a real-app run sharing for 25 to 30 seconds on the 3840 by 2160 display. The text and mixed runs predate `ScreenEncoder`; its budget does not engage below 6 MiB. All were green: no stale samples, `preview.stopped` events, source restarts, or MediaMTX warnings.

| Content | Largest keyframe | Decoded fps | Presented fps |
|---|---|---|---|
| Text | 2.89 MiB | 50.8 | 50.2 |
| Mixed text and grain | 4.67 MiB | 51.2 | 47.6 |
| Photo-like grain | 4.10 MiB with QP 20 | 50.5 | 49.1 |
| Full-range random | 5.91 MiB with QP 26 | 50.4 | 44.7 |

A headless Chrome viewer with a temporary profile watched a 60-second 4K share. It reported Live feed for 117 of 120 samples with no recovery transitions after connecting, at 3840 by 2160. Chrome decoded 43.8 fps and dropped 396 frames itself; playback time did not advance for one second once.

## 30 fps maximum and the viewer stream

Two concurrent 4K60 VideoToolbox encodes, screen capture and the viewer stream, saturated this Mac's hardware encoder: `VTCompressionSessionEncodeFrame` blocked until 240 frames per session took 4.66 s, about 51 fps, and prioritizing speed did not help. Austin decided that Setbeam's use needs at most 30 fps. Match source and Match display now resolve to at most 30 fps, the 60 fps choice is removed, and a saved 60 falls back to Match source. The viewer encode applies the 30 fps selection even when matching the source. Local monitoring of external feeds keeps its received cadence because it is copied.

Headless Chrome then exposed the viewer stream. At 1 fps on a detailed 4K picture it never left Ready to play. WebRTC statistics showed 117,188 packets received, none lost, no frames assembled, and 166 keyframe requests. The viewer's keyframes on `live` were 4.26 MiB at 1 fps, 2.32 MiB for text at 1 fps, and up to 2.94 MiB at 30 fps. Measured with the bundled encoder on a detailed 4K picture:

| Rate control | 1 fps actual | Largest frame | 30 fps actual | Largest frame |
|---|---|---|---|---|
| 12 Mbps average only | 37.8 Mbps | 4.56 MiB | 17.5 Mbps | 4.54 MiB |
| `-constant_bit_rate` | 24.6 Mbps | 3.24 MiB | 31.0 Mbps | 3.42 MiB |
| `-maxrate 12000k` | 6.9 Mbps | 1.54 MiB | 8.7 Mbps | 1.54 MiB |
| `-qmin 30` | 28.8 Mbps | 3.58 MiB | 16.9 Mbps | 3.58 MiB |

The viewer encode now sets `-maxrate` to the selected allowance. The same tab also recorded `AbortError: The play() request was interrupted by a new load request`. The viewer treated every rejection as blocked autoplay, which shows Ready to play and suspends its stale-peer watchdog. It now treats only `NotAllowedError` that way, and a viewer test covers the interrupted request.

Real-app 4K shares with the Chrome viewer, 40 seconds each:

| Case | Native decoded/presented | Viewer before | Viewer after |
|---|---|---|---|
| Photo-like grain, 1 fps capture and viewer | 1.0/1.0 | never live | live at 1.0 s, 1 fps, 40 keyframes decoded, no keyframe requests |
| Mixed, Match source | 30.0/29.6 | live at 4.6 s | live at 1.5 s, 25.2 fps |
| Full-range random, Match source | 30.1/28.2 | live at 11.6 s | live at 1.6 s, 28.4 fps |

None lost packets, stalled natively, restarted a source, or logged a MediaMTX warning.

## Limits and remaining work

- Headless Chrome is not a phone. Safari on iPhone and iPad at 4K, and many viewers at once, are untested after the viewer rate-limit change.
- The local software decoder is limited to about one core because VideoToolbox emits one slice per picture. VideoToolbox hardware decoding was tested and rejected: on a damaged 4K stream it failed all 300 pictures, where software decoding concealed errors and output all 300. A lost packet would freeze the picture instead. The runtime was rebuilt back to its original configuration.
- When monitoring, the local decoder used 30% of a core at 4K and the app 28%. Heavy full-screen motion was measured only at 1080p.
- The virtual display changed from 3840 by 2160 to 1920 by 1080 between 21:43 and 21:49 outside Setbeam. Results from that interval are 1080p and are not used above. The display was returned to 3840 by 2160.
- Intermittent `scripts/check.sh` failures, each of which passed when rerun alone:
  - Three background runs stopped at `check-preview-bridge.py:98`. The first two loopback-RTSP frames had timestamps out of order, for example 0 then -156 µs, each with an 11 µs duration. That script uses its own MediaMTX and FFmpeg sender, unchanged by this work, and waits 0.3 s before decoding. Seventeen direct runs failed once, and relinking first did not reproduce it.
  - `LowRateInputTests` once failed after 0.7 s with `The video service could not start.`, then passed four times alone. MediaMTX's own message was not captured.
  - The recovery probe once reported `RTSP did not reconnect on cycle 1.`, then passed twice alone.
- One full run failed by design after the 30 fps change: the format probe expected 60 fps on `live`. Its expectation now caps viewer output at 30 fps while still requiring local monitoring to keep 60.
- The final foreground `scripts/check.sh` passed 118 Swift tests, 25 viewer checks, and every media probe.
- These are automated and native checks on one Mac with a virtual display. A physical 4K monitor, phones, and Master 4K sources were not retested.
