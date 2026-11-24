#!/usr/bin/env python3
"""Install a signed update end to end through Sparkle, on this Mac, without publishing anything.

Takes a Developer ID release-style app (SETBEAM_UPDATES=1) and optionally a previous
release (--from-app). Makes two copies under a separate QA bundle identifier, serves a
signed feed and disk image from 127.0.0.1, then launches and quits the older copy. Passes
when Sparkle has replaced it with the newer build and its signature is intact. Austin's
installed app, settings and Keychain items are not touched.
"""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
BUNDLE = "app.setbeam.mac.updateqa"
# Quits only a running QA copy; a bare `tell` could launch one.
QUIT = f'if application id "{BUNDLE}" is running then tell application id "{BUNDLE}" to quit'


def variant(source, destination, build, feed, identity):
    shutil.copytree(source, destination, symlinks=True)
    plist = destination / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info.update({"CFBundleIdentifier": BUNDLE, "CFBundleVersion": str(build), "SUFeedURL": feed,
                 # QA only: install without the update window, so no UI step is needed.
                 "SUAllowsAutomaticUpdates": True, "SUAutomaticallyUpdate": True})
    plist.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
                    "--entitlements", ROOT / "scripts/signing/app.entitlements", "--identifier", BUNDLE,
                    destination], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", destination], check=True)


def serve(folder, requests):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k): super().__init__(*a, directory=folder, **k)
        def log_message(self, *a): requests.append(self.path)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def reset_preferences():
    subprocess.run(["defaults", "delete", BUNDLE], capture_output=True)
    (Path.home() / f"Library/Preferences/{BUNDLE}.plist").unlink(missing_ok=True)
    for folder in [Path.home() / f"Library/Caches/{BUNDLE}", Path.home() / f"Library/HTTPStorages/{BUNDLE}",
                   Path.home() / f"Library/Saved Application State/{BUNDLE}.savedState"]:
        shutil.rmtree(folder, ignore_errors=True)


def wait(condition, seconds, step=0.5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(step)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Developer ID app built with SETBEAM_UPDATES=1")
    parser.add_argument("--from-app", type=Path, help="Older Developer ID app to update from")
    args = parser.parse_args()
    source = args.app.resolve()
    previous = args.from_app.resolve() if args.from_app else source
    bundle_info = []
    for app in (previous, source):
        team = subprocess.run(["codesign", "-dvv", app], capture_output=True, text=True).stderr
        if f"TeamIdentifier={release.TEAM}" not in team:
            parser.error(f"{app} must be signed with the Developer ID team.")
        bundle_info.append(plistlib.loads((app / "Contents/Info.plist").read_bytes()))
    new_info = bundle_info[1]
    configured_key = plistlib.loads(release.UPDATE_CONFIG.read_bytes())["SUPublicEDKey"]
    if any(info.get("SUPublicEDKey") != configured_key for info in bundle_info):
        parser.error("Both apps must use Setbeam’s configured Sparkle public key.")
    old_build, new_build = 9000, 9001
    if args.from_app:
        try:
            old_build, new_build = (int(info["CFBundleVersion"]) for info in bundle_info)
        except (KeyError, ValueError):
            parser.error("Both apps must have integer build numbers.")
        if old_build >= new_build:
            parser.error("The previous app must have a lower build number than the candidate.")
    identity = release.developer_id(None)[0]
    work = Path(tempfile.mkdtemp(prefix="setbeam-update-qa-"))
    feed_dir, install = work / "feed", work / "install"
    feed_dir.mkdir(); install.mkdir()
    requests = []
    server = serve(str(feed_dir), requests)
    feed = f"http://127.0.0.1:{server.server_port}/appcast.xml"
    reset_preferences()
    process = None
    try:
        variant(previous, install / "Setbeam.app", old_build, feed, identity)
        variant(source, work / "Setbeam.app", new_build, feed, identity)
        expected = release.tree_hashes(work / "Setbeam.app")
        with tempfile.TemporaryDirectory(dir=work) as folder:
            shutil.move(work / "Setbeam.app", Path(folder) / "Setbeam.app")
            (Path(folder) / "Applications").symlink_to("/Applications")
            dmg = feed_dir / "Setbeam-update-qa.dmg"
            subprocess.run(["hdiutil", "create", "-volname", "Setbeam QA", "-srcfolder", folder, "-fs", "HFS+",
                            "-format", "UDZO", dmg], check=True, capture_output=True)
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        print(json.dumps({"artifact": dmg.name, "bytes": dmg.stat().st_size, "sha256": digest,
                          "build": new_build, "bundleIdentifier": BUNDLE}), flush=True)
        signature = release.run([release.TOOLS / "sign_update", "--account", release.KEY_ACCOUNT, "-p", dmg]).stdout.strip()
        release.write_feed(feed_dir / "appcast.xml", None,
                           types.SimpleNamespace(version=new_info["CFBundleShortVersionString"], build=new_build),
                           f"http://127.0.0.1:{server.server_port}/{dmg.name}", signature, dmg.stat().st_size,
                           "<p>Local update QA.</p>")

        # A previous launch and an overdue check make Sparkle check right away, as on a real second launch.
        # The first-launch Permissions sheet is already dismissed then; while it is open, Quit is refused.
        for key, kind, value in [("permissionsIntroduced", "-bool", "YES"), ("SUHasLaunchedBefore", "-bool", "YES"), ("SUEnableAutomaticChecks", "-bool", "YES"),
                                 ("SUAutomaticallyUpdate", "-bool", "YES"), ("SULastCheckTime", "-date", "2026-01-01 00:00:00 +0000")]:
            subprocess.run(["defaults", "write", BUNDLE, key, kind, value], check=True)
        installed = install / "Setbeam.app"
        process = subprocess.Popen([installed / "Contents/MacOS/Setbeam"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not wait(lambda: f"/{dmg.name}" in requests, 120):
            raise SystemExit(f"FAIL: Sparkle did not download the update. Requests: {requests}")
        print(f"Sparkle fetched the signed feed and the update ({requests}).")
        time.sleep(15)  # Validation and extraction finish before the installer waits for Quit.
        subprocess.run(["osascript", "-e", QUIT], capture_output=True, timeout=30)
        if not wait(lambda: process.poll() is not None, 60):
            process.send_signal(signal.SIGTERM)
            raise SystemExit("FAIL: normal Quit did not finish in 60 seconds.")
        def version():
            try:
                return plistlib.loads((installed / "Contents/Info.plist").read_bytes()).get("CFBundleVersion")
            except FileNotFoundError:
                return None

        if not wait(lambda: version() == str(new_build), 120):
            raise SystemExit(f"FAIL: the installed copy is still build {version()} after Quit.")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", installed], check=True)
        if release.tree_hashes(installed) != expected:
            raise SystemExit("FAIL: the installed update differs from the signed disk image's app.")
        if hashlib.sha256(dmg.read_bytes()).hexdigest() != digest:
            raise SystemExit("FAIL: the QA update disk image changed while being served.")
        print(f"PASS: Sparkle verified the signed feed and EdDSA disk image, then replaced build {old_build} "
              f"with Developer ID build {new_build} ({len(expected)} files match; strict signature valid).")
    finally:
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        # Sparkle may relaunch the updated copy; quit only that QA bundle identifier.
        subprocess.run(["osascript", "-e", QUIT], capture_output=True, timeout=30)
        server.shutdown()
        server.server_close()
        reset_preferences()
        shutil.rmtree(work)
        print("Cleanup: waited for the owned launch, closed the loopback server and removed the QA work directory.", flush=True)


if __name__ == "__main__":
    main()
