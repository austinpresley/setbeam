#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/logs
git diff --check
python3 -m unittest discover -s Tests/SetbeamPreviewBridgeTests > build/logs/preview-timing-tests.log 2>&1 || { cat build/logs/preview-timing-tests.log; exit 1; }
cat build/logs/preview-timing-tests.log
python3 -I -m unittest discover -s Tests/SetbeamReleaseTests > build/logs/release-tests.log 2>&1 || { cat build/logs/release-tests.log; exit 1; }
cat build/logs/release-tests.log
node --test scripts/check-viewer-recovery.js > build/logs/viewer-recovery.log 2>&1 || { cat build/logs/viewer-recovery.log; exit 1; }
node --test scripts/check-viewer-pointers.js > build/logs/viewer-pointers.log 2>&1 || { cat build/logs/viewer-pointers.log; exit 1; }
node --test scripts/check-chat-audit.js > build/logs/chat-audit.log 2>&1 || { cat build/logs/chat-audit.log; exit 1; }
if [[ -z "${SETBEAM_TEST_TOOLS:-}" ]]; then
  scripts/build-preview-bridge.sh
fi
SETBEAM_TEST_TOOLS="$(cd "${SETBEAM_TEST_TOOLS:-$ROOT/Vendor/bin}" && pwd -P)"
fixtures="$ROOT/Fixtures"
if [[ "$SETBEAM_TEST_TOOLS" == */Contents/Helpers ]]; then
  fixtures="$SETBEAM_TEST_TOOLS/../Resources/Fixtures"
fi
SETBEAM_TEST_FIXTURES="$(cd "${SETBEAM_TEST_FIXTURES:-$fixtures}" && pwd -P)"
export SETBEAM_TEST_TOOLS SETBEAM_TEST_FIXTURES
for helper in ffmpeg ffprobe mediamtx setbeam-preview; do
  if [[ ! -x "$SETBEAM_TEST_TOOLS/$helper" ]]; then
    echo "Missing executable $SETBEAM_TEST_TOOLS/$helper" >&2
    exit 1
  fi
done
for fixture in Demo.mp4 Hold.mp4 Compatibility-H264.mp4 Compatibility-HEVC.mp4; do
  if [[ ! -r "$SETBEAM_TEST_FIXTURES/$fixture" ]]; then
    echo "Missing fixture $SETBEAM_TEST_FIXTURES/$fixture" >&2
    exit 1
  fi
done
{
  echo "Checkout Swift tests and probes using $SETBEAM_TEST_TOOLS and $SETBEAM_TEST_FIXTURES"
  shasum -a 256 "$SETBEAM_TEST_TOOLS/"{ffmpeg,ffprobe,mediamtx,setbeam-preview}
  if [[ -x "$SETBEAM_TEST_TOOLS/setbeam-supervisor" ]]; then
    shasum -a 256 "$SETBEAM_TEST_TOOLS/setbeam-supervisor"
  else
    echo 'Packaged supervisor unavailable. Media tests use directly owned helpers.'
  fi
  shasum -a 256 "$SETBEAM_TEST_FIXTURES/"{Demo,Hold,Compatibility-H264,Compatibility-HEVC}.mp4
} | tee build/logs/check-inputs.log
python3 scripts/check-preview-bridge.py --tools "$SETBEAM_TEST_TOOLS" > build/logs/preview-bridge-integration.log 2>&1 || { cat build/logs/preview-bridge-integration.log; exit 1; }
cat build/logs/preview-bridge-integration.log
swift test > build/logs/swift-tests.log 2>&1 || { tail -n 70 build/logs/swift-tests.log; exit 1; }
probe() {
  local log="$1"
  shift
  swift run --skip-build SetbeamProbe --tools "$SETBEAM_TEST_TOOLS" --fixtures "$SETBEAM_TEST_FIXTURES" "$@" > "build/logs/$log.log" 2>&1 || {
    cat "build/logs/$log.log"
    exit 1
  }
  cat "build/logs/$log.log"
}
probe pyro-h-integration --pyro-h-test
probe media-integration
probe source-recovery --recovery-test
probe viewer-access --access-test
probe local-address --local-address-test
probe short-address --short-address-test
probe source-switching --safety-test
probe media-formats --format-test
probe frame-rates --frame-rate-test
probe keyframe-bursts --keyframe-test
echo 'Swift and media checks passed. Native UI, browser, exact package, and physical checks are separate.'
