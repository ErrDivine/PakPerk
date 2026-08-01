use std::{
    collections::HashSet,
    path::Path,
    str::FromStr,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, bail};
use arxiv_client::{
    ArxivClient, ArxivClientConfig, ArxivError, MAX_EXACT_IDS_PER_REQUEST, NormalizedArxivId,
    normalize_arxiv_id,
};
use db::{Database, PaperRepository};
use domain::PaperMetadata;
use observability::{OperationClass, OperationOutcome, record_operation};
use serde::Deserialize;
use tracing::{info, warn};
use url::Url;

const MAX_MANIFEST_BYTES: usize = 1024 * 1024;
const MAX_MANIFEST_PAPERS: usize = 2_000;
const MAX_DATABASE_POOL_SIZE: u32 = 10;
const NEGATIVE_EXACT_CACHE_TTL: Duration = Duration::from_secs(15 * 60);
const FORBIDDEN_ENVIRONMENT: [&str; 3] = ["LLM_API_KEY", "LLM_API_KEY_FILE", "GROBID_URL"];

/// Configuration for the metadata-only command. This intentionally has no
/// GROBID, full-text, model, embedding, queue, or migration settings. Keeping
/// this type separate makes it impossible for the `CronJob` startup path to
/// initialize those higher-privilege worker capabilities.
#[derive(Clone)]
pub(crate) struct MetadataSyncConfig {
    database_url: String,
    database_pool_size: u32,
    arxiv: ArxivClientConfig,
    cache_ttl: Duration,
}

impl std::fmt::Debug for MetadataSyncConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MetadataSyncConfig")
            .field("database_url", &"[redacted]")
            .field("database_pool_size", &self.database_pool_size)
            .field("arxiv", &self.arxiv)
            .field("cache_ttl", &self.cache_ttl)
            .finish()
    }
}

impl MetadataSyncConfig {
    pub(crate) fn from_env() -> Result<Self> {
        reject_privileged_environment(|name| std::env::var_os(name).is_some())?;
        let database_url = required("DATABASE_URL")?;
        validate_database_url(&database_url)?;
        let database_pool_size = env_parse("DATABASE_POOL_SIZE", 2_u32)?;
        if !(1..=MAX_DATABASE_POOL_SIZE).contains(&database_pool_size) {
            bail!("DATABASE_POOL_SIZE must be between 1 and {MAX_DATABASE_POOL_SIZE}");
        }

        let mut arxiv = ArxivClientConfig::default();
        arxiv.user_agent = required("ARXIV_USER_AGENT")?;
        arxiv.contact_email = required("ARXIV_CONTACT_EMAIL")?;
        arxiv.minimum_interval =
            Duration::from_millis(env_parse("ARXIV_MIN_INTERVAL_MS", 3_000_u64)?);
        arxiv.request_timeout = Duration::from_secs(env_parse_alias(
            &["ARXIV_TIMEOUT_SECONDS", "ARXIV_REQUEST_TIMEOUT_SECONDS"],
            30_u64,
        )?);
        arxiv.max_atom_bytes = env_parse("ARXIV_MAX_ATOM_BYTES", arxiv.max_atom_bytes)?;
        // Every HTTP start is reserved in PostgreSQL. Hidden client retries
        // would escape that cross-replica gate.
        arxiv.max_retries = 0;
        // Construct once during validation so configuration errors fail before
        // a database connection or any network request is attempted.
        ArxivClient::new_with_external_gate(arxiv.clone())
            .context("arXiv client configuration is invalid")?;

        let cache_ttl =
            Duration::from_secs(env_parse("ARXIV_CACHE_TTL_SECONDS", 24 * 60 * 60_u64)?);
        if !(Duration::from_secs(60)..=Duration::from_secs(7 * 24 * 60 * 60)).contains(&cache_ttl) {
            bail!("ARXIV_CACHE_TTL_SECONDS must be between 60 and 604800");
        }

        Ok(Self {
            database_url,
            database_pool_size,
            arxiv,
            cache_ttl,
        })
    }
}

pub(crate) async fn run(config: MetadataSyncConfig, manifest_path: &Path) -> Result<()> {
    let started = Instant::now();
    let result = run_inner(config, manifest_path).await;
    record_operation(
        OperationClass::DatabaseMaintenance,
        if result.is_ok() {
            OperationOutcome::Success
        } else {
            OperationOutcome::RetryableFailure
        },
        started.elapsed(),
    );
    result
}

