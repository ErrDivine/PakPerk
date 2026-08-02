# Backup, PITR, restore, and deletion-replay runbook

**Owners:** database recovery owner and privacy/on-call owner.
**Applies to:** PostgreSQL, Keycloak PostgreSQL, the independent signed deletion
ledger, and the key history required to verify/decrypt retained ledger records.

This repository supplies the restore/replay mechanism, but it cannot prove a
hosting provider's snapshots, WAL archive, retention, or recovery time. The
release record must name the environment's measured RPO/RTO, latest verified
backup ID, recovery point, storage inventory, and drill evidence. Until a real
isolated restore completes this runbook, the Phase 6 backup/restore gate is not
passed.

## Non-negotiable topology

- PostgreSQL and Keycloak have separately restorable backups and credentials.
- The final signed deletion-ledger volume is backed up on a recovery timeline
  independent of both databases. A database PITR must mount the current ledger,
  never the ledger snapshot from the older database recovery point.
- Current and retained historical ledger-signing, identity-fingerprint, and
  provider-coordinate encryption keys are recoverable through the secret
  manager. They are not stored in the same backup archive as application data.
- `ACCOUNT_RECOVERABLE_BACKUP_DAYS` covers every snapshot, replica, archive,
  export, and PITR source that can restore pre-deletion personal data. Ledger
  retention is strictly longer. See
  [account-deletion.md](account-deletion.md) before changing either value.
- Backup jobs use read-only/export privileges; restoration uses a dedicated
  isolated target. Migration, API, worker, Keycloak, and backup roles remain
  distinct.

## Backup verification before a release

Record an immutable backup ID in protected release values and verify all of:

1. PostgreSQL base backup/snapshot completed and its WAL/PITR chain reaches the
   declared recovery point.
2. Keycloak backup completed to a compatible point and includes realm state,
   clients, service-account role mappings, and user identities.
3. The current deletion ledger and required historical keys are present in the
   independent inventories. Run `pakperk-deletion-worker verify-ledger` against
   a read-only copy; record both its exact canonical-record count and
   `ledger_inventory_sha256` in the immutable inventory; never inspect or copy
   plaintext provider coordinates. The domain-separated digest binds the signer
   environment and ordered canonical signed-record envelopes, not only their
   count. Record an explicit zero and its environment-specific empty-inventory
   digest when no deletion records exist. A digest commits to the logical
   record set, not a storage device identity; the protected storage inventory
   must independently prove which physical volume or object version was
   mounted.
4. Checksums, encryption-at-rest evidence, retention/expiry, region/account,
   and restore permissions are recorded without secrets.
5. `migration.confirmBackupId` names this evidence. Do not reuse a fixture or a
   previous release's identifier.

## Isolated restore and schema gate

1. Create a network-isolated, non-production target with no public ingress,
   API, scheduled job, or deletion worker. Deny outbound identity-admin access
   until deletion replay is ready.
2. Restore PostgreSQL and Keycloak to the selected points. Restore schema and
   data before running a newer migration. Confirm the restored database name,
   expected `_sqlx_migrations` version, and that `vector`, `pg_trgm`, and
   `pgcrypto` are each installed exactly once in the `public` schema. Extension
   name-only presence is insufficient.
3. Mount the **current** independent ledger and all required keys owner-only.
   Set `APP_ENV` and `ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID` to the same
   `development` or `staging` value. The drill harness refuses production.
4. Install a short-lived guard in the restored database. Use a unique marker
   that is the sanitized durable restore change ID and an expiry no more than
   24 hours away. The harness also uses this exact attested and guard-bound
   marker as the reapply database-audit actor:

   ```sql
   CREATE TABLE public.pakperk_restore_drill_guard (
       marker text PRIMARY KEY,
       backup_id text NOT NULL,
       recovery_point timestamptz NOT NULL,
       restore_attestation_sha256 text NOT NULL,
       expected_ledger_inventory_sha256 text NOT NULL,
       expires_at timestamptz NOT NULL
   );
   REVOKE ALL ON public.pakperk_restore_drill_guard FROM PUBLIC;
   INSERT INTO public.pakperk_restore_drill_guard(
       marker, backup_id, recovery_point, restore_attestation_sha256,
       expected_ledger_inventory_sha256, expires_at
   ) VALUES (
       'restore-CHANGE-ID',
       'backup-change-123-20260802t010000z',
       '2026-08-02T01:00:00Z',
       'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
       'sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
       statement_timestamp() + interval '2 hours'
   );
   ```

