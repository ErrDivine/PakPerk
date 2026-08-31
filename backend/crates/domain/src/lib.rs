//! Stable, transport-agnostic domain contracts shared by Pakperk services.
//!
//! Types in this crate intentionally do not depend on Axum, `SQLx`, or any model
//! provider. They are safe to use at persistence and API boundaries.

mod account;
mod account_deletion;
mod assistant_v2;
mod chat;
mod comment;
mod connection;
mod content_policy;
mod document;
mod document_reader;
mod error;
mod library;
mod paper;
mod passport;
mod processing;
mod recommendation;
mod research_memory;
mod version_diff;

pub use account::{
    AccountStatus, AccountStatusParseError, AuthenticatedUserId, DisplayName,
    DisplayNameValidationError, Handle, HandleValidationError, PublicUser, TermsVersion,
    TermsVersionValidationError, User,
};
pub use account_deletion::{
    AccountDeletionOperation, AccountDeletionState, AccountDeletionStateParseError,
    IdentityFingerprint, IdentityFingerprintError,
};
pub use assistant_v2::{
    ASSISTANT_ANSWER_MAX_SCALARS, ASSISTANT_CLAIM_SEPARATOR, ASSISTANT_FEEDBACK_DETAIL_MAX_SCALARS,
    ASSISTANT_FEEDBACK_MAX_CLAIMS, ASSISTANT_NOT_FOUND_ANSWER, ASSISTANT_PARTIAL_LIMITATION,
    ASSISTANT_QUESTION_MAX_SCALARS, ASSISTANT_SCOPE_MAX_OBJECTS, ASSISTANT_SCOPE_MAX_SECTIONS,
    AssistantAnswer, AssistantAnswerStatus, AssistantAnswerStyle, AssistantClaim,
    AssistantClaimSupport, AssistantEvidenceFeedback, AssistantEvidenceFeedbackType,
    AssistantEvidenceReference, AssistantFeedbackValidationError, AssistantRequest,
    AssistantRequestValidationError, AssistantScope, AssistantScopeKind, AssistantTextSelection,
    assistant_text_contains_link, canonical_assistant_answer,
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
    ReportDetail, ReportDetailValidationError, UserReportReceipt,
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
pub use document_reader::{
    DOCUMENT_SCHEMA_VERSION, DefinitionConfidenceStatus, DefinitionSourceType, DefinitionStatus,
    DocumentBlock, DocumentBlockKind, DocumentEquation, DocumentFigure, DocumentOutlineEntry,
    DocumentProvenanceSummary, DocumentTable, DocumentTerm, DocumentTermDetails,
    DocumentValidationError, EquationConfidenceStatus, FigureExtractionStatus, InlineSpan,
    InlineSpanKind, MAX_DOCUMENT_EQUATIONS, MAX_DOCUMENT_FIGURES, MAX_DOCUMENT_TABLES,
    MAX_TABLE_CELL_SCALARS, MAX_TABLE_CELLS, MAX_TABLE_COLUMNS, MAX_TABLE_PLAIN_TEXT_SCALARS,
    MAX_TABLE_ROWS, MAX_VISUAL_ASSET_DIMENSION, MAX_VISUAL_ASSET_PIXELS, NormalizedBoundingBox,
    NormalizedDocument, SourceLocator, TABLE_STRUCTURE_SCHEMA_VERSION, TableCell,
    TableExtractionStatus, TableStructure, TermDefinition, TermKind, TermOccurrence, content_hash,
    normalize_document_text, normalize_term, stable_block_key, valid_visual_asset_dimensions,
};
pub use error::{ApiErrorBody, ApiErrorEnvelope, DomainError};
pub use library::{
    LibraryChange, LibraryItem, LibraryItemTag, LibraryList, LibraryListItem,
    LibrarySaveSourceKind, LibrarySaveSourceKindParseError, LibraryState, LibraryStateParseError,
    LibraryTag, LibraryV2Change, SavedLibraryPaper,
};
pub use paper::{
    ArxivIdentifier, Author, FeedPage, Paper, PaperId, PaperMetadata, PaperSummary,
    ProcessingGeneration,
};
pub use passport::{
    ArtifactConfidenceStatus, PAPER_PASSPORT_SCHEMA_VERSION, PASSPORT_FEEDBACK_MAX_SCALARS,
    PASSPORT_FIELD_TEXT_MAX_SCALARS, PROVENANCE_INPUT_MAX, PROVENANCE_PARAMETER_MAX, PaperPassport,
    PassportFeedback, PassportFeedbackType, PassportField, PassportFieldKey, PassportFieldStatus,
    PassportStatus, PassportValidationError, ProvenanceActivityType, ProvenanceArtifactType,
    ProvenanceParameter, ProvenanceParameters, ProvenancePrincipal, ProvenanceRecord,
    SEMANTIC_FACET_SCHEMA_VERSION, SemanticDensity, SemanticFacet, SemanticSpan,
    SemanticSpanSourceKind, SemanticSupportStatus,
};
pub use processing::{
    Capabilities, FailureCategory, OverallProcessingState, PreparationTriggerKind,
    PreparationTriggerKindParseError, ProcessingError, ProcessingStage, ProcessingState,
};
pub use recommendation::RecommendationReasonCode;
pub use research_memory::{
    ANNOTATION_BODY_MAX_SCALARS, ANNOTATION_QUOTE_MAX_SCALARS, Annotation, AnnotationAnchorStatus,
    AnnotationColorRole, AnnotationConflict, AnnotationConflictResolution, AnnotationKind,
    AnnotationWrite, EVIDENCE_CARD_TITLE_MAX_SCALARS, EvidenceCard, EvidenceCardWrite,
    EvidenceVerificationStatus, MEMORY_TEXT_MAX_SCALARS, MemoryItem, MemoryItemWrite,
    MemorySourceType, MemoryStatus, ReaderMode, ReaderStage, ReadingCheckpoint,
    ReadingCheckpointWrite, ReanchorBlock, ReanchorResult, ReanchorStrategy,
    ResearchArtifactValidationError, TextQuotePositionSelector, reanchor_annotation,
};
pub use version_diff::{
    DiffBlock, DiffConfidenceStatus, DocumentVersionManifest, PaperVersionDiff, ParserIdentity,
    VERSION_DIFF_ALGORITHM_VERSION, VERSION_DIFF_SCHEMA_VERSION, VersionChangeType,
    VersionDiffItem, VersionDiffItemKind, VersionDiffStatus, VersionDiffSummary,
    VersionDiffValidationError, align_document_blocks,
};
