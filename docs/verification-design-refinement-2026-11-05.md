# Approved design refinement, 2026-11-05

Austin approved the combined independent Sol/Claude Opus 5.5 high proposal and
three ImageGen mockups under `design/mockups/refinement-v1/`, then requested
implementation. This is a presentation change on top of the existing build-30
checkout. Earlier uncommitted work is preserved; task-only before copies and
input hashes are under ignored `build/design-refinement/`.

## Scope and UX

- Local monitoring uses a fixed dark surround in both appearances and fits the
  complete decoded source in the available stage. The source-kind icon remains
  beside its name. No preview crop, source receive or media setting changes.
- A padded command row above the picture keeps labeled Hold, Resume Sharing and
  Stop Sharing controls visible. A compact arrangement keeps their labels.
  Viewer requests and playback problems remain separate discoverable actions.
- The toolbar opens/closes Sharing and remembers the last selected tab for this
  run. Invite, Viewers and Options keep their existing shortcuts. The outgoing
  summary stays above those tabs, including in the separate window. Private,
  changing, live, held and reconnecting states have words as well as symbols.
  Status words use primary text contrast; state colors belong to symbols.
- Invitations retain stacked small codes and the existing side-by-side large
  presentation. Copy Viewing Link sits below the viewing step. IP fallback is
  a disclosure when a local-address link is available. Wi-Fi editing opens
  beside its step, keeps drafts across tab changes, and commits only with Save.
  The private viewing-code placeholder keeps the two-step structure.
- The chooser keeps source categories, exact window identities, search and the
  pinned last connection. Full-window previews are taller on a dark matte with
  one card outline. The current source has a Monitoring or Waiting for picture
  label; its duplicate pinned-row action is removed. Selecting the current
  card still closes without restarting. A source switch while sharing has a
  visible Hold explanation. Cameras do not acquire extra live previews.
- Viewer rows retain individual Admit/Decline, session numbers and health
  detail. No Admit All, hardware support claim or viewer-page redesign is added.

## Local workflow mapping

This existing SwiftPM app stays in its Swift 5 language mode. Build and package
with `scripts/build-app.sh`; run `scripts/check.sh` locally. Native QA uses the
existing PID-scoped AX control and own-window screenshot workflow with an
isolated preferences suite, generated fixture applications and real packaged
helpers. It never selects another user's desktop or window. Actual AX frames
provide the layout checks instead of the new-app template's grid probes.
Screenshots are in `build/design-refinement/qa/shots/`.

## Native and browser evidence

The release app builds and packages as version 0.2.0 build 31. There are no new
compiler warnings in changed app code. The first compile showed the existing
two unused `fcntl` results and unnecessary `await` in unchanged Core code.
Runtime, bridge, probe, test sources and check thresholds still match the task
baseline. No hosted workflow is enabled or dispatched.

Dark native QA passes private restoration, toolbar opening without publishing,
inline Wi-Fi draft retention/Cancel, explicit Start Sharing, permanent outgoing
header placement in all three tabs and while Options scrolls, and large codes.
Vision decodes the same Wi-Fi and session payloads from small and large native
presentations. One immediate QA activation ran before the app registered its
bundle identity and failed the control tool's target guard; the guarded retry
passes. This is a harness startup failure, not an app test pass.

Both T3 snapshot attempts failed with
`Preview automation snapshot timed out after 15000ms.` The documented local
Chrome workflow is the browser fallback. The dark run passes actual 960×572
window video, individual admission, the same playback peer while editing
identity, natural phone editor flow and 320 px containment, silent browser
Hold with live local monitoring, a 640 pt monitor with three pending requests,
the actual request-card Review action over an unsaved source draft, native
window close/reopen, and Stop preserving local playback. The first Hold image
captures Applying Hold; a stable holding-output image is captured separately.

