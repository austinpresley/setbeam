"""Tests for receiver/scripts/setbeam_receiver_provision.py.

Run: python3 -m unittest discover -s receiver/tests -v
Every device interaction goes to tests/fake_adb.py; nothing reaches a real device.
"""

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
RECEIVER = HERE.parent
SCRIPT = RECEIVER / "scripts" / "setbeam_receiver_provision.py"
WRAPPER = RECEIVER / "scripts" / "setbeam-receiver"
FAKE_ADB = HERE / "fake_adb.py"
FAKE_AAPT2 = HERE / "fake_aapt2.py"

spec = importlib.util.spec_from_file_location("provision", SCRIPT)
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)

PKG = "com.setbeam.receiver"
MAIN = f"{PKG}/{PKG}.MainActivity"
LAUNCHERX = "com.google.android.apps.tv.launcherx/com.google.android.apps.tv.launcherx.home.HomeActivity"
SETUPWRAITH = "com.google.android.tungsten.setupwraith/com.google.android.tungsten.setupwraith.MainActivity"
STOCK = "com.example.tvlauncher/com.example.tvlauncher.Home"
SERIAL = "192.168.1.50:5555"
OTHER = "emulator-5554"
TRICKY_NAME = "O'Brien \"Stage\" $(reboot); `id` & é"

ALLOWED_REMOTE = {
    ("getprop",),
    ("am", "get-current-user"),
    ("am", "start"),
    ("am", "broadcast"),
    ("pm", "path"),
    ("pm", "has-feature"),
    ("dumpsys", "package"),
    ("dumpsys", "activity"),
    ("cmd", "package", "query-activities"),
    ("cmd", "package", "resolve-activity"),
    ("cmd", "package", "query-receivers"),
    ("cmd", "package", "set-home-activity"),
    ("cmd", "role", "get-role-holders"),
    ("cmd", "role", "remove-role-holder"),
    ("cmd", "shortcut", "get-default-launcher"),
    ("appops", "get"),
    ("appops", "set"),
    ("appops", "write-settings"),
    ("input", "keyevent"),
    ("date",),
    ("logcat",),
}
MUTATING_REMOTE = {
    ("am", "start"),
    ("am", "broadcast"),
    ("cmd", "package", "set-home-activity"),
    ("cmd", "role", "remove-role-holder"),
    ("appops", "set"),
    ("appops", "write-settings"),
    ("input", "keyevent"),
}


def make_device(google_tv=False, sdk=34, installed=False, serial_no="FAKESERIAL0001", tv=True, configure="protected", perms=None):
    candidates = (
        [{"component": LAUNCHERX, "priority": 2}, {"component": SETUPWRAITH, "priority": 1}]
        if google_tv
        else [{"component": STOCK, "priority": 0}]
    )
    device = {
        "state": "device",
        "props": {
            "ro.product.manufacturer": "FakeVendor",
            "ro.product.brand": "fake",
            "ro.product.model": "Fake TV Box",
            "ro.product.device": "faketv",
            "ro.build.version.release": "14" if sdk >= 34 else "12",
            "ro.build.version.sdk": str(sdk),
            "ro.build.fingerprint": f"fake/faketv/faketv:{sdk}/TEST.1/1:user/release-keys",
            "ro.build.version.incremental": "1",
            "ro.build.version.security_patch": "2026-10-01",
            "ro.build.characteristics": "tv" if tv else "default",
            "ro.serialno": serial_no,
        },
        "features": ["android.software.leanback"] if tv else [],
        "home_candidates": candidates,
        "role_holders": [candidates[0]["component"].split("/")[0]],
        "packages": {},
        "user": 0,
    }
    if installed:
        device["packages"][PKG] = {"version_code": 5, "version_name": "0.0.5", "configure": configure, "permissions": perms or ["android.permission.INTERNET"]}
    return device


class ProvisionTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="setbeam-receiver-test-"))
        self.state_path = self.tmp / "state.json"
        self.log_path = self.tmp / "adb-log.jsonl"
        self.receipts = self.tmp / "receipts"
        for fake in (FAKE_ADB, FAKE_AAPT2):
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.write_state({SERIAL: make_device()})

    def tearDown(self):
        self.assert_only_allowed_commands()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers

    def write_state(self, devices, install_package=None):
        state = {
            "devices": devices,
            "install_package": install_package
            or {"version_code": 7, "version_name": "0.1.0", "configure": "protected", "permissions": ["android.permission.INTERNET"]},
        }
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def dev(self, serial=SERIAL):
        return self.state()["devices"][serial]

    def log(self):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text().splitlines()]

    def remote_commands(self):
        return [entry["remote"] for entry in self.log() if entry["remote"] is not None]

    def mutating_commands(self):
        found = []
        for remote in self.remote_commands():
            if tuple(remote[:2]) in MUTATING_REMOTE or tuple(remote[:3]) in MUTATING_REMOTE:
                found.append(remote)
        for entry in self.log():
            if len(entry["argv"]) > 2 and entry["argv"][2] in ("install", "uninstall"):
                found.append(entry["argv"][2:])
        return found

    def apk(self, **fields):
        path = self.tmp / fields.pop("filename", "SetbeamReceiver.apk")
        path.write_text(json.dumps(fields))
        return str(path)

    def run_tool(self, *args, env_extra=None, settle=True):
        env = dict(os.environ)
        env.update(
            {
                "SETBEAM_ADB": str(FAKE_ADB),
                "SETBEAM_AAPT2": str(FAKE_AAPT2),
                "SETBEAM_SKIP_APKSIGNER": "1",
                "SETBEAM_RECEIPT_DIR": str(self.receipts),
                "FAKE_ADB_STATE": str(self.state_path),
                "FAKE_ADB_LOG": str(self.log_path),
                "ANDROID_SERIAL": OTHER,
            }
        )
        env.pop("ANDROID_HOME", None)
        env.pop("ANDROID_SDK_ROOT", None)
        if env_extra:
            env.update(env_extra)
        argv = list(args)
        if settle and argv and argv[0] in ("status", "provision", "restore"):
            argv += ["--settle-seconds", "0"]
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *argv], capture_output=True, text=True, env=env, timeout=60)

    def provision(self, *extra, host="http://setbeam.local/", name="Stage Left TV", serial=SERIAL, env_extra=None):
        return self.run_tool("provision", "--serial", serial, "--host", host, "--name", name, *extra, env_extra=env_extra)

    def receipt_files(self):
        if not self.receipts.exists():
            return []
        return sorted(p for p in self.receipts.glob("receiver-*.json") if ".restored-" not in p.name)

    def assert_only_allowed_commands(self):
        for entry in self.log():
            argv = entry["argv"]
            self.assertIsNone(entry["android_serial"], "ANDROID_SERIAL must be stripped from the adb environment")
            if argv in (["devices", "-l"], ["version"]):
                continue
            self.assertEqual(argv[0], "-t", f"device command without -t: {argv}")
            if argv[2] == "shell":
                remote = entry["remote"]
                self.assertTrue(
                    tuple(remote[:2]) in ALLOWED_REMOTE or tuple(remote[:3]) in ALLOWED_REMOTE or tuple(remote[:1]) in ALLOWED_REMOTE,
                    f"unexpected device command {remote}",
                )
                if remote[:2] == ["appops", "set"]:
                    self.assertEqual(remote[-3:-1], [PKG, "SYSTEM_ALERT_WINDOW"])
                if remote[:2] == ["appops", "write-settings"]:
                    self.assertEqual(remote, ["appops", "write-settings"])
                if remote[:2] == ["am", "start"] and "-n" not in remote:
                    self.assertIn("android.settings.SETTINGS", remote)
                if remote[:2] == ["pm", "path"]:
                    self.assertEqual(remote[2], "--user", "pm path defaults to user 0; it must name the user")
                if remote[:2] == ["logcat", "-d"]:
                    self.assertEqual(remote, ["logcat", "-d", "-v", "epoch", "-s", "SetbeamProvision"])
                if remote[:1] == ["date"]:
                    self.assertEqual(remote, ["date", "+%s"])
                if remote[:2] == ["input", "keyevent"]:
                    self.assertEqual(remote, ["input", "keyevent", "KEYCODE_HOME"])
                if remote[:3] == ["cmd", "role", "remove-role-holder"]:
                    self.assertEqual(remote[-2:], ["android.app.role.HOME", PKG])
            elif argv[2] == "install":
                self.assertEqual(argv[3], "--user", "install must be scoped to one profile")
                self.assertTrue(argv[4].isdigit())
                self.assertEqual(argv[5], "-r")
            elif argv[2] == "uninstall":
                self.assertEqual(argv[3], "--user", "uninstall must be scoped to one profile")
                self.assertTrue(argv[4].isdigit())
                self.assertEqual(argv[5:], [PKG])
            else:
                self.fail(f"unexpected adb command {argv}")