5. Ensure monitoring/admin clients are disconnected. The harness rejects any
   other database session. This is a point-in-time observation, not proof of
   network isolation; retain the network-policy evidence separately.

## Reapply and finalize

Run the first phase with the exact reviewed worker binary and the same secret
files/configuration intended for the restored environment. First create a
protected, owner-only, canonical JSON restore attestation. It is a closed
schema: no omitted or additional members, duplicate names, non-finite numbers,
multiple documents, indentation, or alternate key ordering are accepted.

```json
{"backup_id":"backup-change-123-20260802t010000z","backup_observed_at":"2026-08-02T01:02:00Z","database":"pakperk_restore_change_123","environment":"staging","expected_ledger_inventory_sha256":"sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","expected_ledger_records":42,"expected_migration":10,"latest_recoverable_point":"2026-08-02T01:01:00Z","marker":"restore-change-123","recovery_point":"2026-08-02T01:00:00Z","restore_completed_at":"2026-08-02T01:17:00Z","restore_started_at":"2026-08-02T01:02:00Z","schema":2,"source_revision":"0123456789abcdef0123456789abcdef01234567","worker_sha256":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
```

Set its mode to `0600` (or stricter) and record its SHA-256 separately in the
protected release record. The guard row must contain that same digest, backup
ID, and recovery point. Recovery points use canonical whole-second UTC
precision; a fractional database value is rejected rather than silently
truncated. The attestation must complete within the previous 24 hours, and its
chronology must satisfy `recovery_point <=
latest_recoverable_point <= backup_observed_at <= restore_started_at <
restore_completed_at`.

```bash
APP_ENV=staging \
ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID=staging \
PAKPERK_RESTORE_DRILL_CONFIRM=isolated-nonproduction-restore \
PAKPERK_RESTORE_DRILL_PHASE=reapply \
PAKPERK_RESTORE_DRILL_DATABASE=pakperk_restore_change_123 \
PAKPERK_RESTORE_DRILL_MARKER=restore-change-123 \
PAKPERK_RESTORE_DRILL_EVIDENCE_DIR=/secure/evidence/change-123-reapply \
PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS=42 \
PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256=sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
PAKPERK_RESTORE_DRILL_SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567 \
PAKPERK_RESTORE_DRILL_WORKER_SHA256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
PAKPERK_RESTORE_DRILL_BACKUP_ID=backup-change-123-20260802t010000z \
PAKPERK_RESTORE_DRILL_RECOVERY_POINT=2026-08-02T01:00:00Z \
PAKPERK_RESTORE_DRILL_RPO_SECONDS=120 \
PAKPERK_RESTORE_DRILL_RTO_SECONDS=900 \
PAKPERK_RESTORE_DRILL_ATTESTATION=/secure/restore/change-123-attestation.json \
PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
PAKPERK_DELETION_WORKER_BIN=/usr/local/bin/pakperk-deletion-worker \
./scripts/drill_backup_restore.sh
```

Replace every illustrative revision, digest, backup ID, recovery point, and
measured objective with the immutable values from the approved restore record.
The revision must equal the clean checked-out `HEAD`; the worker must be an
executable regular non-symlink file whose SHA-256 matches the reviewed digest.
Backup IDs reject placeholder/fixture shapes. Recovery points must be valid UTC
timestamps. RPO is independently calculated as `backup_observed_at -
recovery_point`; RTO is calculated as `restore_completed_at -
restore_started_at`. The supplied bounded integer values must equal those
calculations exactly. `latest_recoverable_point` records the observed backup
chain reach, but it is deliberately not substituted for the recovery point in
the actual-drill RPO calculation.

