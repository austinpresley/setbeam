# Setbeam execution plan

Date: 2026-10-20. Austin authorized a fork of `titleunknown/holly-share`, the name `setbeam`, a working copy in Project Vault's Projects directory, and continued implementation in this thread. The earlier suggestion to start an independent repository is superseded by that explicit fork request.

## Installable and updatable public download, build 41

Austin asked on 2026-11-14 to make the public download installable and
updatable. Build 41 ships as a Developer ID-signed, hardened-runtime, notarized
and stapled disk image, and includes Sparkle 2.10.0 with a signed feed on the
repository's GitHub Pages. Media behavior is unchanged from build 40.

Acceptance: every executable carries the hardened runtime, team G2R8798RLT and
a secure timestamp. Gatekeeper accepts the app and disk image as notarized.
A Developer ID build installs a signed update end to end through Sparkle on
this Mac. Developer and test launches never contact the feed. A scheduled
update never interrupts an active share. The feed goes live only after the
uploaded disk image downloads anonymously and matches. Build 40 users install
build 41 once by hand.

## Viewer access fixes and public update, build 40

Austin authorized review findings 1, 2 and 3 on 2026-11-11: retain approved
viewers in the roster without heartbeats, end sharing safely if a viewer-access
controller update fails, and update the public prerelease to include these
changes and the build-38 memory correction. Build 39 is the implementation
baseline. The other review findings remain separate work.

Acceptance: stale approved sessions stay individually removable and cannot be
evicted by new requests; missing updates never count as fresh playback.
Credential and disconnect failures stop outgoing media and retire the viewing
link while preserving the original private source. A new share reapplies the
approval policy before publishing. Run failing regressions before the fixes,
then local unit, actual-media, browser and native checks, package audits and
download verification. Keep GitHub Actions disabled and retain physical
qualification limits in the prerelease notes.

## Product goal

Austin's approved visual direction is recorded in [design-standard.md](design-standard.md).
Use that restrained, picture-first standard for future implementation. The
2026-11-06 minimal floating-preview concept supersedes the earlier two-row
preview proposal.

Build a self-contained, native Mac app for receiving, monitoring, and sharing video feeds. Computer displays sent through wireless transmission systems are a primary DigiTech workflow, alongside camera feeds. The main window has a live feed preview, sharing status, and audience controls; invitations and detailed status open from their controls. A separate resizable floating preview remains available while other applications are in use. Viewers open a clean browser page without installing an app or creating an account.

Preserve a quiet, native macOS interface, clear first-run guidance, saved working settings, visible failure states, and recovery during an active session. Software dependencies ship with the app. A physical transmitter and appropriate network or capture connection remain necessary for an external source.

## Future backlog

[STORIES.md](STORIES.md) records Austin's 2026-10-31 requests for optional
application-window sharing, viewer admission and basic session details, a
candidate session password, a friendly local address, presenter cursor
highlighting, and shared named viewer pointers. Pointer refinements include idle
fading, viewer-selected colors, and updates independent of video FPS. Temporary
arrows/circles are deferred until after cursor sharing. S-001 is implemented in
Build 21, with [window-source evidence](verification-window-source-2026-11-01.md);
S-008 is implemented in Build 22 with [shared-pointer evidence](verification-shared-pointers-2026-11-01.md).
S-002 is implemented in Build 24 with [viewer-join evidence](verification-viewer-join-2026-11-02.md). Its necessary S-003/S-005 foundations are partial; the backlog records what
remains. S-006 is implemented in Build 23 with [local-address evidence](verification-friendly-address-2026-11-02.md). The other stories remain future work. The implementation and verification
checkpoints below describe separate work.

## Initial hardware targets and evidence

- Hollyland Mars 300 Pro: documented HollyView Wi-Fi monitoring. A usable input for our own Mac app still needs verification. Do not assume Pyro H endpoints or Mars 400S Pro receiver-LAN support.
- Accsoon CineView Master 4K: documented Apple Silicon MacBook monitoring and app-initiated RTMP/SRT push. Direct third-party Mac integration remains unverified. Its transmitter USB video output to iOS is not a documented generic Mac UVC input.
- Original Hollyland Mars 300: investigate receiver HDMI capture first. Direct app/network video access has not been established.

Each eventual supported profile must name the exact model, variant, firmware, connection route, and test evidence. Generic RTSP URLs and USB capture are useful input types, not promises of model compatibility.

