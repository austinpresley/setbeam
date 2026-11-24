"""Receiver driver regressions with in-memory ADB and process fixtures."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import tv_e2e as e2e
import tv_emulator as emulator
sys.path.pop(0)


class DriverTests(unittest.TestCase):
    def test_recognizes_a_diagnostic_phase_without_adjacent_admission_ocr(self):
        self.assertEqual(e2e.diagnostic_phase("SAMPLE MEDIA\nPhase waiting   admis.1.238/"), "waiting")
        self.assertEqual(e2e.diagnostic_phase("Phase asking again   admission none"), "asking again")
        self.assertIsNone(e2e.diagnostic_phase("Session Phase live\nPhase unknown"))

    def run_fixture(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        run = e2e.Run.__new__(e2e.Run)
        run.args = SimpleNamespace(cases=["startup-home"], uninstall=True)
        run.artifacts = Path(temporary.name)
        run.server = mock.Mock()
        run.device = mock.Mock()
        run.device.receiver_installed.return_value = False
        run.fixture = mock.Mock(tag="A")
        run.second = mock.Mock(tag="B")
        run.fixture.stop.return_value = run.second.stop.return_value = "not started"
        run.log = mock.Mock()
        run.results, run.facts = [], {}
        run.settings_before = None
        run.changed_settings = set()
        run.setup_started = False
        run.install_started = False
        run.startup_restore = None
        return run

    def test_bad_preflight_never_calls_setup_recovery_capture_or_restore(self):
        run = self.run_fixture()
        run.preflight = mock.Mock(side_effect=e2e.Failure("fixture failed before device setup"))
        run.setup = mock.Mock()
        run.recover_baseline = mock.Mock()
        run.c_startup = mock.Mock()
        self.assertEqual(run.execute(), 1)
        self.assertEqual(run.device.mock_calls, [])
        for action in (run.setup, run.recover_baseline, run.c_startup):
            action.assert_not_called()
        run.server.stop.assert_called_once()
        summary = json.loads((run.artifacts / "summary.json").read_text())
        self.assertEqual(summary["missingOrFailedCases"], ["startup-home"])

    def test_unexecuted_case_cannot_pass_summary(self):
        run = self.run_fixture()
        run.execute_cases = mock.Mock(return_value=True)
        self.assertEqual(run.execute(), 1)
        summary = json.loads((run.artifacts / "summary.json").read_text())
        self.assertFalse(summary["ok"])

    def test_skip_startup_only_excludes_implicit_case(self):
        for invalid in ("", "all,configure", "unknown", "configure,", "configure,configure", "startup-home"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                e2e.parse_cases(invalid, skip_startup=True)
        self.assertNotIn("startup-home", e2e.parse_cases("all", skip_startup=True))
        self.assertEqual(e2e.parse_cases("startup-home", skip_startup=False), ["startup-home"])

    def test_cleanup_restores_captured_overrides_even_if_startup_restore_fails(self):
        run = self.run_fixture()
        run.setup_started = True
        run.settings_before = {"wm/size": "1600x900", "wm/density": None, "airplane": "enabled",
                               "secure/screensaver_enabled": "null"}
        run.changed_settings = set(run.settings_before)
        run.device.settings_snapshot.return_value = run.settings_before
        run.facts["homeBefore"] = run.device.home_state.return_value
        run.facts["appopBefore"] = None
        run.startup_restore = mock.sentinel.receipt
        run.restore_startup = mock.Mock(side_effect=e2e.Failure("HOME journal stays open"))
        run.install_started = True
        self.assertEqual(run.restore_device(), ["startup restore: HOME journal stays open"])
        self.assertEqual(run.device.sh.call_args_list, [
            mock.call("wm size 1600x900"),
            mock.call("wm density reset"),
            mock.call("cmd connectivity airplane-mode enable"),
        ])
        run.device.put_setting.assert_called_once_with("secure/screensaver_enabled", "null")
        run.device.adb.assert_not_called()

    def test_startup_failure_restores_before_return_and_never_reboots(self):
        run = self.run_fixture()
        run.args.serial = "emulator-5574"
        run.args.provision_tool = e2e.PROVISION
        run.name = "Test TV"
        run.appop = mock.Mock(return_value="default")
        run.facts.update(homeBefore=run.device.home_state.return_value, appopBefore=None)
        run.restore_startup = mock.Mock()
        run.boot_check = mock.Mock()
        run.run_provision = mock.Mock(side_effect=[SimpleNamespace(returncode=0), SimpleNamespace(returncode=4)])
        with self.assertRaisesRegex(e2e.Failure, "Provisioning exited"):
            run.c_startup()
        run.restore_startup.assert_called_once()
        run.boot_check.assert_not_called()

    def test_changed_transport_or_user_forbids_command(self):
        with tempfile.TemporaryDirectory() as directory:
            server = mock.Mock()
            device = e2e.Device("emulator-5574", mock.Mock(), Path(directory), server)
            device.transport, device.identity, device.user, device.boot_id = "8", {}, 0, "boot"
            with mock.patch.object(e2e, "transport_id", return_value="9"):
                with self.assertRaisesRegex(e2e.Failure, "transport changed"):
                    device.sh("input keyevent 3")
            with mock.patch.object(e2e, "transport_id", return_value="8"),                     mock.patch.object(device, "read_identity", return_value=({}, 10, "boot")):
                with self.assertRaisesRegex(e2e.Failure, "user or boot changed"):
                    device.sh("input keyevent 3")
            server.run.assert_not_called()


class EmulatorLifecycleTests(unittest.TestCase):
    def test_stale_pid_with_other_session_is_never_signalled(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(emulator, "STATE", Path(directory)),                 mock.patch.object(emulator.os, "getpgid", return_value=123),                 mock.patch.object(emulator.os, "getsid", return_value=123),                 mock.patch.object(emulator.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stdout=f"{os.getuid()} unrelated command\n"
                )), mock.patch.object(emulator.os, "kill") as kill:
            emulator.save({"pid": 123, "serial": "emulator-5574", "port": 5574, "token": "a" * 32})
            self.assertEqual(emulator.stop(), 0)
            kill.assert_not_called()
            self.assertIsNone(emulator.load())

    def test_adb_timeout_during_boot_stops_supervisor_and_private_server(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(emulator, "STATE", Path(directory)),                 mock.patch.object(emulator, "avd_path_ok", return_value=True),                 mock.patch.object(emulator.socket, "socket"),                 mock.patch.object(emulator, "AdbServer") as server,                 mock.patch.object(emulator, "transport_id", return_value="1"),                 mock.patch.object(emulator.subprocess, "Popen") as popen:
            fake = popen.return_value
            fake.pid, fake.poll.return_value = 123, None
            server.return_value.env = {}
            server.return_value.run.side_effect = subprocess.TimeoutExpired("adb", 10)
            with self.assertRaises(subprocess.TimeoutExpired):
                emulator.start(5574, False, 20)
            fake.terminate.assert_called_once()
            fake.wait.assert_called_once()
            server.return_value.stop.assert_called_once()
            self.assertIsNone(emulator.load())

    def test_private_server_uses_bound_loopback_and_discards_inherited_routing(self):
        with tempfile.TemporaryDirectory() as directory,                 mock.patch.dict(os.environ, {"ANDROID_SERIAL": "other", "ADB_SERVER_SOCKET": "tcp:remote:5037",
                                            "ANDROID_ADB_SERVER_ADDRESS": "remote", "ANDROID_ADB_SERVER_PORT": "5037",
                                            "ADB_MDNS_AUTO_CONNECT": "adb", "SETBEAM_ADB": "/other/adb"}),                 mock.patch.object(emulator.socket, "socket") as sock,                 mock.patch.object(emulator.subprocess, "Popen") as popen,                 mock.patch.object(emulator.subprocess, "run") as client:
            listener = sock.return_value
            listener.fileno.return_value = 8
            popen.return_value.poll.return_value = None
            server = emulator.AdbServer(5137, Path(directory), 5574)
            server.start()
            listener.bind.assert_called_once_with(("127.0.0.1", 5137))
            self.assertEqual(popen.call_args.kwargs["pass_fds"], (8,))
            self.assertIn("acceptfd:8", popen.call_args.args[0])
            self.assertEqual(client.call_args.args[0][1:5], ["-H", "127.0.0.1", "-P", "5137"])
            self.assertEqual(server.env["ADB_SERVER_SOCKET"], "tcp:127.0.0.1:5137")
            self.assertEqual(server.env["ADB_MDNS_AUTO_CONNECT"], "0")
            for key in ("ANDROID_SERIAL", "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_ADB_SERVER_PORT"):
                self.assertNotIn(key, server.env)
            listener.close.assert_not_called()
            server.stop()
            listener.close.assert_called_once()
