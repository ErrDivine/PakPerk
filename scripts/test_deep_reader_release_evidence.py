#!/usr/bin/env python3
"""Regression tests for the fail-closed Deep Reader evidence contract."""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import deep_reader_release_evidence as evidence


def digest(label: str) -> str:
    return "sha256:" + hashlib.sha256(label.encode("ascii")).hexdigest()


def binding() -> dict[str, object]:
    return {
        "source_revision": hashlib.sha1(b"deep-reader-source").hexdigest(),
        "target_environment": "production",
        "release_configuration_sha256": digest("release-configuration"),
        "deployment_images_sha256": digest("deployment-images"),
        "parser_adapter": "grobid",
        "parser_version": "0.9.0-crf",
        "document_schema_version": 1,
        "model_configuration_sha256": digest("model-configuration"),
        "prompt_version": "assistant-v2.0.0",
        "corpus_manifest_sha256": digest("parser-corpus"),
        "mobile_candidate_id": digest("signed-mobile-candidate"),
    }


def gate_manifest(gate: str) -> dict[str, object]:
    value: dict[str, object] = {
        "schema_version": evidence.SCHEMA_VERSION,
        "content_id": "",
        "classification": evidence.CLASSIFICATION,
        "gate": gate,
        "binding": binding(),
        "run": {
            "outcome": "passed",
            "started_at": "2026-08-01T00:00:00Z",
            "completed_at": "2026-08-01T01:00:00Z",
        },
        "sources": [
            {
                "kind": kind,
                "producer": evidence.SOURCE_PRODUCERS[kind],
                "outcome": "passed",
                "content_id": digest(f"{gate}-{kind}"),
                "completed_at": "2026-08-01T00:30:00Z",
            }
            for kind in evidence.GATE_REQUIREMENTS[gate]
        ],
        "assertions": [
            {"id": assertion, "outcome": "passed"}
            for assertion in evidence.GATE_ASSERTIONS[gate]
        ],
        "sanitization": copy.deepcopy(evidence.SANITIZATION),
    }
    value["content_id"] = evidence.compute_gate_content_id(value)
    return value


def manifest_set() -> dict[str, dict[str, object]]:
    return {gate: gate_manifest(gate) for gate in evidence.GATES}


