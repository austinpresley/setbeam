# Organization and sharing panel, 2026-11-04

Follow-up: the timing and port-reuse failures recorded below are resolved in build 30. Both complete local validation runs pass; the final run uses packaged helpers and fixtures. See [suite reliability verification](verification-suite-reliability-2026-11-04.md). Earlier failure evidence below remains historical.

Austin approved the three image concepts under `design/mockups/organization-v1/` and asked for implementation, a harsh Opus 5.5 critique, fixes, and a demonstration. This work starts from the current build-28 checkout, including its approved source chooser and prior uncommitted changes. The task baseline is preserved under ignored `build/organization/before/`, with an input hash inventory in `build/organization/baseline.json`. Review scope is the task-only patch, not the complete dirty branch.

## Design

- Preserve the native monitor-first window and the separately approved source chooser. Add an optional 320 pt Sharing panel with Invite, Viewers, and Options. Opening the panel widens the window when space permits; a separate Sharing window handles smaller screens and can be requested explicitly.
- Keep Hold/Resume and Stop immediately available. Opening, switching, detaching, docking, and closing Sharing must not change media or admission. Viewer indicators and request-card review open Viewers. Invitation commands open Invite. A quick sharing-status popover retains the outgoing picture check.
- Share invitation content with the large join-code presentation. Keep optional viewer Wi-Fi metadata independent of the Mac's actual Wi-Fi and of the viewer-interface selector. Expose typed-address status and the IP fallback. All codes and links stop granting access after Stop.
- Viewers shows pending requests followed by admitted browser sessions and their observed health. Admission and removal call the existing gateway methods. Names remain labels, not verified identities.
- Replace Advanced with Source Details, direct Enter Stream Address, Sharing Options, and Diagnostics. Capture rate affects the source; viewer quality/rate affects only outgoing media. Group approval and short-address joining together. Confirm an operator-requested viewing-interface change before it stops sharing.
- Use the standard Settings scene for permissions and diagnostics. Organize menu commands by Source, Monitor, Sharing, and Help. Keep source names separate from Session name.
- Give browser viewers a direct identity button. The admitted identity editor overlays the picture without closing/replacing the playback peer; the initial join and approval states still replace the player. Names stay fixed under approval.

## Validation so far

- Release builds pass. Three warnings in unchanged core code remain: two unused fcntl results and one unnecessary await. No core media source is changed by this task.
- Three focused navigation tests pass, including private source setup, preservation of active Hold while navigating, and preservation of Wi-Fi join details when changing only the viewing interface.
- All 43 browser-controller checks pass. The updated identity test fails against the preserved old controller because the direct identity action is absent, and passes on the new controller. Editing keeps the same peer and sends no extra join request.
- The first focused Swift test compile failed on the test's incorrect method name `hold`; using the existing `setHold(true)` fixed compilation. The first release compile found one remaining old viewer-sheet reference in request-card suppression; that reference now checks the active Viewers panel.
- A first isolated QA launch failed because its preferences-suite name equaled its own bundle identifier, for which UserDefaults returns nil. The isolated suite now uses a separate `.preferences` suffix. This is a QA configuration failure, not a production launch-path change.
- Native screenshots and interactions, final full-check results, review findings/responses, and packaging evidence will be recorded below as they complete.

## Review

Claude Opus 5.5, high effort, round 1 returned **CHANGES** after reviewing the 27-file task-only patch and actual dark native/browser screenshots. No edits, builds or tests were run by the reviewer. The original review task is retained in this thread. Review responses below are implemented, with fresh runtime checks and round 2 still pending.

