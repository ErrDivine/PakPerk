//! Provider-neutral access to chat, embedding, and relationship models.
//!
//! Paper excerpts are always framed as untrusted data. Structured model output
//! is validated against trusted source records before it reaches the domain.

mod deterministic;
mod openai;
mod prompt;
mod recovery;
mod tools;
mod traits;
mod types;
mod validation;
mod vision;

pub use deterministic::DeterministicProvider;
pub use openai::{
    ImageDetail, OpenAiCompatibleConfig, OpenAiCompatibleProvider, StructuredOutputMode,
    ThinkingMode,
};
pub use prompt::{ASSISTANT_V2_PROMPT_VERSION, CHAT_PROMPT_VERSION, RELATIONSHIP_PROMPT_VERSION};
pub use recovery::{
    DOCUMENT_RECOVERY_PROMPT_VERSION, DocumentRecoveryCompletion, DocumentRecoveryRequest,
    validate_recovery_output,
};
pub use tools::{
    ASSISTANT_TOOL_MAX_CALLS_PER_ROUND, ASSISTANT_TOOL_MAX_ROUNDS, ASSISTANT_TOOL_RESULT_BYTES,
    ASSISTANT_TOOLS_PROMPT_VERSION, AssistantToolCall, AssistantToolExchange,
    AssistantToolFunction, AssistantToolStep, AssistantToolStepRequest,
};
pub use traits::{
    AssistantProvider, ChatProvider, DocumentRecoveryProvider, DocumentVisionProvider,
    EmbeddingProvider, RelationshipProvider,
};
pub use types::{
    AssistantCompletion, AssistantCompletionRequest, AssistantTokenUsage, BlockEvidenceExcerpt,
    ChatCompletionRequest, EmbeddingRequest, EmbeddingResponse, EvidenceExcerpt,
    RelationshipContext, RelationshipRequest, RelationshipSummary,
};
pub use validation::{
    deterministic_relationship_fallback, validate_assistant_output, validate_chat_output,
    validate_relationship_output,
};
pub use vision::{
    PAGE_TRANSCRIPTION_PROMPT_VERSION, PageTranscriptionCompletion, PageTranscriptionRequest,
    validate_transcription_output,
};

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("invalid model-provider configuration: {0}")]
    InvalidConfiguration(String),
    #[error("invalid model request: {0}")]
    InvalidRequest(String),
    #[error("model-provider request failed")]
    Transport(#[from] reqwest::Error),
    #[error("model-provider operation exceeded its configured total timeout")]
    OperationTimeout,
    #[error("model provider returned HTTP {status}")]
    HttpStatus { status: u16 },
    #[error("model-provider response exceeds {maximum_bytes} bytes")]
    ResponseTooLarge { maximum_bytes: usize },
    #[error("model-provider response has an invalid envelope: {0}")]
    InvalidResponse(String),
    #[error(transparent)]
    StructuredOutput(#[from] ValidationError),
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ValidationError {
    #[error("structured output is not valid JSON")]
    InvalidJson,
    #[error("answer must contain nonempty Markdown without raw HTML")]
    InvalidAnswer,
    #[error("answer cites no source excerpt that was actually supplied")]
    MissingValidEvidence,
    #[error("suggested follow-up is invalid")]
    InvalidFollowUp,
    #[error("relationship confidence must be finite and between zero and one")]
    InvalidConfidence,
    #[error("relationship summary must be one sentence of at most 32 words")]
    InvalidRelationshipSummary,
    #[error("relationship cites no context that was actually supplied")]
    MissingValidRelationshipEvidence,
    #[error("assistant answer status or shape is invalid")]
    InvalidAssistantAnswer,
    #[error("assistant output contains an invalid or unsupported claim")]
    InvalidAssistantClaim,
    #[error("assistant output cites evidence that was not retrieved and validated")]
    InvalidAssistantEvidence,
    #[error("document recovery classification is inconsistent with the supplied segments")]
    InvalidRecoveryAnnotation,
    #[error("page transcription is out of bounds, repeats itself, or mislabels a heading")]
    InvalidPageTranscription,
}
