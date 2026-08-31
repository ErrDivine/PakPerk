#!/usr/bin/env python3
"""Canonical evidence contracts for Pakperk production approval gates.

The five legacy Helm approval IDs covered here are content IDs of sanitized,
production-only manifests. The independently validated Deep Reader bundle ID is
also bound into the release contract. This module validates structure and
binding; it cannot manufacture protected execution or accountable approval.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
from dataclasses import dataclass
from typing import Any, Mapping, Sequence


EVIDENCE_SCHEMA_VERSION = 1
BUNDLE_SCHEMA_VERSION = 3
OLD_CLIENT_POLICY_SCHEMA_VERSION = 1
MAX_DOCUMENT_BYTES = 128 * 1024
MAX_RENDERED_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_JSON_NESTING = 16
EVIDENCE_CLASSIFICATION = "protected production approval evidence"
BUNDLE_CLASSIFICATION = "protected production approval predeploy bundle"
EVIDENCE_DOMAIN = b"pakperk/production-approval-evidence/v1\0"
BUNDLE_DOMAIN = b"pakperk/production-approval-bundle/v3\0"
RELEASE_CONFIGURATION_DOMAIN = b"pakperk/release-configuration/v1\0"
DEPLOYMENT_IMAGES_DOMAIN = b"pakperk/deployment-images/v1\0"
OLD_CLIENT_POLICY_DOMAIN = b"pakperk/old-client-policy/v1\0"
OLD_CLIENT_POLICY_CLASSIFICATION = "protected production old-client policy evidence"

GATES = (
    "legalReviewId",
    "reviewerFlowId",
    "strictContentReviewId",
    "moderationReadinessId",
    "accountDeletionE2eId",
)

SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}")
SOURCE_REVISION_RE = re.compile(r"[0-9a-f]{40}")
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
DNS_LABEL_PATTERN = r"[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?"
DNS_LABEL_RE = re.compile(DNS_LABEL_PATTERN)
DNS_SUBDOMAIN_RE = re.compile(
    rf"{DNS_LABEL_PATTERN}(?:\.{DNS_LABEL_PATTERN})*"
)
EMAIL_RE = re.compile(r"[^@\s]{1,64}@[^@\s]{1,189}")
JWT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
    r"[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"
)

BINDING_KEYS = {
    "source_revision",
    "target_environment",
    "release_configuration_sha256",
    "deployment_images_sha256",
    "restore_drill_id",
    "helm_chart_version",
    "helm_app_version",
    "mobile_candidate_id",
    "mobile_version",
    "mobile_build",
}
RUN_KEYS = {"outcome", "started_at", "completed_at"}
ARTIFACT_KEYS = {"id", "sha256", "size_bytes"}
ASSERTION_KEYS = {"id", "outcome"}
MEASUREMENT_KEYS = {"id", "value"}
APPROVAL_KEYS = {
    "role",
    "decision",
    "approved_at",
    "protected_audit_reference",
}
SANITIZATION = {
    "contains_credentials": False,
    "contains_tokens": False,
    "contains_cookies": False,
    "contains_device_serials": False,
    "contains_personal_data": False,
    "contains_raw_ugc": False,
    "contains_unbounded_logs": False,
}
ROOT_KEYS = {
    "schema_version",
    "content_id",
    "classification",
    "gate",
    "binding",
    "run",
    "artifacts",
    "assertions",
    "measurements",
    "approval",
    "sanitization",
}
BUNDLE_KEYS = {
    "schema_version",
    "content_id",
    "classification",
    "binding",
    "deployment",
    "gates",
}
BUNDLE_GATE_KEYS = {"gate", "content_id"}
BUNDLE_DEPLOYMENT_KEYS = {
    "rendered_manifest_sha256",
    "release_binding_sha256",
    "release_evidence_sha256",
    "restore_drill_id",
    "deep_reader_release_id",
    "to_read_first_enforcement",
    "old_client_policy_id",
}
RELEASE_CONTRACT_KEYS = {
    "schemaVersion",
    "environment",
    "features",
    "releaseEvidence",
    "alertPolicySha256",
    "images",
    "chart",
    "legalPolicy",
}
RELEASE_EVIDENCE_KEYS = set(GATES) | {"restoreDrillId", "deepReaderReleaseId"}
IMAGE_KEYS = {"backend", "site", "grobid", "otelCollector"}
FEATURE_KEYS = {
    "accounts",
    "library",
    "libraryWrites",
    "paperResolution",
    "paperTitleSearch",
    "libraryImportWrites",
    "readingFeed",
    "toReadFirstEnforcement",
    "comments",
    "commentCreation",
    "accountDeletion",
    "libraryV2",
    "researchProfiles",
    "recommendations",
    "recommendationEvents",
    "searchLookup",
    "searchExplore",
    "savedQueries",
    "readingBriefs",
    "subscriptions",
    "notifications",
    "deepReader",
    "paperPassport",
    "semanticFacets",
    "visualObjects",
    "assistantV2",
    "annotations",
    "researchMemory",
    "versionDiff",
    "doclingExperiment",
}
DEEP_READER_FEATURE_KEYS = {
    "deepReader",
    "paperPassport",
    "semanticFacets",
    "visualObjects",
    "assistantV2",
    "annotations",
    "researchMemory",
    "versionDiff",
    "doclingExperiment",
}
FEATURE_DEPENDENCIES = {
    "library": ("accounts",),
    "libraryWrites": ("library",),
    "paperTitleSearch": ("accounts", "paperResolution"),
    "libraryImportWrites": (
        "accounts",
        "library",
        "libraryWrites",
        "paperResolution",
    ),
    "readingFeed": ("accounts", "library"),
    "toReadFirstEnforcement": ("readingFeed",),
    "comments": ("accounts",),
    "commentCreation": ("comments",),
    "accountDeletion": ("accounts",),
    "libraryV2": ("accounts", "library"),
    "researchProfiles": ("accounts",),
    "recommendations": ("accounts", "library", "readingFeed"),
    "searchExplore": ("searchLookup",),
    "savedQueries": ("accounts", "searchExplore"),
    "readingBriefs": ("readingFeed",),
    "subscriptions": ("accounts", "library", "readingFeed"),
    "notifications": ("subscriptions",),
    "paperPassport": ("deepReader",),
    "semanticFacets": ("deepReader",),
    "visualObjects": ("deepReader",),
    "assistantV2": ("deepReader",),
    "annotations": ("accounts", "deepReader"),
    "researchMemory": ("accounts", "deepReader", "annotations"),
    "versionDiff": ("deepReader",),
    "doclingExperiment": ("deepReader",),
}
OLD_CLIENT_POLICY_STRATEGIES = (
    "minimum_supported_version",
    "disable_legacy_account_library",
    "advisory_until_adoption_threshold",
)
OLD_CLIENT_POLICY_ROOT_KEYS = {
    "schema_version",
    "content_id",
    "classification",
    "binding",
    "strategy",
    "parameters",
    "evidence",
    "approval",
    "sanitization",
}
OLD_CLIENT_POLICY_PARAMETER_KEYS = {
    "minimum_supported_version": {
        "minimum_mobile_version",
        "minimum_mobile_build",
        "enforcement_mechanism",
    },
    "disable_legacy_account_library": {
        "legacy_maximum_mobile_version",
        "legacy_maximum_mobile_build",
        "account_access",
        "library_access",
    },
    "advisory_until_adoption_threshold": {
        "adoption_threshold_basis_points",
        "minimum_observation_hours",
        "enforcement_claim",
    },
}
OLD_CLIENT_POLICY_EVIDENCE_KEYS = {
    "minimum_supported_version": {
        "policy_record_sha256",
        "minimum_version_enforcement_sha256",
        "rollback_evidence_sha256",
    },
    "disable_legacy_account_library": {
        "policy_record_sha256",
        "legacy_access_gate_sha256",
        "rollback_evidence_sha256",
    },
    "advisory_until_adoption_threshold": {
        "policy_record_sha256",
        "adoption_measurement_sha256",
        "rollback_evidence_sha256",
    },
}
RELEASE_CONFIG_MAP_ROOT_KEYS = {
    "apiVersion",
    "kind",
    "metadata",
    "immutable",
    "data",
}
RELEASE_CONFIG_MAP_METADATA_KEYS = {"name", "labels", "annotations"}
RELEASE_CONFIG_MAP_LABEL_KEYS = {
    "app.kubernetes.io/name",
    "app.kubernetes.io/instance",
    "app.kubernetes.io/managed-by",
    "app.kubernetes.io/version",
    "helm.sh/chart",
    "app.kubernetes.io/component",
}
RELEASE_CONFIG_MAP_ANNOTATION_KEYS = {
    "pakperk.app/release-evidence-sha256",
    "pakperk.app/release-binding-sha256",
    "pakperk.app/release-binding-schema",
}
RELEASE_CONFIG_MAP_DATA_KEYS = {
    "environment",
    "enabledFeatures.json",
    "alertPolicySha256",
    "imageIdentities.json",
    "chartIdentity.json",
    "legalPolicy.json",
    "releaseContract.json",
    *RELEASE_EVIDENCE_KEYS,
}


class EvidenceError(RuntimeError):
    """A production approval artifact violated its closed contract."""


@dataclass(frozen=True)
class GateSpec:
    approval_role: str
    assertions: tuple[str, ...]
    artifacts: tuple[str, ...]
    measurement_keys: tuple[str, ...]


GATE_SPECS = {
    "legalReviewId": GateSpec(
        approval_role="privacy_legal_owner",
        assertions=(
            "published_privacy_terms_guidelines_support_versions_verified",
            "direct_https_document_checks_passed",
            "monitored_support_contact_canary_passed",
            "enabled_features_reconciled",
            "sdk_and_processor_inventory_reconciled",
            "collection_retention_deletion_and_backup_behavior_reviewed",
            "jurisdictions_and_contracts_reviewed",
            "public_urls_reconciled",
        ),
        artifacts=(
            "published_document_snapshot",
            "sdk_processor_inventory",
            "support_contact_canary",
        ),
        measurement_keys=(
            "document_version",
            "published_routes_checked",
            "support_canary_attempts",
            "support_canary_successes",
            "enabled_features_sha256",
            "sdk_processor_inventory_sha256",
            "data_practices_sha256",
            "retention_schedule_sha256",
            "jurisdictions_contracts_sha256",
        ),
    ),
    "reviewerFlowId": GateSpec(
        approval_role="store_release_owner",
        assertions=(
            "disposable_verified_email_account_lifecycle_recorded",
            "guest_and_system_browser_sign_in_walkthrough_passed",
            "save_and_library_walkthrough_passed",
            "comment_report_and_block_walkthrough_passed",
            "in_app_deletion_walkthrough_passed",
            "web_deletion_walkthrough_passed",
            "strict_content_walkthrough_passed",
            "store_ready_notes_completed",
        ),
        artifacts=(
            "reviewer_walkthrough_result",
            "reviewer_account_lifecycle",
            "reviewer_notes",
        ),
        measurement_keys=(
            "walkthrough_steps_passed",
            "account_expires_at",
            "account_lifecycle_sha256",
            "reviewer_notes_sha256",
            "physical_acceptance_id",
            "account_deletion_e2e_id",
            "sbom_inventory_sha256",
            "legal_review_id",
            "strict_content_review_id",
        ),
    ),
    "strictContentReviewId": GateSpec(
        approval_role="legal_content_owner",
        assertions=(
            "strict_backend_and_mobile_configuration_bound",
            "metadata_save_comments_and_arxiv_remain_available",
            "displayed_and_retained_introduction_behavior_reviewed",
            "online_and_offline_derived_fallbacks_masked",
            "retention_and_display_policy_reviewed",
        ),
        artifacts=(
            "strict_configuration_snapshot",
            "strict_behavior_result",
            "content_policy_snapshot",
        ),
        measurement_keys=(
            "fulltext_policy",
            "allowed_surface_checks",
            "introduction_behavior_checks",
            "derived_fallback_exposures",
            "configuration_sha256",
            "retention_display_policy_sha256",
        ),
    ),
    "moderationReadinessId": GateSpec(
        approval_role="trust_safety_owner",
        assertions=(
            "operator_issuer_audience_recent_auth_and_allowlist_verified",
            "mobile_audience_and_nonallowlisted_operator_rejected",
            "comment_user_report_comment_report_and_block_queues_exercised",
            "inspect_hide_restore_resolve_suspend_and_reinstate_audited",
            "comment_creation_kill_preserved_guest_reads_and_safety_actions",
            "high_risk_and_provider_outage_fallbacks_exercised",
            "alert_and_ticket_canaries_passed",
            "staffed_response_targets_and_escalation_exercised",
            "support_deletion_retention_and_restore_dependencies_reconciled",
        ),
        artifacts=(
            "moderation_exercise_result",
            "alert_ticket_canaries",
            "staffing_escalation_result",
        ),
        measurement_keys=(
            "operator_boundary_cases_passed",
            "live_queue_types_exercised",
            "moderation_actions_exercised",
            "audit_records_verified",
            "alert_ticket_canaries_passed",
            "staffed_response_target_seconds",
            "escalation_exercises_passed",
            "moderation_audit_inventory_sha256",
        ),
    ),
    "accountDeletionE2eId": GateSpec(
        approval_role="privacy_on_call_owner",
        assertions=(
            "stale_reauthentication_rejected_then_recent_authentication_accepted",
            "account_disabled_immediately",
            "sessions_revoked",
            "provider_identity_absent",
            "application_data_purged_or_pseudonymized",
            "one_signed_external_ledger_record_and_database_job_verified",
            "repeated_request_and_worker_retry_safe",
            "alert_canary_passed",
            "real_secret_manager_ledger_and_backup_inventory_bound",
        ),
        artifacts=(
            "account_deletion_exercise_result",
            "external_ledger_inventory",
            "backup_inventory",
            "alert_canary",
        ),
        measurement_keys=(
            "reauthentication_rejections",
            "reauthentication_acceptances",
            "application_rows_purged",
            "application_rows_pseudonymized",
            "external_ledger_records",
            "database_jobs",
            "replay_attempts",
            "alert_canaries_passed",
            "operation_id_sha256",
            "secret_manager_reference_sha256",
            "ledger_inventory_sha256",
            "backup_inventory_sha256",
        ),
    ),
}


def _exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != set(expected):
        raise EvidenceError(f"{label} does not have the exact required keys")
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
    except (TypeError, ValueError) as error:
        raise EvidenceError("evidence is not canonical JSON data") from error


def encode_canonical_document(value: Any) -> bytes:
    """Return the one accepted on-disk JSON representation."""

    return _canonical_json(value) + b"\n"


def _statement(document: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: copy.deepcopy(value)
        for key, value in document.items()
        if key != "content_id"
    }


def compute_evidence_content_id(document: Mapping[str, Any]) -> str:
    gate = document.get("gate")
    if not isinstance(gate, str) or gate not in GATE_SPECS:
        raise EvidenceError("evidence gate is invalid")
    material = (
        EVIDENCE_DOMAIN
        + gate.encode("ascii")
        + b"\0"
        + _canonical_json(_statement(document))
    )
    return f"sha256:{hashlib.sha256(material).hexdigest()}"


def compute_bundle_content_id(document: Mapping[str, Any]) -> str:
    material = BUNDLE_DOMAIN + _canonical_json(_statement(document))
    return f"sha256:{hashlib.sha256(material).hexdigest()}"


def compute_old_client_policy_content_id(document: Mapping[str, Any]) -> str:
    material = OLD_CLIENT_POLICY_DOMAIN + _canonical_json(_statement(document))
    return f"sha256:{hashlib.sha256(material).hexdigest()}"


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


def _read_bounded(
    path: pathlib.Path, *, maximum: int = MAX_DOCUMENT_BYTES
) -> bytes:
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
            or metadata.st_size > maximum
        ):
            raise EvidenceError("evidence file is not a bounded regular file")
        data = bytearray()
        while len(data) <= maximum:
            chunk = os.read(
                descriptor, min(64 * 1024, maximum + 1 - len(data))
            )
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > maximum:
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


def _digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a sha256 content identifier")
    payload = value.removeprefix("sha256:")
    if len(set(payload)) == 1:
        raise EvidenceError(f"{label} is an obvious placeholder digest")
    return value


def compute_release_configuration_id(contract: Mapping[str, Any]) -> str:
    """Address the release contract without recursively produced bundle IDs.

    `restoreDrillId` remains bound because that independently produced ID does
    not depend on these approval bundles. Blanking the five approval gates and
    `deepReaderReleaseId` breaks the otherwise impossible cycles between their
    content IDs and Helm's final release-binding digest.
    """

    normalized = copy.deepcopy(dict(contract))
    release_evidence = normalized.get("releaseEvidence")
    if not isinstance(release_evidence, dict):
        raise EvidenceError("release contract approvals are invalid")
    for gate in (*GATES, "deepReaderReleaseId"):
        release_evidence[gate] = ""
    material = RELEASE_CONFIGURATION_DOMAIN + _canonical_json(normalized)
    return f"sha256:{hashlib.sha256(material).hexdigest()}"


def compute_deployment_images_id(images: Mapping[str, Any]) -> str:
    material = DEPLOYMENT_IMAGES_DOMAIN + _canonical_json(dict(images))
    return f"sha256:{hashlib.sha256(material).hexdigest()}"


def _validate_release_feature_dependencies(features: Mapping[str, bool]) -> None:
    for feature, required in FEATURE_DEPENDENCIES.items():
        if features[feature] and not all(features[parent] for parent in required):
            raise EvidenceError("rendered release feature dependencies are invalid")
    if features["accounts"] and not features["accountDeletion"]:
        raise EvidenceError("rendered release feature dependencies are invalid")


def _positive_int(
    value: Any, label: str, *, minimum: int = 1, maximum: int = 2**31 - 1
) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise EvidenceError(f"{label} is outside its integer boundary")
    return value


def _validate_binding(value: Any) -> dict[str, Any]:
    binding = _exact_keys(value, BINDING_KEYS, "binding")
    revision = binding["source_revision"]
    if (
        not isinstance(revision, str)
        or SOURCE_REVISION_RE.fullmatch(revision) is None
        or len(set(revision)) == 1
    ):
        raise EvidenceError("binding source revision is invalid or placeholder")
    if binding["target_environment"] != "production":
        raise EvidenceError("approval evidence must target production")
    for key in (
        "release_configuration_sha256",
        "deployment_images_sha256",
        "restore_drill_id",
        "mobile_candidate_id",
    ):
        _digest(binding[key], f"binding {key}")
    for key in ("helm_chart_version", "helm_app_version", "mobile_version"):
        value_at_key = binding[key]
        if (
            not isinstance(value_at_key, str)
            or VERSION_RE.fullmatch(value_at_key) is None
        ):
            raise EvidenceError(f"binding {key} must be an exact release version")
    _positive_int(binding["mobile_build"], "binding mobile_build")
    return dict(binding)


def _version_tuple(value: str) -> tuple[int, int, int]:
    major, minor, patch = value.split(".")
    return int(major), int(minor), int(patch)


def validate_old_client_policy(
    value: Any,
    *,
    expected_binding: Mapping[str, Any] | None = None,
    expected_content_id: str | None = None,
) -> dict[str, Any]:
    root = _exact_keys(
        value, OLD_CLIENT_POLICY_ROOT_KEYS, "old-client policy root"
    )
    if (
        type(root["schema_version"]) is not int
        or root["schema_version"] != OLD_CLIENT_POLICY_SCHEMA_VERSION
    ):
        raise EvidenceError("old-client policy schema version is invalid")
    if root["classification"] != OLD_CLIENT_POLICY_CLASSIFICATION:
        raise EvidenceError("old-client policy classification is invalid")
    binding = _validate_binding(root["binding"])
    if expected_binding is not None and binding != _validate_binding(
        expected_binding
    ):
        raise EvidenceError("old-client policy does not match the expected release")

    strategy = root["strategy"]
    if strategy not in OLD_CLIENT_POLICY_STRATEGIES:
        raise EvidenceError("old-client policy strategy is invalid")
    parameters = _exact_keys(
        root["parameters"],
        OLD_CLIENT_POLICY_PARAMETER_KEYS[strategy],
        "old-client policy parameters",
    )
    policy_evidence = _exact_keys(
        root["evidence"],
        OLD_CLIENT_POLICY_EVIDENCE_KEYS[strategy],
        "old-client policy evidence",
    )

    candidate_version = _version_tuple(binding["mobile_version"])
    candidate_build = binding["mobile_build"]
    if strategy == "minimum_supported_version":
        version = parameters["minimum_mobile_version"]
        if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
            raise EvidenceError("minimum-supported mobile version is invalid")
        build = _positive_int(
            parameters["minimum_mobile_build"],
            "minimum-supported mobile build",
        )
        if (
            _version_tuple(version) > candidate_version
            or build > candidate_build
            or parameters["enforcement_mechanism"] != "remote_configuration"
        ):
            raise EvidenceError("minimum-supported version policy is impossible")
    elif strategy == "disable_legacy_account_library":
        version = parameters["legacy_maximum_mobile_version"]
        if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
            raise EvidenceError("legacy maximum mobile version is invalid")
        build = _positive_int(
            parameters["legacy_maximum_mobile_build"],
            "legacy maximum mobile build",
        )
        if (
            _version_tuple(version) > candidate_version
            or build >= candidate_build
            or parameters["account_access"] != "disabled"
            or parameters["library_access"] != "disabled"
        ):
            raise EvidenceError("legacy account/library policy is invalid")
    else:
        _positive_int(
            parameters["adoption_threshold_basis_points"],
            "adoption threshold basis points",
            maximum=10_000,
        )
        _positive_int(
            parameters["minimum_observation_hours"],
            "minimum adoption observation hours",
            maximum=90 * 24,
        )
        if parameters["enforcement_claim"] != "advisory":
            raise EvidenceError("adoption policy must remain advisory")

    for key, identifier in policy_evidence.items():
        _digest(identifier, f"old-client policy evidence {key}")
    approval = _exact_keys(root["approval"], APPROVAL_KEYS, "old-client approval")
    if (
        approval["role"] != "product_release_owner"
        or approval["decision"] != "approved"
    ):
        raise EvidenceError("old-client policy owner approval is invalid")
    _parse_utc(approval["approved_at"], "old-client policy approval timestamp")
    _digest(
        approval["protected_audit_reference"],
        "old-client policy protected audit reference",
    )
    _validate_sanitization(root["sanitization"])
    _reject_sensitive_shapes(root)

    content_id = _digest(root["content_id"], "old-client policy content ID")
    if content_id != compute_old_client_policy_content_id(root):
        raise EvidenceError("old-client policy content ID does not match")
    if expected_content_id is not None and content_id != _digest(
        expected_content_id, "expected old-client policy content ID"
    ):
        raise EvidenceError("old-client policy content ID is not release-bound")
    return copy.deepcopy(root)


def build_old_client_policy(
    binding: Mapping[str, Any],
    *,
    strategy: str,
    parameters: Mapping[str, Any],
    policy_evidence: Mapping[str, str],
    approved_at: str,
    protected_audit_reference: str,
) -> dict[str, Any]:
    statement: dict[str, Any] = {
        "schema_version": OLD_CLIENT_POLICY_SCHEMA_VERSION,
        "classification": OLD_CLIENT_POLICY_CLASSIFICATION,
        "binding": copy.deepcopy(dict(binding)),
        "strategy": strategy,
        "parameters": copy.deepcopy(dict(parameters)),
        "evidence": copy.deepcopy(dict(policy_evidence)),
        "approval": {
            "role": "product_release_owner",
            "decision": "approved",
            "approved_at": approved_at,
            "protected_audit_reference": protected_audit_reference,
        },
        "sanitization": dict(SANITIZATION),
    }
    policy = dict(statement)
    policy["content_id"] = compute_old_client_policy_content_id(policy)
    return validate_old_client_policy(policy, expected_binding=binding)


def read_old_client_policy(
    path: pathlib.Path,
    *,
    expected_binding: Mapping[str, Any] | None = None,
    expected_content_id: str | None = None,
) -> dict[str, Any]:
    return validate_old_client_policy(
        _read_canonical(path),
        expected_binding=expected_binding,
        expected_content_id=expected_content_id,
    )


def _split_yaml_documents(source: str) -> list[str]:
    documents: list[str] = []
    current: list[str] = []
    for line in source.splitlines():
        if line == "---":
            if any(member.strip() and not member.lstrip().startswith("#") for member in current):
                documents.append("\n".join(current))
            current = []
        else:
            current.append(line)
    if any(member.strip() and not member.lstrip().startswith("#") for member in current):
        documents.append("\n".join(current))
    if not documents:
        raise EvidenceError("rendered deployment has no YAML documents")
    return documents


def _parse_simple_yaml_scalar(value: str) -> Any:
    if value.startswith('"'):
        try:
            parsed = json.loads(value)
        except (json.JSONDecodeError, ValueError, RecursionError) as error:
            raise EvidenceError("release ConfigMap contains an invalid quoted scalar") from error
        if not isinstance(parsed, str):
            raise EvidenceError("release ConfigMap quoted scalar is not text")
        return parsed
    if value == "true":
        return True
    if value == "false":
        return False
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9./_-]*", value) is None:
        raise EvidenceError("release ConfigMap contains an unsupported YAML scalar")
    return value


def _has_release_evidence_component(document: str) -> bool:
    prefix = "app.kubernetes.io/component: "
    found = False
    for raw_line in document.splitlines():
        line = raw_line.lstrip(" ")
        if not line.startswith(prefix):
            continue
        component = _parse_simple_yaml_scalar(line.removeprefix(prefix))
        if component == "release-evidence":
            found = True
    return found


def _parse_simple_yaml_mapping(document: str) -> dict[str, Any]:
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(-2, root)]
    key_pattern = re.compile(r"([A-Za-z0-9][A-Za-z0-9./_-]*):(?: (.*))?")
    for raw_line in document.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        if "\t" in raw_line or raw_line != raw_line.rstrip():
            raise EvidenceError("release ConfigMap YAML whitespace is not canonical")
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent % 2:
            raise EvidenceError("release ConfigMap YAML indentation is invalid")
        match = key_pattern.fullmatch(raw_line[indent:])
        if match is None:
            raise EvidenceError("release ConfigMap is not one scalar mapping")
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if not stack or indent != stack[-1][0] + 2:
            raise EvidenceError("release ConfigMap YAML nesting is invalid")
        parent = stack[-1][1]
        key, raw_value = match.groups()
        if key in parent:
            raise EvidenceError("release ConfigMap contains a duplicate key")
        if raw_value is None:
            child: dict[str, Any] = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = _parse_simple_yaml_scalar(raw_value)
    return root


def _parse_canonical_embedded_json(value: Any, label: str) -> Any:
    if not isinstance(value, str):
        raise EvidenceError(f"rendered {label} mirror is not text")
    try:
        parsed = json.loads(
            value,
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_constant,
        )
    except EvidenceError:
        raise
    except (json.JSONDecodeError, ValueError, RecursionError) as error:
        raise EvidenceError(f"rendered {label} mirror is invalid JSON") from error
    _depth(parsed)
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as error:
        raise EvidenceError(f"rendered {label} mirror is not canonical ASCII") from error
    if encoded != _canonical_json(parsed):
        raise EvidenceError(f"rendered {label} mirror is not canonical JSON")
    return parsed


def _release_contract_from_rendered(
    rendered: bytes,
) -> tuple[dict[str, Any], str, str]:
    try:
        source = rendered.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError("rendered deployment is not UTF-8") from error
    candidates = [
        document
        for document in _split_yaml_documents(source)
        if _has_release_evidence_component(document)
    ]
    if len(candidates) != 1:
        raise EvidenceError("rendered deployment has an ambiguous release ConfigMap")
    config_map = _exact_keys(
        _parse_simple_yaml_mapping(candidates[0]),
        RELEASE_CONFIG_MAP_ROOT_KEYS,
        "rendered release ConfigMap",
    )
    if config_map["apiVersion"] != "v1" or config_map["kind"] != "ConfigMap":
        raise EvidenceError("rendered release ConfigMap kind is invalid")
    if config_map["immutable"] is not True:
        raise EvidenceError("rendered release ConfigMap is not immutable")

    metadata = _exact_keys(
        config_map["metadata"],
        RELEASE_CONFIG_MAP_METADATA_KEYS,
        "rendered release ConfigMap metadata",
    )
    labels = _exact_keys(
        metadata["labels"],
        RELEASE_CONFIG_MAP_LABEL_KEYS,
        "rendered release ConfigMap labels",
    )
    annotations = _exact_keys(
        metadata["annotations"],
        RELEASE_CONFIG_MAP_ANNOTATION_KEYS,
        "rendered release ConfigMap annotations",
    )
    data = _exact_keys(
        config_map["data"],
        RELEASE_CONFIG_MAP_DATA_KEYS,
        "rendered release ConfigMap data",
    )
    if (
        labels["app.kubernetes.io/name"] != "pakperk"
        or labels["app.kubernetes.io/managed-by"] != "Helm"
        or labels["app.kubernetes.io/component"] != "release-evidence"
    ):
        raise EvidenceError("rendered release ConfigMap Pakperk labels are invalid")
    instance = labels["app.kubernetes.io/instance"]
    if not isinstance(instance, str) or DNS_LABEL_RE.fullmatch(instance) is None:
        raise EvidenceError("rendered release ConfigMap instance label is invalid")
    if annotations["pakperk.app/release-binding-schema"] != "1":
        raise EvidenceError("rendered release-binding schema is unsupported")

    contract = _parse_canonical_embedded_json(
        data["releaseContract.json"], "release contract"
    )
    if not isinstance(contract, dict):
        raise EvidenceError("rendered release contract is not one JSON object")
    canonical = _canonical_json(contract)
    release_binding = f"sha256:{hashlib.sha256(canonical).hexdigest()}"
    if annotations["pakperk.app/release-binding-sha256"] != release_binding:
        raise EvidenceError("rendered release-binding digest does not match")
    name = metadata["name"]
    if (
        not isinstance(name, str)
        or len(name) > 63
        or DNS_SUBDOMAIN_RE.fullmatch(name) is None
        or not name.endswith(
            "-release-evidence-"
            + release_binding.removeprefix("sha256:")[:12]
        )
    ):
        raise EvidenceError("rendered release ConfigMap name is not content-bound")

    features = contract.get("features")
    images = contract.get("images")
    chart = contract.get("chart")
    legal_policy = contract.get("legalPolicy")
    release_evidence = contract.get("releaseEvidence")
    if (
        not isinstance(features, dict)
        or not isinstance(images, dict)
        or not isinstance(chart, dict)
        or not isinstance(legal_policy, dict)
        or not isinstance(release_evidence, dict)
    ):
        raise EvidenceError("rendered release contract mirrors are invalid")
    if data["environment"] != contract.get("environment"):
        raise EvidenceError("rendered release environment mirror does not match")
    embedded_mirrors = {
        "enabledFeatures.json": features,
        "imageIdentities.json": images,
        "chartIdentity.json": chart,
        "legalPolicy.json": legal_policy,
    }
    for key, expected in embedded_mirrors.items():
        if _parse_canonical_embedded_json(data[key], key) != expected:
            raise EvidenceError("rendered release ConfigMap JSON mirror does not match")
    if data["alertPolicySha256"] != contract.get("alertPolicySha256"):
        raise EvidenceError("rendered release alert-policy mirror does not match")
    for key in RELEASE_EVIDENCE_KEYS:
        if data[key] != release_evidence.get(key):
            raise EvidenceError("rendered release approval mirror does not match")

    release_evidence_sha = (
        f"sha256:{hashlib.sha256(_canonical_json(release_evidence)).hexdigest()}"
    )
    if annotations["pakperk.app/release-evidence-sha256"] != release_evidence_sha:
        raise EvidenceError("rendered release-approval digest does not match")
    if (
        labels["app.kubernetes.io/version"] != chart.get("appVersion")
        or labels["helm.sh/chart"]
        != f"{chart.get('name')}-{chart.get('version')}"
    ):
        raise EvidenceError("rendered release ConfigMap chart labels do not match")
    return contract, release_binding, release_evidence_sha


def validate_rendered_deployment(
    rendered: bytes,
    binding_value: Mapping[str, Any],
    gate_ids_value: Mapping[str, str],
    old_client_policy: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Bind a completed rendered Helm manifest after gate IDs exist."""

    if not rendered or len(rendered) > MAX_RENDERED_MANIFEST_BYTES:
        raise EvidenceError("rendered deployment size is invalid")
    binding = _validate_binding(binding_value)
    if set(gate_ids_value) != set(GATES):
        raise EvidenceError("rendered deployment validation requires five gate IDs")
    gate_ids = {
        gate: _digest(gate_ids_value[gate], f"rendered deployment {gate}")
        for gate in GATES
    }
    contract, release_binding, release_evidence_sha = (
        _release_contract_from_rendered(rendered)
    )
    _exact_keys(contract, RELEASE_CONTRACT_KEYS, "rendered release contract")
    if type(contract["schemaVersion"]) is not int or contract["schemaVersion"] != 1:
        raise EvidenceError("rendered release contract schema is invalid")
    if contract["environment"] != "production":
        raise EvidenceError("rendered release contract is not production")
    features = _exact_keys(
        contract["features"], FEATURE_KEYS, "rendered release features"
    )
    if any(type(enabled) is not bool for enabled in features.values()):
        raise EvidenceError("rendered release feature is not boolean")
    _validate_release_feature_dependencies(features)
    approvals = _exact_keys(
        contract["releaseEvidence"],
        RELEASE_EVIDENCE_KEYS,
        "rendered release approvals",
    )
    for gate in GATES:
        if approvals[gate] != gate_ids[gate]:
            raise EvidenceError("rendered release approval ID does not match bundle")
    deep_reader_release_id = approvals["deepReaderReleaseId"]
    if any(features[key] for key in DEEP_READER_FEATURE_KEYS):
        _digest(
            deep_reader_release_id,
            "rendered Deep Reader release evidence bundle ID",
        )
    elif deep_reader_release_id:
        _digest(
            deep_reader_release_id,
            "rendered dormant Deep Reader release evidence bundle ID",
        )
    restore_id = _digest(approvals["restoreDrillId"], "rendered restore drill ID")
    if restore_id != binding["restore_drill_id"]:
        raise EvidenceError("rendered restore drill ID does not match approval binding")

    chart = _exact_keys(
        contract["chart"], {"name", "version", "appVersion"}, "rendered chart"
    )
    if (
        chart["name"] != "pakperk"
        or chart["version"] != binding["helm_chart_version"]
        or chart["appVersion"] != binding["helm_app_version"]
    ):
        raise EvidenceError("rendered chart identity does not match approval binding")
    images = _exact_keys(contract["images"], IMAGE_KEYS, "rendered images")
    for image in images.values():
        identity = _exact_keys(
            image, {"repository", "digest"}, "rendered image identity"
        )
        repository = identity["repository"]
        if (
            not isinstance(repository, str)
            or not repository
            or len(repository) > 255
            or repository != repository.lower()
        ):
            raise EvidenceError("rendered image repository is invalid")
        _digest(identity["digest"], "rendered image digest")
    if compute_deployment_images_id(images) != binding["deployment_images_sha256"]:
        raise EvidenceError("rendered images do not match approval binding")
    if (
        compute_release_configuration_id(contract)
        != binding["release_configuration_sha256"]
    ):
        raise EvidenceError("rendered release configuration does not match approval binding")
    _digest(contract["alertPolicySha256"], "rendered alert policy")
    _exact_keys(
        contract["legalPolicy"],
        {"documentVersion", "termsVersion", "communityGuidelinesVersion", "fulltext"},
        "rendered legal policy",
    )
    policy_id = None
    if old_client_policy is not None:
        policy_id = validate_old_client_policy(
            old_client_policy, expected_binding=binding
        )["content_id"]
    if features["toReadFirstEnforcement"] and policy_id is None:
        raise EvidenceError(
            "strict To Read First enforcement requires an approved old-client policy"
        )
    return {
        "rendered_manifest_sha256": f"sha256:{hashlib.sha256(rendered).hexdigest()}",
        "release_binding_sha256": release_binding,
        "release_evidence_sha256": release_evidence_sha,
        "restore_drill_id": restore_id,
        "deep_reader_release_id": deep_reader_release_id or None,
        "to_read_first_enforcement": features["toReadFirstEnforcement"],
        "old_client_policy_id": policy_id,
    }


