use std::{fmt, sync::Arc, time::Duration};

use db::{
    CommentCreateOutcome, CommentCreatePrecondition, CommentCreateResolution,
    CommentDeleteResolution, CommentEditResolution, CommentMutationOutcome, CommentReadOutcome,
    CommentReportOutcome, CommentReportResolution, CommentRepository, DbError,
    RateLimitConfigError, RateLimitRepository, RateLimitRequest, StoredReport, UserBlockOutcome,
    UserBlockResolution, UserUnblockResolution,
};
use domain::{
    AccountStatus, AuthenticatedUserId, BlockedUser, BlockedUserPage, CommentBody,
    CommentBodyValidationError, CommentPage, CommentReportReason, CommentReportReceipt,
    CommunityGuidelinesVersion, PaperComment, PaperId, ReportDetail, ReportDetailValidationError,
    TermsVersion,
};
use moderation::{ContentModerator, ModerationDecision, ModerationInput, ModerationReasonCode};
use serde::Serialize;
use thiserror::Error;
use uuid::Uuid;

const DEFAULT_MAXIMUM_PAGE_SIZE: u32 = 50;
const DEFAULT_CREATE_LIMIT: u32 = 10;
const DEFAULT_MUTATION_LIMIT: u32 = 60;
const DEFAULT_REPORT_LIMIT: u32 = 30;
const DEFAULT_ORIGIN_LIMIT: u32 = 120;
const DEFAULT_RATE_WINDOW: Duration = Duration::from_secs(60 * 60);

#[derive(Debug, Clone)]
pub struct CommentServiceConfig {
    current_terms_version: TermsVersion,
    current_community_guidelines_version: CommunityGuidelinesVersion,
    maximum_page_size: u32,
    create_limit: u32,
    create_window: Duration,
    mutation_limit: u32,
    mutation_window: Duration,
    report_limit: u32,
    report_window: Duration,
    origin_limit: u32,
    origin_window: Duration,
}

impl CommentServiceConfig {
    #[must_use]
    pub const fn new(
        current_terms_version: TermsVersion,
        current_community_guidelines_version: CommunityGuidelinesVersion,
    ) -> Self {
        Self {
            current_terms_version,
            current_community_guidelines_version,
            maximum_page_size: DEFAULT_MAXIMUM_PAGE_SIZE,
            create_limit: DEFAULT_CREATE_LIMIT,
            create_window: DEFAULT_RATE_WINDOW,
            mutation_limit: DEFAULT_MUTATION_LIMIT,
            mutation_window: DEFAULT_RATE_WINDOW,
            report_limit: DEFAULT_REPORT_LIMIT,
            report_window: DEFAULT_RATE_WINDOW,
            origin_limit: DEFAULT_ORIGIN_LIMIT,
            origin_window: DEFAULT_RATE_WINDOW,
        }
    }

    pub fn with_maximum_page_size(
        mut self,
        maximum_page_size: u32,
    ) -> Result<Self, CommentServiceConfigError> {
        if maximum_page_size == 0 || maximum_page_size > 200 {
            return Err(CommentServiceConfigError::InvalidPageSize);
        }
        self.maximum_page_size = maximum_page_size;
        Ok(self)
    }

    pub fn with_create_rate_limit(
        mut self,
        limit: u32,
        window: Duration,
    ) -> Result<Self, CommentServiceConfigError> {
        validate_rate_limit(limit, window)?;
        self.create_limit = limit;
        self.create_window = window;
        Ok(self)
    }

    pub fn with_mutation_rate_limit(
        mut self,
        limit: u32,
        window: Duration,
    ) -> Result<Self, CommentServiceConfigError> {
        validate_rate_limit(limit, window)?;
        self.mutation_limit = limit;
        self.mutation_window = window;
        Ok(self)
    }

    pub fn with_report_rate_limit(
        mut self,
        limit: u32,
        window: Duration,
    ) -> Result<Self, CommentServiceConfigError> {
        validate_rate_limit(limit, window)?;
        self.report_limit = limit;
        self.report_window = window;
        Ok(self)
    }

