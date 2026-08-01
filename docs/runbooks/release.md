# Release, migration, rollback, and store-candidate runbook

**Owner:** release manager. **Approvers:** service owner, database owner,
privacy/safety owner, and mobile signing owner for store candidates.

Repository automation builds candidates and fails closed on missing evidence.
It does not establish live backups, approve production, sign with unavailable
keys, publish legal pages, upload store builds, or manufacture performance and
crash evidence.

## Candidate inputs

- A clean reviewed revision with `./scripts/check.sh` passing and every explicit
  skip resolved for the target environment.
- Matching `0.2.0` Rust workspace, Helm `appVersion`, and mobile version name;
  the mobile build number must exceed both stores' highest uploaded value.
- Immutable backend/site/GROBID/Collector image digests and successful
  vulnerability/license/secret scans, generated CycloneDX SBOMs, notices, and
  checksums.
- Exact HTTPS origins, OIDC realm/clients/redirects, support contact, legal
  version, Play app-signing fingerprint, Apple team/bundle ID, reviewed egress
  CIDRs, ingress proxy source CIDRs, database roles, deletion-ledger claim,
  secret rotation version, OTLP endpoint, and verified backup ID.
- An approved strict-content review and the external evidence listed under
  [mobile release blockers](../mobile-release.md#external-release-blockers).

## Pre-deploy gates

1. Freeze the revision and attach CI/security results. Verify every GitHub
   Action is pinned to a real reviewed commit, not only a mutable tag comment.
2. Verify the backup using [backup-restore.md](backup-restore.md). Put its
   evidence ID in `migration.confirmBackupId`.
3. Render the exact protected values with `helm lint` and `helm template`; run
   `scripts/validate_helm_release.sh`. Compare rendered hosts, identities,
   grants, images, NetworkPolicies, retention, feature flags, and commands to
   the change record. The repository staging fixture is never deployable.
4. Confirm the migration role alone can perform DDL; application roles cannot.
   Confirm worker, API, and synchronization roles use distinct Secret keys.
5. Confirm the deletion worker's `manage-users`-only service account readiness,
   current independent ledger, and alert coverage before enabling deletion.
6. Verify live legal/support/association documents return direct HTTPS 200 with
   expected content types. Verify Nginx real-IP trust and API-observed ingress
   source ranges before relying on comment origin limits.

## Expand/contract deployment

1. Use additive/nullable tables, columns, indexes, and dual-compatible code for
   the expand release. Never combine destructive contraction with the first
   code rollout that stops using a field.
2. Run the chart migration Job once, with the reviewed image digest, distinct
   migration database role, `RUN_MIGRATIONS=false` everywhere else, expected
   migration version, and backup evidence ID. Save Job logs/status without
   secrets. A failed or timed-out migration blocks rollout.
3. Roll out the deletion worker and verify readiness, then paper worker,
   metadata sync, telemetry gateway/Collector, API, and site. Keep accounts,
   library writes, comment creation, and deletion dark until their dependencies
   and smoke checks pass.
4. Exercise guest cached reading first, then authenticated profile/library,
   comments/report/block/moderation, deletion request/status/web callback, paper
   preparation, telemetry redaction/export, and association links. Capture
   aggregate status/latency only.
5. Enable flags independently. `LIBRARY_WRITES_ENABLED=false` preserves reads;
   `COMMENT_CREATION_ENABLED=false` preserves comment/safety reads/actions;
   disabling accounts does not make guest reading depend on OIDC.
6. Observe error rate, readiness, database saturation, queue/backlog age,
   moderation SLA, deletion failures, OTLP drops, and ingress errors through the
   release observation window. Record the exact window and approver.

Contraction is a separate release only after every serving/worker version is
compatible, the compatibility window and rollback retention have elapsed, and
another verified backup exists. Exercise the migration and rollback sequence in
staging; a rendered command is not evidence of execution.

## Rollback

Prefer a forward code rollback to the last schema-compatible image plus feature
kill switches. Do not run destructive down migrations. If the new schema is
backward compatible, roll back API/site/workers and preserve the expanded
schema. If data corruption or an incompatible migration requires restore,
declare an incident, isolate writes, follow [backup-restore.md](backup-restore.md),
mount the current deletion ledger, and reapply deletions before traffic.

Never restore only PostgreSQL while leaving deletion obligations behind. Never
roll a mobile store build backward: increment the build and ship a corrected
candidate.

## Signed mobile/store handoff

Run the manual environment-gated `signed-mobile-release` workflow. It validates
flavor configuration, signing/profile identity, AAB/APK/IPA metadata,
entitlements/links, strict bundled assets, symbols, notices, SBOM, and evidence
hashes. The Android upload-key digest proves candidate custody; association
files use the distinct protected Play App Signing digest. See
[mobile-release.md](../mobile-release.md).

Store owners must supply a disposable reviewer account with verified email,
accepted current terms, no real-user data, no privileged role, and a rotation/
expiry owner. Review notes describe guest reading, sign-in, report/block,
account deletion, web deletion URL, strict metadata/full-text behavior, and any
staging-only coordinates. Credentials stay in store portals, never Git/issues.

TestFlight/closed Play upload, physical-device deep links/callbacks/deletion,
current Data Safety/App Privacy/age-rating forms, review status, measured
startup/cache targets, and a representative crash-free observation window are
external gates. Mark each with evidence or leave the release blocked.
