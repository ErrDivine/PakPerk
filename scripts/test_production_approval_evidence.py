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


def release_contract(gate_ids: dict[str, str] | None = None) -> dict[str, object]:
    approvals = {gate: "" for gate in evidence.GATES}
    if gate_ids is not None:
        approvals.update(gate_ids)
    approvals["restoreDrillId"] = RESTORE_DRILL_ID
    return {
        "schemaVersion": 1,
        "environment": "production",
        "features": {
            "accounts": True,
            "library": True,
            "libraryWrites": True,
            "comments": True,
            "commentCreation": True,
            "accountDeletion": True,
        },
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


def binding() -> dict[str, object]:
    contract = release_contract()
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


def rendered_manifest(manifests: dict[str, dict[str, object]]) -> bytes:
    gate_ids = {gate: manifests[gate]["content_id"] for gate in evidence.GATES}
    contract = release_contract(gate_ids)
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
        f'  {gate}: "{gate_ids[gate]}"' for gate in evidence.GATES
    )
    lines.append(f'  restoreDrillId: "{RESTORE_DRILL_ID}"')
    return ("\n".join(lines) + "\n").encode("ascii")


def digest_bytes(value: bytes) -> str:
    return f"sha256:{hashlib.sha256(value).hexdigest()}"


def bundle_for(
    manifests: dict[str, dict[str, object]],
) -> tuple[dict[str, object], bytes]:
    gate_ids = {gate: manifests[gate]["content_id"] for gate in evidence.GATES}
    rendered = rendered_manifest(manifests)
    deployment = evidence.validate_rendered_deployment(rendered, binding(), gate_ids)
    return evidence.build_bundle(binding(), gate_ids, deployment), rendered


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
        bundle, rendered = bundle_for(manifests)
        validated = evidence.validate_predeploy(bundle, manifests)
        self.assertEqual(tuple(validated), evidence.GATES)
        self.assertEqual(
            bundle["deployment"],
            evidence.validate_rendered_deployment(
                rendered,
                binding(),
                {gate: manifests[gate]["content_id"] for gate in evidence.GATES},
            ),
        )

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

        bundle, _ = bundle_for(manifests)
        rebound = copy.deepcopy(manifests)
        rebound["strictContentReviewId"] = copy.deepcopy(
            rebound["strictContentReviewId"]
        )
        rebound["strictContentReviewId"]["binding"]["mobile_build"] = 3
        rebound["strictContentReviewId"]["content_id"] = (
            evidence.compute_evidence_content_id(rebound["strictContentReviewId"])
        )
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_predeploy(bundle, rebound)

        wrong_id = copy.deepcopy(bundle)
        wrong_id["gates"][0]["content_id"] = digest("wrong-legal-gate-id")
        wrong_id["content_id"] = evidence.compute_bundle_content_id(wrong_id)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_predeploy(wrong_id, manifests)

    def test_normalized_binding_breaks_cycle_and_render_tampering_fails(self) -> None:
        manifests = manifest_set()
        gate_ids = {gate: manifests[gate]["content_id"] for gate in evidence.GATES}
        self.assertEqual(
            evidence.compute_release_configuration_id(release_contract()),
            evidence.compute_release_configuration_id(release_contract(gate_ids)),
        )
        rendered = rendered_manifest(manifests)
        evidence.validate_rendered_deployment(rendered, binding(), gate_ids)
        tampered = rendered.replace(
            gate_ids["legalReviewId"].encode("ascii"),
            digest("wrong legal mirror").encode("ascii"),
            1,
        )
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_rendered_deployment(tampered, binding(), gate_ids)

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
                    candidate, binding(), gate_ids
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

        bundle_path = self.directory / "predeploy.json"
        built = subprocess.run(
            [
                sys.executable,
                str(script),
                "bundle",
                *assignments,
                "--rendered-manifest",
                str(rendered_path),
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
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("all five production approval gates", checked.stdout)


if __name__ == "__main__":
    unittest.main()
