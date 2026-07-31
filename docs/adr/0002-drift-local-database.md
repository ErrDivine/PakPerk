# ADR 0002: Drift local database

**Status:** Accepted — implementation pending Phase 2
**Date:** 2026-07-31

## Context

The demo stores JSON blobs in SharedPreferences. Production needs bounded,
queryable multi-page feed caching, saved-paper pinning, comment caches, drafts,
account-scoped state, schema migrations, transactions, and a durable sync
outbox. These cannot be safely managed as a collection of preference blobs.

## Decision

Use Drift over SQLite as the mobile content database. It owns relational public
cache data, saved-paper projections, comment cache, drafts, cache metadata, and
the retry outbox. SharedPreferences remains only for small scalar preferences
and selected restoration metadata. Authentication tokens are not stored in
Drift; they remain in platform secure storage.

The feed repository remains cache-first and stale-while-revalidate. Drift schema
migrations are explicit, public data may be retained across sign-out, and
account-owned rows and outbox records are cleared or scoped on sign-out and
account deletion.

## Consequences

- The app gains generated database code, migration tests, database lifecycle
  management, bounded cache eviction, and migration from legacy preferences.
- Feed cache entries become query/category/cursor-aware instead of a single
  initial-page JSON value.
- The outbox can safely persist idempotent save/unsave operations while offline;
  public comment drafts never auto-publish after reconnecting.
- Existing cached-first UI behavior is preserved while the data model becomes
  queryable and transactional.

## Security and operational implications

- SQLite contains no access tokens, refresh tokens, raw authorization material,
  or account credentials.
- Account-owned tables must be identified for logout/deletion cleanup; public
  paper metadata can remain available offline.
- Cache size, TTL, LRU eviction, and saved-paper pinning need metrics and tests
  to prevent unbounded local storage.
- Migrations must be forward-compatible, tested from prior supported schemas,
  and resilient to interrupted app upgrades.
