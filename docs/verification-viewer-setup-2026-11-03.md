# Viewer identity, pointer view, transmitter setup, and permissions verification, 2026-11-03

Version 0.2.0, build 25. Starting commit `df085a5`. Claude Opus 5.5 implemented the change on high. GPT-6.1 Sol approved it in one review round with no findings (see [Review](#review)). After approval only the build number changed. Preexisting uncommitted notes (`docs/plan.md`, `docs/status.md`, `docs/STORIES.md`, `docs/research/transmitter-expansion-2026-10-29.md`) were kept. This change only adds its own section to `docs/status.md`.

All QA ran on this Mac with an isolated copy of the candidate (`build/viewer-setup/qa`): its own preferences suite `app.setbeam.qa.viewersetup`, session log, loopback viewing (`lo0`), a fixture-only window list, and the labeled sample or a simulated loopback Pyro H stream. No phone, tablet, second computer, or physical transmitter was used.

## What changed

1. **One viewer identity.** A new browser tab first chooses a name and one of twelve colors on the join card, with approval off ("Join this feed", Join) or on ("Ask to join"). That identity is sent with `join` and every heartbeat. It labels the operator's viewer row (name plus a color dot) and the viewer's shared pointer. Connection help shows "You appear as Sam" with the color and a Change name or color button that reopens the same card as an editor (Save, Cancel, Escape). The pointer panel has no name or color fields; pointing without a name opens the card. The name inputs in Connection help and the pointer panel are gone.
   - Under approval, a request still goes out only from Ask to join. Reloads, restored passes, declined, removed, lapsed, busy, and retired-link states behave as before. The name is read-only after asking ("Change color" only). The gateway now accepts a color in heartbeats, under approval too; it still never changes a fixed name.
   - A tab restored with a pass resumes without the card. A saved identity with approval off joins at once.
   - Behavior change: turning approval off while the Ask to join form is open no longer plays without a name. The card switches to Join and plays after the viewer presses it.
   - The hint names everyone who sees the name: "Shown to the operator." With pointers on it adds "and to other viewers when you point." Under approval it adds "It stays fixed after you ask." Every variant ends "Names are not verified."
   - Palette: red, orange, yellow, lime, green, teal, cyan, blue, indigo, purple, pink, brown. The first six enum cases keep their order, so fallback colors for sessions 1-6 are unchanged. Every name label is at least 4.5:1 against its fill (unit test).
   - Storage: `sessionStorage` per tab, using the existing `setbeam-viewer-name` and `setbeam-pointer-color` keys.
2. **Show pointers on this Mac.** A new operator toggle in the sharing popover, nested under "Viewers can point" (formerly "Shared pointers"), and a Feed menu item, Show Viewer Pointers on This Mac. It is off by default, never saved, resets when sharing stops, and is disabled while viewers can't point. Main and floating monitors draw pointers only when it is on. The viewer permission, the presence channel, viewers' own "Show others' pointers" opt-in, and the no-encoded-overlay rule are unchanged. Native overlays still use no extra receiver.
3. **Bare `setbeam.local`.** Diagnosis below. Setbeam does not serve or redirect at the root. The Settings note, the invitation note, and the generic unavailable page now say that viewers need the whole link or QR code.
4. **Transmitter cards.** Choose a source > Wireless transmitters always shows two model cards: Accsoon CineView Master 4K and Hollyland Pyro H. They use drawn artwork, not product photos. Each card's status reads "Join its Wi-Fi to connect", "Found on this Wi-Fi", "Stream found", or "Current source". A card opens that model's guide inside the same sheet, so discovery keeps running. The guide has numbered steps, the found units with a connect row, and the model's evidence line from `hardware-tests.md`: "Tested in Setbeam over direct Wi-Fi, firmware 3.30" or "Not yet tested with a physical Pyro H". Set up a SEE stream bridge moved out of Advanced into the CineView guide as "Connect through Accsoon SEE ... Not tested with hardware." Network stream addresses stay in Advanced, which the footer button opens at Connection while a guide is shown.
5. **Permissions.** A new sheet appears once on first run, only when there is no working setup, and is reopened from Feed > Permissions… and the settings menu. The operator chooses what they'll use: screen or app window, camera or capture device, wireless transmitter, sharing. Each kind of access shows Allowed, Not allowed, Not asked yet, Not allowed yet (Screen Recording, which can't report a refusal), Asked when first needed (Local Network), Off, or Not needed. Allow… is a button press and uses the calls Setbeam already makes when a source starts: `CGRequestScreenCaptureAccess` and `AVCaptureDevice.requestAccess`. Local Network's Allow… runs the chooser's own discovery for four seconds. Location is never requested here; it is described as optional and only for transmitter Wi-Fi rejoin. Open Settings links go to the matching Privacy & Security pane. Later closes without asking for anything. The choices are saved in preferences.

## Bare `setbeam.local` diagnosis

The local address only replaces the host. A working link is `http://setbeam.local:<port>/s/<64-character code>/`.

- Typing `setbeam.local` makes the browser open `http://setbeam.local/`, which is port 80. Nothing listens there, so the result is the browser's own connection error. Some mobile browsers treat a bare word ending in `.local` as a search instead.
- The gateway listens on an ephemeral port chosen when sharing starts, on the selected viewing address only. `setbeam.local:<port>/` reaches the gateway, but any path without the current code gets the generic unavailable page.
- Port 80 on this Mac (macOS 27.0, 26A425), tested from an unprivileged process: binding `0.0.0.0:80` and `0.0.0.0:443` succeeded. Binding port 80 or 443 on `127.0.0.1`, `192.168.1.238`, or `192.168.1.234` failed with `[Errno 13] Permission denied`. Serving on port 80 would therefore need a wildcard listener on every interface. That breaks the "listens only on the selected address" rule, and another app may already hold the port.
- Even with port 80, a root page has to send viewers to the coded link, which publishes the code to anyone who types the name, or drop the code. Both are excluded by this request.

Feasible UX, for a decision by Austin (not implemented):

- **Recommended: an opt-in short address that requires Ask before viewers join.** While approval is on, a wildcard port-80 listener answers only connections whose local address is the viewing address and redirects `/` to the current link. The link alone then cannot play media, because each session needs its own admitted reader. Every request still waits for Admit, so the code stops being the gate. The settings copy would have to say "Anyone on this network who opens setbeam.local can ask to join." This also needs a clear fallback for when port 80 is taken.
- **Alternative: a short typed join code** on the gateway page, which would need its own rate limits and expiry, a new authentication design.
- **Current answer:** share the QR code or the copied link. The IP address link remains the fallback. The 64-character code still makes hand typing impractical.

## Automated checks

Final `scripts/check.sh` passed: 194 Swift tests, 43 viewer checks, 12 pointer checks, and 52 probe PASS lines. Details are in [Full check](#full-check).

- **Swift.** 5 new tests (194 total, from 189):
  - `PermissionsTests` (3): each choice needs only its own access, with Location only for transmitters. Reported statuses map to distinct states. Permissions opens on first run, then not after it was shown, and remembers the choices.
  - `PointerVisibilityTests` (1): letting viewers point doesn't draw pointers on the Mac. The view choice is never saved. Hold and turning pointing off hide pointers.
  - `ViewerAccessTests.testHeartbeatsChangeColorButNotAFixedNameUnderApproval`.
  - `PointerPresenceTests` palette test extended: 12 colors, fallback order for sessions 1-6 unchanged, contrast of every label.
- **Viewer controller** (`check-viewer-recovery.js`): 43 checks (42 before). Two tests were rewritten for the new rules: "turning approval off while the form is open keeps the card and joins only when the viewer does" and "with approval off a saved identity plays at once, and Change name or color edits it in place" (Save, Cancel, Escape, no new join request). Two were added: "a new tab chooses one name and color before it plays, with approval off" (nothing sent before the choice, a cleaned 40-character name, color and storage, heartbeat identity, reload without the card) and "an empty name is not sent, and shared pointers are named in the hint". "viewer names are optional…" was replaced by those two. The Connection help Escape test and the approval read-only test now use the identity editor. The approval read-only test now also proves a color change keeps the fixed name. The harness gained `createElement`, a palette, and a default saved identity, so older playback tests describe a tab that already chose one.
- **Pointer controller** (`check-viewer-pointers.js`): 12 checks. Two were rewritten: pointing without a name opens the join card and announces the viewer's own color, and the panel has no name or color fields while a changed identity reconnects with the new hello. The palette has 12 colors.
- No probe changed. The access and local-address probes already send names with `ask`.

## Native QA (isolated copy, Accessibility-driven)

Native captures are of Setbeam's own windows only, in `build/viewer-setup/qa/shots/`. Chooser captures were cropped to remove the live display thumbnail. The window list was limited to a nonexistent fixture bundle. Two earlier captures that showed real desktop and window titles were deleted.

- **Permissions** (`native-dark-permissions-first-run`, `-access`, `-chosen`, `native-light-permissions-first-run`, `-access`). It appeared on a fresh suite at launch, and Later closed it without any system prompt. Statuses on this Mac read without prompting: Screen Recording Allowed, Camera Not asked yet, Microphone Allowed, Location Off. Unchosen rows read Not needed. Choices were restored on reopen. No Allow… button was pressed, so no macOS permission dialog was shown and no grant changed.
- **Chooser cards** (`native-dark-chooser-transmitters`, `native-light-chooser-transmitters`): both cards are always present.
- **CineView guide** (`native-dark-guide-cineview`, `native-light-guide-cineview`): with no transmitter, it shows "Looking for a CineView Master 4K…". Connect through Accsoon SEE started the existing incoming route and opened its setup sheet (`native-light-see-bridge`, source kind `incoming`). No picture was sent to it.
- **Pyro H guide**:
  - On the home Wi-Fi, it shows the not-found note (`native-dark-guide-pyroh`).
  - With a simulated loopback Pyro H endpoint (bundled MediaMTX on `127.0.0.1:18554/live`, the labeled `Demo.mp4` H.264/AAC through bundled FFmpeg, and the existing `--pyro-h-fixture-port` QA flag), the card read Stream found and the guide listed "Pyro H test stream" (`native-dark-guide-pyroh-found`, `native-light-guide-pyroh-found`).
  - Connecting gave monitoring, a fresh source with audio, and native playback (`native-dark-pyroh-monitoring`). Reopening the chooser showed Current source without probing (`native-dark-guide-pyroh-current`).
- **Pointers on this Mac.** With a browser pointing, the experience file read `nativePointers: 1, pointersOnThisMac: false, nativePointersShown: 0`. After the toggle: `true, 1`. The main monitor (`native-dark-pointers-on-this-mac`) and floating preview (`native-dark-floating-pointers`) drew the teal "Sam" pointer. Hold gave 0 shown and Resume gave 1. Stop Sharing reset `pointersOnThisMac` to false, kept `sharedPointers` true, and kept local monitoring playing. Popovers: `native-dark-sharing-popover-pointers`, `native-light-sharing-popover`.
- **Viewer rows** (`native-dark-viewer-row`, `-after-edit`, `native-dark-pending-ana`, `native-dark-approval-rows`, `native-light-viewer-rows`) showed the chosen name and color dot. The row copy shown in `native-dark-viewer-row` predates its final wording.
- **Quit.** Normal Quit after Stop removed the QA app and all 11 owned descendants (`owned-before-quit.txt`). The fixture's MediaMTX and FFmpeg were stopped by PID.

## Browser QA

**T3 preview tabs** drove the real flow against the isolated copy. A loopback redirect page opened the link.

- Approval off: a new tab showed Join this feed with focus in the name field and no picture. Teal and "Sam" played 1280×720, advancing 2.02 s in 2 s. Storage held `Sam`/`teal`. Connection help read "You appear as Sam".
- Pointing: Start pointing reported "Pointing as Sam. Move over the picture or tap it."
- Edit: Change name or color opened "Your name and color" with focus in the field and the badge still Live feed. Saving "Sam (Director)" in brown returned focus to Help, then updated the operator row and the native pointer's label and color (`native-dark-pointer-after-edit`).
- Approval on, second tab: Ask to join with the fixed-name hint. Only Ask to join sent a request (`{"name":"Ana","ask":true,"color":"indigo"}`), and later joins carried only the pass and color. Waiting read "Asking as Ana (session 2)". Admit played, advancing 2 s in 2 s.
- Approval on, after admission: Connection help offered Change color, and the editor's name field was read-only. Submitting "Director" in pink kept "Ana" and stored pink. A reload kept the session with no new row. Remove showed Removed, detached the stream, and hid the edit button.
- Stop: the first tab showed Sharing ended and hid the pointer and edit controls.

**Headless Chrome on this Mac** took the browser screenshots, because T3 `preview_snapshot` timed out ("Preview automation snapshot timed out after 15000ms."), as in the S-002 and S-006 notes. Reduced motion was emulated. Results are in `shots-results.json` and `shots.log`.

- Desktop 1280×800: `browser-desktop-ask` (approval), `browser-desktop-join` (approval off), `browser-desktop-playing`, `browser-desktop-help-identity`, `browser-desktop-edit`, `browser-desktop-pointer-panel`.
- Phone 390×844 touch: `browser-phone-ask`, with nothing focused so the keyboard doesn't open by itself, and `browser-phone-pending` ("Asking as Kai (session 1)").
- Phone 375×667: `browser-phone-join`.
- No viewport scrolled horizontally. The ask card's accessibility tree has heading "Ask to join", textbox "Your name", group "Your color" with twelve named radio buttons, and button "Ask to join".
- The viewer page is dark only, so no light browser captures exist.
- The first `browser-desktop-help-identity` showed the shortcut line touching the Change button. A 14 px gap was added after that capture. Build 25 captures confirm it (see [Build 25 screenshots](#build-25-screenshots)).

## Tool notes and incidents

- The T3 preview tool echoed the QA tab's URL, including that loopback session's private code. The session was loopback-only, and Stop expired the code.
- A relaunch of a rebuilt QA copy blocked its main thread on `SecItemCopyMatching`. The QA suite had saved the simulated Pyro H setup, and macOS asked the new ad-hoc-signed binary for Keychain access. No prompt was answered. That QA process was ended by PID. The QA-only Keychain item (`app.setbeam.credentials`, `source-ED37472F-…`, created 17:07 today, holding only the loopback test address) and the QA suite's saved setup were deleted. This is existing restore behavior with changing ad-hoc signatures, not part of this change.
- During that incident, an extra QA instance launched before the first had exited. Neither had child processes. Both were ended by PID.
- Escape was sent through System Events three times to close the QA app's own popover while it was frontmost.

## Not covered

- Physical phone, tablet, or second computer; real on-screen keyboards; VoiceOver.
- `.local` resolution from other devices.
- Physical CineView or Pyro H through the new guides. The Pyro H result is a loopback simulation and is not compatibility evidence.
- The real Accsoon SEE push.
- Pressing Allow… for Screen Recording, Camera, Microphone, or Local Network, and the resulting macOS dialogs.
- First run on a Mac that has never granted Setbeam anything.
- Launching the installed build 25 with Austin's own saved setup. It has a new ad-hoc signature. If that setup keeps a stream address, CineView key, or Wi-Fi password in Keychain, macOS may ask for Keychain access on first launch, as it did for the rebuilt QA copy.

## Full check

The final `scripts/check.sh` passed on its first run, with QA apps and the fixture stopped (exit 0, 10 min 25 s):

- 194 Swift tests, 0 failures: 139 core and 55 app (189 before, 5 new).
- 43 viewer and 12 pointer checks, 0 failures.
- 52 probe PASS lines, the same set as build 24: preview bridge, Pyro H simulation, media, recovery, access, local address, source switching, formats, frame rates, and keyframes.

Log: `build/viewer-setup/check-run1.log`, with `check-run1-logs/`. `git diff --check` passes. No probe or preview-bridge intermittent failure occurred this time.

Pre-review rebuild, still numbered 24 (`scripts/build-app.sh`, `build/viewer-setup/build-app-final.log`):

- The strict recursive signature check passes, and no helper links a Homebrew path.
- Executable SHA-256: `9083bf28f0bc4ebb9747335550328017727b60d8255e23cf5864bf86081ecd34`.
- The 14 px gap rule is present in the bundled `viewer.css`. "Stream found" is in the compiled source.

The full check was not repeated for build 25. Only `CFBundleVersion` changed, and the unsigned executable is byte-identical to this rebuild's (below).

## Review

- One sol-loop round. Reviewer: GPT-6.1 Sol, provider codex, reasoning effort high, default service tier. Verdict: APPROVE, with no blocker, should, or nit findings. Usage was not reported.
- The reviewer independently passed 43 viewer checks, 12 pointer checks, and 22 focused Swift tests, and edited no files.
- Review scope: baseline `df085a58f13d4bc556797d530c19244261886ed9`, 24 files, +875/−208, including the four untracked source and test files. Patch: `/tmp/setbeam-20261103-baseline/review-r1.patch`, SHA-256 `0483251d35f054e0271b0848a4ce50fef1b89b4addc02c792f4e9e5b40e88073`. Preexisting notes and this verification note were outside the scope.
- After approval, the same scope regenerated from the checkout is byte-identical to that patch. The only later code change is `CFBundleVersion` 24 → 25 in `scripts/build-app.sh` (+1/−1). Code diff: before 24 files, +875/−208; after 25 files, +876/−209.

## Build 25

`scripts/build-app.sh` built 0.2.0 build 25 into a fresh `build/Setbeam.app`. The build 24 output was first moved to `build/viewer-setup/build25/pre-build25-Setbeam.app`. Log: `build/viewer-setup/build25/build-app.log`.

- 37 files. Strict recursive signature checks pass for the app and each helper. All six executables are arm64 and link only `/usr/lib` and `/System/Library`. No `/opt/homebrew` or `/usr/local/opt|Cellar` path appears in any bundle file.
- Against the build 24 rebuild, only `Contents/Info.plist` and the signed `Contents/MacOS/Setbeam` differ. With signatures removed, both executables hash to `71af9ec53ba92a39f68c4db3c2a041ae1ba68de80c8a7d9b2cbf2d001721e8d3`.
- Executable SHA-256: `6c573a81a28797d203557fd11dacc8fd409ba874252e867d73f8e343d903ceac`. `Info.plist`: `1246a1e54de94030e26aa78b427377b76b1d7b46fa6c181087f1ba01cffddf15`. `CodeResources`: `6b2225a451f41988ba774ab079f9f653a9d35e43d5b906cfdf99958d4d08e79a`. Bundled `viewer.css`: `d8aa31795a8d4977b953ad85fc61def3ad9a18fd1476d2e2f744eec9aade242e`.
- All seven bundled viewer assets match `Sources/SetbeamApp/Resources`.

### Archive

- `dist/Setbeam-0.2.0-build25.zip`, SHA-256 `89ea54ca5a23ac206f5838aa69217aa5a3fc6424a661f2b89dc6da9fad82a212` (also in `dist/Setbeam-0.2.0-build25.zip.sha256`).
- Contents: `Setbeam.app`, `BUILD-NOTES.md`, `APP-SHA256.txt` (37 app files), and `SOURCE-MANIFEST.txt` (134 inputs). It includes no QA sessions, preferences, links, logs, or runtime directories.
- `unzip -t` reports no errors. The extracted app matches `build/Setbeam.app` and the installed app under `diff -r`. All 37 `APP-SHA256.txt` lines verify against the extracted and installed apps. Strict signatures pass on the extracted app. Info: 0.2.0, build 25, `app.setbeam.mac`. Helpers: `ffmpeg`, `ffprobe`, `mediamtx`, `setbeam-preview`, `setbeam-supervisor`.
- Source manifest SHA-256: `e4af0b0e82abcfdca2d565afb3d577c4bc562a038b9428eb44abeccf1e016d88`. It is also saved at `build/viewer-setup/build25/SOURCE-MANIFEST.txt`, and all 134 lines verify against this checkout. It covers non-ignored `Sources`, `Tests`, `scripts`, `Fixtures`, `Package.swift`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `runtime-lock.json`. Against build 24's list, it adds the four new source and test files and drops four ignored `scripts/__pycache__` files. `APP-SHA256.txt` SHA-256: `20105be86e21352893a6f519eb7ade3f39009891bb74e5976d9159e816d15b91`.

### Installation

- `~/Applications/Setbeam.app` held build 24, and no Setbeam process was running. It was moved to `~/Applications/.Setbeam-before-viewer-setup-build25.app`, and build 25 was copied in with `ditto`.
- The installed app matches the build and archive (37 files, `diff -r`). Strict recursive signatures pass. The installed app was not launched against Austin's saved source or settings.

### Packaged runtime checks

The release `SetbeamProbe` ran against the installed app's own `Contents/Helpers` and `Contents/Resources/Fixtures`:

- `--access-test`: all 7 PASS in 43 s (`build/viewer-setup/build25/packaged-access.log`).
- `--local-address-test`: all 10 PASS in 26 s (`build/viewer-setup/build25/packaged-local-address.log`).
- Afterwards no process from the installed bundle was running.

## Build 25 screenshots

The isolated QA copy was replaced with build 25 (`diff -r` identical). The QA suite's saved setup is the sample feed, which never reads Keychain. Both launches answered Accessibility immediately and produced no new prompt. The simulated Pyro H was again bundled MediaMTX on `127.0.0.1:18554/live`, carrying the labeled `Demo.mp4` through bundled FFmpeg, with a fresh fixture password. Each process ran in its own process group (`build/viewer-setup/build25/fixture.py`).

- Native, in `build/viewer-setup/qa/shots/`:
  - `native-dark-chooser-pyroh-found` and `native-light-chooser-pyroh-found`: the Pyro H card reads "Stream found" with a check mark, and CineView reads "Join its Wi-Fi to connect". These are cropped below the display thumbnail.
  - `native-dark-guide-pyroh-found` and `native-light-guide-pyroh-found` replace the earlier guide captures. They list "Pyro H test stream", and step 1 now reads "HDMI input". Nothing was connected, so no source setup or Keychain item was saved.
- Browser, sample feed shared on loopback with approval off:
  - T3 preview went first. A new tab opened the loopback redirect page, joined as teal "Sam", and played 1280×720 (4.38 s after 4 s). Its DOM measured a 14 px gap between Change name or color and the shortcut line. `preview_snapshot` with `save: true` failed three times with "Preview snapshot failed: Preview automation snapshot timed out after 15000ms." T3 also echoed the session URL with its private code again. The session was loopback-only, and Stop expired it (the old link then returned 404).
  - Fallback, headless Chrome (`build/viewer-setup/build25/tools/help-shots.js`, results in `help-shots-results.json` and `help-shots.log`):
    - `browser-desktop-help-identity` (1280×800) replaces the earlier capture: orange "Lee", a 14 px gap, no horizontal overflow.
    - `browser-phone-help-identity` (390×844 touch) and `browser-phone-help-identity-scrolled`: lime "Kai", a 14 px gap. On the phone, the help panel fills its existing `max-height: calc(100% - 75px)` and scrolls (299 px of content in 227 px). Scrolled to the end, it shows Change name or color, the shortcuts, and the full-screen hint. The panel rule is unchanged from build 24.
- The Copy Viewing Link menu command was used to read the QA link. Austin's clipboard held one plain-text item, which was saved to a mode-600 temp file, restored, and confirmed by hash and type. The temp file was deleted.
- One Escape key press was sent through System Events to close the QA app's popover before Stop. Which app was frontmost at that moment was not recorded.
- Cleanup: before each normal Quit, the QA app had 7 owned processes (`owned-before-quit-dark.txt`, `owned-before-quit-light.txt`), and none remained afterwards. The fixture's MediaMTX and FFmpeg, the redirect server, and headless Chrome were each stopped by their recorded process group. No listener remained on ports 18554, 18611, or 9345.

### Prompts left on screen

Two SecurityAgent windows were still on screen after QA. Neither was answered or touched.

- A Setbeam Keychain prompt for `app.setbeam.credentials` (Always Allow, Deny, Allow). Its window ID predates this round's first QA window. It is the prompt from the earlier QA relaunch incident above. No Setbeam process is alive to receive an answer, and that QA Keychain item was already deleted.
- A "diskutil wants to make changes" administrator prompt, unrelated to Setbeam. No `diskutil` process was running.

The parent attempted to inspect the stale Setbeam prompt through computer use. The tool refused with "Computer Use is not allowed to use the app 'com.apple.SecurityAgent' for safety reasons." No other tool was used to bypass that restriction. The prompt remains for Austin to dismiss with Deny. The unrelated administrator prompt was left untouched.

## Parent verification and delivery

Parent verification confirmed the archive SHA-256 and ZIP CRC, all 37 app files byte-identical across archive, fresh build and installation, strict recursive signatures, version 0.2.0 build 25, all 134 source-input hashes, and the byte-identical Sol-approved behavior patch. The original dirty planning, story, research and status content remains unchanged outside the inserted status section. Fresh native dark/light Pyro H screenshots and desktop/phone identity-help screenshots were inspected. Packaged logs report 7 access and 10 local-address PASS lines. `git diff --check` passes.

The Austin Deliveries helper returned `state: delivered` with remote verification at `2026-11-03T22:49:15.393374+00:00`. Delivery ID: `20261103T224902Z--da18391b746a`. Stable request: `setbeam-viewer-setup-build25`. Destination: Setbeam / Viewer setup. Delivered files are `Setbeam-0.2.0-build25.zip` and `Setbeam-0.2.0-build25.zip.sha256`.

[Private verified delivery](https://drive.google.com/drive/folders/1RfPXMQ_OjbNpA7YnqVM4HmLW5Ojtzult).

No behavior changed after approval. No commit, push, PR, or hosted workflow ran.
