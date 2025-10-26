#!/usr/bin/env python3
"""Update config.yaml version field from the latest git tag."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = REPO_ROOT / "config.yaml"
VERSION_PATTERN = re.compile(r'^(version:\s*["\']?)([^"\']+)(["\']?)', re.MULTILINE)
DEFAULT_VERSION = "0.0.0"


def run_git_command(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ("git",) + args,
        cwd=REPO_ROOT,
        check=False,
        text=True,
        capture_output=True,
    )


def get_current_version() -> str:
    if not CONFIG_PATH.exists():
        return DEFAULT_VERSION

    contents = CONFIG_PATH.read_text()
    match = VERSION_PATTERN.search(contents)
    if match:
        return match.group(2).strip()
    return DEFAULT_VERSION


def determine_version(fallback: str) -> str:
    candidates: list[str] = []

    describe = run_git_command("describe", "--tags", "--abbrev=0")
    if describe.returncode == 0 and describe.stdout.strip():
        candidates.append(describe.stdout.strip())

    tags = run_git_command("tag", "--sort=-creatordate")
    if tags.returncode == 0:
        for tag in tags.stdout.splitlines():
            if tag:
                candidates.append(tag)

    semver_re = re.compile(
        r"""
        ^
        v?
        (?P<major>0|[1-9]\d*)
        \.
        (?P<minor>0|[1-9]\d*)
        \.
        (?P<patch>0|[1-9]\d*)
        (?P<rest>[-+][0-9A-Za-z.-]+)?
        $
        """,
        re.VERBOSE,
    )

    for raw in candidates:
        match = semver_re.match(raw)
        if match:
            version = raw[1:] if raw.startswith("v") else raw
            return version

    return fallback


def update_config(version: str, current_version: str) -> bool:
    if not CONFIG_PATH.exists():
        print(f"config.yaml not found at {CONFIG_PATH}", file=sys.stderr)
        return False

    contents = CONFIG_PATH.read_text()
    match = VERSION_PATTERN.search(contents)
    if not match:
        print("Unable to locate version field in config.yaml", file=sys.stderr)
        return False

    new_contents = VERSION_PATTERN.sub(rf"\g<1>{version}\3", contents, count=1)
    if new_contents != contents:
        CONFIG_PATH.write_text(new_contents)
        print(f"config.yaml version updated to {version}")
        return True

    print(f"config.yaml version already up to date ({current_version})")
    return True


def main() -> int:
    current_version = get_current_version()
    version = determine_version(current_version)
    if update_config(version, current_version):
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
