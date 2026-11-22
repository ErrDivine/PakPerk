use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex, PoisonError},
    time::{Duration, Instant},
};

use arxiv_client::normalize_arxiv_id;
use db::RecommendationCitationPaper;
use domain::PaperId;
use recommendations::{CitationDirection, CitationPair, CitationRoot};
use reqwest::{Client, ClientBuilder, StatusCode, Url, header::RETRY_AFTER, redirect::Policy};
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;
use thiserror::Error;
use tokio::{sync::Semaphore, time::timeout};

const WORKS_ENDPOINT: &str = "https://api.openalex.org/works";
const ARXIV_DOI_PREFIX: &str = "10.48550/arxiv.";
const MAX_ROOTS: usize = 10;
const MAX_CANDIDATES: usize = 50;
const DOIS_PER_REQUEST: usize = 100;
const MAX_ENCODED_FILTER_BYTES: usize = 3600;
const MAX_DOI_BYTES: usize = 128;
const MAX_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const MAX_REFERENCES: usize = 4096;
const LOCATIONS_PER_WORK: usize = 100;
const LOOKUP_TIMEOUT: Duration = Duration::from_millis(1500);
const REQUEST_TIMEOUT: Duration = Duration::from_millis(1250);
const WORK_TTL: Duration = Duration::from_hours(1);
const MISSING_OR_AMBIGUOUS_TTL: Duration = Duration::from_mins(5);
const CACHE_CAPACITY: usize = 1024;
const DEFAULT_RATE_LIMIT_DELAY: Duration = Duration::from_secs(30);
const MAX_RATE_LIMIT_DELAY: Duration = Duration::from_hours(24);

#[derive(Debug, Error)]
pub(crate) enum OpenAlexCitationError {
    #[error("could not initialize OpenAlex client")]
    Initialization,
    #[error("OpenAlex citation input exceeds the authorized lookup bounds")]
    InputBounds,
    #[error("OpenAlex citation lookup timed out")]
    Timeout,
    #[error("OpenAlex request failed")]
    Transport,
    #[error("OpenAlex returned HTTP {0}")]
    Status(StatusCode),
    #[error("OpenAlex citation lookups are rate limited")]
    RateLimited,
    #[error("OpenAlex returned an oversized citation response")]
    ResponseBounds,
    #[error("OpenAlex returned an incomplete or invalid work response")]
    InvalidResponse,
}

#[derive(Clone)]
pub(crate) struct OpenAlexCitationClient {
    client: Client,
    endpoint: Url,
    api_key: SecretString,
    cache: Arc<Mutex<WorkCache>>,
    requests: Arc<Semaphore>,
}

impl OpenAlexCitationClient {
    pub(crate) fn new(api_key: SecretString) -> Result<Self, OpenAlexCitationError> {
        let client = client_builder()
            .build()
            .map_err(|_| OpenAlexCitationError::Initialization)?;
        let endpoint =
            Url::parse(WORKS_ENDPOINT).map_err(|_| OpenAlexCitationError::Initialization)?;
        Ok(Self {
            client,
            endpoint,
            api_key,
            cache: Arc::new(Mutex::new(WorkCache::default())),
            requests: Arc::new(Semaphore::new(1)),
        })
    }

    #[cfg(test)]
    pub(crate) fn with_endpoint(mut self, endpoint: Url) -> Self {
        self.endpoint = endpoint;
        self.client = client_builder().no_proxy().build().unwrap();
        self
    }

