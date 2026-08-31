#!/usr/bin/env python3
"""Tamper regressions for the physical-device evidence workflow contract."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_flutter_physical_device as physical_device
import validate_mobile_device_workflow as validator


SOURCE = validator.WORKFLOW.read_text(encoding="utf-8")
CHECK_SCRIPT = (validator.ROOT / "scripts/check.sh").read_text(encoding="utf-8")


def _android_device(**overrides: object) -> dict[str, object]:
    device: dict[str, object] = {
        "id": "physical-android",
        "isSupported": True,
        "emulator": False,
        "targetPlatform": "android-arm64",
        "sdk": "Android 16 (API 36)",
    }
    device.update(overrides)
    return device


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

    def test_profile_driver_contract_cannot_fall_back_to_debug_test(self) -> None:
        self._assert_tamper_rejected(
            "          flutter drive \\\n",
            "          flutter test \\\n",
        )

    def test_profile_driver_target_cannot_change(self) -> None:
        self._assert_tamper_rejected(
            "--target=integration_test/production_verification_test.dart",
            "--target=integration_test/demo_flows_test.dart",
        )

    def test_profile_flavor_environment_pair_cannot_change(self) -> None:
        self._assert_tamper_rejected(
            "--flavor prod --dart-define-from-file=config/prod.json",
            "--flavor dev --dart-define-from-file=config/prod.json",
        )

    def test_emulator_gate_inversion_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            'if selected.get("emulator") is not False:',
            'if selected.get("emulator") is False:',
        )

    def test_supported_device_gate_inversion_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            'if selected.get("isSupported") is not True:',
            'if selected.get("isSupported") is True:',
        )

    def test_flutter_device_source_cannot_be_replaced(self) -> None:
        self._assert_tamper_rejected(
            'flutter devices --machine >"$RUNNER_TEMP/flutter-devices.json"',
            'printf \'[]\\n\' >"$RUNNER_TEMP/flutter-devices.json"',
        )

    def test_selected_device_must_match_the_protected_id(self) -> None:
        self._assert_tamper_rejected(
            'matches = [device for device in devices if device.get("id") == expected]',
            "matches = devices[:1]",
        )

    def test_validated_device_must_come_from_the_exact_match(self) -> None:
        self._assert_tamper_rejected(
            "selected = matches[0]",
            "selected = devices[0]",
        )

    def test_nonmobile_target_expansion_is_rejected(self) -> None:
        self._assert_tamper_rejected(
            'allowed_targets = {"android-arm", "android-arm64", "android-x64", "ios"}',
            'allowed_targets = {"android-arm", "android-arm64", "android-x64", "ios", "linux-x64"}',
        )

    def test_physical_preflight_must_precede_device_test(self) -> None:
        tampered = _move_step_after(
            SOURCE,
            "Verify the exact protected device is connected",
            "Run deterministic production contract in profile mode",
        )
        with self.assertRaisesRegex(RuntimeError, "physical device"):
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

    def test_local_check_preflights_the_selected_device_before_drive(self) -> None:
        branch_start = CHECK_SCRIPT.index(
            '    if [[ -n "${PAKPERK_MOBILE_DEVICE_ID:-}" ]]; then\n'
        )
        branch_end = CHECK_SCRIPT.index("\n    else\n", branch_start)
        physical_branch = CHECK_SCRIPT[branch_start:branch_end]
        devices = 'flutter --no-version-check devices --machine \\\n'
        validator_call = (
            'python3 "$project_dir/scripts/validate_flutter_physical_device.py" \\\n'
        )
        drive = "flutter --no-version-check drive \\\n"
        for fragment in (
            devices,
            '        >"$temporary_dir/flutter-devices.json"\n',
            validator_call,
            '        "$temporary_dir/flutter-devices.json"\n',
            drive,
            "        --driver=test_driver/integration_test.dart \\\n",
            "        --target=integration_test/production_verification_test.dart \\\n",
            "        --flavor prod --dart-define-from-file=config/prod.json \\\n",
            '        --profile -d "$PAKPERK_MOBILE_DEVICE_ID"',
        ):
            self.assertEqual(physical_branch.count(fragment), 1, fragment)
        self.assertLess(
            physical_branch.index(devices), physical_branch.index(validator_call)
        )
        self.assertLess(
            physical_branch.index(validator_call), physical_branch.index(drive)
        )


class FlutterPhysicalDeviceValidationTests(unittest.TestCase):
    def test_supported_physical_android_is_accepted(self) -> None:
        result = physical_device.validate_devices(
            [_android_device()],
            "physical-android",
        )
        self.assertEqual(result.os_family, "android")
        self.assertEqual(result.target_platform, "android-arm64")
        self.assertEqual(result.android_api_level, 36)

    def test_supported_physical_ios_is_accepted(self) -> None:
        result = physical_device.validate_devices(
            [
                {
                    "id": "physical-ios",
                    "isSupported": True,
                    "emulator": False,
                    "targetPlatform": "ios",
                    "sdk": "iOS 26.0 23A123",
                }
            ],
            "physical-ios",
        )
        self.assertEqual(result.os_family, "ios")
        self.assertEqual(result.os_version, "26.0")
        self.assertIsNone(result.android_api_level)

    def test_emulator_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            physical_device.DeviceValidationError,
            "emulators and simulators",
        ):
            physical_device.validate_devices(
                [_android_device(emulator=True)],
                "physical-android",
            )

    def test_unsupported_device_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            physical_device.DeviceValidationError,
            "unsupported",
        ):
            physical_device.validate_devices(
                [_android_device(isSupported=False)],
                "physical-android",
            )

    def test_nonmobile_target_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            physical_device.DeviceValidationError,
            "mobile platform",
        ):
            physical_device.validate_devices(
                [
                    _android_device(
                        targetPlatform="linux-x64",
                        sdk="Linux",
                    )
                ],
                "physical-android",
            )

    def test_ambiguous_selected_device_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            physical_device.DeviceValidationError,
            "exactly one",
        ):
            physical_device.validate_devices(
                [_android_device(), _android_device()],
                "physical-android",
            )


if __name__ == "__main__":
    unittest.main()
