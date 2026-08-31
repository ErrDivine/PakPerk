#!/usr/bin/env python3
"""Focused hermetic tests for protected operational gate evidence."""

from __future__ import annotations

import copy
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable
from unittest import mock

import operational_gate_evidence as evidence


SOURCE_REVISION = hashlib.sha1(b"pakperk operational gate release").hexdigest()


def digest(label: str) -> str:
    return f"sha256:{hashlib.sha256(label.encode('utf-8')).hexdigest()}"


def prefixed(prefix: str, label: str) -> str:
    return f"{prefix}{hashlib.sha256(label.encode('utf-8')).hexdigest()}"


def binding(gate: str) -> dict[str, object]:
    spec = evidence.GATE_SPECS[gate]
    return {
        "source_revision": SOURCE_REVISION,
        "target_environment": spec.target_environment,
        "deployment_id": prefixed(
            "deployment-binding-v1:sha256:", f"{gate} deployed candidate"
        ),
        "candidate_id": digest(f"{gate} candidate"),
        "configuration_sha256": digest(f"{gate} configuration"),
        "tools": [
            {
                "role": role,
                "version": f"1.0.{index + 1}",
                "sha256": digest(f"{gate} {role} tool"),
            }
            for index, role in enumerate(spec.tool_roles)
        ],
    }


def subject(gate: str) -> dict[str, object]:
    if gate == evidence.MIGRATION_GATE:
        return {
            "migration_image_digest": digest("reviewed migration image"),
            "backup_evidence_id": prefixed(
                "pakperk-restore-evidence-v2:sha256:", "verified restore evidence"
            ),
            "starting_schema_version": 18,
            "ending_schema_version": 24,
            "embedded_migration_version": 24,
            "starting_app_version": "0.1.0",
            "ending_app_version": "0.2.0",
            "resolution_path": "schema_compatible_code_rollback",
        }
    if gate == evidence.TELEMETRY_GATE:
        production_binding = binding(gate)
        return {
            "production": {
                "environment": "production",
                "deployment_id": production_binding["deployment_id"],
                "release_configuration_sha256": production_binding[
                    "configuration_sha256"
                ],
                "collector_image_digest": digest("collector image"),
                "telemetry_gateway_image_digest": digest("telemetry gateway image"),
                "platform_adapter_image_digest": digest("platform adapter image"),
                "collector_configuration_sha256": digest(
                    "production collector configuration"
                ),
                "telemetry_gateway_configuration_sha256": digest(
                    "production telemetry gateway configuration"
                ),
                "platform_adapter_configuration_sha256": digest(
                    "production platform adapter configuration"
                ),
                "redaction_policy_sha256": digest("redaction policy"),
                "alert_policy_sha256": evidence.ALERT_POLICY_SHA256,
                "enabled_input_ids": list(evidence.ALERT_INPUT_IDS),
                "enabled_rule_ids": list(evidence.ALERT_RULE_IDS),
                "receiver_inventory_sha256": digest("production receiver inventory"),
                "retention_policy_sha256": digest("production retention policy"),
                "retention_days": 30,
            },
            "staging_canary": {
                "environment": "staging",
                "deployment_id": prefixed(
                    "deployment-binding-v1:sha256:",
                    "staging telemetry canary deployment",
                ),
                "release_configuration_sha256": digest(
                    "staging telemetry release configuration"
                ),
                "collector_image_digest": digest("collector image"),
                "telemetry_gateway_image_digest": digest("telemetry gateway image"),
                "platform_adapter_image_digest": digest("platform adapter image"),
                "collector_configuration_sha256": digest(
                    "staging collector configuration"
                ),
                "telemetry_gateway_configuration_sha256": digest(
                    "staging telemetry gateway configuration"
                ),
                "platform_adapter_configuration_sha256": digest(
                    "staging platform adapter configuration"
                ),
                "redaction_policy_sha256": digest("redaction policy"),
                "alert_policy_sha256": digest(
                    "staging environment-filtered alert policy"
                ),
                "enabled_input_ids": list(evidence.ALERT_INPUT_IDS),
                "enabled_rule_ids": list(evidence.ALERT_RULE_IDS),
                "receiver_inventory_sha256": digest("staging receiver inventory"),
                "retention_policy_sha256": digest("staging retention policy"),
                "retention_days": 30,
            },
            "production_retention_canary": {
                "commitment_inventory_sha256": digest(
                    "production retention canary commitments"
                ),
                "commitment_count": 1,
                "seeded_at": "2026-06-01T00:00:00Z",
                "initial_query_at": "2026-06-01T00:05:00Z",
                "pre_expiry_query_at": "2026-06-30T23:00:00Z",
                "post_expiry_query_at": "2026-07-02T00:00:00Z",
            },
            "staging_production_parity_review_sha256": digest(
                "reviewed staging production telemetry parity diff"
            ),
        }
    if gate == evidence.MOBILE_GATE:
        return {
            "mobile_version": "0.2.0",
            "build_number": 42,
            "android_apk_sha256": digest("signed release APK"),
            "ios_ipa_sha256": digest("signed release IPA"),
            "android_application_id": "app.pakperk.pakperk",
            "ios_application_id": "app.pakperk.pakperk",
            "diagnostics_sources": [
                "app_store_connect",
                "google_play_console",
            ],
            "distribution_scope": "testflight_and_closed_play",
        }
    raise AssertionError(gate)