    pub(crate) async fn citation_pairs(
        &self,
        roots: &[(CitationRoot, Option<String>)],
        candidates: &[RecommendationCitationPaper],
    ) -> Result<Vec<CitationPair>, OpenAlexCitationError> {
        if roots.len() > MAX_ROOTS || candidates.len() > MAX_CANDIDATES {
            return Err(OpenAlexCitationError::InputBounds);
        }
        if roots.is_empty() || candidates.is_empty() {
            return Ok(Vec::new());
        }

        let root_aliases = roots
            .iter()
            .map(|(root, doi)| paper_aliases(&root.base_arxiv_id, doi.as_deref()))
            .collect::<Vec<_>>();
        let candidate_aliases = candidates
            .iter()
            .map(|paper| paper_aliases(&paper.base_arxiv_id, paper.doi.as_deref()))
            .collect::<Vec<_>>();
        if root_aliases.iter().all(Vec::is_empty) || candidate_aliases.iter().all(Vec::is_empty) {
            return Ok(Vec::new());
        }
        let dois = root_aliases
            .iter()
            .chain(&candidate_aliases)
            .flatten()
            .cloned()
            .collect::<BTreeSet<_>>();
        let works = timeout(LOOKUP_TIMEOUT, self.resolve_works(dois))
            .await
            .map_err(|_| OpenAlexCitationError::Timeout)??;

        let resolved_roots = resolve_papers(
            roots.iter().map(|(root, _)| root.paper_id),
            &root_aliases,
            &works,
        );
        let resolved_candidates = resolve_papers(
            candidates.iter().map(|paper| paper.paper_id),
            &candidate_aliases,
            &works,
        );
        Ok(pairs_from_works(
            roots,
            &resolved_roots,
            &resolved_candidates,
        ))
    }

    async fn resolve_works(
        &self,
        dois: BTreeSet<String>,
    ) -> Result<BTreeMap<String, DoiMatch>, OpenAlexCitationError> {
        // A single in-process lookup at a time lets overlapping generations share cache fills.
        let _permit = self
            .requests
            .acquire()
            .await
            .map_err(|_| OpenAlexCitationError::Transport)?;
        let now = Instant::now();
        let (mut resolved, missing, limited) = {
            let mut cache = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
            cache
                .entries
                .retain(|_, entry| now.duration_since(entry.inserted_at) < entry.result.ttl());
            let mut resolved = BTreeMap::new();
            let mut missing = Vec::new();
            for doi in dois {
                if let Some(entry) = cache.entries.get(&doi) {
                    resolved.insert(doi, entry.result.clone());
                } else {
                    missing.push(doi);
                }
            }
            (
                resolved,
                missing,
                cache.resume_at.is_some_and(|at| at > now),
            )
        };
        if limited && !missing.is_empty() {
            return Err(OpenAlexCitationError::RateLimited);
        }

        let mut remaining = missing.as_slice();
        while !remaining.is_empty() {
            let batch_size = doi_batch_size(remaining);
            if batch_size == 0 {
                return Err(OpenAlexCitationError::InputBounds);
            }
            let (chunk, rest) = remaining.split_at(batch_size);
            let matches = self.fetch_chunk(chunk).await?;
            let mut cache = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
            cache.insert(&matches, Instant::now());
            resolved.extend(matches);
            remaining = rest;
        }
        Ok(resolved)
    }

    async fn fetch_chunk(
        &self,
        dois: &[String],
    ) -> Result<BTreeMap<String, DoiMatch>, OpenAlexCitationError> {
        let filter = format!("doi:{}", dois.join("|"));
        let mut response = self
            .client
            .get(self.endpoint.clone())
            .query(&[
                ("filter", filter.as_str()),
                (
                    "select",
                    "id,doi,locations,locations_count,referenced_works",
                ),
                ("per_page", "100"),
                ("corpus", "all"),
            ])
            .bearer_auth(self.api_key.expose_secret())
            .send()
            .await
            .map_err(|error| transport_error(&error))?;
        let status = response.status();
        if status == StatusCode::TOO_MANY_REQUESTS {
            let delay = response
                .headers()
                .get(RETRY_AFTER)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<u64>().ok())
                .map_or(DEFAULT_RATE_LIMIT_DELAY, Duration::from_secs)
                .clamp(Duration::from_secs(1), MAX_RATE_LIMIT_DELAY);
            self.cache
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .resume_at = Some(Instant::now() + delay);
            return Err(OpenAlexCitationError::RateLimited);
        }
        if !status.is_success() {
            return Err(OpenAlexCitationError::Status(status));
        }

