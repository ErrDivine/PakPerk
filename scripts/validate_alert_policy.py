#!/usr/bin/env python3
"""Validate Pakperk's provider-neutral production alert-policy contract."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = (
    PROJECT_ROOT
    / "deploy/helm/pakperk/files/alerts/pakperk-production-alert-policy.json"
)

# Every alert required by docs/runbooks/observability.md is represented
# explicitly. The tuple fixes the operationally meaningful fields so a policy
# change cannot silently weaken a threshold or route while still parsing.
EXPECTED_RULES = {
    "api-readiness-unavailable": (
        "public-api-synthetic", "synthetic", "pakperk.api.readiness",
        "consecutive_failures", "critical", "page", "service-on-call",
        "docs/runbooks/incident-response.md", "greater_than_or_equal", 2, 120, 60, "alert",
    ),
    "api-error-ratio-high": (
        "application-otlp", "metric", "http.server.request.count", "ratio_rate",
        "critical", "page", "service-on-call", "docs/runbooks/incident-response.md",
        "greater_than", 0.05, 300, 300, "alert",
    ),
    "api-latency-high": (
        "application-otlp", "metric", "http.server.request.duration",
        "p95_by_http_route", "warning", "ticket", "service-on-call",
        "docs/runbooks/incident-response.md", "greater_than", 0.5, 300, 600, "alert",
    ),
    "database-pool-saturation": (
        "database-observer", "metric", "pakperk.infrastructure.database.pool.utilization",
        "maximum_by_service", "critical", "page", "database-on-call",
        "docs/runbooks/incident-response.md", "greater_than", 0.85, 300, 300, "alert",
    ),
    "paper-queue-age-high": (
        "database-observer", "metric", "pakperk.infrastructure.paper_queue.oldest_age",
        "maximum", "warning", "ticket", "paper-pipeline-on-call",
        "docs/runbooks/incident-response.md", "greater_than", 300, 300, 300, "alert",
    ),
    "paper-terminal-failure-present": (
        "database-observer", "metric",
        "pakperk.infrastructure.paper_queue.terminal_failures", "maximum", "warning", "ticket",
        "paper-pipeline-on-call", "docs/runbooks/incident-response.md", "greater_than", 0,
        300, 60, "alert",
    ),
    "deletion-queue-age-high": (
        "application-otlp", "metric", "pakperk.backlog.oldest_age", "maximum",
        "critical", "page", "privacy-on-call", "docs/runbooks/account-deletion.md",
        "greater_than", 900, 300, 300, "alert",
    ),
    "deletion-terminal-failure": (
        "application-otlp", "metric", "pakperk.account_deletion.state.count",
        "sum_increase", "critical", "page", "privacy-on-call",
        "docs/runbooks/account-deletion.md", "greater_than", 0, 300, 60, "healthy",
    ),
    "moderation-report-triage-deadline": (
        "application-otlp", "metric", "pakperk.backlog.oldest_age", "maximum",
        "critical", "page", "trust-safety-on-call", "docs/runbooks/moderation.md",
        "greater_than", 2700, 300, 60, "alert",
    ),
    "authentication-recovery-failure": (
        "application-otlp", "metric", "pakperk.operation.count", "sum_increase",
        "critical", "page", "identity-on-call", "docs/runbooks/incident-response.md",
        "greater_than_or_equal", 3, 300, 300, "healthy",
    ),
    "collector-records-rejected": (
        "collector-observer", "metric", "pakperk.infrastructure.collector.rejected_records",
        "sum_increase", "warning", "ticket", "observability-on-call",
        "docs/runbooks/observability.md", "greater_than", 0, 300, 60, "alert",
    ),
    "collector-records-dropped": (
        "collector-observer", "metric", "pakperk.infrastructure.collector.dropped_records",
        "sum_increase", "critical", "page", "observability-on-call",
        "docs/runbooks/observability.md", "greater_than", 0, 300, 60, "alert",
    ),
    "collector-export-failures": (
        "collector-observer", "metric",
        "pakperk.infrastructure.collector.export_failed_records", "sum_increase", "critical",
        "page", "observability-on-call", "docs/runbooks/observability.md", "greater_than", 0,
        300, 60, "alert",
    ),
    "collector-node-agent-coverage": (
        "kubernetes-observer", "metric",
        "pakperk.infrastructure.collector.node_agent_coverage_ratio", "minimum", "critical",
        "page", "platform-on-call", "docs/runbooks/observability.md", "less_than", 1, 300,
        120, "alert",
    ),
    "telemetry-gateway-rejection-spike": (
        "application-otlp", "metric", "pakperk.operation.count", "sum_increase", "warning",
        "ticket", "observability-on-call", "docs/runbooks/observability.md", "greater_than",
        100, 300, 300, "healthy",
    ),
    "deletion-ledger-verification-failure": (
        "kubernetes-redacted-logs", "log", "pakperk.static_message.count", "sum_increase",
        "critical", "page", "privacy-on-call", "docs/runbooks/account-deletion.md",
        "greater_than", 0, 300, 60, "healthy",
    ),
    "deletion-ledger-capacity-high": (
        "kubernetes-observer", "metric",
        "pakperk.infrastructure.deletion_ledger.volume.utilization", "maximum", "critical",
        "page", "privacy-on-call", "docs/runbooks/account-deletion.md", "greater_than", 0.8,
        300, 300, "alert",
    ),
}

EXPECTED_INPUTS = {
    "application-otlp": (
        "otlp",
        "Pakperk content-free application metrics with service.name and "
        "deployment.environment.name resources",
    ),
    "public-api-synthetic": (
        "synthetic_https",
        "External TLS probe of the production API origin with redirects disabled",
    ),
    "database-observer": (
        "aggregate_database_metrics",
        "Read-only aggregate pool and paper-job queue gauges; no statements, identifiers, "
        "titles, or content",
    ),
    "kubernetes-observer": (
        "aggregate_kubernetes_metrics",
        "Desired/ready workload counts and deletion-ledger volume utilization for the Pakperk "
        "production release",
    ),
    "collector-observer": (
        "collector_self_telemetry",
        "Collector accepted/refused/dropped/export-failed aggregate record counters observed "
        "outside the failing export path",
    ),
    "kubernetes-redacted-logs": (
        "static_message_logs",
        "Platform observation of the chart-scoped static message and severity fields only; "
        "no attributes or raw JSON",
    ),
}

EXPECTED_FILTERS: dict[str, dict[str, Any]] = {
    "api-readiness-unavailable": {
        "http.method": "GET", "http.path": "/health/ready", "http.redirects": "disabled",
        "tls.required": "true",
    },
    "api-error-ratio-high": {
        "deployment.environment.name": "production", "service.name": "pakperk-api-production",
    },
    "api-latency-high": {
        "deployment.environment.name": "production", "service.name": "pakperk-api-production",
    },
    "database-pool-saturation": {"deployment.environment.name": "production"},
    "paper-queue-age-high": {
        "deployment.environment.name": "production", "unit": "seconds",
    },
    "paper-terminal-failure-present": {"deployment.environment.name": "production"},
    "deletion-queue-age-high": {
        "backlog.class": "account_deletion", "deployment.environment.name": "production",
        "service.name": "pakperk-deletion-worker-production",
    },
    "deletion-terminal-failure": {
        "account_deletion.state": "terminal_failure",
        "deployment.environment.name": "production",
        "service.name": "pakperk-deletion-worker-production",
    },
    "moderation-report-triage-deadline": {
        "backlog.class": "moderation_reports", "deployment.environment.name": "production",
        "service.name": "pakperk-api-production",
    },
    "authentication-recovery-failure": {
        "deployment.environment.name": "production",
        "operation.class": ["oidc_discovery", "oidc_jwks_refresh"],
        "operation.outcome": ["retryable_failure", "terminal_failure"],
        "service.name": "pakperk-api-production",
    },
    "collector-records-rejected": {"deployment.environment.name": "production"},
    "collector-records-dropped": {"deployment.environment.name": "production"},
    "collector-export-failures": {"deployment.environment.name": "production"},
    "collector-node-agent-coverage": {
        "deployment.environment.name": "production", "workload.kind": "DaemonSet",
    },
    "telemetry-gateway-rejection-spike": {
        "deployment.environment.name": "production",
        "operation.class": "mobile_telemetry_ingest", "operation.outcome": "rejected",
        "service.name": "pakperk-telemetry-gateway-production",
    },
    "deletion-ledger-verification-failure": {
        "body": "external deletion ledger failed verification",
        "deployment.environment.name": "production", "log.severity_text": "ERROR",
        "service.name": "pakperk-deletion-worker-production",
    },
    "deletion-ledger-capacity-high": {"deployment.environment.name": "production"},
}

EXPECTED_NUMERATOR_FILTERS = {
    "api-error-ratio-high": {"http.response.status_class": "5xx"},
}

PROHIBITED_FILTER_FRAGMENTS = {
    "authorization", "cookie", "set-cookie", "access_token", "refresh_token", "id_token",
    "api_key", "email", "oidc.subject", "oidc.sub", "user.id", "account.id", "provider.id",
    "client.address", "source.address", "device.id", "session.id", "search.query",
    "comment.body", "chat.message", "paper.full_text", "model.prompt", "model.response",
    "url.query", "db.statement", "db.query.text",
}


class PolicyError(ValueError):
    """Raised when the alert policy violates its closed contract."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise PolicyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _expect_keys(value: dict[str, Any], expected: set[str], where: str) -> None:
    actual = set(value)
    if actual != expected:
        raise PolicyError(
            f"{where} keys differ: missing={sorted(expected - actual)}, "
            f"unknown={sorted(actual - expected)}"
        )


