//! Transport-independent To Read library policy and orchestration.
//!
//! HTTP parsing stays in the API app and SQL stays in `db`. This crate owns
//! strict request bounds, active-account error mapping, shared mutation rate
//! limits, opaque list cursors, and the fixed tombstone retention policy.

mod service;

pub use service::{
    LibraryChangesPage, LibraryListsPage, LibraryMutationResult, LibraryPage, LibraryPolicy,
    LibraryPolicyError, LibraryService, LibraryServiceError, LibraryStore, LibraryTagsPage,
    LibraryV2ChangesPage, LibraryV2MutationResult, RateLimitStore, TOMBSTONE_RETENTION,
};
