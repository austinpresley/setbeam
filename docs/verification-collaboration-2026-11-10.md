# Collaboration and entry points, build 35

Austin requested seven changes and Opus 5.5 High sign-off for each. This work
builds on the uncommitted build-34 checkout, preserved in a separate local
snapshot before editing. No hosted workflow, Git commit, push or PR ran.

## Review ledger

Opus design round 1 reviewed all requested behavior. Implementation round 2 is
preserved in [the full report](reviews/2026-11-10-opus-r2.md). It approved the menu
structure, requested evidence for display pointers/mobile/QR, and raised five
blocking findings. The current responses are:

- B1: Native attachments already read the 384-pixel outgoing decoder. Preparation
  now also runs off the main actor, downsizes to 960 or 640 pixels and adapts JPEG
  quality. The server adapts its sanitized re-encode. A detailed synthetic 4K
  regression passes through the real operator gateway API under the byte cap.
- B2: The App registers OpenWindowAction while constructing its scene, independently
  of MainView. ApplicationDelegate starts the model and explicitly opens the
  monitor at launch. Reopen raises and unminimizes the monitor; the menu uses that
  same method. Cold-launch/native lifetime checks are in progress.
- B3: A Wi-Fi draft carries an explicit open-network choice. A selected secured
  network cannot save an empty password. Missing or inaccessible stored passwords,
  including legacy setups of unknown security, cannot produce an open QR code.
- B4: The DigiTech can remove any message and its image. No browser removal API
  exists. Images are labeled by sender, and sample-session images retain Sample
  media labels after a source change. Operator roles have a server-assigned badge.
- B5: Source switching closes the frame gate and invalidates attachments at the
  start of the Hold transition, before awaiting replacement. A gateway regression
  rejects the old revision while that immediate gate is closed.

Other fixes cache decoded native chat images, add admitted-only unread activity
through heartbeats, clear dead reply targets, allow a small bounded interaction
burst, match tab/menu shortcut order, respect the selected QR export, and bound
live QR size by window height. Printed output is explicitly a dated snapshot;
Save additionally rejects a changed viewing link after the panel returns.

## Local evidence so far

- The original reopen handler regression failed and now passes.
- Chat tests exercise the real HTTP admission, Origin, pending/removal/rotation,
  Hold/revision gates, operator-only moderation, JPEG bounds/metadata stripping,
  message/image memory bounds, plaintext, replies and like ownership.
- A generated 4K noise picture becomes a bounded JPEG and passes the real native
  chat API. A secured-network draft cannot save an empty password.
- The original unattached SwiftUI PDF was blank. The synchronous AppKit print view
  passes a regression decoding both exact QR payloads from the saved PDF at high
  resolution, including escaped Wi-Fi text. Native Print opens a one-page preview
  containing the QR and expiry labels; no physical printer was used.
- Installed Chrome decodes the actual sample, chooses an identity/color, sends
  literal text, likes, replies and an audience-frame attachment. Eight sizes pass:
  390x844, 844x390, 768x1024, 1024x768, 820x1180, 1180x820, 320x640 and 844x260. Drafts survive resizing.
- macOS WKWebView decodes the actual sample and captures its canvas frame. Sizes
  390x844, 844x390, 768x1024, 1024x768, 820x1180, 1180x820 and 844x260 pass. Its first landscape check
  failed because playback updates overwrote chat/keyboard CSS classes. A focused
  regression fails the original controller and passes the fix. All 59 existing
  and new deterministic browser/pointer checks pass.
- A controlled full-display fixture on the available 1920x1080 display receives
  the named red pointer at the expected center coordinate. A restricted on-screen
  region contains 1,010 red pointer pixels; the same region in an actual decoded
  outgoing frame contains none. A click reaches the fixture button and typing
  remains in its text field. Hold clears native pointer presence and the overlay
  window while native monitoring continues. This is local runtime evidence,
  separate from additional physical display configurations.
- Native Chat receives the viewer image and sends a DigiTech reply plus an
  outgoing-preview image. Message history, Capture/Send, replies and role labels
  are inspected in the running packaged app.

## Final local checks

The complete scripts/check.sh passes: 279 Swift tests, five Python cases,
59 browser/pointer checks and every media integration stage. The 1,749 KB
keyframe stage decodes 497 frames in seven seconds without decoder errors.
The final 279-test Swift run and the last 13 focused UI/PDF/reopen tests also
pass. Small subsequent native layout/copy changes have unchanged media runtime
and gateway sources; focused validation and the release build cover them.
The release SetbeamProbe passes against the app's own bundled helpers and
fixtures. The Chrome and WebKit engine scripts are run manually against an
isolated packaged session, separately from scripts/check.sh.

Closed main + floating preview, minimized main, no visible windows, and closed
main + detached Sharing all reopen through Launch Services. Cold launch after
quitting with the main closed produces exactly one main window, counted through
CoreGraphics, and remains private. The installed build restores Austin's saved
source privately and reopens its closed main window. Direct Dock UI inspection
times out in computer use; Spotlight.app cannot launch in this environment,
returning NSCocoaErrorDomain 256 with a launchd spawn failure. Literal Dock and
Spotlight clicking are therefore not claimed as passes. They use the same
platform reopen callback that is implemented and tested through Launch Services.

Native QR stacking is verified at levels 0, 3 and 0 as Keep on Top changes.
The initial/default native codes fit without scrolling. The final compact
landscape check keeps a frame thumbnail, Remove Frame and Cancel Reply available
in 44-pixel targets and preserves the text draft.

The release app has 38 files matching built, extracted and installed copies.
Strict signatures and ZIP integrity pass. All six executables are arm64 and
have no Homebrew or /usr/local library links. Source/test/script manifest hashes
match the final tree. Build 34 is preserved at
~/Applications/.Setbeam-before-collaboration-build35.app.

## Remaining verification

Opus round 4 approves all seven implementations for delivery under the recorded
manual qualifications. See [the complete sign-off](reviews/2026-11-10-opus-r4-signoff.md).
Final light and dark native chat/code surfaces are inspected.
[The app, screenshots and sign-off report](https://drive.google.com/drive/folders/10FqDt1tRmt67KqbS6QJcHBbwA2H0Usr0) are delivered privately with remote verification.
Delivery ID: 20261110T223616Z--4f233bb669f5. The final installed app is private with exactly one visible main window.

Simulator interaction is unavailable here. Two isolated iOS 26.5 simulators
booted and received the loopback URL, but this Xcode installation has no
Simulator.app, and T3 device_list returns "Agent device access is turned off for
this environment." No interactive Simulator pass is claimed. The disposable
devices were shut down and removed. Physical iPhone/iPad keyboards, phone association from a QR code,
printed-paper scanning, Retina/notched/secondary displays, full-screen Spaces and
spoken VoiceOver remain separate manual qualification. No new transmitter or
capture-device compatibility is claimed.
