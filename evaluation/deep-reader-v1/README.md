# Deep Reader evaluation contract v1

This directory contains repository-owned, synthetic fixtures for the Plan 03
evaluation machinery. It proves that the metric and fail-closed evidence
contracts execute deterministically. It is **not** the representative parser
benchmark and is **not** release evidence.

The fixture has no third-party paper content. Its manifest deliberately records
corpus rights review, human ground truth, live-model evaluation, and
signed-device verification as `not_ready`. The evaluator refuses any checked
repository fixture or generated report that changes those protected statuses.

## Files

- `corpus-manifest.json` binds the source fixture by SHA-256, inventories the
  required Plan 03 document classes, and declares thresholds.
- `ground-truth-labels.json` carries only synthetic structural IDs, expected
  statuses, accepted evidence groups, and source locators. It is explicitly not
  human ground truth.
- `synthetic-candidate-observations.json` exercises GROBID output and records
  Docling as disabled, rather than pretending an experimental run occurred.
- `sources/` contains the generated, non-copyrighted TEI input.
- `schemas/` contains Draft 2020-12 schemas. The Python validator is normative
  for cross-file uniqueness, coverage, source-digest, and semantic invariants
  that JSON Schema cannot express cleanly.

Raw paper text, prompts, questions, answers, private notes, and raw model I/O
are forbidden from the JSON contracts. The parser source is a generated fixture
and is never emitted into reports.

## Run

From the repository root:

```bash
python3 -B scripts/test_deep_reader_evaluation.py

python3 -B scripts/deep_reader_evaluation.py validate-inputs \
  --corpus evaluation/deep-reader-v1/corpus-manifest.json \
  --labels evaluation/deep-reader-v1/ground-truth-labels.json \
  --observations evaluation/deep-reader-v1/synthetic-candidate-observations.json
```

Generate a content-addressable repository report in a private temporary file,
then verify it by recomputing every value from its three bound inputs:

```bash
report_path="$(mktemp /tmp/pakperk-deep-reader-evaluation.XXXXXX)"
python3 -B scripts/deep_reader_evaluation.py evaluate \
  --corpus evaluation/deep-reader-v1/corpus-manifest.json \
  --labels evaluation/deep-reader-v1/ground-truth-labels.json \
  --observations evaluation/deep-reader-v1/synthetic-candidate-observations.json \
  --output "$report_path"

python3 -B scripts/deep_reader_evaluation.py validate-report "$report_path" \
  --corpus evaluation/deep-reader-v1/corpus-manifest.json \
  --labels evaluation/deep-reader-v1/ground-truth-labels.json \
  --observations evaluation/deep-reader-v1/synthetic-candidate-observations.json
```

`report-content-id` runs the same recomputation and prints the SHA-256 that may
be used as the `repository` source reference in a protected gate manifest:

```bash
python3 -B scripts/deep_reader_evaluation.py report-content-id "$report_path" \
  --corpus evaluation/deep-reader-v1/corpus-manifest.json \
  --labels evaluation/deep-reader-v1/ground-truth-labels.json \
  --observations evaluation/deep-reader-v1/synthetic-candidate-observations.json
```

That identifier satisfies only the repository source class. It cannot replace
the `human_domain`, `legal_review`, `live_model`, or `signed_device` sources
required by `scripts/deep_reader_release_evidence.py`.

## Metrics and current gaps

The evaluator computes:

- parser block and paragraph-boundary precision/recall, block order, section
  paths, Introduction detection, citation and visual precision/recall,
  page/source navigation, corruption, duplicate/missing content, resource
  ratios, and failure/fallback classes;
- Passport status accuracy, source-evidence precision, missing-field
  abstention, and inference/conflict label accuracy;
- assistant invented evidence IDs, unsupported citation rate, supported-claim
  recall, full question-category coverage, and method/detail baseline parity;
- visual object and per-kind precision/recall, table-structure fidelity, and
  exact source-navigation success.

The checked corpus intentionally leaves two-column, malformed-reference,
scanned/image-heavy, long-appendix, and older-arXiv coverage missing. Docling is
recorded as disabled, so its quality/resource comparison is `not_ready`. A
legally approved representative corpus, domain labels, exact-candidate live
model runs, and signed-device navigation remain external release blockers.
