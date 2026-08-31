# Observability, redaction, retention, and alert runbook

Pakperk processes emit structured traces/metrics through OTLP and JSON stdout
logs. A chart-managed node Collector tails only Pakperk container logs, applies
container parsing and protected-field redaction, and exports to the configured
HTTPS OTLP sink. Mobile clients send only the closed, identifier-free schema to
the validating `/v1/logs` gateway; the gateway, not the app, forwards accepted
events to the in-cluster Collector.

## Deployment boundary

- Process OTLP uses the exact in-cluster `*-otel-collector:4317` endpoint over
  plaintext only inside the NetworkPolicy boundary. External export is exact
  credential-free HTTPS host/port with headers from the external Secret.
- Telemetry-gateway `/health/live` and `/health/ready` are non-cacheable
  gateway-process signals: configuration, client construction, and listener
  setup succeeded before the server became reachable. They deliberately do
  not probe the Collector receiver, exporter queue, or external sink. Use the
  protected canary and externally observed Collector alerts below for delivery
  evidence; do not make product availability depend on that best-effort path.
- The log DaemonSet mounts `/var/log/pods` read-only and therefore needs
  deliberate node scheduling and Pod Security admission review. It has no
  service-account token, a read-only root filesystem, dropped capabilities,
  bounded memory/batch queues, and only DNS/upstream telemetry egress.
- `filelog` starts at the beginning so a newly scheduled agent does not miss
  existing container output. Its offsets use the `file_storage` extension on a
  128 MiB Pod-scoped `emptyDir`. The OTLP exporter's retry queue uses a separate
  `file_storage` instance and 128 MiB `emptyDir`, so an accepted, checkpointed
  record remains queued across a Collector container restart in the same Pod.
  Retry has no elapsed-time expiry; bounded queue or volume saturation instead
  fails visibly through the Collector failure/drop alerts. Pod replacement,
  rescheduling, or node loss discards both stores and can replay bounded
  retained log files. The sink must deduplicate where needed and
  alerts must tolerate replay; do not infer unique user/session counts from
  logs. Verify rotation and exporter-queue bounds before deployment. These
  `emptyDir` volumes provide continuity for an in-place container restart, not
  durable state or evidence of delivery to the external sink.
- If the cluster's restricted profile forbids the hostPath, deploy an
  equivalent platform-owned node logging agent and disable neither redaction
  nor the backend stdout collection contract. Record the exception/owner.

## Privacy and retention

The Collector deletes authorization/cookie/API-key fields, request/response
bodies, query strings, raw URL/path parameters, user/account/provider IDs,
network addresses, device/session identifiers, comment/paper content, private
notes, profile labels, saved-query definitions, feedback reasons,
recommendation evidence, notification payloads, exception messages/stacks, and
source file paths before export. OTLP log bodies use a
separate fail-closed transform: only an exact mobile-gateway event name with the
expected `pakperk-mobile` service, deployment environment, and
`app.pakperk.mobile` scope remains; every other scalar or structured OTLP body
is replaced by the static `otlp_log_body_redacted` marker. Node stdout is a
separate pipeline: every parsed message becomes the constant
`pakperk_backend_log` marker except two exact content-free alert messages.
`external deletion ledger failed verification` remains only for `ERROR`
records from `account_deletion::worker`; `authenticated reading feed could not
prove queue authority` remains only for `ERROR` records from
`pakperk_api::routes::reading_feed`.
The pipeline upserts its fixed service/environment identity and retains only
body, severity, and Rust namespace. Application diagnostics use bounded error
kinds, operation classes/outcomes, aggregate counters, and request IDs only.
Request IDs are operationally random and must not become a user/session
identity.

Plan 02 diagnostics may retain only closed operation classes/outcomes, queue
mode/reason, revision-mismatch counts, source/mode enums, latency buckets,
aggregate item counts, and maintenance removal/failure counts. They may never
label or log an account, paper/arXiv identity, batch/feedback/profile revision,
cursor, category/topic/author, query/title/URL, private note, reason detail,
saved-query/subscription key, notification payload, or interaction ID. Even an
opaque account or paper identifier creates forbidden cardinality and linkage at
this boundary.

