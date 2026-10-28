# Build 18 UI verification

Date: 2026-10-28. Setbeam 0.2.0, Build 18. Austin approved UI review items 1 and 3–7 with full send and sol-loop. Item 2 was explicitly rejected: the native Hold/Resume and Stop controls remain icon-only, in the same positions, with the same help and accessibility labels. Blue Hold is the separate approved color change.

## Local automated evidence

- The initial local Swift suite passes 119 tests, comprising 84 core and 35 app checks. The new viewer-attention check verifies that struggling sessions come first without losing healthy or neutral sessions, and that Hold/Stop suppress the warning.
- All 26 viewer-controller checks pass. The added Escape case fails against the unchanged main-branch controller with `false !== true`, because help remains open, and passes with the fix. The first draft of the test fixture tried to access its lazily created panel before creation and raised `TypeError: Cannot set properties of undefined (setting 'hidden')`; the fixture now obtains the panel through the mock document first.
- `scripts/build-app.sh` builds and ad-hoc signs Build 18 locally. The complete `scripts/check.sh` passes in one run with tools and fixtures from a frozen copy of that app. It reruns all 119 Swift tests and 26 viewer checks, then passes preview-bridge, sample/RTSP/RTMP media, helper/server recovery, source switching, codec/format/cadence, frame-rate, and keyframe probes. No assertion or timing threshold was relaxed.
- GitHub Actions was enabled at repository level even though the repository has no workflow files. It is now disabled. No hosted test, build, or packaging workflow was run.

## Native and browser evidence

An isolated, uniquely identified QA copy of the packaged app used its own preferences, session files, and logs under ignored `build/ui18`. The first attempted background launch ended with its launcher; running the executable in a retained terminal session kept the intended test arguments. No product workaround or alternate app source was introduced.

- With sharing on loopback, Show QR codes displays the lock, network explanation, and Choose viewing network action, with no invitation codes. That action opens Advanced at Viewer network. Cancel preserves sharing. Selecting Automatic after Stop restores the normal panel, and starting sharing on the selected Ethernet address displays a feed QR again. This verifies presentation and routing, not physical phone scanning or LAN isolation.
- Gear > Picture settings displays viewer quality and frame rate in a focused native sheet. Saving 1 fps updates the running sample's viewer FPS while native playback and sharing remain active. Network credentials are absent from this sheet, and picture controls are absent from Advanced.
- Two synthetic heartbeat senders exercised existing guest reporting in the isolated session. An amber 1 viewer struggling button appears in the native footer. One click opens Picture and viewers with the named struggling session first. Hold removes the warning. These are synthetic health reports, not a physical packet-loss qualification.
- Native Hold uses blue and the local sample continues to advance. The actual Chrome viewer displays the corresponding blue On hold state. Resume returns the session to sharing. Stop makes the existing Chrome page show Sharing ended, while native monitoring continues. Native frames advanced from 7,581 before the final Stop to 7,889 afterward, with sharing false and native playback true.
- In an actual Chrome Incognito viewer, the 1 fps sample reaches Live feed. With the viewer-name field focused, typing and pressing Escape closes Connection help and leaves the Help button focused. The local browser window was selected by its exact title and closed; the user's other Chrome window was left open.
- The source chooser in dark and light appearance shows Available now, the selected Mac display, and the labeled Sample feed together above wireless guidance. Camera/capture instructions expand on demand, and the wireless text names CineView Master 4K.
- A second private light-appearance session selected This Mac's screen. Native playback confirmed 1920×1200. Picture settings showed both Viewers and This Mac's screen sections, including the independent Capture frame rate. Cancel closed the sheet without saving. No sharing was started in this session.
- Normal Quit removed all 11 recorded processes from the sample/sharing QA session and all seven from the light screen session. The synthetic heartbeat sender ended after the isolated session closed.

T3 browser navigation reached the viewer, but snapshot inspection twice returned `Preview automation snapshot timed out after 15000ms.` Chrome was therefore inspected through native computer use. The temporary T3 tab was closed.

## Review and package

Sol approved the full 15-file diff in one round using gpt-6.1-sol on xhigh through the Codex provider in T3 Code. The selected service tier was default. There were no findings, fixes, or declined items. Usage was not exposed. The diff at entry and at approval was unchanged: 273 insertions and 117 deletions. Only final evidence documentation was updated afterward. The reviewed implementation is committed and pushed only after this approval.

The frame-rate probe keeps 1 fps healthy beyond the watchdog thresholds, preserves dimensions and viewing identity across FPS/bitrate changes, restores audio after Resume, and keeps Hold silent. The keyframe probe decodes 543 frames in seven seconds from 1,750 KB keyframes without decoder errors. Unlike the earlier Build 17 handoff, this complete format run passes without an isolated rerun.

The final archive is `dist/Setbeam-0.2.0-build18-macOS-arm64.zip`. Strict recursive signatures, system-only linked dependencies, all six bundled viewer resources, ZIP integrity, extraction, and the matching 105-file source/test/fixture/build manifest pass. The extracted executable is byte-identical to the locally verified build. The archive contains no QA sessions, logs, generated certificate, or media-server runtime configuration.

The app remains an ad-hoc signed Apple Silicon developer preview for macOS 14 or later, not a notarized public release.

Physical phone scanning, Safari, VoiceOver speech, on-set network behavior, hardware compatibility, and endurance were not newly qualified. Existing physical evidence and remaining limits in `docs/status.md` continue to apply.

Package hashes:

- Archive SHA256: `6d78445ac661621e173df30a5f332fdb7c87086ac7fe2db83ac0e375bebff8fa`.
- Executable SHA256: `a0ddab37bcd759b181c06f4cb1f14038c5e2c3c8a6e0fb48b7bde2f491e1ffcd`.
- Source/test/build manifest SHA256: `17de7e200a40949413cc71dd497fc61039d120fa4930e2de0f217d05116ed1dd`.
