#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${SETBEAM_CONFIGURATION:-release}"
VERSION="${SETBEAM_VERSION:-0.3.1}"
BUILD_NUMBER="${SETBEAM_BUILD:-43}"
# Only published releases carry the update feed. Developer and QA builds never check for updates.
UPDATES="${SETBEAM_UPDATES:-0}"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -z "${SETBEAM_BUILD_LOCK_FD:-}" ]]; then
  exec python3 scripts/build-support.py lock "$ROOT/scripts/build-app.sh" "$@"
fi
SIGNING_IDENTITY="${SETBEAM_SIGNING_IDENTITY:--}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] ||
  { echo 'Use a numeric version and positive build number.' >&2; exit 1; }
[[ "$SIGNING_IDENTITY" == - || "$SIGNING_IDENTITY" =~ ^[A-F0-9]{40}$ ]] ||
  { echo 'Use a Developer ID certificate fingerprint or an ad-hoc signature.' >&2; exit 1; }
if [[ "$UPDATES" == 1 ]]; then
  [[ "$SIGNING_IDENTITY" != - && "${SETBEAM_SOURCE_COMMIT:-}" =~ ^[a-f0-9]{40}$ ]] ||
    { echo 'Use release.py to build with updates.' >&2; exit 1; }
elif [[ "$UPDATES" != 0 ]]; then
  echo 'SETBEAM_UPDATES must be 0 or 1.' >&2; exit 1
fi
target="${SETBEAM_APP_OUTPUT:-$ROOT/build/Setbeam.app}"
scratch="$(mktemp -d "$(dirname "$target")/.setbeam-app.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
APP="$scratch/Setbeam.app"
export TMPDIR="$scratch/tmp"
mkdir "$TMPDIR"
for folder in .build .build/cache; do
  [[ ! -L "$folder" && ( ! -e "$folder" || -O "$folder" ) ]] ||
    { echo "Expected an owned SwiftPM directory at $folder." >&2; exit 1; }
  mkdir -p "$folder"
  chmod 700 "$folder"
done
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/swift-module-cache"
scripts/build-preview-bridge.sh
swift build -c "$CONFIGURATION" --force-resolved-versions --disable-dependency-cache --cache-path "$ROOT/.build/cache" > build/logs/app-build.log 2>&1 ||
  { tail -n 70 build/logs/app-build.log; exit 1; }
BIN="$(swift build -c "$CONFIGURATION" --force-resolved-versions --disable-dependency-cache --cache-path "$ROOT/.build/cache" --show-bin-path)"
swift scripts/make-icon.swift "$scratch/Setbeam.iconset"
iconutil --convert icns "$scratch/Setbeam.iconset" --output "$scratch/Setbeam.icns"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Helpers" "$APP/Contents/Resources/Fixtures" "$APP/Contents/Resources/Licenses/Sources"
cp "$BIN/Setbeam" "$APP/Contents/MacOS/Setbeam"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp Vendor/bin/ffmpeg Vendor/bin/ffprobe Vendor/bin/mediamtx Vendor/bin/setbeam-preview "$APP/Contents/Helpers/"
cp "$BIN/SetbeamSupervisor" "$APP/Contents/Helpers/setbeam-supervisor"
# SwiftPM can add its build toolchain's compatibility-library search path.
# Keep the bundle and system paths, and audit the resulting load commands below.
swift_toolchain_lib="$(cd "$(dirname "$(xcrun --find swift)")/../lib" && pwd -P)"
for binary in "$APP/Contents/MacOS/Setbeam" "$APP/Contents/Helpers/setbeam-supervisor"; do
  rpaths="$(otool -l "$binary" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
    rpath && $1 == "path" {
      sub(/^[[:space:]]*path[[:space:]]+/, ""); sub(/[[:space:]]+\(offset [0-9]+\)$/, ""); print; rpath = 0
    }')"
  while IFS= read -r rpath; do
    case "$rpath" in "$swift_toolchain_lib"/swift*) install_name_tool -delete_rpath "$rpath" "$binary";; esac
  done <<< "$rpaths"
done
cp Sources/SetbeamApp/Resources/reader.js Sources/SetbeamApp/Resources/viewer.html Sources/SetbeamApp/Resources/expired.html Sources/SetbeamApp/Resources/viewer.css Sources/SetbeamApp/Resources/viewer.js Sources/SetbeamApp/Resources/keepawake.js Sources/SetbeamApp/Resources/pointers.js Sources/SetbeamApp/Resources/chat.js "$APP/Contents/Resources/"
cp Fixtures/Demo.mp4 Fixtures/Hold.mp4 "$APP/Contents/Resources/Fixtures/"
cp Fixtures/Compatibility-*.mp4 Fixtures/compatibility-notes.txt "$APP/Contents/Resources/Fixtures/"
for name in MediaMTX-MIT.txt Opus-BSD.txt FFmpeg-LGPL-2.1.txt FFmpeg-build-configuration.txt \
  build-runtime.sh build-support.py patch-avfoundation.py setbeam-preview.c build-preview-bridge.sh setbeam-preview-build.txt; do
  cp "Vendor/licenses/$name" "$APP/Contents/Resources/Licenses/"
