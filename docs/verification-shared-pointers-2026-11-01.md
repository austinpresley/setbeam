# S-008 shared pointers with viewer admission

Austin requested backlog S-008: an admitted viewer opts into pointing at the shared picture, and the operator and other pointing viewers see a colored pointer with that person's name. S-008 depends on S-002, S-003, and S-005. This pass adds the parts of those stories that pointers need to be safe: server-issued browser-session identity, optional approval, and individual removal that ends media access. It does not add passwords, a separate compact viewer, viewer zoom, drawing, or presenter cursor highlighting.

## Design

- **Identity.** Each tab joins with `POST join` and receives a 48-hex-character secret pass from the gateway. Heartbeats, `config.json`, and the presence channel accept only that pass. A browser-chosen ID now identifies nothing. Operator rows show Setbeam's session number. Names are bounded plain-text labels and are never treated as verified.
- **Approval (optional).** Off: the link admits as before, and playback uses the link's shared read credential. On: a tab must enter a name and then shows "Waiting for the operator". The operator's rows offer Admit and Decline. An admitted tab plays only with its own MediaMTX read user, and only after MediaMTX has accepted that user. The shared `guest` user is removed, so the viewing-link token alone cannot read media. Under approval the name is the admitted one and cannot be renamed.
- **Removal.** Remove refuses the pass immediately: `config.json`, heartbeats, and presence stop working for it, and its channel closes. The runtime deletes that reader from MediaMTX and then kicks every WebRTC and RTSP session reported for that user, so a reconnect fails authorization. Other viewers continue. Reloading a removed or declined tab keeps the decision. A new tab is a new request.
- **Turning approval on during sharing** gives already-admitted sessions their own readers. Shared-credential sessions are disconnected, and the publisher revision advances so pages reconnect with their own credentials. Turning it off admits waiting requests and keeps refusals.
- **Shared pointers.** A separate operator option. An admitted page opts in with a name and one of six validated colors (blue, green, orange, pink, purple, yellow), then opens a same-origin WebSocket on the existing gateway. The first message must carry an admitted pass. Text frames are masked and at most 512 bytes, limited to 120 frames/s. A channel must say hello within 3 s and is closed after 20 s of silence or a 5 s stuck send. There are at most 16 participants and 24 channels. Each receiver gets the others' number, label, color, picture-relative position, and remaining time; nothing else. It never reaches media control, publishing, administration, or the roster.
- **Presence state.** The server keeps only each participant's latest position for the current publisher revision. Positions must be finite and within the picture (0 to 1). Updates for another revision, while not live, or above 30/s are dropped. A pointer stays visible for 4 s after meaningful movement (0.3% of the picture) or a tap. Repeated or tiny updates do not extend it, and no final hide is needed. Hold, Stop, a new publisher revision (including source changes and encoder restarts), removal, a closed channel, a new link, and turning pointers off clear positions. Receivers coalesce to one send in flight with the newest snapshot. Browsers and the native overlay also expire each pointer locally.
- **Mapping.** Browser pointer events map through the video's `object-fit: contain` rectangle, so letterboxing and page controls are not the picture. The native main monitor maps through its aspect-fit rectangle. The floating preview's overlay covers the zoomed image rectangle, so zoom and pan move pointers with the picture. Overlays take no mouse events and never enter encoded media.
- **Look.** One arrow shape: the participant's color with a white outline and shadow, plus a colored name label with a white edge. Label text is white or near-black to keep at least 4.5:1 contrast. Equal names add the session number ("Sam · 3"). The label flips near the right and bottom edges without moving the arrow tip.

## Automated checks