        let mut body = Vec::new();
        if response
            .content_length()
            .is_some_and(|bytes| bytes > MAX_RESPONSE_BYTES as u64)
        {
            return Err(OpenAlexCitationError::ResponseBounds);
        }
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| transport_error(&error))?
        {
            if chunk.len() > MAX_RESPONSE_BYTES - body.len() {
                return Err(OpenAlexCitationError::ResponseBounds);
            }
            body.extend_from_slice(&chunk);
        }
        let page: WorkPage =
            serde_json::from_slice(&body).map_err(|_| OpenAlexCitationError::InvalidResponse)?;
        page.verify_matches(dois)
    }
}

fn client_builder() -> ClientBuilder {
    Client::builder()
        .redirect(Policy::none())
        .retry(reqwest::retry::never())
        .timeout(REQUEST_TIMEOUT)
}

fn doi_batch_size(dois: &[String]) -> usize {
    let mut bytes = "doi%3A".len();
    dois.iter()
        .take(DOIS_PER_REQUEST)
        .take_while(|doi| {
            bytes += "%7C".len()
                + url::form_urlencoded::byte_serialize(doi.as_bytes())
                    .map(str::len)
                    .sum::<usize>();
            bytes <= MAX_ENCODED_FILTER_BYTES
        })
        .count()
}

fn transport_error(error: &reqwest::Error) -> OpenAlexCitationError {
    if error.is_timeout() {
        OpenAlexCitationError::Timeout
    } else {
        OpenAlexCitationError::Transport
    }
}

#[derive(Clone)]
enum DoiMatch {
    Missing,
    Matched(Arc<Work>),
    Ambiguous,
}

impl DoiMatch {
    const fn ttl(&self) -> Duration {
        match self {
            Self::Matched(_) => WORK_TTL,
            Self::Missing | Self::Ambiguous => MISSING_OR_AMBIGUOUS_TTL,
        }
    }
}

#[derive(Default)]
struct WorkCache {
    entries: BTreeMap<String, CachedWork>,
    resume_at: Option<Instant>,
}

struct CachedWork {
    result: DoiMatch,
    inserted_at: Instant,
}

impl WorkCache {
    fn insert(&mut self, matches: &BTreeMap<String, DoiMatch>, now: Instant) {
        self.entries.extend(matches.iter().map(|(doi, result)| {
            (
                doi.clone(),
                CachedWork {
                    result: result.clone(),
                    inserted_at: now,
                },
            )
        }));

        let overflow = self.entries.len().saturating_sub(CACHE_CAPACITY);
        if overflow > 0 {
            let mut oldest = self
                .entries
                .iter()
                .map(|(doi, entry)| (entry.inserted_at, doi.clone()))
                .collect::<Vec<_>>();
            oldest.sort_unstable();
            for (_, doi) in oldest.into_iter().take(overflow) {
                self.entries.remove(&doi);
            }
        }
    }
}

#[derive(Deserialize)]
struct WorkPage {
    meta: PageMetadata,
    results: Vec<WorkRecord>,
}

#[derive(Deserialize)]
struct PageMetadata {
    count: usize,
}

#[derive(Deserialize)]
struct WorkRecord {
    id: String,
    doi: Option<String>,
    locations: Vec<WorkLocation>,
    locations_count: usize,
    referenced_works: Vec<String>,
}

#[derive(Deserialize)]
struct WorkLocation {
    doi: Option<String>,
}

struct Work {
    id: u64,
    references: Vec<u64>,
}

