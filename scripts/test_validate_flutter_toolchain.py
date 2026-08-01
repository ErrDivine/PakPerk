#!/usr/bin/env python3
"""Tamper regressions for the reviewed Flutter toolchain identity."""

from __future__ import annotations

import copy
import unittest

import validate_flutter_toolchain as validator


REVIEWED = {
    "frameworkVersion": validator.EXPECTED_FLUTTER_VERSION,
    "flutterVersion": validator.EXPECTED_FLUTTER_VERSION,
    "frameworkRevision": validator.EXPECTED_FRAMEWORK_REVISION,
    "dartSdkVersion": validator.EXPECTED_DART_SDK_VERSION,
    "channel": validator.EXPECTED_CHANNEL,
    "repositoryUrl": validator.EXPECTED_REPOSITORY,
    "engineRevision": "0" * 40,
    "engineContentHash": "1" * 40,
}


class FlutterToolchainValidationTests(unittest.TestCase):
    def test_reviewed_constants_are_exact(self) -> None:
        self.assertEqual(validator.EXPECTED_FLUTTER_VERSION, "3.44.8")
        self.assertEqual(
            validator.EXPECTED_FRAMEWORK_REVISION,
            "058e0af2c2b57e369d905a03ac9748b0ebf543c6",
        )
        self.assertEqual(validator.EXPECTED_DART_SDK_VERSION, "3.12.2")

    def test_reviewed_release_passes(self) -> None:
        validator.validate(REVIEWED)

    def test_release_identity_tampering_is_rejected(self) -> None:
        replacements = {
            "frameworkVersion": "3.44.9",
            "flutterVersion": "3.44.9",
            "frameworkRevision": "f" * 40,
            "dartSdkVersion": "3.12.3",
            "channel": "beta",
            "repositoryUrl": "https://example.invalid/flutter.git",
        }
        for key, replacement in replacements.items():
            with self.subTest(key=key):
                payload = copy.deepcopy(REVIEWED)
                payload[key] = replacement
                with self.assertRaises(RuntimeError):
                    validator.validate(payload)

    def test_missing_engine_identity_is_rejected(self) -> None:
        for key in ("engineRevision", "engineContentHash"):
            with self.subTest(key=key):
                payload = copy.deepcopy(REVIEWED)
                payload.pop(key)
                with self.assertRaises(RuntimeError):
                    validator.validate(payload)


if __name__ == "__main__":
    unittest.main()
