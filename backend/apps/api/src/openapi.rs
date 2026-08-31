//! Code-first `OpenAPI` contract for the stable public paper API.

#![allow(dead_code, clippy::struct_excessive_bools)] // Schema-only contract mirrors wire JSON.

use axum::Json;
use serde::Serialize;
use utoipa::openapi::security::{HttpAuthScheme, HttpBuilder, SecurityScheme};
use utoipa::{Modify, OpenApi, ToSchema};

use crate::{
    dto::{
        AccountDeletionEnvelope, AccountDeletionResponse, AccountDeletionStateSchema,
        AccountProfileEnvelope, AccountProfileResponse, AccountStatusSchema,
        AnnotationConflictEnvelope, AnnotationConflictPageEnvelope, AnnotationMutationEnvelope,
        AnnotationPageEnvelope, AnnotationReanchorBody, AnnotationWriteBody,
        AssistantAnswerEnvelope, AssistantEvidenceFeedbackBody, AssistantEvidenceFeedbackEnvelope,
        AssistantEvidenceFeedbackStatusResponse, AssistantEvidenceFeedbackTypeBody,
        AssistantProvenanceEnvelope, AssistantRequestBody, BlockedUserEnvelope,
        BlockedUserPageEnvelope, BlockedUserResponse, ChatBody, CheckpointMutationEnvelope,
        CheckpointsEnvelope, CommentAuthorResponse, CommentEnvelope, CommentPageEnvelope,
        CommentReportEnvelope, CommentReportReasonBody, CommentReportResponse,
        CommentReportStatusSchema, CommentResponse, CommentStatusSchema, CreateCommentBody,
        CreateReadingBriefBody, CreateSubscriptionBody, DeletionVerificationAccount,
        DeletionVerificationEnvelope, DocumentBlocksEnvelope, DocumentOutlineEnvelope,
        DocumentVersionsEnvelope, EditCommentBody, EquationsEnvelope, EvidenceCardMutationEnvelope,
        EvidenceCardPageEnvelope, EvidenceCardWriteBody, ExploreSearchBody, FigureEnvelope,
        FiguresEnvelope, LibraryListItemWriteBody, LibraryListPatchBody, LibraryListWriteBody,
        LibrarySaveBody, LibrarySaveSourceBody, LibraryTagPatchBody, LibraryTagWriteBody,
        LibraryV2ItemWriteBody, LibraryV2StateBody, MemoryItemWriteBody, MemoryMutationEnvelope,
        MemoryPageEnvelope, MemoryReviewBody, NotificationPreferencesBody,
        NotificationTypeFrequenciesBody, PaperImportBody, PaperImportSourceBody,
        PaperInputKindBody, PaperInteractionBatchBody, PaperInteractionBatchEnvelope,
        PaperInteractionBody, PaperSearchBody, PaperVersionDiffEnvelope, PassportEnvelope,
        PassportFeedbackBody, PassportFeedbackEnvelope, PrepareBody, ProfileUpdateBody,
        ProvenanceEnvelope, ReadingCheckpointWriteBody, RecommendationExplanationCodeResponse,
        RecommendationExplanationEnvelope, RecommendationFeedbackBody,
        RecommendationFeedbackEnvelope, ReportCommentBody, ReportUserBody,
        ResearchAnnotationImportBody, ResearchAnnotationImportEnvelope, ResearchProfileEnvelope,
        ResearchProfileExportEnvelope, ResearchProfileInterestsEnvelope, ResetResearchProfileBody,
        SaveSearchBody, SearchFiltersBody, SearchSortBody, SearchSourceBody, SemanticSpansEnvelope,
        TableEnvelope, TablesEnvelope, TermsEnvelope, UpdateReadingBriefProgressBody,
        UpdateResearchProfileBody, UpdateSubscriptionBody, UpsertProfileAuthorBody,
        UpsertProfileTopicBody, UserReportEnvelope, UserReportResponse,
    },
    routes,
};

#[derive(OpenApi)]
#[openapi(
    info(
        title = "Pakperk API",
        version = "1.0.0",
        description = "Stable v1 paper-reading API with optional OIDC-backed account profiles, synchronized To Read libraries, and moderated flat paper comments. Comment publication has an independent emergency kill switch which preserves reads and safety controls."
    ),
    paths(
        routes::health::health_live,
        routes::health::health_ready,
        routes::feed::feed,
        routes::papers::paper_metadata,
        routes::papers::paper_by_arxiv,
        routes::papers::prepare,
        routes::papers::processing,
        routes::papers::introduction,
        routes::chat::chat,
        routes::assistant_v2::assistant,
        routes::assistant_v2::assistant_feedback,
        routes::assistant_v2::assistant_provenance,
        routes::papers::connections,
        routes::document_reader::document_outline,
        routes::document_reader::document_blocks,
        routes::document_reader::figures,
        routes::document_reader::figure,
        routes::document_reader::figure_asset,
        routes::document_reader::tables,
        routes::document_reader::table,
        routes::document_reader::equations,
        routes::document_reader::terms,
        routes::passport::passport,
        routes::passport::passport_feedback,
        routes::passport::semantic_spans,
        routes::passport::shared_provenance,
        routes::version_diff::paper_versions,
        routes::version_diff::paper_version_diff,
        routes::research_memory::list_annotations,
        routes::research_memory::list_annotation_conflicts,
        routes::research_memory::put_annotation,
        routes::research_memory::delete_annotation,
        routes::research_memory::reanchor_annotation,
        routes::research_memory::export_annotations,
        routes::research_memory::import_annotations,
        routes::research_memory::list_evidence_cards,
        routes::research_memory::create_evidence_card,
        routes::research_memory::put_evidence_card,
        routes::research_memory::delete_evidence_card,
        routes::research_memory::list_checkpoints,
        routes::research_memory::put_checkpoint,
        routes::research_memory::memory_review,
        routes::research_memory::create_memory_item,
        routes::research_memory::put_memory_item,
        routes::research_memory::review_memory_item,
        routes::research_memory::delete_memory_item,
        routes::account::get_me,
        routes::account::patch_me,
        routes::account::delete_me,
        routes::account::verify_deletion_identity,
        routes::library::list_library,
        routes::library::library_changes,
        routes::library::save_library_item,
        routes::library::remove_library_item,
        routes::library_v2::list_library_v2_items,
        routes::library_v2::put_library_v2_item,
        routes::library_v2::patch_library_v2_item,
        routes::library_v2::delete_library_v2_item,
        routes::library_v2::list_library_lists,
        routes::library_v2::create_library_list,
        routes::library_v2::update_library_list,
        routes::library_v2::delete_library_list,
        routes::library_v2::put_library_list_item,
        routes::library_v2::delete_library_list_item,
        routes::library_v2::list_library_tags,
        routes::library_v2::create_library_tag,
        routes::library_v2::update_library_tag,
        routes::library_v2::delete_library_tag,
        routes::library_v2::put_library_item_tag,
        routes::library_v2::delete_library_item_tag,
        routes::library_v2::library_v2_changes,
        routes::paper_search::search_papers,
        routes::library_imports::import_library_paper,
        routes::reading_feed::reading_feed,
        routes::research_profiles::get_research_profile,
        routes::research_profiles::update_research_profile,
        routes::research_profiles::get_research_profile_interests,
        routes::research_profiles::upsert_research_profile_topic,
        routes::research_profiles::delete_research_profile_topic,
        routes::research_profiles::upsert_research_profile_author,
        routes::research_profiles::delete_research_profile_author,
        routes::research_profiles::reset_research_profile,
        routes::research_profiles::export_research_profile,
        routes::recommendations::get_recommendation_explanation,
        routes::recommendations::post_recommendation_feedback,
        routes::interactions::post_interaction_batch,
        routes::discovery_search::lookup_search,
        routes::discovery_search::search_suggestions,
        routes::discovery_search::explore_search,
        routes::discovery_search::list_saved_searches,
        routes::discovery_search::save_search,
        routes::discovery_search::delete_saved_search,
        routes::engagement::create_reading_brief,
        routes::engagement::current_reading_brief,
        routes::engagement::update_reading_brief_progress,
        routes::engagement::list_subscriptions,
        routes::engagement::create_subscription,
        routes::engagement::update_subscription,
        routes::engagement::delete_subscription,
        routes::engagement::list_notifications,
        routes::engagement::mark_notification_read,
        routes::engagement::dismiss_notification,
        routes::engagement::mark_all_notifications_read,
        routes::engagement::get_notification_preferences,
        routes::engagement::put_notification_preferences,
        routes::comments::list_paper_comments,
        routes::comments::create_comment,
        routes::comments::edit_comment,
        routes::comments::delete_comment,
        routes::comments::report_comment,
        routes::comments::report_user,
        routes::comments::block_user,
        routes::comments::unblock_user,
        routes::comments::list_blocked_users,
        routes::comments::list_my_comments,
    ),
    components(schemas(
        PrepareBody,
        ChatBody,
        AssistantRequestBody,
        AssistantAnswerEnvelope,
        AssistantEvidenceFeedbackBody,
        AssistantEvidenceFeedbackTypeBody,
        AssistantEvidenceFeedbackEnvelope,
        AssistantEvidenceFeedbackStatusResponse,
        AssistantProvenanceEnvelope,
        ErrorEnvelopeSchema,
        ErrorBodySchema,
        HealthResponseSchema,
        CapabilitiesSchema,
        PaperSummarySchema,
        FeedPageSchema,
        ProcessingErrorSchema,
        FailureCategorySchema,
        ProcessingStateSchema,
        OverallProcessingStateSchema,
        ProcessingStageSchema,
        IntroductionSchema,
        IntroductionParagraphSchema,
        IntroductionCitationSchema,
        IntroductionCitationReferenceSchema,
        IntroductionDetectionSchema,
        ChatResponseSchema,
        ChatEvidenceSchema,
        SectionKindSchema,
        ConnectionsResponseSchema,
        DocumentOutlineEnvelope,
        DocumentBlocksEnvelope,
        FiguresEnvelope,
        FigureEnvelope,
        TablesEnvelope,
        TableEnvelope,
        EquationsEnvelope,
        TermsEnvelope,
        PassportEnvelope,
        PassportFeedbackBody,
        PassportFeedbackEnvelope,
        SemanticSpansEnvelope,
        ProvenanceEnvelope,
        DocumentVersionsEnvelope,
        PaperVersionDiffEnvelope,
        AnnotationWriteBody,
        AnnotationReanchorBody,
        AnnotationMutationEnvelope,
        AnnotationConflictEnvelope,
        AnnotationConflictPageEnvelope,
        AnnotationPageEnvelope,
        ResearchAnnotationImportBody,
        ResearchAnnotationImportEnvelope,
        EvidenceCardWriteBody,
        EvidenceCardMutationEnvelope,
        EvidenceCardPageEnvelope,
        ReadingCheckpointWriteBody,
        CheckpointMutationEnvelope,
        CheckpointsEnvelope,
        MemoryItemWriteBody,
        MemoryReviewBody,
        MemoryMutationEnvelope,
        MemoryPageEnvelope,
        KeyConnectionSchema,
        RelationTypeSchema,
        ConnectionReferenceSchema,
        ReferenceResolutionStatusSchema,
        AccountProfileEnvelope,
        AccountProfileResponse,
        AccountStatusSchema,
        AccountDeletionStateSchema,
        AccountDeletionResponse,
        AccountDeletionEnvelope,
        DeletionVerificationAccount,
        DeletionVerificationEnvelope,
        ProfileUpdateBody,
        LibrarySaveBody,
        LibraryStateSchema,
        LibraryItemSchema,
        LibraryMutationEnvelopeSchema,
        LibraryListEntrySchema,
        LibraryListEnvelopeSchema,
        LibraryChangeEntrySchema,
        LibraryChangesEnvelopeSchema,
        LibraryV2StateBody,
        LibrarySaveSourceBody,
        LibraryV2ItemWriteBody,
        LibraryListWriteBody,
        LibraryListPatchBody,
        LibraryTagWriteBody,
        LibraryTagPatchBody,
        LibraryListItemWriteBody,
        LibraryV2ItemSchema,
        LibraryV2EntrySchema,
        LibraryV2ItemsEnvelopeSchema,
        LibraryV2ItemMutationEnvelopeSchema,
        LibraryListSchema,
        LibraryListsEnvelopeSchema,
        LibraryListMutationEnvelopeSchema,
        LibraryListItemSchema,
        LibraryListItemMutationEnvelopeSchema,
        LibraryTagSchema,
        LibraryTagsEnvelopeSchema,
        LibraryTagMutationEnvelopeSchema,
        LibraryItemTagSchema,
        LibraryItemTagMutationEnvelopeSchema,
        LibraryV2ChangeSchema,
        LibraryV2ChangesEnvelopeSchema,
        PaperSearchBody,
        PaperSearchMatchSchema,
        PaperSearchCandidateSchema,
        PaperSearchEnvelopeSchema,
        PaperInputKindBody,
        PaperImportSourceBody,
        PaperImportBody,
        PaperImportResolutionSchema,
        PaperImportEnvelopeSchema,
        ReadingFeedModeSchema,
        RecommendationModeSchema,
        ReadingFeedItemSourceSchema,
        ReadingFeedDecisionSchema,
        ReadingFeedQueueSchema,
        ReadingFeedRecommendationSchema,
        ReadingFeedBatchMetadataSchema,
        ReadingFeedItemSchema,
        ReadingFeedBriefSchema,
        ReadingFeedEnvelopeSchema,
        UpdateResearchProfileBody,
        UpsertProfileTopicBody,
        UpsertProfileAuthorBody,
        ResetResearchProfileBody,
        ResearchProfileEnvelope,
        ResearchProfileInterestsEnvelope,
        ResearchProfileExportEnvelope,
        RecommendationFeedbackBody,
        RecommendationFeedbackEnvelope,
        RecommendationExplanationEnvelope,
        PaperInteractionBatchBody,
        PaperInteractionBody,
        PaperInteractionBatchEnvelope,
        ExploreSearchBody,
        SaveSearchBody,
        SearchFiltersBody,
        SearchSortBody,
        SearchSourceBody,
        SearchMatchKindSchema,
        SearchSourceStatusSchema,
        SearchSourceCoverageSchema,
        SearchResultSchema,
        SearchSourceDiagnosticSchema,
        RelatedTopicSchema,
        SearchSuggestionsEnvelopeSchema,
        GeneralSearchEnvelopeSchema,
        SavedSearchSchema,
        SavedSearchEnvelopeSchema,
        SavedSearchListEnvelopeSchema,
        CreateReadingBriefBody,
        UpdateReadingBriefProgressBody,
        CreateSubscriptionBody,
        UpdateSubscriptionBody,
        NotificationPreferencesBody,
        NotificationTypeFrequenciesBody,
        BriefModeSchema,
        BriefStatusSchema,
        ReadingBriefItemSchema,
        ReadingBriefSchema,
        ReadingBriefEnvelopeSchema,
        SubscriptionKindSchema,
        SubscriptionFrequencySchema,
        SubscriptionSchema,
        SubscriptionsEnvelopeSchema,
        SubscriptionEnvelopeSchema,
        NotificationTypeSchema,
        NotificationScopeSchema,
        NotificationEntityTypeSchema,
        NotificationDeliveryEligibilitySchema,
        NotificationSchema,
        NotificationsEnvelopeSchema,
        NotificationMutationEnvelopeSchema,
        NotificationTypeFrequenciesSchema,
        NotificationPreferencesSchema,
        NotificationPreferencesEnvelopeSchema,
        CreateCommentBody,
        EditCommentBody,
        ReportCommentBody,
        CommentReportReasonBody,
        CommentReportStatusSchema,
        CommentReportResponse,
        CommentReportEnvelope,
        ReportUserBody,
        UserReportResponse,
        UserReportEnvelope,
        CommentStatusSchema,
        CommentAuthorResponse,
        CommentResponse,
        CommentEnvelope,
        CommentPageEnvelope,
        BlockedUserResponse,
        BlockedUserEnvelope,
        BlockedUserPageEnvelope
    )),
    modifiers(&OidcSecurity),
    tags(
        (name = "health", description = "Process and dependency health"),
        (name = "papers", description = "Public paper reading and processing"),
        (name = "accounts", description = "OIDC-authenticated account profile"),
        (name = "library", description = "OIDC-authenticated synchronized To Read library"),
        (name = "paper resolution", description = "Authenticated bounded title search and exact library import"),
        (name = "reading feed", description = "Authenticated queue-first To Read and recommendation arbitration"),
        (name = "research profiles", description = "Authenticated future-discovery preferences, explicit follows, and transparent separated inferred interests; never queue authority"),
        (name = "recommendations", description = "Authenticated immutable recommendation explanations and explicit feedback; never queue authority"),
        (name = "events", description = "Optional bounded content-free events; never library or queue authority"),
        (name = "search", description = "Explicit metadata-only Lookup and Explore navigation with honest bounded-source diagnostics; saving papers remains a separate canonical library/import operation"),
        (name = "reading briefs", description = "Authenticated bounded snapshots built through canonical queue-first reading-feed arbitration"),
        (name = "subscriptions", description = "Authenticated metadata-only discovery subscriptions; never queue authority"),
        (name = "notifications", description = "Authenticated in-app notifications with queue-aware delivery gating; push and email remain unavailable"),
        (name = "comments", description = "Public flat paper comments and authenticated safety controls")
    )
)]
pub struct ApiDoc;

