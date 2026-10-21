# Outgoing status correction and quick demo

Date: 2026-10-21. Version 0.2.0, build 9. Austin reported repeated outgoing-reconnection text in the Build 8 recording and requested a quick click-through with a visible mouse, no added captions, and moving video if available.

## Reproduction and cause

A native reproduction stopped and started sharing in an isolated Build 8 sample session, then sampled the actual accessibility tree. `checkExpectedOutgoingTransition()` returned `pass: false`. The outgoing-reconnection banner was visible at 44, 323, and 1372 ms after the action returned, clearing by 2399 ms. The publisher was already reported live at 1372 ms while the outgoing thumbnail was still opening. A browser subsequently decoded fresh video normally.

The old predicate combined actual outgoing readiness with the thumbnail decoder's readiness. Start, Hold, and Resume intentionally restart the outgoing publisher; each operation also opens or restarts its thumbnail decoder. That normal preparation was being labeled as reconnection. This is a presentation bug, not evidence of repeated network loss in that recording.

The actual predicate was moved to SessionModel without changing its behavior, then `swift test --filter OutgoingStatusTests` was run. It failed two targeted assertions:

- `A healthy outgoing stream is not reconnecting while its local thumbnail opens.`
- `A cached thumbnail cannot establish a healthy holding output.`

The red log is ignored at `build/outgoing-diagnosis/regression-red.log`. This fixes the observed classification rather than suppressing all warnings.

## Correction and verification

The main status now observes actual outgoing-media readiness independently of the thumbnail. Explicit Start, Hold, and Resume actions have Starting sharing, Applying Hold, and Resuming sharing preparation states, bounded at ten seconds. Fresh output ends preparation immediately. An ensuing unplanned loss therefore has no leftover grace period. Stop or a known failed audience action clears the pending transition. Hold readiness uses the holding output independently of source availability. The thumbnail can say Checking outgoing preview while opening.

`OutgoingStatusTests` covers healthy output with a late thumbnail, missing holding output with a cached thumbnail, a real unplanned live loss, private monitoring, and a healthy holding output with an unavailable input. `OutgoingTransitionTests` covers bounded preparation, first-fresh-output completion, reset after Stop/error, and replacement by a newer explicit change. The final complete run passed 51 Swift tests, comprising 33 core and 18 app tests, five viewer-controller checks, and the packaged media/recovery/source-switching probes.

The original native Start reproduction on the corrected release returned `pass: true`. Native Hold and Resume checks also reported `normalHoldAndResumePassed: true`, with no false recovery banners. Actual source changes, silent Hold, stable viewer identity, read-only access, recovery, and owned-process cleanup continue to pass the bundled-runtime integration probes. No new physical compatibility or long-session evidence is claimed.

Final frozen release packaging passed unchanged-source checks, strict signatures, bundled viewer hashes, and system-only dynamic dependencies. Evidence is ignored under `build/outgoing-status9`.

- App: `dist/Setbeam-0.2.0-build9-macOS-arm64/Setbeam.app`
- Executable SHA256: `b8ce56f9f2ff48d39e9ad484298eb73c8b40db3fec80881d49c783018803a261`
- Source snapshot SHA256: `4044b233b999e675334bb852480fd1ae4b19342dd8eae7f0d9e7d6c5dfd2c706`
- App archive SHA256: `7c2694d6c4201b16400ef59626a26a477b85ac87c32ee889fec08d9d287e2917`

The previous production window was confirmed Private and quit normally. Build 9 opened with the same saved CineView Master 4K, sharing/Hold off, and Mac sound muted. That physical source was unavailable at this checkpoint and the app was waiting for it; fresh physical playback is not claimed for this build.

## Quick click-through

`dist/Setbeam-build9-quick-clickthrough.mp4` is a 32.67-second, 1440×932, 30 fps H.264 native screen recording. It shows moving sample media, source/session and sound popovers, floating preview, settings, invitations/copy feedback, Hold, the actual outgoing holding output, Resume, and Stop. It has no added titles or captions. A visible pointer and click rings follow the recorded control-click targets. Pauses are trimmed and playback is 1.25x; it is a demonstration, not a timing benchmark. There is no audio track.

The moving footage is an excerpt of Big Buck Bunny, `(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org`, used under [Creative Commons Attribution 3.0](https://peach.blender.org/about/). It was downloaded from the [official movie directory](https://download.blender.org/peach/bigbuckbunny_movies/), trimmed, scaled, and re-encoded into the fixture of a separate demo copy. The distributed app retains its approved original sample. The demo executable uses the same release code; its bundle identity and fixture differ for isolation. Film attribution and license links are embedded in the final MP4 and included in the delivered notes.

The entire final MP4 decoded without errors. Representative frames confirmed visible pointer/click rings, the full floating preview and outgoing popover, moving footage, and no caption overlays. Chromium confirmed advancing playback at the expected dimensions and duration with no media error. The sample app was quit after recording, expiring its viewing credential. Captures, the source movie, temporary recorder, and edit data stay ignored under `build/clickthrough9`.

## Private delivery

Delivery `20261021T042437Z--f3f614eb112f` completed remote verification. The private delivery folder contains the finished Build 9 app archive, `Setbeam-build9-quick-clickthrough.mp4`, and `BUILD-NOTES.txt` with verification, limits, and film attribution. Raw captures, input movie, QA app, runtime data, and credentials were excluded.
