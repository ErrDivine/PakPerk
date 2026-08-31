# Deep Reader v0.2 evaluation status

This is a requirements ledger, not a passing evaluation report. Repository
tests may validate schemas, fixtures, thresholds, and evidence bindings. They
cannot mark protected human review, live model runs, legal review, staging,
telemetry, accessibility review, or signed-device exercises as passed.

## Current repository evidence

- The existing five-paper content evaluation and its worker validator remain a
  compatibility baseline for current chat and connection behavior.
- The GROBID image is pinned and the TEI fixture covers the current parser path.
- Queue-first validators cover the aligned Plan 02 authority boundary.
- `scripts/deep_reader_evaluation.py` validates a bounded, versioned,
  content-free corpus/label/observation contract and emits a deterministic
  report bound to all three inputs by SHA-256.
- `evaluation/deep-reader-v1/` includes Draft 2020-12 schemas and a generated
  synthetic fixture covering parser structure/source metrics, Passport
  evidence and abstention, assistant evidence-ID and method-baseline checks,
  and visual precision/source navigation. Repository/API tests additionally
  cover the closed Assistant evidence-correction vocabulary, redaction,
  response/claim/block binding, principal/current-generation fencing, and
  idempotent receipts. Its Docling record is explicitly disabled; no
  experimental result is implied.
- `scripts/deep_reader_release_evidence.py inventory` publishes the exact 23
  Plan 03 gates, required source classes, and closed assertions without a pass
  outcome.

The synthetic evaluator reports a repository contract result only. It cannot
constitute the representative parser corpus, human Passport field review,
exact-candidate live assistant evaluation, human visual precision review,
annotation/device matrix, reading study, legal approval, or accessibility
result required by Plan 03.

The implemented worker baseline must also be interpreted narrowly. GROBID is
the configured parser; the checked Docling observation is disabled rather than
a benchmark run. Passport generation is currently deterministic source-cue
selection and does not establish domain correctness. Version diff algorithm
`stable-key-content-similarity-v2` combines stable keys, exact hashes, and a
bounded content-similarity signal, but it is not a validated semantic text-edit
score. New generations now trigger a bounded background re-anchor pass: unique
exact matches may commit, fuzzy high-threshold candidates remain uncertain, and
users may explicitly reattach to an exact range on a newer generation with the
move retained in private history. Repository fixtures can prove those
fail-closed shapes, but none is permission to enable a feature or a claim that
a human-quality threshold passed.

The repository does not yet complete every surface required to pass the
protected gates. It now has a bounded worker pipeline for an exact
operator-reviewed, generation-scoped PNG source. The worker preflights
dimensions, decodes and re-encodes pixels to strip ancillary metadata, and
atomically publishes a manifest-hash-bound small/medium/large set. The
authenticated route verifies that manifest and the selected file's hash,
dimensions, media type, size, generation, and object scope. Mobile validates
and caches variants independently. Equations use exact-source, non-repairing
maintained rendering: SmartMath sanitization/input repair is disabled, and
malformed LaTeX or unsupported MathML falls back to selectable exact source.
Missing, linked, malformed,
oversized, or otherwise untrusted sources clear stale asset metadata and retain
caption/PDF fallback; parser-coordinate crops are never inferred and generated
accessibility descriptions remain capability-unavailable. Research
JSON/Markdown/manifest export and atomic
annotation import round-trip annotations, selectors, conflicts, merged bodies,
and exact retained re-anchor history in repository tests. The bounded research
export also includes owner-bound Assistant evidence feedback and optional
private correction detail, while deletion-cascade coverage binds those rows to
the same account/thread ownership root. Diff items expose
generation-checked object targets and exact PDF-page URLs where trustworthy.
The large-document schema now carries closed sustained-window, sample, latency,
frame, RSS, widget, and retention budgets, but no signed physical-device run
has passed them. Exact-candidate visual rights, quality, live-pipeline,
annotation, diff, performance, and accessibility results remain external
evidence gaps.

## Required evaluation artifacts

| Area | Repository-executable evidence | Protected external evidence |
| --- | --- | --- |
| Parser | Versioned corpus/label schemas; block/section/Introduction/citation/visual/page/source/corruption metrics; explicit GROBID/optional-Docling resource and failure comparison | Representative corpus rights review, human ground truth, staging resource and failure observations, completed Docling run if proposed |
| Passport | All ten field statuses, evidence precision, missing-field abstention, inference/conflict fixture evaluator | Domain-capable field correctness, contradiction, and evidence review |
| Assistant | All eleven Plan 03 question classes; invented-ID, unsupported-citation, claim support, and method/detail baseline evaluator; closed evidence-correction feedback with exact response/claim/block/principal/generation and idempotency contract tests | Exact-candidate model run, latency/cost evidence, and domain review |
| Annotations | sync/conflict, background exact/uncertain/orphan re-anchor, manual newer-generation reattach history, bounded export plus atomic 8 MiB import, and principal-scoped round-trip tests for selectors/conflicts/merged bodies/re-anchor history | restart, reflow, offline concurrency, export/import fidelity, and version behavior on signed devices |
| Visual objects | Caption/structured/source fallbacks, precision/recall and locator evaluator, exact reviewed-source PNG ingest, bounded ancillary-metadata-stripping re-encode, manifest/hash-verified atomic responsive sets, authenticated selectable-variant delivery, variant-bound account/generation/object/revision LRU pins, exact-source non-repairing on-device LaTeX/bounded-MathML rendering with selectable-source fallback, and terminal capability gating for unavailable generated accessibility descriptions | Human extraction/rights review, exact-candidate derivative pipeline and rollback exercise, and signed-device rendering/source-navigation/accessibility checks |
| Privacy | type/schema exclusions, bounded principal-scoped JSON/Markdown/manifest export including owner-bound Assistant feedback/private correction detail, deletion-cascade inventory tests, redacted feedback debug surfaces, log-fixture scan, ordinary-SQLite disclosure | live telemetry/log sink scan, isolated restore/deletion reapply, signed-device cleanup, local threat-model acceptance, and privacy/security review |
| Accessibility/performance | widget semantics, Dynamic Type, reduced-motion, bounded pagination/retention, and a closed three-role sustained large-document performance contract; no passing physical result | signed-device large-document budget matrix and human accessibility review |
| Rollout | default-off/dependency tests and evidence validator | staging canary, parser/model/queue rollback, reprocessing, release approval |

## Release result

`not_ready`: no checked-in artifact may change this state. A protected release
bundle validates only when all 23 gate manifests use one exact candidate binding
and include every required evidence class with passed outcomes, followed by a
bounded release-owner approval. Missing evidence, `pending`, placeholders, or a
repository result substituted for an external result fail validation.

The schema 18-to-24 migration/restore exercise is likewise protected staging
evidence. Successful unit tests, compilation of live PostgreSQL tests without a
configured database, generated OpenAPI/docs output, or an absent Helm binary do
not satisfy that gate.

The synthetic repository report itself always includes
`release_status: not_ready` and all `human_domain`, `legal_review`, `live_model`,
and `signed_device` sources as `not_ready`. `report-content-id` may bind that
report only to a gate's `repository` source; it never satisfies a protected
source class.

See the [rollout runbook](../runbooks/deep-reader-rollout.md) for the staged
order and rollback sequence.
