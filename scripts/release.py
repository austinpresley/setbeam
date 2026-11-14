#!/usr/bin/env python3
"""Stage a notarized, updatable Setbeam release candidate. Publishes nothing.

Builds with Developer ID and the hardened runtime, audits every executable,
notarizes and staples the app and its DMG, and writes a signed Sparkle feed that
keeps earlier published items. Publish the staged candidate with publish-release.py.
"""
import argparse
import email.utils
import hashlib
import html
import json
import os
import plistlib
import re
import shutil
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
    problems = []
    if run(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=no"]).stdout.strip():
        problems.append("Commit or discard tracked changes first; the candidate must match a commit.")
    try:
        fingerprint, name = developer_id(args.identity)
    except ReleaseError as error:
        problems.append(str(error)); fingerprint = name = None
    notary = run(["xcrun", "notarytool", "history", "--keychain-profile", args.profile, "--output-format", "json"], check=False)
    if notary.returncode != 0:
        detail = (notary.stdout + notary.stderr).strip().splitlines()
        problems.append(f"Notary profile '{args.profile}' cannot submit: {detail[-1] if detail else 'no response'}")
    configured = plistlib.loads(UPDATE_CONFIG.read_bytes())
    key = run([TOOLS / "generate_keys", "--account", KEY_ACCOUNT, "-p"], check=False).stdout.strip()
    if key != configured["SUPublicEDKey"]:
        problems.append(f"The Keychain update key for account '{KEY_ACCOUNT}' does not match SUPublicEDKey.")
    if not args.notes.is_file():
        problems.append(f"Release notes not found: {args.notes}")
    if args.output.exists():
        problems.append(f"Output already exists: {args.output}")
    tag = f"v{args.version}-build{args.build}"
    if run(["gh", "release", "view", tag, "--repo", REPOSITORY], check=False).returncode == 0:
        problems.append(f"Release {tag} already exists.")
    if problems:
        raise ReleaseError("Preflight failed:\n- " + "\n- ".join(problems))
    return fingerprint, name, configured


def macho_files(app):
    for path in sorted(app.rglob("*")):
        if path.is_file() and not path.is_symlink() and "Mach-O" in run(["file", "-b", path]).stdout:
            yield path


def audit(app, configured, version, build):
    """Hardened runtime, team, timestamp and system-only linkage for every executable."""
    run(["codesign", "--verify", "--deep", "--strict", app])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleShortVersionString": version, "CFBundleVersion": str(build),
                "SUFeedURL": configured["SUFeedURL"], "SUPublicEDKey": configured["SUPublicEDKey"]}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ReleaseError(f"Info.plist {key} is {info.get(key)!r}, expected {value!r}.")
    report = []
    for binary in macho_files(app):
        details = run(["codesign", "-dvv", binary]).stderr
        relative = binary.relative_to(app)
        if f"TeamIdentifier={TEAM}" not in details or "Timestamp=" not in details or "(runtime)" not in details:
            raise ReleaseError(f"{relative} lacks Developer ID team, secure timestamp or hardened runtime.")
        # Dependencies are the tab-indented lines; universal binaries add a header per architecture.
        links = [line.split()[0] for line in run(["otool", "-L", binary]).stdout.splitlines() if line.startswith("\t")]
        foreign = [l for l in links if not l.startswith(("/System/Library/", "/usr/lib/", "@rpath/Sparkle.framework/"))]
        if foreign:
            raise ReleaseError(f"{relative} links outside the system and bundled Sparkle: {foreign}")
        report.append(f"{relative}: runtime, team {TEAM}, timestamp, system/Sparkle linkage")
    return report


def notarize(artifact, profile, logs):
    result = run(["xcrun", "notarytool", "submit", artifact, "--keychain-profile", profile,
                  "--wait", "--timeout", "45m", "--output-format", "json"], logs / f"notary-{artifact.name}.json", check=False)
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ReleaseError(f"Notarization of {artifact.name} gave no result:\n{(result.stdout + result.stderr).strip()[-1500:]}")
    if "id" in response:
        run(["xcrun", "notarytool", "log", response["id"], "--keychain-profile", profile,
             logs / f"notary-log-{artifact.name}.json"], check=False)
    if response.get("status") != "Accepted":
        raise ReleaseError(f"Notarization of {artifact.name}: {response.get('status')} {response.get('message', '')}. See {logs}.")
    return response["id"]


def staple(target, logs, kind):
    run(["xcrun", "stapler", "staple", target], logs / f"staple-{target.name}.txt")
    run(["xcrun", "stapler", "validate", target], logs / f"validate-{target.name}.txt")
    extra = ["--context", "context:primary-signature"] if kind == "open" else []
    result = run(["spctl", "--assess", "--type", kind, *extra, "-vv", target], logs / f"gatekeeper-{target.name}.txt")
    if "source=Notarized Developer ID" not in result.stderr:
        raise ReleaseError(f"Gatekeeper did not accept {target.name} as notarized:\n{result.stderr}")


