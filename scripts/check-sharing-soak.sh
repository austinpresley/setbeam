#!/bin/bash
# Run locally with Playwright and the bundled media helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
seconds="${1:-7200}"
if [[ $# -gt 1 || ! "$seconds" =~ ^[1-9][0-9]{1,4}$ ]] || (( seconds < 30 || seconds > 14400 )); then
  echo 'Usage: scripts/check-sharing-soak.sh [live-seconds, 30 through 14400]' >&2
  exit 2
fi
tools="${SETBEAM_TEST_TOOLS:-$PWD/Vendor/bin}"
packaged="$PWD/build/Setbeam.app/Contents/Helpers"
if [[ -z "${SETBEAM_TEST_TOOLS:-}" && ! -x "$tools/setbeam-supervisor" && -x "$packaged/setbeam-supervisor" ]]; then
  tools="$packaged"
fi
tools="$(cd "$tools" && pwd -P)"
fixtures="$PWD/Fixtures"
if [[ "$tools" == */Contents/Helpers ]]; then
  fixtures="$tools/../Resources/Fixtures"
fi
fixtures="$(cd "${SETBEAM_TEST_FIXTURES:-$fixtures}" && pwd -P)"
if [[ ! -r "$fixtures/Hold.mp4" ]]; then
  echo "Missing fixture $fixtures/Hold.mp4" >&2
  exit 2
fi
for helper in ffmpeg ffprobe mediamtx setbeam-preview setbeam-supervisor; do
  if [[ ! -x "$tools/$helper" ]]; then
    echo "Missing $tools/$helper. Build Setbeam or set SETBEAM_TEST_TOOLS to the packaged helpers." >&2
    exit 2
  fi
done
if ! node="$(command -v node)" || [[ ! -x "$node" ]]; then
  echo 'Node.js is required.' >&2
  exit 2
fi
# Resolve from the viewer script so a project-local install and an absolute override both work.
export PLAYWRIGHT_MODULE
PLAYWRIGHT_MODULE="$("$node" -e '
  const {createRequire} = require("node:module");
  const {resolve} = require("node:path");
  console.log(createRequire(resolve("scripts/check-sharing-memory-browser.js"))
    .resolve(process.env.PLAYWRIGHT_MODULE || "playwright-core"));
')"
export SETBEAM_TEST_CHROME="${SETBEAM_TEST_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [[ "$SETBEAM_TEST_CHROME" != /* || ! -x "$SETBEAM_TEST_CHROME" ]]; then
  echo 'Set SETBEAM_TEST_CHROME to the absolute path of the Chrome executable.' >&2
  exit 2
fi

mkdir -p build/logs
umask 077
report="$(mktemp -d "$PWD/build/logs/sharing-soak.XXXXXX")"
echo "Evidence directory: $report"
shasum -a 256 "$tools/"{ffmpeg,ffprobe,mediamtx,setbeam-preview,setbeam-supervisor} "$fixtures/Hold.mp4" | tee "$report/inputs.sha256"
SETBEAM_TEST_TOOLS="$tools" SETBEAM_TEST_FIXTURES="$fixtures" SETBEAM_REAL_MEDIA_SECONDS="$seconds" SETBEAM_REAL_MEDIA_REPORT_DIR="$report" SETBEAM_REAL_MEDIA_NODE="$node" \
  /usr/bin/caffeinate -i swift test --scratch-path "$PWD/.build/sharing-soak" -c release \
    --filter SharingMediaSoakTests 2>&1 | tee "$report/run.log"
if ! grep -q '"event":"passed"' "$report/mac.ndjson" || ! grep -q '"passed":true' "$report/browser.ndjson"; then
  echo "Missing completion evidence in $report." >&2
  exit 1
fi
