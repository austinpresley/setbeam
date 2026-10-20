#!/usr/bin/env python3
"""Force-quit only the app named by its own integration session; check its helpers."""
import argparse
import json
import os
import signal
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("session", type=Path)
parser.add_argument("--wait-for-normal-quit", action="store_true")
args = parser.parse_args()
app = int(json.loads(args.session.read_text())["pid"])
command = subprocess.check_output(["ps", "-p", str(app), "-o", "comm="], text=True).strip()
if not command.endswith("/Setbeam.app/Contents/MacOS/Setbeam"):
    raise SystemExit("Refusing to kill a process that is not the integration Setbeam app")

def processes():
    result = {}
    for line in subprocess.check_output(["ps", "-axo", "pid=,ppid=,stat="], text=True).splitlines():
        pid, parent, state = line.split()
        result[int(pid)] = (int(parent), state)
    return result

before = processes()
owned = {app}
while True:
    expanded = owned | {pid for pid, (parent, _) in before.items() if parent in owned}
    if expanded == owned:
        break
    owned = expanded
if len(owned) < 3:
    raise SystemExit("Expected an active app with owned media processes")
if not args.wait_for_normal_quit:
    os.kill(app, signal.SIGKILL)
deadline = time.monotonic() + (30 if args.wait_for_normal_quit else 6)
while time.monotonic() < deadline:
    running = processes()
    remaining = [pid for pid in owned if pid in running and not running[pid][1].startswith("Z")]
    if not remaining:
        mode = "Normal Quit" if args.wait_for_normal_quit else "Force Quit"
        print(f"PASS: {mode} stopped the app and all {len(owned)-1} owned descendants")
        raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit(f"FAIL: {len(remaining)} owned processes survived Force Quit")
