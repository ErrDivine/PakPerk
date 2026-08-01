#!/usr/bin/env python3
"""Tamper regressions for the locked store-upload toolchain."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_fastlane_lock as validator


class FastlaneLockTests(unittest.TestCase):
    def _validate_with_lock(self, source: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lockfile = pathlib.Path(directory) / "Gemfile.lock"
            lockfile.write_text(source, encoding="utf-8")
            validator.validate(validator.DEFAULT_GEMFILE, lockfile)

    def test_checked_in_lock_passes(self) -> None:
        validator.validate(validator.DEFAULT_GEMFILE, validator.DEFAULT_LOCKFILE)

    def test_fastlane_checksum_tamper_fails(self) -> None:
        source = validator.DEFAULT_LOCKFILE.read_text(encoding="utf-8")
        source = source.replace(validator.FASTLANE_SHA256, "0" * 64, 1)
        with self.assertRaisesRegex(RuntimeError, "checksum changed"):
            self._validate_with_lock(source)

    def test_missing_transitive_checksum_fails(self) -> None:
        source = validator.DEFAULT_LOCKFILE.read_text(encoding="utf-8")
        checksum = next(
            line for line in source.splitlines() if line.startswith("  addressable (") and "sha256=" in line
        )
        source = source.replace(checksum + "\n", "", 1)
        with self.assertRaisesRegex(RuntimeError, "missing checksums"):
            self._validate_with_lock(source)


if __name__ == "__main__":
    unittest.main()
