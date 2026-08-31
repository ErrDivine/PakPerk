#!/usr/bin/env python3
"""Evaluate bounded, content-free Plan 03 repository fixtures.

This harness computes deterministic structural metrics for parser, Passport,
assistant, and visual-object contracts.  It deliberately cannot produce
human, legal, live-model, or signed-device release evidence.  Those protected
sources stay ``not_ready`` in every report emitted by this program and are
validated separately by ``deep_reader_release_evidence.py``.

The input format carries opaque IDs, source locators, statuses, and bounded
counters.  Paper text, private content, questions, answers, and raw model I/O
are outside this repository-fixture contract.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = "deep-reader-evaluation-v1"
REPORT_SCHEMA_VERSION = "deep-reader-evaluation-report-v1"
MAX_DOCUMENT_BYTES = 1024 * 1024
MAX_NESTING = 20
MAX_COLLECTION_ITEMS = 2048
MAX_STRING_LENGTH = 4096
MAX_BLOCKS_PER_FIXTURE = 1024
MAX_CASES_PER_FIXTURE = 128

CLASSIFICATION = "repository_synthetic_contract_fixture"
REPORT_CLASSIFICATION = "repository_evaluation_not_release_evidence"
REPOSITORY_SCOPE = "synthetic_repository_fixture"

PROTECTED_EVIDENCE_KINDS = (
    "human_domain",
    "legal_review",
    "live_model",
    "signed_device",
)
PROTECTED_NOT_READY = {kind: "not_ready" for kind in PROTECTED_EVIDENCE_KINDS}

REQUIRED_DOCUMENT_CLASSES = (
    "two_column",
    "nested_sections",
    "equation_heavy",
    "dense_tables",
    "multi_panel_figures",
    "malformed_references",
    "scanned_or_image_heavy",
    "long_appendix",
    "unusual_headings",
    "older_arxiv",
)

PASSPORT_FIELDS = (
    "research_question",
    "contribution",
    "method",
    "data_or_sample",
    "evaluation",
    "main_result",
    "limitations",
    "assumptions_scope",
    "code_resources",
    "publication_status",
)
PASSPORT_STATUSES = {
    "supported",
    "inferred",
    "conflicting",
    "not_found",
    "not_applicable",
}
MISSING_PASSPORT_STATUSES = {"not_found", "not_applicable"}

ASSISTANT_CATEGORIES = (
    "direct_fact",
    "method_detail",
    "result_comparison",
    "limitation",
    "unsupported_question",
    "ambiguous_question",
    "figure_or_table",
    "equation_or_symbol",
    "adversarial_prompt",
    "stale_generation",
    "conflicting_evidence",
)
ASSISTANT_STATUSES = {
    "supported",
    "partial",
    "not_found",
    "rejected_stale_generation",
}

VISUAL_KINDS = {"figure", "table", "equation"}
BLOCK_KINDS = {
    "heading",
    "paragraph",
    "list_item",
    "quote",
    "theorem_definition",
    "caption",
    "equation_context",
    "table_context",
    "figure_context",
    "footnote",
    "other",
}
PARSER_STATUSES = {"succeeded", "failed", "adapter_disabled"}
FALLBACK_ACTIONS = {"none", "use_grobid", "metadata_only"}

FORBIDDEN_CONTENT_KEYS = {
    "answer",
    "body",
    "note",
    "paper_text",
    "prompt",
    "question",
    "quote",
    "raw_model_io",
    "text",
}

SAFE_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+-]{0,127}\Z")
SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")


class EvaluationError(ValueError):
    """Raised when an evaluation fixture violates the closed contract."""


def _duplicate_rejecting_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvaluationError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise EvaluationError(f"non-finite JSON constant {value!r} is forbidden")


def _validate_shape(value: Any, depth: int = 0) -> None:
    if depth > MAX_NESTING:
        raise EvaluationError("evaluation document exceeds the nesting boundary")
    if isinstance(value, str):
        if len(value) > MAX_STRING_LENGTH or "\0" in value:
            raise EvaluationError("evaluation string is invalid or unbounded")
        return
    if isinstance(value, dict):
        if len(value) > MAX_COLLECTION_ITEMS:
            raise EvaluationError("evaluation object is unbounded")
        for key, item in value.items():
            if key in FORBIDDEN_CONTENT_KEYS:
                raise EvaluationError(
                    f"content-bearing key {key!r} is forbidden in repository fixtures"
                )
            _validate_shape(item, depth + 1)
        return
    if isinstance(value, list):
        if len(value) > MAX_COLLECTION_ITEMS:
            raise EvaluationError("evaluation list is unbounded")
        for item in value:
            _validate_shape(item, depth + 1)


def read_json(path: Path) -> Any:
    data = path.read_bytes()
    if not data or len(data) > MAX_DOCUMENT_BYTES:
        raise EvaluationError(f"{path} has an invalid document size")
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_constant,
        )
    except EvaluationError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise EvaluationError(f"{path} is not strict UTF-8 JSON") from error
    _validate_shape(value)
    return value


def encode_canonical(value: Any) -> bytes:
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
        raise EvaluationError("report is not canonical JSON data") from error


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise EvaluationError(f"{label} must contain the exact required keys")
    return dict(value)


def _list(value: Any, label: str, *, maximum: int = MAX_COLLECTION_ITEMS) -> list[Any]:
    if not isinstance(value, list) or len(value) > maximum:
        raise EvaluationError(f"{label} must be a bounded list")
    return list(value)


def _safe_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or SAFE_ID_RE.fullmatch(value) is None:
        raise EvaluationError(f"{label} is not a bounded safe identifier")
    lowered = value.lower()
    if any(marker in lowered for marker in ("placeholder", "changeme", "todo")):
        raise EvaluationError(f"{label} is an obvious placeholder")
    return value


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise EvaluationError(f"{label} is not a SHA-256 content identifier")
    if len(set(value.removeprefix("sha256:"))) == 1:
        raise EvaluationError(f"{label} is an obvious placeholder digest")
    return value


def _optional_sha256(value: Any, label: str) -> str | None:
    if value is None:
        return None
    return _sha256(value, label)


def _bool(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise EvaluationError(f"{label} must be a Boolean")
    return value


def _integer(
    value: Any,
    label: str,
    *,
    minimum: int = 0,
    maximum: int = 2**31 - 1,
) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise EvaluationError(f"{label} is outside its integer boundary")
    return value


def _optional_integer(
    value: Any,
    label: str,
    *,
    minimum: int = 0,
    maximum: int = 2**31 - 1,
) -> int | None:
    if value is None:
        return None
    return _integer(value, label, minimum=minimum, maximum=maximum)


def _unique_ids(
    values: Any, label: str, *, maximum: int = MAX_COLLECTION_ITEMS
) -> list[str]:
    result = [_safe_id(value, label) for value in _list(values, label, maximum=maximum)]
    if len(set(result)) != len(result):
        raise EvaluationError(f"{label} contains duplicate identifiers")
    return result


def _enum(value: Any, allowed: set[str], label: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise EvaluationError(f"{label} is outside the closed vocabulary")
    return value


def _protected_not_ready(value: Any, label: str) -> dict[str, str]:
    result = _exact(value, set(PROTECTED_EVIDENCE_KINDS), label)
    if result != PROTECTED_NOT_READY:
        raise EvaluationError(f"{label} must keep every protected source not_ready")
    return result


def _relative_source_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 512:
        raise EvaluationError(f"{label} is invalid")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or value != path.as_posix():
        raise EvaluationError(f"{label} must be a normalized repository-relative path")
    return value


def _digest_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _digest_file(path: Path) -> str:
    return _digest_bytes(path.read_bytes())


def _basis_points(numerator: int, denominator: int) -> int:
    if denominator == 0:
        return 10_000 if numerator == 0 else 0
    return min(10_000, numerator * 10_000 // denominator)


def _rate_basis_points(numerator: int, denominator: int) -> int:
    """Return an error/event rate; an empty population has a zero rate."""

    if denominator == 0:
        return 0
    return min(10_000, numerator * 10_000 // denominator)


def _ratio_basis_points(numerator: int, denominator: int) -> int:
    """Return a bounded ratio where 10_000 means parity, not a percentage."""

    if denominator <= 0:
        raise EvaluationError("resource comparison denominator must be positive")
    return min(100_000, numerator * 10_000 // denominator)


def _lcs_length(left: Sequence[str], right: Sequence[str]) -> int:
    if len(left) > MAX_BLOCKS_PER_FIXTURE or len(right) > MAX_BLOCKS_PER_FIXTURE:
        raise EvaluationError("block-order comparison exceeds its boundary")
    row = [0] * (len(right) + 1)
    for left_item in left:
        previous_diagonal = 0
        for index, right_item in enumerate(right, start=1):
            previous = row[index]
            if left_item == right_item:
                row[index] = previous_diagonal + 1
            else:
                row[index] = max(row[index], row[index - 1])
            previous_diagonal = previous
    return row[-1]


def _groups(value: Any, label: str, block_ids: set[str]) -> list[list[str]]:
    groups = _list(value, label, maximum=32)
    parsed: list[list[str]] = []
    for group_index, group in enumerate(groups):
        ids = _unique_ids(group, f"{label}[{group_index}]", maximum=32)
        if not ids or not set(ids) <= block_ids:
            raise EvaluationError(f"{label} references unknown or empty evidence")
        parsed.append(ids)
    return parsed


def _thresholds(value: Any) -> dict[str, dict[str, int]]:
    root = _exact(value, {"parser", "passport", "assistant", "visual"}, "thresholds")
    shapes = {
        "parser": {
            "min_block_precision_basis_points",
            "min_block_recall_basis_points",
            "min_block_order_basis_points",
            "min_paragraph_boundary_precision_basis_points",
            "min_paragraph_boundary_recall_basis_points",
            "min_section_path_basis_points",
            "min_introduction_precision_basis_points",
            "min_introduction_recall_basis_points",
            "min_citation_precision_basis_points",
            "min_citation_recall_basis_points",
            "min_visual_precision_basis_points",
            "min_visual_recall_basis_points",
            "min_page_mapping_basis_points",
            "min_source_navigation_basis_points",
            "max_replacement_characters_per_million",
            "max_duplicate_content_hash_count",
            "max_missing_labeled_block_count",
            "max_optional_latency_ratio_basis_points",
            "max_optional_memory_ratio_basis_points",
        },
        "passport": {
            "min_evidence_precision_basis_points",
            "min_missing_field_abstention_basis_points",
            "min_status_accuracy_basis_points",
        },
        "assistant": {
            "max_invented_evidence_ids",
            "max_unsupported_citation_basis_points",
            "min_method_detail_baseline_basis_points",
        },
        "visual": {
            "min_object_precision_basis_points",
            "min_object_recall_basis_points",
            "min_table_structure_basis_points",
            "min_source_navigation_basis_points",
        },
    }
    parsed: dict[str, dict[str, int]] = {}
    for area, keys in shapes.items():
        raw = _exact(root[area], keys, f"{area} thresholds")
        parsed[area] = {}
        for key, item in raw.items():
            maximum = (
                1_000_000
                if key == "max_replacement_characters_per_million"
                else 100_000
            )
            parsed[area][key] = _integer(item, f"{area}.{key}", maximum=maximum)
    return parsed


def validate_corpus(value: Any, repository_root: Path | None = None) -> dict[str, Any]:
    root = _exact(
        value,
        {
            "schema_version",
            "corpus_id",
            "purpose",
            "classification",
            "rights_review_status",
            "human_ground_truth_status",
            "required_document_classes",
            "documents",
            "thresholds",
            "protected_evidence",
        },
        "corpus manifest",
    )
    if root["schema_version"] != SCHEMA_VERSION:
        raise EvaluationError("corpus schema version is unsupported")
    _safe_id(root["corpus_id"], "corpus ID")
    if root["purpose"] != "contract_validation_only_not_representative_benchmark":
        raise EvaluationError("corpus purpose must not claim representative evidence")
    if root["classification"] != CLASSIFICATION:
        raise EvaluationError("corpus classification is invalid")
    if root["rights_review_status"] != "not_ready":
        raise EvaluationError(
            "checked repository corpus rights review must remain not_ready"
        )
    if root["human_ground_truth_status"] != "not_ready":
        raise EvaluationError("checked repository ground truth must remain not_ready")
    required_classes = _unique_ids(
        root["required_document_classes"], "required document class", maximum=64
    )
    if tuple(required_classes) != REQUIRED_DOCUMENT_CLASSES:
        raise EvaluationError(
            "required document-class inventory is incomplete or reordered"
        )
    _thresholds(root["thresholds"])
    _protected_not_ready(root["protected_evidence"], "corpus protected evidence")

    documents = _list(root["documents"], "corpus documents", maximum=128)
    if not documents:
        raise EvaluationError("corpus manifest contains no repository fixtures")
    seen_fixtures: set[str] = set()
    seen_labels: set[str] = set()
    for index, raw in enumerate(documents):
        document = _exact(
            raw,
            {
                "fixture_id",
                "source_kind",
                "source_path",
                "source_sha256",
                "document_classes",
                "label_set_id",
                "allowed_adapters",
            },
            f"corpus document {index}",
        )
        fixture_id = _safe_id(document["fixture_id"], "fixture ID")
        label_set_id = _safe_id(document["label_set_id"], "label-set ID")
        if fixture_id in seen_fixtures or label_set_id in seen_labels:
            raise EvaluationError("fixture and label-set IDs must be unique")
        seen_fixtures.add(fixture_id)
        seen_labels.add(label_set_id)
        if document["source_kind"] != "synthetic":
            raise EvaluationError("unchecked repository fixtures must be synthetic")
        source_path = _relative_source_path(document["source_path"], "source path")
        source_digest = _sha256(document["source_sha256"], "source digest")
        classes = _unique_ids(
            document["document_classes"], "document class", maximum=32
        )
        if not classes or not set(classes) <= set(REQUIRED_DOCUMENT_CLASSES):
            raise EvaluationError("fixture document class is unknown or empty")
        adapters = _unique_ids(document["allowed_adapters"], "adapter ID", maximum=8)
        if (
            not adapters
            or adapters[0] != "grobid"
            or not set(adapters)
            <= {
                "grobid",
                "docling-experimental",
            }
        ):
            raise EvaluationError("GROBID must remain the first allowed adapter")
        if repository_root is not None:
            resolved = (repository_root / source_path).resolve()
            try:
                resolved.relative_to(repository_root.resolve())
            except ValueError as error:
                raise EvaluationError("source path escapes the repository") from error
            if not resolved.is_file() or _digest_file(resolved) != source_digest:
                raise EvaluationError(
                    "fixture source is missing or does not match its digest"
                )
    return root


def validate_labels(value: Any, corpus: Mapping[str, Any]) -> dict[str, Any]:
    root = _exact(
        value,
        {
            "schema_version",
            "corpus_id",
            "label_source",
            "label_sets",
            "protected_evidence",
        },
        "ground-truth labels",
    )
    if (
        root["schema_version"] != SCHEMA_VERSION
        or root["corpus_id"] != corpus["corpus_id"]
    ):
        raise EvaluationError("label schema or corpus binding is invalid")
    if root["label_source"] != "repository_synthetic_assertions_not_human_ground_truth":
        raise EvaluationError("label source must not claim human ground truth")
    _protected_not_ready(root["protected_evidence"], "label protected evidence")
    corpus_documents = {item["fixture_id"]: item for item in corpus["documents"]}
    label_sets = _list(root["label_sets"], "label sets", maximum=128)
    if len(label_sets) != len(corpus_documents):
        raise EvaluationError("every corpus fixture requires exactly one label set")
    seen: set[str] = set()
    for raw in label_sets:
        labels = _exact(
            raw,
            {
                "label_set_id",
                "fixture_id",
                "blocks",
                "citations",
                "passport_fields",
                "assistant_cases",
                "visual_objects",
            },
            "label set",
        )
        fixture_id = _safe_id(labels["fixture_id"], "label fixture ID")
        if fixture_id not in corpus_documents or fixture_id in seen:
            raise EvaluationError("labels name an unknown or duplicate fixture")
        seen.add(fixture_id)
        if labels["label_set_id"] != corpus_documents[fixture_id]["label_set_id"]:
            raise EvaluationError("label-set ID does not match the corpus manifest")

        blocks = _list(
            labels["blocks"], "labeled blocks", maximum=MAX_BLOCKS_PER_FIXTURE
        )
        if not blocks:
            raise EvaluationError("label set requires at least one block")
        block_ids: set[str] = set()
        for ordinal, raw_block in enumerate(blocks):
            block = _exact(
                raw_block,
                {
                    "block_id",
                    "kind",
                    "section_path",
                    "is_introduction",
                    "page",
                    "source_locator_required",
                },
                "labeled block",
            )
            block_id = _safe_id(block["block_id"], "block ID")
            if block_id in block_ids:
                raise EvaluationError("labeled block IDs must be unique")
            block_ids.add(block_id)
            _enum(block["kind"], BLOCK_KINDS, "block kind")
            _unique_ids(block["section_path"], "section path", maximum=32)
            _bool(block["is_introduction"], "introduction label")
            _optional_integer(block["page"], "source page", minimum=1, maximum=100_000)
            _bool(block["source_locator_required"], "source-locator requirement")
            if ordinal == 0 and block["kind"] != "heading":
                raise EvaluationError(
                    "first synthetic benchmark block must be a heading"
                )

        citations = _list(
            labels["citations"], "citation labels", maximum=MAX_BLOCKS_PER_FIXTURE
        )
        citation_ids: set[str] = set()
        for raw_citation in citations:
            citation = _exact(
                raw_citation,
                {"mention_id", "source_block_id", "target_id"},
                "citation label",
            )
            mention_id = _safe_id(citation["mention_id"], "citation mention ID")
            if (
                mention_id in citation_ids
                or citation["source_block_id"] not in block_ids
            ):
                raise EvaluationError(
                    "citation labels are duplicate or source an unknown block"
                )
            citation_ids.add(mention_id)
            _safe_id(citation["target_id"], "citation target ID")

        fields = _list(labels["passport_fields"], "Passport field labels", maximum=32)
        if [
            field.get("field_key") for field in fields if isinstance(field, dict)
        ] != list(PASSPORT_FIELDS):
            raise EvaluationError("Passport field labels are incomplete or reordered")
        for raw_field in fields:
            field = _exact(
                raw_field,
                {"field_key", "expected_status", "accepted_evidence_groups"},
                "Passport field label",
            )
            status = _enum(
                field["expected_status"], PASSPORT_STATUSES, "Passport status"
            )
            groups = _groups(
                field["accepted_evidence_groups"], "Passport evidence", block_ids
            )
            if (status in MISSING_PASSPORT_STATUSES) != (not groups):
                raise EvaluationError(
                    "Passport evidence groups contradict missing-field status"
                )

        cases = _list(
            labels["assistant_cases"], "assistant cases", maximum=MAX_CASES_PER_FIXTURE
        )
        if [case.get("category") for case in cases if isinstance(case, dict)] != list(
            ASSISTANT_CATEGORIES
        ):
            raise EvaluationError(
                "assistant category inventory is incomplete or reordered"
            )
        case_ids: set[str] = set()
        for raw_case in cases:
            case = _exact(
                raw_case,
                {
                    "case_id",
                    "category",
                    "retrieved_block_ids",
                    "expected_status",
                    "required_claims",
                    "baseline_supported_claim_count",
                },
                "assistant case",
            )
            case_id = _safe_id(case["case_id"], "assistant case ID")
            if case_id in case_ids:
                raise EvaluationError("assistant case IDs must be unique")
            case_ids.add(case_id)
            retrieved = set(
                _unique_ids(
                    case["retrieved_block_ids"], "retrieved block ID", maximum=128
                )
            )
            if not retrieved <= block_ids:
                raise EvaluationError(
                    "assistant retrieval labels reference unknown blocks"
                )
            status = _enum(
                case["expected_status"], ASSISTANT_STATUSES, "assistant status"
            )
            claims = _list(case["required_claims"], "required claims", maximum=32)
            claim_ids: set[str] = set()
            for raw_claim in claims:
                claim = _exact(
                    raw_claim,
                    {"claim_id", "accepted_evidence_groups"},
                    "assistant claim label",
                )
                claim_id = _safe_id(claim["claim_id"], "claim ID")
                if claim_id in claim_ids:
                    raise EvaluationError("required claim IDs must be unique per case")
                claim_ids.add(claim_id)
                groups = _groups(
                    claim["accepted_evidence_groups"], "claim evidence", block_ids
                )
                if not groups or any(not set(group) <= retrieved for group in groups):
                    raise EvaluationError(
                        "claim evidence must be inside retrieved context"
                    )
            baseline = _integer(
                case["baseline_supported_claim_count"],
                "baseline supported claim count",
                maximum=32,
            )
            if baseline > len(claims):
                raise EvaluationError("assistant baseline exceeds required claims")
            if status in {"not_found", "rejected_stale_generation"} and claims:
                raise EvaluationError("non-answer cases cannot require material claims")
            if case["category"] == "method_detail" and (baseline == 0 or not claims):
                raise EvaluationError(
                    "method-detail labels require a non-vacuous baseline"
                )

        objects = _list(labels["visual_objects"], "visual labels", maximum=256)
        object_ids: set[str] = set()
        for raw_object in objects:
            item = _exact(
                raw_object,
                {
                    "object_id",
                    "kind",
                    "caption_id",
                    "structure_sha256",
                    "page",
                    "source_block_ids",
                },
                "visual label",
            )
            object_id = _safe_id(item["object_id"], "visual object ID")
            if object_id in object_ids:
                raise EvaluationError("visual object IDs must be unique")
            object_ids.add(object_id)
            kind = _enum(item["kind"], VISUAL_KINDS, "visual kind")
            _safe_id(item["caption_id"], "caption association ID")
            structure_digest = _optional_sha256(
                item["structure_sha256"], "visual structure digest"
            )
            if (kind == "table") != (structure_digest is not None):
                raise EvaluationError(
                    "only table labels require a structure content identifier"
                )
            _integer(item["page"], "visual source page", minimum=1, maximum=100_000)
            source_ids = set(
                _unique_ids(
                    item["source_block_ids"], "visual source block ID", maximum=32
                )
            )
            if not source_ids or not source_ids <= block_ids:
                raise EvaluationError("visual labels require known source blocks")
    return root


def _validate_parser_run(
    raw: Any,
    fixture: Mapping[str, Any],
) -> dict[str, Any]:
    run = _exact(
        raw,
        {
            "fixture_id",
            "adapter_id",
            "adapter_version",
            "status",
            "blocks",
            "citations",
            "visual_objects",
            "resource",
            "failure_class",
            "fallback_action",
        },
        "parser observation",
    )
    if run["fixture_id"] != fixture["fixture_id"]:
        raise EvaluationError("parser observation fixture binding is invalid")
    adapter_id = _safe_id(run["adapter_id"], "parser adapter ID")
    if adapter_id not in fixture["allowed_adapters"]:
        raise EvaluationError("parser observation uses an unapproved adapter")
    _safe_id(run["adapter_version"], "parser adapter version")
    status = _enum(run["status"], PARSER_STATUSES, "parser status")
    fallback_action = _enum(run["fallback_action"], FALLBACK_ACTIONS, "fallback action")

    blocks = _list(run["blocks"], "observed blocks", maximum=MAX_BLOCKS_PER_FIXTURE)
    block_ids: set[str] = set()
    for raw_block in blocks:
        block = _exact(
            raw_block,
            {
                "block_id",
                "kind",
                "section_path",
                "is_introduction",
                "page",
                "source_locator_present",
                "content_sha256",
                "text_scalar_count",
                "replacement_character_count",
            },
            "observed block",
        )
        block_id = _safe_id(block["block_id"], "observed block ID")
        if block_id in block_ids:
            raise EvaluationError("observed block IDs must be unique")
        block_ids.add(block_id)
        _enum(block["kind"], BLOCK_KINDS, "observed block kind")
        _unique_ids(block["section_path"], "observed section path", maximum=32)
        _bool(block["is_introduction"], "observed introduction flag")
        _optional_integer(
            block["page"], "observed source page", minimum=1, maximum=100_000
        )
        _bool(block["source_locator_present"], "source-locator presence")
        _sha256(block["content_sha256"], "observed content digest")
        scalars = _integer(
            block["text_scalar_count"], "observed text scalar count", maximum=10_000_000
        )
        replacements = _integer(
            block["replacement_character_count"],
            "replacement character count",
            maximum=10_000_000,
        )
        if replacements > scalars:
            raise EvaluationError("replacement character count exceeds text length")

    citations = _list(
        run["citations"], "observed citations", maximum=MAX_BLOCKS_PER_FIXTURE
    )
    citation_ids: set[str] = set()
    for raw_citation in citations:
        citation = _exact(
            raw_citation,
            {"mention_id", "source_block_id", "target_id"},
            "observed citation",
        )
        mention_id = _safe_id(citation["mention_id"], "observed citation ID")
        if mention_id in citation_ids or citation["source_block_id"] not in block_ids:
            raise EvaluationError(
                "observed citation is duplicate or references an unknown block"
            )
        citation_ids.add(mention_id)
        _safe_id(citation["target_id"], "observed citation target")

    objects = _list(run["visual_objects"], "parser visual observations", maximum=256)
    object_ids: set[str] = set()
    for raw_object in objects:
        item = _exact(
            raw_object,
            {"object_id", "kind", "caption_id", "structure_sha256"},
            "parser visual observation",
        )
        object_id = _safe_id(item["object_id"], "parser visual object ID")
        if object_id in object_ids:
            raise EvaluationError("parser visual object IDs must be unique")
        object_ids.add(object_id)
        kind = _enum(item["kind"], VISUAL_KINDS, "parser visual kind")
        _safe_id(item["caption_id"], "parser caption association ID")
        structure_digest = _optional_sha256(
            item["structure_sha256"], "parser visual structure digest"
        )
        if (kind == "table") != (structure_digest is not None):
            raise EvaluationError(
                "only parser table observations require a structure digest"
            )

    if status == "succeeded":
        if not blocks or run["failure_class"] is not None or fallback_action != "none":
            raise EvaluationError(
                "successful parser observation has contradictory failure data"
            )
        resource = _exact(
            run["resource"], {"wall_time_ms", "peak_rss_bytes"}, "parser resource"
        )
        _integer(
            resource["wall_time_ms"], "parser wall time", minimum=1, maximum=86_400_000
        )
        _integer(
            resource["peak_rss_bytes"], "parser peak RSS", minimum=1, maximum=2**50
        )
    else:
        if blocks or citations or objects or run["resource"] is not None:
            raise EvaluationError(
                "non-success parser observation cannot contain derived output"
            )
        _safe_id(run["failure_class"], "parser failure class")
        if fallback_action == "none":
            raise EvaluationError("parser failures require an explicit fallback action")
        if adapter_id == "grobid" and status == "adapter_disabled":
            raise EvaluationError(
                "the production GROBID baseline cannot be adapter_disabled"
            )
    return run


def validate_observations(
    value: Any,
    corpus: Mapping[str, Any],
    labels: Mapping[str, Any],
) -> dict[str, Any]:
    root = _exact(
        value,
        {
            "schema_version",
            "candidate_id",
            "scope",
            "measurement_kind",
            "parser_runs",
            "passport_predictions",
            "assistant_predictions",
            "visual_predictions",
            "protected_evidence",
        },
        "candidate observations",
    )
    if root["schema_version"] != SCHEMA_VERSION:
        raise EvaluationError("observation schema version is unsupported")
    _safe_id(root["candidate_id"], "candidate ID")
    if root["scope"] != REPOSITORY_SCOPE or root["measurement_kind"] != "synthetic":
        raise EvaluationError("checked observations must remain explicitly synthetic")
    _protected_not_ready(root["protected_evidence"], "observation protected evidence")

    fixtures = {item["fixture_id"]: item for item in corpus["documents"]}
    label_sets = {item["fixture_id"]: item for item in labels["label_sets"]}
    runs = _list(root["parser_runs"], "parser runs", maximum=512)
    run_keys: set[tuple[str, str]] = set()
    for raw_run in runs:
        if not isinstance(raw_run, dict) or raw_run.get("fixture_id") not in fixtures:
            raise EvaluationError("parser observation names an unknown fixture")
        fixture = fixtures[raw_run["fixture_id"]]
        run = _validate_parser_run(raw_run, fixture)
        key = (run["fixture_id"], run["adapter_id"])
        if key in run_keys:
            raise EvaluationError(
                "parser observations contain a duplicate fixture/adapter run"
            )
        run_keys.add(key)
    expected_runs = {
        (fixture_id, adapter)
        for fixture_id, fixture in fixtures.items()
        for adapter in fixture["allowed_adapters"]
    }
    if run_keys != expected_runs:
        raise EvaluationError(
            "every allowed parser adapter requires an explicit run or disabled record"
        )

    passport_predictions = _list(
        root["passport_predictions"], "Passport predictions", maximum=4096
    )
    passport_keys: set[tuple[str, str]] = set()
    for raw in passport_predictions:
        item = _exact(
            raw,
            {"fixture_id", "field_key", "predicted_status", "evidence_block_ids"},
            "Passport prediction",
        )
        fixture_id = _safe_id(item["fixture_id"], "Passport fixture ID")
        if fixture_id not in fixtures or item["field_key"] not in PASSPORT_FIELDS:
            raise EvaluationError("Passport prediction scope is unknown")
        key = (fixture_id, item["field_key"])
        if key in passport_keys:
            raise EvaluationError("Passport prediction scope is duplicated")
        passport_keys.add(key)
        status = _enum(
            item["predicted_status"], PASSPORT_STATUSES, "predicted Passport status"
        )
        evidence = _unique_ids(
            item["evidence_block_ids"], "predicted Passport evidence", maximum=128
        )
        block_ids = {block["block_id"] for block in label_sets[fixture_id]["blocks"]}
        if not set(evidence) <= block_ids:
            raise EvaluationError("Passport prediction invented a source block ID")
        if (status in MISSING_PASSPORT_STATUSES) != (not evidence):
            raise EvaluationError(
                "Passport status and evidence presence are inconsistent"
            )
    expected_passport_keys = {
        (fixture_id, field) for fixture_id in fixtures for field in PASSPORT_FIELDS
    }
    if passport_keys != expected_passport_keys:
        raise EvaluationError("Passport predictions are incomplete")

    assistant_predictions = _list(
        root["assistant_predictions"], "assistant predictions", maximum=4096
    )
    assistant_keys: set[tuple[str, str]] = set()
    for raw in assistant_predictions:
        item = _exact(
            raw,
            {
                "fixture_id",
                "case_id",
                "status",
                "claims",
                "latency_ms",
                "cost_microusd",
            },
            "assistant prediction",
        )
        fixture_id = _safe_id(item["fixture_id"], "assistant fixture ID")
        if fixture_id not in fixtures:
            raise EvaluationError("assistant prediction names an unknown fixture")
        case_ids = {
            case["case_id"] for case in label_sets[fixture_id]["assistant_cases"]
        }
        case_id = _safe_id(item["case_id"], "assistant prediction case ID")
        key = (fixture_id, case_id)
        if case_id not in case_ids or key in assistant_keys:
            raise EvaluationError("assistant prediction case is unknown or duplicated")
        assistant_keys.add(key)
        status = _enum(
            item["status"], ASSISTANT_STATUSES, "assistant prediction status"
        )
        claims = _list(item["claims"], "assistant claims", maximum=32)
        claim_ids: set[str] = set()
        for raw_claim in claims:
            claim = _exact(
                raw_claim,
                {"claim_id", "support", "evidence_block_ids"},
                "assistant prediction claim",
            )
            claim_id = _safe_id(claim["claim_id"], "assistant prediction claim ID")
            if claim_id in claim_ids:
                raise EvaluationError(
                    "assistant claim IDs must be unique per prediction"
                )
            claim_ids.add(claim_id)
            _enum(claim["support"], {"direct", "inferred"}, "claim support")
            evidence = _unique_ids(
                claim["evidence_block_ids"], "assistant evidence ID", maximum=128
            )
            if not evidence:
                raise EvaluationError("material assistant claims require evidence")
        if status in {"not_found", "rejected_stale_generation"} and claims:
            raise EvaluationError(
                "non-answer assistant prediction cannot contain claims"
            )
        _integer(item["latency_ms"], "synthetic assistant latency", maximum=86_400_000)
        _integer(item["cost_microusd"], "synthetic assistant cost", maximum=10**12)
    expected_assistant_keys = {
        (fixture_id, case["case_id"])
        for fixture_id, label_set in label_sets.items()
        for case in label_set["assistant_cases"]
    }
    if assistant_keys != expected_assistant_keys:
        raise EvaluationError("assistant predictions are incomplete")

    visual_predictions = _list(
        root["visual_predictions"], "visual predictions", maximum=4096
    )
    visual_keys: set[tuple[str, str]] = set()
    for raw in visual_predictions:
        item = _exact(
            raw,
            {
                "fixture_id",
                "object_id",
                "kind",
                "caption_id",
                "structure_sha256",
                "source_navigation",
            },
            "visual prediction",
        )
        fixture_id = _safe_id(item["fixture_id"], "visual prediction fixture ID")
        if fixture_id not in fixtures:
            raise EvaluationError("visual prediction names an unknown fixture")
        object_id = _safe_id(item["object_id"], "visual prediction object ID")
        key = (fixture_id, object_id)
        if key in visual_keys:
            raise EvaluationError("visual prediction is duplicated")
        visual_keys.add(key)
        kind = _enum(item["kind"], VISUAL_KINDS, "visual prediction kind")
        _safe_id(item["caption_id"], "visual prediction caption ID")
        structure_digest = _optional_sha256(
            item["structure_sha256"], "visual prediction structure digest"
        )
        if (kind == "table") != (structure_digest is not None):
            raise EvaluationError(
                "only predicted tables require a structure content identifier"
            )
        navigation = _exact(
            item["source_navigation"],
            {"page", "source_block_ids", "original_locator_present"},
            "visual source navigation",
        )
        _optional_integer(
            navigation["page"], "visual navigation page", minimum=1, maximum=100_000
        )
        _unique_ids(
            navigation["source_block_ids"], "visual navigation block ID", maximum=32
        )
        _bool(navigation["original_locator_present"], "original locator presence")
    return root


def _precision_recall(expected: set[Any], actual: set[Any]) -> tuple[int, int, int]:
    true_positive = len(expected & actual)
    return (
        _basis_points(true_positive, len(actual)),
        _basis_points(true_positive, len(expected)),
        true_positive,
    )


def _evaluate_parser_run(
    run: Mapping[str, Any], labels: Mapping[str, Any]
) -> dict[str, Any]:
    if run["status"] != "succeeded":
        return {
            "adapter_id": run["adapter_id"],
            "adapter_version": run["adapter_version"],
            "status": run["status"],
            "failure_class": run["failure_class"],
            "fallback_action": run["fallback_action"],
            "metrics": None,
            "resource": None,
        }
    expected_blocks = [block["block_id"] for block in labels["blocks"]]
    actual_blocks = [block["block_id"] for block in run["blocks"]]
    block_precision, block_recall, _ = _precision_recall(
        set(expected_blocks), set(actual_blocks)
    )
    expected_paragraphs = {
        block["block_id"] for block in labels["blocks"] if block["kind"] == "paragraph"
    }
    actual_paragraphs = {
        block["block_id"] for block in run["blocks"] if block["kind"] == "paragraph"
    }
    paragraph_precision, paragraph_recall, _ = _precision_recall(
        expected_paragraphs, actual_paragraphs
    )
    order_denominator = max(len(expected_blocks), len(actual_blocks))
    order_accuracy = _basis_points(
        _lcs_length(expected_blocks, actual_blocks), order_denominator
    )

    expected_by_id = {block["block_id"]: block for block in labels["blocks"]}
    actual_by_id = {block["block_id"]: block for block in run["blocks"]}
    common_ids = set(expected_by_id) & set(actual_by_id)
    correct_paths = sum(
        expected_by_id[block_id]["section_path"]
        == actual_by_id[block_id]["section_path"]
        for block_id in common_ids
    )
    section_path_accuracy = _basis_points(correct_paths, len(expected_by_id))

    expected_intro = {
        block["block_id"] for block in labels["blocks"] if block["is_introduction"]
    }
    actual_intro = {
        block["block_id"] for block in run["blocks"] if block["is_introduction"]
    }
    intro_precision, intro_recall, _ = _precision_recall(expected_intro, actual_intro)

    expected_citations = {
        (item["mention_id"], item["source_block_id"], item["target_id"])
        for item in labels["citations"]
    }
    actual_citations = {
        (item["mention_id"], item["source_block_id"], item["target_id"])
        for item in run["citations"]
    }
    citation_precision, citation_recall, _ = _precision_recall(
        expected_citations, actual_citations
    )

    expected_visuals = {
        (
            item["object_id"],
            item["kind"],
            item["caption_id"],
            item["structure_sha256"],
        )
        for item in labels["visual_objects"]
    }
    actual_visuals = {
        (
            item["object_id"],
            item["kind"],
            item["caption_id"],
            item["structure_sha256"],
        )
        for item in run["visual_objects"]
    }
    visual_precision, visual_recall, _ = _precision_recall(
        expected_visuals, actual_visuals
    )

    expected_pages = {
        block["block_id"]: block["page"]
        for block in labels["blocks"]
        if block["page"] is not None
    }
    page_correct = sum(
        block_id in actual_by_id and actual_by_id[block_id]["page"] == page
        for block_id, page in expected_pages.items()
    )
    source_required = [
        block for block in labels["blocks"] if block["source_locator_required"]
    ]
    source_correct = sum(
        block["block_id"] in actual_by_id
        and actual_by_id[block["block_id"]]["source_locator_present"]
        for block in source_required
    )
    scalar_count = sum(block["text_scalar_count"] for block in run["blocks"])
    replacement_count = sum(
        block["replacement_character_count"] for block in run["blocks"]
    )
    replacement_per_million = (
        replacement_count * 1_000_000 // scalar_count if scalar_count else 0
    )
    content_hashes = [block["content_sha256"] for block in run["blocks"]]
    return {
        "adapter_id": run["adapter_id"],
        "adapter_version": run["adapter_version"],
        "status": run["status"],
        "failure_class": None,
        "fallback_action": "none",
        "metrics": {
            "block_precision_basis_points": block_precision,
            "block_recall_basis_points": block_recall,
            "block_order_basis_points": order_accuracy,
            "paragraph_boundary_precision_basis_points": paragraph_precision,
            "paragraph_boundary_recall_basis_points": paragraph_recall,
            "section_path_basis_points": section_path_accuracy,
            "introduction_precision_basis_points": intro_precision,
            "introduction_recall_basis_points": intro_recall,
            "citation_precision_basis_points": citation_precision,
            "citation_recall_basis_points": citation_recall,
            "visual_precision_basis_points": visual_precision,
            "visual_recall_basis_points": visual_recall,
            "page_mapping_basis_points": _basis_points(
                page_correct, len(expected_pages)
            ),
            "source_navigation_basis_points": _basis_points(
                source_correct, len(source_required)
            ),
            "replacement_characters_per_million": replacement_per_million,
            "duplicate_content_hash_count": len(content_hashes)
            - len(set(content_hashes)),
            "missing_labeled_block_count": len(
                set(expected_blocks) - set(actual_blocks)
            ),
        },
        "resource": dict(run["resource"]),
    }


def _evaluate_parser(
    corpus: Mapping[str, Any],
    labels: Mapping[str, Any],
    observations: Mapping[str, Any],
) -> dict[str, Any]:
    labels_by_fixture = {item["fixture_id"]: item for item in labels["label_sets"]}
    results = [
        {
            "fixture_id": run["fixture_id"],
            **_evaluate_parser_run(run, labels_by_fixture[run["fixture_id"]]),
        }
        for run in observations["parser_runs"]
    ]
    thresholds = corpus["thresholds"]["parser"]
    baseline_results = [
        result
        for result in results
        if result["adapter_id"] == "grobid" and result["status"] == "succeeded"
    ]
    baseline_passed = len(baseline_results) == len(corpus["documents"]) and all(
        result["metrics"]["block_precision_basis_points"]
        >= thresholds["min_block_precision_basis_points"]
        and result["metrics"]["block_recall_basis_points"]
        >= thresholds["min_block_recall_basis_points"]
        and result["metrics"]["block_order_basis_points"]
        >= thresholds["min_block_order_basis_points"]
        and result["metrics"]["paragraph_boundary_precision_basis_points"]
        >= thresholds["min_paragraph_boundary_precision_basis_points"]
        and result["metrics"]["paragraph_boundary_recall_basis_points"]
        >= thresholds["min_paragraph_boundary_recall_basis_points"]
        and result["metrics"]["section_path_basis_points"]
        >= thresholds["min_section_path_basis_points"]
        and result["metrics"]["introduction_precision_basis_points"]
        >= thresholds["min_introduction_precision_basis_points"]
        and result["metrics"]["introduction_recall_basis_points"]
        >= thresholds["min_introduction_recall_basis_points"]
        and result["metrics"]["citation_precision_basis_points"]
        >= thresholds["min_citation_precision_basis_points"]
        and result["metrics"]["citation_recall_basis_points"]
        >= thresholds["min_citation_recall_basis_points"]
        and result["metrics"]["visual_precision_basis_points"]
        >= thresholds["min_visual_precision_basis_points"]
        and result["metrics"]["visual_recall_basis_points"]
        >= thresholds["min_visual_recall_basis_points"]
        and result["metrics"]["page_mapping_basis_points"]
        >= thresholds["min_page_mapping_basis_points"]
        and result["metrics"]["source_navigation_basis_points"]
        >= thresholds["min_source_navigation_basis_points"]
        and result["metrics"]["replacement_characters_per_million"]
        <= thresholds["max_replacement_characters_per_million"]
        and result["metrics"]["duplicate_content_hash_count"]
        <= thresholds["max_duplicate_content_hash_count"]
        and result["metrics"]["missing_labeled_block_count"]
        <= thresholds["max_missing_labeled_block_count"]
        for result in baseline_results
    )

    comparisons: list[dict[str, Any]] = []
    for fixture in corpus["documents"]:
        fixture_results = {
            result["adapter_id"]: result
            for result in results
            if result["fixture_id"] == fixture["fixture_id"]
        }
        grobid = fixture_results["grobid"]
        optional = fixture_results.get("docling-experimental")
        comparison_status = "not_configured"
        latency_ratio = None
        memory_ratio = None
        quality_deltas = None
        resource_budget_status = "not_ready"
        if (
            optional is not None
            and optional["status"] == "succeeded"
            and grobid["status"] == "succeeded"
        ):
            latency_ratio = _ratio_basis_points(
                optional["resource"]["wall_time_ms"], grobid["resource"]["wall_time_ms"]
            )
            memory_ratio = _ratio_basis_points(
                optional["resource"]["peak_rss_bytes"],
                grobid["resource"]["peak_rss_bytes"],
            )
            within_budget = (
                latency_ratio <= thresholds["max_optional_latency_ratio_basis_points"]
                and memory_ratio <= thresholds["max_optional_memory_ratio_basis_points"]
            )
            comparison_status = (
                "compared_within_resource_budget"
                if within_budget
                else "compared_over_resource_budget"
            )
            resource_budget_status = "passed" if within_budget else "failed"
            quality_deltas = {
                metric: optional["metrics"][metric] - grobid["metrics"][metric]
                for metric in (
                    "block_order_basis_points",
                    "paragraph_boundary_precision_basis_points",
                    "paragraph_boundary_recall_basis_points",
                    "section_path_basis_points",
                    "introduction_precision_basis_points",
                    "introduction_recall_basis_points",
                    "citation_precision_basis_points",
                    "citation_recall_basis_points",
                    "visual_precision_basis_points",
                    "visual_recall_basis_points",
                    "source_navigation_basis_points",
                )
            }
        elif optional is not None:
            comparison_status = "not_ready_optional_adapter"
        comparisons.append(
            {
                "fixture_id": fixture["fixture_id"],
                "status": comparison_status,
                "optional_latency_ratio_basis_points": latency_ratio,
                "optional_memory_ratio_basis_points": memory_ratio,
                "resource_budget_status": resource_budget_status,
                "quality_delta_basis_points": quality_deltas,
                "default_adapter_decision": "retain_grobid",
            }
        )

    covered_classes = sorted(
        {
            document_class
            for document in corpus["documents"]
            for document_class in document["document_classes"]
        }
    )
    missing_classes = sorted(set(REQUIRED_DOCUMENT_CLASSES) - set(covered_classes))
    failures: dict[str, int] = {}
    for result in results:
        failure_class = result["failure_class"]
        if failure_class is not None:
            failures[failure_class] = failures.get(failure_class, 0) + 1
    return {
        "repository_status": "passed" if baseline_passed else "failed",
        "release_status": "not_ready",
        "representative_corpus_status": "not_ready",
        "covered_document_classes": covered_classes,
        "missing_document_classes": missing_classes,
        "runs": results,
        "adapter_comparisons": comparisons,
        "failure_distribution": [
            {"failure_class": key, "count": failures[key]} for key in sorted(failures)
        ],
    }


def _evaluate_passport(
    corpus: Mapping[str, Any],
    labels: Mapping[str, Any],
    observations: Mapping[str, Any],
) -> dict[str, Any]:
    label_map = {
        (label_set["fixture_id"], field["field_key"]): field
        for label_set in labels["label_sets"]
        for field in label_set["passport_fields"]
    }
    evidence_total = 0
    evidence_correct = 0
    status_correct = 0
    missing_total = 0
    missing_correct = 0
    inferred_or_conflicting_total = 0
    inferred_or_conflicting_correct = 0
    for prediction in observations["passport_predictions"]:
        expected = label_map[(prediction["fixture_id"], prediction["field_key"])]
        status_correct += prediction["predicted_status"] == expected["expected_status"]
        accepted = {
            block_id
            for group in expected["accepted_evidence_groups"]
            for block_id in group
        }
        evidence_total += len(prediction["evidence_block_ids"])
        evidence_correct += sum(
            block_id in accepted for block_id in prediction["evidence_block_ids"]
        )
        if expected["expected_status"] in MISSING_PASSPORT_STATUSES:
            missing_total += 1
            missing_correct += (
                prediction["predicted_status"] == expected["expected_status"]
                and not prediction["evidence_block_ids"]
            )
        if expected["expected_status"] in {"inferred", "conflicting"}:
            inferred_or_conflicting_total += 1
            inferred_or_conflicting_correct += (
                prediction["predicted_status"] == expected["expected_status"]
            )
    total_fields = len(label_map)
    metrics = {
        "field_count": total_fields,
        "status_accuracy_basis_points": _basis_points(status_correct, total_fields),
        "evidence_precision_basis_points": _basis_points(
            evidence_correct, evidence_total
        ),
        "missing_field_count": missing_total,
        "missing_field_abstention_basis_points": _basis_points(
            missing_correct, missing_total
        ),
        "inference_conflict_label_basis_points": _basis_points(
            inferred_or_conflicting_correct, inferred_or_conflicting_total
        ),
    }
    thresholds = corpus["thresholds"]["passport"]
    passed = (
        metrics["evidence_precision_basis_points"]
        >= thresholds["min_evidence_precision_basis_points"]
        and metrics["missing_field_abstention_basis_points"]
        >= thresholds["min_missing_field_abstention_basis_points"]
        and metrics["status_accuracy_basis_points"]
        >= thresholds["min_status_accuracy_basis_points"]
    )
    return {
        "repository_status": "passed" if passed else "failed",
        "release_status": "not_ready",
        "human_field_correctness_status": "not_ready",
        "metrics": metrics,
    }


def _claim_is_supported(claim: Mapping[str, Any], expected: Mapping[str, Any]) -> bool:
    evidence = set(claim["evidence_block_ids"])
    return any(set(group) <= evidence for group in expected["accepted_evidence_groups"])


def _evaluate_assistant(
    corpus: Mapping[str, Any],
    labels: Mapping[str, Any],
    observations: Mapping[str, Any],
) -> dict[str, Any]:
    case_map = {
        (label_set["fixture_id"], case["case_id"]): case
        for label_set in labels["label_sets"]
        for case in label_set["assistant_cases"]
    }
    invented_ids = 0
    cited_ids = 0
    unsupported_ids = 0
    required_claims = 0
    supported_required_claims = 0
    status_correct = 0
    method_baseline = 0
    method_supported = 0
    total_latency = 0
    total_cost = 0
    for prediction in observations["assistant_predictions"]:
        expected = case_map[(prediction["fixture_id"], prediction["case_id"])]
        status_correct += prediction["status"] == expected["expected_status"]
        retrieved = set(expected["retrieved_block_ids"])
        expected_claims = {
            claim["claim_id"]: claim for claim in expected["required_claims"]
        }
        supported_in_case = 0
        for claim in prediction["claims"]:
            evidence = claim["evidence_block_ids"]
            cited_ids += len(evidence)
            invented_ids += sum(block_id not in retrieved for block_id in evidence)
            expected_claim = expected_claims.get(claim["claim_id"])
            if expected_claim is None:
                unsupported_ids += len(evidence)
                continue
            accepted = {
                block_id
                for group in expected_claim["accepted_evidence_groups"]
                for block_id in group
            }
            unsupported_ids += sum(block_id not in accepted for block_id in evidence)
            if _claim_is_supported(claim, expected_claim):
                supported_in_case += 1
        required_claims += len(expected_claims)
        supported_required_claims += supported_in_case
        if expected["category"] == "method_detail":
            method_baseline += expected["baseline_supported_claim_count"]
            method_supported += supported_in_case
        total_latency += prediction["latency_ms"]
        total_cost += prediction["cost_microusd"]
    metrics = {
        "case_count": len(case_map),
        "category_coverage_count": len(
            {
                case["category"]
                for label_set in labels["label_sets"]
                for case in label_set["assistant_cases"]
            }
        ),
        "invented_evidence_id_count": invented_ids,
        "unsupported_citation_basis_points": _rate_basis_points(
            unsupported_ids, cited_ids
        ),
        "claim_support_recall_basis_points": _basis_points(
            supported_required_claims, required_claims
        ),
        "status_accuracy_basis_points": _basis_points(status_correct, len(case_map)),
        "method_detail_baseline_basis_points": _basis_points(
            method_supported, method_baseline
        ),
        "synthetic_latency_ms_total": total_latency,
        "synthetic_cost_microusd_total": total_cost,
    }
    thresholds = corpus["thresholds"]["assistant"]
    passed = (
        invented_ids <= thresholds["max_invented_evidence_ids"]
        and metrics["unsupported_citation_basis_points"]
        <= thresholds["max_unsupported_citation_basis_points"]
        and metrics["method_detail_baseline_basis_points"]
        >= thresholds["min_method_detail_baseline_basis_points"]
    )
    return {
        "repository_status": "passed" if passed else "failed",
        "release_status": "not_ready",
        "live_model_status": "not_ready",
        "human_method_detail_review_status": "not_ready",
        "metrics": metrics,
    }


def _evaluate_visuals(
    corpus: Mapping[str, Any],
    labels: Mapping[str, Any],
    observations: Mapping[str, Any],
) -> dict[str, Any]:
    expected = {
        (label_set["fixture_id"], item["object_id"]): item
        for label_set in labels["label_sets"]
        for item in label_set["visual_objects"]
    }
    predicted = {
        (item["fixture_id"], item["object_id"]): item
        for item in observations["visual_predictions"]
    }
    true_positive = 0
    navigable = 0
    table_structure_correct = 0
    for key, item in predicted.items():
        label = expected.get(key)
        if label is None:
            continue
        object_matches = (
            item["kind"] == label["kind"]
            and item["caption_id"] == label["caption_id"]
            and item["structure_sha256"] == label["structure_sha256"]
        )
        if object_matches:
            true_positive += 1
            if label["kind"] == "table":
                table_structure_correct += 1
        navigation = item["source_navigation"]
        if (
            object_matches
            and navigation["page"] == label["page"]
            and set(label["source_block_ids"]) <= set(navigation["source_block_ids"])
            and navigation["original_locator_present"]
        ):
            navigable += 1
    per_kind: dict[str, dict[str, int]] = {}
    for kind in sorted(VISUAL_KINDS):
        expected_kind = {key for key, item in expected.items() if item["kind"] == kind}
        predicted_kind = {
            key for key, item in predicted.items() if item["kind"] == kind
        }
        correct_kind = sum(
            key in expected
            and predicted[key]["caption_id"] == expected[key]["caption_id"]
            and predicted[key]["structure_sha256"] == expected[key]["structure_sha256"]
            for key in predicted_kind
        )
        per_kind[kind] = {
            "precision_basis_points": _basis_points(correct_kind, len(predicted_kind)),
            "recall_basis_points": _basis_points(correct_kind, len(expected_kind)),
        }
    table_count = sum(item["kind"] == "table" for item in expected.values())
    metrics = {
        "expected_object_count": len(expected),
        "predicted_object_count": len(predicted),
        "object_precision_basis_points": _basis_points(true_positive, len(predicted)),
        "object_recall_basis_points": _basis_points(true_positive, len(expected)),
        "table_structure_basis_points": _basis_points(
            table_structure_correct, table_count
        ),
        "source_navigation_basis_points": _basis_points(navigable, len(expected)),
        "figure_count": sum(item["kind"] == "figure" for item in expected.values()),
        "table_count": table_count,
        "equation_count": sum(item["kind"] == "equation" for item in expected.values()),
        "per_kind": per_kind,
    }
    thresholds = corpus["thresholds"]["visual"]
    passed = (
        metrics["object_precision_basis_points"]
        >= thresholds["min_object_precision_basis_points"]
        and metrics["object_recall_basis_points"]
        >= thresholds["min_object_recall_basis_points"]
        and metrics["table_structure_basis_points"]
        >= thresholds["min_table_structure_basis_points"]
        and metrics["source_navigation_basis_points"]
        >= thresholds["min_source_navigation_basis_points"]
    )
    return {
        "repository_status": "passed" if passed else "failed",
        "release_status": "not_ready",
        "human_precision_review_status": "not_ready",
        "signed_device_navigation_status": "not_ready",
        "metrics": metrics,
    }


def evaluate(
    corpus: Mapping[str, Any],
    labels: Mapping[str, Any],
    observations: Mapping[str, Any],
    *,
    input_hashes: Mapping[str, str],
) -> dict[str, Any]:
    parser = _evaluate_parser(corpus, labels, observations)
    passport = _evaluate_passport(corpus, labels, observations)
    assistant = _evaluate_assistant(corpus, labels, observations)
    visuals = _evaluate_visuals(corpus, labels, observations)
    repository_passed = all(
        area["repository_status"] == "passed"
        for area in (parser, passport, assistant, visuals)
    )
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "classification": REPORT_CLASSIFICATION,
        "corpus_id": corpus["corpus_id"],
        "candidate_id": observations["candidate_id"],
        "scope": REPOSITORY_SCOPE,
        "input_sha256": {
            "corpus": _sha256(input_hashes["corpus"], "corpus input digest"),
            "labels": _sha256(input_hashes["labels"], "label input digest"),
            "observations": _sha256(
                input_hashes["observations"], "observation input digest"
            ),
        },
        "repository_contract_status": "passed" if repository_passed else "failed",
        "release_status": "not_ready",
        "protected_evidence": dict(PROTECTED_NOT_READY),
        "areas": {
            "parser": parser,
            "passport": passport,
            "assistant": assistant,
            "visual": visuals,
        },
        "limitations": [
            "synthetic fixtures are contract tests, not a representative parser corpus",
            "Passport field correctness requires domain-capable human review",
            "assistant quality, latency, and cost require an exact-candidate live-model run",
            "visual precision requires human review and source navigation requires signed devices",
            "corpus rights and content-policy approval require protected legal review",
        ],
    }


def validate_report(value: Any) -> dict[str, Any]:
    root = _exact(
        value,
        {
            "schema_version",
            "classification",
            "corpus_id",
            "candidate_id",
            "scope",
            "input_sha256",
            "repository_contract_status",
            "release_status",
            "protected_evidence",
            "areas",
            "limitations",
        },
        "evaluation report",
    )
    if root["schema_version"] != REPORT_SCHEMA_VERSION:
        raise EvaluationError("report schema version is unsupported")
    if (
        root["classification"] != REPORT_CLASSIFICATION
        or root["scope"] != REPOSITORY_SCOPE
    ):
        raise EvaluationError("report scope or classification is invalid")
    _safe_id(root["corpus_id"], "report corpus ID")
    _safe_id(root["candidate_id"], "report candidate ID")
    hashes = _exact(
        root["input_sha256"], {"corpus", "labels", "observations"}, "report hashes"
    )
    for key, value in hashes.items():
        _sha256(value, f"report {key} digest")
    if root["repository_contract_status"] not in {"passed", "failed"}:
        raise EvaluationError("repository contract status is invalid")
    if root["release_status"] != "not_ready":
        raise EvaluationError("repository reports can never mark the release ready")
    _protected_not_ready(root["protected_evidence"], "report protected evidence")
    areas = _exact(
        root["areas"], {"parser", "passport", "assistant", "visual"}, "report areas"
    )
    for area_name, area in areas.items():
        if not isinstance(area, dict):
            raise EvaluationError(f"report area {area_name} is invalid")
        if area.get("repository_status") not in {"passed", "failed"}:
            raise EvaluationError(f"report area {area_name} lacks repository status")
        if area.get("release_status") != "not_ready":
            raise EvaluationError(f"report area {area_name} must remain not_ready")
    limitations = _list(root["limitations"], "report limitations", maximum=16)
    if len(limitations) < 5 or any(
        not isinstance(item, str) or not item for item in limitations
    ):
        raise EvaluationError("report limitations are incomplete")
    return root


def validate_report_against_inputs(
    value: Any,
    corpus: Mapping[str, Any],
    labels: Mapping[str, Any],
    observations: Mapping[str, Any],
    *,
    input_hashes: Mapping[str, str],
) -> dict[str, Any]:
    """Reject a report that does not exactly recompute from its bound inputs."""

    report = validate_report(value)
    expected = evaluate(
        corpus,
        labels,
        observations,
        input_hashes=input_hashes,
    )
    if report != expected:
        raise EvaluationError("evaluation report does not match its bound inputs")
    return report


def load_and_validate(
    corpus_path: Path,
    labels_path: Path,
    observations_path: Path,
    repository_root: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    corpus = validate_corpus(read_json(corpus_path), repository_root)
    labels = validate_labels(read_json(labels_path), corpus)
    observations = validate_observations(read_json(observations_path), corpus, labels)
    return corpus, labels, observations


def _paths(arguments: argparse.Namespace) -> tuple[Path, Path, Path]:
    return arguments.corpus, arguments.labels, arguments.observations


def _add_inputs(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--labels", required=True, type=Path)
    parser.add_argument("--observations", required=True, type=Path)
    parser.add_argument(
        "--repository-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate-inputs")
    _add_inputs(validate_parser)
    evaluate_parser = subparsers.add_parser("evaluate")
    _add_inputs(evaluate_parser)
    evaluate_parser.add_argument("--output", type=Path)
    report_parser = subparsers.add_parser("validate-report")
    report_parser.add_argument("path", type=Path)
    _add_inputs(report_parser)
    content_id_parser = subparsers.add_parser("report-content-id")
    content_id_parser.add_argument("path", type=Path)
    _add_inputs(content_id_parser)
    args = parser.parse_args(argv)
    try:
        if args.command in {"validate-report", "report-content-id"}:
            corpus, labels, observations = load_and_validate(
                args.corpus,
                args.labels,
                args.observations,
                args.repository_root,
            )
            report = validate_report_against_inputs(
                read_json(args.path),
                corpus,
                labels,
                observations,
                input_hashes={
                    "corpus": _digest_file(args.corpus),
                    "labels": _digest_file(args.labels),
                    "observations": _digest_file(args.observations),
                },
            )
            if args.command == "report-content-id":
                print(_digest_bytes(encode_canonical(report)))
            else:
                print(
                    f"Deep Reader repository evaluation report validated: {args.path}"
                )
            return 0
        corpus_path, labels_path, observations_path = _paths(args)
        corpus, labels, observations = load_and_validate(
            corpus_path,
            labels_path,
            observations_path,
            args.repository_root,
        )
        if args.command == "validate-inputs":
            print("Deep Reader repository evaluation inputs validated")
            return 0
        report = evaluate(
            corpus,
            labels,
            observations,
            input_hashes={
                "corpus": _digest_file(corpus_path),
                "labels": _digest_file(labels_path),
                "observations": _digest_file(observations_path),
            },
        )
        validate_report(report)
        encoded = encode_canonical(report)
        if args.output is None:
            sys.stdout.buffer.write(encoded)
        else:
            args.output.write_bytes(encoded)
            args.output.chmod(0o600)
        return 0
    except (EvaluationError, OSError) as error:
        parser.exit(1, f"deep-reader repository evaluation failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
