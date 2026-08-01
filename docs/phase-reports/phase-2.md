# Production v0.0 Phase 2 report

**Phase:** Drift cache and feed prefetch
**Status:** Complete
**Implementation snapshot:** 2026-07-31
**Starting commit:** `d0083f9`

This report records the accepted Phase 2 implementation. It does not claim that
accounts, synchronized library operations, comments, moderation, or the
Production v0.0 release are complete.

## Scope and preserved invariants

- Bulk public content moved behind a Drift/SQLite `LocalStore`; anonymous
  identity and navigation restoration remain small SharedPreferences values.
- Startup stays cache-first. A valid migrated or existing device feed can
  produce the first readable frame without network access, with the bundled
  corpus retained only as the resilience fallback.
- Prefetch has a feed-only remote interface. It cannot call paper preparation,
  processing, Introduction, chat, Connections, arXiv, PDF, or model providers.
- Strict full-text masking applies before public content enters or leaves the
  device cache. Production persistence does not weaken the server policy.
- Paper freshness is monotonic by arXiv version and then source update time.
  Derived records are scoped to the current arXiv version and processing
  generation so late network responses cannot restore stale capabilities.
- No credential or authorization field exists in the Drift schema. Phase 2
  adds no login behavior and stores no access or refresh token.

## Relational device cache

The stable production database is `pakperk_content.sqlite`. The accepted Phase
2 snapshot introduced schema version 3; the current production tree is schema
version 6 after the library and comment phases extended the same explicit
migration chain. Foreign keys and WAL remain enabled. Its tables cover cached papers,
feed queries and ordered membership, processing, Introductions, Connections,
comment pages, anonymous chats, library projections, drafts, a sync outbox, and
cache metadata.

The account-facing tables are foundations only. Accounts, library, and comments
remain disabled until their complete later phases land. Library tombstones are
deliberately independent of public paper-row lifetime, while active library
rows project to `cached_papers.pinned_by_library` for eviction protection.

Feed persistence is exact by category and page limit. Paper rows, feed
membership positions, cursor, refresh time, and the first-page validator are
committed transactionally. Cursor pages append membership without erasing that
validator. Missing, corrupt, or gapped membership invalidates its validator
instead of allowing a false `304` to certify an incomplete page.

Paper metadata refuses an older arXiv version, an older update within one
version, or an attempt to bind an existing stable paper ID to another arXiv
work. A real metadata advance clears processing, Introduction, Connections,
and anonymous chat rows atomically. Derived writes capture the expected paper
version, compare their processing generation, and reject late responses after
either boundary advances.

Anonymous chats are keyed by `(session_id, reader_key)`, carry paper-version
and processing-generation context, and expire. Anonymous identity rotation
clears cached chats and restorable chat identifiers before committing the new
identity, preventing old-session content from becoming readable by a new
session.

## Migration from SharedPreferences

The one-time importer recognizes the previous feed, paper, processing,
Introduction, Connections, and chat keys. It uses existing model parsers,
imports accepted rows in one transaction, verifies the result, writes a Drift
migration marker, and only then removes the legacy bulk keys. Paper metadata
can be recovered independently. Derived rows require an exact individually
cached arXiv version plus an explicitly serialized positive generation, and
children require a successfully imported processing row at that generation.
Chat also requires explicit session/paper/arXiv fields matching the exact
feed/restored-route reader key and the anonymous session sampled when the
importer was constructed. A concurrently created or later session cannot lend
provenance to older chat. Before committing the marker, the importer rechecks
the complete immutable bulk-preference snapshot and any imported chat's
session; cleanup removes a key only while its value still matches that
snapshot. Consequently, source mutation or session rotation rolls back without
data loss, frozen unscoped v1 derived/chat blobs are counted as unbound and
discarded, and only a fully bound transitional record can migrate. Wrong-typed,
corrupt, and unbound values are handled without logging their contents. If
parsing or transaction verification fails, startup continues and the source
preferences remain available for a future retry.

The Drift schema has in-place migration tests built from complete frozen
historical fixtures. Version 2 adds feed entry counts, conditional-feed
validators, and anonymous chat persistence. Version 3 adds processing-
generation context. Rebuildable derived rows that predate that context are
deleted rather than inaccurately relabeled. Versions 4–6 extend synchronized
library and account-bound comment state and remove the dormant reply column.
Strict-policy import retains masked metadata but discards every derived
full-text and chat record.

## Predictive feed coordinator

`FeedPrefetchCoordinator` runs from committed vertical page changes and keeps
all production tuning values in `FeedPrefetchConfig`:

| Setting | Default |
|---|---:|
| Remote page size | 30 |
| Load trigger | 10 remaining papers |
| Readable window | 2 behind / 6 ahead |
| Durable target | 60 ahead |
| Metadata row cap | 500 papers |
| Live/physical database target | 64 MiB |
| Metadata TTL | 7 days |
| First comment-page TTL | 5 minutes |
| Eviction delay | 500 ms |

The coordinator repairs metadata for the readable window, records the current
paper access, and starts cursor fetches only when the remaining tail reaches the
trigger. One request is in flight per query. Pages are deduplicated by stable
paper ID without regressing arXiv versions, and duplicate-heavy pages continue
until the durable target is actually present or pagination ends.

