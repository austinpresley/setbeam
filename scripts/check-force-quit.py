#!/usr/bin/env python3
"""Launch a disposable integration app, then verify cleanup of its owned groups."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import uuid


def processes():
    result = {}
    for line in subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat=,lstart="], text=True
    ).splitlines():
        pid, parent, group, state, started = line.split(maxsplit=4)
        if not state.startswith("Z"):
            result[int(pid)] = (int(parent), int(group), started)
    return result


def descendants(snapshot, app):
    owned = {app}
    while True:
        expanded = owned | {pid for pid, (parent, _, _) in snapshot.items() if parent in owned}
        if expanded == owned:
            return owned
        owned = expanded


def state_for(snapshot, identities, groups):
    return {pid: {"pgid": group, "started": started}
            for pid, (_, group, started) in snapshot.items()
            if group in groups or identities.get(pid) == started}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Disposable QA .app with its own app.setbeam.mac.* bundle identifier")
    parser.add_argument("--wait-for-normal-quit", action="store_true")
    parser.add_argument("--expected-executable-sha256")
    args = parser.parse_args()
    bundle = args.app.resolve()
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    identifier = info.get("CFBundleIdentifier", "")
    if not identifier.startswith("app.setbeam.mac.") or info.get("CFBundleExecutable") != "Setbeam":
        parser.error("Use a separately identified Setbeam QA bundle.")
    executable = bundle / "Contents/MacOS/Setbeam"
    if executable.resolve() != executable or not os.access(executable, os.X_OK):
        parser.error("The QA bundle must contain its own executable file.")
    sha256 = hashlib.sha256(executable.read_bytes()).hexdigest()
    if args.expected_executable_sha256 and sha256 != args.expected_executable_sha256.lower():
        parser.error(f"Executable digest mismatch: {sha256}")
    print(json.dumps({"app": str(bundle), "bundleIdentifier": identifier,
                      "build": info.get("CFBundleVersion"), "executableSHA256": sha256}), flush=True)
    preference_suite = "app.setbeam.mac.quitqa." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="setbeam-quit-qa-") as scratch:
        session_file = Path(scratch) / "session.json"
        with (Path(scratch) / "app.log").open("w+") as log:
            app = subprocess.Popen([str(executable), "--integration-demo", "--session-file", str(session_file),
                                    "--preferences-suite", preference_suite],
                                   cwd=scratch, env={**os.environ, "TMPDIR": scratch},
                                   start_new_session=True, stdout=log, stderr=log)
            groups, identities = {app.pid}, {}
            try:
                deadline = time.monotonic() + 30
                while app.poll() is None and time.monotonic() < deadline:
                    snapshot = processes()
                    owned = descendants(snapshot, app.pid)
                    identities.update({pid: snapshot[pid][2] for pid in owned if pid in snapshot})
                    # Each helper supervisor creates its own process group. Record only
                    # group leaders observed inside the tree of our Popen child.
                    groups.update(pid for pid in owned if pid in snapshot and snapshot[pid][1] == pid)
                    if session_file.exists() and json.loads(session_file.read_text()).get("pid") == app.pid:
                        helper_groups = {snapshot[pid][1] for pid in owned - {app.pid} if pid in snapshot}
                        if len(helper_groups - {app.pid}) >= 3 and all(
                            sum(snapshot[pid][1] == group for pid in owned if pid in snapshot) >= 2
                            for group in helper_groups - {app.pid}
                        ):
                            break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("The owned integration app did not start three supervised media groups.")
                print(json.dumps({"ownedGroups": sorted(groups), "ownedBeforeQuit": state_for(snapshot, identities, groups)}), flush=True)
                if args.wait_for_normal_quit:
                    print(f"Quit QA app {identifier} now", flush=True)
                else:
                    app.kill()
                deadline = time.monotonic() + (30 if args.wait_for_normal_quit else 6)
                while time.monotonic() < deadline:
                    remaining = state_for(processes(), identities, groups)
                    status = app.poll()
                    if not remaining and status is not None:
                        expected = 0 if args.wait_for_normal_quit else -signal.SIGKILL
                        if status != expected:
                            raise RuntimeError(f"QA app exited with {status}, expected {expected}.")
                        print(json.dumps({"passed": True, "exitStatus": status, "remaining": remaining,
                                          "checkedGroups": sorted(groups), "executableSHA256": sha256}), flush=True)
                        return
                    time.sleep(0.1)
                raise RuntimeError(f"Owned processes survived the quit deadline: {remaining}")
            finally:
                # On failure, reap only the child we launched and the groups that
                # still contain a process whose identity was observed in its tree.
                if app.poll() is None:
                    app.kill()
                app.wait(timeout=5)
                snapshot = processes()
                for group in groups:
                    if any(pgid == group and identities.get(pid) == started
                           for pid, (_, pgid, started) in snapshot.items()):
                        try:
                            os.killpg(group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                subprocess.run(["/usr/bin/defaults", "delete", preference_suite],
                               capture_output=True, timeout=5, check=False)


if __name__ == "__main__":
    main()
