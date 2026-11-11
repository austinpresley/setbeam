# Single picture and native chat polish, build 36

Austin asked for one media output and a clean native chat after reviewing the
build-35 dark screenshot. Changes are scoped to native presentation and build
metadata; the gateway, runtime, viewer web UI and media ownership are unchanged.

## Design and behavior

- Remove the duplicate live thumbnail from Sharing in both docked and separate
  presentations. Keep one main local picture and the existing audience status.
- Align message names, text and reply excerpts, with cursor-color arrow avatars
  and a server-assigned DigiTech badge. Quiet timestamps and a message menu
  replace the permanent blue Like, Reply and Remove rows.
- Sent images use compact, explicitly sampled attachments and open on request.
- One composer contains the draft, capture, identity and Send controls. Reply
  cancellation and frame removal remain visible while drafting. Identity and
  longer session information open only on request. The encryption/lifetime
  notice remains visible.

UX: Sharing > Chat or Command-4 opens the existing panel. Its conversation rows
use a message menu and context menu for Reply, Like and operator-only removal.
Reply focuses the draft. Capture previews before Send. Attachment, identity and
information buttons open popovers, because each is a small task tied to a
control. Empty chat invites the first note; sharing off explains how to begin.
Errors remain inline and preserve drafts. Icon controls have help and AX labels.

## Local verification

The release app builds. Existing Swift warnings remain in AccsoonDiscovery's
unused fcntl returns and MediaRuntime's unnecessary await; no warnings arise in
the changed views. The first complete scripts/check.sh attempt passed native
bridge, Swift/browser and primary media checks, then passed both source-recovery cases and failed the following viewer-access
startup with `FAIL: The video service could not start.` while an isolated sample UI
session was running. The complete isolated rerun without any QA UI session passes. No timing
bound or test expectation was changed.

The documented local Chrome collaboration script passes all eight layouts,
actual sample decoding, literal text, likes, reply, image attachment and draft
retention. Native dark checks pass message menus, reply/send including
Command-Return, capture/send, reaction, moderation, identity editor, image
expansion and information. Resting chat opens without a focused composer.

Physical hardware, real iOS, audible output and spoken VoiceOver have not been
newly qualified by this presentation-only change.

## Opus round 1 response and native completion

Round 1 approved the visual direction provisionally. Its three required code
refinements are addressed: outgoing picture confirmation/audio facts remain in
the status help and accessibility label; disabled capture names preparation,
sharing transition, Hold or unconfirmed-picture reasons; the composer border
uses the accent only while the draft has keyboard focus. Additional refinements
use a 64x36 image thumbnail, remove repeated sender text, preserve sender case in
help, expose row accessibility actions, and say Remove for Everyone.

The message menu deliberately remains visible. Actual right-clicking selectable
message text opens macOS's text menu. A persistent quiet menu and explicit row
AX actions keep the collaboration commands discoverable alongside text copying.
An AX Reply action was invoked successfully in both native appearances.

Actual key-window snapshots are inspected in both appearances. The main window
is 1221x636; the compact main is 961x472 with a 320-point conversation panel.
The compact composer keeps reply cancellation, image removal and Send visible
together. The 360x640 separate window opens without a focused field; Hold keeps
all prior messages and disables capture with a Resume explanation. Stop clears
chat while the main source keeps playing. A flexible empty state originally let
the separate command area stretch. Giving the chat detail the remaining height
and keeping command layouts intrinsic removes that band, verified in the final
separate sharing-off capture. No global system appearance was changed.

Native snapshots live in build/chat-polish-evidence: chat-light.png,
chat-dark.png, chat-focus-light.png, chat-compact-dark.png,
chat-compact-draft-dark.png, chat-hold-dark.png, chat-detached-dark.png and
chat-stopped-dark.png. These use sample media and fixture names only. QA app
variants change only the bundle identifier; their executable code matches the release after removing the QA signature.
88 scoped layout values pass the existing four-point scale. This repo has no
layout-probe/grid scripts; actual alignment, scrolling and clipping were checked
in native snapshots instead of claiming an unavailable automated layout probe.

All owned QA app PIDs were confirmed exited before the complete isolated check.
That rerun passes with the final build-36 helpers/fixtures. The first failed log
is preserved separately. Opus round 2 approves the design and code with no
remaining blockers, conditional only on this completed full check and the
updated record. Final Opus approval and verified delivery are recorded below.

