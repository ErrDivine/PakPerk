use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{PaperId, ProcessingGeneration, SectionKind};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReferenceResolutionStatus {
    #[default]
    Unresolved,
    Resolving,
    Resolved,
    Ambiguous,
    NotArxiv,
    Failed,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelationType {
    BuildsOn,
    Uses,
    Extends,
    Applies,
    ComparesWith,
    ContrastsWith,
    Background,
    RelatedWork,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Reference {
    pub id: Uuid,
    pub citing_paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub ordinal: usize,
    pub raw_text: String,
    pub extracted_title: Option<String>,
    pub extracted_authors: Vec<String>,
    pub extracted_year: Option<i32>,
    pub doi: Option<String>,
    pub extracted_arxiv_id: Option<String>,
    pub resolved_paper_id: Option<PaperId>,
    pub resolution_status: ReferenceResolutionStatus,
    pub resolution_confidence: Option<f32>,
    pub resolution_method: Option<String>,
    pub key_score: Option<f32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CitationContext {
    pub id: Uuid,
    pub reference_id: Uuid,
    pub section_kind: SectionKind,
    pub section_heading: Option<String>,
    pub context_text: String,
    pub page_number: Option<u32>,
    pub occurrence_ordinal: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Connection {
    pub id: Uuid,
    pub citing_paper_id: PaperId,
    pub cited_paper_id: PaperId,
    pub reference_id: Uuid,
    pub generation: ProcessingGeneration,
    pub relation_type: RelationType,
    pub summary: String,
    pub confidence: f32,
    pub source_context_ids: Vec<Uuid>,
    pub model_id: Option<String>,
    pub prompt_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConnectionReference {
    pub ordinal: usize,
    pub raw_text: String,
    pub resolved: bool,
    pub paper_id: Option<PaperId>,
    pub title: Option<String>,
    pub resolution_status: ReferenceResolutionStatus,
}

/// Enriched connection card returned by the API. `Connection` remains the
/// persistence-oriented relationship record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KeyConnection {
    pub reference_id: Uuid,
    pub paper_id: PaperId,
    pub arxiv_id: String,
    pub title: String,
    pub authors: Vec<String>,
    pub year: Option<i32>,
    pub relation_type: RelationType,
    pub summary: String,
    pub confidence: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConnectionsResponse {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub ready: bool,
    pub key_connections: Vec<KeyConnection>,
    pub references: Vec<ConnectionReference>,
}
