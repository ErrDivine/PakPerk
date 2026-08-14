#!/usr/bin/env python3
"""Focused positive and tamper tests for protected service evidence."""

from __future__ import annotations

import contextlib
import copy
import datetime as dt
import hashlib
import io
import os
import pathlib
import tempfile
import unittest

import protected_service_exercise_evidence as evidence


def digest(label: str) -> str:
    return "sha256:" + hashlib.sha256(("pakperk-test/" + label).encode()).hexdigest()


def rate_scope(label: str) -> str:
    return evidence.RATE_SCOPE_PREFIX + hashlib.sha256(
        ("pakperk-test-rate-scope/" + label).encode()
    ).hexdigest()


def source_revision() -> str:
    return hashlib.sha1(b"pakperk protected service fixture").hexdigest()


def runner_session_payload() -> dict[str, object]:
    return {
        "schema_version": 1,
        "classification": evidence.RUNNER_SESSION_CLASSIFICATION,
        "source_revision": source_revision(),
        "protected_environment": evidence.PROTECTED_ENVIRONMENT,
        "purpose": evidence.RUNNER_SESSION_PURPOSE,
        "runner_labels": list(evidence.RUNNER_SESSION_LABELS),
        "host_identity_sha256": digest("protected-service-host"),
        "dedicated": True,
        "ephemeral": True,
        "issued_at": "2026-08-09T00:00:00Z",
        "expires_at": "2026-08-09T08:00:00Z",
    }


