#!/usr/bin/env python3
"""Validate a rotation-ordered account keyring without exposing key material."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
from pathlib import Path
import re
import stat
import sys


MAXIMUM_FILE_BYTES = 16 * 1024
MAXIMUM_KEYS = 8
KEY_ID = re.compile(r"[a-z0-9_-]{1,64}")


class KeyringValidationError(ValueError):
    """A bounded validation failure that contains no key material."""


def validate_keyring_bytes(
    contents: bytes,
    *,
    minimum_key_bytes: int,
    maximum_key_bytes: int,
) -> None:
    if minimum_key_bytes < 1 or maximum_key_bytes < minimum_key_bytes:
        raise ValueError("invalid key-width bounds")
    if not contents or len(contents) > MAXIMUM_FILE_BYTES:
        raise KeyringValidationError("file size is outside the accepted bounds")
    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError as error:
        raise KeyringValidationError("file is not UTF-8") from error
    if any(
        (ord(character) < 0x20 or ord(character) == 0x7F)
        and character != "\n"
        for character in text
    ):
        raise KeyringValidationError("file contains unsupported control characters")

    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    if not 1 <= len(lines) <= MAXIMUM_KEYS:
        raise KeyringValidationError("key count is outside the accepted bounds")

    key_ids: set[str] = set()
    for line in lines:
        parts = line.split(":")
        if len(parts) != 2:
            raise KeyringValidationError("key line is malformed")
        key_id, encoded = parts
        if KEY_ID.fullmatch(key_id) is None or key_id in key_ids:
            raise KeyringValidationError("key identifier is invalid or duplicated")
        try:
            secret = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as error:
            raise KeyringValidationError("key value is not canonical base64") from error
        if base64.b64encode(secret).decode("ascii") != encoded:
            raise KeyringValidationError("key value is not canonical base64")
        if not minimum_key_bytes <= len(secret) <= maximum_key_bytes:
            raise KeyringValidationError("decoded key width is invalid")
        key_ids.add(key_id)


def validate_keyring_file(
    path: Path,
    *,
    minimum_key_bytes: int,
    maximum_key_bytes: int,
) -> None:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise KeyringValidationError("path is not a non-symlink regular file")
    if metadata.st_size > MAXIMUM_FILE_BYTES:
        raise KeyringValidationError("file size is outside the accepted bounds")

    # Recheck the opened object before reading so a path swap cannot redirect
    # validation to a symlink or a different file. The bounded read remains the
    # authoritative size check if the file grows after either metadata lookup.
    with path.open("rb") as keyring:
        opened_metadata = os.fstat(keyring.fileno())
        if (
            not stat.S_ISREG(opened_metadata.st_mode)
            or opened_metadata.st_dev != metadata.st_dev
            or opened_metadata.st_ino != metadata.st_ino
            or opened_metadata.st_size > MAXIMUM_FILE_BYTES
        ):
            raise KeyringValidationError(
                "path changed or file size is outside the accepted bounds"
            )
        contents = keyring.read(MAXIMUM_FILE_BYTES + 1)

    validate_keyring_bytes(
        contents,
        minimum_key_bytes=minimum_key_bytes,
        maximum_key_bytes=maximum_key_bytes,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--minimum-key-bytes", type=int, required=True)
    parser.add_argument("--maximum-key-bytes", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        validate_keyring_file(
            arguments.path,
            minimum_key_bytes=arguments.minimum_key_bytes,
            maximum_key_bytes=arguments.maximum_key_bytes,
        )
    except (OSError, ValueError) as error:
        print(f"Account keyring validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
