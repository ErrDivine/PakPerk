use std::{collections::BTreeSet, sync::Arc};

use arxiv_client::normalize_arxiv_id;
use domain::{AccountStatus, AuthenticatedUserId};
use sha2::{Digest as _, Sha256};
use unicode_normalization::UnicodeNormalization as _;

use crate::{
    DiscoverySearchError, DiscoverySearchPolicy, ExploreSearchRequest, LookupSearchRequest,
    SaveSearchCommand, SavedSearch, SavedSearchDefinition, SavedSearchDeleteOutcome,
    SavedSearchDeleteReceipt, SavedSearchReadOutcome, SavedSearchWriteOutcome, SearchFilters,
    SearchFingerprint, SearchPage, SearchRateLimitStore, SearchSource, SearchStore,
    SearchSuggestions,
};

const MAX_FILTERS_PER_KIND: usize = 8;
const MAX_CATEGORY_CHARS: usize = 32;
const MAX_TOPIC_CHARS: usize = 160;
const MAX_CURSOR_BYTES: usize = 512;
const SUGGESTION_LIMIT: u32 = 8;

#[derive(Clone)]
pub struct DiscoverySearchService {
    store: Arc<dyn SearchStore>,
    rate_limits: Arc<dyn SearchRateLimitStore>,
    policy: DiscoverySearchPolicy,
}

impl DiscoverySearchService {
    #[must_use]
    pub const fn new(
        store: Arc<dyn SearchStore>,
        rate_limits: Arc<dyn SearchRateLimitStore>,
        policy: DiscoverySearchPolicy,
    ) -> Self {
        Self {
            store,
            rate_limits,
            policy,
        }
    }

