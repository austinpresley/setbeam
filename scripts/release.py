#!/usr/bin/env python3
"""Stage a notarized, updatable Setbeam release candidate. Publishes nothing.

Builds with Developer ID and the hardened runtime, audits every executable,
notarizes and staples the app and its DMG, and writes a signed Sparkle feed that
keeps earlier published items. Publish the staged candidate with publish-release.py.
"""
import argparse
import base64
import email.utils
from contextlib import contextmanager, suppress
from dataclasses import dataclass
import hashlib
import html
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
UPDATE_CONFIG = ROOT / "scripts/signing/update-configuration.plist"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "austinpresley/setbeam"
KEY_ACCOUNT = "Setbeam"
TEAM = "G2R8798RLT"
PAGES_BRANCH = "gh-pages"
PAGES_REF = f"refs/heads/{PAGES_BRANCH}"
OID = r"[0-9a-f]{40}"
FINGERPRINT = r"[0-9A-F]{40}"
ZERO_OID = "0" * 40


class ReleaseError(Exception):
    pass


def run(args, log=None, check=True):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if log:
        Path(log).write_text(result.stdout + result.stderr)
    if check and result.returncode != 0:
        raise ReleaseError(f"{Path(str(args[0])).name} {args[1] if len(args) > 1 else ''} failed:\n"
                           f"{(result.stdout + result.stderr).strip()[-2000:]}")
    return result


def git(*args, **kwargs):
    return run(["git", "-C", ROOT, *args], **kwargs)


