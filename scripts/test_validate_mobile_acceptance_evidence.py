#!/usr/bin/env python3
"""Regressions for protected physical-device acceptance evidence."""

from __future__ import annotations

import copy
import datetime as dt
import hashlib
import pathlib
import stat
import tarfile
import tempfile
import unittest
from typing import Optional

import validate_mobile_acceptance_evidence as validator


SOURCE_REVISION = "a" * 40
VALIDATOR_SHA256 = "9" * 64
DRIVER_SHA256 = "b" * 64
APP_VERSION = "0.2.0"
BUILD_NUMBER = "2"
API_ORIGIN = "https://api.staging.pakperk.app"
APP_LINK_ORIGIN = "https://staging.pakperk.app"
OIDC_ISSUER = "https://identity.staging.pakperk.app/realms/pakperk"
OIDC_CLIENT_ID = "pakperk-mobile-staging"
ANDROID_APPLICATION_ID = "app.pakperk.pakperk.staging"
ANDROID_SIGNER_SHA256 = "c" * 64
ANDROID_AAB_SHA256 = "d" * 64
ANDROID_APK_SHA256 = "6" * 64
IOS_APPLICATION_ID = "app.pakperk.pakperk.staging"
IOS_TEAM_ID = "PAKPERK001"
IOS_SIGNER_SHA256 = "e" * 64
IOS_IPA_SHA256 = "f" * 64
RUN_ID = "123456789"
RUN_ATTEMPT = "2"
RUN_CHALLENGE = "1" * 64
NOT_BEFORE = "2026-08-02T01:00:00Z"
VALIDATED_AT = dt.datetime(2026, 8, 2, 2, 0, 30, tzinfo=dt.timezone.utc)
RUNNER_SESSION_IDENTITY = "7" * 64
RUNNER_HOST_IDENTITY = "8" * 64
MOBILE_FEATURE_EVIDENCE_SHA256 = "5" * 64


def valid_mobile_feature_evidence_binding() -> dict[str, object]:
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


def valid_source_binding_payload() -> dict[str, object]:
    return {
        "schema": validator.SOURCE_BINDING_SCHEMA_VERSION,
        "source_revision": SOURCE_REVISION,
        "environment": "staging",
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "api_origin": API_ORIGIN,
        "app_link_origin": APP_LINK_ORIGIN,
        "oidc_issuer": OIDC_ISSUER,
        "oidc_client_id": OIDC_CLIENT_ID,
    }


def valid_provenance_payload() -> dict[str, object]:
    return {
        "schema": 4,
        "classification": "protected signed mobile release provenance",
        "source_revision": SOURCE_REVISION,
        "environment": "staging",
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "created_at": "2026-08-02T00:45:00Z",
        "mobile_feature_evidence": valid_mobile_feature_evidence_binding(),
        "workflow": {
            "repository": "ErrDivine/PakPerk",
            "path": ".github/workflows/mobile-release.yml",
            "job": "signed-candidate",
            "workflow_sha": SOURCE_REVISION,
            "github_run_id": "987654321",
            "github_run_attempt": "1",
            "stage": "artifacts_verified",
        },
        "android": {
            "aab_sha256": ANDROID_AAB_SHA256,
            "apk_sha256": ANDROID_APK_SHA256,
            "application_id": ANDROID_APPLICATION_ID,
            "signer_sha256": ANDROID_SIGNER_SHA256,
        },
        "ios": {
            "ipa_sha256": IOS_IPA_SHA256,
            "application_id": IOS_APPLICATION_ID,
            "team_id": IOS_TEAM_ID,
            "signer_sha256": IOS_SIGNER_SHA256,
        },
    }


PROVENANCE_BYTES = validator.canonical_json_bytes(valid_provenance_payload())
PROVENANCE_ID = f"sha256:{hashlib.sha256(PROVENANCE_BYTES).hexdigest()}"


def provenance_binding() -> dict[str, object]:
    payload = valid_provenance_payload()
    return {
        "manifest_id": PROVENANCE_ID,
        "workflow": copy.deepcopy(payload["workflow"]),
        "mobile_feature_evidence": copy.deepcopy(
            payload["mobile_feature_evidence"]
        ),
        "android": copy.deepcopy(payload["android"]),
        "ios": copy.deepcopy(payload["ios"]),
    }


def valid_candidate_payload() -> dict[str, object]:
    return {
        "schema": 4,
        "classification": "protected signed mobile candidate",
        "source_revision": SOURCE_REVISION,
        "environment": "staging",
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "strict_full_text": True,
        "mobile_feature_evidence": valid_mobile_feature_evidence_binding(),
        "provenance_id": PROVENANCE_ID,
        "android": {
            "aab_sha256": ANDROID_AAB_SHA256,
            "apk_sha256": ANDROID_APK_SHA256,
            "application_id": ANDROID_APPLICATION_ID,
            "signer_sha256": ANDROID_SIGNER_SHA256,
        },
        "ios": {
            "ipa_sha256": IOS_IPA_SHA256,
            "application_id": IOS_APPLICATION_ID,
            "team_id": IOS_TEAM_ID,
            "signer_sha256": IOS_SIGNER_SHA256,
        },
    }


CANDIDATE_BYTES = validator.canonical_json_bytes(valid_candidate_payload())
CANDIDATE_ID = f"sha256:{hashlib.sha256(CANDIDATE_BYTES).hexdigest()}"


def valid_runner_session_payload() -> dict[str, object]:
    return {
        "schema": 1,
        "classification": "dedicated ephemeral mobile acceptance runner session",
        "source_revision": SOURCE_REVISION,
        "session_id": RUNNER_SESSION_IDENTITY,
        "host_identity_hash": RUNNER_HOST_IDENTITY,
        "runner_class": "dedicated-macos-physical-mobile",
        "physical_identities": {
            role: f"{index + 20:064x}"
            for index, role in enumerate(validator.DEVICE_CONTRACT)
        },
        "dedicated": True,
        "ephemeral": True,
        "created_at": "2026-08-02T00:30:00Z",
        "expires_at": "2026-08-02T06:30:00Z",
    }


RUNNER_SESSION_BYTES = validator.canonical_json_bytes(valid_runner_session_payload())
RUNNER_SESSION_ATTESTATION_ID = (
    f"sha256:{hashlib.sha256(RUNNER_SESSION_BYTES).hexdigest()}"
)


def runner_session_binding() -> dict[str, object]:
    payload = valid_runner_session_payload()
    return {
        "attestation_id": RUNNER_SESSION_ATTESTATION_ID,
        "session_id": payload["session_id"],
        "host_identity_hash": payload["host_identity_hash"],
        "runner_class": payload["runner_class"],
        "physical_identities": copy.deepcopy(payload["physical_identities"]),
        "created_at": payload["created_at"],
        "expires_at": payload["expires_at"],
    }


