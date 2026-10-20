#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/logs
git diff --check
swift test > build/logs/swift-tests.log 2>&1 || { tail -n 70 build/logs/swift-tests.log; exit 1; }
if [[ -x Vendor/bin/ffmpeg && -x Vendor/bin/mediamtx ]]; then
  swift run --skip-build SetbeamProbe --tools "${SETBEAM_TEST_TOOLS:-$ROOT/Vendor/bin}" --fixtures "${SETBEAM_TEST_FIXTURES:-$ROOT/Fixtures}" > build/logs/media-integration.log 2>&1 || { cat build/logs/media-integration.log; exit 1; }
  cat build/logs/media-integration.log
else
  echo 'Media integration not run: build the bundled runtime first.'
  exit 1
fi
echo 'Swift and media checks passed. Native, browser, and physical checks are separate.'