def tree_hashes(app):
    return {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(app.rglob("*")) if p.is_file() and not p.is_symlink()}


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


def published_feed(url):
    """The live feed, so earlier items stay available. None before the first release."""
    result = run(["curl", "--fail", "--silent", "--location", "--max-time", "30", url], check=False)
    if result.returncode == 22 or (result.returncode == 0 and not result.stdout.strip()):
        return None
    if result.returncode != 0:
        raise ReleaseError(f"Could not read the published feed {url} (curl exit {result.returncode}).")
    return result.stdout


def write_feed(path, previous, args, url, signature, length, notes):
    ET.register_namespace("sparkle", SPARKLE_NS)
    if previous:
        # Drop the previous feed's signature comment; the new feed is signed afresh.
        root = ET.fromstring(re.sub(r"<!--.*?-->", "", previous, flags=re.S))
        channel = root.find("channel")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Setbeam"
        ET.SubElement(channel, "link").text = f"https://github.com/{REPOSITORY}/releases"
        ET.SubElement(channel, "description").text = "Signed Setbeam updates for Apple Silicon Macs."
        ET.SubElement(channel, "language").text = "en"
    for old in channel.findall("item"):
        if old.findtext(f"{{{SPARKLE_NS}}}version") == str(args.build):
            raise ReleaseError(f"The published feed already contains build {args.build}.")
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
    fingerprint, identity, configured = preflight(args)
    print(f"Preflight passed: {identity}, notary profile {args.profile}, update key {KEY_ACCOUNT}.")
    if args.preflight:
        return
    commit = run(["git", "-C", ROOT, "rev-parse", "HEAD"]).stdout.strip()
    work = Path(tempfile.mkdtemp(prefix="setbeam-release-", dir=ROOT / "build"))
    logs = work / "logs"; logs.mkdir()
    env = dict(os.environ, SETBEAM_UPDATES="1", SETBEAM_SIGNING_IDENTITY=fingerprint,
               SETBEAM_VERSION=args.version, SETBEAM_BUILD=str(args.build))
    print("Building with Developer ID…")
    build = subprocess.run([ROOT / "scripts/build-app.sh"], env=env, capture_output=True, text=True)
    (logs / "build-app.txt").write_text(build.stdout + build.stderr)
    if build.returncode != 0:
        raise ReleaseError(f"build-app.sh failed; see {logs / 'build-app.txt'}")
    app = work / "Setbeam.app"
    run(["ditto", ROOT / "build/Setbeam.app", app])
    (logs / "audit.txt").write_text("\n".join(audit(app, configured, args.version, args.build)) + "\n")

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
    mount = Path(tempfile.mkdtemp(prefix="setbeam-dmg-"))
    run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg])
    try:
        mounted = mount / "Setbeam.app"
        if tree_hashes(mounted) != tree_hashes(app):
            raise ReleaseError("The disk image's app differs from the notarized app.")
        result = run(["spctl", "--assess", "--type", "execute", "-vv", mounted], logs / "gatekeeper-mounted.txt")
        if "source=Notarized Developer ID" not in result.stderr:
            raise ReleaseError("Gatekeeper did not accept the app inside the disk image.")
    finally:
        run(["hdiutil", "detach", mount], check=False)

    signature = run([TOOLS / "sign_update", "--account", KEY_ACCOUNT, "-p", dmg]).stdout.strip()
    previous = published_feed(configured["SUFeedURL"])
    feed = work / "appcast.xml"
    url = f"https://github.com/{REPOSITORY}/releases/download/v{args.version}-build{args.build}/{dmg.name}"
    write_feed(feed, previous, args, url, signature, dmg.stat().st_size, notes_html(args.notes.read_text()))

    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (work / f"SHA256SUMS-build{args.build}.txt").write_text(f"{digest}  {dmg.name}\n")
    shutil.copy2(args.notes, work / "release-notes.md")
    manifest = {
        "version": args.version, "build": args.build, "tag": f"v{args.version}-build{args.build}",
        "commit": commit, "identity": identity, "notarySubmissions": {"app": app_submission, "dmg": dmg_submission},
        "dmg": dmg.name, "sha256": digest, "bytes": dmg.stat().st_size, "edSignature": signature,
        "feedURL": configured["SUFeedURL"], "previousFeedItems": previous is not None,
        "appFiles": len(tree_hashes(app)),
    }
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.rmtree(app)
    shutil.move(work, args.output)
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
    args.output = (args.output or ROOT / "dist" / f"Setbeam-{args.version}-build{args.build}-release").resolve()
    try:
        stage(args)
    except ReleaseError as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