def _read_policy(path: Path) -> tuple[str, dict[str, Any]]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise PolicyError(f"could not read {path}: {error}") from error
    try:
        parsed = json.loads(raw, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, PolicyError) as error:
        raise PolicyError(f"invalid alert-policy JSON: {error}") from error
    if not isinstance(parsed, dict):
        raise PolicyError("alert policy must be a JSON object")
    canonical = json.dumps(parsed, ensure_ascii=False, indent=2) + "\n"
    if raw != canonical:
        raise PolicyError("alert policy must use deterministic two-space canonical JSON")
    return raw, parsed


def _validate_filter_value(value: Any, where: str) -> None:
    candidates: list[Any]
    if isinstance(value, str):
        candidates = [value]
    elif isinstance(value, list) and value:
        candidates = value
        if len(set(value)) != len(value):
            raise PolicyError(f"{where} any-of values must be unique")
    else:
        raise PolicyError(f"{where} must be a string or non-empty string array")
    for candidate in candidates:
        if not isinstance(candidate, str) or not candidate or len(candidate) > 255:
            raise PolicyError(f"{where} contains an invalid exact-match value")


def _validate_filters(filters: Any, where: str) -> None:
    if not isinstance(filters, dict) or not filters:
        raise PolicyError(f"{where} must be a non-empty object")
    for key, value in filters.items():
        if not isinstance(key, str) or not key or len(key) > 128:
            raise PolicyError(f"{where} contains an invalid key")
        lowered = key.lower()
        if any(fragment in lowered for fragment in PROHIBITED_FILTER_FRAGMENTS):
            raise PolicyError(f"{where} selects protected data: {key}")
        _validate_filter_value(value, f"{where}.{key}")


