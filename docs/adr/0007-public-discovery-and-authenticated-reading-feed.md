# ADR 0007: Separate public discovery from the authenticated reading feed

**Status:** Accepted and implemented behind default-off runtime rollout gates
**Date:** 2026-08-19
**Historical baseline:** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`
records the pre-implementation behavior described in the opening context.

## Context

Pakperk currently exposes `GET /v1/feed` as an anonymous chronological/category
feed. It is always registered, uses an opaque public-feed cursor, and returns
`Cache-Control: public, max-age=60, stale-while-revalidate=300`. Signed-in
clients also have an account-owned `to_read` set with idempotent mutations,
per-user revisions, tombstones, and private synchronization routes.

Making the public route account-aware would combine incompatible authority and
cache boundaries. It could put private queue decisions behind a public cache,
break guest and old-client behavior, and make it unclear whether an empty or
unavailable account queue authorizes recommendations.

## Decision

Pakperk will retain two distinct feed semantics:

- `GET /v1/feed` remains the public discovery feed. Its existing wire shape,
  anonymous availability, public cache policy, cursor purpose, and role as a
  source of chronological recommendations remain compatible.
- `GET /v1/me/reading-feed` will be the authenticated, account-scoped feed. It
  becomes the canonical Read feed for a compatible signed-in client only after
  its default-off rollout gates are enabled. Every response and error is
  private and non-storeable.

The authenticated route decides its mode from one committed database snapshot:

```text
active To Read count > 0
    => mode = to_read
    => every returned item is an active row for that account

active To Read count = 0
    => mode = recommendations
    => recommendations may be returned
```

Database, authentication, revision, or synchronization uncertainty is not an
empty queue. The route fails closed instead of returning recommendations when
it cannot prove the decision.

The client applies an additional local gate. A recommendation response may be
published only when its account and authentication epoch still match, it says
`mode=recommendations`, the local authority is still `serverConfirmedEmpty`,
and no pending save, removal transition, import intent, local active row, or
sync-reset conflict appeared after the request began. Otherwise the response is
discarded and arbitration restarts.

The authenticated cursor has its own cryptographic purpose and is bound to the
local account, feed mode, library revision, query, page-size policy, key epoch,
and expiry. A library revision change makes continuation stale; the server
returns `409 READING_FEED_CURSOR_STALE` and the client restarts at page one.

The queue policy remains above a transport-independent recommendation source.
The first source may adapt the current chronological paper query, but a
recommender never decides whether it is allowed to run.

The feature stays in the existing Rust/Axum API and PostgreSQL modular
monolith. It does not create a service, database, broker, worker path, or mobile
connection to arXiv. Saving, listing, importing, or vertically prefetching
metadata never initiates paper preparation.

The complete wire and state-machine contracts are recorded in
[Authenticated reading feed](../reading-feed.md), [Manual paper search and
import](../paper-import.md), and [To Read First deployment
boundaries](../deployment-boundaries.md).

## Consequences

- Guest reading and clients that have not adopted the authenticated route keep
  the current public feed behavior.
- A signed-in queue-first rollout cannot be considered enforced while supported
  old clients can continue to use only the public feed. Minimum-version or
  equivalent rollout policy must be resolved before strict enforcement.
- The API needs a snapshot-consistent queue decision, account/revision-bound
  cursors, recommendation exclusions, stable errors, private cache headers, and
  invariant tests.
- Mobile must model queue authority as a state rather than `isEmpty`, suppress
  recommendation fetching/rendering while authority is unknown, and cancel
  late work across account or authentication changes.
- Public paper summaries may continue to use the ordinary metadata cache, but
  a cached recommendation page is never durable proof that an account queue is
  empty.

## Security and operational implications

- Personalized responses use `Cache-Control: private, no-store` and
  `Vary: Authorization`; readable user identifiers are absent from bodies,
  entity tags, cursors, logs, and metrics.
- Queue-authority failures return a typed retryable error and never silently
  downgrade to public discovery for a signed-in client.
- All new routes and strict enforcement are independently default-off, with
  validated dependencies on the existing account and library gates.
- Rollback disables the authenticated feature and restores the old client path;
  it does not mutate or reinterpret the public feed or existing library wire
  contract.
