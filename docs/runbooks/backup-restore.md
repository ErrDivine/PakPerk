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
   a read-only copy; record its exact canonical-record count in the immutable
   inventory; never inspect or copy plaintext provider coordinates. Record an
   explicit zero for an environment with no deletion records rather than
   inferring that an empty or wrong volume is acceptable.
4. Checksums, encryption-at-rest evidence, retention/expiry, region/account,
   and restore permissions are recorded without secrets.
5. `migration.confirmBackupId` names this evidence. Do not reuse a fixture or a
   previous release's identifier.

## Isolated restore and schema gate

1. Create a network-isolated, non-production target with no public ingress,
   API, scheduled job, or deletion worker. Deny outbound identity-admin access
   until deletion replay is ready.
2. Restore PostgreSQL and Keycloak to the selected points. Restore schema and
   data before running a newer migration. Confirm the restored database name
   and expected `_sqlx_migrations` version.
3. Mount the **current** independent ledger and all required keys owner-only.
   Set `APP_ENV` and `ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID` to the same
   `development` or `staging` value. The drill harness refuses production.
4. Install a short-lived guard in the restored database. Use a unique marker
   tied to the change record and an expiry no more than 24 hours away:

   ```sql
   CREATE TABLE public.pakperk_restore_drill_guard (
       marker text PRIMARY KEY,
       expires_at timestamptz NOT NULL
   );
   REVOKE ALL ON public.pakperk_restore_drill_guard FROM PUBLIC;
   INSERT INTO public.pakperk_restore_drill_guard(marker, expires_at)
   VALUES ('restore-CHANGE-ID', statement_timestamp() + interval '2 hours');
   ```

5. Ensure monitoring/admin clients are disconnected. The harness rejects any
   non-drill database session; this prevents replay against a serving target.

## Reapply and finalize

Run the first phase with the exact reviewed worker binary and the same secret
files/configuration intended for the restored environment:

```bash
APP_ENV=staging \
ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID=staging \
PAKPERK_RESTORE_DRILL_CONFIRM=isolated-nonproduction-restore \
PAKPERK_RESTORE_DRILL_PHASE=reapply \
PAKPERK_RESTORE_DRILL_DATABASE=pakperk_restore_change_123 \
PAKPERK_RESTORE_DRILL_MARKER=restore-change-123 \
PAKPERK_RESTORE_DRILL_EVIDENCE_DIR=/secure/evidence/change-123-reapply \
PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS=42 \
PAKPERK_DELETION_WORKER_BIN=/usr/local/bin/pakperk-deletion-worker \
./scripts/drill_backup_restore.sh
```

The script verifies every ledger record before mutation, runs
`reapply-ledger`, proves the summary accounts for every verified record, checks
that matching restored users are disabled, checks every ledger has a job, and
writes owner-only checksummed evidence. It also requires the exact database
name, current migration, expiring guard, environment binding, isolation, and
exact ledger count from the immutable pre-restore inventory. A zero count is
valid only when supplied explicitly; a missing or wrong ledger volume cannot
silently produce passing evidence.

Then permit only the restored deletion worker to reach the restored Keycloak,
start `pakperk-deletion-worker run`, and monitor until every replayed job is
`completed`. A provider absence is idempotent; authentication, authorization,
network, semantic, and terminal failures remain release blockers. Do not open
user traffic. Stop the worker and run the harness again with
`PAKPERK_RESTORE_DRILL_PHASE=finalize` and a new evidence directory. Finalize
requires zero unfinished/terminal jobs, zero matching restored users, intact
ledger verification, and no missing jobs.

Sample each restored data class after finalization: deleted Keycloak identities
are absent; the same issuer/subject cannot JIT-provision; user, library,
comment, block, report, draft/cache, session, and token-related application
rows are absent or pseudonymized according to policy; retained moderation
evidence contains no direct account reference. Record counts, never content.

## Approval and teardown

Evidence must include backup/recovery IDs and timestamps, component versions,
worker image digest, schema version, ledger verification/reapply JSON,
checksums, terminal/unfinished counts, reference device/service checks, RPO/RTO,
operators/change record, and privacy/recovery approvals. Never include database
URLs, tokens, key material, provider coordinates, emails, handles, raw IPs, or
UGC.

After approval, destroy the isolated database, Keycloak target, temporary
secrets, and guard according to the evidence-retention policy. A successful
drill does not authorize production rollback. Repeat after backup topology,
retention, deletion schema, key history, provider realm, or restore tooling
changes, and at the organization's scheduled cadence.