def bundle(manifests: dict[str, dict[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {
        "schema_version": evidence.SCHEMA_VERSION,
        "content_id": "",
        "classification": evidence.CLASSIFICATION,
        "binding": binding(),
        "gates": [
            {"gate": gate, "content_id": manifests[gate]["content_id"]}
            for gate in evidence.GATES
        ],
        "approval": {
            "role": "release_owner",
            "decision": "approved",
            "approved_at": "2026-08-02T00:00:00Z",
            "protected_audit_reference": "release-ledger-2026-08-02-01",
        },
        "sanitization": copy.deepcopy(evidence.SANITIZATION),
    }
    value["content_id"] = evidence.compute_bundle_content_id(value)
    return value


def reseal_gate(value: dict[str, object]) -> dict[str, object]:
    value["content_id"] = evidence.compute_gate_content_id(value)
    return value


def reseal_bundle(value: dict[str, object]) -> dict[str, object]:
    value["content_id"] = evidence.compute_bundle_content_id(value)
    return value


class DeepReaderReleaseEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name)

    def write(self, name: str, value: object) -> Path:
        path = self.directory / name
        path.write_bytes(evidence.encode_canonical_document(value))
        path.chmod(0o600)
        return path

    def test_all_plan_gates_and_required_source_classes_are_closed(self) -> None:
        self.assertEqual(len(evidence.GATES), 23)
        self.assertEqual(set(evidence.GATE_REQUIREMENTS), set(evidence.GATES))
        self.assertEqual(set(evidence.GATE_ASSERTIONS), set(evidence.GATES))
        inventory = evidence.gate_inventory()
        self.assertEqual(inventory["status"], "requirements_only_not_release_evidence")
        self.assertNotIn('"outcome"', json.dumps(inventory, sort_keys=True))

    def test_complete_bundle_validates_without_collapsing_external_sources(self) -> None:
        manifests = manifest_set()
        for gate in evidence.GATES:
            validated = evidence.validate_gate(manifests[gate], gate)
            self.assertEqual(validated["gate"], gate)
        validated_bundle = evidence.validate_bundle(bundle(manifests), manifests)
        self.assertEqual(len(validated_bundle["gates"]), 23)
        parser_sources = evidence.GATE_REQUIREMENTS["parser_benchmark_published"]
        self.assertEqual(
            parser_sources,
            ("repository", "human_domain", "legal_review"),
        )

    def test_missing_external_source_fails_even_when_repository_passes(self) -> None:
        value = gate_manifest("large_document_accessibility_performance")
        sources = value["sources"]
        assert isinstance(sources, list)
        sources.pop()
        reseal_gate(value)
        with self.assertRaisesRegex(evidence.EvidenceError, "source inventory"):
            evidence.validate_gate(value)

    def test_repository_evidence_cannot_substitute_for_live_model_evidence(self) -> None:
        value = gate_manifest("assistant_evidence_id_integrity")
        sources = value["sources"]
        assert isinstance(sources, list)
        sources[1]["kind"] = "repository"
        sources[1]["producer"] = evidence.SOURCE_PRODUCERS["repository"]
        reseal_gate(value)
        with self.assertRaisesRegex(evidence.EvidenceError, "source class"):
            evidence.validate_gate(value)

    def test_failed_or_missing_assertions_never_validate(self) -> None:
        failed_source = gate_manifest("private_content_exclusion")
        failed_source["sources"][1]["outcome"] = "failed"
        reseal_gate(failed_source)
        with self.assertRaisesRegex(evidence.EvidenceError, "source did not pass"):
            evidence.validate_gate(failed_source)

        missing_assertion = gate_manifest("checkpoint_library_isolation")
        missing_assertion["assertions"].pop()
        reseal_gate(missing_assertion)
        with self.assertRaisesRegex(evidence.EvidenceError, "assertion inventory"):
            evidence.validate_gate(missing_assertion)

    def test_bundle_requires_every_gate_and_matching_binding(self) -> None:
        manifests = manifest_set()
        missing = dict(manifests)
        missing.pop("rollout_rollback")
        with self.assertRaisesRegex(evidence.EvidenceError, "requires every gate"):
            evidence.validate_bundle(bundle(manifests), missing)

        mismatch = copy.deepcopy(manifests)
        mismatch["strict_content_policy"]["binding"]["prompt_version"] = (
            "assistant-v2.0.1"
        )
        reseal_gate(mismatch["strict_content_policy"])
        mismatched_bundle = bundle(mismatch)
        with self.assertRaisesRegex(evidence.EvidenceError, "binding does not match"):
            evidence.validate_bundle(mismatched_bundle, mismatch)

    def test_bundle_requires_release_owner_approval_after_all_runs(self) -> None:
        manifests = manifest_set()
        value = bundle(manifests)
        value["approval"]["decision"] = "pending"
        reseal_bundle(value)
        with self.assertRaisesRegex(evidence.EvidenceError, "lacks release-owner"):
            evidence.validate_bundle(value, manifests)

        stale = bundle(manifests)
        stale["approval"]["approved_at"] = "2026-09-01T00:00:00Z"
        reseal_bundle(stale)
        with self.assertRaisesRegex(evidence.EvidenceError, "bounded post-run"):
            evidence.validate_bundle(stale, manifests)

    def test_content_tampering_and_obvious_placeholders_fail(self) -> None:
        tampered = gate_manifest("rollout_rollback")
        tampered["run"]["completed_at"] = "2026-08-01T02:00:00Z"
        with self.assertRaisesRegex(evidence.EvidenceError, "content ID"):
            evidence.validate_gate(tampered)

        placeholder = gate_manifest("parser_benchmark_published")
        placeholder["sources"][0]["content_id"] = "sha256:" + "a" * 64
        reseal_gate(placeholder)
        with self.assertRaisesRegex(evidence.EvidenceError, "placeholder"):
            evidence.validate_gate(placeholder)

    def test_files_must_be_canonical_and_private(self) -> None:
        value = gate_manifest("checkpoint_library_isolation")
        path = self.write("gate.json", value)
        self.assertEqual(evidence.read_document(path), value)
        path.chmod(0o644)
        with self.assertRaisesRegex(evidence.EvidenceError, "group/other"):
            evidence.read_document(path)


if __name__ == "__main__":
    unittest.main()
