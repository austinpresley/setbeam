#!/usr/bin/env python3
"""A fake `aapt2` for tests. The test "APK" is a JSON description; output
follows the real `aapt2 dump badging` / `dump xmltree` formats (SDK 35.0.0)."""

import json
import sys

NS = "http://schemas.android.com/apk/res/android"


def attr(indent, name, value, quoted=True):
    if quoted:
        return f'{" " * indent}A: {NS}:{name}(0x01010003)="{value}" (Raw: "{value}")'
    return f'{" " * indent}A: {NS}:{name}(0x01010010)={value}'


def intent_filter(indent, action, categories):
    lines = [f'{" " * indent}E: intent-filter (line=1)', f'{" " * (indent + 4)}E: action (line=1)', attr(indent + 6, "name", action)]
    for category in categories:
        lines += [f'{" " * (indent + 4)}E: category (line=1)', attr(indent + 6, "name", category)]
    return lines


def main():
    args = sys.argv[1:]
    try:
        with open(args[-1]) as handle:
            apk = json.load(handle)
    except (OSError, ValueError):
        sys.stderr.write("W/ziparchive: Unable to open: Invalid file\n")
        return 1
    if args[:2] == ["dump", "badging"] and apk.get("replace_original"):
        with open(apk["replace_original"], "w") as original:
            json.dump({"package": "replacement"}, original)
    package = apk.get("package", "com.setbeam.receiver")
    main_activity = apk.get("main", "com.setbeam.receiver.MainActivity")
    if args[:2] == ["dump", "badging"]:
        print(f"package: name='{package}' versionCode='{apk.get('version_code', 7)}' versionName='0.1.0' platformBuildVersionName='16'")
        print("minSdkVersion:'26'")
        print("targetSdkVersion:'35'")
        for perm in apk.get("permissions", ["android.permission.INTERNET"]):
            print(f"uses-permission: name='{perm}'")
        print("application: label='Setbeam Receiver' icon=''")
        if apk.get("launcher", True):
            print(f"launchable-activity: name='{main_activity}'  label='' icon=''")
        if apk.get("leanback", True):
            print(f"leanback-launchable-activity: name='{main_activity}'  label='' icon='' banner=''")
        return 0
    if args[:2] == ["dump", "xmltree"]:
        lines = [
            f"N: android={NS} (line=2)",
            "  E: manifest (line=2)",
            f'    A: package="{package}" (Raw: "{package}")',
            "      E: uses-sdk (line=3)",
            f"        A: {NS}:targetSdkVersion(0x01010270)=35",
        ]
        for perm in apk.get("permissions", ["android.permission.INTERNET"]):
            lines += ["      E: uses-permission (line=4)", attr(8, "name", perm)]
        lines += ["      E: application (line=9)", attr(8, "label", "Setbeam Receiver")]
        lines += ["          E: activity (line=10)", attr(12, "name", "." + main_activity.split(".")[-1]), attr(12, "exported", "true", quoted=False)]
        lines += intent_filter(14, "android.intent.action.MAIN", ["android.intent.category.LEANBACK_LAUNCHER", "android.intent.category.LAUNCHER"])
        if apk.get("home", True):
            lines += intent_filter(14, "android.intent.action.MAIN", ["android.intent.category.HOME", "android.intent.category.DEFAULT"])
        configure = apk.get("configure", "protected")
        if configure in ("protected", "unprotected"):
            lines += ["          E: activity (line=20)", attr(12, "name", ".ProvisionActivity"), attr(12, "exported", "true", quoted=False)]
            if configure == "protected":
                lines.append(attr(12, "permission", "android.permission.WRITE_SECURE_SETTINGS"))
            lines += intent_filter(14, "com.setbeam.receiver.CONFIGURE", ["android.intent.category.DEFAULT"])
        if apk.get("configure") == "receiver":
            lines += ["          E: receiver (line=30)", attr(12, "name", ".ConfigureReceiver"), attr(12, "exported", "true", quoted=False)]
            lines += intent_filter(14, "com.setbeam.receiver.CONFIGURE", [])
        for extra in apk.get("extra_handlers", []):
            tag = {"activity": "activity", "alias": "activity-alias", "receiver": "receiver"}[extra["kind"]]
            lines += [f"          E: {tag} (line=50)", attr(12, "name", extra["name"])]
            if extra["kind"] == "alias":
                lines.append(attr(12, "targetActivity", extra.get("target", ".ProvisionActivity")))
            lines.append(attr(12, "exported", "true" if extra.get("exported", True) else "false", quoted=False))
            if extra.get("permission"):
                lines.append(attr(12, "permission", extra["permission"]))
            lines += intent_filter(14, "com.setbeam.receiver.CONFIGURE", ["android.intent.category.DEFAULT"])
        if apk.get("app_permission"):
            # Inserted directly under <application>.
            index = lines.index('      E: application (line=9)')
            lines.insert(index + 1, attr(8, "permission", apk["app_permission"]))
        if apk.get("boot", False) or "android.permission.RECEIVE_BOOT_COMPLETED" in apk.get("permissions", []):
            lines += ["          E: receiver (line=40)", attr(12, "name", ".BootReceiver"), attr(12, "exported", "true", quoted=False)]
            lines += intent_filter(14, "android.intent.action.BOOT_COMPLETED", [])
        print("\n".join(lines))
        return 0
    sys.stderr.write(f"fake aapt2: unsupported {args}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
