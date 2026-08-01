#!/usr/bin/env python3
"""Negative and positive regression tests for Android ELF alignment checks."""

from __future__ import annotations

import importlib.util
import pathlib
import struct
import tempfile
import zipfile


SCRIPT = pathlib.Path(__file__).with_name("verify_android_elf_alignment.py")
SPEC = importlib.util.spec_from_file_location("android_elf_alignment", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def _elf(machine: int, alignment: int) -> bytes:
    data = bytearray(120)
    data[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<H", data, 16, 3)
    struct.pack_into("<H", data, 18, machine)
    struct.pack_into("<I", data, 20, 1)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<H", data, 52, 64)
    struct.pack_into("<H", data, 54, 56)
    struct.pack_into("<H", data, 56, 1)
    struct.pack_into("<I", data, 64, 1)
    struct.pack_into("<Q", data, 64 + 48, alignment)
    return bytes(data)


def _archive(path: pathlib.Path, alignment: int, *, include_arm64: bool = True) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        if include_arm64:
            archive.writestr(
                "base/lib/arm64-v8a/libfixture.so",
                _elf(MODULE.EM_AARCH64, alignment),
            )
        archive.writestr(
            "base/lib/x86_64/libfixture.so", _elf(MODULE.EM_X86_64, alignment)
        )


def _expect_failure(path: pathlib.Path, fragment: str) -> None:
    try:
        MODULE.verify_archive(str(path))
    except ValueError as error:
        assert fragment in str(error), (fragment, str(error))
    else:
        raise AssertionError(f"expected verification failure for {path}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="pakperk-elf-alignment-") as raw_dir:
        directory = pathlib.Path(raw_dir)
        valid = directory / "valid.aab"
        unaligned = directory / "unaligned.aab"
        missing_arm64 = directory / "missing-arm64.aab"
        _archive(valid, 1 << 14)
        _archive(unaligned, 1 << 12)
        _archive(missing_arm64, 1 << 14, include_arm64=False)

        counts = MODULE.verify_archive(str(valid))
        assert counts == {"arm64-v8a": 1, "x86_64": 1}, counts
        _expect_failure(unaligned, "must be aligned to at least 16384")
        _expect_failure(missing_arm64, "contains no arm64-v8a")
    print("Android ELF alignment verifier regression tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
