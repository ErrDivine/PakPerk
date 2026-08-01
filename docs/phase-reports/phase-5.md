# Production v0.0 Phase 5 report

**Phase:** Comments and moderation
**Status:** Complete — accepted, public enablement remains a Phase 6 gate
**Implementation snapshot:** 2026-07-31
**Starting commit:** `fefd18e`

This is the accepted Phase 5 record. It implements responsible flat public
paper discussion and its complete in-product safety boundary. It does not
represent the feature as publicly enabled: Phase 6 still owns end-to-end
account deletion, hosted legal/support pages, retention/restore, telemetry and
alerts, store review, and signed release-candidate controls, so both comment
flags and especially public comment creation remain off by default.

The intended product and wire behavior is recorded in
[Comments and moderation contract](../comments-and-moderation.md).

**2026-08-01 gap-closure addendum:** the generic “reports” wording in the
original acceptance record covered comment reports only. Production v0.0 now
also has a distinct user-report table, repeat-safe API, combined backlog
metrics, dedicated operator list/inspect/resolve commands, account-deletion and
backup coverage, and an explicit mobile **Report user** action. Reporting a
user does not create a block or alter visibility. Repository tests cover this
separation; the protected live two-user/store-review evidence must include the
new action before public enablement.

The same closure replaces the dormant moderation seam with a runtime-selectable
HTTPS adapter. Deterministic rules always run first; provider outages, invalid
status/body/schema, redirects, and oversized responses hold the comment for
review rather than publishing it. Helm mounts the distinct bearer credential
only for the HTTP provider and binds its URL, timeout, Secret rotation, and
reviewed API egress into the rollout contract. The admin CLI now authenticates
the operator through an OIDC token with an explicit recent `auth_time`, requires
the resolved local user UUID in a bounded deployment allowlist, and derives
that UUID as the audited actor; callers cannot choose an actor label and an
ordinary active account has no moderation permission.

## Implementation ledger

- [x] PostgreSQL comments, comment reports, user reports, blocks, community acceptance, moderation
  audit, indexes, and shared UGC limits.
- [x] Domain/service normalization, deterministic rules, pluggable moderator,
  safe outage fallback, idempotency, ownership, and version conflicts.
- [x] Feature-gated API routes, strict DTOs, opaque pagination, stable errors,
  private cache policy, OpenAPI, and creation-only kill switch.
- [x] Audited admin CLI for queue/inspect/hide/restore/report/user actions and
  content-free report age metrics.
- [x] Drift v5 personalized comment pages, account drafts, persisted blocks,
  cleanup, and bounded eviction.
- [x] Guest thread, gated composer, create/edit/delete/comment-report/user-report/block, My
  Comments, Blocked Users, pending-review, offline, accessibility, and keyboard
  states.
- [x] Terms, Community Guidelines, Privacy, support contract, moderation
  ownership/runbook, and store UGC review checklist.

## Required acceptance evidence

- [x] Guest reads published comments without depending on OIDC availability.
- [x] Duplicate create and report requests return one canonical record.
- [x] Stale edits conflict; unauthorized edit/delete does not leak existence.
- [x] Block removes an author's comments immediately, persists across restart,
  and filters another device after synchronization.
- [x] Suspended/deletion-state accounts cannot create or mutate UGC.
- [x] Deterministic high risk and moderator outage fail safe.
- [x] Drafts never auto-send and clear only after accepted creation.
- [x] Comment bodies/report details are absent from logs, errors, telemetry,
  list tooling, and debug output.
- [x] Creation-disabled deployment preserves comment reads, safety actions,
  moderation, and public paper reading.
- [x] Admin can inspect and act on reports with an attributable audit record.
- [x] Complete Rust/OpenAPI/Flutter/native/integrated gates pass from the
  settled tree.

## Backend and operational result

Migration `0008_comments_and_moderation.sql` adds normalized comments, unique
reports, durable blocks, community-policy acceptance, moderation audit, and
the indexes needed for newest-first and operator queues. The transport-neutral
comment service resolves exact create/report replays before charging limits,
checks eligibility before provider work, then rechecks inside the final
transaction. Edits use optimistic versions; private-resource edit/delete
failures collapse to one public not-found response. Shared PostgreSQL buckets
cover account, direct-origin, mutation, report, and per-target report pressure.
The API accepts forwarding metadata only from configured ingress-proxy source
ranges, resolves the chain right-to-left, and HMACs the canonical client
address with a validated owner-only secret before persistence.

