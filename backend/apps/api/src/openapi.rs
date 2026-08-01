//! Code-first `OpenAPI` contract for the stable public paper API.

#![allow(dead_code, clippy::struct_excessive_bools)] // Schema-only contract mirrors wire JSON.

use axum::Json;
use serde::Serialize;
use utoipa::openapi::security::{HttpAuthScheme, HttpBuilder, SecurityScheme};
use utoipa::{Modify, OpenApi, ToSchema};

use crate::{
    dto::{
        AccountDeletionEnvelope, AccountDeletionResponse, AccountDeletionStateSchema,
        AccountProfileEnvelope, AccountProfileResponse, AccountStatusSchema, BlockedUserEnvelope,
        BlockedUserPageEnvelope, BlockedUserResponse, ChatBody, CommentAuthorResponse,
        CommentEnvelope, CommentPageEnvelope, CommentReportEnvelope, CommentReportReasonBody,
        CommentReportResponse, CommentReportStatusSchema, CommentResponse, CommentStatusSchema,
        CreateCommentBody, DeletionVerificationAccount, DeletionVerificationEnvelope,
        EditCommentBody, LibrarySaveBody, PrepareBody, ProfileUpdateBody, ReportCommentBody,
        ReportUserBody, UserReportEnvelope, UserReportResponse,
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
        routes::papers::connections,
        routes::account::get_me,
        routes::account::patch_me,
        routes::account::delete_me,
        routes::account::verify_deletion_identity,
        routes::library::list_library,
        routes::library::library_changes,
        routes::library::save_library_item,
        routes::library::remove_library_item,
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
            "/v1/me",
            "/v1/me/deletion-verification",
            "/v1/me/library",
            "/v1/me/library/changes",
            "/v1/me/library/{paper_id}",
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
        let user_report = &document["paths"]["/v1/users/{user_id}/reports"]["post"];
        assert!(
            user_report["description"]
                .as_str()
                .is_some_and(|value| value.contains("independent from blocking"))
        );
        let user_report_body = &document["components"]["schemas"]["ReportUserBody"];
        assert_eq!(user_report_body["additionalProperties"], false);
        let required = user_report_body["required"].as_array().unwrap();
        for field in ["reason", "detail"] {
            assert!(required.iter().any(|required| required == field));
        }
        assert_eq!(
            user_report_body["properties"]["detail"]["type"],
            json!(["string", "null"])
        );
        let user_report_properties =
            &document["components"]["schemas"]["UserReportResponse"]["properties"];
        assert!(user_report_properties["reported_user_id"].is_object());
        assert!(user_report_properties.get("comment_id").is_none());
        assert!(user_report_properties.get("blocked_user").is_none());
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
