#!/usr/bin/env python3
"""Hermetic regressions for the public-edge evidence contract."""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from public_edge_evidence import (
    SCENARIO_IDS,
    EvidenceError,
    PublicEdgeBinding,
    build_evidence,
    initial_scenario_state,
    observation_id,
    read_evidence,
    validate_evidence,
    write_evidence,
)


SOURCE_REVISION = "a" * 40
CANDIDATE_ID = "sha256:" + "b" * 64
ANDROID_SHA256 = ":".join(f"{index:02X}" for index in range(32))


def binding(**overrides: str) -> PublicEdgeBinding:
    values = {
        "source_revision": SOURCE_REVISION,
        "target_environment": "staging",
        "requested_candidate_id": CANDIDATE_ID,
        "site_origin": "https://staging.pakperk.app",
        "api_origin": "https://api.staging.pakperk.app",
        "telemetry_origin": "https://telemetry.staging.pakperk.app",
        "document_version": "2026-08-01",
        "oidc_issuer": "https://identity.staging.pakperk.app/realms/pakperk",
        "oidc_client_id": "pakperk-web-deletion-staging",
        "support_email": "support@pakperk.app",
        "android_package": "app.pakperk.pakperk.staging",
        "android_sha256": ANDROID_SHA256,
        "apple_team_id": "PKPRK2026A",
        "apple_bundle_id": "app.pakperk.pakperk.staging",
    }
    values.update(overrides)
    return PublicEdgeBinding(**values)


def passed_state() -> dict[str, dict[str, str]]:
    return {
        scenario_id: {
            "outcome": "passed",
            "observation_id": observation_id(
                {"scenario": scenario_id, "bounded": True}
            ),
        }
        for scenario_id in SCENARIO_IDS
    }


class PublicEdgeEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name).resolve()

    def test_passed_evidence_is_closed_self_addressed_and_sanitized(self) -> None:
        expected = binding()
        evidence = build_evidence(expected, passed_state(), "passed")
        validated = validate_evidence(
            evidence,
            expected_binding=expected,
            expected_outcome="passed",
        )
        encoded = json.dumps(validated, sort_keys=True)
        self.assertRegex(validated["content_id"], r"^public-edge-sha256:[0-9a-f]{64}$")
        self.assertNotEqual(validated["content_id"], CANDIDATE_ID)
        self.assertEqual(validated["binding"]["requested_candidate_id"], CANDIDATE_ID)
        self.assertEqual(
            validated["scope"]["requested_candidate_identity"],
            "operator_binding_not_observed_at_edge",
        )
        self.assertEqual(
            validated["scope"]["source_revision_observation"],
            "site_notices_source_revision_exact_match",
        )
        self.assertEqual(
            validated["scope"]["telemetry_readiness_scope"],
            "gateway_process_only_not_collector_sink_or_export_delivery",
        )
        self.assertNotIn(expected.support_email, encoded)
        for forbidden in (
            "response_body",
            "authorization",
            "cookie_value",
            "operator_email",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_failed_evidence_is_one_failure_with_passed_prefix(self) -> None:
        expected = binding()
        state = initial_scenario_state()
        for scenario_id in SCENARIO_IDS[:5]:
            state[scenario_id] = {
                "outcome": "passed",
                "observation_id": observation_id({"scenario": scenario_id}),
            }
        state[SCENARIO_IDS[5]] = {
            "outcome": "failed",
            "observation_id": "not_observed",
        }
        evidence = build_evidence(expected, state, "failed")
        validate_evidence(
            evidence,
            expected_binding=expected,
            expected_outcome="failed",
        )
        with self.assertRaises(EvidenceError):
            validate_evidence(
                evidence,
                expected_binding=expected,
                expected_outcome="passed",
            )

    def test_binding_rejects_unsafe_origins_and_non_digest_candidates(self) -> None:
        bad_values = (
            {"site_origin": "http://staging.pakperk.app"},
            {"site_origin": "https://user:secret@staging.pakperk.app"},
            {"site_origin": "https://staging.pakperk.app/path"},
            {"site_origin": "https://staging.pakperk.app?query=1"},
            {"site_origin": "https://127.0.0.1"},
            {"site_origin": "https://10.0.0.1"},
            {"site_origin": "https://pakperk.123"},
            {"site_origin": "https://staging.example.invalid"},
            {"api_origin": "https://staging.pakperk.app"},
            {"oidc_issuer": "https://api.staging.pakperk.app/realms/pakperk"},
            {"oidc_issuer": "https://identity.staging.pakperk.app/realms/%0Apakperk"},
            {"oidc_issuer": "https://identity.staging.pakperk.app/realms\\pakperk"},
            {"requested_candidate_id": "release-candidate-42"},
            {"android_package": "app." + "a" * 300},
        )
        for override in bad_values:
            with self.subTest(override=override), self.assertRaises(EvidenceError):
                binding(**override).validate()

    def test_production_rejects_fixture_signing_identity(self) -> None:
        production = {
            "target_environment": "production",
            "android_package": "app.pakperk.pakperk",
            "apple_bundle_id": "app.pakperk.pakperk",
        }
        with self.assertRaisesRegex(EvidenceError, "known fixture"):
            binding(
                **production,
                android_sha256=("AA:" * 31) + "AA",
            ).validate()
        with self.assertRaisesRegex(EvidenceError, "known fixture"):
            binding(**production, apple_team_id="TEAMID1234").validate()

    def test_extra_fields_tampering_and_plain_content_id_fail_closed(self) -> None:
        expected = binding()
        baseline = build_evidence(expected, passed_state(), "passed")
        mutations = []
        extra = copy.deepcopy(baseline)
        extra["operator"] = "somebody"
        mutations.append(extra)
        tampered = copy.deepcopy(baseline)
        tampered["binding"]["origins"]["api"] = "https://other.pakperk.app"
        mutations.append(tampered)
        observed_failure = copy.deepcopy(baseline)
        observed_failure["scenarios"][0]["outcome"] = "failed"
        mutations.append(observed_failure)
        plain_id = copy.deepcopy(baseline)
        plain_id["content_id"] = "sha256:" + "c" * 64
        mutations.append(plain_id)
        for candidate in mutations:
            with self.subTest(candidate=candidate.get("content_id")), self.assertRaises(
                EvidenceError
            ):
                validate_evidence(candidate, expected_binding=expected)

    def test_hostile_json_value_types_fail_as_contract_errors(self) -> None:
        expected = binding()
        baseline = build_evidence(expected, passed_state(), "passed")
        mutations = []
        schema_boolean = copy.deepcopy(baseline)
        schema_boolean["schema_version"] = True
        mutations.append(schema_boolean)
        numeric_source = copy.deepcopy(baseline)
        numeric_source["binding"]["source_revision"] = 7
        mutations.append(numeric_source)
        object_client = copy.deepcopy(baseline)
        object_client["binding"]["runtime_config"]["oidc_client_id"] = {}
        mutations.append(object_client)
        list_fingerprint = copy.deepcopy(baseline)
        list_fingerprint["binding"]["mobile_candidate"][
            "android_play_signing_sha256"
        ] = []
        mutations.append(list_fingerprint)
        list_outcome = copy.deepcopy(baseline)
        list_outcome["run"]["outcome"] = []
        mutations.append(list_outcome)
        scenario_list_outcome = copy.deepcopy(baseline)
        scenario_list_outcome["scenarios"][0]["outcome"] = []
        mutations.append(scenario_list_outcome)
        for candidate in mutations:
            with self.subTest(candidate=candidate), self.assertRaises(EvidenceError):
                validate_evidence(candidate, expected_binding=expected)

    def test_write_is_private_atomic_and_no_overwrite(self) -> None:
        expected = binding()
        evidence = build_evidence(expected, passed_state(), "passed")
        destination = self.directory / "public-edge.json"
        write_evidence(destination, evidence, expected)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        self.assertEqual(
            validate_evidence(read_evidence(destination), expected_binding=expected),
            evidence,
        )
        with self.assertRaises(EvidenceError):
            write_evidence(destination, evidence, expected)
        self.assertFalse(
            any(path.suffix == ".tmp" for path in self.directory.iterdir())
        )

    def test_read_rejects_symlink_and_public_permissions(self) -> None:
        expected = binding()
        evidence = build_evidence(expected, passed_state(), "passed")
        destination = self.directory / "evidence.json"
        write_evidence(destination, evidence, expected)
        destination.chmod(0o644)
        with self.assertRaisesRegex(EvidenceError, "group or other"):
            read_evidence(destination)
        destination.chmod(0o600)
        link = self.directory / "link.json"
        link.symlink_to(destination)
        with self.assertRaises(EvidenceError):
            read_evidence(link)

    def test_read_rejects_duplicate_nonfinite_and_excessively_nested_json(self) -> None:
        invalid_documents = (
            '{"schema_version":1,"schema_version":1}',
            '{"schema_version":NaN}',
            "[" * 1200 + "]" * 1200,
        )
        for index, source in enumerate(invalid_documents):
            path = self.directory / f"invalid-{index}.json"
            path.write_text(source, encoding="ascii")
            path.chmod(0o600)
            with self.subTest(index=index), self.assertRaises(EvidenceError):
                read_evidence(path)

    def test_atomic_publication_wraps_link_failure_and_leaves_no_artifact(self) -> None:
        expected = binding()
        evidence = build_evidence(expected, passed_state(), "passed")
        destination = self.directory / "evidence.json"
        with mock.patch(
            "public_edge_evidence.os.link", side_effect=OSError("simulated")
        ):
            with self.assertRaisesRegex(EvidenceError, "atomically publish"):
                write_evidence(destination, evidence, expected)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_writer_rejects_group_writable_parent(self) -> None:
        expected = binding()
        evidence = build_evidence(expected, passed_state(), "passed")
        self.directory.chmod(0o770)
        with self.assertRaisesRegex(EvidenceError, "group/other writable"):
            write_evidence(self.directory / "evidence.json", evidence, expected)

    def test_standalone_validator_requires_every_exact_binding(self) -> None:
        expected = binding()
        evidence = build_evidence(expected, passed_state(), "passed")
        destination = self.directory / "evidence.json"
        write_evidence(destination, evidence, expected)
        command = [
            sys.executable,
            str(Path(__file__).with_name("validate_public_edge_evidence.py")),
            str(destination),
            "--source-revision",
            expected.source_revision,
            "--environment",
            expected.target_environment,
            "--expected-outcome",
            "passed",
            "--candidate-id",
            expected.requested_candidate_id,
            "--site-origin",
            expected.site_origin,
            "--api-origin",
            expected.api_origin,
            "--telemetry-origin",
            expected.telemetry_origin,
            "--document-version",
            expected.document_version,
            "--oidc-issuer",
            expected.oidc_issuer,
            "--oidc-client-id",
            expected.oidc_client_id,
            "--support-email",
            expected.support_email,
            "--android-package",
            expected.android_package,
            "--android-sha256",
            expected.android_sha256,
            "--apple-team-id",
            expected.apple_team_id,
            "--apple-bundle-id",
            expected.apple_bundle_id,
        ]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        mismatch = command.copy()
        mismatch[mismatch.index("--document-version") + 1] = "2026-08-02"
        failed = subprocess.run(mismatch, text=True, capture_output=True, check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertNotIn(expected.support_email, failed.stderr)


if __name__ == "__main__":
    unittest.main()
