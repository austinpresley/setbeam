# Architecture

Setbeam is a native macOS application built around one received camera feed.
Holly Share provides the original RTSP-relay reference; its Bash launcher is
not the controller for the new app.

## Modules

- `SetbeamCore` owns source descriptions, session transitions, address validation,
  process ownership, and the media runtime. Its interface separates local monitoring
  from audience sharing. Tests cross that same interface.
- `SetbeamApp` owns SwiftUI/AppKit presentation, saved settings, QR generation,
  local web hosting, native preview presentation, and native window lifetime. UI code observes the session
  state instead of constructing media commands.
- Bundled viewer resources own browser playback and accurate audience states.
  They use the received media rather than contacting the transmitter.

The real source adapters are a labeled sample, a complete RTSP URL, and a
compatible capture device. Named transmitter profiles describe verified
connection methods; a brand name is not a protocol implementation.

## Media flow

The media runtime starts an app-owned MediaMTX instance and supervised FFmpeg
processes. Local monitoring has a private playable output. Audience sharing
uses a separate output so Hold and Stop can change audience media without
closing the camera source.

The initial browser transport is WebRTC. The Mac decodes the private local RTSP relay once into JPEG frames at 24 fps and presents the same native image in its main and floating windows. A separately decoded PCM feed supplies optional local sound through AVAudioEngine. Audio-device initialization stays off the UI thread and has an operator-visible timeout. Guest permission grants read access
only to the audience output. Control and publishing credentials are private.

Each run has a private directory and explicit process ownership. Packaged helpers run in owned process groups through a bundled supervisor that watches the app and terminates its group after parent exit, including Force Quit. The controller also cleans the group after an unexpected supervisor exit. Runtime
state stays outside the signed app bundle and repository. Dependency versions,
source provenance, and build flags are recorded with the bundle tooling.

## Evidence

Automated tests cover session behavior, input validation, access restrictions,
process lifetime, and actual bundled-media playback. Physical device support,
network range, viewer capacity, and end-to-end delay require separate records
in `hardware-tests.md`.