The script verifies every ledger record before mutation, runs
`reapply-ledger`, proves the summary accounts for every verified record, checks
that matching restored users are disabled, checks every ledger has a job, and
writes owner-only content-addressed evidence. It also requires the exact database
name, current migration, expiring guard, environment binding, isolation, and
exact ledger count from the immutable pre-restore inventory. A zero count is
valid only when supplied explicitly with the exact empty-inventory digest. The
worker's verification and reapply digests must both equal the protected value,
so a nonempty missing, stale, substituted, or same-count wrong ledger set cannot
silently produce passing evidence. For an empty set, the digest still binds the
declared environment but cannot distinguish two physically different empty
volumes; require the separately protected storage-volume/object-version
inventory. The context records this limitation as
`empty_inventory_digest_does_not_prove_physical_storage_identity`. Keep the
mounted ledger read-only and do not run append or purge
operations between the verification and reapply passes.
Before any advisory lock, migration, or restore-replay mutation, the standalone
migration connection and every pooled worker connection force
`search_path` to exactly `public, pg_catalog`, read it back, and require the
effective current schema to be `public`. The harness does the same for each
`psql` session. This reset occurs after PostgreSQL applies
startup settings, so a `DATABASE_URL` `options` parameter cannot redirect
unqualified objects into an attacker-selected schema. Before its first
database snapshot (and therefore before its first `public.digest` call), the
harness also joins `pg_extension` to `pg_namespace` and fails unless `vector`,
`pg_trgm`, and `pgcrypto` each resolve exactly once from `public`. Application
readiness enforces the same namespace contract.
For reapply, the harness removes any inherited `PAKPERK_ADMIN_ACTOR` and sets it
to the attested restore marker. A caller-controlled actor therefore cannot
replace the durable change ID recorded by PostgreSQL.
For both phases it also forces `RUN_MIGRATIONS=false`; the reviewed worker's
exact readiness check must inspect the recovered migration history without
repairing or advancing it first, including when `APP_ENV=development`.

The harness copies the already-read, reviewed worker bytes into private staging,
binds that copy's digest, runs only the copy, bounds and privately captures its
stdout/stderr, and publishes nothing on a failed run. The same-UID recovery
operator remains inside the trust boundary: portable owner permissions and a
local digest do not make a file immutable against a deliberately malicious
same-UID process. The evidence target must be a fresh absolute path; existing
targets, symlink targets, and symlinked parent components fail during
protected-input preparation before any database or worker operation.

The owner-only manifest binds schema version, source revision, worker digest,
restore-attestation digest, backup identifier, restored recovery point,
attested RPO/RTO timestamps, migration, environment, database, marker, phase,
and exact ledger count and inventory digest. The attested marker is also the
database reapply audit actor. The database guard independently
repeats the database, marker, backup ID, recovery point, attestation digest, and
expected inventory digest. The final context records the database's observed
ledger count plus the expected, verified, and (during reapply) reapplied
inventory digests and requires exact cross-file equality. The hermetic
self-test exercises production preflight,
database snapshot, worker-summary, evidence-closure, and failure paths through
fake dependencies; it does not claim that a real database or backup was
restored.

Each phase also fails if any required account, paper, core-job, library,
comment/safety, or deletion table is absent. Its checksummed database snapshots
record row counts for `users`, `papers`, `jobs`, `user_paper_library`,
`library_operations`, `paper_comments`, `comment_reports`, `user_reports`,
`user_blocks`, the deletion ledger, and deletion jobs. Each snapshot also
records `local_deletion_bindings_sha256`. This digest commits to an ordered
canonical JSONB array under the fixed
`pakperk-local-account-deletion-bindings-v1` domain: every ledger operation UUID,
original-user UUID, fingerprint key ID and fingerprint bytes, plus the joined
job operation UUID, target-user UUID, fingerprint binding, and nullable provider
binding. UUIDs use PostgreSQL's canonical text form, bytes use lowercase hex,
nulls and array boundaries are explicit, and rows are ordered by operation UUID,
so concatenation and ordering cannot collide. Provider issuer/subject strings
never enter evidence; only their nested, domain-separated SHA-256 participates
in the outer digest. Paper and core-job counts must remain unchanged across
ledger verification/reapplication; account-owned counts may decrease as
deletion obligations are correctly replayed.