def git_bytes(*args):
    result = subprocess.run(["git", "-C", ROOT, *args], capture_output=True)
    if result.returncode:
        raise ReleaseError(f"Could not read Git object {args[-1]}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def check_origin():
    allowed = {f"https://github.com/{REPOSITORY}{suffix}" for suffix in ("", ".git")}
    allowed.update({f"git@github.com:{REPOSITORY}.git", f"ssh://git@github.com/{REPOSITORY}.git"})
    for options in (["--all"], ["--push", "--all"]):
        urls = git("remote", "get-url", *options, "origin").stdout.splitlines()
        if len(urls) != 1 or urls[0] not in allowed:
            raise ReleaseError(f"Origin must fetch and push to {REPOSITORY}.")


def remote_refs(*patterns):
    rows = git("ls-remote", "origin", *patterns).stdout.splitlines()
    refs = {}
    for row in rows:
        oid, ref = row.split("\t", 1)
        if not re.fullmatch(OID, oid) or ref in refs:
            raise ReleaseError("Invalid origin ref listing.")
        refs[ref] = oid
    return refs


def fetch_objects(*oids):
    missing = [oid for oid in set(oids) if git("cat-file", "-e", oid, check=False).returncode]
    if missing:
        git("fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "origin", *missing)


def verify_origin_commit(commit):
    if not re.fullmatch(OID, commit):
        raise ReleaseError("Invalid source commit.")
    heads = {oid for ref, oid in remote_refs("refs/heads/*").items()
             if ref.startswith("refs/heads/") and ref != PAGES_REF}
    fetch_objects(*heads)
    if git("cat-file", "-t", commit, check=False).stdout.strip() != "commit" or not any(
        git("merge-base", "--is-ancestor", commit, tip, check=False).returncode == 0 for tip in heads
    ):
        raise ReleaseError(f"Push source commit {commit} to an origin branch first.")


def verify_tag(tag, commit, required=False):
    ref = f"refs/tags/{tag}"
    refs = remote_refs(ref, ref + "^{}")
    if ref not in refs:
        if required:
            raise ReleaseError(f"Origin tag {tag} is missing.")
        return False
    if refs.get(ref + "^{}", refs[ref]) != commit:
        raise ReleaseError(f"Origin tag {tag} points to a different commit.")
    return True


def release_tag(version, build):
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ReleaseError("Use a three-part numeric version.")
    if type(build) is not int or build < 1:
        raise ReleaseError("Use a positive integer build number.")
    return f"v{version}-build{build}"


def clean_head():
    if git("status", "--porcelain", "--untracked-files=all").stdout:
        raise ReleaseError("Release staging requires a clean checkout, including untracked files.")
    return git("rev-parse", "HEAD").stdout.strip()


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def developer_id(requested):
    found = re.findall(r'\b([A-F0-9]{40}) "(Developer ID Application:[^"]+\(' + TEAM + r'\))"',
                       run(["security", "find-identity", "-v", "-p", "codesigning"]).stdout)
    if requested:
        found = [f for f in found if requested in f]
    if len(found) != 1:
        raise ReleaseError(f"Expected one valid Developer ID Application identity for team {TEAM}; found {len(found)}.")
    return found[0]


def preflight(args):
    """Every check that needs no build and changes nothing."""
    tag = release_tag(args.version, args.build)
    commit = clean_head()
    check_origin()
    verify_origin_commit(commit)
    verify_tag(tag, commit)
    notes_path = args.notes.relative_to(ROOT).as_posix()
    if not re.fullmatch(r"docs/releases/[A-Za-z0-9._-]+\.md", notes_path):
        raise ReleaseError("Use committed release notes in docs/releases/.")
    if args.notes.read_bytes() != git_bytes("show", f"{commit}:{notes_path}"):
        raise ReleaseError("Release notes must match the source commit.")
    if args.output.exists():
        raise ReleaseError(f"Output already exists: {args.output}")
    # A fresh checkout needs the pinned binary artifact before the Keychain check.
    swift_build = ROOT / ".build"
    swift_build.mkdir(mode=0o700, exist_ok=True)
    if swift_build.is_symlink() or swift_build.stat().st_uid != os.getuid():
        raise ReleaseError("Expected an owned SwiftPM build directory.")
    swift_build.chmod(0o700)
    cache = swift_build / "cache"
    cache.mkdir(mode=0o700, exist_ok=True)
    if cache.is_symlink() or cache.stat().st_uid != os.getuid():
        raise ReleaseError("Expected an owned SwiftPM cache directory.")
    cache.chmod(0o700)
    run(["swift", "package", "--package-path", ROOT, "--disable-dependency-cache",
         "--cache-path", cache, "--force-resolved-versions", "resolve"])
    if not os.access(TOOLS / "generate_keys", os.X_OK) or not os.access(TOOLS / "sign_update", os.X_OK):
        raise ReleaseError("Pinned Sparkle tools are missing after dependency resolution.")
    fingerprint, name = developer_id(args.identity)
    run(["xcrun", "notarytool", "history", "--keychain-profile", args.profile, "--output-format", "json"])
    configured = plistlib.loads(UPDATE_CONFIG.read_bytes())
    key = run([TOOLS / "generate_keys", "--account", KEY_ACCOUNT, "-p"]).stdout.strip()
    if key != configured["SUPublicEDKey"]:
        raise ReleaseError(f"The Keychain update key for account '{KEY_ACCOUNT}' does not match SUPublicEDKey.")
    return commit, notes_path, fingerprint, name, configured


def signing_requirement(fingerprint):
    if not re.fullmatch(FINGERPRINT, fingerprint):
        raise ReleaseError("Invalid Developer ID certificate fingerprint.")
    return (f'anchor apple generic and certificate leaf = H"{fingerprint}" and '
            f'certificate leaf[subject.OU] = "{TEAM}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')


def audit(app, configured, version, build, commit, fingerprint):
    report = run([ROOT / "scripts/audit-app.py", app, "--identity", fingerprint]).stdout
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {**configured, "CFBundleShortVersionString": version,
                "CFBundleVersion": str(build), "SetbeamSourceCommit": commit}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ReleaseError(f"Info.plist {key} is {info.get(key)!r}, expected {value!r}.")
    return report


@contextmanager
def mounted_app(dmg):
    mount = Path(tempfile.mkdtemp(prefix="setbeam-dmg-"))
    try:
        run(["hdiutil", "attach", "-readonly", "-nobrowse", "-owners", "on", "-mountpoint", mount, dmg])
    except (OSError, ReleaseError):
        with suppress(FileNotFoundError):
            mount.rmdir()
        raise
    try:
        yield mount / "Setbeam.app"
    finally:
        try:
            run(["hdiutil", "detach", mount])
        except ReleaseError as error:
            raise ReleaseError(f"Could not detach disk image at {mount}: {error}") from error
        with suppress(FileNotFoundError):
            mount.rmdir()


def notarize(artifact, profile, logs):
    submitted = run(["xcrun", "notarytool", "submit", artifact, "--keychain-profile", profile,
                     "--output-format", "json"], logs / f"notary-submit-{artifact.name}.json", check=False)
    try:
        identifier = json.loads(submitted.stdout)["id"]
    except (ValueError, KeyError):
        raise ReleaseError(f"No notary submission ID for {artifact.name}. See {logs}.") from None
    print(f"Notary submission for {artifact.name}: {identifier}", flush=True)
    result = run(["xcrun", "notarytool", "wait", identifier, "--keychain-profile", profile,
                  "--timeout", "45m", "--output-format", "json"], logs / f"notary-wait-{artifact.name}.json", check=False)
    try:
        response = json.loads(result.stdout)
    except ValueError:
        raise ReleaseError(f"Notary submission {identifier} gave no wait result. See {logs}.") from None
    run(["xcrun", "notarytool", "log", identifier, "--keychain-profile", profile],
        logs / f"notary-log-{artifact.name}.json", check=False)
    if response.get("status") != "Accepted":
        raise ReleaseError(f"Notary submission {identifier}: {response.get('status')} {response.get('message', '')}. See {logs}.")
    return identifier


def staple(target, logs, kind):
    run(["xcrun", "stapler", "staple", target], logs / f"staple-{target.name}.txt")
    run(["xcrun", "stapler", "validate", target], logs / f"validate-{target.name}.txt")
    extra = ["--context", "context:primary-signature"] if kind == "open" else []
    result = run(["spctl", "--assess", "--type", kind, *extra, "-vv", target], logs / f"gatekeeper-{target.name}.txt")
    if "source=Notarized Developer ID" not in result.stderr:
        raise ReleaseError(f"Gatekeeper did not accept {target.name} as notarized:\n{result.stderr}")


def tree_hashes(app):
    entries = {}
    for path in sorted(app.rglob("*")):
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            entry = ("symlink", os.readlink(path))
        elif path.is_file():
            entry = ("file", mode, sha256(path))
        elif path.is_dir():
            entry = ("dir", mode)
        else:
            raise ReleaseError(f"Unexpected app bundle file type: {path}")
        entries[str(path.relative_to(app))] = entry
    return entries


def notes_html(markdown):
    """Small Markdown subset for Sparkle's update window: headings, bullets, paragraphs, links."""
    def inline(text):
        text = html.escape(text, quote=False)
        text = re.sub(r"\[([^\]]+)\]\((https://[^)\s]+)\)", lambda m: f'<a href="{html.escape(m[2])}">{m[1]}</a>', text)
        return re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    out, paragraph, bullets = [], [], []
    def flush():
        if paragraph: out.append("<p>" + inline(" ".join(paragraph)) + "</p>"); paragraph.clear()
        if bullets: out.append("<ul>" + "".join(f"<li>{inline(b)}</li>" for b in bullets) + "</ul>"); bullets.clear()
    for line in markdown.splitlines()[1:]:  # The page title repeats Sparkle's own heading.
        stripped = line.strip()
        if not stripped:
            flush()
        elif stripped.startswith("#"):
            flush(); out.append(f"<h3>{inline(stripped.lstrip('#').strip())}</h3>")
        elif stripped.startswith("- "):
            if paragraph: flush()
            bullets.append(stripped[2:])
        elif bullets:
            bullets[-1] += " " + stripped
        else:
            paragraph.append(stripped)
    flush()
    return "\n".join(out)


@dataclass(frozen=True)
class FeedSnapshot:
    tip: str | None
    feed: bytes | None

    @property
    def digest(self):
        return hashlib.sha256(self.feed).hexdigest() if self.feed is not None else None


def published_feed():
    """Read feed bytes by immutable object ID, without using FETCH_HEAD."""
    tip = remote_refs(PAGES_REF).get(PAGES_REF)
    if tip is None:
        return FeedSnapshot(None, None)
    fetch_objects(tip)
    return FeedSnapshot(tip, git_bytes("show", f"{tip}:appcast.xml"))


def signed_feed(data):
    content, marker, footer = data.rpartition(b"<!-- sparkle-signatures:\n")
    match = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n-->\n?", footer)
    if not marker or not match or int(match[2]) != len(content):
        raise ReleaseError("Invalid Sparkle feed signature block or signed length.")
    return content, match[1].decode("ascii")


def feed_items(content):
    root = ET.fromstring(content)
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1:
        raise ReleaseError("Expected one RSS channel in the appcast.")
    items = channels[0].findall("item")
    builds = []
    for item in items:
        versions = item.findall(f"{{{SPARKLE_NS}}}version")
        if len(versions) != 1 or not re.fullmatch(r"[1-9][0-9]*", versions[0].text or ""):
            raise ReleaseError("Each appcast item must declare one numeric build.")
        builds.append(int(versions[0].text))
    if len(builds) != len(set(builds)):
        raise ReleaseError("Duplicate appcast build numbers.")
    return root, items, builds


def verify_update(feed, dmg, manifest, configured):
    """Authenticate the exact bytes Sparkle parses and the enclosure it downloads."""
    content, feed_signature = signed_feed(feed)
    _, items, builds = feed_items(content)
    expected_build = manifest["build"]
    if not builds or builds[0] != expected_build or max(builds) != expected_build:
        raise ReleaseError("Candidate must be the first and newest appcast build.")
    item = items[0]
    versions = item.findall(f"{{{SPARKLE_NS}}}shortVersionString")
    enclosures = item.findall("enclosure")
    url = f"https://github.com/{REPOSITORY}/releases/download/{manifest['tag']}/{dmg.name}"
    signature = manifest["edSignature"]
    if len(versions) != 1 or versions[0].text != manifest["version"] or len(enclosures) != 1:
        raise ReleaseError("Candidate appcast item has the wrong version or enclosure count.")
    enclosure = enclosures[0]
    expected = {"url": url, "length": str(manifest["bytes"]), "type": "application/octet-stream",
                f"{{{SPARKLE_NS}}}edSignature": signature}
    if enclosure.attrib != expected or item.find(f"{{{SPARKLE_NS}}}deltas") is not None:
        raise ReleaseError("Candidate appcast enclosure does not match the staged disk image.")
    verify_signatures(configured, content, feed_signature, dmg, signature)
    return url


def verify_signatures(configured, content, feed_signature, *artifacts):
    for value in (feed_signature, *artifacts[1::2]):
        if len(base64.b64decode(value, validate=True)) != 64:
            raise ReleaseError("Invalid Ed25519 signature length.")
    with tempfile.TemporaryDirectory(prefix="setbeam-signature-") as folder:
        signed = Path(folder) / "appcast-content"
        signed.write_bytes(content)
        run(["/usr/bin/swift", ROOT / "scripts/verify-update.swift", configured["SUPublicEDKey"],
             signed, feed_signature, *artifacts])


def write_feed(path, previous, args, url, signature, length, notes):
    ET.register_namespace("sparkle", SPARKLE_NS)
    if previous is not None:
        # ElementTree drops comments. Sparkle signs the resulting feed afresh.
        root, _, published = feed_items(previous)
        channel = root.find("channel")
    else:
        published = []
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Setbeam"
        ET.SubElement(channel, "link").text = f"https://github.com/{REPOSITORY}/releases"
        ET.SubElement(channel, "description").text = "Signed Setbeam updates for Apple Silicon Macs."
        ET.SubElement(channel, "language").text = "en"
    if published and max(published) >= args.build:
        raise ReleaseError(f"Build {args.build} must be newer than published build {max(published)}.")
    tag = f"v{args.version}-build{args.build}"
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Setbeam {args.version} build {args.build}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(args.build)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {
        "url": url,
        "length": str(length), "type": "application/octet-stream", f"{{{SPARKLE_NS}}}edSignature": signature})
    position = list(channel).index(channel.find("item")) if channel.find("item") is not None else len(channel)
    channel.insert(position, item)
    ET.indent(root)
    path.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n")
    run([TOOLS / "sign_update", "--account", KEY_ACCOUNT, path])
    run([TOOLS / "sign_update", "--account", KEY_ACCOUNT, "--verify", path])


def stage(args):
    commit, notes_path, fingerprint, identity, configured = preflight(args)
    print(f"Preflight passed: {identity}, notary profile {args.profile}, update key {KEY_ACCOUNT}.")
    if args.preflight:
        return
    previous = published_feed()
    prior_content = None
    if previous.feed is not None:
        prior_content, prior_signature = signed_feed(previous.feed)
        verify_signatures(configured, prior_content, prior_signature)
        _, _, builds = feed_items(prior_content)
        if builds and max(builds) >= args.build:
            raise ReleaseError(f"Build {args.build} must be newer than published build {max(builds)}.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".setbeam-release-", dir=args.output.parent))
    try:
        build_candidate(args, commit, notes_path, fingerprint, identity, configured, work, previous, prior_content)
    except Exception:
        print(f"Staging files and logs are in {work}", file=sys.stderr)
        raise


def build_candidate(args, commit, notes_path, fingerprint, identity, configured, work, previous, prior_content):
    logs = work / "logs"; logs.mkdir()
    app = work / "Setbeam.app"
    env = dict(os.environ, SETBEAM_UPDATES="1", SETBEAM_SIGNING_IDENTITY=fingerprint,
               SETBEAM_VERSION=args.version, SETBEAM_BUILD=str(args.build),
               SETBEAM_CONFIGURATION="release", SETBEAM_APP_OUTPUT=str(app), SETBEAM_SOURCE_COMMIT=commit)
    print("Building with Developer ID…")
    build = subprocess.run([ROOT / "scripts/build-app.sh"], env=env, capture_output=True, text=True)
    (logs / "build-app.txt").write_text(build.stdout + build.stderr)
    if build.returncode != 0:
        raise ReleaseError(f"build-app.sh failed; see {logs / 'build-app.txt'}")
    if clean_head() != commit:
        raise ReleaseError("Source commit changed during the build.")
    (logs / "audit.txt").write_text(audit(app, configured, args.version, args.build, commit, fingerprint))

    print("Notarizing the app…")
    app_zip = work / "Setbeam-notarize.zip"
    run(["ditto", "-c", "-k", "--keepParent", "--sequesterRsrc", app, app_zip])
    app_submission = notarize(app_zip, args.profile, logs)
    app_zip.unlink()
    staple(app, logs, "execute")

    base = f"Setbeam-{args.version}-build{args.build}"
    dmg = work / f"{base}.dmg"
    with tempfile.TemporaryDirectory(dir=work) as folder:
        contents = Path(folder)
        run(["ditto", app, contents / "Setbeam.app"])
        (contents / "Applications").symlink_to("/Applications")
        run(["hdiutil", "create", "-volname", f"Setbeam {args.version} build {args.build}", "-srcfolder", contents,
             "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", dmg], logs / "dmg.txt")
    run(["codesign", "--force", "--timestamp", "--sign", fingerprint, dmg])
    run(["codesign", "--verify", "--strict", dmg])
    run(["hdiutil", "verify", dmg], logs / "verify-dmg.txt")
    print("Notarizing the disk image…")
    dmg_submission = notarize(dmg, args.profile, logs)
    staple(dmg, logs, "open")

    # The installed copy must be the same notarized app, file for file.
    with mounted_app(dmg) as mounted:
        if tree_hashes(mounted) != tree_hashes(app):
            raise ReleaseError("The disk image's app differs from the notarized app.")
        result = run(["spctl", "--assess", "--type", "execute", "-vv", mounted], logs / "gatekeeper-mounted.txt")
        if "source=Notarized Developer ID" not in result.stderr:
            raise ReleaseError("Gatekeeper did not accept the app inside the disk image.")

    signature = run([TOOLS / "sign_update", "--account", KEY_ACCOUNT, "-p", dmg]).stdout.strip()
    feed = work / "appcast.xml"
    url = f"https://github.com/{REPOSITORY}/releases/download/v{args.version}-build{args.build}/{dmg.name}"
    write_feed(feed, prior_content, args, url, signature, dmg.stat().st_size, notes_html(git_bytes("show", f"{commit}:{notes_path}").decode()))

    digest = sha256(dmg)
    (work / f"SHA256SUMS-build{args.build}.txt").write_text(f"{digest}  {dmg.name}\n")
    (work / "release-notes.md").write_bytes(git_bytes("show", f"{commit}:{notes_path}"))
    manifest = {
        "version": args.version, "build": args.build, "tag": f"v{args.version}-build{args.build}",
        "commit": commit, "identity": identity, "certificateSHA1": fingerprint, "notesPath": notes_path, "notarySubmissions": {"app": app_submission, "dmg": dmg_submission},
        "dmg": dmg.name, "sha256": digest, "bytes": dmg.stat().st_size, "edSignature": signature,
        "feedURL": configured["SUFeedURL"], "previousFeedSHA256": previous.digest, "previousFeedCommit": previous.tip,
        "appFiles": sum(entry[0] == "file" for entry in tree_hashes(app).values()),
    }
    verify_update(feed.read_bytes(), dmg, manifest, configured)
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.rmtree(app)
    work.rename(args.output)
    print(f"Candidate staged at {args.output}\nSHA-256 {digest}\nNothing was published.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--notes", required=True, type=Path, help="Markdown release notes")
    parser.add_argument("--profile", default=os.environ.get("SETBEAM_NOTARY_PROFILE", "DFA"),
                        help="Existing notarytool Keychain profile")
    parser.add_argument("--identity", help="Developer ID name or SHA-1 fingerprint, if more than one exists")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--preflight", action="store_true", help="Check credentials and inputs only")
    args = parser.parse_args()
    args.notes = args.notes.resolve()
    try:
        tag = release_tag(args.version, args.build)
        args.output = (args.output or ROOT / "dist" / f"Setbeam-{tag[1:]}-release").resolve()
        os.umask(0o077)
        stage(args)
    except (ReleaseError, OSError, ValueError, KeyError, ET.ParseError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
