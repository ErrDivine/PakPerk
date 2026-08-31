use std::str::FromStr;

use chrono::{DateTime, Utc};
use domain::{
    AccountStatus, AuthenticatedUserId, LibraryChange, LibraryItem, LibrarySaveSourceKind,
    LibraryState, PaperId, PaperSummary, SavedLibraryPaper,
};
use opaque_cursor::OpaqueCursorCodec;
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, QueryBuilder, Transaction};
use uuid::Uuid;

use super::{DbError, rows::PaperSummaryRow};
use crate::LibraryCursor;

/// Expand-window storage spelling. Public v2 values remain the closed
/// `LibraryState` wire enum; only the database boundary knows `to_read`.
pub(super) const fn library_state_storage_str(state: LibraryState) -> &'static str {
    match state {
        LibraryState::Inbox => "to_read",
        _ => state.as_str(),
    }
}

pub(super) fn library_state_from_storage(
    value: &str,
) -> Result<LibraryState, domain::LibraryStateParseError> {
    if value == "to_read" {
        Ok(LibraryState::Inbox)
    } else {
        LibraryState::from_str(value)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryMutationIntent {
    Save,
    Remove,
}

/// Complete mutation intent used for durable item idempotency. Legacy v0.0
/// saves preserve v2-only metadata; v2 writes replace it explicitly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryItemMutation {
    pub state: LibraryState,
    pub private_note: Option<String>,
    pub save_source_kind: Option<LibrarySaveSourceKind>,
    /// `None` preserves the canonical reminder, `Some(None)` clears it, and
    /// `Some(Some(_))` replaces it with the selected UTC instant.
    pub reminder_at: Option<Option<DateTime<Utc>>>,
    pub preserve_v2_metadata: bool,
}

impl LibraryItemMutation {
    #[must_use]
    pub const fn legacy(state: LibraryState) -> Self {
        Self {
            state,
            private_note: None,
            save_source_kind: None,
            reminder_at: None,
            preserve_v2_metadata: true,
        }
    }

    #[must_use]
    pub const fn replace(
        state: LibraryState,
        private_note: Option<String>,
        save_source_kind: Option<LibrarySaveSourceKind>,
    ) -> Self {
        Self::replace_with_reminder(state, private_note, save_source_kind, None)
    }

    #[must_use]
    pub const fn replace_with_reminder(
        state: LibraryState,
        private_note: Option<String>,
        save_source_kind: Option<LibrarySaveSourceKind>,
        reminder_at: Option<Option<DateTime<Utc>>>,
    ) -> Self {
        Self {
            state,
            private_note,
            save_source_kind,
            reminder_at,
            preserve_v2_metadata: false,
        }
    }

    const fn is_v0_compatible(&self) -> bool {
        self.preserve_v2_metadata
            && self.private_note.is_none()
            && self.save_source_kind.is_none()
            && self.reminder_at.is_none()
    }
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

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LibraryItemFilter {
    pub state: Option<LibraryState>,
    pub list_id: Option<Uuid>,
    pub tag_id: Option<Uuid>,
    pub active_only: bool,
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
        self.resolve_item_operation(
            user_id,
            paper_id,
            operation_id,
            intent,
            &LibraryItemMutation::legacy(state),
        )
        .await
    }

    pub async fn resolve_item_operation(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        mutation: &LibraryItemMutation,
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

        let Some(operation) = load_operation(
            &mut transaction,
            user_id,
            operation_id,
            paper_id,
            intent,
            mutation,
        )
        .await?
        else {
            transaction.commit().await?;
            return Ok(LibraryOperationResolution::Unknown);
        };
        if operation.paper_id != paper_id
            || operation.intent != intent.as_str()
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
        self.mutate_item(
            user_id,
            paper_id,
            operation_id,
            intent,
            LibraryItemMutation::legacy(state),
        )
        .await
    }

    #[allow(clippy::too_many_lines)]
    pub async fn mutate_item(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        mutation: LibraryItemMutation,
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

        if let Some(operation) = load_operation(
            &mut transaction,
            user_id,
            operation_id,
            paper_id,
            intent,
            &mutation,
        )
        .await?
        {
            if operation.paper_id != paper_id
                || operation.intent != intent.as_str()
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
                    &mutation,
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
                    mutation.state,
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
            &mutation,
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
        self.list_items(
            user_id,
            LibraryItemFilter {
                state: Some(state),
                ..LibraryItemFilter::default()
            },
            cursor,
            limit,
        )
        .await
    }

    pub async fn list_active(
        &self,
        user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        self.list_items(
            user_id,
            LibraryItemFilter {
                active_only: true,
                ..LibraryItemFilter::default()
            },
            cursor,
            limit,
        )
        .await
    }

    #[allow(clippy::too_many_lines)]
    pub async fn list_items(
        &self,
        user_id: AuthenticatedUserId,
        filter: LibraryItemFilter,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        if filter.active_only && filter.state.is_some_and(|state| !state.is_active()) {
            return Ok(LibraryReadOutcome::InvalidCursor);
        }
        let cursor_scope = library_cursor_scope(user_id, filter);
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
                library.private_note,
                library.save_source_kind,
                library.reminder_at,
                library.saved_at,
                library.updated_at AS library_updated_at,
                library.reviewed_at,
                library.archived_at,
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
                processing.connections_ready,
                processing.visual_objects_ready,
                processing.terms_ready,
                processing.semantic_facets_ready,
                processing.paper_passport_ready
            FROM user_paper_library AS library
            JOIN papers AS paper ON paper.id = library.paper_id
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE library.user_id =
            ",
        );
        builder.push_bind(user_id.into_inner());
        if let Some(state) = filter.state {
            if state == LibraryState::Inbox {
                builder.push(" AND library.state IN ('to_read', 'inbox')");
            } else {
                builder.push(" AND library.state = ");
                builder.push_bind(library_state_storage_str(state));
            }
        }
        if filter.active_only {
            builder.push(" AND library.state IN ('to_read', 'inbox', 'read_next', 'reading')");
        }
        if let Some(list_id) = filter.list_id {
            builder.push(
                " AND EXISTS (SELECT 1 FROM library_list_items AS list_item \
                 JOIN library_lists AS list ON list.user_id = list_item.user_id \
                 AND list.id = list_item.list_id AND list.deleted_at IS NULL \
                 WHERE list_item.user_id = library.user_id \
                 AND list_item.paper_id = library.paper_id \
                 AND list_item.list_id = ",
            );
            builder.push_bind(list_id);
            builder.push(" AND list_item.deleted_at IS NULL)");
        }
        if let Some(tag_id) = filter.tag_id {
            builder.push(
                " AND EXISTS (SELECT 1 FROM library_item_tags AS item_tag \
                 JOIN library_tags AS tag ON tag.user_id = item_tag.user_id \
                 AND tag.id = item_tag.tag_id AND tag.deleted_at IS NULL \
                 WHERE item_tag.user_id = library.user_id \
                 AND item_tag.paper_id = library.paper_id \
                 AND item_tag.tag_id = ",
            );
            builder.push_bind(tag_id);
            builder.push(" AND item_tag.deleted_at IS NULL)");
        }
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

    #[allow(clippy::too_many_lines)]
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
                library.private_note,
                library.save_source_kind,
                library.reminder_at,
                library.saved_at,
                library.updated_at AS library_updated_at,
                library.reviewed_at,
                library.archived_at,
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
                processing.connections_ready,
                processing.visual_objects_ready,
                processing.terms_ready,
                processing.semantic_facets_ready,
                processing.paper_passport_ready
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

fn library_cursor_scope(user_id: AuthenticatedUserId, filter: LibraryItemFilter) -> Vec<u8> {
    let mut scope = Vec::with_capacity(128);
    scope.extend_from_slice(user_id.into_inner().as_bytes());
    scope.extend_from_slice(b"library-items-v2\0");
    scope.extend_from_slice(filter.state.map_or("*", LibraryState::as_str).as_bytes());
    scope.push(u8::from(filter.active_only));
    if let Some(list_id) = filter.list_id {
        scope.extend_from_slice(list_id.as_bytes());
    }
    scope.push(0);
    if let Some(tag_id) = filter.tag_id {
        scope.extend_from_slice(tag_id.as_bytes());
    }
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
pub(super) async fn begin_consistent_read(
    pool: &PgPool,
) -> Result<Transaction<'_, Postgres>, DbError> {
    let mut transaction = pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *transaction)
        .await?;
    Ok(transaction)
}

pub(super) async fn lock_account_status(
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

pub(super) async fn advisory_lock(
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

pub(super) async fn allocate_revision(
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

    // A recommendation batch is authoritative only for the exact library
    // revision that proved the active queue empty. Invalidate any in-flight or
    // ready batch in the same transaction that advances library authority.
    sqlx::query(
        r"
        UPDATE recommendation_batches
        SET status = 'superseded'
        WHERE user_id = $1
          AND status IN ('building', 'ready')
          AND library_revision IS DISTINCT FROM $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(revision)
    .execute(&mut **transaction)
    .await?;

    // Phase G account-private surfaces consume the same revision fence. A
    // library mutation invalidates the current brief and makes discovery
    // delivery unknown before the transaction can commit. The separate work
    // queue later reuses reading-feed authority to re-evaluate eligibility.
    sqlx::query(
        r"
        UPDATE reading_briefs
        SET status = 'superseded', updated_at = statement_timestamp()
        WHERE user_id = $1 AND status = 'current'
          AND library_revision IS DISTINCT FROM $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(revision)
    .execute(&mut **transaction)
    .await?;
    sqlx::query(
        r"
        UPDATE notifications
        SET delivery_eligibility = 'deferred_unknown',
            eligibility_library_revision = NULL
        WHERE user_id = $1 AND notification_scope = 'discovery'
          AND delivery_eligibility <> 'expired'
          AND dismissed_at IS NULL
        ",
    )
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await?;
    sqlx::query(
        r"
        INSERT INTO notification_work_items (
            id, user_id, work_kind, subscription_id, window_key,
            payload, state, available_at
        ) VALUES (
            gen_random_uuid(), $1, 'recheck_notification_queue_eligibility',
            NULL, 'revision-' || $2::text, '{}'::jsonb, 'queued', statement_timestamp()
        )
        ON CONFLICT (
            user_id,
            work_kind,
            COALESCE(subscription_id, '00000000-0000-0000-0000-000000000000'::uuid),
            window_key
        ) DO NOTHING
        ",
    )
    .bind(user_id.into_inner())
    .bind(revision)
    .execute(&mut **transaction)
    .await?;
    Ok(revision)
}

pub(super) async fn committed_revision_in(
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
    paper_id: PaperId,
    intent: LibraryMutationIntent,
    mutation: &LibraryItemMutation,
) -> Result<Option<OperationRow>, DbError> {
    sqlx::query_as::<_, OperationRow>(
        r"
        SELECT
            paper_id,
            intent,
            (
                CASE WHEN $6 = 'inbox'
                    THEN state IN ('to_read', 'inbox')
                    ELSE state = $5
                END
                AND CASE
                    WHEN v2_intent_fingerprint IS NOT NULL THEN
                        v2_intent_fingerprint = digest(
                            jsonb_build_array(
                                $3::uuid::text, $4, $6, $7, $8, $9,
                                $10::timestamptz, $11
                            )::text,
                            'sha256'
                        )
                    ELSE
                        $12
                        AND intent_fingerprint = digest(
                            paper_id::text || ':' || intent || ':' || state,
                            'sha256'
                        )
                END
            ) AS fingerprint_valid
        FROM library_operations
        WHERE user_id = $1 AND operation_id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(paper_id)
    .bind(intent.as_str())
    .bind(library_state_storage_str(mutation.state))
    .bind(mutation.state.as_str())
    .bind(mutation.private_note.as_deref())
    .bind(mutation.save_source_kind.map(LibrarySaveSourceKind::as_str))
    .bind(if mutation.preserve_v2_metadata {
        "preserve"
    } else {
        "replace"
    })
    .bind(mutation.reminder_at.as_ref().copied().flatten())
    .bind(if mutation.reminder_at.is_none() {
        "preserve"
    } else {
        "replace"
    })
    .bind(mutation.is_v0_compatible())
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
            private_note,
            save_source_kind,
            reminder_at,
            saved_at,
            updated_at,
            reviewed_at,
            archived_at,
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
            accepted_private_note AS private_note,
            accepted_save_source_kind AS save_source_kind,
            accepted_reminder_at AS reminder_at,
            accepted_saved_at AS saved_at,
            accepted_updated_at AS updated_at,
            accepted_reviewed_at AS reviewed_at,
            accepted_archived_at AS archived_at,
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
    mutation: &LibraryItemMutation,
    revision: i64,
) -> Result<LibraryItem, DbError> {
    let row = sqlx::query_as::<_, LibraryItemRow>(
        r"
        INSERT INTO user_paper_library (
            user_id,
            paper_id,
            state,
            private_note,
            save_source_kind,
            reminder_at,
            saved_at,
            updated_at,
            reviewed_at,
            archived_at,
            removed_at,
            revision,
            last_operation_id
        )
        VALUES (
            $1,
            $2,
            $3,
            $4,
            $5,
            CASE WHEN $3 IN ('to_read', 'inbox', 'read_next', 'reading') THEN $6 END,
            statement_timestamp(),
            statement_timestamp(),
            CASE WHEN $3 = 'reviewed' THEN statement_timestamp() END,
            CASE WHEN $3 = 'archived' THEN statement_timestamp() END,
            NULL,
            $7,
            $8
        )
        ON CONFLICT (user_id, paper_id) DO UPDATE
        SET state = EXCLUDED.state,
            private_note = CASE
                WHEN $9 THEN user_paper_library.private_note
                ELSE EXCLUDED.private_note
            END,
            save_source_kind = CASE
                WHEN $9 THEN user_paper_library.save_source_kind
                ELSE EXCLUDED.save_source_kind
            END,
            reminder_at = CASE
                WHEN EXCLUDED.state NOT IN ('to_read', 'inbox', 'read_next', 'reading') THEN NULL
                WHEN $10 THEN user_paper_library.reminder_at
                ELSE EXCLUDED.reminder_at
            END,
            saved_at = CASE
                WHEN user_paper_library.removed_at IS NULL
                    THEN user_paper_library.saved_at
                ELSE EXCLUDED.saved_at
            END,
            updated_at = EXCLUDED.updated_at,
            reviewed_at = EXCLUDED.reviewed_at,
            archived_at = EXCLUDED.archived_at,
            removed_at = NULL,
            revision = EXCLUDED.revision,
            last_operation_id = EXCLUDED.last_operation_id
        RETURNING
            paper_id,
            state,
            private_note,
            save_source_kind,
            reminder_at,
            saved_at,
            updated_at,
            reviewed_at,
            archived_at,
            removed_at,
            revision,
            last_operation_id
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .bind(library_state_storage_str(mutation.state))
    .bind(mutation.private_note.as_deref())
    .bind(mutation.save_source_kind.map(LibrarySaveSourceKind::as_str))
    .bind(mutation.reminder_at.as_ref().copied().flatten())
    .bind(revision)
    .bind(operation_id)
    .bind(mutation.preserve_v2_metadata)
    .bind(mutation.reminder_at.is_none())
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
            private_note,
            save_source_kind,
            reminder_at,
            saved_at,
            updated_at,
            reviewed_at,
            archived_at,
            removed_at,
            revision,
            last_operation_id
        )
        VALUES (
            $1,
            $2,
            $3,
            NULL,
            NULL,
            NULL,
            statement_timestamp(),
            statement_timestamp(),
            NULL,
            NULL,
            statement_timestamp(),
            $4,
            $5
        )
        ON CONFLICT (user_id, paper_id) DO UPDATE
        SET state = EXCLUDED.state,
            private_note = NULL,
            save_source_kind = NULL,
            reminder_at = NULL,
            saved_at = user_paper_library.saved_at,
            updated_at = EXCLUDED.updated_at,
            reviewed_at = NULL,
            archived_at = NULL,
            removed_at = EXCLUDED.removed_at,
            revision = EXCLUDED.revision,
            last_operation_id = EXCLUDED.last_operation_id
        RETURNING
            paper_id,
            state,
            private_note,
            save_source_kind,
            reminder_at,
            saved_at,
            updated_at,
            reviewed_at,
            archived_at,
            removed_at,
            revision,
            last_operation_id
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .bind(library_state_storage_str(state))
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
    mutation: &LibraryItemMutation,
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
            v2_intent_fingerprint,
            accepted_private_note,
            accepted_save_source_kind,
            accepted_reminder_at,
            accepted_revision,
            accepted_saved_at,
            accepted_updated_at,
            accepted_reviewed_at,
            accepted_archived_at,
            accepted_removed_at
        )
        VALUES (
            $1,
            $2,
            $3,
            $4,
            $5,
            digest($3::text || ':' || $4 || ':' || $5, 'sha256'),
            digest(
                jsonb_build_array(
                    $3::uuid::text, $4, $6, $7, $8, $9, $10::timestamptz, $11
                )::text,
                'sha256'
            ),
            $12,
            $13,
            $14,
            $15,
            $16,
            $17,
            $18,
            $19,
            $20
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(paper_id)
    .bind(intent.as_str())
    .bind(library_state_storage_str(item.state))
    .bind(mutation.state.as_str())
    .bind(mutation.private_note.as_deref())
    .bind(mutation.save_source_kind.map(LibrarySaveSourceKind::as_str))
    .bind(if mutation.preserve_v2_metadata {
        "preserve"
    } else {
        "replace"
    })
    .bind(mutation.reminder_at.as_ref().copied().flatten())
    .bind(if mutation.reminder_at.is_none() {
        "preserve"
    } else {
        "replace"
    })
    .bind(item.private_note.as_deref())
    .bind(item.save_source_kind.map(LibrarySaveSourceKind::as_str))
    .bind(item.reminder_at)
    .bind(item.revision)
    .bind(item.saved_at)
    .bind(item.updated_at)
    .bind(item.reviewed_at)
    .bind(item.archived_at)
    .bind(item.removed_at)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

#[derive(Debug, FromRow)]
struct LibraryItemRow {
    paper_id: Uuid,
    state: String,
    private_note: Option<String>,
    save_source_kind: Option<String>,
    reminder_at: Option<DateTime<Utc>>,
    saved_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    reviewed_at: Option<DateTime<Utc>>,
    archived_at: Option<DateTime<Utc>>,
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
            row.private_note,
            row.save_source_kind.as_deref(),
            row.reminder_at,
            row.saved_at,
            row.updated_at,
            row.reviewed_at,
            row.archived_at,
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
    private_note: Option<String>,
    save_source_kind: Option<String>,
    reminder_at: Option<DateTime<Utc>>,
    saved_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    reviewed_at: Option<DateTime<Utc>>,
    archived_at: Option<DateTime<Utc>>,
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
            row.private_note,
            row.save_source_kind.as_deref(),
            row.reminder_at,
            row.saved_at,
            row.updated_at,
            row.reviewed_at,
            row.archived_at,
            row.removed_at,
            row.revision,
            row.last_operation_id,
        )
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn library_item(
    paper_id: Uuid,
    state: &str,
    private_note: Option<String>,
    save_source_kind: Option<&str>,
    reminder_at: Option<DateTime<Utc>>,
    saved_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    reviewed_at: Option<DateTime<Utc>>,
    archived_at: Option<DateTime<Utc>>,
    removed_at: Option<DateTime<Utc>>,
    revision: i64,
    last_operation_id: Uuid,
) -> Result<LibraryItem, DbError> {
    if revision <= 0 {
        return Err(DbError::InvalidData(
            "persisted library revision must be positive".to_owned(),
        ));
    }
    if updated_at < saved_at
        || removed_at.is_some_and(|removed_at| removed_at != updated_at)
        || reviewed_at.is_some_and(|reviewed_at| !(saved_at..=updated_at).contains(&reviewed_at))
        || archived_at.is_some_and(|archived_at| !(saved_at..=updated_at).contains(&archived_at))
    {
        return Err(DbError::InvalidData(
            "persisted library timestamps are inconsistent".to_owned(),
        ));
    }
    let state = library_state_from_storage(state)
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
    if (state == LibraryState::Reviewed) != reviewed_at.is_some()
        || (state == LibraryState::Archived) != archived_at.is_some()
        || (reminder_at.is_some() && (removed_at.is_some() || !state.is_active()))
    {
        return Err(DbError::InvalidData(
            "persisted library state timestamps are inconsistent".to_owned(),
        ));
    }
    Ok(LibraryItem {
        paper_id,
        state,
        private_note,
        save_source_kind: save_source_kind
            .map(LibrarySaveSourceKind::from_str)
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))?,
        reminder_at,
        saved_at,
        updated_at,
        reviewed_at,
        archived_at,
        removed_at,
        revision,
        last_operation_id,
    })
}

#[derive(Debug, FromRow)]
struct OperationRow {
    paper_id: Uuid,
    intent: String,
    fingerprint_valid: bool,
}

#[derive(Debug, FromRow)]
#[allow(clippy::struct_excessive_bools)]
struct LibraryPaperRow {
    paper_id: Uuid,
    state: String,
    private_note: Option<String>,
    save_source_kind: Option<String>,
    reminder_at: Option<DateTime<Utc>>,
    saved_at: DateTime<Utc>,
    library_updated_at: DateTime<Utc>,
    reviewed_at: Option<DateTime<Utc>>,
    archived_at: Option<DateTime<Utc>>,
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
    visual_objects_ready: bool,
    terms_ready: bool,
    semantic_facets_ready: bool,
    paper_passport_ready: bool,
}

impl TryFrom<LibraryPaperRow> for SavedLibraryPaper {
    type Error = DbError;

    fn try_from(row: LibraryPaperRow) -> Result<Self, Self::Error> {
        let item = library_item(
            row.paper_id,
            &row.state,
            row.private_note,
            row.save_source_kind.as_deref(),
            row.reminder_at,
            row.saved_at,
            row.library_updated_at,
            row.reviewed_at,
            row.archived_at,
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
            visual_objects_ready: row.visual_objects_ready,
            terms_ready: row.terms_ready,
            semantic_facets_ready: row.semantic_facets_ready,
            paper_passport_ready: row.paper_passport_ready,
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
    fn expand_storage_alias_is_confined_to_the_database_boundary() {
        assert_eq!(LibraryState::Inbox.as_str(), "inbox");
        assert_eq!(library_state_storage_str(LibraryState::Inbox), "to_read");
        assert_eq!(
            library_state_from_storage("to_read"),
            Ok(LibraryState::Inbox)
        );
        assert_eq!(library_state_from_storage("inbox"), Ok(LibraryState::Inbox));
        assert!(LibraryState::from_str("to_read").is_err());
    }

    #[test]
    fn row_validation_rejects_invalid_revision_and_timestamp_order() {
        let now = Utc.with_ymd_and_hms(2026, 7, 31, 12, 0, 0).unwrap();
        assert!(
            library_item(
                Uuid::nil(),
                "inbox",
                None,
                None,
                None,
                now,
                now,
                None,
                None,
                None,
                0,
                Uuid::now_v7(),
            )
            .is_err()
        );
        assert!(
            library_item(
                Uuid::nil(),
                "inbox",
                None,
                None,
                None,
                now,
                now,
                None,
                None,
                Some(now + chrono::TimeDelta::seconds(1)),
                1,
                Uuid::now_v7(),
            )
            .is_err()
        );
    }

    #[test]
    fn row_validation_rejects_reminders_outside_active_queue_state() {
        let now = Utc.with_ymd_and_hms(2026, 7, 31, 12, 0, 0).unwrap();
        for state in ["reviewed", "archived"] {
            assert!(
                library_item(
                    Uuid::nil(),
                    state,
                    None,
                    None,
                    Some(now + chrono::TimeDelta::hours(1)),
                    now,
                    now,
                    (state == "reviewed").then_some(now),
                    (state == "archived").then_some(now),
                    None,
                    1,
                    Uuid::now_v7(),
                )
                .is_err()
            );
        }
    }

    #[test]
    fn reminder_migration_has_active_only_storage_and_global_due_index() {
        let migration = include_str!("../../../../migrations/0012_library_v2.sql");
        for contract in [
            "ADD COLUMN reminder_at timestamptz",
            "ADD COLUMN accepted_reminder_at timestamptz",
            "CONSTRAINT user_paper_library_reminder_check",
            "CONSTRAINT library_operations_reminder_check",
            "ON user_paper_library (reminder_at, user_id, paper_id)",
            "WHERE reminder_at IS NOT NULL",
        ] {
            assert!(
                migration.contains(contract),
                "missing reminder SQL contract: {contract}"
            );
        }
    }
}
