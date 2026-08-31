use std::{fmt, str::FromStr, sync::OnceLock};

use chrono::{DateTime, Utc};
use domain::{AccountStatus, AuthenticatedUserId, PaperId};
use regex::Regex;
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::DbError;

const MAX_NORMALIZED_ARXIV_BASE_CHARS: usize = 128;
const MAX_ERROR_CODE_CHARS: usize = 64;

/// A keyed or versioned digest of the normalized import intent.
///
/// The database boundary accepts only an already-computed fixed-width value;
/// it never receives the raw URL or identifier from which the caller derived
/// the digest. Debug output is deliberately redacted.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct PaperImportFingerprint([u8; 32]);

impl PaperImportFingerprint {
    #[must_use]
    pub const fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Debug for PaperImportFingerprint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("PaperImportFingerprint")
            .field(&"[redacted]")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperImportInputKind {
    ArxivUrl,
    ArxivId,
}

impl PaperImportInputKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ArxivUrl => "arxiv_url",
            Self::ArxivId => "arxiv_id",
        }
    }
}

impl FromStr for PaperImportInputKind {
    type Err = DbError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "arxiv_url" => Ok(Self::ArxivUrl),
            "arxiv_id" => Ok(Self::ArxivId),
            _ => Err(DbError::InvalidData(
                "persisted paper import input kind is invalid".to_owned(),
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperImportStatus {
    Resolving,
    Completed,
    RetryableFailure,
    TerminalFailure,
}

impl PaperImportStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Resolving => "resolving",
            Self::Completed => "completed",
            Self::RetryableFailure => "retryable_failure",
            Self::TerminalFailure => "terminal_failure",
        }
    }

    const fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::TerminalFailure)
    }
}