- The final `scripts/check.sh` on reviewed commit `c5e5ea6` passed in one run: preview bridge, 31 viewer-controller checks, 12 pointer-controller checks, 178 Swift tests (129 core, 49 app), and the Pyro H, media, new viewer-access, recovery, source-switching, format, frame-rate, and large-keyframe probes.
- **New Swift tests** cover:
  - Admission rules: no-approval behavior, the name requirement, pending, admit and confirm, decline, and removal. Reloads stay refused, and forged or forgotten passes become new requests. Approval can be switched both ways.
  - Bounds: 16 pending requests and 128 passes, with only stale sessions evicted.
  - Operator rows use numbers rather than passes.
  - Real-socket gateway tests: pending pages get no playback details; readers are distinct and refused until MediaMTX confirms them; removal revokes one session only; client IDs are not identity; a new link forgets admissions; long names, markup, and invalid colors are sanitized.
  - Presence math: an idle pointer expires despite repeated coordinates and jitter, slow movement counts, invalid or stale or unknown updates are dropped, a revision reset clears positions, and rate and participant limits hold. Duplicate names and colors stay separate. Palette contrast is checked.
  - WebSocket framing against RFC 6455, including refusal of unmasked, fragmented, binary, invalid UTF-8, and oversized frames.
  - Presence over a real WebSocket: participants see others but not themselves, and the native observer gets the same pointers. Invalid moves are not shared. Revision, Hold, and removal clear pointers. Idle expiry needs no hide. Cross-origin pages, unauthenticated or unnamed hellos, oversized frames, flooding, and a new link are refused or closed. A slow receiver gets only the newest state, and a stuck receiver is closed.
  - Native overlay: local expiry, release without a retained timer, pillarbox and portrait mapping, and floating zoom and pan. A rendering test proves the arrow tip stays on the point when its label flips; it fails on the earlier layout.
- **Viewer-controller checks** cover the join form, waiting with no `config.json` and no reader, admission starting playback with the pass header, removal through a heartbeat ending playback and polling, reloaded refusals, an unknown pass rejoining, and pointing being offered only while admitted and live.
- **Pointer-controller checks** run the shipped `pointers.js` with a fake channel. They cover contain-rectangle and full-screen mapping, the host option and name gate, the hello contents, coalescing with no resend of an unchanged position, hiding over the letterbox and on leave, taps, sharing off, labels rendered as text, invalid items ignored, local expiry without messages, clearing on a dropped channel, Hold, revision, and pointers off, reconnect backoff, a refusal stopping retries, and a locked admitted name.
- **New `SetbeamProbe --access-test`** (in `check.sh`) uses real bundled MediaMTX and FFmpeg. Without approval, the link's credential reads the audience output. With approval, it is refused over RTSP and WHEP (401), while two admitted readers can read and approval advances the publisher revision. Removing one reader ends its active FFmpeg session within 5 s and refuses reconnection, while the other reader and local monitoring continue. Hold keeps admitted access. Stop Sharing leaves no viewer credential usable.
- Before review the earlier MediaMTX spike confirmed the method: version 1.21.2 reports `user` per WebRTC session, deleting a user does not end its session, and kicking does. After the kick the browser's retries failed authorization, and the other reader kept playing.
- **Earlier full runs:** one hit the known format-cadence assertion (largest interval 50.067 ms at 30 fps, as recorded for builds 17, 20, and 21); the isolated format, frame-rate, and keyframe probes then passed. One access-probe run timed out because the probe's own 3 s WHEP request was shorter than MediaMTX's delay after a failed login. The probe now allows 10 s and then passed three times in a row.
- **Intermittent existing failure:** one full run stopped at `check-preview-bridge.py` line 98 on the live decode's first timestamps (`pts: 0`, then `-2722` with duration 11). In later standalone runs it failed 4 of 8 times with the worktree's helper and 3 of 8 with the parent's untouched helper. The preview bridge, its check, and its build script are unchanged from `225fd5e`, so this is an existing, environment-dependent failure.

## Native and browser verification

An isolated, ad-hoc signed build 22 QA copy ran under ignored `build/s008` with its own preferences suite (`app.setbeam.qa.s008`), session log, and state files. It used `--integration-demo`, the labeled sample, loopback viewing, and a saved viewer rate of 1 fps. Browser contexts were separate T3 preview tabs in the incognito profile, each with its own tab storage and pass. They are not separate devices. Native controls were driven through Accessibility. Zoom and pan used scroll and drag events posted at the QA floating panel, so no keystrokes reached another application. Captures are of Setbeam's own windows only. Capture One was frontmost throughout and was not touched. No production Setbeam was running.