## Package preparation

The staged 0.2.0 build-36 app has 38 files matching the built copy. All six
executables are arm64, have no Homebrew or /usr/local library links, and pass
strict signature checks. All 165 source-input hashes match the current tree.
Only five native UI files and build metadata differ from delivered build 35;
the other 159 inputs, including every runtime, gateway, browser and test input,
are unchanged. The build is ad-hoc signed and not notarized.


Exact failure stage correction: the first full-check log prints both RTMP and
RTSP source-recovery passes before `FAIL: The video service could not start.`
The following command in scripts/check.sh is the viewer-access probe, so that
was its startup failure, not source recovery. Earlier progress/review notes
misidentified the stage. The initial full log remains /tmp/setbeam-chat-polish-check.log;
the recovery PASS excerpt is retained as first-source-recovery-pass.log. The
isolated run has also passed both recovery cases and continues beyond them.


## Final complete local check

The isolated scripts/check.sh exits 0 and ends with `Swift and media checks
passed. Native, browser, and physical checks are separate.` It passes 279 Swift
tests, five Python cases, 59 browser/pointer checks and every media stage,
including source recovery, viewer access, local/short addresses, source-switch
safety, formats, frame rates and large keyframes. The 1,749 KB keyframe stage
decodes 505 frames in seven seconds with no decoder errors. No threshold,
timeout or test expectation was changed. All QA UI sessions were closed before
this run. The pass does not establish the cause of the initial access-startup
failure; that failure remains recorded separately.

Final full log: /tmp/setbeam-chat-polish-check-isolated.log. The 165 source-input
and 38 app-file hashes still match the staged build. No hosted CI, commit, push
or PR was run. Real hardware, real iOS and spoken VoiceOver remain unqualified.


## Installed build

Build 36 is installed at /Users/apresley/Applications/Setbeam.app. Build 35 is
preserved at /Users/apresley/Applications/.Setbeam-before-chat-polish-build36.app.
Native launch restores Austin's saved CineView Master 4K setup privately. The
Sharing status reads Private and Start Sharing is disabled while finding the
absent transmitter. Exactly one main window is present and visible. No QA
viewing session remains active. Final gate acknowledgement is requested from
Opus after the passing suite and this updated evidence.


## Final Opus approval

[Opus 5.5 High round 3](reviews/2026-11-10-chat-polish-opus-signoff.md) approves
delivery with no blockers after checking the complete isolated log, unchanged
code hashes, updated docs and package/installed audits. The ZIP SHA-256 is
682cf671a43758c3c14fa4fb15d0151db2dca0c436c351a29a2bb39fba19192d.
All 38 built, extracted and installed app files match. The initial access-startup
failure remains unexplained and should be diagnosed if it recurs.


## Verified delivery

[App, light/dark screenshots and final Opus report](https://drive.google.com/drive/folders/1XWm0Wm_Aifdrx28gsbKjbuVeYckYEjdm) are delivered
privately through Austin Deliveries with remote verification. Delivery ID:
20261111T032500Z--f4b63d227f21. The installed app remains private with one visible main window and
Austin's saved source. Build 35 is retained as the local rollback. No hosted CI,
commit, push or PR was run.


## Current viewer link shown separately

Austin asked to see the mobile and desktop link after the Mac cleanup. Fresh
build-36 screenshots use a separate loopback-only sample session, installed
Chrome at desktop 1440x900, phone portrait 390x844 and landscape 844x390. These
show the current browser UI, which was not changed by the native chat cleanup.
The browser still uses large sent-image previews and the longer chat notice.
No app code changed, and these are browser viewport captures, not physical iOS
qualification. The QA session was stopped and its owned app PID exited; the
installed app was not restarted or shared. The comparison is visually inspected
at 728 and 360 pixels wide, including its disclosure controls.

[Viewer link screenshots](https://drive.google.com/drive/folders/1NelaNCelwAnVxnqvbPEmrbTF2S53fMIj) are delivered privately with remote
verification, ID 20261111T033719Z--15e6b008abfd. Stable originals are in
local-artifacts/ViewerLink. T3 preview snapshots twice timed out with
`Preview automation snapshot timed out after 15000ms.`; the documented local
Chrome workflow captured the actual viewer instead.
