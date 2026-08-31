use db::{CurrentPassport, CurrentSemanticSpans, FeedbackEvaluationOutcome};
use domain::{
    ArtifactConfidenceStatus, PaperPassport, PassportFeedback, PassportFeedbackType, PassportField,
    PassportFieldKey, PassportFieldStatus, PassportStatus, ProvenanceActivityType,
    ProvenanceArtifactType, ProvenanceRecord, SemanticDensity, SemanticFacet, SemanticSpan,
    SemanticSpanSourceKind, SemanticSupportStatus,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{document_reader::DocumentProvenanceResponse, format_timestamp};

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SemanticDensityBody {
    Off,
    Key,
    Detailed,
}

impl From<SemanticDensityBody> for SemanticDensity {
    fn from(value: SemanticDensityBody) -> Self {
        match value {
            SemanticDensityBody::Off => Self::Off,
            SemanticDensityBody::Key => Self::Key,
            SemanticDensityBody::Detailed => Self::Detailed,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SemanticSpansParams {
    pub(crate) block_id: Option<Uuid>,
    pub(crate) density: Option<SemanticDensityBody>,
}

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PassportFeedbackTypeBody {
    WrongField,
    MisleadingCompression,
    WrongEvidence,
    MissingLimitation,
    ParserIssue,
}

impl From<PassportFeedbackTypeBody> for PassportFeedbackType {
    fn from(value: PassportFeedbackTypeBody) -> Self {
        match value {
            PassportFeedbackTypeBody::WrongField => Self::WrongField,
            PassportFeedbackTypeBody::MisleadingCompression => Self::MisleadingCompression,
            PassportFeedbackTypeBody::WrongEvidence => Self::WrongEvidence,
            PassportFeedbackTypeBody::MissingLimitation => Self::MissingLimitation,
            PassportFeedbackTypeBody::ParserIssue => Self::ParserIssue,
        }
    }
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PassportFeedbackBody {
    pub(crate) operation_id: Uuid,
    pub(crate) passport_id: Uuid,
    pub(crate) field_id: Option<Uuid>,
    pub(crate) feedback_type: PassportFeedbackTypeBody,
    #[schema(max_length = 2000)]
    pub(crate) detail: Option<String>,
}

impl PassportFeedbackBody {
    pub(crate) fn into_domain(self) -> Result<PassportFeedback, &'static str> {
        let feedback = PassportFeedback {
            operation_id: self.operation_id,
            passport_id: self.passport_id,
            field_id: self.field_id,
            feedback_type: self.feedback_type.into(),
            detail: self.detail,
        };
        feedback
            .validate()
            .map_err(|_| "Passport feedback is invalid")?;
        Ok(feedback)
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PassportStatusResponse {
    Draft,
    Ready,
    Partial,
    Failed,
}

impl From<PassportStatus> for PassportStatusResponse {
    fn from(value: PassportStatus) -> Self {
        match value {
            PassportStatus::Draft => Self::Draft,
            PassportStatus::Ready => Self::Ready,
            PassportStatus::Partial => Self::Partial,
            PassportStatus::Failed => Self::Failed,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PassportFieldKeyResponse {
    ResearchQuestion,
    Contribution,
    Method,
    DataOrSample,
    Evaluation,
    MainResult,
    Limitations,
    AssumptionsScope,
    CodeResources,
    PublicationStatus,
}

impl From<PassportFieldKey> for PassportFieldKeyResponse {
    fn from(value: PassportFieldKey) -> Self {
        match value {
            PassportFieldKey::ResearchQuestion => Self::ResearchQuestion,
            PassportFieldKey::Contribution => Self::Contribution,
            PassportFieldKey::Method => Self::Method,
            PassportFieldKey::DataOrSample => Self::DataOrSample,
            PassportFieldKey::Evaluation => Self::Evaluation,
            PassportFieldKey::MainResult => Self::MainResult,
            PassportFieldKey::Limitations => Self::Limitations,
            PassportFieldKey::AssumptionsScope => Self::AssumptionsScope,
            PassportFieldKey::CodeResources => Self::CodeResources,
            PassportFieldKey::PublicationStatus => Self::PublicationStatus,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PassportFieldStatusResponse {
    Supported,
    Inferred,
    Conflicting,
    NotFound,
    NotApplicable,
}

impl From<PassportFieldStatus> for PassportFieldStatusResponse {
    fn from(value: PassportFieldStatus) -> Self {
        match value {
            PassportFieldStatus::Supported => Self::Supported,
            PassportFieldStatus::Inferred => Self::Inferred,
            PassportFieldStatus::Conflicting => Self::Conflicting,
            PassportFieldStatus::NotFound => Self::NotFound,
            PassportFieldStatus::NotApplicable => Self::NotApplicable,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ArtifactConfidenceStatusResponse {
    Supported,
    Inferred,
    Uncertain,
}

impl From<ArtifactConfidenceStatus> for ArtifactConfidenceStatusResponse {
    fn from(value: ArtifactConfidenceStatus) -> Self {
        match value {
            ArtifactConfidenceStatus::Supported => Self::Supported,
            ArtifactConfidenceStatus::Inferred => Self::Inferred,
            ArtifactConfidenceStatus::Uncertain => Self::Uncertain,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct PassportFieldResponse {
    pub(crate) id: Uuid,
    pub(crate) field_key: PassportFieldKeyResponse,
    pub(crate) value_text: Option<String>,
    #[schema(value_type = Option<Object>)]
    pub(crate) value_json: Option<serde_json::Value>,
    pub(crate) status: PassportFieldStatusResponse,
    pub(crate) source_block_ids: Vec<Uuid>,
    pub(crate) confidence_status: ArtifactConfidenceStatusResponse,
    pub(crate) provenance_id: Uuid,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
}

impl From<PassportField> for PassportFieldResponse {
    fn from(value: PassportField) -> Self {
        Self {
            id: value.id,
            field_key: value.key.into(),
            value_text: value.value_text,
            value_json: value.value_json,
            status: value.status.into(),
            source_block_ids: value.source_block_ids,
            confidence_status: value.confidence_status.into(),
            provenance_id: value.provenance_id,
            created_at: format_timestamp(value.created_at),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct PassportProvenanceSummaryResponse {
    pub(crate) id: Uuid,
    pub(crate) status: PassportStatusResponse,
    pub(crate) parser_id: String,
    pub(crate) model_id: Option<String>,
    pub(crate) schema_version: String,
    pub(crate) prompt_version: Option<String>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct PaperPassportResponse {
    pub(crate) id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) version_label: String,
    pub(crate) schema_version: String,
    pub(crate) status: PassportStatusResponse,
    pub(crate) parser_id: String,
    pub(crate) model_id: Option<String>,
    pub(crate) prompt_version: Option<String>,
    pub(crate) provenance_id: Uuid,
    pub(crate) provenance: PassportProvenanceSummaryResponse,
    pub(crate) fields: Vec<PassportFieldResponse>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
}

impl PaperPassportResponse {
    fn new(value: PaperPassport, arxiv_version: u32) -> Self {
        let status = PassportStatusResponse::from(value.status);
        let created_at = format_timestamp(value.created_at);
        Self {
            id: value.id,
            paper_id: value.paper_id,
            generation: value.generation,
            version_label: format!("v{arxiv_version}"),
            schema_version: value.schema_version.clone(),
            status,
            parser_id: value.parser_id.clone(),
            model_id: value.model_id.clone(),
            prompt_version: value.prompt_version.clone(),
            provenance_id: value.provenance_id,
            provenance: PassportProvenanceSummaryResponse {
                id: value.provenance_id,
                status,
                parser_id: value.parser_id,
                model_id: value.model_id,
                schema_version: value.schema_version,
                prompt_version: value.prompt_version,
                created_at: created_at.clone(),
            },
            fields: value.fields.into_iter().map(Into::into).collect(),
            created_at,
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ProvenanceArtifactTypeResponse {
    Document,
    VisualObjects,
    Terms,
    SemanticSpans,
    PaperPassport,
    PaperPassportField,
    AssistantAnswer,
    VersionDiff,
    AccessibilityDescription,
}

impl From<ProvenanceArtifactType> for ProvenanceArtifactTypeResponse {
    fn from(value: ProvenanceArtifactType) -> Self {
        match value {
            ProvenanceArtifactType::Document => Self::Document,
            ProvenanceArtifactType::VisualObjects => Self::VisualObjects,
            ProvenanceArtifactType::Terms => Self::Terms,
            ProvenanceArtifactType::SemanticSpans => Self::SemanticSpans,
            ProvenanceArtifactType::PaperPassport => Self::PaperPassport,
            ProvenanceArtifactType::PaperPassportField => Self::PaperPassportField,
            ProvenanceArtifactType::AssistantAnswer => Self::AssistantAnswer,
            ProvenanceArtifactType::VersionDiff => Self::VersionDiff,
            ProvenanceArtifactType::AccessibilityDescription => Self::AccessibilityDescription,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ProvenanceActivityTypeResponse {
    ParserNormalization,
    VisualExtraction,
    TermExtraction,
    SemanticClassification,
    PassportSynthesis,
    AssistantGeneration,
    VersionComparison,
    AccessibilityGeneration,
}

impl From<ProvenanceActivityType> for ProvenanceActivityTypeResponse {
    fn from(value: ProvenanceActivityType) -> Self {
        match value {
            ProvenanceActivityType::ParserNormalization => Self::ParserNormalization,
            ProvenanceActivityType::VisualExtraction => Self::VisualExtraction,
            ProvenanceActivityType::TermExtraction => Self::TermExtraction,
            ProvenanceActivityType::SemanticClassification => Self::SemanticClassification,
            ProvenanceActivityType::PassportSynthesis => Self::PassportSynthesis,
            ProvenanceActivityType::AssistantGeneration => Self::AssistantGeneration,
            ProvenanceActivityType::VersionComparison => Self::VersionComparison,
            ProvenanceActivityType::AccessibilityGeneration => Self::AccessibilityGeneration,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct ProvenanceRecordResponse {
    pub(crate) id: Uuid,
    pub(crate) artifact_type: ProvenanceArtifactTypeResponse,
    pub(crate) artifact_id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) activity_type: ProvenanceActivityTypeResponse,
    pub(crate) parser_id: Option<String>,
    pub(crate) parser_version: Option<String>,
    pub(crate) model_provider: Option<String>,
    pub(crate) model_id: Option<String>,
    pub(crate) prompt_or_schema_version: Option<String>,
    pub(crate) input_entity_ids: Vec<Uuid>,
    #[schema(value_type = Object)]
    pub(crate) parameters: serde_json::Value,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    pub(crate) superseded_by: Option<Uuid>,
}

impl TryFrom<ProvenanceRecord> for ProvenanceRecordResponse {
    type Error = serde_json::Error;

    fn try_from(value: ProvenanceRecord) -> Result<Self, Self::Error> {
        Ok(Self {
            id: value.id,
            artifact_type: value.artifact_type.into(),
            artifact_id: value.artifact_id,
            paper_id: value.paper_id,
            generation: value.generation,
            activity_type: value.activity_type.into(),
            parser_id: value.parser_id,
            parser_version: value.parser_version,
            model_provider: value.model_provider,
            model_id: value.model_id,
            prompt_or_schema_version: value.prompt_or_schema_version,
            input_entity_ids: value.input_entity_ids,
            parameters: serde_json::to_value(value.parameters)?,
            created_at: format_timestamp(value.created_at),
            superseded_by: value.superseded_by,
        })
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct PassportEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) document_provenance: DocumentProvenanceResponse,
    pub(crate) passport: PaperPassportResponse,
    pub(crate) provenance_records: Vec<ProvenanceRecordResponse>,
}

impl TryFrom<CurrentPassport> for PassportEnvelope {
    type Error = serde_json::Error;

    fn try_from(value: CurrentPassport) -> Result<Self, Self::Error> {
        let paper_id = value.passport.paper_id;
        let generation = value.passport.generation;
        let arxiv_version = value.document_provenance.arxiv_version;
        Ok(Self {
            paper_id,
            generation,
            document_provenance: value.document_provenance.into(),
            passport: PaperPassportResponse::new(value.passport, arxiv_version),
            provenance_records: value
                .provenance
                .into_iter()
                .map(ProvenanceRecordResponse::try_from)
                .collect::<Result<Vec<_>, _>>()?,
        })
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SemanticFacetResponse {
    Objective,
    Method,
    Result,
    Limitation,
    Claim,
    Evidence,
    FutureWork,
    Definition,
}

impl From<SemanticFacet> for SemanticFacetResponse {
    fn from(value: SemanticFacet) -> Self {
        match value {
            SemanticFacet::Objective => Self::Objective,
            SemanticFacet::Method => Self::Method,
            SemanticFacet::Result => Self::Result,
            SemanticFacet::Limitation => Self::Limitation,
            SemanticFacet::Claim => Self::Claim,
            SemanticFacet::Evidence => Self::Evidence,
            SemanticFacet::FutureWork => Self::FutureWork,
            SemanticFacet::Definition => Self::Definition,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SemanticDensityResponse {
    Off,
    Key,
    Detailed,
}

impl From<SemanticDensity> for SemanticDensityResponse {
    fn from(value: SemanticDensity) -> Self {
        match value {
            SemanticDensity::Off => Self::Off,
            SemanticDensity::Key => Self::Key,
            SemanticDensity::Detailed => Self::Detailed,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SemanticSpanSourceKindResponse {
    Deterministic,
    Model,
}

impl From<SemanticSpanSourceKind> for SemanticSpanSourceKindResponse {
    fn from(value: SemanticSpanSourceKind) -> Self {
        match value {
            SemanticSpanSourceKind::Deterministic => Self::Deterministic,
            SemanticSpanSourceKind::Model => Self::Model,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SemanticSupportStatusResponse {
    Supported,
    Inferred,
}

impl From<SemanticSupportStatus> for SemanticSupportStatusResponse {
    fn from(value: SemanticSupportStatus) -> Self {
        match value {
            SemanticSupportStatus::Supported => Self::Supported,
            SemanticSupportStatus::Inferred => Self::Inferred,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct SemanticSpanResponse {
    pub(crate) id: Uuid,
    pub(crate) block_id: Uuid,
    pub(crate) ordinal: u32,
    /// Inclusive Unicode-scalar offset into the exact source block.
    pub(crate) start_offset: u32,
    /// Exclusive Unicode-scalar offset into the exact source block.
    pub(crate) end_offset: u32,
    pub(crate) facet: SemanticFacetResponse,
    pub(crate) minimum_density: SemanticDensityResponse,
    pub(crate) source_kind: SemanticSpanSourceKindResponse,
    pub(crate) confidence_basis_points: u16,
    pub(crate) support_status: SemanticSupportStatusResponse,
    pub(crate) provenance_id: Uuid,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
}

impl From<SemanticSpan> for SemanticSpanResponse {
    fn from(value: SemanticSpan) -> Self {
        Self {
            id: value.id,
            block_id: value.block_id,
            ordinal: value.ordinal,
            start_offset: value.start_offset,
            end_offset: value.end_offset,
            facet: value.facet.into(),
            minimum_density: value.minimum_density.into(),
            source_kind: value.source_kind.into(),
            confidence_basis_points: value.confidence_basis_points,
            support_status: value.support_status.into(),
            provenance_id: value.provenance_id,
            created_at: format_timestamp(value.created_at),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct SemanticSpansEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) density: SemanticDensityResponse,
    pub(crate) document_provenance: DocumentProvenanceResponse,
    pub(crate) spans: Vec<SemanticSpanResponse>,
    pub(crate) provenance_records: Vec<ProvenanceRecordResponse>,
}

impl SemanticSpansEnvelope {
    pub(crate) fn try_new(
        density: SemanticDensity,
        value: CurrentSemanticSpans,
    ) -> Result<Self, serde_json::Error> {
        Ok(Self {
            paper_id: value.paper_id,
            generation: value.generation,
            density: density.into(),
            document_provenance: value.document_provenance.into(),
            spans: value.spans.into_iter().map(Into::into).collect(),
            provenance_records: value
                .provenance
                .into_iter()
                .map(ProvenanceRecordResponse::try_from)
                .collect::<Result<Vec<_>, _>>()?,
        })
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct ProvenanceEnvelope {
    pub(crate) provenance: ProvenanceRecordResponse,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct PassportFeedbackEnvelope {
    pub(crate) evaluation_id: Uuid,
    pub(crate) replayed: bool,
}

impl From<FeedbackEvaluationOutcome> for PassportFeedbackEnvelope {
    fn from(value: FeedbackEvaluationOutcome) -> Self {
        match value {
            FeedbackEvaluationOutcome::Inserted(evaluation_id) => Self {
                evaluation_id,
                replayed: false,
            },
            FeedbackEvaluationOutcome::Replayed(evaluation_id) => Self {
                evaluation_id,
                replayed: true,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feedback_rejects_nil_or_empty_values() {
        let body = PassportFeedbackBody {
            operation_id: Uuid::nil(),
            passport_id: Uuid::now_v7(),
            field_id: None,
            feedback_type: PassportFeedbackTypeBody::WrongEvidence,
            detail: None,
        };
        assert!(body.into_domain().is_err());
    }

    #[test]
    fn semantic_density_conversion_is_closed() {
        assert_eq!(
            SemanticDensity::from(SemanticDensityBody::Detailed),
            SemanticDensity::Detailed
        );
    }
}