| ID | Response |
| --- | --- |
| M1 | Identity editing moves below the player controls in normal page flow on narrow/short viewports. Desktop anchoring follows the picture edge. The direct button exposes expanded state, toggles closed and yields to pointer controls. |
| M2 | Source Details has staged values and one Save/Cancel flow. The tested commit plan includes pending sound and rejoin-password edits. Changed sound confirms reconnection; empty rejoin passwords cannot replace stored credentials, and open transmitter Wi-Fi is explicit. Escape explicitly cancels. The prior native build did close Source Details with Escape in QA; the explicit handler now makes that behavior intentional. |
| M3 | Repeated destination actions increment a focus request and raise the owned Sharing window. Review cards preserve the source form and use the separate window. |
| M4 | Card help/VoiceOver strings, architecture and current status use the new destinations. Current getting-started navigation is updated. Dated historical verification records retain their original menu names. |
| S1–S2 | Pending rows are compact with trailing actions and one identity note. The outgoing thumbnail/sound summary is pinned below the roster. Problem-state health detail is visible. |
| S3–S5 | Approval explains the short-address dependency; inactive dependent switches show off while preserving the saved preference. Drafts stay in the model, address Return applies, and Viewing network is first and targeted by its recovery action. |
| S6 | RTSP pre-fill accepts only network-source active addresses. An incoming key is never offered in the RTSP field. |
| S7–S9 | Footer toggles expose selected state and accurate actions. The inspector is flush to the toolbar and window edge. Private/no-Wi-Fi states have no orphaned steps or large empty Wi-Fi glyph. Large codes are a side-by-side 240 pt presentation with no editor. |
| S10–S12 | Help opens the selected Settings tab. Saved setup names its state and forget target, supplies retry, and disabling Remember removes that source's saved connection. Native close notifications fix the reproduced title-bar close bug. Default window placement, restored empty windows and docking use the main window's screen. |
| S13–S15 | Reviewing viewers preserves modal drafts in a separate window. Switch text has one accessible owner and dims with disabled state. Pure presentation, card-visibility, pre-fill, draft-plan and persistence regressions supplement native interaction checks. |
| Could items | Removed dead network-sheet code and duplicate invitation branches; hid the ellipsis menu indicator; added readable colored initials; used Display labeling and content-fitting Source Details; cached viewer Wi-Fi per SSID; added browser expanded state and pointer/editor coordination; made the Sharing-window menu state-aware and added Command-1/2/3; labeled and announced inline Sharing; same-destination requests close the status popover; normalized stream-entry casing and added a recovery action. The roster says Joined rather than Watching because an admitted session has not necessarily decoded fresh video. |

Additional native QA found that title-bar closing the Sharing window did not run SwiftUI onDisappear. Native NSWindow close observation now clears the presentation state. Added Settings/Sharing windows are also excluded from the local-monitor display-wake decision when they show no local picture. Wi-Fi credentials commit before their saved metadata changes; a failed save keeps its draft.

Thirteen focused review regression tests and all 55 browser/pointer checks pass. The browser identity test fails on the preserved old controller and passes on the new one. The current source is still undergoing final native light/dark checks and a fresh complete local check before re-review.

## Limits

Physical transmitter/capture compatibility, a second device, actual phone QR association, audible sound, supported older macOS versions, and spoken VoiceOver remain separate evidence. Generated fixture windows and labeled sample media qualify only the software behavior exercised here.

## Native and real-browser review-fix evidence

The revised app was exercised in isolated preferences in dark and light. `build/organization/qa/native-{dark,light}-results.json` records source-details entry, staged source-name/FPS edits, request review in a separate window, title-bar close/reopen, Cancel and Escape, docking, preserved address drafts, Settings shortcuts, stream setup/back navigation, and explicit sharing/large-code presentation. Source Details now opens without selecting its text field, and its groups share a trailing edge. Accessibility switch columns align and have one named owner. Disabled pointers and saved-but-inactive short-address states are captured in light mode.

`browser-{dark,light}-results.json` records actual decoded 960×572 application-window video at source capture 1 fps, advancing decoded frames through identity editing without another peer, fixed names under approval, twelve swatches and Save in natural portrait-page flow, no 320 px horizontal control overflow, native admission, outgoing silent Hold, Resume, and Stop with local monitoring intact. Native screenshots show one real browser and three synthetic waiting requests; their names are fixtures and no pending request receives playback credentials. The light run additionally activates the actual corner-card Review link over a typed source draft, verifies that the Sharing window becomes main, then checks native title-bar close/reopen. The action is an accessibility Link, not Button; the QA selector was corrected accordingly.