struct OidcSecurity;

impl Modify for OidcSecurity {
    fn modify(&self, openapi: &mut utoipa::openapi::OpenApi) {
        let components = openapi
            .components
            .get_or_insert_with(utoipa::openapi::Components::new);
        components.add_security_scheme(
            "oidcBearer",
            SecurityScheme::Http(
                HttpBuilder::new()
                    .scheme(HttpAuthScheme::Bearer)
                    .bearer_format("JWT")
                    .description(Some(
                        "OIDC access token validated against the configured issuer, audience, algorithm, and JWKS.",
                    ))
                    .build(),
            ),
        );
    }
}

/// Runtime contract endpoint. Application assembly exposes it only in
/// development and staging.
pub(crate) async fn openapi_json() -> Json<utoipa::openapi::OpenApi> {
    Json(ApiDoc::openapi())
}

/// Deterministic artifact hook used by CI/release tooling.
pub fn openapi_json_pretty() -> Result<String, serde_json::Error> {
    serde_json::to_string_pretty(&ApiDoc::openapi()).map(|mut json| {
        json.push('\n');
        json
    })
}

#[derive(Debug, Serialize, ToSchema)]
pub(crate) struct ErrorEnvelopeSchema {
    error: ErrorBodySchema,
}

#[derive(Debug, Serialize, ToSchema)]
pub(crate) struct ErrorBodySchema {
    /// Stable machine-readable error code.
    #[schema(example = "PAPER_NOT_FOUND")]
    code: String,
    #[schema(example = "The requested paper was not found.")]
    message: String,
    retryable: bool,
    request_id: uuid::Uuid,
}

#[derive(ToSchema)]
pub(crate) struct HealthResponseSchema {
    #[schema(example = "ok")]
    status: String,
}

#[derive(ToSchema)]
pub(crate) struct CapabilitiesSchema {
    metadata: bool,
    introduction: bool,
    chat: bool,
    connections: bool,
}

#[derive(ToSchema)]
pub(crate) struct PaperSummarySchema {
    paper_id: uuid::Uuid,
    #[schema(example = "2401.12345v2")]
    arxiv_id: String,
    title: String,
    #[schema(rename = "abstract")]
    abstract_text: String,
    authors: Vec<String>,
    primary_category: String,
    categories: Vec<String>,
    published_at: String,
    updated_at: String,
    abs_url: String,
    pdf_url: String,
    capabilities: CapabilitiesSchema,
}

#[derive(ToSchema)]
pub(crate) struct FeedPageSchema {
    items: Vec<PaperSummarySchema>,
    next_cursor: Option<String>,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LibraryStateSchema {
    ToRead,
}

#[derive(ToSchema)]
pub(crate) struct LibraryItemSchema {
    pub(crate) paper_id: uuid::Uuid,
    pub(crate) state: LibraryStateSchema,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) saved_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
    pub(crate) removed: bool,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    pub(crate) removed_at: Option<String>,
    /// Monotonic revision within the authenticated account; opaque outside
    /// that account.
    #[schema(minimum = 1)]
    pub(crate) revision: i64,
    pub(crate) last_operation_id: uuid::Uuid,
}

#[derive(ToSchema)]
pub(crate) struct LibraryMutationEnvelopeSchema {
    pub(crate) item: LibraryItemSchema,
}

#[derive(ToSchema)]
pub(crate) struct PaperSearchMatchSchema {
    #[schema(example = "title")]
    kind: String,
    #[schema(minimum = 1)]
    rank: usize,
}

#[derive(ToSchema)]
pub(crate) struct PaperSearchCandidateSchema {
    arxiv_id: String,
    title: String,
    authors: Vec<String>,
    #[schema(rename = "abstract")]
    abstract_text: String,
    primary_category: String,
    categories: Vec<String>,
    #[schema(value_type = String, format = DateTime)]
    published_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
    abs_url: String,
    #[schema(rename = "match")]
    match_value: PaperSearchMatchSchema,
}

