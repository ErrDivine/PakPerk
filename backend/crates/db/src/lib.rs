//! `SQLx` persistence for Pakperk.
//!
//! The crate maps database rows onto transport-agnostic `domain` values. Raw
//! row structs remain private so service code cannot accidentally couple to
//! SQL column layouts.

mod cursor;
mod repository;

pub use cursor::{CursorError, FeedCursor};
pub use repository::{
    AccountRepository, ChatSession, Database, DbError, FeedQuery, PaperRepository, PrepareResult,
    ProfilePatch, ProfileUpdateOutcome, RateLimitConfigError, RateLimitDecision,
    RateLimitRepository, RateLimitRequest, RetrievalCandidate, StoredSection, TitleCandidate,
    VerificationMetrics,
};