The native harness also needed to focus and commit text edits before asserting their SwiftUI binding, wait for published state/Apply-button enablement, distinguish readOnly from disabled in the browser form, and give each Chrome run a fresh debugger profile. Its initial failures are retained in local logs; they are not reported as application regressions or as successful checks. A generated fixture's initial zero-sized container was corrected before final captures. The final reports above are successful runs.

`extra-native-results.json` verifies This Mac only hides unavailable address controls, the limited-network recovery action opens the network selector, Automatic restores it without interrupting monitoring, Remember off removes the saved source, Remember on saves only after the fresh-picture gate, and floating monitoring remains independent. Small and 240 pt large native code presentations decode the same two payloads with Vision; the fictional Wi-Fi code has no password. No phone scanned or associated with that Wi-Fi.

Screenshots are under `build/organization/qa/shots/`. They contain only generated fixture-window or explicitly labeled sample media, never a capture of another user's window. Core and probe source hashes remain identical to the initial task baseline. The final full local check and Opus round 2 are now pending.

## Round 2 and final draft gate

Opus round 2 returned CHANGES. It marked the round-1 must and should items resolved, but found that unrelated sheet openers could still replace a changed Source Details form. The six residual IDs are addressed as follows: R1/R2 use one presentation gate that rejects replacement of dirty details, keeps private preparation from running, and raises the monitor for permitted presentations. Commands and the large-code action disable while that source draft is dirty. R3 bases active typed-address language on the actual open path and retains the local-address condition for its dependency caption. R4 forgets only the saved source's own remember intent. R5 records name/remember changes in the tested commit plan before applying other settings. R6 removes the duplicate standalone header, combines inactive captions and orders parent switches first, focuses stream entry on its required address, inherits remember intent, uses one Wi-Fi draft disclosure, and gives the harness readable close-state labels.

Fifteen focused presenter/draft tests pass after these fixes. The first post-review complete check stopped in unchanged ShortAddressListenerTests.testStopThenServeAgainReusesThePortPromptly at its expected-state deadline, with a second timeout report from that same case. The identical focused test passed unchanged in 0.056 seconds. No listener code or test threshold was changed. The earlier task-wide full run passed; a fresh complete run of the final candidate is still required. Failure logs are preserved in final-check-first.log and final-swift-first.log.

Round-3 regression coverage includes every named sheet target through the dirty-source presentation gate, with an assertion that blocked preparation closures do not run, and a distinct-old-source forget test. The commit plan records name/remember intent independently from rejoin and capture updates. Stream setup inherits remember intent and starts in the required address field. The dedicated Sharing window uses its native toolbar/title rather than duplicating the inspector header. The identical focused port-reuse test passed unchanged; the final complete run will retain both outcomes.

The final light native run passes after the gate changes. The real-browser regression additionally opens Invite from a dirty Source Details task, checks that Show Large Join Codes is disabled without losing the draft, returns to Viewers, and activates the actual corner-card Review link with that destination already selected. It verifies window focus and draft retention. After Cancel, the same separate-window large-code action opens its presentation on the foreground monitor. Hold/Resume/Stop and the natural-flow phone identity editor pass again. No new runtime source or hardware claim was introduced. Round 3 and a fresh complete local check are pending.

## Round 3 follow-up

Opus round 3 marked the earlier findings resolved and requested two final changes: Return to Previous Source needed the same dirty-draft guard, and the short-address row needed a non-truncating title and a tighter relationship to its local-address parent. The model and all return actions now enforce the guard. The dependent switch follows the address field/status, uses a short fixed title, and displays the hostname in wrapping detail. Minor follow-ups route the late incoming guide through the presentation gate, disable its busy source-popover entry, and explain a disabled large-code action with hover help.

