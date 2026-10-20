# Setbeam status

Updated: 2026-10-20. Version 0.1.0, build 2.

## Product scope

Setbeam receives and shares video feeds. Wireless computer displays used by DigiTechs, including a Capture One display, are a primary use case alongside camera feeds. The app uses source/feed terminology; its transmission-system label describes the hardware, not the image content. No physical computer-through-transmitter test has run, and direct capture of this Mac's desktop is not implemented.

## Current checkpoint

A self-contained Apple Silicon developer prototype is implemented. Real sample video plays in the native window and the shared floating preview, and the browser viewer receives H.264 video and Opus audio. Hold and Stop preserve local monitoring. This is the first stopping checkpoint in `plan.md`.

## Milestones

- [x] Concrete plan with goals and acceptance checks.
- [x] GitHub fork and Project Vault checkout.
- [x] Pinned, bundled media runtime with source archives and notices.
- [x] Actual sample-to-native-preview and browser path.
- [x] Native main window and floating preview sharing one decoder.
- [x] Viewer QR, playback status, Hold/Resume/Stop, and frame export.
- [x] Generic RTSP adapter verified against a real authenticated local source.
- [x] Capture adapter and device selection implemented, physical capture test pending.
- [x] Helper recovery, server failure detection, and normal/Force Quit cleanup checks.
- [ ] Physical transmitter, capture, phone/Safari, and LAN tests.
- [ ] Native sound output verification on a responding audio device.
- [ ] Public signing/notarization, Intel builds, and release distribution.

## Evidence and limits

See `verification-2026-10-20.md` for checks and results. No physical transmitter or capture device was used. The named Hollyland and Accsoon profiles remain unverified test targets.

The native renderer uses one FFmpeg JPEG decode at 24 fps shared by both windows. This avoids the stalled WKWebView WebRTC transport observed on this host. It is a prototype implementation; GPU rendering, frame pacing, power use, audio/video synchronization, and latency need measurement before a production release.

Core Audio stalled opening the development Mac's output device. The app now opens audio off the UI thread, times out with a useful message, and keeps video and controls responsive. Outgoing audio and Hold silence passed media checks; audible local output did not pass.

The browser viewer was checked in T3's Chromium browser on this Mac. Phone reachability, Safari, Wi-Fi range, multi-viewer capacity, and device-specific recovery remain unverified. Sharing uses HTTP on a selected local interface with private, read-only session links. No internet relay is implemented.

## Next work

1. Test a DigiTech computer display through the intended transmission and capture route, including readable small text, fine image detail, aspect ratio, resolution/refresh changes, and reconnect behavior. Record the exact variants and firmware of Austin's three systems; establish a vendor-app baseline and test a receiver capture route.
2. Prove a usable direct input or SDK route per model before adding automatic discovery or a compatibility claim. RTMP/SRT ingestion is not implemented in this checkpoint.
3. Verify iPhone/Safari playback and a second device on the selected LAN. Resolve the WebKit transport issue with that evidence if it affects the browser viewer.
4. Verify local sound against a working output device, then measure and tune local A/V timing and preview latency.
5. Add a GPU video renderer if profiling warrants it, finish accessibility/appearance/keyboard checks, and test long sessions, network changes, occupied-port races, sleep/wake, and larger viewer counts.
6. Choose an authorized signing identity, notarize a release, and verify the minimum macOS target on physical machines.