def _validate_input_contracts(spec: dict[str, Any]) -> set[str]:
    inputs = spec["requiredInputs"]
    if not isinstance(inputs, list):
        raise PolicyError("spec.requiredInputs must be an array")
    found: dict[str, tuple[str, str]] = {}
    for index, item in enumerate(inputs):
        where = f"spec.requiredInputs[{index}]"
        if not isinstance(item, dict):
            raise PolicyError(f"{where} must be an object")
        _expect_keys(
            item,
            {"id", "kind", "contract", "liveAdapterEvidenceRequired"},
            where,
        )
        input_id = item["id"]
        if not isinstance(input_id, str) or not re.fullmatch(r"[a-z][a-z0-9-]{2,63}", input_id):
            raise PolicyError(f"{where}.id is invalid")
        if input_id in found:
            raise PolicyError(f"duplicate required input: {input_id}")
        kind = item["kind"]
        if not isinstance(kind, str):
            raise PolicyError(f"{where}.kind must be a string")
        if not isinstance(item["contract"], str) or not (20 <= len(item["contract"]) <= 512):
            raise PolicyError(f"{where}.contract must be a bounded operational contract")
        if item["liveAdapterEvidenceRequired"] is not True:
            raise PolicyError(f"{where} must require external live-adapter evidence")
        found[input_id] = (kind, item["contract"])
    if found != EXPECTED_INPUTS:
        raise PolicyError(f"required input contracts differ: {found}")
    return set(found)