## Step 1: Establish the fork and project record

Goal: a traceable, buildable project with the full agreed scope recorded.

- Create the GitHub fork as `austinpresley/setbeam`; preserve upstream history and license.
- Clone to `the local setbeam checkout` and retain an upstream remote.
- Keep the original launcher available as a reference while developing the native app.
- Bring the reviewed mockup and relevant research into project documentation. Exclude unrelated control-center files and machine-local state.
- Add concise project instructions, architecture notes, this plan, and a current status/test checklist.

Acceptance: correct fork parent and remotes verified; clean baseline; all further work confined to the new project; upstream attribution preserved.

## Step 2: Build and bundle the media runtime

Goal: the app can receive and relay a real media stream without depending on Homebrew at runtime.

- Pin MediaMTX and FFmpeg versions and record provenance, hashes, build flags, and licenses.
- Prefer official MediaMTX releases and a deliberately scoped FFmpeg build with its required codecs and capture inputs.
- Bundle every non-system dependency. Check executable library paths for references to developer Homebrew directories.
- Supervise only this app's child processes, use private session directories, and perform bounded graceful cleanup.
- Keep administration and publishing credentials private; grant guests read access to the shared output only.

Acceptance: bundled executables run from the app's own paths; runtime smoke checks pass; no missing Homebrew libraries; process exit and startup failure cleanup verified.

## Step 3: Prove one complete media path

Goal: live video and audio pass through the actual bundled runtime and play locally and in a browser.

- Add an explicit sample source so development and recovery tests do not require a powered transmitter. Mark it as a sample everywhere it matters.
- Define a small source interface with concrete sample, full-URL network, and capture adapters as their implementations become real.
- Receive each source once. Local preview, floating preview, and audience sharing read the Mac's received feed.
- Validate source readiness and media progress rather than equating a running process with a working picture.

Acceptance: actual encoded sample media reaches both the local preview and a browser player; audio tracks are present; a second preview does not open a second upstream connection.

## Step 4: Implement native monitoring

Goal: a usable native app matching the approved design direction.

- SwiftUI main window with source choice, session name, preview, sharing controls, and connection status.
- A separate resizable floating preview, local mute, remembered geometry where practical, and clear offline presentation.
- Saved non-secret settings and private storage for any saved credentials.
- Standard keyboard, window, appearance, and accessibility behavior. Technical details belong in connection settings and diagnostics.
- Start with a working sample and generic input flow. Display proposed hardware profiles honestly.

Acceptance: app launches, source can be selected, preview and PiP work, local mute affects local playback only, and shutdown stops owned processes.

## Step 5: Implement the audience experience

Goal: a nearby viewer can join and understand the state of the feed.

- Serve a bundled phone-friendly viewer page and its assets locally.
- Generate native QR codes for the session URL and optional user-provided Wi-Fi join details.
- Provide Copy Link and a large join-code view.
- Track actual viewer/player activity separately from source availability; expose a simple connection check.
- Provide obvious sound control and accurate connecting, live, holding, reconnecting, and ended states.

Acceptance: a separate browser session opens the shared link, receives video, reports playback, and follows the session states. Guest requests cannot use administrative or publishing functions.

## Step 6: Separate local monitoring from audience control

Goal: the operator can control the audience without losing the local picture.

- Start/stop sharing independently from local monitoring.
- Hold replaces outgoing source video with a safe holding output and suppresses outgoing source audio. Merely hiding video in the phone page is insufficient.
- Keep local preview and PiP running during Hold and after audience sharing stops.
- Resume through the same viewer page, with reconnection where required by the transport.
- Add Save Frame from the received local feed if it can be implemented and verified without compromising the main path.

Acceptance: capture the actual shared output during Hold and verify it contains no source picture or source audio; local media remains available. Stop Sharing leaves monitoring usable.

## Step 7: Add input and recovery evidence

Goal: establish what works and make failures understandable.

- Exercise a generic RTSP source with the complete URL rather than hardcoded device paths.
- Physically test a computer display through the transmission/capture chain as a peer to a camera source. Check small text, fine image detail, aspect ratios, resolution/refresh changes, and reconnect behavior.
- Implement and enumerate compatible USB/capture input routes without requesting camera/microphone access until needed.
- Add targeted discovery only where the model's protocol is established. Do not change the Mac's Wi-Fi or transmitter firmware automatically.
- Test source loss, child-process failure, occupied ports, repeated start/stop, and application quit. Add backoff and actionable errors.
- Keep technical logs private and redact passwords, session secrets, and credential-bearing URLs.
- Keep the Mac awake as needed during active sharing; defer disruptive updates until sharing stops.

