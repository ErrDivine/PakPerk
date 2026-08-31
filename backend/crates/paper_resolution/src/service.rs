use std::{
    fmt::Write as _,
    sync::Arc,
    time::{Duration, Instant},
};

use arxiv_client::{ArxivClient, ArxivError, normalize_arxiv_id};
use db::{PaperRepository, RateLimitRepository, RateLimitRequest};
use domain::AuthenticatedUserId;
use observability::{
    ArxivAccessOutcome, ArxivOperationClass, CacheClass, CacheOutcome, record_arxiv_access,
    record_cache_result,
};
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use unicode_normalization::UnicodeNormalization as _;
use uuid::Uuid;

use crate::{
    PaperMetadataSource, PaperResolutionError, PaperResolutionRateLimitStore, PaperResolutionStore,
    PaperSearchCacheStatus, PaperSearchError, PaperSearchResult, ResolvedPaper,
};

const NEGATIVE_EXACT_ARXIV_CACHE_TTL: Duration = Duration::from_secs(15 * 60);
const SEARCH_RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);
const SEARCH_CACHE_POLICY_VERSION: &str = "title:v1";
const SEARCH_CACHE_QUERY_KIND: &str = "title_search";
const MAX_SEARCH_POSITIVE_CACHE_TTL: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const MAX_SEARCH_NEGATIVE_CACHE_TTL: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_SEARCH_ACCOUNT_LIMIT_PER_MINUTE: u32 = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum PaperResolutionPolicyError {
    #[error("paper-search query limits are invalid")]
    InvalidQueryLimits,
    #[error("paper-search result limit must be between one and ten")]
    InvalidResultLimit,
    #[error("paper-search cache TTLs must be positive")]
    InvalidCacheTtl,
    #[error("paper-search account rate limit must be positive")]
    InvalidRateLimit,
}

/// Bounded policy shared by exact resolution and authenticated title search.
///
/// Raw title queries are never retained here or emitted through diagnostics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PaperResolutionPolicy {
    pub arxiv_minimum_interval: Duration,
    pub exact_cache_ttl: Duration,
    pub search_min_query_chars: usize,
    pub search_max_query_chars: usize,
    pub search_max_results: usize,
    pub search_positive_cache_ttl: Duration,
    pub search_negative_cache_ttl: Duration,
    pub search_account_limit_per_minute: u32,
}

impl PaperResolutionPolicy {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        arxiv_minimum_interval: Duration,
        exact_cache_ttl: Duration,
        search_min_query_chars: usize,
        search_max_query_chars: usize,
        search_max_results: usize,
        search_positive_cache_ttl: Duration,
        search_negative_cache_ttl: Duration,
        search_account_limit_per_minute: u32,
    ) -> Result<Self, PaperResolutionPolicyError> {
        if search_min_query_chars == 0
            || search_max_query_chars > 300
            || search_min_query_chars > search_max_query_chars
        {
            return Err(PaperResolutionPolicyError::InvalidQueryLimits);
        }
        if !(1..=10).contains(&search_max_results) {
            return Err(PaperResolutionPolicyError::InvalidResultLimit);
        }
        if search_positive_cache_ttl.is_zero()
            || search_negative_cache_ttl.is_zero()
            || search_positive_cache_ttl > MAX_SEARCH_POSITIVE_CACHE_TTL
            || search_negative_cache_ttl > MAX_SEARCH_NEGATIVE_CACHE_TTL
            || search_negative_cache_ttl > search_positive_cache_ttl
        {
            return Err(PaperResolutionPolicyError::InvalidCacheTtl);
        }
        if search_account_limit_per_minute == 0
            || search_account_limit_per_minute > MAX_SEARCH_ACCOUNT_LIMIT_PER_MINUTE
        {
            return Err(PaperResolutionPolicyError::InvalidRateLimit);
        }
        Ok(Self {
            arxiv_minimum_interval,
            exact_cache_ttl,
            search_min_query_chars,
            search_max_query_chars,
            search_max_results,
            search_positive_cache_ttl,
            search_negative_cache_ttl,
            search_account_limit_per_minute,
        })
    }

    const fn exact_only(arxiv_minimum_interval: Duration, exact_cache_ttl: Duration) -> Self {
        Self {
            arxiv_minimum_interval,
            exact_cache_ttl,
            search_min_query_chars: 3,
            search_max_query_chars: 300,
            search_max_results: 10,
            search_positive_cache_ttl: Duration::from_secs(24 * 60 * 60),
            search_negative_cache_ttl: Duration::from_secs(15 * 60),
            search_account_limit_per_minute: 10,
        }
    }
}

