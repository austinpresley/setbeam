#!/usr/bin/env python3
"""Provision, inspect and restore one dedicated Setbeam Receiver TV device.

Runs on the Mac and talks to exactly one Android TV / Google TV device that the
operator names with --serial. Nothing changes on the device without --apply.

Bounds (see receiver/docs/startup.md):
  * One explicit adb serial per run. ANDROID_SERIAL and "the only device" are
    never used to pick a device.
  * Installs only a supplied APK whose package is com.setbeam.receiver and
    whose manifest declares the contracted launcher, HOME and CONFIGURE entries.
  * Changes only: the Setbeam Receiver package, its configuration intent (to
    the WRITE_SECURE_SETTINGS-guarded provisioning activity), the HOME role,
    and (opt-in) the receiver's own SYSTEM_ALERT_WINDOW app-op. The opt-in
    HOME key probe also opens Settings and presses HOME once.
    Every change except configuration is recorded in a local receipt first
    and restored by `restore --apply`, which verifies each step and refuses
    rather than guess when the prior state cannot be read exactly
    (HOME before Android 14, an unreadable overlay mode, another Android
    user, or a different device).
  * Never reboots, roots, flashes, factory-resets, disables or uninstalls other
    packages, edits global settings, or reads app data.
  * Remote shell arguments are quoted individually; local processes run
    without a shell.
"""

from __future__ import annotations

import argparse
from collections import Counter
import contextlib
import datetime as _dt
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path
from typing import Any, Callable, Optional

TOOL_NAME = "setbeam-receiver"
RECEIPT_SCHEMA = 1

PACKAGE = "com.setbeam.receiver"
MAIN_ACTIVITY = f"{PACKAGE}.MainActivity"
MAIN_COMPONENT = f"{PACKAGE}/{MAIN_ACTIVITY}"
ACTION_CONFIGURE = f"{PACKAGE}.CONFIGURE"
EXTRA_HOST = "setbeam_host"
EXTRA_NAME = "setbeam_name"
ROLE_HOME = "android.app.role.HOME"
RESOLVER_PACKAGE = "android"
OVERLAY_OP = "SYSTEM_ALERT_WINDOW"
OVERLAY_PERMISSION = "android.permission.SYSTEM_ALERT_WINDOW"
BOOT_PERMISSION = "android.permission.RECEIVE_BOOT_COMPLETED"
BOOT_ACTION = "android.intent.action.BOOT_COMPLETED"
APPOP_MODES = ("allow", "ignore", "deny", "default", "foreground", "errored")
# `cmd role get-role-holders` exists from Android 14 (packages/modules/Permission,
# android-14.0.0_r1; absent at android-12.0.0_r1 and -13.0.0_r1). Without it the
# exact HOME role holder cannot be read, so HOME changes are refused below this.
MIN_HOME_SDK = 34
CONFIGURE_PERMISSION = "android.permission.WRITE_SECURE_SETTINGS"
PROVISION_LOG_TAG = "SetbeamProvision"  # ProvisionActivity logs "Pairing accepted for <url>" / "Pairing refused: ...".
SETTINGS_ACTION = "android.settings.SETTINGS"
# Factory placeholder or missing values that cannot tell two devices apart.
PLACEHOLDER_SERIALS = {"", "unknown", "null", "none", "0", "0123456789abcdef", "0123456789", "1234567890abcdef", "abcdef0123456789", "serialno", "default"}
NAME_MAX = 40  # Matches the gateway's join-name limit (docs/receiver-protocol.md).
REPO_ROOT = Path(__file__).resolve().parents[2]

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_REFUSED = 2
EXIT_HOME_UNAVAILABLE = 3
EXIT_DEVICE = 4
EXIT_RESTORE_MISMATCH = 5

SERIAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:\-\[\]%@+]{0,127}$")
LABEL_RE = re.compile(r"^(?!-)[A-Za-z0-9-]{1,63}(?<!-)$")
COMPONENT_RE = re.compile(r"^([A-Za-z][\w.]*)/([\w.$]+)$")
PRIORITY_RE = re.compile(r"priority=(-?\d+)")


class ToolError(Exception):
    def __init__(self, message: str, code: int = EXIT_FAILED):
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------------------
# Output


class Out:
    def __init__(self, quiet_json: bool = False):
        self.quiet = quiet_json

    def line(self, text: str = "") -> None:
        if not self.quiet:
            print(text, flush=True)

    def item(self, label: str, value: Any) -> None:
        self.line(f"  {label}: {value}")

    def warn(self, text: str) -> None:
        print(f"warning: {text}", file=sys.stderr, flush=True)


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()


# --------------------------------------------------------------------------
# Input validation


def validate_serial(serial: str) -> str:
    if not serial or not SERIAL_RE.match(serial):
        raise ToolError(
            "--serial must be one adb serial exactly as shown by `adb devices` "
            "(letters, digits and . _ : - [ ] % @ +; no spaces).",
            EXIT_REFUSED,
        )
    return serial


def validate_host(raw: str) -> str:
    """Return the normalized short-address base URL, or refuse.

    Error messages never echo the input: a pasted viewing link carries the
    link's private code, which is also a media credential.
    """
    from urllib.parse import urlsplit

    if not isinstance(raw, str) or not raw or len(raw) > 300:
        raise ToolError("--host must be a short-address URL such as http://setbeam.local/.", EXIT_REFUSED)
    if any(ch.isspace() or unicodedata.category(ch).startswith("C") for ch in raw):
        raise ToolError("--host contains spaces or control characters.", EXIT_REFUSED)
    if "?" in raw or "#" in raw:
        raise ToolError("--host must not contain a query or fragment.", EXIT_REFUSED)
    try:
        parts = urlsplit(raw)
        port = parts.port
    except ValueError:
        raise ToolError("--host is not a valid URL (check the port).", EXIT_REFUSED) from None
    if parts.scheme.lower() == "https":
        raise ToolError(
            "--host must use http://. The Setbeam short address answers only plain HTTP on port 80.",
            EXIT_REFUSED,
        )
    if parts.scheme.lower() != "http":
        raise ToolError("--host must start with http://.", EXIT_REFUSED)
    if "@" in parts.netloc or parts.username is not None or parts.password is not None:
        raise ToolError("--host must not contain a user name or password.", EXIT_REFUSED)
    if parts.path not in ("", "/"):
        raise ToolError(
            "--host must be the short address itself with path '/', such as http://setbeam.local/. "
            "Viewing-link and /s/ paths contain private codes and are refused; the path was not printed.",
            EXIT_REFUSED,
        )
    if port is not None and port != 80:
        raise ToolError("--host must use port 80 (the short address port).", EXIT_REFUSED)
    host = (parts.hostname or "").rstrip(".")
    if not host:
        raise ToolError("--host has no host name.", EXIT_REFUSED)
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None:
        if address.version != 4:
            raise ToolError("--host must be a name or an IPv4 address; the receiver connects over IPv4.", EXIT_REFUSED)
        if address.is_loopback or address.is_unspecified or address.is_multicast:
            raise ToolError("--host must be the Mac's address on the viewing network, not a loopback or wildcard address.", EXIT_REFUSED)
        normalized_host = str(address)
    else:
        labels = host.lower().split(".")
        if len(host) > 253 or not all(LABEL_RE.match(label) for label in labels):
            raise ToolError("--host has an invalid host name.", EXIT_REFUSED)
        if labels[-1] == "localhost" or host.lower() == "localhost":
            raise ToolError("--host must name the Mac, not localhost.", EXIT_REFUSED)
        if labels[-1].isdigit():
            raise ToolError("--host has an invalid host name.", EXIT_REFUSED)
        normalized_host = ".".join(labels)
    return f"http://{normalized_host}/"


