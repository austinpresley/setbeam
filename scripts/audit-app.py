#!/usr/bin/env python3
"""Fail closed on missing resources, unsigned code, or incompatible Mach-O files."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEAM = "G2R8798RLT"
SPARKLE = "Frameworks/Sparkle.framework/Versions/B/"
MAIN = "MacOS/Setbeam"
HELPERS = ("ffmpeg", "ffprobe", "mediamtx", "setbeam-preview", "setbeam-supervisor")
APP_CODE = {MAIN, *(f"Helpers/{name}" for name in HELPERS)}
SPARKLE_CODE = {SPARKLE + name for name in (
    "Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
    "XPCServices/Installer.xpc/Contents/MacOS/Installer",
    "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
)}
LICENSES = (
    "LICENSE", "THIRD_PARTY_NOTICES.md", "runtime-lock.json", "Sparkle-LICENSE.txt", "runtime-provenance.json",
    "FFmpeg-LGPL-2.1.txt", "Opus-BSD.txt", "MediaMTX-MIT.txt", "FFmpeg-build-configuration.txt",
    "build-runtime.sh", "build-support.py", "patch-avfoundation.py", "patch-video-decode.py", "build-preview-bridge.sh",
    "setbeam-preview.c", "setbeam-preview-build.txt",
)
RESOURCES = (
    "Setbeam.icns", "reader.js", "viewer.html", "expired.html", "viewer.css", "viewer.js",
    "keepawake.js", "pointers.js", "chat.js", "Fixtures/Demo.mp4", "Fixtures/Hold.mp4",
    "Fixtures/Compatibility-H264.mp4", "Fixtures/Compatibility-HEVC.mp4", "Fixtures/compatibility-notes.txt",
)
REQUIRED = {"Info.plist", *APP_CODE, *SPARKLE_CODE, *(f"Resources/{name}" for name in RESOURCES),
            *(f"Resources/Licenses/{name}" for name in LICENSES)}
SPARKLE_LINK = "@rpath/Sparkle.framework/Versions/B/Sparkle"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    return result.stdout + result.stderr


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def mediamtx_files(contents, lock, *, before_signing=False):
    licenses = contents / "Resources/Licenses"
    notices = licenses / "MediaMTX"
    pinned_manifest = (ROOT / "licenses/mediamtx/manifest.json").read_bytes()
    manifest_path = notices / "manifest.json"
    require(not notices.is_symlink() and manifest_path.is_file() and not manifest_path.is_symlink()
            and manifest_path.read_bytes() == pinned_manifest,
            "Bundled MediaMTX notice manifest differs from the checkout.")
    manifest = json.loads(pinned_manifest)
    require(any(item["name"] == "mediamtx" and item["sha256"] == manifest["archiveSHA256"]
                for item in lock["dependencies"]),
            "MediaMTX notice manifest does not cover the pinned release archive.")
    for path in (licenses / "MediaMTX-MIT.txt", notices / "buildinfo.txt", notices / "notices.txt"):
        require(path.is_file() and not path.is_symlink() and digest(path) == manifest["filesSHA256"][path.name],
                f"Bundled MediaMTX license or inventory differs from the pin: {path.name}")

    binary = contents / "Helpers/mediamtx"
    require(binary.is_file() and not binary.is_symlink(), "Missing bundled MediaMTX executable.")
    if before_signing:
        require(digest(binary) == manifest["upstreamBinarySHA256"],
                "MediaMTX executable differs from the original pinned release binary.")
    # codesign rewrites the signature and Mach-O load metadata. The pinned
    # __DATA,__go_buildinfo bytes retain their file offset through signing.
    section = manifest["goBuildInfoSection"]
    with binary.open("rb") as stream:
        stream.seek(section["offset"])
        checksum = hashlib.sha256(stream.read(section["size"])).hexdigest()
    require(checksum == section["sha256"], "Bundled MediaMTX Go build information differs from the pin.")


def runtime_files(contents):
    licenses = contents / "Resources/Licenses"
    lock = json.loads((licenses / "runtime-lock.json").read_bytes())
    mediamtx_files(contents, lock)
    provenance = json.loads((licenses / "runtime-provenance.json").read_bytes())
    require(digest(contents / "Resources/reader.js") == lock["reader"]["bundledSHA256"],
            "Bundled reader.js differs from runtime-lock.json.")
    for item in lock["dependencies"] + lock["sourceMaterials"]:
        if item.get("name") == "mediamtx":
            continue
        path = licenses / "Sources" / item["archive"]
        require(path.is_file() and not path.is_symlink() and digest(path) == item["sha256"],
                f"Source archive differs from the lock: {path.name}")
    for source in ("runtime-lock.json", "scripts/build-runtime.sh", "scripts/build-support.py",
                   "scripts/patch-avfoundation.py", "scripts/patch-video-decode.py"):
        require(digest(licenses / Path(source).name) == provenance["inputsSHA256"][source],
                f"Bundled runtime source differs from build provenance: {source}")


def audit_slice(path, name, arch):
    loads = command("otool", "-arch", arch, "-l", path)
    minimums = []
    rpaths = []
    for block in re.split(r"^Load command \d+\n", loads, flags=re.M):
        if re.search(r"\bcmd LC_BUILD_VERSION\b", block):
            platform = re.search(r"^\s*platform\s+(\S+)", block, flags=re.M)
            minimum = re.search(r"^\s*minos\s+(\d+(?:\.\d+){0,2})", block, flags=re.M)
            require(platform and platform[1].lower() in {"macos", "1"} and minimum, f"{name} has a non-macOS slice")
            minimums.append(minimum[1])
        elif re.search(r"\bcmd LC_VERSION_MIN_MACOSX\b", block):
            minimum = re.search(r"^\s*version\s+(\d+(?:\.\d+){0,2})", block, flags=re.M)
            require(minimum, f"{name} has invalid deployment metadata")
            minimums.append(minimum[1])
        elif re.search(r"\bcmd LC_RPATH\b", block):
            rpath = re.search(r"^\s*path (.+) \(offset \d+\)", block, flags=re.M)
            require(rpath, f"{name} has invalid runtime search path metadata")
            rpaths.append(rpath[1])
    require(len(minimums) == 1 and tuple(map(int, (minimums[0] + ".0.0").split(".")[:3])) <= (14, 0, 0),
            f"{name} {arch} lacks a compatible macOS deployment target: {minimums}")
    for rpath in rpaths:
        if rpath.startswith("/usr/lib/") and os.path.normpath(rpath) == rpath:
            continue
        resolved = None
        for prefix in ("@executable_path", "@loader_path"):
            if rpath == prefix or rpath.startswith(prefix + "/"):
                resolved = (path.parent / rpath[len(prefix):].lstrip("/")).resolve()
        require(resolved is not None and resolved.is_relative_to(path.parents[len(Path(name).parts) - 1]),
                f"{name} has a runtime search path outside the bundle: {rpath}")
    links = command("otool", "-arch", arch, "-L", path)
    dependencies = [line.strip().split(" (", 1)[0] for line in links.splitlines() if line.startswith("\t")]
    for dependency in dependencies:
        system = dependency.startswith(("/usr/lib/", "/System/Library/")) and os.path.normpath(dependency) == dependency
        require(system or
                (dependency == SPARKLE_LINK and (name == MAIN or name in SPARKLE_CODE)),
                f"{name} links an unexpected dependency: {dependency}")
    if name == MAIN:
        require(SPARKLE_LINK in dependencies and "@executable_path/../Frameworks" in rpaths,
                "Setbeam lacks the bundled Sparkle dependency or search path.")
    return minimums[0]


def audit(app, identity):
    contents = app / "Contents"
    require(not contents.is_symlink(), "App Contents directory must not be a symlink.")
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    for key, value in {"CFBundleIdentifier": "app.setbeam.mac", "CFBundleExecutable": "Setbeam",
                       "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"}.items():
        require(info.get(key) == value, f"Incorrect bundle {key}")
    for name in sorted(REQUIRED):
        path = contents / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0, f"Missing or empty bundle file: {name}")
    runtime_files(contents)
    command("codesign", "--verify", "--deep", "--strict", app)
    found = set()
    for path in sorted(contents.rglob("*")):
        name = path.relative_to(contents).as_posix()
        if path.is_symlink():
            require(path.resolve(strict=True).is_relative_to(contents), f"Bundle symlink escapes Contents: {name}")
            continue
        if not path.is_file() or "Mach-O" not in command("file", "-b", path):
            continue
        found.add(name)
        require(name in APP_CODE | SPARKLE_CODE, f"Unexpected Mach-O file: {name}")
        require(os.access(path, os.X_OK), f"Mach-O file is not executable: {name}")
        architectures = set(command("lipo", "-archs", path).split())
        require(architectures == {"arm64"} if name in APP_CODE else "arm64" in architectures and
                architectures <= {"arm64", "x86_64"}, f"{name} has unexpected architectures: {architectures}")
        details = command("codesign", "-dv", "--verbose=4", path)
        if identity == "-":
            require("Signature=adhoc" in details, f"{name} lacks an ad-hoc signature")
        else:
            requirement = (f'anchor apple generic and certificate leaf = H"{identity}" and '
                           f'certificate leaf[subject.OU] = "{TEAM}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
            command("codesign", "--verify", "--strict", "-R=" + requirement, path)
            require(f"TeamIdentifier={TEAM}\n" in details and "Timestamp=" in details and "(runtime)" in details,
                    f"{name} lacks the release team, secure timestamp or hardened runtime")
        deployment = ", ".join(f"{arch} macOS {audit_slice(path, name, arch)}" for arch in sorted(architectures))
        print(f"{name}: signature, {deployment}, linkage")
    require(found == APP_CODE | SPARKLE_CODE, f"Expected Mach-O files missing: {(APP_CODE | SPARKLE_CODE) - found}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity", default="-")
    parser.add_argument("--check-mediamtx-before-signing", action="store_true",
                        help="check the original MediaMTX executable and its staged notices")
    args = parser.parse_args()
    try:
        require(args.identity == "-" or re.fullmatch("[A-F0-9]{40}", args.identity), "Use a SHA-1 signing fingerprint.")
        app = args.app.resolve(strict=True)
        if args.check_mediamtx_before_signing:
            contents = app / "Contents"
            lock = json.loads((contents / "Resources/Licenses/runtime-lock.json").read_bytes())
            mediamtx_files(contents, lock, before_signing=True)
        else:
            audit(app, args.identity)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"App audit failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
