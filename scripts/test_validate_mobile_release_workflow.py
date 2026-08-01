#!/usr/bin/env python3
"""Regression tests for the signed-mobile workflow contract validator."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_mobile_release_workflow as validator


MOBILE_SOURCE = validator.WORKFLOW.read_text(encoding="utf-8")
SECURITY_SOURCE = validator.SECURITY_WORKFLOW.read_text(encoding="utf-8")


def _move_step_after(source: str, moving_name: str, anchor_name: str) -> str:
    moving_marker = f"      - name: {moving_name}\n"
    moving_start = source.index(moving_marker)
    moving_end = source.find("\n      - ", moving_start + len(moving_marker))
    if moving_end < 0:
        raise AssertionError(f"moving step has no following step: {moving_name}")
    moving_block = source[moving_start:moving_end]
    without_moving = source[:moving_start] + source[moving_end + 1 :]

    anchor_marker = f"      - name: {anchor_name}\n"
    anchor_start = without_moving.index(anchor_marker)
    anchor_end = without_moving.find(
        "\n      - ", anchor_start + len(anchor_marker)
    )
    if anchor_end < 0:
        raise AssertionError(f"anchor step has no following step: {anchor_name}")
    return (
        without_moving[:anchor_end]
        + "\n"
        + moving_block
        + without_moving[anchor_end:]
    )


class MobileReleaseWorkflowValidationTests(unittest.TestCase):
    def _validate(self, mobile: str = MOBILE_SOURCE, security: str = SECURITY_SOURCE) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            mobile_path = root / "mobile-release.yml"
            security_path = root / "security.yml"
            mobile_path.write_text(mobile, encoding="utf-8")
            security_path.write_text(security, encoding="utf-8")
            validator.validate(mobile_path, security_path)

    def _assert_mobile_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, MOBILE_SOURCE)
        with self.assertRaises(RuntimeError):
            self._validate(mobile=MOBILE_SOURCE.replace(original, replacement, 1))

    def _assert_security_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, SECURITY_SOURCE)
        with self.assertRaises(RuntimeError):
            self._validate(security=SECURITY_SOURCE.replace(original, replacement, 1))

    def test_checked_in_contract_passes(self) -> None:
        self._validate()

    def test_mobile_flutter_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  FLUTTER_VERSION: 3.44.8", "  FLUTTER_VERSION: 3.44.9"
        )

    def test_mobile_flutter_action_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "flutter-version: ${{ env.FLUTTER_VERSION }}",
            "flutter-version: stable",
        )

    def test_mobile_flutter_identity_gate_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "python3 scripts/validate_flutter_toolchain.py",
            "python3 scripts/record_flutter_toolchain.py",
        )

    def test_security_flutter_version_tamper_is_rejected(self) -> None:
        self._assert_security_tamper_rejected(
            "  FLUTTER_VERSION: 3.44.8", "  FLUTTER_VERSION: 3.44.9"
        )

    def test_security_flutter_identity_gate_tamper_is_rejected(self) -> None:
        self._assert_security_tamper_rejected(
            "python3 scripts/validate_flutter_toolchain.py",
            "python3 scripts/record_flutter_toolchain.py",
        )

    def test_ruby_engine_probe_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "ruby -e 'print RUBY_ENGINE'", "ruby -e 'print RUBY_PLATFORM'"
        )

    def test_ruby_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  PAKPERK_RUBY_VERSION: 3.4.10",
            "  PAKPERK_RUBY_VERSION: 3.4.11",
        )

    def test_rubygems_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  PAKPERK_RUBYGEMS_VERSION: 4.0.17",
            "  PAKPERK_RUBYGEMS_VERSION: 4.0.16",
        )

    def test_ruby_gate_after_dependency_resolution_is_rejected(self) -> None:
        tampered = _move_step_after(
            MOBILE_SOURCE,
            "Select, verify, and record the reviewed Ruby runtime",
            "Resolve locked Flutter dependencies",
        )
        with self.assertRaises(RuntimeError):
            self._validate(mobile=tampered)

    def test_jdk_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  PAKPERK_JDK_RUNTIME_VERSION: 17.0.19+10",
            "  PAKPERK_JDK_RUNTIME_VERSION: 17.0.20+8",
        )

    def test_mobile_x64_jdk_contract_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "JAVA_HOME_17_arm64", "JAVA_HOME_17_X64"
        )

    def test_security_arm64_jdk_contract_is_rejected(self) -> None:
        self._assert_security_tamper_rejected(
            "JAVA_HOME_17_X64", "JAVA_HOME_17_arm64"
        )

    def test_xcode_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            '  XCODE_VERSION: "26.6"', '  XCODE_VERSION: "26.7"'
        )

    def test_source_ancestry_gate_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "git merge-base --is-ancestor", "git merge-base --is-descendant"
        )


if __name__ == "__main__":
    unittest.main()
