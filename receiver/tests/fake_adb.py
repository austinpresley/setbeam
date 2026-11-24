#!/usr/bin/env python3
"""A fake `adb` for the provisioning tool's tests. It never touches a device.

State lives in the JSON file named by FAKE_ADB_STATE and persists between
invocations. Every invocation is appended to FAKE_ADB_LOG as JSON:
{"argv": [...], "remote": [...] or null}. `remote` is the device-side argv after
POSIX shell parsing, the way a device's `sh -c` would split it.

HOME resolution mirrors AOSP ResolveIntentHelper.chooseBestActivity: the
highest-priority HOME activity always wins; a role holder / preferred activity
only decides between equal top priorities; otherwise the resolver activity.
"""

import json
import os
import shlex
import signal
import sys

RESOLVER = "android/com.android.internal.app.ResolverActivity"
PKG = "com.setbeam.receiver"
MAIN = "com.setbeam.receiver/com.setbeam.receiver.MainActivity"
PROVISION = "com.setbeam.receiver/com.setbeam.receiver.ProvisionActivity"
SETTINGS = "com.android.tv.settings/com.android.tv.settings.MainSettings"
WSS = "android.permission.WRITE_SECURE_SETTINGS"


def load():
    with open(os.environ["FAKE_ADB_STATE"]) as handle:
        return json.load(handle)


def save(state):
    with open(os.environ["FAKE_ADB_STATE"], "w") as handle:
        json.dump(state, handle, indent=2)


def log(argv, remote):
    path = os.environ.get("FAKE_ADB_LOG")
    if path:
        with open(path, "a") as handle:
            handle.write(json.dumps({"argv": argv, "remote": remote, "android_serial": os.environ.get("ANDROID_SERIAL")}) + "\n")


def short(component):
    package, cls = component.split("/", 1)
    if cls.startswith(package + "."):
        return f"{package}/{cls[len(package):]}"
    return component


def users_of(pkg):
    return pkg.get("users", [0])


def pkg_for_user(dev, name, user=None):
    """The package if it is installed for `user` (default: the current user)."""
    pkg = dev["packages"].get(name)
    user = dev.get("user", 0) if user is None else user
    return pkg if pkg and user in users_of(pkg) else None


def option_user(args, default):
    if "--user" in args:
        return int(args[args.index("--user") + 1])
    return default


def configure_handlers(pkg):
    """CONFIGURE handlers as (kind, class name, exported, permission)."""
    handlers = []
    configure = pkg.get("configure", "protected") if pkg else None
    if configure == "protected":
        handlers.append(("activity", PKG + ".ProvisionActivity", True, WSS))
    elif configure == "unprotected":
        handlers.append(("activity", PKG + ".ProvisionActivity", True, None))
    elif configure == "receiver":
        handlers.append(("receiver", PKG + ".ConfigureReceiver", True, None))
    for extra in (pkg or {}).get("extra_handlers", []):
        handlers.append((extra["kind"], extra["name"], extra.get("exported", True), extra.get("permission")))
    return handlers


def info_dump(handlers, noun):
    if not handlers:
        return f"No {noun} found\n"
    lines = [f"{len(handlers)} {noun} found:"]
    for index, (kind, name, exported, permission) in enumerate(handlers):
        lines += [
            f"  {'Activity' if noun == 'activities' else 'Receiver'} #{index}:",
            "    priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false",
            "    ActivityInfo:",
            f"      name={name}",
            f"      packageName={PKG}",
            f"      enabled=true exported={'true' if exported else 'false'} directBootAware=false",
        ]
        if permission:
            lines.append(f"      permission={permission}")
    return "\n".join(lines) + "\n"


def home_candidates(dev):
    rows = [dict(c) for c in dev["home_candidates"]]
    pkg = pkg_for_user(dev, PKG)
    if pkg and pkg.get("home", True):
        rows.append({"component": MAIN, "priority": 0})
    return sorted(rows, key=lambda r: -r["priority"])