def window(gate: str) -> tuple[str, str, int]:
    if gate == evidence.MIGRATION_GATE:
        return "2026-06-01T00:00:00Z", "2026-06-01T01:00:00Z", 3_600
    if gate == evidence.TELEMETRY_GATE:
        return "2026-06-01T00:00:00Z", "2026-07-02T00:00:00Z", 2_678_400
    if gate == evidence.MOBILE_GATE:
        return "2026-07-01T00:00:00Z", "2026-07-02T00:00:00Z", 86_400
    raise AssertionError(gate)


def metrics(gate: str) -> dict[str, int]:
    started_at, completed_at, seconds = window(gate)
    del started_at, completed_at
    values = {
        metric_id: metric_spec.minimum
        for metric_id, metric_spec in evidence.GATE_SPECS[gate].metrics
    }
    values["window_seconds"] = seconds
    if gate == evidence.TELEMETRY_GATE:
        values.update(
            {
                "retention_initial_query_age_seconds": 300,
                "retention_pre_expiry_query_age_seconds": 2_588_400,
                "retention_post_expiry_query_age_seconds": 2_678_400,
                "staging_expected_node_agents": 3,
                "staging_observed_node_agents": 3,
            }
        )
    if gate == evidence.MOBILE_GATE:
        values.update(
            {
                "device_os_combinations": 4,
                "cached_first_readable_frame_samples": 100,
                "cached_first_readable_frame_p95_ms": 1_400,
                "opening_transition_samples": 100,
                "opening_transition_ms": 600,
                "sequential_cache_requests": 100,
                "sequential_cache_hits": 95,
                "frame_samples": 1_000,
                "observed_sessions": 1_000,
                "crash_free_sessions": 995,
                "crashed_sessions": 5,
                "crash_free_basis_points": 9_950,
            }
        )
    return values


