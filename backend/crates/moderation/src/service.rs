use db::{
    AdminCommentAction, AdminCommentOutcome, AdminReportOutcome, AdminReportResolution,
    AdminUserStatusOutcome, DbError, ModerationRepository, StoredAdminActor,
    StoredModerationInspection, StoredUserReportInspection,
};
use domain::{
    AccountStatus, AuthenticatedUserId, CommentBody, CommentReportReason, CommentStatus, PaperId,
    ReportDetail,
};
use serde::Serialize;
use thiserror::Error;
use uuid::Uuid;

use crate::ModerationReasonCode;

const DEFAULT_MAXIMUM_PAGE_SIZE: u32 = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminActor(StoredAdminActor);

impl AdminActor {
    #[must_use]
    pub const fn local(user_id: AuthenticatedUserId) -> Self {
        Self(StoredAdminActor::User(user_id))
    }

    const fn stored(&self) -> &StoredAdminActor {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ModerationQueueRecord {
    pub comment_id: Uuid,
    pub paper_id: PaperId,
    pub author_user_id: AuthenticatedUserId,
    pub status: CommentStatus,
    pub version: i32,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
    pub open_report_count: i64,
    pub oldest_open_report_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ModerationQueuePage {
    pub items: Vec<ModerationQueueRecord>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReportQueueRecord {
    pub report_id: Uuid,
    pub comment_id: Uuid,
    pub paper_id: PaperId,
    pub author_user_id: AuthenticatedUserId,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReportQueuePage {
    pub items: Vec<ReportQueueRecord>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UserReportQueueRecord {
    pub report_id: Uuid,
    pub reported_user_id: AuthenticatedUserId,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UserReportQueuePage {
    pub items: Vec<UserReportQueueRecord>,
    pub next_cursor: Option<String>,
}

/// Full reporter context is available only from the explicit operator inspect
/// command; the validated detail remains redacted from Debug output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UserReportInspection {
    pub report_id: Uuid,
    pub reported_user_id: AuthenticatedUserId,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub detail: Option<ReportDetail>,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub reviewed_at: Option<chrono::DateTime<chrono::Utc>>,
    pub reviewed_by: Option<AuthenticatedUserId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InspectionReport {
    pub report_id: Uuid,
    pub reporter_user_id: AuthenticatedUserId,
    pub reason: CommentReportReason,
    pub detail: Option<ReportDetail>,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// Full UGC is serializable only from the explicit inspect command. `Debug`
/// remains safe because the validated body/detail wrappers redact themselves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ModerationInspection {
    pub comment_id: Uuid,
    pub paper_id: PaperId,
    pub author_user_id: AuthenticatedUserId,
    pub body: CommentBody,
    pub status: CommentStatus,
    pub moderation_reason: Option<String>,
    pub version: i32,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
    pub reports: Vec<InspectionReport>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ModerationActionResult {
    pub inspection: ModerationInspection,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReportResolutionResult {
    pub report_id: Uuid,
    pub status: String,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UserStatusResult {
    pub user_id: AuthenticatedUserId,
    pub status: AccountStatus,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReportAgeMetrics {
    pub open_count: i64,
    pub oldest_open_age_seconds: Option<f64>,
    pub open_over_24h: i64,
    pub open_over_72h: i64,
}

#[derive(Debug, Error)]
pub enum ModerationServiceError {
    #[error("moderation page limit must be positive")]
    InvalidPageLimit,
    #[error("moderation target was not found")]
    NotFound,
    #[error("moderation action conflicts with current state")]
    Conflict,
    #[error("account deletion state cannot be changed by moderation")]
    AccountDeletionState,
    #[error("moderation storage is unavailable")]
    Storage(#[from] DbError),
    #[error("moderation reason is invalid")]
    InvalidReason,
}

#[derive(Clone)]
pub struct ModerationService {
    repository: ModerationRepository,
    maximum_page_size: u32,
}

impl ModerationService {
    #[must_use]
    pub const fn new(repository: ModerationRepository) -> Self {
        Self {
            repository,
            maximum_page_size: DEFAULT_MAXIMUM_PAGE_SIZE,
        }
    }

    pub fn with_maximum_page_size(
        repository: ModerationRepository,
        maximum_page_size: u32,
    ) -> Result<Self, ModerationServiceError> {
        if maximum_page_size == 0 {
            return Err(ModerationServiceError::InvalidPageLimit);
        }
        Ok(Self {
            repository,
            maximum_page_size,
        })
    }

    pub async fn list_pending(
        &self,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<ModerationQueuePage, ModerationServiceError> {
        let limit = self.page_limit(limit)?;
        let page = self.repository.list_pending(cursor, limit).await?;
        Ok(ModerationQueuePage {
            items: page
                .items
                .into_iter()
                .map(|item| ModerationQueueRecord {
                    comment_id: item.comment_id,
                    paper_id: item.paper_id,
                    author_user_id: item.author_user_id,
                    status: item.status,
                    version: item.version,
                    created_at: item.created_at,
                    updated_at: item.updated_at,
                    open_report_count: item.open_report_count,
                    oldest_open_report_at: item.oldest_open_report_at,
                })
                .collect(),
            next_cursor: page.next_cursor,
        })
    }

    pub async fn list_reports(
        &self,
        status: &str,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<ReportQueuePage, ModerationServiceError> {
        let limit = self.page_limit(limit)?;
        let page = self.repository.list_reports(status, cursor, limit).await?;
        Ok(ReportQueuePage {
            items: page
                .items
                .into_iter()
                .map(|item| ReportQueueRecord {
                    report_id: item.report_id,
                    comment_id: item.comment_id,
                    paper_id: item.paper_id,
                    author_user_id: item.author_user_id,
                    reporter_user_id: item.reporter_user_id,
                    reason: item.reason,
                    status: item.status,
                    created_at: item.created_at,
                })
                .collect(),
            next_cursor: page.next_cursor,
        })
    }

    pub async fn list_user_reports(
        &self,
        status: &str,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<UserReportQueuePage, ModerationServiceError> {
        let limit = self.page_limit(limit)?;
        let page = self
            .repository
            .list_user_reports(status, cursor, limit)
            .await?;
        Ok(UserReportQueuePage {
            items: page
                .items
                .into_iter()
                .map(|item| UserReportQueueRecord {
                    report_id: item.report_id,
                    reported_user_id: item.reported_user_id,
                    reporter_user_id: item.reporter_user_id,
                    reason: item.reason,
                    status: item.status,
                    created_at: item.created_at,
                })
                .collect(),
            next_cursor: page.next_cursor,
        })
    }

    pub async fn inspect_user_report(
        &self,
        report_id: Uuid,
    ) -> Result<UserReportInspection, ModerationServiceError> {
        self.repository
            .inspect_user_report(report_id)
            .await?
            .map(map_user_report_inspection)
            .ok_or(ModerationServiceError::NotFound)
    }

    pub async fn inspect(
        &self,
        comment_id: Uuid,
    ) -> Result<ModerationInspection, ModerationServiceError> {
        self.repository
            .inspect(comment_id)
            .await?
            .map(map_inspection)
            .ok_or(ModerationServiceError::NotFound)
    }

    pub async fn hide(
        &self,
        actor: &AdminActor,
        comment_id: Uuid,
        reason_code: &str,
    ) -> Result<ModerationActionResult, ModerationServiceError> {
        self.comment_action(actor, comment_id, AdminCommentAction::Hide, reason_code)
            .await
    }

    pub async fn restore(
        &self,
        actor: &AdminActor,
        comment_id: Uuid,
        reason_code: &str,
    ) -> Result<ModerationActionResult, ModerationServiceError> {
        self.comment_action(actor, comment_id, AdminCommentAction::Restore, reason_code)
            .await
    }

    pub async fn delete(
        &self,
        actor: &AdminActor,
        comment_id: Uuid,
        reason_code: &str,
    ) -> Result<ModerationActionResult, ModerationServiceError> {
        self.comment_action(actor, comment_id, AdminCommentAction::Delete, reason_code)
            .await
    }

    pub async fn resolve_report(
        &self,
        actor: &AdminActor,
        report_id: Uuid,
        resolution: AdminReportResolution,
        reason_code: &str,
    ) -> Result<ReportResolutionResult, ModerationServiceError> {
        validate_reason(reason_code)?;
        match self
            .repository
            .resolve_report(report_id, actor.stored(), resolution, reason_code)
            .await?
        {
            AdminReportOutcome::Updated { report_id, status } => Ok(ReportResolutionResult {
                report_id,
                status,
                replayed: false,
            }),
            AdminReportOutcome::AlreadyInState { report_id, status } => {
                Ok(ReportResolutionResult {
                    report_id,
                    status,
                    replayed: true,
                })
            }
            AdminReportOutcome::NotFound => Err(ModerationServiceError::NotFound),
            AdminReportOutcome::ResolutionConflict { .. } => Err(ModerationServiceError::Conflict),
        }
    }

    pub async fn resolve_user_report(
        &self,
        actor: &AdminActor,
        report_id: Uuid,
        resolution: AdminReportResolution,
        reason_code: &str,
    ) -> Result<ReportResolutionResult, ModerationServiceError> {
        validate_reason(reason_code)?;
        match self
            .repository
            .resolve_user_report(report_id, actor.stored(), resolution, reason_code)
            .await?
        {
            AdminReportOutcome::Updated { report_id, status } => Ok(ReportResolutionResult {
                report_id,
                status,
                replayed: false,
            }),
            AdminReportOutcome::AlreadyInState { report_id, status } => {
                Ok(ReportResolutionResult {
                    report_id,
                    status,
                    replayed: true,
                })
            }
            AdminReportOutcome::NotFound => Err(ModerationServiceError::NotFound),
            AdminReportOutcome::ResolutionConflict { .. } => Err(ModerationServiceError::Conflict),
        }
    }

    pub async fn suspend_user(
        &self,
        actor: &AdminActor,
        user_id: AuthenticatedUserId,
        reason_code: &str,
    ) -> Result<UserStatusResult, ModerationServiceError> {
        self.user_status(actor, user_id, true, reason_code).await
    }

    pub async fn reinstate_user(
        &self,
        actor: &AdminActor,
        user_id: AuthenticatedUserId,
        reason_code: &str,
    ) -> Result<UserStatusResult, ModerationServiceError> {
        self.user_status(actor, user_id, false, reason_code).await
    }

    pub async fn report_age_metrics(&self) -> Result<ReportAgeMetrics, ModerationServiceError> {
        let metrics = self.repository.report_age_metrics().await?;
        Ok(ReportAgeMetrics {
            open_count: metrics.open_count,
            oldest_open_age_seconds: metrics.oldest_open_age_seconds,
            open_over_24h: metrics.open_over_24h,
            open_over_72h: metrics.open_over_72h,
        })
    }

    async fn comment_action(
        &self,
        actor: &AdminActor,
        comment_id: Uuid,
        action: AdminCommentAction,
        reason_code: &str,
    ) -> Result<ModerationActionResult, ModerationServiceError> {
        validate_reason(reason_code)?;
        match self
            .repository
            .moderate_comment(comment_id, actor.stored(), action, reason_code)
            .await?
        {
            AdminCommentOutcome::Updated(inspection) => Ok(ModerationActionResult {
                inspection: map_inspection(inspection),
                replayed: false,
            }),
            AdminCommentOutcome::AlreadyInState(inspection) => Ok(ModerationActionResult {
                inspection: map_inspection(inspection),
                replayed: true,
            }),
            AdminCommentOutcome::NotFound => Err(ModerationServiceError::NotFound),
            AdminCommentOutcome::InvalidTransition => Err(ModerationServiceError::Conflict),
        }
    }

    async fn user_status(
        &self,
        actor: &AdminActor,
        user_id: AuthenticatedUserId,
        suspended: bool,
        reason_code: &str,
    ) -> Result<UserStatusResult, ModerationServiceError> {
        validate_reason(reason_code)?;
        match self
            .repository
            .set_user_suspended(user_id, actor.stored(), suspended, reason_code)
            .await?
        {
            AdminUserStatusOutcome::Updated(status) => Ok(UserStatusResult {
                user_id,
                status,
                replayed: false,
            }),
            AdminUserStatusOutcome::AlreadyInState(status) => Ok(UserStatusResult {
                user_id,
                status,
                replayed: true,
            }),
            AdminUserStatusOutcome::NotFound => Err(ModerationServiceError::NotFound),
            AdminUserStatusOutcome::DeletionState(_) => {
                Err(ModerationServiceError::AccountDeletionState)
            }
        }
    }

    const fn page_limit(&self, requested: u32) -> Result<u32, ModerationServiceError> {
        if requested == 0 {
            return Err(ModerationServiceError::InvalidPageLimit);
        }
        Ok(if requested > self.maximum_page_size {
            self.maximum_page_size
        } else {
            requested
        })
    }
}

fn validate_reason(reason_code: &str) -> Result<(), ModerationServiceError> {
    ModerationReasonCode::parse(reason_code)
        .map(|_| ())
        .map_err(|_| ModerationServiceError::InvalidReason)
}

fn map_inspection(value: StoredModerationInspection) -> ModerationInspection {
    ModerationInspection {
        comment_id: value.comment_id,
        paper_id: value.paper_id,
        author_user_id: value.author_user_id,
        body: value.body,
        status: value.status,
        moderation_reason: value.moderation_reason,
        version: value.version,
        created_at: value.created_at,
        updated_at: value.updated_at,
        reports: value
            .reports
            .into_iter()
            .map(|report| InspectionReport {
                report_id: report.report_id,
                reporter_user_id: report.reporter_user_id,
                reason: report.reason,
                detail: report.detail,
                status: report.status,
                created_at: report.created_at,
            })
            .collect(),
    }
}

fn map_user_report_inspection(value: StoredUserReportInspection) -> UserReportInspection {
    UserReportInspection {
        report_id: value.report_id,
        reported_user_id: value.reported_user_id,
        reporter_user_id: value.reporter_user_id,
        reason: value.reason,
        detail: value.detail,
        status: value.status,
        created_at: value.created_at,
        reviewed_at: value.reviewed_at,
        reviewed_by: value.reviewed_by,
    }
}
