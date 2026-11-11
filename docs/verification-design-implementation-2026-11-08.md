# Design refinement, build 34

Austin approved the final three-round design direction with the current native
Mac control sizes, viewer-chosen circle colors, and easy QR enlargement.
This pass changes app/browser presentation. All 39 Core, receive, encode,
bridge, probe and supervisor source files match the task's pre-change baseline.
The earlier uncommitted project work is preserved. No hosted CI, commit, push or
PR ran.

## Result

The permanent Local monitor heading and broad toolbar gear are removed. Existing
Source, Monitor, Sharing, Help and app Settings commands remain. Private docked
Invite has one Start Sharing action. Status opens/focuses one Sharing home,
retains its last tab and keeps the actual outgoing preview above all three tabs.
An independent Sharing window keeps its own commands. Closing it changes only
presentation. The dark complete-fit picture surround and approved floating
preview remain.

AudiencePresentation combines pending/failed targets with current outgoing
availability for main commands, menus, outgoing summaries and setup copy.
Failed Hold offers Retry Hold; failed Resume offers Retry Resume and an explicit
Hold choice. Pending/failure does not certify hidden picture or silence.
Automatic source changes use the same Hold presentation. Source readiness,
current output readiness and thumbnail playback remain different facts. The
existing serialized operation guards remain; this does not add an immediate
cancel to an in-flight operation.

Incoming setup uses audience state for its ready sentence and the effective
input host for local-only guidance. Required Accsoon SEE connection details
start expanded. Local sound says Muted/Unmuted without claiming a physical
speaker. Native Hold symbols and Joined wording are consistent.

The pending and joined circles already read ViewerActivity.color. This pass
adds the chosen color's tooltip/accessibility name and verifies all twelve
colors through admission and later updates. The actual Chrome/native check
shows teal chosen before asking, the same teal after admission, then lime after
a color change on the same admitted media peer. A pink waiting Sam remains
beside the lime joined Alex. Names/colors are chosen labels, not authentication.

Both small QR codes are buttons, and Invite has Enlarge Codes. The existing
join-code sheet grows to screen-bounded codes up to 320 points, previously 240.
Done/Escape only closes it. Private Wi-Fi code presentation does not publish a
feed, and the inactive viewing code remains a lock. Vision decodes the same
Wi-Fi and viewing payloads from both native sizes in light and dark.

The browser keeps sound directly in its header and replaces the permanent
secondary tray with a compact disclosed group. A visible 44-pixel entry,
pointer movement and keyboard focus expose controls. Focus/editors pin them
open, and active pointing keeps its picture gestures. M/F, double-click,
identity editing, media health and read-only access remain.

## Local checks

The complete packaged scripts/check.sh passes, exit 0, in
661.136 seconds. All source/test/script inputs remain unchanged
through that run. It uses the built app's helpers and fixtures. Results include
270 Swift tests, 5 Python cases, 58 browser/pointer cases, native decode/PCM,
RTSP/RTMP, approval/access, local/short address, recovery, source replacement,
formats, frame rates and the 1,749 KB keyframe stage. The last stage decodes 499
frames in seven seconds without decoder errors. No threshold was changed.
The full run's result and retained stage logs are under
`build/design-implementation/`.

Native QA uses a separately identified copy, isolated preferences, generated
sample media and PID-guarded AX/window capture. It does not operate the installed
user session. There are 19 before and 25 after recorded native checks per appearance, plus
8 actual Chrome checks per appearance. Native assertions cover one private
Start, all three enlargement entry points, exact QR payload equality, both
real encoder-launch failures and target-specific retries, explicit Hold after
failed Resume, narrow detached commands, close/reopen semantics, Resume and
Stop with local playback retained. Browser checks decode real media, retain
the peer during color changes, preserve focused controls and 320-pixel
containment, detach/mute during Hold, resume playback and retire media at Stop.
These are software sessions on this Mac, not physical remote-device evidence.

