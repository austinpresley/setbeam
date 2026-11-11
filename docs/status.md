# Setbeam status

## Design audit and mockups, 2026-11-11

The [current design audit](../design/audits/2026-11-11-current/Setbeam-design-audit.html)
records six findings and five interactive HTML proposals. Highest priority is
one actionable recovery block and visible physical-test limits on wireless
cards. Medium priorities are content-sized source selection, visible outgoing
picture/audio facts, clearer Sharing Options, and a compact phone composer.
The approved picture-first and minimal floating-preview direction is retained.

Evidence combines installed build 38 observation, current UI source, build 37
native/browser captures, and explicitly labeled older source-chooser history.
Nine proposal images cover light/dark Mac appearances and the phone. Local HTML
checks confirm source-category switching, admission/playback separation,
options disclosures and staged drafts, a 54 px phone composer with 44 px capture
target, and all five report tabs, embedded images and themes at 390 px without
horizontal overflow. T3 browser snapshots timed out twice; visual/prototype
verification used its HTML renderer. These are design checks, not native UI or
physical-device qualification. No build or scripts/check.sh was run for
this design-only work. All 172 source, test and script baseline hashes are
unchanged. Implementation remains future work. Verification details are in
`design/audits/2026-11-11-current/verification.json`.
The [report, five preview images and complete mockup bundle](https://drive.google.com/drive/folders/11bIWF9VMWJCEEndRURwtudxI8Uu-SDZN)
are delivered privately with remote verification.

## Memory fix, build 38, 2026-11-11

Austin reported about 75 GB of RAM during whole-monitor sharing to an iPad and
phone on the GitHub version. VideoPipeWriter retained consumed Data backing
storage across append/drain cycles despite an empty pending count. The same
implementation is in public build 20. The writer now releases drained storage
and copies only unsent tails. Accsoon control output receives the same storage
correction. Native preview buffers have an eight-buffer ceiling across formats
and decoder recovery; hidden/closed monitor layers release queued pictures.

The focused writer regression fails before the fix at 193 MiB growth. Afterward
it sends 79.35 GiB with less than 1 MiB growth. Five preview regressions pass.
Two ten-minute runs pass with real display capture and a generated 4K relay,
each with simultaneous decoded phone/tablet Chrome viewers and Hold/Resume,
hidden/restored previews and Stop preserving monitoring. Display memory peaks
at 57.2 MiB instead of growing to 182.2 MiB; 4K peaks at 842.3 MiB and ends
below its early mean. Initial 4K warm-up measurement failures are retained in
[the investigation record](verification-memory-2026-11-11.md).

Build 38 is installed; all 38 app files match the verified package. Six arm64
executables pass strict signatures and system-library-only audits. The complete
local check passes 290 Swift tests, with one opt-in soak skipped by default,
five Python cases, 59 Node checks and all media integration stages. Its large
keyframe stage decodes 500 frames in seven seconds without errors. Native
light/dark main and floating pictures, Hold/Resume, floating close/reopen and
Stop preserving monitoring pass; normal Quit removes all 11 owned processes.
The [app and investigation report](https://drive.google.com/drive/folders/1DpS5rIvEQgU8NewqaGs0x2E9VDRKklPW)
are delivered privately with remote verification. Normal installed startup is
confirmed Private with the saved CineView setup. Build 37 is preserved at
`~/Applications/.Setbeam-before-memory-build38.app`. No hosted CI or GitHub
publication ran. Physical iOS and transmitter endurance
remain separate qualification; no hardware compatibility claim changed.

## Messages-style chat, build 37, 2026-11-11

Austin requested compact Apple-like bubbles and contextual reactions in every
view. Native Mac and browser phone/tablet/desktop chat now use grouped bubbles,
compact image attachments and no Like/Reply row at rest. Six reactions support
add/replace/remove with bounded per-participant state. Auth, media, Hold and Stop
remain unchanged. Native and browser context menus, touch hold/tap, keyboard and
accessibility paths remain available.

Opus design and round-2 findings are addressed. Fresh Chrome touch-drift, Copy
race/fallback, polling, auto-follow and deletion-focus checks pass. Mac WebKit
passes seven decoded/canvas layouts and a trusted exact Copy on insecure HTTP
LAN with no Clipboard API. Native default-keyboard hotkeys, colored emoji menu,
light/dark, dense six-reaction and compact reply/image controls are inspected.
All sample apps and relays were closed for the complete local check. It passes
282 Swift tests, 5 Python cases, 59 browser/pointer checks and every media stage,
including 499 decoded large-keyframe frames in seven seconds without errors.
Opus round 3 approves code/design with no blockers. Build 37 is installed
privately with exactly one main window. All 38 built/extracted/installed files
and 168 source inputs match; strict signatures, ZIP and six arm64/no-Homebrew-link
audits pass. [Opus 5.5 High final sign-off](reviews/2026-11-11-bubble-chat-opus-signoff.md)
approves delivery with no blockers. [App and current Mac/phone/tablet/desktop
screenshots](https://drive.google.com/drive/folders/1noTTii9VoUxeLuRXxkVTZPAAtFyydRCi) are delivered privately with remote verification.
The installed app opens privately with the saved source; build 36 is preserved
at ~/Applications/.Setbeam-before-messages-build37.app. Real iOS, Simulator and
spoken VoiceOver stay separate qualification. See
[build 37 evidence](verification-bubble-chat-2026-11-11.md).

## Single picture and native chat polish, build 36, 2026-11-10

Austin requested one media picture and cleaner chat. Sharing no longer repeats
its live thumbnail in either presentation. Native chat uses aligned rows,
compact images that enlarge on request, quiet message actions and one composer.
Outgoing picture/audio facts remain in status help and accessibility. Disabled
capture explains its reason, and the draft has a subtle keyboard-focus border.
Light/dark, compact reply/image drafts, separate-window initial focus, Hold and
Stop are inspected. Chat stays bounded and media ownership is unchanged.

[Opus 5.5 High round 3](reviews/2026-11-10-chat-polish-opus-signoff.md) approves
delivery with no blockers. The complete isolated check exits
0 with 279 Swift tests, 5 Python cases, 59 browser/pointer checks and all media
stages passing. Its 1,749 KB keyframe stage decodes 505 frames in seven seconds
without errors. The first run passed recovery then failed viewer-access startup
with `The video service could not start` while QA media was also running. The
isolated pass does not diagnose that first failure. No expectation or timeout
was changed. All six executables pass arm64/no-Homebrew-link/signature audits;
all 165 source inputs and 38 staged app files match. Build 36 is installed and freshly confirmed private with exactly one visible
main window. [App, light/dark screenshots and Opus sign-off](https://drive.google.com/drive/folders/1XWm0Wm_Aifdrx28gsbKjbuVeYckYEjdm) are delivered privately with remote verification.
Build 35 is preserved at ~/Applications/.Setbeam-before-chat-polish-build36.app.
Hardware, real iOS and spoken VoiceOver remain separate qualification. See
[build 36 evidence](verification-chat-polish-2026-11-10.md).

Current viewer-link phone/desktop captures are [delivered separately](https://drive.google.com/drive/folders/1NelaNCelwAnVxnqvbPEmrbTF2S53fMIj).
They show the existing browser chat; the build-36 polish above is native Mac
presentation only. These are Chrome viewport captures, not physical iOS tests.

## Collaboration and entry points, build 35, 2026-11-10

Version 0.2.0 build 35 is installed. S-011 through S-017 add shared-display
pointers for This Mac's screen, viewing Wi-Fi selection with honest password
checks, phone/tablet layouts, admitted session chat with replies/likes/images and
DigiTech moderation, independent floating/printable join codes, app reopening and
a focused menu bar. Viewer media access stays read-only; chat and images are
bounded in memory. Hold closes frame attachments immediately and Stop clears
collaboration while preserving monitoring. Physical password tests use a phone;
the editor never joins a network.

Opus 5.5 High round 3 found no code blockers and approved five items, requesting
extra viewport and cold-launch evidence for the remaining two. The additional
checks now pass. [Opus round 4](reviews/2026-11-10-opus-r4-signoff.md) approves all seven implementations for this developer build, with the recorded manual qualifications. The complete local scripts/check.sh
passes 279 Swift tests, 5 Python cases, 59 browser/pointer checks and all media
stages. Its 1,749 KB keyframe stage decodes 497 frames in seven seconds without
errors. Final Swift and focused UI/PDF/reopen checks pass, as does the release
probe using the packaged helpers and fixtures. The manually run engine checks
pass 8 Chrome and 7 macOS WKWebView sizes with real sample decoding, canvas
capture, draft retention and compact attachment/reply controls.

Controlled display checks show a named pointer on screen, no red pointer pixels
in the corresponding actual outgoing frame, click-through and typing, Hold
removal and Stop cleanup. PDF decoding recovers both exact QR payloads. Native
Print preview contains the codes. Reopen checks cover a closed/minimized main,
floating preview, detached Sharing and cold launch after quitting with the main
closed. Exactly one main window opens and sharing stays off. Literal Dock and
Spotlight UI are unavailable to this environment's automation; the common
Launch Services reopen callback is tested.

All 38 built, extracted and installed app files match. Strict signatures, ZIP
integrity and six arm64/no-Homebrew-link executable audits pass. The previous
installed app is preserved at ~/Applications/.Setbeam-before-collaboration-build35.app.
Final light/dark native chat and QR reference captures are inspected and readable. Opus sign-off is complete. [The app, screenshots and sign-off report](https://drive.google.com/drive/folders/10FqDt1tRmt67KqbS6QJcHBbwA2H0Usr0) are delivered privately with remote verification. The installed app is freshly confirmed private with exactly one visible main window.
No hosted CI, Git commit, push or PR ran. Real iOS/Safari/keyboard, phone Wi-Fi
association, paper scans, additional display configurations and spoken VoiceOver
remain separate qualification. Simulator interaction is unavailable because the
GUI is absent and T3 device access is disabled. See
[build 35 evidence](verification-collaboration-2026-11-10.md).

Previous installed checkpoint follows.

Updated: 2026-11-08. Version 0.2.0 build 34 is installed and open privately.
The reviewed design refinements keep native control sizes, use viewer-selected
circle colors, and make both QR codes clickable with a clear Enlarge Codes action.

## Design refinement, build 34

Main commands, menus and outgoing summaries use observed output plus pending or
failed Hold/Resume targets. Failures retry the intended change without claiming
confirmed picture suppression or silence. One Sharing detail home retains its
last tab and actual outgoing preview. The permanent monitor heading, duplicate
docked Start action and broad gear are removed. The independent Sharing window
has essential commands. Incoming guidance uses audience state and the input
binding. The approved floating geometry and all 39 media/probe/supervisor source
files remain unchanged.

Pending and joined circles follow each viewer's chosen color, including an
admitted color change; tooltip/AX names the color. All twelve choices pass the
ledger projection check. Actual Chrome/native checks retain the same media peer
while teal becomes lime, with a pink pending request beside it. The circles are
labels, not verified identities or playback proof.

Click either small QR or Enlarge Codes to open codes up to 320 points. Native
light/dark code payloads decode identically at both sizes. Browser sound stays
in the header, while secondary controls disclose without reserving picture
height or hiding focused controls. A first-click focus/click regression is
reproduced and fixed before final verification.

The complete packaged scripts/check.sh passes in 661.136 seconds with unchanged
inputs: 270 Swift tests, 5 Python cases, 58 browser/pointer checks and all media
stages. The 1,749 KB keyframe stage decodes 499 frames in seven seconds without
decoder errors. Native and actual Chrome flows pass in both appearances for
individual colors, QR enlargement, target-specific failed Hold/Resume, detached
commands, Resume and Stop preserving monitoring. Incoming ready-state UI is
covered by regression tests; its extra saved-key native fixture reaches macOS
Keychain authorization and is not a native pass. Required incoming waiting
steps are visually inspected in both appearances. Physical/manual qualification
remains separate.

All 37 built, extracted and installed app files match. Strict signatures, ZIP
integrity and six arm64/system-library-only executable audits pass. Build 33 is
preserved at `~/Applications/.Setbeam-before-design-build34.app`. The installed
build 34 is freshly confirmed private with no sheet. No hosted CI, commit,
push or PR ran. See [build 34 evidence](verification-design-implementation-2026-11-08.md)
and [download the app and screenshots](https://drive.google.com/drive/folders/1LrrJ6zCsSfImFJLplRC5Jz78xL334jSQ).
Private delivery completed with remote verification.

## Three-round design audit, 2026-11-07

Three sequential GPT-6.1 Sol xhigh critics reviewed the current UI, then each
preceding critique and ImageGen proposal against the approved design standard.
The [cumulative findings](../design/audits/2026-11-07-three-rounds/final-findings.md)
retain seven findings: one High, five Medium and one Low. Ten design judgments
and eight untested obligations remain separate. Audience Hold/Resume intent can
be presented as confirmed output; incoming setup has two source-derived copy
conditions to correct. Repeated commands and permanent secondary chrome are
lower priorities. No outgoing source leak or new hardware result is established.

All three reports, exact prompts, generated concepts and a comparison are in
`design/audits/2026-11-07-three-rounds/`. Final read-only verification matches
all 84 source entries in the retained build-33 manifest. No app code, build,
runtime test or live session changed. Concepts still approximate frame aspect
and floating geometry; native constants remain authoritative. Implementation
and the recorded behavioral/manual checks remain future work.
[Reports and all three concept images](https://drive.google.com/drive/folders/1WWFDpjXK8z3qda_HE-RcwNWnFFj8FLfC)
are delivered privately with remote verification.

## Floating preview refinement, build 33

The on-picture sample caption is removed. Sample identification stays in the
main window, floating accessibility label and tooltip. Confirmed Hold uses a
22% black veil with restrained desaturation and a dark centered Play control.
Recovery messages use the same placement for sample and other sources. The
design standard, guide and native reference images now describe this direction.

The dark interaction matrix passes all 16 checks. Light appearance passes Hold,
Resume, Stop, private monitoring, viewer actions and the sample AX label. Scoped
source loss/return confirms recovery layout at 220 and 340 points. Opus round 2
approves after fixing recovery spacing and updating the references.

The complete packaged `scripts/check.sh` rerun passes in 647.685 seconds with
unchanged inputs: 262 Swift tests, 5 Python cases, 55 viewer/pointer checks and
all media stages. The 1,749 KB keyframe check decoded 497 frames in seven seconds
without decoder errors. The first attempt failed on a generated live-frame
duration of 116,411 microseconds, over the existing 100,000 limit. That evidence
remains for follow-up; no test or threshold was changed. The successful rerun
does not establish the cause of the initial timing result.

All 37 built, extracted and installed app files match. Strict signatures and
six arm64/system-library-only executable audits pass. Receive, bridge, encode,
probe and supervisor source is unchanged. Build 32 is preserved at
`~/Applications/.Setbeam-before-preview-build33.app`. Private delivery completed
with remote verification. No hosted CI, commit, push or PR ran. Physical hardware,
real Capture One, audible output, spoken VoiceOver, trackpad pinch and older
macOS remain separate qualification. See
[build 33 evidence](verification-preview-refinement-build33-2026-11-06.md).

## Minimal floating preview, build 32

The floating picture has centered Hold/Resume, a confirmed-state light wash,
hover Close, and a small viewer/request shortcut. It has no footer, source name,
More, sound or Fit controls. The durable standard is
[design-standard.md](design-standard.md), with safe native reference images.

Actual outgoing readiness confirms the wash. Failures retry their intended
Hold/Resume target. Guarded pointer Resume cannot be released by a second click,
a boundary-crossing picture gesture or Close. Native key-view navigation works
without pointer operations taking the working app's keystrokes. Individual
viewer decisions revalidate viewing link, session, join time and admission.

Dark and light native checks cover rest/hover, pending transitions, real encoder
failure/retry, keyboard entry and return, gesture guards, minimum size and
private monitoring. A generated portrait source passes loss/return with Hold
and the viewing identity preserved. A real browser decodes actual video/audio,
follows Hold/Resume and the portrait format change, and ends its media on
individual removal. Stop leaves local monitoring live. White-document viewer
control contrast passes at 5.94:1. These are local software/runtime results.

Both Opus 5.5 high round-2 reviews approve, with no blocking findings. The full
`scripts/check.sh` run passes with packaged helpers/fixtures and unchanged source
inputs. Its 1,749 KB keyframe probe decoded 489 frames in seven seconds without
decoder errors. No runtime/bridge/probe/supervisor source changed for this task.

All 37 built, extracted and installed app files match. Strict signatures pass;
six executables are arm64 and link only system libraries. The ZIP includes
build notes, app hashes and a 161-input source manifest. Build 31 is preserved at
`~/Applications/.Setbeam-before-minimal-build32.app`. No hosted CI, commit, push
or PR ran. Physical hardware, real Capture One, audible output, spoken VoiceOver,
trackpad pinch and older macOS remain separate qualification. See
[implementation evidence](verification-minimal-preview-build32-2026-11-06.md).

## Minimal floating preview revision, 2026-11-06

Austin requested a simpler picture-first design. This revision removes both
bottom rows, source names, text status, separate Resume, More, sound and Fit.
Hover offers Hold and Close. A confirmed Hold adds a light wash and a persistent
centered play button to resume; a small viewer/request shortcut remains useful.
Opus 5.5 high endorsed this direction with refinements. No numerical rating was
assigned to the revision.

Twenty-one simulated interaction/geometry checks and rest/hover/compact HTML
renders pass. The app is unchanged; native implementation and qualification
remain. See [minimal preview design evidence](verification-floating-preview-minimal-2026-11-06.md).
The rest/hover images, interactive prototype and design notes are
[delivered privately](https://drive.google.com/drive/folders/1l8JngDCpIxhlXSx-oNuGuFjM4hpaBzh-).

## Floating preview design study, 2026-11-06

Superseded by Austin's minimal revision above. The earlier proposal and review
history remain as evidence, not the current design direction.

Austin requested a back-and-forth design debate with Claude Opus 5.5 at high
effort and a comparison with the current preview. Four review rounds reached
an explicit 10/10 design approval, shared by Sol. One attached 48-point bar
separates local picture/zoom/sound from audience state/requests/Hold, retaining
the 220-point minimum. No controls cover the picture or move on hover. Pending
or failed commands retain confirmed audience truth; pointer interactions must
leave the working app's keyboard focus alone.

The study passes 48 browser geometry combinations and standalone SwiftUI font
and layout renders at 1×/2×, including a synthetic dark source. These are design
checks. Native focus, accessibility, runtime commands and real-source behavior
remain unimplemented and unqualified for the proposal. Production app source
and the installed build are unchanged. The comparison, interactive prototype and
design notes are [delivered privately](https://drive.google.com/drive/folders/1gFCl1L81Yv2_ePZvJeDNg10rZ2Ztz_JH).
See [floating preview design evidence](verification-floating-preview-design-2026-11-06.md).

## Approved design refinement, build 31, 2026-11-05

Austin approved the combined Sol/Opus 5.5 high design proposal and three ImageGen
concepts, then requested implementation. Local monitoring has a dark surround
in both appearances. Labeled sharing controls sit above the picture. Sharing
keeps its outgoing preview above Invite, Viewers and Options, including in its
separate window. Invitations have an inline Wi-Fi editor, nearby link copying
and an IP fallback disclosure. The source chooser has larger complete window
previews, one card outline, a pinned last connection and a source-switch Hold
explanation. Source categories, individual admission and media behavior remain.

Both appearances pass native and real-browser checks for private restoration,
draft retention, admission, persistent outgoing status, compact controls,
source identity, automatic source-switch Hold, Resume, Stop, QR decoding and
floating monitoring. Selecting the current source preserves owned media
process IDs. All 29 added spatial values pass the grid check. The full packaged
check passed in 645.493 seconds with unchanged implementation inputs. It
decoded 503 frames in seven seconds from 1,749 KB keyframes without errors.
Its first attempt failed the unchanged startup duration bound at 116.778 ms;
both results are recorded. No runtime code or check limit changed.

Build 31 is installed and open at `~/Applications/Setbeam.app`, with the previous
installed build 29 preserved at `~/Applications/.Setbeam-before-design-build31.app`.
All 37 built, installed and extracted app files match, strict signatures pass,
and six arm64 executables link only system libraries. The app ZIP and three
native screenshots are delivered privately. No hosted CI, commit, push or PR
ran. Physical hardware, audible output, spoken VoiceOver and older macOS remain
separate qualification. See [design refinement verification](verification-design-refinement-2026-11-05.md).

## Suite reliability, build 30, 2026-11-04

Austin requested fixes for the complete-run timing and port-reuse failures. A repeated-handoff regression reproduced an asynchronous Network.framework socket-release race. The listener now gives that release a bounded one-second grace, keeps endpoint reuse disabled, and cancels stale retries by attempt. Two hundred immediate handoffs with real HTTP requests pass; an occupied port still belongs exclusively to its other owner.

The preview helper no longer mistakes the 90 kHz RTP clock for a frame rate and emits a reasonable initial duration. Tests preserve real RTCP clock alignment in either direction and require later positive durations to match source PTS. Cadence checks read completed-decode reorder depth, exclude the finite B-frame flush tail and account for measured fixture jitter; missing interior frames still fail. No source timestamps or encoder cadence settings were rewritten.

The first full local check passed in 645.4 seconds. A packaged check then caught an overly strict new assertion on a valid 322-microsecond positive alignment interval; five deterministic cases now cover that distinction. The final complete check passed in 643.967 seconds against the build-30 bundled helpers and fixtures, with no stage retries or skips. It decoded 498 frames in seven seconds from 1,749 KB keyframes without errors. Strict signatures, six arm64/system-only executables, all 37 app files and 155 source inputs are verified. Build 30 is delivered as a developer ZIP; the existing installed instance was left running. Physical qualification remains separate. See [suite reliability verification](verification-suite-reliability-2026-11-04.md).


## Organization and sharing panel, build 29, 2026-11-04

Austin approved the organization mockups and requested implementation, harsh Opus 5.5 critique, fixes, and a demonstration. The optional Sharing panel has Invite, Viewers, and Options; it can detach into a separate window while the source form remains open. Source Details stages its edits for Save/Cancel. Stream entry is direct. Settings owns permissions and diagnostics. Menus use Source, Monitor, Sharing, and Help. Browser identity editing keeps the same media peer and uses page flow on narrow screens. The runtime, source identity and physical hardware evidence are unchanged.

Opus round 1 returned CHANGES with four must and fifteen should findings, plus polish. The revisions include consistent staged source settings, preserved drafts and gated presentations/source return, native close/focus handling, compact outgoing status, clearer dependencies, a full-height inspector, side-by-side large codes, explicit saved-setup status, corrected navigation/accessibility text and natural-flow phone identity editing. Opus approved round 4 and the final caption polish. No core/probe source or test threshold changed.

All 241 Swift tests passed in the round-3 complete run; a later final run again timed out in the existing short-address port-reuse case, while all 88 app tests passed. That focused test passed unchanged afterward. All 55 browser/pointer checks pass. The packaged codec/format transitions, frame-rate and 1,749 KB keyframe probes pass, the latter decoding 509 frames in seven seconds without decoder errors. Earlier whole-script attempts also hit the unchanged preview startup duration assertion and the previously documented 50.067 ms live cadence limit. Those complete runs are failures, not full passes. Native and browser checks cover the actual card Review action, unsaved source retention, title-bar close/reopen, network fallback/recovery, saved setup, and one real browser with three synthetic waiting requests. Physical devices, spoken VoiceOver, audible output and older macOS remain separate qualification. See [organization verification](verification-organization-2026-11-04.md).

Build 29 is installed at `~/Applications/Setbeam.app`; build 28 is preserved at `~/Applications/.Setbeam-before-organization-build29.app`. All 37 installed files match the packaged candidate and strict signatures pass. Six executables are arm64 and link only system libraries. No commit, push, PR or hosted workflow ran.

Earlier dated entries below retain the menu names used by those builds. Current navigation is described above and in getting-started.md.

## Approved source chooser layout, build 28, 2026-11-04

Austin approved the ImageGen concept and requested implementation. Last connected is pinned above a native sidebar with Displays, Cameras & capture, Application windows, and Wireless transmitters. Windows have app/name search, app icons and counts, two equal-height cards, and stable secondary numbers for blank or duplicate labels. Current source closes without restarting. Availability names missing inputs and permissions; a saved capture setup requires its exact video and sound inputs and the relevant Camera/Microphone access. Enter stream address opens the expanded existing form. Wi-Fi Settings is in the wireless category and guides. Hidden categories retain window identities without taking unused previews.

A clean full local run passed 224 Swift tests. Sol found a false Available state when a saved sound input was missing or microphone access denied. The two regressions failed on the old algorithm and all 17 focused tests pass after the fix; Sol approved in round 2 on high, with no remaining findings. Native light/dark checks used two fixture apps and eight windows, covered search, exact private selection/restoration, category keyboard navigation, hidden/ended owners, guides and the stream form. Actual-frame checks confirm four complete equal-height cards and pinned navigation without clipping.

The broad script passed its earlier stages, then failed the unchanged format-cadence assertion; packaged retries also failed at 60 fps with a 33.333 ms maximum interval and 30 fps with a 50.066 ms maximum interval. Those failures are recorded rather than reported as a full pass. All nine packaged frame-rate checks and the large-keyframe probe passed, the latter decoding 506 frames without errors from 1,750 KB keyframes. A separate Swift run exited on SIGPIPE in unchanged core tests; its clean rerun passed. The full failure history and physical/permission/VoiceOver limits are in [approved chooser verification](verification-source-chooser-layout-2026-11-04.md).

The installed, archived and built app match across all 37 files, with strict signatures, ZIP integrity, system-only dependencies and 138 source hashes checked. The previous app is preserved. No commit, push, PR or hosted workflow ran. Private Austin Deliveries upload completed with remote verification. [Open build 28 delivery](https://drive.google.com/drive/folders/1NHFIm00Ek1aRExmtpZyZJ2tBzbgckVch).

## Source chooser, build 27, 2026-11-04

Austin requested the last confirmed source first, a cleaner section name, separate source categories, app groups with larger icons, fewer repeated labels, and application names for untitled windows. The chooser now starts with Recent source, followed by Displays, Cameras, Application windows, and Wireless transmitters. It omits sample choices, including a saved sample. Application groups have a 40 pt icon and one app name, cards retain their own window titles, and only the current window has a status caption. Blank and generic Untitled labels use the application name. Exact source identities, private restore, existing guides, and media flow are preserved.

All 217 Swift tests pass, including new grouping and title cases. Native light/dark fixture checks verified actual selection, picture confirmation, Recent source order, exact private restoration, the transmitter guide, keyboard opening and dismissal, and rendered layout geometry. Two earlier runs stopped at an old label expectation before the actual indexed assertion was corrected. GPT-6.1 Sol on high approved the seven-file task patch in one round with no findings; no behavior changed after approval. The full script stopped at the previously documented 50.067 ms cadence assertion in unchanged media code; the format probe passed unchanged against packaged helpers, followed by the remaining frame-rate and keyframe probes. The latter decoded 509 frames in seven seconds with no errors from 1,750 KB keyframes. The installed app matches all 37 packaged files, with strict signatures and archive integrity verified; the previous app is preserved. Private Austin Deliveries upload completed with remote verification. [Open build 27 delivery](https://drive.google.com/drive/folders/15bC6ys8rOHxqxAj9mMzpSii2TnlpOLsQ). Physical hardware and spoken VoiceOver qualification remain separate. See [source chooser verification](verification-source-chooser-2026-11-04.md).

## Short address and join request card, build 26, 2026-11-03

Viewers on the same network can now type only the local address, such as `setbeam.local`, choose their name and color, and ask to join, when the operator turns on Advanced > Viewer network > Let viewers ask from setbeam.local. The option is off by default. It works only while sharing, with Ask before viewers join, the local address, and a viewing network other devices can join. Each request waits for Admit.

- A wildcard IPv4 port-80 listener answers only connections to the viewing address, and only the active name or that address as `Host`. It redirects `GET /` to a separate ask-only code on the gateway. That code is never the link's code, which is also the shared media password.
- Port 80 in use, refused, or unavailable is named in Settings and the join sheet with the link or QR code as the fallback, and retried.
- Turning approval or the option off declines typed requests still waiting and never admits them. Stop retires the typed path with the link, and local monitoring continues.
- Every new request, from the link or the name, shows Setbeam's own corner card with Admit and Decline. It floats over other apps and the floating preview without taking focus. Requests are announced once and stale actions do nothing. They stay in the sharing bar, Picture and Viewers, the floating preview's controls, the menu bar, Feed > Show Join Requests, and the Dock badge.
- macOS notifications were not used, because they need a permission that can be denied or silenced. The card needs none.

The final `scripts/check.sh` passed: 214 Swift tests, 43 viewer and 12 pointer checks, and 60 probe PASS lines, including 8 from the new real-media `--short-address-test` on the real port 80. Its first run stopped at the known intermittent preview-bridge assertion in unchanged code; the second passed unchanged. The initial implementation check before review passed 209 Swift tests. An earlier `swift test` run failed only on a unit test that checked the old unavailable-page sentence. The test was updated with the new copy.

Isolated QA on this Mac used Ethernet and `setbeam-qa.local`:

- A real browser typed the name, asked, and played 1280×720 after one real click on Admit while Finder stayed frontmost.
- Native captures cover four requests, a dismissed card, answers given elsewhere, approval off, port 80 held by another process (recovered within 10 s), and Stop, in dark and light.
- T3 snapshots timed out again, so headless Chrome took the desktop browser capture.

Not covered: phones, other devices, multicast-blocking networks, or a real port-80 owner on set. A first click on the card's close button once did not reach the card while Calendar became frontmost, which was probably a system banner in the same corner (not confirmed). Evidence, the notification rationale, and limits are in [short address verification](verification-short-address-2026-11-03.md).

GPT-6.1 Sol round 1 (Standards and Spec, xhigh) withheld approval. Both reviewers found that a request already being read when the viewing address moved still got the redirect. Standards also found these problems:

- 3.23:1 white-on-accent buttons
- headers above 4 KB accepted across packets
- truncated text without tooltips
- no hover state
- duplicated probe helpers

All six are fixed:

- A moved address cancels open requests, and each reply rechecks the destination.
- Headers are bounded at 4 KB in total and get `431` past it.
- The card's buttons use an accent-derived palette at 7:1, and hover or press never lowers it.
- Tooltips show while another app is in front.
- The probe helpers are shared.

Regression tests failed on the r1 code and pass now. Native QA measured the buttons from captures in light and dark, at rest, on hover, and pressed. Admit is now at least 5.40:1 even read through the display profile; r1 was 3.23:1. Evidence and the review ledger are in [short address verification](verification-short-address-2026-11-03.md#review-round-1).

Both GPT-6.1 Sol round 2 passes approved with no actionable remaining findings. Standards independently passed 20 focused Swift tests and 55 viewer/pointer checks; Spec passed 32 focused Swift tests, the same browser checks, and 40 real-socket lifecycle cases. The only build-input change after approval is `CFBundleVersion` from 25 to 26. With signatures removed, the rebuilt executable is byte-identical to the reviewed candidate. Build 26 is installed at `~/Applications/Setbeam.app`; build 25 is preserved at `~/Applications/.Setbeam-before-short-address-build26.app`. The archive, fresh build, and installation match across all 37 app files, strict signatures pass, and all 140 source-input hashes match this checkout. Final packaged-runtime checks against the installed app passed: 7 access, 10 local-address, and 8 short-address checks. Private Austin Deliveries upload completed with remote verification under Setbeam / Short address. The receipt and link are recorded in [short address verification](verification-short-address-2026-11-03.md). No commit, push, PR or hosted workflow ran.

## Viewer identity, pointer view, transmitter setup, and permissions, build 25, 2026-11-03

A new browser tab now chooses one name and one of twelve colors before it plays, with approval on or off. That identity labels the operator's viewer row and the viewer's shared pointer. Connection help and the pointer panel reuse it through one editor and no longer have their own name fields. Ask to join, restored passes, fixed names under approval, no request on reload, and removed or expired links behave as before. Turning approval off while the form is open now keeps the card until the viewer presses Join. The operator's new Show pointers on this Mac toggle draws pointers on the main and floating monitors. It is off by default, never saved, resets at Stop, and is separate from Viewers can point. Choose a source always shows CineView Master 4K and Pyro H model cards with guided setup. The SEE bridge moved from Advanced into the CineView guide. A first-run Permissions sheet explains access for the chosen sources and asks only from an Allow button. Bare `setbeam.local` cannot open the feed: nothing listens on port 80, an unprivileged bind to port 80 succeeds only on the wildcard address on this macOS 27 build, and the link's private code is required. The UI now says so. An opt-in, approval-only short address is recorded as a decision for Austin.

The final `scripts/check.sh` passed on its first run: 194 Swift tests (5 new), 43 viewer and 12 pointer checks, and 52 probe PASS lines. Isolated native and browser QA ran on this Mac in dark and light, including a simulated loopback Pyro H stream through the new guide. T3 snapshots timed out again, so headless Chrome took the browser screenshots. No phone, second device, physical transmitter, or macOS permission dialog was exercised. A QA relaunch hit an existing Keychain prompt for the rebuilt ad-hoc binary. That QA process and its QA-only Keychain item were removed. Evidence, the port test, and limits are in [viewer setup verification](verification-viewer-setup-2026-11-03.md).

GPT-6.1 Sol (codex, high) approved in one round with no findings, after independently passing 43 viewer checks, 12 pointer checks, and 22 focused Swift tests. The review scope was 24 files, +875/−208, against `df085a5`. That scope is still byte-identical to the reviewed patch. After approval only `CFBundleVersion` moved from 24 to 25, so the code diff is now 25 files, +876/−209. The full check was not repeated; with signatures removed, the executable is byte-identical to the pre-review rebuild.

Build 25 is installed at `~/Applications/Setbeam.app`; build 24 is kept at `~/Applications/.Setbeam-before-viewer-setup-build25.app`. The installed app, the fresh build, and the extracted archive match across all 37 files, and strict recursive signatures pass. Executables are arm64 and link only system libraries; there are no Homebrew paths.

- Executable SHA-256: `6c573a81a28797d203557fd11dacc8fd409ba874252e867d73f8e343d903ceac`.
- Archive: `dist/Setbeam-0.2.0-build25.zip`, SHA-256 `89ea54ca5a23ac206f5838aa69217aa5a3fc6424a661f2b89dc6da9fad82a212`. It includes `BUILD-NOTES.md`, `APP-SHA256.txt`, and a 134-input `SOURCE-MANIFEST.txt` (SHA-256 `e4af0b0e82abcfdca2d565afb3d577c4bc562a038b9428eb44abeccf1e016d88`).
- Runtime: the packaged `--access-test` (7 PASS) and `--local-address-test` (10 PASS) passed against the installed app's helpers and fixtures.
- Screenshots: fresh build 25 captures show the 14 px Connection help gap (desktop and phone) and the Pyro H "Stream found" card and guide (dark and light). T3 snapshots timed out three times, so headless Chrome took the browser captures.
- Open: an unanswered Setbeam Keychain prompt from the earlier QA incident, and an unrelated diskutil administrator prompt, remain on screen untouched.

Physical transmitter, phone, second-device, and macOS permission-dialog testing remain open. Parent verification confirmed the archive checksum, ZIP integrity, all 37 app files against the build and installation, strict signatures, all 134 source inputs, and the unchanged reviewed behavior patch. Private Austin Deliveries upload completed with remote verification under Setbeam / Viewer setup. The receipt and link are in the verification note. No commit, push, PR, or hosted workflow ran. Computer use refused SecurityAgent access for safety reasons, so the stale QA Keychain prompt remains for Austin to dismiss with Deny.

## S-002 viewer join page, build 24, 2026-11-02

Under viewer approval, a browser session that has not been admitted now sees a join card in place of the picture and controls: Ask to join, Waiting for the operator with "Asking as Sam (session 4)", declined, removed, busy, link no longer active, and sharing ended. Admitted viewers keep the picture-first page. A name saved in the tab only pre-fills the form. The gateway now creates a request under approval only with an explicit `ask`, so a reload or a saved name never sends one by itself. Restored passes keep their state without a new request. A lapsed request returns to the form with the name kept. Failed sends wait for the viewer. Turning approval off while the form is open plays without a name. Under approval, Connection help shows a fixed name read-only, and a session admitted unnamed before approval can set one first label. Approval off, media authorization, per-viewer readers, Hold, Stop, pointers, and native UI are unchanged.

The final `scripts/check.sh` run passed: 189 Swift tests (3 new), 42 viewer checks (11 new), 12 pointer checks, and 52 probe PASS lines, including 3 new real-media gateway checks in `--access-test`. Earlier runs stopped at the known preview-bridge assertion in unchanged code, then at two existing callers that joined under approval without `ask`; both now send it. QA ran an isolated build 24 copy on this Mac, using T3 tabs and headless Chrome with desktop, phone, large-text, tablet, and landscape viewports. It covered operator Admit, Decline, and Remove, duplicate names, Hold, Resume, Stop, approval toggled off, and offline and lapsed requests. No physical phone, tablet, or second computer was tested. GPT-6.1 Sol on high approved in round 2. Its one should finding was fixed: when Stop retires the link while the form is open, the join page now shows the link as no longer active, and Try again keeps it unavailable. Both regression tests failed before the fix and pass after it; real browser transitions passed too. The post-fix full check passed on its first attempt. No finding was declined. Evidence and limits are in [viewer join verification](verification-viewer-join-2026-11-02.md).

Build 24 is installed at `~/Applications/Setbeam.app`. All 37 app files match the fresh local rebuild and extracted archive, strict recursive signatures and ZIP integrity pass, and the seven packaged real-media access checks pass. The archive and checksum are retained under ignored `dist/`. Reviewed source commit `12404e7` contains the implementation and accepted fix. No behavior code changed after approval; preexisting dirty notes are preserved. Private Austin Deliveries upload completed with remote verification; its receipt is in the verification note. No push, PR, or hosted workflow ran.

## S-006 local address, build 23, 2026-11-02

While sharing, Setbeam publishes a readable `.local` name for the viewing address, `setbeam.local` by default. Operators can change it in Advanced > Viewer network or turn it off. The system DNS-SD responder registers one address record on the selected viewing interface, with no administrator rights, internet service, Mac rename, or network change. A conflict moves to `name-2` and later numbers, and Settings, the join sheet, and the QR panel show the name in use. Only the link's host changes. The private code, approval, same-origin pointers, numeric WHEP media, Hold, Stop, and local monitoring are unchanged. Join codes and Copy IP address link keep the IP address. Stop and Quit remove the name, and expired links stay expired. The 64-character code still makes hand-typed links impractical.

The final `scripts/check.sh` passed in one run: 186 Swift tests (8 new), 31 viewer and 12 pointer checks, and every probe, including the new real-media `--local-address-test`. An earlier run hit the known intermittent preview-bridge assertion in unchanged code. Native QA of the candidate on this Mac covered Ethernet and Wi-Fi interfaces, a simulated second host taking the name, invalid input, rename while sharing, Stop and restart, approval, Hold and Resume in a browser at the name, off, and Quit cleanup, in dark and light. No second device, phone, or second Mac was tested. Evidence, screenshots, the cache-lifetime observation, and limits are in [local address verification](verification-friendly-address-2026-11-02.md). Claude Opus 5.5 implemented the change on high, and one GPT-6.1 Sol reviewer approved it on high in one round, with no blocking findings. A cleanup nit outside the current app lifecycle remains a documented follow-up. The reviewer independently passed all unit/browser and local-address checks, but its full run stopped at the unchanged preview-bridge duration assertion on line 98.

Build 23 is installed at `~/Applications/Setbeam.app`. All 37 app files match the fresh local rebuild and the extracted archive; strict recursive signatures and ZIP integrity pass. The final packaged-runtime local-address probe passes all 10 checks with 59 decoded audience frames. The archive and checksum are retained under ignored `dist/`; source commit `03952b8` contains the reviewed implementation. No behavior code changed after review. Private Austin Deliveries upload completed with remote verification; the full review ledger and delivery record are in the verification note. No push, PR, or hosted workflow ran.

## S-008 shared pointers with viewer admission, build 22, 2026-11-01

Admitted viewers can opt in to point at the shared picture with a name and one of six colors. The operator's main and floating monitors and other pointing viewers see the same named pointers, positioned on the picture rather than the page, including letterboxing, browser full screen, and floating zoom and pan. Pointers travel on a bounded, same-origin presence channel on the existing gateway, independent of capture and viewer frame rates. They fade 4 s after the last meaningful movement and clear on Hold, Stop, publisher revisions, removal, and disconnects. They never enter encoded media.

The necessary S-002, S-003, and S-005 foundations are included. Each tab gets a gateway-issued pass. Optional viewer approval asks for a name and waits for Admit or Decline. Admitted sessions read media with their own MediaMTX user, and removal revokes that user and ends its active sessions without interrupting other viewers. Ordinary link sharing is unchanged when approval is off. S-002, S-003, and S-005 remain partial; see the verification note. No password, hostname, presenter highlight, or drawing was added.

The final `scripts/check.sh` passes: 178 Swift tests, 31 viewer and 12 pointer browser checks, and all media probes, including a new real-media access probe. Two GPT-6.1 Sol reviewers approved in round 3 after fixes for late snapshots, opt-out timing, fade revival, native expiry, approval retry, and first-name naming. The ad-hoc signed build 22 is installed locally and delivered. Evidence, the review ledger, hashes, limits, and an observed intermittent preview-bridge timestamp failure in unchanged code are in [shared pointers verification](verification-shared-pointers-2026-11-01.md).

Reviewed code `c5e5ea6` and the final docs-only commit `926b6e7` are integrated
into the main checkout. Parent checks confirm all 131 packaged source inputs
match this checkout, all 37 installed app files match the package, the executable
and archive SHA-256 values match the handoff, and strict recursive signatures
pass. The archive, checksum, and seven delivered screenshots are retained under
ignored `dist/`. Private Austin Deliveries upload is remotely verified. No code
changed during parent integration, and no hosted CI, push, or PR was used.

The two-reviewer loop took three rounds on GPT-6.1 Sol with high reasoning effort.
All substantive findings were fixed; none was declined. The final diff is 35
files, +2966/-97, from +2831/-97 before review. Usage was not reported. S-008 is
marked implemented; S-002, S-003, and S-005 are explicitly partial in the backlog.
The sharing popover's growth can overlap underlying status text until reopened;
its controls remain readable. Physical mobile/multi-laptop checks and native
non-16:9 QA remain open, as detailed in the verification note.

## S-001 single application window, build 21, 2026-11-01

Choose a source now lists other applications' windows beside displays, with application, title, icon, and bounded live previews. Choosing one, such as Capture One, captures only that window through the existing in-app ScreenCaptureKit, encoder, and relay path. One capture feeds main and floating monitoring and sharing; Hold, Stop, readiness, recovery, the 3840 by 2160 bound, the 30 fps ceiling, and the saved capture and viewer frame rates are unchanged. Identity is the window number, owner process, and owner start time, never the title. Minimizing, hiding, or closing the window pauses the picture; a quit owner shows that the window closed. Setbeam never substitutes another window or the whole display. Relaunch restores a window privately only while that same window of the same process still exists; otherwise the operator chooses again. The chooser never requests Screen Recording access.

141 Swift tests (14 new), 26 viewer checks, and the complete `scripts/check.sh` pass. An earlier pre-review run hit the existing 50.067 ms format-cadence assertion on sample media; its isolated probes passed. Two GPT-6.1 Sol reviewers approved in round 2 after one retry-timing fix. A new opt-in real-capture probe proves only the selected window reaches local and audience outputs under an overlapping window, Hold replaces it, rename/move/resize keep it, minimize/restore returns it, and close/reopen never substitutes a same-titled window. Isolated native QA covered dark/light chooser and monitoring, browser Live/Hold/Resume/Stop, loss states, exact-window restoration at 1 fps, the permission-denied chooser, and normal Quit cleanup. Single-display only; multi-display, Capture One itself, attached sheets, and VoiceOver remain unverified. See [window source verification](verification-window-source-2026-11-01.md).

Reviewed commit `225fd5e` is integrated into the main checkout. The review diff
grew from 21 files, +931/-27, to +975/-27 after the retry regression test and final
evidence/ledger updates. The thumbnail observation nit remains a follow-up,
accepted by the reviewer; review usage was not reported. Nothing was pushed,
no PR was opened, and hosted CI stayed disabled.

Build 21 is installed at `~/Applications/Setbeam.app`. Parent verification confirms
its version, executable hash and strict signature, the archive hash, and all 114
packaged source/test/resource hashes against this checkout. The verified archive
and nine reviewed screenshots are also retained under ignored `dist/`; private
Austin Deliveries upload completed with remote verification. S-001 is marked
implemented in the backlog, with the remaining manual qualifications linked.

## Screen sharing and viewer collaboration backlog, 2026-10-31

Austin refined S-008 to include automatic fading of stationary pointers and their
name tags, viewer-selected preset colors, and pointer updates independent of video
frame rate. Idle expiry must survive a throttled or disconnected sender; repeated
heartbeats do not count as movement. The exact idle/fade timing remains a UX
choice. Cursor-shape customization is a later consideration. S-009 records
temporary arrows/circles for after the cursor-only collaboration feature.

This follow-up changes backlog text only. All 50 local Markdown links, nine unique
pending story IDs, dependency references, acceptance-check tags, and
`git diff --check` pass. The full local regression result below belongs to the
preceding backlog pass on unchanged app code; media tests were not repeated for
these text refinements. Additional viewer-workflow suggestions remain discussion
only.

Recorded Austin's future requests in [STORIES.md](STORIES.md), linked from the
execution plan. S-001 covers application-window sharing; S-002 through S-005
extend existing optional names and playback health with optional approval,
individual revocation, a candidate session password, and basic session details.
S-006 considers a friendly local address; S-007 and S-008 cover presenter
highlighting and optional shared named pointers over the picture, including the
Mac's monitor. The backlog preserves one received source, private media/admin
permissions, Hold/Stop behavior, and separation of annotations from encoded video.

This is planning only. Browser API documentation supports pointer feasibility;
no collaborative transport, admission control, password feature, or new media
capture behavior has been implemented. All 50 local Markdown links in the three
planning/status files, the initial eight unique story IDs, acceptance-check tags, and
`git diff --check` pass. An illustrative local pointer concept renders without
horizontal overflow at 728 pixels in dark appearance and 360 pixels in light
appearance; pointer visibility and matching picture-relative positions update in
both simulated views. This is a concept check, not a multi-device network test.

The complete local `scripts/check.sh` passes all 127 Swift tests, 26 viewer
checks, and the preview, simulated Pyro H, media, recovery, source-switching,
format, FPS, and large-keyframe probes. No hosted workflow ran. Native app UI,
physical devices, and hardware qualifications were not retested for this
documentation-only change.

## GitHub build 20 prerelease, 2026-10-29

Published the latest app code, `a635f3e`, as `v0.2.0-build20` on the development fork. The release ZIP includes the self-contained app, build notes, app hashes and a 106-file source/test/resource/script manifest. The executable matches the earlier Build 20 SHA256 exactly. The README now links the download and documents current inputs and limits, with fresh Build 20 sample-session captures of the dark/light Mac window, browser viewer and Picture settings. The repository description and topics reflect the current product. Detailed changes dated October 21–29 are in [release notes](releases/0.2.0-build20.md).

Evidence from this publication run and remaining limits are in [release verification](verification-release-build20-2026-10-29.md). This is a developer prerelease for Apple Silicon and macOS 14 or later, ad-hoc signed and not notarized. All validation ran locally; GitHub Actions remains disabled. Hardware qualifications are unchanged.

## Build 20 native Pyro H port, 2026-10-29

Restores Holly Share's Pyro H connection flow in the native chooser. Bounded discovery checks only the current Wi-Fi router, binds that interface/address, and describes the known `/live` endpoint on ports 5554/554/8554. It requires a complete H.264 SDP, opens no streaming connection, cancels when the chooser closes, and drains before source selection. Discovery pauses during network monitoring. The normal RTSP adapter receives the source once; main/floating monitoring, sharing, Hold/Stop and recovery retain the existing pipeline. Proven profiles save their exact endpoint in Keychain and restore privately. A compatible stream does not establish a model or unique hardware identity.

The initial complete check passed 127 Swift tests, 26 viewer checks, preview, Pyro H simulation, media, recovery and source switching, then hit the existing format assertion with a largest 50.067 ms interval at 30 fps. The unchanged full rerun with QA sessions closed passes all checks, including format/FPS/large-keyframe probes. Active dark/light native UI, simulated H.264/AAC main/floating/browser playback, zero upstream readers during discovery and one while monitoring/sharing, same-page Hold/Resume/Stop, exact-endpoint private restoration, and normal Quit cleanup pass. Strict signatures, system-only dependencies, resources/fixtures/notices, unchanged 99-file source matching, ZIP integrity and all 38 installed/extracted distribution files pass. Build 20 is installed locally, and private archive delivery completed with remote verification. See [Pyro H verification](verification-pyro-h-2026-10-29.md). All validation ran locally; hosted CI stayed disabled.

Austin confirmed a physical Pyro H was unavailable. The software port is implemented and simulated; physical model/firmware, audio/A/V timing, source formats, single-client/power-cycle behavior, latency, range and endurance remain open. No additional transmitter compatibility or physical-test pass is claimed.

## Build 19 display source previews, 2026-10-29

Connected displays now have rounded, updating thumbnails in Choose a source. Each preview fits its complete picture into 120 by 72 points beside the display name and resolution. Unselected displays use small, silent screenshots every two seconds while the sheet is open. The monitored display reuses the existing local feed. Opening the chooser never requests recording access; a denied grant shows Preview off and Enable Previews. Closing it cancels refresh and clears its images.

Debug/release builds and the complete local `scripts/check.sh` retry pass all 119 Swift tests, 26 viewer checks, and every preview/media/recovery/source-switching/format/FPS/keyframe probe. The first run failed an existing core test with `The video service could not start.` Its unchanged isolated rerun and the complete retry pass. Active dark/light chooser screenshots, actual thumbnail updates, permission-denied presentation, Escape, private 1920×1200 screen selection, existing-feed preview reuse, and normal Quit cleanup of all six owned helpers pass. Strict signatures, system-only dependencies, resources/notices, source matching, and archive checks pass. See [display-preview verification](verification-display-previews-2026-10-29.md). Build 19 is installed locally; private app/screenshot delivery completed with remote verification. Physical multi-display/portrait, hot-unplug, and VoiceOver speech checks remain open. Transmitter compatibility is unchanged. All checks ran locally, with hosted CI disabled.

## Latest main rebuild, 2026-10-29

Rebuilt the latest fetched `origin/main`, commit `67918577797b8feba902ef3c304449614c52daff`, without changing app code or test assertions. `scripts/build-app.sh` passes. The matching app is installed at `~/Applications/Setbeam.app` and archived at `dist/Setbeam-0.2.0-build18-macOS-arm64-rebuild.zip`. Private delivery completed with remote verification.

All 119 Swift tests and 26 viewer-controller checks pass. Checks using the frozen app's own helpers and fixtures pass sample/RTSP/RTMP media, source/server recovery, source switching, FPS changes, and large keyframes. The keyframe probe decoded 498 frames in seven seconds from 1,749 KB keyframes without decoder errors.

The complete `scripts/check.sh` does **not** pass on this rebuild. Both full attempts stop at `scripts/check-preview-bridge.py:102`, `assert all(0 < delta < 100_000 for delta in intervals)`. An unchanged isolated preview-bridge rerun passes. Running the remaining check commands separately reaches a format failure: `The live relay changed decoded cadence: expected 30.0 fps, measured 30.000913664188868, largest frame interval 0.050066000000000166 seconds.` After closing the native QA sessions, an unchanged isolated format rerun also fails: `The local relay changed decoded cadence: expected 60.0 fps, measured 59.61040509361171, largest frame interval 0.033332999999999835 seconds.` These failures remain unresolved. Exact logs are retained under ignored `build/latest-build-2026-10-29/`.

The frozen app launched from `/tmp` with isolated sample preferences. Native video advanced at 1280×720 and about 24 fps. Actual Chrome Incognito playback followed Hold, Resume, and Stop; local and floating monitoring continued after Stop. The active dark main-window capture is readable and unclipped. A light window was inspected through computer use, but its capture remained inactive and does not qualify as an active light-mode review. Normal Quit removed both QA apps and all recorded remaining descendants, six for the dark session and ten for the light session. The temporary Chrome window and T3 browser tab were closed. T3 snapshot inspection twice returned `Preview automation snapshot timed out after 15000ms.`, so Chrome was inspected through native computer use.

Strict recursive signatures, arm64 executables, system-only linked libraries, all six viewer resources, bundled fixtures/notices/FFmpeg sources, the matching 105-file source/test/build manifest, ZIP integrity, and every extracted file hash pass. The executable SHA256 is `a0ddab37bcd759b181c06f4cb1f14038c5e2c3c8a6e0fb48b7bde2f491e1ffcd`; the archive SHA256 is `1700f87c1bdd5d71661fb1cc7c378480eb73f2ed11b270235c427c82a6bf3a12`. This remains an ad-hoc signed Apple Silicon developer preview for macOS 14 or later, without notarization. All checks ran locally; no hosted workflows ran. No new physical hardware, audible synchronization, phone/Safari, or endurance evidence is claimed.

Build 17 was rebuilt for the main-branch handoff. All 118 Swift tests and 25 viewer checks pass. Packaged preview/media/recovery/source-switching checks pass. The full check stopped at one format-cadence assertion; the unchanged isolated format rerun and subsequent FPS/keyframe probes pass. Native and Chrome Guest sample playback, Hold/Resume/Stop, continued local monitoring, strict signatures, bundled dependencies/resources, archive integrity, and normal Quit cleanup pass. The exact failure, archive hashes, and remaining physical-test limits are recorded in [Build 17 handoff verification](verification-build17-2026-10-28.md).

## Build 18 UI review changes, 2026-10-28

Austin approved review items 1 and 3–7 and rejected item 2. Hold/Resume and Stop retain their existing icon-only controls and layout. The QR panel, join sheet, and setup check replace loopback invitations with a viewing-network action. Playback problems appear in the main footer and open the struggling sessions first. Escape closes browser Connection help from its name field and returns focus to Help. The source chooser puts local displays, detected capture devices, and the labeled sample before saved setups and empty wireless guidance. Picture settings has a dedicated sheet in the gear and Feed menus, separate from network credentials. Intentional Hold uses blue; recovery remains amber.

Initial local checks pass all 119 Swift tests and 26 viewer-controller checks. Packaged dark/light native checks and actual Chrome playback verify the new layouts, loopback guidance, viewer frame-rate Save, synthetic struggling-viewer heartbeats, blue Hold, continued local monitoring after Stop, and Escape focus restoration. Actual 1920×1200 screen capture stayed private while the light screen-specific settings were inspected. Both QA apps and all recorded owned descendants quit cleanly. The full packaged `scripts/check.sh` passes in one run, including preview, media, recovery, source switching, format, FPS, and large-keyframe probes. Sol approved all 15 changed files in one round with no findings. Strict signatures, all six viewer resources, system-only dependencies, the 105-file source/test/build manifest, and archive extraction/integrity pass. See [UI verification](verification-ui-2026-10-28.md) for evidence and remaining limits. GitHub Actions is disabled; all validation runs locally.

## Product scope

Setbeam receives, monitors, and shares video feeds. Computer displays used by DigiTechs and camera feeds are peer use cases. This Mac's screen is a peer source captured with ScreenCaptureKit.

## This Mac's screen implementation, 2026-10-26

The source chooser lists local displays by localized name and pixel resolution, with a Display fallback when macOS supplies no name, and labels this source No sound. The saved identity is a display UUID. One in-app ScreenCaptureKit stream excludes Setbeam's application windows, includes the cursor, and encodes monitoring-quality H.264 through VideoToolbox into the existing supervised FFmpeg/local relay. Capture retains native pixels up to 3840×2160 and cadence up to 30 fps. Existing audience controls and proven private restore use that same source adapter.

After rebasing onto Build 12, actual capture was verified with the packaged app launched from a shell holding Screen Recording access. The screen produced fresh native frames and passed the proven-setup gate. Setbeam's frontmost window was absent from its own preview. Sharing reached a Chromium-based browser at 1920×1080 decoding 60 frames per second. That run found and fixed near-static relay timestamps from the raw H.264 pipe; the frame step is now 16.7 ms and the outgoing thumbnail plays. Setbeam's own Screen Recording grant when opened from Finder, floating-preview exclusion, larger displays, and hot-unplug remain unverified. See [screen-source verification](verification-mac-screen-2026-10-26.md).

Before the rebase, the final `scripts/check.sh` passed all 80 Swift tests, five viewer checks, and all preview/media/recovery/source-switching/format probes. All five new screen-source tests passed. Later verification encountered intermittent existing preview cadence/timestamp and viewer-port-reuse assertions, recorded with their isolated reruns. Automated evidence and native limits are recorded in [screen-source verification](verification-mac-screen-2026-10-26.md). No new hardware compatibility claim is made. Real screen capture, readable fine text, visible exclusion of main/floating windows, display hot-unplug/reconnect, capture recovery, browser sharing, Hold/Stop with this source, and proven relaunch with captured frames still require a Screen Recording grant. The packaged app's permission-denied UI and exact privacy-pane link were verified natively; Setbeam was off in Screen & System Audio Recording. The isolated QA app was quit afterward.

Austin's Build 15 screen-sharing log showed the native preview cycling stopped/playing after 4K sharing started. Four causes were found and fixed. MediaMTX's default 512-packet reader queue discarded detailed keyframes mid-picture for the preview and audience readers; the runtime now sets 8192. On the real 4K display, a playback clock left behind by a late arrival evicted every later 4K picture before it was due; capacity eviction now restarts the clock. Every native window converted each frame to RGB on the CPU through CoreImage; pooled IOSurface pixel buffers now go to AVSampleBufferDisplayLayer, taking 4K monitoring from 38 to 59.5 presented fps and the app from 202% to 26% CPU. Keyframes above 8 MiB stopped the screen source; ScreenEncoder now withholds oversized pictures and restarts with a higher minimum QP. MediaMTX warnings now reach the session log. Two 4K60 encodes saturated the hardware encoder at about 51 fps, so at Austin's direction nothing Setbeam encodes exceeds 30 fps. The viewer encode overshot its allowance threefold at 1 fps with 4.5 MiB 4K keyframes that browsers could not assemble; its one-second rate limit now holds the allowance, and 1 fps 4K viewing went from no picture to live in 1 s. A play request aborted by a replaced source no longer shows Ready to play or stops viewer recovery. See [screen-sharing stability verification](verification-keyframe-bursts-2026-10-27.md).

## Current behavior

Build 15 adds Match source/display plus 1, 5, 10, 15, 24, 25, 30, and 60 fps in Advanced; the 4K stability work later capped both at 30 fps. Viewer frame rate drops frames before the audience encode, preserves timestamps and full dimensions, and never duplicates a slower incoming feed. Changing it and Viewer picture together replaces only one audience publisher, under the same server and viewing credential. Local monitoring of external sources keeps its received cadence. Screen capture frame rate separately sets the ScreenCaptureKit rate, capture timer, VideoToolbox cadence, and raw-pipe input rate. A screen-rate change retains sharing intent and any running Hold. Defaults match the source; saved rates do not restore sharing. The sample uses the same audience encoder so its FPS and bitrate controls also work. Native freshness allows three frame intervals at 1 fps while retaining bounded frozen-picture detection.

The final matched app passes strict signatures, six bundled viewer-resource comparisons, source/build-record matching, and system-only linked dependencies. The source/test manifest is frozen with the distribution. Source timestamp discovery remains enabled for external stream copying, including B pictures; slice-threaded decoding avoids long startup buffering at 1 fps. Screen-pipe writability drains large frames between capture ticks while retaining the 8 MiB bound. The 24 fps sample's AAC priming produces a 62.988 ms loop-boundary interval even in a direct file-only check; the format/FPS probes now account for that source timing. This is automated/native/browser evidence, not a new physical compatibility or image-quality qualification.

Private Build 15 delivery completed remote verification with the app archive and build notes. The final signed app restored the same selected display privately at 1 fps. All isolated QA apps and their owned helpers were closed afterward.

Build 14 implements the approved browser mockup. A compact feed name/Sample/status strip and icon toolbar share one full-screen player. The picture follows decoded dimensions and fits the available height without cropping. Sound appears only when an incoming audio track is unmuted, including WebRTC peers that negotiate an unused audio receiver. First connection, operator Hold, reconnection, blocked playback, and ended sessions have distinct presentations. Hold uses blue; recovery uses amber. A large Play control handles blocked playback, and unchanged live text is not rewritten on every decoded frame. F/M, double-click full screen, on-demand connection help, and feature-detected video PiP are available. Hold and Stop detach playback and leave PiP. Expired or unknown viewer navigation gets the same self-contained generic 404 page without exposing the current session; API and asset requests retain their access restrictions. Native phone full screen and video PiP cannot include the page's status strip.

Evidence: 101 Swift tests, the complete source and packaged-helper `scripts/check.sh` media/bridge/recovery/switching/format probes, and the final 18 viewer checks pass. Actual Chromium/native Chrome sample playback, whole-player full screen, Hold/Resume/Stop, PiP cleanup, generic expired-link reload, quiet live-status DOM updates, and emulated phone layouts pass. A synthetic 960 by 600 video-only sample proved the 16:10 picture and hidden sound control despite WebRTC's negotiated muted receiver. Strict signatures, source/resource matching, and system-only dependencies pass. Three Sol review rounds approved the final change. These are automated/synthetic/browser checks; physical phone, VoiceOver speech, hardware, and native phone/PiP presentation limits remain open.

Build 12 relays the received encoding to local monitoring. Master 4K HEVC and network or incoming H.264/H.265 are copied to the private relay instead of being re-encoded as 12 Mbps H.264 Baseline. Raw capture frames are encoded once at monitoring quality. Browsers receive the audience output's own H.264 Baseline encode at a per-viewer ceiling of 12, 6, or 3 Mbps, chosen under **Viewer picture** in Advanced. Capture devices open at their active size and highest cadence instead of a fixed 30 fps. A display-sleep assertion is held while a live local picture is visible. A redacted, rotating session log under `~/Library/Logs/Setbeam` records lifecycle commands, process restarts with decoded exit status, connection stages, viewer counts, and every source or audience readiness change with the inputs behind it. Viewer pages receive state as server-sent events, heartbeat about every 3 seconds, and fall back to polling. A **Keep screen on** control requests a Screen Wake Lock where the browser allows it and otherwise plays a 2 KB muted looping clip.

Evidence: `scripts/check.sh` passes all 89 Swift tests (59 core, 30 app), 11 viewer-controller checks, the preview-bridge checks, and the packaged media, recovery, source-switching, and format probes. The format probe verifies that HEVC Main and H.264 High with B frames reach the private relay unchanged at their source size and cadence, that the audience output is Baseline without B frames, and that a viewer-quality change restarts only the audience encode under the same server and credential. A simulated Master 4K route sent RTP HEVC with in-band parameter sets plus AAC into the runtime's exact passthrough arguments. MediaMTX reported H265 plus Opus, and the bundled preview bridge decoded 90 frames at exactly 30 fps with audio. In the packaged Build 12 app, `pmset -g assertions` showed "Setbeam live monitoring" while the picture was visible. Hiding the app released it, showing the app re-acquired it, Stop Sharing released only the sharing assertion, and Quit released both with no helper processes left. The Advanced picker and session-log button were inspected natively. Choosing Light restarted only the audience output. In a Chromium-based browser against the packaged app, live playback made no state polls and heartbeated about every 3 seconds. Hold reached the page 435 ms after the menu click. After Resume the page reacted 18 ms after the server's audience output became ready, which took 4.0 seconds for the sample. Stop ended the page in 202 ms and released keep-awake. That browser refused the Wake Lock request, and the fallback clip played and looped. The app's session log contained no viewing token, and probe logs contained no credential or secret-length strings. The same-port viewer restart test, previously intermittent, passed 40 of 40 runs after `stop()` began waiting for its cancelled listener.

An opt-in transmitter Wi-Fi rejoin is available in Advanced for a saved Master 4K with a known Wi-Fi name. It is off by default. When enabled, it asks for the Location access macOS requires to read Wi-Fi names. After the transmitter has been missing for 15 seconds without a picture, it joins that network through CoreWLAN with a Keychain-stored password, backing off from 20 seconds to two minutes. It never runs while sharing depends on Wi-Fi. Policy tests cover the timing, backoff, reset, opt-in, and blocking rules. On this Mac without Location access, CoreWLAN returned 59 nearby networks with every name hidden and an empty result for a name-filtered scan of an absent network, so Setbeam cannot associate with an unidentified network. An actual association, with Location granted and the physical transmitter power-cycled, has not been tested.

Not established by this build: the Master 4K passthrough on the physical transmitter, a physical capture device at 60 fps (none is attached to this Mac), phone screen-sleep behavior and Safari on iOS, and many simultaneous viewer streams. See [architecture](architecture.md) for the design.

Build 11 adds the approved optional join-code panel while retaining numeric-IP session links. Show QR codes widens the main window by 252 points when space permits, keeping the current picture size; Hide restores its previous width. Wi-Fi and feed codes stack beside the picture and scale with its height. The panel stays open through other controls, Hold, and Stop. Stop removes the feed code while leaving Wi-Fi and local monitoring available. Add/Edit viewing Wi-Fi returns directly to the panel and preserves the viewing link. Relaunch still restores privately; there is no reusable printed invitation, online lookup, or new Bonjour dependency.

The final self-contained Build 11 passes all 75 Swift tests, five viewer checks, and the packaged bridge/media/recovery/source-switching/format probes. Native default dark and compact light layouts, actual QR decoding with protected Wi-Fi punctuation, stable links during Wi-Fi edits and Hold, fresh codes after Stop/Start, same-page browser Resume/Stop, right-edge expansion, and normal/Force Quit process cleanup pass. These are automated/sample checks; physical phone scanning and Wi-Fi joining were not newly tested. See [QR panel verification](verification-qr-panel-2026-10-23.md).

Build 10 completes the four approved architecture changes. MediaRuntime owns session intent and health and recovers without UI status requests; snapshots are observational and lifecycle commands are serialized. Native main/floating playback shares timestamped video and a synchronized audio path instead of JPEG frames and separate audio decoding. External inputs normalize to verified H.264 Baseline without B frames and optional Opus while preserving dimensions and cadence. Source changes retain the same server, viewing identity, and running holding publisher, including an offline source, occupied incoming port, or partial configuration failure. Failed replacement preflight restores the previous source identity and local preview. Relaunch remains private.

The final self-contained Build 10 passes 75 Swift tests, five viewer-controller checks, file and actual-RTSP preview-bridge checks, and packaged sample/RTSP/RTMP, source/server recovery, continuous-Hold source-switching, and media-format probes. Native main/floating and Chromium Start/Hold/Resume/Stop pass. An isolated synthetic 1080p60 native check passes, normal Quit cleans all six private-monitoring descendants, and Force Quit cleans all ten sharing descendants. Strict signatures, system-only dependencies, bundled resource/source hashes, and the frozen source/test snapshot pass. This Mac still reaches the explained local-audio device timeout and returns to mute while video continues; audible synchronization and physical endurance remain open. See [architecture verification](verification-architecture-2026-10-23.md).

Build 9 separates actual outgoing-media health from the outgoing thumbnail. Normal Start, Hold, and Resume changes show bounded preparation states rather than false reconnection warnings. Fresh output ends preparation immediately; real later loss and unavailable holding output remain visible. All 51 Swift tests, five viewer checks, and packaged media/recovery/source-switching probes pass. Native Start/Hold/Resume checks pass without the false banners. A new quick demo uses moving footage and a visible pointer without added captions. See [outgoing-status verification](verification-outgoing-status-2026-10-21.md).

Build 8 replaces the sharing sidebar and repeated healthy/audio text with a full-width local picture, unified source/sound/floating-preview/gear toolbar, and one sharing-status footer. QR invitations and outgoing-picture/audio/viewer details open in native popovers. Hold/Resume and Stop stay visible during sharing. Setup tests, network settings, capture audio routing, Save frame, and diagnostics move into the gear and standard menus. Recovery, changed addresses, and missing outgoing media remain visible when needed. All 42 Swift tests, five viewer checks, and packaged media/recovery/source-switching probes pass with an unchanged source snapshot, strict signature verification, and system-only dependencies. Native dark/light and compact checks pass. The finished app restored the saved physical Master 4K privately with advancing native frames and Mac sound muted. See [layout verification](verification-layout-2026-10-20.md).

Build 7 adds safe source changes under Hold with a stable viewing link and return to the previous input, an actual outgoing-media thumbnail, Test my setup with other-device and listening checks, separate input/local/audience audio status, and active-sharing Quit protection. The source implementation passes all 33 core and 9 app Swift tests, 5 viewer-controller tests, and `scripts/check.sh`, including the new actual-media source-switching probe. Isolated native/Chromium switching, Hold/Resume, local-viewer exclusion, Quit cancel/confirm, and cleanup of all ten owned descendants pass. Physical phone and qualified transmitter power-cycle results are recorded below. See [safeguard verification](verification-safety-2026-10-20.md).

Build 7's earlier dedicated sharing column and healthy-picture labels are superseded by the approved Build 8 layout. The previous 900×720 light and 760×560 dark checks remain recorded in [main-window verification](verification-main-window-2026-10-20.md).

The source chooser shows detected capture names and illustrations, advertised RTSP sources with explicit paths, the last proven setup, an explicitly labeled sample, and discovered CineView Master 4K units. Stream addresses, manual viewer network selection, input sound routing, incoming RTMP, and diagnostics are in Advanced.

A setup is remembered after two seconds of sustained reception and fresh native playback. Complete network addresses and incoming credentials use Keychain. Capture inputs use persistent identities resolved inside bundled FFmpeg. The next launch restores the same source and floating preview privately. Sharing and Hold always start off.

Source stalls, helper failures, preview decoder failures, and server failures have bounded recovery. Healthy status requires fresh frames. Viewer counts distinguish opened pages from actual playback, and the same viewer page reconnects after audience media restarts. Hold suppresses outgoing source video/audio; Stop sharing preserves local monitoring.

Open viewers replace a peer after ten seconds without decoded video. Their state/configuration/heartbeat requests time out after five seconds, including body reads. Active sharing waits for the selected viewing interface through temporary network loss, preserving Hold, the viewing credential, and viewer server port. A changed IP address updates the viewing code and requires viewers at the old numeric address to rescan. Wi-Fi selection remains user controlled; automatic Wi-Fi association is not implemented.

The main window, source chooser, physical guidance, native menus, floating preview, and phone-friendly viewer have been polished. Light/dark appearance, keyboard actions, accessible labels, copied-link feedback, join codes, and desktop/phone-size Chromium layouts were inspected. Viewing Wi-Fi metadata can be edited without interrupting the feed or rotating its viewing link.

While connecting or recovering, the preview shows one stage label, a native activity indicator, and small progress marks. Direct Accsoon reception distinguishes monitor preparation, finding the selected transmitter, its connection acknowledgement, waiting for picture, and opening native playback. Generic network, incoming, capture, and sample inputs use the three observable stages without claiming transmitter discovery. Stages follow runtime signals rather than elapsed time. Missing Accsoon source video retains its physical guidance. The indicator clears only when reception and native playback are both fresh.

The build 7 floating preview adds pinch/scroll inspection and bounded drag-to-pan, with double-click or 0 to restore the whole picture. A separate hover strip stays outside the picture and displays the zoom percentage while magnified. It moves above the preview when there is no room below. Native sample checks passed its hover, scroll, pan, reset, minimum-size badge, and close/reopen behavior. Real routed mouse checks also passed ordinary window movement, edge/corner resizing, zoom, pan, and reset after correcting borderless AppKit handling. Eight new app geometry tests pass; `scripts/check.sh` passed before the final window-handling corrections, and the packaging owner is rerunning the final packaged check. Physical trackpad pinch and display/Space combinations remain open. The verified combined package is recorded below. See [PiP verification](verification-pip-2026-10-20.md).

## Approved layout review

The Build 7 layout review compared an actual isolated sample-session screenshot with the full-width monitor proposal. It included light/dark, Hold, Private, and settings examples plus the reason each visible control stays. Its browser controls and 360-/728-pixel previews passed inspection. Austin approved the privately delivered review and requested implementation. Build 8 is the native implementation. The review exports are archived locally outside the source files. No new hardware compatibility is implied.

## Physical Master 4K result

The exact tested unit is Accsoon CineView Master 4K. The same saved UID has reported product IDs 21 and 24, with firmware 3.30/raw 798; the earlier hardware status was raw 256/0x0100. Austin confirmed the physical unit is unchanged. Both observed product IDs are now recognized, with the product-24 live video, audio, Hold, and recovery route verified separately in the field record. Its direct RTMS4 input works through Accsoon_11D5 on this Apple Silicon Mac. Wi-Fi receives the source while Ethernet retains internet access and serves viewers. No vendor binary is bundled.

A real 1920×1080p60 computer display passed direct reception, legible frame export, main/floating playback, Chromium playback, Hold/Resume/Stop, proven setup restoration, helper recovery, and Wi-Fi rejoin. The AAC 48 kHz stereo input produced Opus and a live browser audio track. A killed input helper recovered fresh native frames in 4.3 seconds, preserving the saved source and private state. A deliberate Wi-Fi interruption also recovered the same source after rejoining its network.

The build 6 receiver check passed direct video/audio conversion, Hold/Stop, and three forced source-helper recoveries in 2.51, 2.97, and 3.01 seconds with Hold and the viewing credential retained. A following 120.5-second check recorded 118 fresh source/audience samples with zero outages. Wi-Fi selection was unchanged. This is short physical-source evidence with injected software failures, not a long session or transmitter power-cycle test.

Accsoon SEE 1.9.3 was installed and its agreement accepted with Austin's explicit approval. Its device list stayed empty on this Ethernet-plus-Wi-Fi Mac, so a vendor-picture baseline did not pass. The tested Setbeam route is direct reception, independent of SEE. A real no-input event was observed, and Setbeam correctly asks for a camera/computer picture when stream arrays are empty.

Build 7 verified the same confirmed unit with product ID 24: real 1920×1080 computer-display export, H.264/Opus conversion, silent outgoing Hold, local monitoring through Hold/Stop, and three source-helper recoveries in 2.37, 2.60, and 2.32 seconds. The completed 120-second continuous-run criterion failed with 2 unavailable samples of 116; recovery occurred, but the cause and duration of those readings were not independently measured.

A physical phone in Safari passed sample video and audible tone, 30-second lock/wake recovery, silent Hold, and automatic same-page Resume with sound. The real transmitter picture also played on that phone. After physical transmitter OFF/ON, macOS switched Wi-Fi to the regular LAN. Manually rejoining the transmitter's Wi-Fi restored the same source, fresh main/outgoing frames, and the same phone page without app Retry or browser reload. The viewing link remained unchanged. This is recovery after a manual Wi-Fi rejoin; automatic association is not implemented. Phone model and OS version were not supplied.

## Verification and packaging

Build 11 is `dist/Setbeam-0.2.0-build11-macOS-arm64/Setbeam.app`. Its frozen source/test snapshot, packaged checks, strict signatures, bundled viewer resources, system-only dependencies, and isolated native/browser sample verification pass. Finished build notes and a native sample screenshot accompany the archive. The app remains an ad-hoc signed developer preview. Physical compatibility and long-session limits are unchanged. See [QR panel verification](verification-qr-panel-2026-10-23.md).

Private Build 11 delivery completed remote verification with the finished app archive, build notes, and native sample screenshot. All isolated QA apps were closed, their owned helpers exited, and their viewing codes expired.

Build 10 is `dist/Setbeam-0.2.0-build10-macOS-arm64/Setbeam.app`. Its packaged-runtime checks passed 75 Swift tests, five viewer checks, and all media/recovery/source-switching/format probes with the source and test snapshot unchanged. Native sample and synthetic 1080p60 monitoring, browser audience controls, normal/Force Quit cleanup, strict signatures, resource/source hashes, and system-only dependencies passed. The archive includes finished build notes. The app remains an ad-hoc signed developer preview. Physical compatibility and long-session limits remain unchanged. See [architecture verification](verification-architecture-2026-10-23.md).

Private Build 10 delivery completed remote verification with the finished app archive and build notes. The production app and its saved hardware source were not operated during this pass.

Build 9 is `dist/Setbeam-0.2.0-build9-macOS-arm64/Setbeam.app`. Its final frozen source, packaged-runtime checks, signatures, resource hashes, and system-only dependencies pass. It opened privately with the same saved Master 4K and Mac sound muted. The physical source was unavailable at that checkpoint, so fresh hardware playback is not claimed for this build. The ad-hoc signed developer distribution and existing hardware limits are unchanged. See [verification](verification-outgoing-status-2026-10-21.md).

The private Build 9 delivery completed remote verification and contains the app archive, a 33-second quick click-through with moving sample footage and a visible pointer, and notes/footage attribution. The new video has no added captions and supersedes the earlier captioned walkthrough for the requested demo.

Build 8 is `dist/Setbeam-0.2.0-build8-macOS-arm64/Setbeam.app`. The final release source remained unchanged through packaging and `scripts/check.sh` against its packaged helpers and fixtures. Native release QA passed 900×636 dark/light, 640×472 light, first-run/private monitoring, invitations/join codes, audio details, and process cleanup. Force Quit stopped all ten sharing descendants; normal private Quit stopped all six. After quitting the old private build, the distribution app launched from `/tmp`, restored the same saved Master 4K, and was left monitoring privately with sound muted. The app is ad-hoc signed, self-contained, and not notarized. Exact hashes and final delivery evidence are in [layout verification](verification-layout-2026-10-20.md).

Private Build 8 delivery completed with remote verification. The delivery folder contains the finished app archive, build notes, and labeled native sample screenshots in dark/light appearances.

A 46-second native walkthrough was privately delivered with remote verification. It records the actual Build 8 sample session, with captions and pauses trimmed, showing Private, sharing/invitations, source and sound popovers, actual outgoing Hold, Resume, Stop, and the gear menu. The sample app was quit afterward; the production monitor was untouched. No app code or hardware claims changed.

All 42 Swift tests, comprising 33 core and 9 app tests, five viewer-controller checks, and `scripts/check.sh` with the final app's packaged helpers and fixtures pass. Connection-stage tests cover discovery, actual acknowledgement, fresh media, loss/recovery, and generic input routes. The actual-media probe covers sample, authenticated RTSP and RTMP, stable incoming destination restoration, actual silent Hold, read-only viewer restrictions, stopped/stalled source recovery, media-server recovery retaining the viewer credential and Hold, and owned-process cleanup. New RTSP/RTMP tests start offline and recover twice after sender loss while retaining audience intent and credentials.

Build 6 packaged Chromium checks recovered a frozen video track in 12.157 seconds and hung state requests in 14.120 seconds on the same page without an operator click. Native Hold, browser silence/closed playback, server recovery and Resume, and cleanup of all eight owned helpers after Force Quit passed. These are injected software checks, not physical phone or network-loss tests.

Build 6 normal Quit stopped the app and all eight owned descendants. Native automatic restoration after quitting an active held session restored the saved picture and floating preview with sharing and Hold off. The distribution app is self-contained, ad-hoc signed, and verified against system-only dynamic dependencies. Private delivery is recorded in the build 3 verification record.

Build 6 launched from `/tmp` and restored the same proven Master 4K privately with sharing and Hold off. Fresh main/floating native playback passed. The previous floating-preview preference was restored, and the finished app was left monitoring the source privately. Packaging and delivery are recorded in the recovery verification record.

Build 7 is `dist/Setbeam-0.2.0-build7-macOS-arm64/Setbeam.app`. The final source/test snapshot remained unchanged during packaging. Strict signature verification, bundled viewer hashes, and system-only dependencies pass. Launched from `/tmp` with isolated sample preferences, it produced fresh native/outgoing pictures and audio tracks; Force Quit cleaned up all ten owned descendants. The final app then restored the saved physical Master 4K privately with Picture ready and sharing off. See [main-window verification](verification-main-window-2026-10-20.md), [PiP verification](verification-pip-2026-10-20.md), and [safeguard verification](verification-safety-2026-10-20.md).

Private build 7 delivery completed with remote verification. Its delivery folder contains the earlier app archive and build notes. It was left monitoring the saved physical source privately at that checkpoint, and is now superseded by Build 8. Full build 7 packaging and delivery evidence is in [main-window verification](verification-main-window-2026-10-20.md).

## Current branding

Austin selected round 3, variant 1, Silver, as the interim Setbeam logo. `Assets/Setbeam.png` preserves the approved artwork; `scripts/make-icon.swift` generates its standard icon representations. Build 3 contained the correct ICNS, but About's system-provided application icon returned a generic placeholder in the screenshot session. Build 4 loads the bundled icon directly for About and assigns that image to the application icon at startup. Native visual inspection and a comparison against the decoded bundled icon pass. All 26 Swift tests and `scripts/check.sh`, including media integration, were rerun successfully. This correction adds no physical hardware evidence.

## Repository cleanup

On 2026-10-21, unused mockups, icon concepts, and review exports were archived locally under the ignored `build/` directory. The approved icon source is `Assets/Setbeam.png`; sample-image provenance stays with `Fixtures/`. The original `holly-share.sh` launcher, installer, page template, and reference documents now live together under `docs/upstream/`. Upstream and dependency notices remain intact.

Ignore rules cover build products, downloaded dependencies, runtime state, local credentials/settings, editor state, logs, and design experiments. Private delivery URLs were removed from the checked-in verification records. Source, tests, required assets, build scripts, and project documentation remain versioned.

The cleaned source passed `scripts/check.sh`: 51 Swift tests, five viewer-controller checks, and the actual-media, source-recovery, and source-switching probes using `Vendor/bin`. The moved artwork generated all ten icon sizes and an ICNS identical to the approved Build 9 icon. Shell syntax, local documentation links, staged-file checks, and ignore-rule checks passed. These are automated checks; native UI, browser playback, and physical hardware were not retested during this cleanup. The hardware limitations below still apply.

## GitHub README

On 2026-10-21, the README was shortened into a product introduction with the approved icon and real native screenshots that follow GitHub's light/dark appearance. Both images are unmodified Build 8 sample-session captures of the layout retained in Build 9. Fictional sample media is labeled. Detailed build, setup, monitoring, sharing, and recovery instructions moved to [getting-started.md](getting-started.md). Hardware limits, developer-preview status, upstream attribution, and license links remain visible.

GitHub's Markdown API preserved the themed picture markup. Rendered checks at 900- and 360-pixel widths confirmed loaded images, the correct theme-specific screenshot, working section navigation, and no horizontal overflow. All 25 local README/setup-guide links and image references passed, and both screenshot hashes match their recorded native captures. `scripts/check.sh` passed all 51 Swift tests, five viewer-controller checks, and the actual-media, source-recovery, and source-switching probes. These are documentation and automated checks; native app behavior and physical hardware were not retested for this change. The remaining evidence below is unchanged.

The publication format check initially failed with `Invalid PNG: Assets/screenshots/main-dark.png`. Both screenshots contain JPEG data and were renamed to `.jpg`, with README and setup-guide references updated. The original image bytes are unchanged. All 26 local references and section anchors passed the final check, both 900×636 JPEGs decoded successfully, and whitespace and private-content scans passed.

## Remaining evidence and release work

- The completed 120-second hardware soak failed its continuous criterion with 2 unavailable samples of 116. The two-hour check was explicitly deferred to Austin's next session. Long-session reliability remains open.
- Native audible output and A/V timing remain unverified. This Mac falls back to mute when its audio device does not respond; video and encoded source/audience audio continue. Audible sample sound passed on the phone; real-source audible sound and A/V timing remain open.
- Physical trackpad pinch, additional displays/Spaces, full VoiceOver, camera content, source format changes, latency, range, capacity, and coexistence with receivers/vendor apps remain untested. One phone result does not establish all phone models or OS versions.
- Hollyland models, physical USB/HDMI capture, other Master 4K firmware, Intel builds, and older macOS versions remain unverified. The build targets Apple Silicon macOS 14 or later and was tested on macOS 27.
- Build 12's monitoring passthrough needs a physical Master 4K recheck. That covers preview start time with the transmitter's own keyframe interval, CPU use of software HEVC decoding, and fine-text legibility compared with the earlier re-encode. Capture-device cadence, phone keep-awake, and viewer capacity at each quality setting also need physical tests. Use the session log to attribute any unavailable samples in the deferred two-hour run.
- 4K screen sharing was verified on a virtual display only; a physical 4K monitor, phones, and Master 4K sources need retesting. Physical phones and iPads at 4K, including Safari, need viewer verification. See [screen-sharing stability verification](verification-keyframe-bursts-2026-10-27.md).
- Developer ID signing/notarization and a stable public release remain separate work.

See [hardware-tests.md](hardware-tests.md), [experience-plan.md](experience-plan.md), [experience verification](verification-experience-2026-10-20.md), [recovery verification](verification-recovery-2026-10-20.md), and [architecture.md](architecture.md).
