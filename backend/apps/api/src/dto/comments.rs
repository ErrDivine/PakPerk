use domain::{
    BlockedUser, CommentReportReason, CommentStatus, PaperComment, PublicUser, UserReportReceipt,
};
use serde::{Deserialize, Deserializer, Serialize};
use uuid::Uuid;

use super::{AccountStatusSchema, format_timestamp};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CommentListParams {
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct CreateCommentBody {
    pub(crate) client_request_id: Uuid,
    #[schema(min_length = 1, max_length = 2000)]
    pub(crate) body: String,
}

impl std::fmt::Debug for CreateCommentBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CreateCommentBody")
            .field("client_request_id", &self.client_request_id)
            .field("body", &"[redacted]")
            .finish()
    }
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct EditCommentBody {
    #[schema(min_length = 1, max_length = 2000)]
    pub(crate) body: String,
    #[schema(minimum = 1)]
    pub(crate) expected_version: i32,
}

impl std::fmt::Debug for EditCommentBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EditCommentBody")
            .field("body", &"[redacted]")
            .field("expected_version", &self.expected_version)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CommentReportReasonBody {
    Spam,
    Harassment,
    Hate,
    Threat,
    SexualContent,
    Privacy,
    Impersonation,
    Copyright,
    Other,
}

impl From<CommentReportReasonBody> for CommentReportReason {
    fn from(value: CommentReportReasonBody) -> Self {
        match value {
            CommentReportReasonBody::Spam => Self::Spam,
            CommentReportReasonBody::Harassment => Self::Harassment,
            CommentReportReasonBody::Hate => Self::Hate,
            CommentReportReasonBody::Threat => Self::Threat,
            CommentReportReasonBody::SexualContent => Self::SexualContent,
            CommentReportReasonBody::Privacy => Self::Privacy,
            CommentReportReasonBody::Impersonation => Self::Impersonation,
            CommentReportReasonBody::Copyright => Self::Copyright,
            CommentReportReasonBody::Other => Self::Other,
        }
    }
}

