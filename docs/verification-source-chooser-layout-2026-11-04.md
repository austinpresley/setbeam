# Approved source chooser concept, 2026-11-04

Austin approved `design/concepts/source-chooser/source-chooser-concept.png` and requested the native implementation after the build 27 critique.

## Design and UX

- The existing Choose a source sheet retains immediate source actions, Close and Escape. Header copy: Choose what to preview on this Mac. Changing source while sharing still explains Hold.
- A Last connected strip sits above the scrolling category content. It retains the picture-confirmed saved-setup gate, excludes samples, and restores only the saved source identity. Available is shown only for detected sources. Network connections not currently confirmed say Connection not checked. Current source closes the chooser without restarting the same input. Ended window identities and disconnected capture/display inputs are labeled and cannot reconnect until available. An active source remains selected while unavailable; known hidden and closed-window states are named explicitly. Retained closed AppKit windows can still report hidden, as documented by the existing locator.
- Four native sidebar categories remain visible: Displays, Cameras & capture, Application windows, Wireless transmitters. The initial category follows the current or saved source, with Application windows as the fallback. The sidebar remains keyboard navigable. Only category contents scroll.
- Enter stream address opens the existing Advanced form at its expanded Network stream fields. It does not change current media. Wi-Fi Settings belongs in the wireless category and guides.
- Window search matches application names or window labels, case-insensitively. App groups have 40 pt icons, names and counts. Two equal-height cards per row preserve complete preview aspect ratio. Long titles retain two lines and hover help. Untitled and duplicate labels use stable Window N secondary labels derived from the full group, independent of search filtering. Every selection still uses the complete window identity.
- Current source has its own reserved caption line and border, so it does not change card height. No initial search focus is intended. Buttons have hover and press feedback. Icons are decorative; source buttons retain meaningful accessible names and current-source traits.
- No permission request runs on opening the chooser. Displays and windows explain Screen Recording and expose an explicit Allow button. Missing, loading, failed and no-match lists have inline guidance. Cameras and capture inputs stay peer routes for display or camera content.
- Reference interpretation: native desktop type and system colors replace raster text. The approved layout needs a wider sheet for the category column and two legible preview cards. It adapts its content height to the available screen. Dynamic source lists can scroll.

## Scope and baseline

The initial checkout already contains build 27 and substantial earlier uncommitted work. Before copies and the task-only review patch are under ignored `build/source-chooser-layout/`. Merge-base after fetching origin: `218e8c51f05249e238d3ceaa5ec304586937f18f`. Only the task patch defines this implementation/review. Media pipeline, source identity, saved-credential handling, admission and hardware qualification remain unchanged.

The chooser has its own source file so the existing settings forms do not grow with its layout. Group matching and source identity comparison have focused tests. The project retains its existing Swift 5 language mode and local build/check workflow.

## Validation

