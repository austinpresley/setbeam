#!/usr/bin/env python3
"""Local end-to-end check of the native Setbeam Receiver against the real Mac stack.

It drives SetbeamReceiverFixture (real ViewerGateway, port-80 ShortAddressListener and MediaRuntime
with labeled Sample media) and one explicitly named Android TV emulator through adb. Assertions come
from independent observers:

  * the fixture's operator view: request rows, admission, heartbeat health and revision;
  * the receiver's own diagnostics overlay, read from screenshots by Vision OCR (UIAutomator cannot
    read the UI while video plays because it never becomes idle);
  * raw emulator screen captures: the picture region must change while live and must stay still
    while pending, held, declined, removed or stopped;
  * SurfaceFlinger: the receiver's SurfaceView layer and its buffer size.

Emulator results are software evidence only. The script refuses any serial whose device does not
report ro.kernel.qemu=1, and it runs its own adb server on a private port with adb's mDNS disabled
(the shared server's mDNS bridge aborts on this network; see docs/verification-tv-receiver-integration.md).

  python3 receiver/integration/tv_e2e.py --serial emulator-5574 [--source 4k --ui-size 1920x1080] [--cases all]

Exit status is 0 only when every selected case passes and the device settings are restored.
"""
import argparse
from collections import Counter
import base64
import hashlib
import http.client
import ipaddress
import json
import math
import os
import re
import shutil
import shlex
import signal
import subprocess
import socket
import struct
import sys
import uuid
import threading
import time
import traceback
import urllib.parse
from pathlib import Path
from xml.etree import ElementTree

from tv_emulator import AdbServer, Failure, load as load_emulator, owned as owns_emulator, transport_id, valid_port

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
PACKAGE = "com.setbeam.receiver"
MAIN = f"{PACKAGE}/.MainActivity"
PROVISION_COMPONENT = f"{PACKAGE}/.ProvisionActivity"
DEFAULT_APK = REPO / "receiver/android/app/build/outputs/apk/debug/app-debug.apk"
FIXTURE_BIN = HERE / ".build/swift/debug/SetbeamReceiverFixture"
OCR_BIN = HERE / ".build/swift/debug/ScreenText"
PROVISION = REPO / "receiver/scripts/setbeam_receiver_provision.py"
sys.path.insert(0, str(PROVISION.parent))
from setbeam_receiver_provision import parse_overlay_mode
sys.path.pop(0)
SECRET = re.compile(r"(?<![0-9a-f])(?<!sha256 )[0-9a-f]{40,}(?![0-9a-f])")
PHASE_LABEL = re.compile(
    r"^Phase[ \t]+(asking again|needs ask|name rejected|storage problem|audience reconnecting|"
    r"unconfigured|paused|searching|asking|waiting|busy|connecting|live|stalled|holding|ended|declined|removed)\b",
    re.MULTILINE | re.IGNORECASE,
)


def diagnostic_phase(text):
    match = PHASE_LABEL.search(text)
    return match.group(1).lower() if match else None


def menu_choices(rows):
    tokens = [(x, y, text.casefold().strip()) for y, items in rows for x, text in items]
    choices = {}
    for label in ("Sound", "Pop-ups", "Pointers"):
        name = label.casefold()
        disabled = "muted" if label == "Sound" else f"{name} off"
        for x, y, token in tokens:
            if token in (f"{name} on", disabled):
                choices[label] = token != disabled
                break
            if token == name:
                # A wrapped state belongs to the label above it in the same button column.
                matches = [(abs(other_x - x), value) for other_x, other_y, value in tokens
                           if 0 < other_y - y < 0.10 and abs(other_x - x) < 0.075 and value in ("on", "off")]
                if matches:
                    choices[label] = min(matches)[1] == "on"
                    break
    return choices


CARD_TITLES = {
    "Looking for the Mac": "searching", "Waiting for the Mac": "searching", "Asking to join": "asking", "Asking again": "asking again",
    "Waiting for approval": "waiting", "The Mac is busy": "busy", "Ask to join": "needs ask",
    "Connecting": "connecting", "On hold": "holding", "Sharing ended": "ended", "Request declined": "declined",
    "Removed by the operator": "removed", "Set up this receiver": "unconfigured", "Paused": "paused",
}


def redact(text):
    return SECRET.sub("<redacted>", text)


class Log:
    def __init__(self, path):
        self.file = open(path, "a", buffering=1)

    def __call__(self, text):
        line = f"[{time.strftime('%H:%M:%S')}] {redact(text)}"
        print(line, flush=True)
        self.file.write(line + "\n")


# ---------------------------------------------------------------- adb

