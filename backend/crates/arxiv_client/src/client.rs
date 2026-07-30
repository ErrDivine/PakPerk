use std::{
    collections::{HashMap, HashSet},
    fmt::Write as _,
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};

use chrono::Utc;
use domain::PaperMetadata;
use reqwest::{Client, StatusCode, header::RETRY_AFTER};
use sha2::{Digest, Sha256};
use tokio::{sync::RwLock, time::sleep};
use tracing::{info, warn};
use url::Url;

use crate::{
    ArxivError, MAX_EXACT_IDS_PER_REQUEST, NormalizedArxivId, RateGate, build_category_query,
    build_exact_ids_query, build_title_query, normalize_arxiv_id, parse_atom_feed,
};

const PROCESS_NEGATIVE_EXACT_CACHE_TTL: Duration = Duration::from_secs(15 * 60);

/// Network configuration. [`Self::default`] intentionally leaves
/// `contact_email` empty; construction fails until an operator supplies a real
/// monitored address.
#[derive(Debug, Clone)]
pub struct ArxivClientConfig {
    pub api_url: Url,
    pub pdf_base_url: Url,
    pub user_agent: String,
    /// Must be set to a monitored, non-placeholder address before constructing
    /// a network client.
    pub contact_email: String,
    /// The legacy API minimum is enforced at three seconds; larger values are
    /// allowed for more conservative deployments.
    pub minimum_interval: Duration,
    pub request_timeout: Duration,
    /// Internal retries share the process-local gate. Set this to zero when a
    /// database/global coordinator owns retry reservations across processes.
    pub max_retries: usize,
    pub max_atom_bytes: usize,
    pub max_pdf_bytes: usize,
}

