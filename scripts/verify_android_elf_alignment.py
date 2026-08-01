#!/usr/bin/env python3
"""Verify 16 KiB ELF LOAD alignment for native Android release archives."""

from __future__ import annotations

import argparse
import pathlib
import re
import struct
import zipfile


MINIMUM_ALIGNMENT = 1 << 14
PT_LOAD = 1
EM_AARCH64 = 183
EM_X86_64 = 62
ABI_MACHINE = {"arm64-v8a": EM_AARCH64, "x86_64": EM_X86_64}
LIBRARY_PATH = re.compile(r"(?:^|/)lib/(arm64-v8a|x86_64)/[^/]+\.so$")


def _load_alignments(data: bytes, *, source: str, expected_machine: int) -> list[int]:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ValueError(f"{source} is not an ELF file")
    if data[4] != 2:
        raise ValueError(f"{source} is not a 64-bit ELF file")
    if data[5] not in (1, 2):
        raise ValueError(f"{source} has an invalid ELF byte order")

    byte_order = "<" if data[5] == 1 else ">"
    machine = struct.unpack_from(f"{byte_order}H", data, 18)[0]
    if machine != expected_machine:
        raise ValueError(
            f"{source} has ELF machine {machine}, expected {expected_machine}"
        )

    program_offset = struct.unpack_from(f"{byte_order}Q", data, 32)[0]
    entry_size = struct.unpack_from(f"{byte_order}H", data, 54)[0]
    entry_count = struct.unpack_from(f"{byte_order}H", data, 56)[0]
    if entry_size < 56 or entry_count == 0:
        raise ValueError(f"{source} has no valid ELF program-header table")
    table_end = program_offset + entry_size * entry_count
    if program_offset < 64 or table_end > len(data):
        raise ValueError(f"{source} has a truncated ELF program-header table")

    alignments: list[int] = []
    for index in range(entry_count):
        offset = program_offset + index * entry_size
        program_type = struct.unpack_from(f"{byte_order}I", data, offset)[0]
        if program_type == PT_LOAD:
            alignments.append(struct.unpack_from(f"{byte_order}Q", data, offset + 48)[0])
    if not alignments:
        raise ValueError(f"{source} has no ELF LOAD segments")
    return alignments


def verify_archive(raw_path: str) -> dict[str, int]:
    path = pathlib.Path(raw_path)
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise ValueError(f"Android artifact is not a non-empty regular file: {path}")

    counts = {abi: 0 for abi in ABI_MACHINE}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        relevant_names = [name for name in names if LIBRARY_PATH.search(name)]
        if len(relevant_names) != len(set(relevant_names)):
            raise ValueError(f"{path.name} contains duplicate native-library entries")
        for name in relevant_names:
            match = LIBRARY_PATH.search(name)
            assert match is not None
            abi = match.group(1)
            counts[abi] += 1
            source = f"{path.name}:{name}"
            alignments = _load_alignments(
                archive.read(name), source=source, expected_machine=ABI_MACHINE[abi]
            )
            for alignment in alignments:
                if alignment < MINIMUM_ALIGNMENT or alignment & (alignment - 1):
                    raise ValueError(
                        f"{source} has LOAD alignment {alignment}; "
                        f"every LOAD segment must be aligned to at least {MINIMUM_ALIGNMENT}"
                    )

    if counts["arm64-v8a"] == 0:
        raise ValueError(f"{path.name} contains no arm64-v8a native library to verify")
    return counts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifacts", nargs="+", help="APK/AAB archives to verify")
    args = parser.parse_args()

    for raw_path in args.artifacts:
        try:
            counts = verify_archive(raw_path)
        except (OSError, ValueError, zipfile.BadZipFile, struct.error) as error:
            parser.error(str(error))
        label = pathlib.Path(raw_path).suffix.removeprefix(".").lower() or "archive"
        print(f"android_{label}_arm64_libraries={counts['arm64-v8a']}")
        print(f"android_{label}_x86_64_libraries={counts['x86_64']}")
    print(f"android_native_elf_load_alignment={MINIMUM_ALIGNMENT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
