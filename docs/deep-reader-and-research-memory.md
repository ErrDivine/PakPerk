# Deep Reader and research memory

Pakperk v0.2 deepens reading without changing the queue-first authority model.
The active To Read queue remains the only source for automatic next-paper
navigation. Reader progress, checkpoints, document end, annotations, evidence
cards, explicit Search/Connections/Memory branches, and memory review cannot
change Library state unless the user performs an explicit Library mutation.

This document is the repository contract, not a statement that every Plan 03
release gate has passed. The protected evidence required for rollout is defined
in the [Deep Reader rollout runbook](runbooks/deep-reader-rollout.md) and its
[evaluation status](evaluations/deep-reader-v0.2.md).

## Reader and document contract

The normalized document model uses stable generation-bound block keys, source
locators, section ancestry, page mappings, and inline citation/term/symbol
spans. Generated Passport fields, assistant claims, definitions, visual
objects, annotations, evidence cards, and version diffs must retain resolvable
provenance. The product contract requires the original source to remain one
action away. Version history and every diff item now expose the exact retained
arXiv source version; object IDs are never treated as public links. A visual or
diff action opens an exact PDF page only when the retained parser locator is
trustworthy, and otherwise falls back to the exact retained source version.

Skim, Read, and Inspect are presentation modes over the same normalized source;
they are not separate documents. Selecting a mode cannot alter Library state.
If parsing or provenance is uncertain, the UI shows the uncertainty or falls
back to metadata/source access. It must not invent reconstructed content.

GROBID remains the production parser baseline. Adapter selection and provenance
follow [ADR 0008](adr/0008-document-ingestion-adapter.md). Docling is an
experiment only; its feature switch is not permission to replace the baseline
without the versioned benchmark, resource, fallback, reprocessing, and rollback
evidence.

The repository now carries the Plan 03 implementation behind default-off
controls:

- migration 19 records and enforces approved preparation triggers;
- migration 20 stores parser-independent generations, section trees, blocks,
  inline spans, figures, tables, equations, terms, definitions, and source
  locators while continuing to publish the legacy Introduction capability;
- migration 21 adds shared provenance, Passport fields and field feedback,
  source-linked semantic spans, bounded assistant threads/messages, and
  principal-bound evidence-specific Assistant feedback evaluations;
- migration 22 adds principal-scoped annotations, retained note conflicts,
  re-anchor history, evidence cards, position-only checkpoints, memory items,
  and an idempotent research-artifact operation stream; and
- migration 23 stores bounded generation-to-generation diff manifests and
  structural diff items; and
- migration 24 adds atomic principal-scoped annotation archive imports,
  content-free import idempotency, and lossless retained conflict resolution.

On mobile, the horizontal stages remain Abstract, Introduction + Assistant,
and Connections. Skim, Read, and Inspect are paper-scoped modes inside those
stages. The reader uses the existing account/auth-epoch-scoped reading-feed
authority for automatic navigation, stops naturally at document end, blocks
horizontal paging while selection or table pan owns the gesture, and restores
position without treating a checkpoint as Library state. Cached document and
private research rows are generation- and account-scoped; late responses and
replayed outbox work are fenced before publication.

Abstract may issue only the public, optional-auth Passport read when the paper
already advertises a current ready Passport; it never requests preparation.
After a committed Introduction, a visible reader may use a bounded, GET-only
status observer for later visual, term, facet, and Passport capabilities while
the prepared text remains readable. Skim renders at most eight loaded blocks
and never paginates or reports a true document end. Read and Inspect retain
bounded active-only pagination, show explicit section and document-end stopping
points, and state that no Library transition occurred. Read also keeps a
48-point, large-text-safe Assistant composer pinned outside the document scroll;
an explicit bounded question is handed to the evidence-scoped sheet exactly
once, and the sheet keeps its own composer above the keyboard. Semantic cues
default to the restorable `Key` density, offer `Off` and `Detailed`, use
non-color distinctions, and open ordered current-paper, cited-paper, glossary,
then clearly labeled generated definitions without synthesizing from a raw
selection.

Research memory is also reachable as an explicit account-owned destination at
`You -> Memory`. Its bounded, paginated due queue spans papers without becoming
an alternate reading feed. Later-today, tomorrow, one-week, custom snooze, and
retire actions update only the memory item; opening a source paper preserves a
Memory return origin and does not write Library history or queue membership.
Clean cached rows absent from an authoritative cross-device snapshot are
removed, while unsynchronized local writes remain recoverable.

The source implementation remains deliberately fail-closed at several Plan 03
release boundaries. GROBID normalizes figure captions, table grids/plain-text
fallbacks, and equation source with generation-bound locators. The worker
accepts only an exact operator-reviewed PNG association, preflights it without
trusting parser paths, decodes and re-encodes it to strip ancillary metadata,
and atomically publishes a manifest-hash-bound generation-scoped
small/medium/large set. The authenticated endpoint revalidates policy,
capability, object, generation, set scope, manifest and file hashes, media type,
dimensions, aspect, and size before serving the requested variant. Mobile
validates response binding and keys its bounded cache by variant. Missing or
invalid sources clear stale asset metadata and retain caption/exact-page
fallback. Equations use exact-source, non-repairing maintained rendering:
SmartMath sanitization/input repair is disabled, and malformed LaTeX or
unsupported MathML falls back to selectable exact source. The worker never
infers PDF crops, and generated
accessibility descriptions fail terminally until a reviewed persisted draft
schema exists. Visual enablement remains blocked on protected source-association,
rights, precision, accessibility, live-pipeline, and signed-device evidence.