class InputValidationTests(unittest.TestCase):
    def test_accepts_and_normalizes_short_addresses(self):
        self.assertEqual(provision.validate_host("http://setbeam.local/"), "http://setbeam.local/")
        self.assertEqual(provision.validate_host("http://SetBeam.Local"), "http://setbeam.local/")
        self.assertEqual(provision.validate_host("http://setbeam.local.:80/"), "http://setbeam.local/")
        self.assertEqual(provision.validate_host("http://192.168.1.20"), "http://192.168.1.20/")

    def test_refuses_unsafe_or_wrong_hosts_without_echoing_them(self):
        secret = "a" * 64
        cases = [
            f"http://192.168.1.20:52001/s/{secret}/",
            f"http://setbeam.local/s/{secret}/",
            f"http://guest:{secret}@setbeam.local/",
            f"http://setbeam.local/?code={secret}",
            f"http://setbeam.local/#{secret}",
            "https://setbeam.local/",
            "ftp://setbeam.local/",
            "http://setbeam.local:8080/",
            "http://setbeam.local:99999/",
            "http://127.0.0.1/",
            "http://localhost/",
            "http://0.0.0.0/",
            "http://[::1]/",
            "http:///",
            "http://bad_host!/",
            "http://setbeam.local/ x",
            "http://setbeam.local/\n",
            "",
            "setbeam.local",
        ]
        for raw in cases:
            with self.subTest(raw=raw):
                with self.assertRaises(provision.ToolError) as caught:
                    provision.validate_host(raw)
                self.assertEqual(caught.exception.code, provision.EXIT_REFUSED)
                self.assertNotIn(secret, str(caught.exception))

    def test_names_are_labels_with_gateway_limits(self):
        self.assertEqual(provision.validate_name("  Stage   Left  "), "Stage Left")
        self.assertEqual(provision.validate_name(TRICKY_NAME), TRICKY_NAME)
        for bad in ("", "   ", "a" * 41, "line\nbreak", "tab\there", "bell\x07", "rtl‮override", "nul\x00"):
            with self.subTest(bad=bad):
                with self.assertRaises(provision.ToolError):
                    provision.validate_name(bad)

    def test_serial_validation(self):
        for good in ("192.168.1.50:5555", "emulator-5554", "adb-G070ABC-xYz._adb-tls-connect._tcp", "R58M12345"):
            self.assertEqual(provision.validate_serial(good), good)
        for bad in ("", "-s", "a b", "x;reboot", "$(id)", "a" * 200):
            with self.assertRaises(provision.ToolError):
                provision.validate_serial(bad)

    def test_remote_quoting_round_trips_through_a_posix_shell(self):
        import shlex

        argv = ["am", "start", "--es", "setbeam_name", TRICKY_NAME, "--es", "setbeam_host", "http://setbeam.local/"]
        self.assertEqual(shlex.split(provision.remote_command(argv)), argv)
        # A real POSIX shell sees the same words and runs nothing.
        result = subprocess.run(["/bin/sh", "-c", "printf '%s\\n' " + provision.remote_command([TRICKY_NAME])], capture_output=True, text=True)
        self.assertEqual(result.stdout, TRICKY_NAME + "\n")

    def test_source_never_uses_a_local_shell_or_destructive_device_commands(self):
        import ast

        source = SCRIPT.read_text()
        for forbidden in ("shell=True", "os.system", "os.popen", "import pty"):
            self.assertNotIn(forbidden, source)
        tree = ast.parse(source)
        docstrings = {id(node.body[0].value) for node in ast.walk(tree)
                      if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef)) and node.body
                      and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant)}
        literals = [node.value for node in ast.walk(tree)
                    if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings]
        for word in ("reboot", "factory", "wipe", "disable-user", "disable", "clear", "settings", "fastboot", "run-as", "su", "dpm", "rm", "setprop"):
            self.assertNotIn(word, literals, f"device command word {word!r} appears as a literal")

    def test_brief_and_permission_parsers(self):
        text = (
            "2 activities found:\n  Activity #0:\n    priority=2 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\n"
            "    com.google.android.apps.tv.launcherx/.home.HomeActivity\n  Activity #1:\n"
            "    priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\n    com.setbeam.receiver/.MainActivity\n"
        )
        self.assertEqual(
            provision.parse_brief_list(text),
            [{"component": LAUNCHERX, "priority": 2}, {"component": MAIN, "priority": 0}],
        )
        self.assertEqual(provision.parse_brief_list("No activity found\n"), [])
        dumpsys = "    requested permissions:\n      android.permission.INTERNET\n      android.permission.SYSTEM_ALERT_WINDOW: restricted=true\n    install permissions:\n"
        self.assertEqual(provision.parse_requested_permissions(dumpsys), ["android.permission.INTERNET", "android.permission.SYSTEM_ALERT_WINDOW"])


class DeviceSelectionTests(ProvisionTestCase):
    def test_serial_is_required(self):
        result = self.run_tool("status", settle=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--serial", result.stderr)
        self.assertEqual(self.log(), [])

    def test_missing_device_is_refused_even_when_another_is_attached(self):
        self.write_state({OTHER: make_device()})
        result = self.run_tool("status", "--serial", SERIAL)
        self.assertEqual(result.returncode, provision.EXIT_DEVICE)
        self.assertIn("never picks a device", result.stderr)
        self.assertEqual([e["argv"] for e in self.log()], [["devices", "-l"]])

    def test_unauthorized_and_offline_devices_are_refused(self):
        for state in ("unauthorized", "offline"):
            with self.subTest(state=state):
                device = make_device()
                device["state"] = state
                self.write_state({SERIAL: device})
                result = self.provision("--apply")
                self.assertEqual(result.returncode, provision.EXIT_DEVICE)
                self.assertEqual(self.mutating_commands(), [])

    def test_only_the_named_device_is_touched(self):
        self.write_state({SERIAL: make_device(installed=True), OTHER: make_device(installed=True, serial_no="OTHER")})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for entry in self.log():
            if entry["argv"][0] == "-t":
                self.assertEqual(entry["argv"][1], "1")
        self.assertNotIn("configured", self.dev(OTHER))
        self.assertEqual(self.dev(OTHER)["role_holders"], ["com.example.tvlauncher"])

    def test_devices_lists_without_selecting(self):
        self.write_state({SERIAL: make_device(), OTHER: make_device(serial_no="OTHER")})
        result = self.run_tool("devices")
        self.assertEqual(result.returncode, 0)
        self.assertIn(SERIAL, result.stdout)
        self.assertIn("does not select", result.stdout)
        self.assertEqual([e["argv"] for e in self.log()], [["devices", "-l"]])

    def test_non_tv_devices_are_refused_by_default(self):
        self.write_state({SERIAL: make_device(installed=True, tv=False)})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED)
        self.assertIn("leanback", result.stderr)
        self.assertEqual(self.mutating_commands(), [])