def load_provenance_payload(payload: object) -> dict[str, object]:
    raw_bytes = validator.canonical_json_bytes(payload)
    provenance_id = f"sha256:{hashlib.sha256(raw_bytes).hexdigest()}"
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "provenance.json"
        path.write_bytes(raw_bytes)
        return validator.load_signed_release_provenance(
            path,
            provenance_id=provenance_id,
            source_revision=SOURCE_REVISION,
            app_version=APP_VERSION,
            build_number=BUILD_NUMBER,
            android_signer_sha256=ANDROID_SIGNER_SHA256,
            ios_team_id=IOS_TEAM_ID,
            ios_signer_sha256=IOS_SIGNER_SHA256,
            require_protected_path=False,
        )


def load_runner_session_payload(
    payload: object,
    *,
    validated_at: dt.datetime = VALIDATED_AT,
) -> dict[str, object]:
    raw_bytes = validator.canonical_json_bytes(payload)
    attestation_id = f"sha256:{hashlib.sha256(raw_bytes).hexdigest()}"
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "runner-session.json"
        path.write_bytes(raw_bytes)
        return validator.load_runner_session_attestation(
            path,
            attestation_id=attestation_id,
            source_revision=SOURCE_REVISION,
            validated_at=validated_at,
            require_protected_path=False,
        )


def candidate_binding(
    payload: Optional[object] = None,
    *,
    candidate_id: Optional[str] = None,
    signed_provenance_binding: Optional[dict[str, object]] = None,
) -> dict[str, object]:
    if payload is None:
        payload = valid_candidate_payload()
    raw_bytes = validator.canonical_json_bytes(payload)
    if candidate_id is None:
        candidate_id = f"sha256:{hashlib.sha256(raw_bytes).hexdigest()}"
    return validator.validate_candidate_manifest_payload(
        payload,
        raw_bytes,
        source_revision=SOURCE_REVISION,
        candidate_id=candidate_id,
        provenance_id=PROVENANCE_ID,
        provenance_binding=signed_provenance_binding or provenance_binding(),
        app_version=APP_VERSION,
        build_number=BUILD_NUMBER,
        android_signer_sha256=ANDROID_SIGNER_SHA256,
        ios_team_id=IOS_TEAM_ID,
        ios_signer_sha256=IOS_SIGNER_SHA256,
    )


