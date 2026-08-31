//! Explicit paper Lookup and Explore search with auditable source coverage.
//!
//! Search is navigation-only. Its persistence contract can save query
//! definitions, but deliberately cannot save papers or mutate library/queue
//! state.

mod error;
mod model;
mod policy;
mod service;
mod store;

pub use error::{DiscoverySearchError, DiscoverySearchPolicyError, SearchStoreError};
pub use model::{
    ExploreSearchRequest, LookupSearchRequest, MatchKind, RelatedTopic, SaveSearchCommand,
    SavedSearch, SavedSearchDefinition, SavedSearchDeleteReceipt, SearchFilters, SearchFingerprint,
    SearchPage, SearchResult, SearchSort, SearchSource, SearchSuggestions, SourceCoverage,
    SourceDiagnostic, SourceStatus,
};
pub use policy::DiscoverySearchPolicy;
pub use service::DiscoverySearchService;
pub use store::{
    SavedSearchDeleteOutcome, SavedSearchReadOutcome, SavedSearchWriteOutcome,
    SearchMutationRateDecision, SearchRateLimitStore, SearchStore,
};

/// Honest disclosure attached to every Explore response.
pub const EXPLORE_DISCLAIMER: &str = "Explore searches Pakperk's bounded local arXiv metadata cache. It is not a systematic or complete literature search.";
