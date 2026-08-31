use domain::{
    ASSISTANT_ANSWER_MAX_SCALARS, AssistantAnswer, AssistantRequest, ChatAnswer, ChatTurn, PaperId,
    ProcessingGeneration, RelationType, SectionKind,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ProviderError;

/// Provider-reported token usage for one evidence-first assistant completion.
/// Token counts are content-free cost inputs; currency conversion remains
/// outside this boundary because compatible endpoints have different pricing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AssistantTokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssistantCompletion {
    pub answer: AssistantAnswer,
    pub token_usage: Option<AssistantTokenUsage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockEvidenceExcerpt {
    pub block_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub section_heading: Option<String>,
    pub page_start: Option<u32>,
    /// Untrusted paper data. It is never interpolated into system messages or
    /// treated as conversation history.
    pub text: String,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssistantCompletionRequest {
    pub paper_title: String,
    pub request: AssistantRequest,
    #[serde(default)]
    pub recent_turns: Vec<ChatTurn>,
    pub evidence: Vec<BlockEvidenceExcerpt>,
}

impl std::fmt::Debug for AssistantCompletionRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AssistantCompletionRequest")
            .field("paper_title", &"[UNTRUSTED PAPER DATA]")
            .field("request", &self.request)
            .field("recent_turn_count", &self.recent_turns.len())
            .field("evidence_count", &self.evidence.len())
            .finish()
    }
}

impl AssistantCompletionRequest {
    pub(crate) fn validate(&self) -> Result<(), ProviderError> {
        self.request
            .validate()
            .map_err(|error| ProviderError::InvalidRequest(error.to_string()))?;
        if self.paper_title.trim().is_empty()
            || self.paper_title.chars().count() > 1_000
            || self.evidence.is_empty()
            || self.evidence.len() > 10
            || self.evidence.iter().any(|evidence| {
                evidence.paper_id != self.request.paper_id
                    || evidence.generation != self.request.generation
                    || evidence.text.trim().is_empty()
                    || evidence.text.chars().count() > 20_000
            })
            || self
                .evidence
                .iter()
                .map(|evidence| evidence.text.chars().count())
                .sum::<usize>()
                > 100_000
            || self
                .recent_turns
                .iter()
                .rev()
                .take(6)
                // A valid answer can become the next request's history, so the
                // history boundary must use the same limit as answer validation.
                .any(|turn| turn.content.chars().count() > ASSISTANT_ANSWER_MAX_SCALARS)
        {
            return Err(ProviderError::InvalidRequest(
                "assistant request exceeds its scope or size bounds".into(),
            ));
        }
        let unique_ids = self
            .evidence
            .iter()
            .map(|evidence| evidence.block_id)
            .collect::<HashSet<_>>();
        if unique_ids.len() != self.evidence.len() {
            return Err(ProviderError::InvalidRequest(
                "assistant evidence block IDs must be unique".into(),
            ));
        }
        Ok(())
    }
}

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

#[cfg(test)]
mod tests {
    use domain::{AssistantAnswerStyle, AssistantScope, AssistantScopeKind, ChatRole};

    use super::*;

    fn assistant_request_with_history(content: String) -> AssistantCompletionRequest {
        let paper_id = Uuid::now_v7();
        AssistantCompletionRequest {
            paper_title: "Bounded history fixture".to_owned(),
            request: AssistantRequest {
                paper_id,
                generation: 1,
                question: "What does the evidence support?".to_owned(),
                scope: AssistantScope {
                    kind: AssistantScopeKind::Paper,
                    section_kinds: Vec::new(),
                    object_ids: Vec::new(),
                    selection: None,
                    passport_field: None,
                },
                answer_style: AssistantAnswerStyle::Concise,
                thread_id: None,
            },
            recent_turns: vec![ChatTurn {
                role: ChatRole::Assistant,
                content,
            }],
            evidence: vec![BlockEvidenceExcerpt {
                block_id: Uuid::now_v7(),
                paper_id,
                generation: 1,
                section_heading: Some("Method".to_owned()),
                page_start: Some(2),
                text: "The bounded evidence excerpt supports the answer.".to_owned(),
            }],
        }
    }

    #[test]
    fn assistant_history_accepts_the_full_validated_answer_bound() {
        assert!(
            assistant_request_with_history("界".repeat(ASSISTANT_ANSWER_MAX_SCALARS))
                .validate()
                .is_ok()
        );
        assert!(
            assistant_request_with_history("界".repeat(ASSISTANT_ANSWER_MAX_SCALARS + 1))
                .validate()
                .is_err()
        );
    }
}