Then permit only the restored deletion worker to reach the restored Keycloak,
start `pakperk-deletion-worker run`, and monitor until every replayed job is
`completed`. A provider absence is idempotent; authentication, authorization,
network, semantic, and terminal failures remain release blockers. Do not open
user traffic. Stop the worker and run the harness again with
`PAKPERK_RESTORE_DRILL_PHASE=finalize` and a new evidence directory. Finalize
requires zero unfinished/terminal jobs, zero matching restored users, intact
ledger verification, and no missing jobs. Reuse the identical source revision,
worker digest, backup ID, recovery point, and measured RPO/RTO so the two
artifacts describe one restore exercise. It also requires
`PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID` set to the externally anchored
`pakperk-restore-evidence-v2:sha256:...` ID printed by the reapply phase and
`PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR` set to the absolute directory
containing that actual package. Finalize fully verifies the prior package and
requires its computed ID to match, its restore-attestation bytes to be identical,
its `recorded_at` not to follow finalize, and its post-reapply paper/core-job
counts, migration, local-ledger count, and local deletion-ledger/job binding
digest to equal finalize's pre-run snapshot. Finalize is read-only: every
database snapshot member, including the binding digest, must be identical before
and after its verification, with the exact ledger inventory represented locally
and no user row matching a ledger original UUID/fingerprint, job target UUID,
or job issuer/subject; unsafe active match; missing job; unfinished job; or
terminal job. A `deletion_pending` user may exist immediately after reapply,
including a provider-matched row restored under a new local UUID, but must be
absent after the deletion worker finishes and before finalize. A fabricated or
unavailable ID is not a chain.
Both phases require `recorded_at` from restore
completion through no more than 24 hours afterward, with the existing
five-minute future-skew cap.

Offline verification repeats the same chain checks. A finalize package cannot
be verified from its ID alone:

```bash
python3 -I -B scripts/restore_drill_evidence.py verify-package \
  /secure/evidence/change-123-finalize \
  --prior-reapply-evidence-dir /secure/evidence/change-123-reapply
```

Sample each restored data class after finalization: paper metadata and core-job
records are intact; deleted Keycloak identities are absent; the same
issuer/subject cannot JIT-provision; user, library, comment, block, report,
draft/cache, session, and token-related application rows are absent or
pseudonymized according to policy; retained moderation evidence contains no
direct account reference. Record counts and keyed integrity results, never
content.

## Approval and teardown

Evidence must include backup/recovery IDs and timestamps, component versions,
worker image digest, schema version, exact ledger count, external inventory
digest, and local ledger/job binding digest, ledger verification/reapply JSON,
checksums, terminal/unfinished counts, reference device/service checks, RPO/RTO,
operators/change record, and privacy/recovery approvals. Never include database
URLs, tokens, key material, provider coordinates, emails, handles, raw IPs, or
UGC.

On success the new evidence directory contains only
`pakperk-restore-evidence.tar` and `PACKAGE_SHA256.json`, both owner-readable
regular files with one link. The deterministic tar contains canonical JSON and
`SHA256SUMS`; the script reopens it, validates the closed member set, and
recomputes every checksum and the domain-separated content ID before reporting
success. Record that printed content ID in an append-only release system outside
the runner. Local permissions and checksums detect change relative to that
anchor but cannot prevent the owner from replacing both local files.

Schema-2 attestations and schema-2 packages use the
`pakperk-restore-evidence-v2:sha256:` content-ID domain. Current tooling rejects
schema-1 attestations, v1 packages, and a v1 prior reapply ID. Historical v1
evidence remains auditable with its pinned historical source revision, but it
cannot satisfy or chain into this exact-inventory release gate.

The restore attestation binds a protected provider/operator statement to the
database guard and result; it does **not** independently prove the hosting
provider's backup ID, WAL reach, timestamps, or restore operation. Preserve the
provider's signed receipts or control-plane audit records alongside the external
content-ID anchor.

After approval, destroy the isolated database, Keycloak target, temporary
secrets, and guard according to the evidence-retention policy. A successful
drill does not authorize production rollback. Repeat after backup topology,
retention, deletion schema, key history, provider realm, or restore tooling
changes, and at the organization's scheduled cadence.
