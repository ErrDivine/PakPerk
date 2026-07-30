use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DomainError {
    #[error("the question must not be empty")]
    EmptyQuestion,
    #[error("the question exceeds {maximum} characters")]
    QuestionTooLong { maximum: usize },
    #[error("invalid processing transition from {from} to {to}")]
    InvalidProcessingTransition { from: String, to: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiErrorBody {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    pub request_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiErrorEnvelope {
    pub error: ApiErrorBody,
}
