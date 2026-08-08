#!/usr/bin/env python3
"""Adversarial tests for the credential-free signed-release finalizer."""

from __future__ import annotations

import hashlib
import json
import pathlib
import tempfile
import types
import unittest

import finalize_mobile_signed_release as finalizer
import test_validate_mobile_store_candidate as candidate_fixtures
import validate_mobile_store_candidate as candidate_validator


class Fixture:
    def __init__(
        self,
        root: pathlib.Path,
        *,
        requested: bool = True,
        environment: str = "production",
    ) -> None:
        self.root = root.resolve()
        source_root = self.root / "source"
        source_root.mkdir(mode=0o700)
        candidate_fixture = candidate_fixtures.Fixture(source_root)
        self.candidate_root = self._directory("candidate")
        (self.candidate_root / "evidence").mkdir(mode=0o700)
        for source, name in (
            (candidate_fixture.candidate_path, "mobile-candidate.json"),
            (candidate_fixture.provenance_path, "mobile-release-provenance.json"),
        ):
            destination = self.candidate_root / "evidence" / name
            destination.write_bytes(source.read_bytes())
            destination.chmod(0o600)
        application_id = finalizer.APPLICATION_IDS[environment]
        provenance_path = (
            self.candidate_root / "evidence/mobile-release-provenance.json"
        )
        provenance = json.loads(provenance_path.read_text())
        provenance["environment"] = environment
        provenance["android"]["application_id"] = application_id
        provenance["ios"]["application_id"] = application_id
        provenance_raw = finalizer.canonical_json_bytes(provenance)
        provenance_path.write_bytes(provenance_raw)
        provenance_id = "sha256:" + hashlib.sha256(provenance_raw).hexdigest()
        candidate_path = self.candidate_root / "evidence/mobile-candidate.json"
        self.candidate = json.loads(candidate_path.read_text())
        self.candidate["environment"] = environment
        self.candidate["android"]["application_id"] = application_id
        self.candidate["ios"]["application_id"] = application_id
        self.candidate["provenance_id"] = provenance_id
        self.candidate["strict_full_text"] = environment != "development"
        candidate_raw = finalizer.canonical_json_bytes(self.candidate)
        candidate_path.write_bytes(candidate_raw)
        candidate_id = "sha256:" + hashlib.sha256(candidate_raw).hexdigest()

        self.android = self._directory("android")
        self.ios = self._directory("ios")
        self.handoff = self._directory("handoff")
        self.output = self.root / "output"
        self.github_output = self.root / "github-output"
        self.github_output.write_text("", encoding="utf-8")
        self.arguments = types.SimpleNamespace(
            requested_uploads="true" if requested else "false",
            environment=environment,
            android_application_id=application_id,
            ios_application_id=application_id,
            repository=finalizer.REPOSITORY,
            source_revision=candidate_fixtures.SOURCE_REVISION,
            app_version=candidate_fixtures.APP_VERSION,
            build_number=candidate_fixtures.BUILD_NUMBER,
            run_id=candidate_fixtures.SIGNED_RELEASE_RUN_ID,
            run_attempt=candidate_fixtures.SIGNED_RELEASE_RUN_ATTEMPT,
            candidate_id=candidate_id,
            provenance_id=provenance_id,
            candidate_job_result="success",
            bootstrap_job_result="success" if requested else "skipped",
            android_job_result="success" if requested else "skipped",
            ios_job_result="success" if requested else "skipped",
            candidate_artifact_id="101",
            candidate_artifact_digest="1" * 64,
            store_client_artifact_id="102" if requested else "",
            store_client_artifact_digest="2" * 64 if requested else "",
            android_evidence_artifact_id="103" if requested else "",
            android_evidence_artifact_digest="3" * 64 if requested else "",
            ios_evidence_artifact_id="104" if requested else "",
            ios_evidence_artifact_digest="4" * 64 if requested else "",
            store_handoff_id="",
            handoff_artifact_id="105" if requested else "",
            handoff_artifact_digest="5" * 64 if requested else "",
            handoff_step_outcome="success" if requested else "skipped",
            handoff_upload_outcome="success" if requested else "skipped",
            candidate_root=self.candidate_root,
            android_evidence_root=self.android,
            ios_evidence_root=self.ios,
            handoff_root=self.handoff,
            output_root=self.output,
            github_output=self.github_output,
        )
        if requested:
            self._successful_platform_evidence()
            handoff = candidate_fixtures.valid_handoff(
                candidate_fixtures.valid_provenance(),
                candidate_id,
                provenance_id,
            )
            handoff["tooling"] = dict(finalizer.EXPECTED_TOOLING)
            handoff_raw = candidate_validator.canonical_json_bytes(handoff)
            digest = hashlib.sha256(handoff_raw).hexdigest()
            self.arguments.store_handoff_id = f"store-handoff-v1:sha256:{digest}"
            self._write(
                self.handoff / "mobile-store-upload-handoff.json", handoff_raw
            )
            self._write(
                self.handoff / "mobile-store-upload-handoff.sha256",
                f"{digest}  mobile-store-upload-handoff.json\n".encode("ascii"),
            )

    def _successful_platform_evidence(self) -> None:
        candidate_artifact = {"digest": "1" * 64, "id": 101}
        store_artifact = {"digest": "2" * 64, "id": 102}
        for platform, root in (("android", self.android), ("ios", self.ios)):
            outcome = finalizer._expected_platform_outcome(
                args=self.arguments,
                platform=platform,
                candidate_artifact=candidate_artifact,
                store_artifact=store_artifact,
            )
            self._write(
                root / f"{platform}-platform-outcome.json",
                finalizer.canonical_json_bytes(outcome),
            )
            artifact_size = 64 if platform == "android" else 38
            digest_key = "aab_sha256" if platform == "android" else "ipa_sha256"
            attempt = {
                "application_id": (
                    self.arguments.android_application_id
                    if platform == "android"
                    else self.arguments.ios_application_id
                ),
                "app_version": self.arguments.app_version,
                "artifact_sha256": self.candidate[platform][digest_key],
                "artifact_size": artifact_size,
                "build_number": self.arguments.build_number,
                "candidate_id": self.arguments.candidate_id,
                "destination": (
                    "google_play_internal" if platform == "android" else "app_store_connect"
                ),
                "mutation_status": "unknown_reconcile_required",
                "platform": platform,
                "provenance_id": self.arguments.provenance_id,
                "schema": 1,
                "workflow": {
                    "github_run_attempt": self.arguments.run_attempt,
                    "github_run_id": self.arguments.run_id,
                    "path": finalizer.WORKFLOW_PATH,
                    "repository": finalizer.REPOSITORY,
                    "source_revision": self.arguments.source_revision,
                },
            }
            self._write(
                root / f"{platform}-upload-attempt.json",
                finalizer.canonical_json_bytes(attempt),
            )
        google = {
            "application_id": self.arguments.android_application_id,
            "bundle": {
                "sha256": self.candidate["android"]["aab_sha256"],
                "version_code": self.arguments.build_number,
            },
            "internal_target": {
                "status": "completed",
                "user_fraction": None,
                "version_codes": [self.arguments.build_number],
            },
            "schema": 1,
            "verification_status": "succeeded_verified",
            "version_code": self.arguments.build_number,
        }
        self._write(
            self.android / "google-upload-verification.json",
            finalizer.canonical_json_bytes(google),
        )
        apple = {
            "app_version": self.arguments.app_version,
            "application_id": self.arguments.ios_application_id,
            "build_number": self.arguments.build_number,
            "operation": "verify-build",
            "schema": 1,
            "upload_verification": {
                "app_id": "app-1",
                "build": {
                    "build_id": "build-42",
                    "build_number": self.arguments.build_number,
                    "pre_release_version_id": "pre-1",
                    "processing_state": "VALID",
                },
                "build_upload": {
                    "asset_file": {
                        "asset_delivery_state": "COMPLETE",
                        "asset_type": "ASSET",
                        "build_upload_file_id": "upload-file-1",
                        "file_size": 38,
                        "source_file_checksum": {
                            "algorithm": "SHA_256",
                            "hash": self.candidate["ios"]["ipa_sha256"],
                        },
                        "uti": "com.apple.ipa",
                    },
                    "build_id": "build-42",
                    "build_upload_id": "build-upload-1",
                    "state": "COMPLETE",
                },
            },
            "verification_status": "succeeded_verified",
        }
        self._write(
            self.ios / "apple-upload-verification.json",
            finalizer.canonical_json_bytes(apple),
        )

    def _directory(self, name: str) -> pathlib.Path:
        path = self.root / name
        path.mkdir(mode=0o700, parents=True)
        return path

    @staticmethod
    def _write(path: pathlib.Path, raw: bytes) -> None:
        path.write_bytes(raw)
        path.chmod(0o600)