impl Default for ArxivClientConfig {
    fn default() -> Self {
        Self {
            api_url: Url::parse("https://export.arxiv.org/api/query")
                .expect("default API URL is valid"),
            pdf_base_url: Url::parse("https://arxiv.org/pdf/").expect("default PDF URL is valid"),
            user_agent: "PakperkDemo/0.1".into(),
            contact_email: String::new(),
            minimum_interval: Duration::from_secs(3),
            request_timeout: Duration::from_secs(30),
            max_retries: 2,
            max_atom_bytes: 8 * 1024 * 1024,
            max_pdf_bytes: 50 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadedPdf {
    pub bytes: Vec<u8>,
    pub sha256_hex: String,
}

/// Random private temporary file. The PDF is deleted automatically when
/// `path` is dropped unless the caller explicitly persists it.
#[derive(Debug)]
pub struct DownloadedPdfFile {
    pub path: tempfile::TempPath,
    pub sha256_hex: String,
    pub byte_length: usize,
}

#[derive(Debug, Default)]
struct Cache {
    exact: RwLock<HashMap<String, ExactCacheEntry>>,
    title: RwLock<HashMap<(String, usize), Vec<PaperMetadata>>>,
}

#[derive(Debug, Clone)]
struct ExactCacheEntry {
    metadata: Option<PaperMetadata>,
    expires_at: Option<Instant>,
}

impl ExactCacheEntry {
    fn new(metadata: Option<PaperMetadata>) -> Self {
        let expires_at = metadata
            .is_none()
            .then(|| Instant::now() + PROCESS_NEGATIVE_EXACT_CACHE_TTL);
        Self {
            metadata,
            expires_at,
        }
    }

    fn is_fresh(&self, now: Instant) -> bool {
        self.expires_at.is_none_or(|expires_at| expires_at > now)
    }
}

#[derive(Debug, Clone)]
pub struct ArxivClient {
    config: Arc<ArxivClientConfig>,
    http: Client,
    cache: Arc<Cache>,
    externally_gated: bool,
}

impl ArxivClient {
    pub fn new(config: ArxivClientConfig) -> Result<Self, ArxivError> {
        Self::new_inner(config, false)
    }

    /// Construct a client whose every network attempt is reserved by an
    /// external cross-process start-time gate immediately before this client
    /// is called. Internal retries and the process-local gate are disabled so
    /// they cannot move the actual HTTP start away from that reservation.
    pub fn new_with_external_gate(mut config: ArxivClientConfig) -> Result<Self, ArxivError> {
        config.max_retries = 0;
        Self::new_inner(config, true)
    }

    fn new_inner(config: ArxivClientConfig, externally_gated: bool) -> Result<Self, ArxivError> {
        validate_config(&config)?;
        let agent = format!("{} ({})", config.user_agent, config.contact_email);
        let http = Client::builder()
            .user_agent(agent)
            .connect_timeout(config.request_timeout.min(Duration::from_secs(15)))
            .timeout(config.request_timeout)
            .build()?;
        Ok(Self {
            config: Arc::new(config),
            http,
            cache: Arc::new(Cache::default()),
            externally_gated,
        })
    }

    pub async fn fetch_recent(
        &self,
        categories: &[String],
        limit: usize,
    ) -> Result<Vec<PaperMetadata>, ArxivError> {
        let url = build_category_query(&self.config.api_url, categories, limit)?;
        let started = Instant::now();
        let result = self.fetch_feed(url).await;
        observe_metadata_result("recent", limit, started, &result);
        result
    }

    pub async fn fetch_by_id(&self, input: &str) -> Result<Option<PaperMetadata>, ArxivError> {
        let mut records = self.fetch_by_ids(&[input.to_owned()]).await?;
        Ok(records.pop())
    }

    /// Fetch up to [`MAX_EXACT_IDS_PER_REQUEST`] exact identifiers in one
    /// legacy API call. Positive and negative results are retained in the
    /// process cache; deployments should additionally persist them in the
    /// shared database cache.
    pub async fn fetch_by_ids(&self, inputs: &[String]) -> Result<Vec<PaperMetadata>, ArxivError> {
        if inputs.is_empty() || inputs.len() > MAX_EXACT_IDS_PER_REQUEST {
            return Err(ArxivError::InvalidConfiguration(format!(
                "exact arXiv ID batches must contain 1 to {MAX_EXACT_IDS_PER_REQUEST} identifiers"
            )));
        }
        let mut seen = HashSet::with_capacity(inputs.len());
        let mut ids = Vec::with_capacity(inputs.len());
        for input in inputs {
            let id = normalize_arxiv_id(input)?;
            if seen.insert(id.as_query_id()) {
                ids.push(id);
            }
        }

        let missing = {
            let cache = self.cache.exact.read().await;
            let now = Instant::now();
            ids.iter()
                .filter(|id| {
                    !cache
                        .get(&id.as_query_id())
                        .is_some_and(|entry| entry.is_fresh(now))
                })
                .cloned()
                .collect::<Vec<_>>()
        };
        if !missing.is_empty() {
            let url = build_exact_ids_query(&self.config.api_url, &missing)?;
            let started = Instant::now();
            let result = self.fetch_feed(url).await;
            observe_metadata_result("exact_id", missing.len(), started, &result);
            let fetched = result?;
            let mut cache = self.cache.exact.write().await;
            for id in &missing {
                let record = fetched
                    .iter()
                    .find(|metadata| exact_metadata_matches(id, metadata))
                    .cloned();
                cache.insert(id.as_query_id(), ExactCacheEntry::new(record));
            }
        }

        let cache = self.cache.exact.read().await;
        let now = Instant::now();
        Ok(ids
            .iter()
            .filter_map(|id| {
                cache
                    .get(&id.as_query_id())
                    .filter(|entry| entry.is_fresh(now))
                    .and_then(|entry| entry.metadata.clone())
            })
            .collect())
    }

    pub async fn search_by_title(
        &self,
        title: &str,
        limit: usize,
    ) -> Result<Vec<PaperMetadata>, ArxivError> {
        let key = title.split_whitespace().collect::<Vec<_>>().join(" ");
        let cache_key = (key.clone(), limit);
        if let Some(cached) = self.cache.title.read().await.get(&cache_key).cloned() {
            return Ok(cached);
        }
        let url = build_title_query(&self.config.api_url, &key, limit)?;
        let started = Instant::now();
        let result = self.fetch_feed(url).await;
        observe_metadata_result("title_search", limit, started, &result);
        let records = result?;
        self.cache
            .title
            .write()
            .await
            .insert(cache_key, records.clone());
        Ok(records)
    }

    /// Download a PDF from a URL constructed solely from a validated arXiv ID.
    /// The response is rejected before and during download when it exceeds the
    /// configured limit.
    pub async fn download_pdf(&self, input: &str) -> Result<DownloadedPdf, ArxivError> {
        let id = normalize_arxiv_id(input)?;
        let url = pdf_url(&self.config.pdf_base_url, &id)?;
        let started = Instant::now();
        let result = self
            .get_bounded(url, self.config.max_pdf_bytes, PayloadKind::Pdf)
            .await;
        observe_pdf_result(started, &result);
        let bytes = result?;
        let digest = Sha256::digest(&bytes);
        let mut sha256_hex = String::with_capacity(64);
        for byte in digest {
            write!(&mut sha256_hex, "{byte:02x}").expect("writing to String cannot fail");
        }
        Ok(DownloadedPdf { bytes, sha256_hex })
    }

    /// Download, hash, and place the bounded PDF at a random path outside the
    /// web root. Dropping the result removes the file.
    pub async fn download_pdf_to_temp(&self, input: &str) -> Result<DownloadedPdfFile, ArxivError> {
        let downloaded = self.download_pdf(input).await?;
        write_pdf_to_temp(downloaded).await
    }

    async fn fetch_feed(&self, url: Url) -> Result<Vec<PaperMetadata>, ArxivError> {
        let body = self
            .get_bounded(url, self.config.max_atom_bytes, PayloadKind::Atom)
            .await?;
        let body = String::from_utf8(body)
            .map_err(|_| ArxivError::Xml("Atom response is not UTF-8".into()))?;
        parse_atom_feed(&body, Utc::now())
    }

    async fn get_bounded(
        &self,
        url: Url,
        maximum_bytes: usize,
        payload_kind: PayloadKind,
    ) -> Result<Vec<u8>, ArxivError> {
        let mut attempt = 0;
        loop {
            let request_started = Instant::now();
            let request = || async {
                let response = self.http.get(url.clone()).send().await?;
                let status = response.status();
                if status.is_success() {
                    return read_bounded(response, maximum_bytes, payload_kind)
                        .await
                        .map(RequestOutcome::Body);
                }
                Ok(RequestOutcome::Status {
                    status,
                    retry_after: retry_after(&response),
                })
            };
            let outcome = if self.externally_gated {
                request().await
            } else {
                RateGate::global()
                    .run(self.config.minimum_interval, request)
                    .await
            };
            observe_http_attempt(payload_kind, attempt + 1, request_started, &outcome);
            match outcome {
                Ok(RequestOutcome::Body(body)) => return Ok(body),
                Ok(RequestOutcome::Status {
                    status,
                    retry_after,
                }) => {
                    if attempt >= self.config.max_retries || !is_retryable(status) {
                        return Err(ArxivError::HttpStatus {
                            status,
                            retry_after,
                        });
                    }
                    if retry_after.is_some_and(|delay| delay > Duration::from_secs(60)) {
                        // Do not violate a long Retry-After by retrying early,
                        // and do not hold a worker task asleep without bound.
                        return Err(ArxivError::HttpStatus {
                            status,
                            retry_after,
                        });
                    }
                    let delay = retry_after.unwrap_or_else(|| backoff_delay(attempt));
                    attempt += 1;
                    sleep(delay).await;
                }
                Err(ArxivError::Transport(error))
                    if attempt < self.config.max_retries
                        && (error.is_timeout() || error.is_connect()) =>
                {
                    let delay = backoff_delay(attempt);
                    attempt += 1;
                    sleep(delay).await;
                }
                Err(error) => return Err(error),
            }
        }
    }
}

fn exact_metadata_matches(id: &NormalizedArxivId, metadata: &PaperMetadata) -> bool {
    metadata.arxiv_id.base_id == id.base_id
        && id
            .version
            .is_none_or(|version| metadata.arxiv_id.version == version)
}

async fn write_pdf_to_temp(downloaded: DownloadedPdf) -> Result<DownloadedPdfFile, ArxivError> {
    let byte_length = downloaded.bytes.len();
    let temporary = tempfile::Builder::new()
        .prefix("pakperk-")
        .suffix(".pdf")
        .tempfile()?
        .into_temp_path();
    tokio::fs::write(&temporary, downloaded.bytes).await?;
    Ok(DownloadedPdfFile {
        path: temporary,
        sha256_hex: downloaded.sha256_hex,
        byte_length,
    })
}

fn validate_config(config: &ArxivClientConfig) -> Result<(), ArxivError> {
    if !config.user_agent.to_ascii_lowercase().contains("pakperk")
        || !is_real_contact(&config.contact_email)
    {
        return Err(ArxivError::InvalidConfiguration(
            "a Pakperk user agent and monitored, non-placeholder contact email are required".into(),
        ));
    }
    if config.minimum_interval < Duration::from_secs(3) {
        return Err(ArxivError::InvalidConfiguration(
            "arXiv legacy API interval must be at least three seconds".into(),
        ));
    }
    if config.max_atom_bytes == 0 || config.max_pdf_bytes == 0 || config.max_retries > 5 {
        return Err(ArxivError::InvalidConfiguration(
            "response limits must be positive and retries at most five".into(),
        ));
    }
    Ok(())
}

fn is_real_contact(contact: &str) -> bool {
    let contact = contact.trim();
    if contact.chars().any(char::is_control) {
        return false;
    }
    let Some((local, domain)) = contact.rsplit_once('@') else {
        return false;
    };
    !local.is_empty()
        && domain.contains('.')
        && !matches!(
            domain.to_ascii_lowercase().as_str(),
            "example.com" | "example.org" | "example.net"
        )
        && !domain.to_ascii_lowercase().ends_with(".invalid")
}

fn retry_after(response: &reqwest::Response) -> Option<Duration> {
    let value = response.headers().get(RETRY_AFTER)?.to_str().ok()?;
    parse_retry_after(value, SystemTime::now())
}

fn parse_retry_after(value: &str, now: SystemTime) -> Option<Duration> {
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }
    let date = httpdate::parse_http_date(value).ok()?;
    date.duration_since(now).ok()
}

const fn is_retryable(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::TOO_MANY_REQUESTS
            | StatusCode::BAD_GATEWAY
            | StatusCode::SERVICE_UNAVAILABLE
            | StatusCode::GATEWAY_TIMEOUT
    )
}

fn pdf_url(base: &Url, id: &NormalizedArxivId) -> Result<Url, ArxivError> {
    let host = base.host_str().ok_or(ArxivError::UnsafeUrl)?;
    if !matches!(base.scheme(), "http" | "https") || host.is_empty() {
        return Err(ArxivError::UnsafeUrl);
    }
    // Base URL is operator configuration; the suffix is a validated ID.
    Url::parse(&format!(
        "{}/{}.pdf",
        base.as_str().trim_end_matches('/'),
        id.as_query_id()
    ))
    .map_err(ArxivError::from)
}

#[derive(Debug, Clone, Copy)]
enum PayloadKind {
    Atom,
    Pdf,
}

enum RequestOutcome {
    Body(Vec<u8>),
    Status {
        status: StatusCode,
        retry_after: Option<Duration>,
    },
}

async fn read_bounded(
    mut response: reqwest::Response,
    maximum_bytes: usize,
    payload_kind: PayloadKind,
) -> Result<Vec<u8>, ArxivError> {
    if let Some(length) = response.content_length()
        && length > maximum_bytes as u64
    {
        return Err(too_large(payload_kind, maximum_bytes));
    }
    let advertised = response
        .content_length()
        .unwrap_or(0)
        .min(u64::try_from(maximum_bytes).unwrap_or(u64::MAX));
    let mut body = Vec::with_capacity(usize::try_from(advertised).unwrap_or(maximum_bytes));
    while let Some(chunk) = response.chunk().await? {
        if body.len().saturating_add(chunk.len()) > maximum_bytes {
            return Err(too_large(payload_kind, maximum_bytes));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

const fn too_large(payload_kind: PayloadKind, maximum_bytes: usize) -> ArxivError {
    match payload_kind {
        PayloadKind::Atom => ArxivError::AtomTooLarge { maximum_bytes },
        PayloadKind::Pdf => ArxivError::PdfTooLarge { maximum_bytes },
    }
}

fn backoff_delay(attempt: usize) -> Duration {
    let exponent = u32::try_from(attempt.min(8)).expect("value is bounded to eight");
    Duration::from_millis(500 * 2_u64.saturating_pow(exponent))
}

fn observe_metadata_result(
    query_kind: &'static str,
    requested_count: usize,
    started: Instant,
    result: &Result<Vec<PaperMetadata>, ArxivError>,
) {
    match result {
        Ok(records) => info!(
            metric.name = "arxiv_query_result",
            arxiv.query_kind = query_kind,
            arxiv.requested_count = requested_count,
            arxiv.result_count = records.len(),
            arxiv.duration_ms = started.elapsed().as_millis(),
            outcome = "success",
            "arXiv metadata query completed"
        ),
        Err(error) => warn!(
            metric.name = "arxiv_query_result",
            arxiv.query_kind = query_kind,
            arxiv.requested_count = requested_count,
            arxiv.result_count = 0_u64,
            arxiv.duration_ms = started.elapsed().as_millis(),
            outcome = "error",
            error.kind = arxiv_error_kind(error),
            "arXiv metadata query failed"
        ),
    }
}

fn observe_pdf_result(started: Instant, result: &Result<Vec<u8>, ArxivError>) {
    match result {
        Ok(bytes) => info!(
            metric.name = "arxiv_query_result",
            arxiv.query_kind = "pdf",
            arxiv.requested_count = 1_u64,
            arxiv.result_count = 1_u64,
            arxiv.response_bytes = bytes.len(),
            arxiv.duration_ms = started.elapsed().as_millis(),
            outcome = "success",
            "arXiv PDF request completed"
        ),
        Err(error) => warn!(
            metric.name = "arxiv_query_result",
            arxiv.query_kind = "pdf",
            arxiv.requested_count = 1_u64,
            arxiv.result_count = 0_u64,
            arxiv.duration_ms = started.elapsed().as_millis(),
            outcome = "error",
            error.kind = arxiv_error_kind(error),
            "arXiv PDF request failed"
        ),
    }
}

fn observe_http_attempt(
    payload_kind: PayloadKind,
    attempt: usize,
    started: Instant,
    result: &Result<RequestOutcome, ArxivError>,
) {
    match result {
        Ok(RequestOutcome::Body(body)) => info!(
            metric.name = "arxiv_http_request",
            arxiv.request_count = 1_u64,
            arxiv.payload_kind = payload_kind.name(),
            arxiv.attempt = attempt,
            arxiv.duration_ms = started.elapsed().as_millis(),
            arxiv.response_bytes = body.len(),
            http.status_code = 200_u16,
            outcome = "success",
            "arXiv HTTP attempt completed"
        ),
        Ok(RequestOutcome::Status {
            status,
            retry_after,
        }) => warn!(
            metric.name = "arxiv_http_request",
            arxiv.request_count = 1_u64,
            arxiv.payload_kind = payload_kind.name(),
            arxiv.attempt = attempt,
            arxiv.duration_ms = started.elapsed().as_millis(),
            http.status_code = status.as_u16(),
            http.retry_after_ms = ?retry_after.map(|delay| delay.as_millis()),
            outcome = "http_error",
            "arXiv HTTP attempt returned an error status"
        ),
        Err(error) => warn!(
            metric.name = "arxiv_http_request",
            arxiv.request_count = 1_u64,
            arxiv.payload_kind = payload_kind.name(),
            arxiv.attempt = attempt,
            arxiv.duration_ms = started.elapsed().as_millis(),
            outcome = "transport_error",
            error.kind = arxiv_error_kind(error),
            "arXiv HTTP attempt failed"
        ),
    }
}

impl PayloadKind {
    const fn name(self) -> &'static str {
        match self {
            Self::Atom => "atom",
            Self::Pdf => "pdf",
        }
    }
}

const fn arxiv_error_kind(error: &ArxivError) -> &'static str {
    match error {
        ArxivError::InvalidIdentifier(_) => "invalid_identifier",
        ArxivError::InvalidCategory(_) => "invalid_category",
        ArxivError::InvalidConfiguration(_) => "invalid_configuration",
        ArxivError::Url(_) => "url",
        ArxivError::Transport(_) => "transport",
        ArxivError::HttpStatus { .. } => "http_status",
        ArxivError::Xml(_) => "xml",
        ArxivError::MissingField(_) => "missing_field",
        ArxivError::InvalidTimestamp(_) => "invalid_timestamp",
        ArxivError::UnsafeUrl => "unsafe_url",
        ArxivError::PdfTooLarge { .. } => "pdf_too_large",
        ArxivError::AtomTooLarge { .. } => "atom_too_large",
        ArxivError::TemporaryFile(_) => "temporary_file",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_client_requires_real_contact_and_conservative_interval() {
        let error = ArxivClient::new(ArxivClientConfig::default()).unwrap_err();
        assert!(matches!(error, ArxivError::InvalidConfiguration(_)));

        let config = ArxivClientConfig {
            contact_email: "maintainer@pakperk.dev".into(),
            minimum_interval: Duration::from_millis(2_999),
            ..ArxivClientConfig::default()
        };
        let error = ArxivClient::new(config).unwrap_err();
        assert!(matches!(error, ArxivError::InvalidConfiguration(_)));
    }

    #[test]
    fn external_gate_constructor_disables_hidden_retries_and_local_delay() {
        let config = ArxivClientConfig {
            contact_email: "maintainer@pakperk.dev".into(),
            max_retries: 5,
            ..ArxivClientConfig::default()
        };
        let client = ArxivClient::new_with_external_gate(config).unwrap();
        assert_eq!(client.config.max_retries, 0);
        assert!(client.externally_gated);
    }

    #[test]
    fn parses_retry_after_delta_and_http_date() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        assert_eq!(parse_retry_after("12", now), Some(Duration::from_secs(12)));
        let date = httpdate::fmt_http_date(now + Duration::from_secs(42));
        assert_eq!(parse_retry_after(&date, now), Some(Duration::from_secs(42)));
    }

    #[test]
    fn exact_negative_process_cache_expires() {
        let now = Instant::now();
        let fresh = ExactCacheEntry {
            metadata: None,
            expires_at: Some(now + Duration::from_secs(1)),
        };
        let expired = ExactCacheEntry {
            metadata: None,
            expires_at: Some(now.checked_sub(Duration::from_secs(1)).unwrap()),
        };
        assert!(fresh.is_fresh(now));
        assert!(!expired.is_fresh(now));
    }

    #[tokio::test]
    async fn temporary_pdf_is_private_and_deleted_on_drop() {
        let downloaded = write_pdf_to_temp(DownloadedPdf {
            bytes: b"%PDF-fixture".to_vec(),
            sha256_hex: "fixture-hash".into(),
        })
        .await
        .unwrap();
        assert_eq!(downloaded.byte_length, 12);
        assert_eq!(
            tokio::fs::read(&downloaded.path).await.unwrap(),
            b"%PDF-fixture"
        );
        let path = downloaded.path.to_path_buf();
        drop(downloaded);
        assert!(!path.exists());
    }
}
