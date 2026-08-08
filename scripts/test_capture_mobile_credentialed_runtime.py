#!/usr/bin/env python3
"""Adversarial tests for credentialed runner-path capture."""

from __future__ import annotations

import hashlib
import os
import pathlib
import tempfile
import unittest
from unittest import mock

import capture_mobile_credentialed_runtime as capture


class CredentialedRuntimeCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.binary_root = self.root / "bin"
        self.home = self.root / "home"
        self.binary_root.mkdir(mode=0o700)
        self.home.mkdir(mode=0o700)
        self.ruby = self._executable("ruby", b"#!/bin/sh\nexit 0\n")
        self.gem = self._executable("gem", b"#!/bin/sh\nexit 0\n")
        self.output = self.root / "github-output"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _executable(self, name: str, data: bytes) -> pathlib.Path:
        path = self.binary_root / name
        path.write_bytes(data)
        path.chmod(0o700)
        return path

    def environment(self) -> dict[str, str]:
        return {"PATH": os.fspath(self.binary_root), "HOME": os.fspath(self.home)}

    def test_capture_emits_canonical_paths_and_executable_hashes(self) -> None:
        alias = self.root / "bin-alias"
        alias.symlink_to(self.binary_root, target_is_directory=True)
        environment = self.environment()
        environment["PATH"] = f"{alias}:{self.binary_root}"
        with mock.patch.dict(os.environ, environment, clear=True):
            values = capture.capture(output=self.output)
        self.assertEqual(os.fspath(self.binary_root), values["reviewed_path"])
        self.assertEqual(os.fspath(self.home), values["real_home"])
        self.assertEqual(os.fspath(self.ruby), values["ruby_bin"])
        self.assertEqual(hashlib.sha256(self.ruby.read_bytes()).hexdigest(), values["ruby_sha256"])
        self.assertEqual(hashlib.sha256(self.gem.read_bytes()).hexdigest(), values["gem_sha256"])

    def test_group_writable_path_is_rejected(self) -> None:
        self.binary_root.chmod(0o720)
        with mock.patch.dict(os.environ, self.environment(), clear=True):
            with self.assertRaisesRegex(ValueError, "no reviewed real directories"):
                capture.capture(output=self.output)

    def test_other_user_writable_home_is_rejected(self) -> None:
        self.home.chmod(0o777)
        with mock.patch.dict(os.environ, self.environment(), clear=True):
            with self.assertRaisesRegex(ValueError, "HOME"):
                capture.capture(output=self.output)

    def test_hardlinked_executable_is_rejected(self) -> None:
        os.link(self.ruby, self.root / "ruby-hardlink")
        with mock.patch.dict(os.environ, self.environment(), clear=True):
            with self.assertRaisesRegex(ValueError, "immutable executable"):
                capture.capture(output=self.output)


if __name__ == "__main__":
    unittest.main()
