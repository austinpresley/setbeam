"""Offline release tests with temporary Git repositories and stubbed platform tools."""
import base64
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    library = importlib.util.module_from_spec(spec)
    sys.modules[name] = library
    spec.loader.exec_module(library)
    return library


publish = load("publish", "publish-release.py")
release = publish.release
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

    def test_older_build_than_the_published_feed_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            newer = self.write(folder, 43).read_text()
            with self.assertRaises(release.ReleaseError):
                self.write(folder, 42, previous=newer)


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


class OriginTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.repo = Path(folder.name) / "source"
        self.origin = Path(folder.name) / "origin"
        self.git("init", "-q", self.repo)
        self.git("init", "-q", "--bare", self.origin)
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "commit.gpgsign", "false")
        self.git("remote", "add", "origin", self.origin)
        self.git("commit", "--allow-empty", "-qm", "source")
        self.source = self.git("rev-parse", "HEAD").decode().strip()
        # Seed the fake origin locally; the only push exercised is the Pages push.
        self.git("--git-dir", self.origin, "fetch", "-q", self.repo, f"{self.source}:refs/heads/main")
        for module in (publish, release):
            patched = mock.patch.object(module, "ROOT", self.repo)
            patched.start()
            self.addCleanup(patched.stop)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", self.repo.parent if not self.repo.exists() else self.repo, *args])

    def manifest(self, snapshot):
        return {"previousFeedCommit": snapshot.tip, "previousFeedSHA256": snapshot.digest, "tag": "v0.2.0-build42"}

    def remote_tip(self):
        return release.remote_refs(release.PAGES_REF).get(release.PAGES_REF)

    def test_missing_and_unreachable_origin_are_distinct(self):
        self.assertIsNone(release.published_feed().tip)
        self.git("remote", "set-url", "origin", self.origin / "missing")
        with self.assertRaises(release.ReleaseError):
            release.published_feed()

    def test_uses_origin_heads_and_remote_peeled_tag(self):
        release.verify_origin_commit(self.source)
        self.git("commit", "--allow-empty", "-qm", "local only")
        local = self.git("rev-parse", "HEAD").decode().strip()
        self.git("update-ref", "refs/remotes/other/main", local)
        self.git("update-ref", "refs/remotes/origin/main", local)
        with self.assertRaisesRegex(release.ReleaseError, "origin branch"):
            release.verify_origin_commit(local)
        tag = "v0.2.0-build42"
        self.assertFalse(release.verify_tag(tag, self.source))
        self.git("tag", "-a", "-m", "annotation", tag, self.source)
        self.git("--git-dir", self.origin, "fetch", "-q", self.repo, f"refs/tags/{tag}:refs/tags/{tag}")
        self.assertTrue(release.verify_tag(tag, self.source))
        with self.assertRaisesRegex(release.ReleaseError, "different commit"):
            release.verify_tag(tag, local)

    def test_wrong_push_url_fails_before_remote_access(self):
        self.git("remote", "set-url", "origin", f"https://github.com/{release.REPOSITORY}.git")
        release.check_origin()
        self.git("remote", "set-url", "--push", "origin", "https://github.com/example/setbeam.git")
        with self.assertRaises(release.ReleaseError):
            release.check_origin()

    def feed(self, *builds, newline="\n"):
        items = "".join(f"<item><sparkle:version>{build}</sparkle:version></item>" for build in builds)
        content = f'<rss xmlns:sparkle="{release.SPARKLE_NS}"><channel>{items}</channel></rss>{newline}'.encode()
        signature = base64.b64encode(b"a" * 64).decode()
        return content + f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n".encode()

    def test_normal_push_uses_validated_parent_and_exact_bytes(self):
        empty = release.published_feed()
        original = self.feed(41, newline="\r\n")
        publish.push_feed(original, self.manifest(empty), empty)
        first = release.published_feed()
        self.assertEqual(first.feed, original)
        updated = self.feed(42, 41)
        self.assertEqual(publish.feed_state(updated, self.manifest(first)), ("ready", first))
        publish.push_feed(updated, self.manifest(first), first)
        latest = release.published_feed()
        self.assertEqual(latest.feed, updated)
        self.assertEqual(self.git("rev-parse", latest.tip + "^").decode().strip(), first.tip)
        self.assertEqual(publish.feed_state(updated, self.manifest(first)), ("published", latest))

    def test_rewind_after_precheck_is_rejected_even_though_push_would_fast_forward(self):
        empty = release.published_feed()
        publish.push_feed(self.feed(40), self.manifest(empty), empty)
        older = release.published_feed()
        publish.push_feed(self.feed(41, 40), self.manifest(older), older)
        staged = release.published_feed()
        self.assertEqual(publish.feed_state(self.feed(42, 41, 40), self.manifest(staged))[0], "ready")
        self.git("--git-dir", self.origin, "update-ref", release.PAGES_REF, older.tip)
        with self.assertRaisesRegex(publish.PublishError, "Pages ref changed during push"):
            publish.push_feed(b"candidate", self.manifest(staged), staged)
        self.assertEqual(self.remote_tip(), older.tip)

    def test_remote_change_after_ref_advertisement_is_rejected_by_receive_pack(self):
        empty = release.published_feed()
        publish.push_feed(self.feed(40), self.manifest(empty), empty)
        older = release.published_feed()
        publish.push_feed(self.feed(41, 40), self.manifest(older), older)
        staged = release.published_feed()
        hook = self.origin / "hooks/pre-receive"
        hook.write_text(f"#!/bin/sh\nunset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES\ngit update-ref {release.PAGES_REF} {older.tip}\n")
        hook.chmod(0o700)
        with self.assertRaisesRegex(publish.PublishError, "cannot lock ref"):
            publish.push_feed(self.feed(42, 41, 40), self.manifest(staged), staged)
        self.assertEqual(self.remote_tip(), older.tip)

    def test_candidate_cannot_drop_published_items_on_unchanged_ref(self):
        empty = release.published_feed()
        publish.push_feed(self.feed(41), self.manifest(empty), empty)
        staged = release.published_feed()
        with self.assertRaisesRegex(publish.PublishError, "dropped published"):
            publish.feed_state(self.feed(42), self.manifest(staged))

    def test_deletion_after_precheck_is_rejected(self):
        empty = release.published_feed()
        publish.push_feed(b"old", self.manifest(empty), empty)
        staged = release.published_feed()
        self.git("--git-dir", self.origin, "update-ref", "-d", release.PAGES_REF)
        with self.assertRaisesRegex(publish.PublishError, "Pages ref changed during push"):
            publish.push_feed(b"candidate", self.manifest(staged), staged)
        self.assertIsNone(self.remote_tip())

    def test_same_feed_bytes_on_different_commit_are_stale(self):
        empty = release.published_feed()
        publish.push_feed(b"old", self.manifest(empty), empty)
        staged = release.published_feed()
        publish.push_feed(b"old", self.manifest(staged), staged)
        with self.assertRaisesRegex(publish.PublishError, "changed after staging"):
            publish.feed_state(b"new", self.manifest(staged))

    def test_existing_branch_without_appcast_is_not_first_release(self):
        self.git("--git-dir", self.origin, "update-ref", release.PAGES_REF, self.source)
        with self.assertRaises(release.ReleaseError):
            release.published_feed()


class CandidateTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.candidate = Path(folder.name)
        self.tag = "v0.2.0-build42"
        self.dmg = self.candidate / "Setbeam-0.2.0-build42.dmg"
        self.dmg.write_bytes(b"test artifact")
        self.sig = base64.b64encode(b"a" * 64).decode()
        self.manifest = {"build": 42, "version": "0.2.0", "tag": self.tag, "edSignature": self.sig,
                         "dmg": self.dmg.name, "bytes": self.dmg.stat().st_size, "sha256": release.sha256(self.dmg)}
        self.config = {"SUPublicEDKey": "fixture public key"}
        self.url = f"https://github.com/{release.REPOSITORY}/releases/download/{self.tag}/{self.dmg.name}"
        feed = self.candidate / "appcast.xml"
        with mock.patch.object(release, "run"):
            release.write_feed(feed, None, args(42), self.url, self.sig, self.manifest["bytes"], "Notes")
        self.content = feed.read_bytes()

    def signed(self, content, size=None):
        return content + (f"<!-- sparkle-signatures:\nedSignature: {self.sig}\n"
                          f"length: {len(content) if size is None else size}\n-->\n").encode()

    def test_checks_exact_feed_and_enclosure_with_configured_public_key(self):
        def verify(command):
            self.assertEqual(command[2], self.config["SUPublicEDKey"])
            self.assertEqual(command[3].read_bytes(), self.content)
            self.assertEqual(command[4:], [self.sig, self.dmg, self.sig])
        with mock.patch.object(release, "run", side_effect=verify) as run:
            self.assertEqual(release.verify_update(self.signed(self.content), self.dmg, self.manifest, self.config), self.url)
        run.assert_called_once()

    def test_wrong_length_version_or_enclosure_fails_before_crypto(self):
        for invalid in (
                self.signed(self.content, 1),
                self.signed(self.content.replace(b'length="13"', b'length="5"')),
                self.signed(self.content.replace(b'>0.2.0<', b'>1.2.0<')),
                self.signed(self.content.replace(self.url.encode(), b'https://example.com/other.dmg') +
                            b"<!-- " + self.url.encode() + b" -->"),
                self.signed(self.content.replace(b'<enclosure ', b'<enclosure/><enclosure ')),
                self.signed(self.content) + b"<!-- unsigned tail -->",
        ):
            with self.subTest(invalid=invalid), mock.patch.object(release, "run") as run:
                with self.assertRaises(release.ReleaseError):
                    release.verify_update(invalid, self.dmg, self.manifest, self.config)
                run.assert_not_called()

    def test_crypto_failure_stops_candidate(self):
        with mock.patch.object(release, "run", side_effect=release.ReleaseError("bad signature")):
            with self.assertRaisesRegex(release.ReleaseError, "bad signature"):
                release.verify_update(self.signed(self.content), self.dmg, self.manifest, self.config)

    def test_manifest_and_checksum_cannot_override_artifact_length(self):
        config = self.candidate / "config.plist"
        config.write_bytes(plistlib.dumps({"SUFeedURL": "https://example.com/appcast.xml"}))
        manifest = dict(self.manifest, certificateSHA1="A" * 40, commit="1" * 40,
                        feedURL="https://example.com/appcast.xml")
        (self.candidate / "release-notes.md").write_text("Notes")
        self.dmg.write_bytes(b"other disk image")
        manifest["sha256"] = release.sha256(self.dmg)
        (self.candidate / "SHA256SUMS-build42.txt").write_text(f"{manifest['sha256']}  {self.dmg.name}\n")
        with mock.patch.object(release, "UPDATE_CONFIG", config), mock.patch.object(publish, "run") as run:
            with self.assertRaisesRegex(publish.PublishError, "length or digest"):
                publish.verify_candidate(self.candidate, manifest)
        run.assert_not_called()

    def test_verify_only_never_enters_publication(self):
        (self.candidate / "manifest.json").write_text(json.dumps(self.manifest))
        with mock.patch.object(sys, "argv", ["publish-release.py", str(self.candidate), "--verify-only"]), \
             mock.patch.object(publish, "verify_candidate", return_value=(self.dmg, None, self.content, self.url)), \
             mock.patch.object(publish, "feed_state", return_value=("ready", None)), \
             mock.patch.object(publish, "ensure_release") as assets, mock.patch.object(publish, "publish_feed") as feed:
            self.assertEqual(publish.main(), 0)
            assets.assert_not_called()
            feed.assert_not_called()

    def test_partial_prerelease_verifies_existing_asset_then_uploads_missing_checksum(self):
        self.manifest["commit"] = "1" * 40
        sums = self.candidate / "SHA256SUMS-build42.txt"
        sums.write_bytes(b"test checksum")
        details = {"isDraft": False, "assets": [{"name": self.dmg.name, "state": "uploaded", "size": self.dmg.stat().st_size}]}
        calls = mock.Mock()
        with mock.patch.object(publish, "existing_release", return_value=details), \
             mock.patch.object(release, "verify_tag"), mock.patch.object(publish, "anonymous_download", calls.download), \
             mock.patch.object(publish, "run", calls.gh):
            publish.ensure_release(self.candidate, self.manifest, self.dmg, sums, self.url)
        self.assertEqual(calls.mock_calls, [
            mock.call.download(self.url, self.manifest["sha256"]),
            mock.call.gh(["gh", "release", "upload", self.tag, "--repo", publish.GH_REPOSITORY, sums]),
            mock.call.download(self.url.rsplit("/", 1)[0] + "/" + sums.name, release.sha256(sums)),
        ])

    def test_draft_prerelease_resumes_after_one_upload_then_verifies_public_downloads(self):
        self.manifest["commit"] = "1" * 40
        sums = self.candidate / "SHA256SUMS-build42.txt"
        sums.write_bytes(b"test checksum")
        draft = {"isDraft": True, "assets": [{"name": self.dmg.name, "state": "uploaded",
                                              "size": self.dmg.stat().st_size}]}
        calls = mock.Mock()
        checksum_url = self.url.rsplit("/", 1)[0] + "/" + sums.name
        sums_digest = release.sha256(sums)
        with mock.patch.object(publish, "existing_release", side_effect=[draft, {"isDraft": False}]), \
             mock.patch.object(release, "verify_tag"), mock.patch.object(publish, "draft_download", calls.draft), \
             mock.patch.object(publish, "anonymous_download", calls.download), mock.patch.object(publish, "run", calls.gh):
            publish.ensure_release(self.candidate, self.manifest, self.dmg, sums, self.url)
        self.assertEqual(calls.mock_calls, [
            mock.call.draft(self.tag, self.dmg.name, self.manifest["sha256"]),
            mock.call.gh(["gh", "release", "upload", self.tag, "--repo", publish.GH_REPOSITORY, sums]),
            mock.call.draft(self.tag, sums.name, sums_digest),
            mock.call.gh(["gh", "release", "edit", self.tag, "--repo", publish.GH_REPOSITORY, "--draft=false", "--prerelease"]),
            mock.call.download(self.url, self.manifest["sha256"]),
            mock.call.download(checksum_url, sums_digest),
        ])

    def test_feed_refresh_preserves_original_dmg_and_candidate(self):
        (self.candidate / "release-notes.md").write_text("# Release\nDetails.")
        (self.candidate / "manifest.json").write_text(json.dumps(self.manifest))
        output_root = tempfile.TemporaryDirectory()
        self.addCleanup(output_root.cleanup)
        output = Path(output_root.name) / "refreshed"
        config = Path(output_root.name) / "config.plist"
        config.write_bytes(plistlib.dumps(self.config))
        prior = self.content.replace(b">42<", b">41<")
        snapshot = release.FeedSnapshot("f" * 40, self.signed(prior))
        with mock.patch.object(release, "published_feed", return_value=snapshot), \
             mock.patch.object(release, "UPDATE_CONFIG", config), mock.patch.object(release, "run"), \
             mock.patch.object(release, "verify_update"):
            publish.refresh_feed(self.candidate, output, self.manifest, self.dmg, self.url)
        self.assertEqual((output / self.dmg.name).read_bytes(), self.dmg.read_bytes())
        refreshed = json.loads((output / "manifest.json").read_bytes())
        self.assertEqual(refreshed["previousFeedCommit"], snapshot.tip)
        self.assertEqual(refreshed["previousFeedSHA256"], snapshot.digest)
        self.assertEqual(release.feed_items((output / "appcast.xml").read_bytes())[2], [42, 41])
        self.assertEqual(json.loads((self.candidate / "manifest.json").read_bytes()), self.manifest)

    def test_conflicting_asset_stops_without_upload(self):
        self.manifest["commit"] = "1" * 40
        sums = self.candidate / "SHA256SUMS-build42.txt"
        sums.write_bytes(b"test checksum")
        details = {"isDraft": False, "assets": [{"name": self.dmg.name, "state": "uploaded", "size": self.dmg.stat().st_size}]}
        with mock.patch.object(publish, "existing_release", return_value=details), \
             mock.patch.object(publish, "run") as run, \
             mock.patch.object(publish, "anonymous_download", side_effect=publish.PublishError("digest mismatch")):
            with self.assertRaisesRegex(publish.PublishError, "digest mismatch"):
                publish.ensure_release(self.candidate, self.manifest, self.dmg, sums, self.url)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