def read_rendered_deployment(
    path: pathlib.Path,
    binding: Mapping[str, Any],
    gate_ids: Mapping[str, str],
    old_client_policy: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    return validate_rendered_deployment(
        _read_bounded(path, maximum=MAX_RENDERED_MANIFEST_BYTES),
        binding,
        gate_ids,
        old_client_policy,
    )


def _validate_run(value: Any) -> tuple[dt.datetime, dt.datetime]:
    run = _exact_keys(value, RUN_KEYS, "run")
    if run["outcome"] != "passed":
        raise EvidenceError("production approval evidence must record a passed run")
    started = _parse_utc(run["started_at"], "run started_at")
    completed = _parse_utc(run["completed_at"], "run completed_at")
    if not started <= completed <= started + dt.timedelta(days=7):
        raise EvidenceError("approval verification window is invalid")
    return started, completed


def _validate_artifacts(value: Any, spec: GateSpec) -> None:
    if not isinstance(value, list) or len(value) != len(spec.artifacts):
        raise EvidenceError("gate artifact inventory is incomplete")
    for expected_id, raw in zip(spec.artifacts, value, strict=True):
        artifact = _exact_keys(raw, ARTIFACT_KEYS, "artifact")
        if artifact["id"] != expected_id:
            raise EvidenceError("gate artifacts are incomplete or reordered")
        _digest(artifact["sha256"], f"artifact {expected_id} digest")
        _positive_int(
            artifact["size_bytes"],
            f"artifact {expected_id} size",
            maximum=1024 * 1024 * 1024,
        )


def _validate_assertions(value: Any, spec: GateSpec) -> None:
    if not isinstance(value, list) or len(value) != len(spec.assertions):
        raise EvidenceError("gate assertion inventory is incomplete")
    for expected_id, raw in zip(spec.assertions, value, strict=True):
        assertion = _exact_keys(raw, ASSERTION_KEYS, "assertion")
        if assertion["id"] != expected_id or assertion["outcome"] != "passed":
            raise EvidenceError("gate assertions are incomplete, reordered, or failed")


def _validate_date(value: Any, label: str) -> None:
    if not isinstance(value, str) or len(value) != 10:
        raise EvidenceError(f"{label} is not an exact date")
    try:
        parsed = dt.date.fromisoformat(value)
    except ValueError as error:
        raise EvidenceError(f"{label} is not a valid date") from error
    if parsed.isoformat() != value:
        raise EvidenceError(f"{label} is not canonical")


def _measurement_map(value: Any, spec: GateSpec) -> dict[str, Any]:
    if not isinstance(value, list) or len(value) != len(spec.measurement_keys):
        raise EvidenceError("gate measurement inventory is incomplete")
    measurements: dict[str, Any] = {}
    for expected_id, raw in zip(spec.measurement_keys, value, strict=True):
        measurement = _exact_keys(raw, MEASUREMENT_KEYS, "measurement")
        if measurement["id"] != expected_id:
            raise EvidenceError("gate measurements are incomplete or reordered")
        measurements[expected_id] = measurement["value"]
    return measurements


def _validate_measurements(gate: str, value: Any, approved_at: dt.datetime) -> None:
    spec = GATE_SPECS[gate]
    measurements = _measurement_map(value, spec)
    if gate == "legalReviewId":
        _validate_date(measurements["document_version"], "legal document version")
        if (
            _positive_int(
                measurements["published_routes_checked"],
                "published legal routes",
                maximum=100,
            )
            != 4
        ):
            raise EvidenceError(
                "legal evidence must check exactly four published routes"
            )
        attempts = _positive_int(
            measurements["support_canary_attempts"],
            "support canary attempts",
            maximum=100,
        )
        successes = _positive_int(
            measurements["support_canary_successes"],
            "support canary successes",
            maximum=100,
        )
        if attempts != successes:
            raise EvidenceError("every bounded support canary must succeed")
        for key in (
            "enabled_features_sha256",
            "sdk_processor_inventory_sha256",
            "data_practices_sha256",
            "retention_schedule_sha256",
            "jurisdictions_contracts_sha256",
        ):
            _digest(measurements[key], f"legal measurement {key}")
    elif gate == "reviewerFlowId":
        if (
            _positive_int(
                measurements["walkthrough_steps_passed"],
                "reviewer walkthrough steps",
                maximum=100,
            )
            != 9
        ):
            raise EvidenceError(
                "reviewer evidence must pass the exact nine-step walkthrough"
            )
        expires = _parse_utc(
            measurements["account_expires_at"], "reviewer account expiry"
        )
        if not approved_at < expires <= approved_at + dt.timedelta(days=90):
            raise EvidenceError(
                "reviewer account expiry is outside the approved lifecycle"
            )
        for key in (
            "account_lifecycle_sha256",
            "reviewer_notes_sha256",
            "physical_acceptance_id",
            "account_deletion_e2e_id",
            "sbom_inventory_sha256",
            "legal_review_id",
            "strict_content_review_id",
        ):
            _digest(measurements[key], f"reviewer measurement {key}")
    elif gate == "strictContentReviewId":
        if measurements["fulltext_policy"] != "strict":
            raise EvidenceError("content evidence must bind the strict policy")
        _positive_int(
            measurements["allowed_surface_checks"],
            "allowed surface checks",
            minimum=4,
            maximum=1000,
        )
        _positive_int(
            measurements["introduction_behavior_checks"],
            "introduction behavior checks",
            minimum=2,
            maximum=1000,
        )
        if (
            _positive_int(
                measurements["derived_fallback_exposures"],
                "derived fallback exposures",
                minimum=0,
                maximum=1000,
            )
            != 0
        ):
            raise EvidenceError("strict evidence observed a derived fallback exposure")
        _digest(measurements["configuration_sha256"], "strict configuration digest")
        _digest(
            measurements["retention_display_policy_sha256"],
            "strict retention/display policy digest",
        )
    elif gate == "moderationReadinessId":
        _positive_int(
            measurements["operator_boundary_cases_passed"],
            "operator boundary cases",
            minimum=4,
            maximum=1000,
        )
        if (
            _positive_int(
                measurements["live_queue_types_exercised"],
                "live moderation queue types",
                maximum=100,
            )
            != 4
        ):
            raise EvidenceError(
                "moderation evidence must exercise all four live queue types"
            )
        if (
            _positive_int(
                measurements["moderation_actions_exercised"],
                "moderation actions",
                maximum=100,
            )
            != 6
        ):
            raise EvidenceError(
                "moderation evidence must exercise all six moderation actions"
            )
        _positive_int(
            measurements["audit_records_verified"],
            "moderation audit records",
            minimum=6,
            maximum=10000,
        )
        _positive_int(
            measurements["alert_ticket_canaries_passed"],
            "moderation alert/ticket canaries",
            minimum=2,
            maximum=100,
        )
        _positive_int(
            measurements["staffed_response_target_seconds"],
            "staffed response target",
            maximum=7 * 24 * 60 * 60,
        )
        _positive_int(
            measurements["escalation_exercises_passed"],
            "moderation escalation exercises",
            maximum=100,
        )
        _digest(
            measurements["moderation_audit_inventory_sha256"],
            "moderation audit inventory",
        )
    elif gate == "accountDeletionE2eId":
        for key in (
            "reauthentication_rejections",
            "reauthentication_acceptances",
            "replay_attempts",
            "alert_canaries_passed",
        ):
            _positive_int(
                measurements[key], f"deletion measurement {key}", maximum=1000
            )
        purged = _positive_int(
            measurements["application_rows_purged"],
            "purged application rows",
            minimum=0,
            maximum=10_000_000,
        )
        pseudonymized = _positive_int(
            measurements["application_rows_pseudonymized"],
            "pseudonymized application rows",
            minimum=0,
            maximum=10_000_000,
        )
        if purged + pseudonymized < 1:
            raise EvidenceError(
                "deletion evidence must record a data-removal side effect"
            )
        ledger_records = _positive_int(
            measurements["external_ledger_records"],
            "external ledger records",
            maximum=100,
        )
        database_jobs = _positive_int(
            measurements["database_jobs"], "deletion database jobs", maximum=100
        )
        if ledger_records != 1 or database_jobs != 1:
            raise EvidenceError(
                "deletion evidence must bind exactly one ledger record and job"
            )
        for key in (
            "operation_id_sha256",
            "secret_manager_reference_sha256",
            "ledger_inventory_sha256",
            "backup_inventory_sha256",
        ):
            _digest(measurements[key], f"deletion measurement {key}")
    else:  # pragma: no cover - the closed gate map makes this unreachable.
        raise EvidenceError("unsupported production approval gate")


def _validate_approval(
    value: Any, spec: GateSpec, completed_at: dt.datetime
) -> dt.datetime:
    approval = _exact_keys(value, APPROVAL_KEYS, "approval")
    if approval["role"] != spec.approval_role or approval["decision"] != "approved":
        raise EvidenceError("approval role or decision does not match the gate")
    approved_at = _parse_utc(approval["approved_at"], "approval timestamp")
    if not completed_at <= approved_at <= completed_at + dt.timedelta(days=7):
        raise EvidenceError("approval timestamp is outside the verification window")
    _digest(approval["protected_audit_reference"], "protected audit reference")
    return approved_at


def _validate_sanitization(value: Any) -> None:
    if (
        not isinstance(value, dict)
        or set(value) != set(SANITIZATION)
        or any(value[key] is not False for key in SANITIZATION)
    ):
        raise EvidenceError("sanitization exclusions are incomplete")


def _reject_sensitive_shapes(value: Mapping[str, Any]) -> None:
    encoded = _canonical_json(value).decode("ascii")
    if EMAIL_RE.search(encoded) or JWT_RE.search(encoded):
        raise EvidenceError(
            "evidence contains credential or personal-data shaped content"
        )


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
        or root["schema_version"] != EVIDENCE_SCHEMA_VERSION
    ):
        raise EvidenceError("evidence schema version is invalid")
    if root["classification"] != EVIDENCE_CLASSIFICATION:
        raise EvidenceError(
            "reference or unapproved evidence classification is forbidden"
        )
    gate = root["gate"]
    if not isinstance(gate, str) or gate not in GATE_SPECS:
        raise EvidenceError("evidence gate is invalid")
    if expected_gate is not None and gate != expected_gate:
        raise EvidenceError("evidence gate does not match the expected gate")
    binding = _validate_binding(root["binding"])
    if expected_binding is not None and binding != _validate_binding(expected_binding):
        raise EvidenceError("evidence binding does not match the expected release")
    _, completed_at = _validate_run(root["run"])
    spec = GATE_SPECS[gate]
    _validate_artifacts(root["artifacts"], spec)
    _validate_assertions(root["assertions"], spec)
    approval = _validate_approval(root["approval"], spec, completed_at)
    _validate_measurements(gate, root["measurements"], approval)
    _validate_sanitization(root["sanitization"])
    _reject_sensitive_shapes(root)
    actual_id = root["content_id"]
    if not isinstance(actual_id, str) or SHA256_RE.fullmatch(actual_id) is None:
        raise EvidenceError("evidence content ID is invalid")
    computed_id = compute_evidence_content_id(root)
    if actual_id != computed_id:
        raise EvidenceError(
            "evidence content ID does not match its canonical statement"
        )
    if expected_content_id is not None and actual_id != _digest(
        expected_content_id, "expected gate ID"
    ):
        raise EvidenceError("evidence content ID does not match the expected gate ID")
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