Changed Swift spatial values pass the four-point audit. AX frames
confirm the 320-point independent Sharing controls remain contained. The new
recovery explanation has conditional eight-point vertical padding and primary
text color, so normal monitoring gains no empty footer and failure text stays
readable in both appearances. The final private captures require an active
window and enabled Start Sharing.

Representative native captures are copied to
[refinement-v2](../design/implemented/refinement-v2/). The source files are
`viewers-light.png`, `viewers-dark.png`, `invite-light.png`, `invite-dark.png`,
`large-codes-light.png` and `large-codes-dark.png`. Additional native and browser
states, including failures, detached commands, compact monitoring and incoming
waiting guidance, remain under `build/design-implementation/qa/shots/` with AX
state/results. All pictures are sample fixtures; invitation metadata is fake,
and the pictured viewing links have ended.

## Iteration and limits

- The first audience regression reproduces the old false On hold/silenced
  presentation with two failed assertions. It passes after the shared state
  change. An early whole-Swift attempt fails only the old On hold capitalization
  expectation; the common label and its expectation now use On Hold.
- Actual Chrome catches pointer focus revealing the new group before the same
  click closes it. The new red test reproduces that event order. Revealing on
  focus-visible fixes the first click; all 58 final browser/pointer cases and
  the real-browser workflow pass. A one-pixel phone wrap is removed while
  retaining 44-pixel touch targets.
- Two T3 snapshot attempts fail with `Preview automation snapshot timed out
  after 15000ms.` The documented local Chrome QA fallback is used with an owned
  temporary profile and bounded process cleanup.
- An initial dark private capture catches transient picture preparation after
  activation. It is retained as private-dark-first-stale.png and is not a happy
  path pass. Final private captures wait for fresh state and an enabled native
  Start action before capture.
- Incoming waiting guidance is inspected natively in both appearances. The
  additional ready-state RTMP UI fixture does not pass. Reading a redacted API
  credential first causes an authentication failure; two seeded test-credential
  attempts then block in SecItemCopyMatching on macOS Keychain authorization.
  Those owned blocked fixtures and their test credentials are removed. The
  incoming ready-state text and loopback-host rules pass regression tests, and
  actual authenticated incoming media/source replacement passes the packaged
  runtime suite. Neither result is substituted for a native ready-state UI
  fixture or physical Accsoon evidence. The waiting sheet retains its existing
  native initial Wi-Fi-field focus behavior.
- Spoken VoiceOver, full inactive/Reduce Transparency/Increase Contrast coverage,
  physical touch/pinch, real Capture One, audible output, older macOS and field
  hardware remain separate qualification. The deferred source-picker/chooser
  judgments, palette disclosure, Options simplification and Permissions sizing
  are not implemented by this pass.

## Packaging and installation

Version 0.2.0 build 34 is an Apple Silicon developer build, ad-hoc signed and
not notarized. Declared minimum macOS is 14; checks ran on macOS 27.0. All six
executables are arm64, link only system libraries and pass strict signatures.
The ZIP passes integrity and extracted-file comparison. All 37 built, extracted
and installed app files match. The archive has 163 source
inputs and 63,926,064 bytes:

`dist/Setbeam-0.2.0-build34.zip`

SHA-256 `8fb3158c121b7e918b1145f1d6846f5f479d1ac7b5d66e29daa07040975aa2be`.

Installed at `/Users/apresley/Applications/Setbeam.app`. The initial running
build-33 instance has no AX window, so its UI alone cannot confirm private
state. Its executable matches the reviewed build 33. Normal termination uses
that build's own sharing confirmation guard; no sharing-ending confirmation is
accepted and no force quit is used. It exits normally. Fresh post-install AX
inspection confirms build 34 open privately, with no sheet. The old app is
preserved at `/Users/apresley/Applications/.Setbeam-before-design-build34.app`.
Private delivery is handled separately; runtime directories, session secrets
and generated build output remain outside Git.
