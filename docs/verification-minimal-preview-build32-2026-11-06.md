# Minimal floating preview implementation, build 32

2026-11-06. Austin approved the V3 minimal concept and adopted its restraint as
the design standard for future work. This implements that concept. The earlier
two-row concept and its numerical design rating are superseded.

## Scope and workflow

The floating window is the local picture. Its persistent UI is the small viewer
shortcut when sessions are joined or waiting, the centered Resume action while
held, and the required Sample label in sample mode. Hover or deliberate keyboard
focus reveals Hold and Close. There is no footer, source title, More, sound or
Fit control. A viewport-sized saturation filter and light wash apply only to
this local floating picture while held. Main monitoring and outgoing media do
not use that filter.

Actual outgoing readiness confirms Hold. Pending Hold does not imply protection;
pending Resume keeps its previous wash until fresh output. A scoped target makes
Retry repeat the intended action. Pointer Resume waits through the system's
double-click interval and cancels on a second click, picture double-click, drag,
close or invalidated action. Hold and deliberate keyboard/accessibility actions
remain immediate. Only the visible rounded control accepts a sharing click.

Viewer actions live in an owned nonactivating panel. Requests and removal match
the current viewing link, session number, join time and admission before acting.
The last answered request closes its action panel. Content sizing is measured,
with scrolling only once the panel reaches its cap. Closing the preview does not
end sharing or monitoring.

The existing SwiftPM project stays in Swift 5 language mode. Local commands are
`scripts/build-app.sh`, `swift test` and `scripts/check.sh`. Native QA uses a
PID-guarded isolated bundle, separate preferences, generated media and only
owned-window captures. It uses the existing own-window Accessibility workflow,
not a template app's snapshot mode. Actual AX frames provide layout evidence.
No hosted workflow is enabled or dispatched.

The checkout already contained earlier uncommitted work. This task's before
copies and hashes are under `build/minimal-preview/before/`; reviewers use the
task-only patch rather than comparing all dirty changes with HEAD.

## Local evidence

- Sixteen focused Swift tests pass. They cover real outgoing confirmation,
  pending/failure targets, private-state safety, confirmation deadlines, stale
  viewer references, gesture guards, audience-count semantics and source-shape
  fitting to the display.
- Dark and light native interaction passes each cover hover/rest, true pending
  Hold/Resume, a real denied encoder launch and intended-target retry, local
  playback continuity, keyboard focus/Tab/Space/zoom/arrows/Escape, double-click
  and drag suppression, real borderless edge resize to 220 points and cancellation
  of an armed Resume on close. The final rounded-hit-area revision and a double-click crossing its
  boundary pass additional native checks.
- A real browser was admitted from the inactive floating panel in both
  appearances while a generated foreground app continued receiving its own
  key events. Light-mode synthetic Sam/Jordan requests additionally exercised
  individual Decline, Admit and Remove. The remaining real browser retained
  admission. These fixture sessions are not physical viewers.
- Browser DOM checks confirm decoded 1280×720 video advancing with live audio
  and video tracks after Resume. Hold is muted with no attached source stream
  while local playback continues. The final browser also decodes 360×640 after source change without
  re-admission, ends media on individual removal, and follows Stop.
- A burnt-in Sample portrait RTSP fixture supplies 360×640 video with a moving
  frame marker. Dark native checks pass Hold/Resume, publisher loss, disabled
  Resume, same-source return with Hold preserved, unchanged viewing link and
  minimum-size resize. A bottom-positioned window stays fully onscreen after
  the portrait aspect change. Light verification passes as well. A white document header tests the
  normal viewer-control scrim at 5.94:1 contrast with white text.

Native captures, JSON states and command logs are under
`build/minimal-preview/qa/`. Spoken VoiceOver, physical trackpad pinch, real
Capture One use, physical transmission/capture hardware, audible output and
older macOS remain separate qualification. Accessibility labels and actions
are inspected through the actual native AX tree; spoken output is not claimed.

## Failures retained

