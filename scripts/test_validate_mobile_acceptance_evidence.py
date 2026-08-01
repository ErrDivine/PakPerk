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
DRIVER_SHA256 = "b" * 64
APP_VERSION = "0.2.0"
BUILD_NUMBER = "2"
API_ORIGIN = "https://api.staging.pakperk.app"
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


def valid_provenance_payload() -> dict[str, object]:
    return {
        "schema": 1,
        "classification": "protected signed mobile release provenance",
        "source_revision": SOURCE_REVISION,
        "environment": "staging",
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "created_at": "2026-08-02T00:45:00Z",
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
        "android": copy.deepcopy(payload["android"]),
        "ios": copy.deepcopy(payload["ios"]),
    }


def valid_candidate_payload() -> dict[str, object]:
    return {
        "schema": 1,
        "classification": "protected signed mobile candidate",
        "source_revision": SOURCE_REVISION,
        "environment": "staging",
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "strict_full_text": True,
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
        provenance_binding=provenance_binding(),
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
        "schema": 2,
        "classification": "protected staging physical-device acceptance",
        "source_revision": SOURCE_REVISION,
        "candidate_id": CANDIDATE_ID,
        "app_version": APP_VERSION,
        "build_number": BUILD_NUMBER,
        "environment": "staging",
        "coordinates": {
            "api_origin": API_ORIGIN,
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

    def test_candidate_manifest_source_mismatch_fails(self) -> None:
        payload = valid_candidate_payload()
        payload["source_revision"] = "9" * 40
        with self.assertRaisesRegex(validator.EvidenceError, "source revision"):
            candidate_binding(payload)

    def test_candidate_manifest_schema_requires_exact_integer(self) -> None:
        for invalid_schema in (True, 1.0):
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

    def test_provenance_schema_requires_exact_integer(self) -> None:
        payload = valid_provenance_payload()
        payload["schema"] = 1.0
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
        for invalid_schema in (True, 2.0):
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

    def test_candidate_binding_mismatch_fails(self) -> None:
        payload = valid_payload()
        candidate = payload["candidate"]
        assert isinstance(candidate, dict)
        android = candidate["android"]
        assert isinstance(android, dict)
        android["apk_sha256"] = "9" * 64
        with self.assertRaisesRegex(validator.EvidenceError, "candidate artifacts"):
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

    def test_twenty_paper_threshold_fails_closed(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "vertical_20_papers_latency")["metrics"]
        assert isinstance(metrics, dict)
        metrics["papers_swiped"] = 19
        with self.assertRaisesRegex(validator.EvidenceError, "required minimum"):
            self.validate(payload)

    def test_refresh_must_happen_exactly_once(self) -> None:
        payload = valid_payload()
        metrics = scenario(payload, "expired_token_refresh")["metrics"]
        assert isinstance(metrics, dict)
        metrics["refresh_attempts"] = 2
        with self.assertRaisesRegex(validator.EvidenceError, "required value"):
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
                driver_sha256=DRIVER_SHA256,
                app_version=APP_VERSION,
                build_number=BUILD_NUMBER,
                api_origin=API_ORIGIN,
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
            validator.verify_archive(archive_path, archive_digest)
            evidence_path.write_bytes(b"changed after validated bytes were captured\n")
            self.assertEqual(stat.S_IMODE(archive_path.stat().st_mode), 0o400)
            with tarfile.open(archive_path, "r") as archive:
                self.assertEqual(
                    archive.getnames(),
                    [validator.EVIDENCE_ARCHIVE_NAME, validator.CHECKSUM_ARCHIVE_NAME],
                )
                packaged = archive.extractfile(validator.EVIDENCE_ARCHIVE_NAME)
                checksum = archive.extractfile(validator.CHECKSUM_ARCHIVE_NAME)
                assert packaged is not None and checksum is not None
                self.assertEqual(packaged.read(), evidence_bytes)
                self.assertEqual(
                    checksum.read(),
                    (
                        f"{hashlib.sha256(evidence_bytes).hexdigest()}  "
                        f"{validator.EVIDENCE_ARCHIVE_NAME}\n"
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
                    driver_sha256=DRIVER_SHA256,
                    app_version=APP_VERSION,
                    build_number=BUILD_NUMBER,
                    api_origin=API_ORIGIN,
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
            archive_digest = validator._publish_archive(archive_path, evidence_bytes)
            archive_path.chmod(0o600)
            tampered = bytearray(archive_path.read_bytes())
            tampered[0] ^= 1
            archive_path.write_bytes(tampered)
            archive_path.chmod(0o400)
            with self.assertRaisesRegex(validator.EvidenceError, "digest"):
                validator.verify_archive(archive_path, archive_digest)


if __name__ == "__main__":
    unittest.main()
