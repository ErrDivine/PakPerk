# To Read First Phase 0 execution report

**Phase:** Baseline, ADR, contracts, and test scaffolding
**Status:** Ready for architecture review
**Recorded:** 2026-08-19
**Branch at start:** `main`
**Starting commit:** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`
**Commit subject:** `V0.1 (almost) complete.`

The exact starting commit was captured with `git rev-parse HEAD` before Phase 0
edits. The shared workspace already contained uncommitted work, including the
supplied root implementation plan and unrelated mobile/docs-site changes; that
working-tree state is not part of the pinned Git commit. This phase preserves
those changes and does not treat them as baseline evidence.

## Scope and decisions

- Added [ADR 0007](../adr/0007-public-discovery-and-authenticated-reading-feed.md),
  which preserves public discovery and gives the authenticated route sole
  responsibility for account queue arbitration.
- Froze the authenticated response shape, snapshot invariant, cursor fence,
  fail-closed queue-authority states, acceptance predicate, and truth table in
  [Authenticated reading feed](../reading-feed.md).
- Froze strict title-search and exact-import requests, successful responses,
  URL/network boundaries, idempotency, recovery, and stable errors in
  [Manual paper search and import](../paper-import.md).
- Recorded current and planned migration, backend flag, mobile flag, component,
  and rollout facts in [To Read First deployment
  boundaries](../deployment-boundaries.md).
- Added JSON examples under
  `backend/apps/api/tests/fixtures/to_read_first/` and a zero-test Rust
  integration target. Later implementation phases can bind the same fixtures
  to Rust serializers, checked OpenAPI, and Dart parsers without adding a
  placeholder production path.

## Baseline evidence

The following source facts were rechecked at the pinned commit:

- `backend/apps/api/src/app.rs` always registers `GET /v1/feed`; account and
  library routes are registered only behind their existing gates. It registers
  no reading-feed, paper-search, or library-import route.
- `backend/apps/api/src/routes/feed.rs` uses the public cache policy
  `public, max-age=60, stale-while-revalidate=300` and the generic paper feed
  repository. It does not arbitrate against an account library.
- `backend/apps/api/src/config.rs` contains six feature booleans—accounts,
  library, library writes, comments, comment creation, and account deletion—
  and none of the planned To Read First flags.
- `mobile/lib/app/feature_flags.dart` contains only accounts, library, comments,
  and opening-motion compile-time booleans, each default-off.
- `backend/migrations/` ends at `0010_user_reports.sql`; `.env.example` asserts
  `PAKPERK_MIGRATION_EXPECTED_VERSION=10`. Migration 0011 is planned, not
  present.
- `docs/library-sync.md` already defines the authoritative account-owned
  `to_read` set, per-user revision, idempotent operations, tombstones, private
  cache policy, and no-preparation boundary that the new contract reuses.
- `docs/openapi-v1.json` includes `/v1/feed` but none of the three planned
  operations. Phase 0 intentionally does not modify that generated contract.

## Runtime impact

None. Phase 0 adds documentation, contract examples, and an empty integration
test target only. It does not:

- register or modify an API route;
- add a migration, table, index, or persisted field;
- parse a new feature flag or change a default;
- alter OpenAPI or generated docs-site files;
- change mobile code or configuration;
- change the public feed, library sync, worker, or preparation behavior.

## Checks run

The following focused checks passed on 2026-08-19:

```bash
for f in backend/apps/api/tests/fixtures/to_read_first/*.json; do
  jq empty "$f"
done
git diff --check
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
cargo test --manifest-path backend/Cargo.toml --locked \
  -p pakperk-api --test to_read_first_contract_scaffold
```

The scaffold test target compiled and ran zero tests as intended: `0 passed; 0
failed; 0 ignored`. Compilation reported two pre-existing/concurrent unused
imports in `backend/apps/api/src/routes/mod.rs`; they are outside this Phase 0
changed-path set and did not fail the focused command. Repository-wide release
evidence is not implied by these documentation/scaffold checks.

A read-only baseline assertion also checked the exact commit tree: all ten
migration names were present in order, `.env.example` expected version 10, and
`git grep` found none of the five planned flags or three planned route paths.
A focused relative-link check resolved every local link in the new/updated
Markdown files, and a trailing-whitespace scan passed for the full Phase 0
changed-path set.

## Exit review

- **Starting revision pinned:** complete; the full SHA is recorded above and in
  the ADR/contract documents.
- **Architecture and public/private boundary:** documented and ready for human
  approval.
- **Queue authority and API semantics:** frozen by the linked contracts.
- **Current migrations and feature flags:** confirmed separately from planned
  names.
- **No runtime behavior changed:** satisfied by the changed-path inventory and
  focused checks.

Phase 1 or later implementation must not be described as started by this
report. The Phase 0 exit becomes accepted only when its architecture review is
approved.
