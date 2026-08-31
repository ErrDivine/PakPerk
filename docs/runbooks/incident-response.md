# Production incident-response runbook

**Primary:** on-call incident commander. **Required specialists:** service,
database/recovery, identity, privacy, safety/moderation, and release owners as
the affected boundary requires.

## Declare and contain

Open a durable incident record, establish severity/commander/time line, and use
aggregate identifiers. Never paste tokens, secrets, raw addresses, provider
subjects, emails, handles, comment bodies, or deletion-ledger ciphertext into
chat/tickets. Preserve relevant immutable release, audit, and checksummed
evidence with access restricted to responders.

Protect anonymous reading while containing narrower writes:

- for a Plan 03 incident, close `DOCLING_EXPERIMENT_ENABLED` first, then
  `VERSION_DIFF_ENABLED`, `RESEARCH_MEMORY_ENABLED`, `ANNOTATIONS_ENABLED`,
  `ASSISTANT_V2_ENABLED`, `VISUAL_OBJECTS_ENABLED`,
  `SEMANTIC_FACETS_ENABLED`, `PAPER_PASSPORT_ENABLED`, and finally
  `DEEP_READER_ENABLED` as the affected dependency requires. Preserve private
  artifacts, legacy Introduction/source access, and schema 24. A parser rollback
  returns to the last proven GROBID configuration and does not merge adapters;
- on a private-research exposure, stop the affected routes and telemetry export,
  preserve access-restricted evidence, keep account deletion available when
  safe, and verify the mobile ordinary-SQLite cleanup boundary. Do not describe
  the Drift database as application-layer encrypted or deploy an unreviewed
  SQLCipher/key migration during containment;
- on a reading-feed invariant or queue-authority alert, close
  `TO_READ_FIRST_ENFORCEMENT_ENABLED` first. Close `NOTIFICATIONS_ENABLED`
  before `SUBSCRIPTIONS_ENABLED`, then `READING_BRIEFS_ENABLED` and
  `RECOMMENDATIONS_ENABLED`, before closing `READING_FEED_ENABLED`; the optional
  event stream may close independently. Never fall through to recommendations
  when authority is unknown;
- close `PAPER_TITLE_SEARCH_ENABLED` and
  `LIBRARY_IMPORT_WRITES_ENABLED` independently for search/import incidents,
  and close `PAPER_RESOLUTION_ENABLED` only after both consumers are off;
- close `NOTIFICATIONS_ENABLED` before `SUBSCRIPTIONS_ENABLED`, and close
  `READING_BRIEFS_ENABLED` before the reading feed, for engagement incidents;
- close `RECOMMENDATIONS_ENABLED` and the independent
  `RECOMMENDATION_EVENTS_ENABLED` for ranking, feedback, explanation, or event
  incidents. While reading feed remains on, only its minimal authority-bound
  Recent fallback may continue, still behind proven emptiness and the final
  revision recheck; this must not expose recommendations over an unverified
  queue;
- close `SAVED_QUERIES_ENABLED` before `SEARCH_EXPLORE_ENABLED`, then close
  `SEARCH_LOOKUP_ENABLED` only after Explore is off. These explicit-search
  switches never authorize automatic feed insertion;
- close `RESEARCH_PROFILES_ENABLED` for profile/privacy incidents and
  `LIBRARY_V2_ENABLED` for expanded-Library incidents while preserving their
  parent account/Library reads when safe;
- freeze library writes with `LIBRARY_WRITES_ENABLED=false`;
- stop new posts with `COMMENT_CREATION_ENABLED=false` while preserving reads,
  report/block, author deletion, and moderation;
- disable account/deletion flags only when their full dependency chain is
  unsafe, and keep the deletion worker/ledger under privacy-owner control;
- scale or isolate a failing paper/provider path without removing cached paper
  reads; and
- withdraw telemetry ingress/export if validation or redaction fails. Mobile
  telemetry is best-effort and product behavior must not depend on it.

Do not destroy evidence, purge a deletion record, edit a signed ledger file,
run ad-hoc destructive SQL, broaden network CIDRs, trust arbitrary forwarding
headers, or lower TLS/auth validation during containment.

## Triage by boundary

- **Credential/signing exposure:** revoke/rotate at the provider, update the
  external Secret, increment `secret.rotationVersion`, roll all consumers, and
  retain prior verification/decryption keys only for bounded historical data.
  For a mobile signing key, follow Apple/Play compromise procedures and update
  association files atomically from authoritative installed-app identities.
- **OIDC outage/compromise:** required-auth routes fail closed; confirm guest
  reading remains healthy. Revoke affected clients/sessions, preserve exact
  issuer/audience, and do not switch to a lookalike issuer hostname.
- **Deletion backlog/restore risk:** stop account provisioning/writes if the
  external ledger, keys, worker permission probe, or queue safety is uncertain.
  Run `verify-ledger`; follow
  [account-deletion.md](account-deletion.md) and never skip a record.
- **Database corruption/data loss:** isolate writes, select a verified recovery
  point, and follow [backup-restore.md](backup-restore.md). The current
  independent deletion ledger is mandatory before traffic returns.
- **UGC abuse/moderation:** preserve report/block/admin safety controls, freeze
  creation if ownership/SLA is overwhelmed, and follow
  [moderation.md](moderation.md). Do not expose private moderation reasons.
- **Privacy/logging/telemetry:** stop the affected pipeline, shorten access to
  preserved evidence, verify collector processors and sinks, determine the
  actual fields/retention window, and notify the privacy/security owner.
- **Deep Reader provenance/parser:** close the narrowest Plan 03 switch, reject
  stale generations and invented evidence IDs, preserve original-source access,
  and stop new affected jobs. Treat paper text as untrusted data. Do not
  reprocess, re-anchor uncertain annotations, change the parser default, or
  publish a version diff without the reviewed trigger and rollback plan.
- **Supply-chain/image:** stop promotion, identify the exact digest/SBOM/action
  commit, revoke provenance/signing material if implicated, rebuild from a clean
  reviewed revision, and rescan before rollback or rollout.

## Recovery and closure

Recovery requires cause-specific tests plus guest reading, health/readiness,
error/latency, database, queue, deletion, moderation, and telemetry checks.
Keep schema 24 in place for the current candidate. Re-enable Plan 02 in
dependency order: accounts/Library;
resolution then title search and import independently; reading feed with
enforcement off; Library v2 and research profiles; Lookup then Explore then
saved queries; recommendations and optional events; reading briefs;
subscriptions; notifications; and enforcement only after compatible-client,
SLO/invariant-alert, privacy, retention, and approval gates pass. Then re-enable
Plan 03 in its staged dependency order only after the exact protected gate is
re-run. The historical Plan 02 rule was: Keep schema 18 in place and never
downgrade to schema 11. The current equivalent never restores schema 18 merely
to close Deep Reader. Observe and retain sanitized evidence after each flag.
Do not run a down migration as feature containment. A database restore
additionally requires successful
deletion verification/reapply and privacy approval. A credential rotation
additionally requires proof that old replicas and cached credentials are gone.

Record impact, detection/containment/recovery times, affected versions/data
classes, decisions, notifications, evidence locations, remaining risk, and
owners/dates for corrective work. Exercise at least credential exposure,
provider outage, database restore/deletion replay, and comment-creation freeze
in non-production. Repository tests do not count as a completed organizational
incident exercise.