impl WorkPage {
    fn verify_matches(
        self,
        dois: &[String],
    ) -> Result<BTreeMap<String, DoiMatch>, OpenAlexCitationError> {
        if self.meta.count != self.results.len() {
            return Err(OpenAlexCitationError::InvalidResponse);
        }
        let mut seen_work_ids = BTreeSet::new();
        let mut unverified_aliases = false;
        let mut matches = dois
            .iter()
            .map(|doi| (doi.clone(), DoiMatch::Missing))
            .collect::<BTreeMap<_, _>>();
        for record in self.results {
            let id = openalex_work_id(&record.id).ok_or(OpenAlexCitationError::InvalidResponse)?;
            if !seen_work_ids.insert(id)
                || record.locations_count.min(LOCATIONS_PER_WORK) != record.locations.len()
            {
                return Err(OpenAlexCitationError::InvalidResponse);
            }
            let truncated = record.locations_count > LOCATIONS_PER_WORK;
            unverified_aliases |= truncated;
            let matched_dois = record
                .locations
                .iter()
                .filter_map(|location| location.doi.as_deref())
                .chain(record.doi.as_deref())
                .filter_map(normalize_doi)
                .filter(|doi| matches.contains_key(doi))
                .collect::<BTreeSet<_>>();
            if matched_dois.is_empty() {
                if truncated {
                    continue;
                }
                return Err(OpenAlexCitationError::InvalidResponse);
            }
            if record.referenced_works.len() > MAX_REFERENCES {
                return Err(OpenAlexCitationError::ResponseBounds);
            }
            let mut references = record
                .referenced_works
                .iter()
                .filter_map(|id| openalex_work_id(id))
                .collect::<Vec<_>>();
            references.sort_unstable();
            references.dedup();
            let work = Arc::new(Work { id, references });
            for doi in matched_dois {
                if let Some(result) = matches.get_mut(&doi) {
                    *result = if matches!(result, DoiMatch::Missing) {
                        DoiMatch::Matched(Arc::clone(&work))
                    } else {
                        DoiMatch::Ambiguous
                    };
                }
            }
        }
        // A requested DOI may match a location OpenAlex omitted from the list response.
        if unverified_aliases {
            matches.retain(|_, result| !matches!(result, DoiMatch::Missing));
        }
        Ok(matches)
    }
}

fn paper_aliases(base_arxiv_id: &str, known_doi: Option<&str>) -> Vec<String> {
    let Ok(arxiv) = normalize_arxiv_id(base_arxiv_id) else {
        return Vec::new();
    };
    let base_id = arxiv.base_id.to_ascii_lowercase();
    let Some(canonical_doi) = normalize_doi(&format!("{ARXIV_DOI_PREFIX}{base_id}")) else {
        return Vec::new();
    };
    if let Some(doi) = known_doi.and_then(normalize_doi)
        && doi != canonical_doi
        && doi.strip_prefix(ARXIV_DOI_PREFIX).is_none_or(|other_id| {
            normalize_arxiv_id(other_id).is_ok_and(|other| other.base_id == base_id)
        })
    {
        return vec![canonical_doi, doi];
    }
    vec![canonical_doi]
}

fn normalize_doi(value: &str) -> Option<String> {
    let value = value.trim();
    if value.len() > MAX_DOI_BYTES + "https://dx.doi.org/".len() {
        return None;
    }
    let value = value.to_ascii_lowercase();
    let doi = value
        .strip_prefix("https://doi.org/")
        .or_else(|| value.strip_prefix("http://doi.org/"))
        .or_else(|| value.strip_prefix("https://dx.doi.org/"))
        .or_else(|| value.strip_prefix("http://dx.doi.org/"))
        .or_else(|| value.strip_prefix("doi:").map(str::trim_start))
        .unwrap_or(&value);
    let (prefix, suffix) = doi.strip_prefix("10.")?.split_once('/')?;
    // Limit the suffix to DOI characters that cannot change the OpenAlex filter syntax.
    (doi.len() <= MAX_DOI_BYTES
        && (4..=9).contains(&prefix.len())
        && prefix.bytes().all(|byte| byte.is_ascii_digit())
        && !suffix.is_empty()
        && suffix
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._/()-;".contains(&byte)))
    .then(|| doi.to_owned())
}

fn openalex_work_id(value: &str) -> Option<u64> {
    let value = value.strip_prefix("https://openalex.org/").unwrap_or(value);
    let id = value.strip_prefix('W')?;
    if !matches!(id.as_bytes().first(), Some(b'1'..=b'9'))
        || !id.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    id.parse().ok()
}

struct ResolvedPaper<'a> {
    paper_id: PaperId,
    canonical_doi: &'a str,
    work: &'a Work,
}

