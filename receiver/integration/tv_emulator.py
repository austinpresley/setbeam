#!/usr/bin/env python3
"""Start, stop or inspect the dedicated Setbeam_TV_API36 emulator."""
import argparse
import fcntl
import json
import os
import re
import secrets
import signal
import socket
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


class Failure(Exception):
    pass


class AdbServer:
    """Bind the private loopback socket before handing it to the foreground server."""

    def __init__(self, port, artifacts, console_port):
        self.port, self.artifacts, self.proc = port, artifacts, None
        self.listener = None
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("ADB_", "ANDROID_ADB_")) and key not in ("ANDROID_SERIAL", "SETBEAM_ADB")}
        self.env.update(ADB_MDNS="0", ADB_MDNS_AUTO_CONNECT="0",
                        ADB_LOCAL_TRANSPORT_MAX_PORT=str(console_port + 1),
                        ADB_SERVER_SOCKET=f"tcp:127.0.0.1:{port}",
                        SETBEAM_ADB=str(ADB))

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        if self.proc is not None:
            raise Failure("Private adb server cannot be restarted during this run")
        self.listener = socket.socket()
        try:
            self.listener.bind(("127.0.0.1", self.port))
            self.listener.listen()
            fd = self.listener.fileno()
            with (self.artifacts / "adb-server.log").open("ab") as log:
                self.proc = subprocess.Popen(
                    [str(ADB), "-L", f"acceptfd:{fd}", "--one-device", "setbeam-no-usb", "nodaemon", "server"],
                    env=self.env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                    start_new_session=True, pass_fds=(fd,),
                )
        except BaseException:
            self.listener.close()
            self.listener = None
            raise
        # Keep the bound socket through teardown so a server crash cannot
        # let another process take over the port between client requests.
        self.run(["devices", "-l"], timeout=15, check=True)

    def run(self, args, timeout=30, check=False):
        if not self.alive():
            raise Failure("The owned adb server is no longer running")
        # The numeric loopback host keeps adb from auto-starting a local daemon.
        result = subprocess.run([str(ADB), "-H", "127.0.0.1", "-P", str(self.port), *args],
                                capture_output=True, timeout=timeout, check=check, env=self.env)
        if not self.alive():
            raise Failure("The owned adb server exited during a request")
        return result

    def stop(self):
        try:
            if self.alive():
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)
        finally:
            if self.listener is not None:
                self.listener.close()
                self.listener = None


def transport_id(server, serial):
    result = server.run(["devices", "-l"], check=True)
    listed = result.stdout.decode().splitlines()
    if result.stderr.strip() or not listed or listed[0].strip() != "List of devices attached":
        raise Failure("Private adb did not return a device list")
    rows = [line.split() for line in listed[1:] if line.strip()]
    matching = [row for row in rows if row[0] == serial]
    if len(matching) != 1 or matching[0][1:2] != ["device"]:
        return None
    ids = [field for field in matching[0][2:] if field.startswith("transport_id:")]
    if (len(ids) != 1 or not re.fullmatch(r"transport_id:[1-9][0-9]*", ids[0])
            or sum(ids[0] in row[2:] for row in rows) != 1):
        return None
    return ids[0].split(":", 1)[1]


def load():
    try:
        value = json.loads((STATE / "state.json").read_text())
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def owned(current):
    if not current:
        return False
    pid, token = current.get("pid"), current.get("token")
    port = current.get("port")
    if (type(pid) is not int or pid <= 1 or type(port) is not int or not valid_port(port)
            or current.get("serial") != f"emulator-{port}"
            or not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{32}", token)):
        return False
    try:
        if os.getpgid(pid) != pid or os.getsid(pid) != pid:
            return False
        # Inspect this PID only. The per-launch token distinguishes a reused PID.
        result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "uid=", "-o", "command="],
                                capture_output=True, text=True, timeout=5)
        fields = result.stdout.strip().split(maxsplit=1)
        uid, command = fields if len(fields) == 2 else ("", "")
        return (result.returncode == 0 and uid == str(os.getuid())
                and command.rstrip().endswith(f"{Path(__file__).resolve()} --supervise {port} {int(current.get('wipe') is True)} {token}"))
    except ProcessLookupError:
        return False


def avd_path_ok():
    ini = Path.home() / ".android" / "avd" / f"{AVD}.ini"
    try:
        lines = dict(line.split("=", 1) for line in ini.read_text().splitlines() if "=" in line)
    except OSError:
        return False
    return bool(lines.get("path")) and Path(lines["path"]).resolve() == EXPECTED_AVD_PATH.resolve()