def _rule_contract(rule: dict[str, Any]) -> tuple[Any, ...]:
    signal = rule["signal"]
    condition = rule["condition"]
    return (
        signal["input"], signal["kind"], signal["name"], signal["aggregation"],
        rule["severity"], rule["notification"], rule["owner"], rule["runbook"],
        condition["operator"], condition["threshold"], condition["windowSeconds"],
        condition["forSeconds"], condition["missingData"],
    )


def _validate_rule(rule: Any, index: int, input_ids: set[str]) -> str:
    where = f"spec.rules[{index}]"
    if not isinstance(rule, dict):
        raise PolicyError(f"{where} must be an object")
    _expect_keys(
        rule,
        {"id", "summary", "severity", "notification", "owner", "runbook", "signal", "condition"},
        where,
    )
    rule_id = rule["id"]
    if not isinstance(rule_id, str) or rule_id not in EXPECTED_RULES:
        raise PolicyError(f"{where}.id is not a required production alert")
    if not isinstance(rule["summary"], str) or not (20 <= len(rule["summary"]) <= 180):
        raise PolicyError(f"{where}.summary must be bounded and actionable")
    if not re.fullmatch(r"[a-z][a-z0-9-]{2,63}", str(rule["owner"])):
        raise PolicyError(f"{where}.owner must be a role, not a person")
    if rule["severity"] not in {"critical", "warning"}:
        raise PolicyError(f"{where}.severity is invalid")
    expected_notification = "page" if rule["severity"] == "critical" else "ticket"
    if rule["notification"] != expected_notification:
        raise PolicyError(f"{where} weakens the severity notification class")

    runbook = rule["runbook"]
    if not isinstance(runbook, str) or not runbook.startswith("docs/runbooks/"):
        raise PolicyError(f"{where}.runbook must be a repository runbook")
    runbook_path = (PROJECT_ROOT / runbook).resolve()
    runbook_root = (PROJECT_ROOT / "docs/runbooks").resolve()
    if runbook_root not in runbook_path.parents or not runbook_path.is_file():
        raise PolicyError(f"{where}.runbook does not resolve to an existing runbook")

    signal = rule["signal"]
    if not isinstance(signal, dict):
        raise PolicyError(f"{where}.signal must be an object")
    signal_keys = {"input", "kind", "name", "aggregation", "filters"}
    if signal.get("aggregation") == "ratio_rate":
        signal_keys.add("numeratorFilters")
    _expect_keys(signal, signal_keys, f"{where}.signal")
    if signal["input"] not in input_ids:
        raise PolicyError(f"{where}.signal references an unknown input")
    if signal["kind"] not in {"metric", "synthetic", "log"}:
        raise PolicyError(f"{where}.signal.kind is invalid")
    for key in ("name", "aggregation"):
        if not isinstance(signal[key], str) or not re.fullmatch(r"[A-Za-z0-9._-]{2,128}", signal[key]):
            raise PolicyError(f"{where}.signal.{key} is invalid")
    _validate_filters(signal["filters"], f"{where}.signal.filters")
    if signal["filters"] != EXPECTED_FILTERS[rule_id]:
        raise PolicyError(f"{where}.signal.filters weakens or changes {rule_id}")
    if "numeratorFilters" in signal:
        _validate_filters(signal["numeratorFilters"], f"{where}.signal.numeratorFilters")
        if signal["numeratorFilters"] != EXPECTED_NUMERATOR_FILTERS.get(rule_id):
            raise PolicyError(f"{where}.signal.numeratorFilters weakens or changes {rule_id}")
    elif rule_id in EXPECTED_NUMERATOR_FILTERS:
        raise PolicyError(f"{where}.signal omits the numerator filter for {rule_id}")

    condition = rule["condition"]
    if not isinstance(condition, dict):
        raise PolicyError(f"{where}.condition must be an object")
    _expect_keys(
        condition,
        {"operator", "threshold", "windowSeconds", "forSeconds", "missingData"},
        f"{where}.condition",
    )
    if condition["operator"] not in {"greater_than", "greater_than_or_equal", "less_than"}:
        raise PolicyError(f"{where}.condition.operator is invalid")
    threshold = condition["threshold"]
    if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not math.isfinite(threshold):
        raise PolicyError(f"{where}.condition.threshold must be finite")
    for duration_key in ("windowSeconds", "forSeconds"):
        duration = condition[duration_key]
        if isinstance(duration, bool) or not isinstance(duration, int) or not (60 <= duration <= 86400):
            raise PolicyError(f"{where}.condition.{duration_key} must be 60..86400 seconds")
        if duration % 60:
            raise PolicyError(f"{where}.condition.{duration_key} must align to one-minute evaluation")
    if condition["missingData"] not in {"alert", "healthy"}:
        raise PolicyError(f"{where}.condition.missingData is invalid")

    if _rule_contract(rule) != EXPECTED_RULES[rule_id]:
        raise PolicyError(f"{where} weakens or changes the fixed contract for {rule_id}")
    return rule_id