class Device:
    def __init__(self, serial, log, artifacts, server):
        self.serial, self.log, self.artifacts, self.server = serial, log, artifacts, server
        self.transport = None
        self.reboot_owner = None
        self.shots = 0
        self.ocr_dir = artifacts / "ocr"
        self.ocr_dir.mkdir(exist_ok=True)

    def probe(self, transport, command, timeout=30):
        result = self.server.run(["-t", transport, "shell", command], timeout=timeout, check=True)
        if result.stderr.strip():
            raise Failure("ADB reported an error while reading emulator identity")
        return result.stdout.decode().strip()

    def adb(self, *args, timeout=60, check=True, binary=False):
        self.check_identity()
        proc = self.server.run(["-t", self.transport, *args], timeout=timeout)
        if check and proc.returncode:
            detail = proc.stderr.decode(errors="replace")
            if not binary:
                detail += proc.stdout.decode(errors="replace")
            raise Failure(f"adb {' '.join(args[:3])} failed ({proc.returncode}): {redact(detail.strip())[:400]}")
        return proc.stdout if binary else proc.stdout.decode(errors="replace")

    def sh(self, command, **kw):
        return self.adb("shell", command, **kw)

    def read_identity(self, transport):
        raw = self.probe(transport, "getprop")
        pairs = re.findall(r"^\[([^\]]+)\]: \[(.*)\]$", raw, re.M)
        props = dict(pairs)
        if (len(pairs) != len(props)
                or (props.get("ro.kernel.qemu") or props.get("ro.boot.qemu")) != "1"
                or props.get("sys.boot_completed") != "1"):
            raise Failure(f"{self.serial} is not a verified, booted emulator")
        keys = ("ro.serialno", "ro.build.fingerprint", "ro.build.version.sdk", "ro.product.model", "ro.product.cpu.abi")
        if any(not props.get(key, "").strip() for key in keys):
            raise Failure("Emulator identity properties are incomplete")
        # Read both values in a single checked shell request.
        values = self.probe(transport, "am get-current-user && cat /proc/sys/kernel/random/boot_id").splitlines()
        if len(values) != 2 or not re.fullmatch(r"[0-9]+", values[0]):
            raise Failure("Cannot identify the emulator's Android user")
        try:
            boot = str(uuid.UUID(values[1]))
        except ValueError:
            raise Failure("Cannot identify the emulator's boot") from None
        return {key: props[key] for key in keys}, int(values[0]), boot

    def check_identity(self):
        if self.reboot_owner is not None and not owns_emulator(self.reboot_owner):
            raise Failure("The reboot test's owned emulator supervisor exited")
        if self.transport is None or transport_id(self.server, self.serial) != self.transport:
            raise Failure("Emulator adb transport changed or was never verified")
        if self.read_identity(self.transport) != (self.identity, self.user, self.boot_id):
            raise Failure("Emulator identity, Android user or boot changed")

    def attach(self, seconds=120, reboot=False):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if reboot and not owns_emulator(self.reboot_owner):
                raise Failure("Cannot reattach after reboot without the original emulator supervisor")
            tid = transport_id(self.server, self.serial)
            if tid:
                try:
                    if self.probe(tid, "getprop sys.boot_completed") == "1":
                        identity, user, boot = self.read_identity(tid)
                        if not reboot:
                            self.transport, self.identity, self.user, self.boot_id = tid, identity, user, boot
                            return
                        if (identity, user) != (self.identity, self.user):
                            raise Failure("A different emulator or Android user attached after reboot")
                        if boot != self.boot_id:
                            self.transport, self.boot_id = tid, boot
                            return
                except subprocess.CalledProcessError:
                    # adbd can temporarily drop the transport while Android is starting.
                    pass
            time.sleep(2)
        raise Failure(f"{self.serial} did not {'reboot' if reboot else 'finish booting'} within {seconds}s")

    def home_state(self):
        role = self.sh(f"cmd role get-role-holders --user {self.user} android.app.role.HOME").strip()
        if role and not all(re.fullmatch(r"[A-Za-z][\w]*(?:\.[\w]+)+", holder) for holder in role.split(";")):
            raise Failure("Cannot read exact emulator HOME role")
        resolved = self.sh(f"cmd package resolve-activity --brief --user {self.user} "
                           "-a android.intent.action.MAIN -c android.intent.category.HOME").strip().splitlines()
        if not resolved or not re.fullmatch(r"[\w.]+/[\w.$]+", resolved[-1]):
            raise Failure("Cannot read emulator HOME resolution")
        return {"role": role, "resolves": resolved[-1]}

    def receiver_installed(self):
        rows = self.sh(f"cmd package list packages --user {self.user} {PACKAGE}").splitlines()
        if any(not re.fullmatch(r"package:[A-Za-z][\w.]+", row) for row in rows):
            raise Failure("Cannot establish whether the receiver is installed")
        return f"package:{PACKAGE}" in rows

    def settings_snapshot(self):
        snapshot = {key: self.read_setting(key) for key in SCREEN_SETTINGS}
        for key in ("size", "density"):
            value = self.sh(f"wm {key}").strip()
            unit = r"[0-9]+x[0-9]+" if key == "size" else r"[0-9]+"
            if not re.fullmatch(rf"Physical {key}: {unit}(?:\nOverride {key}: {unit})?", value):
                raise Failure(f"Cannot read exact display {key}")
            snapshot[f"wm/{key}"] = value.splitlines()[-1].split(": ")[1] if "\n" in value else None
        airplane = self.sh("cmd connectivity airplane-mode").strip()
        if airplane not in ("enabled", "disabled"):
            raise Failure("Cannot read emulator airplane mode")
        snapshot["airplane"] = airplane
        return snapshot

    def read_setting(self, key):
        namespace, name = key.split("/")
        # Listing lets us distinguish a missing entry from a literal "null" value.
        lines = self.sh(f"settings --user {self.user} list {namespace}").splitlines()
        matches = [line.partition("=")[2] for line in lines if line.startswith(name + "=")]
        if len(matches) > 1 or any("=" not in line for line in lines):
            raise Failure(f"Cannot read exact setting {key}")
        return matches[0] if matches else None

    def put_setting(self, key, value):
        namespace, name = key.split("/")
        prefix = f"settings --user {self.user}"
        if value is None:
            self.sh(f"{prefix} delete {namespace} {name}")
        else:
            self.sh(f"{prefix} put {namespace} {name} {shlex.quote(value)}")

    def power(self):
        out = self.sh("dumpsys power", check=False)
        m = re.search(r"mWakefulness=(\w+)", out)
        dreams = self.sh("dumpsys dreams", check=False)
        dreaming = re.search(r"mCurrentDream(Token)?=(\S+)", dreams)
        return {"wakefulness": m.group(1) if m else "", "dream": dreaming.group(2) if dreaming else ""}

    def pid(self):
        return self.sh(f"pidof {PACKAGE}", check=False).strip()

    def front(self):
        out = self.sh("dumpsys activity activities", check=False)
        m = re.search(r"topResumedActivity=ActivityRecord\{\S+ \S+ (\S+)", out)
        return m.group(1) if m else ""

    def keep_screen_on(self):
        out = self.sh("dumpsys window windows", check=False)
        block = out.split(f"{PACKAGE}/{PACKAGE}.MainActivity", 1)
        if len(block) < 2:
            return None
        return "KEEP_SCREEN_ON" in block[1][:4000]

    def key(self, *codes):
        self.sh("input keyevent " + " ".join(str(code) for code in codes))

    def start_main(self):
        self.sh(f"am start -W --user {self.user} -n {MAIN}", timeout=60)

    def force_stop(self):
        self.sh(f"am force-stop --user {self.user} {PACKAGE}")

    def configure(self, host, name, *, refused=False):
        command = "logcat -d -v epoch -s SetbeamProvision:*"
        prior = Counter(self.sh(command).splitlines())
        result = self.sh(f"am start -W --user {self.user} -n {PROVISION_COMPONENT} -a {PACKAGE}.CONFIGURE "
                         f"--es setbeam_host {shlex.quote(host)} --es setbeam_name {shlex.quote(name)}")
        if "Status: ok" not in result.splitlines():
            raise Failure("Android did not acknowledge the configuration activity")
        expected = "Pairing refused" if refused else f"Pairing accepted for {host}"
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            current = Counter(self.sh(command).splitlines())
            messages = [line.split("SetbeamProvision:", 1)[1].strip()
                        for line in (current - prior).elements() if "SetbeamProvision:" in line]
            replies = [message for message in messages if message.startswith(("Pairing refused", "Pairing accepted for "))]
            if len(replies) == 1 and (replies[0] == expected or (refused and replies[0].startswith(expected))):
                return
            if replies:
                raise Failure("Receiver returned an unexpected or ambiguous configuration acknowledgement")
            time.sleep(0.5)
        raise Failure("No fresh receiver acknowledgement for the configuration intent")

    # ---- observation

    def pull_capture(self, remote, flag):
        # `adb exec-out screencap` streams tens of MB, which brought down the adb server here; writing on the
        # device and pulling the file is stable.
        remote = f"{remote}-{uuid.uuid4().hex}"
        local = self.artifacts / ".capture"
        try:
            self.sh(f"screencap {flag} {remote}".replace("  ", " "), timeout=60)
            self.adb("pull", remote, str(local), timeout=120)
            return local.read_bytes()
        finally:
            local.unlink(missing_ok=True)
            self.sh(f"rm -f {remote}")

    def setup_text(self):
        """Read the Android accessibility tree while the static setup activity is in front."""
        remote = f"/data/local/tmp/setbeam-setup-{uuid.uuid4().hex}.xml"
        try:
            xml = self.sh(f"uiautomator dump {remote} >/dev/null && cat {remote}", timeout=15, check=False)
        finally:
            self.sh(f"rm -f {remote}")
        try:
            return "\n".join(node.attrib.get("text", "") for node in ElementTree.fromstring(xml).iter("node"))
        except ElementTree.ParseError:
            return ""

    def screen(self, keep=None):
        """The receiver's visible state, from OCR of one screenshot."""
        png = self.ocr_dir / "last.png"
        png.write_bytes(self.pull_capture("/data/local/tmp/setbeam-ocr.png", "-p"))
        out = subprocess.run([str(OCR_BIN), str(png)], capture_output=True, text=True, timeout=60)
        rows = []
        for line in out.stdout.splitlines():
            try:
                coords, text = line.split("\t", 1)
                x, y = (float(v) for v in coords.split())
            except ValueError:
                continue
            if rows and abs(rows[-1][0] - y) < 0.012:
                rows[-1][1].append((x, text))
            else:
                rows.append([y, [(x, text)]])
        lines = ["   ".join(t for _, t in sorted(items)) for _, items in rows]
        if keep:
            shutil.copyfile(png, self.ocr_dir / f"{keep}.png")
            (self.ocr_dir / f"{keep}.txt").write_text(redact("\n".join(lines)))
        text = "\n".join(lines)
        state = {"lines": lines, "text": text}

        def grab(pattern, cast=str):
            m = re.search(pattern, text)
            try:
                return cast(m.group(1).strip()) if m else None
            except ValueError:
                return None
        state["phase"] = diagnostic_phase(text)
        state["admission"] = grab(r"admission (\w+)")
        state["route"] = grab(r"Mac (?:configured address|discovered|via)?\s*([0-9.]+:\d+)")
        state["video"] = grab(r"Video (\d+\s*[x×]\s*\d+)")
        if state["video"]:
            state["video"] = re.sub(r"\s*[x×]\s*", "x", state["video"])
        state["shown_fps"] = grab(r"(?:rendered|shown) ([\d.]+) fps", float)
        state["decoded"] = grab(r"Decoded (\d+)", int)
        state["dropped"] = grab(r"dropped (\d+)", int)
        state["received"] = grab(r"received (\d+)", int)
        state["decoder_fps"] = grab(r"decoder fps (\S+)")
        state["decoder"] = grab(r"Decoder (\S+)")
        state["created"] = grab(r"Created (.+)")
        state["codec"] = grab(r"Codec (.+)")
        state["audio"] = grab(r"Audio (.+)")
        state["audio_packets"] = grab(r"Audio packets (\d+)", int)
        state["connection"] = grab(r"Connection (.+)")
        state["freezes"] = grab(r"freezes (\d+)", int)
        state["buffer_requested"] = grab(r"Buffer requested (\S+)")
        state["surface_confirmed"] = grab(r"surface confirmed (\S+)")
        state["view"] = grab(r"\bview (\d+x\d+)")
        state["display_mode"] = grab(r"Display mode (\S+)")
        state["last_issue"] = grab(r"Last issue (.+)")
        state["title"] = next((t for t in CARD_TITLES if any(l.startswith(t) for l in lines)), "")
        state["card_phase"] = CARD_TITLES.get(state["title"])
        state["sample_label"] = "SAMPLE MEDIA" in text
        state["diag"] = state["phase"] is not None
        # The close hint distinguishes the strip from the identically named status-card button.
        state["remote_menu"] = "tv options" in text.casefold() and "back to close" in text.casefold()
        state["menu_choices"] = menu_choices(rows) if state["remote_menu"] else {}
        return state

    def ensure_diagnostics(self):
        # KEYCODE_INFO toggles the overlay. Look at several frames before pressing again so a single OCR miss
        # cannot toggle it back off.
        for _ in range(4):
            for _ in range(3):
                s = self.screen()
                if s["diag"] or "Bonjour id hint" in s["text"] or "Discovery " in s["text"]:
                    return s if s["diag"] else self.screen()
                time.sleep(1)
            self.key(165)
            time.sleep(2)
        raise Failure("the receiver's diagnostics overlay did not appear after KEYCODE_INFO")

    def picture_signature(self):
        """48x20 luma block means of the band between the top labels and the diagnostics overlay."""
        png = self.ocr_dir / "grid.png"
        png.write_bytes(self.pull_capture("/data/local/tmp/setbeam-grid.png", "-p"))
        out = subprocess.run([str(OCR_BIN), "--grid", str(png)], capture_output=True, text=True, timeout=60).stdout.split()
        if len(out) != 961:
            raise Failure("could not sample the screen picture")
        return [int(v) for v in out[1:]]

    def png(self, name):
        self.shots += 1
        path = self.artifacts / f"{self.shots:02d}-{name}.png"
        path.write_bytes(self.pull_capture("/data/local/tmp/setbeam-cap.png", "-p"))
        return path

    def surface_buffer(self):
        out = self.sh("dumpsys SurfaceFlinger", check=False)
        sizes = re.findall(r"SurfaceView\[" + re.escape(PACKAGE) + r"[^\n]*BLAST Consumer[^\n]*w/h:(\d+x\d+)", out)
        layer = f"SurfaceView[{PACKAGE}/{PACKAGE}.MainActivity]" in out
        return {"layer": layer, "buffers": sorted(set(sizes))}


def changed(a, b, threshold=6):
    return sum(1 for x, y in zip(a, b) if abs(x - y) > threshold)


# ---------------------------------------------------------------- fixture