class DryRunAndStatusTests(ProvisionTestCase):
    def test_provision_defaults_to_a_dry_run(self):
        self.write_state({SERIAL: make_device(installed=True)})
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run only", result.stdout)
        self.assertIn("would: make Setbeam Receiver the HOME role holder", result.stdout)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(self.receipt_files(), [])
        self.assertNotIn("configured", self.dev())

    def test_dry_run_with_apk_plans_install_without_installing(self):
        result = self.provision("--apk", self.apk())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would: install SetbeamReceiver.apk", result.stdout)
        self.assertEqual(self.mutating_commands(), [])
        self.assertNotIn(PKG, self.dev()["packages"])

    def test_status_is_read_only_and_reports_google_tv_priority(self):
        self.write_state({SERIAL: make_device(google_tv=True, installed=True)})
        result = self.run_tool("status", "--serial", SERIAL, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        status = json.loads(result.stdout)
        self.assertEqual(self.mutating_commands(), [])
        self.assertFalse(status["home"]["resolves_to_setbeam"])
        self.assertEqual([b["component"] for b in status["home"]["blockers"]], [LAUNCHERX, SETUPWRAITH])
        self.assertIn("outranks", status["assessment"])
        self.assertIn("cold power-on start", status["not_verified"])
        self.assertEqual(status["device"]["hardware_serial_sha256"], __import__("hashlib").sha256(b"FAKESERIAL0001").hexdigest())
        self.assertNotIn("FAKESERIAL0001", result.stdout)

    def test_status_text_on_sdk_31_labels_the_launcher_as_approximate(self):
        self.write_state({SERIAL: make_device(sdk=31, installed=True)})
        result = self.run_tool("status", "--serial", SERIAL)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[approximate: shortcut service]", result.stdout)
        self.assertEqual(self.mutating_commands(), [])


class ProvisionApplyTests(ProvisionTestCase):
    def test_happy_path_installs_configures_and_verifies_home(self):
        result = self.provision("--apk", self.apk(), "--apply", "--home-key-probe", name=TRICKY_NAME)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        device = self.dev()
        self.assertEqual(device["packages"][PKG]["version_code"], 7)
        self.assertEqual(device["configured"]["action"], "com.setbeam.receiver.CONFIGURE")
        self.assertEqual(device["configured"]["component"], f"{PKG}/{PKG}.ProvisionActivity")
        self.assertEqual(device["configured"]["extras"], {"setbeam_host": "http://setbeam.local/", "setbeam_name": TRICKY_NAME})
        self.assertEqual(device["role_holders"], [PKG])
        self.assertIn("HOME verified", result.stdout)
        self.assertIn("HOME key probe: the HOME key moved the front screen from com.android.tv.settings/com.android.tv.settings.MainSettings to Setbeam Receiver", result.stdout)
        self.assertIn("Cold power-on is not verified", result.stdout)
        self.assertNotIn("cold boot passed", result.stdout.lower())
        receipts = self.receipt_files()
        self.assertEqual(len(receipts), 1)
        self.assertEqual(stat.S_IMODE(receipts[0].stat().st_mode), 0o600)
        receipt = json.loads(receipts[0].read_text())
        self.assertEqual(receipt["status"], "applied")
        self.assertEqual(receipt["before"]["home"]["holders"], ["com.example.tvlauncher"])
        self.assertEqual(receipt["before"]["home"]["resolved"], STOCK)
        self.assertEqual([(c["kind"], c["state"]) for c in receipt["changes"]], [("install", "done"), ("configure", "accepted"), ("home_role", "done")])
        self.assertTrue(receipt["changes"][0]["fresh"])
        self.assertNotIn("FAKESERIAL0001", receipts[0].read_text())

    def test_installed_receiver_without_protected_configure_activity_is_refused(self):
        for configure in ("unprotected", "receiver", "none"):
            with self.subTest(configure=configure):
                self.write_state({SERIAL: make_device(installed=True, configure=configure)})
                result = self.provision("--apply")
                self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
                self.assertIn("WRITE_SECURE_SETTINGS", result.stderr)
                self.assertEqual(self.mutating_commands(), [])
                self.assertEqual(self.receipt_files(), [])

    def test_configuration_uses_the_protected_provisioning_activity(self):
        self.write_state({SERIAL: make_device(installed=True)})
        result = self.provision("--apply", "--no-set-home")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.dev()["configured"]["via"], "start")
        self.assertEqual(self.dev()["configured"]["component"], f"{PKG}/{PKG}.ProvisionActivity")
        self.assertIn("accepted by the receiver", result.stdout)
        receipt = json.loads(self.receipt_files()[0].read_text())
        self.assertEqual([(c["kind"], c["state"]) for c in receipt["changes"]], [("configure", "accepted")])

    def test_configuration_refused_by_the_receiver_fails(self):
        device = make_device(installed=True)
        device["config_log"] = "refused"
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_DEVICE, result.stdout + result.stderr)
        self.assertIn("refused the configuration", result.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])
        receipt = json.loads(self.receipt_files()[0].read_text())
        self.assertEqual([(c["kind"], c["state"]) for c in receipt["changes"]], [("configure", "refused")])

    def test_unobserved_configuration_is_reported_as_delivered_only(self):
        device = make_device(installed=True)
        device["config_log"] = "silent"
        self.write_state({SERIAL: device})
        result = self.provision("--apply", "--no-set-home")
        self.assertEqual(result.returncode, provision.EXIT_DEVICE, result.stdout + result.stderr)
        self.assertIn("delivered; the receiver's acceptance was not observed", result.stderr)
        self.assertNotIn("accepted by the receiver", result.stdout)
        receipt = json.loads(self.receipt_files()[0].read_text())
        self.assertEqual(receipt["changes"][0]["state"], "delivered")

    def test_google_tv_priority_rolls_home_back_and_reports_fallback(self):
        self.write_state({SERIAL: make_device(google_tv=True, installed=True)})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_HOME_UNAVAILABLE, result.stdout + result.stderr)
        self.assertIn("higher-priority system HOME activities outrank Setbeam", result.stdout)
        self.assertIn("HOME role restored to the holder recorded just before this change (verified)", result.stdout)
        self.assertIn("fallback", result.stdout)
        self.assertEqual(self.dev()["role_holders"], ["com.google.android.apps.tv.launcherx"])
        receipt = json.loads(self.receipt_files()[0].read_text())
        self.assertEqual([(c["kind"], c["state"]) for c in receipt["changes"]], [("configure", "accepted"), ("home_role", "rolled-back")])

    def test_keep_unhonored_home_leaves_role_for_restore(self):
        self.write_state({SERIAL: make_device(google_tv=True, installed=True)})
        result = self.provision("--apply", "--keep-unhonored-home")
        self.assertEqual(result.returncode, provision.EXIT_HOME_UNAVAILABLE)
        self.assertEqual(self.dev()["role_holders"], [PKG])
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.google.android.apps.tv.launcherx"])

    def test_home_change_is_refused_where_exact_role_holders_are_unreadable(self):
        self.write_state({SERIAL: make_device(google_tv=True, installed=True, sdk=31)})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
        self.assertIn("exact HOME role holder", result.stderr)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(self.receipt_files(), [])
        allowed = self.provision("--apply", "--no-set-home")
        self.assertEqual(allowed.returncode, 0, allowed.stdout + allowed.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.google.android.apps.tv.launcherx"])

    def test_settle_seconds_is_bounded(self):
        result = self.run_tool("status", "--serial", SERIAL, "--settle-seconds", "-1", settle=False)
        self.assertEqual(result.returncode, provision.EXIT_REFUSED)
        self.assertEqual(self.log(), [])

    def test_refused_role_change_is_reported(self):
        device = make_device(installed=True)
        device["role_refuses"] = [PKG]
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_DEVICE)
        self.assertIn("refused to set Setbeam Receiver as HOME", result.stderr)
        receipt = json.loads(self.receipt_files()[0].read_text())
        self.assertEqual(receipt["changes"][-1]["kind"], "home_role")
        self.assertEqual(receipt["changes"][-1]["state"], "pending")
        # Restore treats the pending change safely: HOME already matches the original.
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertIn("already matches the original", restore.stdout)

    def test_missing_receiver_without_apk_is_refused(self):
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED)
        self.assertIn("not installed", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    def test_install_failure_stops_before_configuration(self):
        device = make_device()
        device["install_result"] = "INSTALL_FAILED_UPDATE_INCOMPATIBLE"
        self.write_state({SERIAL: device})
        result = self.provision("--apk", self.apk(), "--apply")
        self.assertEqual(result.returncode, provision.EXIT_DEVICE)
        self.assertIn("INSTALL_FAILED_UPDATE_INCOMPATIBLE", result.stderr)
        self.assertNotIn("configured", self.dev())
        receipt = json.loads(self.receipt_files()[0].read_text())
        self.assertEqual(receipt["changes"][0]["state"], "failed")

    def test_downgrade_is_refused(self):
        self.write_state({SERIAL: make_device(installed=True)})
        result = self.provision("--apk", self.apk(version_code=3), "--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED)
        self.assertIn("downgrade", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    def test_reapply_keeps_the_original_state(self):
        first = self.provision("--apk", self.apk(), "--apply")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second = self.provision("--apply", name="Renamed TV")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("already holds the HOME role from an earlier recorded run", second.stdout)
        receipt = json.loads(self.receipt_files()[0].read_text())
        self.assertEqual(receipt["before"]["home"]["holders"], ["com.example.tvlauncher"])
        self.assertEqual(self.dev()["configured"]["extras"]["setbeam_name"], "Renamed TV")
        self.assertEqual(sum(1 for c in receipt["changes"] if c["kind"] == "home_role"), 1)

    def test_overlay_app_op_needs_opt_in_and_a_requesting_build(self):
        self.write_state({SERIAL: make_device(installed=True)})
        refused = self.provision("--apply", "--allow-background-start")
        self.assertEqual(refused.returncode, provision.EXIT_REFUSED)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(self.receipt_files(), [])

    def test_overlay_app_op_is_recorded_and_restored(self):
        self.write_state({SERIAL: make_device(installed=True, perms=["android.permission.INTERNET", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.RECEIVE_BOOT_COMPLETED"])})
        result = self.provision("--apply", "--allow-background-start")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.dev()["appops"], {"SYSTEM_ALERT_WINDOW": "allow"})
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev().get("appops", {}), {})
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])

    def test_receipt_directory_inside_repository_is_refused(self):
        self.write_state({SERIAL: make_device(installed=True)})
        result = self.provision("--apply", env_extra={"SETBEAM_RECEIPT_DIR": str(RECEIVER / "tests" / "receipts")})
        self.assertEqual(result.returncode, provision.EXIT_REFUSED)
        self.assertIn("inside the Setbeam repository", result.stderr)
        self.assertFalse((RECEIVER / "tests" / "receipts").exists())
        self.assertEqual(self.mutating_commands(), [])

    def test_wrapper_runs_the_tool(self):
        env = dict(os.environ, SETBEAM_ADB=str(FAKE_ADB), FAKE_ADB_STATE=str(self.state_path), FAKE_ADB_LOG=str(self.log_path))
        result = subprocess.run([str(WRAPPER), "devices"], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(SERIAL, result.stdout)


class ApkVerificationTests(ProvisionTestCase):
    def verify(self, path):
        return self.run_tool("verify-apk", "--apk", path)

    def test_valid_apk_passes(self):
        result = self.verify(self.apk(boot=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("APK verified", result.stdout)
        self.assertIn("boot_receiver: True", result.stdout)

    def test_wrong_or_incomplete_apks_are_refused_before_any_device_command(self):
        cases = {
            "package": self.apk(filename="a.apk", package="com.example.other"),
            "TV (LEANBACK_LAUNCHER)": self.apk(filename="b.apk", leanback=False),
            "MAIN + HOME + DEFAULT": self.apk(filename="c.apk", home=False),
            "CONFIGURE": self.apk(filename="d.apk", configure="none"),
            "WRITE_SECURE_SETTINGS": self.apk(filename="e.apk", configure="unprotected"),
            "existing .apk": str(self.tmp / "missing.apk"),
            "not a valid APK": self._garbage_apk(),
        }
        for expected, path in cases.items():
            with self.subTest(expected=expected):
                result = self.provision("--apk", path, "--apply")
                self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
                self.assertIn(expected, result.stderr)
        self.assertEqual(self.log(), [])

    def _garbage_apk(self):
        path = self.tmp / "garbage.apk"
        path.write_bytes(b"PK\x03\x04 not really")
        return str(path)


class RestoreTests(ProvisionTestCase):
    def provisioned(self, **device_kwargs):
        self.write_state({SERIAL: make_device(**device_kwargs)})
        result = self.provision("--apk", self.apk(), "--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.log_path.unlink()

    def test_restore_defaults_to_dry_run(self):
        self.provisioned()
        result = self.run_tool("restore", "--serial", SERIAL)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would: give HOME back to com.example.tvlauncher", result.stdout)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(self.dev()["role_holders"], [PKG])

    def test_restore_returns_home_and_archives_receipt(self):
        self.provisioned()
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])
        self.assertIn(PKG, self.dev()["packages"])
        self.assertEqual(self.receipt_files(), [])
        archived = list(self.receipts.glob("*.restored-*.json"))
        self.assertEqual(len(archived), 1)
        self.assertEqual(json.loads(archived[0].read_text())["status"], "restored")
        again = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(again.returncode, provision.EXIT_REFUSED)

    def test_restore_can_uninstall_only_a_fresh_install(self):
        self.provisioned()
        result = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(PKG, self.dev()["packages"])

    def test_restore_keeps_a_receiver_that_was_already_installed(self):
        self.provisioned(installed=True)
        result = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installed for Android user 0 before provisioning", result.stdout)
        self.assertIn(PKG, self.dev()["packages"])

    def test_restore_refuses_when_another_app_took_home(self):
        self.provisioned()
        state = self.state()
        state["devices"][SERIAL]["home_candidates"].append({"component": "com.third.launcher/com.third.launcher.Main", "priority": 0})
        state["devices"][SERIAL]["role_holders"] = ["com.third.launcher"]
        self.state_path.write_text(json.dumps(state))
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED)
        self.assertIn("refusing to override without --force", result.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.third.launcher"])
        forced = self.run_tool("restore", "--serial", SERIAL, "--apply", "--force")
        self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])

    def test_restore_is_tied_to_the_hardware_serial_not_the_adb_address(self):
        self.provisioned()
        state = self.state()
        moved = state["devices"].pop(SERIAL)
        state["devices"]["192.168.1.77:5555"] = moved
        other = make_device(installed=True, serial_no="DIFFERENT")
        state["devices"][SERIAL] = other
        self.state_path.write_text(json.dumps(state))
        refused = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(refused.returncode, provision.EXIT_REFUSED)
        self.assertIn("No open receipt", refused.stderr)
        restored = self.run_tool("restore", "--serial", "192.168.1.77:5555", "--apply")
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual(self.dev("192.168.1.77:5555")["role_holders"], ["com.example.tvlauncher"])

    def test_restore_after_os_update_warns_and_verifies(self):
        self.provisioned()
        state = self.state()
        state["devices"][SERIAL]["props"]["ro.build.fingerprint"] = "fake/faketv/faketv:35/TEST.2/2:user/release-keys"
        self.state_path.write_text(json.dumps(state))
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OS build changed", result.stderr)

    def test_restore_mismatch_keeps_receipt(self):
        self.provisioned()
        state = self.state()
        state["devices"][SERIAL]["fail"] = {"cmd package set-home-activity --user 0 com.example.tvlauncher": {"rc": 0, "stdout": "Success\n"}}
        self.state_path.write_text(json.dumps(state))
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, provision.EXIT_RESTORE_MISMATCH, result.stdout + result.stderr)
        self.assertIn("not restored", result.stdout)
        self.assertEqual(len(self.receipt_files()), 1)


class ReviewRegressionTests(ProvisionTestCase):
    """Regressions for the independent review of 2026-11-17 (P1 1-3, P2 4-10)."""

    def receipt(self):
        return json.loads(self.receipt_files()[0].read_text())

    def edit_device(self, serial=SERIAL, **changes):
        state = self.state()
        device = state["devices"][serial]
        for key, value in changes.items():
            if key == "props":
                device["props"].update(value)
            else:
                device[key] = value
        self.state_path.write_text(json.dumps(state))

    # P1-1
    def test_repeated_apk_runs_keep_one_install_change(self):
        for version in (7, 8):
            self.write_state({SERIAL: self.dev()} if self.state_path.exists() and version == 8 else {SERIAL: make_device()},
                             install_package={"version_code": version, "version_name": "x", "configure": "protected", "permissions": []})
            result = self.provision("--apk", self.apk(version_code=version), "--apply")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installs = [c for c in self.receipt()["changes"] if c["kind"] == "install"]
        self.assertEqual(len(installs), 1)
        self.assertTrue(installs[0]["fresh"])
        self.assertEqual([u["version_code"] for u in installs[0]["updates"]], [8])

    def test_restore_returns_home_before_uninstalling(self):
        self.test_repeated_apk_runs_keep_one_install_change()
        self.log_path.unlink()
        result = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])
        self.assertNotIn(PKG, self.dev()["packages"])
        kinds = [m[0] if m[0] in ("install", "uninstall") else " ".join(m[:3]) for m in self.mutating_commands()]
        self.assertEqual(kinds, ["cmd package set-home-activity", "uninstall"])
        self.assertEqual(self.receipt_files(), [])

    def test_restore_saves_each_step_and_treats_an_absent_package_as_restored(self):
        self.write_state({SERIAL: make_device()})
        self.assertEqual(self.provision("--apk", self.apk(), "--apply").returncode, 0)
        # HOME restore will fail verification; the uninstall must not run yet, and HOME progress is kept.
        self.edit_device(fail={"cmd package set-home-activity --user 0 com.example.tvlauncher": {"rc": 0, "stdout": "Success\n"}})
        first = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(first.returncode, provision.EXIT_RESTORE_MISMATCH, first.stdout + first.stderr)
        self.assertIn(PKG, self.dev()["packages"])
        # Someone removes the app by hand; the next restore closes cleanly.
        state = self.state()
        del state["devices"][SERIAL]["packages"][PKG]
        state["devices"][SERIAL]["role_holders"] = ["com.example.tvlauncher"]
        state["devices"][SERIAL].pop("fail")
        self.state_path.write_text(json.dumps(state))
        second = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("already absent", second.stdout)
        self.assertEqual(self.receipt_files(), [])

    # P1-2
    def test_restore_refuses_another_android_user(self):
        self.write_state({SERIAL: make_device(installed=True)})
        self.assertEqual(self.provision("--apply").returncode, 0)
        self.edit_device(user=10)
        self.log_path.unlink()
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
        self.assertIn("Android user 0", result.stderr)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(len(self.receipt_files()), 1)
        again = self.provision("--apply")
        self.assertEqual(again.returncode, provision.EXIT_REFUSED)
        self.assertEqual(self.mutating_commands(), [])

    # P1-3
    def test_restore_refuses_a_different_device_with_the_same_serial(self):
        self.write_state({SERIAL: make_device(installed=True)})
        self.assertEqual(self.provision("--apply").returncode, 0)
        self.edit_device(props={"ro.product.model": "Other Box", "ro.product.manufacturer": "Other"})
        self.log_path.unlink()
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
        self.assertIn("different device", result.stderr)
        self.assertEqual(self.mutating_commands(), [])
        forced = self.run_tool("restore", "--serial", SERIAL, "--apply", "--force")
        self.assertEqual(forced.returncode, provision.EXIT_REFUSED, forced.stdout + forced.stderr)

    def test_placeholder_hardware_serials_are_refused(self):
        for serial_no in ("0123456789ABCDEF", "unknown", "", "000000"):
            with self.subTest(serial_no=serial_no):
                self.write_state({SERIAL: make_device(installed=True, serial_no=serial_no)})
                result = self.provision("--apply")
                self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
                self.assertIn("serial", result.stderr)
                self.assertEqual(self.mutating_commands(), [])

    # P2-4
    def test_unknown_overlay_mode_is_refused_before_any_change(self):
        perms = ["android.permission.SYSTEM_ALERT_WINDOW", "android.permission.RECEIVE_BOOT_COMPLETED"]
        for raw in ("garbage output\n", "Uid mode: SYSTEM_ALERT_WINDOW: allow\nSYSTEM_ALERT_WINDOW: default; time=+1h\n"):
            with self.subTest(raw=raw):
                device = make_device(installed=True, perms=perms)
                device["appops_raw"] = raw
                self.write_state({SERIAL: device})
                result = self.provision("--apply", "--allow-background-start")
                self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
                self.assertIn("overlay app-op", result.stderr)
                self.assertEqual(self.mutating_commands(), [])
                self.assertEqual(self.receipt_files(), [])

    def test_overlay_parser_is_anchored(self):
        self.assertIsNone(provision.parse_overlay_mode("Uid mode: SYSTEM_ALERT_WINDOW: allow\n"))
        self.assertEqual(provision.parse_overlay_mode("SYSTEM_ALERT_WINDOW: ignore; time=+2m\n"), "ignore")
        self.assertEqual(provision.parse_overlay_mode("No operations.\n"), "default")
        self.assertIsNone(provision.parse_overlay_mode("Error: bad\n"))

    # P2-6
    def test_restore_requires_exact_holders_even_if_resolution_matches(self):
        device = make_device(google_tv=True, installed=True)
        device["role_holders"] = []
        device["fallback_holder"] = "com.google.android.apps.tv.launcherx"
        self.write_state({SERIAL: device})
        self.assertEqual(self.provision("--apply", "--keep-unhonored-home").returncode, provision.EXIT_HOME_UNAVAILABLE)
        self.assertEqual(self.dev()["role_holders"], [PKG])
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, provision.EXIT_RESTORE_MISMATCH, result.stdout + result.stderr)
        self.assertEqual(len(self.receipt_files()), 1)
        self.assertEqual(self.run_tool("restore", "--serial", SERIAL, "--apply", "--force").returncode, 0)
        self.assertEqual(self.dev()["role_holders"], ["com.google.android.apps.tv.launcherx"])
        self.assertEqual(self.receipt_files(), [])

    def test_inexact_fallback_is_reported_and_closes_only_with_force(self):
        # No holder and a chooser before; after removal Android assigns a default, so HOME
        # resolves differently. That is not an exact restore.
        device = make_device(installed=True)
        device["role_holders"] = []
        device["fallback_holder"] = "com.example.tvlauncher"
        self.write_state({SERIAL: device})
        self.assertEqual(self.provision("--apply").returncode, 0)
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, provision.EXIT_RESTORE_MISMATCH, result.stdout + result.stderr)
        self.assertEqual(len(self.receipt_files()), 1)
        forced = self.run_tool("restore", "--serial", SERIAL, "--apply", "--force")
        self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        self.assertIn("Accepted with --force", forced.stderr)
        self.assertEqual(self.receipt_files(), [])

    def test_setbeam_as_original_holder_is_left_alone(self):
        device = make_device(google_tv=True, installed=True)
        device["role_holders"] = [PKG]
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_HOME_UNAVAILABLE, result.stdout + result.stderr)
        self.assertIn("already the HOME role holder", result.stdout)
        self.assertNotIn(["cmd", "package", "set-home-activity"], [m[:3] for m in self.mutating_commands()])
        self.assertEqual([c["kind"] for c in self.receipt()["changes"]], ["configure"])
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev()["role_holders"], [PKG])

    # P2-7
    def test_failed_rollback_during_provision_exits_with_restore_mismatch(self):
        device = make_device(google_tv=True, installed=True)
        device["fail"] = {"cmd package set-home-activity --user 0 com.google.android.apps.tv.launcherx": {"rc": 1, "stdout": "Error: Failed to set default home.\n"}}
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_RESTORE_MISMATCH, result.stdout + result.stderr)
        self.assertIn("restore --serial", result.stdout)
        self.assertEqual(self.receipt()["changes"][-1]["state"], "rollback-failed")
        self.assertEqual(self.receipt()["status"], "needs-restore")

    # P2-10
    def test_home_key_probe_requires_a_real_transition(self):
        device = make_device(installed=True)
        device["home_key_ignored"] = True
        self.write_state({SERIAL: device})
        result = self.provision("--apply", "--home-key-probe")
        self.assertEqual(result.returncode, provision.EXIT_HOME_UNAVAILABLE, result.stdout + result.stderr)
        self.assertNotIn("HOME key opened Setbeam Receiver", result.stdout)

    def test_home_key_probe_is_inconclusive_without_a_starting_point(self):
        device = make_device(installed=True)
        device["settings_blocked"] = True
        self.write_state({SERIAL: device})
        result = self.provision("--apply", "--home-key-probe")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("HOME key probe: inconclusive", result.stdout)
        self.assertNotIn("HOME key opened Setbeam Receiver", result.stdout)