Plan 03 follows the same identifier-free rule. Parser/model/schema versions are
artifact provenance and release bindings, not free-form telemetry labels.
Questions, answers, excerpts, source selectors, annotation/conflict/evidence/
memory bodies, account/paper/block/artifact/operation IDs, exact positions, and
raw cache keys are forbidden. The mobile Drift database contains ordinary
SQLite text, so telemetry redaction must not be described as local encryption.

Production operational telemetry retention is exactly 30 days unless a newer
published privacy schedule and protected values are approved together. Enforce
expiry at the upstream sink; the Collector cannot prove sink deletion. Access
is least privilege and audited. Never copy raw production events into issue
trackers or long-lived test fixtures.

The bounded exporter-queue `emptyDir` contains only batches after the redaction
processors above and is deleted with the Collector Pod. It is transient
delivery state, not an additional retention tier; inspect its node-storage and
access controls during the platform review and never mount it into another
workload.

## Plan 02 source signals and enablement gate

The repository provides closed reading-feed decision/cursor metrics plus the
generic `pakperk.operation.count` and `pakperk.operation.duration` instruments.
Plan 02 operation classes are limited in code to discovery
`lookup|suggestions|explore`, research-profile `read|write|reset`, recommendation
`feedback|event`, reading brief creation, notification scheduling, and retention
cleanup. Outcomes are limited to
`success|no_result|pending|deferred|rejected|retryable_failure|terminal_failure`.
The corresponding route spans are named from a fixed vocabulary and use
`skip_all`; request DTOs, principals, paths, and query/filter values are never
recorded as fields. The queue and intake policy boundaries are the exact eight
names `reading_feed.request`, `reading_feed.queue_snapshot`,
`reading_feed.queue_page`, `reading_feed.recommendation_eligibility`,
`reading_feed.recommendation_page`, `paper_search.request`,
`paper_import.resolve`, and `paper_import.library_save`. The import stage spans
wrap only work that actually runs, so an idempotent replay does not pretend to
resolve metadata or write the Library again.

The backend emits the remaining source-level intake, discovery, and deferred
work signals from the authoritative boundaries:

- `pakperk.reading_feed.stage.duration` separates `queue_snapshot` from
  `recommendation_page` work and uses only
  `success|stale|rejected|unavailable` outcomes.
- `pakperk.paper_search.requests`, `.duration`, and `.candidates` distinguish
  `no_result|single|ambiguous` responses, failures, and the closed
  `hit|miss|not_applicable` cache state. `pakperk.paper_import.requests` and
  `.duration` distinguish a fresh commit from an idempotent replay and closed
  failure outcomes. No query, title, URL, paper, account, or operation key is a
  metric attribute.
- The existing generic operation metrics are the result/no-result signal for
  Lookup and Explore. `pakperk.discovery_search.source.requests` and `.matches`
  add their closed `arxiv_metadata` source, `results|no_result` status, and
  `partial` coverage classification without duplicating the generic outcome.
- `pakperk.arxiv.access.count` and `.duration` cover the exact-resolve and
  title-search cache, caller-rate-limit, shared-gate, fetch, provider-rate-limit,
  and provider-unavailable outcomes. They do not claim a remaining-quota gauge:
  the current provider and shared gate expose no truthful remaining-quota
  value.
- `pakperk.notification.deferred.items`, `.oldest_age`, and
  `.release_budget_remaining` come from one aggregate database snapshot. The
  budget is configured local-day capacity remaining for discovery-enabled
  accounts after already-created notifications; it is not immediate delivery
  eligibility and intentionally does not guess quiet-hour, frequency, queue,
  or downstream-delivery state.

Counts, candidates, matches, ages, and budget values are bounded before export.
All dimensions are closed enums; identities and user- or paper-authored content
remain inside the service or database operation that computes the aggregate.

