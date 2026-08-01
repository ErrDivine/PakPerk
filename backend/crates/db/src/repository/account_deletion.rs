use std::{str::FromStr as _, time::Duration};

use chrono::{DateTime, Utc};
use domain::{
    AccountDeletionOperation, AccountDeletionState, AccountStatus, AuthenticatedUserId,
    IdentityFingerprint,
};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::DbError;

const DELETION_STATES: &str = r"
    'requested', 'sessions_revoked', 'identity_deleted', 'app_data_deleted',
    'completed', 'failed_retryable', 'failed_terminal'
";

type StoredLedgerBinding = (Uuid, Uuid, String, Vec<u8>, DateTime<Utc>);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeletionLedgerRecord {
    pub operation_id: Uuid,
    pub original_user_id: Uuid,
    pub fingerprint: IdentityFingerprint,
    pub requested_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountDeletionRequest {
    pub operation: AccountDeletionOperation,
    pub ledger: DeletionLedgerRecord,
    pub externalized: bool,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountDeletionRequestOutcome {
    Accepted(AccountDeletionRequest),
    RateLimited { retry_after_seconds: u64 },
}

#[derive(Clone, PartialEq, Eq)]
pub struct ClaimedAccountDeletion {
    pub operation_id: Uuid,
    pub user_id: Uuid,
    pub fingerprint: IdentityFingerprint,
    pub issuer: Option<String>,
    pub subject: Option<String>,
    pub state: AccountDeletionState,
    pub retry_from: Option<AccountDeletionState>,
    pub attempt: u32,
    pub max_attempts: u32,
    pub requested_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub externalized_at: Option<DateTime<Utc>>,
}

impl std::fmt::Debug for ClaimedAccountDeletion {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ClaimedAccountDeletion")
            .field("operation_id", &self.operation_id)
            .field("user_id", &self.user_id)
            .field("fingerprint", &"[redacted]")
            .field("issuer", &self.issuer.as_ref().map(|_| "[redacted]"))
            .field("subject", &self.subject.as_ref().map(|_| "[redacted]"))
            .field("state", &self.state)
            .field("retry_from", &self.retry_from)
            .field("attempt", &self.attempt)
            .field("max_attempts", &self.max_attempts)
            .field("requested_at", &self.requested_at)
            .field("updated_at", &self.updated_at)
            .field("externalized", &self.externalized_at.is_some())
            .finish()
    }
}

impl ClaimedAccountDeletion {
    #[must_use]
    pub fn effective_state(&self) -> AccountDeletionState {
        self.retry_from.unwrap_or(self.state)
    }

    #[must_use]
    pub fn ledger_record(&self) -> DeletionLedgerRecord {
        DeletionLedgerRecord {
            operation_id: self.operation_id,
            original_user_id: self.user_id,
            fingerprint: self.fingerprint.clone(),
            requested_at: self.requested_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountDeletionFailure {
    pub class: String,
    pub code: String,
    pub message: String,
    pub retryable: bool,
    pub retry_after: Duration,
}

impl AccountDeletionFailure {
    pub fn validate(&self) -> Result<(), DbError> {
        if !valid_code(&self.class)
            || !valid_code(&self.code)
            || self.message.is_empty()
            || self.message.len() > 256
            || self.message.chars().any(char::is_control)
            || self.retry_after > Duration::from_secs(7 * 24 * 60 * 60)
        {
            return Err(DbError::InvalidData(
                "account-deletion failure metadata is invalid".to_owned(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct StoredAccountDeletionStatus {
    pub operation_id: Uuid,
    pub user_id: Uuid,
    pub state: AccountDeletionState,
    pub retry_from: Option<AccountDeletionState>,
    pub attempts: u32,
    pub max_attempts: u32,
    pub externalized: bool,
    pub requested_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub available_at: DateTime<Utc>,
    pub lease_expires_at: Option<DateTime<Utc>>,
    pub last_error_class: Option<String>,
    pub last_error_code: Option<String>,
}

/// Aggregate-only operational view. No account, provider, fingerprint, or
/// operation identifiers cross the telemetry boundary.
#[derive(Debug, Clone, Copy, PartialEq, FromRow)]
pub struct StoredAccountDeletionBacklogMetrics {
    pub unfinished_count: i64,
    pub oldest_unfinished_age_seconds: Option<f64>,
}

/// Bounded, provider-identity-free result used by the deletion confirmation
/// flow. A retained ledger always resolves as deletion-pending even after the
/// application-owned user row has been purged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StoredDeletionIdentityVerification {
    pub user_id: AuthenticatedUserId,
    pub status: AccountStatus,
    pub operation_id: Option<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DeletionReapplyAction {
    Unchanged,
    RestoredAndQueued,
    RequeuedResurrectedData,
    RequeuedProviderReconciliation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct DeletionReapplyOutcome {
    pub operation_id: Uuid,
    pub action: DeletionReapplyAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ExternalLedgerPurgeAuthorizationState {
    Authorized,
    Resumed,
    AlreadyPurged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExternalLedgerPurgeAuthorization {
    pub state: ExternalLedgerPurgeAuthorizationState,
}

#[derive(Debug, FromRow)]
struct DeletionRow {
    operation_id: Uuid,
    user_id: Uuid,
    identity_fingerprint_key_id: String,
    identity_fingerprint: Vec<u8>,
    state: String,
    retry_from: Option<String>,
    attempts: i32,
    max_attempts: i32,
    available_at: DateTime<Utc>,
    lease_expires_at: Option<DateTime<Utc>>,
    oidc_issuer: Option<String>,
    oidc_subject: Option<String>,
    requested_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    externalized_at: Option<DateTime<Utc>>,
    last_error_class: Option<String>,
    last_error_code: Option<String>,
}

#[derive(Debug, FromRow)]
struct ExternalPurgeCandidateRow {
    operation_id: Uuid,
    original_user_id: Uuid,
    identity_fingerprint_key_id: String,
    identity_fingerprint: Vec<u8>,
    requested_at: DateTime<Utc>,
    externalized_at: Option<DateTime<Utc>>,
    completed_at: Option<DateTime<Utc>>,
    state: String,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct ExternalPurgeAuditRow {
    actor_label: String,
    evidence_id: String,
    oldest_recoverable_at: DateTime<Utc>,
    purged_at: Option<DateTime<Utc>>,
}

impl DeletionRow {
    fn fingerprint(&self) -> Result<IdentityFingerprint, DbError> {
        let digest: [u8; 32] = self
            .identity_fingerprint
            .as_slice()
            .try_into()
            .map_err(|_| {
                DbError::InvalidData("persisted deletion fingerprint is invalid".into())
            })?;
        IdentityFingerprint::new(self.identity_fingerprint_key_id.clone(), digest)
            .map_err(|error| DbError::InvalidData(error.to_string()))
    }

    fn state(&self) -> Result<AccountDeletionState, DbError> {
        AccountDeletionState::from_str(&self.state)
            .map_err(|error| DbError::InvalidData(error.to_string()))
    }

    fn retry_from(&self) -> Result<Option<AccountDeletionState>, DbError> {
        self.retry_from
            .as_deref()
            .map(AccountDeletionState::from_str)
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))
    }

    fn operation(&self) -> Result<AccountDeletionOperation, DbError> {
        Ok(AccountDeletionOperation {
            operation_id: self.operation_id,
            state: self.state()?,
            requested_at: self.requested_at,
            updated_at: self.updated_at,
        })
    }

    fn request(&self, replayed: bool) -> Result<AccountDeletionRequest, DbError> {
        Ok(AccountDeletionRequest {
            operation: self.operation()?,
            ledger: DeletionLedgerRecord {
                operation_id: self.operation_id,
                original_user_id: self.user_id,
                fingerprint: self.fingerprint()?,
                requested_at: self.requested_at,
            },
            externalized: self.externalized_at.is_some(),
            replayed,
        })
    }

    fn claimed(&self) -> Result<ClaimedAccountDeletion, DbError> {
        Ok(ClaimedAccountDeletion {
            operation_id: self.operation_id,
            user_id: self.user_id,
            fingerprint: self.fingerprint()?,
            issuer: self.oidc_issuer.clone(),
            subject: self.oidc_subject.clone(),
            state: self.state()?,
            retry_from: self.retry_from()?,
            attempt: u32::try_from(self.attempts)
                .map_err(|_| DbError::InvalidData("persisted attempt is invalid".into()))?,
            max_attempts: u32::try_from(self.max_attempts)
                .map_err(|_| DbError::InvalidData("persisted max attempts is invalid".into()))?,
            requested_at: self.requested_at,
            updated_at: self.updated_at,
            externalized_at: self.externalized_at,
        })
    }

    fn status(&self) -> Result<StoredAccountDeletionStatus, DbError> {
        Ok(StoredAccountDeletionStatus {
            operation_id: self.operation_id,
            user_id: self.user_id,
            state: self.state()?,
            retry_from: self.retry_from()?,
            attempts: u32::try_from(self.attempts)
                .map_err(|_| DbError::InvalidData("persisted attempt is invalid".into()))?,
            max_attempts: u32::try_from(self.max_attempts)
                .map_err(|_| DbError::InvalidData("persisted max attempts is invalid".into()))?,
            externalized: self.externalized_at.is_some(),
            requested_at: self.requested_at,
            updated_at: self.updated_at,
            available_at: self.available_at,
            lease_expires_at: self.lease_expires_at,
            last_error_class: self.last_error_class.clone(),
            last_error_code: self.last_error_code.clone(),
        })
    }
}

const DELETION_COLUMNS: &str = r"
    jobs.operation_id,
    jobs.user_id,
    jobs.identity_fingerprint_key_id,
    jobs.identity_fingerprint,
    jobs.state,
    jobs.retry_from,
    jobs.attempts,
    jobs.max_attempts,
    jobs.available_at,
    jobs.lease_expires_at,
    jobs.oidc_issuer,
    jobs.oidc_subject,
    ledger.requested_at,
    jobs.updated_at,
    ledger.externalized_at,
    jobs.last_error_class,
    jobs.last_error_code
";

#[derive(Clone)]
pub struct AccountDeletionRepository {
    pool: PgPool,
}

impl AccountDeletionRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn find_by_fingerprints(
        &self,
        fingerprints: &[IdentityFingerprint],
    ) -> Result<Option<AccountDeletionRequest>, DbError> {
        for fingerprint in fingerprints {
            let row = self.fetch_by_fingerprint(fingerprint, None).await?;
            if let Some(row) = row {
                return row.request(true).map(Some);
            }
        }
        Ok(None)
    }

    /// Resolves an already-existing local identity without provisioning it.
    /// The durable ledger is checked first so a restored or stale user row can
    /// never mask an accepted deletion operation.
    pub async fn verify_identity(
        &self,
        issuer: &str,
        subject: &str,
        fingerprints: &[IdentityFingerprint],
    ) -> Result<Option<StoredDeletionIdentityVerification>, DbError> {
        if fingerprints.is_empty() {
            return Err(DbError::InvalidData(
                "deletion fingerprint is required".to_owned(),
            ));
        }
        let key_ids = fingerprints
            .iter()
            .map(|fingerprint| fingerprint.key_id().to_owned())
            .collect::<Vec<_>>();
        let digests = fingerprints
            .iter()
            .map(|fingerprint| fingerprint.digest().to_vec())
            .collect::<Vec<_>>();
        // One statement means the ledger and user alternatives share the same
        // MVCC snapshot. A concurrent deletion is therefore observed either
        // wholly before commit (active/suspended) or wholly after commit
        // (deletion_pending with its operation), never as a split view.
        let resolved: Option<(Uuid, String, Option<Uuid>)> = sqlx::query_as(
            r"
            WITH candidate_fingerprints AS (
                SELECT *
                FROM unnest($3::text[], $4::bytea[]) AS candidate(key_id, digest)
            ),
            retained AS (
                SELECT ledger.original_user_id AS user_id, ledger.operation_id
                FROM account_deletion_ledger ledger
                JOIN candidate_fingerprints candidate
                  ON candidate.key_id = ledger.identity_fingerprint_key_id
                 AND candidate.digest = ledger.identity_fingerprint
                LIMIT 1
            ),
            local AS (
                SELECT id AS user_id, status
                FROM users
                WHERE oidc_issuer = $1 AND oidc_subject = $2
            )
            SELECT user_id, status, operation_id
            FROM (
                SELECT user_id, 'deletion_pending'::text AS status,
                       operation_id, 0 AS priority
                FROM retained
                UNION ALL
                SELECT user_id, status, NULL::uuid AS operation_id, 1 AS priority
                FROM local
                WHERE NOT EXISTS (SELECT 1 FROM retained)
            ) resolved
            ORDER BY priority
            LIMIT 1
            ",
        )
        .bind(issuer)
        .bind(subject)
        .bind(&key_ids)
        .bind(&digests)
        .fetch_optional(&self.pool)
        .await?;
        let Some((user_id, status, operation_id)) = resolved else {
            return Ok(None);
        };
        let status = AccountStatus::from_str(&status)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if matches!(
            status,
            AccountStatus::DeletionPending | AccountStatus::Deleted
        ) && operation_id.is_none()
        {
            return Err(DbError::InvalidData(
                "deletion-state identity has no durable operation".to_owned(),
            ));
        }
        Ok(Some(StoredDeletionIdentityVerification {
            user_id: AuthenticatedUserId::new(user_id),
            status,
            operation_id,
        }))
    }

    #[allow(clippy::too_many_arguments, clippy::too_many_lines)] // Atomic disable, quota, ledger, and job creation must stay visibly ordered.
    pub async fn request(
        &self,
        issuer: &str,
        subject: &str,
        fingerprints: &[IdentityFingerprint],
        rate_limit: u32,
        rate_window: Duration,
        maximum_attempts: u32,
    ) -> Result<AccountDeletionRequestOutcome, DbError> {
        let Some(current) = fingerprints.first() else {
            return Err(DbError::InvalidData(
                "deletion fingerprint is required".into(),
            ));
        };
        if rate_limit == 0
            || !(1..=100).contains(&maximum_attempts)
            || rate_window < Duration::from_secs(1)
            || rate_window > Duration::from_secs(30 * 24 * 60 * 60)
        {
            return Err(DbError::InvalidData(
                "deletion request policy is invalid".into(),
            ));
        }

        let mut transaction = self.pool.begin().await?;
        lock_fingerprints(&mut transaction, fingerprints).await?;
        if let Some(row) = fetch_by_fingerprints_in(&mut transaction, fingerprints).await? {
            transaction.commit().await?;
            return Ok(AccountDeletionRequestOutcome::Accepted(row.request(true)?));
        }

        let existing_user_id: Option<Uuid> = sqlx::query_scalar(
            r"
            SELECT id
            FROM users
            WHERE oidc_issuer = $1 AND oidc_subject = $2
            FOR UPDATE
            ",
        )
        .bind(issuer)
        .bind(subject)
        .fetch_optional(&mut *transaction)
        .await?;
        let user_id = existing_user_id.unwrap_or_else(Uuid::now_v7);

        let retry_after =
            consume_account_delete_rate_limit(&mut transaction, user_id, rate_limit, rate_window)
                .await?;
        if let Some(retry_after_seconds) = retry_after {
            // Persist denied attempts so the shared fixed-window limiter cannot
            // be bypassed by repeatedly entering this transaction.
            transaction.commit().await?;
            return Ok(AccountDeletionRequestOutcome::RateLimited {
                retry_after_seconds,
            });
        }

        if existing_user_id.is_some() {
            sqlx::query(
                r"
                UPDATE users
                SET status = 'deletion_pending',
                    handle = NULL,
                    display_name = NULL,
                    identity_fingerprint_key_id = COALESCE(
                        identity_fingerprint_key_id,
                        $2
                    ),
                    identity_fingerprint = COALESCE(identity_fingerprint, $3),
                    profile_version = profile_version + 1,
                    updated_at = statement_timestamp()
                WHERE id = $1
                ",
            )
            .bind(user_id)
            .bind(current.key_id())
            .bind(current.digest().as_slice())
            .execute(&mut *transaction)
            .await?;
        } else {
            sqlx::query(
                r"
                INSERT INTO users (
                    id, oidc_issuer, oidc_subject, status,
                    identity_fingerprint_key_id, identity_fingerprint
                )
                VALUES ($1, $2, $3, 'deletion_pending', $4, $5)
                ",
            )
            .bind(user_id)
            .bind(issuer)
            .bind(subject)
            .bind(current.key_id())
            .bind(current.digest().as_slice())
            .execute(&mut *transaction)
            .await?;
        }

        let operation_id = Uuid::now_v7();
        sqlx::query(
            r"
            INSERT INTO account_deletion_ledger (
                operation_id, original_user_id,
                identity_fingerprint_key_id, identity_fingerprint
            )
            VALUES ($1, $2, $3, $4)
            ",
        )
        .bind(operation_id)
        .bind(user_id)
        .bind(current.key_id())
        .bind(current.digest().as_slice())
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            r"
            INSERT INTO account_deletion_jobs (
                operation_id, user_id,
                identity_fingerprint_key_id, identity_fingerprint,
                oidc_issuer, oidc_subject, max_attempts
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ",
        )
        .bind(operation_id)
        .bind(user_id)
        .bind(current.key_id())
        .bind(current.digest().as_slice())
        .bind(issuer)
        .bind(subject)
        .bind(i32::try_from(maximum_attempts).unwrap_or(i32::MAX))
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            r"
            INSERT INTO account_deletion_events (
                operation_id, from_state, to_state, actor_kind, reason_code
            )
            VALUES ($1, NULL, 'requested', 'system', 'user_request')
            ",
        )
        .bind(operation_id)
        .execute(&mut *transaction)
        .await?;
        let row = fetch_by_operation_in(&mut transaction, operation_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("created deletion job was not found".into()))?;
        transaction.commit().await?;
        Ok(AccountDeletionRequestOutcome::Accepted(row.request(false)?))
    }

    pub async fn mark_externalized(
        &self,
        operation_id: Uuid,
    ) -> Result<AccountDeletionOperation, DbError> {
        let mut transaction = self.pool.begin().await?;
        let updated = sqlx::query(
            r"
            UPDATE account_deletion_ledger
            SET externalized_at = COALESCE(externalized_at, statement_timestamp())
            WHERE operation_id = $1
            ",
        )
        .bind(operation_id)
        .execute(&mut *transaction)
        .await?;
        if updated.rows_affected() != 1 {
            return Err(DbError::InvalidData(
                "deletion operation was not found".into(),
            ));
        }
        let row = fetch_by_operation_in(&mut transaction, operation_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("deletion operation was not found".into()))?;
        transaction.commit().await?;
        row.operation()
    }

    /// Returns whether a missing external record may be recreated. Final
    /// purge authorization permanently closes externalization before unlink,
    /// preventing a late API replay from recreating a deliberately purged
    /// provider-identity record.
    pub async fn external_record_required(&self, operation_id: Uuid) -> Result<bool, DbError> {
        sqlx::query_scalar(
            r"
            SELECT EXISTS (
                SELECT 1
                FROM account_deletion_ledger ledger
                WHERE ledger.operation_id = $1
                  AND NOT EXISTS (
                      SELECT 1
                      FROM account_deletion_external_purges purge
                      WHERE purge.operation_id = ledger.operation_id
                  )
            )
            ",
        )
        .bind(operation_id)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::from)
    }

    pub async fn claim(
        &self,
        worker_id: &str,
        lease_duration: Duration,
    ) -> Result<Option<ClaimedAccountDeletion>, DbError> {
        validate_worker(worker_id, lease_duration)?;
        let mut transaction = self.pool.begin().await?;
        let operation_id: Option<Uuid> = sqlx::query_scalar(&format!(
            r"
            SELECT operation_id
            FROM account_deletion_jobs
            WHERE state IN ({DELETION_STATES})
              AND state NOT IN ('completed', 'failed_terminal')
              AND available_at <= statement_timestamp()
              AND (lease_expires_at IS NULL OR lease_expires_at <= statement_timestamp())
            ORDER BY available_at, created_at, operation_id
            FOR UPDATE SKIP LOCKED
            LIMIT 1
            "
        ))
        .fetch_optional(&mut *transaction)
        .await?;
        let Some(operation_id) = operation_id else {
            transaction.commit().await?;
            return Ok(None);
        };
        sqlx::query(
            r"
            UPDATE account_deletion_jobs
            SET lease_owner = $2,
                lease_expires_at = statement_timestamp()
                    + make_interval(secs => $3::double precision),
                attempts = attempts + 1,
                updated_at = statement_timestamp()
            WHERE operation_id = $1
            ",
        )
        .bind(operation_id)
        .bind(worker_id)
        .bind(lease_duration.as_secs_f64())
        .execute(&mut *transaction)
        .await?;
        let row = fetch_by_operation_in(&mut transaction, operation_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("claimed deletion job disappeared".into()))?;
        transaction.commit().await?;
        row.claimed().map(Some)
    }

    /// Extends only a still-live lease owned by this worker. A stale worker can
    /// never reacquire ownership or overwrite a checkpoint through heartbeat.
    pub async fn extend_lease(
        &self,
        operation_id: Uuid,
        worker_id: &str,
        lease_duration: Duration,
    ) -> Result<bool, DbError> {
        validate_worker(worker_id, lease_duration)?;
        let result = sqlx::query(
            r"
            UPDATE account_deletion_jobs
            SET lease_expires_at = statement_timestamp()
                    + make_interval(secs => $3::double precision)
            WHERE operation_id = $1
              AND lease_owner = $2
              AND lease_expires_at > statement_timestamp()
              AND state NOT IN ('completed', 'failed_terminal')
            ",
        )
        .bind(operation_id)
        .bind(worker_id)
        .bind(lease_duration.as_secs_f64())
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn advance(
        &self,
        operation_id: Uuid,
        worker_id: &str,
        from: AccountDeletionState,
        to: AccountDeletionState,
    ) -> Result<bool, DbError> {
        if !valid_transition(from, to) {
            return Err(DbError::InvalidData("invalid deletion transition".into()));
        }
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            r"
            UPDATE account_deletion_jobs
            SET state = $4,
                retry_from = NULL,
                lease_owner = NULL,
                lease_expires_at = NULL,
                available_at = statement_timestamp(),
                provider_identity_deleted_at = CASE
                    WHEN $4 = 'identity_deleted'
                    THEN COALESCE(provider_identity_deleted_at, statement_timestamp())
                    ELSE provider_identity_deleted_at
                END,
                oidc_issuer = CASE WHEN $4 = 'identity_deleted' THEN NULL ELSE oidc_issuer END,
                oidc_subject = CASE WHEN $4 = 'identity_deleted' THEN NULL ELSE oidc_subject END,
                last_error_class = NULL,
                last_error_code = NULL,
                last_error_message = NULL,
                attempts = 0,
                updated_at = statement_timestamp()
            WHERE operation_id = $1
              AND lease_owner = $2
              AND lease_expires_at > statement_timestamp()
              AND (
                    state = $3
                    OR (state = 'failed_retryable' AND retry_from = $3)
              )
            ",
        )
        .bind(operation_id)
        .bind(worker_id)
        .bind(from.as_str())
        .bind(to.as_str())
        .execute(&mut *transaction)
        .await?;
        if result.rows_affected() == 1 {
            insert_transition_event(&mut transaction, operation_id, from, to, "worker_advance")
                .await?;
        }
        transaction.commit().await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn fail(
        &self,
        job: &ClaimedAccountDeletion,
        worker_id: &str,
        failure: &AccountDeletionFailure,
    ) -> Result<AccountDeletionState, DbError> {
        failure.validate()?;
        let retryable = failure.retryable && job.attempt < job.max_attempts;
        let state = if retryable {
            AccountDeletionState::FailedRetryable
        } else {
            AccountDeletionState::FailedTerminal
        };
        let retry_from = retryable.then(|| job.effective_state().as_str());
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            r"
            UPDATE account_deletion_jobs
            SET state = $3,
                retry_from = $4,
                available_at = CASE
                    WHEN $3 = 'failed_retryable'
                    THEN statement_timestamp() + make_interval(secs => $5::double precision)
                    ELSE available_at
                END,
                lease_owner = NULL,
                lease_expires_at = NULL,
                last_error_class = $6,
                last_error_code = $7,
                last_error_message = $8,
                updated_at = statement_timestamp()
            WHERE operation_id = $1
              AND lease_owner = $2
              AND lease_expires_at > statement_timestamp()
            ",
        )
        .bind(job.operation_id)
        .bind(worker_id)
        .bind(state.as_str())
        .bind(retry_from)
        .bind(failure.retry_after.as_secs_f64())
        .bind(&failure.class)
        .bind(&failure.code)
        .bind(&failure.message)
        .execute(&mut *transaction)
        .await?;
        if result.rows_affected() != 1 {
            return Err(DbError::InvalidData(
                "deletion worker lost its lease".into(),
            ));
        }
        insert_transition_event(
            &mut transaction,
            job.operation_id,
            job.effective_state(),
            state,
            &failure.code,
        )
        .await?;
        transaction.commit().await?;
        Ok(state)
    }

    #[allow(clippy::too_many_lines)] // One transaction serializes the account lock and every privacy purge/redaction.
    pub async fn purge_app_data(
        &self,
        job: &ClaimedAccountDeletion,
        worker_id: &str,
        security_retention: Duration,
    ) -> Result<bool, DbError> {
        if security_retention < Duration::from_secs(24 * 60 * 60)
            || security_retention > Duration::from_secs(10 * 365 * 24 * 60 * 60)
        {
            return Err(DbError::InvalidData("security retention is invalid".into()));
        }
        let mut transaction = self.pool.begin().await?;
        let locked_job: Option<(String, Option<String>, String, DateTime<Utc>)> = sqlx::query_as(
            r"
            SELECT state, retry_from, lease_owner, lease_expires_at
            FROM account_deletion_jobs
            WHERE operation_id = $1
              AND lease_owner = $2
              AND lease_expires_at > statement_timestamp()
              AND (
                    state = 'identity_deleted'
                    OR (state = 'failed_retryable' AND retry_from = 'identity_deleted')
              )
            FOR UPDATE
            ",
        )
        .bind(job.operation_id)
        .bind(worker_id)
        .fetch_optional(&mut *transaction)
        .await?;
        if locked_job.is_none() {
            return Ok(false);
        }
        sqlx::query("SELECT id FROM users WHERE id = $1 FOR UPDATE")
            .bind(job.user_id)
            .fetch_optional(&mut *transaction)
            .await?;

        let comment_ids: Vec<Uuid> = sqlx::query_scalar(
            r"
            SELECT id FROM paper_comments
            WHERE author_user_id = $1
            ORDER BY id
            FOR UPDATE
            ",
        )
        .bind(job.user_id)
        .fetch_all(&mut *transaction)
        .await?;
        sqlx::query(
            r"
            SELECT id FROM comment_reports
            WHERE reporter_user_id = $1
               OR reviewed_by = $1
               OR comment_id = ANY($2::uuid[])
            ORDER BY id
            FOR UPDATE
            ",
        )
        .bind(job.user_id)
        .bind(&comment_ids)
        .fetch_all(&mut *transaction)
        .await?;
        sqlx::query(
            r"
            SELECT id FROM user_reports
            WHERE reporter_user_id = $1
               OR reported_user_id = $1
               OR reviewed_by = $1
            ORDER BY id
            FOR UPDATE
            ",
        )
        .bind(job.user_id)
        .fetch_all(&mut *transaction)
        .await?;

        sqlx::query(
            r"
            UPDATE comment_moderation_events
            SET retention_pseudonym = CASE
                    WHEN target_user_id = $1 OR comment_id = ANY($2::uuid[])
                    THEN COALESCE(retention_pseudonym, gen_random_bytes(32))
                    ELSE retention_pseudonym
                END,
                actor_retention_pseudonym = CASE
                    WHEN actor_user_id = $1
                    THEN COALESCE(actor_retention_pseudonym, gen_random_bytes(32))
                    ELSE actor_retention_pseudonym
                END,
                comment_id = CASE WHEN comment_id = ANY($2::uuid[]) THEN NULL ELSE comment_id END,
                target_user_id = CASE WHEN target_user_id = $1 THEN NULL ELSE target_user_id END,
                actor_user_id = CASE WHEN actor_user_id = $1 THEN NULL ELSE actor_user_id END,
                metadata = '{}'::jsonb,
                retention_expires_at = statement_timestamp()
                    + make_interval(secs => $3::double precision)
            WHERE target_user_id = $1
               OR actor_user_id = $1
               OR comment_id = ANY($2::uuid[])
            ",
        )
        .bind(job.user_id)
        .bind(&comment_ids)
        .bind(security_retention.as_secs_f64())
        .execute(&mut *transaction)
        .await?;

        sqlx::query(
            r"
            DELETE FROM shared_rate_limit_buckets
            WHERE scope_key = $1
               OR scope_key = ANY($2::text[])
            ",
        )
        .bind(format!("user:{}", job.user_id))
        .bind(
            comment_ids
                .iter()
                .map(|id| format!("comment:{id}"))
                .collect::<Vec<_>>(),
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(job.user_id)
            .execute(&mut *transaction)
            .await?;
        let advanced = sqlx::query(
            r"
            UPDATE account_deletion_jobs
            SET state = 'app_data_deleted',
                retry_from = NULL,
                app_data_deleted_at = COALESCE(app_data_deleted_at, statement_timestamp()),
                lease_owner = NULL,
                lease_expires_at = NULL,
                available_at = statement_timestamp(),
                last_error_class = NULL,
                last_error_code = NULL,
                last_error_message = NULL,
                attempts = 0,
                updated_at = statement_timestamp()
            WHERE operation_id = $1
              AND lease_owner = $2
              AND lease_expires_at > statement_timestamp()
              AND (
                    state = 'identity_deleted'
                    OR (state = 'failed_retryable' AND retry_from = 'identity_deleted')
              )
            ",
        )
        .bind(job.operation_id)
        .bind(worker_id)
        .execute(&mut *transaction)
        .await?;
        if advanced.rows_affected() != 1 {
            return Err(DbError::InvalidData(
                "deletion worker lost its lease".into(),
            ));
        }
        insert_transition_event(
            &mut transaction,
            job.operation_id,
            AccountDeletionState::IdentityDeleted,
            AccountDeletionState::AppDataDeleted,
            "app_data_purged",
        )
        .await?;
        sqlx::query(
            r"
            UPDATE account_deletion_events
            SET expires_at = COALESCE(
                expires_at,
                statement_timestamp() + make_interval(secs => $2::double precision)
            )
            WHERE operation_id = $1
            ",
        )
        .bind(job.operation_id)
        .bind(security_retention.as_secs_f64())
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(true)
    }

    pub async fn complete(
        &self,
        operation_id: Uuid,
        worker_id: &str,
        retention: Duration,
    ) -> Result<bool, DbError> {
        validate_retention(retention)?;
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            r"
            UPDATE account_deletion_jobs
            SET state = 'completed',
                retry_from = NULL,
                lease_owner = NULL,
                lease_expires_at = NULL,
                last_error_class = NULL,
                last_error_code = NULL,
                last_error_message = NULL,
                updated_at = statement_timestamp()
            WHERE operation_id = $1
              AND lease_owner = $2
              AND lease_expires_at > statement_timestamp()
              AND (
                    state = 'app_data_deleted'
                    OR (state = 'failed_retryable' AND retry_from = 'app_data_deleted')
              )
            ",
        )
        .bind(operation_id)
        .bind(worker_id)
        .execute(&mut *transaction)
        .await?;
        if result.rows_affected() == 1 {
            sqlx::query(
                r"
                UPDATE account_deletion_ledger
                SET completed_at = COALESCE(completed_at, statement_timestamp()),
                    expires_at = COALESCE(
                        expires_at,
                        statement_timestamp() + make_interval(secs => $2::double precision)
                    )
                WHERE operation_id = $1
                ",
            )
            .bind(operation_id)
            .bind(retention.as_secs_f64())
            .execute(&mut *transaction)
            .await?;
            insert_transition_event(
                &mut transaction,
                operation_id,
                AccountDeletionState::AppDataDeleted,
                AccountDeletionState::Completed,
                "completed",
            )
            .await?;
            sqlx::query(
                r"
                UPDATE account_deletion_events
                SET expires_at = COALESCE(
                    expires_at,
                    statement_timestamp() + make_interval(secs => $2::double precision)
                )
                WHERE operation_id = $1
                ",
            )
            .bind(operation_id)
            .bind(retention.as_secs_f64())
            .execute(&mut *transaction)
            .await?;
        }
        transaction.commit().await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn get_status(
        &self,
        operation_id: Uuid,
    ) -> Result<Option<StoredAccountDeletionStatus>, DbError> {
        self.fetch_by_operation(operation_id)
            .await?
            .map(|row| row.status())
            .transpose()
    }

    pub async fn list_statuses(
        &self,
        state: Option<AccountDeletionState>,
        limit: u32,
    ) -> Result<Vec<StoredAccountDeletionStatus>, DbError> {
        let rows = sqlx::query_as::<_, DeletionRow>(&format!(
            r"
            SELECT {DELETION_COLUMNS}
            FROM account_deletion_jobs jobs
            JOIN account_deletion_ledger ledger USING (operation_id)
            WHERE $1::text IS NULL OR jobs.state = $1
            ORDER BY jobs.updated_at, jobs.operation_id
            LIMIT $2
            "
        ))
        .bind(state.map(AccountDeletionState::as_str))
        .bind(i64::from(limit.clamp(1, 100)))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter().map(|row| row.status()).collect()
    }

    /// Samples all unfinished deletion obligations, including jobs in long
    /// retry backoff and persistent terminal failure. The single aggregate row
    /// is deliberately content- and identifier-free.
    pub async fn backlog_metrics(&self) -> Result<StoredAccountDeletionBacklogMetrics, DbError> {
        sqlx::query_as(
            r"
            SELECT COUNT(*)::bigint AS unfinished_count,
                   EXTRACT(EPOCH FROM (
                       statement_timestamp() - MIN(ledger.requested_at)
                   ))::double precision AS oldest_unfinished_age_seconds
            FROM account_deletion_jobs jobs
            JOIN account_deletion_ledger ledger USING (operation_id)
            WHERE jobs.state <> 'completed'
            ",
        )
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::from)
    }

    pub async fn retry_terminal(&self, operation_id: Uuid, actor: &str) -> Result<bool, DbError> {
        if !valid_actor(actor) {
            return Err(DbError::InvalidData("admin actor is invalid".into()));
        }
        let mut transaction = self.pool.begin().await?;
        let row: Option<String> = sqlx::query_scalar(
            r"
            UPDATE account_deletion_jobs
            SET state = 'failed_retryable',
                retry_from = CASE
                    WHEN app_data_deleted_at IS NOT NULL THEN 'app_data_deleted'
                    WHEN provider_identity_deleted_at IS NOT NULL THEN 'identity_deleted'
                    ELSE 'requested'
                END,
                attempts = 0,
                available_at = statement_timestamp(),
                lease_owner = NULL,
                lease_expires_at = NULL,
                updated_at = statement_timestamp()
            WHERE operation_id = $1 AND state = 'failed_terminal'
            RETURNING retry_from
            ",
        )
        .bind(operation_id)
        .fetch_optional(&mut *transaction)
        .await?;
        if row.is_some() {
            sqlx::query(
                r"
                INSERT INTO account_deletion_events (
                    operation_id, from_state, to_state, actor_kind, actor_label, reason_code
                )
                VALUES ($1, 'failed_terminal', 'failed_retryable', 'admin', $2, 'manual_retry')
                ",
            )
            .bind(operation_id)
            .bind(actor)
            .execute(&mut *transaction)
            .await?;
        }
        transaction.commit().await?;
        Ok(row.is_some())
    }

    /// Reconciles a signer-verified external tombstone after database restore.
    /// The immutable operation/fingerprint binding is never rewritten. If a
    /// pre-deletion user row reappeared, access is disabled and the worker is
    /// reset to the earliest checkpoint justified by the restored row.
    #[allow(clippy::too_many_lines)] // Restore reconciliation is intentionally a single locked transaction.
    pub async fn reapply_verified_tombstone(
        &self,
        ledger: &DeletionLedgerRecord,
        provider_issuer: &str,
        provider_subject: &str,
        maximum_attempts: u32,
        actor: &str,
    ) -> Result<DeletionReapplyOutcome, DbError> {
        if !(1..=100).contains(&maximum_attempts)
            || !valid_actor(actor)
            || !valid_provider_identity(provider_issuer, provider_subject)
        {
            return Err(DbError::InvalidData(
                "deletion reapply configuration is invalid".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        lock_fingerprints(&mut transaction, std::slice::from_ref(&ledger.fingerprint)).await?;
        let purge_started: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM account_deletion_external_purges WHERE operation_id = $1)",
        )
        .bind(ledger.operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        if purge_started {
            return Err(DbError::InvalidData(
                "external deletion tombstone purge has already started".to_owned(),
            ));
        }

        let existing_ledgers: Vec<StoredLedgerBinding> = sqlx::query_as(
            r"
                SELECT operation_id, original_user_id,
                       identity_fingerprint_key_id, identity_fingerprint, requested_at
                FROM account_deletion_ledger
                WHERE operation_id = $1
                   OR original_user_id = $2
                   OR (
                        identity_fingerprint_key_id = $3
                        AND identity_fingerprint = $4
                   )
                FOR UPDATE
                ",
        )
        .bind(ledger.operation_id)
        .bind(ledger.original_user_id)
        .bind(ledger.fingerprint.key_id())
        .bind(ledger.fingerprint.digest().as_slice())
        .fetch_all(&mut *transaction)
        .await?;
        if existing_ledgers.len() > 1
            || existing_ledgers.first().is_some_and(
                |(operation_id, user_id, key_id, digest, requested_at)| {
                    *operation_id != ledger.operation_id
                        || *user_id != ledger.original_user_id
                        || key_id != ledger.fingerprint.key_id()
                        || digest.as_slice() != ledger.fingerprint.digest().as_slice()
                        || requested_at.timestamp_millis() != ledger.requested_at.timestamp_millis()
                },
            )
        {
            return Err(DbError::InvalidData(
                "external deletion tombstone conflicts with restored database".to_owned(),
            ));
        }
        let ledger_was_missing = existing_ledgers.is_empty();
        if ledger_was_missing {
            sqlx::query(
                r"
                INSERT INTO account_deletion_ledger (
                    operation_id, original_user_id,
                    identity_fingerprint_key_id, identity_fingerprint,
                    requested_at, externalized_at
                ) VALUES ($1, $2, $3, $4, $5, statement_timestamp())
                ",
            )
            .bind(ledger.operation_id)
            .bind(ledger.original_user_id)
            .bind(ledger.fingerprint.key_id())
            .bind(ledger.fingerprint.digest().as_slice())
            .bind(ledger.requested_at)
            .execute(&mut *transaction)
            .await?;
        } else {
            sqlx::query(
                r"
                UPDATE account_deletion_ledger
                SET externalized_at = COALESCE(externalized_at, statement_timestamp())
                WHERE operation_id = $1
                ",
            )
            .bind(ledger.operation_id)
            .execute(&mut *transaction)
            .await?;
        }

        let restored_user: Option<(String, Option<String>, Option<String>)> = sqlx::query_as(
            r"
            SELECT status, oidc_issuer, oidc_subject
            FROM users
            WHERE id = $1
            FOR UPDATE
            ",
        )
        .bind(ledger.original_user_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let resurrected = restored_user
            .as_ref()
            .is_some_and(|(status, _, _)| status != "deletion_pending");
        if restored_user.as_ref().is_some_and(|(_, issuer, subject)| {
            issuer
                .as_ref()
                .zip(subject.as_ref())
                .is_some_and(|(issuer, subject)| {
                    issuer != provider_issuer || subject != provider_subject
                })
        }) {
            return Err(DbError::InvalidData(
                "restored provider identity conflicts with external tombstone".to_owned(),
            ));
        }
        if restored_user.is_some() {
            sqlx::query(
                r"
                UPDATE users
                SET status = 'deletion_pending',
                    handle = NULL,
                    display_name = NULL,
                    identity_fingerprint_key_id = $2,
                    identity_fingerprint = $3,
                    profile_version = profile_version + 1,
                    updated_at = statement_timestamp()
                WHERE id = $1
                  AND (
                        status <> 'deletion_pending'
                        OR handle IS NOT NULL
                        OR display_name IS NOT NULL
                        OR identity_fingerprint_key_id IS DISTINCT FROM $2
                        OR identity_fingerprint IS DISTINCT FROM $3
                  )
                ",
            )
            .bind(ledger.original_user_id)
            .bind(ledger.fingerprint.key_id())
            .bind(ledger.fingerprint.digest().as_slice())
            .execute(&mut *transaction)
            .await?;
        }

        let existing_job: Option<(String, Option<String>, Option<String>)> = sqlx::query_as(
            "SELECT state, oidc_issuer, oidc_subject FROM account_deletion_jobs WHERE operation_id = $1 FOR UPDATE",
        )
        .bind(ledger.operation_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let existing_job_state = existing_job.as_ref().map(|(state, _, _)| state.as_str());
        let restored_state = AccountDeletionState::Requested;
        let should_restore_job = existing_job.is_none();
        let should_requeue = existing_job
            .as_ref()
            .is_some_and(|(state, issuer, subject)| {
                state != AccountDeletionState::Requested.as_str()
                    || issuer.as_deref() != Some(provider_issuer)
                    || subject.as_deref() != Some(provider_subject)
                    || resurrected
            });
        if should_restore_job {
            sqlx::query(
                r"
                INSERT INTO account_deletion_jobs (
                    operation_id, user_id,
                    identity_fingerprint_key_id, identity_fingerprint,
                    oidc_issuer, oidc_subject, state, max_attempts,
                    provider_identity_deleted_at
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULL)
                ",
            )
            .bind(ledger.operation_id)
            .bind(ledger.original_user_id)
            .bind(ledger.fingerprint.key_id())
            .bind(ledger.fingerprint.digest().as_slice())
            .bind(provider_issuer)
            .bind(provider_subject)
            .bind(restored_state.as_str())
            .bind(i32::try_from(maximum_attempts).unwrap_or(i32::MAX))
            .execute(&mut *transaction)
            .await?;
        } else if should_requeue {
            sqlx::query(
                r"
                UPDATE account_deletion_jobs
                SET state = $2,
                    retry_from = NULL,
                    attempts = 0,
                    max_attempts = $3,
                    available_at = statement_timestamp(),
                    lease_owner = NULL,
                    lease_expires_at = NULL,
                    oidc_issuer = $4,
                    oidc_subject = $5,
                    provider_identity_deleted_at = NULL,
                    app_data_deleted_at = NULL,
                    last_error_class = NULL,
                    last_error_code = NULL,
                    last_error_message = NULL,
                    updated_at = statement_timestamp()
                WHERE operation_id = $1
                ",
            )
            .bind(ledger.operation_id)
            .bind(restored_state.as_str())
            .bind(i32::try_from(maximum_attempts).unwrap_or(i32::MAX))
            .bind(provider_issuer)
            .bind(provider_subject)
            .execute(&mut *transaction)
            .await?;
            sqlx::query(
                r"
                UPDATE account_deletion_ledger
                SET completed_at = NULL,
                    expires_at = NULL
                WHERE operation_id = $1
                ",
            )
            .bind(ledger.operation_id)
            .execute(&mut *transaction)
            .await?;
        }

        let action = if resurrected {
            DeletionReapplyAction::RequeuedResurrectedData
        } else if should_restore_job || ledger_was_missing {
            DeletionReapplyAction::RestoredAndQueued
        } else if should_requeue {
            DeletionReapplyAction::RequeuedProviderReconciliation
        } else {
            DeletionReapplyAction::Unchanged
        };
        if action != DeletionReapplyAction::Unchanged {
            sqlx::query(
                r"
                INSERT INTO account_deletion_events (
                    operation_id, from_state, to_state,
                    actor_kind, actor_label, reason_code
                ) VALUES ($1, $2, $3, 'admin', $4, 'restore_reapply')
                ",
            )
            .bind(ledger.operation_id)
            .bind(existing_job_state)
            .bind(restored_state.as_str())
            .bind(actor)
            .execute(&mut *transaction)
            .await?;
        }
        transaction.commit().await?;
        Ok(DeletionReapplyOutcome {
            operation_id: ledger.operation_id,
            action,
        })
    }

    /// Persists operator evidence before the external immutable record is
    /// unlinked. A newly authorized purge requires the verified record to be
    /// present; a prior authorization makes crash recovery idempotent.
    #[allow(clippy::too_many_arguments, clippy::too_many_lines)]
    pub async fn begin_external_ledger_purge(
        &self,
        operation_id: Uuid,
        verified_external_ledger: Option<&DeletionLedgerRecord>,
        ledger_retention: Duration,
        recoverable_backup_horizon: Duration,
        oldest_recoverable_at: DateTime<Utc>,
        evidence_id: &str,
        actor: &str,
    ) -> Result<ExternalLedgerPurgeAuthorization, DbError> {
        validate_retention(ledger_retention)?;
        if recoverable_backup_horizon < Duration::from_secs(24 * 60 * 60)
            || recoverable_backup_horizon >= ledger_retention
            || !valid_purge_actor(actor)
            || !valid_evidence_id(evidence_id)
        {
            return Err(DbError::InvalidData(
                "external ledger purge evidence is invalid".to_owned(),
            ));
        }
        if verified_external_ledger.is_some_and(|ledger| ledger.operation_id != operation_id) {
            return Err(DbError::InvalidData(
                "external ledger purge operation does not match the verified record".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        // New purge authorization and restore reapply share the fingerprint
        // advisory lock. Exactly one can move a completed operation toward
        // final unlink or back to provider reconciliation.
        if let Some(ledger) = verified_external_ledger {
            lock_fingerprints(&mut transaction, std::slice::from_ref(&ledger.fingerprint)).await?;
        }
        let prior = sqlx::query_as::<_, ExternalPurgeAuditRow>(
            r"
            SELECT actor_label, evidence_id, oldest_recoverable_at, purged_at
            FROM account_deletion_external_purges
            WHERE operation_id = $1
            FOR UPDATE
            ",
        )
        .bind(operation_id)
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(prior) = prior {
            if prior.actor_label != actor
                || prior.evidence_id != evidence_id
                || prior.oldest_recoverable_at != oldest_recoverable_at
            {
                return Err(DbError::InvalidData(
                    "external ledger purge evidence conflicts with prior authorization".to_owned(),
                ));
            }
            transaction.commit().await?;
            return Ok(ExternalLedgerPurgeAuthorization {
                state: if prior.purged_at.is_some() {
                    ExternalLedgerPurgeAuthorizationState::AlreadyPurged
                } else {
                    ExternalLedgerPurgeAuthorizationState::Resumed
                },
            });
        }
        let ledger = verified_external_ledger.ok_or_else(|| {
            DbError::InvalidData(
                "external ledger record is absent before purge authorization".to_owned(),
            )
        })?;
        let candidate = sqlx::query_as::<_, ExternalPurgeCandidateRow>(
            r"
            SELECT ledger.operation_id, ledger.original_user_id,
                   ledger.identity_fingerprint_key_id, ledger.identity_fingerprint,
                   ledger.requested_at, ledger.externalized_at, ledger.completed_at,
                   jobs.state, jobs.updated_at
            FROM account_deletion_ledger ledger
            JOIN account_deletion_jobs jobs USING (operation_id)
            WHERE ledger.operation_id = $1
            FOR UPDATE OF ledger, jobs
            ",
        )
        .bind(operation_id)
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or_else(|| DbError::InvalidData("deletion operation was not found".to_owned()))?;
        let digest: [u8; 32] = candidate
            .identity_fingerprint
            .as_slice()
            .try_into()
            .map_err(|_| DbError::InvalidData("deletion fingerprint is invalid".to_owned()))?;
        let candidate_fingerprint =
            IdentityFingerprint::new(candidate.identity_fingerprint_key_id, digest)
                .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if candidate.operation_id != ledger.operation_id
            || candidate.original_user_id != ledger.original_user_id
            || candidate_fingerprint != ledger.fingerprint
            || candidate.requested_at.timestamp_millis() != ledger.requested_at.timestamp_millis()
            || candidate.externalized_at.is_none()
            || candidate.state != AccountDeletionState::Completed.as_str()
        {
            return Err(DbError::InvalidData(
                "external ledger purge preconditions are not satisfied".to_owned(),
            ));
        }
        let completed_at = candidate
            .completed_at
            .map(|ledger_completed| ledger_completed.max(candidate.updated_at))
            .ok_or_else(|| {
                DbError::InvalidData("deletion completion timestamp is unavailable".to_owned())
            })?;
        let retention_elapsed: bool = sqlx::query_scalar(
            r"
            SELECT statement_timestamp() >= $1
                        + make_interval(secs => $2::double precision)
               AND $3 <= statement_timestamp()
            ",
        )
        .bind(completed_at)
        .bind(
            ledger_retention
                .max(recoverable_backup_horizon)
                .as_secs_f64(),
        )
        .bind(oldest_recoverable_at)
        .fetch_one(&mut *transaction)
        .await?;
        if !retention_elapsed || oldest_recoverable_at <= completed_at {
            return Err(DbError::InvalidData(
                "external ledger purge is earlier than retention or backup evidence allows"
                    .to_owned(),
            ));
        }
        sqlx::query(
            r"
            INSERT INTO account_deletion_external_purges (
                operation_id, actor_label, evidence_id,
                completed_at, oldest_recoverable_at
            ) VALUES ($1, $2, $3, $4, $5)
            ",
        )
        .bind(ledger.operation_id)
        .bind(actor)
        .bind(evidence_id)
        .bind(completed_at)
        .bind(oldest_recoverable_at)
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            r"
            INSERT INTO account_deletion_events (
                operation_id, from_state, to_state,
                actor_kind, actor_label, reason_code
            ) VALUES ($1, 'completed', 'completed', 'admin', $2, 'external_purge_authorized')
            ",
        )
        .bind(ledger.operation_id)
        .bind(actor)
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ExternalLedgerPurgeAuthorization {
            state: ExternalLedgerPurgeAuthorizationState::Authorized,
        })
    }

    pub async fn finish_external_ledger_purge(
        &self,
        operation_id: Uuid,
        evidence_id: &str,
        actor: &str,
        audit_retention: Duration,
    ) -> Result<(), DbError> {
        if !valid_purge_actor(actor) || !valid_evidence_id(evidence_id) {
            return Err(DbError::InvalidData(
                "external ledger purge evidence is invalid".to_owned(),
            ));
        }
        validate_retention(audit_retention)?;
        let result = sqlx::query(
            r"
            UPDATE account_deletion_external_purges
            SET purged_at = COALESCE(purged_at, statement_timestamp()),
                expires_at = COALESCE(
                    expires_at,
                    statement_timestamp() + make_interval(secs => $4::double precision)
                )
            WHERE operation_id = $1
              AND actor_label = $2
              AND evidence_id = $3
            ",
        )
        .bind(operation_id)
        .bind(actor)
        .bind(evidence_id)
        .bind(audit_retention.as_secs_f64())
        .execute(&self.pool)
        .await?;
        if result.rows_affected() != 1 {
            return Err(DbError::InvalidData(
                "external ledger purge was not authorized".to_owned(),
            ));
        }
        Ok(())
    }

    #[allow(clippy::too_many_lines)] // One transaction keeps dependent event/job/ledger cleanup ordered.
    pub async fn cleanup_retention(&self, batch_size: u32) -> Result<u64, DbError> {
        if batch_size == 0 {
            return Ok(0);
        }
        if batch_size > 10_000 {
            return Err(DbError::InvalidData(
                "deletion retention cleanup batch is too large".into(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        let moderation = sqlx::query(
            r"
            WITH expired AS (
                SELECT ctid FROM comment_moderation_events
                WHERE retention_expires_at <= statement_timestamp()
                ORDER BY retention_expires_at, id
                FOR UPDATE SKIP LOCKED
                LIMIT $1
            )
            DELETE FROM comment_moderation_events events
            USING expired
            WHERE events.ctid = expired.ctid
            ",
        )
        .bind(i64::from(batch_size))
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        let events = sqlx::query(
            r"
            WITH expired AS (
                SELECT ctid FROM account_deletion_events
                WHERE expires_at <= statement_timestamp()
                ORDER BY expires_at, id
                FOR UPDATE SKIP LOCKED
                LIMIT $1
            )
            DELETE FROM account_deletion_events events
            USING expired
            WHERE events.ctid = expired.ctid
            ",
        )
        .bind(i64::from(batch_size))
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        let expired_operations: Vec<Uuid> = sqlx::query_scalar(
            r"
            SELECT ledger.operation_id
            FROM account_deletion_ledger ledger
            JOIN account_deletion_jobs jobs USING (operation_id)
            JOIN account_deletion_external_purges purge USING (operation_id)
            WHERE ledger.expires_at <= statement_timestamp()
              AND ledger.externalized_at IS NOT NULL
              AND jobs.state = 'completed'
              AND purge.purged_at IS NOT NULL
            ORDER BY ledger.expires_at, ledger.operation_id
            FOR UPDATE OF ledger, jobs SKIP LOCKED
            LIMIT $1
            ",
        )
        .bind(i64::from(batch_size))
        .fetch_all(&mut *transaction)
        .await?;
        if !expired_operations.is_empty() {
            sqlx::query("DELETE FROM account_deletion_events WHERE operation_id = ANY($1::uuid[])")
                .bind(&expired_operations)
                .execute(&mut *transaction)
                .await?;
            sqlx::query("DELETE FROM account_deletion_jobs WHERE operation_id = ANY($1::uuid[])")
                .bind(&expired_operations)
                .execute(&mut *transaction)
                .await?;
            sqlx::query("DELETE FROM account_deletion_ledger WHERE operation_id = ANY($1::uuid[])")
                .bind(&expired_operations)
                .execute(&mut *transaction)
                .await?;
        }
        let purge_audits = sqlx::query(
            r"
            WITH expired AS (
                SELECT purge.operation_id
                FROM account_deletion_external_purges purge
                WHERE purge.expires_at <= statement_timestamp()
                  AND NOT EXISTS (
                      SELECT 1 FROM account_deletion_ledger ledger
                      WHERE ledger.operation_id = purge.operation_id
                  )
                ORDER BY purge.expires_at, purge.operation_id
                FOR UPDATE SKIP LOCKED
                LIMIT $1
            )
            DELETE FROM account_deletion_external_purges purge
            USING expired
            WHERE purge.operation_id = expired.operation_id
            ",
        )
        .bind(i64::from(batch_size))
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        transaction.commit().await?;
        Ok(moderation
            + events
            + purge_audits
            + u64::try_from(expired_operations.len()).unwrap_or(u64::MAX))
    }

    async fn fetch_by_fingerprint(
        &self,
        fingerprint: &IdentityFingerprint,
        _for_update: Option<()>,
    ) -> Result<Option<DeletionRow>, DbError> {
        sqlx::query_as::<_, DeletionRow>(&format!(
            r"
            SELECT {DELETION_COLUMNS}
            FROM account_deletion_jobs jobs
            JOIN account_deletion_ledger ledger USING (operation_id)
            WHERE ledger.identity_fingerprint_key_id = $1
              AND ledger.identity_fingerprint = $2
            "
        ))
        .bind(fingerprint.key_id())
        .bind(fingerprint.digest().as_slice())
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::from)
    }

    async fn fetch_by_operation(&self, operation_id: Uuid) -> Result<Option<DeletionRow>, DbError> {
        sqlx::query_as::<_, DeletionRow>(&format!(
            r"
            SELECT {DELETION_COLUMNS}
            FROM account_deletion_jobs jobs
            JOIN account_deletion_ledger ledger USING (operation_id)
            WHERE jobs.operation_id = $1
            "
        ))
        .bind(operation_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::from)
    }
}

async fn lock_fingerprints(
    transaction: &mut Transaction<'_, Postgres>,
    fingerprints: &[IdentityFingerprint],
) -> Result<(), DbError> {
    let mut keys = fingerprints
        .iter()
        .map(IdentityFingerprint::advisory_lock_key)
        .collect::<Vec<_>>();
    keys.sort_unstable();
    keys.dedup();
    for key in keys {
        sqlx::query("SELECT pg_advisory_xact_lock($1)")
            .bind(key)
            .execute(&mut **transaction)
            .await?;
    }
    Ok(())
}

async fn fetch_by_fingerprints_in(
    transaction: &mut Transaction<'_, Postgres>,
    fingerprints: &[IdentityFingerprint],
) -> Result<Option<DeletionRow>, DbError> {
    for fingerprint in fingerprints {
        let row = sqlx::query_as::<_, DeletionRow>(&format!(
            r"
            SELECT {DELETION_COLUMNS}
            FROM account_deletion_jobs jobs
            JOIN account_deletion_ledger ledger USING (operation_id)
            WHERE ledger.identity_fingerprint_key_id = $1
              AND ledger.identity_fingerprint = $2
            FOR UPDATE OF jobs, ledger
            "
        ))
        .bind(fingerprint.key_id())
        .bind(fingerprint.digest().as_slice())
        .fetch_optional(&mut **transaction)
        .await?;
        if row.is_some() {
            return Ok(row);
        }
    }
    Ok(None)
}

async fn fetch_by_operation_in(
    transaction: &mut Transaction<'_, Postgres>,
    operation_id: Uuid,
) -> Result<Option<DeletionRow>, DbError> {
    sqlx::query_as::<_, DeletionRow>(&format!(
        r"
        SELECT {DELETION_COLUMNS}
        FROM account_deletion_jobs jobs
        JOIN account_deletion_ledger ledger USING (operation_id)
        WHERE jobs.operation_id = $1
        "
    ))
    .bind(operation_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn consume_account_delete_rate_limit(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    limit: u32,
    window: Duration,
) -> Result<Option<u64>, DbError> {
    #[derive(FromRow)]
    struct RateRow {
        request_count: i64,
        retry_after_seconds: i64,
    }
    let row = sqlx::query_as::<_, RateRow>(
        r"
        WITH upserted AS (
            INSERT INTO shared_rate_limit_buckets (
                bucket, scope_key, window_started_at,
                window_ends_at, request_count, updated_at
            )
            VALUES (
                'account_delete', $1, statement_timestamp(),
                statement_timestamp() + make_interval(secs => $2::double precision),
                1, statement_timestamp()
            )
            ON CONFLICT (bucket, scope_key) DO UPDATE
            SET window_started_at = CASE
                    WHEN shared_rate_limit_buckets.window_ends_at <= EXCLUDED.window_started_at
                    THEN EXCLUDED.window_started_at ELSE shared_rate_limit_buckets.window_started_at
                END,
                window_ends_at = CASE
                    WHEN shared_rate_limit_buckets.window_ends_at <= EXCLUDED.window_started_at
                    THEN EXCLUDED.window_ends_at ELSE shared_rate_limit_buckets.window_ends_at
                END,
                request_count = CASE
                    WHEN shared_rate_limit_buckets.window_ends_at <= EXCLUDED.window_started_at
                    THEN 1 ELSE LEAST(shared_rate_limit_buckets.request_count, 9223372036854775806) + 1
                END,
                updated_at = EXCLUDED.updated_at
            RETURNING request_count, window_ends_at
        )
        SELECT request_count,
               GREATEST(1, CEIL(EXTRACT(EPOCH FROM (
                   window_ends_at - statement_timestamp()
               )))::bigint) AS retry_after_seconds
        FROM upserted
        ",
    )
    .bind(format!("user:{user_id}"))
    .bind(window.as_secs_f64())
    .fetch_one(&mut **transaction)
    .await?;
    Ok((row.request_count > i64::from(limit))
        .then_some(u64::try_from(row.retry_after_seconds).unwrap_or(1).max(1)))
}

async fn insert_transition_event(
    transaction: &mut Transaction<'_, Postgres>,
    operation_id: Uuid,
    from: AccountDeletionState,
    to: AccountDeletionState,
    reason: &str,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO account_deletion_events (
            operation_id, from_state, to_state, actor_kind, reason_code
        ) VALUES ($1, $2, $3, 'system', $4)
        ",
    )
    .bind(operation_id)
    .bind(from.as_str())
    .bind(to.as_str())
    .bind(reason)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

fn valid_transition(from: AccountDeletionState, to: AccountDeletionState) -> bool {
    matches!(
        (from, to),
        (
            AccountDeletionState::Requested,
            AccountDeletionState::SessionsRevoked
        ) | (
            AccountDeletionState::SessionsRevoked,
            AccountDeletionState::IdentityDeleted
        ) | (
            AccountDeletionState::IdentityDeleted,
            AccountDeletionState::AppDataDeleted
        ) | (
            AccountDeletionState::AppDataDeleted,
            AccountDeletionState::Completed
        )
    )
}

fn validate_worker(worker_id: &str, lease: Duration) -> Result<(), DbError> {
    if worker_id.is_empty()
        || worker_id.len() > 128
        || worker_id.trim() != worker_id
        || worker_id.chars().any(char::is_control)
        || lease < Duration::from_secs(5)
        || lease > Duration::from_secs(60 * 60)
    {
        return Err(DbError::InvalidData(
            "deletion worker lease is invalid".into(),
        ));
    }
    Ok(())
}

fn validate_retention(retention: Duration) -> Result<(), DbError> {
    if retention < Duration::from_secs(24 * 60 * 60)
        || retention > Duration::from_secs(10 * 365 * 24 * 60 * 60)
    {
        return Err(DbError::InvalidData("deletion retention is invalid".into()));
    }
    Ok(())
}

fn valid_code(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b':' | b'-')
        })
}

fn valid_actor(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.trim() == value
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'@' | b'.' | b'_' | b':' | b'-')
        })
}

fn valid_evidence_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.trim() == value
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'/' | b'-')
        })
}

fn valid_purge_actor(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.trim() == value
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
}

fn valid_provider_identity(issuer: &str, subject: &str) -> bool {
    !issuer.is_empty()
        && issuer.len() <= 2_048
        && issuer.trim() == issuer
        && !issuer.chars().any(char::is_control)
        && !subject.is_empty()
        && subject.len() <= 512
        && subject.trim() == subject
        && !subject.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transition_graph_is_strict() {
        assert!(valid_transition(
            AccountDeletionState::Requested,
            AccountDeletionState::SessionsRevoked
        ));
        assert!(!valid_transition(
            AccountDeletionState::Requested,
            AccountDeletionState::IdentityDeleted
        ));
        assert!(!valid_transition(
            AccountDeletionState::Completed,
            AccountDeletionState::Requested
        ));
    }

    #[test]
    fn claimed_debug_redacts_provider_identity() {
        let job = ClaimedAccountDeletion {
            operation_id: Uuid::nil(),
            user_id: Uuid::nil(),
            fingerprint: IdentityFingerprint::new("secret_key_id", [7; 32]).unwrap(),
            issuer: Some("https://private-issuer.example".into()),
            subject: Some("private-subject".into()),
            state: AccountDeletionState::Requested,
            retry_from: None,
            attempt: 1,
            max_attempts: 12,
            requested_at: Utc::now(),
            updated_at: Utc::now(),
            externalized_at: None,
        };
        let rendered = format!("{job:?}");
        assert!(!rendered.contains("private-issuer"));
        assert!(!rendered.contains("private-subject"));
        assert!(!rendered.contains("secret_key_id"));
    }
}
