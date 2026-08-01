#!/usr/bin/env python3
"""Closed, self-addressed evidence contract for live-comments acceptance.

This module deliberately accepts only fixed status values and a reviewed Git
revision. It never accepts request/response content, bearer tokens, OIDC
subjects, email addresses, or disposable resource identifiers, so those values
cannot enter the retained artifact through an accidentally broad serializer.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
from typing import Any, Mapping
import uuid


EVIDENCE_SCHEMA_VERSION = 1
DATABASE_MIGRATION_VERSION = 10
STATE_SCHEMA_VERSION = 2
MAX_EVIDENCE_BYTES = 64 * 1024

MANUAL_CI_ENVIRONMENT = "manual_ci_disposable_reference"
LOCAL_ENVIRONMENT = "local_disposable_reference"
ENVIRONMENTS = (MANUAL_CI_ENVIRONMENT, LOCAL_ENVIRONMENT)
CLASSIFICATION = (
    "disposable reference evidence; not staging or public-enablement approval"
)

SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
CONTENT_ID = re.compile(r"reference-sha256:[0-9a-f]{64}")
UUID_TEXT = re.compile(
    rb"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"
)
EMAIL_TEXT = re.compile(rb"(?i)\b[^\s@]+@[^\s@]+\.[^\s@]+\b")
JWT_TEXT = re.compile(
    rb"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
    rb"[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"
)

# Order is part of the evidence schema. A failed run is represented by a
# passed prefix, one failed scenario, and a not-run suffix. Cleanup is always
# last and must pass before any artifact can be emitted.
SCENARIO_IDS = (
    "database_migration_version_10",
    "mobile_oidc_authorization_code_pkce_and_password_grant_rejection",
    "admin_oidc_pkce_dedicated_audience_rejected_by_api",
    "account_terms_and_guidelines_onboarding",
    "admin_rejects_mobile_audience_token",
    "admin_rejects_nonallowlisted_admin_audience_identity",
    "admin_accepts_allowlisted_operator_with_owner_only_token_file",
    "comment_create_exact_replay_and_mismatch_conflict",
    "comment_edit_optimistic_version_and_stale_conflict",
    "comment_report_canonical_replay",
    "user_report_canonical_replay_without_implicit_block",
    "user_block_cross_process_filter_and_unblock",
    "high_risk_comment_private_pending_review",
    "admin_queues_inspection_actions_and_attributable_audit",
    "creation_kill_switch_preserves_reads_safety_edit_and_delete",
    "unavailable_oidc_preserves_guest_reads_and_fails_auth_closed",
    "comment_actions_do_not_change_paper_preparation_or_jobs",
    "captured_api_logs_exclude_ugc_headers_tokens_subjects_and_emails",
    "disposable_provider_database_and_rate_limit_state_removed",
)
CLEANUP_SCENARIO_ID = SCENARIO_IDS[-1]
RUNTIME_SCENARIO_IDS = SCENARIO_IDS[:-1]
SCENARIO_OUTCOMES = {"passed", "failed", "not_run"}

ROOT_KEYS = {
    "schema_version",
    "content_id",
    "source_revision",
    "classification",
    "database",
    "run",
    "scenarios",
    "sanitization",
}
CLASSIFICATION_KEYS = {"environment", "scope"}
DATABASE_KEYS = {"migration_version"}
RUN_KEYS = {"outcome", "cleanup"}
SCENARIO_KEYS = {"id", "outcome"}
SANITIZATION_KEYS = {
    "artifact_contract",
    "raw_bearer_tokens",
    "raw_ugc",
    "oidc_subjects",
    "email_addresses",
    "dynamic_resource_ids",
}
SANITIZATION = {
    "artifact_contract": "closed_allowlist_v1",
    "raw_bearer_tokens": "excluded",
    "raw_ugc": "excluded",
    "oidc_subjects": "excluded",
    "email_addresses": "excluded",
    "dynamic_resource_ids": "excluded",
}


class EvidenceError(RuntimeError):
    """A bounded validation error that never includes evidence values."""


def initial_scenario_state() -> dict[str, str]:
    return {scenario_id: "not_run" for scenario_id in SCENARIO_IDS}


def _exact_keys(value: Any, expected: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise EvidenceError(f"{label} does not use the closed evidence schema")
    return value


def _canonical_bytes(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _content_id(statement: Mapping[str, Any]) -> str:
    # The domain-separated prefix intentionally cannot satisfy the production
    # Helm moderationReadinessId contract (`sha256:<64>`). This disposable
    # reference artifact therefore cannot be substituted for launch approval.
    return f"reference-sha256:{hashlib.sha256(_canonical_bytes(statement)).hexdigest()}"


def _validate_status_sequence(
    scenarios: list[dict[str, Any]], run_outcome: str
) -> None:
    runtime_outcomes = [item["outcome"] for item in scenarios[:-1]]
    cleanup_outcome = scenarios[-1]["outcome"]
    if cleanup_outcome != "passed":
        raise EvidenceError("cleanup must pass before evidence is emitted")
    if run_outcome == "passed":
        if any(outcome != "passed" for outcome in runtime_outcomes):
            raise EvidenceError("a passed run must pass every scenario")
        return
    if run_outcome != "failed":
        raise EvidenceError("run outcome is invalid")
    if runtime_outcomes.count("failed") != 1:
        raise EvidenceError("a failed run must identify exactly one failed scenario")
    failure_index = runtime_outcomes.index("failed")
    if any(outcome != "passed" for outcome in runtime_outcomes[:failure_index]):
        raise EvidenceError("failed-run scenario prefix is invalid")
    if any(outcome != "not_run" for outcome in runtime_outcomes[failure_index + 1 :]):
        raise EvidenceError("failed-run scenario suffix is invalid")


def validate_evidence(
    evidence: Any,
    *,
    source_revision: str | None = None,
    expected_outcome: str | None = None,
    environment: str | None = None,
) -> dict[str, Any]:
    root = _exact_keys(evidence, ROOT_KEYS, "root")
    if root["schema_version"] != EVIDENCE_SCHEMA_VERSION:
        raise EvidenceError("evidence schema version is invalid")
    if not isinstance(root["source_revision"], str) or not SOURCE_REVISION.fullmatch(
        root["source_revision"]
    ):
        raise EvidenceError("source revision must be a full lowercase Git SHA")
    if source_revision is not None and root["source_revision"] != source_revision:
        raise EvidenceError("evidence source revision does not match the reviewed source")

    classification = _exact_keys(
        root["classification"], CLASSIFICATION_KEYS, "classification"
    )
    if classification["environment"] not in ENVIRONMENTS:
        raise EvidenceError("evidence environment classification is invalid")
    if environment is not None and classification["environment"] != environment:
        raise EvidenceError("evidence environment does not match the expected environment")
    if classification["scope"] != CLASSIFICATION:
        raise EvidenceError("evidence approval scope is invalid")

    database = _exact_keys(root["database"], DATABASE_KEYS, "database")
    if database["migration_version"] != DATABASE_MIGRATION_VERSION:
        raise EvidenceError("database migration version is invalid")

    run = _exact_keys(root["run"], RUN_KEYS, "run")
    if run["outcome"] not in {"passed", "failed"} or run["cleanup"] != "passed":
        raise EvidenceError("run outcome or cleanup status is invalid")
    if expected_outcome is not None and run["outcome"] != expected_outcome:
        raise EvidenceError("evidence outcome does not match the expected outcome")

    raw_scenarios = root["scenarios"]
    if not isinstance(raw_scenarios, list) or len(raw_scenarios) != len(SCENARIO_IDS):
        raise EvidenceError("evidence does not contain the exact scenario matrix")
    scenarios: list[dict[str, Any]] = []
    for expected_id, raw_scenario in zip(SCENARIO_IDS, raw_scenarios, strict=True):
        scenario = dict(_exact_keys(raw_scenario, SCENARIO_KEYS, "scenario"))
        if scenario["id"] != expected_id or scenario["outcome"] not in SCENARIO_OUTCOMES:
            raise EvidenceError("evidence scenario identity or outcome is invalid")
        scenarios.append(scenario)
    _validate_status_sequence(scenarios, run["outcome"])

    sanitization = _exact_keys(
        root["sanitization"], SANITIZATION_KEYS, "sanitization"
    )
    if dict(sanitization) != SANITIZATION:
        raise EvidenceError("evidence sanitization declaration is invalid")

    content_id = root["content_id"]
    if not isinstance(content_id, str) or not CONTENT_ID.fullmatch(content_id):
        raise EvidenceError("evidence content ID is invalid")
    statement = dict(root)
    del statement["content_id"]
    if not hashlib.sha256(_canonical_bytes(statement)).hexdigest() == content_id.removeprefix(
        "reference-sha256:"
    ):
        raise EvidenceError("evidence content ID does not match its canonical statement")

    # The closed-schema checks above constrain every non-hash string to an
    # exact allowlisted value. These pattern checks are defense in depth and a
    # direct regression guard against accidental identity/token serialization.
    encoded = _canonical_bytes(root)
    if len(encoded) > MAX_EVIDENCE_BYTES:
        raise EvidenceError("evidence exceeds its maximum encoded size")
    if UUID_TEXT.search(encoded):
        raise EvidenceError("evidence contains a dynamic resource or subject identifier")
    if EMAIL_TEXT.search(encoded):
        raise EvidenceError("evidence contains an email address")
    if JWT_TEXT.search(encoded):
        raise EvidenceError("evidence contains token-shaped material")
    return dict(root)


def build_evidence(
    state: Mapping[str, Any],
    source_revision: str,
    environment: str,
    *,
    expected_outcome: str | None = None,
) -> dict[str, Any]:
    if state.get("schema_version") != STATE_SCHEMA_VERSION:
        raise EvidenceError("cleanup state schema is invalid")
    if state.get("cleaned") is not True:
        raise EvidenceError("cleanup has not completed")
    raw_statuses = state.get("scenarios")
    if not isinstance(raw_statuses, dict) or set(raw_statuses) != set(SCENARIO_IDS):
        raise EvidenceError("cleanup state does not contain the exact scenario matrix")
    scenarios = [
        {"id": scenario_id, "outcome": raw_statuses[scenario_id]}
        for scenario_id in SCENARIO_IDS
    ]
    statement: dict[str, Any] = {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "source_revision": source_revision,
        "classification": {
            "environment": environment,
            "scope": CLASSIFICATION,
        },
        "database": {"migration_version": DATABASE_MIGRATION_VERSION},
        "run": {
            "outcome": state.get("acceptance_outcome"),
            "cleanup": "passed",
        },
        "scenarios": scenarios,
        "sanitization": dict(SANITIZATION),
    }
    evidence = dict(statement)
    evidence["content_id"] = _content_id(statement)
    return validate_evidence(
        evidence,
        source_revision=source_revision,
        expected_outcome=expected_outcome,
        environment=environment,
    )


def write_evidence(path: Path, evidence: Mapping[str, Any]) -> None:
    if not path.is_absolute():
        raise EvidenceError("evidence output path must be absolute")
    if os.path.lexists(path):
        raise EvidenceError("evidence output already exists")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise EvidenceError("evidence output parent must be a real existing directory")
    parent_metadata = path.parent.stat()
    if parent_metadata.st_uid != os.geteuid() or parent_metadata.st_mode & 0o077:
        raise EvidenceError("evidence output parent must be private and owner-controlled")
    encoded = (
        json.dumps(evidence, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    if len(encoded) > MAX_EVIDENCE_BYTES:
        raise EvidenceError("evidence exceeds its maximum encoded size")

    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fchmod(output.fileno(), 0o400)
            os.fsync(output.fileno())
        os.link(temporary, path)
        temporary.unlink()
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def read_evidence(path: Path) -> dict[str, Any]:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceError("could not open evidence as a non-symlink file") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_EVIDENCE_BYTES:
            raise EvidenceError("evidence must be a bounded regular file")
        if metadata.st_mode & 0o077:
            raise EvidenceError("evidence must not be group- or world-accessible")
        chunks: list[bytes] = []
        remaining = MAX_EVIDENCE_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(8192, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise EvidenceError("evidence exceeds its maximum encoded size")
    finally:
        os.close(descriptor)
    try:
        value = json.loads(b"".join(chunks))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError("evidence is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise EvidenceError("evidence root is not an object")
    return value
