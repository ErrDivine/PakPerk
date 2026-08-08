#!/usr/bin/env python3
"""Safely extract an attested store-client tarball into a fresh local root."""

from __future__ import annotations

import argparse
import os
import pathlib
import stat
import sys
import tarfile
import tempfile
from typing import Sequence


MAXIMUM_MEMBERS = 100_000
MAXIMUM_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_TREE_BYTES = 2 * 1024 * 1024 * 1024


class ExtractionError(ValueError):
    """The store-client archive violated its closed extraction contract."""


def _real_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    raw = os.fspath(path)
    real = pathlib.Path(os.path.realpath(raw))
    if real != path:
        raise ExtractionError(f"{label} is not an exact real path")
    metadata = real.lstat()
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
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
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
        raise ExtractionError(f"{label} is not an owner-controlled real directory")
    return real


def _relative_member(name: str) -> pathlib.PurePosixPath:
    if (
        not name
        or len(name.encode("utf-8")) > 4096
        or any(character in name for character in ("\x00", "\n", "\r", "\\"))
    ):
        raise ExtractionError("store-client archive member name is malformed")
    relative = pathlib.PurePosixPath(name)
    if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
        raise ExtractionError("store-client archive member escaped its extraction root")
    return relative


def extract(
    *, archive: pathlib.Path, parent: pathlib.Path, output: pathlib.Path
) -> pathlib.Path:
    parent = _real_directory(parent, "store-client extraction parent")
    archive_metadata = archive.lstat()
    if (
        not stat.S_ISREG(archive_metadata.st_mode)
        or archive_metadata.st_uid != os.getuid()
        or archive_metadata.st_nlink != 1
        or archive_metadata.st_size <= 0
        or archive_metadata.st_size > MAXIMUM_TREE_BYTES
    ):
        raise ExtractionError("store-client archive is not one bounded regular file")
    archive_descriptor = os.open(
        archive, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    )
    opened_archive = os.fstat(archive_descriptor)
    archive_identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if archive_identity(archive_metadata) != archive_identity(opened_archive):
        os.close(archive_descriptor)
        raise ExtractionError("store-client archive changed before extraction")
    root = pathlib.Path(tempfile.mkdtemp(prefix="pakperk-store-client.", dir=parent))
    root.chmod(0o700)
    try:
        with os.fdopen(archive_descriptor, "rb", closefd=True) as archive_stream:
            with tarfile.open(fileobj=archive_stream, mode="r:gz") as source:
                members: list[tarfile.TarInfo] = []
                for member in source:
                    if len(members) >= MAXIMUM_MEMBERS:
                        raise ExtractionError(
                            "store-client archive member count is invalid"
                        )
                    members.append(member)
            if not members:
                raise ExtractionError("store-client archive member count is invalid")
            after_archive = os.fstat(archive_stream.fileno())
            if archive_identity(opened_archive) != archive_identity(after_archive):
                raise ExtractionError("store-client archive changed during extraction")
            archive_stream.seek(0)
            with tarfile.open(fileobj=archive_stream, mode="r:gz") as source:
                by_name: dict[pathlib.PurePosixPath, tarfile.TarInfo] = {}
                total_bytes = 0
                for member in members:
                    relative = _relative_member(member.name)
                    if relative in by_name:
                        raise ExtractionError("store-client archive member is duplicated")
                    if not member.isdir() and not member.isreg():
                        raise ExtractionError("store-client archive contains a link or special file")
                    if member.mode & 0o022:
                        raise ExtractionError("store-client archive member is writable by another user")
                    if member.size < 0 or member.size > MAXIMUM_FILE_BYTES:
                        raise ExtractionError("store-client archive member size is invalid")
                    total_bytes += member.size
                    if total_bytes > MAXIMUM_TREE_BYTES:
                        raise ExtractionError("store-client archive exceeded its extraction budget")
                    by_name[relative] = member

                directories = {
                    path
                    for path, member in by_name.items()
                    if member.isdir()
                }
                for path in by_name:
                    for index in range(1, len(path.parts)):
                        directories.add(pathlib.PurePosixPath(*path.parts[:index]))
                for relative in sorted(directories, key=lambda value: (len(value.parts), value.parts)):
                    destination = root.joinpath(*relative.parts)
                    destination.mkdir(mode=0o700)

                for relative, member in sorted(by_name.items(), key=lambda item: item[0].parts):
                    destination = root.joinpath(*relative.parts)
                    if member.isdir():
                        continue
                    stream = source.extractfile(member)
                    if stream is None:
                        raise ExtractionError("store-client archive file has no data stream")
                    descriptor = os.open(
                        destination,
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | getattr(os, "O_NOFOLLOW", 0),
                        0o600,
                    )
                    remaining = member.size
                    try:
                        while remaining:
                            chunk = stream.read(min(1024 * 1024, remaining))
                            if not chunk:
                                raise ExtractionError("store-client archive file ended early")
                            view = memoryview(chunk)
                            while view:
                                written = os.write(descriptor, view)
                                if written <= 0:
                                    raise ExtractionError("store-client extraction did not progress")
                                view = view[written:]
                            remaining -= len(chunk)
                        if stream.read(1):
                            raise ExtractionError("store-client archive file exceeded its header size")
                        os.fchmod(descriptor, member.mode & 0o777)
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)

                for relative in sorted(
                    directories, key=lambda value: (len(value.parts), value.parts), reverse=True
                ):
                    member = by_name.get(relative)
                    mode = (member.mode & 0o777) if member is not None else 0o700
                    root.joinpath(*relative.parts).chmod(mode)
            final_archive = os.fstat(archive_stream.fileno())
            if archive_identity(opened_archive) != archive_identity(final_archive):
                raise ExtractionError("store-client archive changed during extraction")
        with output.open("a", encoding="utf-8") as handle:
            handle.write(f"root={root}\n")
        return root
    except Exception:
        # The ephemeral runner is discarded on failure. Avoid recursive deletion of a
        # partially validated tree from this fail-closed extraction path.
        raise


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--parent", type=pathlib.Path, required=True)
    parser.add_argument("--github-output", type=pathlib.Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        extract(
            archive=arguments.archive,
            parent=arguments.parent,
            output=arguments.github_output,
        )
    except (OSError, tarfile.TarError, ExtractionError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