done
cp Vendor/runtime-provenance.json "$APP/Contents/Resources/Licenses/"
cp LICENSE THIRD_PARTY_NOTICES.md runtime-lock.json "$APP/Contents/Resources/Licenses/"
mkdir "$APP/Contents/Resources/Licenses/MediaMTX"
cp licenses/mediamtx/{manifest.json,buildinfo.txt,notices.txt} "$APP/Contents/Resources/Licenses/MediaMTX/"
python3 scripts/audit-app.py "$APP" --check-mediamtx-before-signing
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
cp Vendor/cache/ffmpeg-9.0.2.tar.xz Vendor/cache/ffmpeg-9.0.2.tar.xz.asc Vendor/cache/ffmpeg-devel.asc Vendor/cache/opus-1.6.1.tar.gz "$APP/Contents/Resources/Licenses/Sources/"
SETBEAM_VERSION="$VERSION" SETBEAM_BUILD="$BUILD_NUMBER" SETBEAM_UPDATES="$UPDATES" python3 - "$APP" "$scratch/Setbeam.icns" <<'PY'
from pathlib import Path
import os, plistlib, shutil, sys
info={'CFBundleName':'Setbeam','CFBundleDisplayName':'Setbeam','CFBundleIdentifier':'app.setbeam.mac','CFBundleExecutable':'Setbeam','CFBundlePackageType':'APPL','CFBundleShortVersionString':os.environ['SETBEAM_VERSION'],'CFBundleVersion':os.environ['SETBEAM_BUILD'],'LSMinimumSystemVersion':'14.0','LSApplicationCategoryType':'public.app-category.video','NSHighResolutionCapable':True,'NSBonjourServices':['_rtsp._tcp.','_setbeam._tcp.'],'NSCameraUseContinuityCameraDeviceType':True,'NSLocalNetworkUsageDescription':'Setbeam connects to transmission systems and network video sources to share feeds with viewers on your local network.','NSCameraUsageDescription':'Setbeam uses the USB camera or capture device you select for monitoring and sharing.','NSMicrophoneUsageDescription':'Setbeam uses audio from the capture input you select for feed monitoring and sharing.','NSLocationUsageDescription':'Setbeam uses Location access to verify Pyro H Wi-Fi, show Wi-Fi names, or rejoin a transmitter when you enable it.','NSLocationWhenInUseUsageDescription':'Setbeam uses Location access to verify Pyro H Wi-Fi, show Wi-Fi names, or rejoin a transmitter when you enable it.','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'Setbeam. Based on Holly Share, copyright 2026 Faini Made. See bundled notices.'}
app = Path(sys.argv[1])
shutil.copy2(sys.argv[2], app / 'Contents/Resources/Setbeam.icns')
info['CFBundleIconFile'] = 'Setbeam'
if os.environ['SETBEAM_UPDATES'] == '1':
    info.update(plistlib.loads(Path('scripts/signing/update-configuration.plist').read_bytes()))
    info['SetbeamSourceCommit'] = os.environ['SETBEAM_SOURCE_COMMIT']
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump(info, output)
PY
# The scratch directory is private. The finished bundle can be installed for all users.
find "$APP" -type d -exec chmod 755 {} +
find "$APP" -type f -perm -100 -exec chmod 755 {} +
find "$APP" -type f ! -perm -100 -exec chmod 644 {} +
# Developer ID builds use the hardened runtime and a secure timestamp, as notarization requires.
SIGN=(codesign --force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != - ]]; then SIGN+=(--options runtime --timestamp); fi
ENTITLEMENTS="$ROOT/scripts/signing"
# Sparkle's nested code is signed inside out. Its downloader keeps its own sandbox entitlements.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Updater.app"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FRAMEWORK"
for helper in "$APP"/Contents/Helpers/*; do
  name="$(basename "$helper")"
  if [[ "$name" == ffmpeg ]]; then
    # ffmpeg opens the selected camera, capture device and audio input itself.
    "${SIGN[@]}" --entitlements "$ENTITLEMENTS/capture.entitlements" --identifier "app.setbeam.$name" "$helper"
  else
    "${SIGN[@]}" --identifier "app.setbeam.$name" "$helper"
  fi
done
"${SIGN[@]}" --entitlements "$ENTITLEMENTS/app.entitlements" --identifier app.setbeam.mac "$APP"
python3 scripts/audit-app.py "$APP" --identity "$SIGNING_IDENTITY"
python3 scripts/build-support.py install-app "$APP" "$target"
echo "$target"
if [[ "$SIGNING_IDENTITY" == - ]]; then echo 'Ad-hoc signed developer build. Not notarized.'; fi
