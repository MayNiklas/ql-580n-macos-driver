#!/usr/bin/env python3
"""Check generated metadata and the exact contents of release archives."""

import argparse
import hashlib
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import zipfile

from generate_ppd import generate

ROOT = Path(__file__).resolve().parents[1]
PPD = ROOT / "ppd" / "Brother-QL-580N-Native.ppd"
ICON = ROOT / "assets" / "ql580n-native.icns"
MANIFEST = ROOT / "scripts" / "package_manifest.txt"


def version() -> str:
    value = (ROOT / "VERSION").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError("VERSION must contain major.minor.patch")
    return value


def check_ppd() -> None:
    expected = generate().encode("ascii")
    if PPD.read_bytes() != expected:
        raise ValueError("generated PPD is stale; run python3 scripts/generate_ppd.py")
    if not ICON.read_bytes().startswith(b"icns"):
        raise ValueError("printer icon is not an ICNS file")


def manifest_files() -> set[str]:
    files = {line for line in MANIFEST.read_text(encoding="utf-8").splitlines()
             if line and not line.startswith("#")}
    if len(files) != len([line for line in MANIFEST.read_text(encoding="utf-8").splitlines()
                         if line and not line.startswith("#")]):
        raise ValueError("package manifest has duplicate entries")
    if any(path.startswith("/") or ".." in Path(path).parts or not (ROOT / path).is_file()
           for path in files):
        raise ValueError("package manifest contains an invalid or missing path")
    if (ROOT / ".git").exists():
        tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
                      .decode("utf-8").rstrip("\0").split("\0"))
        if tracked != files:
            missing = sorted(tracked - files)
            untracked = sorted(files - tracked)
            raise ValueError(f"package manifest differs from Git index: missing={missing}, untracked={untracked}")
    return files


def file_members(archive: zipfile.ZipFile) -> set[str]:
    bad = archive.testzip()
    if bad is not None:
        raise ValueError(f"corrupt ZIP member: {bad}")
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise ValueError("ZIP contains duplicate member names")
    if any(name.startswith("/") or ".." in Path(name).parts or
           ".DS_Store" in name or "__pycache__" in name or
           name.startswith(("sources/", "vendor/")) for name in names):
        raise ValueError("ZIP contains a local or unsafe path")
    return {name for name in names if not name.endswith("/") and
            not name.startswith("__MACOSX/")}


def check_archives() -> None:
    release = version()
    source_path = ROOT / "dist" / f"QL-580N-macOS-Driver-v{release}-Source.zip"
    setup_path = ROOT / "dist" / f"QL-580N-macOS-Driver-v{release}-Setup.zip"
    checksum_path = Path(f"{setup_path}.sha256")
    with zipfile.ZipFile(source_path) as archive:
        actual = file_members(archive)
        expected = manifest_files() | {"build/rastertoql580n"}
        if actual != expected:
            raise ValueError(f"source ZIP members differ: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
        if archive.read("ppd/Brother-QL-580N-Native.ppd") != PPD.read_bytes():
            raise ValueError("source ZIP has a different PPD")
        if archive.read("assets/ql580n-native.icns") != ICON.read_bytes():
            raise ValueError("source ZIP has a different printer icon")
        if archive.read("VERSION").decode("ascii").strip() != release:
            raise ValueError("source ZIP has a different version")
        if archive.read("build/rastertoql580n") != (ROOT / "build/rastertoql580n").read_bytes():
            raise ValueError("source ZIP has a different filter")
        mode = archive.getinfo("Uninstall.command").external_attr >> 16
        if not mode & 0o111:
            raise ValueError("source ZIP uninstaller lost its executable bit")

    folder = f"QL-580N-macOS-Driver-v{release}-Setup"
    app = f"{folder}/QL-580N macOS Driver Setup.app/Contents"
    expected = {
        f"{folder}/README.md", f"{folder}/RELEASE_NOTES.md", f"{folder}/LICENSE",
        f"{app}/Info.plist", f"{app}/_CodeSignature/CodeResources",
        f"{app}/MacOS/QL580NSetup", f"{app}/Resources/LICENSE",
        f"{app}/Resources/QL580NIcon.icns",
        f"{app}/Resources/payload/scripts/install.sh",
        f"{app}/Resources/payload/scripts/uninstall.sh",
        f"{app}/Resources/payload/build/rastertoql580n",
        f"{app}/Resources/payload/ppd/Brother-QL-580N-Native.ppd",
        f"{app}/Resources/payload/assets/ql580n-native.icns",
    }
    expected.update(f"{folder}/docs/{name}" for name in ("DEVELOPING.md", "TESTED_MEDIA.md"))
    with zipfile.ZipFile(setup_path) as archive:
        actual = file_members(archive)
        if actual != expected:
            raise ValueError(f"setup ZIP members differ: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
        for name in archive.namelist():
            if name.startswith("__MACOSX/") and not name.endswith("/"):
                counterpart = name.removeprefix("__MACOSX/")
                parent, slash, filename = counterpart.rpartition("/")
                if not filename.startswith("._"):
                    raise ValueError(f"unknown ZIP metadata member: {name}")
                counterpart = parent + slash + filename[2:]
                if counterpart not in archive.namelist() and counterpart + "/" not in archive.namelist():
                    raise ValueError(f"ZIP metadata has no matching member: {name}")
        info = plistlib.loads(archive.read(f"{app}/Info.plist"))
        if info["CFBundleShortVersionString"] != release or info["CFBundleVersion"] != release:
            raise ValueError("app bundle versions do not match VERSION")
        if archive.read(f"{app}/Resources/payload/ppd/Brother-QL-580N-Native.ppd") != PPD.read_bytes():
            raise ValueError("setup app has a different PPD")
        if archive.read(f"{app}/Resources/payload/assets/ql580n-native.icns") != ICON.read_bytes():
            raise ValueError("setup app has a different printer icon")
        if archive.read(f"{app}/Resources/QL580NIcon.icns") != ICON.read_bytes():
            raise ValueError("setup app has a different app icon")
        if archive.read(f"{app}/Resources/payload/build/rastertoql580n") != (ROOT / "build/rastertoql580n").read_bytes():
            raise ValueError("setup app has a different filter")
        for script in ("install.sh", "uninstall.sh"):
            if archive.read(f"{app}/Resources/payload/scripts/{script}") != (ROOT / "scripts" / script).read_bytes():
                raise ValueError(f"setup app has a different {script}")
    expected_checksum = f"{hashlib.sha256(setup_path.read_bytes()).hexdigest()}  {setup_path.name}\n"
    if checksum_path.read_text(encoding="ascii") != expected_checksum:
        raise ValueError("setup ZIP checksum file does not match the archive")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ppd", action="store_true", help="check generated PPD and icon")
    parser.add_argument("--archives", action="store_true", help="check both versioned release ZIP files")
    args = parser.parse_args()
    if not args.ppd and not args.archives:
        parser.error("select --ppd or --archives")
    try:
        version()
        if args.ppd:
            check_ppd()
        if args.archives:
            check_archives()
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as error:
        print(f"release check failed: {error}", file=sys.stderr)
        return 1
    print("release check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
