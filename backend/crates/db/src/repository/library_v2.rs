use chrono::{DateTime, Utc};
use domain::{
    AccountStatus, AuthenticatedUserId, LibraryItemTag, LibraryList, LibraryListItem, LibraryTag,
    LibraryV2Change, PaperId, PaperSummary,
};
use serde::Serialize;
use sqlx::{FromRow, Postgres, Transaction};
use uuid::Uuid;

use super::{
    DbError,
    library::{
        LibraryRepository, allocate_revision, begin_consistent_read, committed_revision_in,
        library_item, lock_account_status,
    },
    rows::PaperSummaryRow,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LibraryListWrite {
    pub id: Uuid,
    pub name: String,
    pub normalized_name: String,
    pub description: Option<String>,
    pub sort_order: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LibraryTagWrite {
    pub id: Uuid,
    pub name: String,
    pub normalized_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LibraryListItemWrite {
    pub list_id: Uuid,
    pub paper_id: PaperId,
    pub position_rank: i64,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct LibraryItemTagWrite {
    pub paper_id: PaperId,
    pub tag_id: Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryCollectionIntent {
    Create,
    Update,
    Delete,
    Put,
    Remove,
}

impl LibraryCollectionIntent {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Update => "update",
            Self::Delete => "delete",
            Self::Put => "put",
            Self::Remove => "remove",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryV2MutationOutcome<T> {
    Applied { value: T, replayed: bool },
    AccountNotFound,
    Inactive(AccountStatus),
    PaperNotFound,
    ListNotFound,
    TagNotFound,
    MembershipNotFound,
    NameConflict,
    IdempotencyConflict,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LibraryV2ReadOutcome<T> {
    Found(T),
    AccountNotFound,
    Inactive(AccountStatus),
    InvalidAfterRevision,
    ResetRequired {
        purged_through_revision: i64,
        sync_revision: i64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredLibraryLists {
    pub items: Vec<LibraryList>,
    pub sync_revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredLibraryTags {
    pub items: Vec<LibraryTag>,
    pub sync_revision: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StoredLibraryV2ChangesPage {
    pub items: Vec<LibraryV2Change>,
    pub next_after_revision: i64,
    pub has_more: bool,
    pub sync_revision: i64,
    pub purged_through_revision: i64,
}

impl LibraryRepository {
    #[allow(clippy::too_many_lines)]
    pub async fn mutate_list(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: &LibraryListWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryList>, DbError> {
        let payload = canonical_payload(write)?;
        let mut transaction = self.pool().begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryV2MutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryV2MutationOutcome::Inactive(status));
        }
        lock_collection_operation(&mut transaction, user_id, operation_id).await?;
        if let Some(matches) = collection_operation_matches(
            &mut transaction,
            user_id,
            operation_id,
            "list",
            write.id,
            None,
            intent,
            &payload,
        )
        .await?
        {
            if !matches {
                return Ok(LibraryV2MutationOutcome::IdempotencyConflict);
            }
            let value = load_list(&mut transaction, user_id, write.id)
                .await?
                .ok_or_else(|| invalid_replay("list"))?;
            transaction.commit().await?;
            return Ok(LibraryV2MutationOutcome::Applied {
                value,
                replayed: true,
            });
        }

        let exists = list_exists(&mut transaction, user_id, write.id).await?;
        if matches!(intent, LibraryCollectionIntent::Create) && exists {
            return Ok(LibraryV2MutationOutcome::IdempotencyConflict);
        }
        if !matches!(intent, LibraryCollectionIntent::Create) && !exists {
            return Ok(LibraryV2MutationOutcome::ListNotFound);
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        let value = match intent {
            LibraryCollectionIntent::Create => {
                let result = sqlx::query_as::<_, LibraryListRow>(
                    r"
                    INSERT INTO library_lists (
                        id, user_id, name, normalized_name, description, sort_order,
                        revision, deleted_at, created_at, updated_at, last_operation_id
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7, NULL,
                        statement_timestamp(), statement_timestamp(), $8
                    )
                    RETURNING id, name, description, sort_order, revision, deleted_at,
                              created_at, updated_at, last_operation_id
                    ",
                )
                .bind(write.id)
                .bind(user_id.into_inner())
                .bind(&write.name)
                .bind(&write.normalized_name)
                .bind(&write.description)
                .bind(write.sort_order)
                .bind(revision)
                .bind(operation_id)
                .fetch_one(&mut *transaction)
                .await;
                match result {
                    Ok(row) => row.into(),
                    Err(error) if unique_violation(&error) => {
                        return Ok(LibraryV2MutationOutcome::NameConflict);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            LibraryCollectionIntent::Update => {
                let result = sqlx::query_as::<_, LibraryListRow>(
                    r"
                    UPDATE library_lists
                    SET name = $3,
                        normalized_name = $4,
                        description = $5,
                        sort_order = $6,
                        revision = $7,
                        updated_at = statement_timestamp(),
                        last_operation_id = $8
                    WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                    RETURNING id, name, description, sort_order, revision, deleted_at,
                              created_at, updated_at, last_operation_id
                    ",
                )
                .bind(user_id.into_inner())
                .bind(write.id)
                .bind(&write.name)
                .bind(&write.normalized_name)
                .bind(&write.description)
                .bind(write.sort_order)
                .bind(revision)
                .bind(operation_id)
                .fetch_optional(&mut *transaction)
                .await;
                match result {
                    Ok(Some(row)) => row.into(),
                    Ok(None) => return Ok(LibraryV2MutationOutcome::ListNotFound),
                    Err(error) if unique_violation(&error) => {
                        return Ok(LibraryV2MutationOutcome::NameConflict);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            LibraryCollectionIntent::Delete => sqlx::query_as::<_, LibraryListRow>(
                r"
                UPDATE library_lists
                SET revision = $3,
                    deleted_at = statement_timestamp(),
                    updated_at = statement_timestamp(),
                    last_operation_id = $4
                WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                RETURNING id, name, description, sort_order, revision, deleted_at,
                          created_at, updated_at, last_operation_id
                ",
            )
            .bind(user_id.into_inner())
            .bind(write.id)
            .bind(revision)
            .bind(operation_id)
            .fetch_optional(&mut *transaction)
            .await?
            .map(Into::into)
            .ok_or_else(|| invalid_missing("list"))?,
            LibraryCollectionIntent::Put | LibraryCollectionIntent::Remove => {
                return Err(DbError::InvalidData(
                    "list mutation used a membership intent".to_owned(),
                ));
            }
        };
        insert_collection_operation(
            &mut transaction,
            user_id,
            operation_id,
            "list",
            write.id,
            None,
            intent,
            &payload,
            revision,
        )
        .await?;
        transaction.commit().await?;
        Ok(LibraryV2MutationOutcome::Applied {
            value,
            replayed: false,
        })
    }

    #[allow(clippy::too_many_lines)]
    pub async fn mutate_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: &LibraryTagWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryTag>, DbError> {
        let payload = canonical_payload(write)?;
        let mut transaction = self.pool().begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryV2MutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryV2MutationOutcome::Inactive(status));
        }
        lock_collection_operation(&mut transaction, user_id, operation_id).await?;
        if let Some(matches) = collection_operation_matches(
            &mut transaction,
            user_id,
            operation_id,
            "tag",
            write.id,
            None,
            intent,
            &payload,
        )
        .await?
        {
            if !matches {
                return Ok(LibraryV2MutationOutcome::IdempotencyConflict);
            }
            let value = load_tag(&mut transaction, user_id, write.id)
                .await?
                .ok_or_else(|| invalid_replay("tag"))?;
            transaction.commit().await?;
            return Ok(LibraryV2MutationOutcome::Applied {
                value,
                replayed: true,
            });
        }
        let exists = tag_exists(&mut transaction, user_id, write.id).await?;
        if matches!(intent, LibraryCollectionIntent::Create) && exists {
            return Ok(LibraryV2MutationOutcome::IdempotencyConflict);
        }
        if !matches!(intent, LibraryCollectionIntent::Create) && !exists {
            return Ok(LibraryV2MutationOutcome::TagNotFound);
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        let value = match intent {
            LibraryCollectionIntent::Create => {
                let result = sqlx::query_as::<_, LibraryTagRow>(
                    r"
                    INSERT INTO library_tags (
                        id, user_id, name, normalized_name, revision, deleted_at,
                        created_at, updated_at, last_operation_id
                    ) VALUES (
                        $1, $2, $3, $4, $5, NULL,
                        statement_timestamp(), statement_timestamp(), $6
                    )
                    RETURNING id, name, revision, deleted_at, created_at,
                              updated_at, last_operation_id
                    ",
                )
                .bind(write.id)
                .bind(user_id.into_inner())
                .bind(&write.name)
                .bind(&write.normalized_name)
                .bind(revision)
                .bind(operation_id)
                .fetch_one(&mut *transaction)
                .await;
                match result {
                    Ok(row) => row.into(),
                    Err(error) if unique_violation(&error) => {
                        return Ok(LibraryV2MutationOutcome::NameConflict);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            LibraryCollectionIntent::Update => {
                let result = sqlx::query_as::<_, LibraryTagRow>(
                    r"
                    UPDATE library_tags
                    SET name = $3,
                        normalized_name = $4,
                        revision = $5,
                        updated_at = statement_timestamp(),
                        last_operation_id = $6
                    WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                    RETURNING id, name, revision, deleted_at, created_at,
                              updated_at, last_operation_id
                    ",
                )
                .bind(user_id.into_inner())
                .bind(write.id)
                .bind(&write.name)
                .bind(&write.normalized_name)
                .bind(revision)
                .bind(operation_id)
                .fetch_optional(&mut *transaction)
                .await;
                match result {
                    Ok(Some(row)) => row.into(),
                    Ok(None) => return Ok(LibraryV2MutationOutcome::TagNotFound),
                    Err(error) if unique_violation(&error) => {
                        return Ok(LibraryV2MutationOutcome::NameConflict);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            LibraryCollectionIntent::Delete => sqlx::query_as::<_, LibraryTagRow>(
                r"
                UPDATE library_tags
                SET revision = $3,
                    deleted_at = statement_timestamp(),
                    updated_at = statement_timestamp(),
                    last_operation_id = $4
                WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                RETURNING id, name, revision, deleted_at, created_at,
                          updated_at, last_operation_id
                ",
            )
            .bind(user_id.into_inner())
            .bind(write.id)
            .bind(revision)
            .bind(operation_id)
            .fetch_optional(&mut *transaction)
            .await?
            .map(Into::into)
            .ok_or_else(|| invalid_missing("tag"))?,
            LibraryCollectionIntent::Put | LibraryCollectionIntent::Remove => {
                return Err(DbError::InvalidData(
                    "tag mutation used a membership intent".to_owned(),
                ));
            }
        };
        insert_collection_operation(
            &mut transaction,
            user_id,
            operation_id,
            "tag",
            write.id,
            None,
            intent,
            &payload,
            revision,
        )
        .await?;
        transaction.commit().await?;
        Ok(LibraryV2MutationOutcome::Applied {
            value,
            replayed: false,
        })
    }

    #[allow(clippy::too_many_lines)]
    pub async fn mutate_list_item(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: &LibraryListItemWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryListItem>, DbError> {
        if !matches!(
            intent,
            LibraryCollectionIntent::Put | LibraryCollectionIntent::Remove
        ) {
            return Err(DbError::InvalidData(
                "list membership used a collection intent".to_owned(),
            ));
        }
        let payload = canonical_payload(write)?;
        let mut transaction = self.pool().begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryV2MutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryV2MutationOutcome::Inactive(status));
        }
        lock_collection_operation(&mut transaction, user_id, operation_id).await?;
        if let Some(matches) = collection_operation_matches(
            &mut transaction,
            user_id,
            operation_id,
            "list_item",
            write.list_id,
            Some(write.paper_id),
            intent,
            &payload,
        )
        .await?
        {
            if !matches {
                return Ok(LibraryV2MutationOutcome::IdempotencyConflict);
            }
            let value = load_list_item(&mut transaction, user_id, write.list_id, write.paper_id)
                .await?
                .ok_or_else(|| invalid_replay("list item"))?;
            transaction.commit().await?;
            return Ok(LibraryV2MutationOutcome::Applied {
                value,
                replayed: true,
            });
        }
        if !active_list_exists(&mut transaction, user_id, write.list_id).await? {
            return Ok(LibraryV2MutationOutcome::ListNotFound);
        }
        if matches!(intent, LibraryCollectionIntent::Put)
            && !active_library_item_exists(&mut transaction, user_id, write.paper_id).await?
        {
            return Ok(LibraryV2MutationOutcome::PaperNotFound);
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        let value = match intent {
            LibraryCollectionIntent::Put => sqlx::query_as::<_, LibraryListItemRow>(
                r"
                INSERT INTO library_list_items (
                    user_id, list_id, paper_id, position_rank, note, revision,
                    deleted_at, created_at, updated_at, last_operation_id
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, NULL,
                    statement_timestamp(), statement_timestamp(), $7
                )
                ON CONFLICT (list_id, paper_id) DO UPDATE
                SET position_rank = EXCLUDED.position_rank,
                    note = EXCLUDED.note,
                    revision = EXCLUDED.revision,
                    deleted_at = NULL,
                    updated_at = EXCLUDED.updated_at,
                    last_operation_id = EXCLUDED.last_operation_id
                WHERE library_list_items.user_id = EXCLUDED.user_id
                RETURNING list_id, paper_id, position_rank, note, revision,
                          deleted_at, created_at, updated_at, last_operation_id
                ",
            )
            .bind(user_id.into_inner())
            .bind(write.list_id)
            .bind(write.paper_id)
            .bind(write.position_rank)
            .bind(&write.note)
            .bind(revision)
            .bind(operation_id)
            .fetch_one(&mut *transaction)
            .await?
            .into(),
            LibraryCollectionIntent::Remove => {
                let Some(row) = sqlx::query_as::<_, LibraryListItemRow>(
                    r"
                    UPDATE library_list_items
                    SET revision = $4,
                        deleted_at = statement_timestamp(),
                        updated_at = statement_timestamp(),
                        last_operation_id = $5
                    WHERE user_id = $1 AND list_id = $2 AND paper_id = $3
                      AND deleted_at IS NULL
                    RETURNING list_id, paper_id, position_rank, note, revision,
                              deleted_at, created_at, updated_at, last_operation_id
                    ",
                )
                .bind(user_id.into_inner())
                .bind(write.list_id)
                .bind(write.paper_id)
                .bind(revision)
                .bind(operation_id)
                .fetch_optional(&mut *transaction)
                .await?
                else {
                    return Ok(LibraryV2MutationOutcome::MembershipNotFound);
                };
                row.into()
            }
            _ => unreachable!("membership intent was checked above"),
        };
        insert_collection_operation(
            &mut transaction,
            user_id,
            operation_id,
            "list_item",
            write.list_id,
            Some(write.paper_id),
            intent,
            &payload,
            revision,
        )
        .await?;
        transaction.commit().await?;
        Ok(LibraryV2MutationOutcome::Applied {
            value,
            replayed: false,
        })
    }

    #[allow(clippy::too_many_lines)]
    pub async fn mutate_item_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: LibraryItemTagWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryItemTag>, DbError> {
        if !matches!(
            intent,
            LibraryCollectionIntent::Put | LibraryCollectionIntent::Remove
        ) {
            return Err(DbError::InvalidData(
                "tag membership used a collection intent".to_owned(),
            ));
        }
        let payload = canonical_payload(&write)?;
        let mut transaction = self.pool().begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryV2MutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryV2MutationOutcome::Inactive(status));
        }
        lock_collection_operation(&mut transaction, user_id, operation_id).await?;
        if let Some(matches) = collection_operation_matches(
            &mut transaction,
            user_id,
            operation_id,
            "item_tag",
            write.paper_id,
            Some(write.tag_id),
            intent,
            &payload,
        )
        .await?
        {
            if !matches {
                return Ok(LibraryV2MutationOutcome::IdempotencyConflict);
            }
            let value = load_item_tag(&mut transaction, user_id, write.paper_id, write.tag_id)
                .await?
                .ok_or_else(|| invalid_replay("item tag"))?;
            transaction.commit().await?;
            return Ok(LibraryV2MutationOutcome::Applied {
                value,
                replayed: true,
            });
        }
        if !active_tag_exists(&mut transaction, user_id, write.tag_id).await? {
            return Ok(LibraryV2MutationOutcome::TagNotFound);
        }
        if matches!(intent, LibraryCollectionIntent::Put)
            && !active_library_item_exists(&mut transaction, user_id, write.paper_id).await?
        {
            return Ok(LibraryV2MutationOutcome::PaperNotFound);
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        let value = match intent {
            LibraryCollectionIntent::Put => sqlx::query_as::<_, LibraryItemTagRow>(
                r"
                INSERT INTO library_item_tags (
                    user_id, paper_id, tag_id, revision, deleted_at,
                    created_at, updated_at, last_operation_id
                ) VALUES (
                    $1, $2, $3, $4, NULL,
                    statement_timestamp(), statement_timestamp(), $5
                )
                ON CONFLICT (user_id, paper_id, tag_id) DO UPDATE
                SET revision = EXCLUDED.revision,
                    deleted_at = NULL,
                    updated_at = EXCLUDED.updated_at,
                    last_operation_id = EXCLUDED.last_operation_id
                RETURNING paper_id, tag_id, revision, deleted_at,
                          created_at, updated_at, last_operation_id
                ",
            )
            .bind(user_id.into_inner())
            .bind(write.paper_id)
            .bind(write.tag_id)
            .bind(revision)
            .bind(operation_id)
            .fetch_one(&mut *transaction)
            .await?
            .into(),
            LibraryCollectionIntent::Remove => {
                let Some(row) = sqlx::query_as::<_, LibraryItemTagRow>(
                    r"
                    UPDATE library_item_tags
                    SET revision = $4,
                        deleted_at = statement_timestamp(),
                        updated_at = statement_timestamp(),
                        last_operation_id = $5
                    WHERE user_id = $1 AND paper_id = $2 AND tag_id = $3
                      AND deleted_at IS NULL
                    RETURNING paper_id, tag_id, revision, deleted_at,
                              created_at, updated_at, last_operation_id
                    ",
                )
                .bind(user_id.into_inner())
                .bind(write.paper_id)
                .bind(write.tag_id)
                .bind(revision)
                .bind(operation_id)
                .fetch_optional(&mut *transaction)
                .await?
                else {
                    return Ok(LibraryV2MutationOutcome::MembershipNotFound);
                };
                row.into()
            }
            _ => unreachable!("membership intent was checked above"),
        };
        insert_collection_operation(
            &mut transaction,
            user_id,
            operation_id,
            "item_tag",
            write.paper_id,
            Some(write.tag_id),
            intent,
            &payload,
            revision,
        )
        .await?;
        transaction.commit().await?;
        Ok(LibraryV2MutationOutcome::Applied {
            value,
            replayed: false,
        })
    }

    pub async fn lists(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryLists>, DbError> {
        let mut transaction = begin_consistent_read(self.pool()).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryV2ReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryV2ReadOutcome::Inactive(status));
        }
        let sync_revision = committed_revision_in(&mut transaction, user_id).await?;
        let rows = sqlx::query_as::<_, LibraryListRow>(
            r"
            SELECT id, name, description, sort_order, revision, deleted_at,
                   created_at, updated_at, last_operation_id
            FROM library_lists
            WHERE user_id = $1 AND deleted_at IS NULL AND revision <= $2
            ORDER BY sort_order, normalized_name, id
            LIMIT $3
            ",
        )
        .bind(user_id.into_inner())
        .bind(sync_revision)
        .bind(i64::from(limit))
        .fetch_all(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(LibraryV2ReadOutcome::Found(StoredLibraryLists {
            items: rows.into_iter().map(Into::into).collect(),
            sync_revision,
        }))
    }

    pub async fn tags(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryTags>, DbError> {
        let mut transaction = begin_consistent_read(self.pool()).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryV2ReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryV2ReadOutcome::Inactive(status));
        }
        let sync_revision = committed_revision_in(&mut transaction, user_id).await?;
        let rows = sqlx::query_as::<_, LibraryTagRow>(
            r"
            SELECT id, name, revision, deleted_at, created_at, updated_at, last_operation_id
            FROM library_tags
            WHERE user_id = $1 AND deleted_at IS NULL AND revision <= $2
            ORDER BY normalized_name, id
            LIMIT $3
            ",
        )
        .bind(user_id.into_inner())
        .bind(sync_revision)
        .bind(i64::from(limit))
        .fetch_all(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(LibraryV2ReadOutcome::Found(StoredLibraryTags {
            items: rows.into_iter().map(Into::into).collect(),
            sync_revision,
        }))
    }

    #[allow(clippy::too_many_lines)]
    pub async fn v2_changes(
        &self,
        user_id: AuthenticatedUserId,
        after_revision: i64,
        limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryV2ChangesPage>, DbError> {
        let mut transaction = begin_consistent_read(self.pool()).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(LibraryV2ReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(LibraryV2ReadOutcome::Inactive(status));
        }
        let sync_revision = committed_revision_in(&mut transaction, user_id).await?;
        if after_revision < 0 || after_revision > sync_revision {
            return Ok(LibraryV2ReadOutcome::InvalidAfterRevision);
        }
        let purged_through_revision: i64 = sqlx::query_scalar(
            r"
            SELECT COALESCE(
                (SELECT purged_through_revision
                 FROM library_sync_metadata
                 WHERE user_id = $1),
                0
            )
            ",
        )
        .bind(user_id.into_inner())
        .fetch_one(&mut *transaction)
        .await?;
        if after_revision < purged_through_revision {
            return Ok(LibraryV2ReadOutcome::ResetRequired {
                purged_through_revision,
                sync_revision,
            });
        }

        let mut keys = sqlx::query_as::<_, LibraryV2ChangeKeyRow>(
            r"
            SELECT revision, entity_kind, primary_id, secondary_id
            FROM (
                SELECT revision, 'item'::text AS entity_kind,
                       paper_id AS primary_id, NULL::uuid AS secondary_id
                FROM user_paper_library
                WHERE user_id = $1 AND revision > $2 AND revision <= $3
                UNION ALL
                SELECT revision, 'list'::text, id, NULL::uuid
                FROM library_lists
                WHERE user_id = $1 AND revision > $2 AND revision <= $3
                UNION ALL
                SELECT revision, 'list_item'::text, list_id, paper_id
                FROM library_list_items
                WHERE user_id = $1 AND revision > $2 AND revision <= $3
                UNION ALL
                SELECT revision, 'tag'::text, id, NULL::uuid
                FROM library_tags
                WHERE user_id = $1 AND revision > $2 AND revision <= $3
                UNION ALL
                SELECT revision, 'item_tag'::text, paper_id, tag_id
                FROM library_item_tags
                WHERE user_id = $1 AND revision > $2 AND revision <= $3
            ) AS change
            ORDER BY revision ASC, entity_kind ASC, primary_id ASC, secondary_id ASC
            LIMIT $4
            ",
        )
        .bind(user_id.into_inner())
        .bind(after_revision)
        .bind(sync_revision)
        .bind(i64::from(limit) + 1)
        .fetch_all(&mut *transaction)
        .await?;
        let has_more = keys.len() > limit as usize;
        if has_more {
            keys.pop();
        }
        let mut items = Vec::with_capacity(keys.len());
        for key in keys {
            let change = match key.entity_kind.as_str() {
                "item" => load_item_change(&mut transaction, user_id, key.primary_id).await?,
                "list" => load_list(&mut transaction, user_id, key.primary_id)
                    .await?
                    .map(|list| LibraryV2Change::List { list }),
                "list_item" => {
                    let paper_id = key.secondary_id.ok_or_else(|| {
                        DbError::InvalidData(
                            "library list-item change has no paper identity".to_owned(),
                        )
                    })?;
                    load_list_item(&mut transaction, user_id, key.primary_id, paper_id)
                        .await?
                        .map(|list_item| LibraryV2Change::ListItem { list_item })
                }
                "tag" => load_tag(&mut transaction, user_id, key.primary_id)
                    .await?
                    .map(|tag| LibraryV2Change::Tag { tag }),
                "item_tag" => {
                    let tag_id = key.secondary_id.ok_or_else(|| {
                        DbError::InvalidData(
                            "library item-tag change has no tag identity".to_owned(),
                        )
                    })?;
                    load_item_tag(&mut transaction, user_id, key.primary_id, tag_id)
                        .await?
                        .map(|item_tag| LibraryV2Change::ItemTag { item_tag })
                }
                _ => {
                    return Err(DbError::InvalidData(
                        "library change has an unknown entity kind".to_owned(),
                    ));
                }
            }
            .ok_or_else(|| {
                DbError::InvalidData(format!(
                    "library {} change has no canonical row",
                    key.entity_kind
                ))
            })?;
            if change.revision() != key.revision {
                return Err(DbError::InvalidData(
                    "library change revision does not match its canonical row".to_owned(),
                ));
            }
            items.push(change);
        }
        let next_after_revision = if has_more {
            items
                .last()
                .map_or(after_revision, LibraryV2Change::revision)
        } else {
            sync_revision
        };
        transaction.commit().await?;
        Ok(LibraryV2ReadOutcome::Found(StoredLibraryV2ChangesPage {
            items,
            next_after_revision,
            has_more,
            sync_revision,
            purged_through_revision,
        }))
    }
}

async fn load_item_change(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
) -> Result<Option<LibraryV2Change>, DbError> {
    let row = sqlx::query_as::<_, LibraryItemChangeRow>(
        r"
        SELECT paper_id, state, private_note, save_source_kind, reminder_at, saved_at,
               updated_at, reviewed_at, archived_at, removed_at, revision,
               last_operation_id
        FROM user_paper_library
        WHERE user_id = $1 AND paper_id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?;
    let Some(row) = row else {
        return Ok(None);
    };
    let item = library_item(
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
    )?;
    let paper = sqlx::query_as::<_, PaperSummaryRow>(
        r"
        SELECT paper.id, paper.arxiv_base_id, paper.arxiv_version, paper.title,
               paper.abstract AS abstract_text, paper.authors,
               paper.primary_category, paper.categories, paper.published_at,
               paper.updated_at, paper.abs_url, paper.pdf_url,
               processing.metadata_ready, processing.introduction_ready,
               processing.chat_ready, processing.connections_ready
        FROM papers AS paper
        JOIN paper_processing AS processing ON processing.paper_id = paper.id
        WHERE paper.id = $1
        ",
    )
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?
    .map(PaperSummary::try_from)
    .transpose()?;
    Ok(Some(LibraryV2Change::Item {
        item,
        paper: paper.map(Box::new),
    }))
}

fn canonical_payload(value: &impl Serialize) -> Result<Vec<u8>, DbError> {
    serde_json::to_vec(value)
        .map_err(|_| DbError::InvalidData("library operation payload is invalid".to_owned()))
}

async fn lock_collection_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
) -> Result<(), DbError> {
    if operation_id.is_nil() {
        return Err(DbError::InvalidData(
            "library operation ID must not be nil".to_owned(),
        ));
    }
    sqlx::query(
        r"
        SELECT pg_advisory_xact_lock(
            hashtextextended('library-v2-operation:' || $1::text || ':' || $2::text, 0)
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn collection_operation_matches(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    entity_kind: &str,
    entity_id: Uuid,
    secondary_id: Option<Uuid>,
    intent: LibraryCollectionIntent,
    payload: &[u8],
) -> Result<Option<bool>, DbError> {
    sqlx::query_scalar(
        r"
        SELECT entity_kind = $3
           AND entity_id = $4
           AND secondary_id IS NOT DISTINCT FROM $5
           AND intent = $6
           AND payload_fingerprint = digest($7::bytea, 'sha256')
        FROM library_collection_operations
        WHERE user_id = $1 AND operation_id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(entity_kind)
    .bind(entity_id)
    .bind(secondary_id)
    .bind(intent.as_str())
    .bind(payload)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

#[allow(clippy::too_many_arguments)]
async fn insert_collection_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    entity_kind: &str,
    entity_id: Uuid,
    secondary_id: Option<Uuid>,
    intent: LibraryCollectionIntent,
    payload: &[u8],
    revision: i64,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO library_collection_operations (
            user_id, operation_id, entity_kind, entity_id, secondary_id,
            intent, payload_fingerprint, accepted_revision
        ) VALUES ($1, $2, $3, $4, $5, $6, digest($7::bytea, 'sha256'), $8)
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(entity_kind)
    .bind(entity_id)
    .bind(secondary_id)
    .bind(intent.as_str())
    .bind(payload)
    .bind(revision)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn list_exists(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
) -> Result<bool, DbError> {
    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM library_lists WHERE user_id = $1 AND id = $2)")
        .bind(user_id.into_inner())
        .bind(id)
        .fetch_one(&mut **transaction)
        .await
        .map_err(DbError::from)
}

async fn tag_exists(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
) -> Result<bool, DbError> {
    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM library_tags WHERE user_id = $1 AND id = $2)")
        .bind(user_id.into_inner())
        .bind(id)
        .fetch_one(&mut **transaction)
        .await
        .map_err(DbError::from)
}

async fn active_list_exists(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
) -> Result<bool, DbError> {
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM library_lists WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL)",
    )
    .bind(user_id.into_inner())
    .bind(id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn active_tag_exists(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
) -> Result<bool, DbError> {
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM library_tags WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL)",
    )
    .bind(user_id.into_inner())
    .bind(id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn active_library_item_exists(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
) -> Result<bool, DbError> {
    sqlx::query_scalar(
        r"
        SELECT EXISTS(
            SELECT 1
            FROM user_paper_library
            WHERE user_id = $1 AND paper_id = $2 AND removed_at IS NULL
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn load_list(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
) -> Result<Option<LibraryList>, DbError> {
    sqlx::query_as::<_, LibraryListRow>(
        r"
        SELECT id, name, description, sort_order, revision, deleted_at,
               created_at, updated_at, last_operation_id
        FROM library_lists WHERE user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(id)
    .fetch_optional(&mut **transaction)
    .await
    .map(|row| row.map(Into::into))
    .map_err(DbError::from)
}

async fn load_tag(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
) -> Result<Option<LibraryTag>, DbError> {
    sqlx::query_as::<_, LibraryTagRow>(
        r"
        SELECT id, name, revision, deleted_at, created_at, updated_at, last_operation_id
        FROM library_tags WHERE user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(id)
    .fetch_optional(&mut **transaction)
    .await
    .map(|row| row.map(Into::into))
    .map_err(DbError::from)
}

async fn load_list_item(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    list_id: Uuid,
    paper_id: PaperId,
) -> Result<Option<LibraryListItem>, DbError> {
    sqlx::query_as::<_, LibraryListItemRow>(
        r"
        SELECT list_id, paper_id, position_rank, note, revision, deleted_at,
               created_at, updated_at, last_operation_id
        FROM library_list_items
        WHERE user_id = $1 AND list_id = $2 AND paper_id = $3
        ",
    )
    .bind(user_id.into_inner())
    .bind(list_id)
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await
    .map(|row| row.map(Into::into))
    .map_err(DbError::from)
}

async fn load_item_tag(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
    tag_id: Uuid,
) -> Result<Option<LibraryItemTag>, DbError> {
    sqlx::query_as::<_, LibraryItemTagRow>(
        r"
        SELECT paper_id, tag_id, revision, deleted_at,
               created_at, updated_at, last_operation_id
        FROM library_item_tags
        WHERE user_id = $1 AND paper_id = $2 AND tag_id = $3
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .bind(tag_id)
    .fetch_optional(&mut **transaction)
    .await
    .map(|row| row.map(Into::into))
    .map_err(DbError::from)
}

fn unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(sqlx::error::DatabaseError::code)
        .is_some_and(|code| code == "23505")
}

fn invalid_replay(kind: &str) -> DbError {
    DbError::InvalidData(format!(
        "accepted library {kind} operation has no canonical row"
    ))
}

fn invalid_missing(kind: &str) -> DbError {
    DbError::InvalidData(format!("library {kind} disappeared while locked"))
}

#[derive(Debug, FromRow)]
struct LibraryListRow {
    id: Uuid,
    name: String,
    description: Option<String>,
    sort_order: i32,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    last_operation_id: Uuid,
}

impl From<LibraryListRow> for LibraryList {
    fn from(row: LibraryListRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            description: row.description,
            sort_order: row.sort_order,
            revision: row.revision,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
            last_operation_id: row.last_operation_id,
        }
    }
}

#[derive(Debug, FromRow)]
struct LibraryTagRow {
    id: Uuid,
    name: String,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    last_operation_id: Uuid,
}

impl From<LibraryTagRow> for LibraryTag {
    fn from(row: LibraryTagRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            revision: row.revision,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
            last_operation_id: row.last_operation_id,
        }
    }
}

#[derive(Debug, FromRow)]
struct LibraryListItemRow {
    list_id: Uuid,
    paper_id: Uuid,
    position_rank: i64,
    note: Option<String>,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    last_operation_id: Uuid,
}

impl From<LibraryListItemRow> for LibraryListItem {
    fn from(row: LibraryListItemRow) -> Self {
        Self {
            list_id: row.list_id,
            paper_id: row.paper_id,
            position_rank: row.position_rank,
            note: row.note,
            revision: row.revision,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
            last_operation_id: row.last_operation_id,
        }
    }
}

#[derive(Debug, FromRow)]
struct LibraryItemTagRow {
    paper_id: Uuid,
    tag_id: Uuid,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    last_operation_id: Uuid,
}

#[derive(Debug, FromRow)]
struct LibraryV2ChangeKeyRow {
    revision: i64,
    entity_kind: String,
    primary_id: Uuid,
    secondary_id: Option<Uuid>,
}

#[derive(Debug, FromRow)]
struct LibraryItemChangeRow {
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

impl From<LibraryItemTagRow> for LibraryItemTag {
    fn from(row: LibraryItemTagRow) -> Self {
        Self {
            paper_id: row.paper_id,
            tag_id: row.tag_id,
            revision: row.revision,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
            last_operation_id: row.last_operation_id,
        }
    }
}