async fn run_inner(config: MetadataSyncConfig, manifest_path: &Path) -> Result<()> {
    let identifiers = read_manifest(manifest_path).await?;
    let manifest_paper_count = identifiers.len();
    let database = Database::connect(&config.database_url, config.database_pool_size)
        .await
        .context("could not connect with the metadata-sync database role")?;
    database
        .ready()
        .await
        .context("metadata-sync database is not ready")?;
    let papers = database.papers();
    let arxiv = ArxivClient::new_with_external_gate(config.arxiv.clone())
        .context("could not initialize the metadata-only arXiv client")?;
    let mut unavailable = Vec::new();
    let mut missing = Vec::new();

    for identifier in identifiers {
        let cache_key = exact_cache_key(&identifier);
        match papers.get_cached_arxiv(&cache_key).await? {
            Some(cached) if cached.is_empty() => unavailable.push(identifier.as_query_id()),
            Some(cached) => {
                if let Some(metadata) = cached
                    .iter()
                    .find(|metadata| exact_metadata_matches(&identifier, metadata))
                {
                    papers.upsert_metadata(metadata).await?;
                } else {
                    // A mismatched cache entry is treated as corrupt/stale and
                    // refreshed from the authoritative exact-ID endpoint.
                    missing.push(identifier);
                }
            }
            None => missing.push(identifier),
        }
    }

    for batch in missing.chunks(MAX_EXACT_IDS_PER_REQUEST) {
        papers
            .reserve_arxiv_request(config.arxiv.minimum_interval)
            .await
            .context("could not reserve the shared arXiv request gate")?;
        let query_ids = batch
            .iter()
            .map(NormalizedArxivId::as_query_id)
            .collect::<Vec<_>>();
        let fetched = observe_arxiv_result(&papers, arxiv.fetch_by_ids(&query_ids).await).await?;
        for identifier in batch {
            let cache_key = exact_cache_key(identifier);
            if let Some(metadata) = fetched
                .iter()
                .find(|metadata| exact_metadata_matches(identifier, metadata))
            {
                papers.upsert_metadata(metadata).await?;
                papers
                    .put_cached_arxiv(
                        &cache_key,
                        "exact_id",
                        std::slice::from_ref(metadata),
                        config.cache_ttl,
                    )
                    .await?;
            } else {
                unavailable.push(identifier.as_query_id());
                papers
                    .put_cached_arxiv(
                        &cache_key,
                        "exact_id",
                        &[],
                        config.cache_ttl.min(NEGATIVE_EXACT_CACHE_TTL),
                    )
                    .await?;
            }
        }
        info!(
            requested = batch.len(),
            returned = fetched.len(),
            "metadata-only exact arXiv batch synchronized"
        );
    }

    if !unavailable.is_empty() {
        unavailable.sort_unstable();
        unavailable.dedup();
        bail!(
            "arXiv returned no exact metadata for: {}",
            unavailable.join(", ")
        );
    }
    info!(
        paper_count = manifest_paper_count,
        "metadata manifest synchronization completed"
    );
    Ok(())
}

async fn observe_arxiv_result<T>(
    papers: &PaperRepository,
    result: Result<T, ArxivError>,
) -> Result<T> {
    match result {
        Ok(value) => Ok(value),
        Err(error) => {
            if let Some(cooldown) = error.shared_cooldown()
                && let Err(database_error) = papers.defer_arxiv_requests(cooldown).await
            {
                warn!(
                    error.kind = "database",
                    error.type = %std::any::type_name_of_val(&database_error),
                    "could not publish shared arXiv cooldown"
                );
            }
            Err(error).context("metadata-only arXiv request failed")
        }
    }
}

#[derive(Debug, Deserialize)]
struct Manifest {
    papers: Vec<ManifestPaper>,
}

#[derive(Debug, Deserialize)]
struct ManifestPaper {
    arxiv_id: String,
}

async fn read_manifest(path: &Path) -> Result<Vec<NormalizedArxivId>> {
    let bytes = tokio::fs::read(path)
        .await
        .with_context(|| format!("could not read {}", path.display()))?;
    parse_manifest(&bytes)
}

