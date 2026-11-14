"""Feed and release-note rules for scripts/release.py. Signing is stubbed here; staging runs the real signer."""
import importlib.util
import tempfile
import types
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
NS = {"sparkle": release.SPARKLE_NS}


def args(build):
    return types.SimpleNamespace(version="0.2.0", build=build)


class FeedTests(unittest.TestCase):
    def write(self, folder, build, previous=None):
        path = Path(folder) / f"appcast-{build}.xml"
        url = f"https://github.com/austinpresley/setbeam/releases/download/v0.2.0-build{build}/Setbeam-0.2.0-build{build}.dmg"
        with mock.patch.object(release, "run") as run:
            release.write_feed(path, previous, args(build), url, f"sig{build}==", 1234, "<p>Notes</p>")
        self.assertEqual(run.call_count, 2, "the feed is signed and then verified")
        return path

    def test_first_feed_has_one_signed_arm64_item(self):
        with tempfile.TemporaryDirectory() as folder:
            root = ET.parse(self.write(folder, 41)).getroot()
            items = root.findall("channel/item")
            self.assertEqual(len(items), 1)
            item = items[0]
            self.assertEqual(item.findtext("sparkle:version", namespaces=NS), "41")
            self.assertEqual(item.findtext("sparkle:hardwareRequirements", namespaces=NS), "arm64")
            self.assertEqual(item.findtext("sparkle:minimumSystemVersion", namespaces=NS), "14.0")
            enclosure = item.find("enclosure")
            self.assertEqual(enclosure.get("url"), "https://github.com/austinpresley/setbeam/releases/download/v0.2.0-build41/Setbeam-0.2.0-build41.dmg")
            self.assertEqual(enclosure.get(f"{{{release.SPARKLE_NS}}}edSignature"), "sig41==")
            self.assertEqual(enclosure.get("length"), "1234")

    def test_new_item_comes_first_and_earlier_items_remain(self):
        with tempfile.TemporaryDirectory() as folder:
            first = self.write(folder, 41).read_text() + "<!-- sparkle-signatures:\nedSignature: old\n-->\n"
            root = ET.parse(self.write(folder, 42, previous=first)).getroot()
            versions = [i.findtext("sparkle:version", namespaces=NS) for i in root.findall("channel/item")]
            self.assertEqual(versions, ["42", "41"])
            self.assertEqual(len(root.findall("channel/title")), 1)

    def test_republishing_a_build_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            first = self.write(folder, 41).read_text()
            with self.assertRaises(release.ReleaseError):
                self.write(folder, 41, previous=first)


class NotesTests(unittest.TestCase):
    def test_notes_render_headings_bullets_links_and_escape_markup(self):
        rendered = release.notes_html(
            "# Setbeam 0.2.0 build 41\n\n## Install\n\nOpen the disk image.\n\n"
            "- Drag Setbeam to Applications.\n- See [the guide](https://example.com/g) <b>now</b>.\n")
        self.assertNotIn("Setbeam 0.2.0 build 41", rendered)
        self.assertIn("<h3>Install</h3>", rendered)
        self.assertIn("<p>Open the disk image.</p>", rendered)
        self.assertIn('<li>See <a href="https://example.com/g">the guide</a> &lt;b&gt;now&lt;/b&gt;.</li>', rendered)

    def test_non_https_links_stay_text(self):
        self.assertNotIn("<a ", release.notes_html("# T\n\n[x](http://example.com)\n"))


if __name__ == "__main__":
    unittest.main()
