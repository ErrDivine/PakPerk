#!/usr/bin/env python3
"""Canonical data-only evidence for three protected operational release gates.

This module closes the repository-owned shape of migration, live telemetry, and
signed-mobile performance evidence.  It validates bounded statements emitted by
external protected producers; it does not run a migration, query a telemetry
provider, inspect a store account, approve a release, or manufacture those facts.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
from dataclasses import dataclass
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
BUNDLE_SCHEMA_VERSION = 1
MAX_DOCUMENT_BYTES = 256 * 1024
MAX_JSON_NESTING = 18
MAX_ARTIFACT_BYTES = 10 * 1024 * 1024 * 1024
CLASSIFICATION = "protected operational gate evidence"
BUNDLE_CLASSIFICATION = "protected operational gate evidence bundle"
BUNDLE_DOMAIN = b"pakperk/operational-gate-bundle/v1\0"
BUNDLE_CONTENT_PREFIX = "pakperk-operational-gates-v1:sha256:"
APPROVAL_SUBJECT_DOMAIN = b"pakperk/operational-gate-approval-subject/v1\0"
APPROVAL_SUBJECT_PREFIX = "pakperk-operational-approval-subject-v1:sha256:"
APPROVAL_MAX_DELAY_DAYS = 14

MIGRATION_GATE = "migration_expand_contract"
TELEMETRY_GATE = "live_telemetry_retention"
MOBILE_GATE = "mobile_performance_crash"
GATES = (MIGRATION_GATE, TELEMETRY_GATE, MOBILE_GATE)

CURRENT_DATABASE_MIGRATION = 10
PRIOR_DATABASE_MIGRATION = 9
TELEMETRY_RETENTION_DAYS = 30
TELEMETRY_PRE_EXPIRY_MIN_AGE_SECONDS = 29 * 86_400
TELEMETRY_POST_EXPIRY_MAX_AGE_SECONDS = 31 * 86_400
TELEMETRY_INITIAL_QUERY_MAX_AGE_SECONDS = 3_600
CACHED_FIRST_READABLE_FRAME_P95_MAX_MS = 1_500
OPENING_TRANSITION_MAX_MS = 700
SEQUENTIAL_CACHE_HIT_MIN_PERCENT = 95
CRASH_FREE_MIN_BASIS_POINTS = 9_950
MOBILE_OBSERVATION_WINDOW_MIN_SECONDS = 86_400
MOBILE_PERFORMANCE_SAMPLE_MIN = 20
MOBILE_CRASH_SESSION_MIN = 200

ALERT_POLICY_SHA256 = (
    "sha256:1b708d5d63988f0bbb26a6649633d1f1f5b096b0bd52338508142c9afb97140b"
)
ALERT_INPUT_IDS = (
    "application-otlp",
    "public-api-synthetic",
    "database-observer",
    "kubernetes-observer",
    "collector-observer",
    "kubernetes-redacted-logs",
)
ALERT_RULE_IDS = (
    "api-readiness-unavailable",
    "api-error-ratio-high",
    "api-latency-high",
    "database-pool-saturation",
    "paper-queue-age-high",
    "paper-terminal-failure-present",
    "deletion-queue-age-high",
    "deletion-terminal-failure",
    "moderation-report-triage-deadline",
    "authentication-recovery-failure",
    "collector-records-rejected",
    "collector-records-dropped",
    "collector-export-failures",
    "collector-node-agent-coverage",
    "telemetry-gateway-rejection-spike",
    "deletion-ledger-verification-failure",
    "deletion-ledger-capacity-high",
)

SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
DEPLOYMENT_ID_RE = re.compile(r"deployment-binding-v1:sha256:[0-9a-f]{64}\Z")
RESTORE_ID_RE = re.compile(r"pakperk-restore-evidence-v2:sha256:[0-9a-f]{64}\Z")
SOURCE_REVISION_RE = re.compile(r"[0-9a-f]{40}\Z")
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
VERSION_RE = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]{1,32})?\Z"
)
SAFE_TOOL_VERSION_RE = re.compile(
    r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){0,3}" r"(?:[-+][0-9A-Za-z.-]{1,32})?\Z"
)
EMAIL_RE = re.compile(r"[^@\s]{1,64}@[^@\s]{1,189}")
JWT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
    r"[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"
)
BEARER_RE = re.compile(r"(?i)\bbearer[ ]+[A-Za-z0-9._~+/-]{8,}")
PRIVATE_KEY_RE = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
PLACEHOLDER_WORD_RE = re.compile(
    r"(?i)(?:placeholder|pending|todo|tbd|example|dummy|fake|replace[-_ ]?me|not[-_ ]?run)"
)
PLACEHOLDER_DIGESTS = {
    hashlib.sha256(value.encode("ascii")).hexdigest()
    for value in ("placeholder", "pending", "todo", "example", "dummy", "fake", "test")
}

ROOT_KEYS = {
    "schema_version",
    "content_id",
    "approval_subject_id",
    "classification",
    "gate",
    "binding",
    "subject",
    "window",
    "artifacts",
    "assertions",
    "metrics",
    "cleanup",
    "approvals",
    "sanitization",
}
BINDING_KEYS = {
    "source_revision",
    "target_environment",
    "deployment_id",
    "candidate_id",
    "configuration_sha256",
    "tools",
}
TOOL_KEYS = {"role", "version", "sha256"}
WINDOW_KEYS = {"started_at", "completed_at"}
ARTIFACT_KEYS = {"id", "sha256", "size_bytes"}
ASSERTION_KEYS = {"id", "outcome"}
METRIC_KEYS = {"id", "value", "unit"}
CLEANUP_KEYS = {
    "outcome",
    "completed_at",
    "remaining_test_records",
    "protected_audit_reference",
}
APPROVAL_KEYS = {
    "role",
    "decision",
    "approved_at",
    "approval_subject_id",
    "protected_audit_reference",
}
BUNDLE_KEYS = {
    "schema_version",
    "content_id",
    "classification",
    "source_revision",
    "gates",
}
BUNDLE_GATE_KEYS = {"gate", "content_id"}
SANITIZATION = {
    "contains_credentials": False,
    "contains_tokens": False,
    "contains_cookies": False,
    "contains_personal_data": False,
    "contains_raw_logs": False,
    "contains_raw_telemetry": False,
    "contains_raw_crash_records": False,
    "contains_device_identifiers": False,
    "contains_network_addresses": False,
    "contains_user_content": False,
}


class EvidenceError(RuntimeError):
    """A closed evidence contract failed without echoing untrusted values."""


@dataclass(frozen=True)
class MetricSpec:
    unit: str
    minimum: int
    maximum: int


@dataclass(frozen=True)
class GateSpec:
    content_prefix: str
    content_domain: bytes
    target_environment: str
    tool_roles: tuple[str, ...]
    artifact_ids: tuple[str, ...]
    assertion_ids: tuple[str, ...]
    metrics: tuple[tuple[str, MetricSpec], ...]
    approval_roles: tuple[str, ...]
    minimum_window_seconds: int
    maximum_window_seconds: int


def _metric(unit: str, minimum: int, maximum: int) -> MetricSpec:
    return MetricSpec(unit=unit, minimum=minimum, maximum=maximum)


GATE_SPECS = {
    MIGRATION_GATE: GateSpec(
        content_prefix="pakperk-migration-exercise-v1:sha256:",
        content_domain=b"pakperk/operational-gate/migration-expand-contract/v1\0",
        target_environment="staging",
        tool_roles=("evidence_producer", "migration_driver"),
        artifact_ids=(
            "migration_job_result",
            "migration_job_log",
            "ddl_role_proof",
            "expand_compatibility_rollback_result",
            "data_integrity_result",
            "feature_switch_result",
        ),
        assertion_ids=(
            "backup_evidence_verified_before_migration",
            "reviewed_migration_image_and_embedded_version_bound",
            "additive_expand_migration_applied",
            "migration_job_completed_once",
            "ddl_executed_only_by_migration_role",
            "run_migrations_disabled_in_serving_workloads",
            "old_and_new_code_compatibility_exercised",
            "feature_switches_kept_dark_until_dependencies_passed",
            "six_feature_switch_states_reconciled",
            "data_integrity_before_and_after_verified",
            "schema_compatible_code_rollback_exercised",
            "destructive_down_migration_not_used",
            "contraction_deferred_until_compatibility_retention_and_backup",
            "final_schema_and_app_version_verified",
        ),
        metrics=(
            ("window_seconds", _metric("seconds", 1, 86_400)),
            ("migration_job_runs", _metric("count", 1, 1)),
            ("successful_migration_jobs", _metric("count", 1, 1)),
            ("failed_or_timed_out_migration_jobs", _metric("count", 0, 0)),
            ("ddl_role_violations", _metric("count", 0, 0)),
            ("serving_workloads_with_run_migrations", _metric("count", 0, 0)),
            ("compatibility_versions_exercised", _metric("count", 2, 64)),
            ("feature_switches_reconciled", _metric("count", 6, 6)),
            ("data_integrity_failures", _metric("count", 0, 0)),
            ("schema_compatible_code_rollbacks_exercised", _metric("count", 1, 1)),
            ("destructive_down_migrations", _metric("count", 0, 0)),
            ("unfinished_migration_jobs", _metric("count", 0, 0)),
        ),
        approval_roles=("database_owner", "release_owner"),
        minimum_window_seconds=1,
        maximum_window_seconds=86_400,
    ),
    TELEMETRY_GATE: GateSpec(
        content_prefix="pakperk-live-telemetry-v1:sha256:",
        content_domain=b"pakperk/operational-gate/live-telemetry-retention/v1\0",
        target_environment="production",
        tool_roles=("alert_adapter", "evidence_producer", "retention_probe"),
        artifact_ids=(
            "production_collector_gateway_adapter_inventory",
            "production_config_receiver_and_retention_result",
            "staging_canary_copy_inventory_and_parity_result",
            "production_safe_canary_and_live_sink_result",
            "staging_mobile_probe_and_live_sink_result",
            "production_retention_boundary_result",
            "staging_agent_restart_replay_and_coverage_result",
            "staging_page_and_ticket_canary_result",
        ),
        assertion_ids=(
            "production_collector_gateway_adapter_configuration_bound",
            "staging_canary_copy_configuration_bound",
            "staging_production_parity_reviewed_without_policy_weakening",
            "production_required_signal_inputs_and_alert_rules_enabled",
            "staging_required_signal_inputs_and_alert_rules_enabled",
            "production_receiver_ownership_verified",
            "staging_receiver_ownership_verified",
            "privacy_safe_production_canary_reached_production_sink",
            "staging_valid_mobile_probe_exported",
            "staging_hostile_mobile_probe_rejected",
            "staging_safe_canary_present_in_live_sink",
            "staging_protected_sentinels_absent_from_live_sink",
            "staging_protected_headers_content_identifiers_and_raw_diagnostics_absent",
            "production_retention_configured_exactly_thirty_days",
            "staging_retention_configured_exactly_thirty_days",
            "production_retention_canary_initially_observed",
            "production_retention_canary_present_before_expiry",
            "same_production_retention_canary_absent_after_thirty_days",
            "staging_agent_restart_recovered_checkpointed_record",
            "staging_restart_replay_volume_and_duplicates_recorded",
            "staging_node_agent_coverage_and_rotation_bounds_verified",
            "staging_page_canary_delivered",
            "staging_ticket_canary_delivered",
            "staging_collector_failure_alerts_observed_outside_failing_export_path",
        ),
        metrics=(
            ("window_seconds", _metric("seconds", 2_592_000, 7_776_000)),
            ("production_enabled_alert_rules", _metric("count", 17, 17)),
            ("production_required_signal_inputs", _metric("count", 6, 6)),
            ("staging_enabled_alert_rules", _metric("count", 17, 17)),
            ("staging_required_signal_inputs", _metric("count", 6, 6)),
            ("production_alert_rules_with_receiver", _metric("count", 17, 17)),
            ("staging_alert_rules_with_receiver", _metric("count", 17, 17)),
            (
                "production_notification_classes_with_receiver",
                _metric("count", 2, 2),
            ),
            (
                "staging_notification_classes_with_receiver",
                _metric("count", 2, 2),
            ),
            ("production_receivers_without_owner", _metric("count", 0, 0)),
            ("staging_receivers_without_owner", _metric("count", 0, 0)),
            ("production_safe_canaries_sent", _metric("count", 1, 1_000_000)),
            ("production_safe_canary_matches", _metric("count", 1, 1_000_000)),
            ("staging_valid_mobile_probes_exported", _metric("count", 1, 1_000_000)),
            ("staging_hostile_mobile_probes_attempted", _metric("count", 1, 1_000_000)),
            ("staging_hostile_mobile_probes_exported", _metric("count", 0, 0)),
            ("staging_safe_canary_matches", _metric("count", 1, 1_000_000)),
            ("staging_protected_sentinels_checked", _metric("count", 1, 1_000_000)),
            ("staging_protected_sentinel_matches", _metric("count", 0, 0)),
            ("production_retention_days", _metric("days", 30, 30)),
            ("staging_retention_days", _metric("days", 30, 30)),
            ("retention_canaries_seeded", _metric("count", 1, 1_000_000)),
            ("retention_initial_matches", _metric("count", 1, 1_000_000)),
            ("retention_pre_expiry_matches", _metric("count", 1, 1_000_000)),
            ("retention_post_expiry_matches", _metric("count", 0, 0)),
            (
                "retention_initial_query_age_seconds",
                _metric("seconds", 0, TELEMETRY_INITIAL_QUERY_MAX_AGE_SECONDS),
            ),
            (
                "retention_pre_expiry_query_age_seconds",
                _metric(
                    "seconds",
                    TELEMETRY_PRE_EXPIRY_MIN_AGE_SECONDS,
                    TELEMETRY_RETENTION_DAYS * 86_400 - 1,
                ),
            ),
            (
                "retention_post_expiry_query_age_seconds",
                _metric(
                    "seconds",
                    TELEMETRY_RETENTION_DAYS * 86_400,
                    TELEMETRY_POST_EXPIRY_MAX_AGE_SECONDS,
                ),
            ),
            ("staging_checkpointed_records_before_restart", _metric("count", 1, 1)),
            ("staging_recovered_checkpointed_records", _metric("count", 1, 1)),
            ("staging_replay_duplicates_observed", _metric("count", 0, 1_000_000)),
            ("staging_expected_node_agents", _metric("count", 1, 10_000)),
            ("staging_observed_node_agents", _metric("count", 1, 10_000)),
            ("staging_page_canary_successes", _metric("count", 1, 100)),
            ("staging_ticket_canary_successes", _metric("count", 1, 100)),
        ),
        approval_roles=("platform_owner", "observability_owner", "privacy_owner"),
        minimum_window_seconds=2_592_000,
        maximum_window_seconds=7_776_000,
    ),
    MOBILE_GATE: GateSpec(
        content_prefix="pakperk-mobile-performance-v1:sha256:",
        content_domain=b"pakperk/operational-gate/mobile-performance-crash/v1\0",
        target_environment="production",
        tool_roles=("crash_report_adapter", "evidence_producer", "performance_driver"),
        artifact_ids=(
            "signed_candidate_manifest",
            "reference_device_os_matrix",
            "startup_opening_samples",
            "sequential_cache_samples",
            "crash_source_query_or_store_report",
            "crash_denominator_privacy_review",
        ),
        assertion_ids=(
            "exact_signed_android_and_ios_candidate_bound",
            "named_reference_device_and_os_matrix_bound",
            "release_candidate_cold_and_warm_sample_window_recorded",
            "cached_first_readable_frame_p95_within_limit",
            "healthy_local_opening_transition_within_limit",
            "warm_cached_next_paper_has_no_blank_card",
            "sequential_next_paper_cache_hit_rate_at_least_ninety_five_percent",
            "frame_sample_count_and_window_recorded",
            "crash_denominator_is_aggregate_and_privacy_reviewed",
            "diagnostics_reports_bind_exact_candidate_version_and_build",
            "crash_free_sessions_at_least_ninety_nine_point_five_percent",
            "persistent_device_account_and_session_identifiers_not_added",
            "representative_observation_window_approved",
        ),
        metrics=(
            (
                "window_seconds",
                _metric(
                    "seconds",
                    MOBILE_OBSERVATION_WINDOW_MIN_SECONDS,
                    2_592_000,
                ),
            ),
            ("device_os_combinations", _metric("count", 2, 100)),
            (
                "cached_first_readable_frame_samples",
                _metric("count", MOBILE_PERFORMANCE_SAMPLE_MIN, 1_000_000),
            ),
            (
                "cached_first_readable_frame_p95_ms",
                _metric("milliseconds", 1, CACHED_FIRST_READABLE_FRAME_P95_MAX_MS),
            ),
            (
                "opening_transition_samples",
                _metric("count", MOBILE_PERFORMANCE_SAMPLE_MIN, 1_000_000),
            ),
            (
                "opening_transition_ms",
                _metric("milliseconds", 1, OPENING_TRANSITION_MAX_MS),
            ),
            (
                "sequential_cache_requests",
                _metric("count", MOBILE_PERFORMANCE_SAMPLE_MIN, 1_000_000_000),
            ),
            ("sequential_cache_hits", _metric("count", 0, 1_000_000_000)),
            ("warm_cached_blank_cards", _metric("count", 0, 0)),
            (
                "frame_samples",
                _metric("count", MOBILE_PERFORMANCE_SAMPLE_MIN, 1_000_000_000),
            ),
            (
                "observed_sessions",
                _metric("count", MOBILE_CRASH_SESSION_MIN, 2**63 - 1),
            ),
            ("crash_free_sessions", _metric("count", 0, 2**63 - 1)),
            ("crashed_sessions", _metric("count", 0, 2**63 - 1)),
            (
                "crash_free_basis_points",
                _metric("basis_points", CRASH_FREE_MIN_BASIS_POINTS, 10_000),
            ),
            ("diagnostics_sources", _metric("count", 2, 2)),
            ("persistent_identity_fields_added", _metric("count", 0, 0)),
        ),
        approval_roles=("mobile_qa_owner", "release_owner", "privacy_owner"),
        minimum_window_seconds=MOBILE_OBSERVATION_WINDOW_MIN_SECONDS,
        maximum_window_seconds=2_592_000,
    ),
}

MIGRATION_SUBJECT_KEYS = {
    "migration_image_digest",
    "backup_evidence_id",
    "starting_schema_version",
    "ending_schema_version",
    "embedded_migration_version",
    "starting_app_version",
    "ending_app_version",
    "resolution_path",
}
TELEMETRY_SUBJECT_KEYS = {
    "production",
    "staging_canary",
    "production_retention_canary",
    "staging_production_parity_review_sha256",
}
TELEMETRY_ENVIRONMENT_KEYS = {
    "environment",
    "deployment_id",
    "release_configuration_sha256",
    "collector_image_digest",
    "telemetry_gateway_image_digest",
    "platform_adapter_image_digest",
    "collector_configuration_sha256",
    "telemetry_gateway_configuration_sha256",
    "platform_adapter_configuration_sha256",
    "redaction_policy_sha256",
    "alert_policy_sha256",
    "enabled_input_ids",
    "enabled_rule_ids",
    "receiver_inventory_sha256",
    "retention_policy_sha256",
    "retention_days",
}
TELEMETRY_RETENTION_CANARY_KEYS = {
    "commitment_inventory_sha256",
    "commitment_count",
    "seeded_at",
    "initial_query_at",
    "pre_expiry_query_at",
    "post_expiry_query_at",
}
MOBILE_SUBJECT_KEYS = {
    "mobile_version",
    "build_number",
    "android_apk_sha256",
    "ios_ipa_sha256",
    "android_application_id",
    "ios_application_id",
    "diagnostics_sources",
    "distribution_scope",
}


def _canonical_json(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("ascii")
    except (TypeError, ValueError) as error:
        raise EvidenceError("evidence is not canonical JSON data") from error


def encode_canonical_document(value: Any) -> bytes:
    """Return the only accepted on-disk representation."""

    return _canonical_json(value) + b"\n"


def _statement(document: Mapping[str, Any]) -> dict[str, Any]:
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


def compute_evidence_content_id(document: Mapping[str, Any]) -> str:
    gate = document.get("gate")
    if not isinstance(gate, str) or gate not in GATE_SPECS:
        raise EvidenceError("evidence gate is invalid")
    spec = GATE_SPECS[gate]
    digest = hashlib.sha256(
        spec.content_domain + _canonical_json(_statement(document))
    ).hexdigest()
    return f"{spec.content_prefix}{digest}"


def compute_approval_subject_id(document: Mapping[str, Any]) -> str:
    gate = document.get("gate")
    if not isinstance(gate, str) or gate not in GATE_SPECS:
        raise EvidenceError("evidence gate is invalid")
    spec = GATE_SPECS[gate]
    digest = hashlib.sha256(
        APPROVAL_SUBJECT_DOMAIN
        + spec.content_domain
        + _canonical_json(_approval_statement(document))
    ).hexdigest()
    return f"{APPROVAL_SUBJECT_PREFIX}{digest}"


def compute_bundle_content_id(document: Mapping[str, Any]) -> str:
    digest = hashlib.sha256(
        BUNDLE_DOMAIN + _canonical_json(_statement(document))
    ).hexdigest()
    return f"{BUNDLE_CONTENT_PREFIX}{digest}"


def _exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise EvidenceError(f"{label} does not match its closed key contract")
    return value


def _duplicate_rejecting_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("JSON contains a duplicate object key")
        result[key] = value
    return result


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


def _read_bounded(path: pathlib.Path) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        before = path.lstat()
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceError("evidence file cannot be opened safely") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or (before.st_dev, before.st_ino) != (metadata.st_dev, metadata.st_ino)
            or metadata.st_nlink != 1
            or metadata.st_uid not in {0, os.geteuid()}
            or metadata.st_mode & 0o022
            or metadata.st_size <= 0
            or metadata.st_size > MAX_DOCUMENT_BYTES
        ):
            raise EvidenceError("evidence file is not a bounded regular file")
        data = bytearray()
        while len(data) <= MAX_DOCUMENT_BYTES:
            chunk = os.read(
                descriptor,
                min(64 * 1024, MAX_DOCUMENT_BYTES + 1 - len(data)),
            )
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > MAX_DOCUMENT_BYTES:
            raise EvidenceError("evidence file exceeds its maximum size")
        after = os.fstat(descriptor)
        if (
            after.st_size != metadata.st_size
            or after.st_mtime_ns != metadata.st_mtime_ns
            or after.st_ctime_ns != metadata.st_ctime_ns
        ):
            raise EvidenceError("evidence file changed while read")
        return bytes(data)
    finally:
        os.close(descriptor)


def _read_canonical(path: pathlib.Path) -> dict[str, Any]:
    data = _read_bounded(path)
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_constant,
        )
    except EvidenceError:
        raise
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise EvidenceError("evidence file is not valid JSON") from error
    _depth(value)
    if not isinstance(value, dict):
        raise EvidenceError("evidence root must be an object")
    if data != encode_canonical_document(value):
        raise EvidenceError("evidence file is not in canonical JSON form")
    return value


def _parse_utc(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a canonical UTC timestamp")
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as error:
        raise EvidenceError(f"{label} is not a valid UTC timestamp") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise EvidenceError(f"{label} is not canonical")
    return parsed


def _is_placeholder_hex(payload: str) -> bool:
    return len(set(payload)) == 1 or payload in PLACEHOLDER_DIGESTS


def _digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a sha256 content identifier")
    if _is_placeholder_hex(value.removeprefix("sha256:")):
        raise EvidenceError(f"{label} is an obvious placeholder digest")
    return value


def _prefixed_digest(value: Any, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a canonical content identifier")
    payload = value.rsplit(":", 1)[1]
    if _is_placeholder_hex(payload):
        raise EvidenceError(f"{label} is an obvious placeholder digest")
    return value


def _positive_int(
    value: Any,
    label: str,
    *,
    minimum: int = 1,
    maximum: int = 2**63 - 1,
) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise EvidenceError(f"{label} is outside its integer boundary")
    return value


def _version(value: Any, label: str) -> str:
    if not isinstance(value, str) or VERSION_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not an exact release version")
    return value


def _validate_binding(value: Any, spec: GateSpec) -> dict[str, Any]:
    binding = _exact_keys(value, BINDING_KEYS, "binding")
    revision = binding["source_revision"]
    if (
        not isinstance(revision, str)
        or SOURCE_REVISION_RE.fullmatch(revision) is None
        or len(set(revision)) == 1
    ):
        raise EvidenceError("binding source revision is invalid or placeholder")
    if binding["target_environment"] != spec.target_environment:
        raise EvidenceError("binding target environment is invalid for the gate")
    _prefixed_digest(binding["deployment_id"], DEPLOYMENT_ID_RE, "deployment ID")
    _digest(binding["candidate_id"], "candidate ID")
    _digest(binding["configuration_sha256"], "configuration digest")
    tools = binding["tools"]
    if not isinstance(tools, list) or len(tools) != len(spec.tool_roles):
        raise EvidenceError("binding tools do not match the exact gate contract")
    roles: list[str] = []
    for index, expected_role in enumerate(spec.tool_roles):
        tool = _exact_keys(tools[index], TOOL_KEYS, "binding tool")
        if tool["role"] != expected_role:
            raise EvidenceError("binding tool order or role is invalid")
        version = tool["version"]
        if (
            not isinstance(version, str)
            or SAFE_TOOL_VERSION_RE.fullmatch(version) is None
            or PLACEHOLDER_WORD_RE.search(version)
        ):
            raise EvidenceError("binding tool version is invalid or placeholder")
        _digest(tool["sha256"], "binding tool digest")
        roles.append(expected_role)
    if len(set(roles)) != len(roles):
        raise EvidenceError("binding tool roles are not distinct")
    return copy.deepcopy(binding)


def _validate_telemetry_environment(
    value: Any,
    *,
    expected_environment: str,
) -> dict[str, Any]:
    environment = _exact_keys(
        value,
        TELEMETRY_ENVIRONMENT_KEYS,
        f"{expected_environment} telemetry environment",
    )
    if environment["environment"] != expected_environment:
        raise EvidenceError("telemetry environment identity is invalid")
    _prefixed_digest(
        environment["deployment_id"],
        DEPLOYMENT_ID_RE,
        f"{expected_environment} telemetry deployment ID",
    )
    for key in (
        "release_configuration_sha256",
        "collector_image_digest",
        "telemetry_gateway_image_digest",
        "platform_adapter_image_digest",
        "collector_configuration_sha256",
        "telemetry_gateway_configuration_sha256",
        "platform_adapter_configuration_sha256",
        "redaction_policy_sha256",
        "alert_policy_sha256",
        "receiver_inventory_sha256",
        "retention_policy_sha256",
    ):
        _digest(environment[key], f"{expected_environment} telemetry {key}")
    if environment["enabled_input_ids"] != list(ALERT_INPUT_IDS):
        raise EvidenceError(
            f"{expected_environment} telemetry signal inputs are incomplete or reordered"
        )
    if environment["enabled_rule_ids"] != list(ALERT_RULE_IDS):
        raise EvidenceError(
            f"{expected_environment} telemetry alert rules are incomplete or reordered"
        )
    if (
        type(environment["retention_days"]) is not int
        or environment["retention_days"] != TELEMETRY_RETENTION_DAYS
    ):
        raise EvidenceError(
            f"{expected_environment} telemetry retention must be exactly thirty days"
        )
    return copy.deepcopy(environment)


def _validate_subject(gate: str, value: Any) -> dict[str, Any]:
    if gate == MIGRATION_GATE:
        subject = _exact_keys(value, MIGRATION_SUBJECT_KEYS, "migration subject")
        _digest(subject["migration_image_digest"], "migration image digest")
        _prefixed_digest(
            subject["backup_evidence_id"], RESTORE_ID_RE, "backup evidence ID"
        )
        if (
            type(subject["starting_schema_version"]) is not int
            or subject["starting_schema_version"] != PRIOR_DATABASE_MIGRATION
            or type(subject["ending_schema_version"]) is not int
            or subject["ending_schema_version"] != CURRENT_DATABASE_MIGRATION
            or type(subject["embedded_migration_version"]) is not int
            or subject["embedded_migration_version"] != CURRENT_DATABASE_MIGRATION
        ):
            raise EvidenceError(
                "migration subject does not bind the exact 9-to-10 path"
            )
        starting_app = _version(
            subject["starting_app_version"], "starting application version"
        )
        ending_app = _version(
            subject["ending_app_version"], "ending application version"
        )
        if starting_app == ending_app:
            raise EvidenceError("migration exercise must bind distinct app versions")
        if subject["resolution_path"] != "schema_compatible_code_rollback":
            raise EvidenceError(
                "the additive 9-to-10 release gate requires a schema-compatible "
                "code rollback exercise"
            )
        return copy.deepcopy(subject)

    if gate == TELEMETRY_GATE:
        subject = _exact_keys(value, TELEMETRY_SUBJECT_KEYS, "telemetry subject")
        production = _validate_telemetry_environment(
            subject["production"], expected_environment="production"
        )
        staging = _validate_telemetry_environment(
            subject["staging_canary"], expected_environment="staging"
        )
        if production["deployment_id"] == staging["deployment_id"]:
            raise EvidenceError(
                "production and staging telemetry deployments are not distinct"
            )
        if production["alert_policy_sha256"] != ALERT_POLICY_SHA256:
            raise EvidenceError(
                "production telemetry alert policy does not match the reviewed contract"
            )
        if staging["alert_policy_sha256"] == production["alert_policy_sha256"]:
            raise EvidenceError(
                "staging canary policy must have a distinct environment-filtered identity"
            )
        for key in (
            "collector_image_digest",
            "telemetry_gateway_image_digest",
            "platform_adapter_image_digest",
        ):
            if production[key] != staging[key]:
                raise EvidenceError(
                    "production and staging canary images do not bind one candidate"
                )
        for key in (
            "release_configuration_sha256",
            "collector_configuration_sha256",
            "telemetry_gateway_configuration_sha256",
            "platform_adapter_configuration_sha256",
            "alert_policy_sha256",
            "receiver_inventory_sha256",
            "retention_policy_sha256",
        ):
            if production[key] == staging[key]:
                raise EvidenceError(
                    "production and staging environment identities are not distinct"
                )
        parity_digest = _digest(
            subject["staging_production_parity_review_sha256"],
            "staging and production telemetry parity review",
        )
        environment_identity_keys = (
            "release_configuration_sha256",
            "collector_image_digest",
            "telemetry_gateway_image_digest",
            "platform_adapter_image_digest",
            "collector_configuration_sha256",
            "telemetry_gateway_configuration_sha256",
            "platform_adapter_configuration_sha256",
            "redaction_policy_sha256",
            "alert_policy_sha256",
            "receiver_inventory_sha256",
            "retention_policy_sha256",
        )
        if parity_digest in {
            environment[key]
            for environment in (production, staging)
            for key in environment_identity_keys
        }:
            raise EvidenceError(
                "telemetry parity review must have an independent identity"
            )
        retention = _exact_keys(
            subject["production_retention_canary"],
            TELEMETRY_RETENTION_CANARY_KEYS,
            "production retention canary",
        )
        commitment_inventory = _digest(
            retention["commitment_inventory_sha256"],
            "production retention canary commitment inventory",
        )
        if commitment_inventory == parity_digest or commitment_inventory in {
            environment[key]
            for environment in (production, staging)
            for key in environment_identity_keys
        }:
            raise EvidenceError(
                "retention canary inventory must have an independent identity"
            )
        _positive_int(
            retention["commitment_count"],
            "production retention canary commitment count",
            maximum=1_000_000,
        )
        seeded_at = _parse_utc(retention["seeded_at"], "retention canary seed")
        initial_at = _parse_utc(
            retention["initial_query_at"], "retention initial query"
        )
        pre_expiry_at = _parse_utc(
            retention["pre_expiry_query_at"], "retention pre-expiry query"
        )
        post_expiry_at = _parse_utc(
            retention["post_expiry_query_at"], "retention post-expiry query"
        )
        if not seeded_at <= initial_at < pre_expiry_at < post_expiry_at:
            raise EvidenceError("production retention canary chronology is invalid")
        return copy.deepcopy(subject)

    if gate == MOBILE_GATE:
        subject = _exact_keys(value, MOBILE_SUBJECT_KEYS, "mobile subject")
        _version(subject["mobile_version"], "mobile version")
        _positive_int(subject["build_number"], "mobile build number", maximum=2**31 - 1)
        _digest(subject["android_apk_sha256"], "Android APK digest")
        _digest(subject["ios_ipa_sha256"], "iOS IPA digest")
        if subject["android_application_id"] != "app.pakperk.pakperk":
            raise EvidenceError("mobile Android application ID is invalid")
        if subject["ios_application_id"] != "app.pakperk.pakperk":
            raise EvidenceError("mobile iOS application ID is invalid")
        if subject["diagnostics_sources"] != [
            "app_store_connect",
            "google_play_console",
        ]:
            raise EvidenceError(
                "mobile diagnostics sources are incomplete or reordered"
            )
        if subject["distribution_scope"] != "testflight_and_closed_play":
            raise EvidenceError("mobile distribution scope is invalid")
        return copy.deepcopy(subject)

    raise EvidenceError("evidence gate is invalid")


def _validate_window(
    value: Any, spec: GateSpec
) -> tuple[dict[str, Any], int, dt.datetime]:
    window = _exact_keys(value, WINDOW_KEYS, "observation window")
    started_at = _parse_utc(window["started_at"], "window start")
    completed_at = _parse_utc(window["completed_at"], "window completion")
    seconds = int((completed_at - started_at).total_seconds())
    if not spec.minimum_window_seconds <= seconds <= spec.maximum_window_seconds:
        raise EvidenceError("observation window is outside the gate boundary")
    return copy.deepcopy(window), seconds, completed_at


def _validate_artifacts(value: Any, spec: GateSpec) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(spec.artifact_ids):
        raise EvidenceError("gate artifacts are incomplete")
    validated: list[dict[str, Any]] = []
    for index, expected_id in enumerate(spec.artifact_ids):
        artifact = _exact_keys(value[index], ARTIFACT_KEYS, "gate artifact")
        if artifact["id"] != expected_id:
            raise EvidenceError("gate artifacts are missing or reordered")
        _digest(artifact["sha256"], "gate artifact digest")
        _positive_int(
            artifact["size_bytes"],
            "gate artifact size",
            maximum=MAX_ARTIFACT_BYTES,
        )
        validated.append(copy.deepcopy(artifact))
    return validated


def _validate_assertions(value: Any, spec: GateSpec) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(spec.assertion_ids):
        raise EvidenceError("gate assertion evidence is incomplete")
    validated: list[dict[str, Any]] = []
    for index, expected_id in enumerate(spec.assertion_ids):
        assertion = _exact_keys(value[index], ASSERTION_KEYS, "gate assertion")
        if assertion != {"id": expected_id, "outcome": "passed"}:
            raise EvidenceError("gate assertion failed, is missing, or is reordered")
        validated.append(copy.deepcopy(assertion))
    return validated


def _metric_map(value: Any, spec: GateSpec) -> dict[str, int]:
    if not isinstance(value, list) or len(value) != len(spec.metrics):
        raise EvidenceError("gate metric evidence is incomplete")
    result: dict[str, int] = {}
    for index, (expected_id, metric_spec) in enumerate(spec.metrics):
        metric = _exact_keys(value[index], METRIC_KEYS, "gate metric")
        if metric["id"] != expected_id or metric["unit"] != metric_spec.unit:
            raise EvidenceError(
                "gate metrics are missing, reordered, or use wrong units"
            )
        measured = metric["value"]
        if (
            type(measured) is not int
            or not metric_spec.minimum <= measured <= metric_spec.maximum
        ):
            raise EvidenceError("gate metric is outside its closed integer boundary")
        result[expected_id] = measured
    return result


def _validate_metric_relations(
    gate: str,
    metrics: Mapping[str, int],
    subject: Mapping[str, Any],
    window: Mapping[str, Any],
    window_seconds: int,
) -> None:
    if metrics["window_seconds"] != window_seconds:
        raise EvidenceError("gate window metric does not match UTC timestamps")
    if gate == MIGRATION_GATE:
        if metrics["migration_job_runs"] != (
            metrics["successful_migration_jobs"]
            + metrics["failed_or_timed_out_migration_jobs"]
        ):
            raise EvidenceError("migration job outcome counts do not reconcile")
        return
    if gate == TELEMETRY_GATE:
        production = subject["production"]
        staging = subject["staging_canary"]
        retention = subject["production_retention_canary"]
        seeded_at = _parse_utc(retention["seeded_at"], "retention canary seed")
        initial_at = _parse_utc(
            retention["initial_query_at"], "retention initial query"
        )
        pre_expiry_at = _parse_utc(
            retention["pre_expiry_query_at"], "retention pre-expiry query"
        )
        post_expiry_at = _parse_utc(
            retention["post_expiry_query_at"], "retention post-expiry query"
        )
        initial_age = int((initial_at - seeded_at).total_seconds())
        pre_expiry_age = int((pre_expiry_at - seeded_at).total_seconds())
        post_expiry_age = int((post_expiry_at - seeded_at).total_seconds())
        seeded = metrics["retention_canaries_seeded"]
        if (
            metrics["production_enabled_alert_rules"]
            != len(production["enabled_rule_ids"])
            or metrics["production_required_signal_inputs"]
            != len(production["enabled_input_ids"])
            or metrics["staging_enabled_alert_rules"]
            != len(staging["enabled_rule_ids"])
            or metrics["staging_required_signal_inputs"]
            != len(staging["enabled_input_ids"])
            or metrics["production_alert_rules_with_receiver"]
            != len(production["enabled_rule_ids"])
            or metrics["staging_alert_rules_with_receiver"]
            != len(staging["enabled_rule_ids"])
            or metrics["production_retention_days"] != production["retention_days"]
            or metrics["staging_retention_days"] != staging["retention_days"]
            or metrics["production_safe_canary_matches"]
            != metrics["production_safe_canaries_sent"]
            or retention["commitment_count"] != seeded
            or metrics["retention_initial_matches"] != seeded
            or metrics["retention_pre_expiry_matches"] != seeded
            or metrics["retention_initial_query_age_seconds"] != initial_age
            or metrics["retention_pre_expiry_query_age_seconds"] != pre_expiry_age
            or metrics["retention_post_expiry_query_age_seconds"] != post_expiry_age
            or _parse_utc(window["started_at"], "window start") != seeded_at
            or _parse_utc(window["completed_at"], "window completion") != post_expiry_at
            or metrics["staging_recovered_checkpointed_records"]
            != metrics["staging_checkpointed_records_before_restart"]
            or metrics["staging_observed_node_agents"]
            != metrics["staging_expected_node_agents"]
        ):
            raise EvidenceError(
                "telemetry counts do not reconcile with the bound contract"
            )
        return
    if gate == MOBILE_GATE:
        requests = metrics["sequential_cache_requests"]
        hits = metrics["sequential_cache_hits"]
        if hits > requests or hits * 100 < requests * SEQUENTIAL_CACHE_HIT_MIN_PERCENT:
            raise EvidenceError(
                "sequential cache hit rate is below the release threshold"
            )
        observed = metrics["observed_sessions"]
        crash_free = metrics["crash_free_sessions"]
        crashed = metrics["crashed_sessions"]
        if crash_free + crashed != observed:
            raise EvidenceError("mobile crash denominator counts do not reconcile")
        basis_points = crash_free * 10_000 // observed
        if metrics["crash_free_basis_points"] != basis_points:
            raise EvidenceError(
                "mobile crash-free metric does not match its denominator"
            )
        if metrics["diagnostics_sources"] != len(subject["diagnostics_sources"]):
            raise EvidenceError("mobile diagnostics source count does not reconcile")
        return
    raise EvidenceError("evidence gate is invalid")


def _validate_cleanup(
    value: Any, completed_at: dt.datetime
) -> tuple[dict[str, Any], dt.datetime]:
    cleanup = _exact_keys(value, CLEANUP_KEYS, "cleanup")
    if cleanup["outcome"] != "completed":
        raise EvidenceError("protected exercise cleanup did not complete")
    cleanup_at = _parse_utc(cleanup["completed_at"], "cleanup completion")
    if cleanup_at < completed_at:
        raise EvidenceError("cleanup completed before the observation window")
    if (
        type(cleanup["remaining_test_records"]) is not int
        or cleanup["remaining_test_records"] != 0
    ):
        raise EvidenceError("protected exercise cleanup left test records")
    _digest(cleanup["protected_audit_reference"], "cleanup audit reference")
    return copy.deepcopy(cleanup), cleanup_at


def _validate_approvals(
    value: Any,
    spec: GateSpec,
    cleanup_at: dt.datetime,
    approval_subject_id: str,
    cleanup_reference: str,
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(spec.approval_roles):
        raise EvidenceError("gate owner approvals are incomplete")
    references: list[str] = []
    validated: list[dict[str, Any]] = []
    for index, expected_role in enumerate(spec.approval_roles):
        approval = _exact_keys(value[index], APPROVAL_KEYS, "gate approval")
        if approval["role"] != expected_role or approval["decision"] != "approved":
            raise EvidenceError("gate approval role, order, or decision is invalid")
        if approval["approval_subject_id"] != approval_subject_id:
            raise EvidenceError("gate approval does not bind the execution statement")
        approved_at = _parse_utc(approval["approved_at"], "gate approval time")
        if (
            not cleanup_at
            <= approved_at
            <= cleanup_at + dt.timedelta(days=APPROVAL_MAX_DELAY_DAYS)
        ):
            raise EvidenceError("gate approval is not a bounded post-run decision")
        reference = _digest(
            approval["protected_audit_reference"], "gate approval audit reference"
        )
        if reference == cleanup_reference:
            raise EvidenceError("gate approval reuses the cleanup audit reference")
        references.append(reference)
        validated.append(copy.deepcopy(approval))
    if len(set(references)) != len(references):
        raise EvidenceError("gate approval audit references are not distinct")
    return validated


def _validate_sanitization(value: Any) -> None:
    if (
        not isinstance(value, dict)
        or set(value) != set(SANITIZATION)
        or any(value[key] is not False for key in SANITIZATION)
    ):
        raise EvidenceError("sanitization exclusions are incomplete")


def _reject_sensitive_shapes(value: Mapping[str, Any]) -> None:
    encoded = _canonical_json(value).decode("ascii")
    if (
        EMAIL_RE.search(encoded)
        or JWT_RE.search(encoded)
        or BEARER_RE.search(encoded)
        or PRIVATE_KEY_RE.search(encoded)
    ):
        raise EvidenceError(
            "evidence contains credential or personal-data shaped content"
        )


def _validate_content_id(value: Any, gate: str) -> str:
    spec = GATE_SPECS[gate]
    pattern = re.compile(re.escape(spec.content_prefix) + r"[0-9a-f]{64}\Z")
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise EvidenceError("evidence content ID is invalid for the gate domain")
    if _is_placeholder_hex(value.rsplit(":", 1)[1]):
        raise EvidenceError("evidence content ID is an obvious placeholder")
    return value


def _validate_approval_subject_id(value: Any) -> str:
    pattern = re.compile(re.escape(APPROVAL_SUBJECT_PREFIX) + r"[0-9a-f]{64}\Z")
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise EvidenceError("approval subject ID is invalid")
    if _is_placeholder_hex(value.rsplit(":", 1)[1]):
        raise EvidenceError("approval subject ID is an obvious placeholder")
    return value


def validate_evidence(
    value: Any,
    *,
    expected_gate: str | None = None,
    expected_content_id: str | None = None,
    expected_binding: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    root = _exact_keys(value, ROOT_KEYS, "evidence root")
    if (
        type(root["schema_version"]) is not int
        or root["schema_version"] != SCHEMA_VERSION
    ):
        raise EvidenceError("evidence schema version is invalid")
    if root["classification"] != CLASSIFICATION:
        raise EvidenceError(
            "reference or unprotected evidence classification is forbidden"
        )
    gate = root["gate"]
    if not isinstance(gate, str) or gate not in GATE_SPECS:
        raise EvidenceError("evidence gate is invalid")
    if expected_gate is not None and gate != expected_gate:
        raise EvidenceError("evidence gate does not match the expected gate")
    spec = GATE_SPECS[gate]
    validated_binding = _validate_binding(root["binding"], spec)
    if expected_binding is not None and validated_binding != _validate_binding(
        expected_binding, spec
    ):
        raise EvidenceError("evidence binding does not match the expected release")
    subject = _validate_subject(gate, root["subject"])
    if gate == TELEMETRY_GATE and (
        subject["production"]["deployment_id"] != validated_binding["deployment_id"]
        or subject["production"]["release_configuration_sha256"]
        != validated_binding["configuration_sha256"]
    ):
        raise EvidenceError(
            "production telemetry identities do not match the expected binding"
        )
    window, window_seconds, completed_at = _validate_window(root["window"], spec)
    _validate_artifacts(root["artifacts"], spec)
    _validate_assertions(root["assertions"], spec)
    metrics = _metric_map(root["metrics"], spec)
    _validate_metric_relations(gate, metrics, subject, window, window_seconds)
    cleanup, cleanup_at = _validate_cleanup(root["cleanup"], completed_at)
    approval_subject_id = _validate_approval_subject_id(root["approval_subject_id"])
    if approval_subject_id != compute_approval_subject_id(root):
        raise EvidenceError(
            "approval subject ID does not match the execution statement"
        )
    _validate_approvals(
        root["approvals"],
        spec,
        cleanup_at,
        approval_subject_id,
        cleanup["protected_audit_reference"],
    )
    _validate_sanitization(root["sanitization"])
    _reject_sensitive_shapes(root)
    actual_id = _validate_content_id(root["content_id"], gate)
    computed_id = compute_evidence_content_id(root)
    if actual_id != computed_id:
        raise EvidenceError(
            "evidence content ID does not match its canonical statement"
        )
    if expected_content_id is not None and actual_id != _validate_content_id(
        expected_content_id, gate
    ):
        raise EvidenceError("evidence content ID does not match the expected ID")
    return copy.deepcopy(root)


def read_evidence(
    path: pathlib.Path,
    *,
    expected_gate: str | None = None,
    expected_content_id: str | None = None,
    expected_binding: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    return validate_evidence(
        _read_canonical(path),
        expected_gate=expected_gate,
        expected_content_id=expected_content_id,
        expected_binding=expected_binding,
    )


def _build_execution_statement(
    gate: str,
    binding: Mapping[str, Any],
    subject: Mapping[str, Any],
    *,
    started_at: str,
    completed_at: str,
    artifacts: Mapping[str, tuple[str, int]],
    assertion_outcomes: Mapping[str, str],
    metrics: Mapping[str, int],
    cleanup: Mapping[str, Any],
) -> dict[str, Any]:
    if gate not in GATE_SPECS:
        raise EvidenceError("evidence gate is invalid")
    spec = GATE_SPECS[gate]
    if set(artifacts) != set(spec.artifact_ids):
        raise EvidenceError("gate artifact inputs are incomplete")
    if set(assertion_outcomes) != set(spec.assertion_ids):
        raise EvidenceError("gate assertion inputs are incomplete")
    if set(metrics) != {metric_id for metric_id, _ in spec.metrics}:
        raise EvidenceError("gate metric inputs are incomplete")
    return {
        "schema_version": SCHEMA_VERSION,
        "classification": CLASSIFICATION,
        "gate": gate,
        "binding": copy.deepcopy(dict(binding)),
        "subject": copy.deepcopy(dict(subject)),
        "window": {"started_at": started_at, "completed_at": completed_at},
        "artifacts": [
            {
                "id": artifact_id,
                "sha256": artifacts[artifact_id][0],
                "size_bytes": artifacts[artifact_id][1],
            }
            for artifact_id in spec.artifact_ids
        ],
        "assertions": [
            {"id": assertion_id, "outcome": assertion_outcomes[assertion_id]}
            for assertion_id in spec.assertion_ids
        ],
        "metrics": [
            {
                "id": metric_id,
                "value": metrics[metric_id],
                "unit": metric_spec.unit,
            }
            for metric_id, metric_spec in spec.metrics
        ],
        "cleanup": copy.deepcopy(dict(cleanup)),
        "sanitization": dict(SANITIZATION),
    }


def build_approval_subject_id(
    gate: str,
    binding: Mapping[str, Any],
    subject: Mapping[str, Any],
    *,
    started_at: str,
    completed_at: str,
    artifacts: Mapping[str, tuple[str, int]],
    assertion_outcomes: Mapping[str, str],
    metrics: Mapping[str, int],
    cleanup: Mapping[str, Any],
) -> str:
    """Build the exact stable subject that protected owners must approve."""

    statement = _build_execution_statement(
        gate,
        binding,
        subject,
        started_at=started_at,
        completed_at=completed_at,
        artifacts=artifacts,
        assertion_outcomes=assertion_outcomes,
        metrics=metrics,
        cleanup=cleanup,
    )
    return compute_approval_subject_id(statement)


def build_evidence(
    gate: str,
    binding: Mapping[str, Any],
    subject: Mapping[str, Any],
    *,
    started_at: str,
    completed_at: str,
    artifacts: Mapping[str, tuple[str, int]],
    assertion_outcomes: Mapping[str, str],
    metrics: Mapping[str, int],
    cleanup: Mapping[str, Any],
    approvals: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Seal an explicit protected producer statement after full validation.

    Callers must first compute the approval subject, obtain every approval
    against that exact ID, and supply every assertion outcome and measured
    value. This helper only canonicalizes and self-addresses those statements;
    it never observes the systems or manufactures an approval.
    """

    statement = _build_execution_statement(
        gate,
        binding,
        subject,
        started_at=started_at,
        completed_at=completed_at,
        artifacts=artifacts,
        assertion_outcomes=assertion_outcomes,
        metrics=metrics,
        cleanup=cleanup,
    )
    document = dict(statement)
    document["approval_subject_id"] = compute_approval_subject_id(document)
    document["approvals"] = [copy.deepcopy(dict(approval)) for approval in approvals]
    document["content_id"] = compute_evidence_content_id(document)
    return validate_evidence(document, expected_gate=gate)