#[derive(Clone)]
pub struct PaperResolutionService {
    store: Arc<dyn PaperResolutionStore>,
    arxiv: Arc<dyn PaperMetadataSource>,
    rate_limits: Option<Arc<dyn PaperResolutionRateLimitStore>>,
    policy: PaperResolutionPolicy,
}

impl PaperResolutionService {
    #[must_use]
    pub fn new(
        store: PaperRepository,
        arxiv: ArxivClient,
        arxiv_minimum_interval: Duration,
        arxiv_cache_ttl: Duration,
    ) -> Self {
        Self::with_dependencies(
            Arc::new(store),
            Arc::new(arxiv),
            arxiv_minimum_interval,
            arxiv_cache_ttl,
        )
    }

    #[must_use]
    pub const fn with_dependencies(
        store: Arc<dyn PaperResolutionStore>,
        arxiv: Arc<dyn PaperMetadataSource>,
        arxiv_minimum_interval: Duration,
        arxiv_cache_ttl: Duration,
    ) -> Self {
        Self {
            store,
            arxiv,
            rate_limits: None,
            policy: PaperResolutionPolicy::exact_only(arxiv_minimum_interval, arxiv_cache_ttl),
        }
    }

    #[must_use]
    pub fn with_search(
        store: PaperRepository,
        arxiv: ArxivClient,
        rate_limits: RateLimitRepository,
        policy: PaperResolutionPolicy,
    ) -> Self {
        Self::with_search_dependencies(
            Arc::new(store),
            Arc::new(arxiv),
            Arc::new(rate_limits),
            policy,
        )
    }

    #[must_use]
    pub fn with_search_dependencies(
        store: Arc<dyn PaperResolutionStore>,
        arxiv: Arc<dyn PaperMetadataSource>,
        rate_limits: Arc<dyn PaperResolutionRateLimitStore>,
        policy: PaperResolutionPolicy,
    ) -> Self {
        Self {
            store,
            arxiv,
            rate_limits: Some(rate_limits),
            policy,
        }
    }

