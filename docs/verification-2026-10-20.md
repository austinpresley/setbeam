# Prototype verification

Date: 2026-10-20. Host: Apple Silicon, macOS 27, Xcode 27.0, Swift 6.4. Build target: arm64, macOS 14 or later. Version: 0.1.0, build 1.

## Automated checks

`scripts/check.sh` passes four Swift tests plus the bundled-media integration probe. The probe was also run using the helpers and fixtures inside `Setbeam.app`, exercising the packaged supervisor.

| Check | Result |
| --- | --- |
| Source URL validation and credential/query redaction | Passed |
| Hold/Stop session state preserves local monitoring | Passed |
| Viewer token, static-route allowlist, method restrictions, heartbeat, and session rotation | Passed |
| Actual looping sample, H.264 video and Opus audio | Passed |
| Authenticated full-URL RTSP input with dynamic port and decoded frame export | Passed |
| Anonymous administrative request | Rejected with 401 |
| Guest publishing with a valid current guest credential | Rejected |
| Actual audience video during Hold | Replaced, decoded output differs from the camera |
| Actual audience audio during Hold | Silence verified from decoded PCM; live test tone was present |
| Local source during Hold and after Stop Sharing | Continues |
| Forced camera-helper failure | Restarts and delivers fresh frames |
| Forced media-server failure | Reports unavailable with reconnect guidance |
| Runtime shutdown | Owned processes exit |

`scripts/check-native-preview.py` requires fresh telemetry and frame counts that advance across successive observations from the actual native renderer. It passes for local video and with `--require-floating`. The floating panel reports visible at a level above normal windows. Both windows observe the same decoded-image source, so PiP creates no additional camera receive connection or video decoder.

`scripts/check-force-quit.py` passed after terminating the known integration app, with all eight owned descendants stopped. Its `--wait-for-normal-quit` check also passed after native Cmd-Q, including while the audio device was unresponsive.

The runtime archive hashes match `runtime-lock.json`. The FFmpeg release signature was verified using the recorded official public-key fingerprint. `otool -L` on the media helpers shows only macOS system/framework dependencies. The app and every helper pass `codesign --verify --deep --strict` with ad-hoc signing.

## Native and browser observations

The native window displays actual decoded sample video. UI checks exercised floating preview, Hold, Resume, Stop Sharing, and Quit. During Hold the native picture remains visible and advancing. After Stop, the app reports Preview only and Local preview playing.

T3's Chromium browser played the actual shared stream, with readyState 4 and live audio/video tracks. Its heartbeat appeared as one viewer with confirmed playback in the Mac app. Hold displayed the audience slate and muted the player. The portable test caught a stalled Resume with a retained WebRTC player. The page now closes playback during Hold and opens a fresh peer on Resume; the same live/holding/live decoded-playback check passes without navigating the page. Stop displayed Sharing ended and retained mute. Local HTTP assets are bundled, with no CDN dependency. Desktop 1280×800 and phone-size 390×844 Chromium layouts fit without horizontal or vertical overflow; this does not establish Safari or physical phone support.

Native sound did not pass. A sample of the initial freeze placed the main thread in Core Audio's `AudioDeviceCreateIOProcID` while opening the output device. Audio initialization now runs on its own queue and times out after four seconds. The UI returns to mute with an explanation, video frames keep advancing, Hold remains responsive, and Quit completes. The underlying device stall was not diagnosed as an app, driver, or OS defect. Audible local output and A/V synchronization remain open.

The initial WKWebView preview negotiated tracks but received zero WebRTC transport bytes. Changing document loading and candidate/reader details did not resolve it. The native preview now uses shared JPEG frames through AppKit. The exploratory WebKit probes were removed. See `research/native-preview.md` for evidence and limits.

## Packaging and open checks

A copy of the packaged app was launched from its distribution directory with the working directory set to `/tmp`. Its native decoded-frame and floating-window checks passed, and its browser Hold/Resume flow passed. The developer archive contains the complete app, its runtime, source archives, notices, and build information. It is ad-hoc signed and not notarized. Minimum-OS compatibility is a build target, not a physical macOS 14 test result.

No physical transmitter, capture device, phone, Safari viewer, or second LAN device was tested. QR scanning with a phone, hardware decoding formats, latency, network changes, occupied-port races, sleep/wake, long sessions, and multi-viewer capacity remain open. The three model profiles are test targets. RTMP/SRT input and proprietary wireless adapters are not implemented.

## Reproduce

```sh
scripts/build-runtime.sh
scripts/check.sh
scripts/build-app.sh
SETBEAM_TEST_TOOLS="$PWD/build/Setbeam.app/Contents/Helpers" \
SETBEAM_TEST_FIXTURES="$PWD/build/Setbeam.app/Contents/Resources/Fixtures" \
  scripts/check.sh
open -n build/Setbeam.app --args --integration-demo \
  --session-file /tmp/setbeam-session.json \
  --native-preview-file /tmp/setbeam-preview.json
python3 scripts/check-native-preview.py /tmp/setbeam-preview.json \
  --newer-than /tmp/setbeam-session.json
```

The two integration files are private temporary files. The session file contains a private viewing link. Do not commit or publish it. `check-force-quit.py` deliberately kills only the Setbeam app identified by that file; use it only for this disposable sample test.