    pub fn with_origin_rate_limit(
        mut self,
        limit: u32,
        window: Duration,
    ) -> Result<Self, CommentServiceConfigError> {
        validate_rate_limit(limit, window)?;
        self.origin_limit = limit;
        self.origin_window = window;
        Ok(self)
    }

    #[must_use]
    pub const fn current_terms_version(&self) -> &TermsVersion {
        &self.current_terms_version
    }

    #[must_use]
    pub const fn current_community_guidelines_version(&self) -> &CommunityGuidelinesVersion {
        &self.current_community_guidelines_version
    }
}

fn validate_rate_limit(limit: u32, window: Duration) -> Result<(), CommentServiceConfigError> {
    RateLimitRequest::new("comment_config", "validation", limit, window)
        .map(|_| ())
        .map_err(CommentServiceConfigError::InvalidRateLimit)
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CommentServiceConfigError {
    #[error("maximum comment page size must be between 1 and 200")]
    InvalidPageSize,
    #[error("comment rate-limit configuration is invalid")]
    InvalidRateLimit(#[from] RateLimitConfigError),
}

#[derive(Clone, PartialEq, Eq)]
pub struct CreateCommentRequest {
    pub client_request_id: Uuid,
    pub body: String,
    /// Lowercase hexadecimal SHA-256 of the trusted direct peer address under
    /// a server-only secret. Raw network/device identifiers are rejected.
    pub origin_scope: String,
}

impl fmt::Debug for CreateCommentRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateCommentRequest")
            .field("client_request_id", &self.client_request_id)
            .field("body", &"[redacted]")
            .field("origin_scope", &"[redacted hash]")
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct EditCommentRequest {
    pub body: String,
    pub expected_version: i32,
}

impl fmt::Debug for EditCommentRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("EditCommentRequest")
            .field("body", &"[redacted]")
            .field("expected_version", &self.expected_version)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ReportCommentRequest {
    pub reason: CommentReportReason,
    pub detail: Option<String>,
    pub origin_scope: String,
}

impl fmt::Debug for ReportCommentRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ReportCommentRequest")
            .field("reason", &self.reason)
            .field("detail", &self.detail.as_ref().map(|_| "[redacted]"))
            .field("origin_scope", &"[redacted hash]")
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CreateCommentResult {
    pub comment: PaperComment,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DeleteCommentResult {
    pub comment_id: Uuid,
    pub version: i32,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReportCommentResult {
    pub report: CommentReportReceipt,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BlockUserResult {
    pub blocked_user: BlockedUser,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UnblockUserResult {
    pub user_id: AuthenticatedUserId,
    pub existed: bool,
}

#[derive(Debug, Error)]
pub enum CommentServiceError {
    #[error("comment client request ID must not be nil")]
    InvalidClientRequestId,
    #[error("request-origin scope must be a lowercase SHA-256 hex digest")]
    InvalidOriginScope,
    #[error("expected comment version must be positive")]
    InvalidExpectedVersion,
    #[error("comment page limit must be positive")]
    InvalidPageLimit,
    #[error("comment cursor is invalid")]
    InvalidCursor,
    #[error(transparent)]
    InvalidBody(#[from] CommentBodyValidationError),
    #[error(transparent)]
    InvalidReportDetail(#[from] ReportDetailValidationError),
    #[error("comment content was rejected by policy")]
    ContentRejected,
    #[error("account was not found")]
    AccountNotFound,
    #[error("account is not active")]
    Inactive(AccountStatus),
    #[error("comment posting requires a handle and current policy acceptance")]
    ProfileIncomplete,
    #[error("paper was not found")]
    PaperNotFound,
    #[error("comment was not found")]
    CommentNotFound,
    #[error("comment belongs to another author")]
    NotAuthor,
    #[error("comment edit version conflict; current version is {current_version}")]
    EditConflict { current_version: i32 },
    #[error("comment was already deleted")]
    AlreadyDeleted,
    #[error("client request ID was reused for different comment intent")]
    IdempotencyConflict,
    #[error("an account cannot block itself")]
    CannotBlockSelf,
    #[error("blocked account was not found")]
    BlockTargetNotFound,
    #[error("comment write is rate limited; retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("comment storage is unavailable")]
    Storage(#[from] DbError),
    #[error("comment rate-limit policy is invalid")]
    InvalidRateLimitPolicy,
}

#[derive(Clone)]
pub struct CommentService {
    comments: CommentRepository,
    rate_limits: RateLimitRepository,
    moderator: Arc<dyn ContentModerator>,
    config: CommentServiceConfig,
}

impl CommentService {
    #[must_use]
    pub const fn new(
        comments: CommentRepository,
        rate_limits: RateLimitRepository,
        moderator: Arc<dyn ContentModerator>,
        config: CommentServiceConfig,
    ) -> Self {
        Self {
            comments,
            rate_limits,
            moderator,
            config,
        }
    }

    #[must_use]
    pub const fn config(&self) -> &CommentServiceConfig {
        &self.config
    }

    pub async fn list_paper(
        &self,
        paper_id: PaperId,
        viewer_user_id: Option<AuthenticatedUserId>,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CommentPage, CommentServiceError> {
        let limit = self.page_limit(limit)?;
        match self
            .comments
            .list_public(paper_id, viewer_user_id, cursor, limit)
            .await?
        {
            CommentReadOutcome::Found(page) => Ok(page),
            CommentReadOutcome::PaperNotFound => Err(CommentServiceError::PaperNotFound),
            CommentReadOutcome::AccountNotFound => Err(CommentServiceError::AccountNotFound),
            CommentReadOutcome::Inactive(status) => Err(CommentServiceError::Inactive(status)),
            CommentReadOutcome::InvalidCursor => Err(CommentServiceError::InvalidCursor),
        }
    }

    pub async fn list_public(
        &self,
        paper_id: PaperId,
        viewer_user_id: Option<AuthenticatedUserId>,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CommentPage, CommentServiceError> {
        self.list_paper(paper_id, viewer_user_id, cursor, limit)
            .await
    }

    pub async fn list_mine(
        &self,
        author_user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CommentPage, CommentServiceError> {
        let limit = self.page_limit(limit)?;
        map_comment_read(
            self.comments
                .list_own(author_user_id, cursor, limit)
                .await?,
        )
    }

    pub async fn list_own(
        &self,
        author_user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<CommentPage, CommentServiceError> {
        self.list_mine(author_user_id, cursor, limit).await
    }

    pub async fn create(
        &self,
        author_user_id: AuthenticatedUserId,
        paper_id: PaperId,
        request: CreateCommentRequest,
    ) -> Result<CreateCommentResult, CommentServiceError> {
        if request.client_request_id.is_nil() {
            return Err(CommentServiceError::InvalidClientRequestId);
        }
        let origin_scope = validate_origin_scope(&request.origin_scope)?;
        let body = CommentBody::parse(&request.body)?;
        match self
            .comments
            .resolve_create(author_user_id, paper_id, request.client_request_id, &body)
            .await?
        {
            CommentCreateResolution::Replay(comment) => {
                return Ok(CreateCommentResult {
                    comment,
                    replayed: true,
                });
            }
            CommentCreateResolution::AccountNotFound => {
                return Err(CommentServiceError::AccountNotFound);
            }
            CommentCreateResolution::Inactive(status) => {
                return Err(CommentServiceError::Inactive(status));
            }
            CommentCreateResolution::IdempotencyConflict => {
                return Err(CommentServiceError::IdempotencyConflict);
            }
            CommentCreateResolution::Unknown => {}
        }

        self.check_rate_limit(RateLimitRequest::comment_create(
            author_user_id,
            self.config.create_limit,
            self.config.create_window,
        ))
        .await?;
        self.check_rate_limit(RateLimitRequest::comment_origin(
            origin_scope,
            self.config.origin_limit,
            self.config.origin_window,
        ))
        .await?;
        match self
            .comments
            .check_create_preconditions(
                author_user_id,
                paper_id,
                self.config.current_terms_version(),
                self.config.current_community_guidelines_version(),
            )
            .await?
        {
            CommentCreatePrecondition::Eligible => {}
            CommentCreatePrecondition::AccountNotFound => {
                return Err(CommentServiceError::AccountNotFound);
            }
            CommentCreatePrecondition::Inactive(status) => {
                return Err(CommentServiceError::Inactive(status));
            }
            CommentCreatePrecondition::ProfileIncomplete => {
                return Err(CommentServiceError::ProfileIncomplete);
            }
            CommentCreatePrecondition::PaperNotFound => {
                return Err(CommentServiceError::PaperNotFound);
            }
        }
        let (status, reason) = self.moderate(body.clone()).await?;
        match self
            .comments
            .create(
                Uuid::now_v7(),
                author_user_id,
                paper_id,
                request.client_request_id,
                &body,
                status,
                reason.as_ref().map(ModerationReasonCode::as_str),
                self.config.current_terms_version(),
                self.config.current_community_guidelines_version(),
            )
            .await?
        {
            CommentCreateOutcome::Applied { comment, replayed } => {
                Ok(CreateCommentResult { comment, replayed })
            }
            CommentCreateOutcome::AccountNotFound => Err(CommentServiceError::AccountNotFound),
            CommentCreateOutcome::Inactive(status) => Err(CommentServiceError::Inactive(status)),
            CommentCreateOutcome::ProfileIncomplete => Err(CommentServiceError::ProfileIncomplete),
            CommentCreateOutcome::PaperNotFound => Err(CommentServiceError::PaperNotFound),
            CommentCreateOutcome::IdempotencyConflict => {
                Err(CommentServiceError::IdempotencyConflict)
            }
        }
    }

    pub async fn edit(
        &self,
        author_user_id: AuthenticatedUserId,
        comment_id: Uuid,
        request: EditCommentRequest,
    ) -> Result<PaperComment, CommentServiceError> {
        if request.expected_version <= 0 {
            return Err(CommentServiceError::InvalidExpectedVersion);
        }
        let body = CommentBody::parse(&request.body)?;
        match self
            .comments
            .resolve_edit(author_user_id, comment_id, request.expected_version)
            .await?
        {
            CommentEditResolution::Ready => {}
            CommentEditResolution::AccountNotFound => {
                return Err(CommentServiceError::AccountNotFound);
            }
            CommentEditResolution::Inactive(status) => {
                return Err(CommentServiceError::Inactive(status));
            }
            CommentEditResolution::CommentNotFound => {
                return Err(CommentServiceError::CommentNotFound);
            }
            CommentEditResolution::VersionConflict { current_version } => {
                return Err(CommentServiceError::EditConflict { current_version });
            }
        }
        self.check_mutation_limit(author_user_id).await?;
        let (status, reason) = self.moderate(body.clone()).await?;
        map_updated(
            self.comments
                .edit(
                    author_user_id,
                    comment_id,
                    request.expected_version,
                    &body,
                    status,
                    reason.as_ref().map(ModerationReasonCode::as_str),
                )
                .await?,
        )
    }

    pub async fn delete(
        &self,
        author_user_id: AuthenticatedUserId,
        comment_id: Uuid,
    ) -> Result<DeleteCommentResult, CommentServiceError> {
        match self
            .comments
            .resolve_delete(author_user_id, comment_id)
            .await?
        {
            CommentDeleteResolution::Replay(comment) => {
                return Ok(DeleteCommentResult {
                    comment_id: comment.id,
                    version: comment.version,
                    replayed: true,
                });
            }
            CommentDeleteResolution::AccountNotFound => {
                return Err(CommentServiceError::AccountNotFound);
            }
            CommentDeleteResolution::Inactive(status) => {
                return Err(CommentServiceError::Inactive(status));
            }
            CommentDeleteResolution::CommentNotFound | CommentDeleteResolution::NotAuthor => {
                return Err(CommentServiceError::CommentNotFound);
            }
            CommentDeleteResolution::Unknown => {}
        }
        self.check_mutation_limit(author_user_id).await?;
        match self.comments.delete(author_user_id, comment_id).await? {
            CommentMutationOutcome::Deleted { comment, replayed } => Ok(DeleteCommentResult {
                comment_id: comment.id,
                version: comment.version,
                replayed,
            }),
            outcome => map_mutation_error(&outcome),
        }
    }

    pub async fn report(
        &self,
        reporter_user_id: AuthenticatedUserId,
        comment_id: Uuid,
        request: ReportCommentRequest,
    ) -> Result<ReportCommentResult, CommentServiceError> {
        let origin_scope = validate_origin_scope(&request.origin_scope)?;
        match self
            .comments
            .resolve_report(reporter_user_id, comment_id)
            .await?
        {
            CommentReportResolution::Replay(report) => {
                return Ok(report_result(&report, true));
            }
            CommentReportResolution::AccountNotFound => {
                return Err(CommentServiceError::AccountNotFound);
            }
            CommentReportResolution::Inactive(status) => {
                return Err(CommentServiceError::Inactive(status));
            }
            CommentReportResolution::CommentNotFound => {
                return Err(CommentServiceError::CommentNotFound);
            }
            CommentReportResolution::Unknown => {}
        }
        let detail = request
            .detail
            .as_deref()
            .map(ReportDetail::parse)
            .transpose()?;
        self.check_rate_limit(RateLimitRequest::comment_origin(
            origin_scope,
            self.config.origin_limit,
            self.config.origin_window,
        ))
        .await?;
        self.check_rate_limit(RateLimitRequest::comment_report(
            reporter_user_id,
            self.config.report_limit,
            self.config.report_window,
        ))
        .await?;
        self.check_rate_limit(RateLimitRequest::comment_report_target(
            comment_id,
            self.config.report_limit,
            self.config.report_window,
        ))
        .await?;
        match self
            .comments
            .report(
                reporter_user_id,
                comment_id,
                request.reason,
                detail.as_ref(),
            )
            .await?
        {
            CommentReportOutcome::Accepted { report, replayed } => {
                Ok(report_result(&report, replayed))
            }
            CommentReportOutcome::AccountNotFound => Err(CommentServiceError::AccountNotFound),
            CommentReportOutcome::Inactive(status) => Err(CommentServiceError::Inactive(status)),
            CommentReportOutcome::CommentNotFound => Err(CommentServiceError::CommentNotFound),
        }
    }

    #[allow(clippy::similar_names)]
    pub async fn block(
        &self,
        blocker_user_id: AuthenticatedUserId,
        blocked_user_id: AuthenticatedUserId,
    ) -> Result<BlockUserResult, CommentServiceError> {
        match self
            .comments
            .resolve_block(blocker_user_id, blocked_user_id)
            .await?
        {
            UserBlockResolution::Replay(blocked_user) => {
                return Ok(BlockUserResult { blocked_user });
            }
            UserBlockResolution::AccountNotFound => {
                return Err(CommentServiceError::AccountNotFound);
            }
            UserBlockResolution::Inactive(status) => {
                return Err(CommentServiceError::Inactive(status));
            }
            UserBlockResolution::TargetNotFound => {
                return Err(CommentServiceError::BlockTargetNotFound);
            }
            UserBlockResolution::CannotBlockSelf => {
                return Err(CommentServiceError::CannotBlockSelf);
            }
            UserBlockResolution::Unknown => {}
        }
        self.check_mutation_limit(blocker_user_id).await?;
        match self
            .comments
            .block(blocker_user_id, blocked_user_id)
            .await?
        {
            UserBlockOutcome::Applied { blocked_user } => Ok(BlockUserResult { blocked_user }),
            outcome => map_block_error(&outcome),
        }
    }

    #[allow(clippy::similar_names)]
    pub async fn unblock(
        &self,
        blocker_user_id: AuthenticatedUserId,
        blocked_user_id: AuthenticatedUserId,
    ) -> Result<UnblockUserResult, CommentServiceError> {
        match self
            .comments
            .resolve_unblock(blocker_user_id, blocked_user_id)
            .await?
        {
            UserUnblockResolution::Absent => {
                return Ok(UnblockUserResult {
                    user_id: blocked_user_id,
                    existed: false,
                });
            }
            UserUnblockResolution::AccountNotFound => {
                return Err(CommentServiceError::AccountNotFound);
            }
            UserUnblockResolution::Inactive(status) => {
                return Err(CommentServiceError::Inactive(status));
            }
            UserUnblockResolution::CannotBlockSelf => {
                return Err(CommentServiceError::CannotBlockSelf);
            }
            UserUnblockResolution::Present => {}
        }
        self.check_mutation_limit(blocker_user_id).await?;
        match self
            .comments
            .unblock(blocker_user_id, blocked_user_id)
            .await?
        {
            UserBlockOutcome::Removed { existed } => Ok(UnblockUserResult {
                user_id: blocked_user_id,
                existed,
            }),
            outcome => map_block_error(&outcome),
        }
    }

    pub async fn list_blocks(
        &self,
        blocker_user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<BlockedUserPage, CommentServiceError> {
        let limit = self.page_limit(limit)?;
        match self
            .comments
            .list_blocks(blocker_user_id, cursor, limit)
            .await?
        {
            CommentReadOutcome::Found(page) => Ok(page),
            CommentReadOutcome::AccountNotFound => Err(CommentServiceError::AccountNotFound),
            CommentReadOutcome::Inactive(status) => Err(CommentServiceError::Inactive(status)),
            CommentReadOutcome::InvalidCursor => Err(CommentServiceError::InvalidCursor),
            CommentReadOutcome::PaperNotFound => Err(CommentServiceError::Storage(
                DbError::InvalidData("block list unexpectedly required a paper".to_owned()),
            )),
        }
    }

    async fn moderate(
        &self,
        body: CommentBody,
    ) -> Result<(domain::CommentStatus, Option<ModerationReasonCode>), CommentServiceError> {
        let decision = match self.moderator.evaluate(ModerationInput::new(body)).await {
            Ok(decision) => decision,
            Err(_) => ModerationDecision::PendingReview {
                reason_code: ModerationReasonCode::parse("moderator_unavailable")
                    .map_err(|_| CommentServiceError::ContentRejected)?,
            },
        };
        match decision {
            ModerationDecision::Publish => Ok((domain::CommentStatus::Published, None)),
            ModerationDecision::PendingReview { reason_code } => {
                Ok((domain::CommentStatus::PendingReview, Some(reason_code)))
            }
            ModerationDecision::Reject { .. } => Err(CommentServiceError::ContentRejected),
        }
    }

    async fn check_mutation_limit(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<(), CommentServiceError> {
        self.check_rate_limit(RateLimitRequest::comment_mutation(
            user_id,
            self.config.mutation_limit,
            self.config.mutation_window,
        ))
        .await
    }

    async fn check_rate_limit(
        &self,
        request: Result<RateLimitRequest, RateLimitConfigError>,
    ) -> Result<(), CommentServiceError> {
        let request = request.map_err(|_| CommentServiceError::InvalidRateLimitPolicy)?;
        let decision = self.rate_limits.check(&request).await?;
        if decision.allowed {
            Ok(())
        } else {
            Err(CommentServiceError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(1).max(1),
            })
        }
    }

    const fn page_limit(&self, requested: u32) -> Result<u32, CommentServiceError> {
        if requested == 0 {
            return Err(CommentServiceError::InvalidPageLimit);
        }
        Ok(if requested > self.config.maximum_page_size {
            self.config.maximum_page_size
        } else {
            requested
        })
    }
}

fn map_comment_read(
    outcome: CommentReadOutcome<CommentPage>,
) -> Result<CommentPage, CommentServiceError> {
    match outcome {
        CommentReadOutcome::Found(page) => Ok(page),
        CommentReadOutcome::PaperNotFound => Err(CommentServiceError::PaperNotFound),
        CommentReadOutcome::AccountNotFound => Err(CommentServiceError::AccountNotFound),
        CommentReadOutcome::Inactive(status) => Err(CommentServiceError::Inactive(status)),
        CommentReadOutcome::InvalidCursor => Err(CommentServiceError::InvalidCursor),
    }
}

fn report_result(report: &StoredReport, replayed: bool) -> ReportCommentResult {
    ReportCommentResult {
        report: CommentReportReceipt {
            id: report.id,
            comment_id: report.comment_id,
            reason: report.reason,
            status: report.status,
            created_at: report.created_at,
        },
        replayed,
    }
}

fn validate_origin_scope(value: &str) -> Result<String, CommentServiceError> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(CommentServiceError::InvalidOriginScope);
    }
    Ok(format!("origin:{value}"))
}

fn map_updated(outcome: CommentMutationOutcome) -> Result<PaperComment, CommentServiceError> {
    match outcome {
        CommentMutationOutcome::Updated(comment) => Ok(comment),
        outcome => map_mutation_error(&outcome),
    }
}

fn map_mutation_error<T>(outcome: &CommentMutationOutcome) -> Result<T, CommentServiceError> {
    match outcome {
        CommentMutationOutcome::AccountNotFound => Err(CommentServiceError::AccountNotFound),
        CommentMutationOutcome::Inactive(status) => Err(CommentServiceError::Inactive(*status)),
        CommentMutationOutcome::CommentNotFound | CommentMutationOutcome::NotAuthor => {
            Err(CommentServiceError::CommentNotFound)
        }
        CommentMutationOutcome::VersionConflict { current_version } => {
            Err(CommentServiceError::EditConflict {
                current_version: *current_version,
            })
        }
        CommentMutationOutcome::AlreadyDeleted => Err(CommentServiceError::AlreadyDeleted),
        CommentMutationOutcome::Updated(_) | CommentMutationOutcome::Deleted { .. } => {
            Err(CommentServiceError::Storage(DbError::InvalidData(
                "comment mutation returned an unexpected success variant".to_owned(),
            )))
        }
    }
}

fn map_block_error<T>(outcome: &UserBlockOutcome) -> Result<T, CommentServiceError> {
    match outcome {
        UserBlockOutcome::AccountNotFound => Err(CommentServiceError::AccountNotFound),
        UserBlockOutcome::Inactive(status) => Err(CommentServiceError::Inactive(*status)),
        UserBlockOutcome::TargetNotFound => Err(CommentServiceError::BlockTargetNotFound),
        UserBlockOutcome::CannotBlockSelf => Err(CommentServiceError::CannotBlockSelf),
        UserBlockOutcome::Applied { .. } | UserBlockOutcome::Removed { .. } => {
            Err(CommentServiceError::Storage(DbError::InvalidData(
                "block mutation returned an unexpected success variant".to_owned(),
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_redact_user_content_from_debug() {
        let create = CreateCommentRequest {
            client_request_id: Uuid::now_v7(),
            body: "secret comment".to_owned(),
            origin_scope: "a".repeat(64),
        };
        let report = ReportCommentRequest {
            reason: CommentReportReason::Other,
            detail: Some("secret detail".to_owned()),
            origin_scope: "b".repeat(64),
        };
        assert!(!format!("{create:?}").contains("secret comment"));
        assert!(!format!("{report:?}").contains("secret detail"));
    }

    #[test]
    fn default_policy_and_overrides_validate() {
        let config = CommentServiceConfig::new(
            TermsVersion::parse("2026-08-01").unwrap(),
            CommunityGuidelinesVersion::parse("2026-08-01").unwrap(),
        )
        .with_create_rate_limit(12, Duration::from_secs(300))
        .unwrap()
        .with_maximum_page_size(75)
        .unwrap();
        assert_eq!(config.create_limit, 12);
        assert_eq!(config.maximum_page_size, 75);
        assert!(
            CommentServiceConfig::new(
                TermsVersion::parse("2026-08-01").unwrap(),
                CommunityGuidelinesVersion::parse("2026-08-01").unwrap(),
            )
            .with_report_rate_limit(0, Duration::from_secs(60))
            .is_err()
        );
    }
}
