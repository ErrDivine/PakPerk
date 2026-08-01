# ADR 0004: Public comments and moderation

**Status:** Accepted and implemented; public enablement remains environment-gated
**Date:** 2026-07-31

## Context

Production v0.0 adds paper-level discussion, which is public user-generated
content. A comments feature without reporting, blocking, moderation, rate
limits, terms acceptance, deletion, and a response process would create an
unsafe and operationally unsupported launch.

## Decision

Provide public, flat, paper-level comments only. Guests may read published
comments; active authenticated users with a handle and accepted Terms and
Community Guidelines may create them. Comments are normalized plain text, have
strict scalar/byte/URL limits, are newest-first, and contain no HTML,
attachments, replies, reactions, votes, live updates, or anonymous posting.

Creation uses deterministic validation and spam rules, account/IP-device rate
limits, account-status checks, and an optional provider-neutral server-side
moderation adapter. The implemented remote seam is one bounded HTTPS JSON call
from the API through reviewed egress; it is not a mobile SDK or a new Pakperk
service. A suspicious or model-uncertain result is held for review or
temporarily rejected rather than automatically published. Users can
edit/delete their own comments, report comments or users, and separately block
other authors. Moderators can review reports, hide/restore comments, and
suspend/reinstate accounts through audited tooling. A global feature flag can
disable new comments without disabling reading.

## Consequences

- Comments require normalized tables for comments, reports, blocks, and
  moderation events; client creation uses a stable request ID for idempotency.
- Posting requires an explicit community-policy acceptance record in Pakperk,
  not merely an identity-provider consent screen.
- The product must provide clear public-content disclosure, support contact,
  reporting UX, account deletion, and ownership of report response before the
  public flag is enabled.
- The initial moderation interface may be an authenticated admin CLI, but it
  must audit actor and action and avoid printing content except for explicit
  inspection.

## Security and operational implications

- Comment bodies, report details, identities, and moderation metadata are
  sensitive operational data: redact them from telemetry and tightly bound
  access to them.
- Server-side validation is authoritative; client counters and filtering are
  convenience only. Rendered links require safe parsing and external-navigation
  safeguards.
- Idempotency and owner-constrained SQL prevent duplicate retries and
  cross-account edit/delete access. Private-resource failures should avoid
  leaking existence where appropriate.
- Shipping is gated on tested moderation operations, a live support route,
  terms/community pages, rate limits, retention/deletion policy, and a defined
  incident/report-response owner.

## Implementation result

Phase 5 implements the flat comment, report, block, acceptance, shared-limit,
rules-moderation, adapter, and moderation-audit model inside the existing Rust
backend and PostgreSQL database. API registration and new publication use
separate deployment flags. The Flutter client keeps bounded personalized pages,
account-scoped drafts, and persisted blocks behind an account-and-auth-epoch
write barrier; drafts never enter an automatic outbox. `pakperk-admin` provides
explicit inspect/action commands with attributable audit records and
content-free queue metrics. It authorizes only a recent OIDC `auth_time` mapped
to an active local account whose UUID is in the protected operator allowlist;
ordinary authenticated accounts cannot invoke moderation operations.

The repository now implements the in-app/web account deletion, retention and
restore-replay mechanisms, hosted support/legal routes, telemetry pipeline, and
alert/runbook contracts required by this ADR. The launch gate is not weakened:
public creation remains off until those mechanisms are exercised against the
target environment and the final legal, moderation, privacy, and store-policy
reviews approve their evidence.