`COMMENTS_ENABLED` registers public reads and safety routes;
`COMMENT_CREATION_ENABLED` rejects only new posts. Comment limits are asserted
against the domain constants at startup, `rules` and the bounded HTTPS runtime
adapter are the only accepted moderation providers, and a real
environment-safe support URL is mandatory.
Deterministic high risk, provider uncertainty, and provider outage hold content
privately. The audited `pakperk-admin` binary exposes content-free queues and
metrics; only its explicit inspect command serializes one selected body/report.

## Mobile and identity result

Drift schema version 5 stores bounded comment pages separately for guest and
each viewer, account/paper drafts with stable request IDs, and persisted block
projections. All account-owned writes cross a serialized account-and-auth-epoch
barrier shared with sign-out/account-switch cleanup. Network completions from a
disposed controller or old identity cannot repopulate the next session. Drafts
are never placed in the library outbox or sent after connectivity returns; an
explicit Send is required on every attempt and a creation-disabled response
retains the draft.

The paper control and deep-link routes expose guest reading, an explicit
sign-in rationale, handle/Terms/Community onboarding, create/edit/delete,
report/block, My Comments, and Blocked Users. Pending-review content is visible
only to its author. Local block persistence wins before the remote request and
filters immediately; reconciliation converges server state across API
instances. The comment renderer is plain selectable text without HTML/Markdown
execution or unsafe automatic linkification.

## Checks and live acceptance evidence

The settled Phase 5 tree passed on 2026-07-31:

- [x] Rust workspace formatting, Clippy with warnings denied, and complete
  all-target/all-feature tests (API 70, admin 3, domain 15, plus every existing
  crate and route suite).
- [x] Live PostgreSQL comments/service/accounts tests and clean-schema embedded
  migration test.
- [x] Code-first OpenAPI regeneration, byte-for-byte artifact check, four
  compatibility unit tests, and backward-compatibility comparison with
  `fefd18e`.
- [x] Dart formatting, `flutter analyze`, and all 358 Flutter tests, including
  Drift v4→v5, identity-race, draft/block/repository, and comment widget tests.
- [x] Comments/accounts/library-enabled Android debug APK and iOS simulator
  debug app with staging-safe HTTPS/strict-policy build definitions.
- [x] Repository-integrated `./scripts/check.sh`, shell syntax, JSON, diff, and
  protected-content diagnostics scans.
- [x] Disposable live PostgreSQL + Keycloak flow using two real Authorization
  Code + S256 PKCE users; the native public client rejected direct grants.

The live flow onboarded both accounts with the exact published `2026-07-31`
Terms and Community Guidelines; created and exactly replayed one comment;
rejected mismatched reuse; edited and rejected a stale version; replayed one
canonical report; and demonstrated block/filter/unblock across independent API
processes. A deterministic high-risk body stayed private to its author.

The same run exercised content-free admin queues, explicit inspect,
hide/restore, report resolution, suspend/reinstate, and the complete five-action
audit trail. A creation-disabled API still served guest comments and papers,
report/block, and author edit/repeat-safe delete. A third API with unavailable
Keycloak kept guest paper/comment GETs healthy while authenticated access
failed closed. Paper processing/job state was byte-for-byte unchanged. Three
captured API logs contained none of the UGC, protected-header, full bearer, or
token-signature sentinels. All disposable provider/local users, comments,
reports, blocks, moderation events, rate buckets, and paper data were removed.

After that recorded run, the repository acceptance boundary was strengthened
with a dedicated public PKCE `pakperk-admin-dev` client/audience and a manual,
environment-gated, exact-`main` workflow. The updated harness requires separate
negative checks for a valid mobile/API-audience token and a valid but
non-allowlisted admin-audience identity before using an allowlisted operator.
It emits only closed-schema, sanitized, disposable-reference evidence and tears
down a unique Compose project with its volumes. The updated workflow and Docker
flow were not run for this report; validator success proves the repository
contract only. Its `manual_ci_disposable_reference` classification does not
attest hosted environment protection, and its `reference-sha256:` ID cannot
satisfy production Helm `moderationReadinessId`, which still requires protected
staging evidence.

## Remaining Phase 6 launch gates

- In-app and web account deletion, provider identity erasure, recent-auth,
  retention, and restore-safe deletion ledger are not claimed by this phase.
- The checked legal/support text still requires public HTTPS hosting, monitored
  operator details, qualified review, and store disclosure sign-off.
- Simulator/debug native builds do not replace protected production signing,
  physical-device safety/accessibility flows, TestFlight/Play review, or RC
  telemetry.
- Consequently, public comment creation remains off until the Phase 6 policy
  gate is explicitly accepted. The canonical Production v0.0 plan and its
  cross-phase scenarios remain authoritative.