The mobile client closes its queue-policy portion with six identifier-free
events accepted by the schema-validating gateway. `recommendation_publication_rejected`
is emitted at the reading-feed response boundary only while the response still
belongs to the current account/auth epoch, using a closed queue or
personalization reason. `pending_intent_age` samples the oldest durable save
outbox row or import draft as a coarse duration bucket. The import ledger emits
`unknown` when it cannot be verified instead of claiming an age.
`discovery_suppression_latency` starts at the explicit, account-fenced save
intent and ends when the reading-feed controller publishes a non-recommendation
state. `discovery_unlock_latency` starts only after the outbox has received a
successful final active-removal acknowledgement, observes no remaining removal
and no active local queue item, and ends only when a current server response
confirms an empty queue. App termination, scope change, intervening save/import,
or a missing endpoint drops that timing sample rather than inferring it.
`library_sync_conflict` distinguishes only local revision and remote operation
boundaries. `library_outbox_backlog` carries the bounded pending count plus a
coarse oldest-age bucket (`none` for an empty outbox).

These mobile signals are essential queue/product-state telemetry. Turning
personalization off does not enable interaction telemetry and does not suppress
these invariant and sync-health observations. The redacting client schema and
gateway both reject raw timestamps, account/paper/operation identifiers,
content, and unknown attributes; only their shared closed duration buckets and
enums can be exported.

`pakperk.notification.work.items` accepts only a closed work class and outcome.
Its classes cover subscription, user-selected-reminder, and active-paper
evaluation, digest build, expiration, and deferred-queue recheck; the count is
aggregate work only. Reminder-only scheduling must enter the same bounded-work
info and pending-metric path. Logs and spans include only the closed
`evaluate_reminders` class and aggregate counts—never the account, paper, due
timestamp, payload, note, or title.
`pakperk.recommendation.generation.count` and
`pakperk.recommendation.generation.duration` accept only
`completed|superseded|retrying|failed|unavailable|idle`; duration covers the
bounded claim-to-finish poll. Neither instrument can accept a job, batch,
account, paper, query, profile, cursor, or revision value.
`pakperk.recommendation.generator.invocations`, `.outcomes`, `.duration`, and
`.candidates` use only the closed
`recent|following|author|affinity|semantic|citation|exploration` generator,
`primary|fallback` role, and `success|failure|timeout` outcome dimensions plus
bounded duration and aggregate item count. They accept no request or identity
material.
`pakperk.recommendation.batch.generation.duration`,
`.generated_candidates`, and `.concentration` are emitted once the queue-gated
engine completes a ranking, for both inline Recent fallback and queued
generation. Generation duration covers generator fan-out, merge, scoring,
reranking, and explanation construction; failed builds do not masquerade as
completed batches. The only label is the closed effective mode
`recent|following|for_you|explore`, except that concentration adds the closed
dimension `author|category|topic`. Candidate count is capped at 10,000 and each
concentration sample is clamped to `[0,1]`. Concentration uses the offline
evaluator's maximum-item-share definition: the largest number of completed
batch items sharing one normalized author, primary category, or normalized
topic, divided by completed batch size. Duplicate metadata values within one
paper count once. Labels and identities are consumed only in-process to build
the ratios and never cross the telemetry API.
`pakperk.recommendation.batch.serve.count`, `.returned_candidates`, and `.age`
classify page attempts by the closed requested mode, effective mode, outcome,
and serve class. Requested/effective modes are
`recent|following|for_you|explore` (with `undetermined` permitted only before an
effective mode can be selected); outcomes are
`hit|miss|no_result|blocked|superseded|unavailable`; and serve classes are
`existing_batch|inline_generation|generation_queue|pre_serve`. Returned page
size is capped at 100. Age is emitted only when a persisted batch is actually
found and is clamped to zero for a future timestamp and to 30 days maximum.
The recommendation API cache-hit signal is the existing exact pair
`serve_class=existing_batch,outcome=hit`; eligible-mode no-result is the exact
`outcome=no_result` sample with a closed effective mode. Do not create parallel
proxy counters for either outcome.
`pakperk.recommendation.feedback.ingestion.count` uses only an already
authenticated batch's closed mode and `applied|replayed|conflict`; feedback
that cannot authenticate an owned batch has no mode label and is omitted from
this metric. `pakperk.recommendation.feedback.signal.count` adds the closed
`relevant|not_relevant|dismissed` signal and closed batch mode only for a fresh
`applied` write. Idempotent replays and conflicts never increment product
feedback outcomes. None of these instruments accepts an identifier, revision,
feedback reason, text, query, topic/category, or paper value.