def supervise(port, wipe, token):
    if (not re.fullmatch(r"[0-9a-f]{32}", token) or not valid_port(port)
            or os.getpid() != os.getsid(0) or os.getpid() != os.getpgrp()):
        raise Failure("Emulator supervisor needs its own session")
    args = [str(EMULATOR), "-avd", AVD, "-port", str(port), "-no-window", "-no-audio", "-no-snapshot",
            "-no-boot-anim", "-gpu", "swiftshader_indirect", "-netdelay", "none", "-netspeed", "full"]
    if wipe:
        args.append("-wipe-data")

    def stopping(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stopping)
    request = STATE / f"stop-{token}"
    try:
        with (STATE / "emulator.log").open("ab") as log:
            proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            while not request.exists():
                try:
                    proc.wait(timeout=0.25)
                    break
                except subprocess.TimeoutExpired:
                    pass
    except KeyboardInterrupt:
        pass
    finally:
        request.unlink(missing_ok=True)
        # The live session leader anchors the group even if the emulator leader exited.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        os.killpg(os.getpgrp(), signal.SIGTERM)
        time.sleep(2)
        os.killpg(os.getpgrp(), signal.SIGKILL)


def start(port, wipe, boot_timeout, adb_port=5138):
    current = load()
    if owned(current):
        if current["port"] != port or current.get("ready") is not True or wipe:
            raise Failure("An owned emulator is already running. Stop it before starting another.")
        print(f"already booted: {current['serial']} pid {current['pid']}")
        return 0
    if not avd_path_ok():
        raise Failure(f"{AVD} is not registered at {EXPECTED_AVD_PATH}")
    with socket.socket() as console, socket.socket() as transport:
        console.bind(("127.0.0.1", port))
        transport.bind(("127.0.0.1", port + 1))
    receipt = STATE / "state.json"
    receipt.unlink(missing_ok=True)
    server = AdbServer(adb_port, STATE, port)
    proc = None
    booted = False
    serial = f"emulator-{port}"
    try:
        server.start()
        token = secrets.token_hex(16)
        with (STATE / "emulator.log").open("ab") as log:
            proc = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "--supervise", str(port), str(int(wipe)), token],
                env={**server.env, "ANDROID_ADB_SERVER_PORT": str(adb_port)},
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )
        current = {"pid": proc.pid, "serial": serial, "port": port, "token": token, "wipe": wipe, "ready": False}
        save(current)
        deadline = time.monotonic() + boot_timeout
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise Failure(f"Emulator exited during boot. See {STATE / 'emulator.log'}")
            tid = transport_id(server, serial)
            if tid:
                out = server.run(["-t", tid, "shell", "getprop sys.boot_completed"], timeout=10)
                if out.returncode == 0 and out.stdout.strip() == b"1" and owned(current):
                    avd = server.run(["-s", serial, "emu", "avd", "name"], check=True)
                    if avd.stdout.splitlines() != [AVD.encode(), b"OK"]:
                        raise Failure("The attached emulator did not report the dedicated AVD name")
                    current["ready"] = True
                    save(current)
                    booted = True
                    print(f"booted: {serial} pid {proc.pid}")
                    return 0
            time.sleep(2)
        raise Failure("Emulator boot timed out")
    finally:
        try:
            if not booted:
                if proc is not None and proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=10)
                receipt.unlink(missing_ok=True)
        finally:
            server.stop()


def save(current):
    temp = STATE / "state.json.tmp"
    temp.write_text(json.dumps(current))
    temp.replace(STATE / "state.json")


def stop():
    current = load()
    if owned(current):
        # Only the supervisor holding this launch's token can act on the request.
        request = STATE / f"stop-{current['token']}"
        request.touch(mode=0o600)
        deadline = time.monotonic() + 10
        while owned(current):
            if time.monotonic() >= deadline:
                raise Failure("Emulator supervisor did not stop. Its receipt was kept.")
            time.sleep(0.2)
        request.unlink(missing_ok=True)
        print(f"stopped: {current['serial']}")
    else:
        print("no owned emulator")
    (STATE / "state.json").unlink(missing_ok=True)
    return 0


def status():
    current = load()
    up = owned(current)
    print(json.dumps({"serial": current.get("serial") if up else None,
                      "alive": up, "boot_completed_at_start": up and current.get("ready") is True}))
    return 0 if up else 1


def valid_port(port):
    return port % 2 == 0 and 5554 <= port <= 5682


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--supervise":
        supervise(int(sys.argv[2]), sys.argv[3] == "1", sys.argv[4])
        return 1
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["start", "stop", "status"])
    parser.add_argument("--port", type=int, default=5574)
    parser.add_argument("--adb-port", type=int, default=5138)
    parser.add_argument("--wipe", action="store_true")
    parser.add_argument("--boot-timeout", type=int, default=600)
    a = parser.parse_args()
    if (not valid_port(a.port) or not 1024 <= a.adb_port <= 65535
            or a.adb_port in (5037, a.port, a.port + 1) or a.boot_timeout <= 0):
        parser.error("Invalid console port, private adb port or boot timeout")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    STATE.mkdir(parents=True, mode=0o700, exist_ok=True)
    try:
        with (STATE / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if a.action == "start":
                return start(a.port, a.wipe, a.boot_timeout, a.adb_port)
            return stop() if a.action == "stop" else status()
    except (Failure, OSError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
