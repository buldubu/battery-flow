#!/usr/bin/env python3
"""Check repository hygiene in the working tree or the exact staged snapshot."""

import argparse
import plistlib
import posixpath
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


def read_files(staged):
    result = {}
    if staged:
        if Path(git("rev-parse", "--show-toplevel").decode().strip()).resolve() != ROOT:
            raise ValueError("staged checks must run in the project Git repository")
        for entry in git("ls-files", "--stage", "-z").split(b"\0"):
            if not entry:
                continue
            metadata, name_bytes = entry.split(b"\t", 1)
            mode, object_id, stage = metadata.decode().split()
            name = name_bytes.decode()
            if stage != "0":
                fail(f"{name}: resolve the merge conflict before committing")
            elif mode not in ("100644", "100755"):
                fail(f"{name}: symlinks and submodules require review before publication")
            elif int(git("cat-file", "-s", object_id)) > 1_000_000:
                fail(f"{name}: review files larger than 1 MB before publishing")
            else:
                result[name] = git("cat-file", "blob", object_id)
    else:
        for name in candidate_files():
            path = ROOT / name
            if path.is_symlink():
                fail(f"{name}: review symlinks before publishing")
            elif not path.is_file():
                fail(f"{name}: tracked file is missing; stage its deletion or restore it")
            elif path.stat().st_size > 1_000_000:
                fail(f"{name}: review files larger than 1 MB before publishing")
            else:
                result[name] = path.read_bytes()
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="read files from the Git index")
    args = parser.parse_args(argv)
    ERRORS.clear()
    try:
        files = read_files(args.staged)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: unable to read repository snapshot: {error}")
        return 1
    public_paths = set(files)
    def read_text(name):
        try:
            return files.get(name, b"").decode("utf-8")
        except UnicodeDecodeError:
            fail(f"{name}: expected a UTF-8 text file")
            return ""
    version = read_text("VERSION").strip()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        fail("VERSION must contain a MAJOR.MINOR.PATCH release number")
    try:
        info = plistlib.loads(files.get("Resources/Info.plist", b""))
    except (plistlib.InvalidFileException, ValueError):
        info = {}
        fail("Resources/Info.plist is missing or invalid in the checked snapshot")
    if info.get("CFBundleShortVersionString") != version:
        fail("Resources/Info.plist and VERSION disagree")
    changelog = read_text("CHANGELOG.md")
    if not re.search(r"^## " + re.escape(version) + r"(?:\s|$)", changelog, re.MULTILINE):
        fail("CHANGELOG.md must include the current release version")

    if "LICENSE" not in files:
        fail("LICENSE is missing: choose a license and confirm the copyright holder before publishing")
    else:
        license_text = read_text("LICENSE")
        if len(license_text.strip()) < 200 or re.search(
            r"\[(?:year|fullname)\]|<copyright holder>|TBD|TODO",
            license_text, re.IGNORECASE,
        ):
            fail("LICENSE appears incomplete or still contains template placeholders")

    generated = re.compile(
        r"(?:^|/)(?:build|\.build|\.swiftpm|DerivedData|rollback-[^/]+|__pycache__)(?:/|$)"
        r"|\.(?:app|dSYM)(?:/|$)|\.(?:jsonl|log|sample\.txt|zip|tar\.gz|dmg|ips|pyc|p12|pfx|pem|key|mobileprovision|provisionprofile)$"
        r"|(?:^|/)(?:\.env(?:\.[^/]*)?|\.DS_Store|preferences[^/]*\.plist)$",
        re.IGNORECASE,
    )
    private_path = re.compile(r"/(?:Users|home)/[^/\r\n\"']+/")
    credentials = re.compile(
        r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
        r"|\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{30,})\b"
        r"|\bAKIA[0-9A-Z]{16}\b"
        r"|\bxox[baprs]-[A-Za-z0-9-]{20,}\b"
    )
    total_bytes = 0
    for name, data in files.items():
        if generated.search(name):
            fail(f"{name}: generated, private, or signing file must not be tracked")
        total_bytes += len(data)
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
        for number, line in enumerate(content.splitlines(), 1):
            if line.endswith((" ", "\t")):
                fail(f"{name}:{number}: trailing whitespace")
        if content and not content.endswith("\n"):
            fail(f"{name}: missing final newline")
        if Path(name).suffix == ".md":
            # Check inline relative links. Web links and headings are outside this check.
            for target in re.findall(r"\]\(([^\s)]+)\)", content):
                parsed = urlsplit(target.strip("<>"))
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                # Normalize lexically: unstaged symlinks must not affect index checks.
                destination = posixpath.normpath(posixpath.join(posixpath.dirname(name), unquote(parsed.path)))
                if destination not in public_paths:
                    fail(f"{name}: local link is missing or excluded from publication: {target}")

    snapshot = "staged" if args.staged else "candidate"
    print(f"Checked {len(files)} {snapshot} files ({total_bytes / 1024:.1f} KiB); version {version}.")
    if ERRORS:
        for error in ERRORS:
            print(f"ERROR: {error}")
        return 1
    print("Repository hygiene checks passed. Review provenance and the staged diff before publishing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
