#!/usr/bin/env python3
"""Owned lifecycle for the dedicated Setbeam_TV_API36 test emulator.

Starts exactly one emulator on an explicit console port in its own process group, records the
PID and group in an ignored state file, and stops only that group. It never lists, matches, or
signals other emulators or processes by command line. Emulator results are software evidence.

  tv_emulator.py start [--port 5574] [--wipe]
  tv_emulator.py stop
  tv_emulator.py status
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = HERE / ".build" / "emulator"
SDK = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
ADB = SDK / "platform-tools" / "adb"
EMULATOR = SDK / "emulator" / "emulator"
AVD = "Setbeam_TV_API36"
EXPECTED_AVD_PATH = HERE.parent.parent / "build" / "receiver-tv-avd"


# adb's mDNS bridge aborted repeatedly on this network (SIGABRT in adbmdns_bridge); emulator use needs none.
ADB_ENV = dict(os.environ, ADB_MDNS="0")


def adb(serial, *args, timeout=30, check=False):
    return subprocess.run([str(ADB), "-s", serial, *args], capture_output=True, text=True, timeout=timeout, check=check,
                          env=ADB_ENV)


def load():
    try:
        return json.loads((STATE / "state.json").read_text())
    except (OSError, ValueError):
        return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def avd_path_ok():
    ini = Path.home() / ".android" / "avd" / f"{AVD}.ini"
    try:
        lines = dict(l.split("=", 1) for l in ini.read_text().splitlines() if "=" in l)
    except OSError:
        return False
    return Path(lines.get("path", "")).resolve() == EXPECTED_AVD_PATH.resolve()


def start(port, wipe, boot_timeout):
    serial = f"emulator-{port}"
    current = load()
    if current and alive(current["pid"]):
        print(f"already running: {current['serial']} pid {current['pid']}")
        return 0
    if not avd_path_ok():
        print(f"FAIL: {AVD} is not registered at {EXPECTED_AVD_PATH}", file=sys.stderr)
        return 2
    subprocess.run([str(ADB), "start-server"], capture_output=True, timeout=30, env=ADB_ENV)
    listed = subprocess.run([str(ADB), "devices"], capture_output=True, text=True, timeout=30, env=ADB_ENV).stdout
    if any(line.startswith(serial + "\t") for line in listed.splitlines()):
        print(f"FAIL: {serial} is already attached and is not owned by this tool", file=sys.stderr)
        return 2
    STATE.mkdir(parents=True, exist_ok=True)
    log = open(STATE / "emulator.log", "ab")
    args = [str(EMULATOR), "-avd", AVD, "-port", str(port), "-no-window", "-no-audio", "-no-snapshot",
            "-no-boot-anim", "-gpu", "swiftshader_indirect", "-netdelay", "none", "-netspeed", "full"]
    if wipe:
        args.append("-wipe-data")
    proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
    (STATE / "state.json").write_text(json.dumps({"pid": proc.pid, "pgid": proc.pid, "serial": serial, "port": port,
                                                     "started": time.time()}))
    deadline = time.time() + boot_timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            print(f"FAIL: emulator exited with {proc.returncode}; see {STATE / 'emulator.log'}", file=sys.stderr)
            return 1
        out = adb(serial, "shell", "getprop", "sys.boot_completed", timeout=10)
        if out.stdout.strip() == "1":
            print(f"booted: {serial} pid {proc.pid} in {time.time() - (deadline - boot_timeout):.0f}s")
            return 0
        time.sleep(3)
    print("FAIL: boot timed out", file=sys.stderr)
    return 1


def stop():
    current = load()
    if not current:
        print("no owned emulator")
        return 0
    serial, pid = current["serial"], current["pid"]
    if alive(pid):
        adb(serial, "emu", "kill", timeout=20)
        for _ in range(60):
            if not alive(pid):
                break
            time.sleep(0.5)
    if alive(pid):
        try:
            os.killpg(current["pgid"], signal.SIGTERM)
        except ProcessLookupError:
            pass
        time.sleep(3)
    if alive(pid):
        try:
            os.killpg(current["pgid"], signal.SIGKILL)
        except ProcessLookupError:
            pass
    # Any helper left in the owned group (qemu children) goes with it.
    try:
        os.killpg(current["pgid"], 0)
        os.killpg(current["pgid"], signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    (STATE / "state.json").unlink(missing_ok=True)
    print(f"stopped: {serial} pid {pid}")
    return 0


def status():
    current = load()
    if not current:
        print("no owned emulator")
        return 1
    up = alive(current["pid"])
    boot = adb(current["serial"], "shell", "getprop", "sys.boot_completed", timeout=10).stdout.strip() if up else ""
    print(json.dumps({**current, "alive": up, "boot_completed": boot == "1"}))
    return 0 if up else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["start", "stop", "status"])
    parser.add_argument("--port", type=int, default=5574)
    parser.add_argument("--wipe", action="store_true")
    parser.add_argument("--boot-timeout", type=int, default=600)
    a = parser.parse_args()
    if a.port % 2 or not 5554 <= a.port <= 5682:
        parser.error("--port must be an even emulator console port")
    if a.action == "start":
        return start(a.port, a.wipe, a.boot_timeout)
    return stop() if a.action == "stop" else status()


if __name__ == "__main__":
    sys.exit(main())
