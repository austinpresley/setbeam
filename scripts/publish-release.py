#!/usr/bin/env python3
"""Publish a candidate staged by release.py: GitHub prerelease first, then the update feed.

The feed goes live only after an anonymous download of the uploaded disk image
matches the notarized candidate byte for byte, so the app never sees an update
it cannot fetch.
"""
import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
REPOSITORY = "austinpresley/setbeam"
PAGES_BRANCH = "gh-pages"
INDEX = """<!doctype html>
<meta charset="utf-8">
<title>Setbeam updates</title>
<meta http-equiv="refresh" content="0; url=https://github.com/austinpresley/setbeam/releases">
<p>Setbeam's update feed. <a href="https://github.com/austinpresley/setbeam/releases">Download Setbeam</a>.</p>
"""


class PublishError(Exception):
    pass


def run(args, check=True, cwd=None):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, cwd=cwd)
    if check and result.returncode != 0:
        raise PublishError(f"{' '.join(map(str, args[:3]))} failed:\n{(result.stdout + result.stderr).strip()[-1500:]}")
    return result


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_candidate(candidate, manifest):
    dmg = candidate / manifest["dmg"]
    if sha256(dmg) != manifest["sha256"]:
        raise PublishError("The disk image no longer matches the staged manifest.")
    run(["xcrun", "stapler", "validate", dmg])
    gatekeeper = run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "-vv", dmg])
    if "source=Notarized Developer ID" not in gatekeeper.stderr:
        raise PublishError("Gatekeeper does not accept the disk image as notarized.")
    run([TOOLS / "sign_update", "--account", "Setbeam", "--verify", candidate / "appcast.xml"])
    feed = (candidate / "appcast.xml").read_text()
    url = f"https://github.com/{REPOSITORY}/releases/download/{manifest['tag']}/{manifest['dmg']}"
    if url not in feed or manifest["edSignature"] not in feed:
        raise PublishError("The staged feed does not point at this candidate.")
    if run(["git", "-C", ROOT, "branch", "-r", "--contains", manifest["commit"]], check=False).stdout.strip() == "":
        raise PublishError(f"Push commit {manifest['commit'][:9]} to origin before publishing.")
    return dmg, url


def feed_state(candidate, manifest):
    """'published' if this candidate's feed is already on the branch, 'ready' if the branch is
    unchanged since staging. A feed that moved on means an older or parallel candidate: restage."""
    try:
        current, digest = release.published_feed()
    except release.ReleaseError as error:
        raise PublishError(str(error))
    if current is not None and current.encode() == (candidate / "appcast.xml").read_bytes():
        return "published"
    if digest != manifest["previousFeedSHA256"]:
        raise PublishError("The published feed changed after this candidate was staged. "
                           "Stage it again so the feed keeps every newer item.")
    return "ready"


def existing_release(manifest):
    """None if the release is new. An existing one is resumed only if it is this candidate's."""
    view = run(["gh", "release", "view", manifest["tag"], "--repo", REPOSITORY, "--json", "assets,isPrerelease"], check=False)
    if view.returncode != 0:
        if "release not found" in (view.stdout + view.stderr).lower():
            return None
        raise PublishError(f"Could not read release {manifest['tag']}: {(view.stdout + view.stderr).strip()}")
    details = json.loads(view.stdout)
    commit = run(["gh", "api", f"repos/{REPOSITORY}/commits/{manifest['tag']}", "--jq", ".sha"]).stdout.strip()
    names = {asset["name"] for asset in details["assets"]}
    if commit != manifest["commit"] or not details["isPrerelease"] or manifest["dmg"] not in names:
        raise PublishError(f"Release {manifest['tag']} exists but is not this candidate's prerelease. Inspect it by hand.")
    return details


def anonymous_download(url, expected, attempts=6):
    with tempfile.TemporaryDirectory() as folder:
        target = Path(folder) / "download"
        for attempt in range(attempts):
            result = run(["curl", "--fail", "--silent", "--location", "--max-time", "600", "-o", target, url], check=False)
            if result.returncode == 0 and sha256(target) == expected:
                return
            time.sleep(10 * (attempt + 1))
    raise PublishError(f"The anonymous download of {url} does not match {expected}.")