def validate_policy(path: Path = DEFAULT_POLICY) -> None:
    _, policy = _read_policy(path)
    _expect_keys(policy, {"apiVersion", "kind", "metadata", "spec"}, "policy")
    if policy["apiVersion"] != "alerts.pakperk.app/v1alpha1" or policy["kind"] != "AlertPolicy":
        raise PolicyError("policy apiVersion/kind is not the supported provider-neutral contract")

    metadata = policy["metadata"]
    if not isinstance(metadata, dict):
        raise PolicyError("metadata must be an object")
    _expect_keys(metadata, {"name", "environment", "version"}, "metadata")
    if metadata != {"name": "pakperk-production", "environment": "production", "version": 1}:
        raise PolicyError("metadata must identify version 1 of the production policy")

    spec = policy["spec"]
    if not isinstance(spec, dict):
        raise PolicyError("spec must be an object")
    _expect_keys(
        spec,
        {"evaluationIntervalSeconds", "adapterContract", "filterSemantics", "requiredInputs", "rules"},
        "spec",
    )
    if spec["evaluationIntervalSeconds"] != 60:
        raise PolicyError("production alerts must evaluate once per minute")
    if not isinstance(spec["adapterContract"], str) or "do not prove live routing" not in spec["adapterContract"]:
        raise PolicyError("adapterContract must state the live-routing evidence boundary")
    if spec["filterSemantics"] != (
        "A string is an exact match. An array is an exact any-of match. "
        "No filter value is a regular expression."
    ):
        raise PolicyError("filterSemantics must stay exact and provider-neutral")

    input_ids = _validate_input_contracts(spec)
    rules = spec["rules"]
    if not isinstance(rules, list):
        raise PolicyError("spec.rules must be an array")
    found: list[str] = []
    for index, rule in enumerate(rules):
        rule_id = _validate_rule(rule, index, input_ids)
        if rule_id in found:
            raise PolicyError(f"duplicate alert rule: {rule_id}")
        found.append(rule_id)
    if set(found) != set(EXPECTED_RULES) or len(found) != len(EXPECTED_RULES):
        raise PolicyError("policy does not contain every required production alert exactly once")
    if found != list(EXPECTED_RULES):
        raise PolicyError("alert rules must stay in the fixed review order")

    observability_source = (
        PROJECT_ROOT / "backend/crates/observability/src/lib.rs"
    ).read_text(encoding="utf-8")
    emitted_metrics = {
        expected[2]
        for expected in EXPECTED_RULES.values()
        if expected[0] == "application-otlp"
    }
    for metric in emitted_metrics:
        if f'"{metric}"' not in observability_source:
            raise PolicyError(f"application metric is not emitted by observability crate: {metric}")

    deletion_source = (
        PROJECT_ROOT / "backend/crates/account_deletion/src/worker.rs"
    ).read_text(encoding="utf-8")
    if '"external deletion ledger failed verification"' not in deletion_source:
        raise PolicyError("ledger verification alert no longer matches the static worker message")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("policy", nargs="?", type=Path, default=DEFAULT_POLICY)
    args = parser.parse_args()
    try:
        validate_policy(args.policy.resolve())
    except PolicyError as error:
        parser.exit(1, f"alert-policy validation failed: {error}\n")
    print(f"Alert-policy contract validation passed: {args.policy}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
