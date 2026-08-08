# Production v0.0 Phase 4 report

**Phase:** To Read library
**Status:** Complete — accepted
**Implementation snapshot:** 2026-07-31
**Starting commit:** `728ae3d`

This is the accepted Phase 4 record. It closes the first account-owned reader
feature: one synchronized `to_read` set with optimistic offline mutation,
durable retry, revision-based cross-device convergence, and cached metadata.
It does not claim that public comments, account deletion, or the release-wide
Production v0.0 definition of done is complete.

The authoritative wire, pagination, conflict, retention, and preparation
behavior is recorded in the
[To Read library synchronization contract](../library-sync.md).

## Preserved invariants

- Guest feed, paper reading, lazy preparation, processing, Introduction, chat,
  Connections, and arXiv links remain independent of accounts and libraries.
- `LIBRARY_ENABLED=false` publishes no library route or mobile control.
  `LIBRARY_WRITES_ENABLED=false` preserves list/change reads while PUT/DELETE
  fail with 503 `FEATURE_DISABLED`.
- Save is available to any active account without requiring a handle, current
  terms, or paper preparation.
- Library list, change, save, and remove paths perform no arXiv, PDF, GROBID,
  model, or preparation-queue work.
- No global save count or cross-account watermark is observable.

## Backend library model and API

Migrations `0006_library.sql` and `0007_per_user_library_revisions.sql` add
tombstone-capable library rows, a durable operation ledger, per-user sync
metadata, indexes, and shared mutation rate limiting. Revisions are allocated
transactionally within one account. The forward correction safely rebases any
initial global-clock data above a reset barrier, so pre-correction clients must
perform one unambiguous full refresh.

The feature-gated API publishes exactly:

```text
GET    /v1/me/library
GET    /v1/me/library/changes
PUT    /v1/me/library/{paper_id}
DELETE /v1/me/library/{paper_id}
```

List pagination uses an account revision fence and requires a final changes
pass. Changes are ascending, include removal tombstones, and never advance for
another account's activity. Tombstones are retained for 90 days; bounded
cleanup advances a per-user reset floor before deletion, and an older client
receives 410 `LIBRARY_SYNC_RESET_REQUIRED`.

Both mutation directions use one canonical client UUID. Exact replays return
the canonical row; reuse for another paper or intent returns 409
`LIBRARY_OPERATION_CONFLICT`. Operation recording, canonical mutation,
revision allocation, and rate-limit behavior are transactionally ordered.
Cleanup locks per-user metadata in deterministic UUID order before child rows,
avoiding its mutation race.

Every private outcome is `Cache-Control: private, no-store`. DTOs reject unknown
or malformed state, cursor, limit, revision, operation, header, body, and paper
values. Strict full-text policy masks summary capabilities without changing the
paper-node save relationship. The checked OpenAPI artifact includes all four
routes, bearer security, request/response schemas, headers, errors, examples,
and feature-gate descriptions.

## Mobile offline and identity behavior

Drift schema version 4 stores account-scoped library rows, canonical rollback
state, sync checkpoints, and a durable outbox. A local mutation and operation
ID commit in one transaction. The visible saved-state stream drives every
paper stage and To Read copy; saves are immediate, removals offer Undo as a new
operation, and pending/permanent sync states remain actionable.

The sync engine serializes per-paper work, reclaims interrupted sends after
restart, preserves sent operation IDs, overlays pending intent after full
replacement, applies changes transactionally, and retries retryable failures
with exponential backoff, positive jitter, and the server's full `Retry-After`
minimum. Saved paper metadata is pinned through ordinary public-cache eviction
and released by remove or scoped account cleanup.

Offline display and remote authorization use separate scopes. A persisted
account ID may display its cached rows while credentials refresh, but drain and
refresh require an active `/v1/me` profile verified for the exact current auth
epoch and account ID. If stored account A resolves to account B, A's rows and
outbox are cleared before B binds; no A operation can be sent with B's bearer,
and no B response can be committed beneath A.

