//! Code-first `OpenAPI` contract for the stable public paper API.

#![allow(dead_code, clippy::struct_excessive_bools)] // Schema-only contract mirrors wire JSON.

use axum::Json;
use serde::Serialize;
use utoipa::{OpenApi, ToSchema};

use crate::{
    dto::{ChatBody, PrepareBody},
    routes,
};

#[derive(OpenApi)]
#[openapi(
    info(
        title = "Pakperk API",
        version = "1.0.0",
        description = "Stable v1 paper-reading API. Account, library, and comment routes are intentionally absent until their production phases are complete."
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
        ReferenceResolutionStatusSchema
    )),
    tags(
        (name = "health", description = "Process and dependency health"),
        (name = "papers", description = "Public paper reading and processing")
    )
)]
pub struct ApiDoc;

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
