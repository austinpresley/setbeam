# S-001 single application window

Austin requested backlog S-001: choose one application window, such as Capture One, instead of a whole display. The existing Choose a source sheet now lists other applications' windows beside displays, with previews. One ScreenCaptureKit window capture feeds the existing local relay, main and floating monitoring, and audience sharing. Screen Cockpit's window chooser and identity rules were read as a reference only; nothing in that project changed.

## Design and behavior

- **Chooser.** Application windows sits after Available now. A three-column grid shows each window's 140 by 84 point preview, fitted without cropping, with its application icon, title (two lines, full text in hover help), and application name. Empty titles read Untitled window. The current window has an accent border and Current source, and shows the existing monitored picture rather than taking a screenshot; choosing it again only closes the sheet. Loading, empty, and listing-failure states have their own text. Without Screen Recording access, the section explains that windows appear after the existing Enable Previews action; opening the chooser never requests access.
- **Bounded previews.** With access, the list and the pictures of rows on screen refresh every two seconds, at most nine screenshots per pass, one at a time. Each is a silent, shadowless, cursor-free single-window screenshot. Closing the chooser invalidates any screenshot in flight and clears every image, icon, and window handle. Setbeam's own windows are never listed.
- **Identity.** The window number, owner process ID, and the owner's kernel start time. Titles are labels only. Every capture start resolves that exact identity and refuses Setbeam's own process. A reused number, another process, or a relaunched owner with a reused process ID never matches. The session log and diagnostics say only Application window.
- **Capture.** The window's pixel size at start, bounded to 3840 by 2160, sets the stream size. Cadence uses the saved capture frame rate, including 1 fps, up to 30 fps. The existing ScreenEncoder, pipe, supervised FFmpeg, readiness, recovery, Hold, and Stop paths are unchanged.
- **Loss.** On the tested build, minimizing, hiding the application, and closing a retained AppKit window all send one `suspended` frame status and then nothing. Capture stops repeating its last picture, so the source becomes unavailable and viewers see reconnecting. The main window says Waiting for the selected window and asks to show it again. A missing window number or a quit owner is The selected window closed, with Choose a window. Restarts check the exact identity before starting any helper, so retries are cheap and never pick a different window. If the hidden window returns and no new frame arrives within three seconds, Setbeam retries once instead of waiting for runtime backoff.
- **Restoration.** A window identity lasts only as long as its owner process. A proven window setup restores privately after Setbeam relaunches only if that same window of that same running process still exists. Otherwise Setbeam starts nothing and asks the operator to choose a window again.

## Automated checks

- 141 Swift tests pass (97 core, 44 app), including 8 new core tests and 6 new app tests. They cover identity validation, exact-match presence including a renamed window, another window number, another process, a reused process ID with a different start time, unreadable window lists, the closed-owner message, kernel start times, saved-setup round trip and decoding of older saved setups, bounded and sanitized labels, generic log labels, eligibility, stable ordering, the 30 fps ceiling and 1 fps, no listing or capture without access, monitored-window exclusion and the nine-screenshot bound, discarding a screenshot that finishes after the chooser closed, failed previews, refusing to restore a window whose owner has ended, and the one-shot retry when a returned window sends no new frame.
- All 26 viewer-controller checks pass.
- The final `scripts/check.sh` passes in one run: preview bridge, 26 viewer checks, all Swift tests, and the Pyro H, media, recovery, source-switching, format, frame-rate, and large-keyframe probes.
- The first complete pre-review run passed the preview bridge, viewer checks, Swift tests, Pyro H, media, recovery, and source-switching probes. It then hit the existing format-cadence assertion: `The live relay changed decoded cadence: expected 30.0 fps, measured 29.999996629213864, largest frame interval 0.050067000000000306 seconds.` That is the same 50.067 ms interval recorded for builds 17 and 20, on sample media this change does not touch. The isolated format, frame-rate, and large-keyframe probes then passed.
- The first attempt in this new worktree stopped before any check because `Vendor/sources` was absent. The parent's built FFmpeg/Opus static libraries were copied read-only; `Vendor/bin` hashes stayed identical to the parent's.
- New opt-in `SetbeamProbe --window-test`. It needs Screen Recording for the process running it, so `check.sh` does not run it. The probe runs a generated, labeled window in a separate owned process, with an unrelated magenta window over part of it. It passed with real ScreenCaptureKit capture and bundled media:
  - The window list identified the fixture by number, process, and start time, without the probe's own process.
  - The local relay was 640×428 (window plus title bar), 91% fixture colour, 0.00% of the overlapping window.
  - Audience output carried only the window. Hold replaced it (0% fixture colour) while local monitoring continued; Resume and Stop kept monitoring.
  - Renaming, moving, and resizing kept the same source at 640×428. The wider window was fitted whole beside an 8% black bar (8.9% expected), not cropped.
  - Minimizing paused the source; restoring returned the same window.
  - Closing paused it. A new window with the same title in the same application was not substituted, even after a retry.
  - After the owner quit, the window was reported closed, nothing else was captured, and shutdown removed every owned process.