impl FromStr for PaperImportStatus {
    type Err = DbError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "resolving" => Ok(Self::Resolving),
            "completed" => Ok(Self::Completed),
            "retryable_failure" => Ok(Self::RetryableFailure),
            "terminal_failure" => Ok(Self::TerminalFailure),
            _ => Err(DbError::InvalidData(
                "persisted paper import status is invalid".to_owned(),
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredPaperImportOperation {
    pub operation_id: Uuid,
    pub input_kind: PaperImportInputKind,
    pub normalized_arxiv_base: Option<String>,
    pub paper_id: Option<PaperId>,
    pub status: PaperImportStatus,
    pub error_code: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaperImportFinalization {
    Completed {
        normalized_arxiv_base: String,
        paper_id: PaperId,
    },
    RetryableFailure {
        normalized_arxiv_base: Option<String>,
        error_code: String,
    },
    TerminalFailure {
        normalized_arxiv_base: Option<String>,
        error_code: String,
    },
}

impl PaperImportFinalization {
    const fn status(&self) -> PaperImportStatus {
        match self {
            Self::Completed { .. } => PaperImportStatus::Completed,
            Self::RetryableFailure { .. } => PaperImportStatus::RetryableFailure,
            Self::TerminalFailure { .. } => PaperImportStatus::TerminalFailure,
        }
    }

    fn normalized_arxiv_base(&self) -> Option<&str> {
        match self {
            Self::Completed {
                normalized_arxiv_base,
                ..
            } => Some(normalized_arxiv_base),
            Self::RetryableFailure {
                normalized_arxiv_base,
                ..
            }
            | Self::TerminalFailure {
                normalized_arxiv_base,
                ..
            } => normalized_arxiv_base.as_deref(),
        }
    }

    const fn paper_id(&self) -> Option<PaperId> {
        match self {
            Self::Completed { paper_id, .. } => Some(*paper_id),
            Self::RetryableFailure { .. } | Self::TerminalFailure { .. } => None,
        }
    }

    fn error_code(&self) -> Option<&str> {
        match self {
            Self::Completed { .. } => None,
            Self::RetryableFailure { error_code, .. }
            | Self::TerminalFailure { error_code, .. } => Some(error_code),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaperImportReserveOutcome {
    Reserved(StoredPaperImportOperation),
    Resume(StoredPaperImportOperation),
    Replay(StoredPaperImportOperation),
    AccountNotFound,
    Inactive(AccountStatus),
    Conflict,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaperImportReadOutcome {
    Unknown,
    Resume(StoredPaperImportOperation),
    Replay(StoredPaperImportOperation),
    AccountNotFound,
    Inactive(AccountStatus),
    Conflict,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaperImportFinalizeOutcome {
    Finalized(StoredPaperImportOperation),
    Replay(StoredPaperImportOperation),
    Unknown,
    AccountNotFound,
    Inactive(AccountStatus),
    Conflict,
}

/// Short-transaction persistence for exact import idempotency.
///
/// Every method begins and finishes its own database transaction. Callers must
/// commit `reserve`, perform any arXiv work outside this repository, and then
/// call `finalize`; no transaction or connection guard crosses that boundary.
#[derive(Clone)]
pub struct PaperImportRepository {
    pool: PgPool,
}

impl PaperImportRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Removes one bounded batch of expired terminal idempotency records.
    ///
    /// Resolving and retryable operations are deliberately outside this
    /// query: callers may still be working on or resuming them, regardless of
    /// their age. The terminal cleanup index keeps the deterministic age walk
    /// independent from those in-flight rows.
    pub async fn cleanup_terminal_operations(
        &self,
        completed_before: DateTime<Utc>,
        batch_size: u32,
    ) -> Result<u64, DbError> {
        if batch_size == 0 || batch_size > 10_000 {
            return Err(DbError::InvalidData(
                "paper-import cleanup batch is invalid".to_owned(),
            ));
        }
        let result = sqlx::query(
            r"
            WITH expired AS (
                SELECT user_id, operation_id
                FROM paper_import_operations
                WHERE status IN ('completed', 'terminal_failure')
                  AND completed_at <= $1
                ORDER BY completed_at, user_id, operation_id
                LIMIT $2
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM paper_import_operations AS operation
            USING expired
            WHERE operation.user_id = expired.user_id
              AND operation.operation_id = expired.operation_id
            ",
        )
        .bind(completed_before)
        .bind(i64::from(batch_size))
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    pub async fn reserve(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        input_fingerprint: PaperImportFingerprint,
        normalized_arxiv_base: Option<&str>,
    ) -> Result<PaperImportReserveOutcome, DbError> {
        validate_operation_id(operation_id)?;
        validate_normalized_arxiv_base(normalized_arxiv_base)?;

        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(PaperImportReserveOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(PaperImportReserveOutcome::Inactive(status));
        }
        advisory_lock(&mut transaction, user_id, operation_id).await?;

        if let Some(row) =
            load_operation(&mut transaction, user_id, operation_id, input_fingerprint).await?
        {
            if !row.fingerprint_matches || row.input_kind != input_kind.as_str() {
                transaction.commit().await?;
                return Ok(PaperImportReserveOutcome::Conflict);
            }
            let operation = StoredPaperImportOperation::try_from(row)?;
            if normalized_arxiv_base_conflicts(&operation, normalized_arxiv_base) {
                transaction.commit().await?;
                return Ok(PaperImportReserveOutcome::Conflict);
            }
            if operation.status.is_terminal() {
                transaction.commit().await?;
                return Ok(PaperImportReserveOutcome::Replay(operation));
            }

            // A resume is the start of a fresh attempt. Touch its cleanup age
            // even when it was already `resolving`, and reopen retryable rows
            // before the caller performs any external I/O.
            sqlx::query(
                r"
                UPDATE paper_import_operations
                SET normalized_arxiv_base = COALESCE(
                        normalized_arxiv_base,
                        $3
                    ),
                    status = 'resolving',
                    error_code = NULL,
                    updated_at = GREATEST(updated_at, statement_timestamp()),
                    completed_at = NULL
                WHERE user_id = $1 AND operation_id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(operation_id)
            .bind(normalized_arxiv_base)
            .execute(&mut *transaction)
            .await?;
            let operation = load_checked_operation(
                &mut transaction,
                user_id,
                operation_id,
                input_kind,
                input_fingerprint,
            )
            .await?;
            transaction.commit().await?;
            return Ok(PaperImportReserveOutcome::Resume(operation));
        }

        sqlx::query(
            r"
            INSERT INTO paper_import_operations (
                user_id,
                operation_id,
                input_kind,
                input_fingerprint,
                normalized_arxiv_base,
                status
            )
            VALUES ($1, $2, $3, $4, $5, 'resolving')
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(input_kind.as_str())
        .bind(input_fingerprint.as_bytes().as_slice())
        .bind(normalized_arxiv_base)
        .execute(&mut *transaction)
        .await?;
        let operation = load_checked_operation(
            &mut transaction,
            user_id,
            operation_id,
            input_kind,
            input_fingerprint,
        )
        .await?;
        transaction.commit().await?;
        Ok(PaperImportReserveOutcome::Reserved(operation))
    }

    pub async fn read(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        input_fingerprint: PaperImportFingerprint,
    ) -> Result<PaperImportReadOutcome, DbError> {
        validate_operation_id(operation_id)?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(PaperImportReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(PaperImportReadOutcome::Inactive(status));
        }
        advisory_lock(&mut transaction, user_id, operation_id).await?;
        let Some(row) =
            load_operation(&mut transaction, user_id, operation_id, input_fingerprint).await?
        else {
            transaction.commit().await?;
            return Ok(PaperImportReadOutcome::Unknown);
        };
        if !row.fingerprint_matches || row.input_kind != input_kind.as_str() {
            transaction.commit().await?;
            return Ok(PaperImportReadOutcome::Conflict);
        }
        let operation = StoredPaperImportOperation::try_from(row)?;
        transaction.commit().await?;
        Ok(if operation.status.is_terminal() {
            PaperImportReadOutcome::Replay(operation)
        } else {
            PaperImportReadOutcome::Resume(operation)
        })
    }

    pub async fn finalize(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        input_fingerprint: PaperImportFingerprint,
        finalization: PaperImportFinalization,
    ) -> Result<PaperImportFinalizeOutcome, DbError> {
        validate_operation_id(operation_id)?;
        validate_finalization(&finalization)?;

        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(PaperImportFinalizeOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(PaperImportFinalizeOutcome::Inactive(status));
        }
        advisory_lock(&mut transaction, user_id, operation_id).await?;
        let Some(row) =
            load_operation(&mut transaction, user_id, operation_id, input_fingerprint).await?
        else {
            transaction.commit().await?;
            return Ok(PaperImportFinalizeOutcome::Unknown);
        };
        if !row.fingerprint_matches || row.input_kind != input_kind.as_str() {
            transaction.commit().await?;
            return Ok(PaperImportFinalizeOutcome::Conflict);
        }
        let operation = StoredPaperImportOperation::try_from(row)?;
        if normalized_arxiv_base_conflicts(&operation, finalization.normalized_arxiv_base()) {
            transaction.commit().await?;
            return Ok(PaperImportFinalizeOutcome::Conflict);
        }
        if finalization_matches(&operation, &finalization) {
            transaction.commit().await?;
            return Ok(PaperImportFinalizeOutcome::Replay(operation));
        }
        if operation.status.is_terminal() {
            transaction.commit().await?;
            return Ok(PaperImportFinalizeOutcome::Conflict);
        }

        sqlx::query(
            r"
            UPDATE paper_import_operations
            SET normalized_arxiv_base = COALESCE(
                    $3,
                    normalized_arxiv_base
                ),
                paper_id = $4,
                status = $5,
                error_code = $6,
                updated_at = GREATEST(updated_at, statement_timestamp()),
                completed_at = CASE
                    WHEN $5 IN ('completed', 'terminal_failure')
                        THEN GREATEST(updated_at, statement_timestamp())
                    ELSE NULL
                END
            WHERE user_id = $1 AND operation_id = $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(finalization.normalized_arxiv_base())
        .bind(finalization.paper_id())
        .bind(finalization.status().as_str())
        .bind(finalization.error_code())
        .execute(&mut *transaction)
        .await?;
        let operation = load_checked_operation(
            &mut transaction,
            user_id,
            operation_id,
            input_kind,
            input_fingerprint,
        )
        .await?;
        transaction.commit().await?;
        Ok(PaperImportFinalizeOutcome::Finalized(operation))
    }
}

async fn lock_account_status(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<AccountStatus>, DbError> {
    sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1 FOR SHARE")
        .bind(user_id.into_inner())
        .fetch_optional(&mut **transaction)
        .await?
        .map(|status| {
            AccountStatus::from_str(&status)
                .map_err(|error| DbError::InvalidData(error.to_string()))
        })
        .transpose()
}

async fn advisory_lock(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        SELECT pg_advisory_xact_lock(
            hashtextextended('paper-import:' || $1::text || ':' || $2::text, 0)
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn load_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    input_fingerprint: PaperImportFingerprint,
) -> Result<Option<PaperImportOperationRow>, DbError> {
    sqlx::query_as::<_, PaperImportOperationRow>(
        r"
        SELECT
            operation_id,
            input_kind,
            input_fingerprint = $3 AS fingerprint_matches,
            normalized_arxiv_base,
            paper_id,
            status,
            error_code,
            created_at,
            updated_at,
            completed_at
        FROM paper_import_operations
        WHERE user_id = $1 AND operation_id = $2
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(input_fingerprint.as_bytes().as_slice())
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn load_checked_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    input_kind: PaperImportInputKind,
    input_fingerprint: PaperImportFingerprint,
) -> Result<StoredPaperImportOperation, DbError> {
    let row = load_operation(transaction, user_id, operation_id, input_fingerprint)
        .await?
        .ok_or_else(|| {
            DbError::InvalidData("paper import operation disappeared while locked".to_owned())
        })?;
    if !row.fingerprint_matches || row.input_kind != input_kind.as_str() {
        return Err(DbError::InvalidData(
            "paper import operation changed while locked".to_owned(),
        ));
    }
    StoredPaperImportOperation::try_from(row)
}

fn normalized_arxiv_base_conflicts(
    operation: &StoredPaperImportOperation,
    candidate: Option<&str>,
) -> bool {
    matches!(
        (operation.normalized_arxiv_base.as_deref(), candidate),
        (Some(existing), Some(candidate)) if existing != candidate
    )
}

fn finalization_matches(
    operation: &StoredPaperImportOperation,
    finalization: &PaperImportFinalization,
) -> bool {
    if operation.status != finalization.status()
        || operation.paper_id != finalization.paper_id()
        || operation.error_code.as_deref() != finalization.error_code()
    {
        return false;
    }
    finalization
        .normalized_arxiv_base()
        .is_none_or(|normalized| operation.normalized_arxiv_base.as_deref() == Some(normalized))
}

fn validate_operation_id(operation_id: Uuid) -> Result<(), DbError> {
    if operation_id.is_nil() {
        return Err(DbError::InvalidData(
            "paper import operation ID must not be nil".to_owned(),
        ));
    }
    Ok(())
}

fn validate_finalization(finalization: &PaperImportFinalization) -> Result<(), DbError> {
    validate_normalized_arxiv_base(finalization.normalized_arxiv_base())?;
    if finalization
        .paper_id()
        .is_some_and(|paper_id| paper_id.is_nil())
    {
        return Err(DbError::InvalidData(
            "paper import result paper ID must not be nil".to_owned(),
        ));
    }
    if let Some(error_code) = finalization.error_code() {
        validate_error_code(error_code)?;
    }
    Ok(())
}

fn validate_normalized_arxiv_base(value: Option<&str>) -> Result<(), DbError> {
    let Some(value) = value else {
        return Ok(());
    };
    if value.trim() != value
        || !(1..=MAX_NORMALIZED_ARXIV_BASE_CHARS).contains(&value.chars().count())
        || !normalized_arxiv_base_regex().is_match(value)
    {
        return Err(DbError::InvalidData(
            "normalized arXiv base is invalid".to_owned(),
        ));
    }
    Ok(())
}

fn normalized_arxiv_base_regex() -> &'static Regex {
    static VALUE: OnceLock<Regex> = OnceLock::new();
    VALUE.get_or_init(|| {
        Regex::new(r"^(?:[0-9]{4}[.][0-9]{4,5}|[A-Za-z][A-Za-z0-9.-]*/[0-9]{7})$")
            .expect("normalized arXiv base regex is valid")
    })
}

fn validate_error_code(value: &str) -> Result<(), DbError> {
    if !(1..=MAX_ERROR_CODE_CHARS).contains(&value.chars().count())
        || !value.bytes().enumerate().all(|(index, byte)| match byte {
            b'A'..=b'Z' => true,
            b'0'..=b'9' | b'_' => index > 0,
            _ => false,
        })
    {
        return Err(DbError::InvalidData(
            "paper import error code is invalid".to_owned(),
        ));
    }
    Ok(())
}

#[derive(Debug, FromRow)]
struct PaperImportOperationRow {
    operation_id: Uuid,
    input_kind: String,
    fingerprint_matches: bool,
    normalized_arxiv_base: Option<String>,
    paper_id: Option<Uuid>,
    status: String,
    error_code: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    completed_at: Option<DateTime<Utc>>,
}

impl TryFrom<PaperImportOperationRow> for StoredPaperImportOperation {
    type Error = DbError;

    fn try_from(row: PaperImportOperationRow) -> Result<Self, Self::Error> {
        validate_operation_id(row.operation_id)?;
        validate_normalized_arxiv_base(row.normalized_arxiv_base.as_deref())?;
        if let Some(error_code) = row.error_code.as_deref() {
            validate_error_code(error_code)?;
        }
        let input_kind = PaperImportInputKind::from_str(&row.input_kind)?;
        let status = PaperImportStatus::from_str(&row.status)?;
        if row.updated_at < row.created_at
            || row.completed_at.is_some_and(|completed_at| {
                completed_at < row.created_at || completed_at > row.updated_at
            })
            || !persisted_shape_is_valid(
                status,
                row.normalized_arxiv_base.as_deref(),
                row.paper_id,
                row.error_code.as_deref(),
                row.completed_at,
            )
        {
            return Err(DbError::InvalidData(
                "persisted paper import operation is inconsistent".to_owned(),
            ));
        }
        Ok(Self {
            operation_id: row.operation_id,
            input_kind,
            normalized_arxiv_base: row.normalized_arxiv_base,
            paper_id: row.paper_id,
            status,
            error_code: row.error_code,
            created_at: row.created_at,
            updated_at: row.updated_at,
            completed_at: row.completed_at,
        })
    }
}

fn persisted_shape_is_valid(
    status: PaperImportStatus,
    normalized_arxiv_base: Option<&str>,
    paper_id: Option<PaperId>,
    error_code: Option<&str>,
    completed_at: Option<DateTime<Utc>>,
) -> bool {
    match status {
        PaperImportStatus::Resolving => {
            paper_id.is_none() && error_code.is_none() && completed_at.is_none()
        }
        PaperImportStatus::Completed => {
            normalized_arxiv_base.is_some()
                && paper_id.is_some()
                && error_code.is_none()
                && completed_at.is_some()
        }
        PaperImportStatus::RetryableFailure => {
            paper_id.is_none() && error_code.is_some() && completed_at.is_none()
        }
        PaperImportStatus::TerminalFailure => {
            paper_id.is_none() && error_code.is_some() && completed_at.is_some()
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone as _;

    use super::*;

    #[test]
    fn fingerprint_debug_output_is_redacted() {
        let fingerprint = PaperImportFingerprint::new([0x5a; 32]);
        let rendered = format!("{fingerprint:?}");
        assert!(rendered.contains("[redacted]"));
        assert!(!rendered.contains("5a"));
    }

    #[test]
    fn closed_names_round_trip_and_reject_unknown_values() {
        for kind in [
            PaperImportInputKind::ArxivUrl,
            PaperImportInputKind::ArxivId,
        ] {
            assert_eq!(PaperImportInputKind::from_str(kind.as_str()).unwrap(), kind);
        }
        for status in [
            PaperImportStatus::Resolving,
            PaperImportStatus::Completed,
            PaperImportStatus::RetryableFailure,
            PaperImportStatus::TerminalFailure,
        ] {
            assert_eq!(
                PaperImportStatus::from_str(status.as_str()).unwrap(),
                status
            );
        }
        assert!(PaperImportInputKind::from_str("raw_url").is_err());
        assert!(PaperImportStatus::from_str("failed").is_err());
    }

    #[test]
    fn normalized_identity_and_error_code_validation_is_bounded() {
        for valid in ["2401.12345", "hep-th/9901001", "math.GT/0309136"] {
            assert!(validate_normalized_arxiv_base(Some(valid)).is_ok());
        }
        for invalid in [
            "",
            " 2401.12345",
            "2401.12345v2",
            "https://arxiv.org/abs/2401.12345",
            "../2401.12345",
        ] {
            assert!(validate_normalized_arxiv_base(Some(invalid)).is_err());
        }
        assert!(validate_error_code("PAPER_SEARCH_UNAVAILABLE").is_ok());
        assert!(validate_error_code("paper_search_unavailable").is_err());
        assert!(validate_error_code(&"A".repeat(MAX_ERROR_CODE_CHARS + 1)).is_err());
    }

    #[test]
    fn persisted_row_validation_rejects_impossible_state_shapes() {
        let now = Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap();
        let row = PaperImportOperationRow {
            operation_id: Uuid::now_v7(),
            input_kind: "arxiv_url".to_owned(),
            fingerprint_matches: true,
            normalized_arxiv_base: Some("2401.12345".to_owned()),
            paper_id: None,
            status: "completed".to_owned(),
            error_code: None,
            created_at: now,
            updated_at: now,
            completed_at: Some(now),
        };
        assert!(StoredPaperImportOperation::try_from(row).is_err());
    }
}