    #[allow(clippy::too_many_lines)] // Keep the cache, gate, upstream, and observability outcomes in one auditable flow.
    pub async fn resolve_exact(
        &self,
        arxiv_id: &str,
    ) -> Result<ResolvedPaper, PaperResolutionError> {
        let normalized =
            normalize_arxiv_id(arxiv_id).map_err(|_| PaperResolutionError::InvalidArxivId)?;

        let local_started = Instant::now();
        if let Some(paper) = self.store.get_by_arxiv_base(&normalized.base_id).await? {
            record_arxiv_access(
                ArxivOperationClass::ExactResolve,
                ArxivAccessOutcome::LocalPaperHit,
                local_started.elapsed(),
            );
            let summary = self
                .store
                .get_summary(paper.id)
                .await?
                .ok_or(PaperResolutionError::NotFound)?;
            return Ok(ResolvedPaper {
                summary,
                license_uri: paper.metadata.license_uri,
            });
        }

        let cache_key = format!("exact:{}", normalized.as_query_id());
        let cache_started = Instant::now();
        let cached = self.store.get_cached_arxiv(&cache_key).await?;
        let metadata = if let Some(mut cached) = cached {
            record_arxiv_access(
                ArxivOperationClass::ExactResolve,
                ArxivAccessOutcome::CacheHit,
                cache_started.elapsed(),
            );
            cached.pop()
        } else {
            record_arxiv_access(
                ArxivOperationClass::ExactResolve,
                ArxivAccessOutcome::CacheMiss,
                cache_started.elapsed(),
            );
            let gate_started = Instant::now();
            if let Err(error) = self
                .store
                .reserve_arxiv_request(self.policy.arxiv_minimum_interval)
                .await
            {
                record_arxiv_access(
                    ArxivOperationClass::ExactResolve,
                    ArxivAccessOutcome::GateUnavailable,
                    gate_started.elapsed(),
                );
                return Err(error.into());
            }
            record_arxiv_access(
                ArxivOperationClass::ExactResolve,
                ArxivAccessOutcome::GateGranted,
                gate_started.elapsed(),
            );
            let fetch_started = Instant::now();
            let fetched = match self.arxiv.fetch_by_id(&normalized.as_query_id()).await {
                Ok(fetched) => {
                    record_arxiv_access(
                        ArxivOperationClass::ExactResolve,
                        if fetched.is_some() {
                            ArxivAccessOutcome::FetchSuccess
                        } else {
                            ArxivAccessOutcome::FetchNoResult
                        },
                        fetch_started.elapsed(),
                    );
                    fetched
                }
                Err(error) => {
                    record_arxiv_access(
                        ArxivOperationClass::ExactResolve,
                        provider_failure_outcome(&error),
                        fetch_started.elapsed(),
                    );
                    let cooldown_publication_error = if let Some(cooldown) = error.shared_cooldown()
                    {
                        self.store.defer_arxiv_requests(cooldown).await.err()
                    } else {
                        None
                    };
                    return Err(PaperResolutionError::ArxivUnavailable {
                        error,
                        cooldown_publication_error,
                    });
                }
            };
            match &fetched {
                Some(metadata) => {
                    self.store
                        .put_cached_arxiv(
                            &cache_key,
                            "exact_id",
                            std::slice::from_ref(metadata),
                            self.policy.exact_cache_ttl,
                        )
                        .await?;
                }
                None => {
                    self.store
                        .put_cached_arxiv(
                            &cache_key,
                            "exact_id",
                            &[],
                            negative_exact_cache_ttl(self.policy.exact_cache_ttl),
                        )
                        .await?;
                }
            }
            fetched
        }
        .ok_or(PaperResolutionError::NotFound)?;

        let paper = self.store.upsert_metadata(&metadata).await?;
        let summary = self
            .store
            .get_summary(paper.id)
            .await?
            .ok_or(PaperResolutionError::NotFound)?;
        Ok(ResolvedPaper {
            summary,
            license_uri: paper.metadata.license_uri,
        })
    }

    /// Searches arXiv metadata without creating a canonical paper or library
    /// item. The shared cache key is a one-way digest of the normalized title.
    #[allow(clippy::too_many_lines)] // Keep the private rate-limit, cache, source, and bounded-result path visibly ordered.
    pub async fn search_title(
        &self,
        user_id: AuthenticatedUserId,
        query: &str,
        limit: usize,
    ) -> Result<PaperSearchResult, PaperSearchError> {
        let normalized_query = normalize_title_query(query, self.policy)?;
        if !(1..=self.policy.search_max_results).contains(&limit) {
            return Err(PaperSearchError::InvalidLimit);
        }
        let rate_limits = self
            .rate_limits
            .as_ref()
            .ok_or(PaperSearchError::InvalidRateLimitPolicy)?;
        let request = RateLimitRequest::new(
            "paper_search",
            format!("user:{user_id}"),
            self.policy.search_account_limit_per_minute,
            SEARCH_RATE_LIMIT_WINDOW,
        )
        .map_err(|_| PaperSearchError::InvalidRateLimitPolicy)?;
        let caller_limit_started = Instant::now();
        let decision = rate_limits.check(&request).await?;
        if !decision.allowed {
            record_arxiv_access(
                ArxivOperationClass::TitleSearch,
                ArxivAccessOutcome::CallerRateLimited,
                caller_limit_started.elapsed(),
            );
            return Err(PaperSearchError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(60).max(1),
            });
        }

