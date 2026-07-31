//! `SQLx` persistence for Pakperk.
//!
//! The crate maps database rows onto transport-agnostic `domain` values. Raw
//! row structs remain private so service code cannot accidentally couple to
//! SQL column layouts.

mod cursor;
mod repository;

pub use cursor::{CursorError, FeedCursor, LibraryCursor};
pub use repository::{
    AccountRepository, ChatSession, Database, DbError, FeedQuery, LibraryChangesOutcome,
    LibraryMutationIntent, LibraryMutationOutcome, LibraryOperationResolution, LibraryReadOutcome,
    LibraryRepository, PaperRepository, PrepareResult, ProfilePatch, ProfileUpdateOutcome,
    RateLimitConfigError, RateLimitDecision, RateLimitRepository, RateLimitRequest,
    RetrievalCandidate, StoredLibraryChangesPage, StoredLibraryPage, StoredSection, TitleCandidate,
    VerificationMetrics,
};