Qualified recommendation impressions and recommendation-attributed saves are
persisted as content-free, event-ID-deduplicated rows bound to an authenticated
servable batch item and closed feed mode. They are not yet safe online rate
metrics: the repository currently returns only whole-batch accepted/duplicate
totals, so counting submitted event types at the route would inflate retries.
`read_next` is canonical Library state but is not present in the interaction
event contract and carries no originating recommendation batch/mode. Do not
infer impression, save, or Read Next rates from request totals, generic Library
provenance, or queue transitions. A future source must return a fresh accepted
breakdown by closed mode/event type and retain explicit recommendation
attribution through the relevant Library transition before these rates can be
claimed.
`pakperk.retention.removed` accepts only the closed paper-import-operation,
profile-operation, saved-search-operation, interaction-event,
recommendation-batch/feedback, recommendation-generation-job, brief,
notification, engagement-operation, notification-work, assistant-thread, and
assistant-provenance classes.
Every cleanup also emits a closed success/retryable-failure operation outcome.
These signals intentionally cannot reconstruct interaction, feedback, profile,
saved-search, brief, subscription, notification, or account state.

Cold-start coverage and production relevance remain externally classified
quality evidence. The executable offline evaluator computes cold-start coverage
as retrieved IDs from a versioned, manually curated `cold_start_paper_ids`
cohort divided by all IDs in that cohort. Production candidate metadata has no
reviewed cold-start classification, so the service must not substitute paper
age, missing citation neighbors, generator source, novelty, or prior exposure
as a fabricated proxy. Likewise, explicit relevant feedback is an online
product outcome, not a manual relevance judgment. Keep the versioned fixture
gate and staging/manual evidence external until a separately reviewed,
privacy-safe cohort source can supply the same definition at the completed
batch boundary.

Before enabling the corresponding production flags, the protected adapter must
demonstrate these privacy-safe aggregate observations:

- reading-feed decision and active-count buckets; queue/recommendation query
  latency; recommendation-source invocation while active (target zero); client
  publication rejection; revision/cursor staleness; pending save/import age;
  and time to suppress or unlock discovery;
- candidate count/latency and failure/fallback per closed generator enum; batch
  age/generation latency, `blocked_by_queue`, cache hit, supersession on
  library/profile/feedback revision changes, no-result by eligible mode,
  relevance/dismiss outcomes, topic/author concentration, cold-start coverage,
  and feedback dedupe/rejection;
- Library sync conflict/outbox age, manual import success/retry, and search
  latency/index-use/no-result/source-coverage buckets;
- deferred discovery-notification count/age/release budget and queue-owned
  notification delivery outcomes; user-selected-reminder scheduled, completed,
  retry, terminal, dormant-on-rollback, 24-hour-expiry, stale-invalidation, and
  dedupe outcomes using only aggregate closed labels;
- external enrichment quota/rate-limit/error when such a source is actually
  enabled; and
- interaction, batch, feedback, profile-operation, saved-search-operation,
  brief, subscription, notification, and other retention-cleanup outcomes.

Hard-exclusion and queue-race fixtures must accompany those aggregates. A
missing source signal is an open release gate, not permission to infer success
from the API error ratio. The packaged 19-rule baseline includes the
queue-authority invariant but does not by itself attest all of these Plan 02
observations.

