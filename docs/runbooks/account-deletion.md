# Account deletion and restore runbook

**Owner:** the production privacy/on-call operator.
**Backup:** the production incident commander and database recovery owner.
**Safety boundary:** account deletion must stay enabled only while the API,
dedicated deletion worker, external signed ledger, Keycloak service account,
and alerts are healthy.

## Retention invariant

The signed external ledger is the restore authority for deletion obligations.
It must not share the database's recovery timeline: restoring PostgreSQL or
Keycloak to an earlier point must not roll the external ledger back.

`ACCOUNT_RECOVERABLE_BACKUP_DAYS` is the longest period for which any
PostgreSQL, Keycloak, volume, snapshot, PITR, archive, or replicated backup can
restore personal data that predates a deletion. Set it from the real backup
policy, not from a desired value. The worker and API refuse invalid policy when
`ACCOUNT_DELETION_LEDGER_RETENTION_DAYS` is not strictly greater than that
horizon. Database ledger cleanup additionally requires a completed,
externalized operation whose configured retention has expired **and** a
successfully audited external purge; retryable, terminal, and merely expired
obligations are not removed.

Final `<operation-uuid>.json` files are immutable and are never deleted by
routine Pakperk cleanup. Each contains AEAD-encrypted provider issuer/subject
coordinates so a pre-delete Keycloak restore can be reconciled even when the
post-purge application database has no user row. The AEAD associated data binds
the schema, environment, operation, app user UUID, fingerprint, request time,
and encryption-key ID; the outer signature binds the complete ciphertext.

Storage policy must retain each final record until every backup with a recovery
point before the operation's latest completion is irrecoverable, plus any
longer security/legal retention. Do not add a blanket PVC/object lifecycle from
`ACCOUNT_DELETION_LEDGER_RETENTION_DAYS`. Final removal is performed only by the
operator-controlled `purge-ledger` flow below after both time-based retention
and concrete backup evidence pass.

When backup retention grows, first extend external-ledger retention and retain
the required historical signing, identity-fingerprint, and provider-coordinate
decryption keys; then raise `ACCOUNT_RECOVERABLE_BACKUP_DAYS`. A deployment that
fails this ordering must remain unavailable rather than weaken the invariant.

## Normal operation

Run `/usr/local/bin/pakperk-deletion-worker run` as a single-purpose deployment.
Only `run` loads the Keycloak admin client and therefore requires:

- `IDENTITY_ADMIN_PROVIDER=keycloak`;
- `KEYCLOAK_ADMIN_BASE_URL`, `KEYCLOAK_REALM`, and
  `KEYCLOAK_ADMIN_CLIENT_ID`;
- an owner-only, non-symlink `KEYCLOAK_ADMIN_CLIENT_SECRET_FILE`; and
- `OIDC_ISSUER_URL` whose path ends exactly in
  `/realms/${KEYCLOAK_REALM}`.

Startup performs a client-credentials exchange followed by two
non-destructive, permissioned reads of the reserved absent user UUID
`00000000-0000-0000-0000-000000000000`: a direct lookup must return bounded
`404 Not Found`, then an ID-prefixed user query bounded to one result must
return `200`, JSON content type, and the empty array `[]`. Keycloak's
`manage-users` role authorizes this query without an extra `query-users` grant.
Requiring the second positive Keycloak response prevents a reverse proxy that
returns a generic 404 for every admin path from passing readiness. Invalid
credentials, a missing `realm-management/manage-users` grant (`401`/`403`),
redirects, unexpected statuses or response shapes, non-empty results,
oversized responses, provider 408/429/5xx, network failure, or malformed token
responses fail startup. The probe never returns a real user, logs out, changes,
or deletes one. The process removes
`/tmp/pakperk-deletion-worker-ready` before initialization, publishes it
owner-only only after database/ledger checks and this permission probe pass,
and removes it on graceful exit. Kubernetes readiness must test for that exact
file (with a short initial delay so startup clearing happens before the first
probe), not merely test that the process exists. The API rollout must not be
released unless the dedicated worker Deployment becomes Ready.

List, inspect, retry, ledger verification/reapply/purge, and cleanup are database
or ledger maintenance commands and deliberately do not initialize Keycloak or
read its secret. Set `PAKPERK_ADMIN_ACTOR` to a durable incident/change record
identifier; never use a person's email address or put credentials in the value.
Purge rejects actor values containing `@`.

Useful bounded commands are:

```text
pakperk-deletion-worker list --state failed_terminal --limit 100
pakperk-deletion-worker inspect <operation-uuid>
PAKPERK_ADMIN_ACTOR=<change-id> pakperk-deletion-worker retry <operation-uuid>
pakperk-deletion-worker verify-ledger
PAKPERK_ADMIN_ACTOR=<restore-id> pakperk-deletion-worker reapply-ledger
PAKPERK_ADMIN_ACTOR=<change-id> pakperk-deletion-worker purge-ledger <operation-uuid> --oldest-recoverable-at 2027-12-01T00:00:00.000Z --evidence-id <backup-inventory-id>
pakperk-deletion-worker cleanup
```

`verify-ledger` and `reapply-ledger` scan canonical UUID filenames in bounded
pages. Every file is checked for owner-only permissions, regular-file type,
filename/record agreement, exact canonical bytes, environment binding, and a
signature from the current or retained historical key. Verification also
decrypts the protected provider coordinates with the current or retained
historical AEAD key and recomputes the stored fingerprint. Any unknown file,
unknown signing/decryption key, malformed pending name, symlink, hardening
violation, signature/AEAD failure, fingerprint mismatch, or record conflict
fails the entire scan closed. Do not move diagnostic files into the ledger
directory.