def build_evidence(
    gate: str,
    binding: Mapping[str, Any],
    *,
    started_at: str,
    completed_at: str,
    approved_at: str,
    protected_audit_reference: str,
    artifacts: Mapping[str, tuple[str, int]],
    measurements: Mapping[str, Any],
) -> dict[str, Any]:
    if gate not in GATE_SPECS:
        raise EvidenceError("evidence gate is invalid")
    spec = GATE_SPECS[gate]
    if set(artifacts) != set(spec.artifacts):
        raise EvidenceError("gate artifact inputs are incomplete")
    if set(measurements) != set(spec.measurement_keys):
        raise EvidenceError("gate measurement inputs are incomplete")
    statement: dict[str, Any] = {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "classification": EVIDENCE_CLASSIFICATION,
        "gate": gate,
        "binding": copy.deepcopy(dict(binding)),
        "run": {
            "outcome": "passed",
            "started_at": started_at,
            "completed_at": completed_at,
        },
        "artifacts": [
            {
                "id": artifact_id,
                "sha256": artifacts[artifact_id][0],
                "size_bytes": artifacts[artifact_id][1],
            }
            for artifact_id in spec.artifacts
        ],
        "assertions": [
            {"id": assertion_id, "outcome": "passed"}
            for assertion_id in spec.assertions
        ],
        "measurements": [
            {
                "id": measurement_id,
                "value": copy.deepcopy(measurements[measurement_id]),
            }
            for measurement_id in spec.measurement_keys
        ],
        "approval": {
            "role": spec.approval_role,
            "decision": "approved",
            "approved_at": approved_at,
            "protected_audit_reference": protected_audit_reference,
        },
        "sanitization": dict(SANITIZATION),
    }
    evidence = dict(statement)
    evidence["content_id"] = compute_evidence_content_id(evidence)
    return validate_evidence(evidence, expected_gate=gate, expected_binding=binding)