def validate_bundle(
    value: Any,
    manifests: Mapping[str, Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    root = _exact_keys(value, BUNDLE_KEYS, "bundle root")
    if (
        type(root["schema_version"]) is not int
        or root["schema_version"] != BUNDLE_SCHEMA_VERSION
    ):
        raise EvidenceError("bundle schema version is invalid")
    if root["classification"] != BUNDLE_CLASSIFICATION:
        raise EvidenceError("bundle classification is invalid")
    revision = root["source_revision"]
    if (
        not isinstance(revision, str)
        or SOURCE_REVISION_RE.fullmatch(revision) is None
        or len(set(revision)) == 1
    ):
        raise EvidenceError("bundle source revision is invalid or placeholder")
    gates = root["gates"]
    if not isinstance(gates, list) or len(gates) != len(GATES):
        raise EvidenceError("bundle gate references are incomplete")
    references: dict[str, str] = {}
    for index, expected_gate in enumerate(GATES):
        reference = _exact_keys(gates[index], BUNDLE_GATE_KEYS, "bundle gate")
        if reference["gate"] != expected_gate:
            raise EvidenceError("bundle gate references are missing or reordered")
        references[expected_gate] = _validate_content_id(
            reference["content_id"], expected_gate
        )
    content_id = root["content_id"]
    pattern = re.compile(re.escape(BUNDLE_CONTENT_PREFIX) + r"[0-9a-f]{64}\Z")
    if not isinstance(content_id, str) or pattern.fullmatch(content_id) is None:
        raise EvidenceError("bundle content ID is invalid")
    if content_id != compute_bundle_content_id(root):
        raise EvidenceError("bundle content ID does not match its canonical statement")
    if manifests is not None:
        if set(manifests) != set(GATES):
            raise EvidenceError("bundle verification requires every gate manifest")
        for gate in GATES:
            manifest = validate_evidence(manifests[gate], expected_gate=gate)
            if manifest["binding"]["source_revision"] != revision:
                raise EvidenceError("bundle manifest source revisions do not match")
            if manifest["content_id"] != references[gate]:
                raise EvidenceError(
                    "bundle gate content ID does not match its manifest"
                )
    return copy.deepcopy(root)


def build_bundle(manifests: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
    if set(manifests) != set(GATES):
        raise EvidenceError("bundle requires every exact operational gate")
    validated = {
        gate: validate_evidence(manifests[gate], expected_gate=gate) for gate in GATES
    }
    revisions = {validated[gate]["binding"]["source_revision"] for gate in GATES}
    if len(revisions) != 1:
        raise EvidenceError("gate manifests do not share one source revision")
    statement: dict[str, Any] = {
        "schema_version": BUNDLE_SCHEMA_VERSION,
        "classification": BUNDLE_CLASSIFICATION,
        "source_revision": next(iter(revisions)),
        "gates": [
            {"gate": gate, "content_id": validated[gate]["content_id"]}
            for gate in GATES
        ],
    }
    bundle = dict(statement)
    bundle["content_id"] = compute_bundle_content_id(bundle)
    return validate_bundle(bundle, validated)


def read_bundle(
    path: pathlib.Path,
    manifests: Mapping[str, Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    return validate_bundle(_read_canonical(path), manifests)


def _write_exclusive(path: pathlib.Path, value: Mapping[str, Any]) -> None:
    payload = encode_canonical_document(value)
    if len(payload) > MAX_DOCUMENT_BYTES:
        raise EvidenceError("output evidence exceeds its maximum size")
    destination = path.absolute()
    parent = destination.parent
    parent_flags = os.O_RDONLY
    parent_flags |= getattr(os, "O_CLOEXEC", 0)
    parent_flags |= getattr(os, "O_DIRECTORY", 0)
    parent_flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        before = parent.lstat()
        parent_descriptor = os.open(parent, parent_flags)
    except OSError as error:
        raise EvidenceError("output parent cannot be opened safely") from error
    try:
        metadata = os.fstat(parent_descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or (before.st_dev, before.st_ino) != (metadata.st_dev, metadata.st_ino)
            or metadata.st_uid not in {0, os.geteuid()}
            or metadata.st_mode & 0o022
        ):
            raise EvidenceError(
                "output parent is linked, unowned, or group/other writable"
            )
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(
                destination.name,
                flags,
                0o600,
                dir_fd=parent_descriptor,
            )
        except OSError as error:
            raise EvidenceError(
                "output evidence cannot be created exclusively"
            ) from error
        try:
            view = memoryview(payload)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise EvidenceError("output evidence write did not make progress")
                view = view[written:]
            os.fsync(descriptor)
        except Exception as error:
            try:
                os.unlink(destination.name, dir_fd=parent_descriptor)
            except OSError:
                pass
            if isinstance(error, EvidenceError):
                raise
            raise EvidenceError("output evidence write failed") from error
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_descriptor)


def _manifest_paths(values: Sequence[str]) -> dict[str, pathlib.Path]:
    result: dict[str, pathlib.Path] = {}
    for value in values:
        gate, separator, raw_path = value.partition("=")
        if not separator or gate not in GATES or not raw_path or gate in result:
            raise EvidenceError(
                "manifest arguments must contain each gate exactly once"
            )
        result[gate] = pathlib.Path(raw_path)
    if set(result) != set(GATES):
        raise EvidenceError("manifest arguments must contain every gate exactly once")
    return result


def _load_manifest_set(values: Sequence[str]) -> dict[str, dict[str, Any]]:
    return {
        gate: read_evidence(path, expected_gate=gate)
        for gate, path in _manifest_paths(values).items()
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate canonical Pakperk protected operational evidence."
    )
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate", help="validate one gate manifest")
    validate.add_argument("manifest", type=pathlib.Path)
    validate.add_argument("--gate", choices=GATES)
    validate.add_argument("--expected-id")
    validate.add_argument("--expected-binding", type=pathlib.Path)

    bundle = commands.add_parser("bundle", help="bundle the three gate manifests")
    bundle.add_argument(
        "--manifest", action="append", required=True, metavar="GATE=PATH"
    )
    bundle.add_argument("--output", required=True, type=pathlib.Path)

    verify = commands.add_parser(
        "validate-bundle", help="verify a bundle against the three manifests"
    )
    verify.add_argument("bundle", type=pathlib.Path)
    verify.add_argument(
        "--manifest", action="append", required=True, metavar="GATE=PATH"
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "validate":
            expected_binding = (
                _read_canonical(arguments.expected_binding)
                if arguments.expected_binding is not None
                else None
            )
            evidence = read_evidence(
                arguments.manifest,
                expected_gate=arguments.gate,
                expected_content_id=arguments.expected_id,
                expected_binding=expected_binding,
            )
            print(
                f"Validated operational gate {evidence['gate']} "
                f"{evidence['content_id']}."
            )
        elif arguments.command == "bundle":
            manifests = _load_manifest_set(arguments.manifest)
            bundle = build_bundle(manifests)
            _write_exclusive(arguments.output, bundle)
            print(f"Created operational gate bundle {bundle['content_id']}.")
        else:
            manifests = _load_manifest_set(arguments.manifest)
            bundle = read_bundle(arguments.bundle, manifests)
            print(f"Validated operational gate bundle {bundle['content_id']}.")
        return 0
    except EvidenceError as error:
        print(f"operational gate evidence rejected: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