        let cache_key = title_cache_key(&normalized_query);
        let cache_started = Instant::now();
        let (candidates, cache_status) =
            if let Some(cached) = self.store.get_cached_arxiv(&cache_key).await? {
                record_arxiv_access(
                    ArxivOperationClass::TitleSearch,
                    ArxivAccessOutcome::CacheHit,
                    cache_started.elapsed(),
                );
                record_cache_result(CacheClass::PaperSearch, CacheOutcome::Hit);
                (cached, PaperSearchCacheStatus::Hit)
            } else {
                record_arxiv_access(
                    ArxivOperationClass::TitleSearch,
                    ArxivAccessOutcome::CacheMiss,
                    cache_started.elapsed(),
                );
                record_cache_result(CacheClass::PaperSearch, CacheOutcome::Miss);
                let gate_started = Instant::now();
                if let Err(error) = self
                    .store
                    .reserve_arxiv_request(self.policy.arxiv_minimum_interval)
                    .await
                {
                    record_arxiv_access(
                        ArxivOperationClass::TitleSearch,
                        ArxivAccessOutcome::GateUnavailable,
                        gate_started.elapsed(),
                    );
                    return Err(error.into());
                }
                record_arxiv_access(
                    ArxivOperationClass::TitleSearch,
                    ArxivAccessOutcome::GateGranted,
                    gate_started.elapsed(),
                );
                let fetch_started = Instant::now();
                let fetched = match self
                    .arxiv
                    .search_by_title(&normalized_query, self.policy.search_max_results)
                    .await
                {
                    Ok(fetched) => {
                        record_arxiv_access(
                            ArxivOperationClass::TitleSearch,
                            if fetched.is_empty() {
                                ArxivAccessOutcome::FetchNoResult
                            } else {
                                ArxivAccessOutcome::FetchSuccess
                            },
                            fetch_started.elapsed(),
                        );
                        fetched
                    }
                    Err(error) => {
                        record_arxiv_access(
                            ArxivOperationClass::TitleSearch,
                            provider_failure_outcome(&error),
                            fetch_started.elapsed(),
                        );
                        let cooldown_publication_error =
                            if let Some(cooldown) = error.shared_cooldown() {
                                self.store.defer_arxiv_requests(cooldown).await.err()
                            } else {
                                None
                            };
                        return Err(PaperSearchError::ArxivUnavailable {
                            error,
                            cooldown_publication_error,
                        });
                    }
                };
                let ttl = if fetched.is_empty() {
                    self.policy.search_negative_cache_ttl
                } else {
                    self.policy.search_positive_cache_ttl
                };
                self.store
                    .put_cached_arxiv(&cache_key, SEARCH_CACHE_QUERY_KIND, &fetched, ttl)
                    .await?;
                (fetched, PaperSearchCacheStatus::Miss)
            };
        Ok(PaperSearchResult {
            query_id: Uuid::now_v7(),
            normalized_query,
            candidates: candidates.into_iter().take(limit).collect(),
            cache_status,
        })
    }
}

fn provider_failure_outcome(error: &ArxivError) -> ArxivAccessOutcome {
    match error {
        ArxivError::HttpStatus { status, .. } if status.as_u16() == 429 => {
            ArxivAccessOutcome::ProviderRateLimited
        }
        _ => ArxivAccessOutcome::ProviderUnavailable,
    }
}

fn normalize_title_query(
    query: &str,
    policy: PaperResolutionPolicy,
) -> Result<String, PaperSearchError> {
    if query.chars().count() > policy.search_max_query_chars
        || query
            .chars()
            .any(|character| character.is_control() && !character.is_whitespace())
    {
        return Err(PaperSearchError::InvalidQuery);
    }
    let normalized = query
        .nfkc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let normalized_chars = normalized.chars().count();
    if normalized_chars < policy.search_min_query_chars {
        return Err(PaperSearchError::QueryTooShort);
    }
    if normalized_chars > policy.search_max_query_chars {
        return Err(PaperSearchError::InvalidQuery);
    }
    Ok(normalized)
}