fn parse_manifest(bytes: &[u8]) -> Result<Vec<NormalizedArxivId>> {
    if bytes.is_empty() || bytes.len() > MAX_MANIFEST_BYTES {
        bail!("metadata manifest must contain 1 to {MAX_MANIFEST_BYTES} bytes");
    }
    let manifest: Manifest =
        serde_json::from_slice(bytes).context("metadata manifest is invalid JSON")?;
    if manifest.papers.is_empty() || manifest.papers.len() > MAX_MANIFEST_PAPERS {
        bail!("metadata manifest must contain 1 to {MAX_MANIFEST_PAPERS} papers");
    }
    let mut seen = HashSet::with_capacity(manifest.papers.len());
    let mut identifiers = Vec::with_capacity(manifest.papers.len());
    for paper in manifest.papers {
        let normalized = normalize_arxiv_id(&paper.arxiv_id)
            .with_context(|| format!("manifest arXiv ID `{}` is invalid", paper.arxiv_id))?;
        if seen.insert(normalized.as_query_id()) {
            identifiers.push(normalized);
        }
    }
    Ok(identifiers)
}

fn exact_cache_key(identifier: &NormalizedArxivId) -> String {
    format!("exact:{}", identifier.as_query_id())
}

fn exact_metadata_matches(identifier: &NormalizedArxivId, metadata: &PaperMetadata) -> bool {
    metadata.arxiv_id.base_id == identifier.base_id
        && identifier
            .version
            .is_none_or(|version| metadata.arxiv_id.version == version)
}

fn reject_privileged_environment(mut is_present: impl FnMut(&str) -> bool) -> Result<()> {
    let present = FORBIDDEN_ENVIRONMENT
        .iter()
        .copied()
        .filter(|name| is_present(name))
        .collect::<Vec<_>>();
    if !present.is_empty() {
        bail!(
            "metadata-sync must not receive unused privileged environment variables: {}",
            present.join(", ")
        );
    }
    Ok(())
}

fn validate_database_url(value: &str) -> Result<()> {
    let parsed = Url::parse(value).context("DATABASE_URL must be a valid URL")?;
    if !matches!(parsed.scheme(), "postgres" | "postgresql") {
        bail!("DATABASE_URL must use postgres:// or postgresql://");
    }
    Ok(())
}

fn required(name: &str) -> Result<String> {
    let value = std::env::var(name).with_context(|| format!("{name} is required"))?;
    if value.is_empty() || value.trim() != value || value.chars().any(char::is_control) {
        bail!("{name} must be non-empty and contain no surrounding whitespace or controls");
    }
    Ok(value)
}

fn env_parse<T>(name: &str, default: T) -> Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    match std::env::var(name) {
        Ok(value) => value
            .parse()
            .with_context(|| format!("{name} has an invalid value")),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

fn env_parse_alias<T>(names: &[&str], default: T) -> Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    for name in names {
        if let Ok(value) = std::env::var(name) {
            return value
                .parse()
                .with_context(|| format!("{name} has an invalid value"));
        }
    }
    Ok(default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_is_bounded_validated_and_deduplicated() {
        let parsed = parse_manifest(
            br#"{
                "schema_version": 1,
                "papers": [
                    {"arxiv_id": "1706.03762", "prepared": false},
                    {"arxiv_id": "1706.03762", "highlight": true},
                    {"arxiv_id": "hep-th/9901001v2"}
                ]
            }"#,
        )
        .unwrap();
        assert_eq!(
            parsed
                .iter()
                .map(NormalizedArxivId::as_query_id)
                .collect::<Vec<_>>(),
            ["1706.03762", "hep-th/9901001v2"]
        );

        assert!(parse_manifest(br#"{"papers":[]}"#).is_err());
        assert!(parse_manifest(br#"{"papers":[{"arxiv_id":"not-an-id"}]}"#).is_err());
        assert!(parse_manifest(&vec![b' '; MAX_MANIFEST_BYTES + 1]).is_err());
    }

    #[test]
    fn privileged_worker_capabilities_are_rejected() {
        reject_privileged_environment(|_| false).unwrap();
        let error =
            reject_privileged_environment(|name| matches!(name, "LLM_API_KEY_FILE" | "GROBID_URL"))
                .unwrap_err();
        let message = error.to_string();
        assert!(message.contains("LLM_API_KEY_FILE"));
        assert!(message.contains("GROBID_URL"));
    }

    #[test]
    fn database_role_url_must_be_postgres() {
        validate_database_url("postgresql://metadata@database/pakperk").unwrap();
        assert!(validate_database_url("https://database.example.test/pakperk").is_err());
        assert!(validate_database_url("not a URL").is_err());
    }
}
