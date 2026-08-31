//! HTTP-only request and response DTOs.

mod accounts;
mod assistant_v2;
mod comments;
mod discovery_search;
mod document_reader;
mod engagement;
mod interactions;
mod library;
mod library_v2;
mod paper_resolution;
mod passport;
mod reading_feed;
mod recommendations;
mod research_memory;
mod research_profiles;
mod version_diff;

pub(crate) use accounts::{
    AccountDeletionEnvelope, AccountDeletionResponse, AccountDeletionStateSchema,
    AccountProfileEnvelope, AccountProfileResponse, AccountStatusSchema,
    DeletionVerificationAccount, DeletionVerificationEnvelope, ProfilePatchField,
    ProfileUpdateBody,
};
pub(crate) use assistant_v2::{
    AssistantAnswerEnvelope, AssistantEvidenceFeedbackBody, AssistantEvidenceFeedbackEnvelope,
    AssistantEvidenceFeedbackStatusResponse, AssistantEvidenceFeedbackTypeBody,
    AssistantProvenanceEnvelope, AssistantRequestBody,
};
pub(crate) use comments::{
    BlockedUserEnvelope, BlockedUserPageEnvelope, BlockedUserResponse, CommentAuthorResponse,
    CommentEnvelope, CommentListParams, CommentPageEnvelope, CommentReportEnvelope,
    CommentReportReasonBody, CommentReportResponse, CommentReportStatusSchema, CommentResponse,
    CommentStatusSchema, CreateCommentBody, EditCommentBody, ReportCommentBody, ReportUserBody,
    UserReportEnvelope, UserReportResponse,
};
pub(crate) use discovery_search::{
    ExploreSearchBody, LookupSearchParams, SaveSearchBody, SavedSearchEnvelope,
    SavedSearchListEnvelope, SearchFiltersBody, SearchPageEnvelope, SearchSortBody,
    SearchSourceBody, SearchSuggestionsEnvelope, SuggestionSearchParams,
};
pub(crate) use document_reader::{
    DocumentBlocksEnvelope, DocumentBlocksParams, DocumentOutlineEnvelope, DocumentTermsParams,
    EquationsEnvelope, FigureEnvelope, FigureResponse, FiguresEnvelope, SourceLocatorResponse,
    TableEnvelope, TableResponse, TablesEnvelope, TermsEnvelope,
};
pub(crate) use engagement::{
    CreateReadingBriefBody, CreateSubscriptionBody, NotificationListParams,
    NotificationMutationEnvelope, NotificationPreferencesBody, NotificationPreferencesEnvelope,
    NotificationTypeFrequenciesBody, NotificationsEnvelope, ReadingBriefEnvelope,
    SubscriptionEnvelope, SubscriptionsEnvelope, UpdateReadingBriefProgressBody,
    UpdateSubscriptionBody,
};
pub(crate) use interactions::{
    PaperInteractionBatchBody, PaperInteractionBatchEnvelope, PaperInteractionBody,
};
#[allow(unused_imports)] // Preserve the crate-local DTO facade for route and schema consumers.
pub(crate) use library::{
    LibraryChangeEntryResponse, LibraryChangesEnvelope, LibraryChangesParams, LibraryItemResponse,
    LibraryListEntryResponse, LibraryListEnvelope, LibraryListParams, LibraryMutationEnvelope,
    LibrarySaveBody, LibraryStateBody,
};
pub(crate) use library_v2::{
    LibraryItemTagMutationEnvelope, LibraryListItemMutationEnvelope, LibraryListItemWriteBody,
    LibraryListMutationEnvelope, LibraryListPatchBody, LibraryListWriteBody, LibraryListsEnvelope,
    LibrarySaveSourceBody, LibraryTagMutationEnvelope, LibraryTagPatchBody, LibraryTagWriteBody,
    LibraryTagsEnvelope, LibraryV2ChangesEnvelope, LibraryV2ChangesParams, LibraryV2EntryResponse,
    LibraryV2ItemMutationEnvelope, LibraryV2ItemResponse, LibraryV2ItemWriteBody,
    LibraryV2ItemsEnvelope, LibraryV2ListParams, LibraryV2StateBody,
};
pub(crate) use paper_resolution::{
    PaperImportBody, PaperImportEnvelope, PaperImportSourceBody, PaperImportTargetStateBody,
    PaperInputKindBody, PaperSearchBody, PaperSearchEnvelope,
};
pub(crate) use passport::{
    PassportEnvelope, PassportFeedbackBody, PassportFeedbackEnvelope, ProvenanceEnvelope,
    ProvenanceRecordResponse, SemanticDensityBody, SemanticSpansEnvelope, SemanticSpansParams,
};
pub(crate) use reading_feed::{ReadingFeedBriefResponse, ReadingFeedEnvelope, ReadingFeedParams};
pub(crate) use recommendations::{
    RecommendationExplanationCodeResponse, RecommendationExplanationEnvelope,
    RecommendationFeedbackBody, RecommendationFeedbackEnvelope,
};
pub(crate) use research_memory::{
    AnnotationConflictEnvelope, AnnotationConflictListParams, AnnotationConflictPageEnvelope,
    AnnotationListParams, AnnotationMutationEnvelope, AnnotationPageEnvelope,
    AnnotationReanchorBody, AnnotationWriteBody, CheckpointListParams, CheckpointMutationEnvelope,
    CheckpointsEnvelope, CursorPageParams, EvidenceCardMutationEnvelope, EvidenceCardPageEnvelope,
    EvidenceCardWriteBody, MemoryItemWriteBody, MemoryMutationEnvelope, MemoryPageEnvelope,
    MemoryReviewBody, MemoryReviewParams, ReadingCheckpointWriteBody, ResearchAnnotationImportBody,
    ResearchAnnotationImportEnvelope, ResearchExportFormat, ResearchExportParams,
    RevisionDeleteParams,
};
#[allow(unused_imports)] // Preserve the crate-local DTO facade for route and schema consumers.
pub(crate) use research_profiles::{
    DiscoveryModeBody, ExplicitCategoryBody, InterestGroupResponse, InterestSourceBody,
    PreferredDiscoveryModeBody, ProfileAuthorResponse, ProfileCategoryResponse,
    ProfileTopicResponse, ResearchProfileEnvelope, ResearchProfileExportEnvelope,
    ResearchProfileInterestsEnvelope, ResearchProfileResponse, ResetResearchProfileBody,
    ResetScopeBody, TopicPolarityBody, UpdateResearchProfileBody, UpsertProfileAuthorBody,
    UpsertProfileTopicBody,
};
pub(crate) use version_diff::{
    DocumentVersionsEnvelope, PaperVersionDiffEnvelope, VersionDiffParams,
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

#[derive(Debug, Clone, Copy, Default, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PublicPreparationTrigger {
    #[default]
    IntroductionTransition,
    InspectEvidence,
    ExplicitPrepare,
}

