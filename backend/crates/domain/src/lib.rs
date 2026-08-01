//! Stable, transport-agnostic domain contracts shared by Pakperk services.
//!
//! Types in this crate intentionally do not depend on Axum, `SQLx`, or any model
//! provider. They are safe to use at persistence and API boundaries.

mod account;
mod account_deletion;
mod chat;
mod comment;
mod connection;
mod content_policy;
mod document;
mod error;
mod library;
mod paper;
mod processing;

pub use account::{
    AccountStatus, AccountStatusParseError, AuthenticatedUserId, DisplayName,
    DisplayNameValidationError, Handle, HandleValidationError, PublicUser, TermsVersion,
    TermsVersionValidationError, User,
};
pub use account_deletion::{
    AccountDeletionOperation, AccountDeletionState, AccountDeletionStateParseError,
    IdentityFingerprint, IdentityFingerprintError,
};
pub use chat::{
    ChatAnswer, ChatEvidence, ChatMessage, ChatRequest, ChatRole, ChatTurn, SuggestedFollowUp,
};
pub use comment::{
    BlockedUser, BlockedUserPage, COMMENT_MAX_BYTES, COMMENT_MAX_SCALARS, COMMENT_MAX_URLS,
    CommentBody, CommentBodyValidationError, CommentPage, CommentReportReason,
    CommentReportReasonParseError, CommentReportReceipt, CommentReportStatus,
    CommentReportStatusParseError, CommentStatus, CommentStatusParseError,
    CommunityGuidelinesVersion, CommunityGuidelinesVersionValidationError, PaperComment,
    ReportDetail, ReportDetailValidationError,
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
pub use library::{
    LibraryChange, LibraryItem, LibraryState, LibraryStateParseError, SavedLibraryPaper,
};
pub use paper::{
    ArxivIdentifier, Author, FeedPage, Paper, PaperId, PaperMetadata, PaperSummary,
    ProcessingGeneration,
};
pub use processing::{
    Capabilities, FailureCategory, OverallProcessingState, ProcessingError, ProcessingStage,
    ProcessingState,
};
