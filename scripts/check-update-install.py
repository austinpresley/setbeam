#!/usr/bin/env python3
"""Install a signed update end to end through Sparkle, on this Mac, without publishing anything.

Takes a Developer ID release-style app (SETBEAM_UPDATES=1), makes an "installed" and a
"newer" copy under a separate QA bundle identifier, serves a signed feed and disk image
from 127.0.0.1, launches the installed copy normally, and quits it. Passes when Sparkle has
replaced the installed copy with the newer build and its signature is intact. Austin's
installed app, settings and Keychain items are not touched.
"""
import argparse
import hashlib
import importlib.util
import http.server
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
    args = parser.parse_args()
    source = args.app.resolve()
    team = subprocess.run(["codesign", "-dvv", source], capture_output=True, text=True).stderr
    if f"TeamIdentifier={release.TEAM}" not in team:
        raise SystemExit("The app must be signed with the Developer ID team; ad-hoc apps cannot prove the signed path.")
    identity = release.developer_id(None)[0]
    work = Path(tempfile.mkdtemp(prefix="setbeam-update-qa-"))
    feed_dir, install = work / "feed", work / "install"
    feed_dir.mkdir(); install.mkdir()
    requests = []
    server = serve(str(feed_dir), requests)
    feed = f"http://127.0.0.1:{server.server_port}/appcast.xml"
    old_build, new_build = 9000, 9001
    reset_preferences()
    process = None
    try:
        variant(source, install / "Setbeam.app", old_build, feed, identity)
        variant(source, work / "Setbeam.app", new_build, feed, identity)
        expected = release.tree_hashes(work / "Setbeam.app")
        with tempfile.TemporaryDirectory(dir=work) as folder:
            shutil.move(work / "Setbeam.app", Path(folder) / "Setbeam.app")
            (Path(folder) / "Applications").symlink_to("/Applications")
            dmg = feed_dir / "Setbeam-update-qa.dmg"
            subprocess.run(["hdiutil", "create", "-volname", "Setbeam QA", "-srcfolder", folder, "-fs", "HFS+",
                            "-format", "UDZO", dmg], check=True, capture_output=True)
        signature = release.run([release.TOOLS / "sign_update", "--account", release.KEY_ACCOUNT, "-p", dmg]).stdout.strip()
        release.write_feed(feed_dir / "appcast.xml", None, types.SimpleNamespace(version="0.2.0", build=new_build),
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
        version = lambda: plistlib.loads((installed / "Contents/Info.plist").read_bytes()).get("CFBundleVersion")
        if not wait(lambda: installed.exists() and version() == str(new_build), 120):
            raise SystemExit(f"FAIL: the installed copy is still build {version()} after Quit.")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", installed], check=True)
        if release.tree_hashes(installed) != expected:
            raise SystemExit("FAIL: the installed update differs from the signed disk image's app.")
        print(f"PASS: Sparkle verified the signed feed and EdDSA disk image, then replaced build {old_build} "
              f"with Developer ID build {new_build} ({len(expected)} files match; strict signature valid).")
    finally:
        if process and process.poll() is None:
            process.kill()
        # Sparkle may relaunch the updated copy; quit only that QA bundle identifier.
        subprocess.run(["osascript", "-e", QUIT], capture_output=True, timeout=30)
        server.shutdown()
        reset_preferences()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