#[derive(ToSchema)]
pub(crate) struct PaperSearchEnvelopeSchema {
    query_id: uuid::Uuid,
    normalized_query: String,
    candidates: Vec<PaperSearchCandidateSchema>,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SearchMatchKindSchema {
    ExactArxivId,
    ExactDoi,
    ExactTitle,
    ExactAuthor,
    Phrase,
    RelatedText,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SearchSourceStatusSchema {
    Queried,
    NoMatches,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SearchSourceCoverageSchema {
    Partial,
}

#[derive(ToSchema)]
pub(crate) struct SearchResultSchema {
    paper: PaperSummarySchema,
    match_kind: SearchMatchKindSchema,
    relevance_bucket: i64,
    source: SearchSourceBody,
}

#[derive(ToSchema)]
pub(crate) struct SearchSourceDiagnosticSchema {
    source: SearchSourceBody,
    status: SearchSourceStatusSchema,
    coverage: SearchSourceCoverageSchema,
    matches_returned: u32,
}

#[derive(ToSchema)]
pub(crate) struct RelatedTopicSchema {
    topic_id: uuid::Uuid,
    label: String,
    source_vocabulary: String,
}

#[derive(ToSchema)]
pub(crate) struct SearchSuggestionsEnvelopeSchema {
    normalized_query: String,
    #[schema(max_items = 8)]
    items: Vec<RelatedTopicSchema>,
}

#[derive(ToSchema)]
pub(crate) struct GeneralSearchEnvelopeSchema {
    normalized_query: String,
    items: Vec<SearchResultSchema>,
    #[schema(required = true, nullable, max_length = 512)]
    next_cursor: Option<String>,
    diagnostics: Vec<SearchSourceDiagnosticSchema>,
    related_topics: Vec<RelatedTopicSchema>,
    #[schema(required = false, nullable)]
    disclaimer: Option<String>,
}

#[derive(ToSchema)]
pub(crate) struct SavedSearchSchema {
    id: uuid::Uuid,
    query: String,
    filters: SearchFiltersBody,
    sort: SearchSortBody,
    #[schema(minimum = 1)]
    revision: i64,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
}

#[derive(ToSchema)]
pub(crate) struct SavedSearchEnvelopeSchema {
    saved_search: SavedSearchSchema,
}

#[derive(ToSchema)]
pub(crate) struct SavedSearchListEnvelopeSchema {
    items: Vec<SavedSearchSchema>,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BriefModeSchema {
    Queue,
    Discovery,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BriefStatusSchema {
    Current,
    Complete,
    Superseded,
}

#[derive(ToSchema)]
pub(crate) struct ReadingBriefItemSchema {
    ordinal: u16,
    paper: PaperSummarySchema,
    source: ReadingFeedItemSourceSchema,
    reason_codes: Vec<RecommendationExplanationCodeResponse>,
}

#[derive(ToSchema)]
pub(crate) struct ReadingBriefSchema {
    id: uuid::Uuid,
    mode: BriefModeSchema,
    #[schema(required = true, nullable)]
    recommendation_mode: Option<RecommendationModeSchema>,
    #[schema(minimum = 0)]
    library_revision: i64,
    #[schema(required = true, nullable)]
    recommendation_batch_id: Option<uuid::Uuid>,
    #[schema(value_type = String, format = Date)]
    local_date: String,
    #[schema(minimum = 0, maximum = 25)]
    position: u16,
    #[schema(minimum = 1)]
    progress_revision: i64,
    status: BriefStatusSchema,
    items: Vec<ReadingBriefItemSchema>,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    completed_at: Option<String>,
}

#[derive(ToSchema)]
pub(crate) struct ReadingBriefEnvelopeSchema {
    #[schema(required = true, nullable)]
    brief: Option<ReadingBriefSchema>,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SubscriptionKindSchema {
    Topic,
    Category,
    Author,
    SavedQuery,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SubscriptionFrequencySchema {
    Immediate,
    Daily,
    Weekly,
    Off,
}

#[derive(ToSchema)]
pub(crate) struct SubscriptionSchema {
    id: uuid::Uuid,
    kind: SubscriptionKindSchema,
    key: String,
    label: String,
    #[schema(required = true, nullable)]
    saved_search_id: Option<uuid::Uuid>,
    frequency: SubscriptionFrequencySchema,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    last_evaluated_at: Option<String>,
    #[schema(minimum = 1)]
    revision: i64,
    deleted: bool,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
}

#[derive(ToSchema)]
pub(crate) struct SubscriptionsEnvelopeSchema {
    items: Vec<SubscriptionSchema>,
}

#[derive(ToSchema)]
pub(crate) struct SubscriptionEnvelopeSchema {
    subscription: SubscriptionSchema,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NotificationTypeSchema {
    DiscoveryMatch,
    DiscoveryDigest,
    UserSelectedReminder,
    ActivePaperVersion,
    SyncFailure,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NotificationScopeSchema {
    QueueOwned,
    Discovery,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NotificationEntityTypeSchema {
    Paper,
    Subscription,
    Digest,
    Sync,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NotificationDeliveryEligibilitySchema {
    Eligible,
    DeferredQueueNonempty,
    DeferredUnknown,
    Expired,
}

#[derive(ToSchema)]
pub(crate) struct NotificationSchema {
    id: uuid::Uuid,
    notification_type: NotificationTypeSchema,
    scope: NotificationScopeSchema,
    entity_type: NotificationEntityTypeSchema,
    #[schema(required = true, nullable)]
    entity_id: Option<uuid::Uuid>,
    #[schema(value_type = Object)]
    payload: serde_json::Value,
    delivery_eligibility: NotificationDeliveryEligibilitySchema,
    #[schema(required = true, nullable, minimum = 0)]
    eligibility_library_revision: Option<i64>,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    read_at: Option<String>,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    expires_at: Option<String>,
    papers: Vec<PaperSummarySchema>,
}

#[derive(ToSchema)]
pub(crate) struct NotificationsEnvelopeSchema {
    items: Vec<NotificationSchema>,
}

#[derive(ToSchema)]
pub(crate) struct NotificationMutationEnvelopeSchema {
    affected: u64,
}

#[derive(ToSchema)]
pub(crate) struct NotificationTypeFrequenciesSchema {
    #[schema(default = "off")]
    discovery_match: SubscriptionFrequencySchema,
    #[schema(default = "daily")]
    discovery_digest: SubscriptionFrequencySchema,
    #[schema(default = "immediate")]
    user_selected_reminder: SubscriptionFrequencySchema,
    #[schema(default = "off")]
    active_paper_version: SubscriptionFrequencySchema,
    #[schema(default = "immediate")]
    sync_failure: SubscriptionFrequencySchema,
}

#[derive(ToSchema)]
pub(crate) struct NotificationPreferencesSchema {
    /// Deprecated compatibility projection. Direct match wins when enabled;
    /// otherwise this projects the digest frequency.
    #[schema(schema_with = deprecated_subscription_frequency_schema)]
    discovery_frequency: SubscriptionFrequencySchema,
    type_frequencies: NotificationTypeFrequenciesSchema,
    #[schema(required = true, nullable, value_type = String, example = "22:00:00")]
    quiet_hours_start: Option<String>,
    #[schema(required = true, nullable, value_type = String, example = "07:00:00")]
    quiet_hours_end: Option<String>,
    timezone: String,
    in_app_enabled: bool,
    push_enabled: bool,
    email_enabled: bool,
    global_pause: bool,
    /// Deprecated compatibility projection of `active_paper_version`.
    #[schema(deprecated)]
    active_updates_enabled: bool,
    #[schema(minimum = 1, maximum = 20)]
    daily_budget: u16,
    #[schema(minimum = 0)]
    revision: i64,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
}

#[derive(ToSchema)]
pub(crate) struct NotificationPreferencesEnvelopeSchema {
    preferences: NotificationPreferencesSchema,
}

fn deprecated_subscription_frequency_schema() -> utoipa::openapi::schema::Object {
    utoipa::openapi::schema::ObjectBuilder::new()
        .schema_type(utoipa::openapi::schema::Type::String)
        .enum_values(Some(["immediate", "daily", "weekly", "off"]))
        .deprecated(Some(utoipa::openapi::Deprecated::True))
        .build()
}

#[derive(ToSchema)]
pub(crate) struct PaperImportResolutionSchema {
    input_kind: PaperInputKindBody,
    canonical_arxiv_id: String,
}

#[derive(ToSchema)]
pub(crate) struct PaperImportEnvelopeSchema {
    #[schema(example = "saved")]
    result: String,
    resolution: PaperImportResolutionSchema,
    item: LibraryV2ItemSchema,
    paper: PaperSummarySchema,
    #[schema(minimum = 1)]
    sync_revision: i64,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReadingFeedModeSchema {
    ToRead,
    Recommendations,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReadingFeedEnforcementSchema {
    Shadow,
    Strict,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReadingFeedItemSourceSchema {
    ToRead,
    DiscoveryV1,
    RecentV1,
    FollowingV1,
    ForYouV1,
    ExploreV1,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RecommendationModeSchema {
    Recent,
    Following,
    ForYou,
    Explore,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReadingFeedPolicyVersionSchema {
    QueueFirstV1,
}

#[derive(ToSchema)]
pub(crate) struct ReadingFeedDecisionSchema {
    #[schema(minimum = 0)]
    library_revision: i64,
    active_to_read_count: u64,
    queue_proven_empty: bool,
    policy_version: ReadingFeedPolicyVersionSchema,
}

#[derive(ToSchema)]
pub(crate) struct ReadingFeedQueueSchema {
    state: LibraryV2StateBody,
    #[schema(value_type = String, format = DateTime)]
    saved_at: String,
    #[schema(minimum = 0)]
    revision: i64,
    #[schema(required = true, nullable)]
    save_source_kind: Option<LibrarySaveSourceBody>,
}

#[derive(ToSchema)]
pub(crate) struct ReadingFeedItemSchema {
    paper: PaperSummarySchema,
    #[schema(required = true, nullable)]
    queue: Option<ReadingFeedQueueSchema>,
    source: ReadingFeedItemSourceSchema,
    #[schema(required = true, nullable)]
    recommendation: Option<ReadingFeedRecommendationSchema>,
}

#[derive(ToSchema)]
pub(crate) struct ReadingFeedRecommendationSchema {
    mode: RecommendationModeSchema,
    reason_codes: Vec<RecommendationExplanationCodeResponse>,
    reason_label: String,
    explanation_available: bool,
}

#[derive(ToSchema)]
pub(crate) struct ReadingFeedBatchMetadataSchema {
    #[schema(required = true, nullable, minimum = 0)]
    profile_revision: Option<i64>,
    #[schema(minimum = 0)]
    feedback_revision: i64,
    #[schema(min_length = 1, max_length = 64)]
    algorithm_version: String,
    #[schema(min_length = 1, max_length = 64)]
    recommendation_policy_version: String,
}

#[derive(ToSchema)]
pub(crate) struct ReadingFeedBriefSchema {
    id: uuid::Uuid,
    #[schema(minimum = 0, maximum = 25)]
    position: u16,
    #[schema(minimum = 1, maximum = 25)]
    total: u16,
    complete: bool,
}

#[derive(ToSchema)]
pub(crate) struct ReadingFeedEnvelopeSchema {
    enforcement: ReadingFeedEnforcementSchema,
    mode: ReadingFeedModeSchema,
    decision: ReadingFeedDecisionSchema,
    /// Server-created provenance for this recommendation page; null exactly
    /// when `batch_metadata` is null. It may coexist with `next_cursor`, and a
    /// continuation can carry a different page-scoped batch identifier.
    #[schema(required = true, nullable)]
    batch_id: Option<uuid::Uuid>,
    /// Immutable persisted batch authority and implementation versions;
    /// present exactly when `batch_id` is present.
    #[schema(required = true, nullable)]
    batch_metadata: Option<ReadingFeedBatchMetadataSchema>,
    items: Vec<ReadingFeedItemSchema>,
    #[schema(required = true, nullable, max_length = 512)]
    next_cursor: Option<String>,
    #[schema(required = true, nullable)]
    brief: Option<ReadingFeedBriefSchema>,
    #[schema(value_type = String, format = DateTime)]
    server_time: String,
}

#[derive(ToSchema)]
pub(crate) struct LibraryListEntrySchema {
    pub(crate) item: LibraryItemSchema,
    pub(crate) paper: PaperSummarySchema,
}

#[derive(ToSchema)]
pub(crate) struct LibraryListEnvelopeSchema {
    pub(crate) items: Vec<LibraryListEntrySchema>,
    #[schema(required = true, nullable)]
    pub(crate) next_cursor: Option<String>,
    /// Committed account-scoped watermark captured by the first list page.
    #[schema(minimum = 0)]
    pub(crate) sync_revision: i64,
}

#[derive(ToSchema)]
pub(crate) struct LibraryChangeEntrySchema {
    pub(crate) item: LibraryItemSchema,
    #[schema(required = true, nullable)]
    pub(crate) paper: Option<PaperSummarySchema>,
}

#[derive(ToSchema)]
pub(crate) struct LibraryChangesEnvelopeSchema {
    pub(crate) items: Vec<LibraryChangeEntrySchema>,
    /// Next fully applied revision within the authenticated account.
    #[schema(minimum = 0)]
    pub(crate) next_after_revision: i64,
    pub(crate) has_more: bool,
    /// Committed account-scoped watermark; unrelated accounts never advance
    /// it.
    #[schema(minimum = 0)]
    pub(crate) sync_revision: i64,
}

#[derive(ToSchema)]
pub(crate) struct LibraryV2ItemSchema {
    paper_id: uuid::Uuid,
    state: LibraryV2StateBody,
    #[schema(required = true, nullable, max_length = 500)]
    private_note: Option<String>,
    #[schema(required = true, nullable)]
    save_source_kind: Option<LibrarySaveSourceBody>,
    /// User-selected UTC reminder. Null means no reminder.
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    reminder_at: Option<String>,
    #[schema(value_type = String, format = DateTime)]
    saved_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    reviewed_at: Option<String>,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    archived_at: Option<String>,
    removed: bool,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    removed_at: Option<String>,
    #[schema(minimum = 1)]
    revision: i64,
    last_operation_id: uuid::Uuid,
}

#[derive(ToSchema)]
pub(crate) struct LibraryV2EntrySchema {
    item: LibraryV2ItemSchema,
    paper: PaperSummarySchema,
}

#[derive(ToSchema)]
pub(crate) struct LibraryV2ItemsEnvelopeSchema {
    items: Vec<LibraryV2EntrySchema>,
    #[schema(required = true, nullable, max_length = 512)]
    next_cursor: Option<String>,
    #[schema(minimum = 0)]
    sync_revision: i64,
}

#[derive(ToSchema)]
pub(crate) struct LibraryV2ItemMutationEnvelopeSchema {
    item: LibraryV2ItemSchema,
    replayed: bool,
}

#[derive(ToSchema)]
pub(crate) struct LibraryListSchema {
    id: uuid::Uuid,
    name: String,
    #[schema(required = true, nullable)]
    description: Option<String>,
    sort_order: i32,
    #[schema(minimum = 1)]
    revision: i64,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    deleted_at: Option<String>,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
    last_operation_id: uuid::Uuid,
}

#[derive(ToSchema)]
pub(crate) struct LibraryListsEnvelopeSchema {
    items: Vec<LibraryListSchema>,
    #[schema(minimum = 0)]
    sync_revision: i64,
}

#[derive(ToSchema)]
pub(crate) struct LibraryListMutationEnvelopeSchema {
    list: LibraryListSchema,
    replayed: bool,
}

#[derive(ToSchema)]
pub(crate) struct LibraryListItemSchema {
    list_id: uuid::Uuid,
    paper_id: uuid::Uuid,
    position_rank: i64,
    #[schema(required = true, nullable, max_length = 500)]
    note: Option<String>,
    #[schema(minimum = 1)]
    revision: i64,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    deleted_at: Option<String>,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
    last_operation_id: uuid::Uuid,
}

#[derive(ToSchema)]
pub(crate) struct LibraryListItemMutationEnvelopeSchema {
    list_item: LibraryListItemSchema,
    replayed: bool,
}

#[derive(ToSchema)]
pub(crate) struct LibraryTagSchema {
    id: uuid::Uuid,
    name: String,
    #[schema(minimum = 1)]
    revision: i64,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    deleted_at: Option<String>,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
    last_operation_id: uuid::Uuid,
}

#[derive(ToSchema)]
pub(crate) struct LibraryTagsEnvelopeSchema {
    items: Vec<LibraryTagSchema>,
    #[schema(minimum = 0)]
    sync_revision: i64,
}

#[derive(ToSchema)]
pub(crate) struct LibraryTagMutationEnvelopeSchema {
    tag: LibraryTagSchema,
    replayed: bool,
}

#[derive(ToSchema)]
pub(crate) struct LibraryItemTagSchema {
    paper_id: uuid::Uuid,
    tag_id: uuid::Uuid,
    #[schema(minimum = 1)]
    revision: i64,
    #[schema(required = true, nullable, value_type = String, format = DateTime)]
    deleted_at: Option<String>,
    #[schema(value_type = String, format = DateTime)]
    created_at: String,
    #[schema(value_type = String, format = DateTime)]
    updated_at: String,
    last_operation_id: uuid::Uuid,
}

#[derive(ToSchema)]
pub(crate) struct LibraryItemTagMutationEnvelopeSchema {
    item_tag: LibraryItemTagSchema,
    replayed: bool,
}

#[derive(ToSchema)]
pub(crate) struct LibraryV2ChangeSchema {
    #[schema(example = "item")]
    entity: String,
    #[schema(required = true, nullable)]
    item: Option<LibraryV2ItemSchema>,
    #[schema(required = true, nullable)]
    paper: Option<Box<PaperSummarySchema>>,
    #[schema(required = true, nullable)]
    list: Option<LibraryListSchema>,
    #[schema(required = true, nullable)]
    list_item: Option<LibraryListItemSchema>,
    #[schema(required = true, nullable)]
    tag: Option<LibraryTagSchema>,
    #[schema(required = true, nullable)]
    item_tag: Option<LibraryItemTagSchema>,
}

#[derive(ToSchema)]
pub(crate) struct LibraryV2ChangesEnvelopeSchema {
    items: Vec<LibraryV2ChangeSchema>,
    #[schema(minimum = 0)]
    next_after_revision: i64,
    has_more: bool,
    #[schema(minimum = 0)]
    sync_revision: i64,
}

#[derive(ToSchema)]
pub(crate) struct ProcessingErrorSchema {
    category: FailureCategorySchema,
    code: String,
    message: String,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum FailureCategorySchema {
    ExternalTemporary,
    ExternalPermanent,
    ParserTemporary,
    ParserDocument,
    ModelTemporary,
    Validation,
    Internal,
}

#[derive(ToSchema)]
pub(crate) struct ProcessingStateSchema {
    paper_id: uuid::Uuid,
    generation: i32,
    overall_state: OverallProcessingStateSchema,
    stage: ProcessingStageSchema,
    capabilities: CapabilitiesSchema,
    retryable: bool,
    last_error: Option<ProcessingErrorSchema>,
    started_at: Option<String>,
    updated_at: String,
    completed_at: Option<String>,
    parser_version: Option<String>,
    embedding_model: Option<String>,
    summary_model: Option<String>,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OverallProcessingStateSchema {
    NotRequested,
    Processing,
    Ready,
    Failed,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ProcessingStageSchema {
    NotRequested,
    Queued,
    FetchingLicense,
    FetchingPdf,
    ParsingPdf,
    IntroductionReady,
    IndexingChat,
    ResolvingReferences,
    Ready,
    FailedRetryable,
    FailedTerminal,
}

#[derive(ToSchema)]
pub(crate) struct IntroductionParagraphSchema {
    ordinal: usize,
    text: String,
    heading: Option<String>,
    citations: Vec<IntroductionCitationSchema>,
    page_start: Option<u32>,
    page_end: Option<u32>,
}

#[derive(ToSchema)]
pub(crate) struct IntroductionCitationSchema {
    start: usize,
    end: usize,
    marker: String,
    references: Vec<IntroductionCitationReferenceSchema>,
}

#[derive(ToSchema)]
pub(crate) struct IntroductionCitationReferenceSchema {
    paper_id: uuid::Uuid,
    title: String,
}

#[derive(ToSchema)]
pub(crate) struct IntroductionDetectionSchema {
    confidence: f32,
    used_fallback: bool,
}

#[derive(ToSchema)]
pub(crate) struct IntroductionSchema {
    paper_id: uuid::Uuid,
    generation: i32,
    heading: Option<String>,
    paragraphs: Vec<IntroductionParagraphSchema>,
    detection: IntroductionDetectionSchema,
    original_pdf_url: String,
}

#[derive(ToSchema)]
pub(crate) struct ChatEvidenceSchema {
    section_kind: SectionKindSchema,
    section_heading: Option<String>,
    page_start: Option<u32>,
    page_end: Option<u32>,
    chunk_id: uuid::Uuid,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SectionKindSchema {
    Abstract,
    Introduction,
    Background,
    RelatedWork,
    Method,
    Experiment,
    Result,
    Discussion,
    Limitation,
    Conclusion,
    Appendix,
    Acknowledgment,
    References,
    Other,
}

#[derive(ToSchema)]
pub(crate) struct ChatResponseSchema {
    thread_id: uuid::Uuid,
    generation: i32,
    answer_markdown: String,
    insufficient_evidence: bool,
    evidence: Vec<ChatEvidenceSchema>,
    suggested_follow_ups: Vec<String>,
    model_id: Option<String>,
    provider_request_id: Option<String>,
    prompt_version: String,
}

#[derive(ToSchema)]
pub(crate) struct KeyConnectionSchema {
    reference_id: uuid::Uuid,
    paper_id: uuid::Uuid,
    arxiv_id: String,
    title: String,
    authors: Vec<String>,
    year: Option<i32>,
    relation_type: RelationTypeSchema,
    summary: String,
    confidence: f32,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RelationTypeSchema {
    BuildsOn,
    Uses,
    Extends,
    Applies,
    ComparesWith,
    ContrastsWith,
    Background,
    RelatedWork,
    Unknown,
}

#[derive(ToSchema)]
pub(crate) struct ConnectionReferenceSchema {
    ordinal: usize,
    raw_text: String,
    resolved: bool,
    paper_id: Option<uuid::Uuid>,
    title: Option<String>,
    resolution_status: ReferenceResolutionStatusSchema,
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReferenceResolutionStatusSchema {
    Unresolved,
    Resolving,
    Resolved,
    Ambiguous,
    NotArxiv,
    Failed,
}

#[derive(ToSchema)]
pub(crate) struct ConnectionsResponseSchema {
    paper_id: uuid::Uuid,
    generation: i32,
    ready: bool,
    key_connections: Vec<KeyConnectionSchema>,
    references: Vec<ConnectionReferenceSchema>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use domain::{
        FailureCategory, OverallProcessingState, ProcessingStage, ReferenceResolutionStatus,
        RelationType, SectionKind,
    };

    #[test]
    #[allow(clippy::too_many_lines)] // One closed route vector makes undocumented drift explicit.
    fn contract_covers_every_existing_public_route() {
        let document = ApiDoc::openapi();
        let actual = document
            .paths
            .paths
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let expected = [
            "/health/live",
            "/health/ready",
            "/v1/feed",
            "/v1/papers/{paper_id}",
            "/v1/papers/by-arxiv/{arxiv_id}",
            "/v1/papers/{paper_id}/prepare",
            "/v1/papers/{paper_id}/processing",
            "/v1/papers/{paper_id}/introduction",
            "/v1/papers/{paper_id}/chat",
            "/v1/papers/{paper_id}/connections",
            "/v1/papers/{paper_id}/document/outline",
            "/v1/papers/{paper_id}/document/blocks",
            "/v1/papers/{paper_id}/figures",
            "/v1/papers/{paper_id}/figures/{figure_id}",
            "/v1/papers/{paper_id}/figures/{figure_id}/asset",
            "/v1/papers/{paper_id}/tables",
            "/v1/papers/{paper_id}/tables/{table_id}",
            "/v1/papers/{paper_id}/equations",
            "/v1/papers/{paper_id}/terms",
            "/v1/papers/{paper_id}/passport",
            "/v1/papers/{paper_id}/passport/feedback",
            "/v1/papers/{paper_id}/semantic-spans",
            "/v1/papers/{paper_id}/provenance/{provenance_id}",
            "/v1/papers/{paper_id}/assistant",
            "/v1/papers/{paper_id}/assistant/feedback",
            "/v1/assistant/provenance/{provenance_id}",
            "/v1/papers/{paper_id}/versions",
            "/v1/papers/{paper_id}/version-diff",
            "/v1/annotations",
            "/v1/annotation-conflicts",
            "/v1/annotations/{annotation_id}",
            "/v1/annotations/{annotation_id}/reanchor",
            "/v1/annotations/export",
            "/v1/annotations/import",
            "/v1/evidence-cards",
            "/v1/evidence-cards/{id}",
            "/v1/reading/checkpoints",
            "/v1/reading/checkpoints/{paper_id}",
            "/v1/memory/review",
            "/v1/memory/items",
            "/v1/memory/items/{id}",
            "/v1/memory/items/{id}/review",
            "/v1/me",
            "/v1/me/deletion-verification",
            "/v1/me/library",
            "/v1/me/library/changes",
            "/v1/me/library/{paper_id}",
            "/v1/library/items",
            "/v1/library/papers/{paper_id}",
            "/v1/library/lists",
            "/v1/library/lists/{list_id}",
            "/v1/library/lists/{list_id}/papers/{paper_id}",
            "/v1/library/tags",
            "/v1/library/tags/{tag_id}",
            "/v1/library/papers/{paper_id}/tags/{tag_id}",
            "/v1/library/changes",
            "/v1/me/reading-feed",
            "/v1/discovery/profile",
            "/v1/discovery/profile/interests",
            "/v1/discovery/profile/topics/{topic_id}",
            "/v1/discovery/profile/authors/{author_key}",
            "/v1/discovery/profile/reset",
            "/v1/discovery/profile/export",
            "/v1/discovery/batches/{batch_id}/feedback",
            "/v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation",
            "/v1/events/batch",
            "/v1/search/lookup",
            "/v1/search/suggestions",
            "/v1/search/explore",
            "/v1/search/saved",
            "/v1/search/saved/{saved_search_id}",
            "/v1/me/reading-briefs",
            "/v1/me/reading-briefs/current",
            "/v1/me/reading-briefs/{id}/progress",
            "/v1/subscriptions",
            "/v1/subscriptions/{id}",
            "/v1/notifications",
            "/v1/notifications/{id}/read",
            "/v1/notifications/{id}/dismiss",
            "/v1/notifications/read-all",
            "/v1/notification-preferences",
            "/v1/me/paper-searches",
            "/v1/me/library/imports",
            "/v1/papers/{paper_id}/comments",
            "/v1/comments/{comment_id}",
            "/v1/comments/{comment_id}/reports",
            "/v1/users/{user_id}/reports",
            "/v1/me/blocked-users/{user_id}",
            "/v1/me/blocked-users",
            "/v1/me/comments",
        ];
        for path in expected {
            assert!(actual.contains(&path), "OpenAPI is missing {path}");
        }
        assert_eq!(
            actual.len(),
            expected.len(),
            "unexpected undocumented route drift"
        );
    }

    #[test]
    fn account_contract_requires_oidc_and_documents_concurrency_headers() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        assert_eq!(
            document["components"]["securitySchemes"]["oidcBearer"]["scheme"],
            "bearer"
        );
        assert_eq!(
            document["components"]["securitySchemes"]["oidcBearer"]["bearerFormat"],
            "JWT"
        );

        let path = &document["paths"]["/v1/me"];
        for method in ["get", "patch"] {
            assert_eq!(path[method]["security"][0]["oidcBearer"], json!([]));
            assert!(path[method]["responses"]["200"]["headers"]["ETag"].is_object());
            assert!(path[method]["responses"]["200"]["headers"]["Cache-Control"].is_object());
            assert!(path[method]["responses"]["401"]["headers"]["WWW-Authenticate"].is_object());
            assert!(path[method]["responses"]["503"]["headers"]["Retry-After"].is_object());
        }
        assert!(
            path["patch"]["parameters"]
                .as_array()
                .unwrap()
                .iter()
                .any(|parameter| {
                    parameter["name"] == "If-Match"
                        && parameter["in"] == "header"
                        && parameter["required"] == true
                })
        );
        assert!(path["patch"]["responses"]["412"]["headers"]["ETag"].is_object());
        assert!(path["patch"]["responses"]["429"]["headers"]["Retry-After"].is_object());
        assert!(path["patch"]["responses"]["428"].is_object());

        let required = document["components"]["schemas"]["AccountProfileResponse"]["required"]
            .as_array()
            .unwrap();
        for field in [
            "handle",
            "display_name",
            "terms_version",
            "terms_accepted_at",
            "community_guidelines_version",
            "community_guidelines_accepted_at",
            "current_community_guidelines_version",
            "community_guidelines_current",
            "comment_profile_complete",
        ] {
            assert!(required.iter().any(|required| required == field));
        }
    }

    #[test]
    fn deletion_contract_is_recent_auth_private_and_idempotency_header_free() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let delete = &document["paths"]["/v1/me"]["delete"];
        assert_eq!(delete["security"][0]["oidcBearer"], json!([]));
        assert!(
            delete["description"]
                .as_str()
                .is_some_and(|description| description.contains("Every request, including an identity-scoped replay, requires recent authentication"))
        );
        assert!(delete.get("requestBody").is_none());
        assert!(delete["parameters"].as_array().is_none_or(|parameters| {
            parameters
                .iter()
                .all(|parameter| parameter["name"] != "Idempotency-Key")
        }));
        assert!(delete["responses"]["202"]["headers"]["Cache-Control"].is_object());
        assert!(delete["responses"]["401"]["headers"]["WWW-Authenticate"].is_object());
        for status in ["429", "503"] {
            assert!(delete["responses"][status]["headers"]["Retry-After"].is_object());
        }
        assert!(
            delete["responses"]["503"]["description"]
                .as_str()
                .is_some_and(|description| description.contains("SERVICE_UNAVAILABLE"))
        );

        let verify = &document["paths"]["/v1/me/deletion-verification"]["get"];
        assert_eq!(verify["security"][0]["oidcBearer"], json!([]));
        assert!(verify["responses"]["200"]["headers"]["Cache-Control"].is_object());
        assert!(verify["responses"]["404"].is_object());
    }

    #[test]
    fn paper_operations_allow_guest_or_oidc_while_health_is_public_and_no_store() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for (path, method) in [
            ("/v1/feed", "get"),
            ("/v1/papers/{paper_id}", "get"),
            ("/v1/papers/by-arxiv/{arxiv_id}", "get"),
            ("/v1/papers/{paper_id}/prepare", "post"),
            ("/v1/papers/{paper_id}/processing", "get"),
            ("/v1/papers/{paper_id}/introduction", "get"),
            ("/v1/papers/{paper_id}/chat", "post"),
            ("/v1/papers/{paper_id}/connections", "get"),
        ] {
            let security = document["paths"][path][method]["security"]
                .as_array()
                .unwrap();
            assert!(security.iter().any(|requirement| requirement == &json!({})));
            assert!(security.iter().any(|requirement| {
                requirement
                    .get("oidcBearer")
                    .is_some_and(|scopes| scopes == &json!([]))
            }));
        }
        for path in ["/health/live", "/health/ready"] {
            let operation = &document["paths"][path]["get"];
            assert!(operation.get("security").is_none());
            assert!(operation["responses"]["200"]["headers"]["Cache-Control"].is_object());
        }
        assert!(
            document["paths"]["/health/ready"]["get"]["responses"]["503"]["headers"]
                ["Cache-Control"]
                .is_object()
        );
    }

    #[test]
    fn library_contract_requires_auth_idempotency_and_private_responses() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for (path, method) in [
            ("/v1/me/library", "get"),
            ("/v1/me/library/changes", "get"),
            ("/v1/me/library/{paper_id}", "put"),
            ("/v1/me/library/{paper_id}", "delete"),
        ] {
            let operation = &document["paths"][path][method];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert!(
                operation["responses"]["200"]["headers"]["Cache-Control"].is_object(),
                "{method} {path} must document private cache control"
            );
            assert!(operation["responses"]["401"]["headers"]["WWW-Authenticate"].is_object());
            assert!(
                operation["description"]
                    .as_str()
                    .is_some_and(|description| description.contains("never schedules")
                        || description.contains("never schedules preparation")
                        || method == "put"
                        || method == "delete")
            );
        }

        for method in ["put", "delete"] {
            let parameters = document["paths"]["/v1/me/library/{paper_id}"][method]["parameters"]
                .as_array()
                .unwrap();
            assert!(parameters.iter().any(|parameter| {
                parameter["name"] == "Idempotency-Key"
                    && parameter["in"] == "header"
                    && parameter["required"] == true
                    && parameter["schema"]["format"] == "uuid"
            }));
            assert!(
                document["paths"]["/v1/me/library/{paper_id}"][method]["responses"]["409"]
                    .is_object()
            );
            assert!(
                document["paths"]["/v1/me/library/{paper_id}"][method]["responses"]["429"]
                    ["headers"]["Retry-After"]
                    .is_object()
            );
        }
        assert!(document["paths"]["/v1/me/library/changes"]["get"]["responses"]["410"].is_object());
        assert!(
            document["paths"]["/v1/me/library/{paper_id}"]["delete"]
                .get("requestBody")
                .is_none()
        );
    }

    #[test]
    fn library_v2_contract_is_closed_private_and_revisioned() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let operations = [
            ("/v1/library/items", "get", false),
            ("/v1/library/papers/{paper_id}", "put", true),
            ("/v1/library/papers/{paper_id}", "patch", true),
            ("/v1/library/papers/{paper_id}", "delete", true),
            ("/v1/library/lists", "get", false),
            ("/v1/library/lists", "post", true),
            ("/v1/library/lists/{list_id}", "patch", true),
            ("/v1/library/lists/{list_id}", "delete", true),
            ("/v1/library/lists/{list_id}/papers/{paper_id}", "put", true),
            (
                "/v1/library/lists/{list_id}/papers/{paper_id}",
                "delete",
                true,
            ),
            ("/v1/library/tags", "get", false),
            ("/v1/library/tags", "post", true),
            ("/v1/library/tags/{tag_id}", "patch", true),
            ("/v1/library/tags/{tag_id}", "delete", true),
            ("/v1/library/papers/{paper_id}/tags/{tag_id}", "put", true),
            (
                "/v1/library/papers/{paper_id}/tags/{tag_id}",
                "delete",
                true,
            ),
            ("/v1/library/changes", "get", false),
        ];
        for (path, method, mutating) in operations {
            let operation = &document["paths"][path][method];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert!(operation["responses"]["200"]["headers"]["Cache-Control"].is_object());
            assert_eq!(
                operation["responses"]["200"]["headers"]["Vary"]["description"],
                "Always Authorization"
            );
            if mutating {
                assert!(operation["parameters"].as_array().unwrap().iter().any(
                    |parameter| parameter["name"] == "Idempotency-Key"
                        && parameter["in"] == "header"
                        && parameter["required"] == true
                ));
            }
        }
        assert!(document["paths"]["/v1/library/changes"]["get"]["responses"]["410"].is_object());
        assert_eq!(
            document["components"]["schemas"]["LibraryV2StateBody"]["enum"],
            json!(["inbox", "read_next", "reading", "reviewed", "archived"])
        );
        assert_eq!(
            document["components"]["schemas"]["LibrarySaveSourceBody"]["enum"],
            json!([
                "discovery",
                "lookup",
                "title_search",
                "arxiv_url",
                "arxiv_id",
                "connection",
                "other"
            ])
        );
        let queue_required =
            document["components"]["schemas"]["ReadingFeedQueueSchema"]["required"]
                .as_array()
                .unwrap();
        for field in ["state", "saved_at", "revision", "save_source_kind"] {
            assert!(queue_required.contains(&json!(field)));
        }
        let write = &document["components"]["schemas"]["LibraryV2ItemWriteBody"];
        assert_eq!(write["additionalProperties"], false);
        assert!(
            !write["required"]
                .as_array()
                .unwrap()
                .contains(&json!("reminder_at"))
        );
        let reminder_write = &write["properties"]["reminder_at"];
        assert!(
            reminder_write["nullable"] == true
                || reminder_write["type"]
                    .as_array()
                    .is_some_and(|types| types.contains(&json!("null")))
                || reminder_write["oneOf"]
                    .as_array()
                    .is_some_and(|variants| variants.iter().any(|value| value["type"] == "null"))
        );
        assert!(
            reminder_write["description"]
                .as_str()
                .unwrap()
                .contains("Omitted preserves")
        );
        let response = &document["components"]["schemas"]["LibraryV2ItemSchema"];
        assert!(
            response["required"]
                .as_array()
                .unwrap()
                .contains(&json!("reminder_at"))
        );
        assert_eq!(response["properties"]["reminder_at"]["format"], "date-time");
    }

    #[test]
    fn reading_feed_contract_is_private_authenticated_and_revision_fenced() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let operation = &document["paths"]["/v1/me/reading-feed"]["get"];
        assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
        let parameters = operation["parameters"].as_array().unwrap();
        for expected in [
            "category",
            "recommendation_mode",
            "cursor",
            "limit",
            "brief_id",
        ] {
            assert!(
                parameters
                    .iter()
                    .any(|parameter| parameter["name"] == expected)
            );
        }
        assert!(
            operation["description"]
                .as_str()
                .unwrap()
                .contains("authority-revalidated progress summary")
        );
        assert_eq!(
            operation["responses"]["200"]["headers"]["Cache-Control"]["description"],
            "Always private, no-store"
        );
        assert_eq!(
            operation["responses"]["200"]["headers"]["Vary"]["description"],
            "Always Authorization"
        );
        assert!(
            operation["responses"]["409"]["description"]
                .as_str()
                .unwrap()
                .contains("READING_FEED_CURSOR_STALE")
        );

        let schema = &document["components"]["schemas"]["ReadingFeedEnvelopeSchema"];
        for field in [
            "enforcement",
            "mode",
            "decision",
            "batch_id",
            "batch_metadata",
            "items",
            "next_cursor",
            "brief",
            "server_time",
        ] {
            assert!(
                schema["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(field))
            );
        }
        assert_eq!(
            schema["properties"]["brief"]["oneOf"][1]["$ref"],
            "#/components/schemas/ReadingFeedBriefSchema"
        );
        assert_reading_feed_batch_metadata_schema(&document, schema);
        let brief = &document["components"]["schemas"]["ReadingFeedBriefSchema"];
        for field in ["id", "position", "total", "complete"] {
            assert!(
                brief["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(field))
            );
        }
        assert!(
            document["components"]["schemas"]["ReadingFeedModeSchema"]["enum"]
                .as_array()
                .unwrap()
                .contains(&json!("recommendations"))
        );
        assert_eq!(
            document["components"]["schemas"]["ReadingFeedEnforcementSchema"]["enum"],
            json!(["shadow", "strict"])
        );
        assert_eq!(
            document["components"]["schemas"]["RecommendationModeSchema"]["enum"],
            json!(["recent", "following", "for_you", "explore"])
        );
        assert!(
            document["components"]["schemas"]["ReadingFeedDecisionSchema"]["required"]
                .as_array()
                .unwrap()
                .contains(&json!("policy_version"))
        );
        assert_eq!(
            document["components"]["schemas"]["ReadingFeedPolicyVersionSchema"]["enum"],
            json!(["queue_first_v1"])
        );
        let item = &document["components"]["schemas"]["ReadingFeedItemSchema"];
        for field in ["paper", "queue", "source", "recommendation"] {
            assert!(item["required"].as_array().unwrap().contains(&json!(field)));
        }
    }

    #[test]
    fn annotation_conflicts_are_private_and_authenticated() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let operation = &document["paths"]["/v1/annotation-conflicts"]["get"];
        assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
        assert_eq!(
            operation["responses"]["200"]["headers"]["Cache-Control"]["description"],
            "Always private, no-store"
        );
        assert_eq!(
            operation["responses"]["200"]["headers"]["Vary"]["description"],
            "Always Authorization"
        );
    }

    #[test]
    fn research_export_documents_lossless_private_paging() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let operation = &document["paths"]["/v1/annotations/export"]["get"];
        assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
        let parameters = operation["parameters"].as_array().unwrap();
        for expected in ["format", "paper_id", "paged", "cursor"] {
            assert!(
                parameters
                    .iter()
                    .any(|parameter| parameter["name"] == expected),
                "missing export parameter {expected}"
            );
        }
        for header in [
            "X-Pakperk-Export-Next-Cursor",
            "X-Pakperk-Export-Complete",
            "X-Pakperk-Export-Page",
        ] {
            assert!(operation["responses"]["200"]["headers"][header].is_object());
        }
    }

    fn assert_reading_feed_batch_metadata_schema(
        document: &serde_json::Value,
        envelope: &serde_json::Value,
    ) {
        assert_eq!(
            envelope["properties"]["batch_metadata"]["oneOf"][1]["$ref"],
            "#/components/schemas/ReadingFeedBatchMetadataSchema"
        );
        let metadata = &document["components"]["schemas"]["ReadingFeedBatchMetadataSchema"];
        for field in [
            "profile_revision",
            "feedback_revision",
            "algorithm_version",
            "recommendation_policy_version",
        ] {
            assert!(
                metadata["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(field))
            );
        }
        let profile_revision = &metadata["properties"]["profile_revision"];
        let profile_is_nullable = profile_revision["nullable"] == true
            || profile_revision["type"]
                .as_array()
                .is_some_and(|types| types.contains(&json!("null")))
            || profile_revision["oneOf"]
                .as_array()
                .is_some_and(|schemas| schemas.iter().any(|schema| schema["type"] == "null"));
        let profile_is_nonnegative = profile_revision["minimum"] == 0
            || profile_revision["oneOf"]
                .as_array()
                .is_some_and(|schemas| schemas.iter().any(|schema| schema["minimum"] == 0));
        assert!(profile_is_nullable);
        assert!(profile_is_nonnegative);
        assert_eq!(metadata["properties"]["feedback_revision"]["minimum"], 0);
        for field in ["algorithm_version", "recommendation_policy_version"] {
            assert_eq!(metadata["properties"][field]["minLength"], 1);
            assert_eq!(metadata["properties"][field]["maxLength"], 64);
        }
    }

    fn assert_engagement_closed_enums(document: &serde_json::Value) {
        assert_eq!(
            document["components"]["schemas"]["BriefModeSchema"]["enum"],
            json!(["queue", "discovery"])
        );
        assert_eq!(
            document["components"]["schemas"]["SubscriptionKindSchema"]["enum"],
            json!(["topic", "category", "author", "saved_query"])
        );
        assert_eq!(
            document["components"]["schemas"]["BriefStatusSchema"]["enum"],
            json!(["current", "complete", "superseded"])
        );
        assert_eq!(
            document["components"]["schemas"]["SubscriptionFrequencySchema"]["enum"],
            json!(["immediate", "daily", "weekly", "off"])
        );
        assert_eq!(
            document["components"]["schemas"]["NotificationTypeSchema"]["enum"],
            json!([
                "discovery_match",
                "discovery_digest",
                "user_selected_reminder",
                "active_paper_version",
                "sync_failure"
            ])
        );
        assert_eq!(
            document["components"]["schemas"]["NotificationTypeSchema"]["enum"],
            serde_json::to_value(engagement::NotificationType::ALL).unwrap()
        );
        assert_eq!(
            document["components"]["schemas"]["NotificationScopeSchema"]["enum"],
            json!(["queue_owned", "discovery"])
        );
        assert_eq!(
            document["components"]["schemas"]["NotificationEntityTypeSchema"]["enum"],
            json!(["paper", "subscription", "digest", "sync"])
        );
        assert_eq!(
            document["components"]["schemas"]["NotificationEntityTypeSchema"]["enum"],
            serde_json::to_value(engagement::NotificationEntityType::ALL).unwrap()
        );
        assert_eq!(
            document["components"]["schemas"]["NotificationDeliveryEligibilitySchema"]["enum"],
            json!([
                "eligible",
                "deferred_queue_nonempty",
                "deferred_unknown",
                "expired"
            ])
        );
    }

    fn assert_notification_type_frequency_schema(
        document: &serde_json::Value,
        schema_name: &str,
        frequency_schema_name: &str,
    ) {
        let schema = &document["components"]["schemas"][schema_name];
        let expected_fields = [
            "active_paper_version",
            "discovery_digest",
            "discovery_match",
            "sync_failure",
            "user_selected_reminder",
        ];
        let mut properties = schema["properties"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        properties.sort_unstable();
        assert_eq!(properties, expected_fields);
        let mut required = schema["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap())
            .collect::<Vec<_>>();
        required.sort_unstable();
        let expected_required = if schema_name == "NotificationTypeFrequenciesBody" {
            expected_fields
                .iter()
                .copied()
                .filter(|field| *field != "user_selected_reminder")
                .collect::<Vec<_>>()
        } else {
            expected_fields.to_vec()
        };
        assert_eq!(required, expected_required);
        for (field, default) in [
            ("discovery_match", "off"),
            ("discovery_digest", "daily"),
            ("user_selected_reminder", "immediate"),
            ("active_paper_version", "off"),
            ("sync_failure", "immediate"),
        ] {
            assert_eq!(schema["properties"][field]["default"], default);
            let expected_ref = format!("#/components/schemas/{frequency_schema_name}");
            assert!(
                schema["properties"][field]["$ref"] == expected_ref
                    || schema["properties"][field]["oneOf"]
                        .as_array()
                        .is_some_and(|variants| variants
                            .iter()
                            .any(|value| value["$ref"] == expected_ref))
            );
        }
    }

    fn assert_notification_preference_contract(document: &serde_json::Value) {
        let preferences = &document["components"]["schemas"]["NotificationPreferencesBody"];
        assert_eq!(preferences["additionalProperties"], false);
        assert!(
            preferences["required"]
                .as_array()
                .unwrap()
                .contains(&json!("discovery_frequency"))
        );
        assert!(
            !preferences["required"]
                .as_array()
                .unwrap()
                .contains(&json!("type_frequencies"))
        );
        assert_eq!(
            preferences["properties"]["type_frequencies"]["oneOf"][1]["$ref"],
            "#/components/schemas/NotificationTypeFrequenciesBody"
        );
        for legacy in ["discovery_frequency", "active_updates_enabled"] {
            assert_eq!(preferences["properties"][legacy]["deprecated"], true);
        }
        assert_eq!(
            preferences["properties"]["discovery_frequency"]["enum"],
            json!(["immediate", "daily", "weekly", "off"])
        );
        for disabled_channel in ["push_enabled", "email_enabled"] {
            assert_eq!(
                preferences["properties"][disabled_channel]["type"],
                "boolean"
            );
            assert_eq!(
                preferences["properties"][disabled_channel]["enum"],
                json!([false])
            );
        }
        assert_notification_type_frequency_schema(
            document,
            "NotificationTypeFrequenciesBody",
            "SubscriptionFrequencyBody",
        );
        assert_eq!(
            document["components"]["schemas"]["NotificationTypeFrequenciesBody"]["additionalProperties"],
            false
        );

        let response = &document["components"]["schemas"]["NotificationPreferencesSchema"];
        assert!(
            response["required"]
                .as_array()
                .unwrap()
                .contains(&json!("type_frequencies"))
        );
        assert_eq!(
            response["properties"]["type_frequencies"]["$ref"],
            "#/components/schemas/NotificationTypeFrequenciesSchema"
        );
        for legacy in ["discovery_frequency", "active_updates_enabled"] {
            assert_eq!(response["properties"][legacy]["deprecated"], true);
        }
        assert_eq!(
            response["properties"]["discovery_frequency"]["enum"],
            json!(["immediate", "daily", "weekly", "off"])
        );
        assert_notification_type_frequency_schema(
            document,
            "NotificationTypeFrequenciesSchema",
            "SubscriptionFrequencySchema",
        );
    }

    #[test]
    fn engagement_contract_is_private_closed_and_never_exposes_push_delivery() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for (path, method, idempotent) in [
            ("/v1/me/reading-briefs", "post", true),
            ("/v1/me/reading-briefs/current", "get", false),
            ("/v1/me/reading-briefs/{id}/progress", "post", true),
            ("/v1/subscriptions", "get", false),
            ("/v1/subscriptions", "post", true),
            ("/v1/subscriptions/{id}", "patch", true),
            ("/v1/subscriptions/{id}", "delete", true),
            ("/v1/notifications", "get", false),
            ("/v1/notifications/{id}/read", "post", false),
            ("/v1/notifications/{id}/dismiss", "post", false),
            ("/v1/notifications/read-all", "post", false),
            ("/v1/notification-preferences", "get", false),
            ("/v1/notification-preferences", "put", true),
        ] {
            let operation = &document["paths"][path][method];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert_eq!(
                operation["responses"]["200"]["headers"]["Cache-Control"]["description"],
                "Always private, no-store"
            );
            assert_eq!(
                operation["responses"]["200"]["headers"]["Vary"]["description"],
                "Always Authorization"
            );
            if idempotent {
                assert!(operation["parameters"].as_array().unwrap().iter().any(
                    |parameter| parameter["name"] == "Idempotency-Key"
                        && parameter["in"] == "header"
                        && parameter["required"] == true
                ));
            }
        }
        let notification_parameters = document["paths"]["/v1/notifications"]["get"]["parameters"]
            .as_array()
            .unwrap();
        assert_eq!(notification_parameters.len(), 1);
        assert_eq!(notification_parameters[0]["name"], "limit");
        assert_eq!(notification_parameters[0]["in"], "query");

        assert_engagement_closed_enums(&document);
        assert_notification_preference_contract(&document);
        let brief = &document["components"]["schemas"]["ReadingBriefSchema"];
        for field in ["position", "progress_revision", "completed_at"] {
            assert!(
                brief["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(field))
            );
        }
    }

    #[test]
    fn research_profile_contract_is_private_revisioned_and_cannot_control_the_queue() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for (path, method) in [
            ("/v1/discovery/profile", "get"),
            ("/v1/discovery/profile", "put"),
            ("/v1/discovery/profile/interests", "get"),
            ("/v1/discovery/profile/topics/{topic_id}", "put"),
            ("/v1/discovery/profile/topics/{topic_id}", "delete"),
            ("/v1/discovery/profile/authors/{author_key}", "put"),
            ("/v1/discovery/profile/authors/{author_key}", "delete"),
            ("/v1/discovery/profile/reset", "post"),
            ("/v1/discovery/profile/export", "get"),
        ] {
            let operation = &document["paths"][path][method];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert!(
                operation["responses"]["200"]["headers"]["Cache-Control"].is_object(),
                "{method} {path} must document private no-store responses"
            );
        }

        for (path, method) in [
            ("/v1/discovery/profile", "put"),
            ("/v1/discovery/profile/topics/{topic_id}", "put"),
            ("/v1/discovery/profile/topics/{topic_id}", "delete"),
            ("/v1/discovery/profile/authors/{author_key}", "put"),
            ("/v1/discovery/profile/authors/{author_key}", "delete"),
            ("/v1/discovery/profile/reset", "post"),
        ] {
            let parameters = document["paths"][path][method]["parameters"]
                .as_array()
                .unwrap();
            for expected in ["If-Match", "Idempotency-Key"] {
                assert!(parameters.iter().any(|parameter| {
                    parameter["name"] == expected
                        && parameter["in"] == "header"
                        && parameter["required"] == true
                }));
            }
        }
        for path in [
            "/v1/discovery/profile/topics/{topic_id}",
            "/v1/discovery/profile/authors/{author_key}",
        ] {
            assert!(
                document["paths"][path]["delete"]
                    .get("requestBody")
                    .is_none()
            );
        }

        let update = &document["components"]["schemas"]["UpdateResearchProfileBody"];
        assert_eq!(update["additionalProperties"], false);
        for forbidden in ["queue_state", "queue_empty", "library_revision", "paper_id"] {
            assert!(update["properties"].get(forbidden).is_none());
        }
        let interests = &document["components"]["schemas"]["ResearchProfileInterestsEnvelope"];
        for group in ["explicit", "feedback", "inferred"] {
            assert!(interests["properties"][group].is_object());
        }
        let profile = &document["components"]["schemas"]["ResearchProfileResponse"];
        assert!(profile["properties"].get("user_id").is_none());
        assert!(profile["properties"]["queue_override"].is_object());
        let export = &document["components"]["schemas"]["ResearchProfileExportEnvelope"];
        assert!(export["properties"].get("operation_ledger").is_none());
        assert!(
            export["properties"]
                .get("raw_interaction_history")
                .is_none()
        );
    }

    #[test]
    fn recommendation_feedback_and_explanations_are_private_and_queue_read_only() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for (path, method, success) in [
            (
                "/v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation",
                "get",
                "200",
            ),
            ("/v1/discovery/batches/{batch_id}/feedback", "post", "201"),
        ] {
            let operation = &document["paths"][path][method];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert_eq!(
                operation["responses"][success]["headers"]["Cache-Control"]["description"],
                "Always private, no-store"
            );
            assert_eq!(
                operation["responses"][success]["headers"]["Vary"]["description"],
                "Always Authorization"
            );
        }

        let feedback = &document["components"]["schemas"]["RecommendationFeedbackBody"];
        assert_eq!(feedback["additionalProperties"], false);
        assert_eq!(feedback["properties"]["paper_id"]["format"], "uuid");
        for forbidden in [
            "queue_empty",
            "queue_proven_empty",
            "library_revision",
            "explanation",
            "score",
        ] {
            assert!(feedback["properties"].get(forbidden).is_none());
        }
        assert_eq!(
            document["components"]["schemas"]["RecommendationExplanationCodeResponse"]["enum"],
            json!([
                "recent_category",
                "followed_category",
                "followed_topic",
                "followed_author",
                "saved_query_match",
                "feedback_category_affinity",
                "inferred_category_affinity",
                "reviewed_paper_similarity",
                "archived_paper_similarity",
                "reviewed_paper_citation",
                "archived_paper_citation",
                "adjacent_topic_exploration",
                "underrepresented_category_exploration",
                "diversity_slot"
            ])
        );
        assert_eq!(
            document["components"]["schemas"]["RecommendationExplanationCodeResponse"]["enum"],
            serde_json::to_value(domain::RecommendationReasonCode::ALL).unwrap()
        );
        assert_eq!(
            document["components"]["schemas"]["RecommendationSourceResponse"]["enum"],
            json!([
                "recent",
                "category_follow",
                "topic_follow",
                "author_follow",
                "saved_query",
                "feedback_affinity",
                "inferred_affinity",
                "semantic",
                "citation",
                "exploration"
            ])
        );
        let explanation = &document["components"]["schemas"]["RecommendationExplanationResponse"];
        assert_eq!(
            explanation["properties"]["behavior_used"]["type"],
            "boolean"
        );
        assert!(
            explanation["required"]
                .as_array()
                .is_some_and(|required| required.contains(&json!("behavior_used")))
        );
        for schema in ["ReadingFeedRecommendationSchema", "ReadingBriefItemSchema"] {
            assert_eq!(
                document["components"]["schemas"][schema]["properties"]["reason_codes"]["items"]["$ref"],
                "#/components/schemas/RecommendationExplanationCodeResponse"
            );
        }
        let parameters =
            document["paths"]["/v1/discovery/batches/{batch_id}/feedback"]["post"]["parameters"]
                .as_array()
                .unwrap();
        assert!(parameters.iter().any(|parameter| {
            parameter["name"] == "Idempotency-Key"
                && parameter["in"] == "header"
                && parameter["required"] == true
        }));
    }

    #[test]
    fn interaction_batch_is_closed_bounded_and_never_accepts_queue_claims() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let operation = &document["paths"]["/v1/events/batch"]["post"];
        assert_eq!(operation["security"], json!([{}, {"oidcBearer": []}]));
        assert_eq!(
            operation["responses"]["202"]["headers"]["Cache-Control"]["description"],
            "Always private, no-store"
        );
        let batch = &document["components"]["schemas"]["PaperInteractionBatchBody"];
        assert_eq!(batch["additionalProperties"], false);
        assert_eq!(batch["properties"]["events"]["maxItems"], 50);
        let event = &document["components"]["schemas"]["PaperInteractionBody"];
        assert_eq!(event["additionalProperties"], false);
        for forbidden in [
            "metadata",
            "note",
            "reason_codes",
            "queue_proven_empty",
            "library_revision",
            "recommendation_eligible",
        ] {
            assert!(event["properties"].get(forbidden).is_none());
        }
    }

    #[test]
    fn library_schemas_require_revision_cursor_and_canonical_operation_fields() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let list_parameters = document["paths"]["/v1/me/library"]["get"]["parameters"]
            .as_array()
            .unwrap();
        assert!(list_parameters.iter().any(|parameter| {
            parameter["name"] == "state"
                && parameter["required"] == true
                && parameter["schema"]["$ref"] == "#/components/schemas/LibraryStateBody"
        }));
        assert!(list_parameters.iter().any(|parameter| {
            parameter["name"] == "cursor" && parameter["schema"]["maxLength"] == 512
        }));
        let item = &document["components"]["schemas"]["LibraryItemSchema"];
        for field in [
            "paper_id",
            "state",
            "saved_at",
            "updated_at",
            "removed",
            "removed_at",
            "revision",
            "last_operation_id",
        ] {
            assert!(
                item["required"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|required| required == field),
                "canonical library item must require {field}"
            );
        }
        assert_eq!(
            document["components"]["schemas"]["LibraryStateSchema"]["enum"],
            json!(["to_read"])
        );
        for schema in ["LibraryListEnvelopeSchema", "LibraryChangesEnvelopeSchema"] {
            assert!(
                document["components"]["schemas"][schema]["required"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|required| required == "sync_revision")
            );
        }
        let change_required =
            document["components"]["schemas"]["LibraryChangeEntrySchema"]["required"]
                .as_array()
                .unwrap();
        assert!(change_required.iter().any(|required| required == "item"));
        assert!(change_required.iter().any(|required| required == "paper"));
    }

    #[test]
    fn paper_resolution_contract_is_private_bounded_and_has_no_automatic_actions() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for path in ["/v1/me/paper-searches", "/v1/me/library/imports"] {
            let operation = &document["paths"][path]["post"];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert!(operation["responses"]["200"]["headers"]["Cache-Control"].is_object());
            assert!(operation["responses"]["401"]["headers"]["WWW-Authenticate"].is_object());
            let description = operation["description"].as_str().unwrap();
            assert!(description.contains("never"));
            assert!(description.contains("preparation") || description.contains("saves"));
        }

        let search = &document["components"]["schemas"]["PaperSearchBody"];
        assert_eq!(search["additionalProperties"], false);
        assert!(search["properties"].get("auto_save").is_none());
        assert!(search["properties"].get("prepare").is_none());
        assert_eq!(search["properties"]["limit"]["maximum"], 10);

        let import = &document["components"]["schemas"]["PaperImportBody"];
        assert_eq!(import["additionalProperties"], false);
        assert!(import["properties"].get("prepare").is_none());
        for required in ["target_state", "save_source_kind"] {
            assert!(
                import["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(required))
            );
        }
        assert_eq!(
            document["components"]["schemas"]["PaperImportTargetStateBody"]["enum"],
            json!(["inbox"])
        );
        assert_eq!(
            document["components"]["schemas"]["LibrarySaveSourceBody"]["enum"],
            json!([
                "discovery",
                "lookup",
                "title_search",
                "arxiv_url",
                "arxiv_id",
                "connection",
                "other"
            ])
        );
        assert_eq!(
            document["components"]["schemas"]["PaperImportEnvelopeSchema"]["properties"]["item"]["$ref"],
            "#/components/schemas/LibraryV2ItemSchema"
        );
        let parameters = document["paths"]["/v1/me/library/imports"]["post"]["parameters"]
            .as_array()
            .unwrap();
        assert!(parameters.iter().any(|parameter| {
            parameter["name"] == "Idempotency-Key"
                && parameter["in"] == "header"
                && parameter["required"] == true
        }));
    }

    #[test]
    fn general_search_is_explicit_source_honest_and_queue_read_only() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for (path, method) in [
            ("/v1/search/lookup", "get"),
            ("/v1/search/suggestions", "get"),
            ("/v1/search/explore", "post"),
        ] {
            let operation = &document["paths"][path][method];
            assert!(operation.get("security").is_none());
            assert!(operation["responses"]["200"]["headers"]["Cache-Control"].is_object());
            assert!(operation["responses"]["200"]["headers"]["Vary"].is_object());
        }

        let explore = &document["components"]["schemas"]["ExploreSearchBody"];
        assert_eq!(explore["additionalProperties"], false);
        for forbidden in [
            "paper_id",
            "save",
            "save_to_queue",
            "target_state",
            "prepare",
        ] {
            assert!(explore["properties"].get(forbidden).is_none());
        }
        assert_eq!(
            document["components"]["schemas"]["SearchSourceBody"]["enum"],
            json!(["arxiv"])
        );
        assert_eq!(
            document["components"]["schemas"]["SearchSourceCoverageSchema"]["enum"],
            json!(["partial"])
        );
        assert_eq!(
            document["components"]["schemas"]["SearchSuggestionsEnvelopeSchema"]["properties"]["items"]
                ["maxItems"],
            8
        );
        assert!(
            document["paths"]["/v1/search/explore"]["post"]["responses"]["200"]["description"]
                .as_str()
                .is_some_and(|description| description.contains("not-systematic"))
        );

        for method in ["get", "post"] {
            let operation = &document["paths"]["/v1/search/saved"][method];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert!(operation["responses"]["200"]["headers"]["Cache-Control"].is_object());
        }
        let deletion = &document["paths"]["/v1/search/saved/{saved_search_id}"]["delete"];
        assert_eq!(deletion["security"][0]["oidcBearer"], json!([]));
        assert!(deletion["parameters"].as_array().is_some_and(|parameters| {
            parameters.iter().any(|parameter| {
                parameter["name"] == "saved_search_id"
                    && parameter["in"] == "path"
                    && parameter["required"] == true
            })
        }));
        assert!(deletion["parameters"].as_array().is_some_and(|parameters| {
            parameters
                .iter()
                .all(|parameter| parameter["name"] != "Idempotency-Key")
        }));
        assert!(
            deletion["responses"]["204"]["description"]
                .as_str()
                .is_some_and(|description| description.contains("no longer"))
        );
        let save = &document["components"]["schemas"]["SaveSearchBody"];
        assert_eq!(save["additionalProperties"], false);
        assert!(save["properties"].get("paper_id").is_none());
        assert!(
            document["paths"]["/v1/search/saved"]["post"]["parameters"]
                .as_array()
                .unwrap()
                .iter()
                .any(|parameter| {
                    parameter["name"] == "Idempotency-Key"
                        && parameter["in"] == "header"
                        && parameter["required"] == true
                })
        );
    }

    #[test]
    fn comments_contract_keeps_public_reads_and_safety_controls_independent() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let public_read = &document["paths"]["/v1/papers/{paper_id}/comments"]["get"];
        let security = public_read["security"].as_array().unwrap();
        assert!(security.iter().any(|requirement| requirement == &json!({})));
        assert!(security.iter().any(|requirement| {
            requirement
                .get("oidcBearer")
                .is_some_and(|scopes| scopes == &json!([]))
        }));

        for (path, method, success) in [
            ("/v1/papers/{paper_id}/comments", "post", "201"),
            ("/v1/comments/{comment_id}", "patch", "200"),
            ("/v1/comments/{comment_id}", "delete", "204"),
            ("/v1/comments/{comment_id}/reports", "post", "200"),
            ("/v1/users/{user_id}/reports", "post", "200"),
            ("/v1/me/blocked-users/{user_id}", "put", "200"),
            ("/v1/me/blocked-users/{user_id}", "delete", "204"),
            ("/v1/me/blocked-users", "get", "200"),
            ("/v1/me/comments", "get", "200"),
        ] {
            let operation = &document["paths"][path][method];
            assert_eq!(operation["security"][0]["oidcBearer"], json!([]));
            assert!(
                operation["responses"][success]["headers"]["Cache-Control"].is_object(),
                "{method} {path} must document private cache control"
            );
        }

        let create = &document["paths"]["/v1/papers/{paper_id}/comments"]["post"];
        assert!(create["responses"]["503"].is_object());
        assert!(
            create["description"]
                .as_str()
                .is_some_and(|value| value.contains("COMMENT_CREATION_ENABLED"))
        );
        assert!(
            create["parameters"]
                .as_array()
                .unwrap()
                .iter()
                .all(|parameter| parameter["name"] != "Idempotency-Key")
        );
        assert!(
            document["paths"]["/v1/comments/{comment_id}"]["delete"]
                .get("requestBody")
                .is_none()
        );
        assert!(
            document["paths"]["/v1/me/blocked-users/{user_id}"]["delete"]
                .get("requestBody")
                .is_none()
        );
        for method in ["patch", "delete"] {
            let operation = &document["paths"]["/v1/comments/{comment_id}"][method];
            assert!(operation["responses"]["404"].is_object());
            assert!(!operation.to_string().contains("COMMENT_AUTHOR_REQUIRED"));
        }

        let comment = &document["components"]["schemas"]["CommentResponse"]["properties"];
        for forbidden in [
            "moderation_reason",
            "report_count",
            "reports",
            "provider_decision",
        ] {
            assert!(comment.get(forbidden).is_none());
        }
        assert_eq!(
            document["components"]["schemas"]["CommentReportReasonBody"]["enum"],
            json!([
                "spam",
                "harassment",
                "hate",
                "threat",
                "sexual_content",
                "privacy",
                "impersonation",
                "copyright",
                "other"
            ])
        );
        assert_optional_report_detail(&document, "ReportCommentBody");
        let user_report = &document["paths"]["/v1/users/{user_id}/reports"]["post"];
        assert!(
            user_report["description"]
                .as_str()
                .is_some_and(|value| value.contains("independent from blocking"))
        );
        assert_optional_report_detail(&document, "ReportUserBody");
        let user_report_properties =
            &document["components"]["schemas"]["UserReportResponse"]["properties"];
        assert!(user_report_properties["reported_user_id"].is_object());
        assert!(user_report_properties.get("comment_id").is_none());
        assert!(user_report_properties.get("blocked_user").is_none());
    }

    fn assert_optional_report_detail(document: &serde_json::Value, schema: &str) {
        let body = &document["components"]["schemas"][schema];
        assert_eq!(body["additionalProperties"], false);
        let required = body["required"].as_array().unwrap();
        assert!(required.iter().any(|required| required == "reason"));
        assert!(!required.iter().any(|required| required == "detail"));
        assert_eq!(
            body["properties"]["detail"]["type"],
            json!(["string", "null"])
        );
    }

    #[test]
    fn artifact_generation_is_stable() {
        let first = openapi_json_pretty().unwrap();
        let second = openapi_json_pretty().unwrap();
        assert_eq!(first, second);
        assert!(first.ends_with('\n'));
    }

    #[test]
    fn feed_revalidation_headers_and_empty_304_are_documented() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let operation = &document["paths"]["/v1/feed"]["get"];
        let parameters = operation["parameters"].as_array().unwrap();
        assert!(parameters.iter().any(|parameter| {
            parameter["name"] == "If-None-Match" && parameter["in"] == "header"
        }));

        for status in ["200", "304"] {
            let headers = &operation["responses"][status]["headers"];
            assert!(headers.get("ETag").is_some(), "{status} must document ETag");
            assert!(
                headers.get("Cache-Control").is_some(),
                "{status} must document Cache-Control"
            );
        }
        assert!(operation["responses"]["304"].get("content").is_none());
    }

    #[test]
    fn derived_response_generations_are_documented() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();

        for schema_name in ["ChatResponseSchema", "ConnectionsResponseSchema"] {
            let schema = &document["components"]["schemas"][schema_name];
            assert_eq!(schema["properties"]["generation"]["type"], "integer");
            assert!(
                schema["required"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|field| field == "generation"),
                "{schema_name} must require the selected processing generation"
            );
        }
    }

    #[test]
    fn documented_enum_values_match_domain_wire_values() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();

        assert_schema_enum(
            &document,
            "FailureCategorySchema",
            &[
                FailureCategory::ExternalTemporary,
                FailureCategory::ExternalPermanent,
                FailureCategory::ParserTemporary,
                FailureCategory::ParserDocument,
                FailureCategory::ModelTemporary,
                FailureCategory::Validation,
                FailureCategory::Internal,
            ],
        );
        assert_schema_enum(
            &document,
            "OverallProcessingStateSchema",
            &[
                OverallProcessingState::NotRequested,
                OverallProcessingState::Processing,
                OverallProcessingState::Ready,
                OverallProcessingState::Failed,
            ],
        );
        assert_schema_enum(
            &document,
            "ProcessingStageSchema",
            &[
                ProcessingStage::NotRequested,
                ProcessingStage::Queued,
                ProcessingStage::FetchingLicense,
                ProcessingStage::FetchingPdf,
                ProcessingStage::ParsingPdf,
                ProcessingStage::IntroductionReady,
                ProcessingStage::IndexingChat,
                ProcessingStage::ResolvingReferences,
                ProcessingStage::Ready,
                ProcessingStage::FailedRetryable,
                ProcessingStage::FailedTerminal,
            ],
        );
        assert_schema_enum(
            &document,
            "SectionKindSchema",
            &[
                SectionKind::Abstract,
                SectionKind::Introduction,
                SectionKind::Background,
                SectionKind::RelatedWork,
                SectionKind::Method,
                SectionKind::Experiment,
                SectionKind::Result,
                SectionKind::Discussion,
                SectionKind::Limitation,
                SectionKind::Conclusion,
                SectionKind::Appendix,
                SectionKind::Acknowledgment,
                SectionKind::References,
                SectionKind::Other,
            ],
        );
        assert_schema_enum(
            &document,
            "RelationTypeSchema",
            &[
                RelationType::BuildsOn,
                RelationType::Uses,
                RelationType::Extends,
                RelationType::Applies,
                RelationType::ComparesWith,
                RelationType::ContrastsWith,
                RelationType::Background,
                RelationType::RelatedWork,
                RelationType::Unknown,
            ],
        );
        assert_schema_enum(
            &document,
            "ReferenceResolutionStatusSchema",
            &[
                ReferenceResolutionStatus::Unresolved,
                ReferenceResolutionStatus::Resolving,
                ReferenceResolutionStatus::Resolved,
                ReferenceResolutionStatus::Ambiguous,
                ReferenceResolutionStatus::NotArxiv,
                ReferenceResolutionStatus::Failed,
            ],
        );
    }

    #[test]
    fn deep_reader_document_contract_is_published_as_one_versioned_surface() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        for path in [
            "/v1/papers/{paper_id}/document/outline",
            "/v1/papers/{paper_id}/document/blocks",
            "/v1/papers/{paper_id}/figures",
            "/v1/papers/{paper_id}/figures/{figure_id}",
            "/v1/papers/{paper_id}/figures/{figure_id}/asset",
            "/v1/papers/{paper_id}/tables",
            "/v1/papers/{paper_id}/tables/{table_id}",
            "/v1/papers/{paper_id}/equations",
            "/v1/papers/{paper_id}/terms",
        ] {
            assert!(document["paths"].get(path).is_some(), "missing {path}");
        }
        for schema in [
            "DocumentOutlineEnvelope",
            "DocumentBlocksEnvelope",
            "FiguresEnvelope",
            "FigureEnvelope",
            "TablesEnvelope",
            "TableEnvelope",
            "EquationsEnvelope",
            "TermsEnvelope",
            "PassportEnvelope",
            "PassportFeedbackEnvelope",
            "SemanticSpansEnvelope",
            "ProvenanceEnvelope",
        ] {
            assert!(
                document["components"]["schemas"].get(schema).is_some(),
                "missing {schema}"
            );
        }
    }

    #[test]
    fn assistant_evidence_feedback_is_closed_private_and_not_generic_sentiment() {
        let document = serde_json::to_value(ApiDoc::openapi()).unwrap();
        let operation = &document["paths"]["/v1/papers/{paper_id}/assistant/feedback"]["post"];
        assert_eq!(operation["security"], json!([{}, {"oidcBearer": []}]));
        for status in ["200", "201"] {
            assert_eq!(
                operation["responses"][status]["headers"]["Cache-Control"]["description"],
                "Always private, no-store"
            );
            assert_eq!(
                operation["responses"][status]["headers"]["Vary"]["description"],
                "Always Authorization"
            );
        }
        let body = &document["components"]["schemas"]["AssistantEvidenceFeedbackBody"];
        assert_eq!(body["additionalProperties"], false);
        for required in [
            "operation_id",
            "paper_id",
            "generation",
            "thread_id",
            "response_id",
            "provenance_id",
            "feedback_type",
        ] {
            assert!(
                body["required"]
                    .as_array()
                    .is_some_and(|fields| fields.contains(&json!(required))),
                "missing required feedback field {required}"
            );
        }
        assert_eq!(
            document["components"]["schemas"]["AssistantEvidenceFeedbackTypeBody"]["enum"],
            json!([
                "incorrect_citation",
                "evidence_does_not_support_claim",
                "missing_evidence",
                "incorrect_support_label",
                "incorrect_source_location"
            ])
        );
        for forbidden in ["thumbs_up", "thumbs_down", "rating", "sentiment"] {
            assert!(body["properties"].get(forbidden).is_none());
        }
        assert_eq!(body["properties"]["generation"]["minimum"], 1);
        assert_eq!(body["properties"]["claim_index"]["maximum"], 15);
        assert_eq!(body["properties"]["detail"]["maxLength"], 1000);
    }

    fn assert_schema_enum<T: Serialize>(document: &serde_json::Value, schema: &str, values: &[T]) {
        let expected = values
            .iter()
            .map(|value| serde_json::to_value(value).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            document["components"]["schemas"][schema]["enum"],
            serde_json::Value::Array(expected),
            "OpenAPI enum {schema} drifted from its domain wire values"
        );
    }
}
