#!/usr/bin/env python3
"""Adversarial tests for production signed-mobile store candidate validation."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import os
import pathlib
import tempfile
import unittest
from typing import Any
from unittest import mock

import validate_mobile_store_candidate as validator
import validate_mobile_signed_release_run as run_validator


SOURCE_REVISION = "a" * 40
APP_VERSION = "1.2.3"
BUILD_NUMBER = "42"
SIGNED_RELEASE_RUN_ID = "987654321"
SIGNED_RELEASE_RUN_ATTEMPT = "2"
ANDROID_AAB_BYTES = b"signed production Android App Bundle fixture\n"
ANDROID_APK_BYTES = b"signed production Android package fixture\n"
IOS_IPA_BYTES = b"signed production iOS archive fixture\n"
ANDROID_AAB_SHA256 = hashlib.sha256(ANDROID_AAB_BYTES).hexdigest()
ANDROID_APK_SHA256 = hashlib.sha256(ANDROID_APK_BYTES).hexdigest()
ANDROID_SIGNER_SHA256 = "d" * 64
IOS_IPA_SHA256 = hashlib.sha256(IOS_IPA_BYTES).hexdigest()
IOS_SIGNER_SHA256 = "f" * 64
IOS_TEAM_ID = "PAKPERK001"
MOBILE_FEATURE_EVIDENCE_SHA256 = "5" * 64


def valid_mobile_feature_evidence() -> dict[str, object]:
    return {
        "schema": 6,
        "sha256": MOBILE_FEATURE_EVIDENCE_SHA256,
        "paperTitleSearch": True,
        "libraryImportWrites": True,
        "readingFeed": True,
        "toReadFirstEnforcement": True,
        "libraryV2": True,
        "recommendations": True,
        "recommendationEvents": True,
        "searchLookup": True,
        "searchExplore": True,
        "savedQueries": True,
        "researchProfiles": True,
        "readingBriefs": True,
        "subscriptions": True,
        "notifications": True,
        "deepReader": True,
        "paperPassport": True,
        "semanticFacets": True,
        "documentVisualObjects": True,
        "readingCheckpoints": True,
        "annotations": True,
        "evidenceCards": True,
        "researchMemory": True,
        "versionDiff": True,
        "assistantV2": True,
    }


def valid_android() -> dict[str, object]:
    return {
        "aab_sha256": ANDROID_AAB_SHA256,
        "apk_sha256": ANDROID_APK_SHA256,
        "application_id": validator.PRODUCTION_APPLICATION_ID,
        "signer_sha256": ANDROID_SIGNER_SHA256,
    }


def valid_ios() -> dict[str, object]:
    return {
        "application_id": validator.PRODUCTION_APPLICATION_ID,
        "ipa_sha256": IOS_IPA_SHA256,
        "signer_sha256": IOS_SIGNER_SHA256,
        "team_id": IOS_TEAM_ID,
    }


def valid_provenance() -> dict[str, object]:
    return {
        "android": valid_android(),
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "classification": "protected signed mobile release provenance",
        "created_at": "2026-08-03T08:30:00Z",
        "environment": "production",
        "ios": valid_ios(),
        "mobile_feature_evidence": valid_mobile_feature_evidence(),
        "schema": 4,
        "source_revision": SOURCE_REVISION,
        "workflow": {
            "github_run_attempt": "2",
            "github_run_id": SIGNED_RELEASE_RUN_ID,
            "job": validator.WORKFLOW_JOB,
            "path": validator.WORKFLOW_PATH,
            "repository": validator.REPOSITORY,
            "stage": validator.WORKFLOW_STAGE,
            "workflow_sha": SOURCE_REVISION,
        },
    }


def valid_candidate(provenance: dict[str, object]) -> dict[str, object]:
    provenance_bytes = validator.canonical_json_bytes(provenance)
    provenance_id = "sha256:" + hashlib.sha256(provenance_bytes).hexdigest()
    return {
        "android": copy.deepcopy(provenance["android"]),
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "classification": "protected signed mobile candidate",
        "environment": "production",
        "ios": copy.deepcopy(provenance["ios"]),
        "mobile_feature_evidence": copy.deepcopy(
            provenance["mobile_feature_evidence"]
        ),
        "provenance_id": provenance_id,
        "schema": 4,
        "source_revision": SOURCE_REVISION,
        "strict_full_text": True,
    }


def valid_handoff(
    provenance: dict[str, object], candidate_id: str, provenance_id: str
) -> dict[str, object]:
    workflow = copy.deepcopy(provenance["workflow"])
    assert isinstance(workflow, dict)
    workflow["stage"] = validator.UPLOAD_HANDOFF_STAGE
    return {
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "candidate_id": candidate_id,
        "classification": "protected mobile store upload handoff",
        "created_at": "2026-08-03T09:00:00Z",
        "environment": "production",
        "provenance_id": provenance_id,
        "schema": 1,
        "source_revision": SOURCE_REVISION,
        "tooling": {
            "app_store_client_sha256": "1" * 64,
            "bundler_version": "2.6.9",
            "fastlane_lock_sha256": "2" * 64,
            "google_play_client_sha256": "3" * 64,
            "handoff_generator_sha256": "4" * 64,
            "ruby_version": "3.4.10",
            "rubygems_version": "4.0.17",
        },
        "uploads": {
            "android": {
                "application_id": validator.PRODUCTION_APPLICATION_ID,
                "artifact_sha256": ANDROID_AAB_SHA256,
                "destination": "google_play_internal",
                "status": "succeeded",
                "version_code": BUILD_NUMBER,
                "verification": {
                    "bundle": {
                        "sha256": ANDROID_AAB_SHA256,
                        "version_code": BUILD_NUMBER,
                    },
                    "internal_target": {
                        "status": "completed",
                        "user_fraction": None,
                        "version_codes": [BUILD_NUMBER],
                    },
                    "status": "succeeded_verified",
                },
            },
            "ios": {
                "application_id": validator.PRODUCTION_APPLICATION_ID,
                "app_version": APP_VERSION,
                "artifact_sha256": IOS_IPA_SHA256,
                "build_number": BUILD_NUMBER,
                "destination": "app_store_connect",
                "status": "succeeded",
                "verification": {
                    "app_id": "app-1",
                    "asset_delivery_state": "COMPLETE",
                    "asset_type": "ASSET",
                    "build_id": "build-42",
                    "build_upload_file_id": "upload-file-1",
                    "build_upload_id": "build-upload-1",
                    "build_upload_state": "COMPLETE",
                    "file_size": len(IOS_IPA_BYTES),
                    "pre_release_version_id": "pre-1",
                    "processing_state": "VALID",
                    "source_file_checksum": {
                        "algorithm": "SHA_256",
                        "hash": IOS_IPA_SHA256,
                    },
                    "status": "succeeded_verified",
                    "uti": "com.apple.ipa",
                },
            },
        },
        "workflow": workflow,
    }


def valid_run_verification() -> dict[str, object]:
    identity = (
        f"{APP_VERSION}-{BUILD_NUMBER}-{SOURCE_REVISION}-"
        f"{SIGNED_RELEASE_RUN_ID}-{SIGNED_RELEASE_RUN_ATTEMPT}"
    )
    return {
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
            "head_sha": SOURCE_REVISION,
            "id": "2001",
            "name": run_validator.JOB_NAME,
            "run_attempt": SIGNED_RELEASE_RUN_ATTEMPT,
            "run_id": SIGNED_RELEASE_RUN_ID,
            "status": "completed",
            "workflow_name": run_validator.WORKFLOW_NAME,
        },
        "repository": validator.REPOSITORY,
        "run": {
            "conclusion": "success",
            "event": "workflow_dispatch",
            "head_branch": "main",
            "head_sha": SOURCE_REVISION,
            "id": SIGNED_RELEASE_RUN_ID,
            "name": run_validator.WORKFLOW_NAME,
            "path": validator.WORKFLOW_PATH,
            "path_ref": "main",
            "run_attempt": SIGNED_RELEASE_RUN_ATTEMPT,
            "status": "completed",
        },
        "schema": 1,
    }


class Fixture:
    def __init__(
        self,
        root: pathlib.Path,
        *,
        provenance: dict[str, object] | None = None,
        candidate: dict[str, object] | None = None,
        provenance_bytes: bytes | None = None,
        candidate_bytes: bytes | None = None,
    ) -> None:
        if provenance is None:
            provenance = valid_provenance()
        if provenance_bytes is None:
            provenance_bytes = validator.canonical_json_bytes(provenance)
        if candidate is None:
            candidate = valid_candidate(provenance)
        if candidate_bytes is None:
            candidate_bytes = validator.canonical_json_bytes(candidate)
        self.provenance_path = root / "mobile-release-provenance.json"
        self.candidate_path = root / "mobile-candidate.json"
        self.artifact_root = root / "artifacts"
        self.artifact_root.mkdir()
        self.artifact_paths = {
            ".aab": self.artifact_root / "pakperk-production.aab",
            ".apk": self.artifact_root / "pakperk-production.apk",
            ".ipa": self.artifact_root / "pakperk-production.ipa",
        }
        self.artifact_paths[".aab"].write_bytes(ANDROID_AAB_BYTES)
        self.artifact_paths[".apk"].write_bytes(ANDROID_APK_BYTES)
        self.artifact_paths[".ipa"].write_bytes(IOS_IPA_BYTES)
        self.provenance_path.write_bytes(provenance_bytes)
        self.candidate_path.write_bytes(candidate_bytes)
        self.provenance_id = "sha256:" + hashlib.sha256(provenance_bytes).hexdigest()
        self.candidate_id = "sha256:" + hashlib.sha256(candidate_bytes).hexdigest()
        self.handoff_path = root / "mobile-store-upload-handoff.json"
        self.handoff_checksum_path = root / "mobile-store-upload-handoff.sha256"
        handoff_bytes = validator.canonical_json_bytes(
            valid_handoff(provenance, self.candidate_id, self.provenance_id)
        )
        handoff_digest = hashlib.sha256(handoff_bytes).hexdigest()
        self.store_handoff_id = f"store-handoff-v1:sha256:{handoff_digest}"
        self.handoff_path.write_bytes(handoff_bytes)
        self.handoff_checksum_path.write_bytes(
            f"{handoff_digest}  mobile-store-upload-handoff.json\n".encode("ascii")
        )
        self.run_verification_path = root / "signed-release-run-verification.json"
        self.run_verification_path.write_bytes(
            validator.canonical_json_bytes(valid_run_verification())
        )
        self.run_verification_path.chmod(0o600)

    def rewrite_handoff(self, mutate: Any) -> None:
        handoff = validator._parse_canonical_json(
            self.handoff_path.read_bytes(), "test handoff"
        )
        mutate(handoff)
        handoff_bytes = validator.canonical_json_bytes(handoff)
        digest = hashlib.sha256(handoff_bytes).hexdigest()
        self.store_handoff_id = f"store-handoff-v1:sha256:{digest}"
        self.handoff_path.write_bytes(handoff_bytes)
        self.handoff_checksum_path.write_bytes(
            f"{digest}  mobile-store-upload-handoff.json\n".encode("ascii")
        )

    def validate(self, **overrides: str) -> dict[str, Any]:
        arguments = {
            "candidate_id": self.candidate_id,
            "provenance_id": self.provenance_id,
            "source_revision": SOURCE_REVISION,
            "app_version": APP_VERSION,
            "build_number": BUILD_NUMBER,
            "signed_release_run_id": SIGNED_RELEASE_RUN_ID,
            "signed_release_run_attempt": SIGNED_RELEASE_RUN_ATTEMPT,
            "store_handoff_id": self.store_handoff_id,
        }
        arguments.update(overrides)
        return validator.validate_store_candidate(
            self.candidate_path,
            self.provenance_path,
            self.artifact_root,
            self.handoff_path,
            self.handoff_checksum_path,
            self.run_verification_path,
            **arguments,
        )


class MobileStoreCandidateValidationTests(unittest.TestCase):
    def fixture(
        self,
        root: pathlib.Path,
        *,
        provenance: dict[str, object] | None = None,
        candidate: dict[str, object] | None = None,
        provenance_bytes: bytes | None = None,
        candidate_bytes: bytes | None = None,
    ) -> Fixture:
        return Fixture(
            root,
            provenance=provenance,
            candidate=candidate,
            provenance_bytes=provenance_bytes,
            candidate_bytes=candidate_bytes,
        )

    def test_valid_production_candidate_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            binding = fixture.validate()
        self.assertEqual(binding["candidate_id"], fixture.candidate_id)
        self.assertEqual(binding["provenance_id"], fixture.provenance_id)
        self.assertEqual(binding["signed_release_run_id"], SIGNED_RELEASE_RUN_ID)
        self.assertEqual(
            binding["signed_release_run_attempt"], SIGNED_RELEASE_RUN_ATTEMPT
        )
        self.assertEqual(
            binding["store_handoff"]["uploads"]["ios"]["verification"]["app_id"],
            "app-1",
        )
        self.assertEqual(
            binding["artifacts"],
            {
                ".aab": ANDROID_AAB_SHA256,
                ".apk": ANDROID_APK_SHA256,
                ".ipa": IOS_IPA_SHA256,
            },
        )
        self.assertEqual(
            binding["mobile_feature_evidence"],
            valid_mobile_feature_evidence(),
        )

    def test_handoff_must_bind_original_run_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.rewrite_handoff(
                lambda value: value["workflow"].__setitem__("github_run_attempt", "3")
            )
            with self.assertRaisesRegex(validator.ValidationError, "workflow binding"):
                fixture.validate()

    def test_provenance_must_bind_trusted_api_run_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            with self.assertRaisesRegex(validator.ValidationError, "run attempt"):
                fixture.validate(signed_release_run_attempt="3")

    def test_trusted_api_record_must_identify_the_release_workflow(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            value = valid_run_verification()
            value["run"]["path"] = ".github/workflows/forged.yml"  # type: ignore[index]
            fixture.run_verification_path.write_bytes(
                validator.canonical_json_bytes(value)
            )
            with self.assertRaisesRegex(validator.ValidationError, "verification is invalid"):
                fixture.validate()

    def test_handoff_rejects_unverified_google_upload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.rewrite_handoff(
                lambda value: value["uploads"]["android"]["verification"].__setitem__(
                    "status", "unknown_reconcile_required"
                )
            )
            with self.assertRaisesRegex(validator.ValidationError, "Android store upload"):
                fixture.validate()

    def test_handoff_rejects_a_different_verified_google_bundle_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.rewrite_handoff(
                lambda value: value["uploads"]["android"]["verification"][
                    "bundle"
                ].__setitem__("sha256", "0" * 64)
            )
            with self.assertRaisesRegex(validator.ValidationError, "Android store upload"):
                fixture.validate()

    def test_handoff_rejects_wrong_processed_apple_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.rewrite_handoff(
                lambda value: value["uploads"]["ios"].__setitem__(
                    "build_number", "43"
                )
            )
            with self.assertRaisesRegex(validator.ValidationError, "iOS store upload"):
                fixture.validate()

    def test_handoff_rejects_unsafe_apple_app_resource_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.rewrite_handoff(
                lambda value: value["uploads"]["ios"]["verification"].__setitem__(
                    "app_id", "../other-app"
                )
            )
            with self.assertRaisesRegex(validator.ValidationError, "identifier"):
                fixture.validate()

    def test_handoff_rejects_apple_remote_checksum_different_from_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.rewrite_handoff(
                lambda value: value["uploads"]["ios"]["verification"][
                    "source_file_checksum"
                ].__setitem__("hash", "0" * 64)
            )
            with self.assertRaisesRegex(validator.ValidationError, "iOS store upload"):
                fixture.validate()

    def test_handoff_rejects_apple_remote_size_different_from_downloaded_ipa(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.rewrite_handoff(
                lambda value: value["uploads"]["ios"]["verification"].__setitem__(
                    "file_size", len(IOS_IPA_BYTES) + 1
                )
            )
            with self.assertRaisesRegex(validator.ValidationError, "iOS store upload"):
                fixture.validate()

    def test_handoff_checksum_package_is_mandatory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            fixture.handoff_checksum_path.write_text(
                f"{'0' * 64}  mobile-store-upload-handoff.json\n",
                encoding="ascii",
            )
            with self.assertRaisesRegex(validator.ValidationError, "checksum package"):
                fixture.validate()

    def test_cli_accepts_the_required_store_rollout_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = validator.main(
                    [
                        "--candidate",
                        str(fixture.candidate_path),
                        "--provenance",
                        str(fixture.provenance_path),
                        "--artifact-root",
                        str(fixture.artifact_root),
                        "--store-handoff",
                        str(fixture.handoff_path),
                        "--store-handoff-checksum",
                        str(fixture.handoff_checksum_path),
                        "--run-verification",
                        str(fixture.run_verification_path),
                        "--candidate-id",
                        fixture.candidate_id,
                        "--provenance-id",
                        fixture.provenance_id,
                        "--source-revision",
                        SOURCE_REVISION,
                        "--app-version",
                        APP_VERSION,
                        "--build-number",
                        BUILD_NUMBER,
                        "--signed-release-run-id",
                        SIGNED_RELEASE_RUN_ID,
                        "--signed-release-run-attempt",
                        SIGNED_RELEASE_RUN_ATTEMPT,
                        "--store-handoff-id",
                        fixture.store_handoff_id,
                    ]
                )
        self.assertEqual(result, 0)
        self.assertIn("validated for store rollout", output.getvalue())

    def test_duplicate_keys_fail_before_schema_validation(self) -> None:
        provenance = valid_provenance()
        candidate = valid_candidate(provenance)
        raw = validator.canonical_json_bytes(candidate).replace(
            b'"schema":4', b'"schema":4,"schema":4', 1
        )
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory),
                provenance=provenance,
                candidate=candidate,
                candidate_bytes=raw,
            )
            with self.assertRaisesRegex(validator.ValidationError, "duplicate key"):
                fixture.validate()

    def test_nonfinite_json_fails(self) -> None:
        provenance = valid_provenance()
        candidate = valid_candidate(provenance)
        raw = validator.canonical_json_bytes(candidate).replace(
            b'"schema":4', b'"schema":NaN', 1
        )
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory),
                provenance=provenance,
                candidate=candidate,
                candidate_bytes=raw,
            )
            with self.assertRaisesRegex(validator.ValidationError, "non-finite"):
                fixture.validate()

    def test_noncanonical_json_fails(self) -> None:
        provenance = valid_provenance()
        candidate = valid_candidate(provenance)
        raw = validator.canonical_json_bytes(candidate).replace(b'":', b'": ', 1)
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory),
                provenance=provenance,
                candidate=candidate,
                candidate_bytes=raw,
            )
            with self.assertRaisesRegex(validator.ValidationError, "exact canonical"):
                fixture.validate()

    def test_extra_fields_fail_at_every_closed_boundary(self) -> None:
        mutations = []
        candidate_root = valid_candidate(valid_provenance())
        candidate_root["unexpected"] = False
        mutations.append((candidate_root, valid_provenance(), "candidate manifest"))

        provenance_root = valid_provenance()
        provenance_root["unexpected"] = False
        mutations.append(
            (valid_candidate(provenance_root), provenance_root, "provenance")
        )

        provenance_android = valid_provenance()
        android = provenance_android["android"]
        assert isinstance(android, dict)
        android["unexpected"] = "safe"
        mutations.append(
            (
                valid_candidate(provenance_android),
                provenance_android,
                "Android identity",
            )
        )

        provenance_workflow = valid_provenance()
        workflow = provenance_workflow["workflow"]
        assert isinstance(workflow, dict)
        workflow["unexpected"] = "safe"
        mutations.append(
            (valid_candidate(provenance_workflow), provenance_workflow, "workflow")
        )

        for index, (candidate, provenance, message) in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                fixture = self.fixture(
                    pathlib.Path(directory),
                    provenance=provenance,
                    candidate=candidate,
                )
                with self.assertRaisesRegex(validator.ValidationError, message):
                    fixture.validate()

    def test_candidate_and_provenance_content_ids_are_exact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            for key, message in (
                ("candidate_id", "candidate manifest content ID"),
                ("provenance_id", "provenance manifest content ID"),
            ):
                with (
                    self.subTest(key=key),
                    self.assertRaisesRegex(validator.ValidationError, message),
                ):
                    fixture.validate(**{key: "sha256:" + "0" * 64})

    def test_manifest_inputs_require_lowercase_sha256_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            with self.assertRaisesRegex(
                validator.ValidationError, "candidate content ID"
            ):
                fixture.validate(candidate_id="sha256:" + "A" * 64)

    def test_only_production_manifests_pass(self) -> None:
        for target in ("candidate", "provenance"):
            provenance = valid_provenance()
            candidate = valid_candidate(provenance)
            if target == "candidate":
                candidate["environment"] = "staging"
            else:
                provenance["environment"] = "staging"
                candidate = valid_candidate(provenance)
            with (
                self.subTest(target=target),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(
                    pathlib.Path(directory),
                    provenance=provenance,
                    candidate=candidate,
                )
                with self.assertRaisesRegex(validator.ValidationError, "production"):
                    fixture.validate()

    def test_source_version_and_build_must_match_the_requested_release(self) -> None:
        for argument, value in (
            ("source_revision", "9" * 40),
            ("app_version", "9.9.9"),
            ("build_number", "99"),
        ):
            with (
                self.subTest(argument=argument),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(pathlib.Path(directory))
                with self.assertRaisesRegex(
                    validator.ValidationError, "trusted signed release run verification"
                ):
                    fixture.validate(**{argument: value})

    def test_candidate_and_provenance_schema_is_the_exact_integer_four(self) -> None:
        for target in ("candidate", "provenance"):
            for invalid in (3, True, 4.0, "4"):
                provenance = valid_provenance()
                candidate = valid_candidate(provenance)
                if target == "candidate":
                    candidate["schema"] = invalid
                else:
                    provenance["schema"] = invalid
                    candidate = valid_candidate(provenance)
                with (
                    self.subTest(target=target, invalid=invalid),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    fixture = self.fixture(
                        pathlib.Path(directory),
                        provenance=provenance,
                        candidate=candidate,
                    )
                    with self.assertRaisesRegex(
                        validator.ValidationError, "exact integer"
                    ):
                        fixture.validate()

    def test_mobile_feature_evidence_is_closed_and_matches_provenance(self) -> None:
        for key in ("sha256", *validator.MOBILE_FEATURE_FLAG_KEYS):
            provenance = valid_provenance()
            candidate = valid_candidate(provenance)
            feature_evidence = candidate["mobile_feature_evidence"]
            assert isinstance(feature_evidence, dict)
            feature_evidence[key] = (
                "4" * 64 if key == "sha256" else not feature_evidence[key]
            )
            with (
                self.subTest(key=key),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(
                    pathlib.Path(directory),
                    provenance=provenance,
                    candidate=candidate,
                )
                with self.assertRaisesRegex(
                    validator.ValidationError, "does not match"
                ):
                    fixture.validate()

        provenance = valid_provenance()
        feature_evidence = provenance["mobile_feature_evidence"]
        assert isinstance(feature_evidence, dict)
        feature_evidence["readingFeed"] = 1
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory),
                provenance=provenance,
                candidate=valid_candidate(provenance),
            )
            with self.assertRaisesRegex(validator.ValidationError, "exact booleans"):
                fixture.validate()

        provenance = valid_provenance()
        feature_evidence = provenance["mobile_feature_evidence"]
        assert isinstance(feature_evidence, dict)
        feature_evidence["schema"] = 5
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory),
                provenance=provenance,
                candidate=valid_candidate(provenance),
            )
            with self.assertRaisesRegex(validator.ValidationError, "exact integer 6"):
                fixture.validate()

    def test_each_bound_mobile_dependency_is_fail_closed(self) -> None:
        for feature, dependencies in validator.MOBILE_FEATURE_DEPENDENCIES:
            for dependency in dependencies:
                with (
                    self.subTest(feature=feature, dependency=dependency),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    provenance = valid_provenance()
                    feature_evidence = provenance["mobile_feature_evidence"]
                    assert isinstance(feature_evidence, dict)
                    feature_evidence[feature] = True
                    feature_evidence[dependency] = False
                    fixture = self.fixture(
                        pathlib.Path(directory),
                        provenance=provenance,
                        candidate=valid_candidate(provenance),
                    )
                    with self.assertRaisesRegex(
                        validator.ValidationError, "dependency graph"
                    ):
                        fixture.validate()

    def test_strict_full_text_requires_the_exact_true_boolean(self) -> None:
        for invalid in (False, 1, "true"):
            provenance = valid_provenance()
            candidate = valid_candidate(provenance)
            candidate["strict_full_text"] = invalid
            with (
                self.subTest(invalid=invalid),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(
                    pathlib.Path(directory),
                    provenance=provenance,
                    candidate=candidate,
                )
                with self.assertRaisesRegex(
                    validator.ValidationError, "strict full text"
                ):
                    fixture.validate()

    def test_application_ids_are_the_exact_production_id(self) -> None:
        for target in ("candidate", "provenance"):
            for platform in ("android", "ios"):
                provenance = valid_provenance()
                candidate = valid_candidate(provenance)
                payload = candidate if target == "candidate" else provenance
                identity = payload[platform]
                assert isinstance(identity, dict)
                identity["application_id"] = "app.pakperk.pakperk.staging"
                if target == "provenance":
                    candidate = valid_candidate(provenance)
                with (
                    self.subTest(target=target, platform=platform),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    fixture = self.fixture(
                        pathlib.Path(directory),
                        provenance=provenance,
                        candidate=candidate,
                    )
                    with self.assertRaisesRegex(
                        validator.ValidationError, "production"
                    ):
                        fixture.validate()

    def test_platform_identity_values_use_closed_formats(self) -> None:
        cases = (
            ("android", "aab_sha256", "B" * 64, "Android aab_sha256"),
            ("android", "signer_sha256", "short", "Android signer_sha256"),
            ("ios", "ipa_sha256", "E" * 64, "iOS ipa_sha256"),
            ("ios", "team_id", "too-short", "iOS team ID"),
        )
        for platform, key, invalid, message in cases:
            provenance = valid_provenance()
            identity = provenance[platform]
            assert isinstance(identity, dict)
            identity[key] = invalid
            candidate = valid_candidate(provenance)
            with (
                self.subTest(platform=platform, key=key),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(
                    pathlib.Path(directory),
                    provenance=provenance,
                    candidate=candidate,
                )
                with self.assertRaisesRegex(validator.ValidationError, message):
                    fixture.validate()

    def test_candidate_platform_identities_must_exactly_match_provenance(self) -> None:
        provenance = valid_provenance()
        candidate = valid_candidate(provenance)
        android = candidate["android"]
        assert isinstance(android, dict)
        android["apk_sha256"] = "1" * 64
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory), provenance=provenance, candidate=candidate
            )
            with self.assertRaisesRegex(validator.ValidationError, "do not match"):
                fixture.validate()

    def test_candidate_embeds_the_requested_provenance_id(self) -> None:
        provenance = valid_provenance()
        candidate = valid_candidate(provenance)
        candidate["provenance_id"] = "sha256:" + "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory), provenance=provenance, candidate=candidate
            )
            with self.assertRaisesRegex(
                validator.ValidationError, "candidate provenance"
            ):
                fixture.validate()

    def test_workflow_binding_is_exact(self) -> None:
        cases = {
            "repository": "ErrDivine/Other",
            "path": ".github/workflows/other.yml",
            "job": "unsigned-candidate",
            "stage": "artifacts_built",
            "workflow_sha": "9" * 40,
        }
        for key, invalid in cases.items():
            provenance = valid_provenance()
            workflow = provenance["workflow"]
            assert isinstance(workflow, dict)
            workflow[key] = invalid
            candidate = valid_candidate(provenance)
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                fixture = self.fixture(
                    pathlib.Path(directory),
                    provenance=provenance,
                    candidate=candidate,
                )
                with self.assertRaisesRegex(
                    validator.ValidationError, "workflow binding"
                ):
                    fixture.validate()

    def test_workflow_is_bound_to_the_requested_signed_release_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            with self.assertRaisesRegex(validator.ValidationError, "run ID"):
                fixture.validate(signed_release_run_id="123456789")

    def test_workflow_attempt_has_a_closed_positive_integer_format(self) -> None:
        provenance = valid_provenance()
        workflow = provenance["workflow"]
        assert isinstance(workflow, dict)
        workflow["github_run_attempt"] = 2
        candidate = valid_candidate(provenance)
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(
                pathlib.Path(directory), provenance=provenance, candidate=candidate
            )
            with self.assertRaisesRegex(validator.ValidationError, "run attempt"):
                fixture.validate()

    def test_created_at_must_be_a_real_whole_second_utc_timestamp(self) -> None:
        for invalid in ("2026-02-30T00:00:00Z", "2026-08-03T08:30:00.1Z"):
            provenance = valid_provenance()
            provenance["created_at"] = invalid
            candidate = valid_candidate(provenance)
            with (
                self.subTest(invalid=invalid),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(
                    pathlib.Path(directory),
                    provenance=provenance,
                    candidate=candidate,
                )
                with self.assertRaisesRegex(validator.ValidationError, "created_at"):
                    fixture.validate()

    def test_artifact_root_requires_every_signed_platform_suffix(self) -> None:
        for suffix in (".aab", ".apk", ".ipa"):
            with (
                self.subTest(suffix=suffix),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(pathlib.Path(directory))
                fixture.artifact_paths[suffix].unlink()
                with self.assertRaisesRegex(validator.ValidationError, "exactly one"):
                    fixture.validate()

    def test_artifact_root_rejects_duplicate_suffixes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            (fixture.artifact_root / "second-production.aab").write_bytes(
                ANDROID_AAB_BYTES
            )
            with self.assertRaisesRegex(validator.ValidationError, "duplicate"):
                fixture.validate()

    def test_artifact_root_rejects_every_extra_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            (fixture.artifact_root / "download-metadata.txt").write_text(
                "not part of the signed artifact contract\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(validator.ValidationError, "unexpected entry"):
                fixture.validate()

    def test_artifact_root_itself_cannot_be_a_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = self.fixture(root)
            real_root = root / "real-artifacts"
            fixture.artifact_root.rename(real_root)
            fixture.artifact_root.symlink_to(real_root, target_is_directory=True)
            with self.assertRaisesRegex(validator.ValidationError, "real directory"):
                fixture.validate()

    def test_artifacts_cannot_be_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = self.fixture(root)
            target = root / "outside-production.aab"
            fixture.artifact_paths[".aab"].rename(target)
            fixture.artifact_paths[".aab"].symlink_to(target)
            with self.assertRaisesRegex(validator.ValidationError, "bounded regular"):
                fixture.validate()

    def test_artifacts_must_have_exactly_one_hard_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = self.fixture(root)
            os.link(fixture.artifact_paths[".apk"], root / "outside-apk-hardlink")
            with self.assertRaisesRegex(validator.ValidationError, "bounded regular"):
                fixture.validate()

    def test_artifacts_must_be_nonempty_and_bounded(self) -> None:
        for mode in ("empty", "oversized"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                fixture = self.fixture(pathlib.Path(directory))
                if mode == "empty":
                    fixture.artifact_paths[".ipa"].write_bytes(b"")
                    context = contextlib.nullcontext()
                else:
                    context = mock.patch.object(validator, "MAXIMUM_ARTIFACT_BYTES", 4)
                with (
                    context,
                    self.assertRaisesRegex(
                        validator.ValidationError, "bounded regular"
                    ),
                ):
                    fixture.validate()

    def test_downloaded_artifact_digests_must_match_the_signed_manifests(self) -> None:
        for suffix in (".aab", ".apk", ".ipa"):
            with (
                self.subTest(suffix=suffix),
                tempfile.TemporaryDirectory() as directory,
            ):
                fixture = self.fixture(pathlib.Path(directory))
                fixture.artifact_paths[suffix].write_bytes(b"tampered signed binary\n")
                with self.assertRaisesRegex(validator.ValidationError, "digests"):
                    fixture.validate()

    def test_artifact_change_during_hash_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "candidate.aab"
            path.write_bytes(ANDROID_AAB_BYTES)
            real_fstat = os.fstat
            calls = 0

            def changing_fstat(descriptor: int) -> os.stat_result:
                nonlocal calls
                calls += 1
                if calls == 2:
                    path.write_bytes(b"changed while the descriptor was open\n")
                return real_fstat(descriptor)

            with (
                mock.patch.object(validator.os, "fstat", side_effect=changing_fstat),
                self.assertRaisesRegex(validator.ValidationError, "changed while"),
            ):
                validator._hash_artifact(path, ".aab artifact")

    def test_manifest_must_be_a_regular_file_not_a_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = self.fixture(root)
            target = root / "candidate-target.json"
            fixture.candidate_path.rename(target)
            fixture.candidate_path.symlink_to(target)
            with self.assertRaisesRegex(validator.ValidationError, "bounded regular"):
                fixture.validate()

    def test_manifest_must_have_exactly_one_hard_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = self.fixture(root)
            os.link(fixture.candidate_path, root / "second-candidate-link.json")
            with self.assertRaisesRegex(validator.ValidationError, "bounded regular"):
                fixture.validate()

    def test_manifest_size_is_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = self.fixture(root)
            fixture.candidate_path.write_bytes(
                b"x" * (validator.MAXIMUM_MANIFEST_BYTES + 1)
            )
            fixture.candidate_id = (
                "sha256:"
                + hashlib.sha256(fixture.candidate_path.read_bytes()).hexdigest()
            )
            with self.assertRaisesRegex(validator.ValidationError, "bounded regular"):
                fixture.validate()

    def test_cli_failure_is_closed_and_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(pathlib.Path(directory))
            error = io.StringIO()
            with contextlib.redirect_stderr(error):
                result = validator.main(
                    [
                        "--candidate",
                        str(fixture.candidate_path),
                        "--provenance",
                        str(fixture.provenance_path),
                        "--artifact-root",
                        str(fixture.artifact_root),
                        "--store-handoff",
                        str(fixture.handoff_path),
                        "--store-handoff-checksum",
                        str(fixture.handoff_checksum_path),
                        "--run-verification",
                        str(fixture.run_verification_path),
                        "--candidate-id",
                        "sha256:" + "0" * 64,
                        "--provenance-id",
                        fixture.provenance_id,
                        "--source-revision",
                        SOURCE_REVISION,
                        "--app-version",
                        APP_VERSION,
                        "--build-number",
                        BUILD_NUMBER,
                        "--signed-release-run-id",
                        SIGNED_RELEASE_RUN_ID,
                        "--signed-release-run-attempt",
                        SIGNED_RELEASE_RUN_ATTEMPT,
                        "--store-handoff-id",
                        fixture.store_handoff_id,
                    ]
                )
        self.assertEqual(result, 1)
        self.assertIn("validation failed", error.getvalue())


if __name__ == "__main__":
    unittest.main()