def publish_feed(candidate, manifest):
    """Commit the feed to the Pages branch, enable Pages if needed, and wait for HTTPS to serve it."""
    feed = (candidate / "appcast.xml").read_bytes()
    if feed_state(candidate, manifest) == "published":
        print("The update feed is already on the Pages branch.")
    else:
        push_feed(feed, manifest)
    if run(["gh", "api", f"repos/{REPOSITORY}/pages"], check=False).returncode != 0:
        run(["gh", "api", "-X", "POST", f"repos/{REPOSITORY}/pages",
             "-f", f"source[branch]={PAGES_BRANCH}", "-f", "source[path]=/"])
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        live = run(["curl", "--fail", "--silent", "--location", "--max-time", "30",
                    "-H", "Cache-Control: no-cache", manifest["feedURL"]], check=False)
        if live.returncode == 0 and live.stdout.encode() == feed:
            return
        time.sleep(20)
    raise PublishError(f"{manifest['feedURL']} did not serve the new feed within 15 minutes. "
                       "The release is live; rerun this script to resume.")


def push_feed(feed, manifest):
    run(["git", "-C", ROOT, "fetch", "origin", PAGES_BRANCH], check=False)
    exists = run(["git", "-C", ROOT, "rev-parse", "--verify", f"origin/{PAGES_BRANCH}"], check=False).returncode == 0
    with tempfile.TemporaryDirectory(prefix="setbeam-pages-") as folder:
        tree = Path(folder) / "pages"
        if exists:
            run(["git", "-C", ROOT, "worktree", "add", "--detach", tree, f"origin/{PAGES_BRANCH}"])
        else:
            run(["git", "-C", ROOT, "worktree", "add", "--detach", tree])
            run(["git", "checkout", "--orphan", "setbeam-pages-publish"], cwd=tree)
            run(["git", "rm", "-rf", "--quiet", "."], cwd=tree)
        try:
            (tree / "appcast.xml").write_bytes(feed)
            (tree / "index.html").write_text(INDEX)
            (tree / ".nojekyll").write_text("")
            run(["git", "add", "appcast.xml", "index.html", ".nojekyll"], cwd=tree)
            run(["git", "commit", "--quiet", "-m", f"Publish update feed for {manifest['tag']}"], cwd=tree)
            run(["git", "push", "origin", f"HEAD:refs/heads/{PAGES_BRANCH}"], cwd=tree)
        finally:
            run(["git", "-C", ROOT, "worktree", "remove", "--force", tree], check=False)
            run(["git", "-C", ROOT, "branch", "-D", "setbeam-pages-publish"], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path, help="Directory staged by release.py")
    parser.add_argument("--verify-only", action="store_true", help="Check the candidate and stop")
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    try:
        manifest = json.loads((candidate / "manifest.json").read_text())
        dmg, url = verify_candidate(candidate, manifest)
        state = feed_state(candidate, manifest)
        print(f"Candidate verified: {manifest['tag']} {manifest['sha256']}; feed {state}.")
        if args.verify_only:
            return 0
        if existing_release(manifest) is None:
            sums = candidate / f"SHA256SUMS-build{manifest['build']}.txt"
            run(["gh", "release", "create", manifest["tag"], "--repo", REPOSITORY, "--target", manifest["commit"],
                 "--prerelease", "--title", f"Setbeam {manifest['version']} build {manifest['build']}",
                 "--notes-file", candidate / "release-notes.md", dmg, sums])
        else:
            print(f"Resuming: release {manifest['tag']} already exists for this commit.")
        anonymous_download(url, manifest["sha256"])
        print(f"Release published; anonymous download matches: {url}")
        publish_feed(candidate, manifest)
        print(f"Update feed live and matching: {manifest['feedURL']}")
    except (PublishError, release.ReleaseError, OSError, KeyError, json.JSONDecodeError) as error:
        print(f"Publish stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
