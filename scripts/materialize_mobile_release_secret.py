#!/usr/bin/env python3
"""Materialize mobile release secrets without following attacker-planted links."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import pathlib
import re
import stat
import sys
from typing import Sequence


MAXIMUM_SECRET_BYTES = 16 * 1024 * 1024
ENVIRONMENT_NAME = re.compile(r"[A-Z][A-Z0-9_]{0,127}")
SAFE_FILENAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


class MaterializationError(ValueError):
    """A fail-closed secret materialization error."""


def _identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_uid,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _relative_parts(value: str, label: str) -> tuple[str, ...]:
    path = pathlib.PurePath(value)
    parts = path.parts
    if (
        path.is_absolute()
        or not parts
        or any(part in {"", ".", ".."} for part in parts)
        or any("/" in part or "\x00" in part for part in parts)
    ):
        raise MaterializationError(f"{label} is not a safe relative path")
    return parts


def _validate_directory(metadata: os.stat_result, label: str) -> None:
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
    ):
        raise MaterializationError(
            f"{label} is not an owner-controlled real directory"
        )


def _open_root(path: pathlib.Path) -> int:
    try:
        linked = os.lstat(path)
    except OSError as error:
        raise MaterializationError("trusted secret root is unavailable") from error
    _validate_directory(linked, "trusted secret root")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise MaterializationError("trusted secret root could not be opened") from error
    opened = os.fstat(descriptor)
    try:
        _validate_directory(opened, "trusted secret root")
        if _identity(linked) != _identity(opened):
            raise MaterializationError("trusted secret root changed while opening")
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def _open_child_directory(parent: int, name: str, *, create: bool, exclusive: bool) -> int:
    created = False
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
            created = True
        except FileExistsError:
            if exclusive:
                raise MaterializationError("exclusive secret directory already exists")
        except OSError as error:
            raise MaterializationError("secret directory could not be created") from error
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent)
    except OSError as error:
        raise MaterializationError("secret directory is not a real directory") from error
    try:
        metadata = os.fstat(descriptor)
        _validate_directory(metadata, "secret directory")
        if created:
            os.fchmod(descriptor, 0o700)
            metadata = os.fstat(descriptor)
            if stat.S_IMODE(metadata.st_mode) != 0o700:
                raise MaterializationError("exclusive secret directory is not owner-only")
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def _walk_directory(
    root_descriptor: int,
    parts: tuple[str, ...],
    *,
    exclusive: bool,
) -> int:
    current = os.dup(root_descriptor)
    try:
        for part in parts:
            child = _open_child_directory(
                current,
                part,
                create=True,
                exclusive=exclusive,
            )
            os.close(current)
            current = child
        return current
    except Exception:
        os.close(current)
        raise


def _write_exclusive(parent: int, filename: str, content: bytes) -> None:
    if SAFE_FILENAME.fullmatch(filename) is None:
        raise MaterializationError("secret filename is invalid")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(filename, flags, 0o600, dir_fd=parent)
    except OSError as error:
        raise MaterializationError("secret output already exists or is unsafe") from error
    try:
        os.fchmod(descriptor, 0o600)
        remaining = memoryview(content)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise MaterializationError("secret write did not make progress")
            remaining = remaining[written:]
        os.fsync(descriptor)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_size != len(content)
        ):
            raise MaterializationError("secret output is not owner-only regular storage")
        linked = os.stat(filename, dir_fd=parent, follow_symlinks=False)
        if _identity(opened) != _identity(linked):
            raise MaterializationError("secret output changed while it was written")
    finally:
        os.close(descriptor)


def _decode_secret(environment_name: str, maximum_bytes: int) -> bytes:
    if ENVIRONMENT_NAME.fullmatch(environment_name) is None:
        raise MaterializationError("secret environment name is invalid")
    if not 0 < maximum_bytes <= MAXIMUM_SECRET_BYTES:
        raise MaterializationError("secret byte bound is invalid")
    encoded = os.environ.get(environment_name)
    if not isinstance(encoded, str) or not encoded:
        raise MaterializationError("protected secret is empty")
    maximum_encoded = 4 * ((maximum_bytes + 2) // 3)
    if len(encoded) > maximum_encoded:
        raise MaterializationError("protected secret exceeds its encoded bound")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise MaterializationError("protected secret is not strict base64") from error
    if not 0 < len(decoded) <= maximum_bytes:
        raise MaterializationError("protected secret exceeds its decoded bound")
    return decoded


def _read_source(path: pathlib.Path, maximum_bytes: int) -> bytes:
    if not 0 < maximum_bytes <= MAXIMUM_SECRET_BYTES:
        raise MaterializationError("secret byte bound is invalid")
    try:
        linked = os.lstat(path)
    except OSError as error:
        raise MaterializationError("protected source is unavailable") from error
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.getuid()
        or linked.st_nlink != 1
        or linked.st_mode & 0o077
        or not 0 < linked.st_size <= maximum_bytes
    ):
        raise MaterializationError("protected source is not bounded owner-only storage")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise MaterializationError("protected source could not be opened") from error
    try:
        before = os.fstat(descriptor)
        if _identity(linked) != _identity(before):
            raise MaterializationError("protected source changed while opening")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        content = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            _identity(before) != _identity(after)
            or len(content) != before.st_size
            or not 0 < len(content) <= maximum_bytes
        ):
            raise MaterializationError("protected source changed while it was read")
        return content
    finally:
        os.close(descriptor)


def validate_protected_file(path: pathlib.Path, maximum_bytes: int) -> None:
    """Validate a newly created private-key container without following links."""

    if not 0 < maximum_bytes <= MAXIMUM_SECRET_BYTES:
        raise MaterializationError("protected file byte bound is invalid")
    try:
        linked = os.lstat(path)
    except OSError as error:
        raise MaterializationError("protected file is unavailable") from error
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.getuid()
        or linked.st_nlink != 1
        or linked.st_mode & 0o077
        or not 0 < linked.st_size <= maximum_bytes
    ):
        raise MaterializationError("protected file is not bounded owner-only storage")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise MaterializationError("protected file could not be opened") from error
    try:
        opened = os.fstat(descriptor)
        if _identity(linked) != _identity(opened):
            raise MaterializationError("protected file changed while opening")
    finally:
        os.close(descriptor)


def decode_into_exclusive_directory(
    *,
    root: pathlib.Path,
    directory: str,
    secrets: list[tuple[str, str, int]],
) -> None:
    parts = _relative_parts(directory, "exclusive secret directory")
    if not secrets or len({filename for _, filename, _ in secrets}) != len(secrets):
        raise MaterializationError("secret output filenames must be unique")
    decoded = [
        (filename, _decode_secret(environment_name, maximum_bytes))
        for environment_name, filename, maximum_bytes in secrets
    ]
    root_descriptor = _open_root(root)
    try:
        parent = _walk_directory(root_descriptor, parts, exclusive=True)
        try:
            for filename, content in decoded:
                _write_exclusive(parent, filename, content)
        finally:
            os.close(parent)
    finally:
        os.close(root_descriptor)


def copy_to_protected_path(
    *,
    source: pathlib.Path,
    root: pathlib.Path,
    relative_path: str,
    maximum_bytes: int,
) -> None:
    parts = _relative_parts(relative_path, "protected destination")
    if len(parts) < 2 or SAFE_FILENAME.fullmatch(parts[-1]) is None:
        raise MaterializationError("protected destination filename is invalid")
    content = _read_source(source, maximum_bytes)
    root_descriptor = _open_root(root)
    try:
        parent = _walk_directory(root_descriptor, parts[:-1], exclusive=False)
        try:
            _write_exclusive(parent, parts[-1], content)
        finally:
            os.close(parent)
    finally:
        os.close(root_descriptor)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    decode = subparsers.add_parser("decode")
    decode.add_argument("--root", required=True, type=pathlib.Path)
    decode.add_argument("--directory", required=True)
    decode.add_argument(
        "--secret",
        action="append",
        nargs=3,
        metavar=("ENVIRONMENT", "FILENAME", "MAXIMUM_BYTES"),
        required=True,
    )
    copy = subparsers.add_parser("copy")
    copy.add_argument("--source", required=True, type=pathlib.Path)
    copy.add_argument("--root", required=True, type=pathlib.Path)
    copy.add_argument("--relative-path", required=True)
    copy.add_argument("--maximum-bytes", required=True, type=int)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--path", required=True, type=pathlib.Path)
    validate.add_argument("--maximum-bytes", required=True, type=int)
    arguments = parser.parse_args(argv)
    try:
        if arguments.operation == "decode":
            secrets: list[tuple[str, str, int]] = []
            for environment_name, filename, raw_maximum in arguments.secret:
                try:
                    maximum_bytes = int(raw_maximum, 10)
                except ValueError as error:
                    raise MaterializationError("secret byte bound is invalid") from error
                secrets.append((environment_name, filename, maximum_bytes))
            decode_into_exclusive_directory(
                root=arguments.root,
                directory=arguments.directory,
                secrets=secrets,
            )
        elif arguments.operation == "copy":
            copy_to_protected_path(
                source=arguments.source,
                root=arguments.root,
                relative_path=arguments.relative_path,
                maximum_bytes=arguments.maximum_bytes,
            )
        else:
            validate_protected_file(arguments.path, arguments.maximum_bytes)
    except (OSError, MaterializationError) as error:
        print(f"protected secret materialization failed: {error}", file=sys.stderr)
        return 1
    print("Protected mobile release secret materialized safely.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
