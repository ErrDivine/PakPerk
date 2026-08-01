use std::str::FromStr;

use chrono::{DateTime, Utc};
use domain::{
    AccountStatus, AuthenticatedUserId, CommentBody, CommentReportReason, CommentStatus, PaperId,
    ReportDetail,
};
use serde_json::json;
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::DbError;
use crate::CreatedAtCursor;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoredAdminActor {
    User(AuthenticatedUserId),
    Label(String),
}

impl StoredAdminActor {
    fn user_id(&self) -> Option<Uuid> {
        match self {
            Self::User(user_id) => Some(user_id.into_inner()),
            Self::Label(_) => None,
        }
    }

    fn label(&self) -> Option<&str> {
        match self {
            Self::User(_) => None,
            Self::Label(label) => Some(label),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdminCommentAction {
    Hide,
    Restore,
    Delete,
}

impl AdminCommentAction {
    const fn event_action(self) -> &'static str {
        match self {
            Self::Hide => "admin_hide",
            Self::Restore => "admin_restore",
            Self::Delete => "admin_delete",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdminReportResolution {
    Reviewed,
    Actioned,
    Dismissed,
}

impl AdminReportResolution {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Reviewed => "reviewed",
            Self::Actioned => "actioned",
            Self::Dismissed => "dismissed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredModerationQueueRecord {
    pub comment_id: Uuid,
    pub paper_id: PaperId,
    pub author_user_id: AuthenticatedUserId,
    pub status: CommentStatus,
    pub version: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub open_report_count: i64,
    pub oldest_open_report_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredModerationQueuePage {
    pub items: Vec<StoredModerationQueueRecord>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredReportQueueRecord {
    pub report_id: Uuid,
    pub comment_id: Uuid,
    pub paper_id: PaperId,
    pub author_user_id: AuthenticatedUserId,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub status: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredReportQueuePage {
    pub items: Vec<StoredReportQueueRecord>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredUserReportQueueRecord {
    pub report_id: Uuid,
    pub reported_user_id: AuthenticatedUserId,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub status: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredUserReportQueuePage {
    pub items: Vec<StoredUserReportQueueRecord>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredUserReportInspection {
    pub report_id: Uuid,
    pub reported_user_id: AuthenticatedUserId,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub detail: Option<ReportDetail>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub reviewed_at: Option<DateTime<Utc>>,
    pub reviewed_by: Option<AuthenticatedUserId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredInspectionReport {
    pub report_id: Uuid,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub detail: Option<ReportDetail>,
    pub status: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredModerationInspection {
    pub comment_id: Uuid,
    pub paper_id: PaperId,
    pub author_user_id: AuthenticatedUserId,
    pub body: CommentBody,
    pub status: CommentStatus,
    pub moderation_reason: Option<String>,
    pub version: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub reports: Vec<StoredInspectionReport>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdminCommentOutcome {
    Updated(StoredModerationInspection),
    NotFound,
    AlreadyInState(StoredModerationInspection),
    InvalidTransition,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdminReportOutcome {
    Updated { report_id: Uuid, status: String },
    NotFound,
    AlreadyInState { report_id: Uuid, status: String },
    ResolutionConflict { current_status: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdminUserStatusOutcome {
    Updated(AccountStatus),
    NotFound,
    AlreadyInState(AccountStatus),
    DeletionState(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub struct StoredReportAgeMetrics {
    pub open_count: i64,
    pub oldest_open_age_seconds: Option<f64>,
    pub open_over_24h: i64,
    pub open_over_72h: i64,
}

#[derive(Debug, FromRow)]
struct ModerationQueueRow {
    comment_id: Uuid,
    paper_id: Uuid,
    author_user_id: Uuid,
    status: String,
    version: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    open_report_count: i64,
    oldest_open_report_at: Option<DateTime<Utc>>,
}

impl TryFrom<ModerationQueueRow> for StoredModerationQueueRecord {
    type Error = DbError;

    fn try_from(row: ModerationQueueRow) -> Result<Self, Self::Error> {
        Ok(Self {
            comment_id: row.comment_id,
            paper_id: row.paper_id,
            author_user_id: AuthenticatedUserId::new(row.author_user_id),
            status: CommentStatus::from_str(&row.status)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            version: row.version,
            created_at: row.created_at,
            updated_at: row.updated_at,
            open_report_count: row.open_report_count,
            oldest_open_report_at: row.oldest_open_report_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct ReportQueueRow {
    report_id: Uuid,
    comment_id: Uuid,
    paper_id: Uuid,
    author_user_id: Uuid,
    reporter_user_id: Uuid,
    reason: String,
    status: String,
    created_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct UserReportQueueRow {
    report_id: Uuid,
    reported_user_id: Uuid,
    reporter_user_id: Uuid,
    reason: String,
    status: String,
    created_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct UserReportInspectionRow {
    report_id: Uuid,
    reported_user_id: Uuid,
    reporter_user_id: Uuid,
    reason: String,
    detail: Option<String>,
    status: String,
    created_at: DateTime<Utc>,
    reviewed_at: Option<DateTime<Utc>>,
    reviewed_by: Option<Uuid>,
}

impl TryFrom<ReportQueueRow> for StoredReportQueueRecord {
    type Error = DbError;

    fn try_from(row: ReportQueueRow) -> Result<Self, Self::Error> {
        Ok(Self {
            report_id: row.report_id,
            comment_id: row.comment_id,
            paper_id: row.paper_id,
            author_user_id: AuthenticatedUserId::new(row.author_user_id),
            reporter_user_id: AuthenticatedUserId::new(row.reporter_user_id),
            reason: CommentReportReason::from_str(&row.reason)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            status: row.status,
            created_at: row.created_at,
        })
    }
}

impl TryFrom<UserReportQueueRow> for StoredUserReportQueueRecord {
    type Error = DbError;

    fn try_from(row: UserReportQueueRow) -> Result<Self, Self::Error> {
        Ok(Self {
            report_id: row.report_id,
            reported_user_id: AuthenticatedUserId::new(row.reported_user_id),
            reporter_user_id: AuthenticatedUserId::new(row.reporter_user_id),
            reason: CommentReportReason::from_str(&row.reason)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            status: row.status,
            created_at: row.created_at,
        })
    }
}

impl TryFrom<UserReportInspectionRow> for StoredUserReportInspection {
    type Error = DbError;

    fn try_from(row: UserReportInspectionRow) -> Result<Self, Self::Error> {
        Ok(Self {
            report_id: row.report_id,
            reported_user_id: AuthenticatedUserId::new(row.reported_user_id),
            reporter_user_id: AuthenticatedUserId::new(row.reporter_user_id),
            reason: CommentReportReason::from_str(&row.reason)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            detail: row
                .detail
                .map(|detail| ReportDetail::parse(&detail))
                .transpose()
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            status: row.status,
            created_at: row.created_at,
            reviewed_at: row.reviewed_at,
            reviewed_by: row.reviewed_by.map(AuthenticatedUserId::new),
        })
    }
}

#[derive(FromRow)]
struct InspectionRow {
    comment_id: Uuid,
    paper_id: Uuid,
    author_user_id: Uuid,
    body: String,
    status: String,
    moderation_reason: Option<String>,
    version: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(FromRow)]
struct InspectionReportRow {
    report_id: Uuid,
    reporter_user_id: Uuid,
    reason: String,
    detail: Option<String>,
    status: String,
    created_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct MetricsRow {
    open_count: i64,
    oldest_open_age_seconds: Option<f64>,
    open_over_24h: i64,
    open_over_72h: i64,
}

#[derive(Clone)]
pub struct ModerationRepository {
    pool: PgPool,
}

impl ModerationRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn list_pending(
        &self,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<StoredModerationQueuePage, DbError> {
        let cursor = cursor
            .map(CreatedAtCursor::decode)
            .transpose()
            .map_err(|_| DbError::InvalidData("moderation cursor is invalid".to_owned()))?;
        let page_size = limit.max(1);
        let rows = sqlx::query_as::<_, ModerationQueueRow>(
            r"
            SELECT
                comments.id AS comment_id,
                comments.paper_id,
                comments.author_user_id,
                comments.status,
                comments.version,
                comments.created_at,
                comments.updated_at,
                count(reports.id) FILTER (WHERE reports.status = 'open') AS open_report_count,
                min(reports.created_at) FILTER (WHERE reports.status = 'open')
                    AS oldest_open_report_at
            FROM paper_comments comments
            LEFT JOIN comment_reports reports ON reports.comment_id = comments.id
            WHERE comments.status = 'pending_review'
              AND (
                    $1::timestamptz IS NULL
                    OR (comments.created_at, comments.id) > ($1, $2)
              )
            GROUP BY comments.id
            ORDER BY comments.created_at, comments.id
            LIMIT $3
            ",
        )
        .bind(cursor.map(|value| value.created_at))
        .bind(cursor.map(|value| value.id))
        .bind(i64::from(page_size) + 1)
        .fetch_all(&self.pool)
        .await?;
        let mut items = rows
            .into_iter()
            .map(StoredModerationQueueRecord::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = items.len() > usize::try_from(page_size).unwrap_or(usize::MAX);
        if has_more {
            items.pop();
        }
        let next_cursor = has_more.then(|| {
            let last = items.last().expect("a page with more items is non-empty");
            CreatedAtCursor {
                created_at: last.created_at,
                id: last.comment_id,
            }
            .encode()
        });
        Ok(StoredModerationQueuePage { items, next_cursor })
    }

    pub async fn list_reports(
        &self,
        status: &str,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<StoredReportQueuePage, DbError> {
        if !matches!(status, "open" | "reviewed" | "actioned" | "dismissed") {
            return Err(DbError::InvalidData(
                "report status filter is invalid".to_owned(),
            ));
        }
        let cursor = cursor
            .map(CreatedAtCursor::decode)
            .transpose()
            .map_err(|_| DbError::InvalidData("report cursor is invalid".to_owned()))?;
        let page_size = limit.max(1);
        let rows = sqlx::query_as::<_, ReportQueueRow>(
            r"
            SELECT
                reports.id AS report_id,
                reports.comment_id,
                comments.paper_id,
                comments.author_user_id,
                reports.reporter_user_id,
                reports.reason,
                reports.status,
                reports.created_at
            FROM comment_reports reports
            JOIN paper_comments comments ON comments.id = reports.comment_id
            WHERE reports.status = $1
              AND (
                    $2::timestamptz IS NULL
                    OR (reports.created_at, reports.id) > ($2, $3)
              )
            ORDER BY reports.created_at, reports.id
            LIMIT $4
            ",
        )
        .bind(status)
        .bind(cursor.map(|value| value.created_at))
        .bind(cursor.map(|value| value.id))
        .bind(i64::from(page_size) + 1)
        .fetch_all(&self.pool)
        .await?;
        let mut items = rows
            .into_iter()
            .map(StoredReportQueueRecord::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = items.len() > usize::try_from(page_size).unwrap_or(usize::MAX);
        if has_more {
            items.pop();
        }
        let next_cursor = has_more.then(|| {
            let last = items.last().expect("a page with more items is non-empty");
            CreatedAtCursor {
                created_at: last.created_at,
                id: last.report_id,
            }
            .encode()
        });
        Ok(StoredReportQueuePage { items, next_cursor })
    }

    pub async fn list_user_reports(
        &self,
        status: &str,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<StoredUserReportQueuePage, DbError> {
        if !matches!(status, "open" | "reviewed" | "actioned" | "dismissed") {
            return Err(DbError::InvalidData(
                "user-report status filter is invalid".to_owned(),
            ));
        }
        let cursor = cursor
            .map(CreatedAtCursor::decode)
            .transpose()
            .map_err(|_| DbError::InvalidData("user-report cursor is invalid".to_owned()))?;
        let page_size = limit.max(1);
        let rows = sqlx::query_as::<_, UserReportQueueRow>(
            r"
            SELECT
                id AS report_id,
                reported_user_id,
                reporter_user_id,
                reason,
                status,
                created_at
            FROM user_reports
            WHERE status = $1
              AND (
                    $2::timestamptz IS NULL
                    OR (created_at, id) > ($2, $3)
              )
            ORDER BY created_at, id
            LIMIT $4
            ",
        )
        .bind(status)
        .bind(cursor.map(|value| value.created_at))
        .bind(cursor.map(|value| value.id))
        .bind(i64::from(page_size) + 1)
        .fetch_all(&self.pool)
        .await?;
        let mut items = rows
            .into_iter()
            .map(StoredUserReportQueueRecord::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = items.len() > usize::try_from(page_size).unwrap_or(usize::MAX);
        if has_more {
            items.pop();
        }
        let next_cursor = has_more.then(|| {
            let last = items.last().expect("a page with more items is non-empty");
            CreatedAtCursor {
                created_at: last.created_at,
                id: last.report_id,
            }
            .encode()
        });
        Ok(StoredUserReportQueuePage { items, next_cursor })
    }

    pub async fn inspect_user_report(
        &self,
        report_id: Uuid,
    ) -> Result<Option<StoredUserReportInspection>, DbError> {
        sqlx::query_as::<_, UserReportInspectionRow>(
            r"
            SELECT
                id AS report_id,
                reported_user_id,
                reporter_user_id,
                reason,
                detail,
                status,
                created_at,
                reviewed_at,
                reviewed_by
            FROM user_reports
            WHERE id = $1
            ",
        )
        .bind(report_id)
        .fetch_optional(&self.pool)
        .await?
        .map(StoredUserReportInspection::try_from)
        .transpose()
    }

    pub async fn inspect(
        &self,
        comment_id: Uuid,
    ) -> Result<Option<StoredModerationInspection>, DbError> {
        let Some(row) = sqlx::query_as::<_, InspectionRow>(
            r"
            SELECT
                id AS comment_id,
                paper_id,
                author_user_id,
                body,
                status,
                moderation_reason,
                version,
                created_at,
                updated_at
            FROM paper_comments
            WHERE id = $1
            ",
        )
        .bind(comment_id)
        .fetch_optional(&self.pool)
        .await?
        else {
            return Ok(None);
        };
        let reports = sqlx::query_as::<_, InspectionReportRow>(
            r"
            SELECT
                id AS report_id,
                reporter_user_id,
                reason,
                detail,
                status,
                created_at
            FROM comment_reports
            WHERE comment_id = $1
            ORDER BY created_at, id
            ",
        )
        .bind(comment_id)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(|report| {
            Ok(StoredInspectionReport {
                report_id: report.report_id,
                reporter_user_id: AuthenticatedUserId::new(report.reporter_user_id),
                reason: CommentReportReason::from_str(&report.reason)
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
                detail: report
                    .detail
                    .map(|detail| ReportDetail::parse(&detail))
                    .transpose()
                    .map_err(|error| DbError::InvalidData(error.to_string()))?,
                status: report.status,
                created_at: report.created_at,
            })
        })
        .collect::<Result<Vec<_>, DbError>>()?;
        Ok(Some(StoredModerationInspection {
            comment_id: row.comment_id,
            paper_id: row.paper_id,
            author_user_id: AuthenticatedUserId::new(row.author_user_id),
            body: CommentBody::parse(&row.body)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            status: CommentStatus::from_str(&row.status)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            moderation_reason: row.moderation_reason,
            version: row.version,
            created_at: row.created_at,
            updated_at: row.updated_at,
            reports,
        }))
    }

    pub async fn moderate_comment(
        &self,
        comment_id: Uuid,
        actor: &StoredAdminActor,
        action: AdminCommentAction,
        reason_code: &str,
    ) -> Result<AdminCommentOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        lock_active_admin_actor(&mut transaction, actor).await?;
        sqlx::query(
            "SELECT pg_advisory_xact_lock(hashtextextended('moderate-comment:' || $1::text, 0))",
        )
        .bind(comment_id)
        .execute(&mut *transaction)
        .await?;
        let current_status = sqlx::query_scalar::<_, String>(
            "SELECT status FROM paper_comments WHERE id = $1 FOR UPDATE",
        )
        .bind(comment_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let Some(current_status) = current_status else {
            return Ok(AdminCommentOutcome::NotFound);
        };
        let target_status = match action {
            AdminCommentAction::Hide => "hidden",
            AdminCommentAction::Restore => "published",
            AdminCommentAction::Delete => "deleted",
        };
        if current_status == "deleted" && target_status != "deleted" {
            return Ok(AdminCommentOutcome::InvalidTransition);
        }
        if current_status == target_status {
            transaction.commit().await?;
            return self
                .inspect(comment_id)
                .await?
                .map(AdminCommentOutcome::AlreadyInState)
                .ok_or_else(|| DbError::InvalidData("locked comment disappeared".to_owned()));
        }
        sqlx::query(
            r"
            UPDATE paper_comments
            SET status = $2,
                moderation_reason = $3,
                version = version + 1,
                updated_at = statement_timestamp(),
                deleted_at = CASE WHEN $2 = 'deleted' THEN statement_timestamp() ELSE NULL END
            WHERE id = $1
            ",
        )
        .bind(comment_id)
        .bind(target_status)
        .bind(reason_code)
        .execute(&mut *transaction)
        .await?;
        insert_admin_event(
            &mut transaction,
            Some(comment_id),
            None,
            actor,
            action.event_action(),
            Some(reason_code),
            serde_json::Value::Object(serde_json::Map::new()),
        )
        .await?;
        transaction.commit().await?;
        self.inspect(comment_id)
            .await?
            .map(AdminCommentOutcome::Updated)
            .ok_or_else(|| DbError::InvalidData("moderated comment disappeared".to_owned()))
    }

    pub async fn resolve_report(
        &self,
        report_id: Uuid,
        actor: &StoredAdminActor,
        resolution: AdminReportResolution,
        reason_code: &str,
    ) -> Result<AdminReportOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        lock_active_admin_actor(&mut transaction, actor).await?;
        let current = sqlx::query_as::<_, (Uuid, String)>(
            "SELECT comment_id, status FROM comment_reports WHERE id = $1 FOR UPDATE",
        )
        .bind(report_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let Some((comment_id, current_status)) = current else {
            return Ok(AdminReportOutcome::NotFound);
        };
        let target = resolution.as_str();
        if current_status == target {
            transaction.commit().await?;
            return Ok(AdminReportOutcome::AlreadyInState {
                report_id,
                status: current_status,
            });
        }
        if current_status != "open" {
            return Ok(AdminReportOutcome::ResolutionConflict { current_status });
        }
        sqlx::query(
            r"
            UPDATE comment_reports
            SET status = $2,
                reviewed_at = statement_timestamp(),
                reviewed_by = $3
            WHERE id = $1
            ",
        )
        .bind(report_id)
        .bind(target)
        .bind(actor.user_id())
        .execute(&mut *transaction)
        .await?;
        insert_admin_event(
            &mut transaction,
            Some(comment_id),
            None,
            actor,
            "report_resolved",
            Some(reason_code),
            json!({"report_id": report_id, "resolution": target}),
        )
        .await?;
        transaction.commit().await?;
        Ok(AdminReportOutcome::Updated {
            report_id,
            status: target.to_owned(),
        })
    }

    pub async fn resolve_user_report(
        &self,
        report_id: Uuid,
        actor: &StoredAdminActor,
        resolution: AdminReportResolution,
        reason_code: &str,
    ) -> Result<AdminReportOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        lock_active_admin_actor(&mut transaction, actor).await?;
        let current = sqlx::query_as::<_, (Uuid, String)>(
            "SELECT reported_user_id, status FROM user_reports WHERE id = $1 FOR UPDATE",
        )
        .bind(report_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let Some((reported_user_id, current_status)) = current else {
            return Ok(AdminReportOutcome::NotFound);
        };
        let target = resolution.as_str();
        if current_status == target {
            transaction.commit().await?;
            return Ok(AdminReportOutcome::AlreadyInState {
                report_id,
                status: current_status,
            });
        }
        if current_status != "open" {
            return Ok(AdminReportOutcome::ResolutionConflict { current_status });
        }
        sqlx::query(
            r"
            UPDATE user_reports
            SET status = $2,
                reviewed_at = statement_timestamp(),
                reviewed_by = $3
            WHERE id = $1
            ",
        )
        .bind(report_id)
        .bind(target)
        .bind(actor.user_id())
        .execute(&mut *transaction)
        .await?;
        insert_admin_event(
            &mut transaction,
            None,
            Some(AuthenticatedUserId::new(reported_user_id)),
            actor,
            "user_report_resolved",
            Some(reason_code),
            json!({"report_id": report_id, "resolution": target}),
        )
        .await?;
        transaction.commit().await?;
        Ok(AdminReportOutcome::Updated {
            report_id,
            status: target.to_owned(),
        })
    }

    pub async fn set_user_suspended(
        &self,
        target_user_id: AuthenticatedUserId,
        actor: &StoredAdminActor,
        suspended: bool,
        reason_code: &str,
    ) -> Result<AdminUserStatusOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        lock_active_admin_actor(&mut transaction, actor).await?;
        let current =
            sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1 FOR UPDATE")
                .bind(target_user_id.into_inner())
                .fetch_optional(&mut *transaction)
                .await?;
        let Some(current) = current else {
            return Ok(AdminUserStatusOutcome::NotFound);
        };
        let current = AccountStatus::from_str(&current)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if matches!(
            current,
            AccountStatus::DeletionPending | AccountStatus::Deleted
        ) {
            return Ok(AdminUserStatusOutcome::DeletionState(current));
        }
        let target = if suspended {
            AccountStatus::Suspended
        } else {
            AccountStatus::Active
        };
        if current == target {
            transaction.commit().await?;
            return Ok(AdminUserStatusOutcome::AlreadyInState(current));
        }
        sqlx::query(
            "UPDATE users SET status = $2, updated_at = statement_timestamp() WHERE id = $1",
        )
        .bind(target_user_id.into_inner())
        .bind(target.as_str())
        .execute(&mut *transaction)
        .await?;
        insert_admin_event(
            &mut transaction,
            None,
            Some(target_user_id),
            actor,
            if suspended {
                "user_suspended"
            } else {
                "user_reinstated"
            },
            Some(reason_code),
            serde_json::Value::Object(serde_json::Map::new()),
        )
        .await?;
        transaction.commit().await?;
        Ok(AdminUserStatusOutcome::Updated(target))
    }

    pub async fn report_age_metrics(&self) -> Result<StoredReportAgeMetrics, DbError> {
        let row = sqlx::query_as::<_, MetricsRow>(
            r"
            SELECT
                count(*) FILTER (WHERE status = 'open') AS open_count,
                EXTRACT(EPOCH FROM (
                    statement_timestamp() - min(created_at) FILTER (WHERE status = 'open')
                ))::double precision AS oldest_open_age_seconds,
                count(*) FILTER (
                    WHERE status = 'open'
                      AND created_at <= statement_timestamp() - interval '24 hours'
                ) AS open_over_24h,
                count(*) FILTER (
                    WHERE status = 'open'
                      AND created_at <= statement_timestamp() - interval '72 hours'
                ) AS open_over_72h
            FROM (
                SELECT status, created_at FROM comment_reports
                UNION ALL
                SELECT status, created_at FROM user_reports
            ) reports
            ",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(StoredReportAgeMetrics {
            open_count: row.open_count,
            oldest_open_age_seconds: row.oldest_open_age_seconds,
            open_over_24h: row.open_over_24h,
            open_over_72h: row.open_over_72h,
        })
    }
}

/// Serializes a user-backed administrator with account erasure before any
/// target row is locked or an audit event is inserted. Without this lock, an
/// already-authenticated request could append a fresh `actor_user_id` after
/// the deletion transaction had pseudonymized the existing audit history.
async fn lock_active_admin_actor(
    transaction: &mut Transaction<'_, Postgres>,
    actor: &StoredAdminActor,
) -> Result<(), DbError> {
    let StoredAdminActor::User(actor_id) = actor else {
        return Ok(());
    };
    let status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE id = $1 FOR SHARE")
            .bind(actor_id.into_inner())
            .fetch_optional(&mut **transaction)
            .await?;
    match status.as_deref() {
        Some("active") => Ok(()),
        Some("deletion_pending" | "deleted") | None => Err(DbError::IdentityTombstoned),
        Some(_) => Err(DbError::InvalidData(
            "user-backed admin actor is not active".to_owned(),
        )),
    }
}

#[allow(clippy::too_many_arguments)]
async fn insert_admin_event(
    transaction: &mut Transaction<'_, Postgres>,
    comment_id: Option<Uuid>,
    target_user_id: Option<AuthenticatedUserId>,
    actor: &StoredAdminActor,
    action: &str,
    reason_code: Option<&str>,
    metadata: serde_json::Value,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO comment_moderation_events (
            comment_id,
            target_user_id,
            actor_kind,
            actor_user_id,
            actor_label,
            action,
            reason_code,
            metadata
        )
        VALUES ($1, $2, 'admin', $3, $4, $5, $6, $7)
        ",
    )
    .bind(comment_id)
    .bind(target_user_id.map(AuthenticatedUserId::into_inner))
    .bind(actor.user_id())
    .bind(actor.label())
    .bind(action)
    .bind(reason_code)
    .bind(metadata)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}