class ReviewRound2Tests(ProvisionTestCase):
    """Regressions for the second independent review (P1, P2.1, P2.2, P3)."""

    OTHER_LAUNCHER = "com.other.launcher/com.other.launcher.Home"

    def receipt(self):
        return json.loads(self.receipt_files()[0].read_text())

    def mutate_device(self, serial=SERIAL, **changes):
        state = self.state()
        state["devices"][serial].update(changes)
        self.state_path.write_text(json.dumps(state))

    def device_with_other_launcher(self, **kwargs):
        device = make_device(**kwargs)
        device["home_candidates"].append({"component": self.OTHER_LAUNCHER, "priority": 0})
        return device

    # P1, repro 1: an operator's HOME choice between runs is the restore target.
    def test_reused_receipt_records_live_home_before_the_new_change(self):
        self.write_state({SERIAL: self.device_with_other_launcher(installed=True)})
        self.assertEqual(self.provision("--apply", "--no-set-home").returncode, 0)
        self.mutate_device(role_holders=["com.other.launcher"])
        second = self.provision("--apply")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("HOME changed since this receipt was created", second.stderr)
        home = [c for c in self.receipt()["changes"] if c["kind"] == "home_role"][0]
        self.assertEqual(home["before"]["holders"], ["com.other.launcher"])
        self.assertEqual(self.receipt()["before"]["home"]["holders"], ["com.example.tvlauncher"])
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.other.launcher"])

    # P1, repro 2: the rollback inside a re-run returns to the live holder.
    def test_rollback_on_rerun_returns_to_the_live_holder(self):
        device = make_device(google_tv=True, installed=True)
        device["home_candidates"].append({"component": self.OTHER_LAUNCHER, "priority": 0})
        self.write_state({SERIAL: device})
        self.assertEqual(self.provision("--apply").returncode, provision.EXIT_HOME_UNAVAILABLE)
        self.mutate_device(role_holders=["com.other.launcher"])
        second = self.provision("--apply")
        self.assertEqual(second.returncode, provision.EXIT_HOME_UNAVAILABLE, second.stdout + second.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.other.launcher"])
        self.assertIn("HOME role restored to the holder recorded just before this change (verified)", second.stdout)

    def test_open_change_is_superseded_when_the_operator_moved_home_away(self):
        self.write_state({SERIAL: self.device_with_other_launcher(installed=True)})
        self.assertEqual(self.provision("--apply").returncode, 0)
        self.mutate_device(role_holders=["com.other.launcher"])
        second = self.provision("--apply")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        states = [(c["state"], c["before"]["holders"]) for c in self.receipt()["changes"] if c["kind"] == "home_role"]
        self.assertEqual(states, [("superseded", ["com.example.tvlauncher"]), ("done", ["com.other.launcher"])])
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.other.launcher"])

    def test_reuse_with_unchanged_home_does_not_warn(self):
        self.write_state({SERIAL: make_device(installed=True)})
        self.assertEqual(self.provision("--apply", "--no-set-home").returncode, 0)
        second = self.provision("--apply")
        self.assertEqual(second.returncode, 0)
        self.assertNotIn("HOME changed since", second.stderr)

    # P2.1: every exported CONFIGURE handler must require WRITE_SECURE_SETTINGS.
    def test_apk_with_any_unprotected_configure_handler_is_refused(self):
        wss = "android.permission.WRITE_SECURE_SETTINGS"
        refused = {
            "receiver": [{"kind": "receiver", "name": ".ConfigureReceiver"}],
            "activity": [{"kind": "activity", "name": ".OtherConfigure"}],
            "alias without its own permission": [{"kind": "alias", "name": ".ConfigureAlias"}],
        }
        for label, extra in refused.items():
            with self.subTest(label=label):
                result = self.run_tool("verify-apk", "--apk", self.apk(filename=f"{len(label)}.apk", extra_handlers=extra))
                self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
                self.assertIn("WRITE_SECURE_SETTINGS", result.stderr)
        # AOSP: an alias never takes the target's or application's permission; it must declare its own.
        alias_app = self.run_tool("verify-apk", "--apk", self.apk(filename="alias-app.apk", app_permission=wss,
                                                                   extra_handlers=[{"kind": "alias", "name": ".ConfigureAlias"}]))
        self.assertEqual(alias_app.returncode, provision.EXIT_REFUSED, alias_app.stdout + alias_app.stderr)
        accepted = {
            "protected alias": [{"kind": "alias", "name": ".ConfigureAlias", "permission": wss}],
            "non-exported receiver": [{"kind": "receiver", "name": ".Internal", "exported": False}],
        }
        for label, extra in accepted.items():
            with self.subTest(label=label):
                result = self.run_tool("verify-apk", "--apk", self.apk(filename=f"ok{len(label)}.apk", extra_handlers=extra))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        inherited = self.run_tool("verify-apk", "--apk", self.apk(filename="app.apk", app_permission=wss,
                                                                   extra_handlers=[{"kind": "receiver", "name": ".AppGuarded"}]))
        self.assertEqual(inherited.returncode, 0, inherited.stdout + inherited.stderr)

    def test_installed_receiver_with_an_extra_unprotected_handler_is_refused(self):
        device = make_device(installed=True)
        device["packages"][PKG]["extra_handlers"] = [{"kind": "receiver", "name": PKG + ".ConfigureReceiver"}]
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
        self.assertIn("ConfigureReceiver", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    # P2.2: nothing more is changed after a rollback failure.
    def test_no_further_changes_after_a_failed_rollback(self):
        device = make_device(google_tv=True, installed=True, perms=["android.permission.SYSTEM_ALERT_WINDOW", "android.permission.RECEIVE_BOOT_COMPLETED"])
        device["fail"] = {"cmd package set-home-activity --user 0 com.google.android.apps.tv.launcherx": {"rc": 1, "stdout": "Error\n"}}
        self.write_state({SERIAL: device})
        result = self.provision("--apply", "--allow-background-start")
        self.assertEqual(result.returncode, provision.EXIT_RESTORE_MISMATCH, result.stdout + result.stderr)
        self.assertNotIn(["appops", "set"], [m[:2] for m in self.mutating_commands()])
        self.assertNotIn("overlay_appop", [c["kind"] for c in self.receipt()["changes"]])
        self.assertIn("skipped", result.stdout)

    # P3: a failed HOME key probe rolls the role back like a failed resolution.
    def test_failed_home_key_probe_rolls_back_the_role(self):
        device = make_device(installed=True)
        device["home_key_ignored"] = True
        self.write_state({SERIAL: device})
        result = self.provision("--apply", "--home-key-probe")
        self.assertEqual(result.returncode, provision.EXIT_HOME_UNAVAILABLE, result.stdout + result.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])
        home = [c for c in self.receipt()["changes"] if c["kind"] == "home_role"][0]
        self.assertEqual(home["state"], "rolled-back")

    def test_inconclusive_probe_keeps_the_verified_role(self):
        device = make_device(installed=True)
        device["settings_blocked"] = True
        self.write_state({SERIAL: device})
        result = self.provision("--apply", "--home-key-probe")
        self.assertEqual(result.returncode, 0)
        self.assertIn("role is kept", result.stdout)
        self.assertEqual(self.dev()["role_holders"], [PKG])

    # P3: profiles.
    def test_install_in_a_secondary_profile_is_preserved(self):
        device = make_device(installed=True)
        device["device_users"] = [0, 10]
        device["packages"][PKG]["users"] = [10]
        self.write_state({SERIAL: device})
        result = self.provision("--apk", self.apk(), "--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("also installed for Android user(s) 10", result.stderr)
        install = [c for c in self.receipt()["changes"] if c["kind"] == "install"][0]
        self.assertEqual((install["user"], install["fresh"], install["other_users_before"]), (0, True, [10]))
        self.assertEqual(self.dev()["packages"][PKG]["users"], [0, 10])
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev()["packages"][PKG]["users"], [10])

    def test_presence_is_checked_for_the_current_profile(self):
        device = make_device(installed=True)
        device["device_users"] = [0, 10]
        device["user"] = 10
        self.write_state({SERIAL: device})
        status = self.run_tool("status", "--serial", SERIAL, "--json")
        self.assertEqual(status.returncode, 0, status.stderr)
        package = json.loads(status.stdout)["package"]
        self.assertFalse(package["installed"])
        self.assertEqual(package["other_users"], [0])
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED)
        self.assertIn("not installed for Android user 10", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    def test_unreadable_per_profile_state_refuses_install(self):
        device = make_device(installed=True)
        device["dumpsys_no_users"] = True
        self.write_state({SERIAL: device})
        result = self.provision("--apk", self.apk(), "--apply")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
        self.assertIn("per-profile", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    def test_bare_user_header_does_not_override_per_profile_install_state(self):
        device = make_device(installed=True)
        device["dumpsys_bare_user_header"] = True
        self.write_state({SERIAL: device})
        result = self.run_tool("status", "--serial", SERIAL, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        package = json.loads(result.stdout)["package"]
        self.assertTrue(package["installed"])
        self.assertEqual(package["users"], {"0": True})

    def test_receipt_without_profile_ownership_never_uninstalls(self):
        self.write_state({SERIAL: make_device()})
        self.assertEqual(self.provision("--apk", self.apk(), "--apply").returncode, 0)
        path = self.receipt_files()[0]
        data = json.loads(path.read_text())
        for change in data["changes"]:
            if change["kind"] == "install":
                del change["user"]
        path.write_text(json.dumps(data))
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertIn("does not record which profile", restore.stdout)
        self.assertIn(PKG, self.dev()["packages"])

    def test_update_warns_that_restore_keeps_the_new_version(self):
        self.write_state({SERIAL: make_device(installed=True)})
        result = self.provision("--apk", self.apk(), "--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("restore never rolls back an APK version", result.stderr)


class ReviewRound3Tests(ProvisionTestCase):
    """Regressions for the third independent review (P2-1 overlay ownership, P2-2 needs-restore)."""

    OTHER_LAUNCHER = "com.other.launcher/com.other.launcher.Home"
    OVERLAY_PERMS = ["android.permission.INTERNET", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.RECEIVE_BOOT_COMPLETED"]

    def receipt(self):
        return json.loads(self.receipt_files()[0].read_text())

    def set_overlay(self, mode):
        state = self.state()
        appops = state["devices"][SERIAL].setdefault("appops", {})
        if mode == "default":
            appops.pop("SYSTEM_ALERT_WINDOW", None)
        else:
            appops["SYSTEM_ALERT_WINDOW"] = mode
        self.state_path.write_text(json.dumps(state))

    def overlay(self):
        return self.dev().get("appops", {}).get("SYSTEM_ALERT_WINDOW", "default")

    def provision_overlay(self):
        return self.provision("--apply", "--no-set-home", "--allow-background-start")

    # P2-1, repro A: a re-run records the operator's later choice as the new restore target.
    def test_overlay_rerun_supersedes_after_an_operator_choice(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.OVERLAY_PERMS)})
        self.assertEqual(self.provision_overlay().returncode, 0)
        self.set_overlay("deny")
        second = self.provision_overlay()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("overlay app-op changed to deny after the recorded change", second.stderr)
        self.assertEqual(self.overlay(), "allow")
        overlays = [(c["state"], c["previous_mode"]) for c in self.receipt()["changes"] if c["kind"] == "overlay_appop"]
        self.assertEqual(overlays, [("superseded", "default"), ("done", "deny")])
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.overlay(), "deny")

    def test_overlay_rerun_without_an_intervening_change_records_nothing_new(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.OVERLAY_PERMS)})
        self.assertEqual(self.provision_overlay().returncode, 0)
        second = self.provision_overlay()
        self.assertEqual(second.returncode, 0)
        self.assertEqual([c["state"] for c in self.receipt()["changes"] if c["kind"] == "overlay_appop"], ["done"])
        self.assertNotIn("after the recorded change", second.stderr)

    # P2-1, repro B: restore refuses to overwrite a later operator choice without --force.
    def test_overlay_restore_refuses_a_later_operator_choice(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.OVERLAY_PERMS)})
        self.assertEqual(self.provision_overlay().returncode, 0)
        self.set_overlay("deny")
        self.log_path.unlink()
        refused = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(refused.returncode, provision.EXIT_REFUSED, refused.stdout + refused.stderr)
        self.assertIn("neither allow nor the recorded default", refused.stderr)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(self.overlay(), "deny")
        forced = self.run_tool("restore", "--serial", SERIAL, "--apply", "--force")
        self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        self.assertEqual(self.overlay(), "default")

    def test_overlay_restore_refuses_an_unknown_live_mode(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.OVERLAY_PERMS)})
        self.assertEqual(self.provision_overlay().returncode, 0)
        state = self.state()
        state["devices"][SERIAL]["appops_raw"] = "garbage\n"
        self.state_path.write_text(json.dumps(state))
        self.log_path.unlink()
        result = self.run_tool("restore", "--serial", SERIAL, "--apply", "--force")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
        self.assertIn("cannot be read exactly", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    def test_overlay_restore_is_idempotent(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.OVERLAY_PERMS)})
        self.assertEqual(self.provision_overlay().returncode, 0)
        self.set_overlay("default")  # Already back at the recorded mode.
        self.log_path.unlink()
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # No mode change; only the flush, because the matching mode may not be saved yet.
        self.assertEqual(self.mutating_commands(), [["appops", "write-settings"]])

    # P2-2: a needs-restore receipt blocks every provisioning mutation.
    def needs_restore_device(self):
        device = make_device(installed=True, perms=self.OVERLAY_PERMS)
        device["home_candidates"].append({"component": self.OTHER_LAUNCHER, "priority": 0})
        device["role_holders"] = []
        device["fallback_holder"] = "com.other.launcher"
        device["home_key_ignored"] = True
        self.write_state({SERIAL: device})
        first = self.provision("--apply", "--home-key-probe")
        self.assertEqual(first.returncode, provision.EXIT_RESTORE_MISMATCH, first.stdout + first.stderr)
        self.assertEqual(self.receipt()["status"], "needs-restore")
        self.assertEqual([c["state"] for c in self.receipt()["changes"] if c["kind"] == "home_role"], ["rollback-failed"])
        self.mutate(home_key_ignored=False)
        self.log_path.unlink()

    def mutate(self, **changes):
        state = self.state()
        state["devices"][SERIAL].update(changes)
        self.state_path.write_text(json.dumps(state))

    def test_needs_restore_blocks_every_provision_mutation(self):
        self.needs_restore_device()
        before = self.receipt_files()[0].read_text()
        for extra in ((), ("--apk", self.apk(version_code=9)), ("--no-set-home",), ("--no-set-home", "--allow-background-start")):
            with self.subTest(extra=extra):
                result = self.provision("--apply", *extra)
                self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
                self.assertIn("needs restore", result.stderr)
                self.assertIn("restore --serial", result.stderr)
                self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(self.receipt_files()[0].read_text(), before)
        self.assertNotIn("superseded", before)

    def test_needs_restore_is_reported_by_dry_run_and_status(self):
        self.needs_restore_device()
        dry = self.provision()
        self.assertEqual(dry.returncode, provision.EXIT_REFUSED, dry.stdout + dry.stderr)
        self.assertIn("needs restore", dry.stderr)
        status = self.run_tool("status", "--serial", SERIAL)
        self.assertEqual(status.returncode, 0)
        self.assertIn("NEEDS RESTORE", status.stdout)
        status_json = json.loads(self.run_tool("status", "--serial", SERIAL, "--json").stdout)
        self.assertTrue(status_json["receipt"]["needs_restore"])
        self.assertEqual(self.mutating_commands(), [])

    def test_needs_restore_keeps_the_original_target_and_requires_force(self):
        self.needs_restore_device()
        self.assertEqual(self.provision("--apply").returncode, provision.EXIT_REFUSED)
        refused = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(refused.returncode, provision.EXIT_REFUSED, refused.stdout + refused.stderr)
        forced = self.run_tool("restore", "--serial", SERIAL, "--apply", "--force")
        self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        self.assertIn("Accepted with --force", forced.stderr)
        self.assertEqual(self.receipt_files(), [])

    def test_failed_restore_marks_needs_restore_and_blocks_provision(self):
        self.write_state({SERIAL: make_device()})
        self.assertEqual(self.provision("--apk", self.apk(), "--apply").returncode, 0)
        self.mutate(fail={"cmd package set-home-activity --user 0 com.example.tvlauncher": {"rc": 0, "stdout": "Success\n"}})
        result = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(result.returncode, provision.EXIT_RESTORE_MISMATCH)
        self.assertEqual(self.receipt()["status"], "needs-restore")
        self.log_path.unlink()
        blocked = self.provision("--apply")
        self.assertEqual(blocked.returncode, provision.EXIT_REFUSED)
        self.assertEqual(self.mutating_commands(), [])


