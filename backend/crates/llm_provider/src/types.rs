use domain::{ChatAnswer, ChatTurn, RelationType, SectionKind};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ProviderError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidenceExcerpt {
    pub chunk_id: Uuid,
    pub section_kind: SectionKind,
    pub section_heading: Option<String>,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
    /// Untrusted paper data. It is never interpolated into system messages.
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatCompletionRequest {
    pub paper_title: String,
    pub question: String,
    #[serde(default)]
    pub recent_turns: Vec<ChatTurn>,
    pub evidence: Vec<EvidenceExcerpt>,
}

impl ChatCompletionRequest {
    pub(crate) fn validate(&self) -> Result<(), ProviderError> {
        let question_length = self.question.trim().chars().count();
        if question_length == 0 || question_length > 500 {
            return Err(ProviderError::InvalidRequest(
                "question must contain 1 to 500 characters".into(),
            ));
        }
        if self.paper_title.trim().is_empty() || self.paper_title.chars().count() > 1_000 {
            return Err(ProviderError::InvalidRequest(
                "paper title must contain 1 to 1000 characters".into(),
            ));
        }
        if self.evidence.is_empty()
            || self.evidence.len() > 6
            || self.evidence.iter().any(|evidence| {
                evidence.text.trim().is_empty() || evidence.text.chars().count() > 20_000
            })
            || self
                .evidence
                .iter()
                .map(|evidence| evidence.text.chars().count())
                .sum::<usize>()
                > 80_000
        {
            return Err(ProviderError::InvalidRequest(
                "chat requires 1 to 6 bounded evidence excerpts".into(),
            ));
        }
        if self
            .recent_turns
            .iter()
            .rev()
            .take(6)
            .any(|turn| turn.content.chars().count() > 4_000)
        {
            return Err(ProviderError::InvalidRequest(
                "recent conversation turn exceeds 4000 characters".into(),
            ));
        }
        let unique_ids = self
            .evidence
            .iter()
            .map(|evidence| evidence.chunk_id)
            .collect::<HashSet<_>>();
        if unique_ids.len() != self.evidence.len() {
            return Err(ProviderError::InvalidRequest(
                "evidence chunk IDs must be unique".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EmbeddingRequest {
    pub inputs: Vec<String>,
}

impl EmbeddingRequest {
    pub(crate) fn validate(&self) -> Result<(), ProviderError> {
        if self.inputs.is_empty()
            || self.inputs.len() > 256
            || self.inputs.iter().any(|input| {
                input.trim().is_empty()
                    || input.chars().count() > 50_000
                    || !input.chars().any(char::is_alphanumeric)
            })
            || self
                .inputs
                .iter()
                .map(|input| input.chars().count())
                .sum::<usize>()
                > 1_000_000
        {
            return Err(ProviderError::InvalidRequest(
                "embedding request exceeds its count, text, or total-size bounds".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EmbeddingResponse {
    pub vectors: Vec<Vec<f32>>,
    pub model_id: String,
    pub provider_request_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelationshipContext {
    pub context_id: Uuid,
    pub section_kind: SectionKind,
    pub section_heading: Option<String>,
    /// Untrusted text extracted from the citing paper.
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelationshipRequest {
    pub current_paper_title: String,
    pub current_paper_abstract: String,
    pub cited_paper_title: String,
    pub cited_paper_abstract: String,
    /// One to three citation contexts are recommended.
    pub contexts: Vec<RelationshipContext>,
}

impl RelationshipRequest {
    pub(crate) fn validate(&self) -> Result<(), ProviderError> {
        if self.contexts.is_empty()
            || self.contexts.len() > 3
            || self.current_paper_title.trim().is_empty()
            || self.current_paper_title.chars().count() > 1_000
            || self.cited_paper_title.trim().is_empty()
            || self.cited_paper_title.chars().count() > 1_000
            || self.current_paper_abstract.chars().count() > 20_000
            || self.cited_paper_abstract.chars().count() > 20_000
            || self.contexts.iter().any(|context| {
                context.text.trim().is_empty() || context.text.chars().count() > 8_000
            })
        {
            return Err(ProviderError::InvalidRequest(
                "relationship request exceeds title, abstract, or context bounds".into(),
            ));
        }
        let unique_ids = self
            .contexts
            .iter()
            .map(|context| context.context_id)
            .collect::<HashSet<_>>();
        if unique_ids.len() != self.contexts.len() {
            return Err(ProviderError::InvalidRequest(
                "relationship context IDs must be unique".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RelationshipSummary {
    pub relation_type: RelationType,
    pub summary: String,
    pub confidence: f32,
    pub evidence_context_ids: Vec<Uuid>,
    pub model_id: Option<String>,
    pub provider_request_id: Option<String>,
    pub prompt_version: String,
}

/// Keeps rustdoc links to the shared answer contract easy to discover from this
/// provider crate.
#[allow(dead_code)]
fn _domain_answer_contract(_: ChatAnswer) {}
use std::collections::HashSet;