def build_bundle(
    binding: Mapping[str, Any],
    gate_ids: Mapping[str, str],
    deployment: Mapping[str, Any],
) -> dict[str, Any]:
    _validate_binding(binding)
    if set(gate_ids) != set(GATES):
        raise EvidenceError("predeploy bundle must contain all five exact gate IDs")
    validated_deployment = _validate_bundle_deployment(deployment, binding, gate_ids)
    statement: dict[str, Any] = {
        "schema_version": BUNDLE_SCHEMA_VERSION,
        "classification": BUNDLE_CLASSIFICATION,
        "binding": copy.deepcopy(dict(binding)),
        "deployment": validated_deployment,
        "gates": [
            {"gate": gate, "content_id": _digest(gate_ids[gate], f"bundle {gate} ID")}
            for gate in GATES
        ],
    }
    bundle = dict(statement)
    bundle["content_id"] = compute_bundle_content_id(bundle)
    return validate_bundle(bundle)


def _validate_bundle_deployment(
    value: Any,
    binding_value: Mapping[str, Any],
    gate_ids_value: Mapping[str, str],
) -> dict[str, Any]:
    deployment = _exact_keys(
        value, BUNDLE_DEPLOYMENT_KEYS, "bundle deployment binding"
    )
    binding = _validate_binding(binding_value)
    if set(gate_ids_value) != set(GATES):
        raise EvidenceError("bundle deployment gate inventory is incomplete")
    gate_ids = {
        gate: _digest(gate_ids_value[gate], f"bundle deployment {gate}")
        for gate in GATES
    }
    for key in (
        "rendered_manifest_sha256",
        "release_binding_sha256",
        "release_evidence_sha256",
        "restore_drill_id",
    ):
        _digest(deployment[key], f"bundle deployment {key}")
    deep_reader_release_id = deployment["deep_reader_release_id"]
    if deep_reader_release_id is not None:
        _digest(deep_reader_release_id, "bundle Deep Reader release evidence ID")
    if deployment["restore_drill_id"] != binding["restore_drill_id"]:
        raise EvidenceError("bundle restore drill ID does not match release binding")
    policy_id = deployment["old_client_policy_id"]
    if type(deployment["to_read_first_enforcement"]) is not bool:
        raise EvidenceError("bundle enforcement policy is not boolean")
    if deployment["to_read_first_enforcement"] and policy_id is None:
        raise EvidenceError("strict bundle is missing its old-client policy")
    if policy_id is not None:
        _digest(policy_id, "bundle old-client policy ID")
    release_evidence = {
        **gate_ids,
        "restoreDrillId": binding["restore_drill_id"],
        "deepReaderReleaseId": deep_reader_release_id or "",
    }
    expected_approval_sha = (
        f"sha256:{hashlib.sha256(_canonical_json(release_evidence)).hexdigest()}"
    )
    if deployment["release_evidence_sha256"] != expected_approval_sha:
        raise EvidenceError("bundle release-approval digest does not match gate IDs")
    return dict(deployment)


