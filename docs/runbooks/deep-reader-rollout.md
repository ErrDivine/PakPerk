# Deep Reader staged rollout and rollback

This runbook controls the nine default-off Plan 03 switches and the complete
23-gate release evidence bundle. It supplements the general
[release runbook](release.md); it does not replace migration, restore,
deployment-binding, alert-adapter, or signed-mobile procedures.

## Non-negotiable entry conditions

1. The generated OpenAPI contract matches the candidate and preserves legacy
   Introduction and `/chat` compatibility routes.
2. The protected migration/restore exercise starts at schema 18, applies
   migrations 19 through 24 once, proves replay is a no-op, runs
   schema-compatible rollback/re-forward, and repeats deletion-ledger reapply
   against every Plan 03 owner-bound table. Feature rollback retains schema 24.
3. GROBID is still the configured default unless the parser benchmark,
   resource budget, fallback, reprocessing, and rollback gates authorize a
   different adapter.
4. All 30 release switches and all 39 dependency edges reconcile with the
   rendered release contract.
5. Repository, environment, and Helm Plan 03 switches, plus all ten mobile
   Plan 03 controls, are false until `releaseEvidence.deepReaderReleaseId`
   names the complete validated bundle.
6. No feed, import, prefetch, recommendation, notification, or Abstract display
   path can enqueue deep preparation. Approved trigger provenance survives into
   every job and derived artifact.
7. Queue navigation tests prove zero automatic recommendation leakage while
   queue state is active, unknown, stale, pending, offline, or changing account.
8. The public privacy notice and signed-client review state that Drift private
   research bodies are ordinary SQLite text. OS sandbox/device access/file
   protection and backup policy are the current local boundary; SQLCipher is
   deferred and no application-layer at-rest encryption is claimed.

Repository tests prove only the executable contract. Protected staging, human
domain/legal/accessibility/security review, live model/telemetry, signed-device
work, and release approval must be supplied as their distinct evidence source
classes. Never copy a repository digest into an external slot.

## Evidence workflow

Print the requirements-only inventory:

```bash
python3 -B scripts/deep_reader_release_evidence.py inventory
```

The output deliberately contains no outcome. Protected producers create
canonical owner-only JSON manifests, obtain the domain-separated content ID,
and validate each manifest:

```bash
chmod 0600 protected/deep-reader/*.json
python3 -B scripts/deep_reader_release_evidence.py content-id gate protected/deep-reader/gate.json
python3 -B scripts/deep_reader_release_evidence.py validate-gate protected/deep-reader/gate.json
```

After all 23 distinct manifests exist under one exact release binding, a
release owner approves the exact bundle no more than 14 days after the latest
run. Validate it with every manifest:

```bash
python3 -B scripts/deep_reader_release_evidence.py validate-bundle \
  protected/deep-reader/bundle.json \
  --gate-evidence protected/deep-reader/grobid-block-preservation.json \
  --gate-evidence protected/deep-reader/parser-benchmark-published.json
```

The abbreviated command shows the interface only; validation fails until all
23 `--gate-evidence` arguments are present. Keep protected manifests and raw
source records outside Git. Only the final `sha256:` bundle ID enters protected
Helm values.

## Staged enablement

For each step: deploy dark, verify exact candidate/deployment binding, run the
named repository and protected checks, enable only the named switch, observe a
bounded canary, and record the before/after result.

1. Complete the schema 18-to-24 migration, replay, restore/deletion reapply,
   schema-compatible rollback, and re-forward gate with all Plan 03 switches
   false. Repository tests do not satisfy this protected execution.
2. Enable `DEEP_READER_ENABLED` with GROBID. Exercise outline/block pagination,
   source navigation, large documents, preparation trigger isolation,
   generation supersession, cache bounds, and queue-safe entry/exit.
3. Enable `PAPER_PASSPORT_ENABLED`, then `SEMANTIC_FACETS_ENABLED`. Require
   field-level evidence, not-found/partial status, abstention, and domain review.