class Fixture:
    def __init__(self, tag, address, port, lifetime, log, runtime, artifacts):
        self.tag, self.address, self.port, self.lifetime = tag, address, port, lifetime
        self.log, self.runtime = log, runtime
        self.proc, self.seq = None, 0
        self.output = artifacts / f"fixture-{tag}.log"

    @property
    def host(self):
        return f"http://{self.address}/" if self.port == 80 else f"http://{self.address}:{self.port}/"

    def start(self, fixtures=None):
        if self.proc and self.proc.poll() is None:
            raise Failure(f"fixture {self.tag} already running")
        if self.runtime.exists():
            shutil.rmtree(self.runtime)
        self.runtime.mkdir(parents=True, mode=0o700)
        self.seq = 0
        cmd = [str(FIXTURE_BIN), "--repo", str(REPO), "--runtime", str(self.runtime), "--viewer-address", self.address,
               "--web-port", str(self.port), "--lifetime", str(self.lifetime), "--title", f"Receiver integration {self.tag} (Sample)",
               "--label", f"setbeam-tvtest-{self.tag.lower()}"]
        if fixtures:
            cmd += ["--fixtures", str(fixtures)]
        out = open(self.output, "ab")
        out.write(b"FIXTURE-START\n"); out.flush()
        self.proc = subprocess.Popen(cmd, cwd=str(REPO), stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        deadline = time.time() + 90
        while time.time() < deadline:
            text = self.output.read_text(errors="replace").split("FIXTURE-START")[-1]
            if "READY " in text:
                return
            if self.proc.poll() is not None:
                raise Failure(f"fixture {self.tag} exited {self.proc.returncode}: {text[-600:]}")
            time.sleep(0.5)
        raise Failure(f"fixture {self.tag} did not become ready")

    def status(self):
        for _ in range(10):
            try:
                return json.loads((self.runtime / "status.json").read_text())
            except (OSError, ValueError):
                time.sleep(0.2)
        raise Failure(f"fixture {self.tag} status unavailable")

    def command(self, verb, timeout=120, **extra):
        self.seq += 1
        tmp = self.runtime / "commands" / f".{self.seq}.tmp"
        tmp.write_text(json.dumps(dict(extra, command=verb)))
        tmp.rename(self.runtime / "commands" / f"{self.seq}.json")
        ack = self.runtime / "acks" / f"{self.seq}.json"
        deadline = time.time() + timeout
        while time.time() < deadline:
            if ack.exists():
                result = json.loads(ack.read_text())
                self.log(f"fixture {self.tag} {verb}: {json.dumps(result)}")
                if not result.get("ok"):
                    raise Failure(f"fixture {self.tag} command {verb} failed: {result.get('error')}")
                return result.get("result", {})
            if self.proc.poll() is not None:
                raise Failure(f"fixture {self.tag} exited during {verb}")
            time.sleep(0.2)
        raise Failure(f"fixture {self.tag} command {verb} timed out")

    def send(self, verb, **extra):
        self.seq += 1
        tmp = self.runtime / "commands" / f".{self.seq}.tmp"
        tmp.write_text(json.dumps(dict(extra, command=verb)))
        tmp.rename(self.runtime / "commands" / f"{self.seq}.json")
        return self.seq

    def acked(self, seq):
        ack = self.runtime / "acks" / f"{seq}.json"
        return json.loads(ack.read_text()) if ack.exists() else None

    def viewers(self, name):
        return [v for v in self.status()["viewers"] if v["name"] == name]

    def stop(self):
        if not self.proc:
            return "not started"
        if self.proc.poll() is None:
            try:
                self.command("quit", timeout=20)
            except Failure:
                pass
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGTERM)
                try:
                    self.proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                    self.proc.wait(timeout=10)
        try:
            os.killpg(self.proc.pid, 0)
            os.killpg(self.proc.pid, signal.SIGKILL)
            leftover = "killed leftover owned process group"
        except (ProcessLookupError, PermissionError):
            leftover = "process group empty"
        text = self.output.read_text(errors="replace").split("FIXTURE-START")[-1]
        cleaned = "CLEANUP owned media processes exited" in text
        return f"exit {self.proc.returncode}; {'owned media processes exited' if cleaned else 'NO cleanup confirmation'}; {leftover}"


class PointerBot:
    """A second, browser-like viewer. It asks through the short address, waits for the fixture's Admit, and
    moves a shared pointer over the picture through the presence WebSocket. It never touches the receiver."""

    def __init__(self, fixture, name, log):
        self.fixture, self.name, self.log = fixture, name, log
        self.stop_flag = threading.Event()
        self.thread, self.error, self.moves, self.revision, self.passcode = None, None, 0, None, None

    def _root(self):
        conn = http.client.HTTPConnection(self.fixture.address, self.fixture.port, timeout=5)
        conn.request("GET", "/", headers={"Accept": "text/html"})
        reply = conn.getresponse(); location = reply.getheader("Location"); reply.read(); conn.close()
        if reply.status != 302 or not location:
            raise Failure(f"pointer bot: short address answered {reply.status}")
        url = urllib.parse.urlsplit(location)
        self.host, self.port, self.path = url.hostname, url.port, url.path

    def _post(self, endpoint, body):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=5)
        conn.request("POST", self.path + endpoint, json.dumps(body), {"Content-Type": "application/json"})
        reply = conn.getresponse(); data = reply.read(); conn.close()
        return reply.status, (json.loads(data) if data else {})

    def ask(self):
        self._root()
        status, reply = self._post("join", {"name": self.name, "ask": True, "mobile": False, "color": "orange"})
        if status != 200 or "pass" not in reply:
            raise Failure(f"pointer bot: ask returned {status}")
        self.passcode = reply["pass"]

    def admitted(self):
        _, reply = self._post("join", {"pass": self.passcode, "mobile": False})
        return reply.get("admission") == "admitted"

    def start(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_flag.set()
        if self.thread:
            self.thread.join(timeout=10)
        if self.error:
            raise Failure(f"pointer bot: {self.error}")
        return self.moves

    @staticmethod
    def _frame(opcode, payload):
        mask = os.urandom(4)
        head = bytes([0x80 | opcode])
        n = len(payload)
        head += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n)
        return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    def _messages(self, sock, buffer):
        try:
            chunk = sock.recv(65536)
        except (BlockingIOError, socket.timeout):
            return buffer, []
        if not chunk:
            raise ConnectionError("presence channel closed")
        buffer += chunk
        out = []
        while len(buffer) >= 2:
            n, at = buffer[1] & 0x7F, 2
            if n == 126:
                if len(buffer) < 4:
                    break
                n, at = struct.unpack(">H", buffer[2:4])[0], 4
            if len(buffer) < at + n:
                break
            if buffer[0] & 0x0F == 1:
                out.append(json.loads(buffer[at:at + n].decode()))
            buffer = buffer[at + n:]
        return buffer, out

    def _run(self):
        try:
            sock = socket.create_connection((self.host, self.port), timeout=5)
            key = base64.b64encode(os.urandom(16)).decode()
            origin = f"{self.host}:{self.port}"
            sock.sendall((f"GET {self.path}presence HTTP/1.1\r\nHost: {origin}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\nOrigin: http://{origin}\r\n\r\n").encode())
            head = b""
            while b"\r\n\r\n" not in head:
                head += sock.recv(1)
            if b" 101 " not in head.split(b"\r\n")[0]:
                raise ConnectionError(head.split(b"\r\n")[0].decode())
            sock.sendall(self._frame(1, json.dumps({"t": "hello", "pass": self.passcode, "name": self.name, "color": "orange"}).encode()))
            sock.settimeout(0.02)
            buffer, started = b"", time.time()
            while not self.stop_flag.is_set():
                buffer, messages = self._messages(sock, buffer)
                for message in messages:
                    if message.get("t") in ("welcome", "pointers"):
                        self.revision = message.get("r", self.revision)
                    if message.get("t") == "denied":
                        raise ConnectionError(f"denied {message.get('reason')}")
                if self.revision is not None:
                    t = time.time() - started
                    x, y = 0.30 + 0.05 * math.sin(t * 2.0), 0.35 + 0.05 * math.cos(t * 2.0)
                    sock.sendall(self._frame(1, json.dumps({"t": "move", "x": x, "y": y, "r": self.revision}).encode()))
                    self.moves += 1
                time.sleep(0.05)
            sock.sendall(self._frame(1, json.dumps({"t": "hide"}).encode()))
            sock.sendall(self._frame(8, b""))
            sock.close()
        except Exception as error:  # noqa: BLE001
            self.error = str(error)


# ---------------------------------------------------------------- test run

SCREEN_SETTINGS = ("system/screen_off_timeout", "secure/sleep_timeout", "secure/screensaver_enabled",
                   "secure/screensaver_activate_on_sleep")

CASES = ["configure", "ask-pending", "admit-live", "remote-controls", "chat-pointers", "hold-resume", "recovery", "remove-terminal", "newshare-decline",
         "newshare-admit", "stop-keeps-source", "unattended-ended", "unattended-searching", "reconfigure-live", "startup-home"]