def minimum_metrics(scenario_id: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for name, (operator, expected, _upper) in validator.SCENARIO_METRIC_RULES[
        scenario_id
    ].items():
        if operator in {"eq", "min", "range"}:
            values[name] = expected
        else:  # pragma: no cover - a new operator must add an explicit fixture.
            raise AssertionError(f"unsupported metric rule: {operator}")
    return values


def valid_payload() -> dict[str, object]:
    binding = candidate_binding(candidate_id=CANDIDATE_ID)
    session_binding = runner_session_binding()
    physical_identities = session_binding["physical_identities"]
    assert isinstance(physical_identities, dict)
    devices = []
    device_values = (
        (
            "android_gesture",
            "android",
            "gesture",
            "phone",
            "16",
            "Pixel9",
            True,
            "2" * 64,
        ),
        (
            "android_three_button",
            "android",
            "three_button",
            "phone",
            "15.1",
            "Pixel8",
            False,
            "3" * 64,
        ),
        (
            "ios_home_indicator",
            "ios",
            "home_indicator",
            "phone",
            "26.0",
            "iPhone18,1",
            False,
            "4" * 64,
        ),
        (
            "ipad_keyboard_secondary_sync",
            "ios",
            "home_indicator",
            "tablet",
            "26.0",
            "iPad17,1",
            True,
            "5" * 64,
        ),
    )
    for index, (
        role,
        platform,
        navigation_mode,
        device_class,
        os_version,
        hardware_model,
        keyboard_attached,
        installation_hash,
    ) in enumerate(device_values):
        platform_binding = binding[platform]
        assert isinstance(platform_binding, dict)
        install_artifact_sha256 = platform_binding[
            "apk_sha256" if platform == "android" else "ipa_sha256"
        ]
        devices.append(
            {
                "role": role,
                "platform": platform,
                "navigation_mode": navigation_mode,
                "device_class": device_class,
                "os_version": os_version,
                "hardware_model": hardware_model,
                "physical": True,
                "physical_keyboard_attached": keyboard_attached,
                "installation_hash": installation_hash,
                "device_identity_hash": validator.challenge_keyed_device_identity_hash(
                    RUN_CHALLENGE,
                    physical_identities[role],
                ),
                "candidate_id": CANDIDATE_ID,
                "install_artifact_sha256": install_artifact_sha256,
                "application_id": platform_binding["application_id"],
                "signer_sha256": platform_binding["signer_sha256"],
                "team_id": platform_binding.get("team_id"),
            }
        )

    scenarios = [
        {
            "id": scenario_id,
            "status": "passed",
            "device_roles": list(validator.SCENARIO_DEVICE_ROLES[scenario_id]),
            "assertions": list(validator.SCENARIO_ASSERTIONS[scenario_id]),
            "metrics": minimum_metrics(scenario_id),
        }
        for scenario_id in validator.SCENARIO_IDS
    ]
    return {
        "schema": validator.EVIDENCE_SCHEMA_VERSION,
        "classification": "protected staging physical-device acceptance",
        "source_revision": SOURCE_REVISION,
        "candidate_id": CANDIDATE_ID,
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "environment": "staging",
        "mobile_feature_evidence": valid_mobile_feature_evidence_binding(),
        "coordinates": {
            "api_origin": API_ORIGIN,
            "app_link_origin": APP_LINK_ORIGIN,
            "oidc_issuer": OIDC_ISSUER,
            "oidc_client_id": OIDC_CLIENT_ID,
        },
        "candidate": binding,
        "runner_session": validator.public_runner_session_binding(session_binding),
        "driver": {
            "name": "pakperk-mobile-acceptance-driver",
            "version": "1.0.0",
            "sha256": DRIVER_SHA256,
        },
        "run": {
            "github_run_id": RUN_ID,
            "github_run_attempt": RUN_ATTEMPT,
            "challenge": RUN_CHALLENGE,
            "not_before": NOT_BEFORE,
        },
        "started_at": "2026-08-02T01:00:01Z",
        "finished_at": "2026-08-02T02:00:00Z",
        "devices": devices,
        "scenarios": scenarios,
        "redaction": {
            "contains_credentials": False,
            "contains_personal_data": False,
        },
    }


def scenario(payload: dict[str, object], scenario_id: str) -> dict[str, object]:
    scenarios = payload["scenarios"]
    assert isinstance(scenarios, list)
    return next(item for item in scenarios if item["id"] == scenario_id)


class MobileAcceptanceEvidenceTests(unittest.TestCase):
    def validate(
        self,
        payload: object,
        *,
        api_origin: str = API_ORIGIN,
        app_link_origin: str = APP_LINK_ORIGIN,
        oidc_issuer: str = OIDC_ISSUER,
        oidc_client_id: str = OIDC_CLIENT_ID,
    ) -> None:
        validator.validate_payload(
            payload,
            source_revision=SOURCE_REVISION,
            candidate_id=CANDIDATE_ID,
            candidate_binding=candidate_binding(candidate_id=CANDIDATE_ID),
            runner_session_binding=runner_session_binding(),
            driver_sha256=DRIVER_SHA256,
            app_version=APP_VERSION,
            build_number=BUILD_NUMBER,
            api_origin=api_origin,
            app_link_origin=app_link_origin,
            oidc_issuer=oidc_issuer,
            oidc_client_id=oidc_client_id,
            run_id=RUN_ID,
            run_attempt=RUN_ATTEMPT,
            run_challenge=RUN_CHALLENGE,
            not_before=NOT_BEFORE,
            validated_at=VALIDATED_AT,
        )

    def test_complete_evidence_passes(self) -> None:
        self.validate(valid_payload())

    def test_schema_v6_contract_totals_are_closed(self) -> None:
        self.assertEqual(validator.EVIDENCE_SCHEMA_VERSION, 6)
        self.assertEqual(validator.SCENARIO_COUNT, 42)
        self.assertEqual(validator.ASSERTION_COUNT, 317)
        self.assertEqual(validator.METRIC_COUNT, 254)
        self.assertRegex(validator.SCENARIO_CONTRACT_SHA256, r"^[0-9a-f]{64}$")

    def test_owner_only_canonical_source_binding_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "source-binding.json"
            path.write_bytes(
                validator.canonical_json_bytes(valid_source_binding_payload())
            )
            path.chmod(0o600)
            self.assertEqual(
                validator.load_source_binding(
                    path,
                    source_revision=SOURCE_REVISION,
                    app_version=APP_VERSION,
                    build_number=BUILD_NUMBER,
                ),
                {
                    "api_origin": API_ORIGIN,
                    "app_link_origin": APP_LINK_ORIGIN,
                    "oidc_issuer": OIDC_ISSUER,
                    "oidc_client_id": OIDC_CLIENT_ID,
                },
            )

    def test_source_binding_rejects_legacy_schema_without_app_link_contract(
        self,
    ) -> None:
        payload = valid_source_binding_payload()
        payload["schema"] = 1
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "source-binding.json"
            path.write_bytes(validator.canonical_json_bytes(payload))
            path.chmod(0o600)
            with self.assertRaisesRegex(validator.EvidenceError, "exact integer"):
                validator.load_source_binding(
                    path,
                    source_revision=SOURCE_REVISION,
                    app_version=APP_VERSION,
                    build_number=BUILD_NUMBER,
                )

    def test_source_binding_rejects_environment_file_control_injection(self) -> None:
        for control in ("\r", "\n", "\t"):
            with self.subTest(control=repr(control)):
                payload = valid_source_binding_payload()
                payload["oidc_issuer"] = (
                    f"{OIDC_ISSUER}{control}BASH_ENV=/tmp/candidate-hook"
                )
                with tempfile.TemporaryDirectory() as directory:
                    path = pathlib.Path(directory) / "source-binding.json"
                    path.write_bytes(validator.canonical_json_bytes(payload))
                    path.chmod(0o600)
                    with self.assertRaisesRegex(
                        validator.EvidenceError, "bounded string"
                    ):
                        validator.load_source_binding(
                            path,
                            source_revision=SOURCE_REVISION,
                            app_version=APP_VERSION,
                            build_number=BUILD_NUMBER,
                        )

    def test_source_binding_rejects_noncanonical_or_non_private_file(self) -> None:
        raw_bytes = validator.canonical_json_bytes(valid_source_binding_payload())
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "source-binding.json"
            path.write_bytes(raw_bytes)
            path.chmod(0o644)
            with self.assertRaisesRegex(validator.EvidenceError, "owner-only"):
                validator.load_source_binding(
                    path,
                    source_revision=SOURCE_REVISION,
                    app_version=APP_VERSION,
                    build_number=BUILD_NUMBER,
                )
            path.chmod(0o600)
            path.write_bytes(raw_bytes.replace(b'":', b'": ', 1))
            with self.assertRaisesRegex(validator.EvidenceError, "canonical"):
                validator.load_source_binding(
                    path,
                    source_revision=SOURCE_REVISION,
                    app_version=APP_VERSION,
                    build_number=BUILD_NUMBER,
                )

    def test_source_binding_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "target.json"
            target.write_bytes(
                validator.canonical_json_bytes(valid_source_binding_payload())
            )
            target.chmod(0o600)
            link = root / "source-binding.json"
            link.symlink_to(target)
            with self.assertRaisesRegex(validator.EvidenceError, "owner-only"):
                validator.load_source_binding(
                    link,
                    source_revision=SOURCE_REVISION,
                    app_version=APP_VERSION,
                    build_number=BUILD_NUMBER,
                )

    def test_candidate_manifest_source_mismatch_fails(self) -> None:
        payload = valid_candidate_payload()
        payload["source_revision"] = "9" * 40
        with self.assertRaisesRegex(validator.EvidenceError, "source revision"):
            candidate_binding(payload)

    def test_candidate_manifest_schema_requires_exact_integer(self) -> None:
        for invalid_schema in (3, True, 4.0):
            with self.subTest(schema=invalid_schema):
                payload = valid_candidate_payload()
                payload["schema"] = invalid_schema
                with self.assertRaisesRegex(validator.EvidenceError, "exact integer"):
                    candidate_binding(payload)

    def test_candidate_manifest_requires_exact_staging_application_ids(self) -> None:
        payload = valid_candidate_payload()
        android = payload["android"]
        assert isinstance(android, dict)
        android["application_id"] = "app.pakperk.pakperk"
        with self.assertRaisesRegex(validator.EvidenceError, "application ID"):
            candidate_binding(payload)

    def test_candidate_artifacts_must_match_signed_release_provenance(self) -> None:
        payload = valid_candidate_payload()
        android = payload["android"]
        assert isinstance(android, dict)
        android["apk_sha256"] = "9" * 64
        with self.assertRaisesRegex(validator.EvidenceError, "signed provenance"):
            candidate_binding(payload)

    def test_candidate_feature_evidence_must_match_signed_provenance(self) -> None:
        for key in ("sha256", *validator.MOBILE_FEATURE_FLAG_KEYS):
            with self.subTest(key=key):
                payload = valid_candidate_payload()
                feature_evidence = payload["mobile_feature_evidence"]
                assert isinstance(feature_evidence, dict)
                feature_evidence[key] = (
                    "4" * 64
                    if key == "sha256"
                    else not feature_evidence[key]
                )
                with self.assertRaisesRegex(
                    validator.EvidenceError, "does not match signed provenance"
                ):
                    candidate_binding(payload)

    def test_protected_acceptance_requires_each_new_feature_enabled(self) -> None:
        for key in validator.MOBILE_FEATURE_FLAG_KEYS:
            with self.subTest(key=key):
                payload = valid_candidate_payload()
                feature_evidence = payload["mobile_feature_evidence"]
                assert isinstance(feature_evidence, dict)
                feature_evidence[key] = False
                signed_binding = provenance_binding()
                signed_feature_evidence = signed_binding["mobile_feature_evidence"]
                assert isinstance(signed_feature_evidence, dict)
                signed_feature_evidence[key] = False
                with self.assertRaisesRegex(
                    validator.EvidenceError, "must enable all new mobile features"
                ):
                    candidate_binding(
                        payload,
                        signed_provenance_binding=signed_binding,
                    )

    def test_provenance_feature_evidence_requires_closed_schema_and_booleans(
        self,
    ) -> None:
        payload = valid_provenance_payload()
        feature_evidence = payload["mobile_feature_evidence"]
        assert isinstance(feature_evidence, dict)
        feature_evidence["readingFeed"] = 1
        with self.assertRaisesRegex(validator.EvidenceError, "exact booleans"):
            load_provenance_payload(payload)

        payload = valid_provenance_payload()
        feature_evidence = payload["mobile_feature_evidence"]
        assert isinstance(feature_evidence, dict)
        feature_evidence["unreviewedFlag"] = True
        with self.assertRaisesRegex(validator.EvidenceError, "closed key"):
            load_provenance_payload(payload)

        payload = valid_provenance_payload()
        feature_evidence = payload["mobile_feature_evidence"]
        assert isinstance(feature_evidence, dict)
        feature_evidence["schema"] = 5
        with self.assertRaisesRegex(validator.EvidenceError, "exact integer 6"):
            load_provenance_payload(payload)

    def test_each_bound_mobile_dependency_is_fail_closed(self) -> None:
        for feature, dependencies in validator.MOBILE_FEATURE_DEPENDENCIES:
            for dependency in dependencies:
                with self.subTest(feature=feature, dependency=dependency):
                    payload = valid_provenance_payload()
                    feature_evidence = payload["mobile_feature_evidence"]
                    assert isinstance(feature_evidence, dict)
                    feature_evidence[feature] = True
                    feature_evidence[dependency] = False
                    with self.assertRaisesRegex(
                        validator.EvidenceError, "dependency graph"
                    ):
                        load_provenance_payload(payload)

    def test_provenance_schema_requires_exact_integer(self) -> None:
        payload = valid_provenance_payload()
        payload["schema"] = 1
        with self.assertRaisesRegex(validator.EvidenceError, "exact integer"):
            load_provenance_payload(payload)

    def test_provenance_requires_exact_signed_workflow_identity(self) -> None:
        payload = valid_provenance_payload()
        workflow = payload["workflow"]
        assert isinstance(workflow, dict)
        workflow["workflow_sha"] = "9" * 40
        with self.assertRaisesRegex(validator.EvidenceError, "workflow identity"):
            load_provenance_payload(payload)

    def test_expired_runner_session_attestation_fails(self) -> None:
        payload = valid_runner_session_payload()
        payload["expires_at"] = "2026-08-02T01:30:00Z"
        with self.assertRaisesRegex(validator.EvidenceError, "expired"):
            load_runner_session_payload(payload)

    def test_runner_session_requires_exact_true_booleans(self) -> None:
        payload = valid_runner_session_payload()
        payload["ephemeral"] = 1
        with self.assertRaisesRegex(validator.EvidenceError, "dedicated and ephemeral"):
            load_runner_session_payload(payload)

    def test_runner_session_requires_distinct_root_attested_devices(self) -> None:
        payload = valid_runner_session_payload()
        identities = payload["physical_identities"]
        assert isinstance(identities, dict)
        identities["android_three_button"] = identities["android_gesture"]
        with self.assertRaisesRegex(validator.EvidenceError, "must be distinct"):
            load_runner_session_payload(payload)

    def test_candidate_manifest_signer_mismatch_fails(self) -> None:
        payload = valid_candidate_payload()
        android = payload["android"]
        assert isinstance(android, dict)
        android["signer_sha256"] = "9" * 64
        with self.assertRaisesRegex(validator.EvidenceError, "signer digest"):
            candidate_binding(payload)

    def test_candidate_manifest_content_id_mismatch_fails(self) -> None:
        with self.assertRaisesRegex(validator.EvidenceError, "content digest"):
            candidate_binding(candidate_id="sha256:" + "9" * 64)

    def test_source_mismatch_fails(self) -> None:
        payload = valid_payload()
        payload["source_revision"] = "9" * 40
        with self.assertRaisesRegex(validator.EvidenceError, "source revision"):
            self.validate(payload)

    def test_evidence_schema_requires_exact_integer(self) -> None:
        for invalid_schema in (5, True, 6.0):
            with self.subTest(schema=invalid_schema):
                payload = valid_payload()
                payload["schema"] = invalid_schema
                with self.assertRaisesRegex(validator.EvidenceError, "exact integer"):
                    self.validate(payload)

    def test_redaction_requires_exact_false_booleans(self) -> None:
        payload = valid_payload()
        redaction = payload["redaction"]
        assert isinstance(redaction, dict)
        redaction["contains_credentials"] = 0
        with self.assertRaisesRegex(validator.EvidenceError, "explicitly sanitized"):
            self.validate(payload)

    def test_coordinates_cannot_be_rebound_to_loopback(self) -> None:
        payload = valid_payload()
        coordinates = payload["coordinates"]
        assert isinstance(coordinates, dict)
        coordinates["api_origin"] = "https://127.0.0.1"
        with self.assertRaisesRegex(validator.EvidenceError, "staging.json"):
            self.validate(payload, api_origin="https://127.0.0.1")

    def test_app_link_origin_must_match_reviewed_staging_config(self) -> None:
        payload = valid_payload()
        coordinates = payload["coordinates"]
        assert isinstance(coordinates, dict)
        coordinates["app_link_origin"] = "https://hostile.example"
        with self.assertRaisesRegex(validator.EvidenceError, "staging.json"):
            self.validate(payload, app_link_origin="https://hostile.example")

    def test_candidate_binding_mismatch_fails(self) -> None:
        payload = valid_payload()
        candidate = payload["candidate"]
        assert isinstance(candidate, dict)
        android = candidate["android"]
        assert isinstance(android, dict)
        android["apk_sha256"] = "9" * 64
        with self.assertRaisesRegex(validator.EvidenceError, "candidate artifacts"):
            self.validate(payload)

    def test_evidence_feature_binding_tamper_fails(self) -> None:
        for key in ("sha256", *validator.MOBILE_FEATURE_FLAG_KEYS):
            with self.subTest(key=key):
                payload = valid_payload()
                feature_evidence = payload["mobile_feature_evidence"]
                assert isinstance(feature_evidence, dict)
                feature_evidence[key] = (
                    "4" * 64
                    if key == "sha256"
                    else not feature_evidence[key]
                )
                with self.assertRaisesRegex(
                    validator.EvidenceError, "signed candidate"
                ):
                    self.validate(payload)

    def test_device_install_artifact_mismatch_fails(self) -> None:
        payload = valid_payload()
        devices = payload["devices"]
        assert isinstance(devices, list)
        devices[0]["install_artifact_sha256"] = "9" * 64
        with self.assertRaisesRegex(validator.EvidenceError, "installed-candidate"):
            self.validate(payload)

    def test_run_challenge_mismatch_fails(self) -> None:
        payload = valid_payload()
        run = payload["run"]
        assert isinstance(run, dict)
        run["challenge"] = "9" * 64
        with self.assertRaisesRegex(validator.EvidenceError, "run challenge"):
            self.validate(payload)

    def test_stale_replayed_evidence_fails(self) -> None:
        payload = valid_payload()
        with self.assertRaisesRegex(validator.EvidenceError, "stale or replayed"):
            validator.validate_payload(
                payload,
                source_revision=SOURCE_REVISION,
                candidate_id=CANDIDATE_ID,
                candidate_binding=candidate_binding(candidate_id=CANDIDATE_ID),
                runner_session_binding=runner_session_binding(),
                driver_sha256=DRIVER_SHA256,
                app_version=APP_VERSION,
                build_number=BUILD_NUMBER,
                api_origin=API_ORIGIN,
                app_link_origin=APP_LINK_ORIGIN,
                oidc_issuer=OIDC_ISSUER,
                oidc_client_id=OIDC_CLIENT_ID,
                run_id=RUN_ID,
                run_attempt=RUN_ATTEMPT,
                run_challenge=RUN_CHALLENGE,
                not_before=NOT_BEFORE,
                validated_at=VALIDATED_AT + dt.timedelta(hours=1),
            )

    def test_missing_scenario_assertion_fails(self) -> None:
        payload = valid_payload()
        target = scenario(payload, "offline_outbox_process_death_recovery")
        assertions = target["assertions"]
        assert isinstance(assertions, list)
        assertions.pop()
        with self.assertRaisesRegex(validator.EvidenceError, "assertion evidence"):
            self.validate(payload)

    def test_each_plan02_scenario_is_cross_platform(self) -> None:
        for scenario_id in validator.SCENARIO_IDS[-15:-10]:
            with self.subTest(scenario_id=scenario_id):
                self.assertEqual(
                    validator.SCENARIO_DEVICE_ROLES[scenario_id],
                    ("android_gesture", "ios_home_indicator"),
                )

    def test_each_new_scenario_assertion_contract_fails_closed(self) -> None:
        for scenario_id in validator.SCENARIO_IDS[-10:]:
            for assertion_id in validator.SCENARIO_ASSERTIONS[scenario_id]:
                with self.subTest(
                    scenario_id=scenario_id,
                    assertion_id=assertion_id,
                ):
                    payload = valid_payload()
                    target = scenario(payload, scenario_id)
                    assertions = target["assertions"]
                    assert isinstance(assertions, list)
                    assertions.remove(assertion_id)
                    with self.assertRaisesRegex(
                        validator.EvidenceError, "assertion evidence"
                    ):
                        self.validate(payload)

    def test_each_new_scenario_metric_contract_fails_closed(self) -> None:
        for scenario_id in validator.SCENARIO_IDS[-10:]:
            for metric_name in validator.SCENARIO_METRIC_RULES[scenario_id]:
                with self.subTest(
                    scenario_id=scenario_id,
                    metric_name=metric_name,
                ):
                    payload = valid_payload()
                    target = scenario(payload, scenario_id)
                    metrics = target["metrics"]
                    assert isinstance(metrics, dict)
                    metrics.pop(metric_name)
                    with self.assertRaisesRegex(
                        validator.EvidenceError, "closed key contract"
                    ):
                        self.validate(payload)

    def test_new_fail_closed_zero_metrics_reject_one_observed_violation(self) -> None:
        violations = {
            "to_read_first_queue_authority": (
                "recommendation_requests_before_confirmed_empty"
            ),
            "to_read_first_fail_closed_mutations": (
                "recommendation_unlocks_before_final_remove_confirmation"
            ),
            "to_read_first_account_scope_rollout": "old_account_visible_frames",
            "add_paper_exact_and_title_selection": "title_imports_before_selection",
            "add_paper_failure_retry_idempotency": (
                "operation_id_changes_during_retry"
            ),
            "plan02_search_lookup_explore_saved_queries": (
                "lookup_library_mutations"
            ),
            "plan02_research_profile_personalization": (
                "queue_mutations_from_profile_actions"
            ),
            "plan02_why_and_feedback": "active_library_seed_reasons",
            "plan02_reading_brief_progress_authority": (
                "recommendation_unlocks_before_queue_empty"
            ),
            "plan02_subscription_notification_safety": (
                "discovery_deliveries_while_queue_active"
            ),
        }
        for scenario_id, metric in violations.items():
            with self.subTest(scenario_id=scenario_id, metric=metric):
                payload = valid_payload()
                target = scenario(payload, scenario_id)
                metrics = target["metrics"]
                assert isinstance(metrics, dict)
                metrics[metric] = 1
                with self.assertRaisesRegex(validator.EvidenceError, "required value"):
                    self.validate(payload)

    def test_add_paper_retained_raw_input_metric_fails_closed(self) -> None:
        payload = valid_payload()
        target = scenario(payload, "add_paper_failure_retry_idempotency")
        metrics = target["metrics"]
        assert isinstance(metrics, dict)
        metrics["retained_raw_import_fields"] = 1
        with self.assertRaisesRegex(validator.EvidenceError, "required value"):
            self.validate(payload)

    def test_twenty_paper_threshold_fails_closed(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "vertical_20_papers_latency")["metrics"]
        assert isinstance(metrics, dict)
        metrics["papers_swiped"] = 19
        with self.assertRaisesRegex(validator.EvidenceError, "required minimum"):
            self.validate(payload)

    def test_launch_performance_threshold_boundaries_pass(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "cold_cache_launch")["metrics"]
        assert isinstance(metrics, dict)
        metrics["cached_first_readable_frame_p95_ms"] = 1_500
        metrics["opening_transition_ms"] = 700
        self.validate(payload)

    def test_large_document_device_budget_boundaries_pass(self) -> None:
        payload = valid_payload()
        metrics = scenario(
            payload, "plan03_reader_queue_and_large_document_safety"
        )["metrics"]
        assert isinstance(metrics, dict)
        metrics["large_document_peak_retained_blocks"] = (
            validator.LARGE_DOCUMENT_MAX_RETAINED_BLOCKS
        )
        metrics["large_document_worst_device_first_page_ms"] = (
            validator.LARGE_DOCUMENT_FIRST_PAGE_MAX_MS
        )
        metrics["large_document_worst_device_page_fetch_p95_ms"] = (
            validator.LARGE_DOCUMENT_PAGE_FETCH_P95_MAX_MS
        )
        metrics["large_document_worst_device_scroll_frame_p95_us"] = (
            validator.LARGE_DOCUMENT_SCROLL_FRAME_P95_MAX_US
        )
        metrics["large_document_worst_device_scroll_frame_max_us"] = (
            validator.LARGE_DOCUMENT_SCROLL_FRAME_MAX_US
        )
        metrics[
            "large_document_worst_device_missed_frame_ratio_basis_points"
        ] = validator.LARGE_DOCUMENT_MISSED_FRAME_RATIO_MAX_BPS
        metrics["large_document_worst_device_peak_rss_growth_mib"] = (
            validator.LARGE_DOCUMENT_PEAK_RSS_GROWTH_MAX_MIB
        )
        metrics["large_document_worst_device_maximum_live_block_widgets"] = (
            validator.LARGE_DOCUMENT_MAX_LIVE_BLOCK_WIDGETS
        )
        self.validate(payload)

    def test_large_document_requires_sustained_per_device_samples(self) -> None:
        cases = (
            (
                "large_document_minimum_page_fetch_samples_per_device",
                validator.LARGE_DOCUMENT_MIN_PAGE_FETCH_SAMPLES - 1,
            ),
            (
                "large_document_minimum_frame_samples_per_device",
                validator.LARGE_DOCUMENT_MIN_FRAME_SAMPLES - 1,
            ),
            (
                "large_document_minimum_scroll_window_seconds_per_device",
                validator.LARGE_DOCUMENT_MIN_SCROLL_WINDOW_SECONDS - 1,
            ),
        )
        for metric_name, invalid_value in cases:
            with self.subTest(metric_name=metric_name):
                payload = valid_payload()
                metrics = scenario(
                    payload, "plan03_reader_queue_and_large_document_safety"
                )["metrics"]
                assert isinstance(metrics, dict)
                metrics[metric_name] = invalid_value
                with self.assertRaises(validator.EvidenceError):
                    self.validate(payload)

    def test_large_document_aggregate_relationships_fail_closed(self) -> None:
        cases = (
            (
                "large_document_minimum_pages_traversed_per_device",
                validator.LARGE_DOCUMENT_MIN_PAGE_FETCH_SAMPLES + 1,
            ),
            (
                "large_document_minimum_scroll_window_seconds_per_device",
                validator.LARGE_DOCUMENT_MIN_FRAME_SAMPLES // 4 + 1,
            ),
            (
                "large_document_worst_device_scroll_frame_p95_us",
                2,
            ),
        )
        for metric_name, invalid_value in cases:
            with self.subTest(metric_name=metric_name):
                payload = valid_payload()
                metrics = scenario(
                    payload, "plan03_reader_queue_and_large_document_safety"
                )["metrics"]
                assert isinstance(metrics, dict)
                metrics[metric_name] = invalid_value
                with self.assertRaises(validator.EvidenceError):
                    self.validate(payload)

    def test_cached_first_readable_frame_p95_above_limit_fails_closed(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "cold_cache_launch")["metrics"]
        assert isinstance(metrics, dict)
        metrics["cached_first_readable_frame_p95_ms"] = 1_501
        with self.assertRaisesRegex(validator.EvidenceError, "required range"):
            self.validate(payload)

    def test_opening_transition_above_limit_fails_closed(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "cold_cache_launch")["metrics"]
        assert isinstance(metrics, dict)
        metrics["opening_transition_ms"] = 701
        with self.assertRaisesRegex(validator.EvidenceError, "required range"):
            self.validate(payload)

    def test_legacy_first_readable_frame_metric_fails_closed(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "cold_cache_launch")["metrics"]
        assert isinstance(metrics, dict)
        metrics["first_readable_frame_ms"] = metrics.pop(
            "cached_first_readable_frame_p95_ms"
        )
        with self.assertRaisesRegex(validator.EvidenceError, "closed key contract"):
            self.validate(payload)

    def test_refresh_must_happen_exactly_once(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "expired_token_refresh")["metrics"]
        assert isinstance(metrics, dict)
        metrics["refresh_attempts"] = 2
        with self.assertRaisesRegex(validator.EvidenceError, "required value"):
            self.validate(payload)

    def test_schema_v6_contract_family_boundaries_fail_closed(self) -> None:
        cases = (
            (
                "two-device removal convergence",
                "two_device_library_sync",
                "visible_saved_items_after_convergence",
                1,
            ),
            (
                "invalid refresh detachment",
                "invalid_refresh_to_guest",
                "accessible_account_owned_rows",
                1,
            ),
            (
                "fresh signed installations",
                "fresh_install_guest_reader",
                "fresh_installations",
                1,
            ),
            (
                "offline relaunch before reconnect",
                "offline_outbox_process_death_recovery",
                "network_reconnects_before_cached_read",
                1,
            ),
            (
                "comment public disappearance",
                "comment_create_edit_delete",
                "visible_public_comments_after_delete",
                1,
            ),
            (
                "duplicate report idempotence",
                "report_and_block",
                "durable_reports_after_replay",
                2,
            ),
            (
                "physical app-link fail-closed",
                "physical_app_link_dispatch",
                "unsafe_paper_requests",
                1,
            ),
            (
                "signed-device token attributes",
                "signed_device_data_protection",
                "insecure_credential_attribute_findings",
                1,
            ),
            (
                "cache record bound",
                "signed_device_cache_bounds",
                "cached_paper_records",
                validator.MAX_CACHED_PAPER_RECORDS + 1,
            ),
            (
                "cache physical-byte bound",
                "signed_device_cache_bounds",
                "cache_physical_bytes",
                validator.MAX_CACHE_PHYSICAL_BYTES + 1,
            ),
            (
                "light/dark platform matrix",
                "light_dark_appearance",
                "theme_platform_combinations",
                3,
            ),
        )
        for label, scenario_id, metric_name, invalid_value in cases:
            with self.subTest(boundary=label):
                payload = valid_payload()
                metrics = scenario(payload, scenario_id)["metrics"]
                assert isinstance(metrics, dict)
                metrics[metric_name] = invalid_value
                with self.assertRaises(validator.EvidenceError):
                    self.validate(payload)

    def test_comment_onboarding_assertions_are_mandatory(self) -> None:
        payload = valid_payload()
        target = scenario(payload, "comment_create_edit_delete")
        assertions = target["assertions"]
        assert isinstance(assertions, list)
        assertions.remove("incomplete_profile_handle_chosen")
        with self.assertRaisesRegex(validator.EvidenceError, "assertion evidence"):
            self.validate(payload)

    def test_system_back_assertions_are_mandatory(self) -> None:
        payload = valid_payload()
        target = scenario(payload, "root_navigation_safe_area")
        assertions = target["assertions"]
        assert isinstance(assertions, list)
        assertions.remove("ios_edge_back_gesture_verified")
        with self.assertRaisesRegex(validator.EvidenceError, "assertion evidence"):
            self.validate(payload)

    def test_ipad_keyboard_role_must_be_a_tablet(self) -> None:
        payload = valid_payload()
        devices = payload["devices"]
        assert isinstance(devices, list)
        devices[3]["device_class"] = "phone"
        with self.assertRaisesRegex(validator.EvidenceError, "device class"):
            self.validate(payload)

    def test_ipad_keyboard_must_be_physically_attached(self) -> None:
        payload = valid_payload()
        devices = payload["devices"]
        assert isinstance(devices, list)
        devices[3]["physical_keyboard_attached"] = False
        with self.assertRaisesRegex(validator.EvidenceError, "physical-keyboard"):
            self.validate(payload)

    def test_keyboard_command_assertions_are_mandatory(self) -> None:
        payload = valid_payload()
        target = scenario(payload, "hardware_keyboard_navigation")
        assertions = target["assertions"]
        assert isinstance(assertions, list)
        assertions.remove("shift_tab_reverse_verified")
        with self.assertRaisesRegex(validator.EvidenceError, "assertion evidence"):
            self.validate(payload)

    def test_duplicate_installation_fails(self) -> None:
        payload = valid_payload()
        devices = payload["devices"]
        assert isinstance(devices, list)
        devices[3]["installation_hash"] = devices[0]["installation_hash"]
        with self.assertRaisesRegex(validator.EvidenceError, "distinct"):
            self.validate(payload)

    def test_device_roles_require_distinct_challenge_keyed_identities(self) -> None:
        payload = valid_payload()
        devices = payload["devices"]
        assert isinstance(devices, list)
        devices[3]["device_identity_hash"] = devices[0]["device_identity_hash"]
        with self.assertRaisesRegex(
            validator.EvidenceError, "identities must be distinct"
        ):
            self.validate(payload)

    def test_device_identity_hashes_must_match_root_attestation_and_challenge(
        self,
    ) -> None:
        payload = valid_payload()
        devices = payload["devices"]
        assert isinstance(devices, list)
        devices[0]["device_identity_hash"] = "9" * 64
        with self.assertRaisesRegex(validator.EvidenceError, "root attestation"):
            self.validate(payload)

    def test_emulator_evidence_fails(self) -> None:
        payload = valid_payload()
        devices = payload["devices"]
        assert isinstance(devices, list)
        devices[0]["physical"] = False
        with self.assertRaisesRegex(validator.EvidenceError, "not physical"):
            self.validate(payload)

    def test_duplicate_json_key_hiding_secret_fails_before_redaction(self) -> None:
        raw = validator.canonical_json_bytes(valid_payload())
        raw = raw.replace(
            b'"version":"1.0.0"',
            b'"version":"Bearer runtime-secret-must-not-be-retained","version":"1.0.0"',
            1,
        )
        with self.assertRaisesRegex(validator.EvidenceError, "duplicate key"):
            validator._parse_canonical_json(raw, "acceptance evidence")

    def test_noncanonical_json_fails(self) -> None:
        raw = validator.canonical_json_bytes(valid_payload()).replace(b'":', b'": ', 1)
        with self.assertRaisesRegex(validator.EvidenceError, "exact canonical JSON"):
            validator._parse_canonical_json(raw, "acceptance evidence")

    def test_closed_key_error_does_not_echo_untrusted_key(self) -> None:
        payload = valid_payload()
        untrusted_key = "operator-private-value"
        payload[untrusted_key] = False
        with self.assertRaises(validator.EvidenceError) as captured:
            self.validate(payload)
        self.assertNotIn(untrusted_key, str(captured.exception))

    def test_validated_bytes_are_packaged_with_exact_checksum(self) -> None:
        evidence_bytes = validator.canonical_json_bytes(valid_payload())
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            candidate_path = root / "candidate.json"
            provenance_path = root / "provenance.json"
            runner_session_path = root / "runner-session.json"
            evidence_path = root / "evidence.json"
            archive_path = root / "evidence.tar"
            candidate_path.write_bytes(CANDIDATE_BYTES)
            provenance_path.write_bytes(PROVENANCE_BYTES)
            runner_session_path.write_bytes(RUNNER_SESSION_BYTES)
            evidence_path.write_bytes(evidence_bytes)
            archive_digest = validator.validate_and_package(
                evidence_path,
                archive_path,
                candidate_manifest_path=candidate_path,
                provenance_manifest_path=provenance_path,
                runner_session_manifest_path=runner_session_path,
                source_revision=SOURCE_REVISION,
                candidate_id=CANDIDATE_ID,
                provenance_id=PROVENANCE_ID,
                runner_session_id=RUNNER_SESSION_ATTESTATION_ID,
                validator_sha256=VALIDATOR_SHA256,
                driver_sha256=DRIVER_SHA256,
                app_version=APP_VERSION,
                build_number=BUILD_NUMBER,
                api_origin=API_ORIGIN,
                app_link_origin=APP_LINK_ORIGIN,
                oidc_issuer=OIDC_ISSUER,
                oidc_client_id=OIDC_CLIENT_ID,
                android_signer_sha256=ANDROID_SIGNER_SHA256,
                ios_team_id=IOS_TEAM_ID,
                ios_signer_sha256=IOS_SIGNER_SHA256,
                run_id=RUN_ID,
                run_attempt=RUN_ATTEMPT,
                run_challenge=RUN_CHALLENGE,
                not_before=NOT_BEFORE,
                validated_at=VALIDATED_AT,
                require_protected_candidate_path=False,
            )
            validator.verify_archive(
                archive_path,
                archive_digest,
                expected_validator_sha256=VALIDATOR_SHA256,
                expected_driver_sha256=DRIVER_SHA256,
            )
            evidence_path.write_bytes(b"changed after validated bytes were captured\n")
            self.assertEqual(stat.S_IMODE(archive_path.stat().st_mode), 0o400)
            with tarfile.open(archive_path, "r") as archive:
                self.assertEqual(
                    archive.getnames(),
                    [
                        validator.EVIDENCE_ARCHIVE_NAME,
                        validator.TOOLING_ARCHIVE_NAME,
                        validator.CHECKSUM_ARCHIVE_NAME,
                    ],
                )
                packaged = archive.extractfile(validator.EVIDENCE_ARCHIVE_NAME)
                tooling = archive.extractfile(validator.TOOLING_ARCHIVE_NAME)
                checksum = archive.extractfile(validator.CHECKSUM_ARCHIVE_NAME)
                assert (
                    packaged is not None
                    and tooling is not None
                    and checksum is not None
                )
                tooling_bytes = validator.tooling_manifest_bytes(
                    validator_sha256=VALIDATOR_SHA256,
                    driver_sha256=DRIVER_SHA256,
                )
                self.assertEqual(packaged.read(), evidence_bytes)
                self.assertEqual(tooling.read(), tooling_bytes)
                self.assertEqual(
                    checksum.read(),
                    (
                        f"{hashlib.sha256(evidence_bytes).hexdigest()}  "
                        f"{validator.EVIDENCE_ARCHIVE_NAME}\n"
                        f"{hashlib.sha256(tooling_bytes).hexdigest()}  "
                        f"{validator.TOOLING_ARCHIVE_NAME}\n"
                    ).encode("ascii"),
                )

    def test_existing_archive_is_not_overwritten_or_deleted(self) -> None:
        evidence_bytes = validator.canonical_json_bytes(valid_payload())
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            candidate_path = root / "candidate.json"
            provenance_path = root / "provenance.json"
            runner_session_path = root / "runner-session.json"
            evidence_path = root / "evidence.json"
            archive_path = root / "evidence.tar"
            candidate_path.write_bytes(CANDIDATE_BYTES)
            provenance_path.write_bytes(PROVENANCE_BYTES)
            runner_session_path.write_bytes(RUNNER_SESSION_BYTES)
            evidence_path.write_bytes(evidence_bytes)
            archive_path.write_bytes(b"preexisting")
            with self.assertRaisesRegex(validator.EvidenceError, "not fresh"):
                validator.validate_and_package(
                    evidence_path,
                    archive_path,
                    candidate_manifest_path=candidate_path,
                    provenance_manifest_path=provenance_path,
                    runner_session_manifest_path=runner_session_path,
                    source_revision=SOURCE_REVISION,
                    candidate_id=CANDIDATE_ID,
                    provenance_id=PROVENANCE_ID,
                    runner_session_id=RUNNER_SESSION_ATTESTATION_ID,
                    validator_sha256=VALIDATOR_SHA256,
                    driver_sha256=DRIVER_SHA256,
                    app_version=APP_VERSION,
                    build_number=BUILD_NUMBER,
                    api_origin=API_ORIGIN,
                    app_link_origin=APP_LINK_ORIGIN,
                    oidc_issuer=OIDC_ISSUER,
                    oidc_client_id=OIDC_CLIENT_ID,
                    android_signer_sha256=ANDROID_SIGNER_SHA256,
                    ios_team_id=IOS_TEAM_ID,
                    ios_signer_sha256=IOS_SIGNER_SHA256,
                    run_id=RUN_ID,
                    run_attempt=RUN_ATTEMPT,
                    run_challenge=RUN_CHALLENGE,
                    not_before=NOT_BEFORE,
                    validated_at=VALIDATED_AT,
                    require_protected_candidate_path=False,
                )
            self.assertEqual(archive_path.read_bytes(), b"preexisting")

    def test_archive_verifier_rejects_post_package_byte_tampering(self) -> None:
        evidence_bytes = validator.canonical_json_bytes(valid_payload())
        with tempfile.TemporaryDirectory() as directory:
            archive_path = pathlib.Path(directory) / "evidence.tar"
            tooling_bytes = validator.tooling_manifest_bytes(
                validator_sha256=VALIDATOR_SHA256,
                driver_sha256=DRIVER_SHA256,
            )
            archive_digest = validator._publish_archive(
                archive_path, evidence_bytes, tooling_bytes
            )
            archive_path.chmod(0o600)
            tampered = bytearray(archive_path.read_bytes())
            tampered[0] ^= 1
            archive_path.write_bytes(tampered)
            archive_path.chmod(0o400)
            with self.assertRaisesRegex(validator.EvidenceError, "digest"):
                validator.verify_archive(
                    archive_path,
                    archive_digest,
                    expected_validator_sha256=VALIDATOR_SHA256,
                    expected_driver_sha256=DRIVER_SHA256,
                )

    def test_archive_verifier_rejects_wrong_tool_identity(self) -> None:
        evidence_bytes = validator.canonical_json_bytes(valid_payload())
        with tempfile.TemporaryDirectory() as directory:
            archive_path = pathlib.Path(directory) / "evidence.tar"
            tooling_bytes = validator.tooling_manifest_bytes(
                validator_sha256="8" * 64,
                driver_sha256=DRIVER_SHA256,
            )
            archive_digest = validator._publish_archive(
                archive_path, evidence_bytes, tooling_bytes
            )
            with self.assertRaisesRegex(validator.EvidenceError, "tooling SHA-256"):
                validator.verify_archive(
                    archive_path,
                    archive_digest,
                    expected_validator_sha256=VALIDATOR_SHA256,
                    expected_driver_sha256=DRIVER_SHA256,
                )


if __name__ == "__main__":
    unittest.main()
