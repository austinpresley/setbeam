# Setbeam

<img src="Assets/Setbeam.png" width="128" alt="Setbeam logo">

A native Mac app for receiving, monitoring, and sharing video feeds with nearby browser viewers. Computer displays sent through wireless transmission systems are a primary DigiTech use case, alongside camera feeds. Setbeam is Austin's fork of [Holly Share](https://github.com/titleunknown/holly-share) by Faini Made.

This is a working developer app for Apple Silicon. It bundles its media runtime and restores your last proven setup as a private monitor. New users choose a source, with an explicitly labeled sample available. No Homebrew installation is required to run the app.

## What works at this checkpoint

- Full-width native monitor with SF Symbol controls, contextual invitation/status popovers, and a resizable floating preview.
- Browser viewing through a session link and QR code, with actual playback heartbeats.
- Hold replaces outgoing source video and audio while the operator keeps monitoring. Stop Sharing also preserves monitoring.
- Detected source names and illustrations, physical connection guidance, Save Frame, optional Wi-Fi join QR, and menu bar controls.
- Proven setup restoration using stable device identities and Keychain credentials. Sharing and Hold always start off after launch.
- Direct Accsoon CineView Master 4K input, physically tested on firmware 3.30 with a 1080p60 computer display. Full-URL H.264 RTSP, authenticated incoming RTMP, and AVFoundation capture adapters are also implemented. Physical capture hardware remains untested.
- Automatic source, decoder, and server recovery, fresh-frame status, authenticated control/publishing, and owned-process cleanup.
- Native adaptive appearance and a phone-friendly viewer that reconnects through the same page after media restarts.

Local sound startup is asynchronous and returns to mute with an explanation if the output device does not respond. On the development Mac, Core Audio stalled while opening the device. Native sound output therefore remains unverified. The outgoing stream contains audio, and Hold's outgoing silence is verified.

A source might be a Capture One display, another computer output, or a camera connected to a transmission system. The connection route determines compatibility. Built-in capture of this Mac's own desktop is not implemented.

## Hardware targets

The CineView Master 4K on firmware 3.30 passed direct Wi-Fi reception, main/floating monitoring, browser sharing, Hold/Resume/Stop, saved restoration, helper recovery, and Wi-Fi rejoin on this Mac. Other firmware, camera-content formats, and simultaneous vendor-app/receiver operation still need testing. Austin's Hollyland Mars 300 and Mars 300 Pro remain unverified targets. See [physical tests](docs/hardware-tests.md) and the [integration research](docs/research/accsoon-integration-2026-10-20.md).

## Build

Use an Apple Silicon Mac, Xcode with Swift 6, Python 3.12 or newer, Node.js for the viewer-controller checks, `make`, `pkg-config`, and `curl`. All third-party build products stay under the ignored `Vendor/` directory.

```sh
scripts/build-runtime.sh
scripts/check.sh
scripts/build-app.sh
open build/Setbeam.app
```

The app is built for macOS 14 and later. This checkpoint was run on macOS 27, arm64; older supported OS versions still require physical verification. The default build is ad-hoc signed and is not notarized. No public release has been made.

The exact dependency versions and source hashes are in [runtime-lock.json](runtime-lock.json). The app bundles licenses, FFmpeg/Opus source archives, and build information. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Use

Choose a detected source from the session/source control at the top left. For the tested Accsoon, power the transmitter, feed it a live HDMI/SDI picture, and join the Wi-Fi named on its screen. Setbeam then shows the model and network for selection. A sustained received picture and fresh native playback confirm the setup; the next launch restores it automatically. The gear menu contains setup testing, viewing-network settings, capture audio routing, Save frame, Advanced, and diagnostics. The speaker controls sound on this Mac; the adjacent picture-in-picture symbol opens the floating preview.

Start sharing when you want viewers to join, then use the QR symbol to invite them. Its popover has the viewing code, network instructions, and copy-link action. Show join codes opens a sheet that can stay visible for a group. Click the footer's sharing state or playback count for the actual outgoing picture, audience sound, and opened/playing counts. The pause/play and stop symbols control audience Hold/Resume and Stop sharing. Optional viewing Wi-Fi details create a join code without changing the Mac's Wi-Fi. Ethernet can serve viewers while Wi-Fi receives the transmitter. Stop sharing leaves your local monitor available.

The selected source and open viewer pages retry automatically after interruptions. Temporary viewing-network loss preserves sharing and Hold while Setbeam waits for that same interface. Wi-Fi selection stays under your control. If the Mac receives a different IP address, viewers need the updated viewing code. Stopping sharing or quitting ends the audience session; reopening the app restores private monitoring.

Use a trusted local network. Viewer pages and signaling use local HTTP. The viewing link grants read-only audience access and should be treated as private. This prototype has no internet relay or remote account service.

The [execution plan](docs/plan.md), [current status](docs/status.md), [experience verification](docs/verification-experience-2026-10-20.md), [recovery verification](docs/verification-recovery-2026-10-20.md), and [architecture](docs/architecture.md) record the scope and remaining work.

The repository contains the app source, tests, sample fixtures, approved artwork, build scripts, and project documentation. Build products, downloaded dependencies, runtime data, credentials, logs, and local design experiments are ignored.

## Upstream

The original launcher remains under its original name at [docs/upstream/holly-share.sh](docs/upstream/holly-share.sh), alongside its installer, page template, and [documentation](docs/upstream/README.md). The native app does not invoke that shell launcher. Upstream history and its MIT license are retained.
