#!/usr/bin/env python3
"""Check publishable files, version consistency, local doc links, and license presence.

This is a small repository hygiene check, not a complete secret or license audit.
It checks tracked files and unignored new files without staging or changing them.
"""

import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
ERRORS = []


def fail(message):
    ERRORS.append(message)


def git(*arguments, git_dir=None):
    command = ["git", "-C", str(ROOT), "-c", "core.excludesFile=/dev/null"]
    if git_dir:
        command += [f"--git-dir={git_dir}", f"--work-tree={ROOT}"]
    return subprocess.check_output(command + list(arguments), stderr=subprocess.DEVNULL)


def candidate_files():
    try:
        top = Path(git("rev-parse", "--show-toplevel").decode().strip()).resolve()
    except subprocess.CalledProcessError:
        top = None
    arguments = ("ls-files", "--cached", "--others", "--exclude-standard", "-z")
    if top == ROOT:
        listing = git(*arguments)
    else:
        # Source archives have no .git directory. Use Git's ignore rules without
        # initializing the user's working directory or reading global exclusions.
        with tempfile.TemporaryDirectory(prefix="battery-flow-check-") as directory:
            subprocess.run(["git", "init", "--bare", "--quiet", directory], check=True)
            listing = git(*arguments, git_dir=directory)
    return sorted(set(listing.decode().rstrip("\0").split("\0")) - {""})


def main():
    files = candidate_files()
    public_paths = {(ROOT / name).resolve() for name in files}
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        fail("VERSION must contain a MAJOR.MINOR.PATCH release number")
    with (ROOT / "Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleShortVersionString") != version:
        fail("Resources/Info.plist and VERSION disagree")
    changelog = (ROOT / "CHANGELOG.md").read_text()
    if not re.search(r"^## " + re.escape(version) + r"(?:\s|$)", changelog, re.MULTILINE):
        fail("CHANGELOG.md must include the current release version")

    license_path = ROOT / "LICENSE"
    if not license_path.is_file():
        fail("LICENSE is missing: choose a license and confirm the copyright holder before publishing")
    else:
        license_text = license_path.read_text()
        if len(license_text.strip()) < 200 or re.search(
            r"\[(?:year|fullname)\]|<copyright holder>|TBD|TODO",
            license_text, re.IGNORECASE,
        ):
            fail("LICENSE appears incomplete or still contains template placeholders")

    generated = re.compile(
        r"(?:^|/)(?:build|\.build|\.swiftpm|DerivedData|rollback-[^/]+|__pycache__)(?:/|$)"
        r"|\.(?:app|dSYM)(?:/|$)|\.(?:jsonl|log|zip|tar\.gz|dmg|ips|pyc|p12|pfx|pem|key)$"
        r"|(?:^|/)(?:\.env(?:\.[^/]*)?|\.DS_Store|preferences[^/]*\.plist)$",
        re.IGNORECASE,
    )
    private_path = re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/")
    credentials = re.compile(
        r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
        r"|\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{30,})\b"
        r"|\bAKIA[0-9A-Z]{16}\b"
        r"|\bxox[baprs]-[A-Za-z0-9-]{20,}\b"
    )
    total_bytes = 0
    for name in files:
        path = ROOT / name
        if path.is_symlink():
            fail(f"{name}: review symlinks before publishing")
            continue
        if not path.is_file():
            fail(f"{name}: tracked file is missing; stage its deletion or restore it")
            continue
        if generated.search(name):
            fail(f"{name}: generated, private, or signing file must not be tracked")
        data = path.read_bytes()
        total_bytes += len(data)
        if len(data) > 1_000_000:
            fail(f"{name}: review files larger than 1 MB before publishing")
        try:
            content = data.decode("utf-8")
        except UnicodeDecodeError:
            fail(f"{name}: unexpected binary file; review its origin and distribution rights")
            continue
        for pattern, label in ((private_path, "personal absolute path"), (credentials, "possible credential")):
            match = pattern.search(content)
            if match:
                line = content.count("\n", 0, match.start()) + 1
                fail(f"{name}:{line}: {label}; inspect locally without sharing its value")
        if path.suffix == ".md":
            # Check inline relative links. Web links and headings are outside this check.
            for target in re.findall(r"\]\(([^\s)]+)\)", content):
                parsed = urlsplit(target.strip("<>"))
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                destination = (path.parent / unquote(parsed.path)).resolve()
                if destination not in public_paths:
                    fail(f"{name}: local link is missing or excluded from publication: {target}")

    print(f"Checked {len(files)} candidate files ({total_bytes / 1024:.1f} KiB); version {version}.")
    if ERRORS:
        for error in ERRORS:
            print(f"ERROR: {error}")
        return 1
    print("Repository hygiene checks passed. Review provenance and the staged diff before publishing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