- **Ordinary link, pointers on.** Two tabs played at once without approval. Both joined pointing as "Sam" (pink, green). The other tab showed "Sam · 1" at exactly 25%/40% of the picture. The native main monitor drew it at the matching point (0.50, 0.30), readable over the light picture, in dark and light appearance.
- **Idle fade.** After 5 s without movement the pointer was gone from the other browser and the native overlay.
- **1 fps video.** With decoded media times exactly 1 s apart, the other tab received 26 pointer updates per second: median gap 35 ms, p95 70 ms, max 72 ms.
- **Letterboxing and full screen.** In browser full screen at 700×900 the picture element was 676×778. The pointer layer matched the visible 676×380 picture, and the mark's tip landed at the expected pixel (181, 407). Moving onto page controls hid the pointer for others.
- **Floating preview zoom and pan.** At 205% zoom the arrow tip sat on the same detail (the eye) as in the main monitor. After panning, a detail out of view was clipped rather than pinned to an edge, and a visible detail (the hand) was pointed at correctly. The window did not move while panning.
- **Approval during sharing.** Turning it on gave both playing tabs their own readers (`viewer1x…`, `viewer2x…`). Both kept playing after reconnecting, and a page without a pass got 403. A new tab showed Ask to join. After entering a name it waited with 403 on `config.json`, and its own presence attempt was denied. The audience bar showed "1 asking to join", and the sheet showed Admit and Decline next to numbered admitted rows with pointing color dots. Admitting started playback with the name locked for pointing.
- **Remove.** Removing a tab that was pointing showed "Removed" with media detached and 403 on `config.json`. Its pointer disappeared for others. The other two tabs kept playing. Reloading stayed "Removed". Clearing that tab's storage made a new request (session 4) named `<b>Director</b>`, shown as literal text. Declining showed "Not admitted".
- **Hold, Resume, disconnect, Stop.** Hold showed On hold and cleared every pointer; moves during Hold were not shared, and local monitoring continued. Resume returned live playback, and pointing worked without rejoining. Closing a pointing tab removed its pointer for the other tab at once. Stop showed Sharing ended (old pass 404), hid the pointer control, cleared pointers, and left local monitoring running.
- **Exit.** Normal Quit removed the app and all six owned helpers (three supervisors, MediaMTX, FFmpeg, the preview bridge). Quit while sharing showed the existing confirmation; Quit and End Sharing exited with every helper removed. No session log line contained a viewer name, pass, reader, color, or coordinate.
- **Fixed during QA.**
  - A flipped label moved the native arrow by the label's width. Fixed, with the rendering regression test above; then confirmed at (0.889, 0.886).
  - Native pointers faded in on appearance. They now appear at once and fade only when removed.
  - The page's pointer control stayed visible after Stop. It now closes with Stop, removal, or refusal; a regression check was added.
  - The popover's "Asking to join" row had low contrast.
  - The popover squeezed the outgoing thumbnail when rows appeared while it was open. It now grows instead.
  - Admit, Decline, and Remove buttons lacked spoken labels. They now read, for example, "Admit Ana (client), session 1", confirmed through the AX API.

## Review

Two independent GPT-6.1 Sol reviewers (Codex `gpt-6.1-sol`, reasoning effort high, service tier default) reviewed `git diff 225fd5e` in three rounds. A emphasized auth, presence, lifecycle, and privacy; B emphasized mapping, rendering, UX, and native/browser integration. Round 1: both CHANGES. Round 2: both CHANGES on one remaining path. Round 3: both APPROVE.

