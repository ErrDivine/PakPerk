#!/usr/bin/env python3
"""Regressions for closed-schema mobile-store outcome receipts."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import pathlib
import tempfile
import unittest

import generate_mobile_store_rollout_receipt as receipt
import validate_mobile_signed_release_run as run_validator


class MobileStoreReceiptTests(unittest.TestCase):
    def play_snapshot(
        self, code: str, status: str, fraction: str | None = None
    ) -> dict[str, object]:
        return {
            "status": status,
            "user_fraction": fraction,
            "version_codes": [code],
        }

    def valid_google(self) -> dict[str, object]:
        return {
            "after": {
                "fallback": self.play_snapshot("41", "completed"),
                "target": self.play_snapshot("42", "inProgress", "0.02"),
            },
            "application_id": receipt.APPLICATION_ID,
            "before": {
                "fallback": self.play_snapshot("41", "completed"),
                "internal_target": None,
                "target": self.play_snapshot("42", "inProgress", "0.01"),
            },
            "mutation_status": "succeeded_verified",
            "operation": "advance",
            "previous_production_version_code": "41",
            "requested": {
                "expected_current_fraction": "0.01",
                "target_fraction": "0.02",
            },
            "schema": 1,
            "version_code": "42",
        }

    def valid_google_journal(self) -> dict[str, object]:
        value = copy.deepcopy(self.valid_google())
        del value["after"]
        value["mutation_status"] = "unknown_reconcile_required"
        return value

    def valid_apple(self) -> dict[str, object]:
        return {
            "application_id": receipt.APPLICATION_ID,
            "app_version": "1.2.3",
            "build_number": "42",
            "operation": "observe",
            "phased_release": {
                "app_id": "app-1",
                "app_version_id": "version-1",
                "build": {
                    "build_id": "build-1",
                    "build_number": "42",
                    "processing_state": "VALID",
                },
                "current_day_number": 2,
                "phased_release_id": "phase-1",
                "start_date": "2026-08-03",
                "state": "ACTIVE",
                "total_pause_duration": 0,
            },
            "schema": 1,
        }

    def valid_apple_submission(self) -> dict[str, object]:
        value = copy.deepcopy(self.valid_apple())
        value["operation"] = "verify-submission"
        value["phased_release"]["state"] = "INACTIVE"  # type: ignore[index]
        return value

    def valid_apple_preflight(self) -> dict[str, object]:
        return {
            "application_id": receipt.APPLICATION_ID,
            "app_version": "1.2.3",
            "build_number": "42",
            "mutation_status": "unknown_reconcile_required",
            "operation": "verify-update",
            "schema": 1,
            "update_preflight": {
                "app_id": "app-1",
                "previous": {
                    "app_version_id": "previous-1",
                    "state": "READY_FOR_DISTRIBUTION",
                    "version": "1.2.2",
                },
                "target": {
                    "app_version_id": "version-1",
                    "state": "PREPARE_FOR_SUBMISSION",
                    "version": "1.2.3",
                },
                "target_build": {
                    "build_id": "build-1",
                    "build_number": "42",
                    "pre_release_version_id": "pre-1",
                    "processing_state": "VALID",
                },
            },
        }

    def valid_apple_journal(self, operation: str = "pause") -> dict[str, object]:
        before = copy.deepcopy(self.valid_apple()["phased_release"])
        return {
            "application_id": receipt.APPLICATION_ID,
            "app_version": "1.2.3",
            "before": before,
            "build_number": "42",
            "mutation_status": "unknown_reconcile_required",
            "operation": operation,
            "schema": 1,
        }

    def valid_apple_pause(self, *, idempotent: bool = False) -> dict[str, object]:
        value = copy.deepcopy(self.valid_apple())
        value["operation"] = "pause"
        phased = value["phased_release"]
        phased["state"] = "PAUSED"  # type: ignore[index]
        phased["idempotent"] = idempotent  # type: ignore[index]
        phased["previous_state"] = "PAUSED" if idempotent else "ACTIVE"  # type: ignore[index]
        phased["mutation_status"] = "succeeded_verified"  # type: ignore[index]
        return value

    def validate_google(self, value: dict[str, object]) -> None:
        receipt.validate_google_play_result(
            value,
            version_code="42",
            previous_version_code="41",
            operation="advance",
            expected_fraction="0.01",
            target_fraction="0.02",
        )

    def test_exact_google_schema_passes(self) -> None:
        self.validate_google(self.valid_google())

    def test_google_nested_arbitrary_field_is_rejected(self) -> None:
        value = self.valid_google()
        value["after"]["target"]["attacker"] = "accepted"  # type: ignore[index]
        with self.assertRaises(receipt.EvidenceError):
            self.validate_google(value)

    def test_google_partial_snapshot_is_rejected(self) -> None:
        value = self.valid_google()
        del value["before"]["target"]["version_codes"]  # type: ignore[index]
        with self.assertRaises(receipt.EvidenceError):
            self.validate_google(value)

    def test_google_wrong_nested_version_is_rejected(self) -> None:
        value = self.valid_google()
        value["after"]["target"]["version_codes"] = ["999"]  # type: ignore[index]
        with self.assertRaises(receipt.EvidenceError):
            self.validate_google(value)

    def test_google_wrong_nested_state_is_rejected(self) -> None:
        value = self.valid_google()
        value["before"]["target"]["status"] = "draft"  # type: ignore[index]
        with self.assertRaises(receipt.EvidenceError):
            self.validate_google(value)

    def test_google_fraction_drift_is_rejected(self) -> None:
        value = self.valid_google()
        value["after"]["target"]["user_fraction"] = "0.05"  # type: ignore[index]
        with self.assertRaises(receipt.EvidenceError):
            self.validate_google(value)

    def test_exact_apple_schema_passes(self) -> None:
        receipt.validate_app_store_result(
            self.valid_apple(),
            app_version="1.2.3",
            build_number="42",
            operation="advance",
        )

    def test_empty_apple_result_is_rejected(self) -> None:
        with self.assertRaises(receipt.EvidenceError):
            receipt.validate_app_store_result(
                {}, app_version="1.2.3", build_number="42", operation="advance"
            )

    def test_partial_apple_result_is_rejected(self) -> None:
        value = self.valid_apple()
        del value["phased_release"]
        with self.assertRaises(receipt.EvidenceError):
            receipt.validate_app_store_result(
                value,
                app_version="1.2.3",
                build_number="42",
                operation="advance",
            )

    def test_wrong_apple_version_is_rejected(self) -> None:
        value = self.valid_apple()
        value["app_version"] = "9.9.9"
        with self.assertRaises(receipt.EvidenceError):
            receipt.validate_app_store_result(
                value,
                app_version="1.2.3",
                build_number="42",
                operation="advance",
            )

    def test_paused_apple_observation_is_not_an_advance(self) -> None:
        value = self.valid_apple()
        value["phased_release"]["state"] = "PAUSED"  # type: ignore[index]
        with self.assertRaises(receipt.EvidenceError):
            receipt.validate_app_store_result(
                value,
                app_version="1.2.3",
                build_number="42",
                operation="advance",
            )

    def test_apple_transition_idempotence_must_correlate_with_previous_state(self) -> None:
        base = self.valid_apple()
        base["operation"] = "pause"
        base["phased_release"]["state"] = "PAUSED"  # type: ignore[index]
        base["phased_release"]["mutation_status"] = "succeeded_verified"  # type: ignore[index]
        impossible = []
        repeated_but_active = copy.deepcopy(base)
        repeated_but_active["phased_release"].update(  # type: ignore[union-attr]
            {"idempotent": True, "previous_state": "ACTIVE"}
        )
        impossible.append(repeated_but_active)
        changed_but_paused = copy.deepcopy(base)
        changed_but_paused["phased_release"].update(  # type: ignore[union-attr]
            {"idempotent": False, "previous_state": "PAUSED"}
        )
        impossible.append(changed_but_paused)
        for value in impossible:
            with self.assertRaises(receipt.EvidenceError):
                receipt.validate_app_store_result(
                    value,
                    app_version="1.2.3",
                    build_number="42",
                    operation="halt",
                )

    def test_exact_apple_update_preflight_passes(self) -> None:
        receipt.validate_app_update_preflight(
            self.valid_apple_preflight(),
            app_version="1.2.3",
            build_number="42",
            previous_public_version="1.2.2",
        )

    def test_empty_or_partial_apple_update_preflight_is_rejected(self) -> None:
        for value in ({}, {"application_id": receipt.APPLICATION_ID}):
            with self.assertRaises(receipt.EvidenceError):
                receipt.validate_app_update_preflight(
                    value,
                    app_version="1.2.3",
                    build_number="42",
                    previous_public_version="1.2.2",
                )

    def test_apple_update_preflight_binds_versions_and_current_states(self) -> None:
        mutations = []
        wrong_previous = self.valid_apple_preflight()
        wrong_previous["update_preflight"]["previous"]["version"] = "9.9.9"  # type: ignore[index]
        mutations.append(wrong_previous)
        deprecated_state = self.valid_apple_preflight()
        deprecated_state["update_preflight"]["previous"]["state"] = "READY_FOR_SALE"  # type: ignore[index]
        mutations.append(deprecated_state)
        submitted_target = self.valid_apple_preflight()
        submitted_target["update_preflight"]["target"]["state"] = "IN_REVIEW"  # type: ignore[index]
        mutations.append(submitted_target)
        for value in mutations:
            with self.assertRaises(receipt.EvidenceError):
                receipt.validate_app_update_preflight(
                    value,
                    app_version="1.2.3",
                    build_number="42",
                    previous_public_version="1.2.2",
                )

    def write_json(self, path: pathlib.Path, value: object) -> None:
        path.write_bytes(receipt.canonical_json_bytes(value))
        path.chmod(0o600)

    def args(self, root: pathlib.Path, **updates: str) -> argparse.Namespace:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        run_verification = root / "signed-release-run-verification.json"
        if not run_verification.exists():
            identity = f"1.2.3-42-{'a' * 40}-123-2"
            self.write_json(
                run_verification,
                {
                    "artifacts": {
                        "candidate": {
                            "digest": "sha256:" + "1" * 64,
                            "expired": False,
                            "id": "1001",
                            "name": f"pakperk-production-{identity}",
                            "size_in_bytes": 1024,
                        },
                        "store_handoff": {
                            "digest": "sha256:" + "2" * 64,
                            "expired": False,
                            "id": "1002",
                            "name": f"pakperk-production-store-handoff-{identity}",
                            "size_in_bytes": 1024,
                        },
                        "signed_release_outcome": {
                            "digest": "sha256:" + "3" * 64,
                            "expired": False,
                            "id": "1003",
                            "name": f"pakperk-production-store-outcome-{identity}",
                            "size_in_bytes": 1024,
                        },
                    },
                    "classification": "trusted GitHub signed-mobile release run verification",
                    "job": {
                        "conclusion": "success",
                        "head_sha": "a" * 40,
                        "id": "2001",
                        "name": run_validator.JOB_NAME,
                        "run_attempt": "2",
                        "run_id": "123",
                        "status": "completed",
                        "workflow_name": run_validator.WORKFLOW_NAME,
                    },
                    "repository": receipt.REPOSITORY,
                    "run": {
                        "conclusion": "success",
                        "event": "workflow_dispatch",
                        "head_branch": "main",
                        "head_sha": "a" * 40,
                        "id": "123",
                        "name": run_validator.WORKFLOW_NAME,
                        "path": run_validator.WORKFLOW_PATH,
                        "path_ref": "main",
                        "run_attempt": "2",
                        "status": "completed",
                    },
                    "schema": 1,
                },
            )
        values = {
            "source_revision": "a" * 40,
            "signed_release_run_id": "123",
            "candidate_id": "sha256:" + "b" * 64,
            "provenance_id": "sha256:" + "c" * 64,
            "store_handoff_id": "store-handoff-v1:sha256:" + "d" * 64,
            "app_version": "1.2.3",
            "build_number": "42",
            "platforms": "both",
            "operation": "advance",
            "android_previous_version": "41",
            "android_expected_fraction": "0.01",
            "android_target_fraction": "0.02",
            "ios_previous_public_version": "none",
            "android_outcome": "success",
            "ios_outcome": "success",
            "change_id": "change-1",
            "confirmation": "MUTATE_PRODUCTION_MOBILE_STORES",
            "intent_outcome": "success",
            "workflow_sha": "d" * 40,
            "repository": receipt.REPOSITORY,
            "run_id": "456",
            "run_attempt": "1",
            "run_verification": str(run_verification),
            "evidence_root": str(root),
            "github_output": str(root.parent / "github-output"),
            "github_step_summary": str(root.parent / "github-summary"),
            "android_journal": "",
            "ios_journal": "",
        }
        values.update(updates)
        return argparse.Namespace(**values)

    def test_success_requires_the_authenticated_signed_release_run_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            arguments = self.args(
                root,
                platforms="ios",
                android_previous_version="none",
                android_expected_fraction="none",
                android_target_fraction="none",
                android_outcome="skipped",
            )
            pathlib.Path(arguments.run_verification).unlink()
            self.write_json(root / "apple-store-operation.json", self.valid_apple())
            result = receipt.generate(arguments)
            self.assertEqual("failed", result["overall_result"])
            self.assertIsNone(result["signed_release_run_verification"])
            self.assertIsNotNone(result["signed_release_run_verification_error"])

    def test_partial_store_failure_still_writes_content_addressed_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(root / "google-play-rollout.json", self.valid_google())
            self.write_json(
                root / "google-play-attempt.json", self.valid_google_journal()
            )
            result = receipt.generate(self.args(root, ios_outcome="failure"))
            self.assertEqual("partial_failure", result["overall_result"])
            self.assertEqual("succeeded", result["android"]["attempt_state"])
            self.assertEqual("failed", result["ios"]["attempt_state"])
            package = json.loads((root / "PACKAGE_SHA256.json").read_text())
            self.assertRegex(
                package["content_id"], r"^mobile-store-rollout-v3:sha256:[0-9a-f]{64}$"
            )

    def test_successful_step_with_hostile_nested_result_is_receipted_as_failed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            value = self.valid_google()
            value["after"]["target"]["unknown"] = []  # type: ignore[index]
            self.write_json(root / "google-play-rollout.json", value)
            result = receipt.generate(
                self.args(root, platforms="android", ios_outcome="skipped")
            )
            self.assertEqual("failed", result["overall_result"])
            self.assertEqual("failed", result["android"]["attempt_state"])
            self.assertIn("evidence_error", result["android"])
            self.assertTrue((root / "mobile-store-rollout-receipt.json").is_file())

    def test_android_failure_marks_ios_dependency_not_attempted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            result = receipt.generate(
                self.args(root, android_outcome="failure", ios_outcome="skipped")
            )
            self.assertEqual("failed", result["overall_result"])
            self.assertEqual(
                "not_attempted_dependency_failed", result["ios"]["attempt_state"]
            )

    def test_first_ios_publication_cannot_produce_success_without_prior_proof(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(
                root / "apple-store-operation.json", self.valid_apple_submission()
            )
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    operation="start",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="1.2.2",
                    android_outcome="skipped",
                    ios_outcome="success",
                )
            )
            self.assertEqual("failed", result["overall_result"])
            self.assertEqual("failed", result["ios"]["attempt_state"])

    def test_ios_update_start_requires_preflight_and_inactive_postflight(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(
                root / "apple-update-preflight.json", self.valid_apple_preflight()
            )
            self.write_json(
                root / "apple-store-operation.json", self.valid_apple_submission()
            )
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    operation="start",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="1.2.2",
                    android_outcome="skipped",
                    ios_outcome="success",
                )
            )
            self.assertEqual("succeeded", result["overall_result"])
            self.assertEqual("succeeded", result["ios"]["attempt_state"])

    def test_private_reader_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "target"
            self.write_json(target, self.valid_google())
            linked = root / "linked"
            linked.symlink_to(target)
            with self.assertRaises(receipt.EvidenceError):
                receipt.read_private_json(linked)

    def test_private_reader_rejects_hardlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "target"
            self.write_json(target, self.valid_google())
            linked = root / "linked"
            os.link(target, linked)
            with self.assertRaises(receipt.EvidenceError):
                receipt.read_private_json(linked)

    def test_receipt_outputs_are_owner_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(root / "google-play-rollout.json", self.valid_google())
            self.write_json(
                root / "google-play-attempt.json", self.valid_google_journal()
            )
            self.write_json(root / "apple-store-operation.json", self.valid_apple())
            receipt.generate(self.args(root))
            for name in (
                "mobile-store-rollout-receipt.json",
                "PACKAGE_SHA256.json",
            ):
                self.assertEqual(0o600, (root / name).stat().st_mode & 0o777)

    def test_accepted_input_is_independently_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(root / "google-play-rollout.json", self.valid_google())
            self.write_json(
                root / "google-play-attempt.json", self.valid_google_journal()
            )
            self.write_json(root / "apple-store-operation.json", self.valid_apple())
            result = receipt.generate(self.args(root))
            self.assertEqual(
                {
                    "intent_step_outcome": "success",
                    "redacted_fields": [],
                    "status": "accepted",
                },
                result["input_validation"],
            )
            self.assertEqual("succeeded_verified", result["android"]["mutation_status"])
            self.assertEqual("succeeded_verified", result["ios"]["mutation_status"])

    def test_every_dispatch_field_is_validated_and_redacted(self) -> None:
        invalid_values = {
            "source_revision": "A" * 40,
            "signed_release_run_id": "0",
            "candidate_id": "sha256:short",
            "provenance_id": "not-a-content-id",
            "store_handoff_id": "sha256:" + "f" * 64,
            "app_version": "latest",
            "build_number": "0",
            "platforms": "desktop",
            "operation": "delete",
            "android_previous_version": "forty-one",
            "android_expected_fraction": "0.03",
            "android_target_fraction": "0.03",
            "ios_previous_public_version": "1.2",
            "android_outcome": "unknown",
            "ios_outcome": "unknown",
            "change_id": "contains space",
            "confirmation": "yes",
            "intent_outcome": "unknown",
            "workflow_sha": "D" * 40,
            "repository": "fork/pakperk",
            "run_id": "-1",
            "run_attempt": "0",
        }
        for field, invalid in invalid_values.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                root = base / "evidence"
                root.mkdir()
                result = receipt.generate(self.args(root, **{field: invalid}))
                self.assertEqual("rejected", result["input_validation"]["status"])
                self.assertIn(field, result["input_validation"]["redacted_fields"])
                retained = {
                    "source_revision": result["source_revision"],
                    "signed_release_run_id": result["signed_release_run_id"],
                    "candidate_id": result["candidate_id"],
                    "provenance_id": result["provenance_id"],
                    "store_handoff_id": result["store_handoff_id"],
                    "app_version": result["app_version"],
                    "build_number": result["build_number"],
                    "platforms": result["platforms"],
                    "operation": result["operation"],
                    "android_previous_version": result[
                        "android_previous_production_version_code"
                    ],
                    "android_expected_fraction": result[
                        "android_expected_current_fraction"
                    ],
                    "android_target_fraction": result["android_target_fraction"],
                    "ios_previous_public_version": result[
                        "ios_previous_public_version"
                    ],
                    "android_outcome": result["android"]["step_outcome"],
                    "ios_outcome": result["ios"]["step_outcome"],
                    "change_id": result["change_id"],
                    "confirmation": None,
                    "intent_outcome": result["input_validation"][
                        "intent_step_outcome"
                    ],
                    "workflow_sha": result["workflow"]["workflow_sha"],
                    "repository": result["workflow"]["repository"],
                    "run_id": result["workflow"]["github_run_id"],
                    "run_attempt": result["workflow"]["github_run_attempt"],
                }
                self.assertIsNone(retained[field])

    def test_cross_field_transition_is_rejected_without_echoing_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            result = receipt.generate(
                self.args(
                    root,
                    operation="advance",
                    android_expected_fraction="0.02",
                    android_target_fraction="0.10",
                )
            )
            self.assertEqual("rejected", result["input_validation"]["status"])
            self.assertIsNone(result["operation"])
            self.assertIsNone(result["android_expected_current_fraction"])
            self.assertIsNone(result["android_target_fraction"])
            self.assertEqual(
                "rejected_pre_mutation", result["android"]["mutation_status"]
            )
            self.assertEqual(
                "rejected_pre_mutation", result["ios"]["mutation_status"]
            )

    def test_intent_step_failure_rejects_even_well_formed_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(root / "google-play-rollout.json", self.valid_google())
            result = receipt.generate(self.args(root, intent_outcome="failure"))
            self.assertEqual("rejected", result["input_validation"]["status"])
            self.assertEqual("failure", result["input_validation"]["intent_step_outcome"])
            self.assertIsNone(result["android"]["store_api_result"])
            self.assertEqual(
                "rejected_pre_mutation", result["android"]["mutation_status"]
            )

    def test_google_journal_without_verified_result_requires_reconciliation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(
                root / "google-play-attempt.json", self.valid_google_journal()
            )
            result = receipt.generate(
                self.args(
                    root,
                    platforms="android",
                    ios_previous_public_version="none",
                    ios_outcome="skipped",
                    android_outcome="failure",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["android"]["mutation_status"]
            )
            self.assertEqual(
                self.valid_google_journal(), result["android"]["store_api_attempt"]
            )
            self.assertIsNone(result["android"]["store_api_result"])

    def test_google_verified_result_without_journal_requires_reconciliation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(root / "google-play-rollout.json", self.valid_google())
            result = receipt.generate(
                self.args(
                    root,
                    platforms="android",
                    ios_outcome="skipped",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["android"]["mutation_status"]
            )
            self.assertEqual(
                self.valid_google(), result["android"]["store_api_result"]
            )

    def test_apple_verified_patch_without_journal_requires_reconciliation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(root / "apple-store-operation.json", self.valid_apple_pause())
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    operation="halt",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="none",
                    android_outcome="skipped",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["ios"]["mutation_status"]
            )

    def test_idempotent_apple_result_requires_proven_no_send_journal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            result_document = self.valid_apple_pause(idempotent=True)
            journal = self.valid_apple_journal()
            journal["before"]["state"] = "PAUSED"  # type: ignore[index]
            journal["mutation_status"] = "proven_not_committed"
            self.write_json(root / "apple-store-operation.json", result_document)
            self.write_json(root / "apple-store-attempt.json", journal)
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    operation="halt",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="none",
                    android_outcome="skipped",
                )
            )
            self.assertEqual("succeeded", result["overall_result"])
            self.assertEqual(
                "succeeded_verified", result["ios"]["mutation_status"]
            )

    def test_apple_patch_journal_and_result_ids_are_cross_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            journal = self.valid_apple_journal()
            journal["before"]["app_id"] = "different-app"  # type: ignore[index]
            self.write_json(root / "apple-store-attempt.json", journal)
            self.write_json(root / "apple-store-operation.json", self.valid_apple_pause())
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    operation="halt",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="none",
                    android_outcome="skipped",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["ios"]["mutation_status"]
            )
            self.assertIn("do not match", result["ios"]["evidence_error"])

    def test_apple_start_preflight_and_postflight_ids_are_cross_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            preflight = self.valid_apple_preflight()
            preflight["update_preflight"]["app_id"] = "different-app"  # type: ignore[index]
            self.write_json(root / "apple-update-preflight.json", preflight)
            self.write_json(
                root / "apple-store-operation.json", self.valid_apple_submission()
            )
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    operation="start",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="1.2.2",
                    android_outcome="skipped",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["ios"]["mutation_status"]
            )
            self.assertIn("identities do not match", result["ios"]["evidence_error"])

    def test_duplicate_key_and_nonfinite_evidence_fail_closed(self) -> None:
        hostile_documents = (
            receipt.canonical_json_bytes(self.valid_google()).replace(
                b'"schema":1', b'"schema":1,"schema":1', 1
            ),
            receipt.canonical_json_bytes(self.valid_google_journal()).replace(
                b'"schema":1', b'"schema":NaN', 1
            ),
        )
        for index, hostile in enumerate(hostile_documents):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                root = base / "evidence"
                root.mkdir()
                self.write_json(root / "google-play-rollout.json", self.valid_google())
                self.write_json(
                    root / "google-play-attempt.json", self.valid_google_journal()
                )
                target = (
                    root / "google-play-rollout.json"
                    if index == 0
                    else root / "google-play-attempt.json"
                )
                target.write_bytes(hostile)
                target.chmod(0o600)
                result = receipt.generate(
                    self.args(root, platforms="android", ios_outcome="skipped")
                )
                self.assertEqual(
                    "unknown_reconcile_required",
                    result["android"]["mutation_status"],
                )

    def test_invalid_present_journal_still_requires_reconciliation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            hostile = self.valid_google_journal()
            hostile["unexpected"] = "not retained"
            self.write_json(root / "google-play-attempt.json", hostile)
            result = receipt.generate(
                self.args(
                    root,
                    platforms="android",
                    ios_previous_public_version="none",
                    ios_outcome="skipped",
                    android_outcome="failure",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["android"]["mutation_status"]
            )
            self.assertIsNone(result["android"]["store_api_attempt"])
            self.assertNotIn("not retained", json.dumps(result))

    def test_failure_without_journal_is_proven_not_committed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            result = receipt.generate(
                self.args(
                    root,
                    platforms="android",
                    ios_previous_public_version="none",
                    ios_outcome="skipped",
                    android_outcome="failure",
                )
            )
            self.assertEqual(
                "proven_not_committed", result["android"]["mutation_status"]
            )
            self.assertEqual("not_attempted", result["ios"]["mutation_status"])

    def test_apple_patch_journal_without_result_requires_reconciliation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            self.write_json(root / "apple-store-attempt.json", self.valid_apple_journal())
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    operation="halt",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="none",
                    android_outcome="skipped",
                    ios_outcome="failure",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["ios"]["mutation_status"]
            )
            self.assertEqual(
                self.valid_apple_journal(), result["ios"]["store_api_attempt"]
            )

    def test_apple_evidence_is_bound_to_exact_build_number(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            root = base / "evidence"
            root.mkdir()
            value = self.valid_apple()
            value["phased_release"]["build"]["build_number"] = "43"  # type: ignore[index]
            self.write_json(root / "apple-store-operation.json", value)
            result = receipt.generate(
                self.args(
                    root,
                    platforms="ios",
                    android_previous_version="none",
                    android_expected_fraction="none",
                    android_target_fraction="none",
                    ios_previous_public_version="none",
                    android_outcome="skipped",
                )
            )
            self.assertEqual(
                "unknown_reconcile_required", result["ios"]["mutation_status"]
            )
            self.assertIsNone(result["ios"]["store_api_result"])

    def test_leading_dash_pem_and_jwt_are_never_retained_by_cli(self) -> None:
        markers = (
            "-----BEGIN PRIVATE KEY-----\nsynthetic",
            "Bearer synthetic-token-value",
            "eyJabcde.eyJfghij.signature",
        )
        for marker in markers:
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                root = base / "evidence"
                namespace = self.args(root, change_id=marker)
                argv: list[str] = []
                for option in receipt.REQUIRED_CLI_OPTIONS:
                    field = option.replace("-", "_")
                    argv.extend((f"--{option}", getattr(namespace, field)))
                self.assertEqual(0, receipt.main(argv))
                raw = (root / "mobile-store-rollout-receipt.json").read_text()
                self.assertNotIn(marker, raw)
                self.assertNotIn("synthetic", raw.lower())
                parsed = json.loads(raw)
                self.assertEqual("rejected", parsed["input_validation"]["status"])
                self.assertIn("change_id", parsed["input_validation"]["redacted_fields"])
                self.assertIsNone(parsed["change_id"])
                self.assertLess(len(raw), 16_384)


class AggregateReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = MobileStoreReceiptTests(methodName="runTest")

    def _write_json(self, path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(receipt.canonical_json_bytes(value))
        path.chmod(0o600)

    def _platform(self, root: pathlib.Path, platform: str) -> dict[str, object]:
        if platform == "android":
            self._write_json(root / "google-play-rollout.json", self.fixture.valid_google())
            self._write_json(
                root / "google-play-attempt.json", self.fixture.valid_google_journal()
            )
            arguments = self.fixture.args(
                root,
                platforms="android",
                ios_previous_public_version="none",
                ios_outcome="skipped",
            )
        else:
            self._write_json(root / "apple-store-operation.json", self.fixture.valid_apple())
            arguments = self.fixture.args(
                root,
                platforms="ios",
                android_previous_version="none",
                android_expected_fraction="none",
                android_target_fraction="none",
                android_outcome="skipped",
            )
        return receipt.generate(arguments)

    def _args(
        self,
        base: pathlib.Path,
        *,
        platforms: str = "both",
        android_result: str = "success",
        ios_result: str = "success",
        android_id: str = "701",
        ios_id: str = "702",
        android_digest: str = "1" * 64,
        ios_digest: str = "2" * 64,
    ) -> argparse.Namespace:
        return argparse.Namespace(
            source_revision="a" * 40,
            signed_release_run_id="123",
            candidate_id="sha256:" + "b" * 64,
            provenance_id="sha256:" + "c" * 64,
            store_handoff_id="store-handoff-v1:sha256:" + "d" * 64,
            app_version="1.2.3",
            build_number="42",
            platforms=platforms,
            operation="advance",
            android_previous_version="41" if platforms != "ios" else "none",
            android_expected_fraction="0.01" if platforms != "ios" else "none",
            android_target_fraction="0.02" if platforms != "ios" else "none",
            ios_previous_public_version="none",
            change_id="change-1",
            confirmation="MUTATE_PRODUCTION_MOBILE_STORES",
            workflow_sha="d" * 40,
            repository=receipt.REPOSITORY,
            run_id="456",
            run_attempt="1",
            android_job_result=android_result,
            android_artifact_id=android_id,
            android_artifact_digest=android_digest,
            android_root=str(base / "android"),
            ios_job_result=ios_result,
            ios_artifact_id=ios_id,
            ios_artifact_digest=ios_digest,
            ios_root=str(base / "ios"),
            output_root=str(base / "aggregate"),
            github_output=str(base / "aggregate-output"),
            github_step_summary=str(base / "aggregate-summary"),
        )

    def test_raw_upload_action_digest_is_accepted_and_prefixed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self._platform(base / "android", "android")
            arguments = self._args(
                base,
                platforms="android",
                ios_result="skipped",
                ios_id="",
                ios_digest="",
            )
            value = receipt.aggregate(arguments)
            self.assertEqual("succeeded", value["overall_result"])
            self.assertEqual("sha256:" + "1" * 64, value["android"]["artifact"]["digest"])
            self.assertEqual("not_selected", value["ios"]["status"])
            package = json.loads(
                (base / "aggregate/PACKAGE_SHA256.json").read_text(encoding="ascii")
            )
            raw = (base / "aggregate/mobile-store-rollout-receipt.json").read_bytes()
            self.assertEqual(4, value["schema"])
            self.assertEqual(4, package["schema"])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), package["receipt_sha256"])
            self.assertEqual(
                "mobile-store-rollout-v4:sha256:" + package["receipt_sha256"],
                package["content_id"],
            )

    def test_schema_v4_binds_every_release_and_transition_identity(self) -> None:
        mutations = {
            "source_revision": "e" * 40,
            "signed_release_run_id": "124",
            "candidate_id": "sha256:" + "e" * 64,
            "provenance_id": "sha256:" + "f" * 64,
            "store_handoff_id": "store-handoff-v1:sha256:" + "e" * 64,
            "app_version": "1.2.4",
            "build_number": "43",
        }
        for field, changed in mutations.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                self._platform(base / "android", "android")
                arguments = self._args(
                    base,
                    platforms="android",
                    ios_result="skipped",
                    ios_id="",
                    ios_digest="",
                )
                setattr(arguments, field, changed)
                value = receipt.aggregate(arguments)
                self.assertEqual("failed", value["overall_result"])
                self.assertEqual("failed", value["android"]["status"])
                self.assertEqual(
                    "platform artifact failed closed validation",
                    value["android"]["validation_error"],
                )

        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self._platform(base / "android", "android")
            arguments = self._args(
                base,
                platforms="android",
                ios_result="skipped",
                ios_id="",
                ios_digest="",
            )
            arguments.operation = "halt"
            arguments.android_target_fraction = "0.01"
            value = receipt.aggregate(arguments)
            self.assertEqual("failed", value["overall_result"])
            self.assertEqual("failed", value["android"]["status"])

    def test_success_evidence_cannot_override_failed_or_cancelled_job_result(self) -> None:
        for job_result in ("failure", "cancelled"):
            with self.subTest(job_result=job_result), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                self._platform(base / "android", "android")
                value = receipt.aggregate(
                    self._args(
                        base,
                        platforms="android",
                        android_result=job_result,
                        ios_result="skipped",
                        ios_id="",
                        ios_digest="",
                    )
                )
                self.assertEqual("failed", value["overall_result"])
                self.assertEqual("failed", value["android"]["status"])
                self.assertEqual(job_result, value["android"]["job_result"])

    def test_prefixed_rest_digest_is_rejected_as_action_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self._platform(base / "android", "android")
            value = receipt.aggregate(
                self._args(
                    base,
                    platforms="android",
                    ios_result="skipped",
                    ios_id="",
                    ios_digest="",
                    android_digest="sha256:" + "1" * 64,
                )
            )
            self.assertEqual("failed", value["overall_result"])
            self.assertIsNone(value["android"]["artifact"])

    def test_requested_missing_artifact_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            value = receipt.aggregate(
                self._args(
                    base,
                    platforms="android",
                    android_result="failure",
                    android_id="",
                    android_digest="",
                    ios_result="skipped",
                    ios_id="",
                    ios_digest="",
                )
            )
            self.assertEqual("failed", value["overall_result"])
            self.assertEqual("failed", value["android"]["status"])
            self.assertEqual(
                "requested platform artifact identity is missing",
                value["android"]["validation_error"],
            )

    def test_both_android_failure_records_ios_safety_skip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            value = receipt.aggregate(
                self._args(
                    base,
                    android_result="failure",
                    android_id="",
                    android_digest="",
                    ios_result="skipped",
                    ios_id="",
                    ios_digest="",
                )
            )
            self.assertEqual("failed", value["overall_result"])
            self.assertEqual("not_run_safety_dependency", value["ios"]["status"])
            self.assertEqual(
                "android_not_succeeded_verified", value["ios"]["not_run_reason"]
            )

    def test_unselected_platform_must_be_exact_skip_without_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self._platform(base / "android", "android")
            value = receipt.aggregate(
                self._args(
                    base,
                    platforms="android",
                    ios_result="success",
                    ios_id="702",
                    ios_digest="2" * 64,
                )
            )
            self.assertEqual("failed", value["overall_result"])
            self.assertEqual("unexpected_execution", value["ios"]["status"])

    def test_platform_artifact_ids_must_be_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self._platform(base / "android", "android")
            self._platform(base / "ios", "ios")
            with self.assertRaises(receipt.ReceiptError):
                receipt.aggregate(self._args(base, android_id="701", ios_id="701"))

    def test_mismatched_platform_run_verifications_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self._platform(base / "android", "android")
            self._platform(base / "ios", "ios")
            ios_receipt_path = base / "ios/mobile-store-rollout-receipt.json"
            ios_receipt = json.loads(ios_receipt_path.read_text(encoding="ascii"))
            ios_receipt["signed_release_run_verification"]["job"]["id"] = "2002"
            self._write_json(ios_receipt_path, ios_receipt)
            digest = receipt.hashlib.sha256(receipt.canonical_json_bytes(ios_receipt)).hexdigest()
            self._write_json(
                base / "ios/PACKAGE_SHA256.json",
                {
                    "content_id": "mobile-store-rollout-v3:sha256:" + digest,
                    "receipt_sha256": digest,
                    "schema": 3,
                },
            )
            with self.assertRaises(receipt.ReceiptError):
                receipt.aggregate(self._args(base))


if __name__ == "__main__":
    unittest.main()
