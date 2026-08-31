#!/usr/bin/env python3
"""Contract checks for Plan 03 rollout and evidence documentation."""

from __future__ import annotations

import re
from pathlib import Path

import deep_reader_release_evidence as deep_evidence
import operational_gate_evidence as operational_evidence


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def markdown_anchors(document: str) -> set[str]:
    anchors: set[str] = set()
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*$", document, flags=re.MULTILINE):
        plain = heading.replace("`", "")
        anchor = re.sub(r"[^\w\- ]", "", plain.lower())
        anchors.add(re.sub(r" +", "-", anchor))
    return anchors


def assert_local_links(relative: str) -> None:
    source = ROOT / relative
    document = source.read_text(encoding="utf-8")
    for raw_target in re.findall(r"\[[^]]*\]\(([^)]+)\)", document):
        target = raw_target.strip("<>")
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path_text, _, anchor = target.partition("#")
        target_path = source if not path_text else (source.parent / path_text).resolve()
        assert target_path.exists(), f"{relative}: missing link target {target}"
        if anchor:
            assert target_path.is_file(), f"{relative}: directory link has anchor {target}"
            assert anchor in markdown_anchors(
                target_path.read_text(encoding="utf-8")
            ), f"{relative}: missing anchor {target}"


def main() -> int:
    product = read("docs/deep-reader-and-research-memory.md")
    adr = read("docs/adr/0008-document-ingestion-adapter.md")
    rollout = read("docs/runbooks/deep-reader-rollout.md")
    evaluation = read("docs/evaluations/deep-reader-v0.2.md")
    deployment = read("docs/deployment-boundaries.md")
    release = read("docs/runbooks/release.md")
    rollout_lower = " ".join(rollout.split()).lower()
    normalized_adr = " ".join(adr.split())
    normalized_product = " ".join(product.split())

    feature_pairs = {
        "DEEP_READER_ENABLED": "deepReader",
        "PAPER_PASSPORT_ENABLED": "paperPassport",
        "SEMANTIC_FACETS_ENABLED": "semanticFacets",
        "VISUAL_OBJECTS_ENABLED": "visualObjects",
        "ASSISTANT_V2_ENABLED": "assistantV2",
        "ANNOTATIONS_ENABLED": "annotations",
        "RESEARCH_MEMORY_ENABLED": "researchMemory",
        "VERSION_DIFF_ENABLED": "versionDiff",
        "DOCLING_EXPERIMENT_ENABLED": "doclingExperiment",
    }
    for environment_name, helm_name in feature_pairs.items():
        assert environment_name in product
        assert helm_name in product
        assert environment_name in rollout
        assert environment_name in deployment

    assert len(operational_evidence.RELEASE_FEATURE_SWITCHES) == 30
    assert operational_evidence.RELEASE_FEATURE_DEPENDENCY_EDGE_COUNT == 39
    for required in (
        "all 30 release switches",
        "all 39 dependency edges",
        "deepReaderReleaseId",
        "all 23",
        "Never copy a repository digest into an external slot",
        "GROBID",
        "Docling",
        "TO_READ_FIRST_ENFORCEMENT_ENABLED",
        "Unknown or pending queue state remains fail-closed",
    ):
        assert required.lower() in rollout_lower, required
    assert "all 30 release switches" in release
    assert "all 39 required dependency edges" in release

    assert len(deep_evidence.GATES) == 23
    assert "requirements ledger, not a passing evaluation report" in evaluation
    assert "`not_ready`" in evaluation
    for gate in deep_evidence.GATES:
        assert gate in deep_evidence.GATE_ASSERTIONS
    for source_class in deep_evidence.SOURCE_PRODUCERS:
        assert any(
            source_class in required
            for required in deep_evidence.GATE_REQUIREMENTS.values()
        )
        source_label = source_class.replace("_", " ")
        assert source_label in rollout_lower or source_label in " ".join(
            evaluation.split()
        ).lower(), source_class

    for required in (
        "Repository fixtures validate the contract shape",
        "cannot be synthesized by CI",
        "never merged silently",
        "reprocessing/rollback",
    ):
        assert required in normalized_adr, required

    for required in (
        "private by default",
        "excluded from general recommendation inputs",
        "account export/delete API and table inventory",
        "cannot alter Library state",
        "OpenAPI contract",
    ):
        assert required in normalized_product, required

    for relative in (
        "docs/deep-reader-and-research-memory.md",
        "docs/adr/0008-document-ingestion-adapter.md",
        "docs/evaluations/deep-reader-v0.2.md",
        "docs/runbooks/deep-reader-rollout.md",
    ):
        assert_local_links(relative)

    print("Deep Reader rollout documentation contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
