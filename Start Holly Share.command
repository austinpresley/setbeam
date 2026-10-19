#!/bin/bash
# Start Holly Share.command — double-click to share the transmitter's stream.
# Join the transmitter's Wi-Fi first. Press Ctrl+C in this window to stop.

cd "$(dirname "$0")" || exit 1
exec ./holly-share.sh "$@"
