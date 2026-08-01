# ADR 0005: Shared PostgreSQL rate limits

**Status:** Accepted — implemented through Phase 6
**Date:** 2026-07-31

## Context

The demo's in-process limiting is not consistent when API replicas scale out.
Authentication, saves, public comments, reports, profile mutation, deletion,
and expensive paper operations require enforcement that is shared by every API
instance. Introducing Redis or another network service for this milestone would
violate the modular-monolith operational boundary without a demonstrated need.

## Decision

Use PostgreSQL-backed shared rate-limit buckets, implemented as atomic
`INSERT ... ON CONFLICT ... DO UPDATE` operations for fixed or sliding windows.
PostgreSQL remains the source of truth alongside the existing leased jobs and
synchronization records. Apply edge reverse-proxy limits as an additional
coarse abuse control, not as the sole application limit. Return the stable
`RATE_LIMITED` error and `Retry-After`.

Initial buckets cover comment creation (user and keyed request origin), comment
edits, reports (user, target, and keyed request origin), profile updates,
library mutations, account deletion, and anonymous preparation/chat. The
public preparation/chat limiter always consumes a keyed origin bucket and may
also consume an anonymous-session bucket; it never relies only on the
client-supplied session ID.

## Implementation status

Phase 3 adds the shared PostgreSQL bucket table, atomic fixed-window repository,
bounded cleanup operation, and the first `profile_update` per-user bucket. A
denied profile update maps to the stable `RATE_LIMITED` error and a
delta-seconds `Retry-After` value. Phases 4–6 extend that foundation to library,
comments/reports, account deletion, and preparation/chat. Public-operation and
comment origin scopes use the shared trusted-proxy boundary and one generic,
owner-only HMAC key; database failures fail these protected actions closed.

## Consequences

- Rate-limit state is coherent across replicas and can be inspected, expired,
  tested, and backed up with the product database.
- New tables/indexes, a cleanup job, transactional integration, and metrics are
  required; traffic/load tests must validate contention and failure behavior.
- Limits become configuration with documented defaults and reviewed product
  policy rather than implicit per-process behavior.
- Redis, Kafka, NATS, and a separate rate-limit service are out of scope unless
  a future ADR changes this decision.

## Security and operational implications

- IP/device scope keys are hashed with a rotating server secret when retained;
  raw identifiers are not logged or unnecessarily persisted.
- Buckets must have bounded retention and expiration cleanup to avoid unbounded
  growth. Monitor cleanup failures, denied-action rates, database contention,
  and bypass attempts.
- Database outage behavior must fail safely for sensitive writes and remain
  explicit in service health/runbooks; edge controls provide only supplemental
  protection.
- Limits are not authorization. Every protected operation still verifies the
  authenticated principal and applies ownership/status/terms checks.
