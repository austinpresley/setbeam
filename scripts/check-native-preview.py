#!/usr/bin/env python3
"""Check advancing decoded frames reported by the running app's native renderer."""
import argparse
import json
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("feedback", type=Path)
parser.add_argument("--newer-than", type=Path)
parser.add_argument("--timeout", type=float, default=15)
parser.add_argument("--require-floating", action="store_true")
parser.add_argument("--require-sound", action="store_true")
parser.add_argument("--width", type=int)
parser.add_argument("--height", type=int)
parser.add_argument("--min-source-fps", type=float)
parser.add_argument("--max-video-clock-error-ms", type=float)
args = parser.parse_args()
deadline = time.monotonic() + args.timeout
latest, baseline = {}, None
while time.monotonic() < deadline:
    try:
        modified = args.feedback.stat().st_mtime
        fresh = time.time() - modified < 3 and (not args.newer_than or modified >= args.newer_than.stat().st_mtime)
        if fresh:
            latest = json.loads(args.feedback.read_text())
            frames = latest.get("frames", 0)
            if baseline is None:
                baseline = frames
            healthy = latest.get("playing") and latest.get("decoderRunning") and frames > baseline and latest.get("renderer") == "native-timestamped-nv12" and latest.get("audioVideoClockShared")
            floating = not args.require_floating or latest.get("floatingVisible") and latest.get("floatingAboveNormal")
            sound = not args.require_sound or latest.get("audioSamplesScheduled", 0) > 0 and latest.get("audioRendering") and not latest.get("muted", True)
            dimensions = (args.width is None or latest.get("width") == args.width) and (args.height is None or latest.get("height") == args.height)
            cadence = args.min_source_fps is None or latest.get("sourceFPS", 0) >= args.min_source_fps
            timing = args.max_video_clock_error_ms is None or abs(latest.get("videoClockErrorMilliseconds", 1e9)) <= args.max_video_clock_error_ms
            if healthy and floating and sound and dimensions and cadence and timing:
                print("PASS: native decoded video is advancing" + (" with floating preview" if args.require_floating else "") + (" and scheduled native audio" if args.require_sound else ""))
                raise SystemExit(0)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    time.sleep(0.25)
print("FAIL: native preview check", json.dumps(latest, sort_keys=True))
raise SystemExit(1)
