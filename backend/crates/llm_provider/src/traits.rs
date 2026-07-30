use async_trait::async_trait;
use domain::{ChatAnswer, RelationType};

use crate::{
    ChatCompletionRequest, EmbeddingRequest, EmbeddingResponse, ProviderError, RelationshipRequest,
    RelationshipSummary,
};

#[async_trait]
pub trait ChatProvider: Send + Sync {
    async fn answer(&self, request: &ChatCompletionRequest) -> Result<ChatAnswer, ProviderError>;
}

#[async_trait]
pub trait EmbeddingProvider: Send + Sync {
    async fn embed(&self, request: &EmbeddingRequest) -> Result<EmbeddingResponse, ProviderError>;
}

#[async_trait]
pub trait RelationshipProvider: Send + Sync {
    async fn summarize_relationship(
        &self,
        request: &RelationshipRequest,
    ) -> Result<RelationshipSummary, ProviderError>;

    /// Reliability path for cards: provider failures, `unknown`, and
    /// low-confidence generations become the explicit deterministic fallback
    /// instead of an unsupported polished sentence.
    async fn summarize_relationship_or_fallback(
        &self,
        request: &RelationshipRequest,
        minimum_confidence: f32,
    ) -> RelationshipSummary {
        match self.summarize_relationship(request).await {
            Ok(summary)
                if summary.relation_type != RelationType::Unknown
                    && summary.confidence >= minimum_confidence.clamp(0.0, 1.0) =>
            {
                summary
            }
            Ok(_) | Err(_) => crate::deterministic_relationship_fallback(request),
        }
    }
}