class FinalizeMobileSignedReleaseTests(unittest.TestCase):
    def test_requested_both_platforms_succeed_only_with_verified_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "succeeded")
            self.assertEqual(receipt["android"]["status"], "succeeded_verified")
            self.assertEqual(receipt["ios"]["status"], "succeeded_verified")
            self.assertEqual(receipt["errors"], [])

    def test_not_requested_requires_both_upload_jobs_to_be_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory), requested=False)
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "succeeded")
            self.assertEqual(receipt["android"], {
                "evidence_artifact": None,
                "job_result": "skipped",
                "status": "not_requested",
            })
            self.assertEqual(receipt["ios"], {
                "evidence_artifact": None,
                "job_result": "skipped",
                "status": "not_requested",
            })

    def test_staging_candidate_without_store_uploads_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(
                pathlib.Path(directory), requested=False, environment="staging"
            )
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "succeeded")
            self.assertEqual(receipt["environment"], "staging")

    def test_development_candidate_without_store_uploads_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(
                pathlib.Path(directory), requested=False, environment="development"
            )
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "succeeded")
            self.assertFalse(fixture.candidate["strict_full_text"])

    def test_environment_application_identity_must_match(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(
                pathlib.Path(directory), requested=False, environment="staging"
            )
            fixture.arguments.android_application_id = (
                finalizer.PRODUCTION_APPLICATION_ID
            )
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "failed")
            self.assertIn("android_application_id_invalid", receipt["errors"])

    def test_store_uploads_are_rejected_outside_production(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory), environment="staging")
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "failed")
            self.assertIn("store_upload_environment_invalid", receipt["errors"])

    def test_not_requested_rejects_an_unexpected_platform_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory), requested=False)
            fixture.arguments.android_job_result = "success"
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "failed")
            self.assertIn("not_requested_boundary_invalid", receipt["errors"])

    def test_missing_requested_platform_evidence_is_retained_as_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            (fixture.ios / "apple-upload-verification.json").unlink()
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "failed")
            self.assertEqual(receipt["ios"]["status"], "failed")
            self.assertIn("ios_evidence_validation_failed", receipt["errors"])
            self.assertTrue(
                (fixture.output / "mobile-signed-release-outcome.json").is_file()
            )

    def test_platform_outcome_must_bind_raw_transfer_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            path = fixture.android / "android-platform-outcome.json"
            value = json.loads(path.read_text())
            value["candidate_artifact"]["digest"] = "f" * 64
            path.write_bytes(finalizer.canonical_json_bytes(value))
            receipt = finalizer.generate(fixture.arguments)
            self.assertIn("android_evidence_validation_failed", receipt["errors"])

    def test_production_candidate_must_retain_strict_full_text_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            candidate_path = fixture.candidate_root / "evidence/mobile-candidate.json"
            candidate = json.loads(candidate_path.read_text())
            candidate["strict_full_text"] = False
            raw = finalizer.canonical_json_bytes(candidate)
            candidate_path.write_bytes(raw)
            fixture.arguments.candidate_id = "sha256:" + hashlib.sha256(raw).hexdigest()
            receipt = finalizer.generate(fixture.arguments)
            self.assertIn("candidate_validation_failed", receipt["errors"])
            self.assertTrue(
                (fixture.output / "mobile-signed-release-outcome.json").is_file()
            )

    def test_all_immutable_artifact_ids_must_be_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            fixture.arguments.handoff_artifact_id = fixture.arguments.candidate_artifact_id
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual(receipt["overall_result"], "failed")
            self.assertIn("artifact_ids_not_distinct", receipt["errors"])

    def test_noncanonical_platform_outcome_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            path = fixture.ios / "ios-platform-outcome.json"
            value = json.loads(path.read_text())
            path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
            receipt = finalizer.generate(fixture.arguments)
            self.assertIn("ios_evidence_validation_failed", receipt["errors"])

    def test_attempt_must_cross_bind_candidate_digest_and_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            path = fixture.android / "android-upload-attempt.json"
            value = json.loads(path.read_text())
            value["artifact_sha256"] = "f" * 64
            path.write_bytes(finalizer.canonical_json_bytes(value))
            receipt = finalizer.generate(fixture.arguments)
            self.assertIn("android_evidence_validation_failed", receipt["errors"])
            self.assertTrue(
                (fixture.output / "mobile-signed-release-outcome.json").is_file()
            )

    def test_remote_proof_must_cross_bind_digest_size_and_store_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            path = fixture.ios / "apple-upload-verification.json"
            value = json.loads(path.read_text())
            value["upload_verification"]["build_upload"]["asset_file"]["file_size"] = 39
            path.write_bytes(finalizer.canonical_json_bytes(value))
            receipt = finalizer.generate(fixture.arguments)
            self.assertIn("ios_evidence_validation_failed", receipt["errors"])

    def test_malformed_handoff_is_retained_as_canonical_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(pathlib.Path(directory))
            path = fixture.handoff / "mobile-store-upload-handoff.json"
            value = json.loads(path.read_text())
            value["uploads"] = "malformed"
            raw = finalizer.canonical_json_bytes(value)
            digest = hashlib.sha256(raw).hexdigest()
            path.write_bytes(raw)
            (fixture.handoff / "mobile-store-upload-handoff.sha256").write_bytes(
                f"{digest}  mobile-store-upload-handoff.json\n".encode("ascii")
            )
            fixture.arguments.store_handoff_id = f"store-handoff-v1:sha256:{digest}"
            receipt = finalizer.generate(fixture.arguments)
            self.assertEqual("failed", receipt["overall_result"])
            self.assertIn("handoff_validation_failed", receipt["errors"])
            self.assertTrue(
                (fixture.output / "mobile-signed-release-outcome.json").is_file()
            )


if __name__ == "__main__":
    unittest.main()