def resolve_home(dev):
    rows = home_candidates(dev)
    if not rows:
        return None
    top = [r for r in rows if r["priority"] == rows[0]["priority"]]
    if len(top) == 1:
        return top[0]
    for row in top:
        if row["component"].split("/")[0] in dev["role_holders"]:
            return row
    return {"component": RESOLVER, "priority": 0}


def brief(rows, header=True):
    lines = []
    if header:
        lines.append(f"{len(rows)} activities found:")
    for index, row in enumerate(rows):
        prefix = "    " if header else ""
        if header:
            lines.append(f"  Activity #{index}:")
        lines.append(f"{prefix}priority={row['priority']} preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true")
        lines.append(prefix + short(row["component"]))
    return "\n".join(lines) + "\n"


def parse_intent(args):
    intent = {"action": None, "categories": [], "component": None, "package": None, "extras": {}, "user": None}
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--brief", "--components", "-W"):
            i += 1
        elif a == "--user":
            intent["user"] = args[i + 1]; i += 2
        elif a == "-a":
            intent["action"] = args[i + 1]; i += 2
        elif a == "-c":
            intent["categories"].append(args[i + 1]); i += 2
        elif a == "-n":
            intent["component"] = args[i + 1]; i += 2
        elif a == "--es":
            intent["extras"][args[i + 1]] = args[i + 2]; i += 3
        elif a.startswith("-"):
            raise SystemExit(f"fake adb: unsupported intent option {a}")
        else:
            intent["package"] = a; i += 1
    return intent