Acceptance: appropriate automated and runtime checks pass. Each physical hardware test is recorded as passed, failed, or not run; an absent transmitter does not block independent app work or justify a compatibility claim.

## Step 8: Package a reviewable prototype

Goal: a portable Mac app build and source work that Austin can review and test.

- Build the first self-contained Apple Silicon app for this development Mac; record supported macOS and architecture explicitly.
- Sign locally as available and state the signing/notarization status. Do not claim a local or ad-hoc build is a notarized public release.
- Include dependency notices and matching FFmpeg source/build information needed for distribution.
- Run focused Swift tests, media integration checks, a browser playback check, native launch/quit checks, and dependency audits.
- Commit and push coherent changes to the fork. A development PR, if created, targets this fork rather than the upstream project.
- Deliver finished app artifacts through Austin's delivery inbox and provide the exact remaining physical-test steps.

Acceptance: a self-contained app archive launches from its own directory, runs the sample workflow, provides preview/PiP and browser sharing, and has a clear status report and reproducible build instructions.

## First stopping checkpoint

Reach a coherent developer prototype with the actual bundled media path, a native interface, local/floating preview, browser viewing, audience Hold/Resume/Stop, and meaningful recovery tests. Use the sample and generic inputs to verify the software independently. Document proprietary protocol work, physical-device checks, Intel support, and public notarized release work that remain open.

This checkpoint is not a promise that all three owned transmitters already work directly over Wi-Fi. If access to one of them is required, continue all independent work and report the exact model-specific test or SDK dependency.

## Build 3 experience checkpoint

The complete setup and polish pass is recorded in [experience-plan.md](experience-plan.md). It adds detected device identities and illustrations, necessary physical guidance, proven private restoration, Advanced disclosure, automatic same-source recovery, honest frame freshness, clear audience control, workspace restoration, and viewer joining with actual playback feedback.

The CineView Master 4K firmware 3.30 now has a physically tested direct RTMS4 route, independent of Accsoon SEE. Computer-display video, encoded audio, native/floating/browser playback, Hold/Resume/Stop, source loss, helper recovery, and Wi-Fi rejoin are recorded in [hardware-tests.md](hardware-tests.md). Other transmitters and physical capture routes remain unverified. Native audible sound still needs a responsive output device. Build 3 packaging and regression evidence is recorded separately in [verification-experience-2026-10-20.md](verification-experience-2026-10-20.md).

## Build 6 recovery checkpoint

Austin requested stronger Master 4K stability and automatic reconnect for supported inputs and viewers. Wi-Fi selection must remain user controlled by default. The recovery pass adds frozen-peer detection, bounded viewer requests, same-port gateway restart, preservation of sharing and Hold through temporary viewing-interface loss, and immediate recovery of failed Accsoon receivers. Real-media RTSP/RTMP outage tests and browser failure injection are recorded in [recovery verification](verification-recovery-2026-10-20.md). Physical power cycles, format changes, phone/Safari behavior, and long sessions still need separate evidence.

## Build 8 approved layout checkpoint

Austin approved the full-width monitor mockup and requested the native implementation. The unified toolbar uses symbols for local sound, floating preview, and settings. Invitations and detailed source/audience status open on demand. Hold/Resume and Stop remain visible, with recovery and changed-address feedback shown when needed. Native and packaging evidence is in [layout verification](verification-layout-2026-10-20.md). Existing media-flow safeguards and physical-test limits remain in force.

## Build 9 outgoing-status correction

Austin reported the repeated outgoing-reconnection text and requested a quick, uncaptioned click-through with a visible pointer and moving sample video. Build 9 distinguishes explicit audience preparation from actual outgoing loss and keeps thumbnail readiness separate. The reproduction, regression tests, packaged checks, and recorded demo are in [outgoing-status verification](verification-outgoing-status-2026-10-21.md).

## Build 10 architecture pass

Austin approved all four first-principles recommendations on 2026-10-22:

- Give the non-UI session module authoritative ownership of intent, health, and autonomous recovery, with observational snapshot updates.
- Replace JPEG preview and independent audio decoding with one timestamped native video/audio decode and a shared playback clock.
- Define and verify a browser-compatible media contract for every supported external input while preserving dimensions and cadence.
- Retain the running server and holding publisher across source changes and failed input setup.

