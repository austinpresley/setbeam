# Build 20 GitHub publication verification

Date: 2026-10-29. Setbeam 0.2.0, build 20. The app code is commit `a635f3e`. This publication changes documentation and screenshots, not app code or test assertions.

## Local build and automated checks

`scripts/build-app.sh` passes. The resulting executable is byte-for-byte identical to the previously verified build 20 executable.

The first packaged-helper `scripts/check.sh` run passed preview and viewer checks, then failed `LowRateInputTests.testOneFPSNetworkInputWithAudioAcquiresItsPicture` at `LowRateInputTests.swift:38` with `The video service could not start.` The unchanged isolated test passes in 21.552 seconds. The subsequent unchanged complete `scripts/check.sh` run passes all 127 Swift tests, 26 viewer-controller checks, timestamped preview bridge, simulated Pyro H discovery/media, sample/RTSP/RTMP media, guest restrictions, source/server recovery, source switching, codec/dimension/cadence/audio changes, FPS changes, and large-keyframe probes. The final probe decodes 492 frames in seven seconds from 1,749 KB keyframes without decoder errors. This does not resolve the intermittent startup failure's root cause.

Both full runs use the candidate app's own bundled helpers and fixtures through `SETBEAM_TEST_TOOLS` and `SETBEAM_TEST_FIXTURES`. Exact logs are retained under ignored `build/github-release/`, with detailed final per-check logs in `build/logs/`. No hosted test, build, or packaging workflow was enabled or run.

## Native and browser checks

An isolated QA app copied the exact release executable and resources, with a separate bundle ID, preference suites, sample source, loopback viewer, telemetry, and logs. No saved production source or credential was used for its captures.

- Active dark and light main windows render the sample at 1280×720 and about 24 fps. Traffic lights are active, labels are readable, and no controls overlap or clip. The main captures are 900×636 native PNGs.
- The floating preview shows the same received picture. Hold and Stop keep main/floating playback available. Native presented frames advanced from 4,869 during Hold to 13,712 after Stop.
- A separate Chrome Incognito window reaches Live feed, follows On hold, returns to Live feed after Resume on the same page, and shows Sharing ended after Stop. The app independently reports one playing browser session. The browser screenshot captures its real full-screen player with Sample and Live feed visible.
- Picture settings opens from the gear menu and shows independent picture quality and frame rate, including the current match-source limit of 30 fps. Its active sheet is readable and unclipped.
- Normal Quit closes each QA app and all six remaining recorded owned descendants. The temporary Incognito window is closed. Earlier audience-publisher descendants also ended after Stop.

The first LaunchServices QA launch paused in `SessionLog.configure` while creating a custom test-log directory on Project Vault; a process sample showed `mkdirat`. It started no media helpers and is not counted as a native pass. That owned process was terminated. Running the isolated copy and its test logs under `/tmp` succeeds. This check changed no app permission or source code.

T3 browser snapshot inspection twice returned `Preview automation snapshot timed out after 15000ms.` The unused T3 tab was closed; native Chrome computer use provided the actual playback checks.

## GitHub page and screenshot provenance

The README now has an explicit build 20 download, preview/signing status, current product and source descriptions, fresh pictures, installation steps, and October 21–29 change notes. The setup guide includes first-launch instructions and retains hardware limits and upstream attribution.

GitHub's Markdown API preserves the themed `picture`, image links, details, and screenshot-table markup. A local rendering of that sanitized markup, with GitHub-like typography, was inspected at 900 and 360 pixels wide with no horizontal document overflow. A forced dark rendering selects the dark image; the light rendering selects the light image. This is local layout verification of GitHub's sanitized markup, not a physical phone test. All local documentation/image references and applicable section anchors pass.

The dark/light main windows are unmodified PNG window captures. The browser image is cropped by 47 pixels at the top to remove the native full-screen window's blank strip, leaving the 1920×1200 player. Picture settings is cropped to its 500×335 active sheet. Those two images are JPEG exports. No control, text, or media is composited. All images use labeled fictional sample media. Portrait provenance remains in `Fixtures/sample-image-notes.txt`.

| Image | SHA256 |
| --- | --- |
| `main-dark.png` | `9680b55998df85026be6a0d8073520ca0ecbcca9ff1166855744e051423ad6c5` |
| `main-light.png` | `cd367850d5591cd97f6a1366d5491a933b6bf94b831ad03b7827642e8782c0b1` |
| `picture-settings.jpg` | `19b98e621609344e3988e27e7786e0a5d9195a709c6d5f3c2d15797d782549e1` |
| `viewer.jpg` | `c59adee116ce613a4b36972810d59a8948ccd7ec1a666ccd2ba22ad9622678b3` |

## Packaging and publication

Strict recursive signatures, six arm64 executables, system-only linked libraries, all six viewer resources, sample/hold/compatibility fixtures, dependency notices, matching FFmpeg/Opus source archives, and the earlier 99-file source manifest match. A new 106-file source/test/resource/script/notice manifest identifies the frozen build inputs. ZIP integrity, extracted strict signatures, all 39 extracted distribution files, and all 36 installed app files match.

- Executable SHA256: `f30f345087ff097ccf61f71f755328f45aef068fbb04906d5ba7c2d3930e5d86`.
- Archive SHA256: `e79016e8c7ee4a4a8147009fe0b372714215e177a35a85dc27b5d1e1597a76a9`.
- Local archive: `dist/github-build20/Setbeam-0.2.0-build20-macOS-arm64.zip`.
- [GitHub prerelease](https://github.com/austinpresley/setbeam/releases/tag/v0.2.0-build20), with the archive and `SHA256SUMS.txt`.
- The same app is installed at `~/Applications/Setbeam.app`.

This is an ad-hoc signed Apple Silicon developer prerelease for macOS 14 or later, without notarization. The bundled runtime does not rely on a developer Homebrew installation. Private archive and screenshot delivery uses Austin Deliveries with remote verification.

## Remaining evidence

Hardware qualifications are unchanged. Pyro H has simulated H.264/AAC evidence only. The recorded Master 4K firmware 3.30, 1080p60 computer-display route remains the only physically tested wireless route, and its newer local-monitoring path needs a physical recheck. Long-session reliability, native audible sound/A/V timing, physical 4K devices, wider phone/Safari/VoiceOver coverage, Intel/older macOS, and Developer ID signing/notarization remain open. The earlier 120-second hardware soak failed its continuous criterion with 2 unavailable samples out of 116, and the two-hour run remains deferred.

See [hardware tests](hardware-tests.md), [Pyro H verification](verification-pyro-h-2026-10-29.md), and [release notes](releases/0.2.0-build20.md).
