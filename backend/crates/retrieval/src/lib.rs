//! Paragraph-aware chunking, scoped hybrid retrieval, and deterministic
//! reference-ranking helpers.

mod chunking;
mod hybrid;
mod query;
mod reference;

pub use chunking::{CharacterChunkSizer, ChunkSizer, ChunkingConfig, ParagraphChunker};
pub use hybrid::{
    ContextSelectionConfig, FusedHit, RetrievalScope, SearchHit, cosine_similarity, hybrid_rank,
    select_context,
};
pub use query::keyword_websearch_query;
pub use reference::{
    KeyReferenceSignals, MatchDecision, ResolutionSignals, key_reference_score, normalize_title,
    resolution_confidence, resolution_confidence_for_title, resolution_decision,
    resolution_decision_for_title, title_specificity,
};

use thiserror::Error;

#[derive(Debug, Error, PartialEq)]
pub enum RetrievalError {
    #[error("invalid chunking configuration: {0}")]
    InvalidConfiguration(String),
    #[error(
        "chunk {chunk_id} belongs to paper {actual_paper_id} generation {actual_generation}, not the requested scope"
    )]
    ScopeViolation {
        chunk_id: uuid::Uuid,
        actual_paper_id: uuid::Uuid,
        actual_generation: i32,
    },
    #[error("embedding dimensions differ: {left} versus {right}")]
    EmbeddingDimension { left: usize, right: usize },
    #[error("embedding contains a non-finite value")]
    NonFiniteEmbedding,
    #[error("embedding has zero magnitude")]
    ZeroEmbedding,
}
