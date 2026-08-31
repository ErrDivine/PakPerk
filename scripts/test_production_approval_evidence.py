#!/usr/bin/env python3
"""Focused hermetic tests for production approval evidence contracts."""

from __future__ import annotations

import copy
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

import production_approval_evidence as evidence


def digest(label: str) -> str:
    return f"sha256:{hashlib.sha256(label.encode('ascii')).hexdigest()}"


IMAGES = {
    "backend": {
        "repository": "ghcr.io/errdivine/pakperk-backend",
        "digest": digest("backend-image"),
    },
    "site": {
        "repository": "ghcr.io/errdivine/pakperk-site",
        "digest": digest("site-image"),
    },
    "grobid": {
        "repository": "grobid/grobid",
        "digest": digest("grobid-image"),
    },
    "otelCollector": {
        "repository": "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib",
        "digest": digest("collector-image"),
    },
}
RESTORE_DRILL_ID = digest("restore-drill")
TO_READ_FIRST_FEATURE_KEYS = {
    "paperResolution",
    "paperTitleSearch",
    "libraryImportWrites",
    "readingFeed",
    "toReadFirstEnforcement",
}
FEATURE_KEYS = set(evidence.FEATURE_KEYS)


def release_contract(gate_ids: dict[str, str] | None = None) -> dict[str, object]:
    approvals = {gate: "" for gate in evidence.GATES}
    if gate_ids is not None:
        approvals.update(gate_ids)
    approvals["restoreDrillId"] = RESTORE_DRILL_ID
    approvals["deepReaderReleaseId"] = ""
    features = dict.fromkeys(FEATURE_KEYS, False)
    features.update(
        {
            "accounts": True,
            "library": True,
            "libraryWrites": True,
            "paperResolution": True,
            "paperTitleSearch": True,
            "libraryImportWrites": True,
            "readingFeed": True,
            "toReadFirstEnforcement": True,
            "comments": True,
            "commentCreation": True,
            "accountDeletion": True,
            "libraryV2": True,
            "researchProfiles": True,
            "recommendations": True,
            "recommendationEvents": True,
            "searchLookup": True,
            "searchExplore": True,
            "savedQueries": True,
            "readingBriefs": True,
            "subscriptions": True,
            "notifications": True,
        }
    )
    return {
        "schemaVersion": 1,
        "environment": "production",
        "features": features,
        "releaseEvidence": approvals,
        "alertPolicySha256": digest("alert-policy"),
        "images": copy.deepcopy(IMAGES),
        "chart": {"name": "pakperk", "version": "0.2.0", "appVersion": "0.2.0"},
        "legalPolicy": {
            "documentVersion": "2026-08-01",
            "termsVersion": "2026-08-01",
            "communityGuidelinesVersion": "2026-08-01",
            "fulltext": "strict",
        },
    }


def binding(
    contract: dict[str, object] | None = None,
) -> dict[str, object]:
    contract = contract or release_contract()
    return {
        "source_revision": hashlib.sha1(b"production-source").hexdigest(),
        "target_environment": "production",
        "release_configuration_sha256": evidence.compute_release_configuration_id(
            contract
        ),
        "deployment_images_sha256": evidence.compute_deployment_images_id(IMAGES),
        "restore_drill_id": RESTORE_DRILL_ID,
        "helm_chart_version": "0.2.0",
        "helm_app_version": "0.2.0",
        "mobile_candidate_id": digest("mobile-candidate"),
        "mobile_version": "0.2.0",
        "mobile_build": 2,
    }