def device_shell(state, dev, argv):
    """Return (rc, stdout, stderr) for one device-side command."""
    fail = dev.get("fail", {})
    joined = " ".join(argv[:3])
    for prefix, result in fail.items():
        if " ".join(argv).startswith(prefix):
            return result.get("rc", 1), result.get("stdout", ""), result.get("stderr", "")
    if argv == ["getprop"]:
        return 0, "".join(f"[{k}]: [{v}]\n" for k, v in dev["props"].items()), ""
    if argv == ["am", "get-current-user"]:
        return 0, f"{dev.get('user', 0)}\n", ""
    if argv[:2] == ["pm", "has-feature"]:
        return 0, ("true\n" if argv[2] in dev.get("features", []) else "false\n"), ""
    if argv[:2] == ["pm", "path"]:
        # AOSP runPath defaults to the system user (0) without --user.
        if pkg_for_user(dev, argv[-1], option_user(argv, 0)):
            return 0, f"package:/data/app/~~x/{argv[-1]}-y/base.apk\n", ""
        return 1, "", ""
    if argv[:2] == ["dumpsys", "package"]:
        pkg = dev["packages"].get(argv[2])
        if not pkg:
            return 0, "Unable to find package: " + argv[2] + "\n", ""
        perms = "".join(f"      {p}\n" for p in pkg.get("permissions", []))
        user_lines = ""
        if not dev.get("dumpsys_no_users"):
            for user in dev.get("device_users", [0]):
                installed = "true" if user in users_of(pkg) else "false"
                user_lines += f"    User {user}: ceDataInode=1 deDataInode=1 installed={installed} hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false\n"
        if dev.get("dumpsys_bare_user_header"):
            user_lines += "    User 0:\nDexopt state:\n"
        return 0, (
            "Packages:\n"
            f"  Package [{argv[2]}] (abc):\n"
            f"    versionCode={pkg['version_code']} minSdk=26 targetSdk=35\n"
            f"    versionName={pkg.get('version_name', '1.0')}\n"
            "    requested permissions:\n" + perms +
            "    install permissions:\n      android.permission.INTERNET: granted=true\n" +
            ("      android.permission.RECEIVE_BOOT_COMPLETED: granted=true\n"
             if "android.permission.RECEIVE_BOOT_COMPLETED" in pkg.get("permissions", []) and pkg.get("boot_granted", True) else "") + user_lines
        ), ""
    if argv[:3] == ["cmd", "package", "query-activities"]:
        intent = parse_intent(argv[3:])
        if intent["action"] == "android.intent.action.MAIN" and "android.intent.category.HOME" in intent["categories"]:
            return 0, brief(home_candidates(dev)), ""
        if intent["action"] == "com.setbeam.receiver.CONFIGURE" and intent["package"] == PKG and "--brief" not in argv:
            handlers = [h for h in configure_handlers(pkg_for_user(dev, PKG)) if h[0] == "activity"]
            return 0, info_dump(handlers, "activities"), ""
        return 0, "No activities found\n", ""
    if argv[:3] == ["cmd", "package", "resolve-activity"]:
        intent = parse_intent(argv[3:])
        if intent["action"] == "android.intent.action.MAIN" and "android.intent.category.HOME" in intent["categories"]:
            row = resolve_home(dev)
            return 0, (brief([row], header=False) if row else "No activity found\n"), ""
        pkg = pkg_for_user(dev, PKG)
        configure = pkg.get("configure", "protected") if pkg else None
        if intent["action"] == "com.setbeam.receiver.CONFIGURE" and intent["package"] == PKG and configure in ("protected", "unprotected"):
            if "--brief" in argv:
                return 0, brief([{"component": PROVISION, "priority": 0}], header=False), ""
            lines = [
                "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true",
                "ActivityInfo:",
                "  name=com.setbeam.receiver.ProvisionActivity",
                "  packageName=com.setbeam.receiver",
                "  enabled=true exported=true directBootAware=false",
            ]
            if configure == "protected":
                lines.append("  permission=" + WSS)
            lines.append("  taskAffinity=null targetActivity=null persistableMode=PERSIST_ROOT_ONLY")
            return 0, "\n".join(lines) + "\n", ""
        return 0, "No activity found\n", ""
    if argv[:3] == ["cmd", "package", "query-receivers"]:
        intent = parse_intent(argv[3:])
        if intent["action"] == "com.setbeam.receiver.CONFIGURE" and intent["package"] == PKG:
            handlers = [h for h in configure_handlers(pkg_for_user(dev, PKG)) if h[0] == "receiver"]
            return 0, info_dump(handlers, "receivers"), ""
        if intent["action"] == "android.intent.action.BOOT_COMPLETED" and intent["package"] == PKG:
            pkg = pkg_for_user(dev, PKG)
            if pkg and pkg.get("boot", True):
                return 0, info_dump([("receiver", PKG + ".BootReceiver", True, None)], "receivers"), ""
        return 0, "No receivers found\n", ""
    if argv[:3] == ["cmd", "package", "set-home-activity"]:
        target = argv[-1]
        package = target.split("/")[0]
        if dev.get("role_refuses") and package in dev["role_refuses"]:
            return 1, "Error: Failed to set default home.\n", ""
        if not pkg_for_user(dev, package) and package not in [c["component"].split("/")[0] for c in dev["home_candidates"]]:
            return 1, "Error: Failed to set default home.\n", ""
        dev["role_holders"] = [package]
        save(state)
        return 0, "Success\n", ""
    if argv[:3] == ["cmd", "role", "get-role-holders"]:
        if dev["props"].get("ro.build.version.sdk", "34") < "34":
            return 255, "", "Unknown command: get-role-holders\n"
        return 0, ";".join(dev["role_holders"]) + "\n", ""
    if argv[:3] == ["cmd", "role", "remove-role-holder"]:
        dev["role_holders"] = [p for p in dev["role_holders"] if p != argv[-1]]
        if not dev["role_holders"] and dev.get("fallback_holder"):
            dev["role_holders"] = [dev["fallback_holder"]]
        save(state)
        return 0, "", ""
    if argv[:3] == ["cmd", "shortcut", "get-default-launcher"]:
        row = resolve_home(dev)
        return 0, f"Launcher: ComponentInfo{{{row['component']}}}\n", ""
    if argv[:2] == ["appops", "get"]:
        if dev.get("appops_raw") is not None and argv[-2] == PKG:
            return 0, dev["appops_raw"], ""
        if dev.get("appops_shell_raw") is not None and argv[-2] == "com.android.shell":
            return 0, dev["appops_shell_raw"], ""
        mode = dev.get("appops", {}).get(argv[-1]) if argv[-2] == PKG else None
        if mode is None:
            if dev.get("appops_unused_format"):
                # Real Google TV API 36 output for an op the package has never used (QA).
                return 0, "No operations.\nDefault mode: default\n", ""
            return 0, "No operations.\n", ""
        return 0, f"{argv[-1]}: {mode}; time=+1h ago\n", ""
    if argv == ["appops", "write-settings"]:
        # AOSP AppOpsService: flushes in-memory app-op state to disk; changes no mode.
        if dev.get("write_settings_result") is not None:
            result = dev["write_settings_result"]
            return result.get("rc", 0), result.get("stdout", ""), result.get("stderr", "")
        dev["appops_persisted"] = dict(dev.get("appops", {}))
        save(state)
        return 0, "Current settings written.\n", ""
    if argv[:2] == ["appops", "set"]:
        dev.setdefault("appops", {})[argv[-2]] = argv[-1]
        if argv[-1] == "default":
            dev["appops"].pop(argv[-2])
        save(state)
        return 0, "", ""
    if argv[:2] in (["am", "start"], ["am", "broadcast"]):
        intent = parse_intent(argv[2:])
        if intent["action"] == "android.settings.SETTINGS" and intent["component"] is None:
            if not dev.get("settings_blocked"):
                dev["top"] = SETTINGS
                save(state)
            return 0, "Starting: Intent { act=android.settings.SETTINGS }\nStatus: ok\n", ""
        pkg = pkg_for_user(dev, PKG)
        if not pkg or intent["component"] is None or intent["component"].split("/")[0] != PKG:
            return 0, "Error: Activity not started, unable to resolve Intent\n", ""
        dev["clock"] = dev.get("clock", 1000) + 1
        dev["configured"] = {"via": argv[1], "component": intent["component"], "action": intent["action"], "extras": intent["extras"]}
        if dev.get("config_log", "accepted") == "accepted":
            dev.setdefault("logcat", []).append([dev["clock"], "I", "Pairing accepted for " + intent["extras"].get("setbeam_host", "")])
        elif dev.get("config_log") == "refused":
            dev.setdefault("logcat", []).append([dev["clock"], "W", "Pairing refused: That address is not valid."])
        dev["top"] = MAIN
        save(state)
        if argv[1] == "broadcast":
            return 0, "Broadcasting: Intent { act=com.setbeam.receiver.CONFIGURE (has extras) }\nBroadcast completed: result=0\n", ""
        return 0, "Starting: Intent { act=com.setbeam.receiver.CONFIGURE cmp=com.setbeam.receiver/.MainActivity (has extras) }\nStatus: ok\n", ""
    if argv == ["input", "keyevent", "KEYCODE_HOME"]:
        if not dev.get("home_key_ignored"):
            row = resolve_home(dev)
            dev["top"] = row["component"] if row else None
            save(state)
        return 0, "", ""
    if argv == ["date", "+%s"]:
        dev["clock"] = dev.get("clock", 1000) + 1
        save(state)
        return 0, f"{dev['clock']}\n", ""
    if argv[:2] == ["logcat", "-d"]:
        lines = [f"{t}.000  4321  4321 {level} SetbeamProvision: {text}" for t, level, text in dev.get("logcat", [])]
        return 0, "\n".join(["--------- beginning of main"] + lines) + "\n", ""
    if argv == ["dumpsys", "activity", "activities"]:
        top = dev.get("top")
        return 0, (f"  topResumedActivity=ActivityRecord{{1a2b u0 {short(top)} t5}}\n" if top else ""), ""
    return 127, "", f"fake adb: unsupported device command: {argv}\n"


