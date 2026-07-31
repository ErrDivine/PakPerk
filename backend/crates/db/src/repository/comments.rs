use std::str::FromStr;

use chrono::{DateTime, Utc};
use domain::{
    AccountStatus, AuthenticatedUserId, BlockedUser, BlockedUserPage, CommentBody, CommentPage,
    CommentReportReason, CommentReportStatus, CommentStatus, CommunityGuidelinesVersion,
    DisplayName, Handle, PaperComment, PaperId, PublicUser, ReportDetail, TermsVersion,
};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::DbError;
use crate::CreatedAtCursor;

const COMMENT_COLUMNS: &str = r"
    comments.id,
    comments.paper_id,
    comments.author_user_id,
    comments.body,
    comments.status,
    comments.version,
    comments.created_at,
    comments.updated_at,
    comments.edited_at,
    users.handle AS author_handle,
    users.display_name AS author_display_name,
    users.status AS author_status
";

#[derive(FromRow)]
struct CommentRow {
    id: Uuid,
    paper_id: Uuid,
    author_user_id: Uuid,
    body: String,
    status: String,
    version: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    edited_at: Option<DateTime<Utc>>,
    author_handle: Option<String>,
    author_display_name: Option<String>,
    author_status: String,
}

impl TryFrom<CommentRow> for PaperComment {
    type Error = DbError;

