use std::{str::FromStr, time::Duration};

use anyhow::{Context as _, Result};
use arxiv_client::ArxivClientConfig;
use domain::FulltextPolicy;
use grobid_client::GrobidConfig;
use llm_provider::OpenAiCompatibleConfig;
use secrecy::SecretString;
use url::Url;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub enum WorkerModelConfig {
    Deterministic { embedding_dimension: usize },
    OpenAiCompatible(OpenAiCompatibleConfig),
}

impl WorkerModelConfig {
    #[must_use]
    pub const fn embedding_dimension(&self) -> usize {
        match self {
            Self::Deterministic {
                embedding_dimension,
            } => *embedding_dimension,
            Self::OpenAiCompatible(config) => config.embedding_dimension,
        }
    }
}

#[derive(Debug, Clone)]
pub struct WorkerConfig {
    pub database_url: String,
    pub database_pool_size: u32,
    pub run_migrations: bool,
    pub worker_id: String,
    pub lease_duration: Duration,
    pub poll_interval: Duration,
    pub arxiv: ArxivClientConfig,
    pub arxiv_cache_ttl: Duration,
    pub arxiv_categories: Vec<String>,
    pub arxiv_batch_size: usize,
    pub metadata_sync_on_start: bool,
    pub metadata_sync_interval: Duration,
    pub grobid: GrobidConfig,
    pub fulltext_policy: FulltextPolicy,
    pub parser_version: String,
    pub model: WorkerModelConfig,
    pub relationship_minimum_confidence: f32,
}

