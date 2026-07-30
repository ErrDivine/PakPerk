//! Stable, transport-agnostic domain contracts shared by Pakperk services.
//!
//! Types in this crate intentionally do not depend on Axum, `SQLx`, or any model
//! provider. They are safe to use at persistence and API boundaries.

mod chat;
mod connection;
mod content_policy;
mod document;
mod error;
mod paper;
mod processing;

pub use chat::{
    ChatAnswer, ChatEvidence, ChatMessage, ChatRequest, ChatRole, ChatTurn, SuggestedFollowUp,
};
pub use connection::{
    CitationContext, Connection, ConnectionReference, ConnectionsResponse, KeyConnection,
    Reference, ReferenceResolutionStatus, RelationType,
};
pub use content_policy::{
    FulltextPolicy, FulltextPolicyParseError, is_permissive_fulltext_license,
};
pub use document::{
    Chunk, Introduction, IntroductionCitation, IntroductionCitationReference,
    IntroductionDetection, IntroductionParagraph, ParsedCitationContext, ParsedCitationMarker,
    ParsedPaper, ParsedParagraph, ParsedReference, ParsedSection, SectionKind,
};
pub use error::{ApiErrorBody, ApiErrorEnvelope, DomainError};
pub use paper::{
    ArxivIdentifier, Author, FeedPage, Paper, PaperId, PaperMetadata, PaperSummary,
    ProcessingGeneration,
};
pub use processing::{
    Capabilities, FailureCategory, OverallProcessingState, ProcessingError, ProcessingStage,
    ProcessingState,
};
