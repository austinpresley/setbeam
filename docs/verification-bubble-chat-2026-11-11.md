# Messages-style session chat, build 37

Austin requested compact Apple-like message bubbles and contextual reply/emoji
reactions across the native Mac app and every browser viewer layout. No media
runtime, receive, encode, capture or pointer source changed. Previous work stays
in the dirty checkout; the task baseline is /tmp/setbeam-before-bubble-chat-20261110.

## Implementation

- Own messages trail; other messages lead. Group only the same author number,
  name and cursor color within five minutes. Keep role/name labels and compact
  sampled images. There is no permanent Like/Reply action row.
- Six fixed reactions, one per participant/message, replaceable or removable,
  capped at 128 participants. The server projects own-message/selected flags.
  Legacy heart likes remain compatible; reactions have a separate bounded rate
  budget so a reaction burst does not consume the message allowance.
- Native right-click palette, hold popover, hover/focus More, combined message
  accessibility actions and one keyboard conversation stop. Copy and private
  operator Remove for Everyone remain available.
- Browser touch hold or short bubble tap, right-click, Enter/ContextMenu/Shift-F10
  use one bounded menu. Roving focus avoids 100 Tab stops. Reactions are radio
  menu items; Escape/Tab dismiss only the menu. Moving/cancelling a pointer
  cancels a pending hold. The trailing click is suppressed after a hold.
- While a menu is open, polling updates checked state in place without auto
  scrolling; visual keyboard resizing repositions it. Touch image callouts and
  dragging are disabled. Images enlarge in a native popover or browser dialog.
- Plain-HTTP Copy tries the synchronous legacy clipboard operation first, then
  secure Clipboard API if available, then a selectable-text dialog. One compact
  composer retains draft/image/reply cancellation. The short encryption/Stop
  notice remains visible with an explicit information control.

## Opus design response

[Opus 5.5 High design review](reviews/2026-11-10-bubble-chat-opus-design.md)
approves the direction with seven required interaction/data refinements. They
are implemented. The native palette initially rendered blank Text-only choices;
using labeled system-symbol choices fixes that native AppKit menu bridge. A
high-priority native hold gesture swallowed short image clicks. It has been
changed to a simultaneous hold with bounded suppression of the following click;
the final light native check passes both a short image click and a hold, with exactly one popover. The hold focuses its actual target and Reply focuses the composer. No test bound was relaxed.

## Local evidence so far

- Seven focused Swift chat/gateway tests pass, including reaction replacement,
  ownership, invalid kinds, the 128-participant cap, replacement at capacity,
  independent post/reaction budgets, admission, Origin and existing frame gates.
- All 59 existing Node recovery/pointer checks pass.
- The updated installed-Chrome collaboration script passes eight layouts, actual
  sample decode, literal text, a heart reaction, replies, image capture and compact
  draft controls. Its first post-refinement attempt tapped the image button when
  intending to open actions; targeting message text for the short-tap path fixes
  the test. Image tapping intentionally opens the image.
- The manual check-chat-interactions.js passes a single roving keyboard stop,
  Enter/Shift-F10, Escape preserving chat, reaction add/replace/remove, selectable
  Copy fallback, image/sample dialog, actual Chrome touch hold on an image without
  an image click, polling retaining menu nodes/focus, viewport resizing and moved
  or cancelled holds. These are browser-engine checks, not physical iOS evidence.
- Mac WKWebView decodes the actual sample and captures a canvas frame in seven
  viewport sizes with retained drafts. Separate check-chat-webkit.swift runs on
  actual HTTP 192.168.1.238 through an owned local relay: isSecureContext is false
  and navigator.clipboard is absent. A real native click on Copy places the exact
  message on the clipboard. The prior clipboard is restored inside the fixture.
  It also passes keyboard/menu roles, viewport resizing and Escape. The relay and
  fixture are stopped afterwards. The LAN copy check does not qualify video over
  that relay; its media-decoding evidence is the separate loopback engine run.
- Native checks pass context-menu Like, accessibility Reply/reaction replacement,
  Cmd-Return sending, hold on an image without its tap, arrow/Return menu opening,
  Escape, Open Image within the same popover, Hold disabling capture while chat
  remains available, and Stop clearing chat while local monitoring continues.
- Actual dark native and phone/tablet/desktop viewer sample captures are inspected.
  Light native is also inspected. Final compact/dense reactions, complete scripts/check.sh, final Opus implementation sign-off and release packaging remain in progress.

Physical iOS press-and-hold/keyboard/VoiceOver and other hardware qualification
remain separate. No hosted CI, commit, push or PR was run.

## Design references

