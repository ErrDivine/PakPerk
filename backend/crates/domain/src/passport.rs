use std::collections::{BTreeMap, HashSet};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

use crate::{DocumentBlock, PaperId, ProcessingGeneration};

macro_rules! string_enum {
    ($name:ident { $($variant:ident => $value:literal,)+ }) => {
        impl $name {
            #[must_use]
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $value,)+
                }
            }
        }

        impl TryFrom<&str> for $name {
            type Error = PassportValidationError;

            fn try_from(value: &str) -> Result<Self, Self::Error> {
                match value {
                    $($value => Ok(Self::$variant),)+
                    _ => Err(PassportValidationError::UnknownEnumValue),
                }
            }
        }
    };
}

pub const PAPER_PASSPORT_SCHEMA_VERSION: &str = "passport-v1";
pub const SEMANTIC_FACET_SCHEMA_VERSION: &str = "facets-v1";
pub const PROVENANCE_INPUT_MAX: usize = 128;
pub const PROVENANCE_PARAMETER_MAX: usize = 32;
pub const PASSPORT_FIELD_TEXT_MAX_SCALARS: usize = 10_000;
pub const PASSPORT_FEEDBACK_MAX_SCALARS: usize = 2_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PassportStatus {
    Draft,
    Ready,
    Partial,
    Failed,
}