- Grid lint passes on the new view file and the added layout lines.

## Review

Two independent GPT-6.1 Sol reviewers (Codex, reasoning effort high) reviewed the complete base-to-working-tree diff: one emphasizing identity, privacy, and lifecycle, the other chooser previews and native integration. Both approved in round 2.

| ID | Severity | Finding | Outcome |
| --- | --- | --- | --- |
| A1 | should | Returning within the six seconds cached availability stays true skipped the three-second retry. | Fixed: the retry arms on every return and only a newer frame cancels it; regression test added. |
| A2, B2 | nit | Docs said choosing the window again adopts a new size. | Fixed: Retry now does; choosing the current window only closes the chooser. |
| B1 | nit | Unmonitored thumbnails observe the live player and redraw with playback. | Declined: same pattern as display thumbnails, chooser-lifetime only. Follow-up. |

## Native verification

An isolated, ad-hoc signed release QA copy of build 21 ran with its own preferences suite and session log under ignored `build/s001`. Three generated windows from a QA fixture application (`app.setbeam.qa.s001fixture`) provided content. The QA-only `--window-fixture-bundle` argument, honored only together with `--preferences-suite`, limited the chooser to those windows so private desktop windows stayed out of every capture. Dark captures used the app's `-AppleInterfaceStyle Dark` argument default and light captures `-NSRequiresAquaSystemAppearance YES`; the Mac's own appearance was not changed. The display row's existing live desktop thumbnail is redacted in delivered chooser images. The production app was not running.

- The real chooser listed all three windows with application, title, pixel size, and No sound, including a 113-character title (wrapped and truncated, full text in help) and an untitled window. Previews fit without cropping in active dark and light sheets.
- Choosing a window gave native monitoring at its exact 820×552 pixel size at about 30 fps. The floating preview showed only that window. macOS showed its own purple capture indicator in the shared window's title bar.
- Sharing reached an actual browser viewer at 820×552, Live feed, 91% fixture colour. Hold showed On hold with playback detached while native frames advanced from 2073 to 2264. Resume returned live on the same page. Stop showed Sharing ended while native frames advanced from 702 to 766.
- While sharing, minimizing the window stopped native monitoring within about 3 seconds and the source within about 8. The main window showed Waiting for the selected window. Restoring returned the same window in about 4 seconds. After review, the final build resumed a window hidden for 4 seconds on its running capture, and one hidden for 16 seconds in 5 seconds through the runtime's own restart; neither needed the one-shot retry, whose firing is covered by its unit test.
- A title change kept the source and updated its toolbar label.
- Closing the window paused the source. A new window with the same title in the same application, with a new window number, was not substituted after Retry now. Quitting the owner showed The selected window closed.
- Relaunching with that saved setup started no session and asked to choose again. Choosing another window, letting it be remembered, and relaunching with a saved 1 fps capture rate restored that exact window privately at 1.0 fps with sharing off.
- This Mac's screen still captured the 1920×1200 display at about 28 fps after the capture refactor, switching from a window source. No desktop screenshot was taken.
- A Launch Services launch without this shell's Screen Recording grant showed Preview off, the Enable Previews action, and window guidance without a list. It made no Screen Recording request: no TCC or authorization-dialog log entries appeared during the check. macOS showed its existing Local Network prompt for that build; it was left unanswered.
- Normal Quit of each monitoring QA session removed the app and all six recorded descendants (MediaMTX, FFmpeg, the preview bridge, and three supervisors). The final permission-denied instance had no media helpers. An automation mismatch chose the Apple menu's Force Quit Setbeam instead of Quit; nothing was left running.

A system Screen Recording dialog for "Setbeam" was already open from a long-running `universalAccessAuthWarn` process started on October 26. No log entry tied it to this run, and it was not touched.

## Limits and checks not run

- Only one 1920×1200 display was connected. Moving the window between displays, mixed scale factors, portrait, and hot-unplug are unverified. The identity and capture filter follow the window rather than a display, and pixel size uses the filter's own scale.
- A resize after capture starts keeps the starting stream size; the window is fitted inside it, not cropped. ScreenCaptureKit anchors the smaller picture to one edge, leaving a single black bar. Retry now restarts capture at the window's new size; choosing the current window in the chooser only closes it.
- Minimized windows, windows of hidden applications, and windows on another Space are not listed and pause an active window source. Only the window itself is captured: separate menus, popovers, panels, and other windows of the same application are not. Sheets attached to the window and full-screen windows were not tested.
- Capture One itself, other real applications, and VoiceOver speech were not tested. The fixtures are generated AppKit windows.
- Setbeam's own Screen Recording grant when opened from Finder was not granted or changed for this check; real capture ran with the access inherited from the launching shell.
- No physical transmitter or hardware compatibility claim is made. All checks ran locally, with hosted CI disabled.