def validate_bundle(value: Any) -> dict[str, Any]:
    root = _exact_keys(value, BUNDLE_KEYS, "bundle root")
    if (
        type(root["schema_version"]) is not int
        or root["schema_version"] != BUNDLE_SCHEMA_VERSION
    ):
        raise EvidenceError("bundle schema version is invalid")
    if root["classification"] != BUNDLE_CLASSIFICATION:
        raise EvidenceError("bundle classification is invalid")
    binding = _validate_binding(root["binding"])
    gates = root["gates"]
    if not isinstance(gates, list) or len(gates) != len(GATES):
        raise EvidenceError("bundle gate inventory is incomplete")
    gate_ids: dict[str, str] = {}
    for expected_gate, raw in zip(GATES, gates, strict=True):
        item = _exact_keys(raw, BUNDLE_GATE_KEYS, "bundle gate")
        if item["gate"] != expected_gate:
            raise EvidenceError("bundle gates are incomplete or reordered")
        _digest(item["content_id"], f"bundle {expected_gate} ID")
        gate_ids[expected_gate] = item["content_id"]
    _validate_bundle_deployment(root["deployment"], binding, gate_ids)
    actual_id = root["content_id"]
    if not isinstance(actual_id, str) or SHA256_RE.fullmatch(actual_id) is None:
        raise EvidenceError("bundle content ID is invalid")
    if actual_id != compute_bundle_content_id(root):
        raise EvidenceError("bundle content ID does not match its canonical statement")
    _reject_sensitive_shapes(root)
    return copy.deepcopy(root)


