#!/usr/bin/env python3
"""Validate fail-closed Plan 03 Deep Reader release-gate evidence.

The repository owns this closed data contract and its validators. It does not
run protected staging exercises, evaluate model output, perform legal or domain
review, inspect signed devices, or approve a release. A bundle validates only
when every gate carries every required repository and external evidence class;
one class can never stand in for another.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
MAX_DOCUMENT_BYTES = 512 * 1024
MAX_JSON_NESTING = 20
CLASSIFICATION = "protected deep-reader release evidence"
GATE_DOMAIN = b"pakperk/deep-reader-release-gate/v1\0"
BUNDLE_DOMAIN = b"pakperk/deep-reader-release-bundle/v1\0"

SOURCE_PRODUCERS = {
    "repository": "continuous_integration",
    "staging": "staging_operator",
    "human_domain": "domain_reviewer",
    "legal_review": "legal_reviewer",
    "live_model": "model_evaluation_owner",
    "signed_device": "mobile_release_owner",
    "live_telemetry": "telemetry_owner",
    "security_review": "privacy_security_reviewer",
    "accessibility_review": "accessibility_reviewer",
    "release_approval": "release_owner",
}

# Order is part of the contract. "repository" means executable source tests or
# checked-in, content-addressed evaluation output. Every other source is a
# protected human/live environment fact that repository tests cannot create.
GATE_REQUIREMENTS = {
    "grobid_block_preservation": ("repository", "staging"),
    "parser_benchmark_published": (
        "repository",
        "human_domain",
        "legal_review",
    ),
    "preparation_trigger_isolation": ("repository", "staging"),
    "preparation_idempotency": ("repository", "staging"),
    "passport_quality": ("repository", "human_domain"),
    "assistant_evidence_id_integrity": ("repository", "live_model"),
    "assistant_unsupported_citation": (
        "repository",
        "live_model",
        "human_domain",
    ),
    "assistant_method_detail_baseline": (
        "repository",
        "live_model",
        "human_domain",
    ),
    "annotation_durability": ("repository", "signed_device"),
    "concurrent_note_integrity": ("repository", "signed_device"),
    "visual_object_precision": ("repository", "human_domain"),
    "generated_artifact_source_navigation": ("repository", "signed_device"),
    "private_content_exclusion": (
        "repository",
        "live_telemetry",
        "security_review",
    ),
    "checkpoint_library_isolation": ("repository",),
    "document_end_library_isolation": ("repository", "signed_device"),
    "active_queue_auto_advance": ("repository", "signed_device"),
    "recommendation_save_cancellation": ("repository", "signed_device"),
    "final_item_server_confirmation": ("repository", "signed_device"),
    "uncertain_queue_no_fallback": ("repository", "signed_device"),
    "explicit_branch_feed_isolation": ("repository", "signed_device"),
    "strict_content_policy": ("repository", "legal_review"),
    "large_document_accessibility_performance": (
        "repository",
        "signed_device",
        "accessibility_review",
    ),
    "rollout_rollback": ("repository", "staging", "release_approval"),
}

GATE_ASSERTIONS = {
    "grobid_block_preservation": (
        "existing_demo_capabilities_preserved",
        "reference_resolution_preserved",
        "bounded_failure_fallback_preserved",
    ),
    "parser_benchmark_published": (
        "corpus_manifest_versioned",
        "corpus_rights_reviewed",
        "ground_truth_human_reviewed",
        "regression_thresholds_passed",
        "resource_budget_passed",
        "failure_fallback_defined",
        "reprocessing_and_rollback_tested",
    ),
    "preparation_trigger_isolation": (
        "feed_import_prefetch_rejected",
        "abstract_display_rejected",
        "rejected_attempts_auditable",
    ),
    "preparation_idempotency": (
        "approved_triggers_only",
        "one_generation_bounded_work",
        "concurrent_replay_idempotent",
    ),
    "passport_quality": (
        "field_evidence_precision_threshold_passed",
        "missing_field_abstention_threshold_passed",
        "inference_and_conflict_labels_passed",
    ),
    "assistant_evidence_id_integrity": (
        "invented_evidence_ids_zero",
        "stale_generation_rejected",
        "untrusted_paper_instructions_ignored",
    ),
    "assistant_unsupported_citation": (
        "unsupported_citation_threshold_passed",
        "claim_level_evidence_validated",
        "abstention_threshold_passed",
    ),
    "assistant_method_detail_baseline": (
        "method_quality_not_worse_than_baseline",
        "detail_quality_not_worse_than_baseline",
        "latency_and_cost_budget_passed",
    ),
    "annotation_durability": (
        "restart_and_reflow_passed",
        "parser_patch_and_version_behavior_explicit",
        "export_import_fidelity_passed",
    ),
    "concurrent_note_integrity": (
        "conflict_is_detected",
        "silent_loss_zero",
        "offline_reconciliation_passed",
    ),
    "visual_object_precision": (
        "figure_caption_precision_threshold_passed",
        "table_structure_threshold_passed",
        "equation_availability_threshold_passed",
    ),
    "generated_artifact_source_navigation": (
        "passport_source_navigation_passed",
        "assistant_source_navigation_passed",
        "visual_and_annotation_source_navigation_passed",
    ),
    "private_content_exclusion": (
        "telemetry_private_content_absent",
        "recommendation_inputs_private_content_absent",
        "logs_and_crash_reports_private_content_absent",
    ),
    "checkpoint_library_isolation": (
        "checkpoint_write_cannot_mutate_library",
        "checkpoint_write_cannot_change_queue_eligibility",
    ),
    "document_end_library_isolation": (
        "document_end_does_not_mark_reviewed",
        "document_end_does_not_archive_or_remove",
    ),
    "active_queue_auto_advance": (
        "automatic_next_uses_active_queue_only",
        "automatic_recommendation_leakage_zero",
    ),
    "recommendation_save_cancellation": (
        "save_cancels_recommendation_navigation",
        "server_confirmation_precedes_queue_navigation",
    ),
    "final_item_server_confirmation": (
        "final_transition_waits_for_server_emptiness",
        "pending_state_cannot_fall_back",
    ),
    "uncertain_queue_no_fallback": (
        "unknown_state_cannot_fall_back",
        "stale_cursor_cannot_mix_content",
        "offline_state_cannot_fall_back",
        "account_transition_rejects_old_responses",
    ),
    "explicit_branch_feed_isolation": (
        "search_branch_does_not_inject",
        "connections_branch_does_not_inject",
        "memory_branch_does_not_inject",
        "origin_return_preserved",
    ),
    "strict_content_policy": (
        "strict_policy_enforced",
        "asset_authorization_enforced",
        "quote_and_export_boundary_reviewed",
    ),
    "large_document_accessibility_performance": (
        "large_document_device_budget_passed",
        "text_scale_and_reduced_motion_passed",
        "screen_reader_math_table_figure_navigation_passed",
        "selection_toolbar_accessibility_passed",
    ),
    "rollout_rollback": (
        "parser_rollback_tested",
        "model_rollback_tested",
        "queue_navigation_rollback_tested",
        "reprocessing_plan_tested",
        "staged_enablement_tested",
    ),
}

GATES = tuple(GATE_REQUIREMENTS)

ROOT_KEYS = {
    "schema_version",
    "content_id",
    "classification",
    "gate",
    "binding",
    "run",
    "sources",
    "assertions",
    "sanitization",
}
BINDING_KEYS = {
    "source_revision",
    "target_environment",
    "release_configuration_sha256",
    "deployment_images_sha256",
    "parser_adapter",
    "parser_version",
    "document_schema_version",
    "model_configuration_sha256",
    "prompt_version",
    "corpus_manifest_sha256",
    "mobile_candidate_id",
}
RUN_KEYS = {"outcome", "started_at", "completed_at"}
SOURCE_KEYS = {
    "kind",
    "producer",
    "outcome",
    "content_id",
    "completed_at",
}
ASSERTION_KEYS = {"id", "outcome"}
BUNDLE_KEYS = {
    "schema_version",
    "content_id",
    "classification",
    "binding",
    "gates",
    "approval",
    "sanitization",
}
BUNDLE_GATE_KEYS = {"gate", "content_id"}
APPROVAL_KEYS = {
    "role",
    "decision",
    "approved_at",
    "protected_audit_reference",
}
SANITIZATION = {
    "contains_credentials": False,
    "contains_tokens": False,
    "contains_personal_data": False,
    "contains_private_annotations": False,
    "contains_paper_text": False,
    "contains_raw_model_io": False,
    "contains_device_identifiers": False,
    "contains_unbounded_logs": False,
}

SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
REVISION_RE = re.compile(r"[0-9a-f]{40}\Z")
SEMVER_RE = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\Z"
)
SAFE_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+-]{0,127}\Z")
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")


class EvidenceError(ValueError):
    """Raised when protected evidence does not satisfy the closed contract."""


def _canonical_bytes(value: Any) -> bytes:
    try:
        return (
            json.dumps(
                value,
                allow_nan=False,
                ensure_ascii=True,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise EvidenceError("evidence is not canonical JSON data") from error


def encode_canonical_document(value: Any) -> bytes:
    """Encode a document exactly as protected producers must persist it."""

    return _canonical_bytes(value)


def _duplicate_rejecting_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise EvidenceError(f"non-finite JSON constant {value!r} is forbidden")


def _depth(value: Any, depth: int = 0) -> None:
    if depth > MAX_JSON_NESTING:
        raise EvidenceError("evidence exceeds the JSON nesting boundary")
    if isinstance(value, dict):
        for item in value.values():
            _depth(item, depth + 1)
    elif isinstance(value, list):
        for item in value:
            _depth(item, depth + 1)


def strict_json(data: bytes) -> Any:
    if not data or len(data) > MAX_DOCUMENT_BYTES:
        raise EvidenceError("evidence document size is invalid")
    try:
        text = data.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_constant,
        )
    except EvidenceError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise EvidenceError("evidence is not strict UTF-8 JSON") from error
    _depth(value)
    if _canonical_bytes(value) != data:
        raise EvidenceError("evidence is not canonical JSON")
    return value


def read_document(path: Path) -> Any:
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise EvidenceError(f"{path} is not a regular evidence file")
    if metadata.st_mode & 0o077:
        raise EvidenceError(f"{path} must not be readable or writable by group/other")
    return strict_json(path.read_bytes())


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise EvidenceError(f"{label} must contain the exact required keys")
    return dict(value)


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a sha256 content identifier")
    payload = value.removeprefix("sha256:")
    if len(set(payload)) == 1:
        raise EvidenceError(f"{label} is an obvious placeholder digest")
    return value


def _safe_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or SAFE_ID_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not a bounded safe identifier")
    lowered = value.lower()
    if any(marker in lowered for marker in ("placeholder", "changeme", "replace", "todo")):
        raise EvidenceError(f"{label} is an obvious placeholder")
    return value


def _utc(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} is not canonical UTC")
    parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=dt.timezone.utc
    )
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise EvidenceError(f"{label} is not canonical UTC")
    return parsed


def _validate_binding(value: Any) -> dict[str, Any]:
    binding = _exact(value, BINDING_KEYS, "release binding")
    revision = binding["source_revision"]
    if (
        not isinstance(revision, str)
        or REVISION_RE.fullmatch(revision) is None
        or len(set(revision)) == 1
    ):
        raise EvidenceError("source revision is invalid")
    if binding["target_environment"] not in {"staging", "production"}:
        raise EvidenceError("target environment is invalid")
    for key in (
        "release_configuration_sha256",
        "deployment_images_sha256",
        "model_configuration_sha256",
        "corpus_manifest_sha256",
        "mobile_candidate_id",
    ):
        _sha256(binding[key], key)
    _safe_id(binding["parser_adapter"], "parser adapter")
    _safe_id(binding["parser_version"], "parser version")
    _safe_id(binding["prompt_version"], "prompt version")
    if (
        type(binding["document_schema_version"]) is not int
        or not 1 <= binding["document_schema_version"] <= 2**31 - 1
    ):
        raise EvidenceError("document schema version is invalid")
    return binding


def _compute_content_id(value: Mapping[str, Any], domain: bytes) -> str:
    normalized = copy.deepcopy(dict(value))
    normalized["content_id"] = ""
    return "sha256:" + hashlib.sha256(domain + _canonical_bytes(normalized)).hexdigest()


def compute_gate_content_id(value: Mapping[str, Any]) -> str:
    return _compute_content_id(value, GATE_DOMAIN)


def compute_bundle_content_id(value: Mapping[str, Any]) -> str:
    return _compute_content_id(value, BUNDLE_DOMAIN)


def _validate_sanitization(value: Any) -> None:
    if value != SANITIZATION:
        raise EvidenceError("sanitization declaration is incomplete or unsafe")


def validate_gate(value: Any, expected_gate: str | None = None) -> dict[str, Any]:
    root = _exact(value, ROOT_KEYS, "gate evidence")
    if root["schema_version"] != SCHEMA_VERSION or isinstance(
        root["schema_version"], bool
    ):
        raise EvidenceError("gate evidence schema is unsupported")
    if root["classification"] != CLASSIFICATION:
        raise EvidenceError("gate evidence classification is invalid")
    gate = root["gate"]
    if gate not in GATE_REQUIREMENTS or (
        expected_gate is not None and gate != expected_gate
    ):
        raise EvidenceError("gate evidence names an unknown or unexpected gate")
    binding = _validate_binding(root["binding"])
    run = _exact(root["run"], RUN_KEYS, "gate run")
    if run["outcome"] != "passed":
        raise EvidenceError("gate run did not pass")
    started = _utc(run["started_at"], "gate run started_at")
    completed = _utc(run["completed_at"], "gate run completed_at")
    if not started <= completed <= started + dt.timedelta(days=14):
        raise EvidenceError("gate run window is invalid")

    required_sources = GATE_REQUIREMENTS[gate]
    sources = root["sources"]
    if not isinstance(sources, list) or len(sources) != len(required_sources):
        raise EvidenceError("gate evidence source inventory is incomplete")
    for expected_kind, raw in zip(required_sources, sources, strict=True):
        source = _exact(raw, SOURCE_KEYS, "gate evidence source")
        if source["kind"] != expected_kind:
            raise EvidenceError("gate evidence source class is missing or reordered")
        if source["producer"] != SOURCE_PRODUCERS[expected_kind]:
            raise EvidenceError("gate evidence source producer is invalid")
        if source["outcome"] != "passed":
            raise EvidenceError("gate evidence source did not pass")
        _sha256(source["content_id"], f"{expected_kind} evidence content ID")
        source_completed = _utc(
            source["completed_at"], f"{expected_kind} evidence completed_at"
        )
        if not started <= source_completed <= completed:
            raise EvidenceError("gate evidence source is outside the run window")

    expected_assertions = GATE_ASSERTIONS[gate]
    assertions = root["assertions"]
    if not isinstance(assertions, list) or len(assertions) != len(
        expected_assertions
    ):
        raise EvidenceError("gate assertion inventory is incomplete")
    for expected_id, raw in zip(expected_assertions, assertions, strict=True):
        assertion = _exact(raw, ASSERTION_KEYS, "gate assertion")
        if assertion["id"] != expected_id or assertion["outcome"] != "passed":
            raise EvidenceError("gate assertion is missing, reordered, or failed")

    _validate_sanitization(root["sanitization"])
    expected_id = compute_gate_content_id(root)
    if root["content_id"] != expected_id:
        raise EvidenceError("gate evidence content ID does not match")
    root["binding"] = binding
    return root


def validate_bundle(
    value: Any, gate_manifests: Mapping[str, Mapping[str, Any]]
) -> dict[str, Any]:
    root = _exact(value, BUNDLE_KEYS, "release evidence bundle")
    if root["schema_version"] != SCHEMA_VERSION or isinstance(
        root["schema_version"], bool
    ):
        raise EvidenceError("release evidence bundle schema is unsupported")
    if root["classification"] != CLASSIFICATION:
        raise EvidenceError("release evidence bundle classification is invalid")
    binding = _validate_binding(root["binding"])
    if set(gate_manifests) != set(GATES):
        missing = sorted(set(GATES) - set(gate_manifests))
        extra = sorted(set(gate_manifests) - set(GATES))
        raise EvidenceError(
            f"release evidence bundle requires every gate; missing={missing}, extra={extra}"
        )
    gates = root["gates"]
    if not isinstance(gates, list) or len(gates) != len(GATES):
        raise EvidenceError("release evidence bundle gate inventory is incomplete")

    latest_completion: dt.datetime | None = None
    for expected_gate, raw_gate in zip(GATES, gates, strict=True):
        gate_reference = _exact(raw_gate, BUNDLE_GATE_KEYS, "bundle gate")
        if gate_reference["gate"] != expected_gate:
            raise EvidenceError("release evidence bundle gates are missing or reordered")
        manifest = validate_gate(gate_manifests[expected_gate], expected_gate)
        if manifest["binding"] != binding:
            raise EvidenceError("gate evidence binding does not match the bundle")
        if gate_reference["content_id"] != manifest["content_id"]:
            raise EvidenceError("bundle gate content ID does not match its evidence")
        completed = _utc(manifest["run"]["completed_at"], "gate completion")
        latest_completion = max(latest_completion or completed, completed)

    approval = _exact(root["approval"], APPROVAL_KEYS, "bundle approval")
    if approval["role"] != "release_owner" or approval["decision"] != "approved":
        raise EvidenceError("release evidence bundle lacks release-owner approval")
    approved_at = _utc(approval["approved_at"], "bundle approval time")
    if latest_completion is None or not (
        latest_completion <= approved_at <= latest_completion + dt.timedelta(days=14)
    ):
        raise EvidenceError("bundle approval is outside the bounded post-run window")
    _safe_id(
        approval["protected_audit_reference"],
        "bundle protected audit reference",
    )
    _validate_sanitization(root["sanitization"])
    expected_id = compute_bundle_content_id(root)
    if root["content_id"] != expected_id:
        raise EvidenceError("release evidence bundle content ID does not match")
    root["binding"] = binding
    return root


def gate_inventory() -> dict[str, Any]:
    """Return requirements only; this inventory never represents a pass."""

    return {
        "schema_version": SCHEMA_VERSION,
        "status": "requirements_only_not_release_evidence",
        "gates": [
            {
                "gate": gate,
                "required_sources": list(GATE_REQUIREMENTS[gate]),
                "required_assertions": list(GATE_ASSERTIONS[gate]),
            }
            for gate in GATES
        ],
    }


def _read_gate_set(paths: Sequence[Path]) -> dict[str, dict[str, Any]]:
    manifests: dict[str, dict[str, Any]] = {}
    for path in paths:
        value = read_document(path)
        if not isinstance(value, dict) or not isinstance(value.get("gate"), str):
            raise EvidenceError(f"{path} is not gate evidence")
        gate = value["gate"]
        if gate in manifests:
            raise EvidenceError(f"duplicate gate evidence for {gate}")
        manifests[gate] = value
    return manifests


def _content_id(path: Path, kind: str) -> str:
    value = read_document(path)
    if not isinstance(value, dict):
        raise EvidenceError("content-ID input must be one JSON object")
    return (
        compute_gate_content_id(value)
        if kind == "gate"
        else compute_bundle_content_id(value)
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("inventory")
    gate_parser = subparsers.add_parser("validate-gate")
    gate_parser.add_argument("path", type=Path)
    bundle_parser = subparsers.add_parser("validate-bundle")
    bundle_parser.add_argument("path", type=Path)
    bundle_parser.add_argument(
        "--gate-evidence", type=Path, action="append", required=True
    )
    content_parser = subparsers.add_parser("content-id")
    content_parser.add_argument("kind", choices=("gate", "bundle"))
    content_parser.add_argument("path", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "inventory":
            sys.stdout.buffer.write(_canonical_bytes(gate_inventory()))
        elif args.command == "validate-gate":
            validate_gate(read_document(args.path))
            print(f"Deep Reader gate evidence passed: {args.path}")
        elif args.command == "validate-bundle":
            validate_bundle(
                read_document(args.path),
                _read_gate_set(args.gate_evidence),
            )
            print(f"Deep Reader release evidence bundle passed: {args.path}")
        else:
            print(_content_id(args.path, args.kind))
    except (EvidenceError, OSError) as error:
        parser.exit(1, f"deep-reader release evidence validation failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
