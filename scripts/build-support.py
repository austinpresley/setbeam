#!/usr/bin/env python3
"""Private build directories, locked runtime cache, and atomic app replacement."""
import ctypes
import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "Vendor"
CACHE = RUNTIME / "cache"
STAMP = RUNTIME / "runtime-provenance.json"
INPUTS = ("runtime-lock.json", "scripts/build-runtime.sh", "scripts/build-support.py",
          "scripts/patch-avfoundation.py", "scripts/patch-video-decode.py")
OUTPUTS = ("bin/ffmpeg", "bin/ffprobe", "bin/mediamtx", "opus/lib/libopus.a",
           "licenses/build-runtime.sh", "licenses/build-support.py", "licenses/patch-avfoundation.py", "licenses/patch-video-decode.py",
           "sources/ffmpeg-9.0.2/libavformat/libavformat.a", "sources/ffmpeg-9.0.2/libavcodec/libavcodec.a",
           "sources/ffmpeg-9.0.2/libswscale/libswscale.a", "sources/ffmpeg-9.0.2/libswresample/libswresample.a",
           "sources/ffmpeg-9.0.2/libavutil/libavutil.a", "sources/ffmpeg-9.0.2/libavutil/avconfig.h",
           "sources/ffmpeg-9.0.2/libavdevice/avfoundation.m", "sources/ffmpeg-9.0.2/fftools/ffmpeg_dec.c",
           "licenses/FFmpeg-build-configuration.txt",
           "licenses/FFmpeg-LGPL-2.1.txt", "licenses/Opus-BSD.txt", "licenses/MediaMTX-MIT.txt")


def private_directory(path):
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError(f"Expected an owned directory at {path}")
    path.chmod(0o700)


def locked(script, args):
    private_directory(ROOT / "build")
    lock = ROOT / "build/.packaging.lock"
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError(f"Expected an owned lock file at {lock}")
    os.fchmod(fd, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.set_inheritable(fd, True)
    os.environ["SETBEAM_BUILD_LOCK_FD"] = str(fd)
    for name in ("Vendor", "build/logs"):
        private_directory(ROOT / name)
    os.execv(script, [script, *args])


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verified_archive(item):
    archive = CACHE / item["archive"]
    if not archive.is_symlink() and archive.is_file() and digest(archive) == item["sha256"]:
        archive.chmod(0o600)
        return archive
    if archive.is_symlink() or (archive.exists() and not archive.is_file()):
        raise ValueError(f"Expected a regular cache file at {archive}")
    with tempfile.NamedTemporaryFile(dir=CACHE, prefix=".download-", delete=False) as download:
        partial = Path(download.name)
    try:
        subprocess.run(["curl", "-q", "--fail", "--location", "--proto", "=https", "--proto-redir",
                        "=https", "--retry", "3", "--connect-timeout", "20", "--max-time", "180",
                        item["url"], "-o", partial], check=True)
        if digest(partial) != item["sha256"]:
            raise ValueError(f"Checksum mismatch for {archive.name}")
        partial.replace(archive)
    finally:
        partial.unlink(missing_ok=True)
    return archive


def build_inputs():
    return {
        "inputsSHA256": {path: digest(ROOT / path) for path in INPUTS},
        "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], text=True).strip(),
        "clang": subprocess.check_output(["xcrun", "clang", "--version"], text=True).strip(),
        "pkgConfig": subprocess.check_output(["pkg-config", "--version"], text=True).strip(),
    }


def runtime_source(scratch):
    (scratch / "build-inputs.json").write_text(json.dumps(build_inputs()))
    lock = json.loads((ROOT / "runtime-lock.json").read_text())
    private_directory(CACHE)
    archives = {item["archive"]: verified_archive(item) for item in lock["dependencies"] + lock["sourceMaterials"]}
    for item in lock["dependencies"]:
        destination = scratch / "sources"
        if item["name"] == "mediamtx":
            destination /= "mediamtx"
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archives[item["archive"]]) as source:
            source.extractall(destination, filter="data")


def runtime_matches():
    if any((RUNTIME / name).is_symlink() for name in ("sources", "opus", "bin", "licenses")):
        raise ValueError("Runtime output directories must not be symlinks.")
    lock = json.loads((ROOT / "runtime-lock.json").read_text())
    private_directory(CACHE)
    for item in lock["dependencies"] + lock["sourceMaterials"]:
        verified_archive(item)
    try:
        stored = json.loads(STAMP.read_text())
        return (not STAMP.is_symlink() and
                all(os.access(RUNTIME / path, os.X_OK) for path in OUTPUTS if path.startswith("bin/")) and
                stored == runtime_provenance(RUNTIME))
    except (OSError, ValueError):
        return False


def runtime_provenance(folder):
    return {**build_inputs(), "outputsSHA256": {path: digest(folder / path) for path in OUTPUTS}}


def install_runtime(scratch):
    provenance = runtime_provenance(scratch)
    inputs = json.loads((scratch / "build-inputs.json").read_bytes())
    if any(provenance[key] != value for key, value in inputs.items()):
        raise ValueError("Runtime build inputs changed during compilation. Rebuild with stable sources.")
    STAMP.unlink(missing_ok=True)
    for folder in ("sources", "opus", "bin", "licenses"):
        target = RUNTIME / folder
        if target.is_symlink():
            raise ValueError(f"Refusing to replace symlink {target}")
        if target.exists():
            shutil.rmtree(target)
        (scratch / folder).rename(target)
    temporary_stamp = scratch / "runtime-provenance.json"
    temporary_stamp.write_text(json.dumps(provenance, indent=2) + "\n")
    temporary_stamp.rename(STAMP)


def install_app(source, target):
    if target.is_symlink() or (target.exists() and not target.is_dir()):
        raise ValueError(f"Expected an app directory at {target}")
    if not target.exists():
        source.rename(target)
        return
    # macOS exchanges both directory entries in one operation. A failed swap
    # leaves the last build usable and the caller cleans up its new scratch app.
    rename = ctypes.CDLL(None, use_errno=True).renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    if rename(-2, os.fsencode(source), -2, os.fsencode(target), 0x00000002):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(target))


def main():
    action, *args = sys.argv[1:]
    try:
        if action == "lock":
            locked(args[0], args[1:])
        if action == "matches":
            return 0 if runtime_matches() else 1
        if action == "extract":
            runtime_source(Path(args[0]))
        elif action == "install-runtime":
            install_runtime(Path(args[0]))
        elif action == "install-app":
            install_app(*map(Path, args))
        else:
            raise ValueError(f"Unknown build action {action}")
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