def read_bundle(path: pathlib.Path) -> dict[str, Any]:
    return validate_bundle(_read_canonical(path))


def validate_predeploy(
    bundle: Mapping[str, Any],
    manifests: Mapping[str, Mapping[str, Any]],
    old_client_policy: Mapping[str, Any] | None = None,
) -> dict[str, dict[str, Any]]:
    validated_bundle = validate_bundle(bundle)
    if set(manifests) != set(GATES):
        raise EvidenceError("predeploy validation requires all five exact manifests")
    expected_binding = validated_bundle["binding"]
    expected_ids = {
        item["gate"]: item["content_id"] for item in validated_bundle["gates"]
    }
    validated: dict[str, dict[str, Any]] = {}
    for gate in GATES:
        validated[gate] = validate_evidence(
            manifests[gate],
            expected_gate=gate,
            expected_content_id=expected_ids[gate],
            expected_binding=expected_binding,
        )
    reviewer = _measurement_map(
        validated["reviewerFlowId"]["measurements"],
        GATE_SPECS["reviewerFlowId"],
    )
    if (
        reviewer["legal_review_id"] != expected_ids["legalReviewId"]
        or reviewer["strict_content_review_id"] != expected_ids["strictContentReviewId"]
        or reviewer["account_deletion_e2e_id"] != expected_ids["accountDeletionE2eId"]
    ):
        raise EvidenceError(
            "reviewer evidence references do not match the predeploy gate IDs"
        )
    expected_policy_id = validated_bundle["deployment"]["old_client_policy_id"]
    if expected_policy_id is None:
        if old_client_policy is not None:
            raise EvidenceError("old-client policy is not bound by this bundle")
    elif old_client_policy is None:
        raise EvidenceError("predeploy validation requires the old-client policy")
    else:
        validate_old_client_policy(
            old_client_policy,
            expected_binding=expected_binding,
            expected_content_id=expected_policy_id,
        )
    return validated


