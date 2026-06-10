#!/usr/bin/env python3
"""Bump the app version in the Xcode project.

Increments MARKETING_VERSION (semver) and CURRENT_PROJECT_VERSION (a monotonic
build number that Sparkle uses to order updates — see ADR 0010). Prints
"<new_marketing_version> <new_build>" on stdout for the release script.

Usage: bump_version.py {patch|minor|major}
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PBXPROJ = Path("Engram/Engram.xcodeproj/project.pbxproj")


def bump_semver(version: str, part: str) -> str:
    major, minor, patch = (int(component) for component in (version.split(".") + ["0", "0", "0"])[:3])
    if part == "major":
        major, minor, patch = major + 1, 0, 0
    elif part == "minor":
        minor, patch = minor + 1, 0
    elif part == "patch":
        patch += 1
    else:
        raise SystemExit(f"unknown bump part: {part!r} (use patch|minor|major)")
    return f"{major}.{minor}.{patch}"


def main(part: str) -> None:
    text = PBXPROJ.read_text()

    marketing_match = re.search(r"MARKETING_VERSION = ([0-9][0-9.]*);", text)
    build_match = re.search(r"CURRENT_PROJECT_VERSION = ([0-9]+);", text)
    if marketing_match is None or build_match is None:
        raise SystemExit("could not find version settings in project.pbxproj")

    new_marketing = bump_semver(marketing_match.group(1), part)
    new_build = str(int(build_match.group(1)) + 1)

    text = re.sub(r"MARKETING_VERSION = [0-9][0-9.]*;", f"MARKETING_VERSION = {new_marketing};", text)
    text = re.sub(r"CURRENT_PROJECT_VERSION = [0-9]+;", f"CURRENT_PROJECT_VERSION = {new_build};", text)
    PBXPROJ.write_text(text)

    print(f"{new_marketing} {new_build}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: bump_version.py {patch|minor|major}")
    main(sys.argv[1])
