# ADR 0008: Scholarly-document parser adapter and evidence-bound selection

## Status

Accepted for Plan 03 implementation. GROBID remains the production default.

## Context

The existing worker parses GROBID TEI directly into the v0.0 document model.
Deep Reader needs normalized blocks, section trees, citations, page mappings,
figures, tables, equations, terms, and stable provenance. Parser quality varies
by document class, and choosing a parser from a few favorable examples would
make generated artifacts and reprocessing behavior unsafe.

## Decision

Introduce a `ScholarlyDocumentParser` adapter boundary in the ingestion layer.
Every successful or terminal parse records a closed adapter ID, adapter
version, normalized schema version, input generation, and safe failure class.
Normalization, quality checks, provenance publication, and generation
supersession remain parser-independent.

The worker selects one configured primary adapter. A deterministic fallback is
allowed only for explicitly enumerated failure classes. Outputs from two
adapters are never merged silently; any future hybrid records provenance for
each component object.

GROBID retains its pinned image, timeout and PDF bounds, license/full-text
policy, TEI fixtures, and reference-resolution behavior. Docling or another
adapter stays behind `DOCLING_EXPERIMENT_ENABLED`. The experiment flag requires
`DEEP_READER_ENABLED` and does not itself authorize a default change.

## Benchmark decision gate

A candidate default must be evaluated on a legally suitable, versioned corpus
covering two-column layouts, nested sections, equations, dense tables,
multi-panel figures, malformed references, image-heavy inputs where permitted,
long appendices, unusual headings, and older PDFs. Human ground truth covers
ordering, boundaries, citation targets, visual associations, table structure,
equations, page mapping, references, corruption, duplication, and omissions.

The decision binds corpus and ground-truth digests, adapter/container and
dependency identities, document schema, resource measurements, fallback
classes, content-policy behavior, and reprocessing/rollback results. Repository
fixtures validate the contract shape; legal suitability and human labels are
external evidence and cannot be synthesized by CI.

## Consequences

- Parser provenance becomes part of every derived artifact and cache key.
- A parser or schema change creates a new generation/reprocessing decision.
- The system may terminate metadata-only when reliable extraction is
  unavailable.
- The [rollout runbook](../runbooks/deep-reader-rollout.md) must prove canary,
  rollback, and supersession before a default changes.
- New external parser images require the existing digest, SBOM, vulnerability,
  license, network-policy, and release-binding controls.
