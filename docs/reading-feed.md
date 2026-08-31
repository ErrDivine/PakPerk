# Authenticated reading-feed contract

**Status:** Plan 02 queue arbitration and recommendation handoff implemented
behind default-off server flags
**Contract baseline:** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`

This document defines the API and fail-closed client semantics for the To Read
First feature. The authenticated route, flags, snapshot repository, and
encrypted cursor are implemented; compatible-client rollout remains governed
by the independent enforcement switch. The public-feed separation is fixed by
[ADR 0007](adr/0007-public-discovery-and-authenticated-reading-feed.md).

## Availability and request

```http
GET /v1/me/reading-feed?recommendation_mode={optional}&category={optional}&cursor={optional}&limit={optional}
Authorization: Bearer <access-token>
```

| Query parameter | Type | Contract |
| --- | --- | --- |
| `recommendation_mode` | `recent \| following \| for_you \| explore`, optional | An explicit value wins. When omitted, the service uses the account's stored `preferred_discovery_mode`; if profile lookup is unavailable or fails, it safely falls back to `recent`. The effective mode is used only after this request proves the active queue empty and cannot override queue authority. |
| `category` | string, optional | Existing bounded arXiv category syntax. It scopes recommendations only; it never hides an active queue item or changes the active count. |
| `cursor` | string, optional | Opaque `reading_feed.v1` continuation returned by this exact account/query walk. |
| `limit` | integer, optional | Positive page size; default 20 and maximum 50. |

The route is registered only when all of the following server capabilities are
true:

```text
ACCOUNTS_ENABLED=true
LIBRARY_ENABLED=true
READING_FEED_ENABLED=true
```

`TO_READ_FIRST_ENFORCEMENT_ENABLED` is a separate rollout switch for making
this route canonical in supported signed-in clients. It requires
`READING_FEED_ENABLED`; it must not create a half-registered route.

The server policy and signed-client capability form this fail-closed rollout
matrix for authenticated sessions:

| Client enforcement capability | Server `enforcement` | Rendered result |
| --- | --- | --- |
| off | `shadow` | Legacy public discovery; compute and emit the closed shadow decision only. |
| off | `strict` | Legacy public discovery; this build is not an enforced client and cannot count toward universal adoption. |
| on | `shadow` | Legacy public discovery after a current-account/current-epoch response; this is the immediate rollback path. |
| on | `strict` | Authenticated queue-first surface. |

Before a strict-capable client has a current verified-account response, and on
an unavailable, malformed, prior-account, or prior-epoch response, it suppresses
public discovery and fails closed. Guests remain on public discovery. Changing
`strict` to `shadow` reactivates and revalidates the public preload; changing
`shadow` to `strict` deactivates public prefetch before publishing the account
feed. A server `strict` value does not upgrade an old or capability-off build,
so minimum-client/adoption approval remains a separate production gate. The
[production release-evidence procedure](runbooks/release.md#release-evidence-binding-scope)
requires the owner to supply one exact minimum-version, legacy-access-disable,
or advisory-until-threshold policy for a strict render; it defines no default
adoption threshold.

Every success and error from this route has:

```http
Cache-Control: private, no-store
Vary: Authorization
X-Request-Id: <request-id>
```

A successful response may also have an opaque `ETag`. It never inherits the
public feed's cache policy or cursor. A `304` authorizes representation reuse
only after the same local fail-closed predicates are rechecked; it is not fresh
proof that the queue is empty after a local mutation.

## Response schema

The response is a strict JSON object with no account identifier:

| Field | Type | Contract |
| --- | --- | --- |
| `enforcement` | `"shadow" \| "strict"` | Current server rollout policy. Compatible strict-capable clients render the authenticated surface only for `strict`; `shadow` keeps legacy discovery visible while computing the decision in the background. |
| `mode` | `"to_read" \| "recommendations"` | Decision made at the response snapshot. |
| `decision.policy_version` | `"queue_first_v1"` | Exact server queue-arbitration policy understood by this contract; unknown values fail closed in compatible clients. |
| `decision.library_revision` | non-negative integer | Account-scoped revision fence used by the decision and cursor. |
| `decision.active_to_read_count` | non-negative integer | Active queue count at the same snapshot. |
| `decision.queue_proven_empty` | boolean | True only for a successfully proven zero count. |
| `batch_id` | UUID or null | Page-scoped provenance for a persisted recommendation batch. Queue pages never have a batch; a recommendation page may have both a batch ID and `next_cursor`, and the continuation page may use a different batch ID. |
| `items` | array | At most the accepted page limit; item rules depend on `mode`. |
| `next_cursor` | string or null | Opaque continuation bound to account, mode, revision, query, key epoch, and expiry. |
| `server_time` | RFC 3339 UTC string | Server observation time; not queue authority by itself. |

Each item has the existing strict `PaperSummary` as `paper`, a mode-dependent
`queue`, and a closed `source` value:

| Mode | `queue` | `source` | Required invariant |
| --- | --- | --- | --- |
| `to_read` | `{state, saved_at, revision, save_source_kind}` | `"to_read"` | Paper is an active Inbox/Read next/Reading row for this account at the decision fence; `recommendation` is null. |
| `recommendations` | `null` | `"recent_v1" \| "following_v1" \| "for_you_v1" \| "explore_v1"` | Active count is zero at the decision fence, exclusions were applied, and `recommendation` contains the actual mode, immutable reason codes/label, and explanation availability. |

When `READING_FEED_ENABLED=true` and `RECOMMENDATIONS_ENABLED=false`, the only
eligible recommendation path is a persisted minimal `recent_v1` batch bound to
the same empty-library authority and final revision recheck. This keeps cursor
and reading-brief provenance safe without enabling Following, For You,
Explore, profile-derived reasons, explanations, or feedback routes. Its items
set `explanation_available=false`; configured enhanced batches set it to true
only when the recommendation-gated explanation route is available.

The decision tuple is internally consistent:

| `mode` | Active count | `queue_proven_empty` | Recommendation source |
| --- | ---: | ---: | --- |
| `to_read` | greater than zero | false | Must not be invoked. |
| `recommendations` | zero | true | May be invoked exactly once for the page. |
| no authoritative snapshot | unknown | never synthesized | Return `503 QUEUE_AUTHORITY_UNAVAILABLE`. |

Every authoritative row also requires
`decision.policy_version="queue_first_v1"`. Missing or unknown policy values
are not compatible queue authority and must follow the unavailable/fail-closed
path rather than being guessed from `mode` or the count.

The first page is produced by one SQL statement or one read-only repeatable-read
transaction. Counting and selecting through unrelated snapshots is invalid.

## To Read example

```json
{
  "enforcement": "shadow",
  "mode": "to_read",
  "decision": {
    "policy_version": "queue_first_v1",
    "library_revision": 128,
    "active_to_read_count": 1,
    "queue_proven_empty": false
  },
  "batch_id": null,
  "batch_metadata": null,
  "items": [
    {
      "paper": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "arxiv_id": "2401.12345v2",
        "title": "A bounded paper title",
        "abstract": "Bounded public arXiv metadata.",
        "authors": ["Ada Reader"],
        "primary_category": "cs.AI",
        "categories": ["cs.AI"],
        "published_at": "2026-07-01T00:00:00Z",
        "updated_at": "2026-07-02T00:00:00Z",
        "abs_url": "https://arxiv.org/abs/2401.12345v2",
        "pdf_url": "https://arxiv.org/pdf/2401.12345v2",
        "capabilities": {
          "metadata": true,
          "introduction": false,
          "chat": false,
          "connections": false
        }
      },
      "queue": {
        "state": "inbox",
        "saved_at": "2026-07-31T12:00:00Z",
        "revision": 126,
        "save_source_kind": "title_search"
      },
      "source": "to_read",
      "recommendation": null
    }
  ],
  "next_cursor": null,
  "server_time": "2026-08-19T12:00:00Z"
}
```

The Read feed orders queue items by `saved_at ASC, paper_id ASC`. The existing
library-management list may keep its newest-first order.

## Recommendation example

```json
{
  "enforcement": "shadow",
  "mode": "recommendations",
  "decision": {
    "policy_version": "queue_first_v1",
    "library_revision": 129,
    "active_to_read_count": 0,
    "queue_proven_empty": true
  },
  "batch_id": "0198f4d7-a4ce-7b40-8ee8-4f350350830e",
  "batch_metadata": {
    "profile_revision": 7,
    "feedback_revision": 12,
    "algorithm_version": "recommendations_v1",
    "recommendation_policy_version": "weighted_v1"
  },
  "items": [
    {
      "paper": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350820d",
        "arxiv_id": "2501.01010v1",
        "title": "A discovery candidate",
        "abstract": "Bounded public arXiv metadata.",
        "authors": ["Grace Researcher"],
        "primary_category": "cs.LG",
        "categories": ["cs.LG"],
        "published_at": "2026-01-03T00:00:00Z",
        "updated_at": "2026-01-03T00:00:00Z",
        "abs_url": "https://arxiv.org/abs/2501.01010v1",
        "pdf_url": "https://arxiv.org/pdf/2501.01010v1",
        "capabilities": {
          "metadata": true,
          "introduction": false,
          "chat": false,
          "connections": false
        }
      },
      "queue": null,
      "source": "for_you_v1",
      "recommendation": {
        "mode": "for_you",
        "reason_codes": ["feedback_category_affinity"],
        "reason_label": "Based on your relevance feedback",
        "explanation_available": true
      }
    }
  ],
  "next_cursor": null,
  "server_time": "2026-08-19T12:00:00Z"
}
```

Recommendations exclude active rows, retained removal tombstones, duplicate
base arXiv identities, and papers unavailable under the active publication
policy. Exclusions are bounded database anti-joins, not an unbounded in-memory
list.

`batch_metadata` is present exactly when `batch_id` is present. It repeats the
persisted profile and feedback revision fences plus the algorithm and scoring
policy versions that produced that immutable batch. Queue pages and unbatched
chronological fallbacks return both fields as null. Mobile may reuse an
account-scoped cached batch only when this entire tuple, the library revision,
the selected mode, and the enforcement policy still match fresh server
authority.

Recommendation batches are scoped to the exact chronological candidate page
authorized by one queue-empty snapshot. Cursor continuation re-proves queue
authority and can therefore return a different immutable `batch_id`; compatible
clients accept that page only when enforcement, queue decision/library revision,
effective recommendation mode, and `batch_metadata` remain compatible. After
appending pages in memory, clients retain each item's originating batch ID and
its zero-based page-local reranked position for explanations, feedback, saves,
and interaction events. They never serialize a heterogeneous merged cursor walk
under one batch ID or cache it as though it were a single batch.

## Feedback, profile, and batch revision fences

Recommendation feedback never decides queue eligibility. An accepted
`relevant`, `not_relevant`, or `dismissed` action advances an independent,
monotonic feedback revision. Every account batch persists that revision and
rechecks it, the optional research-profile revision, the library revision, and
proven-empty authority before both persistence and serving. A changed feedback
or profile revision supersedes old `building` or `ready` batches; replay cannot
make one current again.

The same-snapshot candidate query excludes every retained exact paper identity
and base arXiv identity with feedback. `not_relevant` and `dismissed` are also
hard reranking exclusions. Unexpired qualified impressions are not proof of
dislike or completion: they contribute only a bounded repeat-exposure penalty.

Positive feedback creates category affinity only when personalization was
already enabled. It advances the profile revision and stores the paper's
primary category with `source=feedback`; it never becomes an explicit follow.
For You may use separately labelled `feedback_affinity` and
`inferred_affinity` sources and matching reason codes. Following consumes only
explicit categories, topics, and authors, so its explanations cannot claim
`you follow` for feedback-derived or inferred material. With personalization
off, no new feedback-derived category affinity is created, while explicit
negative feedback remains an exact-paper exclusion.

`GET /v1/discovery/profile/interests` and the profile export separate
`explicit`, `feedback`, and `inferred` groups. They do not expose a
chronological raw feedback or interaction ledger. Profile Reset All deletes
raw recommendation feedback, its revision fence, interactions, batches, and
non-explicit interests; account deletion cascades the same account-owned data.

The explanation and item `reason_codes` schemas are closed. The 14 supported
codes include `saved_query_match`; its corresponding closed candidate source is
`saved_query`. That pairing means a real account-owned saved query matched the
paper and does not claim the user explicitly follows a topic or author.

## Reading-brief authority

Reading briefs use only the dedicated authenticated create/current and progress
surfaces under `/v1/me/reading-briefs`, including
`/v1/me/reading-briefs/{brief_id}/progress`. A reading-feed request may include
the account-owned `brief_id`; the response then includes a nullable read-only
`brief` summary `{id,position,total,complete}` only when that brief's exact
library revision and queue/recommendation authority match the returned page.
This is not a second creation, selection, cursor, or progress authority: the
feed cannot update the brief, and an absent, mismatched, or unavailable binding
returns `brief=null` without weakening the authoritative feed. Brief creation
uses the stored profile `brief_size` (15–25, default/fallback 20). An explicit
request recommendation mode wins;
when omitted, the stored `preferred_discovery_mode` is used, with a safe
`recent` fallback if the profile cannot be read. These preferences select only
eligible brief material and never change queue authority. A queue brief may
summarize active work and a
discovery brief may be created only from proven-empty authority, but reading,
progressing, completing, dismissing, or expiring a brief cannot change or prove
the active Library count. Only a fresh reading-feed snapshot and acknowledged
canonical Library mutations can do that.

## Cursor and revision behavior

The cursor uses a new cryptographic purpose, `reading_feed.v1`, and binds:

- authenticated local user ID;
- `to_read` or `recommendations` mode;
- library revision fence;
- queue or recommendation ordering coordinates;
- category/effective recommendation query and page-size policy;
- cursor key epoch/version and expiry.

To Read coordinates are `saved_at, paper_id`. Before every continuation the
server compares the current account revision with the cursor fence. A mismatch
returns `409 READING_FEED_CURSOR_STALE`; the client discards the cursor and
restarts page one. Cross-account or wrong-purpose cursors are invalid and never
reveal whether another account exists.

## Fail-closed mobile authority

Mobile models authority as a closed state, not a Boolean:

```text
unknown | localNonEmpty | pendingSave | serverConfirmedNonEmpty |
serverConfirmedEmpty | stale
```

The rendering truth table is authoritative:

| Authentication | Local active rows | Pending save/import | Server/sync authority | Visible result |
| --- | ---: | ---: | --- | --- |
| Signed out | n/a | n/a | n/a | Existing public discovery feed. |
| Signed in | greater than zero | any | any | To Read; recommendations suppressed. |
| Signed in | zero | yes | any | Pending-save/To Read transition; recommendations suppressed immediately. |
| Signed in | zero | no | unknown | Checking or unavailable; no recommendations. |
| Signed in | zero | no | confirmed nonempty | Fetch/render server To Read only. |
| Signed in | zero | no | confirmed empty at current revision under `queue_first_v1` | Recommendations permitted. |
| Signed in | stale cached rows | no | sync reset required | Full sync required; no recommendations. |
| Signed in | zero | no | auth/provider unavailable | Fail closed; no recommendations. |
| Signed in, final remove pending | zero locally | no save | remove not acknowledged and empty not reconfirmed | Finishing queue; no recommendations. |
| Account/auth epoch changing | any | any | response from old scope | Discard response and reset to unknown. |

A recommendation response is publishable only if all predicates still hold:

```text
signed in
AND response.mode == recommendations
AND response.decision.policy_version == queue_first_v1
AND response.decision.queue_proven_empty == true
AND response.decision.active_to_read_count == 0
AND local authority == serverConfirmedEmpty
AND no pending save/import/remove conflict exists
AND account scope and authentication epoch match request start
AND response library_revision remains the accepted decision fence
```

Any failed predicate cancels/deactivates recommendation prefetch, clears its
continuation, retains ordinary public metadata cache rows, and restarts queue
arbitration. Offline or cached state can prove nonempty, but only a current
server decision can prove empty.

## Stable failures

Failures use the existing strict error envelope:

```json
{
  "error": {
    "code": "QUEUE_AUTHORITY_UNAVAILABLE",
    "message": "The To Read queue could not be verified.",
    "retryable": true,
    "request_id": "0198f500-0000-7000-8000-000000000099"
  }
}
```

The feature-specific failures are `READING_FEED_CURSOR_STALE` (409, retry from
page one) and `QUEUE_AUTHORITY_UNAVAILABLE` (503, retryable). Existing auth,
rate-limit, feature-disabled, and library-sync-reset errors retain their current
meanings.

Contract fixtures live under
`backend/apps/api/tests/fixtures/to_read_first/`. The checked OpenAPI now
publishes this operation, while runtime registration remains conditional on
accounts, library, and reading-feed capabilities.

## Operations and staged evidence

The design targets are at least 99.9% monthly reading-feed availability and a
cached first-page server p95 of at most 250 ms. Queue-first correctness is a
100% invariant: any observed recommendation without authoritative empty-queue
proof is severity 1. These are objectives until protected staging and
production observations establish them; repository tests do not claim measured
service performance.

Enable `READING_FEED_ENABLED` in staging only after paper resolution and any
independently selected search/import capability have completed their own gates.
Keep `TO_READ_FIRST_ENFORCEMENT_ENABLED=false` while proving all of the
following against the release-shaped database and API topology:

- active queues return FIFO To Read items and never invoke recommendations;
- only a repeatable-read snapshot that authoritatively counts zero may return
  recommendations, with active-library items excluded;
- stale, wrong-purpose, and cross-account cursors fail closed without exposing
  account state;
- queue mutations, cursor continuation, count, mode, and page stay revision
  consistent; and
- success and error responses remain private/no-store and authorization-varying.

Compatible mobile builds use this exact flag pairing as shadow mode: they keep
rendering legacy public discovery, but run the account-scoped queue-authority
controller and authenticated reading-feed request in the background. The only
new mobile event is `reading_feed_shadow_decision`. Its schema is closed to the
shadow decision, queue-authority enum, constant legacy decision, closed server
policy, one decision-agreement boolean, and offline boolean. It accepts no account, paper,
cursor, category, query, title, URL, token, count, or free-form error value.
Compare these aggregates with the server's `pakperk.reading_feed.decisions`
metric before exposing the new surface. Shadow telemetry is diagnostic only;
its absence must never make the product available or weaken fail-closed policy.

The production alert `reading-feed-authority-unavailable` pages on any exact
`ERROR` message `authenticated reading feed could not prove queue authority`
from `pakperk_api::routes::reading_feed` (greater than zero in five minutes,
held for 60 seconds). Missing data is healthy. The production and staging-copy
policies must keep only closed labels such as environment, service, severity,
Rust namespace, and the fixed message; never add account, cursor, category,
query, title, URL, token, paper, or arXiv identifiers. Exercise a privacy-safe
staging canary and page route before enforcement. See the
[observability runbook](runbooks/observability.md#verification-and-alerts).

Enable enforcement only after compatible signed clients pass the queue-authority
truth table, the minimum-supported-client policy is approved, and the release
record binds the SLO observation, invariant canary, alert delivery, privacy
scan, rollback exercise, and accountable approvals. Rollback first closes
enforcement and then the reading feed. It leaves the public discovery feed,
library reads, and additive migrations 11 through 18 in place.