fn title_cache_key(normalized_query: &str) -> String {
    let digest = Sha256::digest(
        [
            b"pakperk/paper-search/v1\0".as_slice(),
            normalized_query.as_bytes(),
        ]
        .concat(),
    );
    let mut encoded = String::with_capacity(SEARCH_CACHE_POLICY_VERSION.len() + 1 + 64);
    encoded.push_str(SEARCH_CACHE_POLICY_VERSION);
    encoded.push(':');
    for byte in digest {
        write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    encoded
}

fn negative_exact_cache_ttl(configured: Duration) -> Duration {
    configured
        .min(NEGATIVE_EXACT_ARXIV_CACHE_TTL)
        .max(Duration::from_secs(1))
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use arxiv_client::ArxivError;
    use async_trait::async_trait;
    use chrono::{TimeZone, Utc};
    use db::{DbError, RateLimitDecision};
    use domain::{ArxivIdentifier, Author, Capabilities, Paper, PaperMetadata, PaperSummary};
    use url::Url;
    use uuid::Uuid;

    use super::*;

    #[derive(Default)]
    struct FakeStoreState {
        paper: Option<Paper>,
        summary: Option<PaperSummary>,
        cache: Option<Vec<PaperMetadata>>,
        cache_reads: Vec<String>,
        reserve_calls: usize,
        defer_calls: Vec<Duration>,
        upsert_calls: usize,
        cache_writes: Vec<(String, String, usize, Duration)>,
    }

    #[derive(Default)]
    struct FakeStore(Mutex<FakeStoreState>);

    #[async_trait]
    impl PaperResolutionStore for FakeStore {
        async fn get_by_arxiv_base(&self, _base_id: &str) -> Result<Option<Paper>, DbError> {
            Ok(self.0.lock().unwrap().paper.clone())
        }

        async fn get_summary(
            &self,
            _paper_id: domain::PaperId,
        ) -> Result<Option<PaperSummary>, DbError> {
            Ok(self.0.lock().unwrap().summary.clone())
        }

        async fn get_cached_arxiv(
            &self,
            cache_key: &str,
        ) -> Result<Option<Vec<PaperMetadata>>, DbError> {
            let mut state = self.0.lock().unwrap();
            state.cache_reads.push(cache_key.to_owned());
            Ok(state.cache.clone())
        }

        async fn reserve_arxiv_request(&self, _minimum_interval: Duration) -> Result<(), DbError> {
            self.0.lock().unwrap().reserve_calls += 1;
            Ok(())
        }

        async fn defer_arxiv_requests(&self, cooldown: Duration) -> Result<(), DbError> {
            self.0.lock().unwrap().defer_calls.push(cooldown);
            Ok(())
        }

        async fn put_cached_arxiv(
            &self,
            cache_key: &str,
            query_kind: &str,
            papers: &[PaperMetadata],
            ttl: Duration,
        ) -> Result<(), DbError> {
            self.0.lock().unwrap().cache_writes.push((
                cache_key.to_owned(),
                query_kind.to_owned(),
                papers.len(),
                ttl,
            ));
            Ok(())
        }

        async fn upsert_metadata(&self, metadata: &PaperMetadata) -> Result<Paper, DbError> {
            let mut state = self.0.lock().unwrap();
            state.upsert_calls += 1;
            Ok(Paper {
                id: state.summary.as_ref().unwrap().paper_id,
                metadata: metadata.clone(),
            })
        }
    }

    struct FakeArxiv {
        result: Mutex<Option<Result<Option<PaperMetadata>, ArxivError>>>,
        calls: Mutex<Vec<String>>,
    }

    struct FakeSearchSource {
        result: Mutex<Option<Result<Vec<PaperMetadata>, ArxivError>>>,
        calls: Mutex<Vec<(String, usize)>>,
    }

    #[async_trait]
    impl PaperMetadataSource for FakeSearchSource {
        async fn fetch_by_id(&self, _arxiv_id: &str) -> Result<Option<PaperMetadata>, ArxivError> {
            unreachable!("title-search tests do not resolve exact identifiers")
        }

        async fn search_by_title(
            &self,
            normalized_title: &str,
            limit: usize,
        ) -> Result<Vec<PaperMetadata>, ArxivError> {
            self.calls
                .lock()
                .unwrap()
                .push((normalized_title.to_owned(), limit));
            self.result.lock().unwrap().take().unwrap()
        }
    }

    #[derive(Default)]
    struct FakeRateLimits {
        calls: Mutex<Vec<(String, String, u32, Duration)>>,
        denial_retry_after: Option<u64>,
    }

    #[async_trait]
    impl PaperResolutionRateLimitStore for FakeRateLimits {
        async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
            self.calls.lock().unwrap().push((
                request.bucket().to_owned(),
                request.scope_key().to_owned(),
                request.limit(),
                request.window(),
            ));
            let allowed = self.denial_retry_after.is_none();
            Ok(RateLimitDecision {
                allowed,
                limit: request.limit(),
                remaining: u32::from(allowed),
                reset_at: Utc::now() + chrono::Duration::seconds(60),
                retry_after_seconds: self.denial_retry_after,
            })
        }
    }

    #[async_trait]
    impl PaperMetadataSource for FakeArxiv {
        async fn fetch_by_id(&self, arxiv_id: &str) -> Result<Option<PaperMetadata>, ArxivError> {
            self.calls.lock().unwrap().push(arxiv_id.to_owned());
            self.result.lock().unwrap().take().unwrap()
        }

        async fn search_by_title(
            &self,
            _normalized_title: &str,
            _limit: usize,
        ) -> Result<Vec<PaperMetadata>, ArxivError> {
            unreachable!("exact-resolution tests do not search by title")
        }
    }

    #[tokio::test]
    async fn persisted_paper_bypasses_cache_gate_and_arxiv() {
        let (paper, summary) = fixture();
        let store = Arc::new(FakeStore(Mutex::new(FakeStoreState {
            paper: Some(paper.clone()),
            summary: Some(summary.clone()),
            ..FakeStoreState::default()
        })));
        let arxiv = Arc::new(FakeArxiv {
            result: Mutex::new(None),
            calls: Mutex::new(Vec::new()),
        });
        let service = PaperResolutionService::with_dependencies(
            store.clone(),
            arxiv.clone(),
            Duration::from_secs(3),
            Duration::from_secs(3600),
        );

        let resolved = service.resolve_exact("2401.12345").await.unwrap();

        assert_eq!(resolved.summary, summary);
        assert_eq!(resolved.license_uri, paper.metadata.license_uri);
        assert_eq!(store.0.lock().unwrap().reserve_calls, 0);
        assert!(arxiv.calls.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn cache_miss_reserves_fetches_caches_and_upserts_once() {
        let (paper, summary) = fixture();
        let store = Arc::new(FakeStore(Mutex::new(FakeStoreState {
            summary: Some(summary.clone()),
            ..FakeStoreState::default()
        })));
        let arxiv = Arc::new(FakeArxiv {
            result: Mutex::new(Some(Ok(Some(paper.metadata.clone())))),
            calls: Mutex::new(Vec::new()),
        });
        let service = PaperResolutionService::with_dependencies(
            store.clone(),
            arxiv.clone(),
            Duration::from_secs(3),
            Duration::from_secs(3600),
        );

        let resolved = service.resolve_exact("2401.12345v2").await.unwrap();

        assert_eq!(resolved.summary, summary);
        assert_eq!(&*arxiv.calls.lock().unwrap(), &["2401.12345v2"]);
        let state = store.0.lock().unwrap();
        assert_eq!(state.reserve_calls, 1);
        assert_eq!(state.upsert_calls, 1);
        assert_eq!(
            state.cache_writes,
            vec![(
                "exact:2401.12345v2".to_owned(),
                "exact_id".to_owned(),
                1,
                Duration::from_secs(3600),
            )],
        );
    }

    #[tokio::test]
    async fn exact_miss_uses_bounded_negative_cache_ttl() {
        let store = Arc::new(FakeStore::default());
        let arxiv = Arc::new(FakeArxiv {
            result: Mutex::new(Some(Ok(None))),
            calls: Mutex::new(Vec::new()),
        });
        let service = PaperResolutionService::with_dependencies(
            store.clone(),
            arxiv,
            Duration::from_secs(3),
            Duration::from_secs(3600),
        );

        assert!(matches!(
            service.resolve_exact("2401.12345").await,
            Err(PaperResolutionError::NotFound)
        ));
        assert_eq!(
            store.0.lock().unwrap().cache_writes,
            vec![(
                "exact:2401.12345".to_owned(),
                "exact_id".to_owned(),
                0,
                Duration::from_secs(15 * 60),
            )],
        );
    }

    #[tokio::test]
    async fn upstream_cooldown_is_published_once() {
        let store = Arc::new(FakeStore::default());
        let arxiv = Arc::new(FakeArxiv {
            result: Mutex::new(Some(Err(ArxivError::HttpStatus {
                status: http::StatusCode::TOO_MANY_REQUESTS,
                retry_after: Some(Duration::from_secs(17)),
            }))),
            calls: Mutex::new(Vec::new()),
        });
        let service = PaperResolutionService::with_dependencies(
            store.clone(),
            arxiv,
            Duration::from_secs(3),
            Duration::from_secs(3600),
        );

        let error = service.resolve_exact("2401.12345").await.unwrap_err();

        assert!(matches!(
            error,
            PaperResolutionError::ArxivUnavailable { .. }
        ));
        let state = store.0.lock().unwrap();
        assert_eq!(state.reserve_calls, 1);
        assert_eq!(state.defer_calls, vec![Duration::from_secs(17)]);
        assert!(state.cache_writes.is_empty());
    }

    #[test]
    fn title_query_normalization_is_unicode_aware_and_bounded() {
        let policy = search_policy();
        assert_eq!(
            normalize_title_query("  Ｆast\n\tPaper  ", policy).unwrap(),
            "Fast Paper"
        );
        assert!(matches!(
            normalize_title_query("  a ", policy),
            Err(PaperSearchError::QueryTooShort)
        ));
        assert!(matches!(
            normalize_title_query("paper\u{0000}title", policy),
            Err(PaperSearchError::InvalidQuery)
        ));
        assert!(matches!(
            normalize_title_query(&"x".repeat(301), policy),
            Err(PaperSearchError::InvalidQuery)
        ));
    }

    #[test]
    fn title_cache_key_never_contains_the_normalized_title() {
        let title = "private draft paper title";
        let key = title_cache_key(title);
        assert!(key.starts_with("title:v1:"));
        assert_eq!(key.len(), "title:v1:".len() + 64);
        assert!(!key.contains(title));
        assert!(!key.contains("private"));
    }

    #[tokio::test]
    async fn title_cache_hit_never_calls_arxiv_or_upserts_metadata() {
        let (paper, _) = fixture();
        let store = Arc::new(FakeStore(Mutex::new(FakeStoreState {
            cache: Some(vec![paper.metadata.clone()]),
            ..FakeStoreState::default()
        })));
        let source = Arc::new(FakeSearchSource {
            result: Mutex::new(None),
            calls: Mutex::new(Vec::new()),
        });
        let rate_limits = Arc::new(FakeRateLimits::default());
        let service = PaperResolutionService::with_search_dependencies(
            store.clone(),
            source.clone(),
            rate_limits.clone(),
            search_policy(),
        );

        let result = service
            .search_title(Uuid::from_u128(2).into(), "  Fixture   paper ", 1)
            .await
            .unwrap();

        assert_eq!(result.normalized_query, "Fixture paper");
        assert_eq!(result.candidates, vec![paper.metadata]);
        assert_eq!(result.cache_status, PaperSearchCacheStatus::Hit);
        assert!(source.calls.lock().unwrap().is_empty());
        let state = store.0.lock().unwrap();
        assert_eq!(state.reserve_calls, 0);
        assert_eq!(state.upsert_calls, 0, "search must never auto-save");
        assert_eq!(state.cache_reads, vec![title_cache_key("Fixture paper")]);
        assert!(!state.cache_reads[0].contains("Fixture paper"));
        assert_eq!(rate_limits.calls.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn title_cache_miss_fetches_bounded_candidates_without_auto_save() {
        let (paper, _) = fixture();
        let mut second = paper.metadata.clone();
        second.arxiv_id.base_id = "2401.54321".to_owned();
        let store = Arc::new(FakeStore::default());
        let source = Arc::new(FakeSearchSource {
            result: Mutex::new(Some(Ok(vec![paper.metadata.clone(), second]))),
            calls: Mutex::new(Vec::new()),
        });
        let service = PaperResolutionService::with_search_dependencies(
            store.clone(),
            source.clone(),
            Arc::new(FakeRateLimits::default()),
            search_policy(),
        );

        let result = service
            .search_title(Uuid::from_u128(2).into(), "Fixture paper", 1)
            .await
            .unwrap();

        assert_eq!(result.candidates, vec![paper.metadata]);
        assert_eq!(result.cache_status, PaperSearchCacheStatus::Miss);
        assert_eq!(
            &*source.calls.lock().unwrap(),
            &[("Fixture paper".to_owned(), 10)]
        );
        let state = store.0.lock().unwrap();
        assert_eq!(state.reserve_calls, 1);
        assert_eq!(state.upsert_calls, 0, "search must never auto-save");
        assert_eq!(
            state.cache_writes,
            vec![(
                title_cache_key("Fixture paper"),
                SEARCH_CACHE_QUERY_KIND.to_owned(),
                2,
                Duration::from_secs(86_400),
            )]
        );
    }

    #[tokio::test]
    async fn empty_title_search_uses_short_negative_ttl() {
        let store = Arc::new(FakeStore::default());
        let source = Arc::new(FakeSearchSource {
            result: Mutex::new(Some(Ok(Vec::new()))),
            calls: Mutex::new(Vec::new()),
        });
        let service = PaperResolutionService::with_search_dependencies(
            store.clone(),
            source,
            Arc::new(FakeRateLimits::default()),
            search_policy(),
        );

        let result = service
            .search_title(Uuid::from_u128(2).into(), "Nothing here", 8)
            .await
            .unwrap();

        assert!(result.candidates.is_empty());
        assert_eq!(
            store.0.lock().unwrap().cache_writes[0].3,
            Duration::from_secs(900)
        );
    }

    #[tokio::test]
    async fn account_rate_limit_precedes_cache_or_upstream_work() {
        let store = Arc::new(FakeStore::default());
        let source = Arc::new(FakeSearchSource {
            result: Mutex::new(None),
            calls: Mutex::new(Vec::new()),
        });
        let service = PaperResolutionService::with_search_dependencies(
            store.clone(),
            source,
            Arc::new(FakeRateLimits {
                calls: Mutex::new(Vec::new()),
                denial_retry_after: Some(13),
            }),
            search_policy(),
        );

        assert!(matches!(
            service
                .search_title(Uuid::from_u128(2).into(), "Fixture paper", 8)
                .await,
            Err(PaperSearchError::RateLimited {
                retry_after_seconds: 13
            })
        ));
        let state = store.0.lock().unwrap();
        assert!(state.cache_reads.is_empty());
        assert_eq!(state.reserve_calls, 0);
    }

    fn search_policy() -> PaperResolutionPolicy {
        PaperResolutionPolicy::new(
            Duration::from_secs(3),
            Duration::from_secs(3600),
            3,
            300,
            10,
            Duration::from_secs(86_400),
            Duration::from_secs(900),
            10,
        )
        .unwrap()
    }

    fn fixture() -> (Paper, PaperSummary) {
        let now = Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap();
        let paper_id = Uuid::from_u128(1);
        let abs_url = Url::parse("https://arxiv.org/abs/2401.12345v2").unwrap();
        let pdf_url = Url::parse("https://arxiv.org/pdf/2401.12345v2").unwrap();
        let license_uri =
            Some(Url::parse("https://arxiv.org/licenses/nonexclusive-distrib/1.0/").unwrap());
        let metadata = PaperMetadata {
            arxiv_id: ArxivIdentifier {
                base_id: "2401.12345".to_owned(),
                version: 2,
            },
            title: "Fixture paper".to_owned(),
            abstract_text: "Abstract".to_owned(),
            authors: vec![Author::from("Ada Lovelace".to_owned())],
            primary_category: "cs.AI".to_owned(),
            categories: vec!["cs.AI".to_owned()],
            published_at: now,
            updated_at: now,
            abs_url: abs_url.clone(),
            pdf_url: pdf_url.clone(),
            doi: None,
            journal_reference: None,
            comment: None,
            license_uri: license_uri.clone(),
            metadata_fetched_at: now,
        };
        let paper = Paper {
            id: paper_id,
            metadata,
        };
        let summary = PaperSummary {
            paper_id,
            arxiv_id: "2401.12345v2".to_owned(),
            title: "Fixture paper".to_owned(),
            abstract_text: "Abstract".to_owned(),
            authors: vec!["Ada Lovelace".to_owned()],
            primary_category: "cs.AI".to_owned(),
            categories: vec!["cs.AI".to_owned()],
            published_at: now,
            updated_at: now,
            abs_url,
            pdf_url,
            capabilities: Capabilities::metadata_only(),
        };
        (paper, summary)
    }
}
