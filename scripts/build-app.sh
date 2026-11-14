#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${SETBEAM_CONFIGURATION:-release}"
VERSION="${SETBEAM_VERSION:-0.2.0}"
BUILD_NUMBER="${SETBEAM_BUILD:-41}"
# Only published releases carry the update feed. Developer and QA builds never check for updates.
UPDATES="${SETBEAM_UPDATES:-0}"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p build/logs
if [[ ! -x Vendor/bin/ffmpeg || ! -x Vendor/bin/mediamtx ]] || ! Vendor/bin/ffmpeg -hide_banner -filters 2>&1 | grep -q ' select '; then
  scripts/build-runtime.sh
fi
scripts/build-preview-bridge.sh
swift build -c "$CONFIGURATION" > build/logs/app-build.log 2>&1 || { tail -n 70 build/logs/app-build.log; exit 1; }
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
swift scripts/make-icon.swift
iconutil --convert icns build/Setbeam.iconset --output build/Setbeam.icns
APP="$ROOT/build/Setbeam.app"
rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Helpers" "$APP/Contents/Resources/Fixtures" "$APP/Contents/Resources/Licenses/Sources"
cp "$BIN/Setbeam" "$APP/Contents/MacOS/Setbeam"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp Vendor/bin/ffmpeg Vendor/bin/ffprobe Vendor/bin/mediamtx Vendor/bin/setbeam-preview "$APP/Contents/Helpers/"
cp "$BIN/SetbeamSupervisor" "$APP/Contents/Helpers/setbeam-supervisor"
cp Sources/SetbeamApp/Resources/reader.js Sources/SetbeamApp/Resources/viewer.html Sources/SetbeamApp/Resources/expired.html Sources/SetbeamApp/Resources/viewer.css Sources/SetbeamApp/Resources/viewer.js Sources/SetbeamApp/Resources/keepawake.js Sources/SetbeamApp/Resources/pointers.js Sources/SetbeamApp/Resources/chat.js "$APP/Contents/Resources/"
cp Fixtures/Demo.mp4 Fixtures/Hold.mp4 "$APP/Contents/Resources/Fixtures/"
cp Fixtures/Compatibility-*.mp4 Fixtures/compatibility-notes.txt "$APP/Contents/Resources/Fixtures/"
cp Vendor/licenses/* "$APP/Contents/Resources/Licenses/"
cp LICENSE THIRD_PARTY_NOTICES.md runtime-lock.json "$APP/Contents/Resources/Licenses/"
cp Vendor/cache/ffmpeg-9.0.2.tar.xz Vendor/cache/ffmpeg-9.0.2.tar.xz.asc Vendor/cache/ffmpeg-devel.asc Vendor/cache/opus-1.6.1.tar.gz "$APP/Contents/Resources/Licenses/Sources/"
SETBEAM_VERSION="$VERSION" SETBEAM_BUILD="$BUILD_NUMBER" SETBEAM_UPDATES="$UPDATES" python3 - <<'PY'
from pathlib import Path
import os, plistlib
info={'CFBundleName':'Setbeam','CFBundleDisplayName':'Setbeam','CFBundleIdentifier':'app.setbeam.mac','CFBundleExecutable':'Setbeam','CFBundlePackageType':'APPL','CFBundleShortVersionString':os.environ['SETBEAM_VERSION'],'CFBundleVersion':os.environ['SETBEAM_BUILD'],'LSMinimumSystemVersion':'14.0','LSApplicationCategoryType':'public.app-category.video','NSHighResolutionCapable':True,'NSBonjourServices':['_rtsp._tcp.'],'NSCameraUseContinuityCameraDeviceType':True,'NSLocalNetworkUsageDescription':'Setbeam connects to transmission systems and network video sources to share feeds with viewers on your local network.','NSCameraUsageDescription':'Setbeam uses the USB camera or capture device you select for monitoring and sharing.','NSMicrophoneUsageDescription':'Setbeam uses audio from the capture input you select for feed monitoring and sharing.','NSLocationUsageDescription':'When you ask to see Wi-Fi names or enable transmitter rejoin, macOS requires Location access to identify those networks.','NSLocationWhenInUseUsageDescription':'When you ask to see Wi-Fi names or enable transmitter rejoin, macOS requires Location access to identify those networks.','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'Setbeam. Based on Holly Share, copyright 2026 Faini Made. See bundled notices.'}
icon=Path('build/Setbeam.icns')
if icon.exists():
    import shutil
    shutil.copy2(icon,'build/Setbeam.app/Contents/Resources/Setbeam.icns');info['CFBundleIconFile']='Setbeam'
if os.environ['SETBEAM_UPDATES']=='1':
    info.update(plistlib.loads(Path('scripts/signing/update-configuration.plist').read_bytes()))
with Path('build/Setbeam.app/Contents/Info.plist').open('wb') as output:plistlib.dump(info,output)
PY
SIGNING_IDENTITY="${SETBEAM_SIGNING_IDENTITY:--}"
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
codesign --verify --deep --strict "$APP"
echo "$APP"
if [[ "$SIGNING_IDENTITY" == - ]]; then echo 'Ad-hoc signed developer build. Not notarized.'; fi
