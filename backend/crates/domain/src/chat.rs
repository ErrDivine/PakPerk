use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{PaperId, ProcessingGeneration, SectionKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChatRole {
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatTurn {
    pub role: ChatRole,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatRequest {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub thread_id: Option<Uuid>,
    pub message: String,
    #[serde(default)]
    pub recent_turns: Vec<ChatTurn>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatEvidence {
    pub section_kind: SectionKind,
    pub section_heading: Option<String>,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
    pub chunk_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SuggestedFollowUp(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatAnswer {
    pub answer_markdown: String,
    pub insufficient_evidence: bool,
    pub evidence: Vec<ChatEvidence>,
    #[serde(default)]
    pub suggested_follow_ups: Vec<SuggestedFollowUp>,
    pub model_id: Option<String>,
    pub provider_request_id: Option<String>,
    pub prompt_version: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub id: Uuid,
    pub thread_id: Uuid,
    pub role: ChatRole,
    pub content: String,
    #[serde(default)]
    pub evidence: Vec<ChatEvidence>,
}
