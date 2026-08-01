use std::str::FromStr;

use chrono::{DateTime, Utc};
use domain::{
    AccountStatus, AuthenticatedUserId, LibraryChange, LibraryItem, LibraryState, PaperId,
    PaperSummary, SavedLibraryPaper,
};
use opaque_cursor::OpaqueCursorCodec;
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, QueryBuilder, Transaction};
use uuid::Uuid;

use super::{DbError, rows::PaperSummaryRow};
use crate::LibraryCursor;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryMutationIntent {
    Save,
    Remove,
}

impl LibraryMutationIntent {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Save => "save",
            Self::Remove => "remove",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryMutationOutcome {
    Applied { item: LibraryItem, replayed: bool },
    AccountNotFound,
    Inactive(AccountStatus),
    PaperNotFound,
    IdempotencyConflict,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryOperationResolution {
    Unknown,
    Replay(LibraryItem),
    AccountNotFound,
    Inactive(AccountStatus),
    IdempotencyConflict,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LibraryReadOutcome<T> {
    Found(T),
    AccountNotFound,
    Inactive(AccountStatus),
    InvalidCursor,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StoredLibraryPage {
    pub items: Vec<SavedLibraryPaper>,
    pub next_cursor: Option<String>,
    pub sync_revision: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StoredLibraryChangesPage {
    pub items: Vec<LibraryChange>,
    pub next_after_revision: i64,
    pub has_more: bool,
    pub sync_revision: i64,
    pub purged_through_revision: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LibraryChangesOutcome {
    Found(StoredLibraryChangesPage),
    AccountNotFound,
    Inactive(AccountStatus),
    InvalidAfterRevision,
    ResetRequired {
        purged_through_revision: i64,
        sync_revision: i64,
    },
}

#[derive(Clone)]
pub struct LibraryRepository {
    pool: PgPool,
    cursor_codec: Option<OpaqueCursorCodec>,
}

impl LibraryRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self {
            pool,
            cursor_codec: None,
        }
    }

    pub(super) fn with_cursor_codec(pool: PgPool, cursor_codec: Option<OpaqueCursorCodec>) -> Self {
        Self { pool, cursor_codec }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Resolves a durable operation before consuming a write-rate permit.
    /// Known operations take the same operation/paper locks as mutation, so a
    /// replay cannot observe an older canonical row while a newer accepted
    /// mutation is committing.
    pub async fn resolve_operation(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        state: LibraryState,
    ) -> Result<LibraryOperationResolution, DbError> {
        if operation_id.is_nil() {
            return Err(DbError::InvalidData(
                "library operation ID must not be nil".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryOperationResolution::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryOperationResolution::Inactive(status));
        }
        advisory_lock(&mut transaction, "library-operation", user_id, operation_id).await?;
        advisory_lock(&mut transaction, "library-paper", user_id, paper_id).await?;

        let Some(operation) = load_operation(&mut transaction, user_id, operation_id).await? else {
            transaction.commit().await?;
            return Ok(LibraryOperationResolution::Unknown);
        };
        if operation.paper_id != paper_id
            || operation.intent != intent.as_str()
            || operation.state != state.as_str()
            || !operation.fingerprint_valid
        {
            return Ok(LibraryOperationResolution::IdempotencyConflict);
        }
        let item = load_current_or_compacted_item(&mut transaction, user_id, paper_id)
            .await?
            .ok_or_else(|| {
                DbError::InvalidData(
                    "accepted library operation has no canonical snapshot".to_owned(),
                )
            })?;
        transaction.commit().await?;
        Ok(LibraryOperationResolution::Replay(item))
    }

    /// Applies one operation while serializing both operation-ID reuse and the
    /// target paper. The account's sync-metadata row is locked before the
    /// canonical library row and held through commit, so revisions for that
    /// account cannot become visible out of order across API replicas. Cleanup
    /// uses the same metadata-before-library lock order. Unrelated accounts
    /// never share this fence.
    #[allow(clippy::too_many_lines)]
    pub async fn mutate(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        state: LibraryState,
    ) -> Result<LibraryMutationOutcome, DbError> {
        if operation_id.is_nil() {
            return Err(DbError::InvalidData(
                "library operation ID must not be nil".to_owned(),
            ));
        }

        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryMutationOutcome::Inactive(status));
        }

        advisory_lock(&mut transaction, "library-operation", user_id, operation_id).await?;
        advisory_lock(&mut transaction, "library-paper", user_id, paper_id).await?;

        if let Some(operation) = load_operation(&mut transaction, user_id, operation_id).await? {
            if operation.paper_id != paper_id
                || operation.intent != intent.as_str()
                || operation.state != state.as_str()
                || !operation.fingerprint_valid
            {
                return Ok(LibraryMutationOutcome::IdempotencyConflict);
            }
            let item = load_current_or_compacted_item(&mut transaction, user_id, paper_id)
                .await?
                .ok_or_else(|| {
                    DbError::InvalidData(
                        "accepted library operation has no canonical snapshot".to_owned(),
                    )
                })?;
            transaction.commit().await?;
            return Ok(LibraryMutationOutcome::Applied {
                item,
                replayed: true,
            });
        }

        let paper_exists: bool = sqlx::query_scalar(
            r"
            SELECT EXISTS (
                SELECT 1
                FROM papers AS paper
                JOIN paper_processing AS processing
                    ON processing.paper_id = paper.id
                WHERE paper.id = $1
            )
            ",
        )
        .bind(paper_id)
        .fetch_one(&mut *transaction)
        .await?;
        if !paper_exists {
            return Ok(LibraryMutationOutcome::PaperNotFound);
        }

        let revision = allocate_revision(&mut transaction, user_id).await?;
        let item = match intent {
            LibraryMutationIntent::Save => {
                save_item(
                    &mut transaction,
                    user_id,
                    paper_id,
                    operation_id,
                    state,
                    revision,
                )
                .await?
            }
            LibraryMutationIntent::Remove => {
                remove_item(
                    &mut transaction,
                    user_id,
                    paper_id,
                    operation_id,
                    state,
                    revision,
                )
                .await?
            }
        };

        insert_operation(
            &mut transaction,
            user_id,
            operation_id,
            paper_id,
            intent,
            &item,
        )
        .await?;
        transaction.commit().await?;

        Ok(LibraryMutationOutcome::Applied {
            item,
            replayed: false,
        })
    }

    pub async fn list(
        &self,
        user_id: AuthenticatedUserId,
        state: LibraryState,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        let cursor_scope = library_cursor_scope(user_id, state);
        let cursor = match self.decode_list_cursor(&cursor_scope, cursor) {
            Ok(cursor) => cursor,
            Err(crate::CursorError::Invalid) => {
                return Ok(LibraryReadOutcome::InvalidCursor);
            }
            Err(error) => return Err(error.into()),
        };
        let mut transaction = begin_consistent_read(&self.pool).await?;
        match lock_account_status(&mut transaction, user_id).await? {
            None => return Ok(LibraryReadOutcome::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(LibraryReadOutcome::Inactive(status));
            }
            Some(AccountStatus::Active) => {}
            Some(_) => unreachable!("all inactive statuses matched the guard"),
        }

        let committed_revision = committed_revision_in(&mut transaction, user_id).await?;
        let sync_revision = cursor.map_or(committed_revision, |value| value.sync_revision);
        if sync_revision < 0 || sync_revision > committed_revision {
            return Ok(LibraryReadOutcome::InvalidCursor);
        }

        let mut builder = QueryBuilder::<Postgres>::new(
            r"
            SELECT
                library.paper_id,
                library.state,
                library.saved_at,
                library.updated_at AS library_updated_at,
                library.removed_at,
                library.revision,
                library.last_operation_id,
                paper.arxiv_base_id,
                paper.arxiv_version,
                paper.title,
                paper.abstract AS abstract_text,
                paper.authors,
                paper.primary_category,
                paper.categories,
                paper.published_at,
                paper.updated_at AS paper_updated_at,
                paper.abs_url,
                paper.pdf_url,
                processing.metadata_ready,
                processing.introduction_ready,
                processing.chat_ready,
                processing.connections_ready
            FROM user_paper_library AS library
            JOIN papers AS paper ON paper.id = library.paper_id
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE library.user_id =
            ",
        );
        builder.push_bind(user_id.into_inner());
        builder.push(" AND library.state = ");
        builder.push_bind(state.as_str());
        builder.push(" AND library.removed_at IS NULL AND library.revision <= ");
        builder.push_bind(sync_revision);
        if let Some(cursor) = cursor {
            builder.push(" AND (library.saved_at, library.paper_id) < (");
            builder.push_bind(cursor.saved_at);
            builder.push(", ");
            builder.push_bind(cursor.paper_id);
            builder.push(")");
        }
        builder.push(" ORDER BY library.saved_at DESC, library.paper_id DESC LIMIT ");
        builder.push_bind(i64::from(limit) + 1);

        let mut rows = builder
            .build_query_as::<LibraryPaperRow>()
            .fetch_all(&mut *transaction)
            .await?;
        let has_more = rows.len() > limit as usize;
        if has_more {
            rows.pop();
        }
        let next_cursor = self.encode_next_cursor(&rows, has_more, sync_revision, &cursor_scope)?;
        let items = rows
            .into_iter()
            .map(SavedLibraryPaper::try_from)
            .collect::<Result<Vec<_>, _>>()?;

        transaction.commit().await?;

        Ok(LibraryReadOutcome::Found(StoredLibraryPage {
            items,
            next_cursor,
            sync_revision,
        }))
    }

    fn decode_list_cursor(
        &self,
        scope: &[u8],
        value: Option<&str>,
    ) -> Result<Option<LibraryCursor>, crate::CursorError> {
        let Some(value) = value else {
            return Ok(None);
        };
        let codec = self
            .cursor_codec
            .as_ref()
            .ok_or(crate::CursorError::Unavailable)?;
        let cursor = LibraryCursor::decode(codec, scope, value)?;
        if cursor.paper_id.is_nil() || cursor.sync_revision < 0 {
            return Err(crate::CursorError::Invalid);
        }
        Ok(Some(cursor))
    }

    fn encode_next_cursor(
        &self,
        rows: &[LibraryPaperRow],
        has_more: bool,
        sync_revision: i64,
        scope: &[u8],
    ) -> Result<Option<String>, DbError> {
        if !has_more {
            return Ok(None);
        }
        let codec = self
            .cursor_codec
            .as_ref()
            .ok_or(crate::CursorError::Unavailable)?;
        rows.last()
            .map(|row| {
                LibraryCursor {
                    saved_at: row.saved_at,
                    paper_id: row.paper_id,
                    sync_revision,
                }
                .encode(codec, scope)
                .map_err(DbError::from)
            })
            .transpose()
    }

    pub async fn changes(
        &self,
        user_id: AuthenticatedUserId,
        after_revision: i64,
        limit: u32,
    ) -> Result<LibraryChangesOutcome, DbError> {
        let mut transaction = begin_consistent_read(&self.pool).await?;
        match lock_account_status(&mut transaction, user_id).await? {
            None => return Ok(LibraryChangesOutcome::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(LibraryChangesOutcome::Inactive(status));
            }
            Some(AccountStatus::Active) => {}
            Some(_) => unreachable!("all inactive statuses matched the guard"),
        }

        let sync_revision = committed_revision_in(&mut transaction, user_id).await?;
        if after_revision < 0 || after_revision > sync_revision {
            return Ok(LibraryChangesOutcome::InvalidAfterRevision);
        }
        let purged_through_revision: i64 = sqlx::query_scalar(
            r"
            SELECT COALESCE(
                (
                    SELECT purged_through_revision
                    FROM library_sync_metadata
                    WHERE user_id = $1
                ),
                0
            )
            ",
        )
        .bind(user_id.into_inner())
        .fetch_one(&mut *transaction)
        .await?;
        if after_revision < purged_through_revision {
            return Ok(LibraryChangesOutcome::ResetRequired {
                purged_through_revision,
                sync_revision,
            });
        }

        let mut rows = sqlx::query_as::<_, LibraryPaperRow>(
            r"
            SELECT
                library.paper_id,
                library.state,
                library.saved_at,
                library.updated_at AS library_updated_at,
                library.removed_at,
                library.revision,
                library.last_operation_id,
                paper.arxiv_base_id,
                paper.arxiv_version,
                paper.title,
                paper.abstract AS abstract_text,
                paper.authors,
                paper.primary_category,
                paper.categories,
                paper.published_at,
                paper.updated_at AS paper_updated_at,
                paper.abs_url,
                paper.pdf_url,
                processing.metadata_ready,
                processing.introduction_ready,
                processing.chat_ready,
                processing.connections_ready
            FROM user_paper_library AS library
            JOIN papers AS paper ON paper.id = library.paper_id
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE library.user_id = $1
              AND library.revision > $2
              AND library.revision <= $3
            ORDER BY library.revision ASC, library.paper_id ASC
            LIMIT $4
            ",
        )
        .bind(user_id.into_inner())
        .bind(after_revision)
        .bind(sync_revision)
        .bind(i64::from(limit) + 1)
        .fetch_all(&mut *transaction)
        .await?;
        let has_more = rows.len() > limit as usize;
        if has_more {
            rows.pop();
        }
        let items = rows
            .into_iter()
            .map(LibraryChange::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        let next_after_revision = if has_more {
            items
                .last()
                .map_or(after_revision, |change| change.item.revision)
        } else {
            sync_revision
        };

        transaction.commit().await?;

        Ok(LibraryChangesOutcome::Found(StoredLibraryChangesPage {
            items,
            next_after_revision,
            has_more,
            sync_revision,
            purged_through_revision,
        }))
    }

    /// Deletes old tombstones in a bounded skip-locked batch and advances each
    /// affected user's reset floor in the same transaction. The operation
    /// ledger deliberately remains available for duplicate replay handling.
    pub async fn cleanup_tombstones(
        &self,
        retention: std::time::Duration,
        batch_size: u32,
    ) -> Result<u64, DbError> {
        if batch_size == 0 {
            return Ok(0);
        }
        let retention_seconds = retention.as_secs_f64();
        if !retention_seconds.is_finite() || retention_seconds < 1.0 {
            return Err(DbError::InvalidData(
                "library tombstone retention must be at least one second".to_owned(),
            ));
        }

        let mut transaction = self.pool.begin().await?;
        let locked_users =
            lock_tombstone_cleanup_users(&mut transaction, retention_seconds, batch_size).await?;
        if locked_users.is_empty() {
            transaction.commit().await?;
            return Ok(0);
        }

        let (removed_count, advanced_users): (i64, i64) = sqlx::query_as(
            r"
            WITH candidates AS (
                SELECT user_id, paper_id
                FROM user_paper_library
                WHERE user_id = ANY($3)
                  AND removed_at IS NOT NULL
                  AND removed_at <= statement_timestamp()
                        - make_interval(secs => $1::double precision)
                ORDER BY removed_at, user_id, revision
                FOR UPDATE SKIP LOCKED
                LIMIT $2
            ), removed AS (
                DELETE FROM user_paper_library AS library
                USING candidates
                WHERE library.user_id = candidates.user_id
                  AND library.paper_id = candidates.paper_id
                RETURNING library.user_id, library.revision
            ), floors AS (
                SELECT user_id, max(revision) AS revision
                FROM removed
                GROUP BY user_id
            ), advanced AS (
                UPDATE library_sync_metadata AS metadata
                SET current_revision = GREATEST(
                        metadata.current_revision,
                        floors.revision
                    ),
                    purged_through_revision = GREATEST(
                        metadata.purged_through_revision,
                        floors.revision
                    ),
                    updated_at = statement_timestamp()
                FROM floors
                WHERE metadata.user_id = floors.user_id
                RETURNING metadata.user_id
            )
            SELECT
                (SELECT count(*) FROM removed)::bigint,
                (SELECT count(*) FROM advanced)::bigint
            ",
        )
        .bind(retention_seconds)
        .bind(i64::from(batch_size))
        .bind(&locked_users)
        .fetch_one(&mut *transaction)
        .await?;
        if removed_count < 0 || advanced_users < 0 || advanced_users > removed_count {
            return Err(DbError::InvalidData(
                "library tombstone cleanup returned inconsistent counts".to_owned(),
            ));
        }
        let removed_count = u64::try_from(removed_count).map_err(|_| {
            DbError::InvalidData("library tombstone cleanup count overflowed".to_owned())
        })?;
        transaction.commit().await?;
        Ok(removed_count)
    }
}

fn library_cursor_scope(user_id: AuthenticatedUserId, state: LibraryState) -> Vec<u8> {
    let mut scope = Vec::with_capacity(16 + state.as_str().len());
    scope.extend_from_slice(user_id.into_inner().as_bytes());
    scope.extend_from_slice(state.as_str().as_bytes());
    scope
}

/// Discovers only enough accounts to cover one cleanup batch, then locks their
/// revision fences before the caller touches canonical library rows. Mutation
/// uses the same metadata-before-library order. Sorting UUIDs prevents two
/// cleanup workers from forming a multi-account lock cycle.
async fn lock_tombstone_cleanup_users(
    transaction: &mut Transaction<'_, Postgres>,
    retention_seconds: f64,
    batch_size: u32,
) -> Result<Vec<Uuid>, DbError> {
    let candidate_users = sqlx::query_scalar::<_, Uuid>(
        r"
        SELECT DISTINCT candidate.user_id
        FROM (
            SELECT user_id
            FROM user_paper_library
            WHERE removed_at IS NOT NULL
              AND removed_at <= statement_timestamp()
                    - make_interval(secs => $1::double precision)
            ORDER BY removed_at, user_id, revision
            LIMIT $2
        ) AS candidate
        ORDER BY candidate.user_id
        ",
    )
    .bind(retention_seconds)
    .bind(i64::from(batch_size))
    .fetch_all(&mut **transaction)
    .await?;
    if candidate_users.is_empty() {
        return Ok(Vec::new());
    }

    // The delete query rechecks tombstone eligibility after these fences are
    // held. Accounts deleted concurrently after discovery are simply omitted.
    sqlx::query_scalar::<_, Uuid>(
        r"
        SELECT user_id
        FROM library_sync_metadata
        WHERE user_id = ANY($1)
        ORDER BY user_id
        FOR UPDATE
        ",
    )
    .bind(&candidate_users)
    .fetch_all(&mut **transaction)
    .await
    .map_err(DbError::from)
}

/// A list page or incremental page derives several values (authorization,
/// revision fence, purge floor, and rows). They must all come from one MVCC
/// snapshot: otherwise cleanup could remove a tombstone after the floor read
/// but before the row read and let a client advance past the removal.
async fn begin_consistent_read(pool: &PgPool) -> Result<Transaction<'_, Postgres>, DbError> {
    let mut transaction = pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *transaction)
        .await?;
    Ok(transaction)
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
    namespace: &str,
    user_id: AuthenticatedUserId,
    target_id: Uuid,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        SELECT pg_advisory_xact_lock(
            hashtextextended($1 || ':' || $2::text || ':' || $3::text, 0)
        )
        ",
    )
    .bind(namespace)
    .bind(user_id.into_inner())
    .bind(target_id)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn allocate_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, DbError> {
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (
            user_id,
            current_revision,
            purged_through_revision,
            updated_at
        )
        VALUES ($1, 0, 0, statement_timestamp())
        ON CONFLICT (user_id) DO NOTHING
        ",
    )
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await?;

    let revision: i64 = sqlx::query_scalar(
        r"
        UPDATE library_sync_metadata
        SET current_revision = current_revision + 1,
            updated_at = statement_timestamp()
        WHERE user_id = $1
        RETURNING current_revision
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    if revision <= 0 {
        return Err(DbError::InvalidData(
            "per-user library revision returned a non-positive value".to_owned(),
        ));
    }
    Ok(revision)
}

async fn committed_revision_in(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, DbError> {
    let revision: i64 = sqlx::query_scalar(
        r"
        SELECT COALESCE(
            (
                SELECT current_revision
                FROM library_sync_metadata
                WHERE user_id = $1
            ),
            0
        )
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    if revision < 0 {
        return Err(DbError::InvalidData(
            "per-user library watermark returned a negative value".to_owned(),
        ));
    }
    Ok(revision)
}

async fn load_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
) -> Result<Option<OperationRow>, DbError> {
    sqlx::query_as::<_, OperationRow>(
        r"
        SELECT
            paper_id,
            intent,
            state,
            intent_fingerprint = digest(
                paper_id::text || ':' || intent || ':' || state,
                'sha256'
            ) AS fingerprint_valid
        FROM library_operations
        WHERE user_id = $1 AND operation_id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn load_current_or_compacted_item(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
) -> Result<Option<LibraryItem>, DbError> {
    if let Some(row) = sqlx::query_as::<_, LibraryItemRow>(
        r"
        SELECT
            paper_id,
            state,
            saved_at,
            updated_at,
            removed_at,
            revision,
            last_operation_id
        FROM user_paper_library
        WHERE user_id = $1 AND paper_id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?
    {
        return Ok(Some(LibraryItem::try_from(row)?));
    }

    sqlx::query_as::<_, OperationSnapshotRow>(
        r"
        SELECT
            paper_id,
            state,
            accepted_saved_at AS saved_at,
            accepted_updated_at AS updated_at,
            accepted_removed_at AS removed_at,
            accepted_revision AS revision,
            operation_id AS last_operation_id
        FROM library_operations
        WHERE user_id = $1 AND paper_id = $2
        ORDER BY accepted_revision DESC
        LIMIT 1
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?
    .map(LibraryItem::try_from)
    .transpose()
}

async fn save_item(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
    operation_id: Uuid,
    state: LibraryState,
    revision: i64,
) -> Result<LibraryItem, DbError> {
    let row = sqlx::query_as::<_, LibraryItemRow>(
        r"
        INSERT INTO user_paper_library (
            user_id,
            paper_id,
            state,
            saved_at,
            updated_at,
            removed_at,
            revision,
            last_operation_id
        )
        VALUES (
            $1,
            $2,
            $3,
            statement_timestamp(),
            statement_timestamp(),
            NULL,
            $4,
            $5
        )
        ON CONFLICT (user_id, paper_id) DO UPDATE
        SET state = EXCLUDED.state,
            saved_at = CASE
                WHEN user_paper_library.removed_at IS NULL
                    THEN user_paper_library.saved_at
                ELSE EXCLUDED.saved_at
            END,
            updated_at = EXCLUDED.updated_at,
            removed_at = NULL,
            revision = EXCLUDED.revision,
            last_operation_id = EXCLUDED.last_operation_id
        RETURNING
            paper_id,
            state,
            saved_at,
            updated_at,
            removed_at,
            revision,
            last_operation_id
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .bind(state.as_str())
    .bind(revision)
    .bind(operation_id)
    .fetch_one(&mut **transaction)
    .await?;
    LibraryItem::try_from(row)
}

async fn remove_item(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
    operation_id: Uuid,
    state: LibraryState,
    revision: i64,
) -> Result<LibraryItem, DbError> {
    let row = sqlx::query_as::<_, LibraryItemRow>(
        r"
        INSERT INTO user_paper_library (
            user_id,
            paper_id,
            state,
            saved_at,
            updated_at,
            removed_at,
            revision,
            last_operation_id
        )
        VALUES (
            $1,
            $2,
            $3,
            statement_timestamp(),
            statement_timestamp(),
            statement_timestamp(),
            $4,
            $5
        )
        ON CONFLICT (user_id, paper_id) DO UPDATE
        SET state = EXCLUDED.state,
            saved_at = user_paper_library.saved_at,
            updated_at = EXCLUDED.updated_at,
            removed_at = EXCLUDED.removed_at,
            revision = EXCLUDED.revision,
            last_operation_id = EXCLUDED.last_operation_id
        RETURNING
            paper_id,
            state,
            saved_at,
            updated_at,
            removed_at,
            revision,
            last_operation_id
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .bind(state.as_str())
    .bind(revision)
    .bind(operation_id)
    .fetch_one(&mut **transaction)
    .await?;
    LibraryItem::try_from(row)
}

async fn insert_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    paper_id: PaperId,
    intent: LibraryMutationIntent,
    item: &LibraryItem,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO library_operations (
            user_id,
            operation_id,
            paper_id,
            intent,
            state,
            intent_fingerprint,
            accepted_revision,
            accepted_saved_at,
            accepted_updated_at,
            accepted_removed_at
        )
        VALUES (
            $1,
            $2,
            $3,
            $4,
            $5,
            digest($3::text || ':' || $4 || ':' || $5, 'sha256'),
            $6,
            $7,
            $8,
            $9
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(paper_id)
    .bind(intent.as_str())
    .bind(item.state.as_str())
    .bind(item.revision)
    .bind(item.saved_at)
    .bind(item.updated_at)
    .bind(item.removed_at)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

#[derive(Debug, FromRow)]
struct LibraryItemRow {
    paper_id: Uuid,
    state: String,
    saved_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    removed_at: Option<DateTime<Utc>>,
    revision: i64,
    last_operation_id: Uuid,
}

impl TryFrom<LibraryItemRow> for LibraryItem {
    type Error = DbError;

    fn try_from(row: LibraryItemRow) -> Result<Self, Self::Error> {
        library_item(
            row.paper_id,
            &row.state,
            row.saved_at,
            row.updated_at,
            row.removed_at,
            row.revision,
            row.last_operation_id,
        )
    }
}

#[derive(Debug, FromRow)]
struct OperationSnapshotRow {
    paper_id: Uuid,
    state: String,
    saved_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    removed_at: Option<DateTime<Utc>>,
    revision: i64,
    last_operation_id: Uuid,
}

impl TryFrom<OperationSnapshotRow> for LibraryItem {
    type Error = DbError;

    fn try_from(row: OperationSnapshotRow) -> Result<Self, Self::Error> {
        library_item(
            row.paper_id,
            &row.state,
            row.saved_at,
            row.updated_at,
            row.removed_at,
            row.revision,
            row.last_operation_id,
        )
    }
}

fn library_item(
    paper_id: Uuid,
    state: &str,
    saved_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    removed_at: Option<DateTime<Utc>>,
    revision: i64,
    last_operation_id: Uuid,
) -> Result<LibraryItem, DbError> {
    if revision <= 0 {
        return Err(DbError::InvalidData(
            "persisted library revision must be positive".to_owned(),
        ));
    }
    if updated_at < saved_at || removed_at.is_some_and(|removed_at| removed_at != updated_at) {
        return Err(DbError::InvalidData(
            "persisted library timestamps are inconsistent".to_owned(),
        ));
    }
    Ok(LibraryItem {
        paper_id,
        state: LibraryState::from_str(state)
            .map_err(|error| DbError::InvalidData(error.to_string()))?,
        saved_at,
        updated_at,
        removed_at,
        revision,
        last_operation_id,
    })
}

#[derive(Debug, FromRow)]
struct OperationRow {
    paper_id: Uuid,
    intent: String,
    state: String,
    fingerprint_valid: bool,
}

#[derive(Debug, FromRow)]
#[allow(clippy::struct_excessive_bools)]
struct LibraryPaperRow {
    paper_id: Uuid,
    state: String,
    saved_at: DateTime<Utc>,
    library_updated_at: DateTime<Utc>,
    removed_at: Option<DateTime<Utc>>,
    revision: i64,
    last_operation_id: Uuid,
    arxiv_base_id: String,
    arxiv_version: i32,
    title: String,
    abstract_text: String,
    authors: Value,
    primary_category: String,
    categories: Vec<String>,
    published_at: DateTime<Utc>,
    paper_updated_at: DateTime<Utc>,
    abs_url: String,
    pdf_url: String,
    metadata_ready: bool,
    introduction_ready: bool,
    chat_ready: bool,
    connections_ready: bool,
}

impl TryFrom<LibraryPaperRow> for SavedLibraryPaper {
    type Error = DbError;

    fn try_from(row: LibraryPaperRow) -> Result<Self, Self::Error> {
        let item = library_item(
            row.paper_id,
            &row.state,
            row.saved_at,
            row.library_updated_at,
            row.removed_at,
            row.revision,
            row.last_operation_id,
        )?;
        let paper = PaperSummary::try_from(PaperSummaryRow {
            id: row.paper_id,
            arxiv_base_id: row.arxiv_base_id,
            arxiv_version: row.arxiv_version,
            title: row.title,
            abstract_text: row.abstract_text,
            authors: row.authors,
            primary_category: row.primary_category,
            categories: row.categories,
            published_at: row.published_at,
            updated_at: row.paper_updated_at,
            abs_url: row.abs_url,
            pdf_url: row.pdf_url,
            metadata_ready: row.metadata_ready,
            introduction_ready: row.introduction_ready,
            chat_ready: row.chat_ready,
            connections_ready: row.connections_ready,
        })?;
        Ok(Self { item, paper })
    }
}

impl TryFrom<LibraryPaperRow> for LibraryChange {
    type Error = DbError;

    fn try_from(row: LibraryPaperRow) -> Result<Self, Self::Error> {
        let saved = SavedLibraryPaper::try_from(row)?;
        Ok(Self {
            item: saved.item,
            paper: Some(saved.paper),
        })
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone as _;

    use super::*;

    #[test]
    fn row_validation_rejects_invalid_revision_and_timestamp_order() {
        let now = Utc.with_ymd_and_hms(2026, 7, 31, 12, 0, 0).unwrap();
        assert!(library_item(Uuid::nil(), "to_read", now, now, None, 0, Uuid::now_v7(),).is_err());
        assert!(
            library_item(
                Uuid::nil(),
                "to_read",
                now,
                now,
                Some(now + chrono::TimeDelta::seconds(1)),
                1,
                Uuid::now_v7(),
            )
            .is_err()
        );
    }
}
