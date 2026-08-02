use std::time::Duration;

use chrono::{TimeDelta, Utc};
use db::{
    AccountDeletionRepository, AccountDeletionRequest, AccountDeletionRequestOutcome,
    AdminCommentAction, Database, DbError, DeletionReapplyAction,
    ExternalLedgerPurgeAuthorizationState, LibraryMutationIntent, LibraryMutationOutcome,
    StoredAdminActor, UserReportOutcome,
};
use domain::{
    AccountDeletionState, ArxivIdentifier, Author, CommentReportReason, IdentityFingerprint,
    LibraryState, PaperMetadata,
};
use url::Url;
use uuid::Uuid;

#[path = "../../../test_support/account_deletion_queue_guard.rs"]
mod account_deletion_queue_guard;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_deletion_request_rotation_lease_retention_and_restore_reapply() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL account-deletion coverage");
        return;
    };
    let database = Database::connect(&database_url, 24).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let _queue_isolation = account_deletion_queue_guard::acquire(&database)
        .await
        .unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://deletion.test/{unique}");
    let subject = format!("subject-{unique}");
    let current = fingerprint("current", 0x11);
    let legacy = fingerprint("legacy", 0x22);
    let candidates = vec![current.clone(), legacy.clone()];
    let accounts = database.accounts();
    let user = accounts
        .provision_oidc_identity_guarded(
            &issuer,
            &subject,
            Duration::from_secs(900),
            std::slice::from_ref(&legacy),
        )
        .await
        .unwrap();

    // A normal request under a rotated key converges the active row to the
    // current fingerprint before deletion.
    accounts
        .provision_oidc_identity_guarded(&issuer, &subject, Duration::from_secs(900), &candidates)
        .await
        .unwrap();
    let persisted_key: String =
        sqlx::query_scalar("SELECT identity_fingerprint_key_id FROM users WHERE id = $1")
            .bind(user.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(persisted_key, "current");

    // JIT and deletion share all fingerprint locks. Whichever transaction
    // wins, the durable tombstone wins the final state and future JIT fails.
    let deletion_repository = database.account_deletions();
    let delete_task = {
        let repository = deletion_repository.clone();
        let issuer = issuer.clone();
        let subject = subject.clone();
        let candidates = candidates.clone();
        tokio::spawn(async move {
            repository
                .request(
                    &issuer,
                    &subject,
                    &candidates,
                    2,
                    Duration::from_secs(3600),
                    12,
                )
                .await
        })
    };
    let jit_task = {
        let accounts = accounts.clone();
        let issuer = issuer.clone();
        let subject = subject.clone();
        let candidates = candidates.clone();
        tokio::spawn(async move {
            accounts
                .provision_oidc_identity_guarded(
                    &issuer,
                    &subject,
                    Duration::from_secs(900),
                    &candidates,
                )
                .await
        })
    };
    let mut request = accepted(delete_task.await.unwrap().unwrap());
    let jit_result = jit_task.await.unwrap();
    assert!(jit_result.is_ok() || matches!(jit_result, Err(DbError::IdentityTombstoned)));
    assert!(matches!(
        accounts
            .provision_oidc_identity_guarded(
                &issuer,
                &subject,
                Duration::from_secs(900),
                &candidates,
            )
            .await,
        Err(DbError::IdentityTombstoned)
    ));
    let replay = accepted(
        deletion_repository
            .request(
                &issuer,
                &subject,
                &candidates,
                2,
                Duration::from_secs(3600),
                12,
            )
            .await
            .unwrap(),
    );
    assert!(replay.replayed);
    assert_eq!(
        replay.operation.operation_id,
        request.operation.operation_id
    );
    let backlog = deletion_repository.backlog_metrics().await.unwrap();
    assert!(backlog.unfinished_count >= 1);
    assert!(
        backlog
            .oldest_unfinished_age_seconds
            .is_some_and(|age| age.is_finite() && age >= 0.0)
    );
    assert_eq!(
        deletion_repository
            .verify_identity(&issuer, &subject, &candidates)
            .await
            .unwrap()
            .unwrap()
            .operation_id,
        Some(request.operation.operation_id)
    );

    // A denied request commits the shared bucket but performs no account or
    // ledger mutation.
    let denied_subject = format!("denied-{unique}");
    let denied_fingerprint = fingerprint("current", 0x33);
    let denied_user = accounts
        .provision_oidc_identity_guarded(
            &issuer,
            &denied_subject,
            Duration::from_secs(900),
            std::slice::from_ref(&denied_fingerprint),
        )
        .await
        .unwrap();
    sqlx::query(
        r"
        INSERT INTO shared_rate_limit_buckets (
            bucket, scope_key, window_started_at, window_ends_at, request_count
        ) VALUES ('account_delete', $1, statement_timestamp(),
                  statement_timestamp() + interval '1 hour', 1)
        ON CONFLICT (bucket, scope_key) DO UPDATE
        SET request_count = 1,
            window_started_at = statement_timestamp(),
            window_ends_at = statement_timestamp() + interval '1 hour'
        ",
    )
    .bind(format!("user:{}", denied_user.id))
    .execute(database.pool())
    .await
    .unwrap();
    assert!(matches!(
        deletion_repository
            .request(
                &issuer,
                &denied_subject,
                std::slice::from_ref(&denied_fingerprint),
                1,
                Duration::from_secs(3600),
                12,
            )
            .await
            .unwrap(),
        AccountDeletionRequestOutcome::RateLimited { .. }
    ));
    let (denied_status, denied_count): (String, i64) = sqlx::query_as(
        r"
        SELECT users.status, buckets.request_count
        FROM users
        JOIN shared_rate_limit_buckets buckets
          ON buckets.scope_key = 'user:' || users.id::text
         AND buckets.bucket = 'account_delete'
        WHERE users.id = $1
        ",
    )
    .bind(denied_user.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(denied_status, "active");
    assert_eq!(denied_count, 2);

    // Simulate durable external append followed by a crash before the local
    // acknowledgement: the pending request remains claimable and marking is
    // repeat-safe.
    assert!(!request.externalized);
    deletion_repository
        .mark_externalized(request.operation.operation_id)
        .await
        .unwrap();
    deletion_repository
        .mark_externalized(request.operation.operation_id)
        .await
        .unwrap();

    let stale = deletion_repository
        .claim("stale-worker", Duration::from_secs(5))
        .await
        .unwrap()
        .unwrap();
    sqlx::query(
        "UPDATE account_deletion_jobs SET lease_expires_at = statement_timestamp() - interval '1 second' WHERE operation_id = $1",
    )
    .bind(stale.operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    let fresh = deletion_repository
        .claim("fresh-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(fresh.operation_id, stale.operation_id);
    assert!(
        !deletion_repository
            .advance(
                stale.operation_id,
                "stale-worker",
                AccountDeletionState::Requested,
                AccountDeletionState::SessionsRevoked,
            )
            .await
            .unwrap()
    );
    assert!(
        deletion_repository
            .advance(
                fresh.operation_id,
                "fresh-worker",
                AccountDeletionState::Requested,
                AccountDeletionState::SessionsRevoked,
            )
            .await
            .unwrap()
    );
    advance_claimed(
        &deletion_repository,
        "fresh-worker",
        AccountDeletionState::SessionsRevoked,
        AccountDeletionState::IdentityDeleted,
    )
    .await;
    let purge_job = deletion_repository
        .claim("fresh-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert!(
        deletion_repository
            .purge_app_data(
                &purge_job,
                "fresh-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
            .unwrap()
    );
    let completion = deletion_repository
        .claim("fresh-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert!(
        deletion_repository
            .complete(
                completion.operation_id,
                "fresh-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
            .unwrap()
    );

    sqlx::query(
        "UPDATE account_deletion_ledger SET expires_at = statement_timestamp() WHERE operation_id = $1",
    )
    .bind(request.operation.operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        "UPDATE account_deletion_events SET expires_at = statement_timestamp() WHERE operation_id = $1",
    )
    .bind(request.operation.operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    // Routine cleanup cannot erase the restore authority even after expiry.
    assert!(deletion_repository.cleanup_retention(100).await.unwrap() > 0);
    assert!(
        deletion_repository
            .get_status(request.operation.operation_id)
            .await
            .unwrap()
            .is_some()
    );
    assert!(
        deletion_repository
            .external_record_required(request.operation.operation_id)
            .await
            .unwrap()
    );
    assert!(
        deletion_repository
            .begin_external_ledger_purge(
                request.operation.operation_id,
                Some(&request.ledger),
                Duration::from_secs(2 * 24 * 60 * 60),
                Duration::from_secs(24 * 60 * 60),
                Utc::now(),
                "backup-proof-early",
                "change-early",
            )
            .await
            .is_err()
    );
    request.ledger.requested_at = sqlx::query_scalar(
        r"
        UPDATE account_deletion_ledger
        SET requested_at = statement_timestamp() - interval '4 days',
            completed_at = statement_timestamp() - interval '3 days',
            expires_at = statement_timestamp()
        WHERE operation_id = $1
        RETURNING requested_at
        ",
    )
    .bind(request.operation.operation_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    sqlx::query(
        "UPDATE account_deletion_jobs SET created_at = statement_timestamp() - interval '4 days', updated_at = statement_timestamp() - interval '3 days' WHERE operation_id = $1",
    )
    .bind(request.operation.operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    let oldest_recoverable_at = chrono::DateTime::from_timestamp_millis(
        (Utc::now() - chrono::TimeDelta::days(1)).timestamp_millis(),
    )
    .unwrap();
    let authorization = deletion_repository
        .begin_external_ledger_purge(
            request.operation.operation_id,
            Some(&request.ledger),
            Duration::from_secs(2 * 24 * 60 * 60),
            Duration::from_secs(24 * 60 * 60),
            oldest_recoverable_at,
            "backup-proof-final",
            "change-final",
        )
        .await
        .unwrap();
    assert_eq!(
        authorization.state,
        ExternalLedgerPurgeAuthorizationState::Authorized
    );
    assert!(
        !deletion_repository
            .external_record_required(request.operation.operation_id)
            .await
            .unwrap()
    );
    assert!(
        deletion_repository
            .reapply_verified_tombstone(
                &request.ledger,
                &issuer,
                &subject,
                12,
                "restore-after-purge-start",
            )
            .await
            .is_err()
    );
    let resumed = deletion_repository
        .begin_external_ledger_purge(
            request.operation.operation_id,
            None,
            Duration::from_secs(2 * 24 * 60 * 60),
            Duration::from_secs(24 * 60 * 60),
            oldest_recoverable_at,
            "backup-proof-final",
            "change-final",
        )
        .await
        .unwrap();
    assert_eq!(
        resumed.state,
        ExternalLedgerPurgeAuthorizationState::Resumed
    );
    assert!(
        deletion_repository
            .begin_external_ledger_purge(
                request.operation.operation_id,
                None,
                Duration::from_secs(2 * 24 * 60 * 60),
                Duration::from_secs(24 * 60 * 60),
                oldest_recoverable_at,
                "different-proof",
                "change-final",
            )
            .await
            .is_err()
    );
    deletion_repository
        .finish_external_ledger_purge(
            request.operation.operation_id,
            "backup-proof-final",
            "change-final",
            Duration::from_secs(24 * 60 * 60),
        )
        .await
        .unwrap();
    let already_purged = deletion_repository
        .begin_external_ledger_purge(
            request.operation.operation_id,
            None,
            Duration::from_secs(2 * 24 * 60 * 60),
            Duration::from_secs(24 * 60 * 60),
            oldest_recoverable_at,
            "backup-proof-final",
            "change-final",
        )
        .await
        .unwrap();
    assert_eq!(
        already_purged.state,
        ExternalLedgerPurgeAuthorizationState::AlreadyPurged
    );
    assert!(deletion_repository.cleanup_retention(100).await.unwrap() > 0);
    assert!(
        deletion_repository
            .get_status(request.operation.operation_id)
            .await
            .unwrap()
            .is_none()
    );

    // Simulate a database recovery point from before purge authorization while
    // the independently retained external record remains available.
    sqlx::query("DELETE FROM account_deletion_external_purges WHERE operation_id = $1")
        .bind(request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();

    // Skewed restore: PostgreSQL is post-app-purge (no user row), while the
    // provider may have been restored to a pre-delete point. Protected
    // external coordinates must still queue provider reconciliation.
    let provider_only = deletion_repository
        .reapply_verified_tombstone(&request.ledger, &issuer, &subject, 12, "restore-skew")
        .await
        .unwrap();
    assert_eq!(
        provider_only.action,
        DeletionReapplyAction::RestoredAndQueued
    );
    let restored_provider: (String, String, String) = sqlx::query_as(
        "SELECT state, oidc_issuer, oidc_subject FROM account_deletion_jobs WHERE operation_id = $1",
    )
    .bind(request.operation.operation_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        restored_provider,
        ("requested".to_owned(), issuer.clone(), subject.clone())
    );

    // A restore can retain the completed ledger while losing its job. The
    // recreated obligation must reset the old completion/expiry timeline.
    sqlx::query("DELETE FROM account_deletion_jobs WHERE operation_id = $1")
        .bind(request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query(
        r"
        UPDATE account_deletion_ledger
        SET completed_at = statement_timestamp(),
            expires_at = statement_timestamp() + interval '1 day'
        WHERE operation_id = $1
        ",
    )
    .bind(request.operation.operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    let restored_missing_job = deletion_repository
        .reapply_verified_tombstone(
            &request.ledger,
            &issuer,
            &subject,
            12,
            "restore-missing-job",
        )
        .await
        .unwrap();
    assert_eq!(
        restored_missing_job.action,
        DeletionReapplyAction::RestoredAndQueued
    );
    let reset_completion: (bool, bool) = sqlx::query_as(
        r"
        SELECT completed_at IS NULL, expires_at IS NULL
        FROM account_deletion_ledger
        WHERE operation_id = $1
        ",
    )
    .bind(request.operation.operation_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(reset_completion, (true, true));

    // A restored job can satisfy the schema's separate operation and
    // fingerprint foreign keys while cross-wiring two tombstones. Reapply
    // must fail closed instead of deleting the unrelated job user.
    let decoy_operation_id = Uuid::now_v7();
    let decoy_user_id = Uuid::now_v7();
    let decoy_fingerprint = fingerprint("decoy", 0x44);
    sqlx::query(
        r"
        INSERT INTO account_deletion_ledger (
            operation_id, original_user_id,
            identity_fingerprint_key_id, identity_fingerprint,
            requested_at, externalized_at
        ) VALUES ($1, $2, $3, $4, statement_timestamp(), statement_timestamp())
        ",
    )
    .bind(decoy_operation_id)
    .bind(decoy_user_id)
    .bind(decoy_fingerprint.key_id())
    .bind(decoy_fingerprint.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        UPDATE account_deletion_jobs
        SET identity_fingerprint_key_id = $2,
            identity_fingerprint = $3
        WHERE operation_id = $1
        ",
    )
    .bind(request.operation.operation_id)
    .bind(decoy_fingerprint.key_id())
    .bind(decoy_fingerprint.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    assert!(
        deletion_repository
            .reapply_verified_tombstone(
                &request.ledger,
                &issuer,
                &subject,
                12,
                "restore-crosswired-fingerprint",
            )
            .await
            .is_err()
    );
    sqlx::query(
        r"
        UPDATE account_deletion_jobs
        SET identity_fingerprint_key_id = $2,
            identity_fingerprint = $3
        WHERE operation_id = $1
        ",
    )
    .bind(request.operation.operation_id)
    .bind(request.ledger.fingerprint.key_id())
    .bind(request.ledger.fingerprint.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query("UPDATE account_deletion_jobs SET user_id = $2 WHERE operation_id = $1")
        .bind(request.operation.operation_id)
        .bind(decoy_user_id)
        .execute(database.pool())
        .await
        .unwrap();
    assert!(
        deletion_repository
            .reapply_verified_tombstone(
                &request.ledger,
                &issuer,
                &subject,
                12,
                "restore-crosswired-user",
            )
            .await
            .is_err()
    );
    sqlx::query("UPDATE account_deletion_jobs SET user_id = $2 WHERE operation_id = $1")
        .bind(request.operation.operation_id)
        .bind(request.ledger.original_user_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_ledger WHERE operation_id = $1")
        .bind(decoy_operation_id)
        .execute(database.pool())
        .await
        .unwrap();

    // The historical UUID is only a locator, not sufficient identity proof.
    // Ambiguous rows must fail closed instead of having unrelated data erased.
    sqlx::query("INSERT INTO users (id, status) VALUES ($1, 'active')")
        .bind(request.ledger.original_user_id)
        .execute(database.pool())
        .await
        .unwrap();
    assert!(
        deletion_repository
            .reapply_verified_tombstone(
                &request.ledger,
                &issuer,
                &subject,
                12,
                "restore-unbound-original-uuid",
            )
            .await
            .is_err()
    );
    let unbound_status: String = sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
        .bind(request.ledger.original_user_id)
        .fetch_one(database.pool())
        .await
        .unwrap();
    assert_eq!(unbound_status, "active");
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(request.ledger.original_user_id)
        .execute(database.pool())
        .await
        .unwrap();

    sqlx::query(
        r"
        INSERT INTO users (
            id, status, identity_fingerprint_key_id, identity_fingerprint
        ) VALUES ($1, 'active', $2, $3)
        ",
    )
    .bind(request.ledger.original_user_id)
    .bind(legacy.key_id())
    .bind(legacy.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    assert!(
        deletion_repository
            .reapply_verified_tombstone(
                &request.ledger,
                &issuer,
                &subject,
                12,
                "restore-mismatched-original-uuid",
            )
            .await
            .is_err()
    );
    let mismatched_fingerprint: Vec<u8> =
        sqlx::query_scalar("SELECT identity_fingerprint FROM users WHERE id = $1")
            .bind(request.ledger.original_user_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(mismatched_fingerprint, legacy.digest().as_slice());
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(request.ledger.original_user_id)
        .execute(database.pool())
        .await
        .unwrap();

    sqlx::query(
        r"
        INSERT INTO users (
            id, oidc_issuer, oidc_subject, status,
            identity_fingerprint_key_id, identity_fingerprint
        ) VALUES ($1, $2, $3, 'active', $4, $5)
        ",
    )
    .bind(request.ledger.original_user_id)
    .bind(format!("https://unrelated-restore.test/{unique}"))
    .bind(format!("unrelated-subject-{unique}"))
    .bind(request.ledger.fingerprint.key_id())
    .bind(request.ledger.fingerprint.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    assert!(
        deletion_repository
            .reapply_verified_tombstone(
                &request.ledger,
                &issuer,
                &subject,
                12,
                "restore-conflicting-provider-original-uuid",
            )
            .await
            .is_err()
    );
    let conflicting_provider_status: String =
        sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
            .bind(request.ledger.original_user_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(conflicting_provider_status, "active");
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(request.ledger.original_user_id)
        .execute(database.pool())
        .await
        .unwrap();

    // Once the provider identity has been deleted, the exact retained
    // tombstone fingerprint remains sufficient proof for the original row.
    sqlx::query(
        r"
        INSERT INTO users (
            id, status, identity_fingerprint_key_id, identity_fingerprint
        ) VALUES ($1, 'deletion_pending', $2, $3)
        ",
    )
    .bind(request.ledger.original_user_id)
    .bind(request.ledger.fingerprint.key_id())
    .bind(request.ledger.fingerprint.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    let provider_deleted = deletion_repository
        .reapply_verified_tombstone(
            &request.ledger,
            &issuer,
            &subject,
            12,
            "restore-provider-deleted-original-uuid",
        )
        .await
        .unwrap();
    assert_eq!(provider_deleted.action, DeletionReapplyAction::Unchanged);
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(request.ledger.original_user_id)
        .execute(database.pool())
        .await
        .unwrap();

    // Restore an older active user row, then replay the independently verified
    // tombstone. Access is disabled and provider/app cleanup is queued again.
    sqlx::query(
        r"
        INSERT INTO users (
            id, oidc_issuer, oidc_subject, status,
            identity_fingerprint_key_id, identity_fingerprint
        ) VALUES ($1, $2, $3, 'active', $4, $5)
        ",
    )
    .bind(request.ledger.original_user_id)
    .bind(&issuer)
    .bind(&subject)
    .bind(legacy.key_id())
    .bind(legacy.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    let reapplied = deletion_repository
        .reapply_verified_tombstone(&request.ledger, &issuer, &subject, 12, "restore-test")
        .await
        .unwrap();
    assert_eq!(
        reapplied.action,
        DeletionReapplyAction::RequeuedResurrectedData
    );
    assert!(matches!(
        accounts
            .provision_oidc_identity_guarded(
                &issuer,
                &subject,
                Duration::from_secs(900),
                &candidates,
            )
            .await,
        Err(DbError::IdentityTombstoned)
    ));
    drive_to_app_data_deleted(&deletion_repository, "restore-worker").await;
    let completion = deletion_repository
        .claim("restore-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert!(
        deletion_repository
            .complete(
                completion.operation_id,
                "restore-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
            .unwrap()
    );

    // A restored identity can also exist under a newly issued local UUID with
    // the same authenticated provider coordinates. Reapply must bind the job
    // to that row, disable it, and purge it rather than deleting only the
    // historical UUID recorded by the external ledger.
    let reissued_user_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO users (
            id, oidc_issuer, oidc_subject, status,
            identity_fingerprint_key_id, identity_fingerprint
        ) VALUES ($1, $2, $3, 'active', $4, $5)
        ",
    )
    .bind(reissued_user_id)
    .bind(&issuer)
    .bind(&subject)
    .bind(legacy.key_id())
    .bind(legacy.digest().as_slice())
    .execute(database.pool())
    .await
    .unwrap();
    let reissued = deletion_repository
        .reapply_verified_tombstone(
            &request.ledger,
            &issuer,
            &subject,
            12,
            "restore-reissued-user",
        )
        .await
        .unwrap();
    assert_eq!(
        reissued.action,
        DeletionReapplyAction::RequeuedResurrectedData
    );
    let rebound_job_user: Uuid =
        sqlx::query_scalar("SELECT user_id FROM account_deletion_jobs WHERE operation_id = $1")
            .bind(request.operation.operation_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(rebound_job_user, reissued_user_id);
    let rebound_status: String = sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
        .bind(reissued_user_id)
        .fetch_one(database.pool())
        .await
        .unwrap();
    assert_eq!(rebound_status, "deletion_pending");
    drive_to_app_data_deleted(&deletion_repository, "restore-reissued-worker").await;
    let canonical_job_user: Uuid =
        sqlx::query_scalar("SELECT user_id FROM account_deletion_jobs WHERE operation_id = $1")
            .bind(request.operation.operation_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(canonical_job_user, request.ledger.original_user_id);
    let reissued_completion = deletion_repository
        .claim("restore-reissued-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert!(
        deletion_repository
            .complete(
                reissued_completion.operation_id,
                "restore-reissued-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
            .unwrap()
    );
    let reissued_users: i64 = sqlx::query_scalar("SELECT count(*) FROM users WHERE id = $1")
        .bind(reissued_user_id)
        .fetch_one(database.pool())
        .await
        .unwrap();
    assert_eq!(reissued_users, 0);

    let repeated_reapply = deletion_repository
        .reapply_verified_tombstone(
            &request.ledger,
            &issuer,
            &subject,
            12,
            "restore-reissued-repeat",
        )
        .await
        .unwrap();
    assert_eq!(
        repeated_reapply.action,
        DeletionReapplyAction::RequeuedProviderReconciliation
    );
    drive_to_app_data_deleted(&deletion_repository, "restore-repeat-worker").await;
    let repeat_completion = deletion_repository
        .claim("restore-repeat-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert!(
        deletion_repository
            .complete(
                repeat_completion.operation_id,
                "restore-repeat-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
            .unwrap()
    );
    let unrelated_status: String = sqlx::query_scalar("SELECT status FROM users WHERE id = $1")
        .bind(denied_user.id.into_inner())
        .fetch_one(database.pool())
        .await
        .unwrap();
    assert_eq!(unrelated_status, "active");

    sqlx::query("DELETE FROM account_deletion_events WHERE operation_id = $1")
        .bind(request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_jobs WHERE operation_id = $1")
        .bind(request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_ledger WHERE operation_id = $1")
        .bind(request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(denied_user.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_deletion_purge_and_library_cleanup_have_acyclic_lock_order() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL deletion/library cleanup race");
        return;
    };
    let database = Database::connect(&database_url, 24).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let _queue_isolation = account_deletion_queue_guard::acquire(&database)
        .await
        .unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://deletion-library-race.test/{unique}");
    let identity = fingerprint("current", 0x66);
    let user = database
        .accounts()
        .provision_oidc_identity_guarded(
            &issuer,
            "subject",
            Duration::from_secs(900),
            std::slice::from_ref(&identity),
        )
        .await
        .unwrap();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("deletion-library-race.{unique}")))
        .await
        .unwrap();
    let library = database.library();
    assert!(matches!(
        library
            .mutate(
                user.id,
                paper.id,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    assert!(matches!(
        library
            .mutate(
                user.id,
                paper.id,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    sqlx::query(
        r"
        UPDATE user_paper_library
        SET saved_at = statement_timestamp() - interval '10 years',
            updated_at = statement_timestamp() - interval '10 years',
            removed_at = statement_timestamp() - interval '10 years'
        WHERE user_id = $1 AND paper_id = $2
        ",
    )
    .bind(user.id.into_inner())
    .bind(paper.id)
    .execute(database.pool())
    .await
    .unwrap();

    let deletion_repository = database.account_deletions();
    let deletion = accepted(
        deletion_repository
            .request(
                &issuer,
                "subject",
                std::slice::from_ref(&identity),
                2,
                Duration::from_secs(3600),
                12,
            )
            .await
            .unwrap(),
    );
    deletion_repository
        .mark_externalized(deletion.operation.operation_id)
        .await
        .unwrap();
    advance_claimed(
        &deletion_repository,
        "library-race-worker",
        AccountDeletionState::Requested,
        AccountDeletionState::SessionsRevoked,
    )
    .await;
    advance_claimed(
        &deletion_repository,
        "library-race-worker",
        AccountDeletionState::SessionsRevoked,
        AccountDeletionState::IdentityDeleted,
    )
    .await;
    let purge_job = deletion_repository
        .claim("library-race-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();

    // Hold the revision fence so cleanup queues first. Purge then acquires the
    // account row and queues on the same fence through the user cascade. Since
    // cleanup never takes the account row, releasing this blocker must let both
    // transactions finish; any future inverted lock order deterministically
    // turns the bounded waits below into a regression failure.
    let mut fence_blocker = database.pool().begin().await.unwrap();
    let held_xact: String = sqlx::query_scalar("SELECT pg_current_xact_id()::text")
        .fetch_one(&mut *fence_blocker)
        .await
        .unwrap();
    let locked_user: Uuid = sqlx::query_scalar(
        "SELECT user_id FROM library_sync_metadata WHERE user_id = $1 FOR UPDATE",
    )
    .bind(user.id.into_inner())
    .fetch_one(&mut *fence_blocker)
    .await
    .unwrap();
    assert_eq!(locked_user, user.id.into_inner());

    let cleanup_library = library.clone();
    let cleanup_task = tokio::spawn(async move {
        cleanup_library
            .cleanup_tombstones(Duration::from_secs(90 * 24 * 60 * 60), 1)
            .await
    });
    wait_for_transaction_waiters(database.pool(), &held_xact, 1).await;

    let purge_repository = deletion_repository.clone();
    let purge_task = tokio::spawn(async move {
        purge_repository
            .purge_app_data(
                &purge_job,
                "library-race-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
    });
    wait_for_deletion_row_locks(
        database.pool(),
        deletion.operation.operation_id,
        user.id.into_inner(),
    )
    .await;
    fence_blocker.commit().await.unwrap();

    let cleanup_count = tokio::time::timeout(Duration::from_secs(5), cleanup_task)
        .await
        .expect("library cleanup deadlocked with deletion purge")
        .unwrap()
        .unwrap();
    assert!(cleanup_count <= 1);
    assert!(
        tokio::time::timeout(Duration::from_secs(5), purge_task)
            .await
            .expect("deletion purge deadlocked with library cleanup")
            .unwrap()
            .unwrap()
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM users WHERE id = $1")
            .bind(user.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM user_paper_library WHERE user_id = $1")
            .bind(user.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap(),
        0
    );

    let completion = deletion_repository
        .claim("library-race-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert!(
        deletion_repository
            .complete(
                completion.operation_id,
                "library-race-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
            .unwrap()
    );
    sqlx::query("DELETE FROM account_deletion_events WHERE operation_id = $1")
        .bind(deletion.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_jobs WHERE operation_id = $1")
        .bind(deletion.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_ledger WHERE operation_id = $1")
        .bind(deletion.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

async fn wait_for_transaction_waiters(pool: &sqlx::PgPool, xid: &str, expected: i64) {
    for _ in 0..200 {
        let waiters: i64 = sqlx::query_scalar(
            r"
            SELECT count(*)
            FROM pg_locks
            WHERE locktype = 'transactionid'
              AND transactionid::text = $1
              AND NOT granted
            ",
        )
        .bind(xid)
        .fetch_one(pool)
        .await
        .unwrap();
        if waiters >= expected {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("expected {expected} transaction waiters on the forced library fence");
}

async fn wait_for_deletion_row_locks(pool: &sqlx::PgPool, operation_id: Uuid, user_id: Uuid) {
    for _ in 0..200 {
        let job_probe = sqlx::query(
            "SELECT operation_id FROM account_deletion_jobs WHERE operation_id = $1 FOR UPDATE NOWAIT",
        )
        .bind(operation_id)
        .fetch_optional(pool)
        .await;
        let account_probe = sqlx::query("SELECT id FROM users WHERE id = $1 FOR UPDATE NOWAIT")
            .bind(user_id)
            .fetch_optional(pool)
            .await;
        if job_probe.as_ref().is_err_and(lock_not_available)
            && account_probe.as_ref().is_err_and(lock_not_available)
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("deletion purge did not hold its job and account locks at the cleanup revision fence");
}

fn lock_not_available(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(sqlx::error::DatabaseError::code)
        .is_some_and(|code| code == "55P03")
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_deletion_hides_comments_and_serializes_user_admin_actor() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL deletion/moderation race");
        return;
    };
    let database = Database::connect(&database_url, 24).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let _queue_isolation = account_deletion_queue_guard::acquire(&database)
        .await
        .unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://deletion-actor.test/{unique}");
    let actor_fingerprint = fingerprint("current", 0x44);
    let author_fingerprint = fingerprint("current", 0x55);
    let accounts = database.accounts();
    let actor = accounts
        .provision_oidc_identity_guarded(
            &issuer,
            "actor",
            Duration::from_secs(900),
            std::slice::from_ref(&actor_fingerprint),
        )
        .await
        .unwrap();
    let author = accounts
        .provision_oidc_identity_guarded(
            &issuer,
            "author",
            Duration::from_secs(900),
            std::slice::from_ref(&author_fingerprint),
        )
        .await
        .unwrap();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("deletion.{unique}")))
        .await
        .unwrap();
    let actor_comment = insert_comment(database.pool(), paper.id, actor.id.into_inner()).await;
    let target_comment = insert_comment(database.pool(), paper.id, author.id.into_inner()).await;
    let user_report_id = match database
        .comments()
        .report_user(actor.id, author.id, CommentReportReason::Harassment, None)
        .await
        .unwrap()
    {
        UserReportOutcome::Accepted {
            report,
            replayed: false,
        } => report.id,
        other => panic!("expected deletion user-report fixture, got {other:?}"),
    };
    let public_before = database
        .comments()
        .list_public(paper.id, None, None, 20)
        .await
        .unwrap();
    assert_eq!(public_count(public_before), 2);

    let deletion = accepted(
        database
            .account_deletions()
            .request(
                &issuer,
                "actor",
                std::slice::from_ref(&actor_fingerprint),
                2,
                Duration::from_secs(3600),
                12,
            )
            .await
            .unwrap(),
    );
    let public_after = database
        .comments()
        .list_public(paper.id, None, None, 20)
        .await
        .unwrap();
    assert_eq!(public_count(public_after), 1);
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM paper_comments WHERE id = $1 AND status = 'published'",
        )
        .bind(actor_comment)
        .fetch_one(database.pool())
        .await
        .unwrap(),
        1,
        "visibility disappears at status commit, before physical purge"
    );

    let deletion_repository = database.account_deletions();
    deletion_repository
        .mark_externalized(deletion.operation.operation_id)
        .await
        .unwrap();
    advance_claimed(
        &deletion_repository,
        "actor-worker",
        AccountDeletionState::Requested,
        AccountDeletionState::SessionsRevoked,
    )
    .await;
    advance_claimed(
        &deletion_repository,
        "actor-worker",
        AccountDeletionState::SessionsRevoked,
        AccountDeletionState::IdentityDeleted,
    )
    .await;
    let purge_job = deletion_repository
        .claim("actor-worker", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    let purge_repository = deletion_repository.clone();
    let moderation = database.moderation();
    let stored_actor = StoredAdminActor::User(actor.id);
    let purge = tokio::spawn(async move {
        purge_repository
            .purge_app_data(
                &purge_job,
                "actor-worker",
                Duration::from_secs(24 * 60 * 60),
            )
            .await
    });
    let moderate = tokio::spawn(async move {
        moderation
            .moderate_comment(
                target_comment,
                &stored_actor,
                AdminCommentAction::Hide,
                "privacy_test",
            )
            .await
    });
    assert!(purge.await.unwrap().unwrap());
    let moderation_result = moderate.await.unwrap();
    assert!(
        moderation_result.is_ok() || matches!(moderation_result, Err(DbError::IdentityTombstoned))
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM comment_moderation_events WHERE actor_user_id = $1",
        )
        .bind(actor.id.into_inner())
        .fetch_one(database.pool())
        .await
        .unwrap(),
        0,
        "no post-purge audit event may retain the erased actor link"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM user_reports WHERE id = $1")
            .bind(user_report_id)
            .fetch_one(database.pool())
            .await
            .unwrap(),
        0,
        "deleting a reporter must erase its account-level safety report"
    );

    sqlx::query("DELETE FROM comment_moderation_events WHERE comment_id = $1")
        .bind(target_comment)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_events WHERE operation_id = $1")
        .bind(deletion.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_jobs WHERE operation_id = $1")
        .bind(deletion.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_ledger WHERE operation_id = $1")
        .bind(deletion.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(&issuer)
        .execute(database.pool())
        .await
        .unwrap();
}

fn fingerprint(key_id: &str, byte: u8) -> IdentityFingerprint {
    IdentityFingerprint::new(key_id, [byte; 32]).unwrap()
}

fn accepted(outcome: AccountDeletionRequestOutcome) -> AccountDeletionRequest {
    match outcome {
        AccountDeletionRequestOutcome::Accepted(request) => request,
        AccountDeletionRequestOutcome::RateLimited { .. } => panic!("request was rate-limited"),
    }
}

async fn advance_claimed(
    repository: &AccountDeletionRepository,
    worker: &str,
    from: AccountDeletionState,
    to: AccountDeletionState,
) {
    let claimed = repository
        .claim(worker, Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(claimed.effective_state(), from);
    assert!(
        repository
            .advance(claimed.operation_id, worker, from, to)
            .await
            .unwrap()
    );
}

async fn drive_to_app_data_deleted(repository: &AccountDeletionRepository, worker: &str) {
    advance_claimed(
        repository,
        worker,
        AccountDeletionState::Requested,
        AccountDeletionState::SessionsRevoked,
    )
    .await;
    advance_claimed(
        repository,
        worker,
        AccountDeletionState::SessionsRevoked,
        AccountDeletionState::IdentityDeleted,
    )
    .await;
    let purge = repository
        .claim(worker, Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert!(
        repository
            .purge_app_data(&purge, worker, Duration::from_secs(24 * 60 * 60))
            .await
            .unwrap()
    );
}

async fn insert_comment(pool: &sqlx::PgPool, paper_id: Uuid, user_id: Uuid) -> Uuid {
    let comment_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO paper_comments (
            id, paper_id, author_user_id, client_request_id,
            body, create_body_sha256, status
        ) VALUES ($1, $2, $3, $4, 'deletion visibility fixture', $5, 'published')
        ",
    )
    .bind(comment_id)
    .bind(paper_id)
    .bind(user_id)
    .bind(Uuid::now_v7())
    .bind(vec![0x61_u8; 32])
    .execute(pool)
    .await
    .unwrap();
    comment_id
}

fn public_count(outcome: db::CommentReadOutcome<domain::CommentPage>) -> usize {
    match outcome {
        db::CommentReadOutcome::Found(page) => page.items.len(),
        other => panic!("expected public comment page, got {other:?}"),
    }
}

fn metadata(base_id: &str) -> PaperMetadata {
    let published_at = Utc::now() - TimeDelta::days(2);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: "Deletion fixture".to_owned(),
        abstract_text: "A metadata-only deletion fixture.".to_owned(),
        authors: vec![Author::from("Ada Lovelace".to_owned())],
        primary_category: "cs.AI".to_owned(),
        categories: vec!["cs.AI".to_owned()],
        published_at,
        updated_at: published_at,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v1")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v1")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: Utc::now(),
    }
}
