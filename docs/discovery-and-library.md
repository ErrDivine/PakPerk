# Plan 02 discovery and library backend contract

**Status:** Backend contracts are implemented behind default-off flags. Mobile
exposure and production enablement remain separate protected rollout gates.

This document records the current source behavior added by migrations 12
through 18. The controlling invariant remains the
[authenticated reading-feed contract](reading-feed.md): a signed-in automated
feed may recommend only after one authoritative snapshot proves the active
Inbox/Read next/Reading set empty. Search, profile editing, lists, tags,
feedback, briefs, subscriptions, and notifications never override that gate.

## Capability boundaries

| Capability | Server switch | Dependency | Authority boundary |
| --- | --- | --- | --- |
| Five-state Library, lists, tags, notes, change feed | `LIBRARY_V2_ENABLED` | accounts + library | Reuses the canonical library revision; active-state changes can affect queue eligibility. Lists/tags/notes cannot. |
| Research profile | `RESEARCH_PROFILES_ENABLED` | accounts | Future-discovery preferences only; every response says `queue_override=false`. |
| Advanced recommendation modes, reasons, explanations, feedback | `RECOMMENDATIONS_ENABLED` | accounts + library + reading feed | Advanced batches bind a proven-empty library revision and current profile/feedback revisions. The reading feed may still persist a minimal authority-bound Recent fallback while this switch is off. |
| Optional interaction events | `RECOMMENDATION_EVENTS_ENABLED` | none | Closed content-free evaluation input; never product or queue authority. |
| Public deterministic Lookup and suggestions | `SEARCH_LOOKUP_ENABLED` | none | Metadata-only explicit navigation plus bounded local topic-vocabulary suggestions. |
| Public Explore | `SEARCH_EXPLORE_ENABLED` | Lookup | Bounded local arXiv coverage with a not-systematic disclaimer. |
| Account-owned saved queries | `SAVED_QUERIES_ENABLED` | accounts + Explore | Saves only a query definition; saving a paper still uses canonical Library/import. |
| Reading briefs | `READING_BRIEFS_ENABLED` | reading feed | Queue brief when active; discovery brief only from proven-empty authority. Dedicated brief progress never changes or proves queue state. |
| Subscriptions | `SUBSCRIPTIONS_ENABLED` | accounts + library + reading feed | Stores explicit topic/category/author/saved-query intent; it cannot deliver over queue policy. |
| In-app notifications | `NOTIFICATIONS_ENABLED` | subscriptions | Discovery delivery is revision-bound and deferred for nonempty/unknown queue state. Push and email remain unavailable. |

All switches default false. Startup rejects an enabled child whose dependency
is off. `RECOMMENDATION_EVENTS_ENABLED` is intentionally independent because
event collection is optional and product state must remain correct when it is
unavailable. With `READING_FEED_ENABLED=true`
and `RECOMMENDATIONS_ENABLED=false`, a proven-empty snapshot may persist and
serve only a minimal authority-bound Recent batch so the final empty-revision
recheck and reading briefs remain safe. Advanced modes, profile-derived
reasons, explanations, and feedback routes remain disabled; Recent-only items
therefore emit `explanation_available=false`, while configured enhanced batches
emit true.

The mobile event sender is best-effort and in-memory only. It emits the closed
12-event/five-mode schema in batches of at most 50, uses UUID event identities
and UTC timestamps, and erases pending work synchronously when account or
anonymous scope changes. Disabling personalization removes account behavioral
events; essential account save/remove/library-state signals may remain. A
disabled or failed event endpoint cannot block Library, queue, or reader state.
Account behavioral events are also fenced by the stored server preference, so
a modified client cannot bypass an opt-out. The v0.1 server rejects every
anonymous event batch with `INTERACTION_CONSENT_REQUIRED`: an anonymous session
UUID is request scope, not verifiable consent, and guests have neither an
analytics-consent control nor account Library state.

## Account-private surfaces

All routes below require bearer authentication and return private, no-store,
authorization-varying responses unless the code-first OpenAPI says otherwise:

- `/v1/library/...` exposes five-state items, lists, tags, and one unified
  revisioned change stream. Writes are idempotent and never enqueue PDF work.
- `/v1/discovery/profile`, `/interests`, `/topics/{topic_id}`,
  `/authors/{author_key}`, `/reset`, and `/export` expose revision-fenced
  preferences and separately grouped explicit, feedback, and inferred data.
- `/v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation` and
  `/feedback` accept only an owned, unexpired, server-created batch/item pair.
- `GET/POST /v1/search/saved` list or store an explicit query definition.
  `DELETE /v1/search/saved/{saved_search_id}` repeat-safely removes only the
  caller's definition. It returns `204` for a present owned row, an already
  absent row, or an ID outside that account so ownership is never disclosed.
  The same transaction retires a linked saved-query subscription, scrubs its
  display label, stops queued evaluation, and expires pending match/digest
  notifications. Deletion is not query-history clearing and does not save,
  remove, or prepare any paper.
- `/v1/me/reading-briefs` create/current and
  `/v1/me/reading-briefs/{brief_id}/progress` are the only brief authority.
  A reading-feed request may pass that account-owned `brief_id` and receive a
  nullable read-only `{id,position,total,complete}` summary, but only when the
  brief's exact library revision and queue/recommendation authority match the
  returned page. The feed cannot create, select, or update a brief, and brief
  progress/completion neither mutates nor proves queue emptiness. Creation uses
  stored `brief_size` (15–25, default/fallback 20)
  and, when no explicit mode is supplied, stored `preferred_discovery_mode`;
  profile lookup failure falls back to Recent. An explicit request mode wins.
  `/v1/subscriptions`, `/v1/notifications`, and
  `/v1/notification-preferences` also remain subordinate to reading-feed
  authority.

Public `GET /v1/search/lookup`, `GET /v1/search/suggestions`, and
`POST /v1/search/explore` search only bounded local metadata. Suggestions are a
deterministic list of at most eight `{topic_id, label, source_vocabulary}`
records; they perform no external lookup or queue mutation. Opening a result is
explicit navigation. To add a paper, use the canonical
[manual import contract](paper-import.md) or Library write; that pending save
immediately suppresses recommendations in a compatible client. These public
search responses remain `Cache-Control: private, no-store` with
`Vary: Authorization`; an unsaved query is not server-side history.

Lookup ranking is deterministic: exact normalized arXiv identity, exact DOI,
exact title, high title-trigram similarity, exact author plus matching title
tokens, then related full text, with newer publication time and stable paper ID
as tie-breakers. Explore uses auditable fixed-weight local fusion: direct text
`1.0`, a published citation-neighbor edge `0.25`, and an explicit
topic/category filter `0.125`. Abstract-vector retrieval is optional and stays
unavailable until a compatible query-embedding model is configured; the
service never substitutes a fabricated vector score. Every response retains
closed source diagnostics and the bounded/not-systematic coverage disclaimer.

## User-selected Library reminders

An active Inbox, Read next, or Reading item may carry one account-private UTC
`reminder_at`. Library v2 writes use patch semantics: omitting the field
preserves it, JSON `null` clears it, and a future timestamp sets or replaces
it. Reviewed, Archived, removed, or already-past values are rejected by the
server. Moving an item out of the active queue or removing it clears the
reminder. The post-import success action opens the same account-scoped Library
editor immediately; quick saves remain silent.

`user_selected_reminder` is a closed in-app notification type with its own
`immediate|daily|weekly|off` preference and an `immediate` default. Its worker
locks the account, applies global pause, quiet hours, in-app enablement, daily
budget, and the per-type frequency, and creates only queue-owned paper
notifications. The idempotency boundary is account + paper + the exact
microsecond reminder timestamp. The payload contains only the reminder epoch;
it never copies a title, note, list, tag, query, or account identifier.
Clearing, replacing, inactivating, or removing the Library item makes an old
unread notification ineligible at list time. Dismissing a notification changes
only notification state and never mutates or advances Library queue authority.