class FinalRoundTests(ProvisionTestCase):
    """API 36 unused app-op output (QA) and interrupted rollback/restore (review round 4)."""

    OVERLAY_PERMS = ["android.permission.INTERNET", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.RECEIVE_BOOT_COMPLETED"]
    QA_OUTPUT = "No operations.\nDefault mode: default"

    def receipt(self):
        return json.loads(self.receipt_files()[0].read_text())

    def mutate(self, **changes):
        state = self.state()
        device = state["devices"][SERIAL]
        for key, value in changes.items():
            if value is None:
                device.pop(key, None)
            else:
                device[key] = value
        self.state_path.write_text(json.dumps(state))

    # ---- Parser
    def test_parser_accepts_exactly_the_api36_unused_op_form(self):
        parse = provision.parse_overlay_mode
        self.assertEqual(parse(self.QA_OUTPUT), "default")
        self.assertEqual(parse(self.QA_OUTPUT + "\n"), "default")
        self.assertEqual(parse("  No operations.  \n\n  Default mode: default \n"), "default")
        self.assertEqual(parse("No operations.\nDefault mode: allow\n"), "allow")
        self.assertEqual(parse("No operations.\nDefault mode: ignore\n"), "ignore")
        self.assertEqual(parse("No operations.\n"), "default")  # Unchanged single-line form.
        self.assertEqual(parse("SYSTEM_ALERT_WINDOW: deny; time=+1m\n"), "deny")  # Unchanged package line.
        for ambiguous in (
            "No operations.\nDefault mode: weird\n",
            "No operations.\nDefault mode:\n",
            "No operations.\nDefault mode: default extra\n",
            "Default mode: default\n",
            "Default mode: default\nNo operations.\n",
            "No operations.\nDefault mode: default\nDefault mode: allow\n",
            "No operations.\nSYSTEM_ALERT_WINDOW: allow\n",
            "No operations.\nDefault mode: default\nUid mode: SYSTEM_ALERT_WINDOW: allow\n",
            "Uid mode: SYSTEM_ALERT_WINDOW: allow\nNo operations.\nDefault mode: default\n",
            "No operations.\nNo operations.\n",
            "",
        ):
            with self.subTest(text=ambiguous):
                self.assertIsNone(parse(ambiguous))

    # ---- End to end with the QA output
    def test_api36_output_provisions_reports_and_restores_the_overlay(self):
        device = make_device(installed=True, perms=self.OVERLAY_PERMS)
        device["appops_unused_format"] = True
        self.write_state({SERIAL: device})
        status = json.loads(self.run_tool("status", "--serial", SERIAL, "--json").stdout)
        self.assertEqual(status["overlay_mode"], "default")
        result = self.provision("--apply", "--no-set-home", "--allow-background-start")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        overlay = [c for c in self.receipt()["changes"] if c["kind"] == "overlay_appop"][0]
        self.assertEqual((overlay["state"], overlay["previous_mode"]), ("done", "default"))
        self.assertEqual(self.dev()["appops"], {"SYSTEM_ALERT_WINDOW": "allow"})
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev().get("appops", {}), {})
        again = json.loads(self.run_tool("status", "--serial", SERIAL, "--json").stdout)
        self.assertEqual(again["overlay_mode"], "default")

    def test_fresh_apk_preflight_reads_the_shell_package_in_the_api36_form(self):
        device = make_device(perms=self.OVERLAY_PERMS)
        device["appops_unused_format"] = True
        self.write_state({SERIAL: device}, install_package={"version_code": 7, "version_name": "0.1.0", "configure": "protected", "permissions": self.OVERLAY_PERMS})
        result = self.provision("--apk", self.apk(permissions=self.OVERLAY_PERMS), "--apply", "--no-set-home", "--allow-background-start")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        shell_reads = [r for r in self.remote_commands() if r[:2] == ["appops", "get"] and r[-2] == "com.android.shell"]
        self.assertTrue(shell_reads, "fresh installs must check appops readability on com.android.shell")
        self.assertEqual(self.dev()["appops"], {"SYSTEM_ALERT_WINDOW": "allow"})

    def test_fresh_apk_preflight_refuses_unreadable_shell_appops(self):
        device = make_device(perms=self.OVERLAY_PERMS)
        device["appops_shell_raw"] = "No operations.\nDefault mode: mystery\n"
        self.write_state({SERIAL: device})
        result = self.provision("--apk", self.apk(permissions=self.OVERLAY_PERMS), "--apply", "--no-set-home", "--allow-background-start")
        self.assertEqual(result.returncode, provision.EXIT_REFUSED, result.stdout + result.stderr)
        self.assertIn("overlay app-op cannot be read exactly", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    # ---- Interruption: a real process kill after the command, before verification.
    def test_killed_home_rollback_blocks_provision_and_restore_resumes(self):
        device = make_device(google_tv=True, installed=True)
        device["kill_parent_after"] = "cmd package set-home-activity --user 0 com.google.android.apps.tv.launcherx"
        self.write_state({SERIAL: device})
        killed = self.provision("--apply")
        self.assertEqual(killed.returncode, -9, killed.stdout + killed.stderr)
        home = [c for c in self.receipt()["changes"] if c["kind"] == "home_role"][0]
        self.assertEqual(home["state"], "rolling-back")
        self.mutate(kill_parent_after=None)
        self.log_path.unlink()
        for extra in ((), ("--no-set-home",), ("--apk", self.apk(version_code=9))):
            with self.subTest(extra=extra):
                blocked = self.provision("--apply", *extra)
                self.assertEqual(blocked.returncode, provision.EXIT_REFUSED, blocked.stdout + blocked.stderr)
                self.assertIn("needs restore", blocked.stderr)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual([c["state"] for c in self.receipt()["changes"] if c["kind"] == "home_role"], ["rolling-back"])
        self.assertIn("NEEDS RESTORE", self.run_tool("status", "--serial", SERIAL).stdout)
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertEqual(self.dev()["role_holders"], ["com.google.android.apps.tv.launcherx"])
        self.assertEqual(self.receipt_files(), [])

    def test_killed_overlay_restore_blocks_provision_and_resumes(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.OVERLAY_PERMS)})
        self.assertEqual(self.provision("--apply", "--no-set-home", "--allow-background-start").returncode, 0)
        self.mutate(kill_parent_after="appops set --user 0 com.setbeam.receiver SYSTEM_ALERT_WINDOW default")
        killed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(killed.returncode, -9)
        self.assertEqual([c["state"] for c in self.receipt()["changes"] if c["kind"] == "overlay_appop"], ["restoring"])
        self.mutate(kill_parent_after=None)
        self.log_path.unlink()
        blocked = self.provision("--apply", "--no-set-home", "--allow-background-start")
        self.assertEqual(blocked.returncode, provision.EXIT_REFUSED)
        self.assertEqual(self.mutating_commands(), [])
        resumed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        self.assertEqual(self.dev().get("appops", {}), {})

    def test_killed_uninstall_blocks_provision_and_resumes(self):
        self.write_state({SERIAL: make_device()})
        self.assertEqual(self.provision("--apk", self.apk(), "--apply", "--no-set-home").returncode, 0)
        self.mutate(kill_parent_after="uninstall")
        killed = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(killed.returncode, -9)
        self.assertEqual([c["state"] for c in self.receipt()["changes"] if c["kind"] == "install"], ["restoring"])
        self.mutate(kill_parent_after=None)
        blocked = self.provision("--apk", self.apk(), "--apply", "--no-set-home")
        self.assertEqual(blocked.returncode, provision.EXIT_REFUSED)
        resumed = self.run_tool("restore", "--serial", SERIAL, "--apply")  # Even without --uninstall-receiver.
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        self.assertNotIn(PKG, self.dev()["packages"])
        self.assertEqual(self.receipt_files(), [])

    # ---- Interruption: a process-like BaseException inside the tool's own process.
    def run_in_process(self, *args, interrupt_on_call=None):
        from unittest import mock

        env = {
            "SETBEAM_ADB": str(FAKE_ADB), "SETBEAM_AAPT2": str(FAKE_AAPT2), "SETBEAM_SKIP_APKSIGNER": "1",
            "SETBEAM_RECEIPT_DIR": str(self.receipts), "FAKE_ADB_STATE": str(self.state_path), "FAKE_ADB_LOG": str(self.log_path),
        }
        calls = {"n": 0}
        real = provision.home_restored

        def interrupting(before, current):
            calls["n"] += 1
            if calls["n"] == interrupt_on_call:
                raise KeyboardInterrupt
            return real(before, current)

        with mock.patch.dict(os.environ, env), mock.patch.object(provision, "home_restored", interrupting), \
                mock.patch("sys.stdout", new=__import__("io").StringIO()), mock.patch("sys.stderr", new=__import__("io").StringIO()):
            return provision.main([*args, "--settle-seconds", "0"])

    def test_interrupted_home_restore_is_never_superseded_on_rerun(self):
        device = make_device(installed=True)
        device["home_candidates"].append({"component": "com.other.launcher/com.other.launcher.Home", "priority": 0})
        self.write_state({SERIAL: device})
        self.assertEqual(self.provision("--apply").returncode, 0)
        # Call 1 is restore's "already matches?" check; call 2 follows the restore command.
        code = self.run_in_process("restore", "--serial", SERIAL, "--apply", interrupt_on_call=2)
        self.assertEqual(code, provision.EXIT_FAILED)
        self.assertEqual([c["state"] for c in self.receipt()["changes"] if c["kind"] == "home_role"], ["restoring"])
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])
        self.log_path.unlink()
        blocked = self.provision("--apply")
        self.assertEqual(blocked.returncode, provision.EXIT_REFUSED, blocked.stdout + blocked.stderr)
        self.assertEqual(self.mutating_commands(), [])
        self.assertNotIn("superseded", self.receipt_files()[0].read_text())
        resumed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        self.assertEqual(self.receipt_files(), [])

    def test_interrupted_home_rollback_in_process_leaves_rolling_back(self):
        self.write_state({SERIAL: make_device(google_tv=True, installed=True)})
        code = self.run_in_process("provision", "--serial", SERIAL, "--host", "http://setbeam.local/", "--name", "TV", "--apply", interrupt_on_call=1)
        self.assertEqual(code, provision.EXIT_FAILED)
        self.assertEqual([c["state"] for c in self.receipt()["changes"] if c["kind"] == "home_role"], ["rolling-back"])
        self.assertTrue(provision.needs_restore(self.receipt()))