Acceptance uses real bundled-media tests, independent recovery without status reads, decoded frame timestamp/cadence checks, continuous outgoing-media decoding through source changes, failure injection, native main/floating and browser playback, and self-contained packaged-runtime verification. Physical latency, audible synchronization, and long-session qualification remain separate evidence. Results are recorded in [architecture verification](verification-architecture-2026-10-23.md).

## Build 11 persistent join-code panel

Austin chose the existing numeric-IP session invitations and approved an optional Show/Hide QR codes panel to the right of the picture. Wi-Fi sits above the feed code, with each section using half the picture height. The main window widens when room permits and collapses when hidden. No permanent printed-link mechanism or online lookup is added.

Acceptance covers exact decoding of both native codes, adding/editing viewing Wi-Fi without replacing the session link, persistent presentation through other controls and Hold, removal of the viewing code after Stop, refresh after Start, default and compact native layouts, on-screen window expansion, the existing packaged regression checks, and delivery of the finished developer build. Results are recorded in [QR panel verification](verification-qr-panel-2026-10-23.md). Physical phone scanning and Wi-Fi association remain separate checks.

## Build 12 monitoring fidelity and on-set reliability

On 2026-10-26 Austin asked for the improvements from the app review: the local monitor should show the received picture rather than a re-encode, viewers should have their own bounded encode, capture devices should keep their own cadence, and the on-set reliability and viewer-page items should be fixed. Mac screen capture is a separate change.

- Local monitoring relays the received encoding. Only the audience output is normalized for browsers, at a per-viewer ceiling of 12, 6, or 3 Mbps chosen in Advanced. Raw capture input is encoded once at monitoring quality.
- Capture devices open at their active size and highest cadence instead of a fixed 30 fps.
- The display stays awake while a live local picture is visible. A redacted, size-bounded session log records transitions, recoveries, and the readiness inputs behind each outage.
- Viewer pages receive state as server-sent events and heartbeat about every 3 seconds, falling back to polling. A Keep screen on control uses the Screen Wake Lock API where available and a muted looping clip otherwise.
- An opt-in transmitter Wi-Fi rejoin follows separately, because its association step needs Location access and the physical transmitter to verify.

Acceptance uses the actual-media format probe (source codec preserved on the private relay, Baseline on the audience output, viewer quality change at the same credential), the Accsoon RTP route simulated with in-band HEVC parameter sets, power-assertion observation in the packaged app, session-log redaction and rotation tests, viewer-controller and gateway tests, and a Chromium-based browser check. Physical phone screen sleep, a physical capture device, and the Master 4K passthrough on hardware remain separate evidence.

## Build 14 approved browser viewer

Austin approved the interactive viewer mockup and requested full send. Implement the picture-first layout with a persistent feed name/Sample/status strip inside the full-screen player, familiar icon controls, original source aspect ratio, clear Hold/recovery/play/ended states, and generic unavailable-link navigation. Preserve Build 12 pushed state and keep-awake behavior. Prove actual sample playback, full screen, PiP and Hold/Resume/Stop, expired-code navigation, a synthetic non-16:9 video-only stream, and packaged regressions before delivering and merging the fork PR. Native phone presentation and physical qualifications remain separate. Evidence is recorded in [viewer verification](verification-viewer-2026-10-27.md).

## Build 15 selectable frame rates

On 2026-10-27 Austin requested FPS controls to favor sharper still-image review, such as a Capture One display shared at 1 fps. Add a saved viewer-rate control alongside Viewer picture, and an independent saved rate for This Mac's screen. Preserve dimensions, the selected bitrate allowance, full-rate external-source local monitoring, the viewing identity, and Hold/Stop behavior. Matching the source/display stays the default. Low-rate source acquisition, native playback, browser decoding, and frozen-feed recovery must remain usable.

Acceptance uses actual decoded timestamps and dimensions at 1 and intermediate rates, a slower input with a higher viewer limit, live setting changes and audio-bearing Hold/Resume/Stop, native 1 fps display capture, preference restoration, bounded pipe backpressure, the complete packaged regression checks, and private delivery. Physical transmitter, phone, image-quality comparisons, and endurance qualifications remain separate. Results are recorded in [frame-rate verification](verification-frame-rate-2026-10-27.md).

## Build 16 viewer names and playback health