The contextual interaction follows [Apple context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus).
Keyboard roles/navigation use [W3C menu-button guidance](https://www.w3.org/WAI/ARIA/apg/patterns/menu-button/).
The gesture cancels on the browser's [pointer cancellation](https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events) path without disabling scrolling.


Additional safeguards: asynchronous clipboard fallback is cancelled if chat
closes, admission ends, or the message disappears; a removed message closes its
selectable Copy view. The draft grows from one line up to a bounded height.
Native reaction chips collapse after three kinds with an all-reaction palette
summary, while browser chips wrap. These refinements are undergoing the final
engine and compact-size regression pass.


## Round-2 response and refreshed evidence

The touch-move handler now uses the same ten-pixel threshold as the hold timer.
The final real Chrome touch sequence moves three pixels after the menu opens
and before release; it passes without dismissing or opening the image. The
refreshed verified-interactions report passes fourteen scenarios, including
resuming at-end following after new posts and restoring a neighbouring message
when the operator removes the target of an open Copy dialog. The delayed-Copy
closure race and the selectable fallback also pass.

verified-browser covers all eight layouts; verified-webkit decodes/captures the
sample and retains drafts at seven sizes. verified-webkit-chat repeats the
trusted native Copy click on an insecure LAN origin with no Clipboard API and
exact clipboard output. verified-assets.json confirms the running browser
assets match current sources byte for byte.

With Full Keyboard Access off, native conversation Tab/Return opens actions;
keys 1-6 select/toggle reactions, R focuses Reply, I opens the image and Shift-D
removes for everyone. These actions were exercised through native computer use;
native-keyboard-proof.json records them and the app itself reports the system
keyboard-access setting. The palette uses these explicit keys with the default
Mac setting. Arrow/Return selection *inside* that palette is not claimed; the
old hint was removed. Conversation arrow navigation and Return entry remain.
The right-click palette now uses cached rasterized emoji matching the chips,
with one None choice and no duplicate Remove Reaction row.

Fresh shipping-showcase and shipping-light-showcase captures cover the actual
phone orientations, both iPad orientations, desktop and touch menu. Fresh
native-shipping and native-shipping-light captures show both native appearances
without initial focus. Dense six-kind reactions and compact reply/image drafts
fit a 320-point panel in a 961x472 window; earlier captures document that layout
and the updated keyboard code does not change those resting dimensions.
Final source hashes are in final-review-inputs.json. The complete isolated check
and final Opus gate remain pending.


## Shipping-code native and density evidence

The final native-shipping.png and native-shipping-light.png captures use the
shipping binary. shipping-showcase and shipping-light-showcase are fresh actual
viewer captures of that bundle. native-emoji-context-final.png shows the cached
color emoji menu, including only one None choice. The final native-dense-final
and native-dense-draft-final captures use the same shipping binary in a 961x472
window with six real admitted HTTP reaction participants. All six reaction kinds
fit via three chips plus an expander; the reply/image cancellation and Send stay
on screen together.

The native default-setting check selected reactions with 2, Reply with R, image
with I, and operator removal with Shift-D. fullKeyboardAccess is false in the
app's own experience output. The native palette deliberately uses these explicit
hotkeys, not arrow/Return selection inside the palette; its hint lists those hotkeys. Conversation arrow navigation and Return still open it.

All owned QA apps, the HTTP relay, engine fixtures and the private installed
build are closed. The complete scripts/check.sh is now running alone against
the final bundled tools/fixtures. No app source changes are planned while it runs.
The current fourteen scoped file hashes are frozen in final-review-inputs.json.


## Final full check

The complete isolated scripts/check.sh exits 0 with 282 Swift tests (3 Probe,
163 Core, 116 App), five Python cases, 59 Node browser/pointer checks and all
media stages passing. The 1,749 KB keyframe stage decodes 499 frames in seven
seconds without errors. Log: /tmp/setbeam-bubbles-full-check.log. All fourteen
scoped source hashes remain unchanged through that run. There was no failure
or stage retry in this full run, and no test expectation or timeout changed.

Opus round 3 approves the code/design and all must-fix responses, with only the
full-check/package gate remaining. The final package contains 38 files and 168
source inputs; six arm64 executables pass strict signatures and no-Homebrew-link
audits. Private installation and archive verification are complete.

Non-blocking follow-ups remain explicitly separate: native palette Command-C
is implemented but was not part of the observed 2/R/I/Shift-D proof; visible
hotkey tooltips and retaining the reply target in a growing minimum-size draft
are future polish. No popup arrow/Return selection is claimed. The palette hint
lists its actual hotkeys. Physical iOS/Simulator/spoken VoiceOver remain manual.


## Archive and installed verification

ZIP SHA-256: c55dc9ebd57b40aae3b41cef92a5ed9aa18c6bc5a0c274562d3581fc8e99d4e2. ZIP integrity, strict extracted
signatures and all 38 built/extracted/installed app hashes match. The 168 source
inputs match the frozen tree. Build 37 is installed at
/Users/apresley/Applications/Setbeam.app; build 36 is preserved at
/Users/apresley/Applications/.Setbeam-before-messages-build37.app. Native launch
restores Austin's saved CineView Master 4K setup privately, with Start Sharing
disabled while the transmitter is absent. The actual running process has exactly
one main window and one visible main window. No QA sharing session remains.


## Final approval and delivery

[Opus 5.5 High round 4](reviews/2026-11-11-bubble-chat-opus-signoff.md) approves
build 37 delivery with no blockers after recomputing the source/archive hashes
and checking the completed full log and installed state.

[App, current screenshots and final report](https://drive.google.com/drive/folders/1noTTii9VoUxeLuRXxkVTZPAAtFyydRCi) are delivered privately
through Austin Deliveries with remote verification. Delivery ID:
20261111T065117Z--dd8096a9edeb. The app remains private with exactly one visible main window and
Austin's saved source. The previous installed build remains available locally.

The inline screenshot comparison is checked at 728 and 360 pixels with working
disclosures. Source code is unchanged after sign-off. No hosted CI, commit, push
or PR ran. Physical iOS, Simulator, spoken VoiceOver and the explicitly listed
non-blocking follow-ups remain separate qualification.