The mobile document client uses bounded pagination, lazy visual loading only in
Inspect, cancellation fences, and an explicit 2,000-block device budget
contract, but no protected physical-device run has supplied the required
measurements. Bounded JSON research export and atomic annotation import now
round-trip annotations, selectors, retained conflicts, merged conflict bodies,
and exact re-anchor history in database/mobile contract tests. Every supported
diff object is resolved against its exact retained paper generation and opens
the matching PDF page when a trustworthy locator exists, falling back to that
exact retained source version otherwise. Signed-device import/reflow/conflict,
diff-navigation, and large-document results remain `not_ready`; repository
tests and dark UI cannot substitute for protected execution.

## Evidence-first generation

Every generated artifact records the paper, generation, source block/object,
parser/schema version, and model/prompt version where applicable. Assistant
output is accepted only when every cited evidence ID exists in the allowed
retrieval set and belongs to the current generation. Unsupported questions
abstain. Paper text is untrusted input and cannot override system policy or ask
the model to ignore evidence validation.

No chain-of-thought is stored or exposed. Bounded answer text, claim-level
citations, validation outcomes, provider-reported token availability/counts,
latency, and safe failure classes are sufficient for product behavior and
evaluation. Pricing is derived outside the request path; a provider that does
not return token usage is recorded as `unavailable`, never estimated.

Assistant evidence feedback uses a closed correction vocabulary rather than a
generic thumbs or sentiment score. The
`POST /v1/papers/{paper_id}/assistant/feedback` route accepts an idempotent
operation only after the response, thread, provenance, paper, principal, and
current generation match, and after any claim/evidence-block target is found in
the persisted answer evidence map. Optional correction detail is private and
redacted from debug output; every feedback response is `private, no-store`.

## Private artifacts

Annotations, note bodies, evidence cards, checkpoints, research-memory items,
and account-owned Assistant evidence feedback are private by default. They are
excluded from general recommendation inputs, training, logs, crash reports, and
content-free product telemetry. Memory review and retirement remain independent
of Library state.

The implemented account export/delete API and table inventory is explicit:

- `GET /v1/annotations/export` returns principal-scoped JSON or Markdown. Small
  exports retain the single-response contract; `paged=true` switches to a
  lossless bounded sequence for either one paper or the complete account. Each
  part carries one complete artifact plus only the parent/citation context
  needed to interpret or import it. Its opaque `next_cursor` is encrypted and
  bound to the principal, optional paper scope, and export snapshot; it appears
  in both JSON page metadata and response headers. `format=manifest` remains a
  bounded per-paper summary. The export includes annotations and
  selectors, retained conflicts, re-anchor attempts, evidence cards,
  checkpoints, memory items, owner-bound assistant threads/messages,
  evidence-specific Assistant feedback including optional private correction
  detail, private provenance, canonical Library metadata/private save notes,
  and citation metadata/original links. It does not export reconstructed full
  paper text or principal identifiers.
- The same bounded export remains reachable from `You -> Settings -> Account`
  when Assistant v2 is enabled without annotations, so private assistant
  history, evidence feedback, and provenance never become undeletable or
  inaccessible merely because the annotation UI is dark. The mobile action
  rechecks account scope before and after the request and copies only after a
  verified response. When another part exists, the committed copy confirmation
  exposes `Next part`; no individually valid note has to be shortened or
  deleted to fit a single mobile response.
- `POST /v1/annotations/import` accepts only the annotation-bearing subset of
  that JSON schema under an idempotency key and an 8 MiB request ceiling. The
  transaction verifies retained paper/generation/block text and offsets,
  restores conflicts and re-anchor history, skips equivalent IDs, and aborts
  the whole import on an ID collision or unavailable source. It never imports
  Library state, papers, evidence cards, memory, or assistant history.
- Individual annotation, evidence-card, and memory deletes are idempotent
  tombstones that clear private bodies. Account deletion cascades
  `research_artifact_sync_metadata`, `research_artifact_operations`,
  `annotations`, `annotation_conflicts`, `annotation_reanchor_attempts`,
  `annotation_imports`,
  `evidence_cards`, `reading_sessions`, `reading_checkpoints`, `memory_items`,
  owner-bound `assistant_threads`/messages,
  `assistant_evidence_feedback_evaluations`, owner-bound provenance, and
  Passport feedback through the canonical `users` ownership root. Shared paper
  metadata, shared normalized documents, and shared derived artifacts remain.
