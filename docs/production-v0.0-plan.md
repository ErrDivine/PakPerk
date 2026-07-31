# Pakperk Production v0.0 implementation plan

**Status:** authoritative implementation plan
**Milestone:** Production v0.0
**Last synchronized:** 2026-07-31

This document is the documentation entrypoint for the Production v0.0 plan.
The complete normative plan is maintained at the repository root in
[`pakperk_production_v0_0_implementation_plan.md`](../pakperk_production_v0_0_implementation_plan.md).
That file is intentionally the canonical copy so agents working from the
repository root and contributors reading `docs/` use the same requirements.
Changes to either location must preserve this relationship; do not summarize,
silently narrow, or selectively supersede requirements from the canonical
plan.

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

Phase 0's exit criteria require unchanged demo behavior and API fixtures,
passing `./scripts/check.sh`, complete OpenAPI coverage for its existing routes,
and no public account controls. Phase 2 additionally requires offline migration,
the measured cache-ahead scenario, single-flight requests, enforced cache
bounds, a saved-paper pin, and proof that prefetch does not prepare papers.
Later phases are not considered complete merely because their code compiles:
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
