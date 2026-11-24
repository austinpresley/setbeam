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
marker = args.newer_than.stat().st_mtime_ns if args.newer_than else 0
while time.monotonic() < deadline:
    try:
        modified = args.feedback.stat().st_mtime_ns
        fresh = 0 <= time.time_ns() - modified < 3_000_000_000 and modified > marker
        if fresh:
            latest = json.loads(args.feedback.read_text())
            frames = latest.get("frames", 0)
            if baseline is None or frames < baseline[0]:
                baseline = (frames, modified)
            healthy = (latest.get("playing") and latest.get("decoderRunning") and frames > baseline[0] and
                       modified > baseline[1] and latest.get("renderer") == "native-timestamped-nv12" and
                       latest.get("audioVideoClockShared"))
            floating = not args.require_floating or latest.get("floatingVisible") and latest.get("floatingAboveNormal")
            sound = not args.require_sound or latest.get("audioSamplesScheduled", 0) > 0 and latest.get("audioRendering") and not latest.get("muted", True)
            dimensions = (args.width is None or latest.get("width") == args.width) and (args.height is None or latest.get("height") == args.height)
            cadence = args.min_source_fps is None or latest.get("sourceFPS", 0) >= args.min_source_fps
            timing = args.max_video_clock_error_ms is None or abs(latest.get("videoClockErrorMilliseconds", 1e9)) <= args.max_video_clock_error_ms
            if healthy and floating and sound and dimensions and cadence and timing:
                print("PASS: native decoded video is advancing" + (" with floating preview" if args.require_floating else "") + (" and scheduled native audio" if args.require_sound else ""))
                print(json.dumps({"beforeFrames": baseline[0], "afterFrames": frames, "beforeFeedbackNS": baseline[1],
                                  "afterFeedbackNS": modified, "afterMarkerNS": marker or None}))
                raise SystemExit(0)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    time.sleep(0.25)
print("FAIL: native preview check", json.dumps(latest, sort_keys=True))
raise SystemExit(1)