def old_client_policy(
    *,
    strategy: str = "minimum_supported_version",
    policy_binding: dict[str, object] | None = None,
    adoption_threshold_basis_points: int | None = None,
) -> dict[str, object]:
    if strategy == "minimum_supported_version":
        parameters = {
            "minimum_mobile_version": "0.2.0",
            "minimum_mobile_build": 2,
            "enforcement_mechanism": "remote_configuration",
        }
        policy_evidence = {
            "policy_record_sha256": digest("minimum-version-policy"),
            "minimum_version_enforcement_sha256": digest(
                "minimum-version-enforcement"
            ),
            "rollback_evidence_sha256": digest("minimum-version-rollback"),
        }
    elif strategy == "disable_legacy_account_library":
        parameters = {
            "legacy_maximum_mobile_version": "0.1.0",
            "legacy_maximum_mobile_build": 1,
            "account_access": "disabled",
            "library_access": "disabled",
        }
        policy_evidence = {
            "policy_record_sha256": digest("legacy-access-policy"),
            "legacy_access_gate_sha256": digest("legacy-access-gate"),
            "rollback_evidence_sha256": digest("legacy-access-rollback"),
        }
    else:
        assert strategy == "advisory_until_adoption_threshold"
        assert adoption_threshold_basis_points is not None
        parameters = {
            "adoption_threshold_basis_points": adoption_threshold_basis_points,
            "minimum_observation_hours": 24,
            "enforcement_claim": "advisory",
        }
        policy_evidence = {
            "policy_record_sha256": digest("advisory-policy"),
            "adoption_measurement_sha256": digest("adoption-measurement"),
            "rollback_evidence_sha256": digest("advisory-rollback"),
        }
    return evidence.build_old_client_policy(
        policy_binding or binding(),
        strategy=strategy,
        parameters=parameters,
        policy_evidence=policy_evidence,
        approved_at="2026-08-01T03:00:00Z",
        protected_audit_reference=digest(f"{strategy}-approval"),
    )


def measurements(
    gate: str, references: dict[str, str] | None = None
) -> dict[str, object]:
    if gate == "legalReviewId":
        return {
            "document_version": "2026-08-01",
            "published_routes_checked": 4,
            "support_canary_attempts": 2,
            "support_canary_successes": 2,
            "enabled_features_sha256": digest("enabled-features"),
            "sdk_processor_inventory_sha256": digest("processors"),
            "data_practices_sha256": digest("data-practices"),
            "retention_schedule_sha256": digest("retention"),
            "jurisdictions_contracts_sha256": digest("jurisdictions"),
        }
    if gate == "reviewerFlowId":
        assert references is not None
        return {
            "walkthrough_steps_passed": 9,
            "account_expires_at": "2026-09-01T02:00:00Z",
            "account_lifecycle_sha256": digest("account-lifecycle"),
            "reviewer_notes_sha256": digest("reviewer-notes"),
            "physical_acceptance_id": digest("physical-acceptance"),
            "account_deletion_e2e_id": references["accountDeletionE2eId"],
            "sbom_inventory_sha256": digest("mobile-sbom"),
            "legal_review_id": references["legalReviewId"],
            "strict_content_review_id": references["strictContentReviewId"],
        }
    if gate == "strictContentReviewId":
        return {
            "fulltext_policy": "strict",
            "allowed_surface_checks": 4,
            "introduction_behavior_checks": 2,
            "derived_fallback_exposures": 0,
            "configuration_sha256": digest("strict-configuration"),
            "retention_display_policy_sha256": digest("strict-retention"),
        }
    if gate == "moderationReadinessId":
        return {
            "operator_boundary_cases_passed": 4,
            "live_queue_types_exercised": 4,
            "moderation_actions_exercised": 6,
            "audit_records_verified": 6,
            "alert_ticket_canaries_passed": 2,
            "staffed_response_target_seconds": 3600,
            "escalation_exercises_passed": 1,
            "moderation_audit_inventory_sha256": digest("moderation-audit"),
        }
    if gate == "accountDeletionE2eId":
        return {
            "reauthentication_rejections": 1,
            "reauthentication_acceptances": 1,
            "application_rows_purged": 7,
            "application_rows_pseudonymized": 1,
            "external_ledger_records": 1,
            "database_jobs": 1,
            "replay_attempts": 1,
            "alert_canaries_passed": 1,
            "operation_id_sha256": digest("deletion-operation"),
            "secret_manager_reference_sha256": digest("secret-version"),
            "ledger_inventory_sha256": digest("ledger-inventory"),
            "backup_inventory_sha256": digest("backup-inventory"),
        }
    raise AssertionError(gate)