| ID | Severity | Finding | Outcome |
| --- | --- | --- | --- |
| A1 | blocker | Enabling approval with no admitted readers did not retry after a failed MediaMTX update, leaving the shared credential usable. | Fixed: the app tracks the applied approval and retries until MediaMTX accepts it. |
| A2, B1 | blocker | A late snapshot after Hold or a newer revision restored old pointers. In round 2, a delayed `welcome` could still lower the revision. | Fixed in both places, with two regression checks. |
| A3, B2 | blocker / should | Turning off Share my pointer could still send a queued move. | Fixed: the queued move is cleared and hide sent first; flushes check sharing. Regression check. |
| A4 | should | A session admitted without a name before approval could not point. | Fixed: it may set its first label once, which then stays fixed. Ledger, channel, and viewer tests. |
| A5, B3 | should | A pointer revived during its fade still disappeared. | Fixed: revival cancels the pending removal. Regression check. |
| B4 | should | The native overlay missed a tap in place because it compared remaining time. | Fixed: it compares absolute expiry. Regression test. |

No finding was declined. Diff against `225fd5e`: 35 files, +2,831/−97 before review; 35 files, +2,939/−97 after (code commit `c5e5ea6`).

## Package

- `dist/s008/Setbeam-0.2.0-build22-macOS-arm64.zip`, SHA256 `038b4d185dd7f90536496e23853b1286956255d6e3c480a5558a16c9cc09574b`, built from `c5e5ea6`. Ad-hoc signed and not notarized; Apple Silicon, macOS 14 or later.
- Executable SHA256 `654e3084501eacc90611457fb7a75dc791d0b1b3e0551ba3f73d2b3b1c0e4460`.
- The archive includes `BUILD-NOTES.md`, `APP-SHA256.txt` (37 app files), and `SOURCE-MANIFEST.txt` (131 build inputs).
- Strict recursive signatures pass. All six executables are arm64 and link only system libraries. All seven viewer resources, including `pointers.js`, match the sources, and fixtures and notices are bundled.
- ZIP integrity passes. The extracted app passes strict signatures and all 37 file hashes.
- **Packaged smoke test.** The extracted app ran with approval and pointers on. A browser tab asked to join and was admitted from the native sheet. Its purple "Ana" pointer appeared on the matching detail in the main monitor. Quit with sharing active showed the confirmation; Quit and End Sharing left no processes.
- **Installed** in `~/Applications/Setbeam.app`, replacing the idle build 21 (its archive stays in the parent `dist`). All 37 installed files match.
- **Delivered** to Austin Deliveries / Setbeam / Build 22 shared pointers (archive, checksum, and seven QA screenshots): https://drive.google.com/drive/folders/1ZnqURu2POxoIE7ocPWVcer5UeK9mfMOL

## Limits and checks not run

- Contexts were browser tabs on one Mac, not simultaneous laptops, phones, or tablets, and not a capacity test. Touch pointing (tap to point, no scrolling on the picture only while sharing) is covered by controller checks, not physical touch.
- Native video full screen on phones and video picture in picture show only the video, so page pointers do not appear there. That is feature behavior, not a tested phone result.
- Different viewers can be on different frames of moving footage. Pointers are positions on the picture, not frame-synchronized annotations.
- No real non-16:9 source ran through native QA. Native letterbox and pillarbox mapping is covered by unit tests. The browser's letterboxed full screen ran for real.
- The operator does not point, and browser viewers have no zoom; neither was requested. No session password, friendly hostname, presenter highlight, or drawing was added.
- If the popover grows while open, its bottom edge can cover the sharing status text until it is reopened.
- No physical hardware compatibility claim is made. Everything ran locally with hosted CI disabled.

## Prerequisite stories

- **S-002 Request access with a viewer name — partial.** Done: an approval session asks for a bounded plain-text name and shows waiting, admitted, declined, and removed states. Ordinary links keep optional names. Duplicate names stay separate by session number and are not verified. Names are not in links and are shown to other viewers only as shared-pointer labels. Not done: no separate join page design or physical device checks.
- **S-003 Approve or remove an individual viewer — partial, enforcement complete.** Done: approval is an explicit option with distinct pending and admitted actions, and bypassing the join page yields no playback, credential, or presence. Removal ends that session's media and authorization and survives reloads, with per-viewer authorization verified against real media sessions, and other viewers, local monitoring, Hold, and Stop are preserved. Not done: physical multi-device checks.
- **S-005 Inspect a viewer's basic session details — partial.** Rows add admission state, pointing state, and color to the existing name, number, and health. Joined time, last update, and technical measurements are not shown.
