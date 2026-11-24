#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -z "${SETBEAM_BUILD_LOCK_FD:-}" ]]; then
  exec python3 scripts/build-support.py lock "$ROOT/scripts/build-preview-bridge.sh" "$@"
fi
scripts/build-runtime.sh
FFMPEG="$ROOT/Vendor/sources/ffmpeg-9.0.2"
scratch="$(mktemp -d "$ROOT/Vendor/.preview.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -I "$FFMPEG" Sources/SetbeamPreviewBridge/main.c \
  "$FFMPEG/libavformat/libavformat.a" "$FFMPEG/libavcodec/libavcodec.a" \
  "$FFMPEG/libswscale/libswscale.a" "$FFMPEG/libswresample/libswresample.a" \
  "$FFMPEG/libavutil/libavutil.a" Vendor/opus/lib/libopus.a \
  -framework VideoToolbox -framework CoreFoundation -framework CoreMedia \
  -framework CoreVideo -framework CoreServices -lz -lm -lpthread \
  -o "$scratch/setbeam-preview" > build/logs/preview-bridge-build.log 2>&1 || { cat build/logs/preview-bridge-build.log; exit 1; }
links="$(otool -L "$scratch/setbeam-preview")"
if awk 'NR > 1 && $1 !~ /^\/(System\/Library|usr\/lib)\// {print; bad=1} END {exit !bad}' <<< "$links"; then
  echo 'Non-system dynamic dependency in setbeam-preview' >&2
  exit 1
fi
mv -f "$scratch/setbeam-preview" Vendor/bin/setbeam-preview
# The separately linked LGPL executable is reproducible/relinkable from bundled sources.
cp Sources/SetbeamPreviewBridge/main.c Vendor/licenses/setbeam-preview.c
cp scripts/build-preview-bridge.sh Vendor/licenses/build-preview-bridge.sh
{
  echo 'setbeam-preview is a separate executable statically linked to the pinned LGPL FFmpeg and BSD Opus libraries.'
  echo 'Its complete MIT bridge source is setbeam-preview.c. Put that file at Sources/SetbeamPreviewBridge/main.c.'
  echo 'Put both build scripts, build-support.py and patch-avfoundation.py in scripts/, runtime-lock.json in the project root, and the matching source archives in Vendor/cache/.'
  echo 'Run scripts/build-preview-bridge.sh to rebuild or relink against modified compatible FFmpeg libraries. Replace Contents/Helpers/setbeam-preview and re-sign the app for local use.'
  echo 'The app communicates with this executable through stdout; FFmpeg is not linked into the Swift app.'
  xcrun clang --version
  shasum -a 256 Sources/SetbeamPreviewBridge/main.c Vendor/bin/setbeam-preview
  otool -L Vendor/bin/setbeam-preview
} > Vendor/licenses/setbeam-preview-build.txt
echo 'Timestamped native playback bridge ready.'