    fn try_from(row: CommentRow) -> Result<Self, Self::Error> {
        if row.version <= 0 {
            return Err(DbError::InvalidData(
                "persisted comment version must be positive".to_owned(),
            ));
        }
        Ok(Self {
            id: row.id,
            paper_id: row.paper_id,
            author: PublicUser {
                id: AuthenticatedUserId::new(row.author_user_id),
                handle: row
                    .author_handle
                    .map(|value| Handle::parse(&value))
                    .transpose()
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
                display_name: row
                    .author_display_name
                    .map(|value| DisplayName::parse(&value))
                    .transpose()
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
                status: AccountStatus::from_str(&row.author_status)
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
            },
            body: CommentBody::parse(&row.body)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            status: CommentStatus::from_str(&row.status)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            version: row.version,
            created_at: row.created_at,
            updated_at: row.updated_at,
            edited_at: row.edited_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct AccountEligibilityRow {
    status: String,
    handle: Option<String>,
    terms_version: Option<String>,
    terms_accepted_at: Option<DateTime<Utc>>,
    community_guidelines_version: Option<String>,
    community_guidelines_accepted_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentCreateResolution {
    Unknown,
    Replay(PaperComment),
    AccountNotFound,
    Inactive(AccountStatus),
    IdempotencyConflict,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentCreateOutcome {
    Applied {
        comment: PaperComment,
        replayed: bool,
    },
    AccountNotFound,
    Inactive(AccountStatus),
    ProfileIncomplete,
    PaperNotFound,
    IdempotencyConflict,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentCreatePrecondition {
    Eligible,
    AccountNotFound,
    Inactive(AccountStatus),
    ProfileIncomplete,
    PaperNotFound,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentMutationOutcome {
    Updated(PaperComment),
    Deleted {
        comment: PaperComment,
        replayed: bool,
    },
    AccountNotFound,
    Inactive(AccountStatus),
    CommentNotFound,
    NotAuthor,
    VersionConflict {
        current_version: i32,
    },
    AlreadyDeleted,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentDeleteResolution {
    Unknown,
    Replay(PaperComment),
    AccountNotFound,
    Inactive(AccountStatus),
    CommentNotFound,
    NotAuthor,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentEditResolution {
    Ready,
    AccountNotFound,
    Inactive(AccountStatus),
    CommentNotFound,
    VersionConflict { current_version: i32 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentReadOutcome<T> {
    Found(T),
    PaperNotFound,
    AccountNotFound,
    Inactive(AccountStatus),
    InvalidCursor,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredReport {
    pub id: Uuid,
    pub comment_id: Uuid,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub status: CommentReportStatus,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentReportOutcome {
    Accepted {
        report: StoredReport,
        replayed: bool,
    },
    AccountNotFound,
    Inactive(AccountStatus),
    CommentNotFound,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommentReportResolution {
    Unknown,
    Replay(StoredReport),
    AccountNotFound,
    Inactive(AccountStatus),
    CommentNotFound,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UserBlockOutcome {
    Applied { blocked_user: BlockedUser },
    Removed { existed: bool },
    AccountNotFound,
    Inactive(AccountStatus),
    TargetNotFound,
    CannotBlockSelf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UserBlockResolution {
    Unknown,
    Replay(BlockedUser),
    AccountNotFound,
    Inactive(AccountStatus),
    TargetNotFound,
    CannotBlockSelf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UserUnblockResolution {
    Present,
    Absent,
    AccountNotFound,
    Inactive(AccountStatus),
    CannotBlockSelf,
}

#[derive(Debug, FromRow)]
struct ReportRow {
    id: Uuid,
    comment_id: Uuid,
    reporter_user_id: Uuid,
    reason: String,
    status: String,
    created_at: DateTime<Utc>,
}

impl TryFrom<ReportRow> for StoredReport {
    type Error = DbError;

    fn try_from(row: ReportRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            comment_id: row.comment_id,
            reporter_user_id: AuthenticatedUserId::new(row.reporter_user_id),
            reason: CommentReportReason::from_str(&row.reason)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            status: CommentReportStatus::from_str(&row.status)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            created_at: row.created_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct BlockedUserRow {
    blocked_user_id: Uuid,
    handle: Option<String>,
    display_name: Option<String>,
    status: String,
    created_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct BlockResolutionRow {
    blocked_user_id: Uuid,
    handle: Option<String>,
    display_name: Option<String>,
    status: String,
    created_at: Option<DateTime<Utc>>,
}

impl TryFrom<BlockedUserRow> for BlockedUser {
    type Error = DbError;

    fn try_from(row: BlockedUserRow) -> Result<Self, Self::Error> {
        Ok(Self {
            user: PublicUser {
                id: AuthenticatedUserId::new(row.blocked_user_id),
                handle: row
                    .handle
                    .map(|value| Handle::parse(&value))
                    .transpose()
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
                display_name: row
                    .display_name
                    .map(|value| DisplayName::parse(&value))
                    .transpose()
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
                status: AccountStatus::from_str(&row.status)
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
            },
            created_at: row.created_at,
        })
    }
}

#[derive(Clone)]
pub struct CommentRepository {
    pool: PgPool,
}

impl CommentRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Resolves a durable create request before a caller spends moderation or
    /// shared rate-limit capacity.
    pub async fn resolve_create(
        &self,
        author_user_id: AuthenticatedUserId,
        paper_id: PaperId,
        client_request_id: Uuid,
        body: &CommentBody,
    ) -> Result<CommentCreateResolution, DbError> {
        if client_request_id.is_nil() {
            return Err(DbError::InvalidData(
                "comment client request ID must not be nil".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, author_user_id).await? else {
            return Ok(CommentCreateResolution::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(CommentCreateResolution::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "comment-create",
            author_user_id,
            client_request_id,
        )
        .await?;
        let row = sqlx::query_as::<_, CommentRow>(&format!(
            r"
            SELECT {COMMENT_COLUMNS}
            FROM paper_comments comments
            JOIN users ON users.id = comments.author_user_id
            WHERE comments.author_user_id = $1
              AND comments.client_request_id = $2
              AND comments.paper_id = $3
              AND comments.create_body_sha256 = digest($4, 'sha256')
            "
        ))
        .bind(author_user_id.into_inner())
        .bind(client_request_id)
        .bind(paper_id)
        .bind(body.as_str())
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(row) = row {
            transaction.commit().await?;
            return Ok(CommentCreateResolution::Replay(PaperComment::try_from(
                row,
            )?));
        }
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM paper_comments WHERE author_user_id = $1 AND client_request_id = $2)",
        )
        .bind(author_user_id.into_inner())
        .bind(client_request_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(if exists {
            CommentCreateResolution::IdempotencyConflict
        } else {
            CommentCreateResolution::Unknown
        })
    }

    pub async fn check_create_preconditions(
        &self,
        author_user_id: AuthenticatedUserId,
        paper_id: PaperId,
        current_terms_version: &TermsVersion,
        current_guidelines_version: &CommunityGuidelinesVersion,
    ) -> Result<CommentCreatePrecondition, DbError> {
        let mut transaction = self.pool.begin().await?;
        let Some(account) = lock_account_eligibility(&mut transaction, author_user_id).await?
        else {
            return Ok(CommentCreatePrecondition::AccountNotFound);
        };
        let status = AccountStatus::from_str(&account.status)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if !status.is_active() {
            return Ok(CommentCreatePrecondition::Inactive(status));
        }
        if account.handle.is_none()
            || account.terms_accepted_at.is_none()
            || account.terms_version.as_deref() != Some(current_terms_version.as_str())
            || account.community_guidelines_accepted_at.is_none()
            || account.community_guidelines_version.as_deref()
                != Some(current_guidelines_version.as_str())
        {
            return Ok(CommentCreatePrecondition::ProfileIncomplete);
        }
        let paper_exists: bool =
            sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM papers WHERE id = $1)")
                .bind(paper_id)
                .fetch_one(&mut *transaction)
                .await?;
        transaction.commit().await?;
        Ok(if paper_exists {
            CommentCreatePrecondition::Eligible
        } else {
            CommentCreatePrecondition::PaperNotFound
        })
    }

    #[allow(clippy::too_many_arguments, clippy::too_many_lines)]
    pub async fn create(
        &self,
        comment_id: Uuid,
        author_user_id: AuthenticatedUserId,
        paper_id: PaperId,
        client_request_id: Uuid,
        body: &CommentBody,
        status: CommentStatus,
        moderation_reason: Option<&str>,
        current_terms_version: &TermsVersion,
        current_guidelines_version: &CommunityGuidelinesVersion,
    ) -> Result<CommentCreateOutcome, DbError> {
        if comment_id.is_nil() || client_request_id.is_nil() {
            return Err(DbError::InvalidData(
                "comment and client request IDs must not be nil".to_owned(),
            ));
        }
        if !matches!(
            status,
            CommentStatus::Published | CommentStatus::PendingReview
        ) {
            return Err(DbError::InvalidData(
                "new comments must be published or pending review".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        let Some(account) = lock_account_eligibility(&mut transaction, author_user_id).await?
        else {
            return Ok(CommentCreateOutcome::AccountNotFound);
        };
        let account_status = AccountStatus::from_str(&account.status)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if !account_status.is_active() {
            return Ok(CommentCreateOutcome::Inactive(account_status));
        }
        let eligible = account.handle.is_some()
            && account.terms_accepted_at.is_some()
            && account.terms_version.as_deref() == Some(current_terms_version.as_str())
            && account.community_guidelines_accepted_at.is_some()
            && account.community_guidelines_version.as_deref()
                == Some(current_guidelines_version.as_str());
        if !eligible {
            return Ok(CommentCreateOutcome::ProfileIncomplete);
        }
        advisory_lock(
            &mut transaction,
            "comment-create",
            author_user_id,
            client_request_id,
        )
        .await?;

        let paper_exists: bool =
            sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM papers WHERE id = $1)")
                .bind(paper_id)
                .fetch_one(&mut *transaction)
                .await?;
        if !paper_exists {
            return Ok(CommentCreateOutcome::PaperNotFound);
        }

        let inserted = sqlx::query(
            r"
            INSERT INTO paper_comments (
                id,
                paper_id,
                author_user_id,
                client_request_id,
                body,
                create_body_sha256,
                status,
                moderation_reason
            )
            VALUES ($1, $2, $3, $4, $5, digest($5, 'sha256'), $6, $7)
            ON CONFLICT (author_user_id, client_request_id) DO NOTHING
            ",
        )
        .bind(comment_id)
        .bind(paper_id)
        .bind(author_user_id.into_inner())
        .bind(client_request_id)
        .bind(body.as_str())
        .bind(status.as_str())
        .bind(moderation_reason)
        .execute(&mut *transaction)
        .await?
        .rows_affected()
            == 1;

        if inserted {
            insert_system_event(
                &mut transaction,
                comment_id,
                if status == CommentStatus::Published {
                    "create_published"
                } else {
                    "create_pending_review"
                },
                moderation_reason,
            )
            .await?;
        }

        let same_intent = sqlx::query_scalar::<_, bool>(
            r"
            SELECT paper_id = $3 AND create_body_sha256 = digest($4, 'sha256')
            FROM paper_comments
            WHERE author_user_id = $1 AND client_request_id = $2
            ",
        )
        .bind(author_user_id.into_inner())
        .bind(client_request_id)
        .bind(paper_id)
        .bind(body.as_str())
        .fetch_one(&mut *transaction)
        .await?;
        if !same_intent {
            return Ok(CommentCreateOutcome::IdempotencyConflict);
        }
        let comment = load_comment_by_request(&mut transaction, author_user_id, client_request_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("accepted comment disappeared".to_owned()))?;
        transaction.commit().await?;
        Ok(CommentCreateOutcome::Applied {
            comment,
            replayed: !inserted,
        })
    }

    pub async fn edit(
        &self,
        author_user_id: AuthenticatedUserId,
        comment_id: Uuid,
        expected_version: i32,
        body: &CommentBody,
        status: CommentStatus,
        moderation_reason: Option<&str>,
    ) -> Result<CommentMutationOutcome, DbError> {
        if expected_version <= 0
            || !matches!(
                status,
                CommentStatus::Published | CommentStatus::PendingReview
            )
        {
            return Err(DbError::InvalidData(
                "comment edit preconditions are invalid".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, author_user_id).await? {
            None => return Ok(CommentMutationOutcome::AccountNotFound),
            Some(account_status) if !account_status.is_active() => {
                return Ok(CommentMutationOutcome::Inactive(account_status));
            }
            Some(_) => {}
        }
        advisory_lock(
            &mut transaction,
            "comment-mutation",
            author_user_id,
            comment_id,
        )
        .await?;
        let updated = sqlx::query_as::<_, CommentRow>(&format!(
            r"
            UPDATE paper_comments comments
            SET body = $4,
                status = CASE
                    WHEN comments.status = 'hidden' THEN 'pending_review'
                    ELSE $5
                END,
                moderation_reason = CASE
                    WHEN comments.status = 'hidden' THEN 'edit_after_admin_hide'
                    ELSE $6
                END,
                version = comments.version + 1,
                updated_at = statement_timestamp(),
                edited_at = statement_timestamp()
            FROM users
            WHERE comments.id = $1
              AND comments.author_user_id = $2
              AND comments.version = $3
              AND comments.status <> 'deleted'
              AND users.id = comments.author_user_id
            RETURNING {COMMENT_COLUMNS}
            "
        ))
        .bind(comment_id)
        .bind(author_user_id.into_inner())
        .bind(expected_version)
        .bind(body.as_str())
        .bind(status.as_str())
        .bind(moderation_reason)
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(row) = updated {
            let comment = PaperComment::try_from(row)?;
            insert_system_event(
                &mut transaction,
                comment_id,
                if comment.status == CommentStatus::Published {
                    "edit_published"
                } else {
                    "edit_pending_review"
                },
                if comment.status == CommentStatus::PendingReview
                    && status == CommentStatus::Published
                {
                    Some("edit_after_admin_hide")
                } else {
                    moderation_reason
                },
            )
            .await?;
            transaction.commit().await?;
            return Ok(CommentMutationOutcome::Updated(comment));
        }
        let outcome =
            classify_failed_mutation(&mut transaction, author_user_id, comment_id).await?;
        transaction.commit().await?;
        Ok(match outcome {
            FailedMutation::NotFound => CommentMutationOutcome::CommentNotFound,
            FailedMutation::NotAuthor => CommentMutationOutcome::NotAuthor,
            FailedMutation::Deleted { .. } => CommentMutationOutcome::AlreadyDeleted,
            FailedMutation::Current { version } => CommentMutationOutcome::VersionConflict {
                current_version: version,
            },
        })
    }

    pub async fn resolve_edit(
        &self,
        author_user_id: AuthenticatedUserId,
        comment_id: Uuid,
        expected_version: i32,
    ) -> Result<CommentEditResolution, DbError> {
        if expected_version <= 0 {
            return Err(DbError::InvalidData(
                "expected comment version must be positive".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, author_user_id).await? {
            None => return Ok(CommentEditResolution::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(CommentEditResolution::Inactive(status));
            }
            Some(_) => {}
        }
        advisory_lock(
            &mut transaction,
            "comment-mutation",
            author_user_id,
            comment_id,
        )
        .await?;
        let row = sqlx::query_as::<_, (Uuid, i32, String)>(
            "SELECT author_user_id, version, status FROM paper_comments WHERE id = $1",
        )
        .bind(comment_id)
        .fetch_optional(&mut *transaction)
        .await?;
        transaction.commit().await?;
        let Some((persisted_author_id, current_version, status)) = row else {
            return Ok(CommentEditResolution::CommentNotFound);
        };
        if persisted_author_id != author_user_id.into_inner() || status == "deleted" {
            return Ok(CommentEditResolution::CommentNotFound);
        }
        Ok(if current_version == expected_version {
            CommentEditResolution::Ready
        } else {
            CommentEditResolution::VersionConflict { current_version }
        })
    }

    pub async fn delete(
        &self,
        author_user_id: AuthenticatedUserId,
        comment_id: Uuid,
    ) -> Result<CommentMutationOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, author_user_id).await? {
            None => return Ok(CommentMutationOutcome::AccountNotFound),
            Some(account_status) if !account_status.is_active() => {
                return Ok(CommentMutationOutcome::Inactive(account_status));
            }
            Some(_) => {}
        }
        advisory_lock(
            &mut transaction,
            "comment-mutation",
            author_user_id,
            comment_id,
        )
        .await?;
        let updated = sqlx::query_as::<_, CommentRow>(&format!(
            r"
            UPDATE paper_comments comments
            SET status = 'deleted',
                moderation_reason = NULL,
                version = comments.version + 1,
                updated_at = statement_timestamp(),
                deleted_at = statement_timestamp()
            FROM users
            WHERE comments.id = $1
              AND comments.author_user_id = $2
              AND comments.status <> 'deleted'
              AND users.id = comments.author_user_id
            RETURNING {COMMENT_COLUMNS}
            "
        ))
        .bind(comment_id)
        .bind(author_user_id.into_inner())
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(row) = updated {
            transaction.commit().await?;
            return Ok(CommentMutationOutcome::Deleted {
                comment: PaperComment::try_from(row)?,
                replayed: false,
            });
        }
        let outcome =
            classify_failed_mutation(&mut transaction, author_user_id, comment_id).await?;
        transaction.commit().await?;
        Ok(match outcome {
            FailedMutation::NotFound => CommentMutationOutcome::CommentNotFound,
            FailedMutation::NotAuthor => CommentMutationOutcome::NotAuthor,
            FailedMutation::Deleted { comment } => CommentMutationOutcome::Deleted {
                comment,
                replayed: true,
            },
            FailedMutation::Current { .. } => {
                return Err(DbError::InvalidData(
                    "repeat-safe delete found an active comment after a locked update".to_owned(),
                ));
            }
        })
    }

    pub async fn resolve_delete(
        &self,
        author_user_id: AuthenticatedUserId,
        comment_id: Uuid,
    ) -> Result<CommentDeleteResolution, DbError> {
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, author_user_id).await? {
            None => return Ok(CommentDeleteResolution::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(CommentDeleteResolution::Inactive(status));
            }
            Some(_) => {}
        }
        advisory_lock(
            &mut transaction,
            "comment-mutation",
            author_user_id,
            comment_id,
        )
        .await?;
        let resolution =
            match classify_failed_mutation(&mut transaction, author_user_id, comment_id).await? {
                FailedMutation::NotFound => CommentDeleteResolution::CommentNotFound,
                FailedMutation::NotAuthor => CommentDeleteResolution::NotAuthor,
                FailedMutation::Deleted { comment } => CommentDeleteResolution::Replay(comment),
                FailedMutation::Current { .. } => CommentDeleteResolution::Unknown,
            };
        transaction.commit().await?;
        Ok(resolution)
    }

    pub async fn list_public(
        &self,
        paper_id: PaperId,
        viewer_user_id: Option<AuthenticatedUserId>,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CommentReadOutcome<CommentPage>, DbError> {
        let Ok(cursor) = cursor.map(CreatedAtCursor::decode).transpose() else {
            return Ok(CommentReadOutcome::InvalidCursor);
        };
        let exists: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM papers WHERE id = $1)")
            .bind(paper_id)
            .fetch_one(&self.pool)
            .await?;
        if !exists {
            return Ok(CommentReadOutcome::PaperNotFound);
        }
        let page_size = limit.max(1);
        let rows = sqlx::query_as::<_, CommentRow>(&format!(
            r"
            SELECT {COMMENT_COLUMNS}
            FROM paper_comments comments
            JOIN users ON users.id = comments.author_user_id
            WHERE comments.paper_id = $1
              AND comments.status = 'published'
              AND (
                    $2::uuid IS NULL
                    OR NOT EXISTS (
                        SELECT 1
                        FROM user_blocks
                        WHERE blocker_user_id = $2
                          AND blocked_user_id = comments.author_user_id
                    )
              )
              AND (
                    $3::timestamptz IS NULL
                    OR (comments.created_at, comments.id) < ($3, $4)
              )
            ORDER BY comments.created_at DESC, comments.id DESC
            LIMIT $5
            "
        ))
        .bind(paper_id)
        .bind(viewer_user_id.map(AuthenticatedUserId::into_inner))
        .bind(cursor.map(|value| value.created_at))
        .bind(cursor.map(|value| value.id))
        .bind(i64::from(page_size) + 1)
        .fetch_all(&self.pool)
        .await?;
        page_from_comment_rows(rows, page_size)
    }

    pub async fn list_own(
        &self,
        author_user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CommentReadOutcome<CommentPage>, DbError> {
        let Ok(cursor) = cursor.map(CreatedAtCursor::decode).transpose() else {
            return Ok(CommentReadOutcome::InvalidCursor);
        };
        match account_status(&self.pool, author_user_id).await? {
            None => return Ok(CommentReadOutcome::AccountNotFound),
            Some(status) if !status.is_active() => return Ok(CommentReadOutcome::Inactive(status)),
            Some(_) => {}
        }
        let page_size = limit.max(1);
        let rows = sqlx::query_as::<_, CommentRow>(&format!(
            r"
            SELECT {COMMENT_COLUMNS}
            FROM paper_comments comments
            JOIN users ON users.id = comments.author_user_id
            WHERE comments.author_user_id = $1
              AND comments.status <> 'deleted'
              AND (
                    $2::timestamptz IS NULL
                    OR (comments.created_at, comments.id) < ($2, $3)
              )
            ORDER BY comments.created_at DESC, comments.id DESC
            LIMIT $4
            "
        ))
        .bind(author_user_id.into_inner())
        .bind(cursor.map(|value| value.created_at))
        .bind(cursor.map(|value| value.id))
        .bind(i64::from(page_size) + 1)
        .fetch_all(&self.pool)
        .await?;
        page_from_comment_rows(rows, page_size)
    }

    pub async fn report(
        &self,
        reporter_user_id: AuthenticatedUserId,
        comment_id: Uuid,
        reason: CommentReportReason,
        detail: Option<&ReportDetail>,
    ) -> Result<CommentReportOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, reporter_user_id).await? {
            None => return Ok(CommentReportOutcome::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(CommentReportOutcome::Inactive(status));
            }
            Some(_) => {}
        }
        advisory_lock(
            &mut transaction,
            "comment-report",
            reporter_user_id,
            comment_id,
        )
        .await?;
        let comment_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM paper_comments WHERE id = $1 AND status <> 'deleted')",
        )
        .bind(comment_id)
        .fetch_one(&mut *transaction)
        .await?;
        if !comment_exists {
            return Ok(CommentReportOutcome::CommentNotFound);
        }
        let inserted = sqlx::query(
            r"
            INSERT INTO comment_reports (comment_id, reporter_user_id, reason, detail)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (comment_id, reporter_user_id) DO NOTHING
            ",
        )
        .bind(comment_id)
        .bind(reporter_user_id.into_inner())
        .bind(reason.as_str())
        .bind(detail.map(ReportDetail::as_str))
        .execute(&mut *transaction)
        .await?
        .rows_affected()
            == 1;
        let row = sqlx::query_as::<_, ReportRow>(
            r"
            SELECT id, comment_id, reporter_user_id, reason, status, created_at
            FROM comment_reports
            WHERE comment_id = $1 AND reporter_user_id = $2
            ",
        )
        .bind(comment_id)
        .bind(reporter_user_id.into_inner())
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(CommentReportOutcome::Accepted {
            report: StoredReport::try_from(row)?,
            replayed: !inserted,
        })
    }

    /// Resolves the reporter/comment uniqueness key before a shared permit is
    /// consumed. Report content is immutable after first acceptance, so any
    /// retry returns that canonical record.
    pub async fn resolve_report(
        &self,
        reporter_user_id: AuthenticatedUserId,
        comment_id: Uuid,
    ) -> Result<CommentReportResolution, DbError> {
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, reporter_user_id).await? {
            None => return Ok(CommentReportResolution::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(CommentReportResolution::Inactive(status));
            }
            Some(_) => {}
        }
        advisory_lock(
            &mut transaction,
            "comment-report",
            reporter_user_id,
            comment_id,
        )
        .await?;
        let row = sqlx::query_as::<_, ReportRow>(
            r"
            SELECT id, comment_id, reporter_user_id, reason, status, created_at
            FROM comment_reports
            WHERE comment_id = $1 AND reporter_user_id = $2
            ",
        )
        .bind(comment_id)
        .bind(reporter_user_id.into_inner())
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(row) = row {
            transaction.commit().await?;
            return Ok(CommentReportResolution::Replay(StoredReport::try_from(
                row,
            )?));
        }
        let comment_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM paper_comments WHERE id = $1 AND status <> 'deleted')",
        )
        .bind(comment_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(if comment_exists {
            CommentReportResolution::Unknown
        } else {
            CommentReportResolution::CommentNotFound
        })
    }

    #[allow(clippy::similar_names)]
    pub async fn resolve_block(
        &self,
        blocker_user_id: AuthenticatedUserId,
        blocked_user_id: AuthenticatedUserId,
    ) -> Result<UserBlockResolution, DbError> {
        if blocker_user_id == blocked_user_id {
            return Ok(UserBlockResolution::CannotBlockSelf);
        }
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, blocker_user_id).await? {
            None => return Ok(UserBlockResolution::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(UserBlockResolution::Inactive(status));
            }
            Some(_) => {}
        }
        let row = sqlx::query_as::<_, BlockResolutionRow>(
            r"
            SELECT
                users.id AS blocked_user_id,
                users.handle,
                users.display_name,
                users.status,
                blocks.created_at
            FROM users
            LEFT JOIN user_blocks blocks
              ON blocks.blocker_user_id = $1
             AND blocks.blocked_user_id = users.id
            WHERE users.id = $2
            ",
        )
        .bind(blocker_user_id.into_inner())
        .bind(blocked_user_id.into_inner())
        .fetch_optional(&mut *transaction)
        .await?;
        transaction.commit().await?;
        let Some(row) = row else {
            return Ok(UserBlockResolution::TargetNotFound);
        };
        let Some(created_at) = row.created_at else {
            return Ok(UserBlockResolution::Unknown);
        };
        Ok(UserBlockResolution::Replay(BlockedUser::try_from(
            BlockedUserRow {
                blocked_user_id: row.blocked_user_id,
                handle: row.handle,
                display_name: row.display_name,
                status: row.status,
                created_at,
            },
        )?))
    }

    #[allow(clippy::similar_names)]
    pub async fn resolve_unblock(
        &self,
        blocker_user_id: AuthenticatedUserId,
        blocked_user_id: AuthenticatedUserId,
    ) -> Result<UserUnblockResolution, DbError> {
        if blocker_user_id == blocked_user_id {
            return Ok(UserUnblockResolution::CannotBlockSelf);
        }
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, blocker_user_id).await? {
            None => return Ok(UserUnblockResolution::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(UserUnblockResolution::Inactive(status));
            }
            Some(_) => {}
        }
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM user_blocks WHERE blocker_user_id = $1 AND blocked_user_id = $2)",
        )
        .bind(blocker_user_id.into_inner())
        .bind(blocked_user_id.into_inner())
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(if exists {
            UserUnblockResolution::Present
        } else {
            UserUnblockResolution::Absent
        })
    }

    #[allow(clippy::similar_names)]
    pub async fn block(
        &self,
        blocker_user_id: AuthenticatedUserId,
        blocked_user_id: AuthenticatedUserId,
    ) -> Result<UserBlockOutcome, DbError> {
        if blocker_user_id == blocked_user_id {
            return Ok(UserBlockOutcome::CannotBlockSelf);
        }
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, blocker_user_id).await? {
            None => return Ok(UserBlockOutcome::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(UserBlockOutcome::Inactive(status));
            }
            Some(_) => {}
        }
        let target_exists: bool =
            sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM users WHERE id = $1)")
                .bind(blocked_user_id.into_inner())
                .fetch_one(&mut *transaction)
                .await?;
        if !target_exists {
            return Ok(UserBlockOutcome::TargetNotFound);
        }
        let created_at: DateTime<Utc> = sqlx::query_scalar(
            r"
            INSERT INTO user_blocks (blocker_user_id, blocked_user_id)
            VALUES ($1, $2)
            ON CONFLICT (blocker_user_id, blocked_user_id) DO UPDATE
            SET created_at = user_blocks.created_at
            RETURNING created_at
            ",
        )
        .bind(blocker_user_id.into_inner())
        .bind(blocked_user_id.into_inner())
        .fetch_one(&mut *transaction)
        .await?;
        let row = sqlx::query_as::<_, BlockedUserRow>(
            r"
            SELECT
                users.id AS blocked_user_id,
                users.handle,
                users.display_name,
                users.status,
                $2::timestamptz AS created_at
            FROM users
            WHERE users.id = $1
            ",
        )
        .bind(blocked_user_id.into_inner())
        .bind(created_at)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(UserBlockOutcome::Applied {
            blocked_user: BlockedUser::try_from(row)?,
        })
    }

    #[allow(clippy::similar_names)]
    pub async fn unblock(
        &self,
        blocker_user_id: AuthenticatedUserId,
        blocked_user_id: AuthenticatedUserId,
    ) -> Result<UserBlockOutcome, DbError> {
        if blocker_user_id == blocked_user_id {
            return Ok(UserBlockOutcome::CannotBlockSelf);
        }
        let mut transaction = self.pool.begin().await?;
        match lock_account_status(&mut transaction, blocker_user_id).await? {
            None => return Ok(UserBlockOutcome::AccountNotFound),
            Some(status) if !status.is_active() => {
                return Ok(UserBlockOutcome::Inactive(status));
            }
            Some(_) => {}
        }
        let existed = sqlx::query(
            "DELETE FROM user_blocks WHERE blocker_user_id = $1 AND blocked_user_id = $2",
        )
        .bind(blocker_user_id.into_inner())
        .bind(blocked_user_id.into_inner())
        .execute(&mut *transaction)
        .await?
        .rows_affected()
            == 1;
        transaction.commit().await?;
        Ok(UserBlockOutcome::Removed { existed })
    }

    pub async fn list_blocks(
        &self,
        blocker_user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CommentReadOutcome<BlockedUserPage>, DbError> {
        let Ok(cursor) = cursor.map(CreatedAtCursor::decode).transpose() else {
            return Ok(CommentReadOutcome::InvalidCursor);
        };
        match account_status(&self.pool, blocker_user_id).await? {
            None => return Ok(CommentReadOutcome::AccountNotFound),
            Some(status) if !status.is_active() => return Ok(CommentReadOutcome::Inactive(status)),
            Some(_) => {}
        }
        let page_size = limit.max(1);
        let rows = sqlx::query_as::<_, BlockedUserRow>(
            r"
            SELECT
                blocks.blocked_user_id,
                users.handle,
                users.display_name,
                users.status,
                blocks.created_at
            FROM user_blocks blocks
            JOIN users ON users.id = blocks.blocked_user_id
            WHERE blocks.blocker_user_id = $1
              AND (
                    $2::timestamptz IS NULL
                    OR (blocks.created_at, blocks.blocked_user_id) < ($2, $3)
              )
            ORDER BY blocks.created_at DESC, blocks.blocked_user_id DESC
            LIMIT $4
            ",
        )
        .bind(blocker_user_id.into_inner())
        .bind(cursor.map(|value| value.created_at))
        .bind(cursor.map(|value| value.id))
        .bind(i64::from(page_size) + 1)
        .fetch_all(&self.pool)
        .await?;
        let mut items = rows
            .into_iter()
            .map(BlockedUser::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = items.len() > usize::try_from(page_size).unwrap_or(usize::MAX);
        if has_more {
            items.pop();
        }
        let next_cursor = has_more.then(|| {
            let last = items.last().expect("a page with more rows is non-empty");
            CreatedAtCursor {
                created_at: last.created_at,
                id: last.user.id.into_inner(),
            }
            .encode()
        });
        Ok(CommentReadOutcome::Found(BlockedUserPage {
            items,
            next_cursor,
        }))
    }
}

fn page_from_comment_rows(
    rows: Vec<CommentRow>,
    page_size: u32,
) -> Result<CommentReadOutcome<CommentPage>, DbError> {
    let mut items = rows
        .into_iter()
        .map(PaperComment::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    let has_more = items.len() > usize::try_from(page_size).unwrap_or(usize::MAX);
    if has_more {
        items.pop();
    }
    let next_cursor = has_more.then(|| {
        let last = items.last().expect("a page with more rows is non-empty");
        CreatedAtCursor {
            created_at: last.created_at,
            id: last.id,
        }
        .encode()
    });
    Ok(CommentReadOutcome::Found(CommentPage {
        items,
        next_cursor,
    }))
}

enum FailedMutation {
    NotFound,
    NotAuthor,
    Deleted { comment: PaperComment },
    Current { version: i32 },
}

async fn classify_failed_mutation(
    transaction: &mut Transaction<'_, Postgres>,
    author_user_id: AuthenticatedUserId,
    comment_id: Uuid,
) -> Result<FailedMutation, DbError> {
    let row = sqlx::query_as::<_, CommentRow>(&format!(
        r"
        SELECT {COMMENT_COLUMNS}
        FROM paper_comments comments
        JOIN users ON users.id = comments.author_user_id
        WHERE comments.id = $1
        "
    ))
    .bind(comment_id)
    .fetch_optional(&mut **transaction)
    .await?;
    let Some(row) = row else {
        return Ok(FailedMutation::NotFound);
    };
    if row.author_user_id != author_user_id.into_inner() {
        return Ok(FailedMutation::NotAuthor);
    }
    let comment = PaperComment::try_from(row)?;
    if comment.status == CommentStatus::Deleted {
        Ok(FailedMutation::Deleted { comment })
    } else {
        Ok(FailedMutation::Current {
            version: comment.version,
        })
    }
}

async fn load_comment_by_request(
    transaction: &mut Transaction<'_, Postgres>,
    author_user_id: AuthenticatedUserId,
    client_request_id: Uuid,
) -> Result<Option<PaperComment>, DbError> {
    sqlx::query_as::<_, CommentRow>(&format!(
        r"
        SELECT {COMMENT_COLUMNS}
        FROM paper_comments comments
        JOIN users ON users.id = comments.author_user_id
        WHERE comments.author_user_id = $1 AND comments.client_request_id = $2
        "
    ))
    .bind(author_user_id.into_inner())
    .bind(client_request_id)
    .fetch_optional(&mut **transaction)
    .await?
    .map(PaperComment::try_from)
    .transpose()
}

async fn insert_system_event(
    transaction: &mut Transaction<'_, Postgres>,
    comment_id: Uuid,
    action: &str,
    reason_code: Option<&str>,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO comment_moderation_events (
            comment_id,
            actor_kind,
            action,
            reason_code
        )
        VALUES ($1, 'system', $2, $3)
        ",
    )
    .bind(comment_id)
    .bind(action)
    .bind(reason_code)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn account_status(
    pool: &PgPool,
    user_id: AuthenticatedUserId,
) -> Result<Option<AccountStatus>, DbError> {
    sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1")
        .bind(user_id.into_inner())
        .fetch_optional(pool)
        .await?
        .map(|value| {
            AccountStatus::from_str(&value).map_err(|error| DbError::InvalidData(error.to_string()))
        })
        .transpose()
}

async fn lock_account_status(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<AccountStatus>, DbError> {
    sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1 FOR SHARE")
        .bind(user_id.into_inner())
        .fetch_optional(&mut **transaction)
        .await?
        .map(|value| {
            AccountStatus::from_str(&value).map_err(|error| DbError::InvalidData(error.to_string()))
        })
        .transpose()
}

async fn lock_account_eligibility(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<AccountEligibilityRow>, DbError> {
    sqlx::query_as::<_, AccountEligibilityRow>(
        r"
        SELECT
            status,
            handle,
            terms_version,
            terms_accepted_at,
            community_guidelines_version,
            community_guidelines_accepted_at
        FROM users
        WHERE id = $1
        FOR SHARE
        ",
    )
    .bind(user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
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