    pub async fn lookup(
        &self,
        query: &str,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<SearchPage, DiscoverySearchError> {
        let normalized_query = normalize_query(query, self.policy)?;
        let exact_arxiv_base_id = normalize_arxiv_id(&normalized_query)
            .ok()
            .map(|identifier| identifier.base_id);
        self.store
            .lookup(&LookupSearchRequest {
                normalized_query,
                exact_arxiv_base_id,
                cursor: normalize_cursor(cursor)?,
                limit: validate_limit(limit, self.policy)?,
            })
            .await
            .map_err(DiscoverySearchError::from)
    }

    pub async fn explore(
        &self,
        query: &str,
        filters: SearchFilters,
        sort: crate::SearchSort,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<SearchPage, DiscoverySearchError> {
        let request = ExploreSearchRequest {
            normalized_query: normalize_query(query, self.policy)?,
            filters: normalize_filters(filters)?,
            sort,
            cursor: normalize_cursor(cursor)?,
            limit: validate_limit(limit, self.policy)?,
        };
        self.store
            .explore(&request)
            .await
            .map_err(DiscoverySearchError::from)
    }

    pub async fn suggestions(
        &self,
        query: &str,
    ) -> Result<SearchSuggestions, DiscoverySearchError> {
        let normalized_query = normalize_query(query, self.policy)?;
        self.store
            .suggestions(&normalized_query, SUGGESTION_LIMIT)
            .await
            .map_err(DiscoverySearchError::from)
    }

    pub async fn list_saved(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<Vec<SavedSearch>, DiscoverySearchError> {
        match self.store.list_saved(user_id).await? {
            SavedSearchReadOutcome::Found(saved) => Ok(saved),
            SavedSearchReadOutcome::AccountNotFound => Err(DiscoverySearchError::AccountNotFound),
            SavedSearchReadOutcome::Inactive(status) => Err(inactive_error(status)),
        }
    }

    pub async fn save(
        &self,
        user_id: AuthenticatedUserId,
        command: SaveSearchCommand,
    ) -> Result<SavedSearch, DiscoverySearchError> {
        if command.operation_id.is_nil() {
            return Err(DiscoverySearchError::InvalidOperationId);
        }
        let definition = SavedSearchDefinition {
            normalized_query: normalize_query(&command.query, self.policy)?,
            filters: normalize_filters(command.filters)?,
            sort: command.sort,
        };
        let fingerprint = fingerprint(&definition);
        if let Some(outcome) = self
            .store
            .resolve_saved_operation(user_id, command.operation_id, fingerprint)
            .await?
        {
            return map_write(outcome);
        }
        let decision = self
            .rate_limits
            .check_saved_search_mutation(
                user_id,
                self.policy.mutation_limit(),
                self.policy.mutation_window(),
            )
            .await?;
        if !decision.allowed {
            if let Some(outcome) = self
                .store
                .resolve_saved_operation(user_id, command.operation_id, fingerprint)
                .await?
            {
                return map_write(outcome);
            }
            return Err(DiscoverySearchError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(1).max(1),
            });
        }
        map_write(
            self.store
                .save_query(
                    user_id,
                    command.operation_id,
                    fingerprint,
                    &definition,
                    self.policy.maximum_saved_searches(),
                )
                .await?,
        )
    }

    /// Repeat-safely removes a saved query from only the authenticated
    /// account. Unknown and foreign IDs intentionally produce the same
    /// successful `deleted = false` receipt.
    pub async fn delete_saved(
        &self,
        user_id: AuthenticatedUserId,
        saved_search_id: uuid::Uuid,
    ) -> Result<SavedSearchDeleteReceipt, DiscoverySearchError> {
        if saved_search_id.is_nil() {
            return Err(DiscoverySearchError::InvalidSavedSearchId);
        }
        let outcome = self.store.delete_saved(user_id, saved_search_id).await?;
        match outcome {
            SavedSearchDeleteOutcome::Deleted {
                linked_subscriptions_deleted,
            } => Ok(SavedSearchDeleteReceipt {
                saved_search_id,
                deleted: true,
                linked_subscriptions_deleted,
            }),
            SavedSearchDeleteOutcome::AlreadyAbsent => Ok(SavedSearchDeleteReceipt {
                saved_search_id,
                deleted: false,
                linked_subscriptions_deleted: 0,
            }),
            SavedSearchDeleteOutcome::AccountNotFound => Err(DiscoverySearchError::AccountNotFound),
            SavedSearchDeleteOutcome::Inactive(status) => Err(inactive_error(status)),
        }
    }
}

fn normalize_query(
    value: &str,
    policy: DiscoverySearchPolicy,
) -> Result<String, DiscoverySearchError> {
    if value.trim() != value || value.chars().any(char::is_control) {
        return Err(DiscoverySearchError::InvalidQuery);
    }
    let normalized = value
        .nfkc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    let characters = normalized.chars().count();
    if characters < policy.minimum_query_chars()
        || characters > policy.maximum_query_chars()
        || !normalized.chars().any(char::is_alphanumeric)
    {
        return Err(DiscoverySearchError::InvalidQuery);
    }
    Ok(normalized)
}

fn normalize_cursor(cursor: Option<&str>) -> Result<Option<String>, DiscoverySearchError> {
    cursor
        .map(|value| {
            if value.is_empty()
                || value.len() > MAX_CURSOR_BYTES
                || !value.is_ascii()
                || value.bytes().any(|byte| byte.is_ascii_control())
            {
                Err(DiscoverySearchError::InvalidCursor)
            } else {
                Ok(value.to_owned())
            }
        })
        .transpose()
}

fn validate_limit(limit: u32, policy: DiscoverySearchPolicy) -> Result<u32, DiscoverySearchError> {
    if limit == 0 || limit > policy.maximum_results() {
        Err(DiscoverySearchError::InvalidLimit)
    } else {
        Ok(limit)
    }
}

fn normalize_filters(mut filters: SearchFilters) -> Result<SearchFilters, DiscoverySearchError> {
    if filters.categories.len() > MAX_FILTERS_PER_KIND
        || filters.topics.len() > MAX_FILTERS_PER_KIND
        || filters.sources.len() > 1
        || filters
            .published_after
            .zip(filters.published_before)
            .is_some_and(|(after, before)| after > before)
    {
        return Err(DiscoverySearchError::InvalidFilters);
    }
    filters.categories = normalize_values(filters.categories, MAX_CATEGORY_CHARS, valid_category)?;
    filters.topics = normalize_values(filters.topics, MAX_TOPIC_CHARS, |_| true)?;
    if filters.sources.is_empty() {
        filters.sources.push(SearchSource::ArxivMetadata);
    }
    filters.sources.sort_unstable();
    filters.sources.dedup();
    Ok(filters)
}

fn normalize_values(
    values: Vec<String>,
    maximum_chars: usize,
    validate: impl Fn(&str) -> bool,
) -> Result<Vec<String>, DiscoverySearchError> {
    let mut normalized = BTreeSet::new();
    for value in values {
        if value.trim() != value || value.chars().any(char::is_control) {
            return Err(DiscoverySearchError::InvalidFilters);
        }
        let value = value
            .nfkc()
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if value.is_empty() || value.chars().count() > maximum_chars || !validate(&value) {
            return Err(DiscoverySearchError::InvalidFilters);
        }
        normalized.insert(value);
    }
    Ok(normalized.into_iter().collect())
}

fn valid_category(value: &str) -> bool {
    let mut parts = value.split('.');
    let archive = parts.next().unwrap_or_default();
    let subject = parts.next();
    parts.next().is_none()
        && !archive.is_empty()
        && archive.len() <= 16
        && archive
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        && subject.is_none_or(|subject| {
            !subject.is_empty()
                && subject.len() <= 16
                && subject
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn fingerprint(definition: &SavedSearchDefinition) -> SearchFingerprint {
    let mut digest = Sha256::new();
    digest.update(b"pakperk/saved-search/v1\0");
    digest.update(
        serde_json::to_vec(definition).expect("validated saved-search definitions serialize"),
    );
    SearchFingerprint::new(digest.finalize().into())
}

fn map_write(outcome: SavedSearchWriteOutcome) -> Result<SavedSearch, DiscoverySearchError> {
    match outcome {
        SavedSearchWriteOutcome::Applied { saved, .. } => Ok(*saved),
        SavedSearchWriteOutcome::AccountNotFound => Err(DiscoverySearchError::AccountNotFound),
        SavedSearchWriteOutcome::Inactive(status) => Err(inactive_error(status)),
        SavedSearchWriteOutcome::LimitReached => Err(DiscoverySearchError::SavedSearchLimitReached),
        SavedSearchWriteOutcome::IdempotencyConflict => {
            Err(DiscoverySearchError::IdempotencyConflict)
        }
    }
}

fn inactive_error(status: AccountStatus) -> DiscoverySearchError {
    match status {
        AccountStatus::Active => {
            DiscoverySearchError::Storage(crate::SearchStoreError::InvalidData)
        }
        AccountStatus::Suspended => DiscoverySearchError::Suspended,
        AccountStatus::DeletionPending => DiscoverySearchError::DeletionPending,
        AccountStatus::Deleted => DiscoverySearchError::Deleted,
    }
}

#[cfg(test)]
mod tests {
    use std::{sync::Mutex, time::Duration};

    use async_trait::async_trait;
    use chrono::{TimeZone as _, Utc};
    use uuid::Uuid;

    use super::*;
    use crate::{SavedSearchReadOutcome, SearchMutationRateDecision, SearchSort, SearchStoreError};

    #[derive(Clone)]
    struct FakeStore {
        saved: SavedSearch,
        writes: Arc<Mutex<u32>>,
        deletes: Arc<Mutex<u32>>,
    }

    #[async_trait]
    impl SearchStore for FakeStore {
        async fn lookup(
            &self,
            request: &LookupSearchRequest,
        ) -> Result<SearchPage, SearchStoreError> {
            Ok(SearchPage {
                normalized_query: request.normalized_query.clone(),
                items: Vec::new(),
                next_cursor: None,
                diagnostics: Vec::new(),
                related_topics: Vec::new(),
            })
        }

        async fn explore(
            &self,
            request: &ExploreSearchRequest,
        ) -> Result<SearchPage, SearchStoreError> {
            Ok(SearchPage {
                normalized_query: request.normalized_query.clone(),
                items: Vec::new(),
                next_cursor: None,
                diagnostics: Vec::new(),
                related_topics: Vec::new(),
            })
        }

        async fn suggestions(
            &self,
            normalized_query: &str,
            limit: u32,
        ) -> Result<SearchSuggestions, SearchStoreError> {
            assert_eq!(limit, SUGGESTION_LIMIT);
            Ok(SearchSuggestions {
                normalized_query: normalized_query.to_owned(),
                items: Vec::new(),
            })
        }

        async fn list_saved(
            &self,
            _user_id: AuthenticatedUserId,
        ) -> Result<SavedSearchReadOutcome, SearchStoreError> {
            Ok(SavedSearchReadOutcome::Found(vec![self.saved.clone()]))
        }

        async fn resolve_saved_operation(
            &self,
            _user_id: AuthenticatedUserId,
            _operation_id: Uuid,
            _fingerprint: SearchFingerprint,
        ) -> Result<Option<SavedSearchWriteOutcome>, SearchStoreError> {
            Ok(None)
        }

        async fn save_query(
            &self,
            _user_id: AuthenticatedUserId,
            _operation_id: Uuid,
            _fingerprint: SearchFingerprint,
            _definition: &SavedSearchDefinition,
            _maximum_saved_searches: u32,
        ) -> Result<SavedSearchWriteOutcome, SearchStoreError> {
            *self.writes.lock().unwrap() += 1;
            Ok(SavedSearchWriteOutcome::Applied {
                saved: Box::new(self.saved.clone()),
                replayed: false,
            })
        }

        async fn delete_saved(
            &self,
            _user_id: AuthenticatedUserId,
            saved_search_id: Uuid,
        ) -> Result<SavedSearchDeleteOutcome, SearchStoreError> {
            *self.deletes.lock().unwrap() += 1;
            Ok(if saved_search_id == self.saved.id {
                SavedSearchDeleteOutcome::Deleted {
                    linked_subscriptions_deleted: 1,
                }
            } else {
                SavedSearchDeleteOutcome::AlreadyAbsent
            })
        }
    }

    struct AllowingRateLimit;

    #[async_trait]
    impl SearchRateLimitStore for AllowingRateLimit {
        async fn check_saved_search_mutation(
            &self,
            _user_id: AuthenticatedUserId,
            _limit: u32,
            _window: Duration,
        ) -> Result<SearchMutationRateDecision, SearchStoreError> {
            Ok(SearchMutationRateDecision {
                allowed: true,
                retry_after_seconds: None,
            })
        }
    }

    fn service() -> (DiscoverySearchService, Arc<Mutex<u32>>, SavedSearch) {
        let user_id = AuthenticatedUserId::new(Uuid::from_u128(1));
        let now = Utc.with_ymd_and_hms(2026, 8, 19, 0, 0, 0).unwrap();
        let saved = SavedSearch {
            id: Uuid::from_u128(2),
            user_id,
            definition: SavedSearchDefinition {
                normalized_query: "retrieval augmented generation".to_owned(),
                filters: SearchFilters {
                    sources: vec![SearchSource::ArxivMetadata],
                    ..SearchFilters::default()
                },
                sort: SearchSort::Relevance,
            },
            revision: 1,
            created_at: now,
            updated_at: now,
        };
        let writes = Arc::new(Mutex::new(0));
        (
            DiscoverySearchService::new(
                Arc::new(FakeStore {
                    saved: saved.clone(),
                    writes: Arc::clone(&writes),
                    deletes: Arc::new(Mutex::new(0)),
                }),
                Arc::new(AllowingRateLimit),
                DiscoverySearchPolicy::default(),
            ),
            writes,
            saved,
        )
    }

    #[tokio::test]
    async fn lookup_normalizes_without_mutation_capability() {
        let (service, writes, _) = service();
        let page = service
            .lookup("Retrieval   Augmented Generation", None, 20)
            .await
            .unwrap();
        assert_eq!(page.normalized_query, "retrieval augmented generation");
        assert_eq!(*writes.lock().unwrap(), 0);
    }

    #[tokio::test]
    async fn suggestions_are_bounded_normalized_and_read_only() {
        let (service, writes, _) = service();
        let response = service.suggestions("  private query  ").await;
        assert_eq!(response, Err(DiscoverySearchError::InvalidQuery));

        let response = service.suggestions("Retrieval   Systems").await.unwrap();
        assert_eq!(response.normalized_query, "retrieval systems");
        assert!(response.items.is_empty());
        assert_eq!(*writes.lock().unwrap(), 0);
        let debug = format!("{response:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("retrieval systems"));
    }

    #[tokio::test]
    async fn saved_query_normalizes_filters_and_writes_only_query_state() {
        let (service, writes, saved) = service();
        let result = service
            .save(
                saved.user_id,
                SaveSearchCommand {
                    operation_id: Uuid::now_v7(),
                    query: "Retrieval Augmented Generation".to_owned(),
                    filters: SearchFilters {
                        categories: vec!["cs.CL".to_owned(), "cs.CL".to_owned()],
                        ..SearchFilters::default()
                    },
                    sort: SearchSort::Relevance,
                },
            )
            .await
            .unwrap();
        assert_eq!(result, saved);
        assert_eq!(*writes.lock().unwrap(), 1);
    }

    #[tokio::test]
    async fn saved_query_deletion_is_owned_repeat_safe_and_rejects_nil_ids() {
        let (service, _, saved) = service();
        let deleted = service.delete_saved(saved.user_id, saved.id).await.unwrap();
        assert!(deleted.deleted);
        assert_eq!(deleted.linked_subscriptions_deleted, 1);

        let absent = service
            .delete_saved(saved.user_id, Uuid::from_u128(99))
            .await
            .unwrap();
        assert!(!absent.deleted);
        assert_eq!(absent.linked_subscriptions_deleted, 0);
        assert_eq!(
            service.delete_saved(saved.user_id, Uuid::nil()).await,
            Err(DiscoverySearchError::InvalidSavedSearchId)
        );
    }

    #[test]
    fn rejects_unbounded_private_query_and_filter_material() {
        let policy = DiscoverySearchPolicy::default();
        assert_eq!(
            normalize_query("  private query", policy),
            Err(DiscoverySearchError::InvalidQuery)
        );
        assert!(normalize_query(&"x".repeat(301), policy).is_err());
        assert!(
            normalize_filters(SearchFilters {
                categories: vec!["cs..CL".to_owned()],
                ..SearchFilters::default()
            })
            .is_err()
        );
    }

    #[test]
    fn fingerprint_is_domain_separated_and_redacted() {
        let definition = SavedSearchDefinition {
            normalized_query: "private research direction".to_owned(),
            filters: SearchFilters::default(),
            sort: SearchSort::Recency,
        };
        let first = fingerprint(&definition);
        let second = fingerprint(&SavedSearchDefinition {
            sort: SearchSort::Relevance,
            ..definition
        });
        assert_ne!(first, second);
        assert_eq!(format!("{first:?}"), "SearchFingerprint([redacted])");
    }
}
