#!/usr/bin/env python3
"""Capture immutable runner PATH, HOME, Ruby, and RubyGems identities."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import shutil
import stat
import sys
from typing import Sequence


def _real_directory(raw: str, label: str, *, require_owner: bool) -> str:
    if (
        not raw
        or len(raw) > 4096
        or any(character in raw for character in ("\x00", "\n", "\r"))
        or not os.path.isabs(raw)
    ):
        raise ValueError(f"{label} is not one bounded absolute path")
    real = os.path.realpath(raw)
    metadata = os.lstat(real)
    descriptor = os.open(
        real,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_mode & 0o022
        or (require_owner and metadata.st_uid != os.getuid())
        or (metadata.st_dev, metadata.st_ino, metadata.st_mode)
        != (opened.st_dev, opened.st_ino, opened.st_mode)
    ):
        raise ValueError(f"{label} is not a reviewed real directory")
    return real


def _real_executable(name: str, reviewed_path: str) -> tuple[str, str]:
    resolved = shutil.which(name, path=reviewed_path)
    if resolved is None:
        raise ValueError(f"reviewed {name} executable is unavailable")
    real = os.path.realpath(resolved)
    metadata = os.lstat(real)
    descriptor = os.open(real, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    digest = hashlib.sha256()
    try:
        before = os.fstat(descriptor)
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o022
        or not metadata.st_mode & 0o100
        or identity(metadata) != identity(before)
        or identity(before) != identity(after)
    ):
        raise ValueError(f"reviewed {name} is not one immutable executable")
    return real, digest.hexdigest()


def capture(*, output: pathlib.Path) -> dict[str, str]:
    inherited_path = os.environ.get("PATH", "")
    if (
        not inherited_path
        or len(inherited_path) > 32768
        or any(character in inherited_path for character in ("\x00", "\n", "\r"))
    ):
        raise ValueError("runner PATH is missing or malformed")
    reviewed_entries: list[str] = []
    for entry in inherited_path.split(":"):
        try:
            reviewed = _real_directory(
                entry, "runner PATH entry", require_owner=False
            )
        except (FileNotFoundError, ValueError):
            continue
        if reviewed not in reviewed_entries:
            reviewed_entries.append(reviewed)
    if not reviewed_entries:
        raise ValueError("runner PATH has no reviewed real directories")
    reviewed_path = ":".join(reviewed_entries)
    real_home = _real_directory(
        os.environ.get("HOME", ""), "runner HOME", require_owner=True
    )
    ruby_bin, ruby_sha256 = _real_executable("ruby", reviewed_path)
    gem_bin, gem_sha256 = _real_executable("gem", reviewed_path)
    values = {
        "reviewed_path": reviewed_path,
        "real_home": real_home,
        "ruby_bin": ruby_bin,
        "ruby_sha256": ruby_sha256,
        "gem_bin": gem_bin,
        "gem_sha256": gem_sha256,
    }
    with output.open("a", encoding="utf-8") as handle:
        for name, value in values.items():
            handle.write(f"{name}={value}\n")
    return values


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", type=pathlib.Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        capture(output=arguments.github_output)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
