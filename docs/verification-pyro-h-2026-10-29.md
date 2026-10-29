# Pyro H native port

Austin requested restoration of Holly Share's Pyro H connection under Setbeam's native media and lifecycle rules. Build 20 ports the upstream endpoint discovery into the source chooser and uses the existing supervised RTSP pipeline. The original launcher remains unchanged.

## Scope and UX

- Flow: Choose a source from the toolbar or Command-O → join the transmitter's Wi-Fi → compatible Pyro H connection appears → select it → check the private picture → Start sharing separately. Done/Escape closes the chooser.
- Surface: the existing Wireless transmitters section. The row shows a compatible stream was found and asks the operator to confirm the model. A visible note identifies physical verification as pending.
- States: searching, no compatible stream/no Wi-Fi with join guidance, found, and current source. Discovery pauses during network monitoring. Advanced retains the full-address override.
- Recovery: the selected endpoint retries through the existing runtime. Guidance covers the transmitter Wi-Fi, HDMI source, competing HollyView clients, and a changed endpoint. The saved profile restores privately through the same sustained-picture gate and Keychain used by other network sources.
- Access: one combined Connect label for the choice, normal keyboard navigation, and a full-name tooltip. No new permission request or Wi-Fi selection is added.

The port probes only current Wi-Fi routers on their directly attached private IPv4 subnets. It binds the exact interface/address, then tries `/live` on ports 5554, 554 and 8554. It checks a complete H.264 SDP, never sends SETUP or PLAY during discovery, and bounds header/body size, request deadlines and cancellation. The chooser cancels its task when dismissed; source selection drains that cancellation before opening an upstream reader. Network monitoring disables further probes. No Homebrew executable or global process matching is used.

A valid SDP does not identify the physical model or a unique transmitter. The profile name expresses the chosen Pyro H connection route. Setbeam remembers and retries the exact selected URL, without following another discovered device. No physical compatibility pass is claimed.

## Automated evidence

The initial focused run passes five core and three app checks: RTSP framing and fragmented TCP delivery, H.264 track validation, HTTP/auth/malformed/oversized rejection, actual-private-subnet boundaries, port fallback, no media requests, timeout/cancellation socket cleanup, backward-compatible profile persistence, scan suppression during network monitoring, late-result rejection and route changes.

The actual-media simulation exposes `/live` through the bundled MediaMTX with H.264/AAC from the labeled sample fixture. Discovery leaves zero upstream media readers. Local and audience pictures/audio then pass through one upstream reader. Silent Hold, source loss/recovery retaining Hold and viewing identity, Resume, Stop preserving monitoring, and owned-process cleanup pass. These are simulated-transmitter software checks. The final audience-picture replacement assertion also passes. The first complete packaged-helper `scripts/check.sh` run passed all 127 Swift tests, 26 viewer checks, preview, Pyro H, standard-media, recovery and source-switching checks, then failed the format probe with `The live relay changed decoded cadence: expected 30.0 fps, measured 30.000003797468835, largest frame interval 0.05006699999999986 seconds.` This is the same assertion recorded on the earlier main rebuild. After closing QA apps and the fixture, the unchanged complete rerun passes every check, including formats, FPS and 1,749 KB keyframes. The final keyframe probe decodes 488 frames in seven seconds without decoder errors. Exact logs are under ignored `build/pyro-h`.

## Native, browser and package evidence

An isolated Build 20 QA copy used its own preference suite, Keychain source account and private logs. A loopback fixture override requires the explicit preferences-suite flag; normal launches use actual Wi-Fi metadata. Its source and session were labeled Pyro H test stream and SIMULATED PYRO H. No production saved connection was used.

- The active dark/light chooser shows the current Pyro H connection, full model-confirmation and competing-client guidance, and physical-test status. Escape works. Scrolling is necessary for the actual content. There is no unsolicited focus ring, overlapping control or clipped row text. Native PNGs are `build/pyro-h/chooser-dark.png` and `chooser-light.png`.
- Main and floating previews render the simulated 1280×720 feed at about 24 fps. The upstream server reports zero media readers after discovery and one while native/floating and browser sharing run. Reopening the chooser during monitoring shows Current source without another probe.
- Actual Chrome Incognito playback reaches Live feed, follows Hold, returns to Live feed after Resume on the same page, and shows Sharing ended after Stop. Local/floating monitoring remains live after Stop. T3 browser snapshots twice returned `Preview automation snapshot timed out after 15000ms.` before the native Chrome fallback. Its test tab and separate Chrome window were closed.
- Relaunch restores the same saved setup ID and endpoint with sharing/Hold off and local/floating playback available. Both QA sessions quit normally with all six recorded owned descendants gone. The simulated transmitter's two owned process groups were stopped. Austin confirmed a physical Pyro H was not available.
- The layout-grid lint passes added view lines. Measured artwork is 44×44 points within the 485×68 point current-source row, with 12 point insets. Both screenshot geometry checks pass.
- The release app passes strict recursive signatures, arm64 checks, system-only linked dependencies, six viewer resource matches, every sample/hold/compatibility fixture, and bundled dependency notices/source archives. The frozen 99-file source/test/script manifest stayed unchanged throughout final checks. Executable SHA256 is `f30f345087ff097ccf61f71f755328f45aef068fbb04906d5ba7c2d3930e5d86`. The immutable app is `dist/Setbeam-0.2.0-build20-macOS-arm64/Setbeam.app`, and its identical installed copy is `~/Applications/Setbeam.app`. ZIP integrity, extracted signatures and all 38 installed/extracted distribution files pass. Archive SHA256 is `1e1de9fbada82fb8cbb2935047d6b1b1e736b06ccd3f6d09cf00c3013981f328`.

Private Build 20 delivery completed with remote verification. Its archive contains the app, build notes and the matching source/test/script manifest.

All checks ran locally. No hosted test/build/packaging workflow was enabled or run. This remains an ad-hoc signed Apple Silicon developer build for macOS 14 or later, without notarization.

## Remaining physical evidence

A physical Pyro H is not connected. Verify exact variant/firmware, Wi-Fi router and ports, real SDP and formats, computer-display and camera pictures, audible source sound/A/V timing, other-client behavior, one received feed with main/floating/browser use, power cycles/manual Wi-Fi rejoin, latency, range and endurance. Do not apply this route to Pyro S, Mars 300/300 Pro, or Mars 400S Pro without their own protocol evidence.

The known route comes from the preserved [Holly Share source](upstream/holly-share.sh) and [upstream first-party project code](https://github.com/titleunknown/holly-share/blob/3fcf772273d6f3db3423b2eb39f5db70ee601519/holly-share.sh#L170-L204). The upstream project's physical claim does not qualify this native port.