The previously unverified main-window-close case passes in native QA: after closing the main window with the detached Sharing window open, its large-code link reopens the monitor and presents the codes in front. `closed-main-large-codes.json` and `shots/closed-main-large-codes-light.png` record it; no new fallback was needed. Updated Options screenshots in light and dark show the full generic title and parent/child grouping. Fifteen focused tests pass.

The round-3 complete script passed all 241 Swift tests and the earlier media/access/recovery/short-address stages, then hit the pre-existing format-cadence assertion in unchanged code: 30.000003658537032 fps with a largest interval of 0.05006699999999986 seconds. This is recorded as a failed complete run, not a pass, with logs in round3-full-check-failure.log and round3-format-failure.log. No thresholds or core/probe source were changed. A final complete run is being made without QA media or concurrent builds.

Opus round 4 returned **APPROVE**, with all N1–N5 resolved. Its optional caption polish is applied: the hostname stays together when the option is off, the on-state caption leaves the active-state explanation to its status, and that status is indented with the child. The optional previous-source unit-test limitation is accepted as code-review plus guarded-command/model evidence; no claim is made that an empty-previous-source fixture alone tests that guard.

The next complete attempt stopped at the known unchanged preview-bridge startup timestamp-duration assertion before Swift tests. The failure is preserved in round4-full-check.log. The prior run passed all 241 Swift tests and the earlier integration stages before its unchanged cadence assertion. The final caption-only build is being checked again; no media source, bridge or threshold is changed.

## Approval, installation and final validation

Opus round 4 approved all remaining source/presentation/layout items. Its optional three-line caption polish was applied and independently approved. No source changed afterward. The remaining optional previous-source unit fixture limitation is recorded as code-review and disabled-command/model evidence rather than overclaimed test coverage.

Build 29 is installed; all 37 files match the packaged candidate, with strict recursive signatures. Build 28 remains at `~/Applications/.Setbeam-before-organization-build29.app`. The six arm64 executables link only system libraries. Source inputs are captured in the 145-input manifest. Core and probe sources remain byte-identical to the task baseline.

All 241 Swift tests passed in the round-3 complete run. Later final attempts stopped at the unchanged preview-bridge duration/gap assertions; the packaged focused preview rerun passed unchanged. The final independent Swift run had only the existing short-address port-reuse deadline case fail, with all 88 app tests passing; the exact focused test passed unchanged again. All 55 browser/pointer checks pass. Independent packaged format/codec transition, frame-rate and large-keyframe checks pass. The latter carried 1,749 KB keyframes and decoded 509 frames in seven seconds without decoder errors. These focused successes do not turn the failed whole scripts into passes. Full logs and exit codes are under `build/organization/final/` and the task's complete-run logs.

No retry relaxed an assertion, changed a core/bridge/probe implementation, or enabled hosted CI. The known media timing and listener-reuse checks remain follow-up work outside this UI reorganization. Private delivery and the final archive audit are recorded below when complete.

The final packaged safety probe also passed all three cases: invalid-source preservation and continuous held video across input changes, offline replacement/return/Resume with the same viewing identity, and accurate source/outgoing audio status with silent Hold and complete owned-process cleanup. The final independent result inventory is `build/organization/final/final-check-results.json`.

## Delivery

Private Austin Deliveries upload completed with remote verification under Setbeam / Organization. Receipt `20261104T113324Z--91694066d136` reports state delivered. [Open build 29 delivery](https://drive.google.com/drive/folders/1yLPwTisI2-j0KAqDEW2LZAPiME7I_Vls). The ZIP and four actual native/browser screens are included. Local originals remain under dist/ and design/implemented/organization-v1/.

- Archive SHA-256: `59744b982d79a2b704abca6d90ad8751b6418bd099fc12dc32253a2d95bd3f29`.
- Archive bytes: 63868758. ZIP integrity and all 37 app-file hashes match the build and installation.
- Installed app: `~/Applications/Setbeam.app`, build 29. Previous build 28 is preserved.
- The installed app was opened for Austin. No commit, push, PR or hosted workflow ran.