def build_gate(
    gate: str, references: dict[str, str] | None = None
) -> dict[str, object]:
    spec = evidence.GATE_SPECS[gate]
    return evidence.build_evidence(
        gate,
        binding(),
        started_at="2026-08-01T00:00:00Z",
        completed_at="2026-08-01T01:00:00Z",
        approved_at="2026-08-01T02:00:00Z",
        protected_audit_reference=digest(f"{gate}-protected-audit"),
        artifacts={
            artifact_id: (digest(f"{gate}-{artifact_id}"), 1024 + index)
            for index, artifact_id in enumerate(spec.artifacts)
        },
        measurements=measurements(gate, references),
    )


def manifest_set() -> dict[str, dict[str, object]]:
    manifests = {
        gate: build_gate(gate)
        for gate in (
            "legalReviewId",
            "strictContentReviewId",
            "moderationReadinessId",
            "accountDeletionE2eId",
        )
    }
    references = {gate: manifest["content_id"] for gate, manifest in manifests.items()}
    manifests["reviewerFlowId"] = build_gate("reviewerFlowId", references)
    return {gate: manifests[gate] for gate in evidence.GATES}


def rendered_manifest(
    manifests: dict[str, dict[str, object]],
    contract: dict[str, object] | None = None,
) -> bytes:
    gate_ids = {gate: manifests[gate]["content_id"] for gate in evidence.GATES}
    if contract is None:
        contract = release_contract(gate_ids)
    else:
        contract = copy.deepcopy(contract)
        approvals = contract["releaseEvidence"]
        assert isinstance(approvals, dict)
        approvals.update(gate_ids)
    canonical_contract = json.dumps(
        contract, allow_nan=False, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    )
    binding_sha = digest_bytes(canonical_contract.encode("ascii"))
    approval_sha = digest_bytes(
        json.dumps(
            contract["releaseEvidence"],
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("ascii")
    )
    def encoded_mirror(value: object) -> str:
        canonical = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )
        return json.dumps(canonical, ensure_ascii=True)

    lines = [
        "---",
        "# Source: pakperk/templates/release-evidence.yaml",
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        f"  name: pakperk-pakperk-release-evidence-{binding_sha.removeprefix('sha256:')[:12]}",
        "  labels:",
        "    app.kubernetes.io/name: pakperk",
        "    app.kubernetes.io/instance: pakperk",
        "    app.kubernetes.io/managed-by: Helm",
        f'    app.kubernetes.io/version: "{contract["chart"]["appVersion"]}"',
        f'    helm.sh/chart: "pakperk-{contract["chart"]["version"]}"',
        "    app.kubernetes.io/component: release-evidence",
        "  annotations:",
        f'    pakperk.app/release-evidence-sha256: "{approval_sha}"',
        f'    pakperk.app/release-binding-sha256: "{binding_sha}"',
        '    pakperk.app/release-binding-schema: "1"',
        "immutable: true",
        "data:",
        f'  environment: "{contract["environment"]}"',
        f'  enabledFeatures.json: {encoded_mirror(contract["features"])}',
        f'  alertPolicySha256: "{contract["alertPolicySha256"]}"',
        f'  imageIdentities.json: {encoded_mirror(contract["images"])}',
        f'  chartIdentity.json: {encoded_mirror(contract["chart"])}',
        f'  legalPolicy.json: {encoded_mirror(contract["legalPolicy"])}',
        f"  releaseContract.json: {json.dumps(canonical_contract, ensure_ascii=True)}",
    ]
    lines.extend(
        f'  {key}: "{contract["releaseEvidence"][key]}"'
        for key in (*evidence.GATES, "restoreDrillId", "deepReaderReleaseId")
    )
    return ("\n".join(lines) + "\n").encode("ascii")


def digest_bytes(value: bytes) -> str:
    return f"sha256:{hashlib.sha256(value).hexdigest()}"


def bundle_for(
    manifests: dict[str, dict[str, object]],
) -> tuple[dict[str, object], bytes, dict[str, object]]:
    gate_ids = {gate: manifests[gate]["content_id"] for gate in evidence.GATES}
    rendered = rendered_manifest(manifests)
    policy = old_client_policy()
    deployment = evidence.validate_rendered_deployment(
        rendered, binding(), gate_ids, policy
    )
    return (
        evidence.build_bundle(binding(), gate_ids, deployment),
        rendered,
        policy,
    )