- Assistant threads start with a 30-day expiry, are refreshed by at most 30
  days without extending beyond 90 days from creation, retain at most 50
  messages, and are removed in hourly batches of at most 1,000 together with
  their private provenance. Other live research artifacts remain until the
  user deletes them through a supported surface, or deletes the account;
  checkpoints have no separate delete route. Tombstones/conflict history
  remain part of sync/export until a separately reviewed purge policy exists.

Server traffic is protected by TLS and server storage relies on the deployed
infrastructure's reviewed at-rest controls. The mobile Drift database is not
encrypted by Pakperk at the application layer: private bodies are ordinary
SQLite text protected by the OS app sandbox, device access controls, platform
file protection, and backup exclusions where configured. SQLCipher is deferred
until a platform threat-model and migration/recovery design is approved. Do not
describe the current mobile database as encrypted at rest.

The database cascades and repository tests establish the executable mechanism;
the privacy/legal review, signed-device cleanup, live deletion, isolated
restore, and current-ledger reapply evidence are still `not_ready` and block
private-feature rollout.

## Compatibility API

Plan 03 adds versioned document, Passport, assistant, annotation, evidence-card,
checkpoint, memory, version, and diff surfaces under `/v1`. Existing
Introduction and `/chat` routes remain available during the compatibility
window. The generated [OpenAPI contract](openapi-v1.json) is authoritative for
which operations exist in the current build; this product contract must never
be used as a substitute for generated API evidence.

The current contract also exposes a current-generation semantic-span read,
Passport feedback, evidence-specific Assistant feedback, and principal-scoped
annotation-conflict recovery. Assistant feedback is bound to the exact
principal/current-generation answer and uses operation-ID replay receipts;
generic sentiment is not accepted. Conflict pagination is revision-fenced and
sealed; a reinstalled client can rebuild the complete conflict queue without
relying on an old local annotation cache. Checkpoint reads accept an exact
paper scope so a current paper cannot be hidden behind an account-wide
retention/page bound.

The current Passport worker is a deterministic source-cue baseline. It emits
all ten typed fields as source-backed `supported`, `not_found`, or
`not_applicable`, with per-field provenance; no model quality is implied. The
current version-diff algorithm is `stable-key-content-similarity-v2`: it
compares metadata, blocks, sections, figures, tables, equations, Passport
fields, and references using stable keys, exact content hashes, and a bounded
similarity signal for modified content. It labels parser-change uncertainty and
does not claim a validated semantic text-edit score.

Publishing a newer document generation enqueues an independent, bounded
background annotation re-anchor pass. A unique exact quote on the same stable
block or in matching quote context may move automatically; a unique
high-threshold fuzzy candidate is recorded as `uncertain`, and no match becomes
`orphaned`. Neither case is silently committed as an anchored move. A user may
manually reattach an existing annotation only within the same paper to a newer
retained generation with an exact target range and matching optimistic
revision. That action records a `manual` re-anchor attempt in the same private,
idempotent history. These conservative baselines remain dark until their
protected quality gates pass.

## Default-off controls

The server and Helm contract expose these switches, all false by default:

| Environment switch | Helm key | Dependency |
| --- | --- | --- |
| `DEEP_READER_ENABLED` | `deepReader` | none |
| `PAPER_PASSPORT_ENABLED` | `paperPassport` | Deep Reader |
| `SEMANTIC_FACETS_ENABLED` | `semanticFacets` | Deep Reader |
| `VISUAL_OBJECTS_ENABLED` | `visualObjects` | Deep Reader |
| `ASSISTANT_V2_ENABLED` | `assistantV2` | Deep Reader |
| `ANNOTATIONS_ENABLED` | `annotations` | accounts and Deep Reader |
| `RESEARCH_MEMORY_ENABLED` | `researchMemory` | accounts, Deep Reader, and annotations |
| `VERSION_DIFF_ENABLED` | `versionDiff` | Deep Reader |
| `DOCLING_EXPERIMENT_ENABLED` | `doclingExperiment` | Deep Reader |

Repository, mobile, Helm, and environment defaults keep every Plan 03 switch
off. Production rejects any enabled Plan 03 switch without an immutable
`releaseEvidence.deepReaderReleaseId`. That ID must name a complete bundle
validated by `scripts/deep_reader_release_evidence.py`; a digest alone does not
prove that the protected human, staging, telemetry, or signed-device work ran.

## Repository verification

Run the repository-owned checks without treating them as external approval:

```bash
python3 -B scripts/test_deep_reader_release_evidence.py
python3 -B scripts/test_production_approval_evidence.py
python3 -B scripts/test_deployment_binding_evidence.py
python3 -B scripts/test_deep_reader_rollout_docs.py
./scripts/check_openapi.sh
./scripts/validate_helm_release.sh
```

The parser benchmark, assistant and Passport evaluation, annotation/device
matrix, accessibility review, live privacy scan, staging canary, rollback, and
release approval remain protected external gates until their exact manifests
are present and validated. Responsive derivative generation/sanitization and
maintained equation rendering are repository implementations. Their
exact-candidate pipeline/rollback exercise and protected signed-device,
visual-rights/quality, accessibility, and performance evidence remain
outstanding and cannot be waived by repository tests or an approval artifact.
