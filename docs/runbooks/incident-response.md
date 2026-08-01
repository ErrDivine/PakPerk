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
- **Supply-chain/image:** stop promotion, identify the exact digest/SBOM/action
  commit, revoke provenance/signing material if implicated, rebuild from a clean
  reviewed revision, and rescan before rollback or rollout.

## Recovery and closure

Recovery requires cause-specific tests plus guest reading, health/readiness,
error/latency, database, queue, deletion, moderation, and telemetry checks.
Re-enable the narrowest flag first and observe before the next. A database
restore additionally requires successful deletion verification/reapply and
privacy approval. A credential rotation additionally requires proof that old
replicas and cached credentials are gone.

Record impact, detection/containment/recovery times, affected versions/data
classes, decisions, notifications, evidence locations, remaining risk, and
owners/dates for corrective work. Exercise at least credential exposure,
provider outage, database restore/deletion replay, and comment-creation freeze
in non-production. Repository tests do not count as a completed organizational
incident exercise.
