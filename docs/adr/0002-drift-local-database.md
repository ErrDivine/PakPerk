# ADR 0002: Drift local database

**Status:** Accepted — implemented in Phase 2
**Date:** 2026-07-31
**Implemented:** 2026-07-31

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

## Implemented shape

The production database uses the stable `pakperk_content.sqlite` filename and
currently has schema version 6. Foreign keys are enabled and the database uses
WAL mode. The schema contains:

- normalized paper, feed-query, and ordered feed-membership tables;
- generation- and arXiv-version-bound processing, Introduction, Connections,
  and anonymous chat caches;
- a bounded comment-page cache; and
- account-scoped library, draft, outbox, sync-state, and cache-metadata tables.
  Phase 4 activates the library subset only behind its feature gates; comment
  behavior remains disabled.

Feed rows are keyed by an opaque, versioned identity that includes the exact
category and limit. The first-page validator is stored with that query, while
cursor-page appends preserve it. Paper metadata is monotonic by arXiv version
and source update time. A newer paper version clears derived rows in the same
transaction, and processing-generation changes prevent late Introduction,
Connections, or chat responses from crossing a retry boundary.

The one-time legacy importer parses existing feed, paper, processing,
Introduction, Connections, and chat blobs with the ordinary model decoders,
imports and verifies accepted rows in one transaction, and removes bulk
preference keys only after that verification succeeds. A derived record is
accepted only when an individually cached paper proves the exact arXiv version,
the JSON explicitly carries a positive generation, and the corresponding
processing row for that generation was imported first. Chat additionally needs
an explicit session, paper, and arXiv envelope matching the exact feed/restored
route reader key and the anonymous session that existed when the importer was
constructed. It never mints or resamples an identity to label old chat, so
genuine unscoped v1 derived/chat blobs fail closed instead of borrowing newer
provenance. The marker is committed only while the complete captured bulk
snapshot and imported chat session remain unchanged, and cleanup compares each
key again before removal. Invalid, wrong-typed, and unbound rows are counted
without logging their content. A failed or raced transaction leaves the source
preferences in place and does not block startup. Under strict full-text policy,
public metadata is masked and all derived legacy records are discarded by
policy.

Eviction applies comment expiry, stale non-active feed membership, unpinned
paper LRU/TTL, and then expired or oldest unprotected derived generation
clusters under byte pressure. It protects the active reader window, restored
paper routes and chats, library pins, drafts, and pending outbox ownership.
Swipe-time maintenance enforces metadata-row and live SQLite-byte bounds
without vacuuming. Physical allocation includes the main database, WAL, and
shared-memory files; checkpointing and `VACUUM` run only during a
non-interactive lifecycle state.

`FeedPrefetchCoordinator` is separate from the screen and receives only a
feed-page remote interface plus the Drift persistence capability. Its defaults
are centralized (30-row pages, trigger at 10 remaining, 2 behind/6 ahead in the
readable window, 60 durable rows ahead, 500 metadata rows, 64 MiB, and a 7-day
metadata TTL). Query-local single-flight, snapshot obsolescence, bounded retry,
and cursor-cycle termination keep speculative work coherent. The narrowed
remote interface makes the no-prepare boundary structural rather than a caller
convention.

## Consequences

- The app has generated database code, migration tests, database lifecycle
  management, bounded cache eviction, and migration from legacy preferences.
- Feed cache entries become query/category/cursor-aware instead of a single
  initial-page JSON value.
- The schema persists idempotent save/unsave operations in an outbox while
  offline, and Phase 4 owns their guarded synchronization behavior. Public
  comment drafts remain distinct from the outbox and never auto-publish.
- Existing cached-first UI behavior is preserved while the data model becomes
  queryable and transactional.

## Security and operational implications

- SQLite contains no access tokens, refresh tokens, raw authorization material,
  or account credentials.
- Account-owned tables are structurally separated for logout/account-switch
  cleanup and later deletion; public paper metadata can remain available
  offline.
- Cache size, TTL, LRU eviction, saved-paper pinning, and lifecycle-safe
  physical compaction have focused metrics and tests.
- Migrations are explicit and tested from complete historical schema fixtures
  through version 6.
  Rebuildable pre-generation derived blobs are discarded during the version-3
  migration instead of being relabeled as current. Later migrations add
  synchronized-library state, account-bound comment caches/drafts and blocks,
  and remove the dormant reply column without weakening prior boundaries.
