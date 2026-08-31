#!/usr/bin/env python3
"""Regression tests for the Plan 03 repository evaluation harness."""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from typing import Any

import deep_reader_evaluation as evaluation


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = PROJECT_ROOT / "evaluation" / "deep-reader-v1"
CORPUS_PATH = FIXTURE_ROOT / "corpus-manifest.json"
LABELS_PATH = FIXTURE_ROOT / "ground-truth-labels.json"
OBSERVATIONS_PATH = FIXTURE_ROOT / "synthetic-candidate-observations.json"


def digest(label: str) -> str:
    return "sha256:" + hashlib.sha256(label.encode("ascii")).hexdigest()


class DeepReaderEvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.corpus = evaluation.validate_corpus(
            evaluation.read_json(CORPUS_PATH), PROJECT_ROOT
        )
        self.labels = evaluation.validate_labels(
            evaluation.read_json(LABELS_PATH), self.corpus
        )
        self.observations = evaluation.validate_observations(
            evaluation.read_json(OBSERVATIONS_PATH), self.corpus, self.labels
        )

    def report(self, observations: dict[str, Any] | None = None) -> dict[str, Any]:
        return evaluation.evaluate(
            self.corpus,
            self.labels,
            observations or self.observations,
            input_hashes={
                "corpus": digest("corpus"),
                "labels": digest("labels"),
                "observations": digest("observations"),
            },
        )

    def actual_report(self) -> dict[str, Any]:
        return evaluation.evaluate(
            self.corpus,
            self.labels,
            self.observations,
            input_hashes={
                "corpus": evaluation._digest_file(CORPUS_PATH),
                "labels": evaluation._digest_file(LABELS_PATH),
                "observations": evaluation._digest_file(OBSERVATIONS_PATH),
            },
        )

    def test_checked_fixture_passes_repository_contract_but_not_release(self) -> None:
        report = evaluation.validate_report(self.report())
        self.assertEqual(report["repository_contract_status"], "passed")
        self.assertEqual(report["release_status"], "not_ready")
        self.assertEqual(report["protected_evidence"], evaluation.PROTECTED_NOT_READY)

        areas = report["areas"]
        self.assertEqual(areas["parser"]["representative_corpus_status"], "not_ready")
        self.assertEqual(
            areas["parser"]["adapter_comparisons"][0]["status"],
            "not_ready_optional_adapter",
        )
        self.assertEqual(areas["passport"]["metrics"]["field_count"], 10)
        self.assertEqual(areas["assistant"]["metrics"]["category_coverage_count"], 11)
        self.assertEqual(areas["visual"]["metrics"]["expected_object_count"], 3)

    def test_every_versioned_json_schema_is_strict_and_unique(self) -> None:
        schema_paths = sorted((FIXTURE_ROOT / "schemas").glob("*.schema.json"))
        self.assertEqual(len(schema_paths), 5)
        ids: set[str] = set()
        for path in schema_paths:
            value = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(
                value["$schema"], "https://json-schema.org/draft/2020-12/schema"
            )
            self.assertNotIn(value["$id"], ids)
            ids.add(value["$id"])
            if path.name != "common-v1.schema.json":
                self.assertIs(value["additionalProperties"], False)

    def test_corpus_digest_and_protected_status_fail_closed(self) -> None:
        wrong_digest = copy.deepcopy(self.corpus)
        wrong_digest["documents"][0]["source_sha256"] = digest("wrong-source")
        with self.assertRaisesRegex(evaluation.EvaluationError, "does not match"):
            evaluation.validate_corpus(wrong_digest, PROJECT_ROOT)

        fabricated_legal_review = copy.deepcopy(self.corpus)
        fabricated_legal_review["protected_evidence"]["legal_review"] = "passed"
        with self.assertRaisesRegex(evaluation.EvaluationError, "not_ready"):
            evaluation.validate_corpus(fabricated_legal_review, PROJECT_ROOT)

    def test_raw_content_and_duplicate_json_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            content_path = Path(temporary_directory) / "content.json"
            content_path.write_text('{"answer":"raw model output"}\n', encoding="utf-8")
            with self.assertRaisesRegex(evaluation.EvaluationError, "content-bearing"):
                evaluation.read_json(content_path)

            duplicate_path = Path(temporary_directory) / "duplicate.json"
            duplicate_path.write_text('{"scope":"a","scope":"b"}\n', encoding="utf-8")
            with self.assertRaisesRegex(
                evaluation.EvaluationError, "duplicate JSON key"
            ):
                evaluation.read_json(duplicate_path)

    def test_parser_order_and_source_regressions_fail_repository_threshold(
        self,
    ) -> None:
        reordered = copy.deepcopy(self.observations)
        blocks = reordered["parser_runs"][0]["blocks"]
        blocks[0], blocks[1] = blocks[1], blocks[0]
        evaluation.validate_observations(reordered, self.corpus, self.labels)
        self.assertEqual(
            self.report(reordered)["areas"]["parser"]["repository_status"], "failed"
        )

        missing_source = copy.deepcopy(self.observations)
        missing_source["parser_runs"][0]["blocks"][0]["source_locator_present"] = False
        evaluation.validate_observations(missing_source, self.corpus, self.labels)
        parser_area = self.report(missing_source)["areas"]["parser"]
        self.assertEqual(parser_area["repository_status"], "failed")
        self.assertLess(
            parser_area["runs"][0]["metrics"]["source_navigation_basis_points"],
            10_000,
        )

    def test_every_optional_adapter_has_explicit_run_or_disabled_record(self) -> None:
        missing_docling = copy.deepcopy(self.observations)
        missing_docling["parser_runs"].pop()
        with self.assertRaisesRegex(evaluation.EvaluationError, "explicit run"):
            evaluation.validate_observations(missing_docling, self.corpus, self.labels)

        unsafe_failure = copy.deepcopy(self.observations)
        unsafe_failure["parser_runs"][1]["fallback_action"] = "none"
        with self.assertRaisesRegex(evaluation.EvaluationError, "fallback"):
            evaluation.validate_observations(unsafe_failure, self.corpus, self.labels)

    def test_optional_parser_resource_and_quality_comparison_is_deterministic(
        self,
    ) -> None:
        compared = copy.deepcopy(self.observations)
        grobid = compared["parser_runs"][0]
        docling = copy.deepcopy(grobid)
        docling["adapter_id"] = "docling-experimental"
        docling["adapter_version"] = "2.0.0-contract"
        docling["resource"] = {
            "wall_time_ms": 125,
            "peak_rss_bytes": 83_886_080,
        }
        compared["parser_runs"][1] = docling
        evaluation.validate_observations(compared, self.corpus, self.labels)
        comparison = self.report(compared)["areas"]["parser"]["adapter_comparisons"][0]
        self.assertEqual(comparison["status"], "compared_within_resource_budget")
        self.assertEqual(comparison["optional_latency_ratio_basis_points"], 12_500)
        self.assertEqual(comparison["optional_memory_ratio_basis_points"], 12_500)
        self.assertEqual(comparison["resource_budget_status"], "passed")
        self.assertEqual(set(comparison["quality_delta_basis_points"].values()), {0})
        self.assertEqual(comparison["default_adapter_decision"], "retain_grobid")

    def test_passport_wrong_evidence_and_missing_field_synthesis_fail(self) -> None:
        wrong_evidence = copy.deepcopy(self.observations)
        wrong_evidence["passport_predictions"][0]["evidence_block_ids"] = [
            "block-table-caption"
        ]
        evaluation.validate_observations(wrong_evidence, self.corpus, self.labels)
        passport = self.report(wrong_evidence)["areas"]["passport"]
        self.assertEqual(passport["repository_status"], "failed")
        self.assertLess(passport["metrics"]["evidence_precision_basis_points"], 10_000)

        synthesized_missing = copy.deepcopy(self.observations)
        limitation = next(
            item
            for item in synthesized_missing["passport_predictions"]
            if item["field_key"] == "limitations"
        )
        limitation["predicted_status"] = "supported"
        limitation["evidence_block_ids"] = ["block-methods-paragraph"]
        evaluation.validate_observations(synthesized_missing, self.corpus, self.labels)
        passport = self.report(synthesized_missing)["areas"]["passport"]
        self.assertEqual(passport["repository_status"], "failed")
        self.assertLess(
            passport["metrics"]["missing_field_abstention_basis_points"], 10_000
        )

    def test_assistant_invented_and_unsupported_ids_are_counted(self) -> None:
        invented = copy.deepcopy(self.observations)
        invented["assistant_predictions"][0]["claims"][0]["evidence_block_ids"] = [
            "invented-block-id"
        ]
        evaluation.validate_observations(invented, self.corpus, self.labels)
        assistant = self.report(invented)["areas"]["assistant"]
        self.assertEqual(assistant["metrics"]["invented_evidence_id_count"], 1)
        self.assertEqual(assistant["repository_status"], "failed")

        unsupported = copy.deepcopy(self.observations)
        method = next(
            item
            for item in unsupported["assistant_predictions"]
            if item["case_id"] == "assistant-method-detail"
        )
        method["claims"][0]["evidence_block_ids"] = ["block-methods-heading"]
        evaluation.validate_observations(unsupported, self.corpus, self.labels)
        assistant = self.report(unsupported)["areas"]["assistant"]
        self.assertGreater(assistant["metrics"]["unsupported_citation_basis_points"], 0)
        self.assertEqual(assistant["repository_status"], "failed")

    def test_method_detail_baseline_regression_fails(self) -> None:
        regression = copy.deepcopy(self.observations)
        method = next(
            item
            for item in regression["assistant_predictions"]
            if item["case_id"] == "assistant-method-detail"
        )
        method["claims"] = []
        evaluation.validate_observations(regression, self.corpus, self.labels)
        assistant = self.report(regression)["areas"]["assistant"]
        self.assertEqual(assistant["metrics"]["method_detail_baseline_basis_points"], 0)
        self.assertEqual(assistant["repository_status"], "failed")

        no_citations = copy.deepcopy(self.observations)
        for prediction in no_citations["assistant_predictions"]:
            prediction["claims"] = []
            if prediction["status"] != "rejected_stale_generation":
                prediction["status"] = "not_found"
        evaluation.validate_observations(no_citations, self.corpus, self.labels)
        assistant = self.report(no_citations)["areas"]["assistant"]
        self.assertEqual(assistant["metrics"]["unsupported_citation_basis_points"], 0)

    def test_visual_precision_and_source_navigation_regressions_fail(self) -> None:
        wrong_caption = copy.deepcopy(self.observations)
        wrong_caption["visual_predictions"][0]["caption_id"] = "caption-wrong"
        evaluation.validate_observations(wrong_caption, self.corpus, self.labels)
        visual = self.report(wrong_caption)["areas"]["visual"]
        self.assertEqual(visual["repository_status"], "failed")
        self.assertLess(visual["metrics"]["object_precision_basis_points"], 10_000)

        broken_navigation = copy.deepcopy(self.observations)
        broken_navigation["visual_predictions"][0]["source_navigation"][
            "original_locator_present"
        ] = False
        evaluation.validate_observations(broken_navigation, self.corpus, self.labels)
        visual = self.report(broken_navigation)["areas"]["visual"]
        self.assertEqual(visual["repository_status"], "failed")
        self.assertLess(visual["metrics"]["source_navigation_basis_points"], 10_000)

        wrong_table_structure = copy.deepcopy(self.observations)
        table = next(
            item
            for item in wrong_table_structure["visual_predictions"]
            if item["kind"] == "table"
        )
        table["structure_sha256"] = digest("wrong-table-structure")
        evaluation.validate_observations(
            wrong_table_structure, self.corpus, self.labels
        )
        visual = self.report(wrong_table_structure)["areas"]["visual"]
        self.assertEqual(visual["repository_status"], "failed")
        self.assertEqual(visual["metrics"]["table_structure_basis_points"], 0)

    def test_repository_report_cannot_fabricate_release_or_external_readiness(
        self,
    ) -> None:
        release_ready = self.report()
        release_ready["release_status"] = "ready"
        with self.assertRaisesRegex(evaluation.EvaluationError, "never mark"):
            evaluation.validate_report(release_ready)

        external_pass = self.report()
        external_pass["protected_evidence"]["live_model"] = "passed"
        with self.assertRaisesRegex(evaluation.EvaluationError, "not_ready"):
            evaluation.validate_report(external_pass)

    def test_report_encoding_is_canonical_and_hash_bound(self) -> None:
        report = self.report()
        encoded = evaluation.encode_canonical(report)
        self.assertEqual(encoded, evaluation.encode_canonical(report))
        self.assertTrue(encoded.endswith(b"\n"))
        self.assertNotIn(b"raw_model_io", encoded)
        self.assertEqual(evaluation.validate_report(json.loads(encoded)), report)

        actual = self.actual_report()
        evaluation.validate_report_against_inputs(
            actual,
            self.corpus,
            self.labels,
            self.observations,
            input_hashes={
                "corpus": evaluation._digest_file(CORPUS_PATH),
                "labels": evaluation._digest_file(LABELS_PATH),
                "observations": evaluation._digest_file(OBSERVATIONS_PATH),
            },
        )
        tampered = copy.deepcopy(actual)
        tampered["areas"]["assistant"]["metrics"]["invented_evidence_id_count"] = 0 + 1
        with self.assertRaisesRegex(evaluation.EvaluationError, "bound inputs"):
            evaluation.validate_report_against_inputs(
                tampered,
                self.corpus,
                self.labels,
                self.observations,
                input_hashes={
                    "corpus": evaluation._digest_file(CORPUS_PATH),
                    "labels": evaluation._digest_file(LABELS_PATH),
                    "observations": evaluation._digest_file(OBSERVATIONS_PATH),
                },
            )


if __name__ == "__main__":
    unittest.main()