def set_measurement(
    manifest: dict[str, object], measurement_id: str, value: object
) -> None:
    values = manifest["measurements"]
    assert isinstance(values, list)
    item = next(item for item in values if item["id"] == measurement_id)
    item["value"] = value


class ProductionApprovalEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = pathlib.Path(self.temporary_directory.name)

    def write(self, name: str, value: object) -> pathlib.Path:
        path = self.directory / name
        path.write_bytes(evidence.encode_canonical_document(value))
        return path

    def test_all_five_gates_and_predeploy_bundle_validate(self) -> None:
        manifests = manifest_set()
        for gate in evidence.GATES:
            validated = evidence.validate_evidence(manifests[gate], expected_gate=gate)
            self.assertEqual(validated["binding"]["target_environment"], "production")
        bundle, rendered, policy = bundle_for(manifests)
        validated = evidence.validate_predeploy(bundle, manifests, policy)
        self.assertEqual(tuple(validated), evidence.GATES)
        self.assertEqual(
            bundle["deployment"],
            evidence.validate_rendered_deployment(
                rendered,
                binding(),
                {gate: manifests[gate]["content_id"] for gate in evidence.GATES},
                policy,
            ),
        )

    def test_release_features_are_exact_default_off_and_dependency_checked(
        self,
    ) -> None:
        manifests = manifest_set()
        gate_ids = {
            gate: manifests[gate]["content_id"] for gate in evidence.GATES
        }

        default_off = release_contract(gate_ids)
        default_off["features"] = dict.fromkeys(FEATURE_KEYS, False)
        evidence.validate_rendered_deployment(
            rendered_manifest(manifests, default_off),
            binding(default_off),
            gate_ids,
        )
        self.assertEqual(set(release_contract()["features"]), FEATURE_KEYS)

        for key in FEATURE_KEYS:
            with self.subTest(missing=key):
                missing = release_contract(gate_ids)
                features = missing["features"]
                assert isinstance(features, dict)
                features.pop(key)
                with self.assertRaisesRegex(
                    evidence.EvidenceError, "exact required keys"
                ):
                    evidence.validate_rendered_deployment(
                        rendered_manifest(manifests, missing),
                        binding(missing),
                        gate_ids,
                    )

        extra = release_contract(gate_ids)
        extra_features = extra["features"]
        assert isinstance(extra_features, dict)
        extra_features["unreviewedFeature"] = False
        with self.assertRaisesRegex(evidence.EvidenceError, "exact required keys"):
            evidence.validate_rendered_deployment(
                rendered_manifest(manifests, extra), binding(extra), gate_ids
            )

        non_boolean = release_contract(gate_ids)
        non_boolean_features = non_boolean["features"]
        assert isinstance(non_boolean_features, dict)
        non_boolean_features["readingFeed"] = "false"
        with self.assertRaisesRegex(evidence.EvidenceError, "not boolean"):
            evidence.validate_rendered_deployment(
                rendered_manifest(manifests, non_boolean),
                binding(non_boolean),
                gate_ids,
            )

        invalid_feature_sets = {
            "library without accounts": {"library": True},
            "writes without library": {
                "accounts": True,
                "accountDeletion": True,
                "libraryWrites": True,
            },
            "search without resolution": {
                "accounts": True,
                "accountDeletion": True,
                "paperTitleSearch": True,
            },
            "search without accounts": {
                "paperResolution": True,
                "paperTitleSearch": True,
            },
            "import without library writes": {
                "accounts": True,
                "accountDeletion": True,
                "library": True,
                "paperResolution": True,
                "libraryImportWrites": True,
            },
            "feed without library": {
                "accounts": True,
                "accountDeletion": True,
                "readingFeed": True,
            },
            "enforcement without feed": {"toReadFirstEnforcement": True},
            "comments without accounts": {"comments": True},
            "creation without comments": {
                "accounts": True,
                "accountDeletion": True,
                "commentCreation": True,
            },
            "deletion without accounts": {"accountDeletion": True},
            "production accounts without deletion": {"accounts": True},
            "library v2 without library": {
                "accounts": True,
                "accountDeletion": True,
                "libraryV2": True,
            },
            "research profiles without accounts": {"researchProfiles": True},
            "recommendations without feed": {
                "accounts": True,
                "accountDeletion": True,
                "library": True,
                "recommendations": True,
            },
            "explore without lookup": {"searchExplore": True},
            "saved query without explore": {
                "accounts": True,
                "accountDeletion": True,
                "savedQueries": True,
            },
            "brief without feed": {"readingBriefs": True},
            "subscription without feed": {
                "accounts": True,
                "accountDeletion": True,
                "library": True,
                "subscriptions": True,
            },
            "notification without subscription": {"notifications": True},
            "passport without deep reader": {"paperPassport": True},
            "annotations without account": {
                "deepReader": True,
                "annotations": True,
            },
            "memory without annotations": {
                "accounts": True,
                "accountDeletion": True,
                "deepReader": True,
                "researchMemory": True,
            },
        }
        for label, enabled in invalid_feature_sets.items():
            with self.subTest(case=label):
                invalid = release_contract(gate_ids)
                invalid["features"] = {
                    key: enabled.get(key, False) for key in FEATURE_KEYS
                }
                with self.assertRaisesRegex(
                    evidence.EvidenceError, "feature dependencies"
                ):
                    evidence.validate_rendered_deployment(
                        rendered_manifest(manifests, invalid),
                        binding(invalid),
                        gate_ids,
                    )

        deep_reader = release_contract(gate_ids)
        deep_reader["features"] = dict.fromkeys(FEATURE_KEYS, False)
        deep_reader["features"]["deepReader"] = True
        with self.assertRaisesRegex(evidence.EvidenceError, "Deep Reader"):
            evidence.validate_rendered_deployment(
                rendered_manifest(manifests, deep_reader),
                binding(deep_reader),
                gate_ids,
            )
        deep_reader["releaseEvidence"]["deepReaderReleaseId"] = digest(
            "complete-deep-reader-release-bundle"
        )
        evidence.validate_rendered_deployment(
            rendered_manifest(manifests, deep_reader),
            binding(deep_reader),
            gate_ids,
        )

    def test_to_read_first_feature_tampering_breaks_approval_binding(
        self,
    ) -> None:
        manifests = manifest_set()
        gate_ids = {
            gate: manifests[gate]["content_id"] for gate in evidence.GATES
        }
        prerequisites = {
            "paperResolution": {},
            "paperTitleSearch": {
                "accounts": True,
                "accountDeletion": True,
                "paperResolution": True,
            },
            "libraryImportWrites": {
                "accounts": True,
                "accountDeletion": True,
                "library": True,
                "libraryWrites": True,
                "paperResolution": True,
            },
            "readingFeed": {
                "accounts": True,
                "accountDeletion": True,
                "library": True,
            },
            "toReadFirstEnforcement": {
                "accounts": True,
                "accountDeletion": True,
                "library": True,
                "readingFeed": True,
            },
        }
        for key, required in prerequisites.items():
            with self.subTest(feature=key):
                baseline = release_contract(gate_ids)
                baseline["features"] = {
                    feature: required.get(feature, False)
                    for feature in FEATURE_KEYS
                }
                changed = copy.deepcopy(baseline)
                changed_features = changed["features"]
                assert isinstance(changed_features, dict)
                changed_features[key] = True
                self.assertNotEqual(
                    evidence.compute_release_configuration_id(baseline),
                    evidence.compute_release_configuration_id(changed),
                )
                with self.assertRaisesRegex(
                    evidence.EvidenceError, "release configuration"
                ):
                    evidence.validate_rendered_deployment(
                        rendered_manifest(manifests, changed),
                        binding(baseline),
                        gate_ids,
                    )

    def test_old_client_policy_is_dormant_until_strict_enforcement(self) -> None:
        manifests = manifest_set()
        gate_ids = {
            gate: manifests[gate]["content_id"] for gate in evidence.GATES
        }
        strict_rendered = rendered_manifest(manifests)
        with self.assertRaisesRegex(
            evidence.EvidenceError, "requires an approved old-client policy"
        ):
            evidence.validate_rendered_deployment(
                strict_rendered, binding(), gate_ids
            )

        shadow = release_contract(gate_ids)
        shadow_features = shadow["features"]
        assert isinstance(shadow_features, dict)
        shadow_features["toReadFirstEnforcement"] = False
        deployment = evidence.validate_rendered_deployment(
            rendered_manifest(manifests, shadow), binding(shadow), gate_ids
        )
        self.assertIs(deployment["to_read_first_enforcement"], False)
        self.assertIsNone(deployment["old_client_policy_id"])

        policies = [
            old_client_policy(),
            old_client_policy(strategy="disable_legacy_account_library"),
            old_client_policy(
                strategy="advisory_until_adoption_threshold",
                adoption_threshold_basis_points=1,
            ),
        ]
        for policy in policies:
            with self.subTest(strategy=policy["strategy"]):
                self.assertEqual(
                    evidence.validate_old_client_policy(policy)["content_id"],
                    policy["content_id"],
                )
                strict = evidence.validate_rendered_deployment(
                    strict_rendered, binding(), gate_ids, policy
                )
                self.assertEqual(
                    strict["old_client_policy_id"], policy["content_id"]
                )
                self.assertIs(strict["to_read_first_enforcement"], True)

    def test_old_client_policy_is_closed_release_bound_and_tamper_evident(
        self,
    ) -> None:
        policy = old_client_policy()

        extra = copy.deepcopy(policy)
        extra["parameters"]["unreviewed"] = False
        extra["content_id"] = evidence.compute_old_client_policy_content_id(
            extra
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "exact required keys"):
            evidence.validate_old_client_policy(extra)

        tampered = copy.deepcopy(policy)
        tampered["parameters"]["minimum_mobile_build"] = 1
        tampered["content_id"] = evidence.compute_old_client_policy_content_id(
            tampered
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "not release-bound"):
            evidence.validate_old_client_policy(
                tampered, expected_content_id=policy["content_id"]
            )

        evidence_tampered = copy.deepcopy(policy)
        evidence_tampered["evidence"]["rollback_evidence_sha256"] = digest(
            "different-rollback-evidence"
        )
        evidence_tampered["content_id"] = (
            evidence.compute_old_client_policy_content_id(evidence_tampered)
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "not release-bound"):
            evidence.validate_old_client_policy(
                evidence_tampered, expected_content_id=policy["content_id"]
            )

        unapproved = copy.deepcopy(policy)
        unapproved["approval"]["decision"] = "pending"
        unapproved["content_id"] = evidence.compute_old_client_policy_content_id(
            unapproved
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "owner approval"):
            evidence.validate_old_client_policy(unapproved)

        wrong_release = copy.deepcopy(policy)
        wrong_release["binding"]["mobile_build"] = 3
        wrong_release["content_id"] = (
            evidence.compute_old_client_policy_content_id(wrong_release)
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "expected release"):
            evidence.validate_old_client_policy(
                wrong_release, expected_binding=binding()
            )

        advisory = old_client_policy(
            strategy="advisory_until_adoption_threshold",
            adoption_threshold_basis_points=1,
        )
        for invalid_threshold in (0, 10_001):
            with self.subTest(threshold=invalid_threshold):
                invalid = copy.deepcopy(advisory)
                invalid["parameters"][
                    "adoption_threshold_basis_points"
                ] = invalid_threshold
                invalid["content_id"] = (
                    evidence.compute_old_client_policy_content_id(invalid)
                )
                with self.assertRaisesRegex(
                    evidence.EvidenceError, "integer boundary"
                ):
                    evidence.validate_old_client_policy(invalid)

        manifests = manifest_set()
        bundle, _, bound_policy = bundle_for(manifests)
        different_policy = old_client_policy(
            strategy="disable_legacy_account_library"
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "release-bound"):
            evidence.validate_predeploy(
                bundle, manifests, different_policy
            )
        with self.assertRaisesRegex(evidence.EvidenceError, "requires"):
            evidence.validate_predeploy(bundle, manifests)
        evidence.validate_predeploy(bundle, manifests, bound_policy)

    def test_duplicate_noncanonical_and_oversized_files_fail(self) -> None:
        valid = manifest_set()["legalReviewId"]
        duplicate = self.directory / "duplicate.json"
        duplicate.write_text(
            '{"schema_version":1,"schema_version":1}\n', encoding="ascii"
        )
        pretty = self.directory / "pretty.json"
        pretty.write_text(json.dumps(valid, indent=2) + "\n", encoding="ascii")
        oversized = self.directory / "oversized.json"
        oversized.write_bytes(b" " * (evidence.MAX_DOCUMENT_BYTES + 1))
        for path in (duplicate, pretty, oversized):
            with self.subTest(path=path.name), self.assertRaises(
                evidence.EvidenceError
            ):
                evidence.read_evidence(path)

    def test_exact_keys_and_content_id_tampering_fail(self) -> None:
        valid = manifest_set()["legalReviewId"]
        extra = copy.deepcopy(valid)
        extra["operator_name"] = "not allowed"
        tampered = copy.deepcopy(valid)
        set_measurement(tampered, "document_version", "2026-08-02")
        for candidate in (extra, tampered):
            with self.subTest(keys=tuple(candidate)), self.assertRaises(
                evidence.EvidenceError
            ):
                evidence.validate_evidence(candidate)

    def test_sanitization_placeholder_reference_and_environment_fail(self) -> None:
        valid = manifest_set()["legalReviewId"]
        mutations = []
        sanitization = copy.deepcopy(valid)
        sanitization["sanitization"]["contains_tokens"] = True
        sanitization["content_id"] = evidence.compute_evidence_content_id(sanitization)
        mutations.append(sanitization)
        placeholder = copy.deepcopy(valid)
        placeholder["binding"]["release_configuration_sha256"] = (
            "sha256:" + "a" * 64
        )
        placeholder["content_id"] = evidence.compute_evidence_content_id(placeholder)
        mutations.append(placeholder)
        reference = copy.deepcopy(valid)
        reference["classification"] = "manual_ci_disposable_reference"
        reference["content_id"] = evidence.compute_evidence_content_id(reference)
        mutations.append(reference)
        staging = copy.deepcopy(valid)
        staging["binding"]["target_environment"] = "staging"
        staging["content_id"] = evidence.compute_evidence_content_id(staging)
        mutations.append(staging)
        for candidate in mutations:
            with self.subTest(
                classification=candidate["classification"]
            ), self.assertRaises(evidence.EvidenceError):
                evidence.validate_evidence(candidate)

    def test_gate_specific_and_bundle_binding_tampering_fail(self) -> None:
        manifests = manifest_set()
        invalid_gate = copy.deepcopy(manifests["moderationReadinessId"])
        set_measurement(invalid_gate, "live_queue_types_exercised", 3)
        invalid_gate["content_id"] = evidence.compute_evidence_content_id(invalid_gate)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_evidence(invalid_gate)

        reordered = copy.deepcopy(manifests["legalReviewId"])
        reordered["measurements"][0], reordered["measurements"][1] = (
            reordered["measurements"][1],
            reordered["measurements"][0],
        )
        reordered["content_id"] = evidence.compute_evidence_content_id(reordered)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_evidence(reordered)

        bundle, _, policy = bundle_for(manifests)
        rebound = copy.deepcopy(manifests)
        rebound["strictContentReviewId"] = copy.deepcopy(
            rebound["strictContentReviewId"]
        )
        rebound["strictContentReviewId"]["binding"]["mobile_build"] = 3
        rebound["strictContentReviewId"]["content_id"] = (
            evidence.compute_evidence_content_id(rebound["strictContentReviewId"])
        )
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_predeploy(bundle, rebound, policy)

        wrong_id = copy.deepcopy(bundle)
        wrong_id["gates"][0]["content_id"] = digest("wrong-legal-gate-id")
        wrong_id["content_id"] = evidence.compute_bundle_content_id(wrong_id)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_predeploy(wrong_id, manifests, policy)

    def test_normalized_binding_breaks_cycle_and_render_tampering_fails(self) -> None:
        manifests = manifest_set()
        gate_ids = {gate: manifests[gate]["content_id"] for gate in evidence.GATES}
        self.assertEqual(
            evidence.compute_release_configuration_id(release_contract()),
            evidence.compute_release_configuration_id(release_contract(gate_ids)),
        )
        rendered = rendered_manifest(manifests)
        policy = old_client_policy()
        evidence.validate_rendered_deployment(
            rendered, binding(), gate_ids, policy
        )
        tampered = rendered.replace(
            gate_ids["legalReviewId"].encode("ascii"),
            digest("wrong legal mirror").encode("ascii"),
            1,
        )
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_rendered_deployment(
                tampered, binding(), gate_ids, policy
            )

        invalid_documents = {
            "wrong kind": rendered.replace(
                b"kind: ConfigMap", b"kind: Secret", 1
            ),
            "mutable": rendered.replace(
                b"immutable: true", b"immutable: false", 1
            ),
            "unbound name": rendered.replace(
                b"-release-evidence-", b"-release-evidence-unbound-", 1
            ),
            "overlong name": rendered.replace(
                b"name: pakperk-pakperk-", b"name: " + b"a" * 46 + b"-", 1
            ),
            "wrong Pakperk component": rendered.replace(
                b"app.kubernetes.io/component: release-evidence",
                b"app.kubernetes.io/component: api",
                1,
            ),
            "wrong Helm manager": rendered.replace(
                b"app.kubernetes.io/managed-by: Helm",
                b"app.kubernetes.io/managed-by: kubectl",
                1,
            ),
            "wrong binding annotation": rendered.replace(
                b"pakperk.app/release-binding-sha256: \"sha256:",
                b"pakperk.app/release-binding-sha256: \"sha256:0",
                1,
            ),
            "extra data mirror": rendered.replace(
                b"data:\n", b"data:\n  unreviewed.json: \"{}\"\n", 1
            ),
            "mismatched feature mirror": rendered.replace(
                b'\\\"accounts\\\":true', b'\\\"accounts\\\":false', 1
            ),
            "ambiguous release ConfigMap": rendered
            + rendered.replace(
                b"app.kubernetes.io/component: release-evidence",
                b'app.kubernetes.io/component: "release-evidence"',
                1,
            ),
        }
        for label, candidate in invalid_documents.items():
            with self.subTest(label=label), self.assertRaises(
                evidence.EvidenceError
            ):
                evidence.validate_rendered_deployment(
                    candidate, binding(), gate_ids, policy
                )

    def test_cli_validates_manifests_and_predeploy_bundle(self) -> None:
        manifests = manifest_set()
        assignments = []
        for gate in evidence.GATES:
            path = self.write(f"{gate}.json", manifests[gate])
            assignments.extend(["--manifest", f"{gate}={path}"])
        script = pathlib.Path(__file__).with_name("production_approval_evidence.py")
        rendered_path = self.directory / "rendered.yaml"
        rendered_path.write_bytes(rendered_manifest(manifests))
        policy_path = self.write("old-client-policy.json", old_client_policy())
        one = subprocess.run(
            [
                sys.executable,
                str(script),
                "validate",
                str(self.directory / "legalReviewId.json"),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(one.returncode, 0, one.stderr)

        policy_checked = subprocess.run(
            [
                sys.executable,
                str(script),
                "validate-old-client-policy",
                str(policy_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(policy_checked.returncode, 0, policy_checked.stderr)

        bundle_path = self.directory / "predeploy.json"
        built = subprocess.run(
            [
                sys.executable,
                str(script),
                "bundle",
                *assignments,
                "--rendered-manifest",
                str(rendered_path),
                "--old-client-policy",
                str(policy_path),
                "--output",
                str(bundle_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(built.returncode, 0, built.stderr)
        checked = subprocess.run(
            [
                sys.executable,
                str(script),
                "predeploy",
                str(bundle_path),
                *assignments,
                "--rendered-manifest",
                str(rendered_path),
                "--old-client-policy",
                str(policy_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("all five production approval gates", checked.stdout)


if __name__ == "__main__":
    unittest.main()