def after(timestamp: str, minutes: int) -> str:
    parsed = dt.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=dt.timezone.utc
    )
    return (parsed + dt.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def manifest(gate: str) -> dict[str, object]:
    spec = evidence.GATE_SPECS[gate]
    started_at, completed_at, _ = window(gate)
    cleanup_at = after(completed_at, 1)
    artifact_values = {
        artifact_id: (digest(f"{gate} {artifact_id} artifact"), 100 + index)
        for index, artifact_id in enumerate(spec.artifact_ids)
    }
    assertion_values = {assertion_id: "passed" for assertion_id in spec.assertion_ids}
    metric_values = metrics(gate)
    cleanup = {
        "outcome": "completed",
        "completed_at": cleanup_at,
        "remaining_test_records": 0,
        "protected_audit_reference": digest(f"{gate} cleanup audit"),
    }
    approval_subject_id = evidence.build_approval_subject_id(
        gate,
        binding(gate),
        subject(gate),
        started_at=started_at,
        completed_at=completed_at,
        artifacts=artifact_values,
        assertion_outcomes=assertion_values,
        metrics=metric_values,
        cleanup=cleanup,
    )
    return evidence.build_evidence(
        gate,
        binding(gate),
        subject(gate),
        started_at=started_at,
        completed_at=completed_at,
        artifacts=artifact_values,
        assertion_outcomes=assertion_values,
        metrics=metric_values,
        cleanup=cleanup,
        approvals=[
            {
                "role": role,
                "decision": "approved",
                "approved_at": after(cleanup_at, index + 1),
                "approval_subject_id": approval_subject_id,
                "protected_audit_reference": digest(
                    f"{gate} {role} protected approval"
                ),
            }
            for index, role in enumerate(spec.approval_roles)
        ],
    )


def reseal(value: dict[str, object]) -> dict[str, object]:
    result = copy.deepcopy(value)
    result["content_id"] = evidence.compute_evidence_content_id(result)
    return result


def reapprove_and_reseal(value: dict[str, object]) -> dict[str, object]:
    result = copy.deepcopy(value)
    result["approval_subject_id"] = evidence.compute_approval_subject_id(result)
    for approval in result["approvals"]:
        approval["approval_subject_id"] = result["approval_subject_id"]
    result["content_id"] = evidence.compute_evidence_content_id(result)
    return result


def metric(value: dict[str, object], metric_id: str) -> dict[str, object]:
    rows = value["metrics"]
    assert isinstance(rows, list)
    return next(row for row in rows if row["id"] == metric_id)


class OperationalGateEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, value: object) -> pathlib.Path:
        path = self.directory / name
        path.write_bytes(evidence.encode_canonical_document(value))
        path.chmod(0o600)
        return path

    def test_repository_contract_pins_current_migration_policy_and_mobile_limits(
        self,
    ) -> None:
        repository = pathlib.Path(__file__).resolve().parents[1]
        migrations = sorted(
            int(path.name.split("_", 1)[0])
            for path in (repository / "backend" / "migrations").glob(
                "[0-9][0-9][0-9][0-9]_*.sql"
            )
        )
        self.assertEqual(migrations, list(range(1, 25)))
        self.assertEqual(evidence.PRIOR_DATABASE_MIGRATION, 18)
        self.assertEqual(evidence.CURRENT_DATABASE_MIGRATION, 24)

        values_text = (
            repository / "deploy" / "helm" / "pakperk" / "values.yaml"
        ).read_text(encoding="utf-8")
        feature_block = values_text.split("\nfeatures:\n", 1)[1].split(
            "\nreleaseEvidence:\n", 1
        )[0]
        helm_switches = tuple(
            line.strip().split(":", 1)[0]
            for line in feature_block.splitlines()
            if line.startswith("  ") and line.strip().endswith(": false")
        )

        def environment_name(helm_name: str) -> str:
            converted = []
            for character in helm_name:
                if character.isupper():
                    converted.append("_")
                converted.append(character.upper())
            return f"{''.join(converted)}_ENABLED"

        self.assertEqual(
            evidence.RELEASE_FEATURE_SWITCHES,
            (
                "ACCOUNTS_ENABLED",
                "LIBRARY_ENABLED",
                "LIBRARY_WRITES_ENABLED",
                "PAPER_RESOLUTION_ENABLED",
                "PAPER_TITLE_SEARCH_ENABLED",
                "LIBRARY_IMPORT_WRITES_ENABLED",
                "READING_FEED_ENABLED",
                "TO_READ_FIRST_ENFORCEMENT_ENABLED",
                "COMMENTS_ENABLED",
                "COMMENT_CREATION_ENABLED",
                "ACCOUNT_DELETION_ENABLED",
                "LIBRARY_V2_ENABLED",
                "RESEARCH_PROFILES_ENABLED",
                "RECOMMENDATIONS_ENABLED",
                "RECOMMENDATION_EVENTS_ENABLED",
                "SEARCH_LOOKUP_ENABLED",
                "SEARCH_EXPLORE_ENABLED",
                "SAVED_QUERIES_ENABLED",
                "READING_BRIEFS_ENABLED",
                "SUBSCRIPTIONS_ENABLED",
                "NOTIFICATIONS_ENABLED",
                "DEEP_READER_ENABLED",
                "PAPER_PASSPORT_ENABLED",
                "SEMANTIC_FACETS_ENABLED",
                "VISUAL_OBJECTS_ENABLED",
                "ASSISTANT_V2_ENABLED",
                "ANNOTATIONS_ENABLED",
                "RESEARCH_MEMORY_ENABLED",
                "VERSION_DIFF_ENABLED",
                "DOCLING_EXPERIMENT_ENABLED",
            ),
        )
        self.assertEqual(
            tuple(environment_name(name) for name in helm_switches),
            evidence.RELEASE_FEATURE_SWITCHES,
        )
        config_text = (
            repository / "backend" / "apps" / "api" / "src" / "config.rs"
        ).read_text(encoding="utf-8")
        api_switches = re.findall(
            r'env_bool\("([A-Z0-9_]+_ENABLED)", false\)\?', config_text
        )
        self.assertCountEqual(api_switches, evidence.RELEASE_FEATURE_SWITCHES)
        self.assertEqual(len(evidence.RELEASE_FEATURE_SWITCHES), 30)
        self.assertEqual(
            evidence.RELEASE_FEATURE_DEPENDENCIES,
            (
                ("LIBRARY_ENABLED", ("ACCOUNTS_ENABLED",)),
                ("LIBRARY_WRITES_ENABLED", ("LIBRARY_ENABLED",)),
                (
                    "PAPER_TITLE_SEARCH_ENABLED",
                    ("ACCOUNTS_ENABLED", "PAPER_RESOLUTION_ENABLED"),
                ),
                (
                    "LIBRARY_IMPORT_WRITES_ENABLED",
                    (
                        "ACCOUNTS_ENABLED",
                        "LIBRARY_ENABLED",
                        "LIBRARY_WRITES_ENABLED",
                        "PAPER_RESOLUTION_ENABLED",
                    ),
                ),
                (
                    "READING_FEED_ENABLED",
                    ("ACCOUNTS_ENABLED", "LIBRARY_ENABLED"),
                ),
                (
                    "TO_READ_FIRST_ENFORCEMENT_ENABLED",
                    ("READING_FEED_ENABLED",),
                ),
                ("COMMENTS_ENABLED", ("ACCOUNTS_ENABLED",)),
                ("COMMENT_CREATION_ENABLED", ("COMMENTS_ENABLED",)),
                ("ACCOUNT_DELETION_ENABLED", ("ACCOUNTS_ENABLED",)),
                (
                    "LIBRARY_V2_ENABLED",
                    ("ACCOUNTS_ENABLED", "LIBRARY_ENABLED"),
                ),
                ("RESEARCH_PROFILES_ENABLED", ("ACCOUNTS_ENABLED",)),
                (
                    "RECOMMENDATIONS_ENABLED",
                    (
                        "ACCOUNTS_ENABLED",
                        "LIBRARY_ENABLED",
                        "READING_FEED_ENABLED",
                    ),
                ),
                ("SEARCH_EXPLORE_ENABLED", ("SEARCH_LOOKUP_ENABLED",)),
                (
                    "SAVED_QUERIES_ENABLED",
                    ("ACCOUNTS_ENABLED", "SEARCH_EXPLORE_ENABLED"),
                ),
                ("READING_BRIEFS_ENABLED", ("READING_FEED_ENABLED",)),
                (
                    "SUBSCRIPTIONS_ENABLED",
                    (
                        "ACCOUNTS_ENABLED",
                        "LIBRARY_ENABLED",
                        "READING_FEED_ENABLED",
                    ),
                ),
                ("NOTIFICATIONS_ENABLED", ("SUBSCRIPTIONS_ENABLED",)),
                ("PAPER_PASSPORT_ENABLED", ("DEEP_READER_ENABLED",)),
                ("SEMANTIC_FACETS_ENABLED", ("DEEP_READER_ENABLED",)),
                ("VISUAL_OBJECTS_ENABLED", ("DEEP_READER_ENABLED",)),
                ("ASSISTANT_V2_ENABLED", ("DEEP_READER_ENABLED",)),
                (
                    "ANNOTATIONS_ENABLED",
                    ("ACCOUNTS_ENABLED", "DEEP_READER_ENABLED"),
                ),
                (
                    "RESEARCH_MEMORY_ENABLED",
                    (
                        "ACCOUNTS_ENABLED",
                        "DEEP_READER_ENABLED",
                        "ANNOTATIONS_ENABLED",
                    ),
                ),
                ("VERSION_DIFF_ENABLED", ("DEEP_READER_ENABLED",)),
                ("DOCLING_EXPERIMENT_ENABLED", ("DEEP_READER_ENABLED",)),
            ),
        )
        self.assertEqual(evidence.RELEASE_FEATURE_DEPENDENCY_EDGE_COUNT, 39)
        switch_set = set(evidence.RELEASE_FEATURE_SWITCHES)
        self.assertTrue(
            all(
                switch in switch_set and set(required) <= switch_set
                for switch, required in evidence.RELEASE_FEATURE_DEPENDENCIES
            )
        )

        policy_path = (
            repository
            / "deploy"
            / "helm"
            / "pakperk"
            / "files"
            / "alerts"
            / "pakperk-production-alert-policy.json"
        )
        policy_bytes = policy_path.read_bytes()
        self.assertEqual(
            f"sha256:{hashlib.sha256(policy_bytes).hexdigest()}",
            evidence.ALERT_POLICY_SHA256,
        )
        policy = json.loads(policy_bytes)
        self.assertEqual(
            tuple(item["id"] for item in policy["spec"]["requiredInputs"]),
            evidence.ALERT_INPUT_IDS,
        )
        self.assertEqual(
            tuple(item["id"] for item in policy["spec"]["rules"]),
            evidence.ALERT_RULE_IDS,
        )
        self.assertEqual(
            {item["notification"] for item in policy["spec"]["rules"]},
            {"page", "ticket"},
        )

        import validate_mobile_acceptance_evidence as mobile_evidence

        self.assertEqual(
            evidence.CACHED_FIRST_READABLE_FRAME_P95_MAX_MS,
            mobile_evidence.CACHED_FIRST_READABLE_FRAME_P95_MAX_MS,
        )
        self.assertEqual(
            evidence.OPENING_TRANSITION_MAX_MS,
            mobile_evidence.OPENING_TRANSITION_MAX_MS,
        )
        self.assertEqual(evidence.MOBILE_OBSERVATION_WINDOW_MIN_SECONDS, 86_400)
        self.assertEqual(evidence.MOBILE_PERFORMANCE_SAMPLE_MIN, 20)
        self.assertEqual(evidence.MOBILE_CRASH_SESSION_MIN, 200)

    def test_all_three_gates_and_bundle_are_closed_and_self_addressed(self) -> None:
        manifests = {gate: manifest(gate) for gate in evidence.GATES}
        prefixes = set()
        for gate in evidence.GATES:
            validated = evidence.validate_evidence(manifests[gate], expected_gate=gate)
            self.assertEqual(
                validated["content_id"], evidence.compute_evidence_content_id(validated)
            )
            prefix = evidence.GATE_SPECS[gate].content_prefix
            self.assertTrue(validated["content_id"].startswith(prefix))
            prefixes.add(prefix)
            path = self.write(f"{gate}.json", validated)
            self.assertEqual(
                evidence.read_evidence(path, expected_binding=validated["binding"]),
                validated,
            )
        self.assertEqual(len(prefixes), 3)

        bundle = evidence.build_bundle(manifests)
        self.assertTrue(bundle["content_id"].startswith(evidence.BUNDLE_CONTENT_PREFIX))
        self.assertEqual(evidence.validate_bundle(bundle, manifests), bundle)

    def test_approvals_bind_one_exact_execution_subject_and_cannot_be_replayed(
        self,
    ) -> None:
        approved = manifest(evidence.MOBILE_GATE)
        replayed = manifest(evidence.MOBILE_GATE)
        replayed["binding"]["candidate_id"] = digest(
            "a different signed mobile candidate"
        )
        replayed["subject"]["build_number"] = 43
        replayed["approval_subject_id"] = evidence.compute_approval_subject_id(replayed)
        replayed["approvals"] = copy.deepcopy(approved["approvals"])
        with self.assertRaisesRegex(evidence.EvidenceError, "execution statement"):
            evidence.validate_evidence(reseal(replayed))

        cleanup_reuse = manifest(evidence.MIGRATION_GATE)
        cleanup_reuse["approvals"][0]["protected_audit_reference"] = cleanup_reuse[
            "cleanup"
        ]["protected_audit_reference"]
        with self.assertRaisesRegex(evidence.EvidenceError, "cleanup audit"):
            evidence.validate_evidence(reseal(cleanup_reuse))

        stale = manifest(evidence.TELEMETRY_GATE)
        stale["approvals"][0]["approved_at"] = "2027-01-01T00:00:00Z"
        with self.assertRaisesRegex(evidence.EvidenceError, "bounded post-run"):
            evidence.validate_evidence(reseal(stale))

    def test_additive_eleven_to_sixteen_gate_requires_code_rollback(self) -> None:
        value = manifest(evidence.MIGRATION_GATE)
        value["subject"]["resolution_path"] = "forward_fix"
        value["approval_subject_id"] = evidence.compute_approval_subject_id(value)
        for approval in value["approvals"]:
            approval["approval_subject_id"] = value["approval_subject_id"]
        with self.assertRaisesRegex(evidence.EvidenceError, "code rollback"):
            evidence.validate_evidence(reseal(value))

    def test_migration_gate_requires_all_current_switches_and_dependency_edges(
        self,
    ) -> None:
        valid = manifest(evidence.MIGRATION_GATE)
        self.assertEqual(metric(valid, "feature_switches_reconciled")["value"], 30)
        self.assertEqual(
            metric(valid, "feature_switch_dependency_edges_rejected")["value"],
            39,
        )

        missing_switch = copy.deepcopy(valid)
        metric(missing_switch, "feature_switches_reconciled")["value"] = 29
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_evidence(reapprove_and_reseal(missing_switch))

        missing_dependency = copy.deepcopy(valid)
        metric(missing_dependency, "feature_switch_dependency_edges_rejected")[
            "value"
        ] = 38
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_evidence(reapprove_and_reseal(missing_dependency))

        assertion_missing = copy.deepcopy(valid)
        assertion_missing["assertions"] = [
            assertion
            for assertion in assertion_missing["assertions"]
            if assertion["id"]
            != "feature_switch_dependency_graph_reconciled_and_invalid_edges_rejected"
        ]
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_evidence(reapprove_and_reseal(assertion_missing))

    def test_mobile_release_policy_rejects_degenerate_samples_and_window(
        self,
    ) -> None:
        cases: list[tuple[str, Callable[[dict[str, object]], None]]] = []

        def short_window(value: dict[str, object]) -> None:
            value["window"]["completed_at"] = "2026-07-01T23:59:59Z"
            metric(value, "window_seconds")["value"] = 86_399

        def cached_samples(value: dict[str, object]) -> None:
            metric(value, "cached_first_readable_frame_samples")["value"] = 19

        def opening_samples(value: dict[str, object]) -> None:
            metric(value, "opening_transition_samples")["value"] = 19

        def sequential_samples(value: dict[str, object]) -> None:
            metric(value, "sequential_cache_requests")["value"] = 19
            metric(value, "sequential_cache_hits")["value"] = 19

        def frame_samples(value: dict[str, object]) -> None:
            metric(value, "frame_samples")["value"] = 19

        def crash_denominator(value: dict[str, object]) -> None:
            metric(value, "observed_sessions")["value"] = 199
            metric(value, "crash_free_sessions")["value"] = 199
            metric(value, "crashed_sessions")["value"] = 0
            metric(value, "crash_free_basis_points")["value"] = 10_000

        cases.extend(
            (
                ("observation window", short_window),
                ("cached samples", cached_samples),
                ("opening samples", opening_samples),
                ("sequential samples", sequential_samples),
                ("frame samples", frame_samples),
                ("crash denominator", crash_denominator),
            )
        )
        for label, mutate in cases:
            with self.subTest(policy=label):
                value = manifest(evidence.MOBILE_GATE)
                mutate(value)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(reseal(value))

    def test_telemetry_production_staging_and_retention_boundaries_fail_closed(
        self,
    ) -> None:
        def production_delivery(value: dict[str, object]) -> None:
            metric(value, "production_safe_canaries_sent")["value"] = 2

        def incomplete_production_routing(value: dict[str, object]) -> None:
            metric(value, "production_alert_rules_with_receiver")["value"] = (
                len(evidence.ALERT_RULE_IDS) - 1
            )

        def missed_retention_ingestion(value: dict[str, object]) -> None:
            value["subject"]["production_retention_canary"]["commitment_count"] = 2
            metric(value, "retention_canaries_seeded")["value"] = 2

        def lost_before_expiry(value: dict[str, object]) -> None:
            value["subject"]["production_retention_canary"]["commitment_count"] = 2
            metric(value, "retention_canaries_seeded")["value"] = 2
            metric(value, "retention_initial_matches")["value"] = 2

        def query_age_mismatch(value: dict[str, object]) -> None:
            value["subject"]["production_retention_canary"][
                "pre_expiry_query_at"
            ] = "2026-06-30T22:00:00Z"

        def present_after_expiry(value: dict[str, object]) -> None:
            metric(value, "retention_post_expiry_matches")["value"] = 1

        def unfiltered_staging_policy(value: dict[str, object]) -> None:
            value["subject"]["staging_canary"]["alert_policy_sha256"] = value[
                "subject"
            ]["production"]["alert_policy_sha256"]

        def different_staging_image(value: dict[str, object]) -> None:
            value["subject"]["staging_canary"]["collector_image_digest"] = digest(
                "different staging collector image"
            )

        def unbound_production_deployment(value: dict[str, object]) -> None:
            value["subject"]["production"]["deployment_id"] = prefixed(
                "deployment-binding-v1:sha256:",
                "another production telemetry deployment",
            )

        for label, mutate in (
            ("production delivery", production_delivery),
            ("production receiver routing", incomplete_production_routing),
            ("retention ingestion", missed_retention_ingestion),
            ("retention pre-expiry presence", lost_before_expiry),
            ("retention query age", query_age_mismatch),
            ("retention post-expiry absence", present_after_expiry),
            ("staging policy identity", unfiltered_staging_policy),
            ("candidate image parity", different_staging_image),
            ("production deployment binding", unbound_production_deployment),
        ):
            with self.subTest(boundary=label):
                value = manifest(evidence.TELEMETRY_GATE)
                mutate(value)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(reseal(value))

    def test_gate_specific_thresholds_and_relations_fail_closed(self) -> None:
        cases: list[tuple[str, str, Callable[[dict[str, object]], None]]] = []

        def embedded_version(value: dict[str, object]) -> None:
            value["subject"]["embedded_migration_version"] = 10

        def resolution_path(value: dict[str, object]) -> None:
            value["subject"]["resolution_path"] = "statement_only"

        def retention(value: dict[str, object]) -> None:
            value["subject"]["production"]["retention_days"] = 29
            metric(value, "production_retention_days")["value"] = 29

        def protected_sentinel(value: dict[str, object]) -> None:
            metric(value, "staging_protected_sentinel_matches")["value"] = 1

        def node_coverage(value: dict[str, object]) -> None:
            metric(value, "staging_observed_node_agents")["value"] = 2

        def startup_p95(value: dict[str, object]) -> None:
            metric(value, "cached_first_readable_frame_p95_ms")["value"] = 1_501

        def opening(value: dict[str, object]) -> None:
            metric(value, "opening_transition_ms")["value"] = 701

        def cache_rate(value: dict[str, object]) -> None:
            metric(value, "sequential_cache_hits")["value"] = 94

        def crash_rate(value: dict[str, object]) -> None:
            metric(value, "crash_free_sessions")["value"] = 994
            metric(value, "crashed_sessions")["value"] = 6
            metric(value, "crash_free_basis_points")["value"] = 9_940

        cases.extend(
            [
                ("migration version", evidence.MIGRATION_GATE, embedded_version),
                ("migration resolution", evidence.MIGRATION_GATE, resolution_path),
                ("telemetry retention", evidence.TELEMETRY_GATE, retention),
                ("telemetry redaction", evidence.TELEMETRY_GATE, protected_sentinel),
                ("telemetry coverage", evidence.TELEMETRY_GATE, node_coverage),
                ("mobile startup", evidence.MOBILE_GATE, startup_p95),
                ("mobile opening", evidence.MOBILE_GATE, opening),
                ("mobile cache", evidence.MOBILE_GATE, cache_rate),
                ("mobile crash", evidence.MOBILE_GATE, crash_rate),
            ]
        )
        for label, gate, mutate in cases:
            with self.subTest(boundary=label):
                value = manifest(gate)
                mutate(value)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(reseal(value))

        valid = manifest(evidence.MIGRATION_GATE)
        expected = copy.deepcopy(valid["binding"])
        expected["candidate_id"] = digest("different expected candidate")
        with self.assertRaisesRegex(evidence.EvidenceError, "expected release"):
            evidence.validate_evidence(valid, expected_binding=expected)

    def test_source_deployment_candidate_configuration_and_tool_bindings_fail_closed(
        self,
    ) -> None:
        def source(value: dict[str, object]) -> None:
            value["binding"]["source_revision"] = "a" * 40

        def deployment(value: dict[str, object]) -> None:
            value["binding"]["deployment_id"] = digest("not a deployment binding")

        def candidate(value: dict[str, object]) -> None:
            value["binding"]["candidate_id"] = "sha256:" + "b" * 64

        def configuration(value: dict[str, object]) -> None:
            value["binding"]["configuration_sha256"] = "sha256:" + "c" * 64

        def tool(value: dict[str, object]) -> None:
            value["binding"]["tools"][0]["sha256"] = "sha256:" + "d" * 64

        for label, mutate in (
            ("source", source),
            ("deployment", deployment),
            ("candidate", candidate),
            ("configuration", configuration),
            ("tool", tool),
        ):
            with self.subTest(binding=label):
                value = manifest(evidence.MIGRATION_GATE)
                mutate(value)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(reseal(value))

    def test_window_cleanup_approval_assertion_and_sanitization_fail_closed(
        self,
    ) -> None:
        mutations = []

        reversed_window = manifest(evidence.MIGRATION_GATE)
        reversed_window["window"]["completed_at"] = "2026-05-31T23:59:59Z"
        mutations.append(reversed_window)

        cleanup = manifest(evidence.TELEMETRY_GATE)
        cleanup["cleanup"]["remaining_test_records"] = 1
        mutations.append(cleanup)

        approval = manifest(evidence.MOBILE_GATE)
        approval["approvals"].pop()
        mutations.append(approval)

        assertion = manifest(evidence.MIGRATION_GATE)
        assertion["assertions"][0]["outcome"] = "failed"
        mutations.append(assertion)

        sanitization = manifest(evidence.TELEMETRY_GATE)
        sanitization["sanitization"]["contains_raw_telemetry"] = True
        mutations.append(sanitization)

        for value in mutations:
            with self.subTest(gate=value["gate"]):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_evidence(reseal(value))

    def test_duplicate_noncanonical_nonfinite_oversized_and_unsafe_files_fail(
        self,
    ) -> None:
        valid = manifest(evidence.MIGRATION_GATE)
        canonical = evidence.encode_canonical_document(valid)
        duplicate = self.directory / "duplicate.json"
        duplicate.write_bytes(b'{"schema_version":1,' + canonical[1:])
        noncanonical = self.directory / "pretty.json"
        noncanonical.write_text(json.dumps(valid, indent=2), encoding="utf-8")
        nonfinite = self.directory / "nonfinite.json"
        nonfinite.write_bytes(
            canonical.replace(b'"size_bytes":100', b'"size_bytes":NaN', 1)
        )
        oversized = self.directory / "oversized.json"
        oversized.write_bytes(b" " * (evidence.MAX_DOCUMENT_BYTES + 1))
        writable = self.write("writable.json", valid)
        writable.chmod(0o666)
        for path in (duplicate, noncanonical, nonfinite, oversized, writable):
            with self.subTest(path=path.name), self.assertRaises(
                evidence.EvidenceError
            ):
                evidence.read_evidence(path)

    def test_tamper_placeholder_plain_id_and_incomplete_build_inputs_fail(self) -> None:
        value = manifest(evidence.MOBILE_GATE)
        value["artifacts"][0]["size_bytes"] += 1
        with self.assertRaisesRegex(evidence.EvidenceError, "approval subject"):
            evidence.validate_evidence(value)

        placeholder = manifest(evidence.MIGRATION_GATE)
        placeholder["artifacts"][0]["sha256"] = "sha256:" + "e" * 64
        with self.assertRaisesRegex(evidence.EvidenceError, "placeholder"):
            evidence.validate_evidence(reseal(placeholder))

        plain = manifest(evidence.TELEMETRY_GATE)
        plain["content_id"] = digest("plain undomained evidence ID")
        with self.assertRaisesRegex(evidence.EvidenceError, "gate domain"):
            evidence.validate_evidence(plain)

        spec = evidence.GATE_SPECS[evidence.MIGRATION_GATE]
        started_at, completed_at, _ = window(evidence.MIGRATION_GATE)
        with self.assertRaisesRegex(evidence.EvidenceError, "assertion inputs"):
            evidence.build_evidence(
                evidence.MIGRATION_GATE,
                binding(evidence.MIGRATION_GATE),
                subject(evidence.MIGRATION_GATE),
                started_at=started_at,
                completed_at=completed_at,
                artifacts={
                    artifact_id: (digest(artifact_id), 1)
                    for artifact_id in spec.artifact_ids
                },
                assertion_outcomes={},
                metrics=metrics(evidence.MIGRATION_GATE),
                cleanup={},
                approvals=[],
            )

    def test_bundle_rejects_rebound_manifest_and_source_revision(self) -> None:
        manifests = {gate: manifest(gate) for gate in evidence.GATES}
        bundle = evidence.build_bundle(manifests)

        rebound = copy.deepcopy(bundle)
        rebound["gates"][0]["content_id"] = manifest(evidence.MIGRATION_GATE)[
            "content_id"
        ]
        rebound["content_id"] = evidence.compute_bundle_content_id(rebound)
        changed_manifest = copy.deepcopy(manifests[evidence.MIGRATION_GATE])
        changed_manifest["subject"]["starting_app_version"] = "0.0.9"
        changed_manifest = reapprove_and_reseal(changed_manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "does not match"):
            evidence.validate_bundle(
                rebound, {**manifests, evidence.MIGRATION_GATE: changed_manifest}
            )

        different_source = copy.deepcopy(manifests[evidence.MOBILE_GATE])
        different_source["binding"]["source_revision"] = hashlib.sha1(
            b"different reviewed source"
        ).hexdigest()
        different_source = reapprove_and_reseal(different_source)
        with self.assertRaisesRegex(evidence.EvidenceError, "source revision"):
            evidence.build_bundle({**manifests, evidence.MOBILE_GATE: different_source})

    def test_cli_validates_and_bundles_without_producing_gate_facts(self) -> None:
        manifests = {gate: manifest(gate) for gate in evidence.GATES}
        paths = {
            gate: self.write(f"{gate}.json", manifests[gate]) for gate in evidence.GATES
        }
        binding_path = self.write(
            "expected-migration-binding.json",
            manifests[evidence.MIGRATION_GATE]["binding"],
        )
        script = pathlib.Path(__file__).with_name("operational_gate_evidence.py")
        checked = subprocess.run(
            [
                sys.executable,
                str(script),
                "validate",
                str(paths[evidence.MIGRATION_GATE]),
                "--gate",
                evidence.MIGRATION_GATE,
                "--expected-id",
                manifests[evidence.MIGRATION_GATE]["content_id"],
                "--expected-binding",
                str(binding_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("Validated operational gate", checked.stdout)

        bundle_path = self.directory / "operational-gates.json"
        manifest_arguments = [
            item
            for gate in evidence.GATES
            for item in ("--manifest", f"{gate}={paths[gate]}")
        ]
        subprocess.run(
            [
                sys.executable,
                str(script),
                "bundle",
                *manifest_arguments,
                "--output",
                str(bundle_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        verified = subprocess.run(
            [
                sys.executable,
                str(script),
                "validate-bundle",
                str(bundle_path),
                *manifest_arguments,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("Validated operational gate bundle", verified.stdout)
        self.assertEqual(bundle_path.stat().st_mode & 0o777, 0o600)

    def test_output_rejects_unsafe_parent_and_removes_partial_file(self) -> None:
        bundle = evidence.build_bundle(
            {gate: manifest(gate) for gate in evidence.GATES}
        )
        unsafe = self.directory / "unsafe"
        unsafe.mkdir()
        unsafe.chmod(0o777)
        unsafe_output = unsafe / "bundle.json"
        with self.assertRaisesRegex(evidence.EvidenceError, "output parent"):
            evidence._write_exclusive(unsafe_output, bundle)
        self.assertFalse(unsafe_output.exists())

        safe = self.directory / "safe"
        safe.mkdir(mode=0o700)
        linked = self.directory / "linked"
        linked.symlink_to(safe, target_is_directory=True)
        linked_output = linked / "bundle.json"
        with self.assertRaisesRegex(evidence.EvidenceError, "output parent"):
            evidence._write_exclusive(linked_output, bundle)
        self.assertFalse((safe / "bundle.json").exists())

        partial = safe / "partial.json"
        with mock.patch.object(
            evidence.os,
            "write",
            side_effect=OSError("synthetic short storage failure"),
        ), self.assertRaisesRegex(evidence.EvidenceError, "output evidence write"):
            evidence._write_exclusive(partial, bundle)
        self.assertFalse(partial.exists())


if __name__ == "__main__":
    unittest.main()