Austin approved optional viewer names, distinguishable browser sessions, and playback health with full-send delivery. Names stay optional in the viewer's Connection help. Operator-only rows show numbered sessions and Good, Struggling, or an accurate neutral/playback state. Measure the existing peer without changing media flow, permissions, bitrate, or recovery decisions. Account for Hold, blocked playback, background/paused pages, unavailable browser statistics, 1 fps, stale heartbeats, and peer replacement. Preserve the earlier uncommitted FPS work separately from this feature's PR. Automated, native, browser, package, review, and delivery evidence belongs in [viewer health verification](verification-viewer-health-2026-10-27.md).

## Build 18 approved UI review

On 2026-10-28 Austin approved review items 1 and 3–7, requested full send and sol-loop, and rejected item 2. Preserve the icon-only Hold/Resume and Stop controls. Replace loopback phone invitations with an actionable network explanation, expose struggling viewers in the footer, repair Escape/focus in browser help, prioritize immediately usable sources, move picture quality and FPS to a dedicated sheet, and consistently distinguish blue Hold from amber recovery. Keep media flow, health measurement, viewer permissions, private restore, and existing hardware qualifications unchanged. Run all tests, packaging checks, and native/browser verification locally with hosted CI disabled. Record evidence in [UI verification](verification-ui-2026-10-28.md), obtain Sol approval, merge the fork PR, and deliver the matched Build 18 developer app.

## Build 20 restored Pyro H connection

Austin requested a native port of the Pyro H support in the original Holly Share launcher, using current Setbeam standards. Restore bounded Wi-Fi-router discovery for the known `/live` endpoint, a one-click chooser connection and exact-endpoint private restoration. Reuse the existing RTSP adapter and supervised local/audience media path. Never open a streaming connection during discovery, probe while a network source is monitored, switch Wi-Fi, or infer model/physical identity from RTSP alone.

Acceptance uses parser/subnet/cancellation tests, a simulated H.264/AAC endpoint with actual bundled-media decoding, one upstream reader, native main/floating and browser playback, silent Hold and replaced outgoing video, source-loss recovery preserving Hold and viewer identity, Stop preserving local monitoring, private saved restoration, normal Quit cleanup, the complete local check script, and package/resource/signature audits. Physical Pyro H compatibility requires a separate recorded hardware test. The original launcher and its MIT attribution remain preserved.

## Build 23 customizable local viewing address

Austin requested S-006 with an editable local address in Settings, implemented by
Claude Opus 5.5 on high and reviewed with a GPT-6.1 Sol loop on high. The local
address is offered only while sharing on the selected viewing interface, with
collision numbering, effective-name status, and an IP fallback. The private
per-session code, viewer admission, same-origin pointers, Hold, Stop, and local
monitoring remain intact. No global Mac rename or privileged network change is
required.

One Sol round approved the behavior without blocking findings. The final full
implementation check and final packaged local-address probe pass. Physical
second-device, mobile, actual DHCP-change, and multicast-blocking-network checks
remain separate. See [local address verification](verification-friendly-address-2026-11-02.md)
for exact passing and intermittent failing evidence and the deferred cleanup nit.

## Build 24 completed viewer name and approval joining

Austin requested completion of S-002 with Opus 5.5 on high and a Sol 6.1 review
loop on high. New visitors under approval review a name and explicitly ask before
a request is created. A dedicated join card shows waiting and the operator's
decision; restored passes keep their state, optional naming remains available
with approval off, and retired links stay unavailable after retry.

GPT-6.1 Sol approved in round 2 after an expired-link regression fix with two
checks proven to fail before the fix. The final full local suite passes. Physical
phone/tablet/second-computer, real on-screen keyboard, and spoken accessibility
qualification remain open. See [viewer join verification](verification-viewer-join-2026-11-02.md)
for the review ledger, exact failures, local evidence, and packaged handoff.

## Short address and join request card

Austin authorized the opt-in, approval-only short address from the [viewer setup diagnosis](verification-viewer-setup-2026-11-03.md) on 2026-11-03, implemented by Claude Opus 5.5 on high with an independent GPT-6.1 Sol review. He also asked for approval requests that arrive like a notification, native or custom. Viewers on the same network type the effective local name, choose a name and color, and ask. The operator admits each one.