string_enum!(PassportStatus {
    Draft => "draft",
    Ready => "ready",
    Partial => "partial",
    Failed => "failed",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PassportFieldKey {
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

impl PassportFieldKey {
    pub const ALL: [Self; 10] = [
        Self::ResearchQuestion,
        Self::Contribution,
        Self::Method,
        Self::DataOrSample,
        Self::Evaluation,
        Self::MainResult,
        Self::Limitations,
        Self::AssumptionsScope,
        Self::CodeResources,
        Self::PublicationStatus,
    ];
}

string_enum!(PassportFieldKey {
    ResearchQuestion => "research_question",
    Contribution => "contribution",
    Method => "method",
    DataOrSample => "data_or_sample",
    Evaluation => "evaluation",
    MainResult => "main_result",
    Limitations => "limitations",
    AssumptionsScope => "assumptions_scope",
    CodeResources => "code_resources",
    PublicationStatus => "publication_status",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PassportFieldStatus {
    Supported,
    Inferred,
    Conflicting,
    NotFound,
    NotApplicable,
}

string_enum!(PassportFieldStatus {
    Supported => "supported",
    Inferred => "inferred",
    Conflicting => "conflicting",
    NotFound => "not_found",
    NotApplicable => "not_applicable",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactConfidenceStatus {
    Supported,
    Inferred,
    Uncertain,
}

string_enum!(ArtifactConfidenceStatus {
    Supported => "supported",
    Inferred => "inferred",
    Uncertain => "uncertain",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PassportFeedbackType {
    WrongField,
    MisleadingCompression,
    WrongEvidence,
    MissingLimitation,
    ParserIssue,
}

string_enum!(PassportFeedbackType {
    WrongField => "wrong_field",
    MisleadingCompression => "misleading_compression",
    WrongEvidence => "wrong_evidence",
    MissingLimitation => "missing_limitation",
    ParserIssue => "parser_issue",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SemanticFacet {
    Objective,
    Method,
    Result,
    Limitation,
    Claim,
    Evidence,
    FutureWork,
    Definition,
}

string_enum!(SemanticFacet {
    Objective => "objective",
    Method => "method",
    Result => "result",
    Limitation => "limitation",
    Claim => "claim",
    Evidence => "evidence",
    FutureWork => "future_work",
    Definition => "definition",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SemanticDensity {
    Off,
    Key,
    Detailed,
}

string_enum!(SemanticDensity {
    Off => "off",
    Key => "key",
    Detailed => "detailed",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SemanticSpanSourceKind {
    Deterministic,
    Model,
}

string_enum!(SemanticSpanSourceKind {
    Deterministic => "deterministic",
    Model => "model",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SemanticSupportStatus {
    Supported,
    Inferred,
}

string_enum!(SemanticSupportStatus {
    Supported => "supported",
    Inferred => "inferred",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProvenanceArtifactType {
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

string_enum!(ProvenanceArtifactType {
    Document => "document",
    VisualObjects => "visual_objects",
    Terms => "terms",
    SemanticSpans => "semantic_spans",
    PaperPassport => "paper_passport",
    PaperPassportField => "paper_passport_field",
    AssistantAnswer => "assistant_answer",
    VersionDiff => "version_diff",
    AccessibilityDescription => "accessibility_description",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProvenanceActivityType {
    ParserNormalization,
    VisualExtraction,
    TermExtraction,
    SemanticClassification,
    PassportSynthesis,
    AssistantGeneration,
    VersionComparison,
    AccessibilityGeneration,
}

string_enum!(ProvenanceActivityType {
    ParserNormalization => "parser_normalization",
    VisualExtraction => "visual_extraction",
    TermExtraction => "term_extraction",
    SemanticClassification => "semantic_classification",
    PassportSynthesis => "passport_synthesis",
    AssistantGeneration => "assistant_generation",
    VersionComparison => "version_comparison",
    AccessibilityGeneration => "accessibility_generation",
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "id")]
pub enum ProvenancePrincipal {
    OwnerUser(Uuid),
    AnonymousSession(Uuid),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ProvenanceParameter {
    Boolean(bool),
    Integer(i64),
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProvenanceParameters(pub BTreeMap<String, ProvenanceParameter>);

impl ProvenanceParameters {
    pub fn validate(&self) -> Result<(), PassportValidationError> {
        if self.0.len() > PROVENANCE_PARAMETER_MAX
            || self.0.keys().any(|key| {
                key.is_empty()
                    || key.len() > 64
                    || !key.bytes().all(|byte| {
                        byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'
                    })
            })
        {
            return Err(PassportValidationError::InvalidProvenance);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProvenanceRecord {
    pub id: Uuid,
    pub artifact_type: ProvenanceArtifactType,
    pub artifact_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub activity_type: ProvenanceActivityType,
    pub parser_id: Option<String>,
    pub parser_version: Option<String>,
    pub model_provider: Option<String>,
    pub model_id: Option<String>,
    pub prompt_or_schema_version: Option<String>,
    pub input_entity_ids: Vec<Uuid>,
    pub parameters: ProvenanceParameters,
    pub principal: Option<ProvenancePrincipal>,
    pub created_at: DateTime<Utc>,
    pub superseded_by: Option<Uuid>,
}

impl ProvenanceRecord {
    pub fn validate(&self) -> Result<(), PassportValidationError> {
        let assistant = self.artifact_type == ProvenanceArtifactType::AssistantAnswer
            && self.activity_type == ProvenanceActivityType::AssistantGeneration;
        if self.id.is_nil()
            || self.artifact_id.is_nil()
            || self.generation <= 0
            || assistant != self.principal.is_some()
            || self.input_entity_ids.len() > PROVENANCE_INPUT_MAX
            || contains_duplicate_or_nil(&self.input_entity_ids)
            || self.superseded_by == Some(self.id)
            || self
                .principal
                .is_some_and(|principal| principal.id().is_nil())
            || !valid_optional_identifier(self.parser_id.as_deref(), 64)
            || !valid_optional_identifier(self.parser_version.as_deref(), 128)
            || !valid_optional_identifier(self.model_provider.as_deref(), 64)
            || !valid_optional_identifier(self.model_id.as_deref(), 128)
            || !valid_optional_identifier(self.prompt_or_schema_version.as_deref(), 128)
        {
            return Err(PassportValidationError::InvalidProvenance);
        }
        self.parameters.validate()
    }
}

impl ProvenancePrincipal {
    #[must_use]
    pub const fn id(self) -> Uuid {
        match self {
            Self::OwnerUser(id) | Self::AnonymousSession(id) => id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PassportField {
    pub id: Uuid,
    pub key: PassportFieldKey,
    pub value_text: Option<String>,
    pub value_json: Option<Value>,
    pub status: PassportFieldStatus,
    pub source_block_ids: Vec<Uuid>,
    pub confidence_status: ArtifactConfidenceStatus,
    pub provenance_id: Uuid,
    pub created_at: DateTime<Utc>,
}

impl PassportField {
    pub fn validate(&self) -> Result<(), PassportValidationError> {
        let has_text = self
            .value_text
            .as_ref()
            .is_some_and(|value| valid_text(value, PASSPORT_FIELD_TEXT_MAX_SCALARS));
        let has_json = self.value_json.as_ref().is_some_and(|value| {
            matches!(value, Value::Object(_) | Value::Array(_))
                && serde_json::to_vec(value).is_ok_and(|bytes| bytes.len() <= 32_768)
        });
        let has_evidence = matches!(
            self.status,
            PassportFieldStatus::Supported
                | PassportFieldStatus::Inferred
                | PassportFieldStatus::Conflicting
        );
        if self.id.is_nil()
            || self.provenance_id.is_nil()
            || self.source_block_ids.len() > 64
            || contains_duplicate_or_nil(&self.source_block_ids)
            || (has_evidence && (self.source_block_ids.is_empty() || has_text == has_json))
            || (!has_evidence
                && (!self.source_block_ids.is_empty()
                    || self.value_text.is_some()
                    || self.value_json.is_some()))
            || (self.value_text.is_some() && !has_text)
            || (self.value_json.is_some() && !has_json)
        {
            return Err(PassportValidationError::InvalidField(self.key));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaperPassport {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub schema_version: String,
    pub status: PassportStatus,
    pub parser_id: String,
    pub model_id: Option<String>,
    pub prompt_version: Option<String>,
    pub provenance_id: Uuid,
    pub fields: Vec<PassportField>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl PaperPassport {
    pub fn validate(&self) -> Result<(), PassportValidationError> {
        if self.id.is_nil()
            || self.provenance_id.is_nil()
            || self.generation <= 0
            || !valid_identifier(&self.schema_version, 64)
            || !valid_identifier(&self.parser_id, 64)
            || !valid_optional_identifier(self.model_id.as_deref(), 128)
            || !valid_optional_identifier(self.prompt_version.as_deref(), 128)
            || self.updated_at < self.created_at
            || self.fields.len() != PassportFieldKey::ALL.len()
        {
            return Err(PassportValidationError::InvalidPassport);
        }
        let mut keys = HashSet::new();
        for field in &self.fields {
            field.validate()?;
            if !keys.insert(field.key) {
                return Err(PassportValidationError::DuplicateOrMissingField);
            }
        }
        if PassportFieldKey::ALL
            .iter()
            .any(|field_key| !keys.contains(field_key))
        {
            return Err(PassportValidationError::DuplicateOrMissingField);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SemanticSpan {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub block_id: Uuid,
    pub ordinal: u32,
    /// Inclusive Unicode-scalar offset into the block text.
    pub start_offset: u32,
    /// Exclusive Unicode-scalar offset into the block text.
    pub end_offset: u32,
    pub facet: SemanticFacet,
    pub minimum_density: SemanticDensity,
    pub source_kind: SemanticSpanSourceKind,
    pub confidence_basis_points: u16,
    pub support_status: SemanticSupportStatus,
    pub provenance_id: Uuid,
    pub created_at: DateTime<Utc>,
}

impl SemanticSpan {
    pub fn validate_for_block(&self, block: &DocumentBlock) -> Result<(), PassportValidationError> {
        let scalar_count = block.text.chars().count();
        let start = usize::try_from(self.start_offset).unwrap_or(usize::MAX);
        let end = usize::try_from(self.end_offset).unwrap_or(usize::MAX);
        if self.id.is_nil()
            || self.provenance_id.is_nil()
            || self.generation <= 0
            || self.paper_id != block.paper_id
            || self.generation != block.generation
            || self.block_id != block.id
            || start >= end
            || end > scalar_count
            || self.minimum_density == SemanticDensity::Off
            || self.confidence_basis_points > 10_000
        {
            return Err(PassportValidationError::InvalidSemanticSpan);
        }
        Ok(())
    }

    #[must_use]
    pub const fn visible_at(&self, density: SemanticDensity) -> bool {
        match density {
            SemanticDensity::Off => false,
            SemanticDensity::Key => matches!(self.minimum_density, SemanticDensity::Key),
            SemanticDensity::Detailed => true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PassportFeedback {
    pub operation_id: Uuid,
    pub passport_id: Uuid,
    pub field_id: Option<Uuid>,
    pub feedback_type: PassportFeedbackType,
    pub detail: Option<String>,
}

impl PassportFeedback {
    pub fn validate(&self) -> Result<(), PassportValidationError> {
        if self.operation_id.is_nil()
            || self.passport_id.is_nil()
            || self.field_id == Some(Uuid::nil())
            || self
                .detail
                .as_ref()
                .is_some_and(|detail| !valid_text(detail, PASSPORT_FEEDBACK_MAX_SCALARS))
        {
            return Err(PassportValidationError::InvalidFeedback);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum PassportValidationError {
    #[error("paper Passport is invalid")]
    InvalidPassport,
    #[error("paper Passport has duplicate or missing fields")]
    DuplicateOrMissingField,
    #[error("paper Passport field {0:?} is invalid")]
    InvalidField(PassportFieldKey),
    #[error("semantic span is invalid or outside its source block")]
    InvalidSemanticSpan,
    #[error("provenance record is invalid")]
    InvalidProvenance,
    #[error("Passport feedback is invalid")]
    InvalidFeedback,
    #[error("persisted enum value is unknown")]
    UnknownEnumValue,
}

fn contains_duplicate_or_nil(values: &[Uuid]) -> bool {
    let mut seen = HashSet::new();
    values
        .iter()
        .any(|value| value.is_nil() || !seen.insert(*value))
}

fn valid_identifier(value: &str, maximum: usize) -> bool {
    let value = value.trim();
    !value.is_empty() && value.len() <= maximum && !value.contains('\0')
}

fn valid_optional_identifier(value: Option<&str>, maximum: usize) -> bool {
    value.is_none_or(|value| valid_identifier(value, maximum))
}

fn valid_text(value: &str, maximum: usize) -> bool {
    let scalar_count = value.chars().count();
    scalar_count > 0 && scalar_count <= maximum && !value.trim().is_empty() && !value.contains('\0')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DocumentBlockKind, content_hash};

    fn block(text: &str) -> DocumentBlock {
        DocumentBlock {
            id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            generation: 2,
            stable_key: "block-1".to_owned(),
            ordinal: 0,
            section_path: vec!["Results".to_owned()],
            kind: DocumentBlockKind::Paragraph,
            text: text.to_owned(),
            content_hash: content_hash(text),
            page_start: Some(1),
            page_end: Some(1),
            source_locator: None,
            inline_spans: Vec::new(),
        }
    }

    #[test]
    fn semantic_offsets_are_unicode_scalar_offsets() {
        let source = block("A🦀B");
        let span = SemanticSpan {
            id: Uuid::now_v7(),
            paper_id: source.paper_id,
            generation: source.generation,
            block_id: source.id,
            ordinal: 0,
            start_offset: 1,
            end_offset: 2,
            facet: SemanticFacet::Result,
            minimum_density: SemanticDensity::Key,
            source_kind: SemanticSpanSourceKind::Deterministic,
            confidence_basis_points: 9_000,
            support_status: SemanticSupportStatus::Supported,
            provenance_id: Uuid::now_v7(),
            created_at: Utc::now(),
        };
        span.validate_for_block(&source).unwrap();

        let mut out_of_bounds = span;
        out_of_bounds.end_offset = 4;
        assert_eq!(
            out_of_bounds.validate_for_block(&source),
            Err(PassportValidationError::InvalidSemanticSpan)
        );
    }

    #[test]
    fn missing_passport_values_cannot_claim_sources() {
        let field = PassportField {
            id: Uuid::now_v7(),
            key: PassportFieldKey::Limitations,
            value_text: None,
            value_json: None,
            status: PassportFieldStatus::NotFound,
            source_block_ids: vec![Uuid::now_v7()],
            confidence_status: ArtifactConfidenceStatus::Uncertain,
            provenance_id: Uuid::now_v7(),
            created_at: Utc::now(),
        };
        assert_eq!(
            field.validate(),
            Err(PassportValidationError::InvalidField(
                PassportFieldKey::Limitations
            ))
        );
    }

    #[test]
    fn provenance_rejects_text_shaped_parameter_keys_and_private_shared_mixups() {
        let mut parameters = BTreeMap::new();
        parameters.insert("Prompt Body".to_owned(), ProvenanceParameter::Boolean(true));
        assert_eq!(
            ProvenanceParameters(parameters).validate(),
            Err(PassportValidationError::InvalidProvenance)
        );

        let shared_with_principal = ProvenanceRecord {
            id: Uuid::now_v7(),
            artifact_type: ProvenanceArtifactType::PaperPassport,
            artifact_id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            generation: 1,
            activity_type: ProvenanceActivityType::PassportSynthesis,
            parser_id: Some("grobid".to_owned()),
            parser_version: Some("1".to_owned()),
            model_provider: None,
            model_id: None,
            prompt_or_schema_version: Some(PAPER_PASSPORT_SCHEMA_VERSION.to_owned()),
            input_entity_ids: Vec::new(),
            parameters: ProvenanceParameters::default(),
            principal: Some(ProvenancePrincipal::AnonymousSession(Uuid::now_v7())),
            created_at: Utc::now(),
            superseded_by: None,
        };
        assert_eq!(
            shared_with_principal.validate(),
            Err(PassportValidationError::InvalidProvenance)
        );
    }

    #[test]
    fn enum_wire_values_are_closed() {
        for field in PassportFieldKey::ALL {
            assert_eq!(PassportFieldKey::try_from(field.as_str()).unwrap(), field);
        }
        assert_eq!(
            SemanticDensity::try_from("everything"),
            Err(PassportValidationError::UnknownEnumValue)
        );
    }
}
