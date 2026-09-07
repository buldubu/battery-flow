#!/usr/bin/env python3
"""Validate a version tag and prepare verified macOS release assets."""

import argparse
import hashlib
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def version_for_tag(tag):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("release tags must have the form vMAJOR.MINOR.PATCH")
    return tag[1:]


def notes_for_version(changelog, version):
    match = re.search(r"^## " + re.escape(version) + r"(?:[ \t]+[^\n]*)?\n(.*?)(?=^## |\Z)",
                      changelog, re.MULTILINE | re.DOTALL)
    if not match or not match[1].strip():
        raise ValueError("the release version needs a nonempty changelog entry")
    return match[1].strip() + "\n"


def check_version(tag):
    version = version_for_tag(tag)
    if (ROOT / "VERSION").read_text().strip() != version:
        raise ValueError("the tag does not match VERSION")
    with (ROOT / "Resources/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleShortVersionString") != version:
            raise ValueError("the tag does not match Resources/Info.plist")
    return version, notes_for_version((ROOT / "CHANGELOG.md").read_text(), version)


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], stderr=subprocess.DEVNULL).decode().strip()


def validate_tag(tag):
    check_version(tag)
    if git("rev-parse", f"refs/tags/{tag}^{{commit}}") != git("rev-parse", "HEAD"):
        raise ValueError("the tag must point to the checked-out commit")
    ancestry = subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", "HEAD", "origin/main"],
                              stderr=subprocess.DEVNULL)
    if ancestry.returncode:
        raise ValueError("the release commit must already be on origin/main")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("release validation requires a clean checkout")
    print(f"Validated {tag} at a commit on main.")


def package(tag):
    version, notes = check_version(tag)
    app = ROOT / "build/BatteryFlow.app"
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleShortVersionString") != version:
            raise ValueError("the built app version does not match the tag")
    for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        if (ROOT / notice).read_bytes() != (app / "Contents/Resources" / notice).read_bytes():
            raise ValueError(f"the app is missing the current {notice}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architectures = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/BatteryFlow")]).decode().strip()
    if architectures != "arm64":
        raise ValueError("the release asset must contain an arm64 application")
    output = ROOT / "build/releases"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"BatteryFlow-{version}-arm64.zip"
    with tempfile.TemporaryDirectory(prefix="package-", dir=output) as temporary:
        candidate = Path(temporary) / archive.name
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(candidate)], check=True)
        candidate.replace(archive)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{checksum}  {archive.name}\n")
    notes += "\nThis Apple silicon build is ad-hoc signed and has not been notarized by Apple.\n"
    (output / "RELEASE_NOTES.md").write_text(notes)
    print(f"Prepared {archive.name}, SHA256SUMS, and release notes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "package"))
    parser.add_argument("tag")
    args = parser.parse_args()
    try:
        (validate_tag if args.command == "validate" else package)(args.tag)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release check failed: {error}\n")


if __name__ == "__main__":
    main()
