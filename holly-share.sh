#!/usr/bin/env bash
# holly-share.sh — find the Hollyland transmitter's RTSP stream, re-serve it
# with MediaMTX, and show QR codes so phones can watch it in a browser.
#
# Usage:
#   ./holly-share.sh                         # auto-detect everything
#   ./holly-share.sh --ssid "HL-PYRO-1234" --wifi-pass "12345678"
#                                            # add a "join this Wi-Fi" QR (the network viewers
#                                            # should join: the hotspot or your venue Wi-Fi)
#   ./holly-share.sh --ip 192.168.218.10     # transmitter IP, if auto-detect fails
#   ./holly-share.sh --share-ip 10.0.0.42    # address viewers should use
#   ./holly-share.sh --no-open               # don't open the QR page
#
# Needs: brew install ffmpeg mediamtx qrencode
# The QR page's text is in share-page.html next to this script (made on first run).
# Stop with Ctrl+C.

set -euo pipefail

# Find Homebrew's tools even when started by double-click.
for d in /opt/homebrew/bin /usr/local/bin; do
  if [ -d "$d" ]; then PATH="$d:$PATH"; fi
done

TX_IP=""
TX_PORT=""
SHARE_IP=""
SSID="${HOLLY_SSID:-}"
WIFI_PASS="${HOLLY_WIFI_PASS:-}"
OPEN_PAGE=1
PORTS_TO_TRY="5554 554 8554"   # 5554 is the Pyro H; the rest are common defaults

die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[36m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ip)        TX_IP="$2"; shift 2 ;;
    --port)      TX_PORT="$2"; shift 2 ;;
    --share-ip)  SHARE_IP="$2"; shift 2 ;;
    --ssid)      SSID="$2"; shift 2 ;;
    --wifi-pass) WIFI_PASS="$2"; shift 2 ;;
    --no-open)   OPEN_PAGE=0; shift ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "Unknown option: $1 (try --help)" ;;
  esac
done

