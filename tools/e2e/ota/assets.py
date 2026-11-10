#!/usr/bin/env python3
"""Prepares the OTA e2e run from the release archive that scripts/build_release.py built.

  assets.py <dist zip> <work dir>

Extracts the archive as the installed plugin (<work>/kohome/plugins/opds_plus.koplugin) and writes
<work>/release.zip: the same archive with the next minor version, served as the newer release.
Prints "<installed version> <newer version>".
"""
import re
import sys
import zipfile
from pathlib import Path

NAME = "opds_plus.koplugin"
VERSION_FILE = NAME + "/opds_plus_version.lua"
WORK = re.compile(r"/tmp/opds_plus_test_e2e\.[A-Za-z0-9]+")


def main():
    source, work = Path(sys.argv[1]), Path(sys.argv[2])
    if not WORK.fullmatch(str(work)) or work.is_symlink() or not work.is_dir():
        sys.exit(f"refusing work dir {work}")
    plugins = work / "kohome" / "plugins"
    plugins.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(source) as archive:
        for name in archive.namelist():
            if not name.startswith(NAME + "/") or ".." in name.split("/"):
                sys.exit(f"unexpected entry {name}")
        archive.extractall(plugins)
        text = archive.read(VERSION_FILE).decode("utf-8")
        match = re.search(r'VERSION\s*=\s*"(\d+)\.(\d+)\.(\d+)"', text)
        if not match:
            sys.exit("no plain VERSION in opds_plus_version.lua")
        old = ".".join(match.groups())
        new = f"{match.group(1)}.{int(match.group(2)) + 1}.0"
        patched = text[: match.start()] + f'VERSION = "{new}"' + text[match.end():]
        with zipfile.ZipFile(work / "release.zip", "w") as release:
            for info in archive.infolist():
                data = patched.encode("utf-8") if info.filename == VERSION_FILE else archive.read(info)
                release.writestr(info, data)
    print(old, new)


if __name__ == "__main__":
    main()
