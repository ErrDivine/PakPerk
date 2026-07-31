//! `SQLx` persistence for Pakperk.
//!
//! The crate maps database rows onto transport-agnostic `domain` values. Raw
//! row structs remain private so service code cannot accidentally couple to
//! SQL column layouts.

mod cursor;
mod repository;

pub use cursor::{CreatedAtCursor, CursorError, FeedCursor, LibraryCursor};
pub use repository::{
    AccountRepository, AdminCommentAction, AdminCommentOutcome, AdminReportOutcome,
    AdminReportResolution, AdminUserStatusOutcome, ChatSession, CommentCreateOutcome,
    CommentCreatePrecondition, CommentCreateResolution, CommentDeleteResolution,
    CommentEditResolution, CommentMutationOutcome, CommentReadOutcome, CommentReportOutcome,
    CommentReportResolution, CommentRepository, Database, DbError, FeedQuery,
    LibraryChangesOutcome, LibraryMutationIntent, LibraryMutationOutcome,
    LibraryOperationResolution, LibraryReadOutcome, LibraryRepository, ModerationRepository,
    PaperRepository, PrepareResult, ProfilePatch, ProfileUpdateOutcome, RateLimitConfigError,
    RateLimitDecision, RateLimitRepository, RateLimitRequest, RetrievalCandidate, StoredAdminActor,
    StoredInspectionReport, StoredLibraryChangesPage, StoredLibraryPage,
    StoredModerationInspection, StoredModerationQueuePage, StoredModerationQueueRecord,
    StoredReport, StoredReportAgeMetrics, StoredReportQueuePage, StoredReportQueueRecord,
    StoredSection, TitleCandidate, UserBlockOutcome, UserBlockResolution, UserUnblockResolution,
    VerificationMetrics,
};