def _write_exclusive(path: pathlib.Path, value: Mapping[str, Any]) -> None:
    destination = path.absolute()
    parent = destination.parent
    if (
        not parent.is_dir()
        or parent.is_symlink()
        or stat.S_IMODE(parent.stat().st_mode) & 0o022
    ):
        raise EvidenceError("output parent is missing, linked, or group/other writable")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(destination, flags, 0o600)
    except OSError as error:
        raise EvidenceError("output path is not fresh") from error
    try:
        payload = encode_canonical_document(value)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise EvidenceError("could not write canonical output")
            view = view[written:]
        os.fsync(descriptor)
    except Exception:
        try:
            os.unlink(destination)
        except OSError:
            pass
        raise
    finally:
        os.close(descriptor)


def _gate_paths(values: Sequence[str]) -> dict[str, pathlib.Path]:
    result: dict[str, pathlib.Path] = {}
    for value in values:
        gate, separator, raw_path = value.partition("=")
        if not separator or gate not in GATE_SPECS or not raw_path or gate in result:
            raise EvidenceError("manifest arguments must be unique GATE=PATH values")
        result[gate] = pathlib.Path(raw_path)
    if set(result) != set(GATES):
        raise EvidenceError(
            "exactly one manifest for every production gate is required"
        )
    return result


