# To Read library synchronization contract

The Phase 4 library is one account-owned set named `to_read`. It has no
folders, tags, priority, notes, read state, or public save counts. The server
is authoritative; mobile applies the same operations optimistically and uses
the change feed to converge across devices.

## Availability and authorization

The four routes are registered only when both `ACCOUNTS_ENABLED=true` and
`LIBRARY_ENABLED=true`. They require a valid OIDC bearer token mapped to an
active Pakperk account. A handle and terms acceptance are not prerequisites
for saving a paper.

`LIBRARY_WRITES_ENABLED=false` is an emergency read-only switch. It preserves
both library read routes and returns 503 `FEATURE_DISABLED` from PUT and
DELETE. Turning the library feature off removes all four routes; it does not
alter public paper reading.

Every response from `/v1/me/library` and its descendants, including errors,
has `Cache-Control: private, no-store`. Browser clients may send
`Authorization`, `Content-Type`, `Idempotency-Key`, `X-Request-Id`, and the
other documented v1 headers through configured CORS origins.

## Wire contract

```text
GET    /v1/me/library?state=to_read&cursor=&limit=
GET    /v1/me/library/changes?after_revision=&limit=
PUT    /v1/me/library/{paper_id}
DELETE /v1/me/library/{paper_id}
```

List responses are ordered by newest `saved_at`, then paper ID, and contain
only active items:

```json
{
  "items": [
    {
      "item": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "state": "to_read",
        "saved_at": "2026-07-31T12:00:00.000Z",
        "updated_at": "2026-07-31T12:00:00.000Z",
        "removed": false,
        "removed_at": null,
        "revision": 42,
        "last_operation_id": "0198f4da-383f-77f0-9404-e6d6614d26e1"
      },
      "paper": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "arxiv_id": "2401.12345v2",
        "title": "A bounded paper title",
        "abstract": "Bounded public arXiv metadata.",
        "authors": ["Ada Reader"],
        "primary_category": "cs.AI",
        "categories": ["cs.AI"],
        "published_at": "2026-07-01T00:00:00.000Z",
        "updated_at": "2026-07-02T00:00:00.000Z",
        "abs_url": "https://arxiv.org/abs/2401.12345v2",
        "pdf_url": "https://arxiv.org/pdf/2401.12345v2",
        "capabilities": {
          "metadata": true,
          "introduction": false,
          "chat": false,
          "connections": false
        }
      }
    }
  ],
  "next_cursor": null,
  "sync_revision": 42
}
```

`state` must be exactly `to_read`. `limit` is bounded by the API and cursors
are opaque: clients must return them unchanged and must not construct or
inspect them. The first page captures a committed, account-scoped
`sync_revision`; every `next_cursor` carries that revision fence, and every
later page repeats the same revision. Rows whose current canonical revision
advances beyond the fence are excluded from later pages. Because the server
stores only each paper's latest row, pagination is not an immutable historical
snapshot: a concurrently mutated item can disappear from or move across the
remaining pages. After exhausting the list, clients must request changes from
the first page's `sync_revision` and transactionally apply that delta. This
mandatory pass restores convergence. Mutations by other accounts never
advance this watermark and cannot be inferred by polling an empty change feed.

The change feed is ordered by ascending revision within the authenticated
account and includes active rows and removal tombstones:

```json
{
  "items": [
    {
      "item": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "state": "to_read",
        "saved_at": "2026-07-31T12:00:00.000Z",
        "updated_at": "2026-08-01T09:00:00.000Z",
        "removed": true,
        "removed_at": "2026-08-01T09:00:00.000Z",
        "revision": 43,
        "last_operation_id": "0198f9be-9b08-72ff-b946-62e68779ce36"
      },
      "paper": null
    }
  ],
  "next_after_revision": 43,
  "has_more": false,
  "sync_revision": 43
}
```

Clients persist `next_after_revision` only after applying the whole page in a
local transaction. When `has_more` is true they request the next page
immediately. When `has_more` is false, `next_after_revision` advances to the
page's committed `sync_revision`. Revisions may appear to skip because the
feed returns each paper's latest canonical state rather than every superseded
operation, but another account can never create a gap. The optional paper
projection lets a tombstone remain useful even if public metadata has since
been evicted.