def fixture() -> dict[str, object]:
    binding = {
        "source_revision": source_revision(),
        "target_environment": "staging",
        "candidate_id": digest("candidate"),
        "deployment_evidence_id": "deployment-binding-v1:" + digest("deployment"),
        "deployment_images_sha256": digest("images"),
        "release_configuration_sha256": digest("release-config"),
        "topology_sha256": digest("topology"),
        "database_identity_sha256": digest("database"),
        "service_identity_sha256": digest("service"),
        "issuer_identity_sha256": digest("issuer"),
        "application_identity_sha256": digest("oidc-application"),
        "runner_session_id": digest("runner-session"),
        "driver_sha256": digest("driver"),
        "validator_sha256": digest("validator"),
        "workflow_sha256": digest("workflow"),
        "driver_request_contract_sha256": evidence.DRIVER_REQUEST_CONTRACT_SHA256,
    }
    replicas = sorted([digest("replica-a"), digest("replica-b")])
    shared_scope = rate_scope("paper-prepare-fixture")
    document: dict[str, object] = {
        "schema_version": evidence.SCHEMA_VERSION,
        "content_id": "",
        "approval_subject_id": "",
        "classification": evidence.CLASSIFICATION,
        "binding": binding,
        "run": {
            "workflow_run_id": 987654321,
            "workflow_run_attempt": 2,
            "challenge_sha256": evidence.challenge_sha256("0123456789abcdef" * 4),
            "protected_environment": evidence.PROTECTED_ENVIRONMENT,
            "started_at": "2026-08-09T01:00:00Z",
            "completed_at": "2026-08-09T02:00:00Z",
            "outcome": "passed",
        },
        "identity_rotation": {
            "release_issuer_sha256": binding["issuer_identity_sha256"],
            "discovery_endpoint_sha256": digest("discovery-endpoint"),
            "discovery_document_sha256": digest("discovery"),
            "jwks_endpoint_sha256": digest("jwks-endpoint"),
            "jwks_before_sha256": digest("jwks-before"),
            "jwks_after_rotation_sha256": digest("jwks-rotation"),
            "jwks_after_removal_sha256": digest("jwks-removal"),
            "old_kid": "kid-2026-rotation-a",
            "replacement_kid": "kid-2026-rotation-b",
            "configured_cache_ttl_seconds": 900,
            "wait_after_removal_seconds": 901,
            "replacement_token_status": 200,
            "replacement_token_result": "authenticated",
            "old_key_token_pre_removal_status": 200,
            "old_key_token_pre_removal_result": "authenticated",
            "removed_key_token_status": 401,
            "removed_key_error_code": "UNAUTHENTICATED",
            "old_key_token_remaining_lifetime_seconds_at_probe": 299,
            "expired_token_status": 401,
            "expired_token_error_code": "TOKEN_EXPIRED",
            "mobile_expiry_refresh_attempts": 1,
            "mobile_expiry_refresh_successes": 1,
            "invalidated_refresh_physical_evidence_sha256": digest(
                "physical-refresh"
            ),
            "provider_key_final_state": "retired",
        },
        "library_replay": {
            "operation_id_sha256": digest("library-operation"),
            "idempotency_key_sha256": digest("library-operation"),
            "intent_sha256": digest("library-intent"),
            "first_status": 200,
            "replay_status": 200,
            "first_response_sha256": digest("library-response"),
            "replay_response_sha256": digest("library-response"),
            "canonical_paper_state_sha256": digest("library-paper-state"),
            "first_revision": 3,
            "replay_revision": 3,
            "durable_operation_rows": 1,
            "durable_side_effect_rows": 1,
        },
        "comment_replay": {
            "paper_id_sha256": digest("comment-paper"),
            "client_request_id_sha256": digest("comment-request"),
            "normalized_body_sha256": digest("comment-normalized-body"),
            "first_status": 201,
            "replay_status": 200,
            "first_comment_identity_sha256": digest("comment-identity"),
            "replay_comment_identity_sha256": digest("comment-identity"),
            "first_response_body_sha256": digest("comment-response"),
            "replay_response_body_sha256": digest("comment-response"),
            "published_status_sha256": digest("comment-published-status"),
            "durable_comment_rows": 1,
            "durable_side_effect_rows": 1,
        },
        "shared_rate_limit": {
            "action": "paper_prepare",
            "scope_identity_sha256": shared_scope,
            "quota_limit": 4,
            "window_seconds": 60,
            "replicas": [
                {
                    "identity_sha256": replicas[0],
                    "scope_identity_sha256": shared_scope,
                    "accepted_requests": 2,
                },
                {
                    "identity_sha256": replicas[1],
                    "scope_identity_sha256": shared_scope,
                    "accepted_requests": 2,
                },
            ],
            "exhausting_replica_identity_sha256": replicas[0],
            "exhausting_scope_identity_sha256": shared_scope,
            "limited_replica_identity_sha256": replicas[1],
            "limited_scope_identity_sha256": shared_scope,
            "limited_status": 429,
            "limited_error_code": "RATE_LIMITED",
            "retry_after_seconds": 55,
            "reset_wait_seconds": 60,
            "reset_replica_identity_sha256": replicas[0],
            "reset_scope_identity_sha256": shared_scope,
            "reset_status": 200,
            "reset_outcome": "accepted_after_reset",
        },
        "switches": [
            {
                "id": switch_id,
                "before": copy.deepcopy(evidence.SWITCH_CONTEXTS[switch_id][0]),
                "after": copy.deepcopy(evidence.SWITCH_CONTEXTS[switch_id][1]),
                "rendered_before_sha256": digest(f"{switch_id}-before"),
                "rendered_after_sha256": digest(f"{switch_id}-after"),
                "observations": [
                    {
                        "id": observation_id,
                        "outcome": "passed",
                        "observation_sha256": digest(
                            f"{switch_id}-{observation_id}"
                        ),
                    }
                    for observation_id in evidence.SWITCH_OBSERVATIONS[switch_id]
                ],
                "restored_baseline_sha256": digest(f"{switch_id}-before"),
                "baseline_restored": True,
            }
            for switch_id in evidence.FEATURE_IDS
        ],
        "invalid_combinations": [
            {
                "id": case_id,
                "rendered_values": copy.deepcopy(values),
                "rendered_values_sha256": digest(f"invalid-{case_id}"),
                "target_environment": "production",
                "validation_status": "rejected",
                "failure_code": "INVALID_FEATURE_DEPENDENCY",
                "deployment_attempted": False,
            }
            for case_id, values in evidence.INVALID_CONTEXTS.items()
        ],
        "assertions": [
            {"id": assertion_id, "outcome": "passed"}
            for assertion_id in evidence.ASSERTION_IDS
        ],
        "measurements": [],
        "cleanup": {
            "synthetic_fixture_count": 4,
            "fixture_rows_removed": 7,
            "shared_rate_limit_buckets_removed": 1,
            "provider_key_state_reconciled": True,
            "baseline_restored": True,
            "cleanup_inventory_sha256": digest("cleanup"),
            "cleanup_failures": 0,
        },
        "approvals": [],
        "sanitization": copy.deepcopy(evidence.SANITIZATION),
    }
    measurement_values = {
        "assertions_passed": len(evidence.ASSERTION_IDS),
        "assertions_failed": 0,
        "jwks_cache_ttl_seconds": 900,
        "wait_after_old_key_removal_seconds": 901,
        "old_key_token_remaining_lifetime_seconds_at_probe": 299,
        "mobile_refresh_attempts": 1,
        "mobile_refresh_successes": 1,
        "library_durable_operation_rows": 1,
        "library_durable_side_effect_rows": 1,
        "comment_durable_comment_rows": 1,
        "comment_durable_side_effect_rows": 1,
        "serving_replica_count": 2,
        "accepted_rate_limit_requests": 4,
        "rate_limit_quota": 4,
        "rate_limit_window_seconds": 60,
        "rate_limit_status": 429,
        "retry_after_seconds": 55,
        "switch_cases_passed": 6,
        "invalid_dependency_cases_rejected": 6,
        "cleanup_failures": 0,
    }
    document["measurements"] = [
        {"id": measurement_id, "value": measurement_values[measurement_id]}
        for measurement_id in evidence.MEASUREMENT_IDS
    ]
    return reseal(document)