def _load_manifest_set(values: Sequence[str]) -> dict[str, dict[str, Any]]:
    return {
        gate: read_evidence(path, expected_gate=gate)
        for gate, path in _gate_paths(values).items()
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate canonical Pakperk production approval evidence."
    )
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate", help="validate one gate manifest")
    validate.add_argument("manifest", type=pathlib.Path)
    validate.add_argument("--gate", choices=GATES)
    validate.add_argument("--expected-id")

    validate_policy = commands.add_parser(
        "validate-old-client-policy",
        help="validate one owner-approved old-client policy",
    )
    validate_policy.add_argument("policy", type=pathlib.Path)
    validate_policy.add_argument("--expected-id")

    bundle = commands.add_parser(
        "bundle", help="create a predeploy bundle from five manifests"
    )
    bundle.add_argument(
        "--manifest", action="append", required=True, metavar="GATE=PATH"
    )
    bundle.add_argument("--rendered-manifest", required=True, type=pathlib.Path)
    bundle.add_argument("--old-client-policy", type=pathlib.Path)
    bundle.add_argument("--output", required=True, type=pathlib.Path)

    validate_bundle_command = commands.add_parser(
        "validate-bundle", help="validate one canonical predeploy bundle"
    )
    validate_bundle_command.add_argument("bundle", type=pathlib.Path)

    predeploy = commands.add_parser(
        "predeploy", help="verify five manifests against one predeploy bundle"
    )
    predeploy.add_argument("bundle", type=pathlib.Path)
    predeploy.add_argument(
        "--manifest", action="append", required=True, metavar="GATE=PATH"
    )
    predeploy.add_argument("--rendered-manifest", required=True, type=pathlib.Path)
    predeploy.add_argument("--old-client-policy", type=pathlib.Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "validate":
            evidence = read_evidence(
                arguments.manifest,
                expected_gate=arguments.gate,
                expected_content_id=arguments.expected_id,
            )
            print(
                f"Validated production approval evidence {evidence['gate']} {evidence['content_id']}."
            )
        elif arguments.command == "validate-old-client-policy":
            policy = read_old_client_policy(
                arguments.policy, expected_content_id=arguments.expected_id
            )
            print(
                "Validated production old-client policy "
                f"{policy['strategy']} {policy['content_id']}."
            )
        elif arguments.command == "bundle":
            manifests = _load_manifest_set(arguments.manifest)
            bindings = [manifests[gate]["binding"] for gate in GATES]
            if any(binding != bindings[0] for binding in bindings[1:]):
                raise EvidenceError(
                    "gate manifests do not share one exact release binding"
                )
            gate_ids = {gate: manifests[gate]["content_id"] for gate in GATES}
            policy = (
                read_old_client_policy(
                    arguments.old_client_policy, expected_binding=bindings[0]
                )
                if arguments.old_client_policy is not None
                else None
            )
            deployment = read_rendered_deployment(
                arguments.rendered_manifest, bindings[0], gate_ids, policy
            )
            bundle = build_bundle(bindings[0], gate_ids, deployment)
            validate_predeploy(bundle, manifests, policy)
            _write_exclusive(arguments.output, bundle)
            print(
                f"Created production approval predeploy bundle {bundle['content_id']}."
            )
        elif arguments.command == "validate-bundle":
            bundle = read_bundle(arguments.bundle)
            print(
                f"Validated production approval predeploy bundle {bundle['content_id']}."
            )
        elif arguments.command == "predeploy":
            bundle = read_bundle(arguments.bundle)
            manifests = _load_manifest_set(arguments.manifest)
            policy = (
                read_old_client_policy(
                    arguments.old_client_policy,
                    expected_binding=bundle["binding"],
                )
                if arguments.old_client_policy is not None
                else None
            )
            validate_predeploy(bundle, manifests, policy)
            gate_ids = {
                gate: manifests[gate]["content_id"] for gate in GATES
            }
            deployment = read_rendered_deployment(
                arguments.rendered_manifest,
                bundle["binding"],
                gate_ids,
                policy,
            )
            if deployment != bundle["deployment"]:
                raise EvidenceError(
                    "rendered deployment does not match the predeploy bundle"
                )
            print(
                f"Validated all five production approval gates for {bundle['content_id']}."
            )
        else:  # pragma: no cover
            raise EvidenceError("unsupported command")
    except EvidenceError as error:
        print(
            f"production approval evidence validation failed: {error}", file=sys.stderr
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