The reader exposes one accessible “Save to To Read” control above the stage
pager, so Abstract, Introduction, and Connections share the same state. A guest
save retains one pending action through PKCE; incomplete profile onboarding is
not required for save. Failure retains an explicit retry path, while system
back clears the pending intent. The You branch provides an offline-first To
Read list, Read navigation, refresh, remove/undo, empty, offline, pending, and
error states. The Section 2.4 broad-launch enhancement added on 2026-08-03
keeps newest-saved as the default while adding local newest/oldest/title
sorting, title/author/arXiv/category search, and an exact category filter. The
controls operate only on the already-loaded account projection, so cached and
offline lists neither issue a new request nor lose pending state.

## Checks and acceptance evidence

The settled Phase 4 tree passed the following checks on 2026-07-31:

- [x] Rust workspace formatting, Clippy with warnings denied, unit,
  integration, documentation, and all-feature/all-target tests.
- [x] Code-first OpenAPI generation, checked-artifact byte comparison, four
  compatibility tests, route/security/header/error assertions, and diff check.
- [x] Dart formatting, full Flutter analysis, and the complete Flutter test
  suite.
- [x] Repository-integrated `./scripts/check.sh`.
- [x] Live PostgreSQL library migration, idempotency, privacy, tombstone/reset,
  and deterministic mutation-versus-cleanup locking tests.
- [x] Android account/library-enabled debug APK at
  `mobile/build/app/outputs/flutter-apk/app-debug.apk`.
- [x] iOS account/library-enabled simulator debug app at
  `mobile/build/ios/iphonesimulator/Runner.app`.
- [x] Real Keycloak Authorization Code + PKCE, JIT account mapping, and
  two-client library flow with a disposable verified account.
- [x] Independent write-disabled API: list remained available, mutation
  returned 503, and anonymous feed returned 200.
- [x] Holistic privacy, concurrency, idempotency, cache, feature-gate, and
  preparation-boundary audit with no unresolved P0/P1 finding.

The live two-client flow began at revision zero, saved and exactly replayed one
operation, synchronized it to client B, removed and exactly replayed from B,
delivered the tombstone to A, replayed the older accepted save without
regression, and converged both clients at revision 2. The disposable local and
provider identities were removed afterward.

The acceptance paper had three pre-existing jobs and processing stage `ready`
before the flow. It still had exactly three jobs and stage `ready` afterward,
proving that library operations scheduled no preparation. Focused regressions
also cover restart upload, offline retry, duplicate/conflicting operation IDs,
90-day reset, cache pinning, sign-out/account switch, stale HTTP completion,
delayed 401 replay, and the cold-restore A→B identity race.

## Exit-criteria ledger

- **Save/unsave updates immediately:** accepted by the shared Drift projection
  and reader/list widget tests.
- **Two devices converge:** accepted by deterministic cross-device tests and
  the live PKCE/API flow.
- **Offline save survives restart and syncs later:** accepted by persistent
  outbox recovery and network-recovery tests.
- **Duplicate delivery creates one canonical state:** accepted by service,
  live PostgreSQL, HTTP, and live-provider replay scenarios.
- **Tombstones and old-client reset converge safely:** accepted by live
  database retention/reset tests and mobile full-replacement overlay tests.
- **Saved metadata survives ordinary eviction:** accepted by Drift eviction,
  remove, and cleanup tests.
- **Write kill switch preserves reading:** accepted by independent live API and
  route-registration tests.
- **Library performs no preparation:** accepted structurally, by service/API
  tests, and by the unchanged live job/stage count.
- **Saved-paper sort/filter:** focused widget tests cover deterministic
  newest/oldest/title ordering, author search, category filtering, no-result
  recovery, live result semantics, 48-pixel controls, 200% text reflow, and
  `ActiveLibraryScope` isolation of query, category, sort, and scroll state.

## Known risks and later-phase boundaries

- Simulator builds and source/resource inspection do not replace final signed
  physical-device database, secure-store, offline/restart, accessibility, and
  callback checks.
- The mobile v0.0 refresh guard treats more than 1,000 pages as an inconsistent
  snapshot; the exact 100,000-row list ceiling is documented in the sync
  contract and is intentionally above the initial product scale.
- Phase 6 account deletion must align its cascade lock order with library
  tombstone cleanup and include a deterministic live concurrency regression.
- Public comments, UGC policy controls, moderation, and account deletion remain
  independently gated and are not made complete by this phase.
