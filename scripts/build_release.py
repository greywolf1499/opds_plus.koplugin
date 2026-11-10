#!/usr/bin/env python3
"""Build the release archive: dist/opds_plus.koplugin.zip and dist/opds_plus.koplugin.zip.sha256.

Only the paths in SHIPPED are packaged, and only the files git tracks or would add, so editor leftovers and
ignored files never ship. A Lua file in a directory that is neither shipped nor listed in NON_RUNTIME fails
the build: a new runtime directory missing from the list would otherwise give a plugin that cannot load.

The archive is deterministic: sorted entries, fixed permissions, and the time of the commit (or
SOURCE_DATE_EPOCH) on every entry, so the same commit gives the same bytes with the same zlib.

Usage: scripts/build_release.py [--tag vX.Y.Z]
  --tag  also require the tag to match VERSION in opds_plus_version.lua and the newest CHANGELOG.md entry
         (an empty value skips the check), and write that entry to dist/RELEASE_NOTES.md, the body of the
         GitHub release

Needs only Python 3 and git.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = "opds_plus.koplugin"

# What the release ships, relative to the repository root.
SHIPPED = (
    "main.lua",
    "_meta.lua",
    "opds_plus_version.lua",
    "LICENSE",
    "README.md",
    "CHANGELOG.md",
    "config",
    "core",
    "models",
    "services",
    "ui",
    "utils",
)
# Top-level directories that hold Lua code but are not part of the plugin.
NON_RUNTIME = ("spec", "scripts", "tools", "docs")
# Without these KOReader cannot load the plugin.
REQUIRED = ("main.lua", "_meta.lua", "opds_plus_version.lua")

DOS_EPOCH = 315532800  # zip timestamps cannot be earlier than 1980-01-01


class BuildError(Exception):
    pass


def git(*args):
    result = subprocess.run(["git", *args], cwd=ROOT, check=True, stdout=subprocess.PIPE)
    return result.stdout.decode("utf-8")


def git_files(*pathspec):
    """Files git tracks or would add (not ignored), relative to the repository root, sorted."""
    listing = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *pathspec)
    return sorted({name for name in listing.split("\0") if name})


def read_version():
    text = (ROOT / "opds_plus_version.lua").read_text(encoding="utf-8")
    match = re.search(r'VERSION\s*=\s*"([^"]+)"', text)
    if not match or not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?", match.group(1)):
        raise BuildError("opds_plus_version.lua has no valid VERSION")
    return match.group(1)


def check_tag(tag, version, changelog):
    if tag != "v" + version:
        raise BuildError(f"tag {tag} does not match VERSION {version} in opds_plus_version.lua")
    match = re.search(r"^## \[(\d[^\]]*)\]", changelog, re.MULTILINE)
    newest = match.group(1) if match else None
    if newest != version:
        raise BuildError(f"the newest CHANGELOG.md entry is {newest}, expected {version}")


def release_notes(changelog, version):
    """The text of a version's CHANGELOG.md entry, without its heading and the link definitions at the end."""
    heading = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n", changelog, re.MULTILINE)
    if not heading:
        raise BuildError(f"CHANGELOG.md has no entry for {version}")
    following = re.search(r"^## \[", changelog[heading.end() :], re.MULTILINE)
    body = changelog[heading.end() : heading.end() + following.start()] if following else changelog[heading.end() :]
    body = re.sub(r"^\[[^\]\n]+\]: \S+[ \t]*$\n?", "", body, flags=re.MULTILINE).strip()
    if not body:
        raise BuildError(f"the CHANGELOG.md entry for {version} is empty")
    return body + "\n"


def check_no_unlisted_lua():
    known = set(SHIPPED) | set(NON_RUNTIME)
    stray = [name for name in git_files("*.lua") if name.split("/")[0] not in known]
    if stray:
        raise BuildError(
            "Lua files outside the allow-list: "
            + ", ".join(stray)
            + "\nAdd their directory to SHIPPED (runtime code) or NON_RUNTIME (development only) in "
            + "scripts/build_release.py"
        )


def collect_files():
    files = git_files(*SHIPPED)
    for name in files:
        path = ROOT / name
        if not path.exists() and not path.is_symlink():
            raise BuildError(f"{name} is tracked by git but missing from the working tree")
        if path.is_symlink() or not path.is_file():
            raise BuildError(f"{name} is not a regular file")
    missing = [item for item in SHIPPED if not any(name == item or name.startswith(item + "/") for name in files)]
    if missing:
        raise BuildError("in SHIPPED but not in the repository: " + ", ".join(missing))
    return files


def archive_time():
    epoch = os.environ.get("SOURCE_DATE_EPOCH") or git("log", "-1", "--format=%ct").strip()
    return time.gmtime(max(int(epoch), DOS_EPOCH))[:6]


def write_archive(path, files):
    date_time = archive_time()
    directories = {NAME}
    for name in files:
        parts = name.split("/")[:-1]
        directories.update(NAME + "/" + "/".join(parts[: index + 1]) for index in range(len(parts)))

    entries = [(directory + "/", None) for directory in directories] + [(NAME + "/" + name, name) for name in files]
    with zipfile.ZipFile(path, "w") as archive:
        for entry_name, source in sorted(entries):
            info = zipfile.ZipInfo(entry_name, date_time)
            info.create_system = 3  # Unix, whatever machine builds it
            if source is None:
                info.external_attr = (0o40755 << 16) | 0x10
                info.compress_type = zipfile.ZIP_STORED
                archive.writestr(info, b"")
            else:
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, (ROOT / source).read_bytes(), compresslevel=9)


def verify_archive(path, files):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise BuildError("the archive failed its integrity test")
        names = archive.namelist()
        if any(not name.startswith(NAME + "/") for name in names):
            raise BuildError(f"the archive has entries outside {NAME}/")
        packed = sorted(name[len(NAME) + 1 :] for name in names if not name.endswith("/"))
        if packed != files:
            raise BuildError("the archive does not hold exactly the allow-listed files")
        for required in REQUIRED:
            if required not in packed:
                raise BuildError(f"the archive has no {required}")
        for name in files:
            if archive.read(NAME + "/" + name) != (ROOT / name).read_bytes():
                raise BuildError(f"{name} in the archive differs from the working tree")


def build(tag):
    version = read_version()
    notes = None
    if tag:
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        check_tag(tag, version, changelog)
        notes = release_notes(changelog, version)
    check_no_unlisted_lua()
    files = collect_files()

    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    notes_path = dist / "RELEASE_NOTES.md"
    if notes:
        notes_path.write_text(notes, encoding="utf-8")
    else:
        # an untagged build must not leave an older release's notes next to its archive
        notes_path.unlink(missing_ok=True)
    archive = dist / (NAME + ".zip")
    write_archive(archive, files)
    verify_archive(archive, files)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist / (NAME + ".zip.sha256")).write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
    print(f"Built {archive.relative_to(ROOT)}: version {version}, {len(files)} files, {archive.stat().st_size} bytes")
    print(f"sha256 {digest}")


def main():
    parser = argparse.ArgumentParser(description="Build the OPDS Plus release archive.")
    parser.add_argument("--tag", default="", help="release tag to verify, such as v1.4.0")
    args = parser.parse_args()
    try:
        build(args.tag)
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"error: {' '.join(error.cmd)} failed: is this a git checkout with a commit?", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