Implemented source instruments are necessary but not sufficient release
evidence. Live p95 values, source-to-sink delivery, production alert evaluation
and paging, sink retention/deletion, provider quota where a future adapter
actually exposes it, and the curated cold-start cohort remain external online
or protected evidence. Search provenance is not index-use evidence: PostgreSQL
chooses among the full-text GIN, trigram GIN, source/recency index, and a
sequential path from the deployed data and parameters. Bind index-use proof to
the released migration and query digest with a privacy-safe staging
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` over versioned representative
synthetic data, plus aggregate `pg_stat_user_indexes` and
`pg_stat_statements` observations for the same deployment window. The protected
evidence must retain the expected versus actual plan nodes and index names,
row/cardinality estimates, buffer and latency bounds, dataset revision, and
owner without retaining a user query. Do not replace any external gate with a
repository-test result or inferred proxy.

The hourly bounded recommendation-generation cleanup query also returns, from
the same database statement and snapshot, the aggregate count and oldest age
of work still in `queued|running`. Maintenance exports those samples through
`pakperk.backlog.items` and `pakperk.backlog.oldest_age` with the single closed
`recommendation_generation` class; missing age becomes zero and any accepted
age is capped at ten years. This sample does not add a second query and exposes
no job, batch, account, paper, or revision data. Live source-to-sink delivery,
alert thresholds, paging, and retention evidence remain external release
gates; an `idle` generation poll alone is never backlog evidence.

Retain a privacy-safe reconciliation for each enabled feature: rendered flag,
closed dependency result, request outcome, relevant aggregate signal, cleanup
result, UTC window, candidate/deployment identity, and accountable owner. This
is external protected evidence. Repository tests, a local log scan, or a chart
render do not prove live source-to-sink delivery, retention, or paging.

## Plan 03 source signals and open telemetry gates

The backend exposes the following closed, content-free instruments:

- `pakperk.parser.run.count` and `.duration` classify only
  `grobid|docling` and
  `success|temporary_failure|document_failure|validation_failure`.
  `pakperk.parser.object.count` records bounded aggregate
  `block|figure|table|equation` counts; `pakperk.parser.anomaly.count` uses only
  `no_heading|no_visual_objects|large_document`.
- `pakperk.preparation.decision.count` records approved/rejected decisions by
  the closed trigger kind. Together with `pakperk.paper_job.stage.count` and
  `.duration`, this distinguishes permitted Introduction/Inspect/explicit/
  approved-reprocessing work from rejected or unparsed public requests without
  retaining a paper or operation key.
- `pakperk.passport.field.count` records the ten fixed field keys and
  `supported|inferred|conflicting|not_found|not_applicable` only.
  `pakperk.visual_object.count` covers extraction/delivery for aggregate,
  figure, table, or equation with a closed outcome including policy denial and
  stale generation.
- `pakperk.assistant.phase.count` and `.duration` cover request, retrieval,
  answer, and provenance lookup. Outcomes distinguish support, partial answer,
  abstention, rejected request/unsupported output, context-not-ready, not-found,
  policy denial, rate limit, unavailable, and failure.
  `pakperk.assistant.validated_evidence.count` and `.claim.count` carry bounded
  counts only. `pakperk.assistant.cost.availability.count` records
  `reported|unavailable`; when the provider reports usage,
  `pakperk.assistant.cost.token_count` separates input/output tokens. Monetary
  cost is derived downstream from a candidate-bound price table and is never
  guessed in the service.
- `pakperk.version_diff.count`, `.duration`, and `.item.count` classify
  `build|lookup`, a bounded completion outcome, and
  `none|parser_change|item_level` uncertainty. They do not export diff text or
  source identities.
- `pakperk.annotation_reanchor.count` records the bounded background pass by
  closed strategy `stable_block_exact|quote_context|fuzzy_high_threshold|manual|no_match`
  and outcome `anchored|uncertain|orphaned|skipped|failure`. It carries no
  annotation, account, paper, block, generation, selector, quote, or note data;
  manual moves remain owner-bound history rather than a telemetry identity.
- hourly assistant cleanup emits `pakperk.retention.removed` for
  `assistant_thread` and `assistant_provenance`; no content or owner identity is
  emitted.

The mobile gateway accepts only these Plan 03 event names and bounded fields:

- `reader_entry_context`, `queue_auto_advance`,
  `queue_stale_cursor_recovery`,
  `recommendation_advance_cancelled_after_save`,
  `end_of_document_library_mutation`, and
  `final_item_checking_duration` describe only closed entry/authority/outcome,
  offline/explicit-action booleans, and a coarse duration bucket;
- `document_cache_lookup`, `document_cache_eviction`, and
  `document_cache_size` expose hit/miss, a closed eviction reason, and bounded
  count/byte values; and
- `annotation_sync_outcome` and `memory_lifecycle` expose only a closed action,
  anchor/conflict outcome or source type, strategy class, offline Boolean, and
  bounded count. They never carry selector text, note content, source IDs, or
  an account/paper identity.

Two Plan 03 observability requirements remain deliberately open in repository
code. Arbitrary parser-version and document-class strings are not accepted as
metric labels; version is bound in provenance/release evidence, while a future
bounded document-class classifier needs its own reviewed enum before it can be
telemetry. Likewise, provider token usage is sometimes unavailable and no
money-cost value is fabricated. Visual-object outcomes have an instrumented
schema, and the candidate now has both a bounded derivative producer and a
policy-checked selectable-variant route. No protected exact-candidate live
generation/delivery run exists, so no live asset-generation or delivery rate
can yet be claimed. The protected
telemetry gate must reconcile these limitations, demonstrate exact-candidate
source-to-sink delivery and privacy scanning, define live parser/model/queue
dashboards and owned alert thresholds, and prove 30-day sink deletion. The
current packaged 19-rule alert policy does not by itself provide Plan 03
quality/release dashboards. These live-telemetry, privacy/security, staging,
and release-approval results remain `not_ready` while all Plan 03 flags are off.

## Verification and alerts

The reviewed, provider-neutral rule contract is
`deploy/helm/pakperk/files/alerts/pakperk-production-alert-policy.json`.
`scripts/validate_alert_policy.py` fixes the required signal, threshold,
missing-data behavior, role owner, notification class, and runbook for every
rule below. The Helm chart verifies `alerting.policySha256` against the exact
packaged bytes and deploys those bytes in a content-addressed, immutable
ConfigMap. This makes the released policy auditable; a ConfigMap is not an
alert engine and is not evidence that paging works.

The platform adapter must import every rule without weakening it, supply the
declared external synthetic/database/Kubernetes/Collector inputs, and retain
immutable evidence of the imported policy digest, enabled rule IDs, receiver
ownership, all 19 rules routed across owned `page` and `ticket` receiver
classes in both environments, and successful staging page/ticket canaries.
Collector failure signals must be observed outside the Collector's own failing
export path. Do not enable production feature gates merely because repository
validation or a Helm render passed.

The packaged policy is deliberately production-only: its exact filters select
production resource and service identities. Staging canaries must use a
separately imported copy whose resource filters select staging, and that
staging policy needs its own immutable adapter evidence. Bind a reviewed
production-versus-staging parity diff: the canary copy may change the exact
environment filters and staging receivers, but it may not weaken the six
inputs, 19 rules, redaction, ownership, or 30-day retention policy. The chart
rejects mounting the packaged production policy in a staging release.

Before release:

1. Run `scripts/test_backend_log_export.sh` with the chart-pinned Collector. It
   injects a backend container log plus direct OTLP log, trace, and metric
   fixtures. Every configured protected key is exercised as both a signal and
   resource attribute; hostile scalar and structured OTLP log bodies must be
   replaced, the exact mobile event identity, constant backend marker, and
   exact ledger-alert body/severity/namespace must remain, hostile interpolated
   and structured stdout messages plus spoofed resource identities must not,
   safe sentinels must export, and protected sentinels must not. The harness
   also requires the Collector body allowlist to match the gateway event
   vocabulary exactly. It then holds the sink unavailable, checkpoints and
   queues the exact ledger-alert record, restarts the Collector with the same
   Pod-scoped stores, brings the sink up, and requires that queued record to
   arrive without being reread from the source log. This local E2E is pipeline
   and same-Pod restart evidence, not proof of the live sink or retention job.
2. Against the exact staging candidate, scan API logs, Collector output, the
   external sink, and the sanitized evidence package for To Read First and
   every enabled Plan 02 flow. Prove they contain no raw search query or paper
   title, submitted URL, bearer or refresh token, account/paper/batch/event
   identifier, reading-feed/search cursor, private note, profile interest,
   saved-query/subscription key, feedback reason, recommendation evidence, or
   notification payload. Inspect success and failure for resolution, search,
   import, queue mode, stale cursor, unavailable authority, profile/reset,
   batch/feedback/explanation, events, briefs, subscriptions, notifications,
   and every retention cleanup. Keep only approved content-free canaries,
   closed enums/buckets, request IDs, and aggregates.
   A repository string scan or local Collector test does not replace this live
   source-to-sink observation.
3. Send valid and hostile mobile telemetry payloads through staging. Require
   valid events to export and unknown fields, identifiers, oversized payloads,
   redirects, and wrong content types to fail closed. Confirm no auth/cookie
   header is sent by the app.
   During To Read First shadow rollout, require
   `reading_feed_shadow_decision` to contain only `shadow_decision`,
   `queue_authority`, constant `legacy_decision=public_discovery`,
   closed `server_policy`, `queue_policy_agrees`, and `offline`. Reconcile its closed decision totals
   with `pakperk.reading_feed.decisions`; never join or label either stream by
   account, paper, cursor, category, query, title, URL, or token.
4. Inspect the staging sink using canary values that are not personal/content
   data and verify the redacted fields are absent. Separately send a privacy-safe
   canary through the exact dark production Collector/gateway/adapter images and
   require the same bound commitment in the production sink. Process readiness
   and a staging delivery do not replace this production-path observation.
5. Bind the production and staging receiver/retention-policy identities
   separately and verify both are configured at exactly 30 days. For the
   production retention behavior test, seed a bounded commitment inventory,
   observe every canary initially, observe the same set once between day 29 and
   day 30, and observe none of them between day 30 and day 31. Record canonical
   UTC seed/query timestamps and exact ages/counts so a canary that was never
   ingested cannot pass as expired.
6. Restart one agent in staging and record replay volume/duplicates and recovery
   time. Verify node coverage and that log rotation cannot outgrow storage.

The immutable policy alerts on API readiness/error/latency, reading-feed
queue-authority fail-closed events, confirmed recommendation-card leakage, and
database saturation; paper/deletion
queue age and terminal failure; moderation report age; authentication recovery
failure; Collector rejected/dropped/export-failed data; missing node agents;
telemetry gateway rejection spikes; and deletion-ledger verification/capacity.
Alerts contain aggregates or exact content-free static messages only. Each
alert links its role owner and the applicable incident/deletion/moderation
runbook.

`reading-feed-authority-unavailable` is the queue-authority invariant guard. It
selects only production `ERROR` records from
`pakperk_api::routes::reading_feed` whose body is exactly `authenticated reading
feed could not prove queue authority`, and pages when the count is greater than
zero over five minutes for 60 seconds; missing data is healthy. Its staging
copy must preserve that threshold and duration while changing only the reviewed
environment/receiver binding. No account, cursor, category, query, title, URL,
token, paper, or arXiv value may be introduced as an alert label. Treat every
firing as an enforcement blocker and follow the
[incident-response runbook](incident-response.md).

`recommendation-card-queue-leakage` is the rendered-card invariant guard. It
selects only the closed production mobile event `recommendation_card_rendered`
with exact `policy_consistent=false`, pages on any event over five minutes for
60 seconds, and treats missing data as healthy. Its only filters are the closed
event body, production environment, false consistency result, and mobile
service identity; account, cursor, paper, category, query, title, URL, token,
and arXiv values are forbidden. A firing is confirmed UI leakage, not a broad
API error proxy, and blocks enforcement rollout.

If redaction, exporter credentials, sink access, or retention is wrong, stop
the affected export, preserve bounded evidence, rotate credentials when needed,
and follow [incident-response.md](incident-response.md). Do not make product
availability depend on mobile telemetry or loosen the schema to recover volume.
