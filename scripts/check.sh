#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/logs
git diff --check
scripts/build-preview-bridge.sh
python3 scripts/check-preview-bridge.py --tools "${SETBEAM_TEST_TOOLS:-$ROOT/Vendor/bin}" > build/logs/preview-bridge-integration.log 2>&1 || { cat build/logs/preview-bridge-integration.log; exit 1; }
cat build/logs/preview-bridge-integration.log
node --test scripts/check-viewer-recovery.js > build/logs/viewer-recovery.log 2>&1 || { cat build/logs/viewer-recovery.log; exit 1; }
swift test > build/logs/swift-tests.log 2>&1 || { tail -n 70 build/logs/swift-tests.log; exit 1; }
if [[ -x Vendor/bin/ffmpeg && -x Vendor/bin/mediamtx ]]; then
  swift run --skip-build SetbeamProbe --tools "${SETBEAM_TEST_TOOLS:-$ROOT/Vendor/bin}" --fixtures "${SETBEAM_TEST_FIXTURES:-$ROOT/Fixtures}" > build/logs/media-integration.log 2>&1 || { cat build/logs/media-integration.log; exit 1; }
  cat build/logs/media-integration.log
  swift run --skip-build SetbeamProbe --recovery-test --tools "${SETBEAM_TEST_TOOLS:-$ROOT/Vendor/bin}" --fixtures "${SETBEAM_TEST_FIXTURES:-$ROOT/Fixtures}" > build/logs/source-recovery.log 2>&1 || { cat build/logs/source-recovery.log; exit 1; }
  cat build/logs/source-recovery.log
  swift run --skip-build SetbeamProbe --safety-test --tools "${SETBEAM_TEST_TOOLS:-$ROOT/Vendor/bin}" --fixtures "${SETBEAM_TEST_FIXTURES:-$ROOT/Fixtures}" > build/logs/source-switching.log 2>&1 || { cat build/logs/source-switching.log; exit 1; }
  cat build/logs/source-switching.log
  swift run --skip-build SetbeamProbe --format-test --tools "${SETBEAM_TEST_TOOLS:-$ROOT/Vendor/bin}" --fixtures "${SETBEAM_TEST_FIXTURES:-$ROOT/Fixtures}" > build/logs/media-formats.log 2>&1 || { cat build/logs/media-formats.log; exit 1; }
  cat build/logs/media-formats.log
else
  echo 'Media integration not run: build the bundled runtime first.'
  exit 1
fi
echo 'Swift and media checks passed. Native, browser, and physical checks are separate.'