impl From<PublicPreparationTrigger> for domain::PreparationTriggerKind {
    fn from(value: PublicPreparationTrigger) -> Self {
        match value {
            PublicPreparationTrigger::IntroductionTransition => Self::IntroductionTransition,
            PublicPreparationTrigger::InspectEvidence => Self::InspectEvidence,
            PublicPreparationTrigger::ExplicitPrepare => Self::ExplicitPrepare,
        }
    }
}

#[derive(Debug, Default, Deserialize, utoipa::ToSchema)]
pub(crate) struct PrepareBody {
    #[serde(default)]
    pub(crate) retry: bool,
    #[serde(default)]
    pub(crate) trigger: PublicPreparationTrigger,
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
    fn prepare_body_defaults_legacy_clients_to_committed_introduction() {
        let body: PrepareBody = serde_json::from_str(r#"{"retry":false}"#).unwrap();
        assert!(!body.retry);
        assert!(matches!(
            body.trigger,
            PublicPreparationTrigger::IntroductionTransition
        ));
    }

    #[test]
    fn prepare_body_rejects_metadata_only_origins() {
        for denied in [
            "manual_import",
            "queue_save",
            "reading_feed_prefetch",
            "recommendation_generation",
            "abstract_display",
            "notification_evaluation",
            "approved_reprocessing",
        ] {
            let json = format!(r#"{{"trigger":"{denied}"}}"#);
            assert!(
                serde_json::from_str::<PrepareBody>(&json).is_err(),
                "accepted forbidden public trigger {denied}"
            );
        }
    }

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
