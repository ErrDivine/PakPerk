# Pakperk Production v0.0 implementation plan

**Status:** authoritative implementation plan and repository status entrypoint
**Milestone:** Production v0.0
**Last synchronized:** 2026-08-02

This document is the documentation entrypoint for the Production v0.0 plan.
The complete normative plan is maintained at the repository root in
[`pakperk_production_v0_0_implementation_plan.md`](../pakperk_production_v0_0_implementation_plan.md).
That file is intentionally the canonical copy so agents working from the
repository root and contributors reading `docs/` use the same requirements.
Changes to either location must preserve this relationship; do not summarize,
silently narrow, or selectively supersede requirements from the canonical
plan.

The current repository-versus-release evidence status is maintained in the
[Production v0.0 completion audit](production-v0.0-completion-audit.md).

## What the plan governs

Production v0.0 evolves the existing modular Rust monolith and Flutter reader
into a store-ready early product. It preserves guest reading and the current
paper-processing lifecycle while adding, in releasable phases:

- a persistent Read / You application shell and accessible launch motion;
- Drift/SQLite for relational offline cache, drafts, and a durable sync outbox;
- OIDC Authorization Code with PKCE, secure token storage, and provider-neutral
  backend verification (with Keycloak as the reference deployment);
- synchronized To Read saves for signed-in users;
- public, flat paper comments with terms acceptance, reporting, blocking,
  moderation, account deletion, and operational ownership;
- PostgreSQL-backed shared rate limits, contract checks, observability, and
  production operations.

The canonical plan's stable API names, including names reserved by successful
v0.0 semantics, are indexed in the [API error catalogue](api-error-catalogue.md).

## Non-negotiable guardrails

The canonical plan's execution contract is binding. In particular:

- do not rewrite the current paper pipeline or weaken its generation-scoped
  artifact and full-text-policy boundaries;
- never initiate paper preparation through startup, prefetch, cache loading, or
  account synchronization; it remains a committed reader transition or explicit
  retry;
- preserve anonymous browsing and reading; authentication is only for
  cloud-owned and moderation-sensitive actions;
- do not store passwords or put access/refresh tokens in general preferences,
  SQLite, logs, analytics, crash reports, or provider snapshots;
- make retried writes idempotent and use expand-and-contract database
  migrations;
- do not expose public comments until all required safety controls are live;
- do not add a network service without an ADR; PostgreSQL remains the shared
  synchronization, jobs, and rate-limit source of truth for this milestone.

## Phase records

Phase 0 creates safe extension points without altering the visible demo. Its
documentation outputs are this plan entrypoint and the ADRs in
[`docs/adr/`](adr/). The implementation outputs are route/middleware/DTO and
repository splits, initial OpenAPI, typed flags, and validated staging/
production configuration. No accounts, account tables, or public controls are
introduced by Phase 0 alone.

Implementation evidence is recorded in the
[Phase 0 report](phase-reports/phase-0.md).

Phase 1 establishes the two-destination mobile frame, stateful routing,
validated paper/arXiv links, guest You surface, root contextual routes, design
tokens, light/dark themes, native launch assets, and a bounded cached-first
startup state machine. Accounts, library, and comments remain explicitly
disabled; their routes are truthful placeholders rather than partial product
claims. Implementation and verification evidence is recorded in the
[Phase 1 report](phase-reports/phase-1.md).

Phase 2 replaces bulk SharedPreferences content with a versioned Drift/SQLite
database, transactionally imports and removes valid legacy blobs, and adds
exact multi-page feed persistence, arXiv-version and processing-generation
coherence, bounded eviction, and lifecycle-safe physical compaction. A
dedicated feed-only prefetch coordinator implements single-flight cache-ahead,
query obsolescence, retry/backoff, and content-free metrics. The backend and
mobile client add opaque ETag/`If-None-Match` revalidation with bodyless `304`
responses. The implementation is present; final integrated and native gates
are recorded as passing in the [Phase 2 report](phase-reports/phase-2.md), and
the phase is complete.

Phase 3 adds optional OIDC accounts while preserving guest reading. Its current
implementation includes bounded provider-neutral discovery/JWKS verification,
transactional JIT account mapping, versioned profile updates, the first shared
PostgreSQL rate-limit bucket, native AppAuth and secure token storage, an
optional Keycloak development profile, and the account-aware You/onboarding
flow. `GET` and `PATCH /v1/me` are registered only when accounts are enabled;
library, comments, and deletion remain absent. The repository-wide gates,
native builds, live PostgreSQL scenarios, and real Keycloak/Mailpit PKCE flow
passed, so Phase 3 is **complete**. Evidence is recorded in the
[Phase 3 report](phase-reports/phase-3.md).

Phase 4 is **complete**. Its bounded contract is a single `to_read` set,
authenticated list and account-scoped revision-change reads, idempotent
save/remove writes, 90-day tombstones with a safe reset signal, and mobile
optimistic outbox convergence. Another account's mutations never advance or
leak through a reader's watermark. Library routes require the account and
library gates; an independent write gate can freeze mutations without removing
reads or affecting public paper access. The detailed contract is in
[To Read library synchronization](library-sync.md), and the repository, live
OIDC/PostgreSQL, two-client, no-preparation, write-kill, and native-build
evidence is recorded in the [Phase 4 report](phase-reports/phase-4.md).