def reseal(document: dict[str, object]) -> dict[str, object]:
    document["approval_subject_id"] = evidence.compute_approval_subject_id(document)
    document["approvals"] = [
        {
            "role": role,
            "decision": "approved",
            "approved_at": "2026-08-09T03:00:00Z",
            "approval_subject_id": document["approval_subject_id"],
            "protected_audit_reference_sha256": digest(f"approval-{role}"),
        }
        for role in evidence.APPROVER_ROLES
    ]
    document["content_id"] = evidence.compute_content_id(document)
    return document


class ProtectedServiceEvidenceTests(unittest.TestCase):
    def write(self, directory: str, value: dict[str, object]) -> pathlib.Path:
        path = pathlib.Path(directory) / "protected-service-exercise.json"
        path.write_bytes(evidence.encode_canonical_document(value))
        return path

    def test_valid_document_file_and_cli_pass(self) -> None:
        document = fixture()
        expected = evidence.ExpectedBinding(
            source_revision=source_revision(),
            candidate_id=document["binding"]["candidate_id"],  # type: ignore[index]
            deployment_evidence_id=document["binding"]["deployment_evidence_id"],  # type: ignore[index]
            workflow_run_id=987654321,
            workflow_run_attempt=2,
            challenge="0123456789abcdef" * 4,
            runner_session_id=document["binding"]["runner_session_id"],  # type: ignore[index]
            driver_sha256=document["binding"]["driver_sha256"],  # type: ignore[index]
            validator_sha256=document["binding"]["validator_sha256"],  # type: ignore[index]
            workflow_sha256=document["binding"]["workflow_sha256"],  # type: ignore[index]
        )
        self.assertEqual(evidence.validate_evidence(document, expected=expected), document)
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(directory, document)
            self.assertEqual(evidence.validate_file(path, expected=expected), document)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = evidence.main(
                    [
                        "validate",
                        str(path),
                        "--source-revision",
                        source_revision(),
                        "--candidate-id",
                        str(document["binding"]["candidate_id"]),  # type: ignore[index]
                        "--deployment-evidence-id",
                        str(document["binding"]["deployment_evidence_id"]),  # type: ignore[index]
                        "--workflow-run-id",
                        "987654321",
                        "--workflow-run-attempt",
                        "2",
                        "--challenge",
                        "0123456789abcdef" * 4,
                        "--runner-session-id",
                        str(document["binding"]["runner_session_id"]),  # type: ignore[index]
                        "--driver-sha256",
                        str(document["binding"]["driver_sha256"]),  # type: ignore[index]
                        "--validator-sha256",
                        str(document["binding"]["validator_sha256"]),  # type: ignore[index]
                        "--workflow-sha256",
                        str(document["binding"]["workflow_sha256"]),  # type: ignore[index]
                    ]
                )
            self.assertEqual(result, 0)
            self.assertIn(str(document["content_id"]), stdout.getvalue())

    def test_root_owned_runner_session_contract_and_tampers(self) -> None:
        validation_time = dt.datetime(2026, 8, 9, 1, tzinfo=dt.timezone.utc)

        def validate_payload(
            directory: pathlib.Path, payload: dict[str, object]
        ) -> dict[str, object]:
            serialized = evidence.encode_canonical_document(payload)
            session_id = "sha256:" + hashlib.sha256(serialized).hexdigest()
            path = directory / f"{session_id.removeprefix('sha256:')}.json"
            path.write_bytes(serialized)
            path.chmod(0o600)
            return evidence.validate_runner_session_file(
                path,
                session_id=session_id,
                source_revision=source_revision(),
                validation_time=validation_time,
                root=directory,
                owner_uid=os.geteuid(),
                verify_ancestors=False,
            )

        with tempfile.TemporaryDirectory() as directory_text:
            directory = pathlib.Path(directory_text)
            directory.chmod(0o700)
            self.assertEqual(
                validate_payload(directory, runner_session_payload()),
                runner_session_payload(),
            )
            variants = []
            wrong_source = runner_session_payload()
            wrong_source["source_revision"] = hashlib.sha1(b"other source").hexdigest()
            variants.append(wrong_source)
            not_ephemeral = runner_session_payload()
            not_ephemeral["ephemeral"] = False
            variants.append(not_ephemeral)
            wrong_labels = runner_session_payload()
            wrong_labels["runner_labels"] = ["self-hosted"]
            variants.append(wrong_labels)
            insufficient_window = runner_session_payload()
            insufficient_window["expires_at"] = "2026-08-09T02:00:00Z"
            variants.append(insufficient_window)
            for variant in variants:
                with self.subTest(variant=variant):
                    with self.assertRaises(evidence.EvidenceError):
                        validate_payload(directory, variant)

            payload = runner_session_payload()
            serialized = evidence.encode_canonical_document(payload)
            wrong_id = digest("wrong-runner-session")
            wrong_path = directory / f"{wrong_id.removeprefix('sha256:')}.json"
            wrong_path.write_bytes(serialized)
            wrong_path.chmod(0o600)
            with self.assertRaisesRegex(evidence.EvidenceError, "content address"):
                evidence.validate_runner_session_file(
                    wrong_path,
                    session_id=wrong_id,
                    source_revision=source_revision(),
                    validation_time=validation_time,
                    root=directory,
                    owner_uid=os.geteuid(),
                    verify_ancestors=False,
                )

            valid_bytes = evidence.encode_canonical_document(runner_session_payload())
            valid_id = "sha256:" + hashlib.sha256(valid_bytes).hexdigest()
            valid_path = directory / f"{valid_id.removeprefix('sha256:')}.json"
            directory.chmod(0o777)
            with self.assertRaisesRegex(evidence.EvidenceError, "root ownership"):
                evidence.validate_runner_session_file(
                    valid_path,
                    session_id=valid_id,
                    source_revision=source_revision(),
                    validation_time=validation_time,
                    root=directory,
                    owner_uid=os.geteuid(),
                    verify_ancestors=False,
                )
            directory.chmod(0o700)
            valid_path.chmod(0o666)
            with self.assertRaisesRegex(evidence.EvidenceError, "owner-safe"):
                evidence.validate_runner_session_file(
                    valid_path,
                    session_id=valid_id,
                    source_revision=source_revision(),
                    validation_time=validation_time,
                    root=directory,
                    owner_uid=os.geteuid(),
                    verify_ancestors=False,
                )

    def test_semantic_tampers_are_rejected_even_when_resealed(self) -> None:
        mutations = {
            "old key probed at cache bound": lambda item: item["identity_rotation"].__setitem__(  # type: ignore[union-attr]
                "wait_after_removal_seconds", 900
            ),
            "old key token was not accepted before removal": lambda item: item["identity_rotation"].__setitem__(  # type: ignore[union-attr]
                "old_key_token_pre_removal_status", 401
            ),
            "old key token expired at removal probe": lambda item: item["identity_rotation"].__setitem__(  # type: ignore[union-attr]
                "old_key_token_remaining_lifetime_seconds_at_probe", 0
            ),
            "library replay response changed": lambda item: item["library_replay"].__setitem__(  # type: ignore[union-attr]
                "replay_response_sha256", digest("different-library-response")
            ),
            "library idempotency identity changed": lambda item: item["library_replay"].__setitem__(  # type: ignore[union-attr]
                "idempotency_key_sha256", digest("different-library-operation")
            ),
            "comment duplicated durable row": lambda item: item["comment_replay"].__setitem__(  # type: ignore[union-attr]
                "durable_comment_rows", 2
            ),
            "rate error changed": lambda item: item["shared_rate_limit"].__setitem__(  # type: ignore[union-attr]
                "limited_error_code", "TOO_MANY_REQUESTS"
            ),
            "non-repeatable account deletion quota selected": lambda item: item["shared_rate_limit"].__setitem__(  # type: ignore[union-attr]
                "action", "account_delete"
            ),
            "limited request used a different scope": lambda item: item["shared_rate_limit"].__setitem__(  # type: ignore[union-attr]
                "limited_scope_identity_sha256", rate_scope("unrelated-fixture")
            ),
            "accepted requests mixed scopes": lambda item: item["shared_rate_limit"]["replicas"][1].__setitem__(  # type: ignore[index,union-attr]
                "scope_identity_sha256", rate_scope("other-accepted-fixture")
            ),
            "switch dependency changed": lambda item: item["switches"][2]["after"].__setitem__(  # type: ignore[index,union-attr]
                "LIBRARY_ENABLED", False
            ),
            "invalid combo deployed": lambda item: item["invalid_combinations"][0].__setitem__(  # type: ignore[index,union-attr]
                "deployment_attempted", True
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                tampered = copy.deepcopy(fixture())
                mutate(tampered)
                reseal(tampered)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(tampered)

    def test_repeatable_rate_action_accepts_http_202_after_reset(self) -> None:
        document = copy.deepcopy(fixture())
        document["shared_rate_limit"]["reset_status"] = 202  # type: ignore[index]
        reseal(document)
        self.assertEqual(evidence.validate_evidence(document), document)
        self.assertNotIn("account_delete", evidence.ALLOWED_RATE_ACTIONS)

    def test_switch_cases_are_runtime_valid_and_cover_every_invalid_dependency(self) -> None:
        def runtime_valid(values: dict[str, bool]) -> bool:
            return (
                (not values["LIBRARY_ENABLED"] or values["ACCOUNTS_ENABLED"])
                and (
                    not values["LIBRARY_WRITES_ENABLED"]
                    or values["LIBRARY_ENABLED"]
                )
                and (not values["COMMENTS_ENABLED"] or values["ACCOUNTS_ENABLED"])
                and (
                    not values["COMMENT_CREATION_ENABLED"]
                    or values["COMMENTS_ENABLED"]
                )
                and (
                    not values["ACCOUNT_DELETION_ENABLED"]
                    or values["ACCOUNTS_ENABLED"]
                )
            )

        for switch_id, (before, after) in evidence.SWITCH_CONTEXTS.items():
            with self.subTest(switch_id=switch_id):
                self.assertTrue(runtime_valid(before))
                self.assertTrue(runtime_valid(after))
                self.assertEqual(
                    [name for name in evidence.FEATURE_IDS if before[name] != after[name]],
                    [switch_id],
                )
        self.assertIn("accounts_without_account_deletion", evidence.INVALID_CONTEXTS)
        self.assertIn("account_deletion_without_accounts", evidence.INVALID_CONTEXTS)
        self.assertEqual(len(evidence.INVALID_CONTEXTS), 6)

    def test_exact_keys_types_order_content_id_and_expected_binding_are_closed(self) -> None:
        variants: list[dict[str, object]] = []
        extra = copy.deepcopy(fixture())
        extra["unexpected"] = True
        variants.append(reseal(extra))
        boolean_count = copy.deepcopy(fixture())
        boolean_count["shared_rate_limit"]["quota_limit"] = True  # type: ignore[index]
        variants.append(reseal(boolean_count))
        reordered = copy.deepcopy(fixture())
        reordered["assertions"][0], reordered["assertions"][1] = (  # type: ignore[index]
            reordered["assertions"][1],
            reordered["assertions"][0],
        )
        variants.append(reseal(reordered))
        tampered_id = copy.deepcopy(fixture())
        tampered_id["content_id"] = evidence.CONTENT_PREFIX + hashlib.sha256(b"tamper").hexdigest()
        variants.append(tampered_id)
        for variant in variants:
            with self.subTest(content_id=variant["content_id"]):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(variant)

        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_evidence(
                fixture(),
                expected=evidence.ExpectedBinding(source_revision=hashlib.sha1(b"other").hexdigest()),
            )

    def test_sanitization_placeholder_and_reference_class_are_rejected(self) -> None:
        variants: list[dict[str, object]] = []
        sensitive = copy.deepcopy(fixture())
        sensitive["identity_rotation"]["old_kid"] = "operator@example.invalid"  # type: ignore[index]
        variants.append(reseal(sensitive))
        false_as_integer = copy.deepcopy(fixture())
        false_as_integer["sanitization"]["contains_raw_ugc"] = 0  # type: ignore[index]
        variants.append(reseal(false_as_integer))
        placeholder = copy.deepcopy(fixture())
        placeholder["binding"]["candidate_id"] = "sha256:" + "0" * 64  # type: ignore[index]
        variants.append(reseal(placeholder))
        reference = copy.deepcopy(fixture())
        reference["classification"] = "reference staging result"
        variants.append(reseal(reference))
        for variant in variants:
            with self.subTest(classification=variant["classification"]):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(variant)

    def test_duplicate_noncanonical_and_oversize_files_are_rejected(self) -> None:
        document = fixture()
        canonical = evidence.encode_canonical_document(document)
        duplicate = canonical.replace(
            b'"schema_version":1', b'"schema_version":1,"schema_version":1', 1
        )
        noncanonical = b" " + canonical
        oversize = b"{" + b" " * evidence.MAX_DOCUMENT_BYTES + b"}"
        with tempfile.TemporaryDirectory() as directory:
            for name, payload in (
                ("duplicate.json", duplicate),
                ("noncanonical.json", noncanonical),
                ("oversize.json", oversize),
            ):
                with self.subTest(name=name):
                    path = pathlib.Path(directory) / name
                    path.write_bytes(payload)
                    with self.assertRaises(evidence.EvidenceError):
                        evidence.validate_file(path)

    def test_unsafe_file_permissions_and_links_are_rejected(self) -> None:
        document = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            unsafe = self.write(directory, document)
            unsafe.chmod(0o666)
            with self.assertRaisesRegex(evidence.EvidenceError, "owner-safe"):
                evidence.validate_file(unsafe)

            unsafe.chmod(0o600)
            hardlink = root / "hardlink.json"
            hardlink.hardlink_to(unsafe)
            with self.assertRaisesRegex(evidence.EvidenceError, "owner-safe"):
                evidence.validate_file(unsafe)
            with self.assertRaisesRegex(evidence.EvidenceError, "owner-safe"):
                evidence.validate_file(hardlink)

            hardlink.unlink()
            symlink = root / "symlink.json"
            symlink.symlink_to(unsafe)
            with self.assertRaisesRegex(evidence.EvidenceError, "owner-safe"):
                evidence.validate_file(symlink)


if __name__ == "__main__":
    unittest.main()
