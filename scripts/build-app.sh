#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${SETBEAM_CONFIGURATION:-release}"
mkdir -p build/logs
[[ -x Vendor/bin/ffmpeg && -x Vendor/bin/mediamtx ]] || scripts/build-runtime.sh
swift build -c "$CONFIGURATION" > build/logs/app-build.log 2>&1 || { tail -n 70 build/logs/app-build.log; exit 1; }
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
swift scripts/make-icon.swift
iconutil --convert icns build/Setbeam.iconset --output build/Setbeam.icns
APP="$ROOT/build/Setbeam.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Fixtures" "$APP/Contents/Resources/Licenses/Sources"
cp "$BIN/Setbeam" "$APP/Contents/MacOS/Setbeam"
cp Vendor/bin/ffmpeg Vendor/bin/ffprobe Vendor/bin/mediamtx "$APP/Contents/Helpers/"
cp "$BIN/SetbeamSupervisor" "$APP/Contents/Helpers/setbeam-supervisor"
cp Sources/SetbeamApp/Resources/reader.js Sources/SetbeamApp/Resources/viewer.html Sources/SetbeamApp/Resources/viewer.css Sources/SetbeamApp/Resources/viewer.js "$APP/Contents/Resources/"
cp Fixtures/Demo.mp4 Fixtures/Hold.mp4 "$APP/Contents/Resources/Fixtures/"
cp Vendor/licenses/* "$APP/Contents/Resources/Licenses/"
cp LICENSE THIRD_PARTY_NOTICES.md runtime-lock.json "$APP/Contents/Resources/Licenses/"
cp Vendor/cache/ffmpeg-9.0.2.tar.xz Vendor/cache/ffmpeg-9.0.2.tar.xz.asc Vendor/cache/ffmpeg-devel.asc Vendor/cache/opus-1.6.1.tar.gz "$APP/Contents/Resources/Licenses/Sources/"
python3 - <<'PY'
from pathlib import Path
import plistlib
info={'CFBundleName':'Setbeam','CFBundleDisplayName':'Setbeam','CFBundleIdentifier':'app.setbeam.mac','CFBundleExecutable':'Setbeam','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'2','LSMinimumSystemVersion':'14.0','LSApplicationCategoryType':'public.app-category.video','NSHighResolutionCapable':True,'NSLocalNetworkUsageDescription':'Setbeam connects to transmission systems and network video sources to share feeds with viewers on your local network.','NSCameraUsageDescription':'Setbeam uses the USB camera or capture device you select for monitoring and sharing.','NSMicrophoneUsageDescription':'Setbeam uses audio from the capture input you select for feed monitoring and sharing.','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'Setbeam. Based on Holly Share, copyright 2026 Faini Made. See bundled notices.'}
icon=Path('build/Setbeam.icns')
if icon.exists():
    import shutil
    shutil.copy2(icon,'build/Setbeam.app/Contents/Resources/Setbeam.icns');info['CFBundleIconFile']='Setbeam'
with Path('build/Setbeam.app/Contents/Info.plist').open('wb') as output:plistlib.dump(info,output)
PY
SIGNING_IDENTITY="${SETBEAM_SIGNING_IDENTITY:--}"
for helper in "$APP"/Contents/Helpers/*; do
  codesign --force --sign "$SIGNING_IDENTITY" --identifier "app.setbeam.$(basename "$helper")" "$helper"
done
codesign --force --sign "$SIGNING_IDENTITY" --identifier app.setbeam.mac "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
if [[ "$SIGNING_IDENTITY" == - ]]; then echo 'Ad-hoc signed developer build. Not notarized.'; fi
