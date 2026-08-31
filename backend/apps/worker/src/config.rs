use std::{
    fs,
    io::Read as _,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

use anyhow::{Context as _, Result};
use arxiv_client::ArxivClientConfig;
use domain::FulltextPolicy;
use grobid_client::GrobidConfig;
use llm_provider::OpenAiCompatibleConfig;
use secrecy::SecretString;
use url::{Host, Url};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub enum WorkerModelConfig {
    Deterministic { embedding_dimension: usize },
    OpenAiCompatible(Box<OpenAiCompatibleConfig>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerEnvironment {
    Development,
    Staging,
    Production,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerVisualAssetConfig {
    pub directory: PathBuf,
    pub maximum_source_bytes: usize,
    pub maximum_derivative_bytes: usize,
}

impl WorkerVisualAssetConfig {
    const DEFAULT_MAXIMUM_SOURCE_BYTES: usize = 32 * 1024 * 1024;
    const MAXIMUM_CONFIGURED_SOURCE_BYTES: usize = 64 * 1024 * 1024;
    const DEFAULT_MAXIMUM_DERIVATIVE_BYTES: usize = 8 * 1024 * 1024;
    const MAXIMUM_CONFIGURED_DERIVATIVE_BYTES: usize = 8 * 1024 * 1024;

    fn from_env() -> Result<Option<Self>> {
        let Some(raw_directory) = std::env::var_os("VISUAL_ASSET_DIRECTORY") else {
            return Ok(None);
        };
        if raw_directory.is_empty() {
            return Ok(None);
        }
        let config = Self {
            directory: PathBuf::from(raw_directory),
            maximum_source_bytes: env_parse(
                "VISUAL_ASSET_SOURCE_MAX_BYTES",
                Self::DEFAULT_MAXIMUM_SOURCE_BYTES,
            )?,
            maximum_derivative_bytes: env_parse(
                "VISUAL_ASSET_MAX_BYTES",
                Self::DEFAULT_MAXIMUM_DERIVATIVE_BYTES,
            )?,
        };
        config.validate()?;
        Ok(Some(config))
    }

    fn validate(&self) -> Result<()> {
        if !self.directory.is_absolute() {
            anyhow::bail!("VISUAL_ASSET_DIRECTORY must be an absolute path");
        }
        if self.maximum_source_bytes == 0
            || self.maximum_source_bytes > Self::MAXIMUM_CONFIGURED_SOURCE_BYTES
        {
            anyhow::bail!("VISUAL_ASSET_SOURCE_MAX_BYTES must be between 1 and 67108864");
        }
        if self.maximum_derivative_bytes == 0
            || self.maximum_derivative_bytes > Self::MAXIMUM_CONFIGURED_DERIVATIVE_BYTES
        {
            anyhow::bail!("VISUAL_ASSET_MAX_BYTES must be between 1 and 8388608");
        }
        Ok(())
    }
}

impl WorkerEnvironment {
    const fn is_deployed(self) -> bool {
        matches!(self, Self::Staging | Self::Production)
    }
}

impl FromStr for WorkerEnvironment {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "development" | "dev" => Ok(Self::Development),
            "staging" | "stage" => Ok(Self::Staging),
            "production" | "prod" => Ok(Self::Production),
            _ => {
                anyhow::bail!("APP_ENV must be development, staging, or production, got `{value}`")
            }
        }
    }
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
    pub environment: WorkerEnvironment,
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
    /// Optional shared private root. Its `sources/` subtree is an
    /// operator-controlled ingest boundary; only re-encoded `generated/`
    /// descendants are ever published to the API.
    pub visual_assets: Option<WorkerVisualAssetConfig>,
}

impl WorkerConfig {
    #[allow(clippy::too_many_lines)]
    pub fn from_env() -> Result<Self> {
        let environment = std::env::var("APP_ENV")
            .unwrap_or_else(|_| "development".to_owned())
            .parse::<WorkerEnvironment>()?;
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
        } else if provider.eq_ignore_ascii_case("openai_compatible") {
            let mut config = OpenAiCompatibleConfig::default();
            if let Ok(base_url) = std::env::var("LLM_BASE_URL")
                && !base_url.trim().is_empty()
            {
                config.base_url = Url::parse(&base_url)?;
            }
            config.require_https = environment.is_deployed();
            config.api_key = model_api_key(environment)?;
            config.chat_model =
                std::env::var("LLM_CHAT_MODEL").context("LLM_CHAT_MODEL is required")?;
            config.embedding_model =
                std::env::var("LLM_EMBEDDING_MODEL").context("LLM_EMBEDDING_MODEL is required")?;
            config.embedding_dimension = embedding_dimension;
            config.request_timeout = Duration::from_secs(env_parse("LLM_TIMEOUT_SECONDS", 60_u64)?);
            config.maximum_response_bytes =
                env_parse("LLM_MAX_RESPONSE_BYTES", 4 * 1024 * 1024_usize)?;
            config.maximum_retries = env_parse("LLM_MAX_RETRIES", 2_usize)?;
            WorkerModelConfig::OpenAiCompatible(Box::new(config))
        } else {
            anyhow::bail!(
                "LLM_PROVIDER must be disabled, deterministic, or openai_compatible, got `{provider}`"
            );
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

        let config = Self {
            environment,
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
            visual_assets: WorkerVisualAssetConfig::from_env()?,
        };
        config.validate(demo_mode)?;
        Ok(config)
    }

    fn validate(&self, demo_mode: bool) -> Result<()> {
        if !self.database_url.starts_with("postgres://")
            && !self.database_url.starts_with("postgresql://")
        {
            anyhow::bail!("DATABASE_URL must use postgres:// or postgresql://");
        }
        if self.database_pool_size == 0 || self.database_pool_size > 100 {
            anyhow::bail!("DATABASE_POOL_SIZE must be between 1 and 100");
        }
        if self.worker_id.trim().is_empty() || self.worker_id.len() > 128 {
            anyhow::bail!("WORKER_ID must contain 1 to 128 characters");
        }
        if !(Duration::from_secs(30)..=Duration::from_secs(60 * 60)).contains(&self.lease_duration)
        {
            anyhow::bail!("JOB_LEASE_SECONDS must be between 30 and 3600");
        }
        if !(Duration::from_millis(100)..=Duration::from_secs(60)).contains(&self.poll_interval)
            || self.poll_interval >= self.lease_duration
        {
            anyhow::bail!(
                "JOB_POLL_INTERVAL_MS must be between 100 and 60000 and shorter than the lease"
            );
        }
        if self.arxiv_categories.is_empty() || self.arxiv_batch_size == 0 {
            anyhow::bail!("ARXIV_CATEGORIES and a positive ARXIV_BATCH_SIZE are required");
        }
        if !(0.0..=1.0).contains(&self.relationship_minimum_confidence) {
            anyhow::bail!("RELATIONSHIP_MINIMUM_CONFIDENCE must be between 0 and 1");
        }
        if let Some(visual_assets) = &self.visual_assets {
            visual_assets.validate()?;
        }
        validate_service_url(self.environment, "GROBID_URL", &self.grobid.base_url)?;
        validate_deployment_policy(
            self.environment,
            demo_mode,
            self.run_migrations,
            self.fulltext_policy,
            matches!(self.model, WorkerModelConfig::Deterministic { .. }),
        )
    }
}

fn validate_deployment_policy(
    environment: WorkerEnvironment,
    demo_mode: bool,
    run_migrations: bool,
    fulltext_policy: FulltextPolicy,
    deterministic_model: bool,
) -> Result<()> {
    if environment.is_deployed() && demo_mode {
        anyhow::bail!("DEMO_MODE must be false in staging and production");
    }
    if environment.is_deployed() && run_migrations {
        anyhow::bail!("RUN_MIGRATIONS must be false in staging and production");
    }
    if environment.is_deployed() && deterministic_model {
        anyhow::bail!("the deterministic model provider is not allowed in deployed workers");
    }
    if environment == WorkerEnvironment::Production && fulltext_policy != FulltextPolicy::Strict {
        anyhow::bail!("FULLTEXT_POLICY must be strict in production");
    }
    Ok(())
}

fn validate_service_url(environment: WorkerEnvironment, variable: &str, url: &Url) -> Result<()> {
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        anyhow::bail!(
            "{variable} must be an absolute HTTP(S) URL without credentials, query, or fragment"
        );
    }
    let is_loopback = url.host().is_some_and(|host| match host {
        Host::Ipv4(address) => address.is_loopback(),
        Host::Ipv6(address) => address.is_loopback(),
        Host::Domain(host) => host.eq_ignore_ascii_case("localhost"),
    });
    if environment.is_deployed() && is_loopback {
        anyhow::bail!("{variable} must not use a loopback host outside development");
    }
    Ok(())
}

fn model_api_key(environment: WorkerEnvironment) -> Result<Option<SecretString>> {
    let inline = std::env::var("LLM_API_KEY")
        .ok()
        .filter(|value| !value.is_empty());
    let file = std::env::var("LLM_API_KEY_FILE")
        .ok()
        .filter(|value| !value.is_empty());
    if inline.is_some() && file.is_some() {
        anyhow::bail!("set only one of LLM_API_KEY or LLM_API_KEY_FILE");
    }
    if environment.is_deployed() && inline.is_some() {
        anyhow::bail!("LLM_API_KEY_FILE is required instead of LLM_API_KEY in deployed workers");
    }
    if let Some(path) = file {
        return Ok(Some(SecretString::from(read_secret_file(
            "LLM_API_KEY_FILE",
            Path::new(&path),
        )?)));
    }
    Ok(inline.map(SecretString::from))
}

fn read_secret_file(variable: &str, path: &Path) -> Result<String> {
    let path_metadata = fs::symlink_metadata(path)
        .with_context(|| format!("could not read {variable} metadata"))?;
    if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
        anyhow::bail!("{variable} must reference a regular non-symlink file");
    }
    let mut file = fs::File::open(path).with_context(|| format!("could not open {variable}"))?;
    let metadata = file
        .metadata()
        .with_context(|| format!("could not read opened {variable} metadata"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if path_metadata.dev() != metadata.dev() || path_metadata.ino() != metadata.ino() {
            anyhow::bail!("{variable} changed while it was opened");
        }
        if metadata.mode() & 0o077 != 0 {
            anyhow::bail!("{variable} must not be accessible by group or others");
        }
    }
    if !(1..=16_384).contains(&metadata.len()) {
        anyhow::bail!("{variable} must contain 1 to 16384 bytes");
    }
    let expected_length = metadata.len();
    let mut bytes = Vec::with_capacity(usize::try_from(expected_length).unwrap_or(16_384));
    (&mut file)
        .take(16_385)
        .read_to_end(&mut bytes)
        .with_context(|| format!("could not read {variable}"))?;
    let final_metadata = file
        .metadata()
        .with_context(|| format!("could not recheck {variable} metadata"))?;
    if final_metadata.len() != expected_length
        || u64::try_from(bytes.len()).ok() != Some(expected_length)
    {
        anyhow::bail!("{variable} changed while it was read");
    }
    let value = String::from_utf8(bytes)
        .with_context(|| format!("{variable} must contain UTF-8"))?
        .trim_end_matches(['\r', '\n'])
        .to_owned();
    if value.is_empty() || value.trim() != value || value.chars().any(char::is_control) {
        anyhow::bail!("{variable} must contain one non-blank line");
    }
    Ok(value)
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

    #[test]
    fn environment_names_are_strict_and_have_short_aliases() {
        assert_eq!(
            "production".parse::<WorkerEnvironment>().unwrap(),
            WorkerEnvironment::Production
        );
        assert_eq!(
            "stage".parse::<WorkerEnvironment>().unwrap(),
            WorkerEnvironment::Staging
        );
        assert!("production-ish".parse::<WorkerEnvironment>().is_err());
    }

    #[test]
    fn deployed_worker_policy_fails_closed() {
        assert!(
            validate_deployment_policy(
                WorkerEnvironment::Staging,
                true,
                false,
                FulltextPolicy::Strict,
                false,
            )
            .is_err()
        );
        assert!(
            validate_deployment_policy(
                WorkerEnvironment::Production,
                false,
                true,
                FulltextPolicy::Strict,
                false,
            )
            .is_err()
        );
        assert!(
            validate_deployment_policy(
                WorkerEnvironment::Production,
                false,
                false,
                FulltextPolicy::Prototype,
                false,
            )
            .is_err()
        );
        assert!(
            validate_deployment_policy(
                WorkerEnvironment::Production,
                false,
                false,
                FulltextPolicy::Strict,
                true,
            )
            .is_err()
        );
        validate_deployment_policy(
            WorkerEnvironment::Production,
            false,
            false,
            FulltextPolicy::Strict,
            false,
        )
        .unwrap();
    }

    #[test]
    fn deployed_service_url_rejects_loopback_and_credentials() {
        let localhost = Url::parse("http://localhost:8070").unwrap();
        assert!(
            validate_service_url(WorkerEnvironment::Production, "GROBID_URL", &localhost).is_err()
        );
        let credentialed = Url::parse("https://user:pass@grobid.example.test").unwrap();
        assert!(
            validate_service_url(WorkerEnvironment::Production, "GROBID_URL", &credentialed,)
                .is_err()
        );
        let cluster = Url::parse("http://pakperk-grobid:8070").unwrap();
        validate_service_url(WorkerEnvironment::Production, "GROBID_URL", &cluster).unwrap();
    }

    #[test]
    fn deployed_worker_model_configuration_requires_https() {
        assert!(WorkerEnvironment::Staging.is_deployed());
        assert!(WorkerEnvironment::Production.is_deployed());
        assert!(!WorkerEnvironment::Development.is_deployed());
    }

    #[cfg(unix)]
    #[test]
    fn model_secret_file_rejects_embedded_control_characters() {
        use std::{fs::OpenOptions, io::Write as _, os::unix::fs::OpenOptionsExt as _};

        let path = std::env::temp_dir().join(format!(
            "pakperk-worker-model-secret-{}",
            uuid::Uuid::now_v7()
        ));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        file.write_all(b"prefix\nembedded").unwrap();
        drop(file);
        assert!(read_secret_file("LLM_API_KEY_FILE", &path).is_err());
        fs::remove_file(path).unwrap();
    }
}
