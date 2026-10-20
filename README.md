# Setbeam

A native Mac app for monitoring a camera and sharing its picture with nearby browser viewers. Setbeam is Austin's fork of [Holly Share](https://github.com/titleunknown/holly-share) by Faini Made.

This is a working developer prototype for Apple Silicon. It bundles its media runtime and starts with an explicitly labeled sample camera. No Homebrew installation is required to run the app.

## What works at this checkpoint

- Native SwiftUI session window, a shared local picture, and a resizable floating preview.
- Browser viewing through a session link and QR code, with actual playback heartbeats.
- Hold replaces outgoing camera video and audio while the operator keeps monitoring. Stop Sharing also preserves monitoring.
- Save Frame, optional Wi-Fi join QR, menu bar controls, and saved setup with optional Keychain credentials.
- Full-URL H.264 RTSP input and an AVFoundation capture adapter. RTSP is exercised against a real local source; capture hardware is still untested.
- Owned helper supervision, camera-helper recovery, authenticated control/publishing, and Force Quit cleanup.

Local sound startup is asynchronous and returns to mute with an explanation if the output device does not respond. On the development Mac, Core Audio stalled while opening the device. Native sound output therefore remains unverified. The outgoing stream contains audio, and Hold's outgoing silence is verified.

## Hardware targets

Austin's Hollyland Mars 300, Mars 300 Pro, and Accsoon CineView Master 4K are test targets. Their names in settings do not assert direct wireless compatibility. See [physical tests](docs/hardware-tests.md) and the [device research](docs/research/owned-wireless-camera-targets-2026-10-20.md).

## Build

Use an Apple Silicon Mac, Xcode with Swift 6, Python 3.12 or newer, `make`, `pkg-config`, and `curl`. All third-party build products stay under the ignored `Vendor/` directory.

```sh
scripts/build-runtime.sh
scripts/check.sh
scripts/build-app.sh
open build/Setbeam.app
```

The app is built for macOS 14 and later. This checkpoint was run on macOS 27, arm64; older supported OS versions still require physical verification. The default build is ad-hoc signed and is not notarized. No public release has been made.

The exact dependency versions and source hashes are in [runtime-lock.json](runtime-lock.json). The app bundles licenses, FFmpeg/Opus source archives, and build information. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Use

Launch Setbeam to monitor the sample. Open connection settings to choose a full RTSP URL or a compatible capture device, a session name, and the network viewers will use. Start Sharing, then open or scan the viewing link on that reachable network. Optional Wi-Fi details create a join code without changing the Mac's Wi-Fi.

Use a trusted local network. Viewer pages and signaling use local HTTP. The viewing link grants read-only audience access and should be treated as private. This prototype has no internet relay or remote account service.

The [execution plan](docs/plan.md), [current status](docs/status.md), [verification record](docs/verification-2026-10-20.md), and [architecture](docs/architecture.md) record the scope and remaining work. The approved design reference is [design/mockup.html](design/mockup.html).

## Upstream

The original launcher remains at `holly-share.sh`, with its documentation preserved in [docs/upstream/README.md](docs/upstream/README.md). The native app does not invoke that shell launcher. Upstream history and its MIT license are retained.