On the tested macOS build, port 80 binds unprivileged only on the wildcard address, so it answers only the viewing address, only while sharing with approval, the local address, and the option on. It sends viewers to an ask-only code, never the link's media credential, and falls back to the link with a named reason. Requests arrive as Setbeam's own non-activating card, which needs no notification permission, and stay discoverable elsewhere until answered. Stop, approval off, and a new link retire the short address; local monitoring, Hold, per-session readers, single receive, bundled runtime, and owned-process cleanup are unchanged. Physical multi-device and network qualification remain open. Sol round 1 withheld approval for a destination recheck on open requests, plus five card and listener findings. All six are fixed with regression evidence. Both round 2 passes approved with no actionable findings. Build 26 is installed locally, with the previous app preserved; packaged access, local-address and short-address probes all pass. See [short address verification](verification-short-address-2026-11-03.md) for checks and delivery evidence.

## Organization and sharing panel, build 29

Austin approved the three organization mockups, requested implementation, and asked for a harsh Claude Opus 5.5 critique followed by fixes and a demonstration. Preserve the separately approved build-28 source chooser. Replace the catch-all Advanced sheet with contextual Source Details, Sharing Options, direct stream entry, and diagnostics. Invitations and viewer management share an optional panel with a separate-window fallback. Keep local monitoring, Hold, Stop, source identity, read-only viewers, and bundled runtime invariants. Verify locally in both appearances and record the review findings and responses before packaging.

## Suite reliability, build 30

Austin requested fixes for the timing and port-reuse failures reported after build 29. Reproduce each failure, distinguish asynchronous socket teardown from a real port owner, preserve source media timestamps, and correct cadence measurement using decoded reorder depth and measured fixture jitter. Acceptance requires new regressions, the complete local `scripts/check.sh` without stage retries or skips, and verification of the packaged helpers. Evidence belongs in [suite reliability verification](verification-suite-reliability-2026-11-04.md).

## Approved design refinement, build 31

On 2026-11-05 Austin approved the combined Sol and Claude Opus 5.5 high design
proposal and its three ImageGen concepts. This approval supersedes build 18's
earlier icon-only audience controls and blue Hold treatment. Use labeled
Hold/Resume and Stop Sharing controls above the local picture, an intentionally
dark monitor stage in both appearances, and a permanent outgoing preview above
the Sharing tabs. Hold has an amber symbol and an explicit text state. Keep
individual admission, the optional Sharing panel/window, source categories,
full-frame previews and existing media behavior. Refine invitation hierarchy
and chooser thumbnail scale without adding new capture sessions or hardware
claims. Viewer-page polish is a later pass.

Acceptance requires local light/dark native interaction and layout checks,
actual browser playback through admission/Hold/Resume/Stop, unchanged source
identity and media ownership, the complete packaged-runtime check, and private
delivery. Evidence belongs in
[design refinement verification](verification-design-refinement-2026-11-05.md).


## Collaboration and entry points, build 35

Implement S-011 through S-017 from Austin's 2026-11-10 request: source-display pointers where possible, viewing Wi-Fi selection and honest password checks, phone/tablet viewer layouts, admitted session chat with frames, independent printable join codes, reliable app reopening and a focused menu bar. Preserve the existing uncommitted work. Use Claude Opus 5.5 with High effort to review each item. Run all builds and checks locally, distinguish software evidence from physical Wi-Fi/mobile/display qualification, and deliver the verified app privately.


## Single picture and chat polish, build 36

Austin rejected repeated media views and the cluttered native chat. Remove the
Sharing live thumbnail in both presentations. Keep sent images compact and
open them on request. Use aligned author/message rows, contextual message
actions and one quiet composer. Verify native light/dark and compact layouts,
chat interactions, Hold/Stop and the complete local check. Get Opus 5.5 High
sign-off and deliver the installed developer build.

## Messages-style chat in every view, build 37

Austin requested compact, Apple-like bubbles and press-and-hold reactions/replies
across native Mac, desktop viewer, iPhone orientations and iPad. Remove action
rows at rest, group consecutive authors, keep names/cursor colors clear and
retain compact images. Add six bounded per-participant reactions, contextual
keyboard and accessibility paths, and plain-HTTP copying. Preserve the media,
admission, Hold and Stop invariants. Verify all layouts locally and obtain
Opus 5.5 High sign-off before private delivery.


Build 37 is implemented, locally verified, installed privately and delivered.
[Implementation and final Opus approval](verification-bubble-chat-2026-11-11.md)
record the exact software evidence and remaining physical/manual qualification.