The notifications deployment flag independently gates creation and execution
of reminder work. During rollback, already queued or expired-leased reminder
work is safely completed without evaluation, while other engagement work
continues. Mobile keeps an existing reminder visible and clearable but disables
new selection and uses the neutral “Organize paper” import action. Re-enabling
does not resurrect an arbitrarily old promise: scheduling and evaluation share
a strict 24-hour overdue delivery window. A timestamp older than that remains
visible until the user clears it or next explicitly saves the item; the editor
then explains that the completed reminder will be cleared. Rollout evidence
must exercise this dormant-work and no-late-delivery behavior.

## Source terms and attribution

Lookup, Explore, suggestions, recommendation cards, and briefs use the
repository's canonical arXiv metadata boundary. Preserve the paper's authors,
title, versioned arXiv identity, and canonical abstract-page link; do not imply
that Pakperk owns the paper. Pakperk is not affiliated with or endorsed by
arXiv. Explore
must show its bounded local-source diagnostics and not-systematic disclaimer.
Topic suggestions retain `source_vocabulary` so a product label cannot be
presented as an inferred user follow or a universal taxonomy.

The existing [full-text and arXiv data policy](content-policy.md) still governs
metadata, links, PDFs, and derived content. A repository fixture or successful
search does not complete the release review: the exact enabled sources,
attribution presentation, usage terms, quotas, and qualified content/legal
approval must be attached to the candidate evidence before production use.

## Feedback truthfulness

Accepted feedback advances `recommendation_feedback_revisions`. Batch build,
persistence, and serve bind that revision, the optional profile revision, and
the proven-empty library revision. A mismatch supersedes an unserved batch.
Every response with a recommendation `batch_id` also carries the exact
`batch_metadata` tuple: profile revision, feedback revision, algorithm version,
and recommendation-policy version. The tuple is absent exactly when the batch
ID is absent and is part of mobile cache validity. The batch is scoped to that
authorized cursor page: a response may carry both `batch_id` and `next_cursor`,
and the continuation page may have a different batch ID. A compatible client
requires the same enforcement, queue decision/library revision, effective mode,
and immutable metadata tuple before appending it. It retains each item's source
batch and zero-based page-local reranked position for batch-bound actions and
events, and never caches a heterogeneous merged walk under one batch identity.
Generation runs through a separate account-owned job queue. A worker claims a
bounded job, builds from the job's bound library/profile/feedback authority,
and rechecks those fences before publication; it cannot weaken the synchronous
reading-feed empty-queue proof. Each page's continuation coordinates and
candidate rows are persisted so pagination never serves an unbound result set.
The same-snapshot candidate read excludes every retained exact/base arXiv
identity with feedback; not-relevant and dismissed items are hard exclusions.
Qualified impressions add only a capped repeat penalty.

Relevant feedback creates a `source=feedback` primary-category affinity only
when personalization is already on. For You can use separately labelled
feedback or inferred affinity and must explain the actual source. Following
uses explicit interests only. Reset All deletes raw feedback, the feedback
revision, interactions, batches, and non-explicit profile interests. The
profile interests/export surfaces show separated aggregates, not a raw
chronological feedback history.

Explanation codes and candidate sources are closed wire enums. They include
`saved_query_match` with source `saved_query`; a saved-query reason reports a
real stored definition and never implies an explicit topic or author follow.

## Privacy and retention

- Explicit profile/library/saved-query/subscription data persists until reset,
  item deletion, or account deletion as applicable. Deleting a saved query
  hard-deletes its normalized definition and bounded save-retry bindings;
  only content-free subscription audit identity/revision data remains after
  its raw display label is scrubbed.
- Research-profile retry bindings expire after 30 days; saved-search retry
  bindings use a bounded server-assigned expiry.
- Recommendation batches and candidates currently expire after 24 hours.
  Content-free interaction events expire after 90 days, and raw recommendation
  feedback after 180 days. Terminal/dormant/expired-lease recommendation
  generation jobs older than 30 days are removed by bounded maintenance.