The worker treats an already absent Keycloak session or identity as success.
Network failures, provider 408/429/5xx, step timeouts, and post-start `401`/`403`
responses use the same bounded attempt budget and backoff. The latter allows a
replacement pod with a corrected rotated secret or `manage-users` role to
resume the obligation; it still reaches `failed_terminal` and alerts when the
configured maximum is exhausted. Semantic provider rejections remain terminal
immediately and require operator review plus an explicit `retry`. Never repair
state by editing deletion tables or signed JSON.

## Crash residue and cleanup

Publishing a final record uses a synced owner-only pending file followed by a
same-filesystem no-replace hard link and directory sync. A crash can leave
`.pending-<operation-uuid>-<temporary-uuid>.tmp` behind, either unpublished or
as an extra link to an already published final record. Removing that old name
is safe: an unpublished obligation remains in the database and is recreated
before provider deletion, while a published record retains its final link.

The running worker checks cleanup on every loop iteration, including under a
continuously full queue. It and the explicit `cleanup` command remove at most
`ACCOUNT_DELETION_CLEANUP_BATCH_SIZE` pending files per pass and only when they:

- have the exact pending filename grammar;
- are regular, non-symlink, owner-only files owned like the ledger directory;
- have no unexpected hard links; and
- are older than `ACCOUNT_DELETION_PENDING_FILE_MAX_AGE_SECONDS` (minimum five
  minutes, default one hour).

Routine cleanup never touches final JSON. Do not manually glob-remove files. Alert on
`error.kind=external_ledger`, failed verification, stale-pending growth beyond
two cleanup intervals, or ledger-volume capacity thresholds. Resolve unsafe
names/links as a storage-integrity incident before resuming the worker.

## Final ledger lifecycle purge

Use `purge-ledger` for one operation only after the privacy owner verifies all
of the following:

- the operation is externally acknowledged and completed;
- the latest completion is older than the maximum of configured ledger
  retention and recoverable-backup horizon;
- the supplied `--oldest-recoverable-at` is a past, inventory-proven boundary
  later than that completion, covering PostgreSQL, Keycloak, ledger-volume,
  snapshot, replica, archive, and PITR stores; and
- `--evidence-id` and `PAKPERK_ADMIN_ACTOR` identify durable backup-inventory
  and approved change records, not a person or credential.

The command verifies and decrypts the exact final record, writes authorization
evidence to PostgreSQL, unlinks only that canonical file, syncs its directory,
and records completion. A crash before unlink leaves the file; a crash after
unlink resumes from the authorization and treats absence as idempotent. New
authorization fails if the file is already absent, evidence conflicts, the
operation is incomplete, retention has not elapsed, the backup boundary is in
the future/too old, or verification fails. Routine database cleanup can remove
the fingerprint/user-bearing job and ledger only after this purge record says
the external unlink completed; the minimal operation/change audit later expires
under security retention.

Live unlink is not immediate physical erasure from backups of the external
ledger itself. Those backups may retain the encrypted coordinates until their
declared recovery horizon expires. The privacy disclosure and deletion response
must describe this residual protected-backup window. The purge evidence must
cover that storage class, and its legacy AEAD key remains protected until every
record or backup encrypted by it is gone; destroying a still-needed key would
make restore verification fail closed.

## Restore drill and production restore

1. Isolate the restored environment from user and worker traffic. Keep account
   provisioning and writes disabled.
2. Restore PostgreSQL and, if required, Keycloak to the selected recovery
   points. Mount the **current independent external ledger**, not a ledger
   snapshot from the database recovery point.
3. Mount the current signing/fingerprint/provider-coordinate key files together
   with every legacy verification/decryption key needed by retained records.
   Files and the ledger directory must remain owner-only and non-symlink.
4. Confirm `APP_ENV` and
   `ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID` are the same canonical value
   (`development`, `staging`, or `production`). Never reapply one environment's
   records to another.
5. Run `pakperk-deletion-worker verify-ledger`. Stop on any failure; do not skip
   or rewrite the offending record.
6. Run
   `PAKPERK_ADMIN_ACTOR=<restore-change-id> pakperk-deletion-worker reapply-ledger`.
   This restores missing tombstones, immediately disables any resurrected local
   account, decrypts provider coordinates, and queues provider deletion even
   when the local user row is absent. A completed local operation is
   intentionally requeued because Keycloak may have an older recovery point.
7. Start `pakperk-deletion-worker run` with the correctly scoped Keycloak
   service account. Monitor the queue until requeued operations complete.
8. Repeat `verify-ledger`, but do not run a second post-completion reapply for
   the same restore: it intentionally requests another provider reconciliation.
   A command retry while work remains is safe. Inspect terminal failures and
   retry only after their cause is fixed.
9. Verify samples from each restored data class and Keycloak: deleted identities
   are absent, accounts cannot be JIT-provisioned from the same issuer/subject,
   private application rows are gone, and retained moderation evidence is
   pseudonymized.
10. Record recovery point/time, ledger verification count, reapply summary,
    terminal-failure count, operator, and timestamps. Re-enable traffic only
    after the privacy owner approves this evidence.

Exercise this procedure against a non-production restore whenever the backup
topology, retention, signing-key set, Keycloak realm, or deletion schema
changes, and at the regular restore-drill cadence.