impl WorkerConfig {
    #[allow(clippy::too_many_lines)]
    pub fn from_env() -> Result<Self> {
        let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL is required")?;
        let demo_mode = env_bool("DEMO_MODE", true)?;
        let embedding_dimension = std::env::var("EMBEDDING_DIMENSION")
            .ok()
            .map(|value| value.parse())
            .transpose()
            .context("EMBEDDING_DIMENSION must be an integer")?
            .unwrap_or(384);
        let provider = std::env::var("LLM_PROVIDER").unwrap_or_else(|_| {
            if demo_mode {
                "deterministic"
            } else {
                "disabled"
            }
            .to_owned()
        });
        let model = if provider.eq_ignore_ascii_case("deterministic")
            || provider.eq_ignore_ascii_case("disabled")
        {
            // A disabled network model still needs deterministic embeddings
            // and evidence-safe relationship fallbacks for an offline demo.
            WorkerModelConfig::Deterministic {
                embedding_dimension,
            }
        } else {
            let mut config = OpenAiCompatibleConfig::default();
            if let Ok(base_url) = std::env::var("LLM_BASE_URL")
                && !base_url.trim().is_empty()
            {
                config.base_url = Url::parse(&base_url)?;
            }
            config.api_key = std::env::var("LLM_API_KEY")
                .ok()
                .filter(|key| !key.is_empty())
                .map(SecretString::from);
            config.chat_model =
                std::env::var("LLM_CHAT_MODEL").context("LLM_CHAT_MODEL is required")?;
            config.embedding_model =
                std::env::var("LLM_EMBEDDING_MODEL").context("LLM_EMBEDDING_MODEL is required")?;
            config.embedding_dimension = embedding_dimension;
            config.request_timeout = Duration::from_secs(env_parse("LLM_TIMEOUT_SECONDS", 60_u64)?);
            config.maximum_response_bytes =
                env_parse("LLM_MAX_RESPONSE_BYTES", 4 * 1024 * 1024_usize)?;
            config.maximum_retries = env_parse("LLM_MAX_RETRIES", 2_usize)?;
            WorkerModelConfig::OpenAiCompatible(config)
        };

        let mut arxiv = ArxivClientConfig::default();
        arxiv.user_agent =
            std::env::var("ARXIV_USER_AGENT").unwrap_or_else(|_| arxiv.user_agent.clone());
        arxiv.contact_email =
            std::env::var("ARXIV_CONTACT_EMAIL").unwrap_or_else(|_| arxiv.contact_email.clone());
        arxiv.minimum_interval =
            Duration::from_millis(env_parse("ARXIV_MIN_INTERVAL_MS", 3_000_u64)?);
        arxiv.request_timeout = Duration::from_secs(env_parse_alias(
            &["ARXIV_TIMEOUT_SECONDS", "ARXIV_REQUEST_TIMEOUT_SECONDS"],
            30_u64,
        )?);
        arxiv.max_pdf_bytes = env_parse("MAX_PDF_BYTES", arxiv.max_pdf_bytes)?;
        // Job retries re-enter the PostgreSQL-backed cross-process request
        // reservation. Internal HTTP retries would bypass that global gate.
        enforce_cross_process_arxiv_gate(&mut arxiv);

        let mut grobid = GrobidConfig::default();
        grobid.base_url = Url::parse(
            &std::env::var("GROBID_URL").unwrap_or_else(|_| grobid.base_url.to_string()),
        )?;
        grobid.request_timeout = Duration::from_secs(env_parse("GROBID_TIMEOUT_SECONDS", 180_u64)?);

        let fulltext_policy = std::env::var("FULLTEXT_POLICY")
            .unwrap_or_else(|_| "prototype".to_owned())
            .parse::<FulltextPolicy>()?;

        Ok(Self {
            database_url,
            database_pool_size: env_parse("DATABASE_POOL_SIZE", 5_u32)?,
            run_migrations: env_bool("RUN_MIGRATIONS", true)?,
            worker_id: std::env::var("WORKER_ID")
                .unwrap_or_else(|_| format!("worker-{}", Uuid::now_v7())),
            lease_duration: Duration::from_secs(env_parse("JOB_LEASE_SECONDS", 300_u64)?),
            poll_interval: Duration::from_millis(env_parse("JOB_POLL_INTERVAL_MS", 1_000_u64)?),
            arxiv,
            arxiv_cache_ttl: Duration::from_secs(env_parse(
                "ARXIV_CACHE_TTL_SECONDS",
                24 * 60 * 60_u64,
            )?),
            arxiv_categories: std::env::var("ARXIV_CATEGORIES")
                .unwrap_or_else(|_| "cs.AI,cs.CL,cs.LG".to_owned())
                .split(',')
                .map(str::trim)
                .filter(|category| !category.is_empty())
                .map(str::to_owned)
                .collect(),
            arxiv_batch_size: env_parse("ARXIV_BATCH_SIZE", 100_usize)?,
            metadata_sync_on_start: env_bool("METADATA_SYNC_ON_START", !demo_mode)?,
            metadata_sync_interval: Duration::from_secs(env_parse(
                "METADATA_SYNC_INTERVAL_SECONDS",
                24 * 60 * 60_u64,
            )?),
            grobid,
            fulltext_policy,
            parser_version: std::env::var("PARSER_VERSION")
                .unwrap_or_else(|_| "grobid-tei-v1".to_owned()),
            model,
            relationship_minimum_confidence: env_parse(
                "RELATIONSHIP_MINIMUM_CONFIDENCE",
                0.55_f32,
            )?,
        })
    }
}

fn env_parse<T>(name: &str, default: T) -> Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    match std::env::var(name) {
        Ok(value) => Ok(value.parse()?),
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
            return Ok(value.parse()?);
        }
    }
    Ok(default)
}

fn env_bool(name: &str, default: bool) -> Result<bool> {
    match std::env::var(name) {
        Ok(value) if value.eq_ignore_ascii_case("true") || value == "1" => Ok(true),
        Ok(value) if value.eq_ignore_ascii_case("false") || value == "0" => Ok(false),
        Ok(value) => anyhow::bail!("{name} must be true/false or 1/0, got `{value}`"),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

fn enforce_cross_process_arxiv_gate(config: &mut ArxivClientConfig) {
    config.max_retries = 0;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arxiv_internal_retries_cannot_bypass_database_gate() {
        let mut config = ArxivClientConfig {
            max_retries: 4,
            ..ArxivClientConfig::default()
        };
        enforce_cross_process_arxiv_gate(&mut config);
        assert_eq!(config.max_retries, 0);
    }
}