## Mutations and idempotency

Both mutations require one `Idempotency-Key` header containing a canonical
UUID. PUT also requires strict JSON—the API rejects unknown fields—and the body
operation ID must exactly match the header:

```http
PUT /v1/me/library/0198f4d7-a4ce-7b40-8ee8-4f350350810c
Idempotency-Key: 0198f4da-383f-77f0-9404-e6d6614d26e1
Content-Type: application/json

{"operation_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","state":"to_read"}
```

DELETE has no request body; its operation ID is the header value. A newly
accepted operation receives a new monotonic revision even when its desired
state is already current. Revisions are allocated by a transactional per-user
fence, preserving commit order between that account's devices without
serializing or exposing activity from unrelated accounts. An active re-save
preserves `saved_at`; a save after removal begins a new saved interval.
Removing a never-saved paper produces a tombstone so an offline optimistic
save on another device is still defeated.

An exact replay returns the current canonical row. Reusing an operation ID for
a different paper or intent returns 409 `IDEMPOTENCY_CONFLICT`. Durable known
replays and conflicts are resolved before consuming a new mutation permit, so
a full rate-limit bucket cannot turn a previously accepted replay into 429.
Distinct operation IDs are serialized and last server acceptance wins, so an
ordinary cross-device race is not an error. Shared PostgreSQL rate limits are
keyed by the server-owned user UUID and return 429 with `Retry-After`.

## Retention and reset

Removal tombstones are retained for 90 days. Operation-ledger rows remain until
account deletion in v0.0, so an arbitrarily delayed operation replay can never
regress canonical state. Cleanup is bounded and advances a per-user
synchronization floor before removing old tombstones. A client whose
`after_revision` is below that floor receives 410
`LIBRARY_SYNC_RESET_REQUIRED`; it must transactionally replace its account
library from `GET /v1/me/library`, preserve/re-overlay unsent local operations,
record the returned `sync_revision`, then resume incremental changes.

The forward migration from the initial global Phase 4 clock rebases each
existing account's durable operation order into its own revision namespace.
It installs a per-user reset barrier above every possible legacy checkpoint,
so an already-synced pre-migration client receives one safe full-refresh reset
instead of ambiguously interpreting an old global number as a per-user one.
New accounts begin at revision zero and do not pay this migration cost.

## Metadata and preparation boundary

Library responses reuse only bounded paper-summary metadata already in
PostgreSQL. In strict full-text mode, any derived capability unsupported by
the recorded license is masked exactly as on the public paper routes. Listing,
changing, saving, and removing library items never fetch arXiv, download a PDF,
enqueue preparation, invoke GROBID, or call a model provider. Opening a saved
paper follows the ordinary Read route and its existing explicit preparation
boundary.

## Mobile convergence rules

- Drift is the visible source of truth; a save/remove and its outbox entry are
  written in one transaction.
- A full refresh persists the first list page's `sync_revision`, exhausts its
  cursor chain, then applies `/changes` from that saved revision before treating
  the local view as converged.
- Each refresh is bounded to 1,000 list or change pages (100,000 list rows at
  the mobile page size). Exceeding that v0.0 safety ceiling is treated as an
  inconsistent snapshot and retried instead of running an unbounded loop.
- One device serializes operations per `(user_id, paper_id)`. A newer unsent
  intent may supersede an older unsent one, but never rewrites a sent
  operation ID.
- Retryable network, 429, and 503 failures keep the optimistic state and retry
  with bounded exponential backoff, positive jitter, and `Retry-After`.
- Permanent validation/authorization failures reconcile with canonical server
  state and remain actionable to the reader.
- Sign-out and account switching clear account-owned library rows, sync state,
  and outbox operations while preserving the public paper cache.
- Library pins keep saved paper metadata out of ordinary public-cache eviction.
  Library refresh never preloads PDFs or derived content.

The code-first [OpenAPI artifact](openapi-v1.json) is the machine-readable
contract. This document records synchronization behavior that is intentionally
more detailed than the endpoint schema.