class Run:
    def __init__(self, args):
        self.args = args
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.artifacts = HERE / "artifacts" / stamp
        self.artifacts.mkdir(parents=True)
        self.log = Log(self.artifacts / "run.log")
        self.server = AdbServer(args.adb_port, self.artifacts, int(args.serial.split("-")[1]))
        self.device = Device(args.serial, self.log, self.artifacts, self.server)
        self.fixture = Fixture("A", args.viewer_address, args.web_port, args.fixture_lifetime, self.log,
                               HERE / "runtime" / stamp / "A", self.artifacts)
        self.second = Fixture("B", args.second_address, args.second_port, args.fixture_lifetime, self.log,
                              HERE / "runtime" / stamp / "B", self.artifacts)
        self.results, self.facts, self.name = [], {}, args.name
        self.fixtures_dir = None
        self.last_live = None
        self.settings_before = None
        self.setup_started = False
        self.install_started = False
        self.startup_restore = None
        self.startup_appop_before = None
        self.changed_settings = set()
        self.reboot_pending = False
        self.expected_size = "3840x2160" if args.source == "4k" else "1280x720"
        # The bundled Demo clip is nearly still in the sampled band; generated patterns move everywhere.
        self.motion_required = args.source != "demo"

    def selected(self, name):
        return name in self.args.cases

    # ---- helpers

    def wait(self, what, predicate, timeout, interval=1.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            last = predicate()
            if last:
                return last
            time.sleep(interval)
        raise Failure(f"timed out after {timeout}s waiting for {what}")

    def phase(self, *wanted, timeout=45, keep=None):
        seen = []

        def check():
            s = self.device.screen()
            if not s["diag"] and self.device.front().startswith(PACKAGE):
                s = self.device.ensure_diagnostics()
            current = s["phase"] or s["card_phase"]
            if not seen or seen[-1] != current:
                seen.append(current)
            return s if current in wanted else None
        try:
            s = self.wait(f"receiver phase {wanted}", check, timeout, 1.0)
        except Failure:
            s = self.device.screen(keep=f"phase-fail-{int(time.time())}")
            raise Failure(f"receiver phase {s['phase'] or s['card_phase']!r} (card {s['title']!r}), wanted {wanted}; "
                          f"seen {seen}; screen: {' | '.join(s['lines'][:14])}")
        if keep:
            self.device.screen(keep=keep)
        return s

    def assert_live(self, label, fixture=None, expect_size=None, seconds=8):
        fixture = fixture or self.fixture
        self.phase("live", timeout=75)
        time.sleep(2)
        # A new peer may not report statistics for its first second; wait until it does.
        s1 = self.wait(f"{label}: decoder statistics", lambda: (lambda s: s if s["decoded"] is not None else None)(self.device.screen()), 20)
        t1 = time.time()
        sig1 = self.device.picture_signature()
        time.sleep(seconds)
        sig2 = self.device.picture_signature()
        self.last_live = sig2
        # A single OCR read over moving video can drop a line; retry until the counters are readable.
        s2 = self.wait(f"{label}: readable statistics", lambda: (lambda s: s if s["decoded"] is not None and (not expect_size or s["video"]) else None)(self.device.screen(keep=f"live-{label}")), 15)
        elapsed = time.time() - t1
        d1, d2 = s1["decoded"], s2["decoded"]
        moved = changed(sig1, sig2)
        if d1 is None or d2 is None or d2 - d1 < 3 * seconds:
            raise Failure(f"{label}: decoded frames did not advance ({d1} -> {d2} in {elapsed:.0f}s); screen {s2['lines'][:12]}")
        if self.motion_required and moved < 20:
            raise Failure(f"{label}: screen picture region did not change while live ({moved}/960 sampled points)")
        if not s2["sample_label"]:
            raise Failure(f"{label}: SAMPLE MEDIA label not visible for a sample feed")
        if expect_size and s2["video"] != expect_size:
            raise Failure(f"{label}: decoded video {s2['video']} != expected {expect_size}")
        rows = [v for v in fixture.viewers(self.name) if v["admission"] == "admitted" and v["lastSeenAgo"] < 8]
        status = fixture.status()
        if not rows or not rows[-1]["playing"] or rows[-1]["revision"] != status["revision"]:
            raise Failure(f"{label}: operator row on {fixture.tag} does not show this receiver playing revision "
                          f"{status['revision']}: {fixture.viewers(self.name)}")
        rate = (d2 - d1) / elapsed
        result = {"bufferRequested": s2["buffer_requested"], "surfaceConfirmed": s2["surface_confirmed"], "view": s2["view"],
                  "displayMode": s2["display_mode"], "video": s2["video"], "decodedPerSecond": round(rate, 1), "shownFps": s2["shown_fps"],
                  "decoderFps": s2["decoder_fps"], "decoder": s2["decoder"], "created": s2["created"], "codec": s2["codec"],
                  "dropped": s2["dropped"], "received": s2["received"], "freezes": s2["freezes"], "audio": s2["audio"],
                  "connection": s2["connection"], "pictureChanged": moved, "operatorRow": rows[-1]["health"]}
        self.log(f"{label}: live {json.dumps(result)}")
        return result

    def assert_no_media(self, label, seconds=6):
        s1 = self.device.screen()
        sig1 = self.device.picture_signature(); time.sleep(seconds); sig2 = self.device.picture_signature()
        s2 = self.device.screen(keep=f"nomedia-{label}")
        moved = changed(sig1, sig2)
        if s1["decoded"] is not None and s2["decoded"] is not None and s2["decoded"] > s1["decoded"]:
            raise Failure(f"{label}: frames still decoding ({s1['decoded']} -> {s2['decoded']})")
        if moved > 10:
            raise Failure(f"{label}: picture region still changing ({moved} sampled points)")
        if s1["audio_packets"] is not None and s2["audio_packets"] is not None and s2["audio_packets"] > s1["audio_packets"]:
            raise Failure(f"{label}: audio packets still arriving ({s1['audio_packets']} -> {s2['audio_packets']})")
        # Privacy: outside Live/Stalled no source picture may remain on screen. The rotating pattern makes a
        # retained last frame match the last live sample closely.
        if self.last_live is not None:
            # Compare only blocks that were lit in the last live frame; black-on-black is no evidence of a picture.
            lit = [(a, b) for a, b in zip(self.last_live, sig2) if a > 40]
            same = sum(1 for a, b in lit if abs(a - b) <= 6)
            if len(lit) >= 50 and same > 0.5 * len(lit):
                raise Failure(f"{label}: the last source picture is still visible ({same}/{len(lit)} lit blocks match the last live frame)")
        return s2

    def no_new_request(self, seconds, label, fixture=None):
        fixture = fixture or self.fixture
        before = len(fixture.viewers(self.name))
        time.sleep(seconds)
        rows = fixture.viewers(self.name)
        if len(rows) != before or any(v["admission"] == "pending" for v in rows):
            raise Failure(f"{label}: receiver asked again ({before} -> {len(rows)} rows: {[v['admission'] for v in rows]})")

    def pending_request(self, timeout=45, fixture=None):
        fixture = fixture or self.fixture

        def check():
            rows = [v for v in fixture.viewers(self.name) if v["admission"] == "pending" and v["lastSeenAgo"] < 10]
            return rows[-1] if rows else None
        row = self.wait(f"a pending request on {fixture.tag}", check, timeout)
        if not row["shortAddress"]:
            raise Failure("the request did not arrive through the short address")
        return row

    def admit(self, fixture=None):
        fixture = fixture or self.fixture
        row = self.pending_request(30, fixture)
        fixture.command("admit", number=row["number"])
        return row["number"]

    def restart_app(self):
        self.device.force_stop(); time.sleep(1); self.device.start_main(); time.sleep(3)
        self.device.ensure_diagnostics()

    def case(self, name, fn):
        self.log(f"=== {name}")
        started = time.time()
        try:
            detail = fn() or {}
            self.results.append({"case": name, "result": "PASS", "seconds": round(time.time() - started, 1), **detail})
            self.log(f"PASS {name}")
            return True
        except Exception as error:  # noqa: BLE001 - every failure is recorded
            try:
                if self.setup_started and name != "setup":
                    self.log(f"failure screenshot {self.device.png(f'FAIL-{name}').name}")
            except Exception:  # noqa: BLE001
                pass
            message = str(error) if isinstance(error, Failure) else traceback.format_exc()
            self.results.append({"case": name, "result": "FAIL", "seconds": round(time.time() - started, 1), "error": redact(message)})
            self.log(f"FAIL {name}: {redact(message)}")
            return False

    # ---- cases

    def preflight(self):
        if self.args.reboot:
            owner = load_emulator()
            if not owns_emulator(owner) or owner["serial"] != self.args.serial or owner.get("ready") is not True:
                raise Failure("Reboot cases require an emulator started by tv_emulator.py")
            self.device.reboot_owner = owner
        self.device.attach()
        self.device.check_identity()
        self.facts["device"] = self.device.identity
        self.facts["homeBefore"] = self.device.home_state()
        self.settings_before = self.device.settings_snapshot()
        self.facts["settingsBefore"] = self.settings_before
        installed = self.device.receiver_installed()
        self.facts["receiverInstalledBefore"] = installed
        self.facts["appopBefore"] = self.appop() if installed else None
        if installed and (self.args.fresh or self.args.uninstall):
            home = self.facts["homeBefore"]
            if (PACKAGE in home["role"].split(";") or home["resolves"].startswith(PACKAGE + "/")
                    or self.facts["appopBefore"] != "default"):
                raise Failure("Removing the existing receiver would discard its captured HOME or overlay state. Use a clean AVD.")
        apk = self.artifacts / "receiver.apk"
        shutil.copyfile(self.args.apk, apk)
        digest = hashlib.sha256(apk.read_bytes()).hexdigest()
        self.facts["apk"] = {"source": str(self.args.apk), "sha256": digest, "bytes": apk.stat().st_size}
        self.log(f"device {self.facts['device']}; HOME {self.facts['homeBefore']}; settings {self.settings_before}")
        self.log(f"APK sha256 {digest}")
        if self.args.source != "demo":
            self.fixtures_dir = self.make_pattern("3840x2160" if self.args.source == "4k" else "1280x720")
        self.fixture.start(self.fixtures_dir)
        st = self.fixture.status()
        if not (st["sharing"] and st["listener"] == "active" and st["sample"] and st["audience"] == "live"):
            raise Failure(f"fixture not sharing with an open short address: {st}")
        return {"apkSha256": digest}

    def setup(self):
        self.device.check_identity()
        self.setup_started = True
        self.install_started = True
        if self.args.fresh and self.facts["receiverInstalledBefore"]:
            self.device.adb("uninstall", "--user", str(self.device.user), PACKAGE)
            if self.device.receiver_installed():
                raise Failure("The previous receiver could not be removed for --fresh")
        result = self.device.adb("install", "--user", str(self.device.user), "-r", "-t",
                                 str(self.artifacts / "receiver.apk"), timeout=300)
        if "Success" not in result.splitlines() or not self.device.receiver_installed():
            raise Failure(f"adb install did not confirm success: {result.strip()[-300:]}")
        if self.args.ui_size:
            self.changed_settings.add("wm/size")
            self.device.sh(f"wm size {self.args.ui_size}")
            self.changed_settings.add("wm/density")
            self.device.sh(f"wm density {self.args.ui_density}")
            time.sleep(3)
        self.device.sh("logcat -c")

    def make_pattern(self, size):
        target = HERE / ".build" / f"fixtures-{size}-rotating"
        demo = target / "Demo.mp4"
        if not demo.exists():
            target.mkdir(parents=True, exist_ok=True)
            # Generated moving test pattern with a tone, served as the labeled Sample source.
            subprocess.run([str(REPO / "Vendor/bin/ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                            "-f", "lavfi", "-i", f"testsrc2=size={size}:rate=30:duration=12,rotate=a=0.5*t:c=black",
                            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=12",
                            "-c:v", "h264_videotoolbox", "-b:v", "16000k", "-profile:v", "high", "-g", "30", "-bf", "0",
                            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-shortest", str(demo)], check=True, timeout=300)
            shutil.copyfile(REPO / "Fixtures/Hold.mp4", target / "Hold.mp4")
        return target

    def check_remote_setup(self):
        """Drive first-run setup with a real DNS-SD advertisement for the fixture's short address."""
        text = self.device.setup_text
        self.device.start_main()
        self.wait("first setup", lambda: "Choose a Mac" in text(), 15)
        first = self.device.png("setup-no-macs")
        self.device.key(22, 23)
        self.wait("TV setup", lambda: "Open after restart" in text(), 15)
        startup = self.device.png("setup-tv-options")
        self.device.key(4, 21, 23)
        self.wait("manual setup", lambda: "Connect by address" in text(), 15)
        manual = self.device.png("setup-manual")
        self.device.key(23)  # Open the keyboard in the address field.
        self.device.sh("input text setbeam.local/wrong")
        self.device.key(4)   # Close only the keyboard.
        self.wait("address entered", lambda: "setbeam.local/wrong" in text(), 15)
        self.device.key(20, 20, 23)
        self.wait("viewing/link path rejected", lambda: "without a code" in text() or "Viewing links" in text(), 15)
        self.device.key(4)
        self.wait("Back restores Mac chooser", lambda: "Choose a Mac" in text(), 15)
        self.device.key(4)
        self.wait("unpaired Back returns to launcher", lambda: not self.device.front().startswith(PACKAGE + "/"), 15)
        self.device.start_main()
        self.wait("chooser reopened", lambda: "Choose a Mac" in text(), 15)

        host = "studio-mac.local"
        with open(self.artifacts / "dns-sd.log", "w") as log:
            ad = subprocess.Popen(
                ["/usr/bin/dns-sd", "-P", "Setbeam TV Integration", "_setbeam._tcp", "local", "80", host,
                 self.args.viewer_address, "v=1", "path=/", f"host={host}"],
                stdout=log, stderr=subprocess.STDOUT,
            )
            try:
                self.wait("nearby Mac", lambda: host in text(), 25)
                nearby = self.device.png("setup-nearby")
                self.device.key(23)
                self.wait("one OK opens the receiver", lambda: self.device.front().endswith(".MainActivity"), 10)
                row = self.wait("discovered Mac receives the TV request", lambda: next(
                    (v for v in self.fixture.viewers("Setbeam TV") if v["admission"] == "pending"), None), 30)
                if not row["shortAddress"] or self.fixture.status()["readers"] != 0:
                    raise Failure("nearby setup bypassed short-address approval")
            finally:
                ad.terminate()
                ad.wait(timeout=10)
        self.fixture.command("newshare")
        return {"emptySetup": first.name, "startupSetup": startup.name, "manualSetup": manual.name, "nearbySetup": nearby.name}

    def c_configure(self):
        setup = self.check_remote_setup() if self.args.check_remote_setup else {}
        self.device.configure(f"http://{self.args.viewer_address}/s/abc/", self.name, refused=True)
        self.device.configure(self.fixture.host, self.name)
        self.wait("receiver in front", lambda: self.device.front().startswith(PACKAGE + "/"), 20)
        self.device.ensure_diagnostics()
        return setup

    def c_ask_pending(self):
        row = self.pending_request(45)
        s = self.phase("waiting", timeout=30, keep="pending")
        state = self.assert_no_media("pending", 6)
        if self.fixture.status()["readers"] != 0:
            raise Failure("a media reader exists before Admit")
        if state["decoded"]:
            raise Failure(f"pending receiver reports decoded video: {state['video']} {state['decoded']}")
        # The status card must expose the same menu without requiring a Menu or Info key.
        self.device.key(4)
        self.device.png("pending")
        self.device.key(23)
        self.device.png("pending-options")
        self.wait("Options menu while pending", lambda: self.device.screen()["remote_menu"], 10)
        # The pending menu starts on Mac settings. Up/Down must stay on the strip.
        self.device.key(20, 19)
        time.sleep(2)  # Repeated controller renders must not steal focus back to the status card.
        self.device.key(23)
        self.wait("Mac settings from a pending card", lambda: self.device.front().endswith(".SetupActivity"), 15)
        self.wait("settings window visible", lambda: "Choose a Mac" in self.device.setup_text(), 15)
        self.device.key(4)
        self.wait("receiver after setup", lambda: self.device.front().endswith(".MainActivity"), 15)
        self.phase("waiting")
        rows = self.fixture.viewers(self.name)
        if len(rows) != 1 or rows[0]["number"] != row["number"]:
            raise Failure("opening pending receiver options created another join request")
        return {"number": row["number"], "card": s["title"], "operatorLabel": row["label"], "optionsFromPending": True}

    def c_admit(self):
        self.admit()
        live = self.assert_live("admit", expect_size=self.expected_size)
        self.device.png("live")
        pid = self.device.pid()
        maps = self.device.sh(f"run-as {PACKAGE} cat /proc/{pid}/maps", check=False)
        if not maps.strip():
            raise Failure("could not read the receiver's memory map to confirm native WebRTC")
        # useLegacyPackaging=false: the APK's only native library (libjingle_peerconnection_so) runs mapped from
        # base.apk. Every app maps the system WebView loader stubs; a WebView would map its implementation.
        apk_libs = self.device.sh(f"pm path --user {self.device.user} {PACKAGE}", check=False)
        native = any(" r-xp " in line and "/base.apk" in line for line in maps.splitlines())
        webview = bool(re.search(r"/(libwebviewchromium|libmonochrome[^/ ]*|libchrome[^/ ]*)\.so", maps))
        webview = webview or "sandboxed_process" in self.device.sh("ps -A -o NAME", check=False)
        surface = self.device.surface_buffer()
        if not native or webview or not surface["layer"]:
            raise Failure(f"native rendering not confirmed: webrtc lib {native}, webview {webview}, SurfaceView {surface}")
        live["surfaceBuffers"] = surface["buffers"]
        live["decoderLog"] = [l.split(": ", 1)[-1] for l in self.device.sh("logcat -d -s SetbeamPlayer:*", check=False).splitlines()
                              if "Decoder for" in l][-2:]
        live["native"] = ("executable mapping of base.apk (libjingle_peerconnection_so, uncompressed), no WebView implementation "
                          "library or renderer process, SurfaceView layer present, MediaCodec decoder created")
        if not (live.get("created") or "").endswith("(MediaCodec)") and "MediaCodec" not in " ".join(live["decoderLog"]):
            raise Failure(f"no MediaCodec decoder reported: {live.get('created')} {live['decoderLog']}")
        self.facts["live"] = live
        if self.args.source == "4k" and ("3840x2160" not in surface["buffers"] or live.get("surfaceConfirmed") not in (None, "3840x2160")):
            raise Failure(f"4K decoded but the SurfaceView buffer is {surface['buffers']} (app confirms {live.get('surfaceConfirmed')}, "
                          f"view {live.get('view')}), not 3840x2160 (UI {self.args.ui_size or 'native 3840x2160'})")
        return live

    def c_remote_controls(self):
        self.phase("live")
        self.device.key(4)  # Back closes connection info without leaving the receiver.
        clean = self.wait("clean playback after Back", lambda: (lambda s: s if not s["diag"] and not s["remote_menu"] else None)(self.device.screen()), 15)
        if not clean["sample_label"]:
            raise Failure("SAMPLE MEDIA disappeared with diagnostics")
        if "Receiver integration" in clean["text"] or re.search(r"\bLive\b", clean["text"]):
            raise Failure("the session/Live badge is still visible during clean playback")
        capture = self.device.png("clean-playback")
        self.device.key(23)
        opened = time.time()
        self.wait("receiver menu after OK", lambda: self.device.screen()["remote_menu"], 10)
        menu_capture = self.device.png("remote-menu")
        before = self.device.picture_signature()
        time.sleep(2)
        if changed(before, self.device.picture_signature()) < 20:
            raise Failure("the picture stopped advancing while the menu was open")
        observed = time.time() - opened
        if not self.device.screen()["remote_menu"]:
            # Full-resolution captures can outlast the 10 s idle timeout, which is checked on its own below.
            self.log(f"remote-controls: menu idle-closed during {observed:.1f}s of observation; reopening with OK")
            if observed < 10:
                raise Failure(f"the menu closed after only {observed:.1f}s without input")
            self.device.key(23)
            self.wait("menu reopened", lambda: self.device.screen()["remote_menu"], 10)
        # Info is the rightmost control. Going past the edge keeps it focused.
        self.device.key(22, 22, 22, 22, 22, 22, 23)
        details = self.wait("connection info from the menu", lambda: (lambda s: s if s["diag"] and not s["remote_menu"] else None)(self.device.screen()), 15)
        if "Session Receiver integration" not in details["text"]:
            raise Failure("the session name is missing from on-demand diagnostics")
        self.device.png("connection-info")
        self.device.key(20, 20, 20, 20, 20, 20, 20, 20)
        self.wait("receiver version in scrollable connection info", lambda: "Receiver 0." in self.device.screen()["text"], 10)
        self.device.png("connection-info-scrolled")
        self.device.key(4)
        self.wait("connection info hidden by Back", lambda: not self.device.screen()["diag"], 15)
        self.device.key(23)
        self.wait("menu reopens", lambda: self.device.screen()["remote_menu"], 10)
        self.device.key(4)
        self.wait("menu closed by Back", lambda: not self.device.screen()["remote_menu"], 10)
        if not self.device.front().endswith(".MainActivity"):
            raise Failure("Back left the receiver instead of dismissing its menu")
        self.device.key(23)
        self.wait("menu before Settings", lambda: self.device.screen()["remote_menu"], 10)
        self.device.key(22, 22, 22, 22, 23)
        self.wait("Mac settings using only OK and Right", lambda: self.device.front().endswith(".SetupActivity"), 15)
        self.wait("settings window visible", lambda: "Choose a Mac" in self.device.setup_text(), 15)
        self.device.key(4)  # BACK returns without changing the pairing.
        self.wait("receiver after Back", lambda: self.device.front().endswith(".MainActivity"), 15)
        resumed = self.assert_live("remote-return", expect_size=self.expected_size)
        self.device.key(4)
        self.device.key(23)
        self.wait("menu before timeout", lambda: self.device.screen()["remote_menu"], 10)
        time.sleep(6)
        self.device.key(22)  # Navigation extends the timeout even when the button consumes the event.
        time.sleep(5)
        if not self.device.screen()["remote_menu"]:
            raise Failure("the menu timed out despite recent remote input")
        self.wait("menu hides after inactivity", lambda: not self.device.screen()["remote_menu"], 15)
        if not self.device.front().endswith(".MainActivity") or self.device.screen()["diag"]:
            raise Failure("the menu timeout did not leave clean playback in front")
        self.device.key(82)  # Optional Menu key opens the same menu, rather than pairing directly.
        self.wait("optional Menu shortcut", lambda: self.device.screen()["remote_menu"], 10)
        self.device.key(4)
        self.device.ensure_diagnostics()
        return {"cleanCapture": capture.name, "menuCapture": menu_capture.name, "basicRemoteMenu": True,
                "sampleLabelRetained": True, "backDismisses": True, "timeoutAndInputReset": True,
                "resumeFps": resumed["decodedPerSecond"]}

    def c_chat_pointers(self):
        """Read-only session chat and other viewers' shared pointers, both opt-in from the remote menu."""
        self.phase("live")
        self.device.key(4)
        self.wait("clean playback", lambda: not self.device.screen()["diag"], 15)
        menu = lambda: self.device.screen()["remote_menu"]
        # The operator turns on shared pointers first, so the receiver's first channel is accepted.
        self.fixture.command("pointers", on=True)
        # The live menu opens on Sound. Check both choices with the same remote button.
        self.device.key(23)
        self.wait("menu", menu, 10)
        self.set_choice("Sound", False)
        self.set_choice("Sound", True)
        self.device.key(22, 22)
        self.set_choice("Pop-ups", True)
        self.device.key(22)
        self.set_choice("Pointers", True)
        menu_capture = self.device.png("menu-tv-choices")
        self.device.key(4)
        self.wait("menu closed", lambda: not menu(), 10)
        quiet = self.device.screen()
        if "Pointers not offered" in quiet["text"] or "Check focus" in quiet["text"]:
            raise Failure("a chat message appeared before one was sent")

        # An operator message pops up over playback, then leaves the picture clean again.
        posted = self.fixture.command("chat", text="Check focus on the left mark")
        self.wait("chat pop-up", lambda: "Check focus" in self.device.screen()["text"], 20)
        popup = self.device.png("chat-popup")
        self.wait("pop-up hides by itself", lambda: "Check focus" not in self.device.screen()["text"], 25)

        # The chat panel from the menu: OK, Right, OK. Video continues beneath it; SAMPLE MEDIA stays visible.
        self.device.key(23)
        self.wait("menu for chat", menu, 10)
        self.device.key(22, 23)
        self.wait("chat panel", lambda: (lambda s: "Session chat" in s["text"] and "Check focus" in s["text"])(self.device.screen()), 15)
        panel = self.device.png("chat-panel")
        if not self.device.screen()["sample_label"]:
            raise Failure("the chat panel hides the SAMPLE MEDIA label")
        before = self.device.picture_signature()
        time.sleep(2)
        if changed(before, self.device.picture_signature()) < 20:
            raise Failure("the picture stopped advancing while the chat panel was open")
        self.device.key(4)
        self.wait("chat panel closed by Back", lambda: "Session chat" not in self.device.screen()["text"], 10)
        if not self.device.front().endswith(".MainActivity"):
            raise Failure("Back left the receiver instead of closing chat")

        # Another admitted viewer's pointer appears over the picture and fades when it stops.
        bot = PointerBot(self.fixture, "Pointer Bot", self.log)
        bot.ask()
        self.wait("pointer bot pending", lambda: any(v["admission"] == "pending" for v in self.fixture.viewers("Pointer Bot")), 15)
        self.fixture.command("admit", name="Pointer Bot")
        self.wait("pointer bot admitted", bot.admitted, 20)
        bot.start()
        try:
            self.wait("shared pointer on the TV", lambda: "Pointer Bot" in self.device.screen()["text"], 40)
            pointer = self.device.png("shared-pointer")
            # The Mac closes a presence channel it has not heard from in 20 s; the receiver must keep it open
            # while another viewer keeps the Mac busy sending pointers.
            time.sleep(25)
            self.wait("pointer still shown after 25 s", lambda: "Pointer Bot" in self.device.screen()["text"], 6)
        finally:
            moves = bot.stop()
        self.wait("pointer fades", lambda: "Pointer Bot" not in self.device.screen()["text"], 20)
        self.fixture.command("remove", name="Pointer Bot")
        rows = self.fixture.viewers(self.name)
        if len(rows) != 1 or rows[0]["admission"] != "admitted":
            raise Failure(f"chat or pointers changed this receiver's own request: {rows}")
        details = self.device.ensure_diagnostics()
        if not re.search(r"Chat \d+ messages?", details["text"]):
            raise Failure("diagnostics do not report chat")
        if "pointers watching" not in details["text"]:
            raise Failure("the pointer channel did not stay open after the pointer stopped")
        live = self.assert_live("after-chat-pointers", expect_size=self.expected_size)
        # Restore this TV's defaults (saved on the device, kept across re-pairing) for later cases and runs.
        self.device.key(4)
        self.device.key(23)
        self.wait("menu to restore choices", menu, 10)
        self.device.key(22, 22)
        self.set_choice("Pop-ups", False)
        self.device.key(22)
        self.set_choice("Pointers", False)
        self.device.key(4)
        self.wait("menu closed after restore", lambda: not menu(), 10)
        self.device.ensure_diagnostics()
        return {"chatId": posted.get("id"), "popupCapture": popup.name, "panelCapture": panel.name, "pointerCapture": pointer.name,
                "menuCapture": menu_capture.name, "pointerMoves": moves, "resumeFps": live["decodedPerSecond"]}

    def set_choice(self, label, on):
        """With focus on a TV-choice button, presses OK only if needed so it reads On/Off as wanted."""
        def visible_choice():
            choices = self.device.screen()["menu_choices"]
            return choices if label in choices else None

        state = self.wait(f"{label} button", visible_choice, 10)
        if state[label] != on:
            self.device.key(23)
            self.wait(f"{label} {'on' if on else 'off'}", lambda: self.device.screen()["menu_choices"].get(label) is on, 10)

    def c_hold(self):
        self.fixture.command("hold")
        s = self.phase("holding", timeout=20, keep="hold")
        self.assert_no_media("hold", 6)
        self.device.key(4)
        self.device.png("hold")
        self.device.key(23)
        self.wait("receiver options during Hold", lambda: self.device.screen()["remote_menu"], 10)
        self.assert_no_media("hold-menu", 3)
        self.device.key(4)
        self.device.ensure_diagnostics()
        st = self.fixture.status()
        if not (st["sourceAvailable"] and st["monitoring"] and (st["sourceFrameAge"] or 99) < 3):
            raise Failure(f"local monitoring did not continue during Hold: {st}")
        self.fixture.command("resume")
        live = self.assert_live("resume", expect_size=self.expected_size)
        return {"holdCard": s["title"], "resume": live["decodedPerSecond"]}

    def c_recovery(self):
        out = {}
        for outage in ["source-outage", "server-outage"]:
            result = self.fixture.command(outage, timeout=120)
            live = self.assert_live(outage)
            out[outage] = {"revision": f"{result.get('revisionBefore')}->{result.get('revisionAfter')}",
                           "decodedPerSecond": live["decodedPerSecond"]}
        self.fixture.command("gateway-outage", seconds=12, timeout=60)
        out["gateway-outage"] = {"decodedPerSecond": self.assert_live("gateway-outage")["decodedPerSecond"]}
        if self.settings_before["airplane"] != "disabled":
            raise Failure("Airplane mode must be disabled to test the network outage")
        self.changed_settings.add("airplane")
        try:
            self.device.sh("cmd connectivity airplane-mode enable")
            time.sleep(15)
            during = self.device.screen(keep="airplane")
        finally:
            self.device.sh("cmd connectivity airplane-mode disable")
        live = self.assert_live("device-network")
        out["device-network"] = {"phaseDuringOutage": during["phase"] or during["card_phase"], "decodedPerSecond": live["decodedPerSecond"]}
        return out

    def c_remove(self):
        admitted = [v for v in self.fixture.viewers(self.name) if v["admission"] == "admitted"]
        if not admitted:
            raise Failure(f"precondition: no admitted session to remove (an earlier case left {self.fixture.viewers(self.name)})")
        self.fixture.command("remove", number=admitted[-1]["number"])
        s = self.phase("removed", timeout=20, keep="removed")
        self.device.png("removed")
        self.assert_no_media("removed", 5)
        self.no_new_request(25, "after removal")
        self.restart_app()
        s2 = self.phase("removed", timeout=30)
        self.no_new_request(20, "after removal and app restart")
        return {"card": s["title"], "afterRestart": s2["phase"]}

    def c_newshare_decline(self):
        result = self.fixture.command("newshare")
        if not result.get("askPath") or result.get("askPath") == result.get("previousAskPath"):
            raise Failure("new share did not rotate the ask path")
        row = self.pending_request(60)
        self.phase("waiting", timeout=20)
        self.fixture.command("decline", number=row["number"])
        s = self.phase("declined", timeout=20, keep="declined")
        self.device.png("declined")
        self.assert_no_media("declined", 4)
        self.no_new_request(25, "after decline")
        self.restart_app()
        self.phase("declined", timeout=30)
        self.no_new_request(20, "after decline and app restart")
        return {"card": s["title"]}

    def c_newshare_admit(self):
        self.fixture.command("newshare")
        self.pending_request(60)
        self.assert_no_media("fresh request", 4)
        self.admit()
        return {"decodedPerSecond": self.assert_live("fresh share admit")["decodedPerSecond"]}

    def c_stop(self):
        self.fixture.command("stop")
        s = self.phase("ended", "searching", timeout=30, keep="stopped")
        self.device.png("stopped")
        self.assert_no_media("stopped", 5)
        st = self.fixture.status()
        if st["sharing"] or not st["sourceAvailable"] or not st["monitoring"] or (st["sourceFrameAge"] or 99) > 3:
            raise Failure(f"Stop did not keep the Mac's local source: {st}")
        self.fixture.command("start")
        self.pending_request(60)
        s2 = self.phase("waiting", timeout=30)
        self.assert_no_media("after sharing restarted", 6)
        return {"stoppedPhase": s["phase"], "nextShare": s2["phase"]}

    def short_sleep_settings(self):
        # Only on the test emulator, restored at the end: a 20 s timeout with the screen saver starting on sleep.
        for key, value in (("system/screen_off_timeout", "20000"), ("secure/screensaver_enabled", "1"),
                           ("secure/screensaver_activate_on_sleep", "1")):
            self.changed_settings.add(key)
            self.device.put_setting(key, value)

    def unattended(self, label, idle, resume):
        """Leaves the receiver alone in a non-playing phase, then lets the Mac share again. No remote input."""
        try:
            self.short_sleep_settings()
            keep_on = self.device.keep_screen_on()
            time.sleep(idle)
            power, front = self.device.power(), self.device.front()
            self.log(f"{label}: after {idle}s idle: {power}, front {front}, keep-screen-on flag {keep_on}")
            resume()
            requested = True
            try:
                self.pending_request(75)
            except Failure:
                requested = False
            observed = {"keepScreenOn": keep_on, "power": power, "front": front, "askedForNewShareWithoutInput": requested}
        finally:
            for key in ("system/screen_off_timeout", "secure/screensaver_enabled", "secure/screensaver_activate_on_sleep"):
                if key in self.changed_settings:
                    self.device.put_setting(key, self.settings_before[key])
                    self.changed_settings.remove(key)
        if not requested or power["wakefulness"] != "Awake" or not front.startswith(PACKAGE):
            self.device.key(224)  # KEYCODE_WAKEUP, so the rest of the run can continue; recorded as remote input
            time.sleep(2)
            if not self.device.front().startswith(PACKAGE):
                self.device.start_main()
            raise Failure(f"{label}: unattended receiver did not stay ready: {json.dumps(observed)}")
        return observed

    def c_unattended_ended(self):
        self.fixture.command("stop")
        self.phase("ended", "searching", timeout=30, keep="ended-before-idle")
        return self.unattended("ended", 45, lambda: self.fixture.command("start"))

    def c_unattended_searching(self):
        """Lost contact while pending: a short gateway outage on the same share, then the Mac quitting entirely,
        then a new share. Expected: searching while unreachable, the same pass after a short outage, no duplicate
        asks, and exactly one ask for the new share."""
        pending = self.pending_request(30)
        rows_before = len(self.fixture.viewers(self.name))
        seq = self.fixture.send("gateway-outage", seconds=14)
        seen = []
        deadline = time.time() + 14
        while time.time() < deadline:
            st = self.device.screen()
            seen.append(st["phase"] or st["card_phase"])
            if seen[-1] == "searching":
                self.device.screen(keep="lost-contact-same-share")
                break
            time.sleep(1)
        self.wait("gateway back", lambda: self.fixture.acked(seq), 40)
        time.sleep(20)
        rows = self.fixture.viewers(self.name)
        same = [v for v in rows if v["number"] == pending["number"] and v["admission"] == "pending" and v["lastSeenAgo"] < 8]
        outage = {"phasesDuringOutage": seen, "samePassResumed": bool(same), "rowsBefore": rows_before, "rowsAfter": len(rows)}
        self.log(f"short outage while pending: {json.dumps(outage)}")
        if "searching" not in seen:
            raise Failure(f"no searching state during a 14 s gateway outage while pending: {json.dumps(outage)}")
        if len(rows) > rows_before + 1 or sum(1 for v in rows if v["admission"] == "pending" and v["lastSeenAgo"] < 8) > 1:
            raise Failure(f"duplicate requests after a short outage: {rows}")
        self.log(f"fixture A stopped: {self.fixture.stop()}")
        problem = None
        try:
            self.phase("searching", timeout=60, keep="searching-before-idle")
        except Failure as error:
            problem = f"receiver did not show searching within 60 s of the Mac quitting: {error}"
            self.log(f"FINDING {problem}")
        observed = self.unattended("searching", 45, lambda: self.fixture.start(self.fixtures_dir))
        time.sleep(15)
        asks = len(self.fixture.viewers(self.name))
        observed.update(shortOutage=outage, requestsOnNewShare=asks)
        if problem:
            raise Failure(problem + f"; afterwards: {json.dumps(observed)}")
        if asks != 1:
            raise Failure(f"the new share received {asks} requests from the receiver, expected exactly one")
        return observed

    def c_reconfigure_live(self):
        """CONFIGURE to Mac B while MainActivity is visible and playing A, without force-stop."""
        if not [v for v in self.fixture.viewers(self.name) if v["admission"] == "pending" and v["lastSeenAgo"] < 10]:
            self.pending_request(60)
        self.admit()
        self.assert_live("before reconfigure")
        a_number = [v for v in self.fixture.viewers(self.name) if v["admission"] == "admitted"][-1]["number"]
        # Only one process can answer port 80. Mac A stops offering its short address (its admitted session keeps
        # playing, as in the app), then Mac B opens its own on another address of this Mac.
        self.fixture.command("close-short")
        self.second.start(self.fixtures_dir)
        probe = self.device.sh(f"printf 'GET / HTTP/1.1\\r\\nHost: {self.second.address}\\r\\n\\r\\n' | "
                               f"nc -w 3 {self.second.address} {self.second.port} | head -1", check=False).strip()
        self.log(f"emulator -> Mac B short address: {probe!r}")
        if "302" not in probe:
            raise Failure(f"Mac B's short address is not reachable from the emulator ({probe!r}); not a receiver result")
        pid_before = self.device.pid()
        self.device.configure(self.second.host, self.name)
        try:
            row = self.pending_request(45, self.second)
        except Failure:
            s = self.device.screen(keep="reconfigure-no-request")
            raise Failure(f"no request reached Mac B within 45 s of CONFIGURE while playing A; receiver: {' | '.join(s['lines'][:16])}; "
                          f"A rows: {self.fixture.viewers(self.name)}")
        s = self.phase("waiting", timeout=30, keep="reconfigured-waiting")
        if self.device.pid() != pid_before:
            self.log("note: the receiver process changed during CONFIGURE")
        self.assert_no_media("reconfigured, pending on B", 5)
        stale = [v for v in self.fixture.viewers(self.name) if v["number"] == a_number][0]
        time.sleep(max(0, 6 - stale["lastSeenAgo"]))
        stale = [v for v in self.fixture.viewers(self.name) if v["number"] == a_number][0]
        if stale["lastSeenAgo"] < 5:
            raise Failure(f"the receiver still heartbeats Mac A after pairing B: {stale}")
        if s["route"] and s["route"].split(":")[0] != self.second.address:
            raise Failure(f"diagnostics show route {s['route']} after pairing B")
        self.second.command("admit", number=row["number"])
        live = self.assert_live("after reconfigure", fixture=self.second)
        return {"bRequest": row["number"], "aLastSeenAgo": round(stale["lastSeenAgo"], 1), "bLive": live["decodedPerSecond"],
                "route": s["route"]}

    def c_startup(self):
        """Measures HOME and the receiver's own boot start on this image with the provisioning tool, optionally
        across an emulator reboot, and restores both. Emulator only; not a cold-power or HDMI-CEC test."""
        receipts = self.artifacts / "provision-receipts"
        tool = self.artifacts / "setbeam_receiver_provision.py"
        shutil.copyfile(self.args.provision_tool, tool)
        self.facts["provisionTool"] = {"sha256": hashlib.sha256(tool.read_bytes()).hexdigest()}
        base = [sys.executable, "-I", str(tool)]
        common = ["--serial", self.args.serial, "--receipt-dir", str(receipts)]
        status = self.run_provision(base, ["status", *common, "--json"], "provision-status-before")
        if status.returncode:
            raise Failure(f"Provisioning status exited {status.returncode}")
        before, appop_before = self.device.home_state(), self.appop()
        if before != self.facts["homeBefore"] or appop_before != (self.facts["appopBefore"] or "default"):
            raise Failure("HOME or overlay app-op changed before startup testing")
        self.startup_restore = (base, ["restore", *common, "--apply"], receipts)
        self.startup_appop_before = appop_before
        cmd = ["provision", *common, "--host", self.fixture.host, "--name", self.name, "--allow-non-tv",
               "--home-key-probe", "--allow-background-start", "--apply"]
        try:
            prov = self.run_provision(base, cmd, "provision-apply")
            if prov.returncode not in (0, 3):
                raise Failure(f"Provisioning exited {prov.returncode}. See provision-apply.txt.")
            during, appop_during = self.device.home_state(), self.appop()
            if appop_during != "allow":
                raise Failure("Provisioning did not grant SYSTEM_ALERT_WINDOW")
            if prov.returncode == 0 and not during["resolves"].startswith(PACKAGE + "/"):
                raise Failure(f"Tool reported HOME verified but HOME resolves to {during['resolves']}")
            if prov.returncode == 3 and during != before:
                raise Failure("Tool reported HOME unavailable and left HOME changed")
            flush = None
            if self.args.flush_appops:
                flush = self.device.sh("cmd appops write-settings").strip()
                if flush != "Current settings written.":
                    raise Failure("Android did not acknowledge the app-op save")
            boots = []
            if self.args.reboot:
                modes = ["graceful", "hard"] if self.args.reboot_mode == "both" else [self.args.reboot_mode]
                for mode in modes:
                    boots.append(self.boot_check(mode, flush))
        finally:
            self.restore_startup()
        result = {"provisionExit": prov.returncode, "homeDuring": during, "homeAfterRestore": self.device.home_state(),
                  "appopDuring": appop_during, "boots": boots}
        bad = [b for b in boots if not (b["frontAfterBoot"].startswith(PACKAGE) and b.get("liveAfterBoot"))]
        if bad:
            raise Failure(f"receiver did not open and play by itself after reboot: {json.dumps(bad)[:1500]}")
        return result

    def run_provision(self, base, args, log_name):
        self.device.check_identity()
        env = {
            **self.server.env,
            "SETBEAM_EXPECT_TRANSPORT_ID": self.device.transport,
            "SETBEAM_EXPECT_ANDROID_USER": str(self.device.user),
            "SETBEAM_EXPECT_HARDWARE_SERIAL_SHA256": hashlib.sha256(self.device.identity["ro.serialno"].encode()).hexdigest(),
            "SETBEAM_EXPECT_BUILD_FINGERPRINT": self.device.identity["ro.build.fingerprint"],
        }
        result = subprocess.run(base + args, capture_output=True, text=True, timeout=300, env=env)
        (self.artifacts / f"{log_name}.txt").write_text(redact(result.stdout + result.stderr))
        return result

    def restore_startup(self):
        if self.startup_restore is None:
            return
        if self.reboot_pending:
            try:
                self.device.check_identity()
            except (Failure, subprocess.SubprocessError):
                self.device.attach(seconds=30, reboot=True)
            self.reboot_pending = False
        base, args, receipts = self.startup_restore
        if any(path for path in receipts.glob("receiver-*.json") if ".restored-" not in path.name):
            result = self.run_provision(base, args, "provision-restore")
            if result.returncode:
                raise Failure(f"Provisioning restore exited {result.returncode}. See provision-restore.txt.")
        if self.device.home_state() != self.facts["homeBefore"] or self.appop() != self.startup_appop_before:
            raise Failure("HOME or overlay app-op differs from the captured state after restore")
        self.startup_restore = None

    def boot_check(self, mode, flush):
        """Reboots the emulator, then observes, without any input first, whether the receiver opens and plays."""
        identity = {"user": self.device.user, "bootIdBefore": self.device.boot_id, "appopBeforeReboot": self.appop()}
        if identity["appopBeforeReboot"] != "allow":
            raise Failure("Background-start permission is missing before reboot")
        self.device.sh("logcat -c")
        self.reboot_pending = True
        if mode == "graceful":
            self.device.sh("svc power reboot", check=False, timeout=60)
        else:
            self.device.adb("reboot", check=False, timeout=60)
        self.device.attach(seconds=400, reboot=True)
        self.reboot_pending = False
        if self.appop() != "allow":
            raise Failure("Background-start permission did not survive reboot")
        booted = time.time()
        try:
            front = self.wait("receiver in front after boot", lambda: (lambda f: f if f.startswith(PACKAGE) else None)(self.device.front()), 120, 3)
        except Failure:
            front = self.device.front()
        boot = {"rebootMode": mode, "flush": flush, **identity,
                "bootIdAfter": self.device.boot_id,
                "userAfter": self.device.user,
                "uid": (re.search(r"appId=(\d+)", self.device.sh(f"dumpsys package {PACKAGE}", check=False)) or [None, ""])[1],
                "frontAfterBoot": front, "secondsToFront": round(time.time() - booted, 1), "appopAfterBoot": self.appop(),
                "homeAfterBoot": self.device.home_state()}
        if boot["bootIdAfter"] == boot["bootIdBefore"]:
            raise Failure(f"{mode} reboot did not change boot_id")
        (self.artifacts / f"appops-after-{mode}-boot.txt").write_text(self.device.sh(f"dumpsys appops --package {PACKAGE}", check=False))
        if front.startswith(PACKAGE):
            # No input yet: the operator row must show this receiver playing the current revision, and the screen picture must move.
            try:
                self.wait("receiver playing after boot", lambda: any(v["lastSeenAgo"] < 8 and v["playing"] and v["revision"] == self.fixture.status()["revision"]
                                                                     for v in self.fixture.viewers(self.name)), 90, 3)
                sig1 = self.device.picture_signature(); time.sleep(6); sig2 = self.device.picture_signature()
                boot["pictureChangedNoInput"] = changed(sig1, sig2)
                boot["operatorRow"] = [(v["number"], v["admission"], v["health"]) for v in self.fixture.viewers(self.name) if v["lastSeenAgo"] < 8]
                self.device.png(f"after-{mode}-boot-no-input")
                # Then INFO is pressed only to read the receiver's own decoded-frame counters.
                boot["liveAfterBoot"] = self.assert_live(f"after-{mode}-boot")
                boot["diagnosticsNeededInfoKey"] = True
                if boot["pictureChangedNoInput"] < 20:
                    boot["liveAfterBoot"] = None
            except Failure as error:
                boot["liveAfterBoot"] = None
                boot["afterBootProblem"] = str(error)[:400]
        boot["log"] = [redact(l) for l in self.device.sh("logcat -d", check=False).splitlines()
                       if "Setbeam" in l or ("setbeam" in l and re.search(r"(?i)background activity|BAL|abort", l))][-10:]
        self.log(f"after {mode} reboot: {json.dumps(boot)}")
        return boot

    def appop(self):
        out = self.device.sh(f"appops get --user {self.device.user} {PACKAGE} SYSTEM_ALERT_WINDOW")
        # The provisioning tool handles both API 36 unused-op forms.
        mode = parse_overlay_mode(out)
        if mode is None:
            raise Failure("Cannot read exact receiver overlay app-op")
        return mode

    # ---- driver

    def restore_device(self):
        notes = []
        if not self.setup_started:
            return notes

        def restore(label, action):
            try:
                action()
            except Exception as error:  # noqa: BLE001
                notes.append(f"{label}: {error}")

        restore("startup restore", self.restore_startup)
        for key, value in self.settings_before.items():
            def restore_setting(key=key, value=value):
                if key.startswith("wm/"):
                    mode = key.split("/")[1]
                    self.device.sh(f"wm {mode} {value or 'reset'}")
                elif key == "airplane":
                    self.device.sh(f"cmd connectivity airplane-mode {value.removesuffix('d')}")
                else:
                    self.device.put_setting(key, value)
            if key in self.changed_settings:
                restore(key, restore_setting)

        def verify():
            after = self.device.settings_snapshot()
            self.facts["settingsAfter"] = after
            if after != self.settings_before:
                notes.append(f"settings differ after restore: {after}")
            self.facts["homeAfter"] = self.device.home_state()
            if self.facts["homeAfter"] != self.facts["homeBefore"]:
                notes.append(f"HOME differs from baseline: {self.facts['homeAfter']}")
            if self.device.receiver_installed():
                mode = self.appop()
                self.facts["appopAfter"] = mode
                expected = self.facts.get("appopBefore") or "default"
                if mode != expected:
                    notes.append(f"overlay app-op differs from baseline: {mode} (expected {expected})")
                if self.args.uninstall and self.startup_restore is None:
                    notes.append("receiver is still installed after requested removal")
        def uninstall():
            if self.device.receiver_installed():
                self.device.adb("uninstall", "--user", str(self.device.user), PACKAGE)

        if self.args.uninstall and self.install_started and self.startup_restore is None:
            restore("receiver uninstall", uninstall)
        restore("restore verification", verify)
        return notes

    def execute(self):
        ok = False
        interrupted = False
        notes = []
        try:
            ok = self.execute_cases()
        except KeyboardInterrupt:
            interrupted = True
            self.log("INTERRUPTED: cleaning up owned fixtures and emulator settings")
        except Exception as error:  # noqa: BLE001
            self.log(f"FAIL: {error}")
        finally:
            try:
                for fixture in (self.fixture, self.second):
                    try:
                        cleanup = fixture.stop()
                        self.log(f"fixture {fixture.tag} cleanup: {cleanup}")
                        self.facts[f"fixture{fixture.tag}Cleanup"] = cleanup
                        if "NO cleanup confirmation" in cleanup:
                            notes.append(f"fixture {fixture.tag} did not confirm cleanup")
                    except Exception as error:  # noqa: BLE001
                        notes.append(f"fixture {fixture.tag} cleanup failed: {error}")
                notes.extend(self.restore_device())
            finally:
                try:
                    self.server.stop()
                except Exception as error:  # noqa: BLE001
                    notes.append(f"private adb cleanup failed: {error}")
        for note in notes:
            self.log(f"RESTORE PROBLEM {note}")
        passed = {entry["case"] for entry in self.results if entry["result"] == "PASS"}
        missing = [name for name in self.args.cases if name not in passed]
        summary = {"ok": ok and not notes and not missing, "results": self.results, "facts": self.facts,
                   "missingOrFailedCases": missing, "restoreProblems": notes,
                   "evidence": "Android TV emulator software evidence only."}
        (self.artifacts / "summary.json").write_text(json.dumps(summary, indent=2))
        self.log(f"summary: {self.artifacts / 'summary.json'}")
        return 130 if interrupted else (0 if summary["ok"] else 1)

    def execute_cases(self):
        self.server.start()
        if not self.case("preflight", self.preflight) or not self.case("setup", self.setup):
            return False
        ok = True
        dependent = True
        table = [("configure", self.c_configure), ("ask-pending", self.c_ask_pending), ("admit-live", self.c_admit),
                 ("remote-controls", self.c_remote_controls), ("chat-pointers", self.c_chat_pointers),
                 ("hold-resume", self.c_hold), ("recovery", self.c_recovery), ("remove-terminal", self.c_remove),
                 ("newshare-decline", self.c_newshare_decline), ("newshare-admit", self.c_newshare_admit),
                 ("stop-keeps-source", self.c_stop), ("unattended-ended", self.c_unattended_ended),
                 ("unattended-searching", self.c_unattended_searching), ("reconfigure-live", self.c_reconfigure_live)]
        if ok:
            for name, fn in table:
                if not self.selected(name):
                    continue
                passed = self.case(name, fn)
                ok = ok and passed
                # The first three build the paired, admitted state every later case needs.
                if not passed and name in ("configure", "ask-pending", "admit-live"):
                    dependent = False
                    break
                if not passed:
                    self.recover_baseline()
        if dependent and self.selected("startup-home"):
            ok = self.case("startup-home", self.c_startup) and ok
        return ok

    def recover_baseline(self):
        """After a failed case, return to a known state (fixture A sharing, receiver in front) so later cases still run."""
        try:
            if not (self.fixture.proc and self.fixture.proc.poll() is None):
                self.fixture.start(self.fixtures_dir)
            self.device.key(224)
            if not self.device.front().startswith(PACKAGE):
                self.device.start_main()
            st = self.fixture.status()
            if not st["sharing"]:
                self.fixture.command("start")
        except Exception as error:  # noqa: BLE001
            self.log(f"baseline recovery failed: {error}")


def default_address(interfaces=("en0", "en1")):
    for interface in interfaces:
        out = subprocess.run(["ipconfig", "getifaddr", interface], capture_output=True, text=True).stdout.strip()
        if out:
            return out
    return ""


def parse_cases(raw, skip_startup):
    if raw == "all":
        return [name for name in CASES if not (skip_startup and name == "startup-home")]
    cases = raw.split(",")
    unknown = [name for name in cases if name not in CASES]
    if unknown:
        raise ValueError(f"Unrecognized case names {', '.join(map(repr, unknown))}")
    if len(cases) != len(set(cases)):
        raise ValueError("Each test case may be requested only once")
    if skip_startup and "startup-home" in cases:
        raise ValueError("--skip-startup conflicts with the requested startup-home case")
    return cases


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--serial", required=True, help="explicit emulator serial, e.g. emulator-5574")
    p.add_argument("--apk", default=str(DEFAULT_APK))
    p.add_argument("--viewer-address", default=default_address(), help="Mac A: this Mac's LAN IPv4, reached through the emulator NAT")
    p.add_argument("--web-port", type=int, default=80)
    p.add_argument("--second-address", default="", help="Mac B for reconfigure-live (default: en1, else Mac A's address)")
    p.add_argument("--second-port", type=int, default=80)
    p.add_argument("--name", default="Stage TV Test")
    p.add_argument("--source", choices=["pattern", "4k", "demo"], default="pattern",
                   help="generated 1280x720 pattern, generated 3840x2160 pattern, or the bundled Demo clip; all labeled Sample")
    p.add_argument("--ui-size", default="", help="temporary `wm size` override such as 1920x1080 (restored)")
    p.add_argument("--ui-density", default="320")
    p.add_argument("--cases", default="all", help=f"comma list or all: {','.join(CASES)}")
    p.add_argument("--fixture-lifetime", type=int, default=3600)
    p.add_argument("--adb-port", type=int, default=5137, help="private adb server port owned by this run")
    p.add_argument("--fresh", action="store_true", help="uninstall the receiver first so no earlier pairing remains")
    p.add_argument("--check-remote-setup", action="store_true", help="also exercise D-pad setup and local DNS-SD during configure; requires --fresh")
    p.add_argument("--uninstall", action="store_true", help="uninstall the receiver at the end")
    p.add_argument("--skip-build", action="store_true")
    p.add_argument("--skip-startup", action="store_true")
    p.add_argument("--reboot", action="store_true", help="reboot the emulator after provisioning to observe the receiver's own start")
    p.add_argument("--reboot-mode", choices=["graceful", "hard", "both"], default="graceful")
    p.add_argument("--provision-tool", default=str(PROVISION), help="provisioning tool file; copied and hashed per run")
    p.add_argument("--flush-appops", action="store_true", help="run `cmd appops write-settings` after grant and restore")
    args = p.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    if args.check_remote_setup and not args.fresh:
        p.error("--check-remote-setup requires --fresh")
    match = re.fullmatch(r"emulator-([0-9]{4})", args.serial)
    if not match or not valid_port(int(match.group(1))):
        p.error("An explicit emulator console serial is required")
    if not 1024 <= args.adb_port <= 65535 or args.adb_port in (5037, int(match.group(1)), int(match.group(1)) + 1):
        p.error("Choose a private adb port outside the emulator console/transport and shared adb ports")
    try:
        args.cases = parse_cases(args.cases, args.skip_startup)
    except ValueError as error:
        p.error(str(error))
    if (args.reboot or args.flush_appops) and "startup-home" not in args.cases:
        p.error("--reboot and --flush-appops require startup-home")
    if args.check_remote_setup and "configure" not in args.cases:
        p.error("--check-remote-setup requires configure")
    if args.ui_size and (not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", args.ui_size)
                         or not re.fullmatch(r"[1-9][0-9]*", args.ui_density)):
        p.error("Invalid display size or density override")
    if not args.viewer_address:
        p.error("--viewer-address is required (no en0/en1 IPv4)")
    if not args.second_address:
        other = default_address(("en1", "en0"))
        args.second_address = other if other and other != args.viewer_address else args.viewer_address
    if "reconfigure-live" in args.cases and args.second_address == args.viewer_address:
        p.error("Mac B needs a second IPv4 address of this Mac (en1); the short address only answers on port 80")
    try:
        args.viewer_address = str(ipaddress.IPv4Address(args.viewer_address))
        args.second_address = str(ipaddress.IPv4Address(args.second_address))
    except ValueError:
        p.error("Use IPv4 addresses for both Mac fixtures")
    if not args.skip_build:
        subprocess.run(["swift", "build", "--package-path", str(HERE), "--scratch-path", str(HERE / ".build/swift")], check=True)
    return Run(args).execute()


if __name__ == "__main__":
    sys.exit(main())
