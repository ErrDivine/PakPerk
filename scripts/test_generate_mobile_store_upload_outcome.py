#!/usr/bin/env python3
"""Tests for unconditional signed-candidate upload outcome receipts."""

from __future__ import annotations

import argparse
import pathlib
import tempfile
import unittest

import generate_mobile_store_upload_attempt as attempt_generator
import generate_mobile_store_upload_outcome as outcome_generator
import test_generate_mobile_store_upload_handoff as handoff_fixtures
import test_validate_mobile_store_candidate as candidate_fixtures
import validate_mobile_store_candidate as validator


class StoreUploadOutcomeTests(unittest.TestCase):
    def args(self, root: pathlib.Path, **updates: str) -> argparse.Namespace:
        values = {
            "candidate": str(root / "mobile-candidate.json"),
            "candidate_id": self.fixture.candidate_id,
            "provenance_id": self.fixture.provenance_id,
            "source_revision": candidate_fixtures.SOURCE_REVISION,
            "app_version": candidate_fixtures.APP_VERSION,
            "build_number": candidate_fixtures.BUILD_NUMBER,
            "repository": validator.REPOSITORY,
            "run_id": candidate_fixtures.SIGNED_RELEASE_RUN_ID,
            "run_attempt": candidate_fixtures.SIGNED_RELEASE_RUN_ATTEMPT,
            "android_upload_outcome": "success",
            "ios_upload_outcome": "success",
            "verification_outcome": "success",
            "handoff_outcome": "success",
            "handoff_upload_outcome": "success",
            "evidence_root": str(root / "attempt"),
        }
        values.update(updates)
        return argparse.Namespace(**values)

    def prepare(self, root: pathlib.Path) -> pathlib.Path:
        self.fixture = candidate_fixtures.Fixture(root)
        self.fixture.candidate_path.chmod(0o600)
        evidence = root / "attempt"
        evidence.mkdir(mode=0o700)
        for platform, suffix in (("android", ".aab"), ("ios", ".ipa")):
            attempt_generator.generate(
                candidate_path=self.fixture.candidate_path,
                artifact_path=self.fixture.artifact_paths[suffix],
                output_path=evidence / f"{platform}-upload-attempt.json",
                platform=platform,
                candidate_id=self.fixture.candidate_id,
                provenance_id=self.fixture.provenance_id,
                source_revision=candidate_fixtures.SOURCE_REVISION,
                app_version=candidate_fixtures.APP_VERSION,
                build_number=candidate_fixtures.BUILD_NUMBER,
                repository=validator.REPOSITORY,
                run_id=candidate_fixtures.SIGNED_RELEASE_RUN_ID,
                run_attempt=candidate_fixtures.SIGNED_RELEASE_RUN_ATTEMPT,
            )
        verification_root = root / "verification-fixture"
        verification_root.mkdir()
        _, google, apple = handoff_fixtures.StoreUploadHandoffTests().prepare(
            verification_root
        )
        (evidence / "google-upload-verification.json").write_bytes(google.read_bytes())
        (evidence / "apple-upload-verification.json").write_bytes(apple.read_bytes())
        for path in evidence.iterdir():
            path.chmod(0o600)
        return evidence

    def test_fully_verified_uploads_are_succeeded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            evidence = self.prepare(root)
            result = outcome_generator.generate(self.args(root))
            self.assertEqual("succeeded", result["overall_result"])
            self.assertEqual("succeeded_verified", result["android"]["mutation_status"])
            self.assertEqual("succeeded_verified", result["ios"]["mutation_status"])
            self.assertEqual(0o600, (evidence / "store-upload-outcome.json").stat().st_mode & 0o777)

    def test_journal_without_remote_proof_requires_reconciliation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            evidence = self.prepare(root)
            (evidence / "apple-upload-verification.json").unlink()
            result = outcome_generator.generate(
                self.args(root, verification_outcome="failure", handoff_outcome="skipped")
            )
            self.assertEqual("unknown_reconcile_required", result["ios"]["mutation_status"])
            self.assertEqual("failed", result["overall_result"])

    def test_missing_immutable_handoff_retention_cannot_be_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root)
            result = outcome_generator.generate(
                self.args(root, handoff_upload_outcome="failure")
            )
            self.assertEqual("failed", result["overall_result"])

    def test_failure_before_journal_proves_no_send(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            evidence = self.prepare(root)
            (evidence / "android-upload-attempt.json").unlink()
            (evidence / "google-upload-verification.json").unlink()
            result = outcome_generator.generate(
                self.args(root, android_upload_outcome="failure", handoff_outcome="skipped")
            )
            self.assertEqual("proven_not_committed", result["android"]["mutation_status"])

    def test_tampered_journal_is_unknown_not_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            evidence = self.prepare(root)
            path = evidence / "android-upload-attempt.json"
            value = validator._parse_canonical_json(path.read_bytes(), "journal")
            value["artifact_sha256"] = "0" * 64
            path.write_bytes(validator.canonical_json_bytes(value))
            path.chmod(0o600)
            result = outcome_generator.generate(self.args(root))
            self.assertEqual("unknown_reconcile_required", result["android"]["mutation_status"])

    def test_apple_remote_size_must_match_pre_send_journal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            evidence = self.prepare(root)
            path = evidence / "apple-upload-verification.json"
            value = validator._parse_canonical_json(path.read_bytes(), "Apple proof")
            value["upload_verification"]["build_upload"]["asset_file"][
                "file_size"
            ] += 1
            path.write_bytes(validator.canonical_json_bytes(value))
            path.chmod(0o600)
            result = outcome_generator.generate(self.args(root))
            self.assertEqual(
                "unknown_reconcile_required", result["ios"]["mutation_status"]
            )
            self.assertEqual("failed", result["overall_result"])


if __name__ == "__main__":
    unittest.main()
