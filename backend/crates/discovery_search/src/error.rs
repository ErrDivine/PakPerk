use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SearchStoreError {
    #[error("the search cursor is invalid or expired")]
    InvalidCursor,
    #[error("discovery-search storage is unavailable")]
    Unavailable,
    #[error("discovery-search storage returned invalid data")]
    InvalidData,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DiscoverySearchPolicyError {
    #[error("search query bounds are invalid")]
    InvalidQueryBounds,
    #[error("search result bounds are invalid")]
    InvalidResultBounds,
    #[error("saved-search limit is invalid")]
    InvalidSavedSearchLimit,
    #[error("saved-search mutation policy is invalid")]
    InvalidMutationPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DiscoverySearchError {
    #[error("the search query is invalid")]
    InvalidQuery,
    #[error("the search result limit is invalid")]
    InvalidLimit,
    #[error("the search cursor is invalid")]
    InvalidCursor,
    #[error("the search filters are invalid")]
    InvalidFilters,
    #[error("the saved-search operation ID is invalid")]
    InvalidOperationId,
    #[error("the saved-search ID is invalid")]
    InvalidSavedSearchId,
    #[error("the saved-search operation conflicts with a different intent")]
    IdempotencyConflict,
    #[error("the saved-search limit was reached")]
    SavedSearchLimitReached,
    #[error("the account was not found")]
    AccountNotFound,
    #[error("the account is suspended")]
    Suspended,
    #[error("account deletion is pending")]
    DeletionPending,
    #[error("the account is deleted")]
    Deleted,
    #[error("saved-search mutation is rate limited; retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("discovery-search storage is unavailable")]
    Storage(SearchStoreError),
}

impl From<SearchStoreError> for DiscoverySearchError {
    fn from(error: SearchStoreError) -> Self {
        match error {
            SearchStoreError::InvalidCursor => Self::InvalidCursor,
            error @ (SearchStoreError::Unavailable | SearchStoreError::InvalidData) => {
                Self::Storage(error)
            }
        }
    }
}
