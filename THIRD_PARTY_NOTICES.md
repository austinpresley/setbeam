# Third-party notices

Setbeam is a fork of [Holly Share](https://github.com/titleunknown/holly-share), copyright 2026 Faini Made, under the MIT license retained in `LICENSE`. Original documentation is preserved in `docs/upstream/README.md`. New Setbeam source uses that same MIT license.

The application bundles these separate helper programs and assets:

| Component | Version | License | Source |
| --- | --- | --- | --- |
| MediaMTX and reader.js | 1.21.2 | MIT | https://github.com/bluenviron/mediamtx/tree/v1.21.2 |
| FFmpeg | 9.0.2 | LGPL 2.1 or later, built with GPL and nonfree components disabled | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| Opus, statically linked into FFmpeg and the preview helper | 1.6.1 | BSD 3-Clause | https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz |

See `Setbeam.app/Contents/Resources/Licenses` for the complete notices, pinned versions and hashes, FFmpeg configuration, and runtime build script. Matching unmodified FFmpeg and Opus sources are included in its `Sources` subdirectory. The FFmpeg source signature and official public verification key are included too. The Swift app communicates with FFmpeg and `setbeam-preview` as separate supervised processes.

`setbeam-preview` is a separate executable linked with the pinned LGPL FFmpeg libraries and BSD Opus library. Its complete bridge source and `build-preview-bridge.sh` are bundled with the runtime source materials so the helper can be rebuilt and relinked with modified compatible libraries. The Swift app does not link FFmpeg libraries. Rebuild the runtime first, then run `scripts/build-preview-bridge.sh`; replace and re-sign the preview helper in a local app copy as with the other helpers.

To rebuild the runtime, use this repository's `scripts/build-runtime.sh`. Source archives from the bundle can be copied into `Vendor/cache/` to reuse them. The build script downloads the pinned MediaMTX archive and verifies all archive hashes. Replace the matching helpers in a local copy of the app and re-sign that copy for local use.

Setbeam applies the bundled `patch-avfoundation.py` to FFmpeg's LGPL AVFoundation adapter. It adds exact video/audio device identity options, failing when the selected device is missing rather than selecting a different device. The unmodified archive, patch script, and build script reproduce the modified helper. Keep the two scripts together under a `scripts` directory when rebuilding from the bundled source materials.

The demonstration portrait is a generated fictional image, not camera-test evidence. Its prompt and generation method are in `Fixtures/sample-image-notes.txt`. The bundled MP4 contains H.264 video and a generated test tone; the holding MP4 uses a plain background and silence. Apple frameworks are supplied by macOS.
