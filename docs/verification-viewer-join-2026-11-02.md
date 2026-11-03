# S-002 viewer join page verification, 2026-11-02

Build 24, version 0.2.0. Starting commit `86cd04a`. Claude Opus 5.5 implemented the change on high. GPT-6.1 Sol approved the change on high after two review rounds; see the ledger and handoff evidence below. The accepted fix is recorded under [Round 1 fix](#round-1-fix-a-retired-link-under-the-join-form).

## UX decision

Under viewer approval, a browser session that is not admitted gets its own join page in place of the picture and control bar. Admitted viewers keep the picture-first page unchanged. The join form used to sit inside the picture slate, centered in a 16:9 box that shrank on phones. It also sent a request on its own whenever the tab had a saved name.

- Flow: open the link -> the session title and an Ask to join card appear -> type or review the name -> Ask to join (Return or tap) -> Waiting for the operator -> Admit starts the picture, Decline or Remove shows the decision -> reload keeps the state.
- Surface: one card in the page body, top-aligned so a phone keyboard does not cover the field. It reuses the viewer's existing colors, type, 44 px controls, and the slate background. Light mode is not offered because the viewer page is dark only.
- States, each with the header badge text and the card title:
  - Ask to join: "Ask to join".
  - Waiting: "Waiting to join", "Waiting for the operator", with "Asking as Sam (session 4)".
  - Declined: "Not admitted", "The operator declined this request".
  - Removed: "Removed", "The operator removed you from this session".
  - Busy: "Session busy", "This session is busy", with Try again.
  - Link gone: "Session unavailable", "This viewing link is no longer active", with Try again.
  - Ended: "Sharing ended".
  - Messages: sending, offline, request failed, connection lost while waiting, a lapsed request that needs to ask again, and an empty name.
- Words: "Ask to join", "Your name", "Only the operator sees this name. Names are not verified.", "Keep this page open. The picture starts when the operator admits you." The session number matches the operator's row, so two people both named Sam can tell the operator which one they are.
- Access: label and hint are tied to the field (`aria-describedby`). Messages use a `role="status"` region. The header badge stays the page's live status. Focus moves only when the step changes. On a fine pointer the name field takes focus on first display. On touch nothing takes focus until the viewer taps, so the keyboard does not open over the explanation. After Ask to join, focus goes to the new heading. After Admit it goes to the session title. Polls never move focus or rewrite a name the viewer is typing. Reduced motion stops the waiting spinner, and increased contrast brightens secondary text.

## Changed behavior

- **A saved name never asks on its own.** The gateway creates a new request under approval only with a name and `ask: true`. The page sends `ask` only from Ask to join or Try again. A saved name pre-fills the form. A restored pass resumes its pending, admitted, declined, or removed state with no new request. Before this change, a tab with a saved name and no pass sent a request as soon as it loaded.
- **A lapsed request does not silently come back.** If a pending request expires while the page is offline, or the gateway no longer knows the pass, the page returns to Ask to join with the name kept and says it needs to ask again.
- **Failures wait for the viewer.** A request that fails to send shows a message in the form and is not resent automatically. Busy under approval waits for Try again. Busy with approval off still retries by itself, as before.
- **A retired link replaces the form.** If Stop or a new code retires the link while Ask to join is open, the page shows "This viewing link is no longer active" on the next poll. Try again checks the link again and stays on that card, sending no request. Before the round 1 fix, the page ignored the `state.json` 404 and kept the form open.
- **Approval toggles while the page is open.** The join page polls `state.json`, so it shows the session title and leaves the form when approval is turned off, joining with the optional name. Before this change, the form stayed on screen indefinitely after approval was turned off.
- **Connection help names under approval.** Once a session has a name under approval, the field is read-only and says names stay fixed. A session admitted unnamed before approval can set its first label through Connection help. The gateway now accepts that first label in heartbeats, which matches the existing pointer rule. Before this change, Save appeared to work but the gateway ignored it.
- **Approval off is unchanged.** No join page, optional names, Connection help editing, and immediate playback.

Unchanged: MediaMTX users and WHEP, `config.json` authorization, pending and refused sessions receiving no playback details, per-viewer readers and removal, Hold, Stop, the presence channel, link and host handling, and native UI. No dependency was added.

## Automated checks

- **Swift.** `ViewerAccessTests` adds three ledger cases: a saved name without ask and an ask without a name are both refused with no operator row; a reload resumes the same request and a lapsed one needs a new ask; and an unnamed session admitted before approval can set one first label through heartbeats. `ViewerAdmissionGatewayTests` adds an HTTP test. A name without ask gets 400 with no row. Ask creates numbered pending requests, and equal names stay separate. `state.json` contains no viewer name. A pending pass gets 403 from `config.json`. Turning approval off admits a waiting page, and ordinary links need neither name nor ask. Existing approval tests, `PresenceChannelTests`, and the local-address probe now send `ask` with their names.
- **Viewer controller** (`scripts/check-viewer-recovery.js`, 42 checks, 11 new). Covered:
  - A saved name pre-fills but sends nothing over several polls; Ask sends one request with the name in the POST body only.
  - Reload of pending, declined, and removed tabs makes no new request and offers no way to ask again from a refusal.
  - Failed sends are reported and not repeated; lost connection while waiting shows reconnecting; a lapsed request asks again with the name kept.
  - Turning approval off while the form is open plays without a name; approval off never shows the join page and keeps Connection help editing.
  - Focus moves on step changes only, and touch does not open the keyboard by itself.
  - Busy waits for Try again, and a removed link shows the unavailable card without fetching `config.json`.
  - A link retired while the form is open shows the unavailable card, and Try again keeps it with no request. An Ask that meets a retired link shows the same card, and Try again sends no new request. Both added in the round 1 fix.
  - An admitted name under approval is read-only; Hold and recovery keep the picture page and send no request.
- **Pointer controller.** 12 checks, unchanged, pass.
- **Real-media access probe** (`--access-test`, 7 PASS lines, 3 new). A real `ViewerGateway` runs in front of the bundled MediaMTX, the way the app wires them.
  - A saved name gets 400. Two Ask requests named "Sam" become sessions 1 and 2. A waiting pass gets 403, and a resumed join keeps its number.
  - Admit gives session 1 its own reader, which reads RTSP and passes WHEP authorization. Decline keeps session 2 at 403 after a reload.
  - Remove makes session 1 get 403 again, its reader fails RTSP and gets WHEP 401, and another admitted reader keeps reading.
  - The first probe run reached WHEP 404 because it ran right after Resume, before the output came back. It now waits for live output. The access logic was not changed for this.
- **`scripts/check.sh`.** Run 1 stopped at the known intermittent assertion `scripts/check-preview-bridge.py` line 102, `assert all(0 < delta < 100_000 for delta in intervals)`. Four isolated bridge runs then passed twice and failed twice at line 98 (`assert all(right["duration"] == delta ...)`, first timestamps `pts 0` then `-311`, and `204689` then `200422`, each with duration 11). The S-008 note records the same failure. The preview bridge, its check, and its build script are unchanged from `86cd04a`.
  - Run 2 failed in `PresenceChannelTests.testHoldPublisherRevisionAndRemovalClearPointers` line 147, `XCTUnwrap failed: expected non-nil value of type "String"`. That test joined under approval with a name and no `ask`, which the gateway now correctly refuses. The test now sends `ask`, and all 189 Swift tests passed on their own.
  - Run 3 failed at "FAIL: Viewer approval was bypassed at the local address." The local-address probe joined the same way. It now sends `ask`, and its 10 checks passed on their own. Neither file ships in the app.
  - Run 4 passed in full: 189 Swift tests (138 core, 51 app; 186 before, 3 new), 40 viewer and 12 pointer checks, and all 52 probe PASS lines (49 before, 3 new).

After the round 1 fix, the first `scripts/check.sh` run passed in full, including the preview bridge: 189 Swift tests (138 core, 51 app), 42 viewer and 12 pointer checks, and 52 probe PASS lines. Log: `build/viewer-join/round2/check-run1.log` and `check-run1-logs/`.

Logs: `build/viewer-join/check-run{1,2,3,4}.log`, `check-run{1,2,3,4}-logs/`, `preview-bridge-isolated-{1..4}.log`, `swift-test-after-fix.log`, `logs/access-probe.log`, and `logs/local-address-after-fix.log`.

## Browser and native QA on this Mac

An isolated copy of the build 24 candidate ran from `build/viewer-join/qa`. It had its own preferences suite (`app.setbeam.qa.s002`), session log, labeled sample source, loopback viewing, and approval on. Native controls were driven through Accessibility with the earlier QA helper. Captures are of Setbeam's own windows. Every browser was on this Mac. No phone, tablet, or second computer was used.

**T3 preview tabs** drove the real flow and read state by page evaluation:

- New tab: Ask to join with focus in the field. "Sam" became pending as session 1, and no URL contained the name. The operator row read "Sam, Asking to join, Desktop browser · 1 · This Mac" with Admit and Decline.
- Admit: the 1280×720 sample advanced 2.01 s in 2 s, and focus moved to the title. Connection help showed the name read-only.
- Hold: On hold, with the stream detached and muted. Resume: 2.03 s in 2 s with no new request.
- Second tab, also "Sam": session 2. Its `config.json` was 403, and `state.json` had only approval, pointers, revision, title, state, sample, and wifiSSID. A reload stayed pending as session 2 with one request on the operator side.
- Decline: "Not admitted", "Asked as Sam (session 2)", and still declined with 403 after a reload.
- Remove session 1 from Viewer details: Removed, stream detached, 403.
- Third tab at Ask to join, then approval turned off: it played unnamed (1.98 s in 2 s). Saving "Lee's laptop" in Connection help showed on the operator row. The declined tab stayed declined.
- Stop: the playing page showed Sharing ended. Local monitoring continued (`shots/native-after-stop.png`).

**Headless Chrome on this Mac** (fallback, see tool failures) drove fresh tabs against a new QA session. Operator actions went through the same Accessibility helper. Reduced motion was emulated in every tab. Results are in `build/viewer-join/qa/shots-results.json` and `shots.log`.

- Desktop 1280×800: ask, pending, admitted playing (1280×720), Hold, Sharing ended after Stop.
- Phone 390×844 with touch: a saved name pre-filled for review with nothing focused. It asked as the second "Sam", was declined, and stayed declined after a reload.
- Large text, a 375 pt phone at 150 % (250 CSS px): ask with the button wrapped below the field, pending, admitted picture, removed. Another admitted viewer kept playing after the removal.
- Tablet 768×1024: offline send failure, connection lost while waiting, and after 33 s offline a lapsed request asking again with "Kai" kept.
- Busy: 16 real pending requests sent to the gateway, then a 17th Ask showed Session busy. After the 16 lapsed, Try again became pending.
- Phone landscape 844×390: ask.
- Stop while waiting: Sharing ended.
- No viewport scrolled horizontally. The accessibility tree for the ask card had heading "Ask to join", textbox "Your name", button "Ask to join", and two status regions.

Normal Quit removed the QA app and all six owned descendants within 6 s (`owned-before-quit.txt`).

Screenshots are in `build/viewer-join/qa/shots/`:

- Desktop: `desktop-1-ask`, `desktop-2-pending`, `desktop-3-admitted-playing`, `desktop-4-hold`, `desktop-5-busy`, `desktop-6-stopped-while-waiting`, `desktop-7-admitted-after-stop`.
- Phone: `phone-1-ask-prefilled`, `phone-2-pending-duplicate-name`, `phone-3-declined`, `phone-landscape-ask`.
- Large text: `phone-large-1-ask`, `phone-large-2-pending`, `phone-large-3-admitted`, `phone-large-4-removed`.
- Tablet: `tablet-1-request-failed`, `tablet-2-pending-reconnecting`, `tablet-3-ask-again`.
- Native: `native-pending-request`, `native-two-sams`, `native-approval-off-named`, `native-after-stop`.

**Tool failures and QA notes.**

- `preview_snapshot` failed three times with "Preview automation snapshot timed out after 15000ms.", including after revealing the tab. This matches the build 18 and S-006 notes. Page evaluation, typing, clicks, and key presses worked, so T3 carried the functional flow and headless Chrome took the screenshots.
- The T3 status output echoed the QA tab's URL, which contains that QA session's private code, even though the tab was opened through a loopback redirect. The session was loopback-only sample media, and Stop expired the code before the next session started.
- I sent one Escape through System Events to close a popover. The QA Setbeam window was frontmost at the time, so it reached only that window. No other keystrokes were sent outside the browser tabs.
- First headless attempts failed in the driver itself: Enter with nothing focused, rendering throttled in background tabs, and a Resume press sent during the Hold transition. The app ignores commands during a transition. The driver now taps, brings each tab to the front, and waits for Hold to finish. None needed a product change.
- Observed, existing: a Picture and viewers sheet left open while its rows changed showed "1 opened · 1 playing" with no row until it was reopened. Native views are unchanged in this story.

## Round 1 fix: a retired link under the join form

Sol round 1 (finding S1, should fix) reported that `viewer.js` ignored `state.json` failures while the join form was open. Under approval with no pending Ask, `join()` sends nothing, so the poll's `state.json` request was the only sign that Stop had retired the link. It returned 404, and the page kept offering Ask to join indefinitely. An Ask sent after that showed Session unavailable, and Try again led back to the same form, which could not work.

The fix is one line in the pre-admission branch of `poll()`: a `state.json` 404 sets `unavailable`, as a 404 from `join` or `config.json` already did. A comment there now also says the poll checks whether the link still works. No other product code changed. Diff against the reviewer's snapshot: `build/viewer-join/round2/viewer-since-round1.diff`.

**Tests first.** Two controller tests were added, and the browser fake gained a switch that makes `state.json` return 404:

- "a link retired while the form is open shows unavailable, and Try again sends no request".
- "Try again after an ask meets a retired link stays unavailable without a new request".

Against the round 1 controller, both failed where expected. Each got `'Ask to join'` where `'Session unavailable'` was expected: the first right after Stop, the second after Try again. Result: 42 tests, 40 pass, 2 fail (`round2/viewer-before-fix.log`). With the fix, 42 of 42 pass (`viewer-after-fix.log`), and the 12 pointer checks pass (`pointers.log`).

**T3 preview tabs** on the rebuilt QA copy. It was isolated as before: suite `app.setbeam.qa.s002`, loopback, labeled sample, and approval on. A wrapper around the page's `fetch` recorded each request. Notes: `build/viewer-join/round2/qa/t3-results.md`.

- Form open with "Sam" typed but not sent, then Stop: within 5 s the page showed Session unavailable and "This viewing link is no longer active", with the form hidden and Try again shown. `state.json` went from 200 to 404. No `join` or `config.json` request was sent.
- Try again: one more `state.json` 404, and the page stayed on the unavailable card. No `join` request.
- Ask after Stop. `state.json` failed inside the page so the poll could not report the link first, standing in for Ask pressed within one poll of Stop. The first attempt asked 1.5 s after Stop, and the gateway still accepted the old link (200, pending). The next join with the stored pass got 404 and showed unavailable, which is the existing pending path. The second attempt used a new tab and waited until `curl` to the old link returned 404. The Ask got 404 and showed Session unavailable. Try again sent one `state.json` request, got 404, sent no `join`, and stayed unavailable.

**Headless Chrome on this Mac** (fallback for screenshots) ran the same two transitions on another link. `regress.js` logged every `join`, `state.json`, and `config.json` request through the DevTools network events. Results are in `results.json` and `regress.log`.

- Desktop 1280×800 and phone 390×844 with touch, form open, then Stop: both showed the unavailable card. The desktop's only `join` was the first state check, a 400 with no name and no ask. Try again sent no `join`.
- Ask after Stop on a new link, after the old link's `join` returned 404: the Ask got 404, and the page showed the unavailable card. Try again sent no new Ask, and `state.json` returned 404.
- No `config.json` requests, and no horizontal scrolling. After each restart, the operator's popover button read "0 viewers playing" with no request listed.

Screenshots are in `build/viewer-join/round2/qa/shots/`:

- `r2-1-form-open-before-stop`
- `r2-2-stop-while-form-open`, `r2-2-phone-stop-while-form-open`
- `r2-3-try-again-stays-unavailable`
- `r2-4-ask-after-stop-unavailable`, `r2-5-ask-after-stop-try-again`

Normal Quit removed the QA app and its six owned descendants within 2.5 s (`round2/qa/owned-before-quit.txt`).

Tool notes:

- `preview_snapshot` failed once more with "Preview snapshot failed: Preview automation snapshot timed out after 15000ms."
- T3 again echoed tab URLs containing the QA session's private code. All three codes were loopback-only sample sessions, and Stop expired each one.
- The round 1 evidence above is unchanged and remains in `build/viewer-join/`.

## Package

`scripts/build-app.sh` rebuilt 0.2.0 build 24 after the round 1 fix. The ad-hoc signed, unnotarized candidate is frozen at `build/viewer-join/candidate/Setbeam.app`, and the round 2 QA copy is byte-identical. Executable SHA-256: `431628cfe437aef941aa97049afeee6653a3039dab2c69f31611d18945279585`. `viewer.js` SHA-256: `d74a334bcc160b1fe8ef84dd6d48f440a9c4f19aff4025330c4542185ffd8347`.

The first build 24 candidate moved to `build/viewer-join/candidate-round1/` (executable `4c259aa2…0252`, `viewer.js` `95682f17…3df4`). Only three files differ: `viewer.js`, the signature seal, and the main executable. With signatures removed, both executables hash to `eb5759a4…fae`, so the compiled code is the same and only the signature changed. Against the round 1 source manifest, only `viewer.js` and `scripts/check-viewer-recovery.js` changed.

- Strict recursive signatures pass, all six executables are arm64, and linked libraries are system-only.
- No Homebrew paths appear in the executables.
- The seven viewer resources match the source, and the fixtures and notices are present. The app has 37 files.

No packaged source changed after the rebuild. Results: `build/viewer-join/round2/package-audit.txt`, `source-manifest.txt`, and `source-manifest-diff.txt`. The first candidate's audit stays in `build/viewer-join/package-audit.txt`.

## Limitations

- **One Mac.** Phone, tablet, and large-text results come from viewport and touch emulation in desktop Chrome on this Mac. No physical phone, tablet, Safari on iOS, Android browser, or second computer was tested. Real on-screen keyboard overlap, iOS text size settings, and VoiceOver or TalkBack speech remain manual checks.
- **Ambiguous send failures.** If a request reaches the gateway but its response is lost, the page reports a failure. A second Ask creates a second request. The first drops off the operator's list after 12 s and lapses after 30 s.
- **Ended or unavailable.** A page whose link stopped working cannot tell an ended session from a changed code. It shows Sharing ended when `state.json` says so, and otherwise "This viewing link is no longer active".
- **Dark only.** The viewer has no light appearance, so none was checked.
- **Existing failure.** The intermittent preview-bridge assertion above remains in unchanged code.

## Review ledger

- Implementation and fix: Claude provider, `claude-opus-5-5`, `effort: high`, verified in both task responses. Reviewer: Codex provider, `gpt-6.1-sol`, `reasoningEffort: high`, `serviceTier: default`, verified in both review responses. One reviewer per round; no nested reviewers. Usage was not reported.
- Round 1: CHANGES. S1, should, accepted: the pre-admission `state.json` fetch ignored HTTP 404. Stop with the form open left an invalid Ask to join form, and Try again could revive that form. The reviewer reproduced both transitions. Its local validation passed 40 viewer checks, 12 pointer checks, 22 focused Swift checks using `--skip-build`, and `git diff --check`. It did not rerun the full suite.
- Response: fixed the pre-admission HTTP 404 branch, with one condition and its explanatory comment as the only product delta. Added two regression checks that failed at the intended assertions before the fix and pass afterward. The full local suite and real served-browser transitions passed as recorded above. No finding was disputed or declined.
- Round 2: APPROVE. S1 resolved; the form stays hidden after Stop and retry, without new requests or playback-configuration fetches. No new bug found in the delta. Reviewer validation passed all 42 viewer and 12 pointer checks and inspected the recorded served-browser evidence; it did not repeat native QA or the full suite.
- Scope: fixed local base `86cd04a`; prior S-001/S-008/S-006 work and preexisting dirty notes were excluded. At round 1, 12 tracked feature files were +459/-60, plus the new 122-line verification note and 15 additive status/backlog lines. At approval, those same 12 tracked files are +489/-60. The increase is the two focused tests; evidence text grew separately. No behavior code changed after approval.
- Nothing was pushed, no PR was opened, and no hosted workflow ran.

## Parent package confirmation

The parent ran `scripts/build-app.sh` locally after approval. All 37 candidate app files match the fresh current-source rebuild byte for byte. All 80 inputs in the frozen source manifest and all seven viewer assets match this checkout. Build 24 and strict recursive signatures pass. The executable SHA-256 remains `431628cfe437aef941aa97049afeee6653a3039dab2c69f31611d18945279585`. Results are in `build/viewer-join-parent/package-confirm.txt`.

Parent visual inspection confirms readable desktop and narrow-phone joining, waiting, declined, removed, and unavailable states. The 150% text example wraps its submit button beneath the field without horizontal overflow; content remains vertically scrollable. Expired-link captures show the form hidden before and after Try again. These are viewport emulations on this Mac, not physical-device or spoken accessibility results.