Category changes and authoritative same-query snapshot replacements cancel or
logically obsolete old work. Cyclic cursors and no-progress pages terminate.
Network failure leaves existing cards readable and schedules bounded
exponential backoff with jitter; a committed page advance or connectivity
recovery resets the retry state. Prefetched cursor pages update the controller
only while their query and snapshot generation are still current.

## Bounded eviction and telemetry

Low-priority eviction removes expired comment pages, stale non-active feed
membership, unpinned LRU/TTL paper rows, then expired and oldest unprotected
derived generation clusters when byte pressure remains. The current paper,
immediate reader window, restored routes and chats, active library pins, drafts,
and pending outbox ownership are protected. Row count and live SQLite page bytes
are enforced during ordinary maintenance. Physical usage includes the database,
WAL, and shared-memory files; checkpointing and `VACUUM` are single-flight and
run only after the app enters a non-interactive lifecycle state.

Prefetch telemetry has a closed numeric shape for request, success, failure,
deduplication, next-paper hit/miss, blank-card, cache row/byte, and readable-time
events. It has no string attributes, preventing titles, abstracts, authors,
categories, comments, cursors, and raw identifiers from being attached.

## Conditional feed transport

The Rust feed endpoint returns an opaque weak ETag derived with SHA-256 over
the complete query representation and every public response field. The tag
does not expose database IDs or timestamps directly. Successful and unchanged
responses include:

```text
ETag: W/"pp-feed-v1-..."
Cache-Control: public, max-age=60, stale-while-revalidate=300
```

`If-None-Match` supports weak comparison, wildcards, lists, repeated header
fields, and quoted opaque values. Malformed or over-limit input falls back to
an unconditional response. A match returns an empty `304` with the same cache
headers. CORS permits `If-None-Match` and exposes `ETag`, and OpenAPI documents
the request header and both `200` and bodyless `304` responses.

The mobile client sends a stored validator only for a matching first-page
query. A `304` republishes the exact cached page and updates its refresh time;
a response that omits `ETag` retains the validator used for that request. An
orphan validator without a readable page is repaired with one unconditional
request. Network failure continues to serve the exact cached query, including
an intentionally empty category result, rather than leaking the all-feed page.

## Verification evidence in the tree

Focused suites cover:

- complete historical schema migration, transactional legacy import and
  rollback, exact version/generation/session provenance, frozen unbound v1
  rejection, strict-policy migration, and offline startup from imported
  content;
- exact feed queries and validators, monotonic arXiv metadata, version- and
  generation-safe derived writes, anonymous-session isolation, eviction
  ownership, row/live-byte bounds, and lifecycle-only physical compaction;
- mobile ETag parsing, `304` handling, conditional repository repair, exact
  category fallback, and query cancellation;
- the >=95% sequential cache-hit criterion, readable windows, single-flight
  requests, durable unique-paper targets, cancellation, cursor-cycle guards,
  retry/backoff, eviction, content-free telemetry, and the feed-only prefetch
  boundary; and
- backend ETag identity, invalidation, RFC-compatible matching, empty `304`
  responses, CORS, OpenAPI, and a PostgreSQL-backed route scenario when
  `TEST_DATABASE_URL` is provided.

## Final acceptance record

The settled Phase 2 tree passed:

- [x] Rust formatting, workspace Clippy with warnings denied, workspace tests,
  and deterministic OpenAPI generation/compatibility checks.
- [x] Dart formatting and Flutter analysis with no issues, plus all 231 Flutter
  tests, including the file-backed 64 MiB compaction scenario.
- [x] The repository-integrated `./scripts/check.sh` command.
- [x] `flutter build apk --debug`.
- [x] `flutter build ios --simulator --debug`.
- [x] Android manifest XML and iOS plist host parsing checks.

The PostgreSQL-backed ETag route scenario remains part of the workspace suite
and runs when `TEST_DATABASE_URL` is configured. The local acceptance run did
not claim a live database exercise when that opt-in URL was absent.

Native builds use the official SQLite 3.53.3 amalgamation vendored at
`mobile/third_party/sqlite/sqlite3.c` through the pinned Dart package's source
hook, eliminating a release-build download dependency. The audited upstream
archive SHA3-256 is
`d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9`; the
vendored `sqlite3.c` SHA3-256 is
`28e484abdaa43630e34040ef6ed92be973a1ad54107803d8af5145b889c23ed7`.

## Exit-criteria mapping

- **Cached feed opens offline after migration:** implemented by startup waiting
  for the non-blocking importer before choosing Drift or bundled content;
  covered by the migration/startup tests.
- **Normal sequential test reaches >=95% next-card hits:** the deterministic
  100-paper scenario asserts the ratio and records only its first transition as
  a miss.
- **No duplicate request during rapid swipes:** the per-query single-flight
  test asserts one remote call and a deduplication event.
- **Maximum cache bounds:** independent row/live-byte tests and a file-backed
  physical-allocation test cover eviction and lifecycle-safe compaction.
- **Saved-paper pin exists before library UI:** the schema and account-cache DAO
  project active library rows to the paper pin while retaining tombstones after
  public metadata eviction.
- **Preparation count is unchanged by prefetch:** the prefetch adapter exposes
  only `getFeed`; its boundary test asserts zero prepare, processing,
  Introduction, chat, Connections, paper-repair, and arXiv lookup calls.

These mappings identify the implementation and tests for every Phase 2 exit
criterion. Phase 2 is accepted; later production phases remain separate gates.