def validate_name(raw: str) -> str:
    if not isinstance(raw, str):
        raise ToolError("--name is required.", EXIT_REFUSED)
    if any(unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Co", "Cn") or ch in "  " for ch in raw):
        raise ToolError("--name must not contain control or invisible formatting characters.", EXIT_REFUSED)
    name = " ".join(raw.split())
    if not name:
        raise ToolError("--name must not be empty.", EXIT_REFUSED)
    if len(name) > NAME_MAX:
        raise ToolError(f"--name must be at most {NAME_MAX} characters.", EXIT_REFUSED)
    return name


def remote_command(argv: list[str]) -> str:
    """Quote each argument for the device's POSIX shell (adb shell runs `sh -c`)."""
    for arg in argv:
        if "\x00" in arg:
            raise ToolError("Refusing an argument with a NUL byte.", EXIT_REFUSED)
    return " ".join(shlex.quote(arg) for arg in argv)


def full_component(component: str) -> str:
    match = COMPONENT_RE.match(component.strip())
    if not match:
        return component.strip()
    package, cls = match.groups()
    if cls.startswith("."):
        cls = package + cls
    return f"{package}/{cls}"


def component_package(component: Optional[str]) -> Optional[str]:
    if not component or "/" not in component:
        return None
    return component.split("/", 1)[0]


# --------------------------------------------------------------------------
# Tool discovery


def sdk_root_candidates() -> list[Path]:
    roots = []
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(var):
            roots.append(Path(os.environ[var]).expanduser())
    roots.append(Path.home() / "Library" / "Android" / "sdk")
    return roots


def find_adb(explicit: Optional[str]) -> str:
    candidates = [explicit, os.environ.get("SETBEAM_ADB")]
    candidates += [str(root / "platform-tools" / "adb") for root in sdk_root_candidates()]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("adb")
    if found:
        return found
    raise ToolError(
        "adb was not found. Install Android SDK Platform-Tools (see receiver/docs/startup.md) "
        "or pass --adb /path/to/adb.",
        EXIT_REFUSED,
    )


def find_aapt2(explicit: Optional[str]) -> str:
    candidates = [explicit, os.environ.get("SETBEAM_AAPT2")]
    for root in sdk_root_candidates():
        build_tools = root / "build-tools"
        if build_tools.is_dir():
            versions = sorted(build_tools.iterdir(), key=lambda p: [int(x) if x.isdigit() else 0 for x in re.split(r"[.-]", p.name)], reverse=True)
            candidates += [str(v / "aapt2") for v in versions]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise ToolError(
        "aapt2 was not found. Install Android SDK Build-Tools or pass --aapt2; "
        "the APK is inspected on the Mac before anything is installed.",
        EXIT_REFUSED,
    )


def child_env() -> dict[str, str]:
    env = dict(os.environ)
    env.pop("ANDROID_SERIAL", None)  # Device requests use the pinned transport ID.
    return env


# --------------------------------------------------------------------------
# APK inspection (on the Mac; the APK is never executed here)


def parse_xmltree(text: str) -> dict[str, Any]:
    """Parse `aapt2 dump xmltree --file AndroidManifest.xml` into a tree."""
    root: dict[str, Any] = {"tag": "#root", "attrs": {}, "children": []}
    stack: list[tuple[int, dict[str, Any]]] = [(-1, root)]
    attr_re = re.compile(r'^A: (?:[^=]*?:)?([A-Za-z_][\w]*)(?:\(0x[0-9a-fA-F]+\))?=(.*)$')
    for raw in text.splitlines():
        stripped = raw.lstrip(" ")
        indent = len(raw) - len(stripped)
        if stripped.startswith("E: "):
            tag = stripped[3:].split(" ", 1)[0]
            node = {"tag": tag, "attrs": {}, "children": []}
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack[-1][1]["children"].append(node)
            stack.append((indent, node))
        elif stripped.startswith("A: "):
            match = attr_re.match(stripped)
            if not match:
                continue
            key, value = match.groups()
            quoted = re.match(r'^"((?:[^"\\]|\\.)*)"', value)
            if quoted:
                value = quoted.group(1)
            else:
                value = value.split(" ", 1)[0]
            while len(stack) > 1 and stack[-1][0] >= indent:
                stack.pop()
            stack[-1][1]["attrs"][key] = value
    return root


def _children(node: dict[str, Any], tag: str) -> list[dict[str, Any]]:
    return [c for c in node["children"] if c["tag"] == tag]


def _qualify(package: str, name: str) -> str:
    if name.startswith("."):
        return package + name
    if "." not in name:
        return f"{package}.{name}"
    return name


def analyze_manifest(tree: dict[str, Any]) -> dict[str, Any]:
    manifests = _children(tree, "manifest")
    if not manifests:
        raise ToolError("The APK manifest could not be read.", EXIT_REFUSED)
    manifest = manifests[0]
    package = manifest["attrs"].get("package", "")
    permissions = sorted(
        c["attrs"].get("name", "") for c in manifest["children"] if c["tag"] in ("uses-permission", "uses-permission-sdk-23")
    )
    target_sdk = None
    for uses_sdk in _children(manifest, "uses-sdk"):
        target_sdk = uses_sdk["attrs"].get("targetSdkVersion", target_sdk)
    components: list[dict[str, Any]] = []
    for app in _children(manifest, "application"):
        if app["attrs"].get("enabled") == "false":
            continue
        for comp in app["children"]:
            if comp["tag"] not in ("activity", "activity-alias", "receiver"):
                continue
            name = _qualify(package, comp["attrs"].get("name", ""))
            filters = []
            for flt in _children(comp, "intent-filter"):
                filters.append(
                    {
                        "actions": sorted(a["attrs"].get("name", "") for a in _children(flt, "action")),
                        "categories": sorted(c["attrs"].get("name", "") for c in _children(flt, "category")),
                    }
                )
            exported_raw = comp["attrs"].get("exported")
            try:
                legacy_export = target_sdk is None or int(str(target_sdk), 0) < 31
            except ValueError:
                legacy_export = False
            exported = exported_raw == "true" or (exported_raw is None and bool(filters) and legacy_export)
            if comp["attrs"].get("enabled") == "false":
                continue
            if comp["tag"] == "activity-alias":
                # AOSP ParsedActivityUtils: "An alias will override permissions to allow referencing an
                # Activity through its alias without needing the original permission." An alias has
                # only its own permission, never its target's or the application's.
                permission = comp["attrs"].get("permission")
            else:
                # Activities and receivers fall back to the application's permission.
                permission = comp["attrs"].get("permission") or app["attrs"].get("permission")
            components.append(
                {
                    "kind": "receiver" if comp["tag"] == "receiver" else "activity",
                    "alias": comp["tag"] == "activity-alias",
                    "name": name,
                    "exported": exported,
                    "filters": filters,
                    "permission": permission,
                }
            )

    def has(kind: str, name: Optional[str], action: str, categories: tuple[str, ...] = ()) -> list[dict[str, Any]]:
        found = []
        for comp in components:
            if comp["kind"] != kind or (name and comp["name"] != name):
                continue
            for flt in comp["filters"]:
                if action in flt["actions"] and all(cat in flt["categories"] for cat in categories):
                    found.append(comp)
                    break
        return found

    home = has("activity", MAIN_ACTIVITY, "android.intent.action.MAIN", ("android.intent.category.HOME", "android.intent.category.DEFAULT"))
    configure_any = has("activity", None, ACTION_CONFIGURE) + has("receiver", None, ACTION_CONFIGURE)
    configure_unprotected = [c["name"] for c in configure_any if c["exported"] and c["permission"] != CONFIGURE_PERMISSION]
    configure_protected = [
        c for c in has("activity", None, ACTION_CONFIGURE)
        if c["exported"] and not c["alias"] and c["permission"] == CONFIGURE_PERMISSION
    ]
    boot = has("receiver", None, BOOT_ACTION)
    return {
        "package": package,
        "target_sdk": target_sdk,
        "permissions": permissions,
        "main_exported": any(c["name"] == MAIN_ACTIVITY and c["exported"] for c in components),
        "home_on_main": bool(home),
        "configure": None if configure_unprotected else (configure_protected or [None])[0],
        "configure_declared": bool(configure_any),
        "configure_unprotected": configure_unprotected,
        "boot_receiver": bool(boot),
        "boot_available": any(c["exported"] and not c["permission"] for c in boot),
    }


def verify_apk(apk_path: str, aapt2: str, out: Out) -> dict[str, Any]:
    path = Path(apk_path).expanduser()
    if not path.is_file() or path.suffix.lower() != ".apk":
        raise ToolError("--apk must name an existing .apk file.", EXIT_REFUSED)
    if path.stat().st_size > 512 * 1024 * 1024:
        raise ToolError("--apk is larger than 512 MB; refusing.", EXIT_REFUSED)
    run = lambda args: subprocess.run(  # noqa: E731
        [aapt2, *args], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env=child_env()
    )
    badging = run(["dump", "badging", str(path)])
    if badging.returncode != 0:
        raise ToolError("aapt2 could not read the APK (not a valid APK?).", EXIT_REFUSED)
    package_match = re.search(r"^package: name='([^']*)'(?: versionCode='(\d*)')?(?: versionName='([^']*)')?", badging.stdout, re.M)
    if not package_match:
        raise ToolError("The APK has no package line.", EXIT_REFUSED)
    package, version_code, version_name = package_match.groups()
    if not version_code:
        raise ToolError("The APK version code could not be read.", EXIT_REFUSED)
    if package != PACKAGE:
        raise ToolError(f"The APK package is {package!r}, not {PACKAGE}; refusing to install it.", EXIT_REFUSED)
    leanback = re.findall(r"^leanback-launchable-activity: name='([^']*)'", badging.stdout, re.M)
    launchable = re.findall(r"^launchable-activity: name='([^']*)'", badging.stdout, re.M)
    if MAIN_ACTIVITY not in leanback:
        raise ToolError(
            f"The APK does not declare {MAIN_ACTIVITY} as its TV (LEANBACK_LAUNCHER) activity; refusing.", EXIT_REFUSED
        )
    xml = run(["dump", "xmltree", "--file", "AndroidManifest.xml", str(path)])
    if xml.returncode != 0:
        raise ToolError("aapt2 could not read the APK manifest.", EXIT_REFUSED)
    manifest = analyze_manifest(parse_xmltree(xml.stdout))
    if manifest["package"] != PACKAGE:
        raise ToolError("The APK manifest package does not match its badging; refusing.", EXIT_REFUSED)
    if not manifest["main_exported"]:
        raise ToolError(f"{MAIN_ACTIVITY} is not exported; refusing.", EXIT_REFUSED)
    if not manifest["home_on_main"]:
        raise ToolError(
            f"{MAIN_ACTIVITY} does not declare MAIN + HOME + DEFAULT; this is not the contracted receiver build.", EXIT_REFUSED
        )
    if manifest["configure_unprotected"]:
        raise ToolError(
            f"The APK exports {ACTION_CONFIGURE} handler(s) without {CONFIGURE_PERMISSION}: "
            f"{', '.join(manifest['configure_unprotected'])}. Any app could repoint the receiver through them; refusing.",
            EXIT_REFUSED,
        )
    if manifest["configure"] is None:
        if manifest["configure_declared"]:
            raise ToolError(
                f"The APK's {ACTION_CONFIGURE} handler is not an exported activity guarded by {CONFIGURE_PERMISSION}; "
                "any app could repoint it, so it is refused.",
                EXIT_REFUSED,
            )
        raise ToolError(f"The APK has no {ACTION_CONFIGURE} activity; refusing.", EXIT_REFUSED)
    info = {
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
        "package": package,
        "version_code": int(version_code),
        "version_name": version_name,
        "debuggable": bool(re.search(r"^application-debuggable", badging.stdout, re.M)),
        "launcher": MAIN_ACTIVITY in launchable,
        "leanback_launcher": True,
        "home": True,
        "configure_handler": manifest["configure"],
        "requests_overlay": OVERLAY_PERMISSION in manifest["permissions"],
        "boot_receiver": manifest["boot_receiver"],
        "requests_boot": BOOT_PERMISSION in manifest["permissions"],
        "boot_available": manifest["boot_available"],
        "signer_sha256": apk_signer_digest(path, aapt2),
    }
    return info


def apk_signer_digest(path: Path, aapt2: str) -> Optional[str]:
    """Signer certificate digest via apksigner when Java is available; None otherwise."""
    apksigner = Path(aapt2).with_name("apksigner")
    if not apksigner.is_file() or os.environ.get("SETBEAM_SKIP_APKSIGNER") == "1":
        return None
    try:
        result = subprocess.run(
            [str(apksigner), "verify", "--print-certs", str(path)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env=child_env(),
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    digests = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})$", result.stdout, re.M)
    return digests[0].lower() if len(digests) == 1 else None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# adb


class Adb:
    def __init__(self, exe: str, serial: Optional[str], timeout: float = 60.0):
        self.exe = exe
        self.serial = serial
        self.timeout = timeout
        self.transport = None
        self.write_guard: Optional[Callable[[], None]] = None

    def _run(self, args: list[str], timeout: Optional[float] = None) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(
                [self.exe, *args],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                errors="replace",
                timeout=timeout or self.timeout,
                env=child_env(),
            )
        except subprocess.TimeoutExpired:
            raise ToolError(f"adb did not finish within {int(timeout or self.timeout)} s.", EXIT_DEVICE) from None
        except OSError as error:
            raise ToolError(f"adb could not run: {error.strerror}.", EXIT_DEVICE) from None

    def devices(self) -> list[dict[str, str]]:
        result = self._run(["devices", "-l"])
        if result.returncode != 0:
            raise ToolError("`adb devices` failed; is the adb server able to start?", EXIT_DEVICE)
        lines = result.stdout.splitlines()
        if not lines or lines[0].strip() != "List of devices attached":
            raise ToolError("adb did not return a device list.", EXIT_DEVICE)
        rows = []
        for line in lines[1:]:
            fields = line.split()
            if len(fields) < 2:
                continue
            row = {"serial": fields[0], "state": fields[1]}
            for extra in fields[2:]:
                if ":" in extra:
                    key, value = extra.split(":", 1)
                    if key in row:
                        raise ToolError("adb reported an ambiguous device list.", EXIT_DEVICE)
                    row[key] = value
            rows.append(row)
        return rows

    def selected_transport(self) -> str:
        rows = self.devices()
        matching = [row for row in rows if row["serial"] == self.serial]
        if len(matching) != 1:
            raise ToolError(f"Expected one attached adb device with serial {self.serial!r}; this tool never picks a device for you.", EXIT_DEVICE)
        row = matching[0]
        if row["state"] == "unauthorized":
            raise ToolError("The device has not authorized this Mac. Accept the debugging prompt on the TV, then retry.", EXIT_DEVICE)
        if row["state"] != "device":
            raise ToolError(f"The device is {row['state']!r}, not ready. Reconnect it, then retry.", EXIT_DEVICE)
        transport = row.get("transport_id", "")
        if not re.fullmatch(r"[1-9][0-9]*", transport) or sum(r.get("transport_id") == transport for r in rows) != 1:
            raise ToolError("adb did not report a unique transport ID for the selected device.", EXIT_DEVICE)
        return transport

    def device_args(self) -> list[str]:
        if self.transport is None:
            raise ToolError("Device command without a verified adb transport.", EXIT_DEVICE)
        return ["-t", self.transport]

    def mutate(self, argv: list[str]) -> tuple[int, str, str]:
        self.check_write()
        return self.shell(argv)

    def check_write(self) -> None:
        if self.write_guard is None:
            raise ToolError("Device write without a verified identity.", EXIT_DEVICE)
        self.write_guard()

    def shell(self, argv: list[str], timeout: Optional[float] = None) -> tuple[int, str, str]:
        result = self._run([*self.device_args(), "shell", remote_command(argv)], timeout)
        return result.returncode, result.stdout, result.stderr

    def install(self, apk: str, user: int) -> tuple[int, str, str]:
        self.check_write()
        # Scoped to one Android user; without --user, adb installs for every user.
        result = self._run([*self.device_args(), "install", "--user", str(user), "-r", apk], timeout=600)
        return result.returncode, result.stdout, result.stderr

    def uninstall(self, package: str, user: int) -> tuple[int, str, str]:
        if package != PACKAGE:
            raise ToolError("Refusing to uninstall any package other than the Setbeam Receiver.", EXIT_REFUSED)
        self.check_write()
        # Scoped to one Android user; without --user, adb removes the app from every profile.
        result = self._run([*self.device_args(), "uninstall", "--user", str(user), package], timeout=120)
        return result.returncode, result.stdout, result.stderr


def adb_display(serial: str, argv: list[str]) -> str:
    return f"adb -s {shlex.quote(serial)} shell {shlex.quote(remote_command(argv))}"


# --------------------------------------------------------------------------
# Device probes (read-only)


class Device:
    def __init__(self, adb: Adb):
        self.adb = adb
        self.props: dict[str, str] = {}
        self.user = 0
        self.sdk = 0

    def connect(self, out: Out) -> None:
        self.adb.transport = self.adb.selected_transport()
        expected = os.environ.get("SETBEAM_EXPECT_TRANSPORT_ID")
        if expected is not None and expected != self.adb.transport:
            raise ToolError("The selected adb transport does not match the expected transport.", EXIT_DEVICE)
        self.props, self.user = self.read_identity()
        expected_fields = {
            "SETBEAM_EXPECT_ANDROID_USER": str(self.user),
            "SETBEAM_EXPECT_HARDWARE_SERIAL_SHA256": hashlib.sha256(self.hardware_serial.encode()).hexdigest(),
            "SETBEAM_EXPECT_BUILD_FINGERPRINT": self.props["ro.build.fingerprint"],
        }
        if any(os.environ.get(key, value) != value for key, value in expected_fields.items()):
            raise ToolError("The selected Android user or device does not match the expected identity.", EXIT_DEVICE)
        self.sdk = int(self.props["ro.build.version.sdk"])
        self.adb.write_guard = self.check_identity

    def read_identity(self) -> tuple[dict[str, str], int]:
        rc, stdout, stderr = self.adb.shell(["getprop"])
        pairs = re.findall(r"^\[([^\]]+)\]: \[(.*)\]$", stdout, re.M)
        props = dict(pairs)
        required = ("ro.product.manufacturer", "ro.product.model", "ro.product.device", "ro.build.fingerprint")
        if (rc or stderr.strip() or len(pairs) != len(props)
                or any(props.get(key, "").strip().lower() in PLACEHOLDER_SERIALS for key in required)
                or not re.fullmatch(r"[1-9][0-9]*", props.get("ro.build.version.sdk", ""))):
            raise ToolError("Could not read complete device identity properties.", EXIT_DEVICE)
        rc, stdout, stderr = self.adb.shell(["am", "get-current-user"])
        if rc or stderr.strip() or not re.fullmatch(r"[0-9]+", stdout.strip()):
            raise ToolError("Could not read the current Android user (profile) on the device.", EXIT_DEVICE)
        return props, int(stdout.strip())

    def check_identity(self) -> None:
        if self.adb.selected_transport() != self.adb.transport:
            raise ToolError("The adb transport changed during this run. Reconnect and run status before retrying.", EXIT_DEVICE)
        props, user = self.read_identity()
        keys = ("ro.serialno", "ro.boot.serialno", "ro.product.manufacturer", "ro.product.model",
                "ro.product.device", "ro.build.fingerprint", "ro.build.version.sdk")
        if user != self.user or any(props.get(key) != self.props.get(key) for key in keys):
            raise ToolError("The device identity or Android user changed during this run.", EXIT_DEVICE)

    @property
    def hardware_serial(self) -> str:
        return self.props.get("ro.serialno") or self.props.get("ro.boot.serialno") or ""

    @property
    def hardware_serial_usable(self) -> bool:
        serial = self.hardware_serial.strip()
        return (
            len(serial) >= 6
            and serial.lower() not in PLACEHOLDER_SERIALS
            and len(set(serial.lower())) > 1
        )

    def identity(self) -> dict[str, Any]:
        serial = self.hardware_serial
        return {
            "adb_serial": self.adb.serial,
            "hardware_serial_sha256": hashlib.sha256(serial.encode()).hexdigest() if serial else None,
            "manufacturer": self.props.get("ro.product.manufacturer"),
            "brand": self.props.get("ro.product.brand"),
            "model": self.props.get("ro.product.model"),
            "device": self.props.get("ro.product.device"),
            "android_release": self.props.get("ro.build.version.release"),
            "sdk": self.sdk,
            "build_fingerprint": self.props.get("ro.build.fingerprint"),
            "build_incremental": self.props.get("ro.build.version.incremental"),
            "security_patch": self.props.get("ro.build.version.security_patch"),
            "user": self.user,
        }

    def is_tv(self) -> bool:
        rc, stdout, _ = self.adb.shell(["pm", "has-feature", "android.software.leanback"])
        if rc == 0 and stdout.strip() == "true":
            return True
        return "tv" in self.props.get("ro.build.characteristics", "").split(",")

    def package_info(self) -> dict[str, Any]:
        """The receiver's state for the current Android user, plus which other
        users have it. `pm path` defaults to user 0 (AOSP runPath), so --user
        is always passed; per-user state comes from dumpsys "User N: ... installed=" lines."""
        rc, stdout, stderr = self.adb.shell(["pm", "path", "--user", str(self.user), PACKAGE])
        paths = stdout.strip().splitlines()
        path_present = rc == 0 and not stderr.strip() and bool(paths) and all(
            re.fullmatch(r"package:/[^\r\n]+\.apk", line) for line in paths
        )
        path_absent = rc == 1 and not stdout.strip() and not stderr.strip()
        info: dict[str, Any] = {
            "installed": None, "user": self.user, "present_on_device": None, "users": None,
            "other_users": None, "version_code": None, "version_name": None, "permissions": [],
            "boot_permission_granted": False,
        }
        rc, stdout, stderr = self.adb.shell(["dumpsys", "package", PACKAGE])
        if rc or stderr.strip():
            return info
        if stdout.strip() == f"Unable to find package: {PACKAGE}" and path_absent:
            info.update(installed=False, present_on_device=False, users={}, other_users=[])
            return info
        if len(re.findall(rf"^\s*Package \[{re.escape(PACKAGE)}\] \(", stdout, re.M)) != 1:
            return info
        info["present_on_device"] = True
        lines = re.findall(r"^[ \t]*User [0-9]+:.*$", stdout, re.M)
        rows = [re.match(r"\s*User (\d+):.*?\binstalled=(true|false)\b", line) for line in lines]
        users = {int(row[1]): row[2] == "true" for row in rows if row}
        if (len(lines) == len(users) and self.user in users
                and (path_present if users[self.user] else path_absent)):
            info.update(installed=users[self.user], users=users,
                        other_users=sorted(u for u, present in users.items() if present and u != self.user))
        version = re.search(r"\bversionCode=(\d+)", stdout)
        name = re.search(r"\bversionName=(\S+)", stdout)
        info["version_code"] = int(version.group(1)) if version else None
        info["version_name"] = name.group(1) if name else None
        info["permissions"] = parse_requested_permissions(stdout)
        info["boot_permission_granted"] = bool(re.search(rf"^\s*{re.escape(BOOT_PERMISSION)}: granted=true\s*$", stdout, re.M))
        return info

    def require_boot_receiver(self, package: dict[str, Any]) -> None:
        rc, stdout, stderr = self.adb.shell(
            ["cmd", "package", "query-receivers", "--user", str(self.user), "-a", BOOT_ACTION, PACKAGE]
        )
        available = not rc and not stderr.strip() and any(
            info.get("packageName") == PACKAGE and info.get("enabled") == "true"
            and info.get("exported") == "true" and info.get("permission") in (None, "null")
            for info in parse_activity_infos(stdout)
        )
        if not available or not package["boot_permission_granted"] or BOOT_PERMISSION not in package["permissions"]:
            raise ToolError("--allow-background-start needs an enabled, exported BOOT_COMPLETED receiver with RECEIVE_BOOT_COMPLETED granted.", EXIT_REFUSED)

    def _query(self, verb: str, action: str, categories: tuple[str, ...] = (), package: Optional[str] = None) -> str:
        argv = ["cmd", "package", verb, "--brief", "--user", str(self.user), "-a", action]
        for category in categories:
            argv += ["-c", category]
        if package:
            argv.append(package)
        rc, stdout, stderr = self.adb.shell(argv)
        if rc != 0 or stderr.strip():
            raise ToolError(f"`cmd package {verb}` failed on the device.", EXIT_DEVICE)
        return stdout

    def home_candidates(self) -> list[dict[str, Any]]:
        return parse_brief_list(self._query("query-activities", "android.intent.action.MAIN", ("android.intent.category.HOME",)))

    def home_resolved(self) -> Optional[str]:
        raw = self._query("resolve-activity", "android.intent.action.MAIN", ("android.intent.category.HOME",))
        listed = parse_brief_list(raw)
        if raw.strip() == "No activity found":
            return None
        if len(listed) != 1:
            raise ToolError("Could not read the resolved HOME activity.", EXIT_DEVICE)
        return listed[0]["component"]

    def home_holders(self) -> tuple[Optional[list[str]], Optional[str]]:
        """Exact HOME role holders ("role", Android 14+), or the shortcut
        service's default launcher ("shortcut"), which is only approximate:
        it names a launcher even when no explicit role holder exists."""
        if self.sdk >= MIN_HOME_SDK:
            rc, stdout, stderr = self.adb.shell(["cmd", "role", "get-role-holders", "--user", str(self.user), ROLE_HOME])
            text = stdout + stderr
            if rc == 0 and not stderr.strip() and "Unknown command" not in text and "Error" not in text and "Exception" not in text:
                holders = [p for p in stdout.strip().split(";") if p]
                if len(holders) <= 1 and stdout.strip() == ";".join(holders) and all(re.fullmatch(r"[A-Za-z][\w]*(\.[\w]+)+", h) for h in holders):
                    return holders, "role"
        rc, stdout, _ = self.adb.shell(["cmd", "shortcut", "get-default-launcher", "--user", str(self.user)])
        match = re.search(r"ComponentInfo\{([^/}]+)/", stdout)
        if rc == 0 and match:
            return [match.group(1)], "shortcut"
        return None, None

    def configure_handler(self) -> Optional[dict[str, Any]]:
        """The installed CONFIGURE handlers, read from the ResolveInfo dumps of
        query-activities and query-receivers (ActivityInfo prints name=,
        packageName=, exported= and permission=). `protected` requires a
        guarded exported activity and no exported handler without the guard."""
        infos: list[tuple[str, dict[str, str]]] = []
        for verb, kind in (("query-activities", "activity"), ("query-receivers", "receiver")):
            rc, stdout, stderr = self.adb.shell(["cmd", "package", verb, "--user", str(self.user), "-a", ACTION_CONFIGURE, PACKAGE])
            noun = "activities" if kind == "activity" else "receivers"
            if rc or stderr.strip():
                return None
            if stdout.strip() == f"No {noun} found":
                continue
            header = re.match(rf"^([0-9]+) {noun} found:", stdout.strip())
            parsed = parse_activity_infos(stdout)
            if (not header or int(header[1]) != len(parsed) or not parsed
                    or any(i.get("packageName") != PACKAGE or not i.get("name") or "exported" not in i for i in parsed)):
                return None
            infos.extend((kind, info) for info in parsed)
        exported = [(kind, info) for kind, info in infos if info.get("exported") == "true"]
        unprotected = [info["name"] for kind, info in exported if info.get("permission") != CONFIGURE_PERMISSION]
        guarded = [info for kind, info in exported if kind == "activity" and info.get("permission") == CONFIGURE_PERMISSION]
        if not guarded and not unprotected:
            return None
        chosen = guarded[0] if guarded else None
        return {
            "component": f"{PACKAGE}/{chosen['name']}" if chosen else None,
            "unprotected": unprotected,
            "protected": bool(chosen) and not unprotected,
        }

    def overlay_mode(self) -> Optional[str]:
        """The receiver's package-level overlay app-op mode, or None when it
        cannot be read exactly (failed command, unparseable output, or a uid
        mode that would override the package mode)."""
        return self._overlay_mode_for(PACKAGE)

    def _overlay_mode_for(self, package: str) -> Optional[str]:
        rc, stdout, _ = self.adb.shell(["appops", "get", "--user", str(self.user), package, OVERLAY_OP])
        if rc != 0:
            return None
        return parse_overlay_mode(stdout)

    def flush_appops(self, expected_mode: str) -> Optional[str]:
        """Run `appops write-settings` and confirm the overlay mode still reads `expected_mode`.

        AOSP AppOpsService delays package-mode writes (10 s on Android 16, 30 min on
        Android 14), and a hard reboot can skip the shutdown write, so a fresh grant can
        be lost. write-settings saves all current app-op state to disk and changes no
        mode; it needs MANAGE_APP_OPS_MODES like `appops set`. Returns None on success,
        otherwise the reason. Only a real reboot proves persistence."""
        rc, stdout, stderr = self.adb.mutate(["appops", "write-settings"])
        if rc != 0 or stdout.strip() != "Current settings written." or stderr.strip():
            first = (stderr.strip() or stdout.strip() or "no output").splitlines()[0][:120]
            return f"`appops write-settings` did not confirm the save (exit {rc}: {first})"
        mode = self.overlay_mode()
        if mode != expected_mode:
            return f"after saving, the overlay app-op reads {mode or 'unknown'}, not {expected_mode}"
        return None

    def appops_readable(self) -> bool:
        """Whether this build's appops output parses, checked on the shell package."""
        return self._overlay_mode_for("com.android.shell") is not None

    def device_time(self) -> Optional[int]:
        rc, stdout, _ = self.adb.shell(["date", "+%s"])
        return int(stdout.strip()) if rc == 0 and stdout.strip().isdigit() else None

    def provision_log(self, since: int) -> Optional[list[tuple[str, str]]]:
        """Read recent acknowledgements without clearing the device log."""
        rc, stdout, _ = self.adb.shell(["logcat", "-d", "-v", "epoch", "-s", PROVISION_LOG_TAG])
        if rc != 0:
            return None
        return [(match.group(0), match.group(2).strip()) for match in re.finditer(
            rf"^[ \t]*(\d+)\.\d+\s+\d+\s+\d+\s+[VDIWEF]\s+{PROVISION_LOG_TAG}\s*:[ \t]*(.*)$", stdout, re.M
        ) if int(match.group(1)) >= since]

    def top_activity(self) -> Optional[str]:
        rc, stdout, _ = self.adb.shell(["dumpsys", "activity", "activities"])
        if rc != 0:
            return None
        for pattern in (r"topResumedActivity=ActivityRecord\{\S+ u\d+ (\S+)", r"mResumedActivity: ActivityRecord\{\S+ u\d+ (\S+)", r"ResumedActivity: ActivityRecord\{\S+ u\d+ (\S+)"):
            match = re.search(pattern, stdout)
            if match:
                return full_component(match.group(1))
        return None

    def home_state(self) -> dict[str, Any]:
        candidates = self.home_candidates()
        resolved = self.home_resolved()
        holders, source = self.home_holders()
        setbeam = next((c for c in candidates if c["component"] == MAIN_COMPONENT), None)
        # Android caps HOME filters of non-privileged apps at priority 0, so an
        # uninstalled receiver is assessed at 0.
        setbeam_priority = setbeam["priority"] if setbeam else 0
        blockers = [c for c in candidates if c["priority"] > setbeam_priority and component_package(c["component"]) != PACKAGE]
        return {
            "candidates": candidates,
            "resolved": resolved,
            "holders": holders,
            "holders_source": source,
            "setbeam_declares_home": setbeam is not None,
            "setbeam_priority": setbeam_priority,
            "blockers": blockers,
            "resolves_to_setbeam": resolved == MAIN_COMPONENT,
        }


def parse_brief_list(text: str) -> list[dict[str, Any]]:
    """Parse --brief output of resolve-activity / query-activities / query-receivers."""
    rows: list[dict[str, Any]] = []
    priority: Optional[int] = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        match = PRIORITY_RE.search(line)
        if match and line.startswith("priority="):
            priority = int(match.group(1))
            continue
        if COMPONENT_RE.match(line):
            rows.append({"component": full_component(line), "priority": priority if priority is not None else 0})
            priority = None
    return rows


def parse_activity_infos(text: str) -> list[dict[str, str]]:
    """Each ActivityInfo block of a non-brief resolve/query dump."""
    infos: list[dict[str, str]] = []
    current: Optional[dict[str, str]] = None
    for raw in text.splitlines():
        line = raw.strip()
        if line == "ActivityInfo:":
            current = {}
            infos.append(current)
            continue
        if re.match(r"^(Activity|Receiver|Service|Provider) #\d+:$", line):
            current = None
            continue
        if current is None:
            continue
        for key in ("name", "packageName", "permission"):
            if line.startswith(key + "=") and key not in current:
                current[key] = line[len(key) + 1 :].strip()
        for key in ("exported", "enabled"):
            match = re.search(rf"(?:^|\s){key}=(true|false)\b", line)
            if match and key not in current:
                current[key] = match.group(1)
    return infos


def parse_overlay_mode(text: str) -> Optional[str]:
    """Exact package-level mode from `appops get --user U PKG SYSTEM_ALERT_WINDOW`, or None.

    Accepted forms only:
      * exactly "No operations."                         -> "default"
      * exactly "No operations." then "Default mode: <m>" -> m, when m is a known mode
        (the API 36 Google TV form for an op the package never used: QA observed
        "No operations.\nDefault mode: default")
      * one anchored "SYSTEM_ALERT_WINDOW: <m>..." package line -> m
    Any uid mode, unknown mode or other shape is ambiguous and returns None.
    """
    if re.search(rf"^\s*Uid mode:.*\b{OVERLAY_OP}\b", text, re.M):
        return None  # A uid mode overrides the package mode; exact restore is not supported.
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if lines == ["No operations."]:
        return "default"
    if lines and lines[0] == "No operations.":
        if len(lines) == 2:
            match = re.fullmatch(r"Default mode: (\S+)", lines[1])
            if match and match.group(1) in APPOP_MODES:
                return match.group(1)
        return None
    matches = re.findall(rf"^{OVERLAY_OP}: (\w+)", text, re.M)
    if len(matches) == 1 and matches[0] in APPOP_MODES:
        return matches[0]
    return None


def parse_requested_permissions(dumpsys: str) -> list[str]:
    permissions: list[str] = []
    lines = dumpsys.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "requested permissions:":
            indent = len(line) - len(line.lstrip())
            for follow in lines[index + 1 :]:
                follow_indent = len(follow) - len(follow.lstrip())
                if not follow.strip() or follow_indent <= indent:
                    break
                permissions.append(follow.strip().split(":", 1)[0].strip())
            break
    return permissions


# --------------------------------------------------------------------------
# Receipts


def default_receipt_dir() -> Path:
    if os.environ.get("SETBEAM_RECEIPT_DIR"):
        return Path(os.environ["SETBEAM_RECEIPT_DIR"]).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Setbeam" / "receiver-provisioning"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "setbeam" / "receiver-provisioning"


def check_receipt_dir(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.relative_to(REPO_ROOT)
        inside = True
    except ValueError:
        inside = False
    if inside:
        probe = resolved / "receipt-probe.json"
        ignored = False
        git = shutil.which("git")
        if git:
            result = subprocess.run(
                [git, "-C", str(REPO_ROOT), "check-ignore", "-q", str(probe)],
                stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
            )
            ignored = result.returncode == 0
        if not ignored:
            raise ToolError(
                "The receipt directory is inside the Setbeam repository and is not ignored by Git; "
                "choose a directory outside the repository (the default is under ~/Library/Application Support).",
                EXIT_REFUSED,
            )
    return resolved


class ReceiptStore:
    def __init__(self, directory: Path):
        self.directory = directory

    def key(self, device: Device) -> str:
        serial = device.hardware_serial
        if not device.hardware_serial_usable:
            raise ToolError(
                "The device reports no usable hardware serial (ro.serialno is missing or a factory placeholder), "
                "so a restore receipt cannot be tied to it; refusing.",
                EXIT_REFUSED,
            )
        return "receiver-" + hashlib.sha256(f"setbeam-receiver:{serial}".encode()).hexdigest()[:24]

    def path(self, device: Device) -> Path:
        return self.directory / f"{self.key(device)}.json"

    def load(self, device: Device) -> Optional[dict[str, Any]]:
        path = self.path(device)
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            raise ToolError(f"The receipt at {path} is unreadable; it was left untouched.", EXIT_FAILED) from None
        if data.get("schema") != RECEIPT_SCHEMA:
            raise ToolError(f"The receipt at {path} has an unknown schema.", EXIT_FAILED)
        return data

    def save(self, device: Device, data: dict[str, Any]) -> Path:
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = self.path(device)
        data["updated_at"] = now_iso()
        temp = path.with_suffix(".json.tmp")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        return path

    def archive(self, device: Device) -> Path:
        path = self.path(device)
        stamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        target = path.with_name(f"{path.stem}.restored-{stamp}.json")
        os.replace(path, target)
        return target

    @contextlib.contextmanager
    def lock(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(self.directory / ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ToolError("Another provisioning run holds the receipt lock; wait for it to finish.", EXIT_REFUSED) from None
            yield
        finally:
            os.close(fd)


# --------------------------------------------------------------------------
# HOME role changes


def set_home(device: Device) -> None:
    rc, stdout, stderr = device.adb.mutate(
        ["cmd", "package", "set-home-activity", "--user", str(device.user), f"{PACKAGE}/.MainActivity"]
    )
    if rc != 0 or "Success" not in stdout.splitlines():
        raise ToolError("The device refused to set Setbeam Receiver as HOME (set-home-activity did not report Success).", EXIT_DEVICE)


def restore_home(device: Device, before: dict[str, Any]) -> None:
    """Return HOME to the exact holders recorded before provisioning (role source only)."""
    if before.get("holders_source") != "role" or before.get("holders") is None:
        raise ToolError("The original HOME role holder was not recorded exactly; refusing to guess.", EXIT_REFUSED)
    holders = [h for h in before["holders"] if h != PACKAGE]
    if holders:
        rc, stdout, _ = device.adb.mutate(["cmd", "package", "set-home-activity", "--user", str(device.user), holders[0]])
        if rc != 0 or "Success" not in stdout.splitlines():
            raise ToolError(f"The device refused to give HOME back to {holders[0]}.", EXIT_DEVICE)
    else:
        rc, stdout, stderr = device.adb.mutate(["cmd", "role", "remove-role-holder", "--user", str(device.user), ROLE_HOME, PACKAGE])
        if rc != 0:
            raise ToolError("The device refused to remove Setbeam Receiver from the HOME role.", EXIT_DEVICE)


def home_restored(before: dict[str, Any], current: dict[str, Any]) -> bool:
    """Require the same role holders and resolved component."""
    return (
        before.get("holders_source") == current.get("holders_source") == "role"
        and before.get("holders") == current.get("holders")
        and before.get("resolved") == current.get("resolved")
    )


HOLDER_SOURCES = {"role": "exact", "shortcut": "approximate: shortcut service"}


def describe_home(state: dict[str, Any]) -> list[str]:
    lines = []
    for candidate in state["candidates"]:
        mark = " (Setbeam)" if candidate["component"] == MAIN_COMPONENT else ""
        lines.append(f"    HOME candidate: {candidate['component']} priority={candidate['priority']}{mark}")
    holders = state["holders"]
    source = HOLDER_SOURCES.get(state["holders_source"] or "", "unavailable")
    lines.append(f"    HOME role holder(s) [{source}]: {', '.join(holders) if holders else ('none' if holders == [] else 'unknown')}")
    lines.append(f"    HOME intent resolves to: {state['resolved'] or 'nothing'}")
    return lines


IDENTITY_FIELDS = ("manufacturer", "model", "device")


def check_receipt_matches(receipt: dict[str, Any], device: Device, out: Out) -> None:
    """Refuse a receipt recorded for another Android user, or (unless forced) another device."""
    recorded = receipt["device"]
    if recorded.get("user") != device.user:
        raise ToolError(
            f"The receipt was recorded for Android user {recorded.get('user')}, but the TV's current user is {device.user}. "
            "Switch the TV to that profile, then retry; changes are per user.",
            EXIT_REFUSED,
        )
    current = device.identity()
    differing = [f for f in (*IDENTITY_FIELDS, "hardware_serial_sha256")
                 if not recorded.get(f) or recorded.get(f) != current.get(f)]
    if differing:
        raise ToolError(f"The receipt appears to belong to a different device (identity differs in {', '.join(differing)}).", EXIT_REFUSED)
    if recorded.get("build_fingerprint") != current.get("build_fingerprint"):
        out.warn("the OS build changed since provisioning (fingerprint differs); results are verified, but re-qualify startup.")


# --------------------------------------------------------------------------
# Commands


def open_device(args: argparse.Namespace, out: Out) -> Device:
    if not 0 <= args.settle_seconds <= 60:
        raise ToolError("--settle-seconds must be between 0 and 60.", EXIT_REFUSED)
    serial = validate_serial(args.serial)
    adb = Adb(find_adb(args.adb), serial, timeout=args.adb_timeout)
    device = Device(adb)
    device.connect(out)
    return device


def print_identity(out: Out, identity: dict[str, Any]) -> None:
    out.line("Device")
    for key in ("adb_serial", "manufacturer", "model", "device", "android_release", "sdk", "build_fingerprint", "security_patch", "user"):
        out.item(key, identity.get(key))


def cmd_devices(args: argparse.Namespace, out: Out) -> int:
    adb = Adb(find_adb(args.adb), None, timeout=args.adb_timeout)
    rows = adb.devices()
    if not rows:
        out.line("No adb devices attached.")
    for row in rows:
        out.line(f"{row['serial']}  {row['state']}  model={row.get('model', '?')}")
    out.line("Pass one of these to --serial. This list does not select a device.")
    return EXIT_OK


def check_expected_signer(expected: Optional[str], info: Optional[dict[str, Any]]) -> None:
    if expected is None:
        return
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise ToolError("--expect-signer requires one 64-digit SHA-256 certificate digest.", EXIT_REFUSED)
    if info is None or info["signer_sha256"] != expected.lower():
        raise ToolError("The APK signer does not match --expect-signer (or could not be checked).", EXIT_REFUSED)


@contextlib.contextmanager
def staged_apk(apk: str):
    source = Path(apk).expanduser().resolve()
    if not source.is_file() or source.suffix.lower() != ".apk":
        raise ToolError("--apk must name an existing .apk file.", EXIT_REFUSED)
    with tempfile.TemporaryDirectory(prefix="setbeam-receiver-apk-") as directory:
        staged = Path(directory) / source.name
        # Copy once into a private directory before invoking the inspection tools.
        with source.open("rb") as original, staged.open("wb") as copy:
            for chunk in iter(lambda: original.read(1 << 20), b""):
                if copy.tell() + len(chunk) > 512 * 1024 * 1024:
                    raise ToolError("--apk is larger than 512 MB; refusing.", EXIT_REFUSED)
                copy.write(chunk)
        staged.chmod(0o400)
        yield source, staged


def cmd_verify_apk(args: argparse.Namespace, out: Out) -> int:
    with staged_apk(args.apk) as (source, staged):
        info = verify_apk(str(staged), find_aapt2(args.aapt2), out)
        check_expected_signer(args.expect_signer, info)
    info["path"] = str(source)
    if args.json:
        print(json.dumps(info, indent=2, sort_keys=True))
        return EXIT_OK
    out.line("APK verified for Setbeam Receiver")
    for key in ("path", "sha256", "version_code", "version_name", "debuggable", "requests_overlay", "boot_receiver"):
        out.item(key, info[key])
    out.item("configure_handler", f"{info['configure_handler']['name']} (requires {info['configure_handler']['permission']})")
    out.item("signer_sha256", info["signer_sha256"] or "not checked (apksigner needs a Java runtime)")
    return EXIT_OK


def collect_status(device: Device, store: Optional[ReceiptStore]) -> dict[str, Any]:
    package = device.package_info()
    status: dict[str, Any] = {
        "device": device.identity(),
        "is_tv": device.is_tv(),
        "package": package,
        "home": device.home_state(),
        "configure_handler": device.configure_handler() if package["installed"] else None,
        "overlay_mode": device.overlay_mode() if package["installed"] else None,
        "receipt": None,
        "not_verified": [
            "cold power-on start",
            "standby wake",
            "HDMI output mode and 4K30 playback",
            "Mac admission, Hold, Stop and reconnect on this device",
        ],
    }
    if store is not None and device.hardware_serial_usable:
        receipt = store.load(device)
        if receipt is not None:
            status["receipt"] = {
                "path": str(store.path(device)),
                "status": receipt.get("status"),
                "created_at": receipt.get("created_at"),
                "changes": [{"kind": c["kind"], "state": c["state"]} for c in receipt.get("changes", [])],
                "fingerprint_changed": receipt["device"].get("build_fingerprint") != device.props.get("ro.build.fingerprint"),
                "needs_restore": needs_restore(receipt),
            }
    return status


def startup_assessment(status: dict[str, Any]) -> str:
    home = status["home"]
    if status["package"]["installed"] is None:
        return "Setbeam Receiver install state is unknown."
    if not status["package"]["installed"]:
        return "Setbeam Receiver is not installed."
    if home["resolves_to_setbeam"]:
        return "HOME resolves to Setbeam Receiver now. Power-on start is still unverified until the physical checklist passes."
    if not home["setbeam_declares_home"]:
        return "The installed receiver does not offer a HOME activity; HOME cannot be used."
    if home["blockers"]:
        names = ", ".join(f"{b['component']} (priority {b['priority']})" for b in home["blockers"])
        return (
            f"HOME cannot resolve to Setbeam: {names} outranks it (Setbeam priority {home['setbeam_priority']}). "
            "Android always picks the higher-priority system launcher, so use a fallback in receiver/docs/startup.md."
        )
    return "HOME does not resolve to Setbeam Receiver. Run provision to request it."


def cmd_status(args: argparse.Namespace, out: Out) -> int:
    device = open_device(args, out)
    store = ReceiptStore(check_receipt_dir(Path(args.receipt_dir) if args.receipt_dir else default_receipt_dir()))
    status = collect_status(device, store)
    status["assessment"] = startup_assessment(status)
    if args.json:
        print(json.dumps(status, indent=2, sort_keys=True))
        return EXIT_OK
    print_identity(out, status["device"])
    out.item("television", "yes" if status["is_tv"] else "no (leanback feature missing)")
    pkg = status["package"]
    out.line("Setbeam Receiver")
    out.item(f"installed for Android user {pkg['user']}", {True: "yes", False: "no", None: "unknown"}[pkg["installed"]])
    if pkg["other_users"]:
        out.item("also installed for Android user(s)", ", ".join(str(u) for u in pkg["other_users"]))
    if pkg["installed"]:
        out.item("version", f"{pkg['version_name']} ({pkg['version_code']})")
        handler = status["configure_handler"]
        if handler:
            if handler["protected"]:
                out.item("configure handler", f"{handler['component']} (protected by {CONFIGURE_PERMISSION})")
            else:
                names = ", ".join(handler["unprotected"]) or "no guarded activity"
                out.item("configure handler", f"NOT protected ({names}); provisioning will refuse it")
        else:
            out.item("configure handler", "missing")
        out.item("overlay app-op", status["overlay_mode"] or "unknown (not exactly readable)")
    out.line("Startup")
    for line in describe_home(status["home"]):
        out.line(line)
    out.item("assessment", status["assessment"])
    out.item("not verified here", "; ".join(status["not_verified"]))
    receipt = status["receipt"]
    out.line("Receipt")
    if receipt:
        out.item("path", receipt["path"])
        out.item("status", receipt["status"])
        out.item("changes", ", ".join(f"{c['kind']}={c['state']}" for c in receipt["changes"]) or "none")
        if receipt["needs_restore"]:
            out.line(
                "  NEEDS RESTORE: an earlier rollback or restore could not be verified, and provisioning is blocked. "
                f"Run: {restore_command(status['device']['adb_serial'])}"
            )
        if receipt["fingerprint_changed"]:
            out.warn("the device build fingerprint changed since provisioning (OS update); re-run status after updates and re-qualify startup.")
    else:
        out.item("status", "none for this device")
    return EXIT_OK


class Plan:
    """Runs mutating steps under --apply, or prints them in a dry run."""

    def __init__(self, apply: bool, out: Out, serial: str):
        self.apply = apply
        self.out = out
        self.serial = serial

    def step(self, description: str, commands: list[str], action: Callable[[], Any]) -> Any:
        if not self.apply:
            self.out.line(f"would: {description}")
            for command in commands:
                self.out.line(f"    {command}")
            return None
        self.out.line(f"doing: {description}")
        return action()


def new_receipt(device: Device, before_home: dict[str, Any], package: dict[str, Any], overlay: Optional[str]) -> dict[str, Any]:
    return {
        "schema": RECEIPT_SCHEMA,
        "tool": TOOL_NAME,
        "status": "in-progress",
        "created_at": now_iso(),
        "device": device.identity(),
        "before": {
            "home": {k: before_home[k] for k in ("resolved", "holders", "holders_source", "candidates")},
            "receiver_installed": package["installed"],
            "receiver_version_code": package["version_code"],
            "overlay_mode": overlay,
        },
        "changes": [],
        "notes": [
            "Restore with: setbeam-receiver restore --serial <serial> --apply",
            "Configuration (host and label) lives in the receiver's own app data and is not reverted by restore.",
        ],
    }


# States restore still has to act on. "rollback-failed" marks a provisioning rollback that
# could not be verified; only restore resolves it, and provisioning is blocked meanwhile.
# "rolling-back" and "restoring" are in-flight markers saved before a rollback or restore
# command is sent and cleared only after verified success; a killed run leaves them behind.
UNRESOLVED_STATES = ("pending", "rollback-failed", "rolling-back", "restoring", "flush-pending")
RESTORE_OPEN_STATES = ("done",) + UNRESOLVED_STATES


def needs_restore(receipt: Optional[dict[str, Any]]) -> bool:
    if not receipt or receipt.get("status") == "restored":
        return False
    return receipt.get("status") == "needs-restore" or any(
        c["state"] in UNRESOLVED_STATES or any(u.get("result") == "pending" for u in c.get("updates", []))
        for c in receipt["changes"]
    )


def find_change(receipt: dict[str, Any], kind: str) -> Optional[dict[str, Any]]:
    for change in receipt["changes"]:
        if change["kind"] == kind and change["state"] in ("pending", "done"):
            return change
    return None


def require_protected_handler(handler: Optional[dict[str, Any]], advice: str = "") -> dict[str, Any]:
    if handler is None or not handler["protected"]:
        unprotected = handler["unprotected"] if handler else []
        detail = f" Unprotected exported handler(s): {', '.join(unprotected)}." if unprotected else ""
        raise ToolError(
            f"The installed receiver must handle {ACTION_CONFIGURE} only through exported activities guarded by "
            f"{CONFIGURE_PERMISSION}.{detail} {advice}".rstrip(),
            EXIT_REFUSED,
        )
    return handler


def home_summary(state: dict[str, Any]) -> tuple[list[str], Optional[str]]:
    return sorted(state.get("holders") or []), state.get("resolved")


def restore_command(serial: str) -> str:
    return f"setbeam-receiver restore --serial {shlex.quote(serial)} --apply"


def cmd_provision(args: argparse.Namespace, out: Out) -> int:
    host = validate_host(args.host)
    name = validate_name(args.name)
    if not args.apk:
        check_expected_signer(args.expect_signer, None)
        return provision_device(args, out, host, name, None, None)
    with staged_apk(args.apk) as (source, staged):
        apk_info = verify_apk(str(staged), find_aapt2(args.aapt2), out)
        check_expected_signer(args.expect_signer, apk_info)
        apk_info["path"] = str(source)
        return provision_device(args, out, host, name, apk_info, staged)


def provision_device(
    args: argparse.Namespace, out: Out, host: str, name: str,
    apk_info: Optional[dict[str, Any]], staged: Optional[Path],
) -> int:
    device = open_device(args, out)
    store = ReceiptStore(check_receipt_dir(Path(args.receipt_dir) if args.receipt_dir else default_receipt_dir()))
    print_identity(out, device.identity())
    out.item("receiver host", host)
    out.item("receiver label (unverified on the Mac)", name)
    is_emulator = (device.props.get("ro.kernel.qemu") or device.props.get("ro.boot.qemu")) == "1"
    if not device.is_tv() and not (args.allow_non_tv and is_emulator):
        raise ToolError("This device does not report the Android TV leanback feature; refusing (use --allow-non-tv for an emulator).", EXIT_REFUSED)
    receipt_path = store.path(device)  # Refuses missing or placeholder hardware serials before any change.

    # ---- Preflight: everything below is read-only.
    package = device.package_info()
    if package["installed"] is None:
        raise ToolError("The receiver's per-profile install state cannot be read; refusing to change the device.", EXIT_REFUSED)
    if apk_info is None and not package["installed"]:
        raise ToolError(
            f"Setbeam Receiver is not installed for Android user {device.user} on this device; pass --apk with a verified build.",
            EXIT_REFUSED,
        )
    if apk_info and package["present_on_device"]:
        if package["version_code"] is None:
            raise ToolError("Cannot compare receiver version codes; refusing to install.", EXIT_REFUSED)
        if apk_info["version_code"] < package["version_code"]:
            raise ToolError("The supplied APK is older than the installed receiver; downgrades are refused.", EXIT_REFUSED)
        if package["other_users"]:
            out.warn(
                f"the receiver is also installed for Android user(s) {', '.join(map(str, package['other_users']))}. "
                "Installing updates the shared app code for those profiles too; restore never removes their install."
            )
        if package["version_code"] != apk_info["version_code"]:
            out.warn("this updates an existing receiver; restore never rolls back an APK version.")
    if package["installed"] and apk_info is None:
        require_protected_handler(device.configure_handler(), "supply a current --apk.")
    before_home = device.home_state()
    if args.set_home and (device.sdk < MIN_HOME_SDK or before_home["holders_source"] != "role"):
        raise ToolError(
            "This device cannot report its exact HOME role holder (needs Android 14, SDK 34, or later), so the original "
            "HOME could not be restored exactly; refusing. Use --no-set-home and a fallback from receiver/docs/startup.md.",
            EXIT_REFUSED,
        )
    overlay_before = device.overlay_mode() if package["installed"] else None
    if args.overlay:
        requested = ([OVERLAY_PERMISSION] if apk_info["requests_overlay"] else []) if apk_info else package["permissions"]
        if OVERLAY_PERMISSION not in requested:
            raise ToolError("--allow-background-start needs a receiver build that requests SYSTEM_ALERT_WINDOW.", EXIT_REFUSED)
        if apk_info:
            if not apk_info["boot_available"] or not apk_info["requests_boot"]:
                raise ToolError("--allow-background-start needs an enabled, exported BOOT_COMPLETED receiver and RECEIVE_BOOT_COMPLETED in the APK.", EXIT_REFUSED)
        else:
            device.require_boot_receiver(package)
        readable = overlay_before is not None if package["installed"] else device.appops_readable()
        if not readable:
            raise ToolError(
                "The receiver's overlay app-op cannot be read exactly on this device (failed or unrecognized appops output, "
                "or a uid mode); refusing before any change because it could not be restored exactly.",
                EXIT_REFUSED,
            )

    plan = Plan(args.apply, out, device.adb.serial)
    out.line("Plan" if not args.apply else "Applying")
    with store.lock():
        receipt = store.load(device)
        if receipt and receipt.get("status") == "restored":
            receipt = None
        if needs_restore(receipt):
            check_receipt_matches(receipt, device, out)
            effect = "Nothing was changed" if args.apply else "--apply would be refused"
            raise ToolError(
                "This device's receipt needs restore: an earlier rollback or restore could not be verified. "
                f"{effect}; provisioning makes no change (install, configuration, HOME or overlay) until it is resolved. "
                f"Run: {restore_command(device.adb.serial)} (it may need --force to accept a result that is not exact).",
                EXIT_REFUSED,
            )
        if receipt is None:
            receipt = new_receipt(device, before_home, package, overlay_before)
        else:
            check_receipt_matches(receipt, device, out)
            out.line(f"  existing receipt reused (created {receipt['created_at']}; its first snapshot is kept as history)")
            open_home = find_change(receipt, "home_role")
            if open_home is None and home_summary(before_home) != home_summary(receipt["before"]["home"]):
                out.warn(
                    "HOME changed since this receipt was created (an operator choice?). Any new HOME change records the "
                    "current state, and restore returns HOME there, not to the receipt's first snapshot."
                )
            elif open_home is not None and PACKAGE not in (before_home["holders"] or []):
                out.warn(
                    "HOME was moved away from Setbeam after the recorded change. A new HOME change records the current "
                    "holder as its restore target and supersedes the earlier change."
                )
        if args.apply:
            store.save(device, receipt)
            out.item("receipt", receipt_path)
        else:
            out.item("receipt (not written in a dry run)", receipt_path)

        def record(change: dict[str, Any]) -> dict[str, Any]:
            receipt["changes"].append(change)
            store.save(device, receipt)
            return change

        # 1. Install. One install change per receipt; later updates are listed under it, so
        # restore knows whether this tool installed the receiver in the first place.
        if apk_info:
            install_change = find_change(receipt, "install")

            def do_install() -> None:
                if device.package_info() != package:
                    raise ToolError("Receiver package state changed since preflight; retry.", EXIT_REFUSED)
                if sha256_file(staged) != apk_info["sha256"]:
                    raise ToolError("The inspected APK bytes changed before install.", EXIT_REFUSED)
                update = {"at": now_iso(), "apk_sha256": apk_info["sha256"], "version_code": apk_info["version_code"], "previous_version_code": package["version_code"]}
                if install_change is None:
                    # Ownership is per Android user: "fresh" means this tool installed it for `user`.
                    change = record({
                        "kind": "install", "state": "pending", "user": device.user, "fresh": not package["installed"],
                        "other_users_before": package["other_users"], "updates": [], **update,
                    })
                else:
                    change = install_change
                    update["result"] = "pending"
                    change["updates"].append(update)
                    store.save(device, receipt)
                rc, stdout, stderr = device.adb.install(str(staged), device.user)
                installed = device.package_info()
                lost = [u for u in package["other_users"] if u not in (installed["other_users"] or [])]
                if (rc or "Success" not in stdout.splitlines() or installed["installed"] is not True or lost
                        or installed["version_code"] != apk_info["version_code"]):
                    if installed == package and installed["installed"] is False:
                        if install_change is None:
                            change["state"] = "failed"
                        else:
                            update["result"] = "failed"
                        store.save(device, receipt)
                    reason = re.search(r"(INSTALL_[A-Z_]+)", stdout + stderr)
                    raise ToolError(f"Install could not be verified{': ' + reason.group(1) if reason else ''}. Check the receipt before retrying.", EXIT_DEVICE)
                change["state"] = "done"
                update["result"] = "done"
                store.save(device, receipt)
                out.line(f"    installed {PACKAGE} version {installed['version_code']}")
            plan.step(
                f"install {Path(apk_info['path']).name} (sha256 {apk_info['sha256'][:12]}…, version {apk_info['version_code']})",
                [f"adb -s {shlex.quote(device.adb.serial)} install --user {device.user} -r {shlex.quote(apk_info['path'])}"],
                do_install,
            )

        # 2. Contracted entries on the device.
        home_now = before_home
        if args.apply:
            home_now = device.home_state()
            if not home_now["setbeam_declares_home"]:
                raise ToolError(f"The installed receiver does not offer {MAIN_ACTIVITY} for HOME; refusing to continue.", EXIT_REFUSED)
            handler = require_protected_handler(device.configure_handler())
            if args.overlay and apk_info:
                current_package = device.package_info()
                if current_package["installed"] is not True or OVERLAY_PERMISSION not in current_package["permissions"]:
                    raise ToolError("The installed receiver did not confirm the requested overlay permission.", EXIT_REFUSED)
                device.require_boot_receiver(current_package)
        elif package["installed"] and apk_info is None:
            handler = require_protected_handler(device.configure_handler())
        else:
            handler = {"component": f"{PACKAGE}/{apk_info['configure_handler']['name']}"}

        # 3. Configure through the protected provisioning activity.
        configure_argv = [
            "am", "start", "-W", "--user", str(device.user), "-n", handler["component"], "-a", ACTION_CONFIGURE,
            "--es", EXTRA_HOST, host, "--es", EXTRA_NAME, name,
        ]

        def do_configure() -> None:
            since = device.device_time()
            prior = device.provision_log(since) if since is not None else None
            if prior is None:
                raise ToolError("Cannot read the acknowledgement log before configuration.", EXIT_DEVICE)
            change = record({"kind": "configure", "state": "pending", "at": now_iso(),
                             "host": host, "name": name, "reversible": False})
            rc, stdout, stderr = device.adb.mutate(configure_argv)
            if rc or stderr.strip() or "Status: ok" not in stdout.splitlines() or re.search(r"Error|Exception", stdout):
                raise ToolError("The configuration intent could not be verified as delivered.", EXIT_DEVICE)
            deadline = time.monotonic() + min(args.settle_seconds, 5)
            while True:
                messages = device.provision_log(since)
                old = Counter(line for line, _ in prior)
                fresh = []
                for line, message in messages or []:
                    if old[line]:
                        old[line] -= 1
                    elif message.startswith(("Pairing accepted for ", "Pairing refused")):
                        fresh.append(message)
                if fresh or messages is None or time.monotonic() >= deadline:
                    break
                time.sleep(0.25)
            if fresh == [f"Pairing accepted for {host}"]:
                change["state"] = "accepted"
                store.save(device, receipt)
                out.line("    configuration accepted by the receiver (its log names the same host)")
                return
            if len(fresh) == 1 and fresh[0].startswith("Pairing refused"):
                change["state"] = "refused"
                store.save(device, receipt)
                raise ToolError("The receiver refused the configuration; check the TV screen.", EXIT_DEVICE)
            change["state"] = "delivered"
            store.save(device, receipt)
            raise ToolError("Configuration delivered; the receiver's acceptance was not observed. Check the host and label on the TV.", EXIT_DEVICE)
        plan.step("send the configuration intent (host and label) to the receiver's provisioning activity", [adb_display(device.adb.serial, configure_argv)], do_configure)

        # 4. HOME
        exit_code = EXIT_OK
        if args.set_home:
            home_argv = ["cmd", "package", "set-home-activity", "--user", str(device.user), f"{PACKAGE}/.MainActivity"]
            recorded_home = find_change(receipt, "home_role")
            if PACKAGE in (home_now["holders"] or []):
                if recorded_home:
                    out.line("  Setbeam Receiver already holds the HOME role from an earlier recorded run; no HOME change needed.")
                else:
                    out.line("  Setbeam Receiver is already the HOME role holder (original state); HOME is left unchanged and not recorded.")
                if args.apply:
                    # A recorded role that no longer works is rolled back to that change's own "before".
                    exit_code = verify_home_after(device, out, args, recorded_home, receipt, store)
            else:
                if home_now["blockers"]:
                    names = ", ".join(f"{b['component']} priority {b['priority']}" for b in home_now["blockers"])
                    out.warn(f"higher-priority HOME activities are present ({names}); Android will likely keep resolving to them.")

                def do_home() -> int:
                    # The restore target is the live HOME state read immediately before this change.
                    # receipt["before"] is the first snapshot and is history only.
                    live = device.home_state()
                    if live["holders_source"] != "role":
                        raise ToolError("The exact HOME role holder could not be read just before the change; nothing was changed.", EXIT_REFUSED)
                    if recorded_home is not None:
                        if recorded_home["state"] not in ("pending", "done"):  # Never supersede a failed rollback.
                            raise ToolError("Internal error: refusing to supersede an unresolved HOME change.", EXIT_FAILED)
                        recorded_home["state"] = "superseded"
                        recorded_home["superseded_at"] = now_iso()
                    change = record({
                        "kind": "home_role", "state": "pending", "at": now_iso(),
                        "before": {k: live[k] for k in ("resolved", "holders", "holders_source", "candidates")},
                    })
                    set_home(device)
                    change["state"] = "done"
                    store.save(device, receipt)
                    return verify_home_after(device, out, args, change, receipt, store)
                result = plan.step("make Setbeam Receiver the HOME role holder, then test HOME resolution", [adb_display(device.adb.serial, home_argv)], do_home)
                if result is not None:
                    exit_code = result

        # 5. Optional overlay app-op for the receiver's own boot start.
        if args.overlay and exit_code == EXIT_RESTORE_MISMATCH:
            out.line("  overlay app-op: skipped, because the HOME rollback failed. Run restore before any further change.")
        elif args.overlay:
            overlay_argv = ["appops", "set", "--user", str(device.user), PACKAGE, OVERLAY_OP, "allow"]

            flush_argv = ["appops", "write-settings"]

            def flush_owned(change: dict[str, Any]) -> int:
                # In-flight marker first: a failed or interrupted save leaves the receipt unresolved.
                change["state"] = "flush-pending"
                store.save(device, receipt)
                problem = device.flush_appops("allow")
                if problem:
                    receipt["status"] = "needs-restore"
                    store.save(device, receipt)
                    out.line(f"    overlay allow could not be confirmed saved: {problem}.")
                    out.line("    Boot start may not survive a reboot, so setup is not claimed. Provisioning is blocked;")
                    out.line(f"    run {restore_command(device.adb.serial)} and provision again once the save works.")
                    return EXIT_RESTORE_MISMATCH
                change["state"] = "done"
                change["flushed_at"] = now_iso()
                store.save(device, receipt)
                out.line("    overlay allow saved to disk (appops write-settings); only a real reboot proves it persists")
                return EXIT_OK

            def do_overlay() -> int:
                live = device.overlay_mode()  # Read immediately before the change.
                if live is None:
                    raise ToolError("The receiver's overlay app-op cannot be read exactly; it was not changed.", EXIT_REFUSED)
                recorded = find_change(receipt, "overlay_appop")
                if live == "allow":
                    if recorded is not None:
                        # Our earlier grant may never have reached disk; save it again.
                        out.line("    overlay app-op already allowed; the recorded change stays the restore target")
                        return flush_owned(recorded)
                    # Not ours to restore, but startup still depends on it being saved.
                    out.line("    overlay app-op already allowed; nothing recorded")
                    problem = device.flush_appops("allow")
                    if problem:
                        out.line(f"    overlay allow could not be confirmed saved: {problem}.")
                        out.line("    Boot start may not survive a reboot, so setup is not claimed. Nothing was changed; retry.")
                        return EXIT_DEVICE
                    out.line("    overlay allow saved to disk (appops write-settings); only a real reboot proves it persists")
                    return EXIT_OK
                if recorded is not None:
                    # The mode moved away from "allow" after our change: an operator's choice on a
                    # resolved receipt (needs-restore receipts never get here). It becomes the new target.
                    out.warn(
                        f"the overlay app-op changed to {live} after the recorded change; recording {live} as the new "
                        "restore target and superseding the earlier change."
                    )
                    recorded["state"] = "superseded"
                    recorded["superseded_at"] = now_iso()
                change = record({"kind": "overlay_appop", "state": "pending", "at": now_iso(), "previous_mode": live})
                rc, _, _ = device.adb.mutate(overlay_argv)
                if rc != 0 or device.overlay_mode() != "allow":
                    raise ToolError("The device did not apply the overlay app-op.", EXIT_DEVICE)
                return flush_owned(change)
            result = plan.step(
                "allow the receiver's own SYSTEM_ALERT_WINDOW app-op (lets its boot receiver open the player), then save app-op state",
                [adb_display(device.adb.serial, overlay_argv), adb_display(device.adb.serial, flush_argv)],
                do_overlay,
            )
            if result and (result == EXIT_RESTORE_MISMATCH or exit_code == EXIT_OK):
                exit_code = result

        if args.apply:
            receipt["status"] = "applied" if exit_code != EXIT_RESTORE_MISMATCH else "needs-restore"
            store.save(device, receipt)
    out.line("Not verified by this tool: cold power-on start, standby wake, HDMI output, playback, admission.")
    out.line("Run the physical checklist in receiver/docs/hardware-qualification.md before calling this receiver qualified.")
    if not args.apply:
        out.line("Dry run only. Nothing on the device changed. Re-run with --apply to make these changes.")
    return exit_code


def home_key_probe(device: Device, out: Out, args: argparse.Namespace) -> str:
    """Press HOME from another screen and require a real move to Setbeam.

    Returns "passed", "failed" or "inconclusive". Settings is opened first so a
    HOME key that does nothing cannot be mistaken for success.
    """
    device.adb.mutate(["am", "start", "-W", "--user", str(device.user), "-a", SETTINGS_ACTION])
    if args.settle_seconds:
        time.sleep(args.settle_seconds)
    start = device.top_activity()
    if start is None or component_package(start) == PACKAGE:
        out.line("  HOME key probe: inconclusive (no other screen could be brought to the front first, so no transition was observable).")
        return "inconclusive"
    device.adb.mutate(["input", "keyevent", "KEYCODE_HOME"])
    if args.settle_seconds:
        time.sleep(args.settle_seconds)
    top = device.top_activity()
    if top is not None and component_package(top) == PACKAGE:
        out.line(f"  HOME key probe: the HOME key moved the front screen from {start} to Setbeam Receiver.")
        return "passed"
    out.line(f"  HOME key probe: the HOME key left {top or 'an unknown activity'} in front, not Setbeam Receiver.")
    return "failed"


def rollback_home(device: Device, out: Out, args: argparse.Namespace, change: dict[str, Any], receipt: dict[str, Any], store: ReceiptStore) -> int:
    """Return HOME to the change's recorded "before", verify it and persist the result.

    Returns EXIT_HOME_UNAVAILABLE after a verified rollback, or EXIT_RESTORE_MISMATCH
    when it cannot be verified (the caller then makes no further device changes)."""
    change["state"] = "rolling-back"  # Saved before the command, so a killed run stays unresolved.
    store.save(device, receipt)
    try:
        restore_home(device, change["before"])
        if args.settle_seconds:
            time.sleep(args.settle_seconds)
        restored = home_restored(change["before"], device.home_state())
    except ToolError as error:
        out.line(f"  HOME rollback failed: {error}")
        restored = False
    if not restored:
        change["state"] = "rollback-failed"
        receipt["status"] = "needs-restore"
        store.save(device, receipt)
        out.line(f"  HOME rollback could not be verified. Run: {restore_command(device.adb.serial)}")
        return EXIT_RESTORE_MISMATCH
    change["state"] = "rolled-back"
    store.save(device, receipt)
    out.line("  HOME role restored to the holder recorded just before this change (verified).")
    return EXIT_HOME_UNAVAILABLE


def verify_home_after(device: Device, out: Out, args: argparse.Namespace, change: Optional[dict[str, Any]], receipt: dict[str, Any], store: ReceiptStore) -> int:
    if args.settle_seconds:
        time.sleep(args.settle_seconds)
    state = device.home_state()
    for line in describe_home(state):
        out.line(line)
    holder_ok = PACKAGE in (state["holders"] or [])
    roll_back = change is not None and not args.keep_unhonored_home
    if state["resolves_to_setbeam"] and holder_ok:
        probe = home_key_probe(device, out, args) if args.home_key_probe else None
        if probe == "failed":
            if roll_back:
                out.line("  Rolling the HOME role back, because the HOME key did not bring Setbeam to the front.")
                return rollback_home(device, out, args, change, receipt, store)
            out.line("  The HOME role is kept (not changed by this run, or --keep-unhonored-home); it is restorable from the receipt.")
            return EXIT_HOME_UNAVAILABLE
        if probe == "inconclusive":
            out.line("  The verified HOME role is kept; the probe could not show a transition either way.")
        out.line("  HOME verified: the HOME intent resolves to Setbeam Receiver (resolve-activity). Cold power-on is not verified.")
        return EXIT_OK
    if not holder_ok:
        reason = "the HOME role was not granted to Setbeam Receiver"
    elif state["blockers"]:
        reason = "higher-priority system HOME activities outrank Setbeam: " + ", ".join(f"{b['component']} ({b['priority']})" for b in state["blockers"])
    else:
        reason = f"HOME resolves to {state['resolved']}"
    out.line(f"  HOME not available on this OS build: {reason}.")
    if roll_back:
        out.line("  Rolling the HOME role back, because it has no effect here.")
        result = rollback_home(device, out, args, change, receipt, store)
        if result == EXIT_RESTORE_MISMATCH:
            return result
    out.line("  Use a fallback from receiver/docs/startup.md (Projectivy autostart, or the receiver's own boot start).")
    return EXIT_HOME_UNAVAILABLE


def cmd_restore(args: argparse.Namespace, out: Out) -> int:
    device = open_device(args, out)
    store = ReceiptStore(check_receipt_dir(Path(args.receipt_dir) if args.receipt_dir else default_receipt_dir()))
    print_identity(out, device.identity())
    with store.lock():
        receipt = store.load(device)
        if receipt is None:
            raise ToolError("No open receipt exists for this device (matched by hardware serial); nothing to restore.", EXIT_REFUSED)
        check_receipt_matches(receipt, device, out)
        plan = Plan(args.apply, out, device.adb.serial)
        out.line("Restore plan" if not args.apply else "Restoring")
        failures: list[str] = []
        package = device.package_info()
        if package["installed"] is None:
            raise ToolError("The receiver's per-profile install state cannot be read; restore left the receipt open.", EXIT_REFUSED)
        open_changes = [c for c in receipt["changes"] if c["state"] in RESTORE_OPEN_STATES]
        for change in open_changes:
            if change["kind"] == "install" and "user" in change and change["user"] != device.user:
                raise ToolError("The recorded install belongs to a different Android user.", EXIT_REFUSED)

        def save() -> None:
            if args.apply:
                store.save(device, receipt)

        def mark(change: dict[str, Any]) -> None:
            if args.apply:
                change["state"] = "restored"
                store.save(device, receipt)

        def in_flight(*changes: dict[str, Any]) -> None:
            # Saved before the restore command; only verified success (mark) clears it, so a
            # killed restore leaves the receipt unresolved and provisioning blocked.
            for change in changes:
                change["state"] = "restoring"
            store.save(device, receipt)

        # Fixed order: overlay app-op, then HOME, then (optionally) the app itself.
        for change in [c for c in open_changes if c["kind"] == "overlay_appop"]:
            previous = change.get("previous_mode")
            if previous not in APPOP_MODES:
                failures.append("the recorded overlay app-op mode is not a known mode")
                continue
            if not package["installed"]:
                out.line("  overlay app-op: the receiver is absent, so its app-op no longer exists.")
                mark(change)
                continue
            live = device.overlay_mode()
            if live is None:
                raise ToolError(
                    "The receiver's overlay app-op cannot be read exactly now (failed or unrecognized output, or a uid mode); "
                    "refusing to restore it.",
                    EXIT_REFUSED,
                )
            flush_argv = ["appops", "write-settings"]
            if live == previous:
                # Possibly an earlier restore interrupted before its save: save before closing.
                def do_flush(change=change, previous=previous) -> None:
                    in_flight(change)
                    problem = device.flush_appops(previous)
                    if problem:
                        failures.append(f"overlay app-op {previous} could not be confirmed saved: {problem}")
                    else:
                        mark(change)
                plan.step(
                    f"overlay app-op already {previous}; save app-op state before closing",
                    [adb_display(device.adb.serial, flush_argv)],
                    do_flush,
                )
                continue
            if live != "allow" and not args.force:
                raise ToolError(
                    f"The receiver's overlay app-op is now {live}, which is neither allow nor the recorded {previous} "
                    "(allow is what this tool set). Someone changed it later; refusing to override without --force.",
                    EXIT_REFUSED,
                )
            argv = ["appops", "set", "--user", str(device.user), PACKAGE, OVERLAY_OP, previous]

            def do_overlay(change=change, argv=argv, previous=previous) -> None:
                in_flight(change)
                device.adb.mutate(argv)
                if device.overlay_mode() != previous:
                    failures.append(f"overlay app-op is not back to {previous}")
                    return
                problem = device.flush_appops(previous)
                if problem:
                    failures.append(f"overlay app-op {previous} could not be confirmed saved: {problem}")
                else:
                    mark(change)
            plan.step(
                f"set the receiver's overlay app-op back to {previous}, then save app-op state",
                [adb_display(device.adb.serial, argv), adb_display(device.adb.serial, flush_argv)],
                do_overlay,
            )

        for change in [c for c in open_changes if c["kind"] == "home_role"]:
            before = change["before"]
            current = device.home_state()
            if before.get("holders_source") != "role" or current["holders_source"] != "role":
                raise ToolError(
                    "The exact HOME role holder cannot be read on this device now, so HOME cannot be restored exactly; refusing.",
                    EXIT_REFUSED,
                )
            if home_restored(before, current):
                out.line("  HOME already matches the original state.")
                mark(change)
                continue
            ours = current["resolves_to_setbeam"] or PACKAGE in (current["holders"] or [])
            if not ours and not args.force:
                raise ToolError(
                    f"HOME now belongs to {', '.join(current['holders'] or []) or current['resolved']}, which is neither Setbeam "
                    "nor the original holder. Someone changed it later; refusing to override without --force.",
                    EXIT_REFUSED,
                )
            holders = [h for h in before.get("holders") or [] if h != PACKAGE]
            if holders:
                commands = [adb_display(device.adb.serial, ["cmd", "package", "set-home-activity", "--user", str(device.user), holders[0]])]
            else:
                commands = [adb_display(device.adb.serial, ["cmd", "role", "remove-role-holder", "--user", str(device.user), ROLE_HOME, PACKAGE])]

            def do_home(change=change, before=before) -> None:
                in_flight(change)
                try:
                    restore_home(device, before)
                except ToolError as error:
                    failures.append(str(error))
                    return
                if args.settle_seconds:
                    time.sleep(args.settle_seconds)
                after = device.home_state()
                if home_restored(before, after):
                    mark(change)
                elif (args.force and after["holders_source"] == "role"
                      and not before["holders"] and PACKAGE not in after["holders"]):
                    # No explicit holder existed before; Android assigned its own default after removal.
                    out.warn(
                        f"Android assigned {', '.join(after['holders'] or []) or 'no holder'} after Setbeam was removed; "
                        f"HOME now resolves to {after['resolved']} instead of {before.get('resolved')}. Accepted with --force."
                    )
                    mark(change)
                else:
                    failures.append(f"HOME resolves to {after['resolved']} with holders {after['holders']}, expected {before.get('resolved')}")
            plan.step(f"give HOME back to {', '.join(holders) or 'no explicit holder'} (original resolution {before.get('resolved')})", commands, do_home)

        for change in open_changes:
            if change["kind"] == "configure":
                change["state"] = "unverified"
                save()
        if any(c["kind"] == "configure" for c in receipt["changes"]):
            out.line("  configuration: kept in the receiver's app data (removed only by uninstalling the receiver).")

        installs = [c for c in open_changes if c["kind"] == "install"]
        if installs:
            owner = installs[0]
            fresh = bool(owner.get("fresh"))
            resuming = any(c["state"] == "restoring" for c in installs)
            keep = owner.get("other_users_before") or []
            lost = [u for u in keep if u not in package["other_users"]]
            if lost:
                failures.append(f"the receiver app is missing for Android user(s) {lost}, which this tool did not install")
            elif not args.uninstall_receiver and not resuming:
                out.line("  receiver app: left installed (pass --uninstall-receiver to remove it if this tool installed it).")
            elif "user" not in owner:
                out.line("  receiver app: left installed; the receipt does not record which profile it was installed for.")
            elif not fresh:
                out.line(f"  receiver app: it was installed for Android user {owner['user']} before provisioning, so it is left installed.")
            elif failures:
                out.line("  receiver app: left installed because an earlier restore step failed.")
            elif not package["installed"]:
                out.line(f"  receiver app: already absent for Android user {owner['user']}.")
                for change in installs:
                    mark(change)
            else:
                user = owner["user"]  # Equal to the current user; check_receipt_matches refused otherwise.

                def do_uninstall() -> None:
                    in_flight(*installs)
                    device.adb.uninstall(PACKAGE, user)
                    after = device.package_info()
                    lost = [u for u in keep if u not in (after["other_users"] or [])]
                    if after["installed"] is not False:
                        failures.append(f"the receiver app could not be uninstalled for Android user {user}")
                    elif lost:
                        failures.append(f"the receiver app is now missing for Android user(s) {lost}, which this tool did not install")
                    else:
                        for change in installs:
                            mark(change)
                other = f"; it stays installed for Android user(s) {', '.join(map(str, keep))}" if keep else ""
                plan.step(
                    f"uninstall {PACKAGE} for Android user {user} only (installed there by this tool{other})",
                    [f"adb -s {shlex.quote(device.adb.serial)} uninstall --user {user} {PACKAGE}"],
                    do_uninstall,
                )
        if not args.apply:
            out.line("Dry run only. Nothing on the device changed. Re-run with --apply to restore.")
            return EXIT_OK
        save()
        if failures:
            receipt["status"] = "needs-restore"
            store.save(device, receipt)
            for failure in failures:
                out.line(f"  not restored: {failure}")
            out.line(f"Receipt kept at {store.path(device)} and marked needs-restore; provisioning stays blocked until restore succeeds.")
            return EXIT_RESTORE_MISMATCH
        receipt["status"] = "restored"
        receipt["restored_at"] = now_iso()
        store.save(device, receipt)
        archived = store.archive(device)
        out.line(f"Restored and verified. Receipt archived at {archived}.")
    return EXIT_OK


# --------------------------------------------------------------------------
# CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=TOOL_NAME,
        description="Provision, inspect and restore one dedicated Setbeam Receiver TV device. Dry run unless --apply.",
    )
    parser.add_argument("--adb", help="path to adb (default: SETBEAM_ADB, the Android SDK, then PATH)")
    parser.add_argument("--adb-timeout", type=float, default=60.0, help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)

    def device_command(name: str, help_text: str) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--serial", required=True, help="the one adb serial to use, exactly as `adb devices` shows it")
        p.add_argument("--receipt-dir", help="where restore receipts live (default: ~/Library/Application Support/Setbeam/receiver-provisioning)")
        p.add_argument("--settle-seconds", type=float, default=2.0, help="wait before re-checking HOME (default 2)")
        return p

    sub.add_parser("devices", help="list attached adb devices without selecting one")

    verify = sub.add_parser("verify-apk", help="check a receiver APK on this Mac")
    verify.add_argument("--apk", required=True)
    verify.add_argument("--aapt2")
    verify.add_argument("--expect-signer", help="required signer certificate SHA-256 (needs apksigner and Java)")
    verify.add_argument("--json", action="store_true")

    status = device_command("status", "read-only report of the receiver, HOME and receipt")
    status.add_argument("--json", action="store_true")

    provision = device_command("provision", "install/configure the receiver and request HOME")
    provision.add_argument("--host", required=True, help="the Mac's short address, e.g. http://setbeam.local/")
    provision.add_argument("--name", required=True, help=f"receiver label shown to the operator (max {NAME_MAX}; unverified)")
    provision.add_argument("--apk", help="a Setbeam Receiver APK to install or update first")
    provision.add_argument("--aapt2")
    provision.add_argument("--expect-signer", help="required signer certificate SHA-256 for --apk")
    provision.add_argument("--no-set-home", dest="set_home", action="store_false", help="do not request the HOME role")
    provision.add_argument("--keep-unhonored-home", action="store_true", help="keep the HOME role even when Android still resolves another launcher")
    provision.add_argument("--home-key-probe", action="store_true", help="after HOME verifies, press HOME once and check that Setbeam comes to the front")
    provision.add_argument("--allow-background-start", dest="overlay", action="store_true", help="allow the receiver's own SYSTEM_ALERT_WINDOW app-op (recorded and restorable)")
    provision.add_argument("--allow-non-tv", action="store_true", help="permit a device without the leanback feature (emulators)")
    provision.add_argument("--apply", action="store_true", help="make the changes (default is a dry run)")

    restore = device_command("restore", "undo recorded changes using this device's receipt")
    restore.add_argument("--uninstall-receiver", action="store_true", help="also uninstall the receiver if this tool installed it")
    restore.add_argument("--force", action="store_true", help="restore HOME even if another app took it after provisioning")
    restore.add_argument("--apply", action="store_true", help="make the changes (default is a dry run)")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    out = Out(quiet_json=getattr(args, "json", False))
    handlers = {
        "devices": cmd_devices,
        "verify-apk": cmd_verify_apk,
        "status": cmd_status,
        "provision": cmd_provision,
        "restore": cmd_restore,
    }
    try:
        return handlers[args.command](args, out)
    except ToolError as error:
        print(f"error: {error}", file=sys.stderr)
        return error.code
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_FAILED
    except KeyboardInterrupt:
        print("error: interrupted; run `status` to see the device state and receipt.", file=sys.stderr)
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