def main():
    argv = sys.argv[1:]
    state = load()
    if argv == ["version"]:
        log(argv, None)
        print("Android Debug Bridge version 1.0.41 (fake)")
        return 0
    if argv == ["devices", "-l"]:
        log(argv, None)
        print("List of devices attached")
        for index, (serial, dev) in enumerate(state["devices"].items(), 1):
            suffix = f" transport_id:{dev.get('transport_id', index)}" if not dev.get("omit_transport") else ""
            print(f"{serial}\t{dev.get('state', 'device')} product:x model:{dev['props'].get('ro.product.model', '?').replace(' ', '_')} device:y{suffix}")
        return 0
    if len(argv) < 3 or argv[0] != "-t":
        log(argv, None)
        sys.stderr.write("fake adb: device commands must name a device with -t\n")
        return 64
    transport, rest = argv[1], argv[2:]
    candidates = [dev for i, dev in enumerate(state["devices"].values(), 1) if str(dev.get("transport_id", i)) == transport]
    dev = candidates[0] if len(candidates) == 1 else None
    if dev is None:
        log(argv, None)
        sys.stderr.write(f"adb: transport '{transport}' not found\n")
        return 1
    if dev.get("state", "device") != "device":
        log(argv, None)
        sys.stderr.write("adb: device unauthorized.\n")
        return 1
    if rest[0] == "shell":
        command = " ".join(rest[1:])  # adb joins the remaining words with spaces.
        remote = shlex.split(command)
        log(argv, remote)
        rc, out, err = device_shell(state, dev, remote)
        sys.stdout.write(out)
        sys.stderr.write(err)
        change = dev.get("change_after")
        if change and " ".join(remote).startswith(change["command"]):
            dev.update(change["update"])
            del dev["change_after"]
            save(state)
        kill_after = dev.get("kill_parent_after")
        if kill_after and " ".join(remote).startswith(kill_after):
            # Simulate the tool being killed after the device acted but before it could check.
            sys.stdout.flush()
            os.kill(os.getppid(), signal.SIGKILL)
        return rc
    log(argv, None)
    if rest[0] == "install":
        result = dev.get("install_result", "Success")
        if result != "Success":
            print(f"Performing Streamed Install\nadb: failed to install {rest[-1]}: Failure [{result}]")
            return 1
        # adb install without --user installs for every user; the tool always scopes it.
        target_users = [option_user(rest, None)] if "--user" in rest else list(dev.get("device_users", [0]))
        existing = dev["packages"].get(PKG)
        template = dict(state["install_package"])
        template["users"] = sorted(set((users_of(existing) if existing else []) + target_users))
        dev["packages"][PKG] = template  # Code is shared: an update changes every profile's version.
        with open(rest[-1]) as apk:
            state["installed_bytes"] = apk.read()
        save(state)
        print("Performing Streamed Install\nSuccess")
        return 0
    if rest[0] == "uninstall":
        name = rest[-1]
        kill_after_uninstall = dev.get("kill_parent_after") == "uninstall"
        pkg = dev["packages"].get(name)
        user = option_user(rest, None)
        if pkg and (user is None or user in users_of(pkg)):
            remaining = [] if user is None else [u for u in users_of(pkg) if u != user]
            if remaining:
                pkg["users"] = remaining
            else:
                del dev["packages"][name]
            dev["role_holders"] = [p for p in dev["role_holders"] if p != name]
            save(state)
            print("Success")
            if kill_after_uninstall:
                sys.stdout.flush()
                os.kill(os.getppid(), signal.SIGKILL)
            return 0
        print("Failure [DELETE_FAILED_INTERNAL_ERROR]")
        return 1
    sys.stderr.write(f"fake adb: unsupported command {rest}\n")
    return 127


if __name__ == "__main__":
    sys.exit(main())
