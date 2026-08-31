use std::time::Duration;

use async_trait::async_trait;
use domain::{AccountStatus, AuthenticatedUserId};
use uuid::Uuid;

use crate::{
    ExploreSearchRequest, LookupSearchRequest, SavedSearch, SavedSearchDefinition,
    SearchFingerprint, SearchPage, SearchStoreError, SearchSuggestions,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchMutationRateDecision {
    pub allowed: bool,
    pub retry_after_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SavedSearchReadOutcome {
    Found(Vec<SavedSearch>),
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum SavedSearchWriteOutcome {
    Applied {
        saved: Box<SavedSearch>,
        replayed: bool,
    },
    AccountNotFound,
    Inactive(AccountStatus),
    LimitReached,
    IdempotencyConflict,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SavedSearchDeleteOutcome {
    Deleted { linked_subscriptions_deleted: u32 },
    AlreadyAbsent,
    AccountNotFound,
    Inactive(AccountStatus),
}

#[async_trait]
pub trait SearchStore: Send + Sync {
    async fn lookup(&self, request: &LookupSearchRequest) -> Result<SearchPage, SearchStoreError>;

    async fn explore(&self, request: &ExploreSearchRequest)
    -> Result<SearchPage, SearchStoreError>;

    async fn suggestions(
        &self,
        normalized_query: &str,
        limit: u32,
    ) -> Result<SearchSuggestions, SearchStoreError>;

    async fn list_saved(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<SavedSearchReadOutcome, SearchStoreError>;

    async fn resolve_saved_operation(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: SearchFingerprint,
    ) -> Result<Option<SavedSearchWriteOutcome>, SearchStoreError>;

    async fn save_query(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: SearchFingerprint,
        definition: &SavedSearchDefinition,
        maximum_saved_searches: u32,
    ) -> Result<SavedSearchWriteOutcome, SearchStoreError>;

    /// Deletes only the caller's saved query. Unknown and foreign IDs are
    /// intentionally represented by the same repeat-safe outcome.
    async fn delete_saved(
        &self,
        user_id: AuthenticatedUserId,
        saved_search_id: Uuid,
    ) -> Result<SavedSearchDeleteOutcome, SearchStoreError>;
}

#[async_trait]
pub trait SearchRateLimitStore: Send + Sync {
    async fn check_saved_search_mutation(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
        window: Duration,
    ) -> Result<SearchMutationRateDecision, SearchStoreError>;
}