class OverlayPersistenceTests(ProvisionTestCase):
    """appops write-settings after overlay changes (AOSP delays package-mode writes;
    a hard reboot can lose an unsaved grant). The fake keeps live and saved modes apart."""

    PERMS = ["android.permission.INTERNET", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.RECEIVE_BOOT_COMPLETED"]
    FLUSH_FAILURES = {
        "refused": {"rc": 255, "stdout": "", "stderr": "Security exception: requires MANAGE_APP_OPS_MODES\n"},
        "unsupported": {"rc": 255, "stdout": "", "stderr": "Unknown command: write-settings\n"},
        "ambiguous": {"rc": 0, "stdout": "Done\n", "stderr": ""},
    }

    def receipt(self):
        return json.loads(self.receipt_files()[0].read_text())

    def mutate(self, **changes):
        state = self.state()
        device = state["devices"][SERIAL]
        for key, value in changes.items():
            if value is None:
                device.pop(key, None)
            else:
                device[key] = value
        self.state_path.write_text(json.dumps(state))

    def reboot(self):
        """Reload app-op modes from what was saved to disk, as a hard reboot would."""
        state = self.state()
        device = state["devices"][SERIAL]
        device["appops"] = dict(device.get("appops_persisted", {}))
        self.state_path.write_text(json.dumps(state))

    def live(self):
        return self.dev().get("appops", {}).get("SYSTEM_ALERT_WINDOW", "default")

    def saved(self):
        return self.dev().get("appops_persisted", {}).get("SYSTEM_ALERT_WINDOW", "default")

    def grant(self, *extra):
        return self.provision("--apply", "--no-set-home", "--allow-background-start", *extra)

    def overlay_states(self):
        return [c["state"] for c in self.receipt()["changes"] if c["kind"] == "overlay_appop"]

    def flushes(self):
        return [r for r in self.remote_commands() if r == ["appops", "write-settings"]]

    def test_grant_is_flushed_and_survives_a_reboot(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        result = self.grant()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.flushes()), 1)
        self.assertIn("saved to disk", result.stdout)
        self.assertEqual(self.saved(), "allow")
        self.assertEqual(self.overlay_states(), ["done"])
        self.reboot()
        self.assertEqual(self.live(), "allow")

    def test_an_unflushed_grant_is_lost_on_reboot_in_the_fake(self):
        # Guards the fake itself: without write-settings the saved mode is untouched.
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.mutate(appops={"SYSTEM_ALERT_WINDOW": "allow"})
        self.reboot()
        self.assertEqual(self.live(), "default")

    def test_flush_failure_after_grant_blocks_and_restore_resolves(self):
        for label, failure in self.FLUSH_FAILURES.items():
            with self.subTest(label=label):
                self.tearDown()  # Fresh temporary state per failure kind; unittest's tearDown cleans the last.
                self.setUp()
                self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
                self.mutate(write_settings_result=failure)
                result = self.grant()
                self.assertEqual(result.returncode, provision.EXIT_RESTORE_MISMATCH, result.stdout + result.stderr)
                self.assertIn("could not be confirmed saved", result.stdout)
                self.assertNotIn("saved to disk", result.stdout)
                self.assertEqual(self.overlay_states(), ["flush-pending"])
                self.assertEqual(self.receipt()["status"], "needs-restore")
                self.assertEqual(self.live(), "allow")
                self.assertEqual(self.saved(), "default")
                self.log_path.unlink()
                blocked = self.grant()
                self.assertEqual(blocked.returncode, provision.EXIT_REFUSED)
                self.assertEqual(self.mutating_commands(), [])
                self.assertIn("NEEDS RESTORE", self.run_tool("status", "--serial", SERIAL).stdout)
                self.mutate(write_settings_result=None)
                restore = self.run_tool("restore", "--serial", SERIAL, "--apply")
                self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
                self.assertEqual((self.live(), self.saved()), ("default", "default"))
                self.assertEqual(self.receipt_files(), [])

    def test_flush_failure_during_restore_keeps_it_open_then_resumes(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.assertEqual(self.grant().returncode, 0)
        self.mutate(write_settings_result=self.FLUSH_FAILURES["ambiguous"])
        failed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(failed.returncode, provision.EXIT_RESTORE_MISMATCH, failed.stdout + failed.stderr)
        self.assertIn("could not be confirmed saved", failed.stdout)
        self.assertEqual(self.overlay_states(), ["restoring"])
        self.assertEqual(self.receipt()["status"], "needs-restore")
        self.assertEqual((self.live(), self.saved()), ("default", "allow"))
        self.log_path.unlink()
        self.assertEqual(self.grant().returncode, provision.EXIT_REFUSED)
        self.assertEqual(self.mutating_commands(), [])
        self.mutate(write_settings_result=None)
        resumed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        self.assertEqual(self.flushes(), [["appops", "write-settings"]])
        self.assertEqual((self.live(), self.saved()), ("default", "default"))
        self.reboot()
        self.assertEqual(self.live(), "default")

    def test_interrupted_restore_with_target_mode_flushes_before_closing(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.assertEqual(self.grant().returncode, 0)
        self.mutate(kill_parent_after="appops set --user 0 com.setbeam.receiver SYSTEM_ALERT_WINDOW default")
        killed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(killed.returncode, -9)
        self.assertEqual(self.overlay_states(), ["restoring"])
        self.assertEqual((self.live(), self.saved()), ("default", "allow"))  # Changed but not saved.
        self.mutate(kill_parent_after=None)
        self.log_path.unlink()
        resumed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        self.assertEqual(self.mutating_commands(), [["appops", "write-settings"]])
        self.assertEqual(self.saved(), "default")

    def test_reboot_before_flush_during_restore_is_resumed_from_the_saved_mode(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.assertEqual(self.grant().returncode, 0)
        self.mutate(kill_parent_after="appops set --user 0 com.setbeam.receiver SYSTEM_ALERT_WINDOW default")
        self.assertEqual(self.run_tool("restore", "--serial", SERIAL, "--apply").returncode, -9)
        self.mutate(kill_parent_after=None)
        self.reboot()  # The unsaved restore is lost; the live mode is allow again.
        self.assertEqual(self.live(), "allow")
        resumed = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        self.assertEqual((self.live(), self.saved()), ("default", "default"))

    def test_already_allowed_but_unsaved_setup_is_flushed_without_a_new_record(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.mutate(appops={"SYSTEM_ALERT_WINDOW": "allow"})  # Granted live, never saved.
        result = self.grant()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.overlay_states(), [])
        self.assertEqual(len(self.flushes()), 1)
        self.assertEqual(self.saved(), "allow")
        self.reboot()
        self.assertEqual(self.live(), "allow")

    def test_already_allowed_setup_with_a_failed_flush_is_not_claimed(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.mutate(appops={"SYSTEM_ALERT_WINDOW": "allow"}, write_settings_result=self.FLUSH_FAILURES["refused"])
        result = self.grant()
        self.assertEqual(result.returncode, provision.EXIT_DEVICE, result.stdout + result.stderr)
        self.assertIn("could not be confirmed saved", result.stdout)
        self.assertNotIn("saved to disk", result.stdout)
        self.assertEqual(self.overlay_states(), [])

    def test_rerun_with_an_open_allow_change_flushes_again(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.assertEqual(self.grant().returncode, 0)
        self.mutate(appops_persisted={})  # Pretend the earlier save did not reach disk.
        self.log_path.unlink()
        second = self.grant()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(self.flushes(), [["appops", "write-settings"]])
        self.assertEqual(self.overlay_states(), ["done"])
        self.assertEqual(self.saved(), "allow")

    def test_closed_receipt_restore_is_a_no_op(self):
        self.write_state({SERIAL: make_device(installed=True, perms=self.PERMS)})
        self.assertEqual(self.grant().returncode, 0)
        self.assertEqual(self.run_tool("restore", "--serial", SERIAL, "--apply").returncode, 0)
        self.log_path.unlink()
        again = self.run_tool("restore", "--serial", SERIAL, "--apply")
        self.assertEqual(again.returncode, provision.EXIT_REFUSED)
        self.assertEqual(self.mutating_commands(), [])


class AuditRegressionTests(ProvisionTestCase):
    def test_verify_expected_signer_before_any_success_output(self):
        apk = self.apk()
        fake_tools = self.tmp / "tools"
        fake_tools.mkdir()
        aapt2 = fake_tools / "aapt2"
        aapt2.symlink_to(FAKE_AAPT2)
        signer = fake_tools / "apksigner"
        signer.write_text("#!/bin/sh\nprintf 'Signer #1 certificate SHA-256 digest: %s\\n' " + "a" * 64 + "\n")
        signer.chmod(0o700)
        env = {"SETBEAM_AAPT2": str(aapt2), "SETBEAM_SKIP_APKSIGNER": "0"}
        for output in ((), ("--json",)):
            wrong = self.run_tool("verify-apk", "--apk", apk, "--expect-signer", "b" * 64, *output, env_extra=env)
            self.assertEqual(wrong.returncode, provision.EXIT_REFUSED, wrong.stderr)
            self.assertEqual(wrong.stdout, "")
            right = self.run_tool("verify-apk", "--apk", apk, "--expect-signer", "A" * 64, *output, env_extra=env)
            self.assertEqual(right.returncode, 0, right.stderr)
        self.assertEqual(self.log(), [])

    def test_install_uses_the_inspected_bytes_after_source_replacement(self):
        apk = Path(self.apk())
        original = json.dumps({"replace_original": str(apk)})
        apk.write_text(original)
        result = self.provision("--apk", str(apk), "--no-set-home", "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["installed_bytes"], original)
        self.assertNotEqual(apk.read_text(), original)

    def test_unreadable_package_state_stays_unknown_and_prevents_restore_writes(self):
        self.assertEqual(self.provision("--apk", self.apk(), "--apply").returncode, 0)
        original_receipt = self.receipt_files()[0].read_text()
        device = self.dev()
        device["fail"] = {"pm path": {"rc": 1, "stderr": "bridge disconnected"},
                          "dumpsys package": {"rc": 1}}
        self.write_state({SERIAL: device})
        self.log_path.unlink()
        status = self.run_tool("status", "--serial", SERIAL, "--json")
        self.assertIsNone(json.loads(status.stdout)["package"]["installed"])
        self.assertEqual(self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver").returncode,
                         provision.EXIT_REFUSED)
        self.assertEqual(self.mutating_commands(), [])
        self.assertEqual(self.receipt_files()[0].read_text(), original_receipt)

    def test_boot_receiver_and_permission_are_required_before_apply(self):
        for missing in ("boot", "boot_granted"):
            with self.subTest(missing=missing):
                device = make_device(installed=True, perms=[provision.OVERLAY_PERMISSION, provision.BOOT_PERMISSION])
                device["packages"][PKG][missing] = False
                self.write_state({SERIAL: device})
                result = self.provision("--apply", "--no-set-home", "--allow-background-start")
                self.assertEqual(result.returncode, provision.EXIT_REFUSED)
                self.assertIn("BOOT_COMPLETED", result.stderr)
                self.assertEqual(self.mutating_commands(), [])

    def test_missing_or_changed_transport_prevents_writes(self):
        device = make_device(installed=True)
        device["omit_transport"] = True
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_DEVICE)
        del device["omit_transport"]
        device["change_after"] = {"command": "logcat -d", "update": {"transport_id": 9}}
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_DEVICE)
        self.assertIn("transport changed", result.stderr)
        self.assertEqual(self.mutating_commands(), [])

    def test_same_second_stale_ack_cannot_grant_home_or_overlay(self):
        device = make_device(installed=True)
        device.update(config_log="silent", clock=40,
                      logcat=[[41, "I", "Pairing accepted for http://setbeam.local/"]])
        self.write_state({SERIAL: device})
        result = self.provision("--apply")
        self.assertEqual(result.returncode, provision.EXIT_DEVICE)
        self.assertIn("acceptance was not observed", result.stderr)
        self.assertEqual([cmd[:2] for cmd in self.mutating_commands()], [["am", "start"]])
        self.assertEqual(self.dev()["role_holders"], ["com.example.tvlauncher"])

    def test_install_that_succeeds_with_wrong_version_remains_recoverable(self):
        self.write_state({SERIAL: make_device()}, install_package={"version_code": 6})
        result = self.provision("--apply", "--apk", self.apk())
        self.assertEqual(result.returncode, provision.EXIT_DEVICE)
        self.assertEqual(json.loads(self.receipt_files()[0].read_text())["changes"][0]["state"], "pending")
        self.assertEqual(self.provision("--apply").returncode, provision.EXIT_REFUSED)
        restore = self.run_tool("restore", "--serial", SERIAL, "--apply", "--uninstall-receiver")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertNotIn(PKG, self.dev()["packages"])


@unittest.skipUnless(shutil.which("true"), "posix")
class RealAapt2ManifestTests(unittest.TestCase):
    """Builds a resource-only APK with the SDK's real aapt2 when it is installed."""

    def setUp(self):
        self.aapt2 = None
        try:
            self.aapt2 = provision.find_aapt2(None)
        except provision.ToolError:
            pass
        platforms = []
        for root in provision.sdk_root_candidates():
            platforms += sorted((root / "platforms").glob("android-*/android.jar"))
        if not self.aapt2 or not platforms or "fake" in self.aapt2:
            self.skipTest("Android SDK build-tools and a platform are not installed")
        self.android_jar = platforms[-1]
        self.tmp = Path(tempfile.mkdtemp(prefix="setbeam-aapt2-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def build(self, home=True):
        home_filter = (
            '<intent-filter><action android:name="android.intent.action.MAIN"/>'
            '<category android:name="android.intent.category.HOME"/><category android:name="android.intent.category.DEFAULT"/></intent-filter>'
            if home
            else ""
        )
        manifest = self.tmp / "AndroidManifest.xml"
        manifest.write_text(
            f"""<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.setbeam.receiver" android:versionCode="9" android:versionName="0.1">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
  <application android:label="Setbeam Receiver">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LEANBACK_LAUNCHER"/></intent-filter>
      {home_filter}
    </activity>
    <activity android:name=".ProvisionActivity" android:exported="true" android:permission="android.permission.WRITE_SECURE_SETTINGS">
      <intent-filter><action android:name="com.setbeam.receiver.CONFIGURE"/><category android:name="android.intent.category.DEFAULT"/></intent-filter>
    </activity>
    <receiver android:name=".BootReceiver" android:exported="false">
      <intent-filter><action android:name="android.intent.action.BOOT_COMPLETED"/></intent-filter>
    </receiver>
  </application>
</manifest>
"""
        )
        apk = self.tmp / ("home.apk" if home else "nohome.apk")
        subprocess.run([self.aapt2, "link", "-o", str(apk), "--manifest", str(manifest), "-I", str(self.android_jar)], check=True, capture_output=True)
        return str(apk)

    def test_real_aapt2_output_is_understood(self):
        previous = os.environ.get("SETBEAM_SKIP_APKSIGNER")
        os.environ["SETBEAM_SKIP_APKSIGNER"] = "1"
        self.addCleanup(lambda: os.environ.pop("SETBEAM_SKIP_APKSIGNER") if previous is None else os.environ.__setitem__("SETBEAM_SKIP_APKSIGNER", previous))
        info = provision.verify_apk(self.build(), self.aapt2, provision.Out())
        self.assertEqual(info["version_code"], 9)
        self.assertTrue(info["requests_overlay"])
        self.assertTrue(info["boot_receiver"])
        self.assertEqual(info["configure_handler"]["name"], "com.setbeam.receiver.ProvisionActivity")
        self.assertEqual(info["configure_handler"]["permission"], "android.permission.WRITE_SECURE_SETTINGS")
        with self.assertRaises(provision.ToolError):
            provision.verify_apk(self.build(home=False), self.aapt2, provision.Out())


if __name__ == "__main__":
    unittest.main()