# Default share-page.html, written next to the script on first run.
write_default_template() {
cat <<'EOF'
<!doctype html>
<!--
  share-page.html: the page holly-share.sh shows with the QR codes.
  Change any text or style here. Keep the names in double curly braces below:
  the script swaps them for the real QR codes and links.
    WATCH_QR   QR code that opens the stream     WATCH_URL  its link
    WIFI_QR    QR code that joins the Wi-Fi       WIFI_NAME  the network's name
    HLS_URL    fallback link for browsers         RTSP_URL   link for VLC or OBS
  Anything with class="wifi-only" shows only when you run with --ssid.
  Delete this file to get the default back.
-->
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Watch the Camera</title>
<style>
  :root { --bg:#f6f5f2; --card:#fff; --ink:#1b1b1b; --muted:#6b6b6b; --accent:#d4502a; }
  @media (prefers-color-scheme: dark) { :root { --bg:#141414; --card:#1f1f1f; --ink:#f2f2f2; --muted:#9a9a9a; } }
  * { box-sizing:border-box }
  body { margin:0; background:var(--bg); color:var(--ink); font:16px/1.4 -apple-system,system-ui,sans-serif;
         min-height:100vh; display:flex; flex-direction:column; align-items:center; justify-content:center; padding:24px 16px; }
  h1 { font-size:clamp(28px,5vw,48px); margin:0 0 4px; letter-spacing:-.02em; text-align:center }
  .sub { color:var(--muted); margin:0 0 32px; text-align:center }
  main { width:100%; display:flex; gap:32px; flex-wrap:wrap; justify-content:center; align-items:flex-start }
  section { background:var(--card); border-radius:20px; padding:28px; width:min(400px,100%); text-align:center;
            box-shadow:0 1px 3px rgba(0,0,0,.08) }
  h2 { margin:0 0 20px; font-size:22px; display:flex; align-items:center; justify-content:center; gap:10px }
  .step { background:var(--accent); color:#fff; border-radius:50%; width:30px; height:30px; display:none; place-items:center; font-size:16px }
  .wifi-only { display:none }
  .has-wifi .wifi-only { display:block }
  .has-wifi .step { display:inline-grid }
  svg { width:100%; height:auto; background:#fff; border-radius:12px }
  .url { font:15px ui-monospace,Menlo,monospace; color:var(--muted); word-break:break-all; margin:16px 0 0 }
  footer { margin-top:32px; color:var(--muted); font-size:14px; text-align:center; max-width:720px }
  .credit { margin:16px 0 0; color:var(--muted); font-size:13px; text-align:center }
  .credit a { color:inherit }
</style></head>
<body class="{{WIFI_CLASS}}">
<h1>Watch the camera</h1>
<p class="sub">Scan with your phone's camera. Tap the speaker icon for sound.</p>
<main>
  <section class="wifi-only">
    <h2><span class="step">1</span>Join the Wi-Fi</h2>
    {{WIFI_QR}}
    <p class="url">{{WIFI_NAME}}</p>
  </section>
  <section>
    <h2><span class="step">2</span>Open the stream</h2>
    {{WATCH_QR}}
    <p class="url">{{WATCH_URL}}</p>
  </section>
</main>
<footer>Not loading? Try {{HLS_URL}} (a few seconds more delay)<br>VLC: {{RTSP_URL}}</footer>
<p class="credit">Made possible by <a href="https://fainimade.com">Faini Made</a> · <a href="https://github.com/titleunknown/holly-share">Open source on GitHub</a></p>
</body></html>
EOF
}

# --- 1. Tools --------------------------------------------------------------
missing=""
for t in ffmpeg mediamtx qrencode nc; do
  command -v "$t" >/dev/null || missing="$missing $t"
done
[ -z "$missing" ] || die "Missing:$missing — install with: brew install$missing"

for p in 8554 8888 8889 1935; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port $p is already in use (another MediaMTX? try: brew services stop mediamtx; pkill mediamtx)"
  fi
done

# --- 2. Find the transmitter ------------------------------------------------
WIFI_IF=$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}' || true)
WIFI_IF=${WIFI_IF:-en0}
HOTSPOT_IP=$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null || true)

if [ -z "$TX_IP" ]; then
  TX_IP=$(ipconfig getoption "$WIFI_IF" router 2>/dev/null || true)
  [ -n "$TX_IP" ] || die "Wi-Fi ($WIFI_IF) has no router. Join the transmitter's hotspot, or pass --ip."
fi

rtsp_ok() {
  printf 'OPTIONS rtsp://%s:%s/live RTSP/1.0\r\nCSeq: 1\r\n\r\n' "$1" "$2" \
    | nc -G 2 -w 2 "$1" "$2" 2>/dev/null | head -1 | grep -q 'RTSP/1.0 200'
}

info "Looking for RTSP on $TX_IP..."
if [ -n "$TX_PORT" ]; then
  rtsp_ok "$TX_IP" "$TX_PORT" || die "No RTSP answer on $TX_IP:$TX_PORT"
else
  for p in $PORTS_TO_TRY; do
    if rtsp_ok "$TX_IP" "$p"; then TX_PORT=$p; break; fi
  done
  [ -n "$TX_PORT" ] || die "No RTSP on $TX_IP (tried $PORTS_TO_TRY). Scan with: sudo nmap -p- -T4 --open $TX_IP, then pass --port"
fi
ok "Transmitter stream: rtsp://$TX_IP:$TX_PORT/live"

# --- 3. Pick the address viewers will use ----------------------------------
# Prefer a wired/LAN interface (viewers stay off the transmitter's hotspot);
# fall back to the hotspot address.
ADDRS=$(ifconfig | awk '/^[a-z]/{i=$1; sub(":","",i)} /inet /{print i, $2}' \
  | grep -v '^lo' | grep -v ' 169\.254\.' || true)

if [ -z "$SHARE_IP" ]; then
  SHARE_IP=$(echo "$ADDRS" | awk -v w="$WIFI_IF" \
    '$1!=w && $1!~/^utun/ && $2!~/^100\./ {print $2; exit}' || true)
  SHARE_IP=${SHARE_IP:-$HOTSPOT_IP}
fi
[ -n "$SHARE_IP" ] || die "Couldn't work out this Mac's IP. Pass --share-ip."

SHARE_IF=$(echo "$ADDRS" | awk -v s="$SHARE_IP" '$2==s {print $1; exit}' || true)
ON_HOTSPOT=0
[ "$SHARE_IP" = "$HOTSPOT_IP" ] && ON_HOTSPOT=1

# --- 4. MediaMTX config ----------------------------------------------------
# "cam"  = the transmitter feed as-is (H.264 + AAC) for HLS, RTSP, RTMP.
# "live" = same video, audio converted to Opus, because browsers' WebRTC
#          can't play AAC. This is the low-latency link the QR code opens.
RUN_DIR="${TMPDIR:-/tmp}/holly-share"
mkdir -p "$RUN_DIR"
CONF="$RUN_DIR/mediamtx.yml"

cat > "$CONF" <<EOF
logLevel: warn
api: yes
apiAddress: 127.0.0.1:9997
hlsVariant: mpegts
paths:
  cam:
    source: rtsp://$TX_IP:$TX_PORT/live
    rtspTransport: tcp
    runOnAvailable: ffmpeg -nostdin -loglevel error -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam -c:v copy -c:a libopus -b:a 96k -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
    runOnAvailableRestart: yes
  live: {}
EOF

# --- 5. URLs and QR codes --------------------------------------------------
WATCH_URL="http://$SHARE_IP:8889/live"
HLS_URL="http://$SHARE_IP:8888/cam"
RTSP_URL="rtsp://$SHARE_IP:8554/cam"
RTMP_URL="rtmp://$SHARE_IP/cam"

wifi_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//;/\\;}; s=${s//,/\\,}; s=${s//:/\\:}; s=${s//\"/\\\"}; printf '%s' "$s"; }
html_escape() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }

WIFI_QR=""
if [ -n "$SSID" ]; then
  WIFI_QR="WIFI:T:WPA;S:$(wifi_escape "$SSID");P:$(wifi_escape "$WIFI_PASS");;"
fi

qrencode -t PNG -s 12 -m 2 -o "$RUN_DIR/watch-qr.png" "$WATCH_URL"
WATCH_SVG=$(qrencode -t SVG --inline --svg-path -m 2 -o - "$WATCH_URL")
WIFI_SVG=""
[ -n "$WIFI_QR" ] && WIFI_SVG=$(qrencode -t SVG --inline --svg-path -m 2 -o - "$WIFI_QR")

# The page's text and look live in share-page.html next to this script, so
# they can be edited without touching the script. First run writes the default.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/share-page.html"
if [ ! -f "$TEMPLATE" ]; then
  write_default_template > "$TEMPLATE"
  info "Created share-page.html next to the script. Edit it to change the page's text."
fi

shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2+: keep "&" literal in replacements
page=$(cat "$TEMPLATE")
fill() { page=${page//"{{$1}}"/$2}; }
fill WATCH_QR   "$WATCH_SVG"
fill WATCH_URL  "$WATCH_URL"
fill WIFI_QR    "$WIFI_SVG"
fill WIFI_NAME  "$(html_escape "$SSID")"
fill WIFI_CLASS "$([ -n "$WIFI_QR" ] && echo has-wifi)"
fill HLS_URL    "$HLS_URL"
fill RTSP_URL   "$RTSP_URL"
printf '%s\n' "$page" > "$RUN_DIR/share.html"

# --- 6. Start MediaMTX ------------------------------------------------------
info "Starting MediaMTX..."
(cd "$RUN_DIR" && exec mediamtx "$CONF") &   # run there so its auto-generated cert stays out of this folder
MTX_PID=$!
trap 'echo; info "Stopping..."; kill $MTX_PID 2>/dev/null; wait $MTX_PID 2>/dev/null; ok "Stopped."; exit 0' INT TERM

ready() { curl -fs "http://127.0.0.1:9997/v3/paths/get/$1" 2>/dev/null | grep -q '"ready":true'; }
for _ in $(seq 1 30); do
  kill -0 $MTX_PID 2>/dev/null || die "MediaMTX exited — see the errors above."
  ready cam && ready live && break
  sleep 0.5
done
if ready live; then ok "Stream is live"; else warn "Stream not ready yet — it may take a few more seconds."; fi

# --- 7. Show it -------------------------------------------------------------
echo
echo "  Sharing on ${SHARE_IF:-?} ($SHARE_IP)"
[ -n "$WIFI_QR" ] && { echo "  1) Join Wi-Fi \"$SSID\":"; qrencode -t ANSIUTF8 -m 2 "$WIFI_QR"; echo "  2) Then open:"; }
qrencode -t ANSIUTF8 -m 2 "$WATCH_URL"
cat <<EOF
  Phones / browsers (low delay):  $WATCH_URL
  Fallback (HLS, ~5 s delay):     $HLS_URL
  VLC / OBS (RTSP):               $RTSP_URL
  RTMP:                           $RTMP_URL

  QR page:  $RUN_DIR/share.html
  QR image: $RUN_DIR/watch-qr.png
EOF

if [ "$ON_HOTSPOT" = 1 ]; then
  echo
  warn "Viewers must be on the transmitter's Wi-Fi hotspot to reach $SHARE_IP."
  warn "That hotspot is 2.4 GHz and each viewer adds ~3 Mbps, so keep it to a few people."
  [ -z "$WIFI_QR" ] && warn "Add --ssid NAME --wifi-pass PASS to put a join-Wi-Fi QR on the page."
fi
other=$(echo "$ADDRS" | awk -v s="$SHARE_IP" '$2!=s {printf "    %-8s %s\n", $1, $2}')
[ -n "$other" ] && { echo; echo "  Other addresses for this Mac (use with --share-ip):"; echo "$other"; }

echo
info "Running. Press Ctrl+C to stop."
[ "$OPEN_PAGE" = 1 ] && open "$RUN_DIR/share.html"
wait $MTX_PID