impl From<CommentReportReason> for CommentReportReasonBody {
    fn from(value: CommentReportReason) -> Self {
        match value {
            CommentReportReason::Spam => Self::Spam,
            CommentReportReason::Harassment => Self::Harassment,
            CommentReportReason::Hate => Self::Hate,
            CommentReportReason::Threat => Self::Threat,
            CommentReportReason::SexualContent => Self::SexualContent,
            CommentReportReason::Privacy => Self::Privacy,
            CommentReportReason::Impersonation => Self::Impersonation,
            CommentReportReason::Copyright => Self::Copyright,
            CommentReportReason::Other => Self::Other,
        }
    }
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReportCommentBody {
    pub(crate) reason: CommentReportReasonBody,
    #[serde(deserialize_with = "required_nullable_string")]
    #[schema(required = true, nullable, min_length = 1, max_length = 500)]
    pub(crate) detail: Option<String>,
}

impl std::fmt::Debug for ReportCommentBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ReportCommentBody")
            .field("reason", &self.reason)
            .field("detail", &self.detail.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CommentReportStatusSchema {
    Open,
    Reviewed,
    Actioned,
    Dismissed,
}

impl From<domain::CommentReportStatus> for CommentReportStatusSchema {
    fn from(value: domain::CommentReportStatus) -> Self {
        match value {
            domain::CommentReportStatus::Open => Self::Open,
            domain::CommentReportStatus::Reviewed => Self::Reviewed,
            domain::CommentReportStatus::Actioned => Self::Actioned,
            domain::CommentReportStatus::Dismissed => Self::Dismissed,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct CommentReportResponse {
    pub(crate) id: Uuid,
    pub(crate) comment_id: Uuid,
    pub(crate) reason: CommentReportReasonBody,
    pub(crate) status: CommentReportStatusSchema,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct CommentReportEnvelope {
    pub(crate) report: CommentReportResponse,
}

impl From<domain::CommentReportReceipt> for CommentReportEnvelope {
    fn from(report: domain::CommentReportReceipt) -> Self {
        Self {
            report: CommentReportResponse {
                id: report.id,
                comment_id: report.comment_id,
                reason: report.reason.into(),
                status: report.status.into(),
                created_at: format_timestamp(report.created_at),
            },
        }
    }
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReportUserBody {
    pub(crate) reason: CommentReportReasonBody,
    #[serde(deserialize_with = "required_nullable_string")]
    #[schema(required = true, nullable, min_length = 1, max_length = 500)]
    pub(crate) detail: Option<String>,
}

fn required_nullable_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer)
}

impl std::fmt::Debug for ReportUserBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ReportUserBody")
            .field("reason", &self.reason)
            .field("detail", &self.detail.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct UserReportResponse {
    pub(crate) id: Uuid,
    pub(crate) reported_user_id: Uuid,
    pub(crate) reason: CommentReportReasonBody,
    pub(crate) status: CommentReportStatusSchema,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct UserReportEnvelope {
    pub(crate) report: UserReportResponse,
}

impl From<UserReportReceipt> for UserReportEnvelope {
    fn from(report: UserReportReceipt) -> Self {
        Self {
            report: UserReportResponse {
                id: report.id,
                reported_user_id: report.reported_user_id.into_inner(),
                reason: report.reason.into(),
                status: report.status.into(),
                created_at: format_timestamp(report.created_at),
            },
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CommentStatusSchema {
    PendingReview,
    Published,
    Hidden,
    Deleted,
}

impl From<CommentStatus> for CommentStatusSchema {
    fn from(value: CommentStatus) -> Self {
        match value {
            CommentStatus::PendingReview => Self::PendingReview,
            CommentStatus::Published => Self::Published,
            CommentStatus::Hidden => Self::Hidden,
            CommentStatus::Deleted => Self::Deleted,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct CommentAuthorResponse {
    pub(crate) id: Uuid,
    #[schema(required = true, nullable, min_length = 3, max_length = 30)]
    pub(crate) handle: Option<String>,
    #[schema(required = true, nullable, min_length = 1, max_length = 80)]
    pub(crate) display_name: Option<String>,
    pub(crate) status: AccountStatusSchema,
}

impl From<PublicUser> for CommentAuthorResponse {
    fn from(user: PublicUser) -> Self {
        Self {
            id: user.id.into_inner(),
            handle: user.handle.map(domain::Handle::into_inner),
            display_name: user.display_name.map(domain::DisplayName::into_inner),
            status: user.status.into(),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct CommentResponse {
    pub(crate) id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) author: CommentAuthorResponse,
    pub(crate) body: String,
    pub(crate) status: CommentStatusSchema,
    #[schema(minimum = 1)]
    pub(crate) version: i32,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    pub(crate) edited_at: Option<String>,
}

impl std::fmt::Debug for CommentResponse {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CommentResponse")
            .field("id", &self.id)
            .field("paper_id", &self.paper_id)
            .field("author", &self.author)
            .field("body", &"[redacted]")
            .field("status", &self.status)
            .field("version", &self.version)
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .field("edited_at", &self.edited_at)
            .finish()
    }
}

impl From<PaperComment> for CommentResponse {
    fn from(comment: PaperComment) -> Self {
        Self {
            id: comment.id,
            paper_id: comment.paper_id,
            author: comment.author.into(),
            body: comment.body.into_inner(),
            status: comment.status.into(),
            version: comment.version,
            created_at: format_timestamp(comment.created_at),
            updated_at: format_timestamp(comment.updated_at),
            edited_at: comment.edited_at.map(format_timestamp),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct CommentEnvelope {
    pub(crate) comment: CommentResponse,
}

impl std::fmt::Debug for CommentEnvelope {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CommentEnvelope")
            .field("comment", &self.comment)
            .finish()
    }
}

impl From<PaperComment> for CommentEnvelope {
    fn from(comment: PaperComment) -> Self {
        Self {
            comment: comment.into(),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct CommentPageEnvelope {
    pub(crate) items: Vec<CommentResponse>,
    #[schema(required = true, nullable, max_length = 512)]
    pub(crate) next_cursor: Option<String>,
}

impl std::fmt::Debug for CommentPageEnvelope {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CommentPageEnvelope")
            .field("items", &self.items)
            .field("next_cursor", &self.next_cursor)
            .finish()
    }
}

impl From<domain::CommentPage> for CommentPageEnvelope {
    fn from(page: domain::CommentPage) -> Self {
        Self {
            items: page.items.into_iter().map(CommentResponse::from).collect(),
            next_cursor: page.next_cursor,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct BlockedUserResponse {
    pub(crate) user: CommentAuthorResponse,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
}

impl From<BlockedUser> for BlockedUserResponse {
    fn from(block: BlockedUser) -> Self {
        Self {
            user: block.user.into(),
            created_at: format_timestamp(block.created_at),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct BlockedUserEnvelope {
    pub(crate) blocked_user: BlockedUserResponse,
}

impl From<BlockedUser> for BlockedUserEnvelope {
    fn from(block: BlockedUser) -> Self {
        Self {
            blocked_user: block.into(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct BlockedUserPageEnvelope {
    pub(crate) items: Vec<BlockedUserResponse>,
    #[schema(required = true, nullable, max_length = 512)]
    pub(crate) next_cursor: Option<String>,
}

impl From<domain::BlockedUserPage> for BlockedUserPageEnvelope {
    fn from(page: domain::BlockedUserPage) -> Self {
        Self {
            items: page
                .items
                .into_iter()
                .map(BlockedUserResponse::from)
                .collect(),
            next_cursor: page.next_cursor,
        }
    }
}