- Reading briefs expire after 35 days. In-app notifications, engagement
  retry/idempotency rows, and completed/failed notification work expire after
  30 days. Hourly maintenance caps each table deletion at 1,000 rows per pass.
- Unsaved Lookup/suggestion/Explore and submitted import text are not stored as server
  query history. Search logs and telemetry must never contain raw query,
  title, URL, account, paper, cursor, token, private note, reason detail, or
  notification payload.
- Account deletion cascades all account-owned Plan 02 rows. Public paper and
  canonical topic metadata remain because they are not account-owned.

See the [Privacy Notice](legal/privacy.md),
[observability runbook](runbooks/observability.md), and
[account-deletion runbook](runbooks/account-deletion.md) for the operational
policy and protected evidence requirements.

## Rollout and rollback

Migrations 12–18 are additive over deployed schema 11. Exercise the exact
11-to-18 path from a verified isolated restore, preserve schema 18 during a
feature rollback, and re-forward after a schema-compatible old-code exercise.
Do not use a down migration to close a capability.

Migration 12 is an expand migration, not the physical To Read-to-Inbox
contraction. While v0.0 code can coexist with or roll back onto schema 18,
logical Inbox remains stored as `to_read`; v2 code decodes that alias as Inbox
and encodes Inbox back to `to_read`. The legacy operation fingerprint remains
unchanged for v0 replay, while a nullable v2 fingerprint carries the complete
private-note/source/reminder intent for new writes. The legacy Library list
projects Inbox, Read next, and Reading as its single `to_read` collection;
the v2 `state=inbox` filter remains exact.

Before any Read next or Reading value is written, a rollback may use the
verified v0.0 image against schema 18. After Library v2 writes are enabled, the
rollback target must be the last expand-compatible image that understands all
five logical states; v0.0 is no longer a safe code rollback target. Keep schema
18 and close the feature flags in either case.

Enable by dependency and risk: Library v2; research profiles; Lookup then
Explore then saved queries; recommendation/event storage in shadow evaluation;
reading-feed recommendation modes only after queue/privacy/evaluation gates;
reading briefs; subscriptions; notifications last. Enforcement of the
authenticated queue-first surface remains the final client-adoption gate.
Rollback reverses those dependencies while preserving the ordinary public
feed, existing Library reads, account deletion, and schema 18.

Before For You or discovery delivery leaves shadow, bind the offline evaluation
corpus and result digest, generator/feature/scoring/diversity policy versions,
source-coverage and topic/author concentration results, queue-leakage target
zero, and accountable research/product/privacy review. Concurrency property
tests must cover save/remove/account-switch/revision races; fail-closed tests
must cover database, authentication, and source unavailability; retention and
account-deletion tests must cover every account-owned class. These repository
checks are prerequisites, not live-candidate evidence.

The checked-in offline gate includes an executable 18-case queue-policy matrix
and versioned recommendation fixtures for explicit profiles, expected candidate
pools, sparse categories, misleading title overlap, ambiguous author names,
arXiv version duplicates, inactive historical-seed reasons, negative feedback,
and small-profile changes. It measures Recall@K, nDCG@K, catalog/topic and
cold-start coverage, diversity, novelty, author/category concentration,
explanation correctness, negative-feedback response, and ranking stability.
It also reports deterministic latency microseconds, micro-USD cost,
generator invocations, generator-document work units, and external-request
budgets with explicit units. Those resource gates do not substitute for manual
relevance judgments, production latency/cost, online metrics, an approved A/B
assignment and stop policy, or the protected production observation gates.

Repository tests and rendered flags are mechanism evidence only. Production
requires the exact 11-to-18 restore/migration/rollback result, full feature-map
dependency exercise, live privacy scan, retention cleanup observation,
queue-invariant and alert canaries, signed-client acceptance, and accountable
database/service/platform/privacy/mobile/release approvals.