- The release build passes. The project keeps its existing Swift 5 language mode. The new chooser uses system colors and native sidebar selection. No developer Homebrew dependency is added.
- The first `scripts/check.sh` passed 222 Swift tests, 43 viewer checks, 12 pointer checks, the preview bridge, simulated Pyro H, general media, source recovery, viewer access, local address, short address and source safety. It stopped at a format-cadence assertion in unchanged code: local expected 60 fps, measured 59.55224769436534 fps, largest interval 0.033332999999999835 s. After shutting down QA, packaged format retries failed at the known live-30-fps limit with largest interval 0.050066000000000166 s, then at local 60 fps, measured 59.610381868781566 fps, largest interval 0.03333300000000072 s. No media threshold or behavior changed. SetbeamCore and SetbeamProbe diffs remain byte-identical to the initial checkout. The format check is recorded as failing, not as an overall script pass. All nine packaged frame-rate checks and the large-keyframe check passed afterward. The latter carried 1,750 KB keyframes and decoded 506 frames in seven seconds without decoder errors. Final exit codes are format 1, frame-rate 0, keyframe 0 in packaged-probe-results.json. The unchanged cadence assertion remains a validation failure for follow-up; it was not relaxed to make this UI change pass.
- A focused test compile initially failed because its new test method was placed in the adjacent CaptureGate helper rather than the test class. Moving that method to the test class fixed compilation. All 15 focused chooser/group/preview tests pass.
- A subsequent full Swift run exited unexpectedly on signal 13 in the unchanged core test process, without an assertion failure. The clean rerun passed all 224 tests, 153 core and 71 app. Logs are `swift-final.log` and `swift-clean.log` under the task's ignored build directory. This task changes no SetbeamCore code.
- Native QA ran the release app in an isolated preferences suite. Two generated fixture applications supplied eight windows, with two untitled, duplicate titles, and a long title. Search by application and title, no matches, clear, immediate exact-window selection, private picture confirmation, restart restoration, category switching, arrow-key navigation, Command-O and Escape passed. Command-clicking the selected category retains a category and its search field.
- Minimized fixture windows drop out of the list. After the model's next presence observation, the pinned source says Show this window; restoring resumes that exact private source. Closing a retained AppKit fixture window reported hidden, consistent with the locator's existing contract. Ending its owner and relaunching produced Window closed, a disabled Reconnect, and no replacement capture.
- Enter stream address opened Advanced at its expanded Network stream form in both appearances, without changing the source. The Pyro H guide remains inline with a Wireless transmitters back action and a relevant Wi-Fi Settings action.
- Light/dark screenshots of the source chooser, empty cameras category, displays, transmitter list and Pyro H guide were inspected, along with the expanded stream form. The final chooser geometry has a 920 × 729 pt sheet, a pinned history row, 212 pt native sidebar, and four equal 171 pt-high window cards. Both app groups and all cards fit the content pane without clipping. Real-frame checks verify leading edges, 12 pt column gaps, equal card heights, containment and visible category navigation. The existing app has no template grid-probe tooling, so AX frames supply the layout measurements.
- Final screenshots are in `build/source-chooser-layout/qa/shots/`. Display screenshots include a local desktop thumbnail and are private QA files, excluded from delivery. Public chooser images contain generated fixture windows and system app icons, not other apps' live content. No media was shared with viewers during this QA.
- Physical capture hardware, a physical transmitter, a second device, macOS permission dialogs, mixed-monitor sizing, portrait windows and spoken VoiceOver were not tested. Accessible names, keyboard navigation and current-source traits were inspected through native accessibility.

## Review

GPT-6.1 Sol on provider codex and high reasoning effort reviewed the task in two rounds. Service tier was default. No sub-reviewers were started.

- Round 1: CHANGES. S1, should: saved capture availability ignored saved audio device and microphone access and could falsely show Available.
- S1 agreed and fixed. The UI now reads both authorization statuses without requesting access. A pure helper checks the exact saved video and sound identities, Camera access, and Microphone access only when saved audio exists. Missing sound says Sound input disconnected; denied microphone access says Needs microphone access. A silent saved capture remains independent of microphone permission.
- The two regression tests produced five assertion failures against the extracted old video-only logic. All 17 focused chooser/group/preview tests pass with the fix. The final release rebuild passes.
- Round 2: APPROVE. S1 resolved, no new findings. The reviewer checked all ten file hashes against the frozen manifest and reviewed the changed code and surrounding caller. It ran no tests or edits.
- Scope before review: 10 files, +530/−217. After the accepted fix: 10 files, +567/−217. The 37 added lines are the complete-route helper and focused regression coverage. No finding was declined. Usage metrics were not exposed.
- Both task IDs use the suffixes `setbeam-source-chooser-layout-sol-r1-20261104` and `setbeam-source-chooser-layout-sol-r2-20261104` under the app's delegated task namespace. Patches, before copies and the current reviewed hash manifest are in `build/source-chooser-layout/`.
- No behavior changed after round-2 approval. No commit, push, PR or hosted workflow ran. Prior dirty work remains unchanged outside this task.

## Packaging

The final build 28 is installed at `~/Applications/Setbeam.app`. Build 27 is preserved at `~/Applications/.Setbeam-before-source-chooser-layout-build28.app`. All 37 app files match across the fresh build, extracted archive and installation, and strict recursive signatures pass. All six executables are arm64 and link only system libraries. The source manifest covers 138 inputs. No code changed after round-2 approval.

- Executable SHA-256: `4ac635f4a31b754215064dba380620f4a52e4ebd35548dab2c1074da84ea37fc`.
- Archive: `dist/Setbeam-0.2.0-build28.zip`, SHA-256 `47bb7c30f7d348013c431721c78226a74cdf739d29e116e2a05fdc29b16ad0d0`.
- ZIP integrity, extracted-file inventory and every app-file hash passed. The archive includes build notes, executable checksum and source manifest.
- Private Austin Deliveries upload completed with remote verification under Setbeam / Source chooser layout. Receipt `20261104T065023Z--6319941d138a` reports state delivered. [Open delivery](https://drive.google.com/drive/folders/1NHFIm00Ek1aRExmtpZyZJ2tBzbgckVch). Only the archive and light/dark window chooser captures are included; private display-thumbnail QA captures remain local.
