# Queue-first discovery deployment boundaries

**Status:** Current default-off rollout contract with a preserved Phase 0
baseline inventory
**Inspected:** 2026-08-31
**Git baseline:** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`

The first three sections preserve facts from the pinned Phase 0 Git commit.
Later sections describe the current implementation through Plan 03. Do not use
the historical inventory as the current feature or migration manifest.

## Pinned Phase 0 migration facts (historical)

The backend embeds ten forward SQL migrations:

| Version | File |
| ---: | --- |
| 1 | `backend/migrations/0001_initial.sql` |
| 2 | `backend/migrations/0002_arxiv_shared_cooldown.sql` |
| 3 | `backend/migrations/0003_chat_prompt_version.sql` |
| 4 | `backend/migrations/0004_accounts.sql` |
| 5 | `backend/migrations/0005_shared_rate_limits.sql` |
| 6 | `backend/migrations/0006_library.sql` |
| 7 | `backend/migrations/0007_per_user_library_revisions.sql` |
| 8 | `backend/migrations/0008_comments_and_moderation.sql` |
| 9 | `backend/migrations/0009_account_deletion.sql` |
| 10 | `backend/migrations/0010_user_reports.sql` |

The release/deployment contract also expects version 10 in `.env.example`, the
Helm validation template and README, restore/load evidence, and operational
gate validators. There is no `0011_reading_feed_imports.sql` at this baseline.

The Phase 0 plan required a future migration 0011 to be forward-only and
additive, to update every exact-version assertion, to cover upgrade and replay
against disposable PostgreSQL, and to preserve account deletion. That work is
now historical; the current migration boundary is recorded below.

## Pinned Phase 0 server flags (historical)

At that commit, `backend/apps/api/src/config.rs` defined exactly these six API
capability flags. Every `.env.example` and Helm repository default was false:

| Environment flag | Helm value | Current dependency/effect |
| --- | --- | --- |
| `ACCOUNTS_ENABLED` | `features.accounts` | Enables account verification/profile behavior. |
| `LIBRARY_ENABLED` | `features.library` | Requires accounts; registers To Read reads and mutation routes. |
| `LIBRARY_WRITES_ENABLED` | `features.libraryWrites` | Requires library; independently enables save/remove mutations. |
| `COMMENTS_ENABLED` | `features.comments` | Requires accounts; registers discussion and safety routes. |
| `COMMENT_CREATION_ENABLED` | `features.commentCreation` | Requires comments; enables only new comment publication. |
| `ACCOUNT_DELETION_ENABLED` | `features.accountDeletion` | Requires accounts and the deletion boundary. |

At that commit no server field, environment parse, Helm value, route
registration, or OpenAPI operation existed for the queue-first flags or routes.

## Pinned Phase 0 mobile flags (historical)

At that commit, `mobile/lib/app/feature_flags.dart` contained four compile-time
booleans, all defaulting to false:

```text
PAKPERK_ACCOUNTS_ENABLED
PAKPERK_LIBRARY_ENABLED
PAKPERK_COMMENTS_ENABLED
PAKPERK_OPENING_MOTION_ENABLED
```

Library and comments each required accounts. This list is historical; the
current source has the additional Plan 01, Plan 02, and Plan 03 build controls
described below.

## Current migration boundary

Schema 18 is the accepted Plan 02 boundary; its historical release exercise ran
from schema 11 through migrations 12–18. The current Plan 03 exercise starts at
schema 18 and applies migrations 19–24: preparation-trigger audit, normalized
document model, Passport/provenance/assistant, private annotations/research
memory, version diff, and annotation archive import/conflict fidelity. The
protected release gate must restore schema 18,
apply the reviewed migration image to schema 24 exactly once, prove replay,
old/new compatibility, private-data deletion and restore reapply, integrity, a
schema-compatible code rollback, and re-forward. Feature rollback preserves
schema 24; it never runs a down migration merely to close a capability.

## Current default-off server controls

The following controls are implemented and validated at startup:

| Flag | Required dependencies | Route/behavior boundary |
| --- | --- | --- |
| `ACCOUNTS_ENABLED` | none | Enables authenticated account/profile behavior. |
| `LIBRARY_ENABLED` | accounts | Registers legacy Library reads and mutation routes. |
| `LIBRARY_WRITES_ENABLED` | library | Independently enables canonical Library mutations. |
| `COMMENTS_ENABLED` | accounts | Registers discussion and safety routes. |
| `COMMENT_CREATION_ENABLED` | comments | Independently enables new comment publication. |
| `ACCOUNT_DELETION_ENABLED` | accounts | Registers recent-auth deletion and its durable worker boundary. |
| `PAPER_RESOLUTION_ENABLED` | none; deployed use requires monitored arXiv configuration and shared gate | Allows new search/import resolution flows; it must not disable or change the existing public exact-paper route. |
| `PAPER_TITLE_SEARCH_ENABLED` | accounts, paper resolution | Registers/enables bounded title search. |
| `LIBRARY_IMPORT_WRITES_ENABLED` | accounts, library, library writes, paper resolution | Registers/enables idempotent exact import into To Read. |
| `READING_FEED_ENABLED` | accounts and library | Registers the authenticated reading feed, including its minimal authority-bound Recent fallback after proven emptiness. |
| `TO_READ_FIRST_ENFORCEMENT_ENABLED` | reading feed | Publishes `enforcement=strict` on the authenticated response; off publishes `shadow`, giving strict-capable clients an immediate rollback authority. |
| `LIBRARY_V2_ENABLED` | accounts, library | Registers the canonical five-state Library, lists, tags, and unified change feed. |
| `RESEARCH_PROFILES_ENABLED` | accounts | Registers optional future-discovery preferences; it never mutates queue state. |
| `RECOMMENDATIONS_ENABLED` | accounts, library, reading feed | Enables advanced recommendation modes, profile-aware reasons, explanations, and feedback. The minimal authority-bound Recent fallback remains available to the reading feed while this switch is off. |
| `RECOMMENDATION_EVENTS_ENABLED` | none | Registers optional content-free evaluation events; product state never depends on delivery. |
| `SEARCH_LOOKUP_ENABLED` | none | Registers deterministic public local-metadata Lookup. |
| `SEARCH_EXPLORE_ENABLED` | Lookup | Registers explicit, bounded Explore with source diagnostics. |
| `SAVED_QUERIES_ENABLED` | accounts, Explore | Registers account-owned saved query definitions. |
| `READING_BRIEFS_ENABLED` | reading feed | Registers queue/discovery briefs under reading-feed authority. |
| `SUBSCRIPTIONS_ENABLED` | accounts, library, reading feed | Registers private category/topic/author/saved-query subscriptions. |
| `NOTIFICATIONS_ENABLED` | subscriptions | Registers queue-aware in-app notification delivery; push and email remain unavailable. |
| `DEEP_READER_ENABLED` | none | Registers the normalized document/outline boundary. Deeper Plan 03 capabilities remain subordinate to it. |
| `PAPER_PASSPORT_ENABLED` | Deep Reader | Enables evidence-linked Paper Passport artifacts. |
| `SEMANTIC_FACETS_ENABLED` | Deep Reader | Enables bounded semantic facets and source-linked definitions. |
| `VISUAL_OBJECTS_ENABLED` | Deep Reader | Enables source-linked figure, table, and equation objects. |
| `ASSISTANT_V2_ENABLED` | Deep Reader | Enables the evidence-ID-validated assistant contract. |
| `ANNOTATIONS_ENABLED` | accounts, Deep Reader | Enables private synchronized annotations and evidence cards. |
| `RESEARCH_MEMORY_ENABLED` | accounts, Deep Reader, annotations | Enables private reviewable memory items without Library authority. |
| `VERSION_DIFF_ENABLED` | Deep Reader | Enables generation-aware paper-version and diff surfaces. |
| `DOCLING_EXPERIMENT_ENABLED` | Deep Reader | Allows an evaluated parser experiment; it never makes Docling the default by itself. |

All current optional controls default to false. Startup rejects contradictory
security-critical combinations. Optional feature routes follow the existing
pattern: absent when their parent capability is off, with an explicit 503 only
for an independently disabled write/action behind an otherwise available
parent surface.

Mobile build controls default off and validate compatible account/Library
dependencies. The ten Plan 03 build controls are Deep Reader, Passport,
semantic facets, document visual objects, reading checkpoints, annotations,
evidence cards, research memory, version diff, and assistant v2. Closed
schema-v6 feature evidence and schema-v4 candidate/provenance manifests bind
all ten, while protected acceptance schema v6 defines their ten physical-device
scenarios. This repository mechanism is not a passing run: signed-device,
privacy, legal, human, live-model, staging, and release-owner evidence remain
`not_ready`, so checked-in production values stay false. A Helm server switch
never rewrites an already signed binary.

## Runtime ownership

| Boundary | Ownership |
| --- | --- |
| Public discovery `GET /v1/feed` | Existing API route, anonymous/public cache; unchanged. |
| Authenticated reading feed | API orchestration and one PostgreSQL repeatable-read snapshot; private/no-store and authorization-varying. |
| Title search and exact import | Authenticated API routes using the existing arXiv client, shared DB gate/cache, paper metadata repository, and library service. |
| Queue and import state | PostgreSQL through additive migrations 11–18; the canonical Library revision remains authority after migrations 19–24. |
| Profiles, recommendations, and feedback | Account-private PostgreSQL state with independent profile and feedback revision fences; never direct queue mutation. |
| Lookup, Explore, and saved queries | Bounded public local-metadata reads plus an account-owned explicit saved-query definition; no implicit search history. |
| Briefs, subscriptions, and notifications | Account-private delivery state subordinate to reading-feed authority; in-app only. |
| Document preparation and derived artifacts | Paper worker with an approved-trigger audit and parser-independent adapter; GROBID remains default, Docling is compile/runtime-gated, and feed/search/import/Abstract display cannot trigger deep work. |
| Private research artifacts | Owner-bound PostgreSQL annotations/conflicts/re-anchor history, evidence cards, checkpoints, memory, assistant history/provenance, and idempotent operations; shared paper artifacts remain separate. |
| Mobile arbitration and storage | Account/auth-epoch-scoped controllers behind signed compile-time flags; public metadata cache is never empty-queue authority. Drift private bodies are ordinary SQLite text protected by the platform boundary, not application-layer encryption. |
| Shared protocol assets | Checked OpenAPI after route implementation plus Rust/Dart fixture parity. |

## Plan 02 evolution and rollout order (historical)

1. Land contracts and fixture scaffolding with no runtime behavior.
2. Add migration/resolution/search/import behind default-off server flags.
3. Add reading-feed service and invariant tests behind its flag. (Implemented.)
4. Add Plan 02 Library, profile, search, recommendation, brief, subscription,
   and in-app notification capabilities behind default-off flags.
5. Ship compatible mobile support hidden/default-off.
6. Enable server capabilities internally, then compatible mobile cohorts.
7. Resolve minimum-supported old-client policy before enabling strict
   enforcement.

The final production approval bundle enforces step 7. A strict rendered
`toReadFirstEnforcement` value requires one canonical, owner-approved
old-client policy bound to that exact source, release configuration, image set,
chart, restore drill, and signed mobile candidate. The closed choices are a
minimum supported version, disabling account and library access for identified
legacy builds, or an explicitly advisory period until an owner-supplied
adoption threshold. No threshold is defined by repository defaults. A render
with enforcement false keeps this policy slot `null` and dormant. See the
[release evidence procedure](runbooks/release.md#release-evidence-binding-scope).

Rollback closes the new gates without changing the public feed or existing
library wire contract. Schema changes remain additive until a later reviewed
contract phase.

## Plan 02 enablement and rollback (historical)

All optional queue-first discovery controls remain false in production
defaults. Exercise each staging switch independently, retain its rendered
before/after value and observed request result, and restore the reviewed
baseline before moving to the next switch. Enable the capabilities in this
order:

1. Complete the schema 11-to-18 backup/restore/migration/rollback rehearsal and
   all external gates below while every new switch is false.
2. Enable `PAPER_RESOLUTION_ENABLED`. Prove the existing public exact-paper
   route and anonymous `GET /v1/feed` remain compatible.
3. Exercise `PAPER_TITLE_SEARCH_ENABLED` and
   `LIBRARY_IMPORT_WRITES_ENABLED` as separate staging changes. Search requires
   accounts and resolution. Import requires accounts, library, library writes,
   and resolution. Enabling or disabling either one must not change the other.
4. Enable `READING_FEED_ENABLED` while
   `TO_READ_FIRST_ENFORCEMENT_ENABLED=false`. Prove FIFO queue behavior,
   active-library recommendation exclusion, current-revision cursor handling,
   authoritative-empty-only recommendations, and fail-closed behavior.
5. Enable `LIBRARY_V2_ENABLED`, then `RESEARCH_PROFILES_ENABLED`, proving that
   profile and list/tag/note operations cannot override active queue state.
6. Enable `SEARCH_LOOKUP_ENABLED`, then `SEARCH_EXPLORE_ENABLED`, then
   `SAVED_QUERIES_ENABLED`. Prove explicit navigation, bounded diagnostics,
   privacy, and canonical Library/import-only saves.
7. Enable `RECOMMENDATIONS_ENABLED` only after reading-feed shadow authority is
   green. Exercise `RECOMMENDATION_EVENTS_ENABLED` independently because its
   optional stream is not a product-state dependency. Prove library, profile,
   and feedback revision supersession and feedback identity exclusions.
8. Enable `READING_BRIEFS_ENABLED`, then `SUBSCRIPTIONS_ENABLED`, then
   `NOTIFICATIONS_ENABLED`. Prove active/unknown queue deferral, quiet hours,
   budgets, expiry, and in-app-only delivery.
9. Enable `TO_READ_FIRST_ENFORCEMENT_ENABLED` last, only after compatible
   signed clients, minimum-supported-client policy, the reading-feed service
   objective, the invariant alert, and rollback have protected evidence.

Rollback uses the switches in reverse dependency order. Close enforcement and
every reading-feed consumer before reading feed; close notifications before
subscriptions; close saved queries before Explore and Explore before Lookup;
close title search and import before resolution. The optional event stream may
close independently. Preserve schema 18 and roll back to a compatible image;
do not run a down migration or restore schema 11 merely to disable a feature.
The public feed, existing Library reads, account deletion, and explicit search
navigation remain available as their own dependencies permit.

Repository tests, a Helm render, and local Docker Compose are necessary checks,
not release evidence. Production enablement additionally requires protected
proof of the schema 11-to-18 rehearsal and isolated restore/deletion replay;
the monitored arXiv contact, shared gate/cache, and live adapter behavior;
staging switch and invariant canaries; the privacy log scan; signed physical
mobile results; alert routing; and database, platform, security/privacy, mobile,
and release approvals. The executable sequence and evidence boundary live in
the [release runbook](runbooks/release.md#queue-first-discovery-staged-enablement).

## Current Plan 03 enablement and rollback

Every Plan 03 server/Helm switch and every corresponding mobile build switch is
false by default. Complete the schema 18-to-24 migration/restore/deletion
reapply gate first, then enable Deep Reader, Passport/facets, visual objects,
assistant v2, annotations, research memory, version diff, and finally any
Docling experiment in the dependency order documented by the
[Deep Reader rollout runbook](runbooks/deep-reader-rollout.md). A production
Plan 03 switch also requires the exact immutable
`releaseEvidence.deepReaderReleaseId` for a complete 23-gate bundle.

Rollback closes those capabilities in reverse order, preserves legacy
Introduction and source access, keeps private artifacts, and retains schema 24.
The feature gate never authorizes a down migration to schema 18 or a switch to
Docling as default. Repository checks are not protected staging, human domain,
legal, live-model, live-telemetry, accessibility, signed-device, security, or
release-approval evidence; all such gates remain `not_ready` until their exact
candidate-bound manifests exist.