fn resolve_papers<'a>(
    paper_ids: impl Iterator<Item = PaperId>,
    aliases: &'a [Vec<String>],
    works: &'a BTreeMap<String, DoiMatch>,
) -> Vec<ResolvedPaper<'a>> {
    paper_ids
        .zip(aliases)
        .filter_map(|(paper_id, aliases)| {
            let canonical_doi = aliases.first()?;
            let mut resolved = None::<&Work>;
            for doi in aliases {
                match works.get(doi)? {
                    DoiMatch::Missing => (),
                    DoiMatch::Ambiguous => return None,
                    DoiMatch::Matched(work) => {
                        if resolved.is_some_and(|previous| previous.id != work.id) {
                            return None;
                        }
                        resolved.get_or_insert(work);
                    }
                }
            }
            resolved.map(|work| ResolvedPaper {
                paper_id,
                canonical_doi,
                work,
            })
        })
        .collect()
}

fn pairs_from_works(
    roots: &[(CitationRoot, Option<String>)],
    root_works: &[ResolvedPaper<'_>],
    candidate_works: &[ResolvedPaper<'_>],
) -> Vec<CitationPair> {
    let mut owners = BTreeMap::<u64, Option<PaperId>>::new();
    for paper in root_works.iter().chain(candidate_works) {
        owners
            .entry(paper.work.id)
            .and_modify(|owner| {
                if *owner != Some(paper.paper_id) {
                    *owner = None;
                }
            })
            .or_insert(Some(paper.paper_id));
    }

    let roots = roots
        .iter()
        .map(|(root, _)| (root.paper_id, root))
        .collect::<BTreeMap<_, _>>();
    let mut pairs = BTreeMap::new();
    for root in root_works {
        if owners.get(&root.work.id) != Some(&Some(root.paper_id)) {
            continue;
        }
        for candidate in candidate_works {
            if candidate.paper_id == root.paper_id
                || candidate.canonical_doi == root.canonical_doi
                || candidate.work.id == root.work.id
                || owners.get(&candidate.work.id) != Some(&Some(candidate.paper_id))
            {
                continue;
            }
            let direction = match (
                root.work
                    .references
                    .binary_search(&candidate.work.id)
                    .is_ok(),
                candidate
                    .work
                    .references
                    .binary_search(&root.work.id)
                    .is_ok(),
            ) {
                (true, false) => CitationDirection::Reference,
                (false, true) => CitationDirection::Citing,
                (true, true) => CitationDirection::Reciprocal,
                (false, false) => continue,
            };
            pairs
                .entry((candidate.paper_id, root.paper_id))
                .or_insert_with(|| CitationPair {
                    candidate_paper_id: candidate.paper_id,
                    root: roots[&root.paper_id].clone(),
                    direction,
                });
        }
    }
    pairs.into_values().collect()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use axum::{
        Json, Router,
        body::Body,
        extract::{OriginalUri, Query},
        http::{HeaderMap, Response},
        routing::get,
    };
    use chrono::Utc;
    use recommendations::HistoricalSeedState;
    use serde_json::{Value, json};

    use super::*;

    fn root(id: u128, base_arxiv_id: &str) -> (CitationRoot, Option<String>) {
        (
            CitationRoot {
                paper_id: PaperId::from_u128(id),
                base_arxiv_id: base_arxiv_id.to_owned(),
                title: "A reviewed paper".to_owned(),
                state: HistoricalSeedState::Reviewed,
                tier: 3,
                updated_at: Utc::now(),
            },
            None,
        )
    }

    fn candidate(
        id: u128,
        base_arxiv_id: &str,
        doi: Option<String>,
    ) -> RecommendationCitationPaper {
        RecommendationCitationPaper {
            paper_id: PaperId::from_u128(id),
            base_arxiv_id: base_arxiv_id.to_owned(),
            doi,
        }
    }

    fn work(id: u64, doi: &str, location_dois: &[&str], references: &[u64]) -> Value {
        json!({
            "id": format!("https://openalex.org/W{id}"),
            "doi": format!("https://doi.org/{doi}"),
            "locations": location_dois.iter().map(|doi| json!({"doi": doi})).collect::<Vec<_>>(),
            "locations_count": location_dois.len(),
            "referenced_works": references.iter().map(|id| format!("https://openalex.org/W{id}")).collect::<Vec<_>>(),
        })
    }

    fn work_page(results: &[Value]) -> Value {
        json!({"meta": {"count": results.len()}, "results": results})
    }

    fn work_matches(work: &Value, dois: &BTreeSet<&str>) -> bool {
        let locations = work["locations"].as_array().unwrap();
        std::iter::once(&work["doi"])
            .chain(locations.iter().map(|location| &location["doi"]))
            .filter_map(|value| value.as_str().and_then(normalize_doi))
            .any(|doi| dois.contains(doi.as_str()))
    }

    async fn mock_client(router: Router) -> OpenAlexCitationClient {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        OpenAlexCitationClient::new(SecretString::from("test-key"))
            .unwrap()
            .with_endpoint(Url::parse(&format!("http://{addr}/works")).unwrap())
    }

    fn pair_ids(pairs: &[CitationPair]) -> Vec<(u128, u128, CitationDirection)> {
        pairs
            .iter()
            .map(|pair| {
                (
                    pair.candidate_paper_id.as_u128(),
                    pair.root.paper_id.as_u128(),
                    pair.direction,
                )
            })
            .collect()
    }

    #[tokio::test]
    async fn resolves_bounded_page_pairs_in_both_directions_and_caches_misses() {
        let roots = [root(1, "2501.00001"), root(5, "2501.00005")];
        let mut candidates = vec![
            candidate(
                2,
                "2501.00002",
                Some("https://doi.org/10.1000/example".into()),
            ),
            candidate(3, "2501.00003", None),
            candidate(4, "2501.00004", None),
        ];
        // Enough long, valid aliases to force multiple requests with a full page of known IDs.
        for id in 100..140 {
            let base = format!("2501.{id:05}");
            candidates.push(candidate(
                id,
                &base,
                Some(format!("10.1000/{id}{}", "x".repeat(100))),
            ));
        }
        let sent = Arc::new(Mutex::new(Vec::<String>::new()));
        let sent_by_mock = Arc::clone(&sent);
        let works = [
            work(101, "10.48550/arxiv.2501.00001", &[], &[102, 104, 999]),
            work(
                102,
                "10.1000/example",
                &["https://doi.org/10.48550/arXiv.2501.00002"],
                &[],
            ),
            work(103, "10.48550/arxiv.2501.00003", &[], &[101]),
            work(104, "10.48550/arxiv.2501.00004", &[], &[101]),
            work(105, "10.48550/arxiv.2501.00005", &[], &[102]),
        ];
        let router = Router::new().route(
            "/works",
            get(
                move |headers: HeaderMap,
                      OriginalUri(uri): OriginalUri,
                      Query(query): Query<BTreeMap<String, String>>| {
                    let sent = Arc::clone(&sent_by_mock);
                    let works = works.clone();
                    async move {
                        assert_eq!(headers["authorization"], "Bearer test-key");
                        assert_eq!(query["corpus"], "all");
                        assert!(!query.contains_key("api_key"));
                        assert_eq!(
                            query["select"],
                            "id,doi,locations,locations_count,referenced_works"
                        );
                        let filter = query["filter"].strip_prefix("doi:").unwrap();
                        let chunk = filter.split('|').collect::<BTreeSet<_>>();
                        assert!(chunk.len() <= DOIS_PER_REQUEST);
                        let encoded_filter = uri.query().unwrap().split('&').next().unwrap();
                        assert!(
                            encoded_filter.strip_prefix("filter=").unwrap().len()
                                <= MAX_ENCODED_FILTER_BYTES
                        );
                        sent.lock()
                            .unwrap()
                            .extend(chunk.iter().map(|doi| (*doi).to_owned()));
                        let results = works
                            .into_iter()
                            .filter(|work| work_matches(work, &chunk))
                            .collect::<Vec<_>>();
                        Json(work_page(&results))
                    }
                },
            ),
        );
        let client = mock_client(router).await;

        for _ in 0..2 {
            let pairs = client.citation_pairs(&roots, &candidates).await.unwrap();
            assert_eq!(
                pair_ids(&pairs),
                [
                    (2, 1, CitationDirection::Reference),
                    (2, 5, CitationDirection::Reference),
                    (3, 1, CitationDirection::Citing),
                    (4, 1, CitationDirection::Reciprocal),
                ]
            );
        }
        let sent = sent.lock().unwrap();
        assert!(doi_batch_size(&sent) < sent.len());
        let requested = roots
            .iter()
            .flat_map(|(root, doi)| paper_aliases(&root.base_arxiv_id, doi.as_deref()))
            .chain(candidates.iter().flat_map(|candidate| {
                paper_aliases(&candidate.base_arxiv_id, candidate.doi.as_deref())
            }))
            .collect::<BTreeSet<_>>();
        assert_eq!(sent.len(), requested.len());
        assert_eq!(sent.iter().cloned().collect::<BTreeSet<_>>(), requested);
    }

    #[test]
    fn rejects_ambiguous_dois_shared_work_ids_and_self_matches() {
        let roots = [root(1, "2501.00001"), root(2, "2501.00002")];
        let candidates = [
            candidate(11, "2501.00011", Some("10.1000/conflict".into())),
            candidate(12, "2501.00012", None),
            candidate(13, "2501.00013", None),
            candidate(14, "2501.00014", None),
            candidate(1, "2501.00001", None),
        ];
        let root_aliases = roots
            .iter()
            .map(|(root, _)| paper_aliases(&root.base_arxiv_id, None))
            .collect::<Vec<_>>();
        let candidate_aliases = candidates
            .iter()
            .map(|candidate| paper_aliases(&candidate.base_arxiv_id, candidate.doi.as_deref()))
            .collect::<Vec<_>>();
        let dois = root_aliases
            .iter()
            .chain(&candidate_aliases)
            .flatten()
            .cloned()
            .collect::<Vec<_>>();
        let page = work_page(&[
            work(
                101,
                "10.48550/arxiv.2501.00001",
                &[],
                &[101, 111, 112, 113, 114],
            ),
            work(
                102,
                "10.48550/arxiv.2501.00002",
                &["10.48550/arxiv.2501.00013"],
                &[114],
            ),
            work(111, "10.48550/arxiv.2501.00011", &[], &[]),
            work(112, "10.48550/arxiv.2501.00012", &[], &[]),
            work(114, "10.48550/arxiv.2501.00014", &[], &[]),
            work(121, "10.1000/conflict", &[], &[101]),
            work(122, "10.48550/arxiv.2501.00012", &[], &[101]),
        ]);
        let works = serde_json::from_value::<WorkPage>(page)
            .unwrap()
            .verify_matches(&dois)
            .unwrap();
        let root_works = resolve_papers(
            roots.iter().map(|(root, _)| root.paper_id),
            &root_aliases,
            &works,
        );
        let candidate_works = resolve_papers(
            candidates.iter().map(|candidate| candidate.paper_id),
            &candidate_aliases,
            &works,
        );
        assert_eq!(
            pair_ids(&pairs_from_works(&roots, &root_works, &candidate_works)),
            [(14, 1, CitationDirection::Reference)]
        );

        assert_eq!(
            paper_aliases("2501.00001", Some("10.1000/bad|10.1000/extra")),
            ["10.48550/arxiv.2501.00001"]
        );
        assert_eq!(
            paper_aliases("2501.00001", Some("10.48550/arXiv.2501.00002")),
            ["10.48550/arxiv.2501.00001"]
        );
        assert!(paper_aliases("2501.١٢٣٤٥", None).is_empty());
        assert!(paper_aliases(&format!("{}/0001001", "a".repeat(128)), None).is_empty());
    }

    #[test]
    fn truncated_locations_keep_verified_hits_without_caching_uncertain_misses() {
        let visible = "10.48550/arxiv.2501.00002";
        let hidden = "10.48550/arxiv.2501.00003";
        let mut truncated = work(103, "10.1000/journal", &[], &[]);
        truncated["locations_count"] = json!(LOCATIONS_PER_WORK + 1);
        truncated["locations"] = json!(vec![json!({"doi": null}); LOCATIONS_PER_WORK]);
        let page = work_page(&[work(102, visible, &[], &[101]), truncated]);
        let requested = [visible.to_owned(), hidden.to_owned()];
        let matches = serde_json::from_value::<WorkPage>(page)
            .unwrap()
            .verify_matches(&requested)
            .unwrap();
        assert!(matches!(matches.get(visible), Some(DoiMatch::Matched(work)) if work.id == 102));
        assert!(!matches.contains_key(hidden));
    }

    #[tokio::test]
    async fn failed_responses_do_not_cache_misses_and_rate_limits_delay_new_requests() {
        let requests = Arc::new(AtomicUsize::new(0));
        let request_count = Arc::clone(&requests);
        let client = mock_client(Router::new().route(
            "/works",
            get(move || {
                let attempt = request_count.fetch_add(1, Ordering::SeqCst);
                async move {
                    match attempt {
                        0 => Response::builder()
                            .status(StatusCode::FOUND)
                            .header("location", "/works")
                            .body(Body::empty())
                            .unwrap(),
                        1 => Response::builder()
                            .status(StatusCode::OK)
                            .body(Body::from(r#"{"meta":{"count":1},"results":[]}"#))
                            .unwrap(),
                        _ => Response::builder()
                            .status(StatusCode::TOO_MANY_REQUESTS)
                            .header("retry-after", "60")
                            .body(Body::empty())
                            .unwrap(),
                    }
                }
            }),
        ))
        .await;
        let roots = [root(1, "2501.00001")];
        let candidates = [candidate(2, "2501.00002", None)];
        assert!(matches!(
            client.citation_pairs(&roots, &candidates).await,
            Err(OpenAlexCitationError::Status(StatusCode::FOUND))
        ));
        assert!(matches!(
            client.citation_pairs(&roots, &candidates).await,
            Err(OpenAlexCitationError::InvalidResponse)
        ));
        for _ in 0..2 {
            assert!(matches!(
                client.citation_pairs(&roots, &candidates).await,
                Err(OpenAlexCitationError::RateLimited)
            ));
        }
        assert_eq!(requests.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    #[ignore = "uses the live OpenAlex API with OPENALEX_API_KEY"]
    async fn live_openalex_resolves_known_citations() {
        let secret =
            SecretString::from(std::env::var("OPENALEX_API_KEY").expect("set OPENALEX_API_KEY"));
        let client = OpenAlexCitationClient::new(secret).unwrap();
        let roots = [root(1, "1706.03762"), root(2, "1810.04805")];
        let candidates = [candidate(3, "2005.14165", None)];
        let pairs = client.citation_pairs(&roots, &candidates).await.unwrap();
        assert_eq!(
            pair_ids(&pairs),
            [
                (3, 1, CitationDirection::Citing),
                (3, 2, CitationDirection::Citing),
            ]
        );
        let roots = [root(3, "2005.14165")];
        let candidates = [candidate(1, "1706.03762", None)];
        let pairs = client.citation_pairs(&roots, &candidates).await.unwrap();
        assert_eq!(pair_ids(&pairs), [(1, 3, CitationDirection::Reference)]);
    }
}