Both appearances now pass 17 initial native assertions, 24 post-browser native
assertions and 9 real-browser assertions. The second light attempt corrected
the harness's choice of a zero-sized hidden menu item over the visible Start
Sharing button; the first attempt timed out without invoking sharing. The
controller now prefers visible elements. Source changes use a fresh-picture
gate, and selecting the current source preserves the exact owned process IDs.
Native AX frames confirm four complete equal-height window cards, the outgoing
header above every tab, and labeled controls contained in the 640 pt monitor.
All 29 added spatial literals checked against the 4 pt scale pass. Camera/capture
and wireless categories, plus the floating preview, were inspected in both
appearances. Inactive/wrong-category extra captures were replaced after explicit
AXRow selection and frontmost activation; those first captures did not count
as a passing review. Display capture itself is unchanged and no private desktop
thumbnail is exported.

The reviewed dark/live, light/Hold, light/source-chooser and private/light PNGs
are also under `design/implemented/refinement-v1/`. They show the full sample
picture against the dark stage, native chrome, readable control labels, the
separate outgoing state, and unclipped source cards. Initial Hold captures show
Applying Hold; `source-switch-hold-{light,dark}.png` shows the settled On Hold
state. Final source formatting rebuilt to an executable byte-identical to the
QA candidate.

## Complete check and packaging

The first complete packaged check failed in 3.944 seconds at the unchanged
startup timing assertion. Its second frame had PTS and duration 116,778 µs,
above the validator's 100,000 µs duration bound. The first three durations were
33,333, 116,778 and 16,666 µs. The runtime, helper, validation code and limits
match the baseline. The failure and all stage logs are retained in
`full-check-first-failure.log`, `full-check-first-failure-result.json` and
`check-stages-first-failure/`. That stage-log directory is a snapshot of the
build logs; only the raw failed-run log establishes which stages ran.

The complete unchanged rerun passed in 645.493 seconds with exit 0, using build
31's packaged helpers and fixtures. It passed all 246 Swift tests, 5 Python
timing cases, 55 viewer/pointer checks and every media stage, with no stage
retries or skips. It covers source recovery, admission/read-only access,
local/short addresses, source changes and continuous Hold, codec/format/cadence
transitions and frame-rate changes. The final large-keyframe probe decoded 503
frames in seven seconds from 1,749 KB keyframes without decoder errors. All
recorded implementation and test-input hashes still match. The raw result is
`build/design-refinement/full-check-result.json`, with the complete log and
stage logs beside it. Both results are retained.

The staged archive matches all 37 built app files. Strict signatures pass and
all six arm64 executables link only system libraries. The source-input manifest
records 149 files. App installation and final private delivery follow below.
Physical devices, actual phone scanning, audible output,
spoken VoiceOver and older macOS are separate qualification. No commit, push
or PR is part of this task; the earlier dirty checkout is not bundled into an
unrelated commit.

## Installation and private delivery

Build 31 is installed at `~/Applications/Setbeam.app` and was opened for Austin.
The previous running app was checked to be private with no open sheet, then
quit normally. Build 29 is preserved at
`~/Applications/.Setbeam-before-design-build31.app`; build 30 had been delivered
as an archive without replacing that installation. The reopened build-31
window is private, with Start Sharing available and no active sharing or sheet.
All 37 installed files match the fresh build and extracted archive. Strict
recursive signatures and ZIP integrity pass. No app or implementation input
changed after the passing check.

- Archive: `dist/Setbeam-0.2.0-build31.zip`, 63,894,222 bytes.
- SHA-256: `6dced6d7a60ee52b3481debaea157924ae848db20174e8106fc3197e8e205d7d`.
- Delivery receipt: `20261105T060626Z--c7564b5eb24d`, state delivered with remote
  verification under Setbeam / Design update.
- [Download build 31 and native screenshots](https://drive.google.com/drive/folders/1o435wPYIsW6yGzSmRs2ViboD4lzMZ4nI).

The delivered images are actual native captures of generated sample windows,
not the ImageGen concepts. The ZIP includes the developer-build notes, all app
file hashes and the 149-input source manifest. The detailed local receipt and
package, archive, dependency and installation audits are retained under
`build/design-refinement/`.