4. Enable `VISUAL_OBJECTS_ENABLED` only after extraction precision and source
   navigation pass. Exercise the exact operator-reviewed source-key workflow
   through ancillary-metadata-stripping generation, atomic manifest/hash-bound
   small/medium/large publication, authenticated variant selection, mobile
   cache identity, caption fallback, and rollback. Require rights review,
   protected live-delivery evidence, signed-device rendering/source-navigation/
   accessibility checks, and exact-source, non-repairing maintained equation
   renderer exercise before visual enablement. Confirm SmartMath input repair
   and sanitization remain disabled and that malformed LaTeX or unsupported
   MathML falls back to selectable exact source. Do not treat capability-gated
   accessibility-description regeneration as available.
5. Enable `ASSISTANT_V2_ENABLED` only after invented evidence IDs are zero,
   unsupported citation and baseline thresholds pass, and model cost/latency
   stay within budget.
6. Enable `ANNOTATIONS_ENABLED` after private authorization, sync conflict,
   bounded background re-anchor, manual reattach, export, deletion, offline,
   and signed-device checks pass.
7. Enable `RESEARCH_MEMORY_ENABLED` after annotations. Verify review/retire does
   not change Library state or automatic feed membership.
8. Enable `VERSION_DIFF_ENABLED` after uncertainty, provenance, version
   navigation, and old-generation behavior pass.
9. Enable `DOCLING_EXPERIMENT_ENABLED` only for the approved canary population.
   It must not alter the configured default or silently merge parser outputs.

At every stage, inspect parser/model failure and rejection rates, preparation
trigger counts, source-navigation failures, annotation conflict/orphan rates,
cache bounds, queue-authority violations, and privacy-safe telemetry. Any
confirmed queue-policy violation pages immediately; a rendered alert policy is
not proof that the live adapter routes it.

The current source tree is not eligible to complete this sequence. Responsive
visual generation/sanitization, selectable variants, bounded mobile caching,
and maintained equation rendering are implemented as repository contracts.
Generated accessibility descriptions remain deliberately unavailable because
no reviewed persisted draft schema exists. Parser/Passport/assistant/visual
quality, source-association and rights review, privacy review, annotation/
reflow/diff/accessibility checks, live pipeline and rollback exercise,
large-document measurements, staging runs, and signed-device evidence remain
protected execution gaps. Keep the affected switches false; an approval cannot
waive those gates.

## Rollback

Close switches in this order while preserving readable source access and stored
user data:

1. `DOCLING_EXPERIMENT_ENABLED`;
2. `VERSION_DIFF_ENABLED`;
3. `RESEARCH_MEMORY_ENABLED`;
4. `ANNOTATIONS_ENABLED`;
5. `ASSISTANT_V2_ENABLED`;
6. `VISUAL_OBJECTS_ENABLED`;
7. `SEMANTIC_FACETS_ENABLED`;
8. `PAPER_PASSPORT_ENABLED`;
9. `DEEP_READER_ENABLED`.

Then return parser selection to the last proven GROBID configuration, stop new
affected work, let leases settle or explicitly supersede generations, preserve
private artifacts, and run the tested reprocessing plan only with an approved
trigger. Do not down-migrate merely to close a feature. Legacy Introduction and
source access remain available. Keep schema 24; schema 18 is the migration
starting boundary, not a Plan 03 rollback target.

For queue leakage, first close `TO_READ_FIRST_ENFORCEMENT_ENABLED` as directed
by the general runbook, then close the affected Plan 03 switch. Unknown or
pending queue state remains fail-closed; rollback must never enable a
recommendation fallback.

## Exit criteria

- The exact release/deployment/candidate/parser/model/schema/prompt/corpus
  binding matches all 23 gate manifests and the bundle.
- Repository, staging, human, legal, live-model, signed-device, live-telemetry,
  security, accessibility, and release-approval classes are all present where
  required.
- Privacy/export/deletion and content-rights review match the final implemented
  schema and API names.
- The staged rollback and reprocessing exercise completed on the same candidate
  without private data exposure or queue-policy violation.

Until every item above has protected evidence, the release state is
`not_ready`; a repository pass or generated digest cannot change it.
