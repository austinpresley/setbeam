# Setbeam execution plan

Date: 2026-10-20. Austin authorized a fork of `titleunknown/holly-share`, the name `setbeam`, a working copy in Project Vault's Projects directory, and continued implementation in this thread. The earlier suggestion to start an independent repository is superseded by that explicit fork request.

## Product goal

Build a self-contained, native Mac app for receiving, monitoring, and sharing video feeds. Computer displays sent through wireless transmission systems are a primary DigiTech workflow, alongside camera feeds. The main window has a live feed preview, sharing status, and audience controls; invitations and detailed status open from their controls. A separate resizable floating preview remains available while other applications are in use. Viewers open a clean browser page without installing an app or creating an account.

Preserve a quiet, native macOS interface, clear first-run guidance, saved working settings, visible failure states, and recovery during an active session. Software dependencies ship with the app. A physical transmitter and appropriate network or capture connection remain necessary for an external source.

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
