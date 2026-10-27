#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FFMPEG="$ROOT/Vendor/sources/ffmpeg-9.0.2"
if [[ ! -f "$FFMPEG/libavformat/libavformat.a" || ! -f Vendor/opus/lib/libopus.a ]]; then
  SETBEAM_REBUILD_FFMPEG=1 scripts/build-runtime.sh
fi
mkdir -p Vendor/bin Vendor/licenses build/logs
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -I "$FFMPEG" Sources/SetbeamPreviewBridge/main.c \
  "$FFMPEG/libavformat/libavformat.a" "$FFMPEG/libavcodec/libavcodec.a" \
  "$FFMPEG/libswscale/libswscale.a" "$FFMPEG/libswresample/libswresample.a" \
  "$FFMPEG/libavutil/libavutil.a" Vendor/opus/lib/libopus.a \
  -framework VideoToolbox -framework CoreFoundation -framework CoreMedia \
  -framework CoreVideo -framework CoreServices -lz -lm -lpthread \
  -o Vendor/bin/setbeam-preview > build/logs/preview-bridge-build.log 2>&1 || { cat build/logs/preview-bridge-build.log; exit 1; }
if otool -L Vendor/bin/setbeam-preview | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/)' | grep -q .; then
  echo 'Non-system dynamic dependency in setbeam-preview' >&2
  exit 1
fi
# The separately linked LGPL executable is reproducible/relinkable from bundled sources.
cp Sources/SetbeamPreviewBridge/main.c Vendor/licenses/setbeam-preview.c
cp scripts/build-preview-bridge.sh Vendor/licenses/build-preview-bridge.sh
{
  echo 'setbeam-preview is a separate executable statically linked to the pinned LGPL FFmpeg and BSD Opus libraries.'
  echo 'Its complete MIT bridge source is setbeam-preview.c. Put that file at Sources/SetbeamPreviewBridge/main.c.'
  echo 'Put both build scripts and patch-avfoundation.py in scripts/, runtime-lock.json in the project root, and the matching source archives in Vendor/cache/.'
  echo 'Run scripts/build-preview-bridge.sh to rebuild or relink against modified compatible FFmpeg libraries. Replace Contents/Helpers/setbeam-preview and re-sign the app for local use.'
  echo 'The app communicates with this executable through stdout; FFmpeg is not linked into the Swift app.'
  xcrun clang --version
  shasum -a 256 Sources/SetbeamPreviewBridge/main.c Vendor/bin/setbeam-preview
  otool -L Vendor/bin/setbeam-preview
} > Vendor/licenses/setbeam-preview-build.txt
echo 'Timestamped native playback bridge ready.'