Phase 5 is **complete** as a repository capability. It implements flat public
paper comments, current policy acceptance, deterministic and provider-neutral
moderation, shared user/request-origin limits, separate comment-report,
user-report, block, and author actions,
audited moderator tooling, account-scoped mobile pages/drafts/blocks, and the
independent comment-creation kill switch. Live two-user PostgreSQL/Keycloak and
provider-outage evidence is recorded in the
[Phase 5 report](phase-reports/phase-5.md). The feature remains default-off;
public enablement also requires the target environment's moderation, deletion,
legal, monitoring, and store-policy evidence.

Phase 6's **repository implementation is present as a dark-launched release
candidate**. It includes the recent-auth mobile/API/web deletion flow, bounded
Keycloak administration, leased deletion worker, independent signed restore
ledger and replay, retention cleanup/purge controls, a production Helm topology,
OTLP and a validating mobile telemetry gateway, a content-addressed production
alert policy and immutable release-evidence contract bound to features,
deployed image digests, chart/app identity, and legal-policy versions, exact-
SHA scan-before-publish backend/site image automation with digest-only
promotion, security/source/native SBOM workflows with reviewed runtime-graph
completeness, and locked native/mobile release tools including MRI Ruby 3.4.10
and RubyGems 4.0.17 plus Flutter 3.44.8/framework
`058e0af2c2b57e369d905a03ac9748b0ebf543c6`/Dart 3.12.2, signed mobile
candidate automation with content-addressed artifact/signing provenance, a
protected four-device acceptance lane, policy/support hosting, and release,
incident, moderation, deletion, observability, load, and backup/restore
runbooks. The repository also contains an opt-in disposable Keycloak deletion
acceptance workflow, a protected exact-SHA staging backend load gate, a manual
exact-main public-edge verification/evidence lane for the configured dark
deployment, and a closed two-phase restore harness bound to a protected
attestation and content-addressed evidence. Mobile startup/cache/accessibility
hardening covers one shared cache policy, stale-content-first rendering, an
accessible cache-miss skeleton, shared paper actions, concurrent local/session
work, retry/repair ownership, reduced motion, settled haptics, 200% text,
contrast, and canonical arXiv actions. Repository and mobile evidence is
recorded in the
[Phase 6 report](phase-reports/phase-6.md) and
[mobile Phase 6 report](phase-reports/phase-6-mobile.md).

The 2026-08-02 closure audit also replaced readable pagination coordinates
with rotation-aware authenticated-encryption tokens bound to each list's
purpose and viewer/filter scope, bound feed validators to the active cursor-key
epoch, made shared mobile connectivity state depend on raw transport outcomes,
preserved real `401` reachability through failed refreshes, enforced one-shot
authenticated handoffs, bounded safety-intent recovery after authenticated
comment reload, hid comment totals until a network-backed page is known
complete, and bound policy acceptance to the exact documents in each signed
build. CI now parses every shell script independently rather than relying on
Bash's multi-argument behavior, and the OpenAPI compatibility gate rejects
directional schema, response, callback, webhook, and serialization regressions.
The final current-tree canonical run passed Flutter analysis and all 601 locked
tests, every Android debug flavor, every iOS simulator flavor, strict artifact
inspection, the fresh-database Rust workspace, 31 browser/site tests, Helm,
SBOM and release-contract validators, and the opt-in Collector export E2E. The
locked suite includes account-rebind, deletion-latch, async-intent, and cache-
purge isolation regressions. These are local repository checks; they do not
alter the external release-gate status below.
Fresh isolated reference-stack runs also passed the real Keycloak/PostgreSQL
account-deletion worker/ledger/reconciliation path and the two-user plus
operator comments/moderation/IdP-outage matrix, with redaction and cleanup.

Phase 6 is not accepted as a public/store release from source evidence alone.
The disposable reference-provider workflow does not replace protected staging
deletion against the real secret manager, external ledger, backup inventory,
and alert route; the bounded load harness does not replace a successful
protected staging run. The latest analyzer, locked-suite, debug/simulator
artifact, site, Helm, and Collector results are current-tree local evidence. An
actual isolated backup/PITR restore and deletion replay, migration/rollback
exercise, deployed staging/production telemetry sink/retention and alert-
adapter/receiver/canary checks, current networked advisory/container scans,
protected image publication and digest promotion, a successful public-edge
workflow artifact for that exact dark-deployed target, physical-device and
performance/crash windows, protected signing, TestFlight/closed Play upload,
reviewer account/notes, legal/content review, disclosures, and store approval
remain external release gates and must stay marked unpassed until their owners
attach immutable evidence.

Phase 0's exit criteria require unchanged demo behavior and API fixtures,
passing `./scripts/check.sh`, complete OpenAPI coverage for its existing routes,
and no public account controls. Phase 2 additionally requires offline migration,
the measured cache-ahead scenario, single-flight requests, enforced cache
bounds, a saved-paper pin, and proof that prefetch does not prepare papers.
Repository phases and public release gates are not considered complete merely
because their code compiles:
the acceptance scenarios and Definition of Done in the canonical plan remain
the release gate.

## Decision records

The following ADRs record the fixed choices needed before production behavior
is added:

1. [ADR 0001 — OIDC and Keycloak reference deployment](adr/0001-oidc-and-keycloak-reference.md)
2. [ADR 0002 — Drift local database](adr/0002-drift-local-database.md)
3. [ADR 0003 — Stateful shell routing](adr/0003-stateful-shell-routing.md)
4. [ADR 0004 — Public comments and moderation](adr/0004-public-comments-and-moderation.md)
5. [ADR 0005 — Shared PostgreSQL rate limits](adr/0005-shared-postgres-rate-limits.md)
6. [ADR 0006 — Mobile telemetry gateway](adr/0006-mobile-telemetry-gateway.md)
