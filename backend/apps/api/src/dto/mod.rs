//! HTTP-only request and response DTOs.

use chrono::{SecondsFormat, Utc};
use domain::{
    AccountDeletionOperation, AccountDeletionState, AccountStatus, BlockedUser,
    CommentReportReason, CommentStatus, CommunityGuidelinesVersion, LibraryItem, LibraryState,
    PaperComment, PaperSummary, PublicUser, SavedLibraryPaper, TermsVersion, User,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
pub(crate) struct FeedParams {
    pub(crate) category: Option<String>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Default, Deserialize, utoipa::ToSchema)]
pub(crate) struct PrepareBody {
    #[serde(default)]
    pub(crate) retry: bool,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub(crate) struct ChatBody {
    pub(crate) thread_id: Option<Uuid>,
    pub(crate) message: String,
}

#[derive(Debug, Serialize)]
pub(crate) struct ChatResponse {
    pub(crate) thread_id: Uuid,
    pub(crate) generation: domain::ProcessingGeneration,
    #[serde(flatten)]
    pub(crate) answer: domain::ChatAnswer,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryListParams {
    pub(crate) state: Option<String>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryChangesParams {
    pub(crate) after_revision: Option<i64>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LibraryStateBody {
    ToRead,
}

impl From<LibraryStateBody> for LibraryState {
    fn from(value: LibraryStateBody) -> Self {
        match value {
            LibraryStateBody::ToRead => Self::ToRead,
        }
    }
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibrarySaveBody {
    pub(crate) operation_id: Uuid,
    pub(crate) state: LibraryStateBody,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryItemResponse {
    pub(crate) paper_id: Uuid,
    pub(crate) state: LibraryState,
    pub(crate) saved_at: String,
    pub(crate) updated_at: String,
    pub(crate) removed: bool,
    pub(crate) removed_at: Option<String>,
    pub(crate) revision: i64,
    pub(crate) last_operation_id: Uuid,
}

impl From<LibraryItem> for LibraryItemResponse {
    fn from(item: LibraryItem) -> Self {
        Self {
            paper_id: item.paper_id,
            state: item.state,
            saved_at: format_timestamp(item.saved_at),
            updated_at: format_timestamp(item.updated_at),
            removed: item.removed(),
            removed_at: item.removed_at.map(format_timestamp),
            revision: item.revision,
            last_operation_id: item.last_operation_id,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryMutationEnvelope {
    pub(crate) item: LibraryItemResponse,
}

impl From<LibraryItem> for LibraryMutationEnvelope {
    fn from(item: LibraryItem) -> Self {
        Self { item: item.into() }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryListEntryResponse {
    pub(crate) item: LibraryItemResponse,
    pub(crate) paper: PaperSummary,
}

impl From<SavedLibraryPaper> for LibraryListEntryResponse {
    fn from(saved: SavedLibraryPaper) -> Self {
        Self {
            item: saved.item.into(),
            paper: saved.paper,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryListEnvelope {
    pub(crate) items: Vec<LibraryListEntryResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) sync_revision: i64,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryChangeEntryResponse {
    pub(crate) item: LibraryItemResponse,
    pub(crate) paper: Option<PaperSummary>,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryChangesEnvelope {
    pub(crate) items: Vec<LibraryChangeEntryResponse>,
    pub(crate) next_after_revision: i64,
    pub(crate) has_more: bool,
    pub(crate) sync_revision: i64,
}

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
    #[schema(required = true, nullable, min_length = 1, max_length = 500)]
    pub(crate) detail: Option<String>,
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

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum ProfilePatchField<T> {
    #[default]
    Omitted,
    Null,
    Value(T),
}

impl<'de, T> Deserialize<'de> for ProfilePatchField<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        Option::<T>::deserialize(deserializer).map(|value| match value {
            Some(value) => Self::Value(value),
            None => Self::Null,
        })
    }
}

/// Supported compare-and-swap fields for `PATCH /v1/me`. All properties are
/// optional, while an explicit JSON null is meaningful only for
/// `display_name`.
#[derive(Debug, Default, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ProfileUpdateBody {
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        min_length = 3,
        max_length = 30,
        pattern = "^[A-Za-z0-9_]+$",
        example = "ada_reader"
    )]
    pub(crate) handle: ProfilePatchField<String>,
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        nullable,
        min_length = 1,
        max_length = 80,
        example = "Ada Reader"
    )]
    pub(crate) display_name: ProfilePatchField<String>,
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        min_length = 1,
        max_length = 64,
        pattern = "^[A-Za-z0-9._:-]+$",
        example = "2026-07-31"
    )]
    pub(crate) accept_terms_version: ProfilePatchField<String>,
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        min_length = 1,
        max_length = 64,
        pattern = "^[A-Za-z0-9._:-]+$",
        example = "2026-07-31"
    )]
    pub(crate) accept_community_guidelines_version: ProfilePatchField<String>,
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AccountStatusSchema {
    Active,
    Suspended,
    DeletionPending,
    Deleted,
}

impl From<AccountStatus> for AccountStatusSchema {
    fn from(value: AccountStatus) -> Self {
        match value {
            AccountStatus::Active => Self::Active,
            AccountStatus::Suspended => Self::Suspended,
            AccountStatus::DeletionPending => Self::DeletionPending,
            AccountStatus::Deleted => Self::Deleted,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DeletionVerificationEnvelope {
    pub(crate) account: DeletionVerificationAccount,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DeletionVerificationAccount {
    pub(crate) id: Uuid,
    pub(crate) status: AccountStatusSchema,
    #[schema(required = true, nullable)]
    pub(crate) deletion_operation_id: Option<Uuid>,
}

impl From<account_deletion::DeletionIdentityVerification> for DeletionVerificationEnvelope {
    fn from(value: account_deletion::DeletionIdentityVerification) -> Self {
        Self {
            account: DeletionVerificationAccount {
                id: value.account_id.into_inner(),
                status: value.status.into(),
                deletion_operation_id: value.operation_id,
            },
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AccountProfileEnvelope {
    pub(crate) account: AccountProfileResponse,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
#[allow(clippy::struct_excessive_bools)] // Wire contract exposes independent onboarding states.
pub(crate) struct AccountProfileResponse {
    pub(crate) id: Uuid,
    #[schema(required = true, nullable)]
    #[schema(min_length = 3, max_length = 30, pattern = "^[a-z0-9_]+$")]
    pub(crate) handle: Option<String>,
    #[schema(required = true, nullable)]
    #[schema(min_length = 1, max_length = 80)]
    pub(crate) display_name: Option<String>,
    pub(crate) status: AccountStatusSchema,
    #[schema(minimum = 1)]
    pub(crate) profile_version: i64,
    pub(crate) profile_complete: bool,
    #[schema(required = true, nullable)]
    pub(crate) terms_version: Option<String>,
    #[schema(required = true, nullable)]
    pub(crate) terms_accepted_at: Option<String>,
    pub(crate) current_terms_version: String,
    pub(crate) terms_current: bool,
    #[schema(required = true, nullable)]
    pub(crate) community_guidelines_version: Option<String>,
    #[schema(required = true, nullable)]
    pub(crate) community_guidelines_accepted_at: Option<String>,
    pub(crate) current_community_guidelines_version: String,
    pub(crate) community_guidelines_current: bool,
    pub(crate) comment_profile_complete: bool,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

impl AccountProfileEnvelope {
    pub(crate) fn new(
        user: &User,
        current_terms_version: &TermsVersion,
        current_community_guidelines_version: &CommunityGuidelinesVersion,
    ) -> Self {
        Self {
            account: AccountProfileResponse {
                id: *user.id.as_uuid(),
                handle: user.handle.as_ref().map(ToString::to_string),
                display_name: user.display_name.as_ref().map(ToString::to_string),
                status: user.status.into(),
                profile_version: user.profile_version,
                profile_complete: user.profile_complete(current_terms_version),
                terms_version: user.terms_version.as_ref().map(ToString::to_string),
                terms_accepted_at: user.terms_accepted_at.map(format_timestamp),
                current_terms_version: current_terms_version.to_string(),
                terms_current: user.has_accepted_terms(current_terms_version),
                community_guidelines_version: user
                    .community_guidelines_version
                    .as_ref()
                    .map(ToString::to_string),
                community_guidelines_accepted_at: user
                    .community_guidelines_accepted_at
                    .map(format_timestamp),
                current_community_guidelines_version: current_community_guidelines_version
                    .to_string(),
                community_guidelines_current: user
                    .has_accepted_community_guidelines(current_community_guidelines_version),
                comment_profile_complete: user.comment_profile_complete(
                    current_terms_version,
                    current_community_guidelines_version,
                ),
                created_at: format_timestamp(user.created_at),
                updated_at: format_timestamp(user.updated_at),
            },
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AccountDeletionStateSchema {
    Requested,
    SessionsRevoked,
    IdentityDeleted,
    AppDataDeleted,
    Completed,
    FailedRetryable,
    FailedTerminal,
}

impl From<AccountDeletionState> for AccountDeletionStateSchema {
    fn from(value: AccountDeletionState) -> Self {
        match value {
            AccountDeletionState::Requested => Self::Requested,
            AccountDeletionState::SessionsRevoked => Self::SessionsRevoked,
            AccountDeletionState::IdentityDeleted => Self::IdentityDeleted,
            AccountDeletionState::AppDataDeleted => Self::AppDataDeleted,
            AccountDeletionState::Completed => Self::Completed,
            AccountDeletionState::FailedRetryable => Self::FailedRetryable,
            AccountDeletionState::FailedTerminal => Self::FailedTerminal,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AccountDeletionResponse {
    pub(crate) operation_id: Uuid,
    pub(crate) state: AccountDeletionStateSchema,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) requested_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AccountDeletionEnvelope {
    pub(crate) deletion: AccountDeletionResponse,
}

impl From<AccountDeletionOperation> for AccountDeletionEnvelope {
    fn from(operation: AccountDeletionOperation) -> Self {
        Self {
            deletion: AccountDeletionResponse {
                operation_id: operation.operation_id,
                state: operation.state.into(),
                requested_at: format_timestamp(operation.requested_at),
                updated_at: format_timestamp(operation.updated_at),
            },
        }
    }
}

fn format_timestamp(value: chrono::DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comment_mutation_dtos_are_strict_and_debug_redacted() {
        let create: CreateCommentBody = serde_json::from_str(
            r#"{"client_request_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","body":"private observation"}"#,
        )
        .unwrap();
        let debug = format!("{create:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("private observation"));
        assert!(
            serde_json::from_str::<CreateCommentBody>(
                r#"{"client_request_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","body":"ok","admin":true}"#,
            )
            .is_err()
        );

        let report: ReportCommentBody =
            serde_json::from_str(r#"{"reason":"privacy","detail":"private reporter context"}"#)
                .unwrap();
        let debug = format!("{report:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("private reporter context"));
        assert!(
            serde_json::from_str::<ReportCommentBody>(r#"{"reason":"dislike","detail":null}"#)
                .is_err()
        );

        let response = CommentResponse {
            id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            author: CommentAuthorResponse {
                id: Uuid::now_v7(),
                handle: Some("reader".to_owned()),
                display_name: None,
                status: AccountStatusSchema::Active,
            },
            body: "sentinel-response-ugc".to_owned(),
            status: CommentStatusSchema::Published,
            version: 1,
            created_at: "2026-08-01T00:00:00.000Z".to_owned(),
            updated_at: "2026-08-01T00:00:00.000Z".to_owned(),
            edited_at: None,
        };
        let envelope = CommentPageEnvelope {
            items: vec![response],
            next_cursor: None,
        };
        let debug = format!("{envelope:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("sentinel-response-ugc"));
    }
}
