#!/usr/bin/env python3
"""Capture or verify the immutable mobile store-client installation tree."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import stat
import sys
from dataclasses import dataclass
from typing import Sequence


SHA256 = re.compile(r"[0-9a-f]{64}")
POSITIVE_INTEGER = re.compile(r"[1-9][0-9]{0,31}")
MAXIMUM_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_TREE_BYTES = 2 * 1024 * 1024 * 1024


class ValidationError(ValueError):
    """The store-client installation failed its closed trust contract."""


@dataclass(frozen=True)
class Attestation:
    root_device: int
    root_inode: int
    bundle_sha256: str
    tree_sha256: str


def _identity(
    metadata: os.stat_result,
) -> tuple[int, int, int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _real_path(raw: pathlib.Path, root: pathlib.Path, label: str) -> pathlib.Path:
    text = os.fspath(raw)
    if (
        not text
        or len(text) > 4096
        or any(character in text for character in ("\x00", "\n", "\r"))
        or not os.path.isabs(text)
    ):
        raise ValidationError(f"{label} is not one bounded absolute path")
    real = pathlib.Path(os.path.realpath(text))
    if real != raw or os.path.commonpath((root, real)) != os.fspath(root):
        raise ValidationError(f"{label} escaped the exact real store-client root")
    return real


def _directory(path: pathlib.Path, label: str, *, owner_only: bool = False) -> os.stat_result:
    metadata = path.lstat()
    descriptor = os.open(
        path,
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
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & (0o077 if owner_only else 0o022)
        or (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
            metadata.st_mode,
            metadata.st_ctime_ns,
        )
        != (
            opened.st_dev,
            opened.st_ino,
            opened.st_uid,
            opened.st_mode,
            opened.st_ctime_ns,
        )
    ):
        raise ValidationError(f"{label} is not an owner-controlled real directory")
    return metadata


def _regular_digest(
    path: pathlib.Path,
    label: str,
    *,
    executable: bool = False,
) -> tuple[os.stat_result, str]:
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o022
        or metadata.st_size > MAXIMUM_FILE_BYTES
        or (executable and not metadata.st_mode & 0o100)
    ):
        raise ValidationError(f"{label} is not one owner-controlled regular file")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
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
    if _identity(metadata) != _identity(before) or _identity(before) != _identity(after):
        raise ValidationError(f"{label} changed while it was read")
    return metadata, digest.hexdigest()


def attest(
    *,
    root: pathlib.Path,
    bundle_bin: pathlib.Path,
    gem_home: pathlib.Path,
    bundle_gemfile: pathlib.Path,
    bundle_lockfile: pathlib.Path,
    bundle_path: pathlib.Path,
    bundle_app_config: pathlib.Path,
    client_home: pathlib.Path,
) -> Attestation:
    root_text = os.fspath(root)
    if pathlib.Path(os.path.realpath(root_text)) != root:
        raise ValidationError("store-client root is not an exact real path")
    root_metadata = _directory(root, "store-client root", owner_only=True)
    expected_directories = {
        _real_path(gem_home, root, "GEM_HOME"),
        _real_path(bundle_path, root, "BUNDLE_PATH"),
        _real_path(bundle_app_config, root, "BUNDLE_APP_CONFIG"),
        _real_path(client_home, root, "store-client HOME"),
    }
    for path in expected_directories:
        _directory(
            path,
            "store-client HOME" if path == client_home else "store-client storage",
            owner_only=path == client_home,
        )
    bundle_bin = _real_path(bundle_bin, root, "bundle executable")
    bundle_gemfile = _real_path(bundle_gemfile, root, "reviewed Gemfile")
    bundle_lockfile = _real_path(bundle_lockfile, root, "reviewed Gemfile.lock")
    _, bundle_sha256 = _regular_digest(
        bundle_bin, "bundle executable", executable=True
    )
    _regular_digest(bundle_gemfile, "reviewed Gemfile")
    _regular_digest(bundle_lockfile, "reviewed Gemfile.lock")

    records: list[str] = []
    total_bytes = 0
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        for name in [*directories, *files]:
            path = pathlib.Path(current, name)
            relative = path.relative_to(root).as_posix()
            if any(character in relative for character in ("\x00", "\n", "\r")):
                raise ValidationError("store-client path contains a control character")
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                _directory(path, "store-client tree directory")
                records.append(f"d {metadata.st_mode & 0o777:o} {relative}\n")
                continue
            metadata, digest = _regular_digest(path, "store-client tree file")
            total_bytes += metadata.st_size
            if total_bytes > MAXIMUM_TREE_BYTES:
                raise ValidationError("store-client tree exceeded its attestation budget")
            records.append(
                f"f {metadata.st_mode & 0o777:o} {metadata.st_size} {digest} {relative}\n"
            )
    tree_sha256 = hashlib.sha256("".join(records).encode("utf-8")).hexdigest()
    return Attestation(
        root_device=root_metadata.st_dev,
        root_inode=root_metadata.st_ino,
        bundle_sha256=bundle_sha256,
        tree_sha256=tree_sha256,
    )


def _common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-bin", type=pathlib.Path, required=True)
    parser.add_argument("--gem-home", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-gemfile", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-lockfile", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-path", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-app-config", type=pathlib.Path, required=True)
    parser.add_argument("--client-home", type=pathlib.Path, required=True)


def _attest_from_arguments(arguments: argparse.Namespace) -> Attestation:
    return attest(
        root=arguments.root,
        bundle_bin=arguments.bundle_bin,
        gem_home=arguments.gem_home,
        bundle_gemfile=arguments.bundle_gemfile,
        bundle_lockfile=arguments.bundle_lockfile,
        bundle_path=arguments.bundle_path,
        bundle_app_config=arguments.bundle_app_config,
        client_home=arguments.client_home,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    capture = subparsers.add_parser("capture")
    _common_arguments(capture)
    capture.add_argument("--github-output", type=pathlib.Path, required=True)
    restore = subparsers.add_parser("restore")
    _common_arguments(restore)
    restore.add_argument("--bundle-sha256", required=True)
    restore.add_argument("--tree-sha256", required=True)
    restore.add_argument("--github-output", type=pathlib.Path, required=True)
    verify = subparsers.add_parser("verify")
    _common_arguments(verify)
    verify.add_argument("--root-device", required=True)
    verify.add_argument("--root-inode", required=True)
    verify.add_argument("--bundle-sha256", required=True)
    verify.add_argument("--tree-sha256", required=True)
    arguments = parser.parse_args(argv)

    try:
        value = _attest_from_arguments(arguments)
        if arguments.operation == "capture":
            with arguments.github_output.open("a", encoding="utf-8") as output:
                output.write(f"root_device={value.root_device}\n")
                output.write(f"root_inode={value.root_inode}\n")
                output.write(f"bundle_bin_sha256={value.bundle_sha256}\n")
                output.write(f"tree_sha256={value.tree_sha256}\n")
            return 0
        if arguments.operation == "restore":
            if (
                SHA256.fullmatch(arguments.bundle_sha256) is None
                or SHA256.fullmatch(arguments.tree_sha256) is None
                or value.bundle_sha256 != arguments.bundle_sha256
                or value.tree_sha256 != arguments.tree_sha256
            ):
                raise ValidationError("restored store-client content identity changed")
            with arguments.github_output.open("a", encoding="utf-8") as output:
                output.write(f"root_device={value.root_device}\n")
                output.write(f"root_inode={value.root_inode}\n")
                output.write(f"bundle_bin_sha256={value.bundle_sha256}\n")
                output.write(f"tree_sha256={value.tree_sha256}\n")
            return 0
        if (
            POSITIVE_INTEGER.fullmatch(arguments.root_device) is None
            or POSITIVE_INTEGER.fullmatch(arguments.root_inode) is None
            or SHA256.fullmatch(arguments.bundle_sha256) is None
            or SHA256.fullmatch(arguments.tree_sha256) is None
            or value.root_device != int(arguments.root_device)
            or value.root_inode != int(arguments.root_inode)
            or value.bundle_sha256 != arguments.bundle_sha256
            or value.tree_sha256 != arguments.tree_sha256
        ):
            raise ValidationError("store-client tree changed after installation")
    except (OSError, ValidationError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
