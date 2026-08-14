#!/usr/bin/env python3
"""Validate sanitized protected auth, replay, quota, and switch evidence.

This module intentionally does not drive an identity provider or a cluster.
The protected workflow hands a data-only request to a separately installed,
root-owned driver.  The driver may emit a final document only after the six
owners have approved the immutable execution-statement ID.  That two-ID model
avoids asking an approval record to refer to a content ID which includes the
approval record itself.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import stat
import sys
from dataclasses import dataclass
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
MAX_DOCUMENT_BYTES = 128 * 1024
MAX_RUNNER_SESSION_BYTES = 16 * 1024
MAX_JSON_NESTING = 16
CLASSIFICATION = "protected staging production-gate evidence"
PROTECTED_ENVIRONMENT = "protected-staging-service-exercise"
RUNNER_SESSION_ROOT = pathlib.Path("/opt/pakperk/protected-service-runner-sessions")
RUNNER_SESSION_CLASSIFICATION = (
    "dedicated ephemeral protected service exercise runner session"
)
RUNNER_SESSION_PURPOSE = "protected_service_exercise"
RUNNER_SESSION_LABELS = (
    "Linux",
    "pakperk-protected-service-exercise",
    "self-hosted",
)
MAX_RUNNER_SESSION_LIFETIME = dt.timedelta(hours=8)
MIN_RUNNER_SESSION_REMAINING = dt.timedelta(hours=6)
CONTENT_DOMAIN = b"pakperk/protected-service-exercise/v1\0"
APPROVAL_SUBJECT_DOMAIN = b"pakperk/protected-service-exercise-approval-subject/v1\0"
CHALLENGE_DOMAIN = b"pakperk/protected-service-exercise-challenge/v1\0"
DRIVER_REQUEST_CONTRACT_DOMAIN = (
    b"pakperk/protected-service-exercise-driver-request-contract/v1\0"
)
CONTENT_PREFIX = "protected-service-exercise-sha256:"
SUBJECT_PREFIX = "protected-service-subject-sha256:"
RATE_SCOPE_PREFIX = "protected-rate-scope-sha256:"

SOURCE_REVISION_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}")
DEPLOYMENT_ID_RE = re.compile(r"deployment-binding-v1:sha256:[0-9a-f]{64}")
CONTENT_ID_RE = re.compile(r"protected-service-exercise-sha256:[0-9a-f]{64}")
SUBJECT_ID_RE = re.compile(r"protected-service-subject-sha256:[0-9a-f]{64}")
RATE_SCOPE_ID_RE = re.compile(r"protected-rate-scope-sha256:[0-9a-f]{64}")
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
KID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{2,127}")
ACTION_RE = re.compile(r"[a-z][a-z0-9_-]{2,63}")
EMAIL_RE = re.compile(r"[^@\s]{1,64}@[^@\s]{1,189}")
JWT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
    r"[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"
)
IPV4_RE = re.compile(r"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")

ROOT_KEYS = {
    "schema_version",
    "content_id",
    "approval_subject_id",
    "classification",
    "binding",
    "run",
    "identity_rotation",
    "library_replay",
    "comment_replay",
    "shared_rate_limit",
    "switches",
    "invalid_combinations",
    "assertions",
    "measurements",
    "cleanup",
    "approvals",
    "sanitization",
}
BINDING_KEYS = {
    "source_revision",
    "target_environment",
    "candidate_id",
    "deployment_evidence_id",
    "deployment_images_sha256",
    "release_configuration_sha256",
    "topology_sha256",
    "database_identity_sha256",
    "service_identity_sha256",
    "issuer_identity_sha256",
    "application_identity_sha256",
    "runner_session_id",
    "driver_sha256",
    "validator_sha256",
    "workflow_sha256",
    "driver_request_contract_sha256",
}
RUN_KEYS = {
    "workflow_run_id",
    "workflow_run_attempt",
    "challenge_sha256",
    "protected_environment",
    "started_at",
    "completed_at",
    "outcome",
}
IDENTITY_KEYS = {
    "release_issuer_sha256",
    "discovery_endpoint_sha256",
    "discovery_document_sha256",
    "jwks_endpoint_sha256",
    "jwks_before_sha256",
    "jwks_after_rotation_sha256",
    "jwks_after_removal_sha256",
    "old_kid",
    "replacement_kid",
    "configured_cache_ttl_seconds",
    "wait_after_removal_seconds",
    "replacement_token_status",
    "replacement_token_result",
    "old_key_token_pre_removal_status",
    "old_key_token_pre_removal_result",
    "removed_key_token_status",
    "removed_key_error_code",
    "old_key_token_remaining_lifetime_seconds_at_probe",
    "expired_token_status",
    "expired_token_error_code",
    "mobile_expiry_refresh_attempts",
    "mobile_expiry_refresh_successes",
    "invalidated_refresh_physical_evidence_sha256",
    "provider_key_final_state",
}
LIBRARY_KEYS = {
    "operation_id_sha256",
    "idempotency_key_sha256",
    "intent_sha256",
    "first_status",
    "replay_status",
    "first_response_sha256",
    "replay_response_sha256",
    "canonical_paper_state_sha256",
    "first_revision",
    "replay_revision",
    "durable_operation_rows",
    "durable_side_effect_rows",
}
COMMENT_KEYS = {
    "paper_id_sha256",
    "client_request_id_sha256",
    "normalized_body_sha256",
    "first_status",
    "replay_status",
    "first_comment_identity_sha256",
    "replay_comment_identity_sha256",
    "first_response_body_sha256",
    "replay_response_body_sha256",
    "published_status_sha256",
    "durable_comment_rows",
    "durable_side_effect_rows",
}
RATE_LIMIT_KEYS = {
    "action",
    "scope_identity_sha256",
    "quota_limit",
    "window_seconds",
    "replicas",
    "exhausting_replica_identity_sha256",
    "exhausting_scope_identity_sha256",
    "limited_replica_identity_sha256",
    "limited_scope_identity_sha256",
    "limited_status",
    "limited_error_code",
    "retry_after_seconds",
    "reset_wait_seconds",
    "reset_replica_identity_sha256",
    "reset_scope_identity_sha256",
    "reset_status",
    "reset_outcome",
}
REPLICA_KEYS = {"identity_sha256", "scope_identity_sha256", "accepted_requests"}
SWITCH_KEYS = {
    "id",
    "before",
    "after",
    "rendered_before_sha256",
    "rendered_after_sha256",
    "observations",
    "restored_baseline_sha256",
    "baseline_restored",
}
OBSERVATION_KEYS = {"id", "outcome", "observation_sha256"}
INVALID_KEYS = {
    "id",
    "rendered_values",
    "rendered_values_sha256",
    "target_environment",
    "validation_status",
    "failure_code",
    "deployment_attempted",
}
ASSERTION_KEYS = {"id", "outcome"}
MEASUREMENT_KEYS = {"id", "value"}
CLEANUP_KEYS = {
    "synthetic_fixture_count",
    "fixture_rows_removed",
    "shared_rate_limit_buckets_removed",
    "provider_key_state_reconciled",
    "baseline_restored",
    "cleanup_inventory_sha256",
    "cleanup_failures",
}
APPROVAL_KEYS = {
    "role",
    "decision",
    "approved_at",
    "approval_subject_id",
    "protected_audit_reference_sha256",
}
SANITIZATION = {
    "contains_credentials": False,
    "contains_bearer_tokens": False,
    "contains_cookies": False,
    "contains_raw_network_addresses": False,
    "contains_raw_ugc": False,
    "contains_raw_logs": False,
    "contains_operator_identity": False,
    "contains_personal_data": False,
    "contains_provider_key_material": False,
    "contains_device_serials": False,
}
RUNNER_SESSION_KEYS = {
    "schema_version",
    "classification",
    "source_revision",
    "protected_environment",
    "purpose",
    "runner_labels",
    "host_identity_sha256",
    "dedicated",
    "ephemeral",
    "issued_at",
    "expires_at",
}

FEATURE_IDS = (
    "ACCOUNTS_ENABLED",
    "LIBRARY_ENABLED",
    "LIBRARY_WRITES_ENABLED",
    "COMMENTS_ENABLED",
    "COMMENT_CREATION_ENABLED",
    "ACCOUNT_DELETION_ENABLED",
)


def _feature_values(**enabled: bool) -> dict[str, bool]:
    return {name: enabled.get(name, False) for name in FEATURE_IDS}


SWITCH_CONTEXTS = {
    "ACCOUNTS_ENABLED": (
        _feature_values(ACCOUNTS_ENABLED=True),
        _feature_values(),
    ),
    "LIBRARY_ENABLED": (
        _feature_values(
            ACCOUNTS_ENABLED=True,
            LIBRARY_ENABLED=True,
            ACCOUNT_DELETION_ENABLED=True,
        ),
        _feature_values(ACCOUNTS_ENABLED=True, ACCOUNT_DELETION_ENABLED=True),
    ),
    "LIBRARY_WRITES_ENABLED": (
        _feature_values(
            ACCOUNTS_ENABLED=True,
            LIBRARY_ENABLED=True,
            LIBRARY_WRITES_ENABLED=True,
            ACCOUNT_DELETION_ENABLED=True,
        ),
        _feature_values(
            ACCOUNTS_ENABLED=True,
            LIBRARY_ENABLED=True,
            ACCOUNT_DELETION_ENABLED=True,
        ),
    ),
    "COMMENTS_ENABLED": (
        _feature_values(
            ACCOUNTS_ENABLED=True,
            COMMENTS_ENABLED=True,
            ACCOUNT_DELETION_ENABLED=True,
        ),
        _feature_values(ACCOUNTS_ENABLED=True, ACCOUNT_DELETION_ENABLED=True),
    ),
    "COMMENT_CREATION_ENABLED": (
        _feature_values(
            ACCOUNTS_ENABLED=True,
            COMMENTS_ENABLED=True,
            COMMENT_CREATION_ENABLED=True,
            ACCOUNT_DELETION_ENABLED=True,
        ),
        _feature_values(
            ACCOUNTS_ENABLED=True,
            COMMENTS_ENABLED=True,
            ACCOUNT_DELETION_ENABLED=True,
        ),
    ),
    "ACCOUNT_DELETION_ENABLED": (
        _feature_values(ACCOUNTS_ENABLED=True, ACCOUNT_DELETION_ENABLED=True),
        _feature_values(ACCOUNTS_ENABLED=True),
    ),
}

SWITCH_OBSERVATIONS = {
    "ACCOUNTS_ENABLED": (
        "authenticated_account_path_allowed_before_disable",
        "account_routes_absent_after_disable",
        "guest_reading_preserved_after_disable",
    ),
    "LIBRARY_ENABLED": (
        "library_read_allowed_before_disable",
        "library_routes_absent_after_disable",
        "guest_reading_preserved_after_library_disable",
    ),
    "LIBRARY_WRITES_ENABLED": (
        "library_write_allowed_before_disable",
        "library_write_feature_disabled_after_disable",
        "library_reads_preserved_after_write_disable",
    ),
    "COMMENTS_ENABLED": (
        "comment_read_allowed_before_disable",
        "comment_routes_absent_after_disable",
        "guest_paper_reading_preserved_after_comments_disable",
    ),
    "COMMENT_CREATION_ENABLED": (
        "comment_creation_allowed_before_disable",
        "comment_creation_feature_disabled_after_disable",
        "comment_reads_and_safety_actions_preserved_after_creation_disable",
    ),
    "ACCOUNT_DELETION_ENABLED": (
        "account_deletion_route_available_before_disable",
        "account_deletion_route_absent_after_valid_disable",
        "guest_reading_preserved_after_deletion_disable",
    ),
}

INVALID_CONTEXTS = {
    "accounts_without_account_deletion": _feature_values(ACCOUNTS_ENABLED=True),
    "account_deletion_without_accounts": _feature_values(
        ACCOUNT_DELETION_ENABLED=True
    ),
    "library_without_accounts": _feature_values(LIBRARY_ENABLED=True),
    "library_writes_without_library": _feature_values(
        ACCOUNTS_ENABLED=True,
        LIBRARY_WRITES_ENABLED=True,
        ACCOUNT_DELETION_ENABLED=True,
    ),
    "comments_without_accounts": _feature_values(COMMENTS_ENABLED=True),
    "comment_creation_without_comments": _feature_values(
        ACCOUNTS_ENABLED=True,
        COMMENT_CREATION_ENABLED=True,
        ACCOUNT_DELETION_ENABLED=True,
    ),
}

ASSERTION_IDS = (
    "exact_main_source_verified",
    "protected_environment_approved",
    "exact_deployment_binding_verified",
    "release_issuer_discovery_and_jwks_bound",
    "replacement_signing_key_published",
    "replacement_key_token_accepted",
    "old_key_token_accepted_before_removal",
    "old_signing_key_removed",
    "configured_cache_bound_elapsed_before_old_key_probe",
    "removed_key_token_was_unexpired_at_probe",
    "removed_key_token_rejected",
    "expired_token_rejected",
    "mobile_expiry_refresh_succeeded_once",
    "invalidated_refresh_physical_result_bound",
    "library_same_operation_and_idempotency_identity_replayed",
    "library_replay_has_one_durable_side_effect",
    "comment_same_operation_and_client_request_identity_replayed",
    "comment_replay_has_one_durable_side_effect",
    "at_least_two_serving_replicas_identified",
    "one_shared_bucket_bound_across_rate_limit_sequence",
    "accepted_quota_requests_routed_through_each_replica",
    "shared_quota_exhausted_cross_replica",
    "stable_rate_limited_contract_observed",
    "shared_quota_reset_succeeded",
    "six_switches_observed_under_valid_dependencies",
    "invalid_feature_dependencies_failed_closed",
    "baseline_restored_between_switch_cases",
    "synthetic_fixtures_cleaned",
    "owner_approvals_complete",
)

MEASUREMENT_IDS = (
    "assertions_passed",
    "assertions_failed",
    "jwks_cache_ttl_seconds",
    "wait_after_old_key_removal_seconds",
    "old_key_token_remaining_lifetime_seconds_at_probe",
    "mobile_refresh_attempts",
    "mobile_refresh_successes",
    "library_durable_operation_rows",
    "library_durable_side_effect_rows",
    "comment_durable_comment_rows",
    "comment_durable_side_effect_rows",
    "serving_replica_count",
    "accepted_rate_limit_requests",
    "rate_limit_quota",
    "rate_limit_window_seconds",
    "rate_limit_status",
    "retry_after_seconds",
    "switch_cases_passed",
    "invalid_dependency_cases_rejected",
    "cleanup_failures",
)

APPROVER_ROLES = (
    "identity_owner",
    "service_owner",
    "database_owner",
    "platform_owner",
    "release_owner",
    "privacy_safety_owner",
)

ALLOWED_RATE_ACTIONS = {
    "paper_prepare",
    "profile_update",
    "library_mutation",
    "comment_create",
    "comment_mutation",
    "comment_report",
    "user_report",
}


class EvidenceError(RuntimeError):
    """A closed evidence contract violation with no untrusted value echo."""


@dataclass(frozen=True)
class ExpectedBinding:
    source_revision: str | None = None
    candidate_id: str | None = None
    deployment_evidence_id: str | None = None
    workflow_run_id: int | None = None
    workflow_run_attempt: int | None = None
    challenge: str | None = None
    runner_session_id: str | None = None
    driver_sha256: str | None = None
    validator_sha256: str | None = None
    workflow_sha256: str | None = None


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise EvidenceError(f"{label} does not have the exact required keys")
    return value


def _integer(
    value: Any, label: str, *, minimum: int = 0, maximum: int = 2**63 - 1
) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise EvidenceError(f"{label} is outside its integer boundary")
    return value


def _canonical_json(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeError, RecursionError) as error:
        raise EvidenceError("evidence is not canonical JSON data") from error


def encode_canonical_document(value: Any) -> bytes:
    return _canonical_json(value) + b"\n"


DRIVER_REQUEST_CONTRACT = {
    "schema_version": 1,
    "evidence_schema_version": SCHEMA_VERSION,
    "classification": CLASSIFICATION,
    "protected_environment": PROTECTED_ENVIRONMENT,
    "root_keys": sorted(ROOT_KEYS),
    "binding_keys": sorted(BINDING_KEYS),
    "run_keys": sorted(RUN_KEYS),
    "identity_keys": sorted(IDENTITY_KEYS),
    "library_keys": sorted(LIBRARY_KEYS),
    "comment_keys": sorted(COMMENT_KEYS),
    "rate_limit_keys": sorted(RATE_LIMIT_KEYS),
    "replica_keys": sorted(REPLICA_KEYS),
    "switch_keys": sorted(SWITCH_KEYS),
    "observation_keys": sorted(OBSERVATION_KEYS),
    "invalid_combination_keys": sorted(INVALID_KEYS),
    "assertion_keys": sorted(ASSERTION_KEYS),
    "measurement_keys": sorted(MEASUREMENT_KEYS),
    "cleanup_keys": sorted(CLEANUP_KEYS),
    "approval_keys": sorted(APPROVAL_KEYS),
    "sanitization": dict(SANITIZATION),
    "assertion_ids": list(ASSERTION_IDS),
    "measurement_ids": list(MEASUREMENT_IDS),
    "switch_ids": list(FEATURE_IDS),
    "switch_contexts": {
        key: [before, after]
        for key, (before, after) in SWITCH_CONTEXTS.items()
    },
    "switch_observations": {
        key: list(observations)
        for key, observations in SWITCH_OBSERVATIONS.items()
    },
    "invalid_dependency_ids": list(INVALID_CONTEXTS),
    "invalid_dependency_contexts": dict(INVALID_CONTEXTS),
    "approver_roles": list(APPROVER_ROLES),
    "allowed_rate_actions": sorted(ALLOWED_RATE_ACTIONS),
    "rate_scope_prefix": RATE_SCOPE_PREFIX,
}
DRIVER_REQUEST_CONTRACT_SHA256 = "sha256:" + hashlib.sha256(
    DRIVER_REQUEST_CONTRACT_DOMAIN + _canonical_json(DRIVER_REQUEST_CONTRACT)
).hexdigest()


def _content_statement(document: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: copy.deepcopy(value)
        for key, value in document.items()
        if key != "content_id"
    }


def _approval_statement(document: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: copy.deepcopy(value)
        for key, value in document.items()
        if key not in {"content_id", "approval_subject_id", "approvals"}
    }


def compute_content_id(document: Mapping[str, Any]) -> str:
    digest = hashlib.sha256(
        CONTENT_DOMAIN + _canonical_json(_content_statement(document))
    ).hexdigest()
    return CONTENT_PREFIX + digest


def compute_approval_subject_id(document: Mapping[str, Any]) -> str:
    digest = hashlib.sha256(
        APPROVAL_SUBJECT_DOMAIN + _canonical_json(_approval_statement(document))
    ).hexdigest()
    return SUBJECT_PREFIX + digest


def challenge_sha256(challenge: str) -> str:
    if (
        not isinstance(challenge, str)
        or re.fullmatch(r"[0-9a-f]{64}", challenge) is None
        or len(set(challenge)) < 8
    ):
        raise EvidenceError("expected workflow challenge is invalid")
    return "sha256:" + hashlib.sha256(
        CHALLENGE_DOMAIN + challenge.encode("ascii")
    ).hexdigest()


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise EvidenceError("JSON contains a duplicate object key")
        value[key] = child
    return value


def _reject_constant(_value: str) -> None:
    raise EvidenceError("JSON contains a non-finite number")


def _depth(value: Any, level: int = 0) -> None:
    if level > MAX_JSON_NESTING:
        raise EvidenceError("JSON nesting exceeds the evidence boundary")
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise EvidenceError("JSON object keys must be strings")
            _depth(child, level + 1)
    elif isinstance(value, list):
        for child in value:
            _depth(child, level + 1)
    elif value is None or isinstance(value, (str, bool, int)):
        return
    else:
        raise EvidenceError("JSON contains an unsupported scalar type")


def _file_identity(value: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_canonical(
    path: pathlib.Path,
    *,
    maximum_bytes: int = MAX_DOCUMENT_BYTES,
    allowed_owner_uids: set[int] | None = None,
    label: str = "evidence",
) -> dict[str, Any]:
    owners = {0, os.geteuid()} if allowed_owner_uids is None else allowed_owner_uids
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise EvidenceError(f"{label} file cannot be inspected") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid not in owners
        or metadata.st_mode & 0o022
        or not 0 < metadata.st_size <= maximum_bytes
    ):
        raise EvidenceError(
            f"{label} must be one owner-safe bounded regular file"
        )

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        try:
            before = os.fstat(descriptor)
            chunks: list[bytes] = []
            remaining = maximum_bytes + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(64 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise EvidenceError(f"{label} exceeds the byte boundary")
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        current = os.lstat(path)
    except (OSError, ValueError) as error:
        raise EvidenceError(f"{label} file cannot be read safely") from error

    data = b"".join(chunks)
    if (
        _file_identity(metadata) != _file_identity(before)
        or _file_identity(before) != _file_identity(after)
        or _file_identity(after) != _file_identity(current)
        or len(data) != before.st_size
    ):
        raise EvidenceError(f"{label} changed while it was read")
    try:
        value = json.loads(
            data.decode("ascii"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_constant,
        )
    except EvidenceError:
        raise
    except (json.JSONDecodeError, UnicodeError, ValueError, RecursionError) as error:
        raise EvidenceError(f"{label} is not valid bounded ASCII JSON") from error
    _depth(value)
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} root must be an object")
    if data != encode_canonical_document(value):
        raise EvidenceError(f"{label} file is not canonical JSON")
    return value


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not one SHA-256 identity")
    digest = value.removeprefix("sha256:")
    if len(set(digest)) < 8 or digest in {
        "0123456789abcdef" * 4,
        "deadbeef" * 8,
        "cafebabe" * 8,
    }:
        raise EvidenceError(f"{label} is a placeholder SHA-256 identity")
    return value


def _source_revision(value: Any) -> str:
    if not isinstance(value, str) or SOURCE_REVISION_RE.fullmatch(value) is None:
        raise EvidenceError("source revision is not one full lowercase commit SHA")
    if len(set(value)) < 8 or value in {"0123456789abcdef" * 2 + "01234567"}:
        raise EvidenceError("source revision is a placeholder")
    return value


def _deployment_id(value: Any) -> str:
    if not isinstance(value, str) or DEPLOYMENT_ID_RE.fullmatch(value) is None:
        raise EvidenceError("deployment evidence ID is invalid")
    _sha256("sha256:" + value.rsplit(":", 1)[1], "deployment evidence ID")
    return value


def _rate_scope_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or RATE_SCOPE_ID_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not one protected rate-scope identity")
    _sha256(
        "sha256:" + value.removeprefix(RATE_SCOPE_PREFIX),
        label,
    )
    return value


def _utc(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not one canonical UTC timestamp")
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as error:
        raise EvidenceError(f"{label} is not a real UTC timestamp") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise EvidenceError(f"{label} is not canonical")
    return parsed


def _validate_runner_session_path(
    path: pathlib.Path,
    *,
    root: pathlib.Path,
    owner_uid: int,
    session_id: str,
    verify_ancestors: bool,
) -> None:
    digest = _sha256(session_id, "runner session attestation ID").removeprefix(
        "sha256:"
    )
    if (
        not path.is_absolute()
        or not root.is_absolute()
        or path.parent != root
        or path.name != f"{digest}.json"
    ):
        raise EvidenceError(
            "runner session attestation is outside its content-addressed root"
        )

    directories = [root]
    if verify_ancestors:
        current = root.parent
        while True:
            directories.append(current)
            if current == current.parent:
                break
            current = current.parent
    for directory in directories:
        try:
            metadata = os.lstat(directory)
        except OSError as error:
            raise EvidenceError(
                "runner session attestation root cannot be inspected"
            ) from error
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != owner_uid
            or metadata.st_mode & 0o022
        ):
            raise EvidenceError(
                "runner session attestation root ownership or mode is unsafe"
            )


def validate_runner_session_file(
    path: pathlib.Path,
    *,
    session_id: str,
    source_revision: str,
    validation_time: dt.datetime | None = None,
    root: pathlib.Path = RUNNER_SESSION_ROOT,
    owner_uid: int = 0,
    verify_ancestors: bool = True,
) -> dict[str, Any]:
    """Open and validate one fresh root-controlled runner-session attestation."""

    expected_source = _source_revision(source_revision)
    _validate_runner_session_path(
        path,
        root=root,
        owner_uid=owner_uid,
        session_id=session_id,
        verify_ancestors=verify_ancestors,
    )
    payload = _read_canonical(
        path,
        maximum_bytes=MAX_RUNNER_SESSION_BYTES,
        allowed_owner_uids={owner_uid},
        label="runner session attestation",
    )
    observed_id = "sha256:" + hashlib.sha256(
        encode_canonical_document(payload)
    ).hexdigest()
    if observed_id != session_id:
        raise EvidenceError(
            "runner session attestation bytes do not match its content address"
        )

    session = _exact(payload, RUNNER_SESSION_KEYS, "runner session attestation")
    if session["schema_version"] != 1 or type(session["schema_version"]) is not int:
        raise EvidenceError("runner session attestation schema is invalid")
    if session["classification"] != RUNNER_SESSION_CLASSIFICATION:
        raise EvidenceError("runner session attestation classification is invalid")
    if session["source_revision"] != expected_source:
        raise EvidenceError("runner session attestation source revision does not match")
    if session["protected_environment"] != PROTECTED_ENVIRONMENT:
        raise EvidenceError("runner session attestation environment does not match")
    if session["purpose"] != RUNNER_SESSION_PURPOSE:
        raise EvidenceError("runner session attestation purpose does not match")
    labels = session["runner_labels"]
    if not isinstance(labels, list) or tuple(labels) != RUNNER_SESSION_LABELS:
        raise EvidenceError("runner session attestation labels do not match")
    host_identity = _sha256(
        session["host_identity_sha256"], "runner session host identity"
    )
    if host_identity == session_id:
        raise EvidenceError("runner session and host identities must be distinct")
    if session["dedicated"] is not True or session["ephemeral"] is not True:
        raise EvidenceError("runner session must be dedicated and ephemeral")

    issued = _utc(session["issued_at"], "runner session issue time")
    expires = _utc(session["expires_at"], "runner session expiry time")
    now = validation_time or dt.datetime.now(dt.timezone.utc)
    if now.tzinfo is None or now.utcoffset() is None:
        raise EvidenceError("runner session validation time must be timezone-aware")
    now = now.astimezone(dt.timezone.utc)
    if not issued <= now < expires:
        raise EvidenceError("runner session attestation is not currently valid")
    if not dt.timedelta(0) < expires - issued <= MAX_RUNNER_SESSION_LIFETIME:
        raise EvidenceError("runner session lifetime must be positive and at most eight hours")
    if expires - now < MIN_RUNNER_SESSION_REMAINING:
        raise EvidenceError(
            "runner session does not cover the protected workflow timeout"
        )
    _reject_sensitive_shapes(session)
    return session


def _feature_map(value: Any, label: str) -> dict[str, bool]:
    result = _exact(value, set(FEATURE_IDS), label)
    if any(type(result[key]) is not bool for key in FEATURE_IDS):
        raise EvidenceError(f"{label} contains a non-boolean switch")
    return result


def _all_strings(value: Any) -> Sequence[str]:
    strings: list[str] = []

    def visit(child: Any) -> None:
        if isinstance(child, str):
            strings.append(child)
        elif isinstance(child, dict):
            for key, nested in child.items():
                strings.append(key)
                visit(nested)
        elif isinstance(child, list):
            for nested in child:
                visit(nested)

    visit(value)
    return strings


def _reject_sensitive_shapes(value: Mapping[str, Any]) -> None:
    for string in _all_strings(value):
        lowered = string.lower()
        try:
            ipaddress.ip_address(string.removeprefix("[").removesuffix("]"))
        except ValueError:
            raw_address = False
        else:
            raw_address = True
        if (
            raw_address
            or EMAIL_RE.search(string)
            or JWT_RE.search(string)
            or IPV4_RE.search(string)
            or "://" in string
            or "-----begin" in lowered
            or "bearer " in lowered
            or "set-cookie" in lowered
            or "authorization:" in lowered
        ):
            raise EvidenceError("evidence contains a forbidden sensitive-data shape")


def _validate_binding(value: Any) -> dict[str, Any]:
    binding = _exact(value, BINDING_KEYS, "binding")
    _source_revision(binding["source_revision"])
    if binding["target_environment"] != "staging":
        raise EvidenceError("target environment must be protected staging")
    _sha256(binding["candidate_id"], "candidate ID")
    _deployment_id(binding["deployment_evidence_id"])
    for key in (
        "deployment_images_sha256",
        "release_configuration_sha256",
        "topology_sha256",
        "database_identity_sha256",
        "service_identity_sha256",
        "issuer_identity_sha256",
        "application_identity_sha256",
        "runner_session_id",
        "driver_sha256",
        "validator_sha256",
        "workflow_sha256",
        "driver_request_contract_sha256",
    ):
        _sha256(binding[key], key.replace("_", " "))
    if binding["driver_request_contract_sha256"] != DRIVER_REQUEST_CONTRACT_SHA256:
        raise EvidenceError("driver request contract digest does not match")
    identities = [
        binding["candidate_id"],
        binding["deployment_images_sha256"],
        binding["release_configuration_sha256"],
        binding["topology_sha256"],
        binding["database_identity_sha256"],
        binding["service_identity_sha256"],
        binding["issuer_identity_sha256"],
        binding["application_identity_sha256"],
        binding["runner_session_id"],
        binding["driver_sha256"],
        binding["validator_sha256"],
        binding["workflow_sha256"],
        binding["driver_request_contract_sha256"],
    ]
    if len(set(identities)) != len(identities):
        raise EvidenceError("independent binding identities must be distinct")
    return binding


def _validate_run(value: Any) -> tuple[dict[str, Any], dt.datetime, dt.datetime]:
    run = _exact(value, RUN_KEYS, "run")
    _integer(run["workflow_run_id"], "workflow run ID", minimum=1)
    _integer(run["workflow_run_attempt"], "workflow run attempt", minimum=1, maximum=100)
    _sha256(run["challenge_sha256"], "run challenge")
    if run["protected_environment"] != PROTECTED_ENVIRONMENT:
        raise EvidenceError("run is not bound to the protected environment")
    if run["outcome"] != "passed":
        raise EvidenceError("protected exercise outcome is not passed")
    started = _utc(run["started_at"], "run start")
    completed = _utc(run["completed_at"], "run completion")
    if not started < completed <= started + dt.timedelta(hours=24):
        raise EvidenceError("run UTC window is empty or exceeds 24 hours")
    return run, started, completed


def _validate_identity(value: Any, binding: Mapping[str, Any]) -> dict[str, Any]:
    identity = _exact(value, IDENTITY_KEYS, "identity rotation")
    for key in (
        "release_issuer_sha256",
        "discovery_endpoint_sha256",
        "discovery_document_sha256",
        "jwks_endpoint_sha256",
        "jwks_before_sha256",
        "jwks_after_rotation_sha256",
        "jwks_after_removal_sha256",
        "invalidated_refresh_physical_evidence_sha256",
    ):
        _sha256(identity[key], key.replace("_", " "))
    if identity["release_issuer_sha256"] != binding["issuer_identity_sha256"]:
        raise EvidenceError("release issuer does not match the bound issuer identity")
    if len(
        {
            identity["discovery_document_sha256"],
            identity["discovery_endpoint_sha256"],
            identity["jwks_endpoint_sha256"],
            identity["jwks_before_sha256"],
            identity["jwks_after_rotation_sha256"],
            identity["jwks_after_removal_sha256"],
        }
    ) != 6:
        raise EvidenceError("discovery and JWKS observations must be distinct")
    for key in ("old_kid", "replacement_kid"):
        kid = identity[key]
        if not isinstance(kid, str) or KID_RE.fullmatch(kid) is None:
            raise EvidenceError("recorded signing-key ID is invalid")
        if any(word in kid.lower() for word in ("example", "placeholder", "dummy")):
            raise EvidenceError("recorded signing-key ID is a placeholder")
    if identity["old_kid"] == identity["replacement_kid"]:
        raise EvidenceError("old and replacement signing-key IDs must differ")
    cache_ttl = _integer(
        identity["configured_cache_ttl_seconds"],
        "configured JWKS cache bound",
        minimum=1,
        maximum=86_400,
    )
    wait = _integer(
        identity["wait_after_removal_seconds"],
        "wait after old-key removal",
        minimum=2,
        maximum=86_700,
    )
    if wait <= cache_ttl or wait > cache_ttl + 300:
        raise EvidenceError("old-key probe was not just beyond the configured cache bound")
    exact = {
        "replacement_token_status": 200,
        "replacement_token_result": "authenticated",
        "old_key_token_pre_removal_status": 200,
        "old_key_token_pre_removal_result": "authenticated",
        "removed_key_token_status": 401,
        "removed_key_error_code": "UNAUTHENTICATED",
        "expired_token_status": 401,
        "expired_token_error_code": "TOKEN_EXPIRED",
        "mobile_expiry_refresh_attempts": 1,
        "mobile_expiry_refresh_successes": 1,
    }
    for key, expected in exact.items():
        if identity[key] != expected or type(identity[key]) is not type(expected):
            raise EvidenceError("identity rotation result is not the exact closed outcome")
    _integer(
        identity["old_key_token_remaining_lifetime_seconds_at_probe"],
        "old-key token remaining lifetime at removal probe",
        minimum=1,
        maximum=86_400,
    )
    if identity["provider_key_final_state"] not in {"restored", "retired"}:
        raise EvidenceError("provider signing-key cleanup state is invalid")
    return identity


def _validate_library(value: Any) -> dict[str, Any]:
    replay = _exact(value, LIBRARY_KEYS, "library replay")
    for key in (
        "operation_id_sha256",
        "idempotency_key_sha256",
        "intent_sha256",
        "first_response_sha256",
        "replay_response_sha256",
        "canonical_paper_state_sha256",
    ):
        _sha256(replay[key], key.replace("_", " "))
    if replay["operation_id_sha256"] != replay["idempotency_key_sha256"]:
        raise EvidenceError(
            "library Idempotency-Key does not match the body operation identity"
        )
    for key in ("first_status", "replay_status"):
        if replay[key] != 200 or type(replay[key]) is not int:
            raise EvidenceError("library replay did not return HTTP 200 twice")
    first_revision = _integer(replay["first_revision"], "library first revision", minimum=1)
    replay_revision = _integer(replay["replay_revision"], "library replay revision", minimum=1)
    if (
        replay["first_response_sha256"] != replay["replay_response_sha256"]
        or first_revision != replay_revision
    ):
        raise EvidenceError("library replay response or revision changed")
    if replay["durable_operation_rows"] != 1 or type(replay["durable_operation_rows"]) is not int:
        raise EvidenceError("library replay did not retain exactly one durable operation")
    if replay["durable_side_effect_rows"] != 1 or type(replay["durable_side_effect_rows"]) is not int:
        raise EvidenceError("library replay did not retain exactly one durable side effect")
    return replay


def _validate_comment(value: Any) -> dict[str, Any]:
    replay = _exact(value, COMMENT_KEYS, "comment replay")
    for key in (
        "paper_id_sha256",
        "client_request_id_sha256",
        "normalized_body_sha256",
        "first_comment_identity_sha256",
        "replay_comment_identity_sha256",
        "first_response_body_sha256",
        "replay_response_body_sha256",
        "published_status_sha256",
    ):
        _sha256(replay[key], key.replace("_", " "))
    if replay["first_status"] != 201 or type(replay["first_status"]) is not int:
        raise EvidenceError("first comment creation did not return HTTP 201")
    if replay["replay_status"] != 200 or type(replay["replay_status"]) is not int:
        raise EvidenceError("comment replay did not return HTTP 200")
    if (
        replay["first_comment_identity_sha256"]
        != replay["replay_comment_identity_sha256"]
        or replay["first_response_body_sha256"]
        != replay["replay_response_body_sha256"]
    ):
        raise EvidenceError("comment replay changed canonical identity or body")
    if replay["durable_comment_rows"] != 1 or type(replay["durable_comment_rows"]) is not int:
        raise EvidenceError("comment replay did not retain exactly one durable comment")
    if replay["durable_side_effect_rows"] != 1 or type(replay["durable_side_effect_rows"]) is not int:
        raise EvidenceError("comment replay did not retain exactly one durable side effect")
    return replay


def _validate_rate_limit(value: Any) -> tuple[dict[str, Any], int]:
    rate = _exact(value, RATE_LIMIT_KEYS, "shared rate limit")
    if (
        not isinstance(rate["action"], str)
        or ACTION_RE.fullmatch(rate["action"]) is None
        or rate["action"] not in ALLOWED_RATE_ACTIONS
    ):
        raise EvidenceError("shared rate-limit action is not a reviewed bucket")
    scope_identity = _rate_scope_id(
        rate["scope_identity_sha256"], "shared rate-limit scope identity"
    )
    quota = _integer(rate["quota_limit"], "shared quota", minimum=2, maximum=10_000)
    window = _integer(
        rate["window_seconds"], "shared quota window", minimum=1, maximum=30 * 24 * 60 * 60
    )
    replicas = rate["replicas"]
    if not isinstance(replicas, list) or not 2 <= len(replicas) <= 16:
        raise EvidenceError("shared quota did not identify two to sixteen serving replicas")
    identities: list[str] = []
    accepted = 0
    for item in replicas:
        replica = _exact(item, REPLICA_KEYS, "serving replica")
        identity = _sha256(replica["identity_sha256"], "serving replica identity")
        if (
            _rate_scope_id(
                replica["scope_identity_sha256"],
                "accepted request rate-limit scope identity",
            )
            != scope_identity
        ):
            raise EvidenceError("accepted requests did not use one shared rate-limit scope")
        identities.append(identity)
        accepted += _integer(
            replica["accepted_requests"],
            "per-replica accepted request count",
            minimum=1,
            maximum=quota,
        )
    if identities != sorted(identities) or len(set(identities)) != len(identities):
        raise EvidenceError("serving replicas must be unique and identity-sorted")
    scope_digest = scope_identity.removeprefix(RATE_SCOPE_PREFIX)
    if any(identity.removeprefix("sha256:") == scope_digest for identity in identities):
        raise EvidenceError("rate-limit scope and serving replica identities must differ")
    if accepted != quota:
        raise EvidenceError("accepted cross-replica requests do not exactly exhaust the quota")
    exhausting_identity = _sha256(
        rate["exhausting_replica_identity_sha256"],
        "quota-exhausting serving replica identity",
    )
    limited_identity = _sha256(
        rate["limited_replica_identity_sha256"], "limited serving replica identity"
    )
    reset_identity = _sha256(
        rate["reset_replica_identity_sha256"], "reset serving replica identity"
    )
    for key, label in (
        ("exhausting_scope_identity_sha256", "quota-exhausting rate-limit scope"),
        ("limited_scope_identity_sha256", "limited request rate-limit scope"),
        ("reset_scope_identity_sha256", "reset request rate-limit scope"),
    ):
        if _rate_scope_id(rate[key], label) != scope_identity:
            raise EvidenceError(
                "accepted, exhausting, limited, and reset requests did not use one shared bucket"
            )
    if (
        exhausting_identity not in identities
        or limited_identity not in identities
        or reset_identity not in identities
    ):
        raise EvidenceError("rate-limit failure or reset was not attributed to a serving replica")
    if exhausting_identity == limited_identity:
        raise EvidenceError("quota exhaustion and the next limited request must use different replicas")
    if rate["limited_status"] != 429 or type(rate["limited_status"]) is not int:
        raise EvidenceError("shared quota did not return stable HTTP 429")
    if rate["limited_error_code"] != "RATE_LIMITED":
        raise EvidenceError("shared quota did not return RATE_LIMITED")
    retry_after = _integer(
        rate["retry_after_seconds"],
        "Retry-After delta seconds",
        minimum=1,
        maximum=window,
    )
    reset_wait = _integer(
        rate["reset_wait_seconds"],
        "rate-limit reset wait",
        minimum=retry_after,
        maximum=window + 300,
    )
    if reset_wait < retry_after:
        raise EvidenceError("rate-limit reset was attempted before Retry-After")
    if rate["reset_status"] not in {200, 201, 202, 204} or type(rate["reset_status"]) is not int:
        raise EvidenceError("shared quota reset did not return a successful HTTP status")
    if rate["reset_outcome"] != "accepted_after_reset":
        raise EvidenceError("shared quota did not accept a request after reset")
    return rate, accepted


def _validate_switches(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(FEATURE_IDS):
        raise EvidenceError("switch evidence must contain exactly six cases")
    validated: list[dict[str, Any]] = []
    for expected_id, item in zip(FEATURE_IDS, value):
        case = _exact(item, SWITCH_KEYS, "switch case")
        if case["id"] != expected_id:
            raise EvidenceError("switch cases are missing, duplicate, or out of order")
        before = _feature_map(case["before"], "switch before values")
        after = _feature_map(case["after"], "switch after values")
        expected_before, expected_after = SWITCH_CONTEXTS[expected_id]
        if before != expected_before or after != expected_after:
            raise EvidenceError("switch case is not the reviewed valid dependency combination")
        if [name for name in FEATURE_IDS if before[name] != after[name]] != [expected_id]:
            raise EvidenceError("switch case changed more than one switch")
        _sha256(case["rendered_before_sha256"], "rendered before values")
        _sha256(case["rendered_after_sha256"], "rendered after values")
        _sha256(case["restored_baseline_sha256"], "restored baseline")
        if case["rendered_before_sha256"] == case["rendered_after_sha256"]:
            raise EvidenceError("rendered switch values did not change")
        if case["restored_baseline_sha256"] != case["rendered_before_sha256"]:
            raise EvidenceError("restored switch baseline does not match its before rendering")
        observations = case["observations"]
        expected_observations = SWITCH_OBSERVATIONS[expected_id]
        if not isinstance(observations, list) or len(observations) != 3:
            raise EvidenceError("switch case must contain three closed observations")
        for expected_observation, observation_value in zip(expected_observations, observations):
            observation = _exact(observation_value, OBSERVATION_KEYS, "switch observation")
            if observation["id"] != expected_observation or observation["outcome"] != "passed":
                raise EvidenceError("switch observation is missing, failed, or out of order")
            _sha256(observation["observation_sha256"], "switch observation")
        if case["baseline_restored"] is not True:
            raise EvidenceError("switch baseline was not restored")
        validated.append(case)
    return validated


def _validate_invalid_combinations(value: Any) -> list[dict[str, Any]]:
    expected_ids = tuple(INVALID_CONTEXTS)
    if not isinstance(value, list) or len(value) != len(expected_ids):
        raise EvidenceError("invalid dependency evidence has the wrong case count")
    validated: list[dict[str, Any]] = []
    for expected_id, item in zip(expected_ids, value):
        case = _exact(item, INVALID_KEYS, "invalid dependency case")
        if case["id"] != expected_id:
            raise EvidenceError("invalid dependency cases are missing, duplicate, or out of order")
        if _feature_map(case["rendered_values"], "invalid rendered values") != INVALID_CONTEXTS[expected_id]:
            raise EvidenceError("invalid dependency case values changed")
        if case["target_environment"] != "production":
            raise EvidenceError("invalid dependency case is not a production fail-closed rendering")
        _sha256(case["rendered_values_sha256"], "invalid rendered values")
        if (
            case["validation_status"] != "rejected"
            or case["failure_code"] != "INVALID_FEATURE_DEPENDENCY"
            or case["deployment_attempted"] is not False
        ):
            raise EvidenceError("invalid feature dependencies did not fail closed before deployment")
        validated.append(case)
    return validated


def _validate_assertions(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(ASSERTION_IDS):
        raise EvidenceError("assertion list has the wrong closed count")
    validated: list[dict[str, Any]] = []
    for expected_id, item in zip(ASSERTION_IDS, value):
        assertion = _exact(item, ASSERTION_KEYS, "assertion")
        if assertion["id"] != expected_id or assertion["outcome"] != "passed":
            raise EvidenceError("assertions are missing, failed, or out of order")
        validated.append(assertion)
    return validated


def _validate_measurements(value: Any, expected: Mapping[str, int]) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(MEASUREMENT_IDS):
        raise EvidenceError("measurement list has the wrong closed count")
    validated: list[dict[str, Any]] = []
    for expected_id, item in zip(MEASUREMENT_IDS, value):
        measurement = _exact(item, MEASUREMENT_KEYS, "measurement")
        if measurement["id"] != expected_id:
            raise EvidenceError("measurements are missing, duplicate, or out of order")
        value_integer = _integer(measurement["value"], "measurement value")
        if value_integer != expected[expected_id]:
            raise EvidenceError("measurement does not match the closed evidence result")
        validated.append(measurement)
    return validated


def _validate_cleanup(value: Any) -> dict[str, Any]:
    cleanup = _exact(value, CLEANUP_KEYS, "cleanup")
    fixtures = _integer(
        cleanup["synthetic_fixture_count"], "synthetic fixture count", minimum=1, maximum=10_000
    )
    removed = _integer(
        cleanup["fixture_rows_removed"], "removed fixture row count", minimum=1, maximum=100_000
    )
    if removed < fixtures:
        raise EvidenceError("cleanup removed fewer rows than synthetic fixtures")
    _integer(
        cleanup["shared_rate_limit_buckets_removed"],
        "removed shared rate-limit bucket count",
        minimum=1,
        maximum=10_000,
    )
    if cleanup["provider_key_state_reconciled"] is not True or cleanup["baseline_restored"] is not True:
        raise EvidenceError("protected cleanup or baseline restoration is incomplete")
    _sha256(cleanup["cleanup_inventory_sha256"], "cleanup inventory")
    if cleanup["cleanup_failures"] != 0 or type(cleanup["cleanup_failures"]) is not int:
        raise EvidenceError("protected cleanup recorded a failure")
    return cleanup


def _validate_approvals(
    value: Any,
    subject_id: str,
    completed: dt.datetime,
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(APPROVER_ROLES):
        raise EvidenceError("owner approval list has the wrong closed count")
    validated: list[dict[str, Any]] = []
    audit_references: list[str] = []
    for expected_role, item in zip(APPROVER_ROLES, value):
        approval = _exact(item, APPROVAL_KEYS, "owner approval")
        if approval["role"] != expected_role or approval["decision"] != "approved":
            raise EvidenceError("owner approvals are missing, rejected, or out of order")
        if approval["approval_subject_id"] != subject_id:
            raise EvidenceError("owner approval does not bind the execution statement")
        approved = _utc(approval["approved_at"], "owner approval timestamp")
        if not completed <= approved <= completed + dt.timedelta(days=14):
            raise EvidenceError("owner approval is not a bounded post-run decision")
        audit_references.append(_sha256(
            approval["protected_audit_reference_sha256"],
            "protected owner approval audit reference",
        ))
        validated.append(approval)
    if len(set(audit_references)) != len(audit_references):
        raise EvidenceError("owner approvals must have distinct protected audit references")
    return validated


def _validate_expected(
    binding: Mapping[str, Any], run: Mapping[str, Any], expected: ExpectedBinding
) -> None:
    comparisons: tuple[tuple[str, Any, Any], ...] = (
        ("source revision", expected.source_revision, binding["source_revision"]),
        ("candidate ID", expected.candidate_id, binding["candidate_id"]),
        (
            "deployment evidence ID",
            expected.deployment_evidence_id,
            binding["deployment_evidence_id"],
        ),
        ("workflow run ID", expected.workflow_run_id, run["workflow_run_id"]),
        (
            "workflow run attempt",
            expected.workflow_run_attempt,
            run["workflow_run_attempt"],
        ),
        ("runner session ID", expected.runner_session_id, binding["runner_session_id"]),
        ("driver digest", expected.driver_sha256, binding["driver_sha256"]),
        ("validator digest", expected.validator_sha256, binding["validator_sha256"]),
        ("workflow digest", expected.workflow_sha256, binding["workflow_sha256"]),
    )
    for label, requested, observed in comparisons:
        if requested is not None and requested != observed:
            raise EvidenceError(f"evidence does not match the expected {label}")
    if expected.challenge is not None and challenge_sha256(expected.challenge) != run["challenge_sha256"]:
        raise EvidenceError("evidence does not match the expected workflow challenge")


def validate_evidence(
    value: Mapping[str, Any], *, expected: ExpectedBinding | None = None
) -> dict[str, Any]:
    root = _exact(value, ROOT_KEYS, "evidence root")
    _depth(root)
    if root["schema_version"] != SCHEMA_VERSION or type(root["schema_version"]) is not int:
        raise EvidenceError("evidence schema version is invalid")
    if root["classification"] != CLASSIFICATION:
        raise EvidenceError("evidence is not classified as protected staging production-gate evidence")

    binding = _validate_binding(root["binding"])
    run, _started, completed = _validate_run(root["run"])
    identity = _validate_identity(root["identity_rotation"], binding)
    library = _validate_library(root["library_replay"])
    comment = _validate_comment(root["comment_replay"])
    rate, accepted_requests = _validate_rate_limit(root["shared_rate_limit"])
    switches = _validate_switches(root["switches"])
    invalid = _validate_invalid_combinations(root["invalid_combinations"])
    assertions = _validate_assertions(root["assertions"])
    cleanup = _validate_cleanup(root["cleanup"])

    expected_measurements = {
        "assertions_passed": len(assertions),
        "assertions_failed": 0,
        "jwks_cache_ttl_seconds": identity["configured_cache_ttl_seconds"],
        "wait_after_old_key_removal_seconds": identity["wait_after_removal_seconds"],
        "old_key_token_remaining_lifetime_seconds_at_probe": identity[
            "old_key_token_remaining_lifetime_seconds_at_probe"
        ],
        "mobile_refresh_attempts": identity["mobile_expiry_refresh_attempts"],
        "mobile_refresh_successes": identity["mobile_expiry_refresh_successes"],
        "library_durable_operation_rows": library["durable_operation_rows"],
        "library_durable_side_effect_rows": library["durable_side_effect_rows"],
        "comment_durable_comment_rows": comment["durable_comment_rows"],
        "comment_durable_side_effect_rows": comment["durable_side_effect_rows"],
        "serving_replica_count": len(rate["replicas"]),
        "accepted_rate_limit_requests": accepted_requests,
        "rate_limit_quota": rate["quota_limit"],
        "rate_limit_window_seconds": rate["window_seconds"],
        "rate_limit_status": rate["limited_status"],
        "retry_after_seconds": rate["retry_after_seconds"],
        "switch_cases_passed": len(switches),
        "invalid_dependency_cases_rejected": len(invalid),
        "cleanup_failures": cleanup["cleanup_failures"],
    }
    _validate_measurements(root["measurements"], expected_measurements)

    subject_id = root["approval_subject_id"]
    if not isinstance(subject_id, str) or SUBJECT_ID_RE.fullmatch(subject_id) is None:
        raise EvidenceError("approval subject ID is invalid")
    if subject_id != compute_approval_subject_id(root):
        raise EvidenceError("approval subject ID does not match the execution statement")
    _validate_approvals(root["approvals"], subject_id, completed)

    if root["sanitization"] != SANITIZATION or any(
        root["sanitization"].get(key) is not False for key in SANITIZATION
    ):
        raise EvidenceError("sanitization exclusions are missing or not exact booleans")
    _reject_sensitive_shapes(root)

    content_id = root["content_id"]
    if not isinstance(content_id, str) or CONTENT_ID_RE.fullmatch(content_id) is None:
        raise EvidenceError("evidence content ID is invalid")
    if content_id != compute_content_id(root):
        raise EvidenceError("evidence content ID does not match its canonical statement")
    if expected is not None:
        _validate_expected(binding, run, expected)
    return root


def validate_file(
    path: pathlib.Path, *, expected: ExpectedBinding | None = None
) -> dict[str, Any]:
    return validate_evidence(_read_canonical(path), expected=expected)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate protected Pakperk service-exercise evidence."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate", help="validate one canonical evidence document")
    validate.add_argument("evidence", type=pathlib.Path)
    validate.add_argument("--source-revision")
    validate.add_argument("--candidate-id")
    validate.add_argument("--deployment-evidence-id")
    validate.add_argument("--workflow-run-id", type=int)
    validate.add_argument("--workflow-run-attempt", type=int)
    validate.add_argument("--challenge")
    validate.add_argument("--runner-session-id")
    validate.add_argument("--driver-sha256")
    validate.add_argument("--validator-sha256")
    validate.add_argument("--workflow-sha256")
    session = subparsers.add_parser(
        "validate-session",
        help="validate one root-owned protected runner-session attestation",
    )
    session.add_argument("attestation", type=pathlib.Path)
    session.add_argument("--session-id", required=True)
    session.add_argument("--source-revision", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "validate-session":
            validate_runner_session_file(
                arguments.attestation,
                session_id=arguments.session_id,
                source_revision=arguments.source_revision,
            )
            print(
                "Validated protected service runner session "
                f"{arguments.session_id}."
            )
            return 0
        expected = ExpectedBinding(
            source_revision=arguments.source_revision,
            candidate_id=arguments.candidate_id,
            deployment_evidence_id=arguments.deployment_evidence_id,
            workflow_run_id=arguments.workflow_run_id,
            workflow_run_attempt=arguments.workflow_run_attempt,
            challenge=arguments.challenge,
            runner_session_id=arguments.runner_session_id,
            driver_sha256=arguments.driver_sha256,
            validator_sha256=arguments.validator_sha256,
            workflow_sha256=arguments.workflow_sha256,
        )
        evidence = validate_file(arguments.evidence, expected=expected)
    except EvidenceError as error:
        print(f"protected service evidence invalid: {error}", file=sys.stderr)
        return 2
    print(f"Validated protected service exercise {evidence['content_id']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
