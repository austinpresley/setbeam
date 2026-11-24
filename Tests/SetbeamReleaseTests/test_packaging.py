"""Exercise packaging decisions without compiling, signing, or opening an app."""
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_release import load


build = load("support", "build-support.py")
audit = load("audit", "audit-app.py")


class CacheTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        patch = mock.patch.object(build, "CACHE", self.cache)
        patch.start()
        self.addCleanup(patch.stop)
        target = self.root / "upstream"
        target.write_bytes(b"good")
        self.item = {"archive": "a.tar.gz", "sha256": build.digest(target), "url": "https://example.com/a.tar.gz"}

    def test_failed_download_leaves_no_partial_cache_entry(self):
        def corrupt(command, check):
            command[-1].write_bytes(b"partial")
        with mock.patch.object(build.subprocess, "run", side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                build.verified_archive(self.item)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_cache_replaces_corrupt_archive_only_after_hash_matches(self):
        target = self.cache / self.item["archive"]
        target.write_bytes(b"old corrupt file")

        def download(command, check):
            self.assertEqual(target.read_bytes(), b"old corrupt file")
            command[-1].write_bytes(b"good")

        with mock.patch.object(build.subprocess, "run", side_effect=download):
            self.assertEqual(build.verified_archive(self.item), target)
        self.assertEqual(target.read_bytes(), b"good")
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.cache.iterdir()), [target])

    def test_patch_and_configure_option_bytes_change_runtime_inputs(self):
        with mock.patch.object(build, "ROOT", self.root), \
             mock.patch.object(build.subprocess, "check_output", return_value="fixture tool version"):
            for entry in build.INPUTS:
                target = self.root / entry
                target.parent.mkdir(exist_ok=True)
                target.write_text("base")
            original = build.build_inputs()
            (self.root / "scripts/patch-avfoundation.py").write_text("changed patch")
            patched = build.build_inputs()
            (self.root / "scripts/build-runtime.sh").write_text("changed flags")
            options = build.build_inputs()
        self.assertNotEqual(original, patched)
        self.assertNotEqual(patched, options)

    def test_atomic_exchange_replaces_entire_app_directory(self):
        source = self.root / "app.next"
        target = self.root / "Setbeam.app"
        source.mkdir()
        target.mkdir()
        (target / "old").touch()
        (source / "new").touch()
        build.install_app(source, target)
        self.assertEqual([path.name for path in target.iterdir()], ["new"])
        self.assertEqual([path.name for path in source.iterdir()], ["old"])


class PackageAuditTests(unittest.TestCase):
    def test_missing_required_binary_fails_before_signature_verification(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(audit, "command") as command:
            app = Path(folder) / "Setbeam.app"
            contents = app / "Contents"
            for name in audit.REQUIRED - {"Helpers/ffprobe"}:
                path = contents / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture")
            (contents / "Info.plist").write_bytes(audit.plistlib.dumps({
                "CFBundleIdentifier": "app.setbeam.mac", "CFBundleExecutable": "Setbeam",
                "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
            }))
            with self.assertRaisesRegex(ValueError, "Helpers/ffprobe"):
                audit.audit(app, "-")
        command.assert_not_called()

    def test_runtime_paths_and_minimum_macos_fail_closed(self):
        helper = Path("/ignore/Setbeam.app/Contents/Helpers/ffmpeg")
        metadata = "Load command 1\n      cmd LC_BUILD_VERSION\n platform MACOS\n    minos 14.0\n"
        system = f"{helper}:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
        with mock.patch.object(audit, "command", side_effect=[metadata, system]):
            self.assertEqual(audit.audit_slice(helper, "Helpers/ffmpeg", "arm64"), "14.0")
        with mock.patch.object(audit, "command", return_value=metadata.replace("14.0", "15.0")):
            with self.assertRaisesRegex(ValueError, "deployment target"):
                audit.audit_slice(helper, "Helpers/ffmpeg", "arm64")
        with mock.patch.object(audit, "command", return_value=metadata +
                               "Load command 2\n      cmd LC_RPATH\n path /opt/homebrew/lib (offset 12)\n"):
            with self.assertRaisesRegex(ValueError, "search path outside"):
                audit.audit_slice(helper, "Helpers/ffmpeg", "arm64")
        with mock.patch.object(audit, "command", side_effect=[metadata, system.replace("/usr/lib", "/opt/homebrew/lib")]):
            with self.assertRaisesRegex(ValueError, "unexpected dependency"):
                audit.audit_slice(helper, "Helpers/ffmpeg", "arm64")
