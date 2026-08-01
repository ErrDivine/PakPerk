//! HTTP-only request and response DTOs.

mod accounts;
mod comments;
mod library;

pub(crate) use accounts::{
    AccountDeletionEnvelope, AccountDeletionResponse, AccountDeletionStateSchema,
    AccountProfileEnvelope, AccountProfileResponse, AccountStatusSchema,
    DeletionVerificationAccount, DeletionVerificationEnvelope, ProfilePatchField,
    ProfileUpdateBody,
};
pub(crate) use comments::{
    BlockedUserEnvelope, BlockedUserPageEnvelope, BlockedUserResponse, CommentAuthorResponse,
    CommentEnvelope, CommentListParams, CommentPageEnvelope, CommentReportEnvelope,
    CommentReportReasonBody, CommentReportResponse, CommentReportStatusSchema, CommentResponse,
    CommentStatusSchema, CreateCommentBody, EditCommentBody, ReportCommentBody, ReportUserBody,
    UserReportEnvelope, UserReportResponse,
};
#[allow(unused_imports)] // Preserve the crate-local DTO facade for route and schema consumers.
pub(crate) use library::{
    LibraryChangeEntryResponse, LibraryChangesEnvelope, LibraryChangesParams, LibraryItemResponse,
    LibraryListEntryResponse, LibraryListEnvelope, LibraryListParams, LibraryMutationEnvelope,
    LibrarySaveBody, LibraryStateBody,
};

use chrono::{SecondsFormat, Utc};
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
        assert_eq!(
            serde_json::from_str::<ReportCommentBody>(r#"{"reason":"privacy"}"#)
                .unwrap()
                .detail,
            None,
        );

        let user_report: ReportUserBody = serde_json::from_str(
            r#"{"reason":"impersonation","detail":"private account report context"}"#,
        )
        .unwrap();
        let debug = format!("{user_report:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("private account report context"));
        assert!(
            serde_json::from_str::<ReportUserBody>(r#"{"reason":"impersonation","detail":null}"#,)
                .is_ok()
        );
        assert_eq!(
            serde_json::from_str::<ReportUserBody>(r#"{"reason":"impersonation"}"#)
                .unwrap()
                .detail,
            None,
        );
        assert!(
            serde_json::from_str::<ReportUserBody>(
                r#"{"reason":"impersonation","detail":null,"block":true}"#,
            )
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