The first focused test compile lacked the existing project's `@testable` Core
import. Correcting the test-only import produced a passing run. Native testing
caught missing key-view traversal; explicit traversal and native target/action
dispatch fixed it. The harness also needed fresh state files and registered
window waits, a real two-click sequence, the observed primary-action-first Tab
order, the form's actual AX locator and real edge resizing instead of an
unsupported AX size setter. Those harness failures are distinguished from the
keyboard implementation defect. The failure ledger and failed-run logs remain.

## Opus review

Claude Opus 5.5, high effort, runs Standards and Spec as separate review tasks.
Round 1 returned CHANGES on both axes. Responses include correct recovery
semantics, specific guidance without source names, saturation, disabled styling,
safe key handoff, the confirmation deadline, explicit action targets and smaller
redraw work. Review responses and complete reports are retained in
`build/minimal-preview/review/`. Round-1 findings are addressed; final approval is pending. Additional native
checks found and fixed an armed Resume crossing between a rounded button and
the picture. The same pointer guard cancels on subsequent picture gestures.
The normal control scrim was strengthened after an actual white-source test.

The complete packaged run passes. Installation and archive audits pass; private
upload is in progress. Build 32 is installed; build 31 is preserved.

## Standards review, round 2

Opus 5.5 high: APPROVE. All documented round-1 blockers are fixed. The review
confirms truthful confirmation/deadline behavior, stale-safe actions, private
preview safety, keyboard handoff and owned panel cleanup. Optional future cleanup
includes sharing more recovery wording, a raw-value action enum, a common Tab
helper, legacy activation API modernization and fewer forwarding methods. None
is a blocker for this implementation.

## Spec review, round 2

Opus 5.5 high: APPROVE. No must-fix spec defects remain. The review inspected the
reference and actual captures plus native PASS records. It confirms the minimal
layout, local wash/saturation, disabled Resume, guarded gestures, pending/error
truth, viewer decisions, source geometry and accessibility labels. The 28-point
native corner hit areas are deliberate, documented above the concept's 26-point
illustration. The rounded Sample scrim prioritizes contrast as a label.

Review summary: Standards 0 blocking findings; Spec 0 blocking findings. Full
packaged checks remain pending. Advancing native frames confirm rendering works;
GPU cost of the held-state filter has not been separately profiled. Physical and
spoken-accessibility qualifications remain unclaimed. Full reports and exact
round-specific task patches are retained in `build/minimal-preview/review/`.

## Final packaged checks and installation

`scripts/check.sh` passed with exit 0 in 652.850 seconds on Austin's Mac using
build 32's bundled helpers and fixtures. Source inputs stayed unchanged. All
262 Swift tests, five Python timing cases, 43 viewer and 12 pointer checks and
every media stage pass, with no stage retries/skips. The large-keyframe check
decoded 489 frames in seven seconds from 1,749 KB keyframes without errors.

The ZIP is 63,947,225 bytes, SHA-256
`7e0d282f75b1a1aefe926347667c3482fcd057e93f55ea06fa2ce67606a8c536`.
Its integrity passes; all 37 app files match the extracted archive, candidate
and installation. Strict signatures pass. Six arm64 executables link only system
libraries. The archive includes developer-build notes, app hashes and a 161-input
source manifest. It is ad-hoc signed, not a notarized public release.

Before replacement, the installed running app was checked to be private with no
open sheet and quit normally. Build 32 is installed at
`~/Applications/Setbeam.app` and opened normally. Build 31 remains at
`~/Applications/.Setbeam-before-minimal-build32.app`. The install audit, dependency
audit, package audit, complete check log and stage logs are retained under
`build/minimal-preview/`. No production source changed after approval. No hosted
workflow, commit, push or PR ran.

## Private delivery

Austin Deliveries reports delivered with remote verification under Setbeam /
Minimal preview. Receipt `20261106T220224Z--2fb99ade634f` contains the build-32 ZIP
and three safe native sample captures. [Open the delivered build](https://drive.google.com/drive/folders/1ErYW6xQT26mFoYYtRgDdX-HbaUNtDs3C).

The reopened installed app reports build 32 and is private with no open sheet.
All reviewed production source hashes still match the round-2 review snapshot.
Installation, packaging and delivery are complete. The separate physical,
spoken-accessibility, audible-output and older-OS limits remain as recorded.
