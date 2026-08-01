#!/usr/bin/env python3
"""Tamper regressions for the physical-device evidence workflow contract."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_mobile_device_workflow as validator


SOURCE = validator.WORKFLOW.read_text(encoding="utf-8")


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
    anchor_end = without_moving.find("\n      - ", anchor_start + len(anchor_marker))
    if anchor_end < 0:
        raise AssertionError(f"anchor step has no following step: {anchor_name}")
    return (
        without_moving[:anchor_end]
        + "\n"
        + moving_block
        + without_moving[anchor_end:]
    )


class MobileDeviceWorkflowValidationTests(unittest.TestCase):
    def _validate_source(self, source: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workflow = pathlib.Path(directory) / "mobile-device-integration.yml"
            workflow.write_text(source, encoding="utf-8")
            validator.validate(workflow)

    def _assert_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, SOURCE)
        with self.assertRaises(RuntimeError):
            self._validate_source(SOURCE.replace(original, replacement, 1))

    def test_checked_in_contract_passes(self) -> None:
        validator.validate()

    def test_automatic_trigger_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            "  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n"
        )

    def test_flutter_version_tamper_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            "  FLUTTER_VERSION: 3.44.8", "  FLUTTER_VERSION: 3.44.9"
        )

    def test_source_checkout_binding_removal_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            "          ref: ${{ inputs.source_revision }}\n",
            "          ref: ${{ github.ref }}\n",
        )

    def test_non_main_source_acceptance_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            '[[ "$DISPATCH_REF" != "refs/heads/main" ]]',
            '[[ -z "$DISPATCH_REF" ]]',
        )

    def test_dispatch_revision_binding_removal_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            '[[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]',
            '[[ -z "$REQUESTED_REVISION" ]]',
        )

    def test_origin_main_tip_binding_removal_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            '[[ "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]',
            '[[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" ]]',
        )

    def test_confirmation_gate_tamper_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            '[[ "$DISPATCH_CONFIRMATION" != "RUN_DETERMINISTIC_DEVICE_PROBE" ]]',
            '[[ -z "$DISPATCH_CONFIRMATION" ]]',
        )

    def test_flutter_identity_gate_removal_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            "python3 scripts/validate_flutter_toolchain.py",
            "python3 scripts/record_flutter_toolchain.py",
        )

    def test_flutter_identity_after_dependencies_is_rejected(self) -> None:
        tampered = _move_step_after(
            SOURCE,
            "Verify and record the exact reviewed Flutter SDK",
            "Resolve locked Flutter dependencies",
        )
        with self.assertRaisesRegex(RuntimeError, "before dependencies"):
            self._validate_source(tampered)

    def test_toolchain_metadata_omission_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            "            ${{ runner.temp }}/flutter-toolchain.json\n",
            "",
        )

    def test_missing_evidence_warning_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            "if-no-files-found: error", "if-no-files-found: warn"
        )

    def test_empty_evidence_acceptance_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            'if [[ ! -s "$evidence_path" ]]',
            'if [[ ! -e "$evidence_path" ]]',
        )

    def test_toolchain_outcome_omission_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            "          PAKPERK_FLUTTER_TOOLCHAIN_OUTCOME: "
            "${{ steps.flutter-toolchain.outcome }}\n",
            "",
        )

    def test_external_path_attestation_tamper_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            '"does_not_attest_external_paths": True',
            '"does_not_attest_external_paths": False',
        )


if __name__ == "__main__":
    unittest.main()
