//! Validated deployment configuration and production feature gates.

use std::{net::SocketAddr, str::FromStr, time::Duration};

use accounts::{AccountPolicy, AccountPolicyError};
use arxiv_client::ArxivClientConfig;
use auth::{OidcAlgorithm, OidcVerifierConfig};
use axum::http::HeaderValue;
use domain::{FulltextPolicy, TermsVersion};
use llm_provider::OpenAiCompatibleConfig;
use secrecy::SecretString;
use url::{Host, Url};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiEnvironment {
    Development,
    Staging,
    Production,
}

impl FromStr for ApiEnvironment {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "development" | "dev" => Ok(Self::Development),
            "staging" | "stage" => Ok(Self::Staging),
            "production" | "prod" => Ok(Self::Production),
            _ => Err(anyhow::anyhow!(
                "APP_ENV must be development, staging, or production, got `{value}`"
            )),
        }
    }
}

impl ApiEnvironment {
    pub const fn exposes_openapi(self) -> bool {
        matches!(self, Self::Development | Self::Staging)
    }

    pub const fn is_deployed(self) -> bool {
        matches!(self, Self::Staging | Self::Production)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[allow(clippy::struct_excessive_bools)]
pub struct FeatureFlags {
    pub accounts: bool,
    pub library: bool,
    /// Allows operators to freeze account-owned mutations while preserving
    /// synchronized library reads.
    pub library_writes: bool,
    pub comments: bool,
}

impl FeatureFlags {
    pub(crate) fn validate(self) -> anyhow::Result<Self> {
        if self.library && !self.accounts {
            anyhow::bail!("LIBRARY_ENABLED requires ACCOUNTS_ENABLED");
        }
        if self.library_writes && !self.library {
            anyhow::bail!("LIBRARY_WRITES_ENABLED requires LIBRARY_ENABLED");
        }
        if self.comments && !self.accounts {
            anyhow::bail!("COMMENTS_ENABLED requires ACCOUNTS_ENABLED");
        }
        Ok(self)
    }
}

#[derive(Debug, Clone)]
pub struct ApiConfig {
    pub environment: ApiEnvironment,
    pub features: FeatureFlags,
    /// Present exactly when the account feature is enabled. Keeping this
    /// optional means guest-only deployments do not need placeholder identity
    /// settings and cannot accidentally initialize an OIDC client.
    pub accounts: Option<AccountFeatureConfig>,
    /// Present exactly when synchronized library routes are enabled.
    pub library: Option<LibraryFeatureConfig>,
    pub bind: SocketAddr,
    pub database_url: String,
    pub database_pool_size: u32,
    pub run_migrations: bool,
    pub request_timeout: Duration,
    pub chat_request_timeout: Duration,
    pub max_request_bytes: usize,
    pub cors_allowed_origins: Vec<HeaderValue>,
    pub arxiv: ArxivClientConfig,
    pub arxiv_cache_ttl: Duration,
    pub fulltext_policy: FulltextPolicy,
    pub embedding_dimension: Option<usize>,
    pub llm: Option<ApiModelConfig>,
    pub prepare_requests_per_minute: u32,
    pub chat_requests_per_minute: u32,
}

#[derive(Debug, Clone)]
pub struct AccountFeatureConfig {
    pub oidc: OidcVerifierConfig,
    pub current_terms_version: TermsVersion,
    pub last_seen_interval: Duration,
    pub profile_update_limit: u32,
    pub profile_update_window: Duration,
    pub auth_retry_initial: Duration,
    pub auth_retry_maximum: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LibraryFeatureConfig {
    pub mutation_limit: u32,
    pub mutation_window: Duration,
}

impl LibraryFeatureConfig {
    fn from_env() -> anyhow::Result<Self> {
        let config = Self {
            mutation_limit: env_parse("LIBRARY_MUTATION_LIMIT", 120_u32)?,
            mutation_window: Duration::from_secs(env_parse(
                "LIBRARY_MUTATION_WINDOW_SECONDS",
                60 * 60_u64,
            )?),
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(self) -> anyhow::Result<Self> {
        if self.mutation_limit == 0 {
            anyhow::bail!("LIBRARY_MUTATION_LIMIT must be greater than zero");
        }
        if self.mutation_window < Duration::from_secs(1)
            || self.mutation_window > Duration::from_secs(30 * 24 * 60 * 60)
        {
            anyhow::bail!(
                "LIBRARY_MUTATION_WINDOW_SECONDS must be between one second and thirty days"
            );
        }
        Ok(self)
    }
}

impl AccountFeatureConfig {
    fn from_env(environment: ApiEnvironment) -> anyhow::Result<Self> {
        let issuer_raw = required_env("OIDC_ISSUER_URL")?;
        let issuer = Url::parse(&issuer_raw)
            .map_err(|_| anyhow::anyhow!("OIDC_ISSUER_URL must be a valid URL"))?;
        let audience = required_env("OIDC_AUDIENCE")?;
        if audience.trim() != audience {
            anyhow::bail!("OIDC_AUDIENCE must not contain surrounding whitespace");
        }
        let mut oidc = OidcVerifierConfig::new(
            issuer,
            audience,
            OidcAlgorithm::parse_csv(
                &std::env::var("OIDC_ALLOWED_ALGORITHMS").unwrap_or_else(|_| "RS256".to_owned()),
            )?,
        );
        oidc.discovery_timeout = Duration::from_secs(env_parse(
            "OIDC_DISCOVERY_TIMEOUT_SECONDS",
            oidc.discovery_timeout.as_secs(),
        )?);
        oidc.jwks_cache_ttl = Duration::from_secs(env_parse(
            "OIDC_JWKS_CACHE_TTL_SECONDS",
            oidc.jwks_cache_ttl.as_secs(),
        )?);
        oidc.jwks_refresh_cooldown = Duration::from_secs(env_parse(
            "OIDC_JWKS_MIN_REFRESH_SECONDS",
            oidc.jwks_refresh_cooldown.as_secs(),
        )?);
        oidc.clock_skew = Duration::from_secs(env_parse(
            "OIDC_CLOCK_SKEW_SECONDS",
            oidc.clock_skew.as_secs(),
        )?);
        oidc.allow_insecure_http = validate_oidc_issuer_environment(environment, &oidc.issuer)?;

        let config = Self {
            oidc,
            current_terms_version: TermsVersion::parse(&required_env("CURRENT_TERMS_VERSION")?)?,
            last_seen_interval: Duration::from_secs(env_parse(
                "ACCOUNT_LAST_SEEN_INTERVAL_SECONDS",
                15 * 60_u64,
            )?),
            profile_update_limit: env_parse("PROFILE_UPDATE_LIMIT", 5_u32)?,
            profile_update_window: Duration::from_secs(env_parse(
                "PROFILE_UPDATE_WINDOW_SECONDS",
                60 * 60_u64,
            )?),
            auth_retry_initial: Duration::from_secs(env_parse(
                "OIDC_RETRY_INITIAL_SECONDS",
                5_u64,
            )?),
            auth_retry_maximum: Duration::from_secs(env_parse(
                "OIDC_RETRY_MAX_SECONDS",
                5 * 60_u64,
            )?),
        };
        config.validate()?;
        Ok(config)
    }

    pub fn account_policy(&self) -> Result<AccountPolicy, AccountPolicyError> {
        AccountPolicy::new(
            self.current_terms_version.clone(),
            self.last_seen_interval,
            self.profile_update_limit,
            self.profile_update_window,
        )
    }

    fn validate(&self) -> anyhow::Result<()> {
        self.oidc.validate()?;
        self.account_policy()?;
        if self.auth_retry_initial.is_zero()
            || self.auth_retry_maximum.is_zero()
            || self.auth_retry_initial >= self.auth_retry_maximum
            || self.auth_retry_maximum > Duration::from_secs(60 * 60)
        {
            anyhow::bail!("OIDC retry delays must be positive, ordered, and at most one hour");
        }
        Ok(())
    }
}

impl ApiConfig {
    #[allow(clippy::too_many_lines)]
    pub fn from_env() -> anyhow::Result<Self> {
        let environment = std::env::var("APP_ENV")
            .unwrap_or_else(|_| "development".to_owned())
            .parse()?;
        let features = FeatureFlags {
            accounts: env_bool("ACCOUNTS_ENABLED", false)?,
            library: env_bool("LIBRARY_ENABLED", false)?,
            library_writes: env_bool("LIBRARY_WRITES_ENABLED", false)?,
            comments: env_bool("COMMENTS_ENABLED", false)?,
        }
        .validate()?;
        let accounts = features
            .accounts
            .then(|| AccountFeatureConfig::from_env(environment))
            .transpose()?;
        let library = features
            .library
            .then(LibraryFeatureConfig::from_env)
            .transpose()?;
        let bind = std::env::var("API_BIND")
            .unwrap_or_else(|_| "0.0.0.0:8080".to_owned())
            .parse()?;
        let database_url = std::env::var("DATABASE_URL")
            .map_err(|_| anyhow::anyhow!("DATABASE_URL is required"))?;
        let request_timeout = Duration::from_secs(env_parse_alias(
            &["API_REQUEST_TIMEOUT_SECONDS", "REQUEST_TIMEOUT_SECONDS"],
            30_u64,
        )?);
        let max_request_bytes = env_parse("API_MAX_REQUEST_BYTES", 64 * 1024_usize)?;
        let cors_allowed_origins = env_first(&["CORS_ALLOWED_ORIGINS", "CORS_ALLOWED_ORIGIN"])
            .map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|origin| !origin.is_empty())
                    .map(HeaderValue::from_str)
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?
            .unwrap_or_default();

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
        enforce_cross_process_arxiv_gate(&mut arxiv);

        let configured_embedding_dimension = std::env::var("EMBEDDING_DIMENSION")
            .ok()
            .map(|value| value.parse())
            .transpose()?;
        let (embedding_dimension, llm) = provider_config_from_env(configured_embedding_dimension)?;
        let default_chat_timeout = llm
            .as_ref()
            .map_or(Duration::from_secs(65), ApiModelConfig::request_timeout)
            .saturating_add(Duration::from_secs(5));
        let chat_request_timeout = Duration::from_secs(env_parse(
            "CHAT_REQUEST_TIMEOUT_SECONDS",
            default_chat_timeout.as_secs(),
        )?);

        let config = Self {
            environment,
            features,
            accounts,
            library,
            bind,
            database_url,
            database_pool_size: env_parse("DATABASE_POOL_SIZE", 10_u32)?,
            run_migrations: env_bool("RUN_MIGRATIONS", true)?,
            request_timeout,
            chat_request_timeout,
            max_request_bytes,
            cors_allowed_origins,
            arxiv,
            arxiv_cache_ttl: Duration::from_secs(env_parse(
                "ARXIV_CACHE_TTL_SECONDS",
                24 * 60 * 60_u64,
            )?),
            fulltext_policy: std::env::var("FULLTEXT_POLICY")
                .unwrap_or_else(|_| "prototype".to_owned())
                .parse()?,
            embedding_dimension,
            llm,
            prepare_requests_per_minute: env_parse_alias(
                &[
                    "PREPARE_RATE_LIMIT_PER_MINUTE",
                    "PREPARE_REQUESTS_PER_MINUTE",
                ],
                30_u32,
            )?,
            chat_requests_per_minute: env_parse_alias(
                &["CHAT_RATE_LIMIT_PER_MINUTE", "CHAT_REQUESTS_PER_MINUTE"],
                10_u32,
            )?,
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> anyhow::Result<()> {
        self.features.validate()?;
        match (self.features.accounts, self.accounts.as_ref()) {
            (true, Some(accounts)) => {
                accounts.validate()?;
                let allow_insecure =
                    validate_oidc_issuer_environment(self.environment, &accounts.oidc.issuer)?;
                if accounts.oidc.allow_insecure_http != allow_insecure {
                    anyhow::bail!("OIDC issuer transport override is inconsistent with APP_ENV");
                }
            }
            (false, None) => {}
            (true, None) => {
                anyhow::bail!("account configuration is required when accounts are enabled")
            }
            (false, Some(_)) => {
                anyhow::bail!("account configuration requires accounts to be enabled")
            }
        }
        match (self.features.library, self.library) {
            (true, Some(library)) => {
                library.validate()?;
            }
            (false, None) => {}
            (true, None) => {
                anyhow::bail!("library configuration is required when library is enabled")
            }
            (false, Some(_)) => {
                anyhow::bail!("library configuration requires library to be enabled")
            }
        }
        if self.database_pool_size == 0 {
            anyhow::bail!("DATABASE_POOL_SIZE must be greater than zero");
        }
        if self.max_request_bytes == 0 {
            anyhow::bail!("API_MAX_REQUEST_BYTES must be greater than zero");
        }
        if self.request_timeout.is_zero() || self.chat_request_timeout.is_zero() {
            anyhow::bail!("API request timeouts must be greater than zero");
        }
        if self.prepare_requests_per_minute == 0 || self.chat_requests_per_minute == 0 {
            anyhow::bail!("API rate limits must be greater than zero");
        }
        if self.environment.is_deployed() {
            if self.cors_allowed_origins.is_empty() {
                anyhow::bail!("CORS_ALLOWED_ORIGINS is required in staging and production");
            }
            for origin in &self.cors_allowed_origins {
                validate_cors_origin(self.environment, origin)?;
            }
            if !self.database_url.starts_with("postgres://")
                && !self.database_url.starts_with("postgresql://")
            {
                anyhow::bail!("DATABASE_URL must use postgres:// or postgresql://");
            }
        }
        if self.environment == ApiEnvironment::Production {
            if self.run_migrations {
                anyhow::bail!("RUN_MIGRATIONS must be false in production");
            }
            if self.fulltext_policy != FulltextPolicy::Strict {
                anyhow::bail!("FULLTEXT_POLICY must be strict in production");
            }
            if matches!(self.llm, Some(ApiModelConfig::Deterministic { .. })) {
                anyhow::bail!("the deterministic model provider is not allowed in production");
            }
        }
        Ok(())
    }
}

fn required_env(name: &str) -> anyhow::Result<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("{name} is required when accounts are enabled"))
}

fn validate_oidc_issuer_environment(
    environment: ApiEnvironment,
    issuer: &Url,
) -> anyhow::Result<bool> {
    let is_loopback = issuer.host().is_some_and(|host| match host {
        Host::Ipv4(address) => address.is_loopback(),
        Host::Ipv6(address) => address.is_loopback(),
        Host::Domain(host) => host.eq_ignore_ascii_case("localhost"),
    });
    if environment.is_deployed() && is_loopback {
        anyhow::bail!("OIDC_ISSUER_URL must not use a loopback host outside development");
    }
    if issuer.scheme() == "http" {
        if environment != ApiEnvironment::Development {
            anyhow::bail!("OIDC_ISSUER_URL must use HTTPS outside development");
        }
        if !is_loopback {
            anyhow::bail!("development HTTP OIDC issuers must use a loopback host");
        }
        return Ok(true);
    }
    Ok(false)
}

fn validate_cors_origin(_environment: ApiEnvironment, value: &HeaderValue) -> anyhow::Result<()> {
    let raw = value
        .to_str()
        .map_err(|_| anyhow::anyhow!("CORS_ALLOWED_ORIGINS must contain ASCII origins"))?;
    if raw.contains('*') {
        anyhow::bail!("CORS_ALLOWED_ORIGINS must not contain wildcard origins");
    }
    let origin =
        Url::parse(raw).map_err(|error| anyhow::anyhow!("invalid CORS origin `{raw}`: {error}"))?;
    if origin.scheme() != "https" {
        anyhow::bail!("CORS origin `{raw}` must use HTTPS in staging and production");
    }
    if origin.host_str().is_none()
        || !origin.username().is_empty()
        || origin.password().is_some()
        || origin.path() != "/"
        || origin.query().is_some()
        || origin.fragment().is_some()
    {
        anyhow::bail!(
            "CORS origin `{raw}` must be an explicit origin without credentials, path, query, or fragment"
        );
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub enum ApiModelConfig {
    Deterministic { embedding_dimension: usize },
    OpenAiCompatible(OpenAiCompatibleConfig),
}

impl ApiModelConfig {
    fn request_timeout(&self) -> Duration {
        match self {
            Self::Deterministic { .. } => Duration::from_secs(60),
            Self::OpenAiCompatible(config) => config.request_timeout,
        }
    }
}

fn provider_config_from_env(
    embedding_dimension: Option<usize>,
) -> anyhow::Result<(Option<usize>, Option<ApiModelConfig>)> {
    let demo_mode = env_bool("DEMO_MODE", true)?;
    let provider = std::env::var("LLM_PROVIDER").unwrap_or_else(|_| {
        if demo_mode {
            "deterministic"
        } else {
            "disabled"
        }
        .to_owned()
    });
    if provider.eq_ignore_ascii_case("disabled") {
        return Ok((embedding_dimension, None));
    }
    if provider.eq_ignore_ascii_case("deterministic") {
        let dimension = embedding_dimension.unwrap_or(384);
        return Ok((
            Some(dimension),
            Some(ApiModelConfig::Deterministic {
                embedding_dimension: dimension,
            }),
        ));
    }
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
    config.chat_model = std::env::var("LLM_CHAT_MODEL")
        .map_err(|_| anyhow::anyhow!("LLM_CHAT_MODEL is required when LLM_PROVIDER is enabled"))?;
    config.embedding_model = std::env::var("LLM_EMBEDDING_MODEL").map_err(|_| {
        anyhow::anyhow!("LLM_EMBEDDING_MODEL is required when LLM_PROVIDER is enabled")
    })?;
    config.embedding_dimension = embedding_dimension.ok_or_else(|| {
        anyhow::anyhow!("EMBEDDING_DIMENSION is required when LLM_PROVIDER is enabled")
    })?;
    config.request_timeout = Duration::from_secs(env_parse("LLM_TIMEOUT_SECONDS", 60_u64)?);
    config.maximum_response_bytes = env_parse("LLM_MAX_RESPONSE_BYTES", 4 * 1024 * 1024_usize)?;
    config.maximum_retries = env_parse("LLM_MAX_RETRIES", 2_usize)?;
    Ok((
        embedding_dimension,
        Some(ApiModelConfig::OpenAiCompatible(config)),
    ))
}

fn env_parse<T>(name: &str, default: T) -> anyhow::Result<T>
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

fn env_parse_alias<T>(names: &[&str], default: T) -> anyhow::Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    match env_first(names) {
        Some(value) => Ok(value.parse()?),
        None => Ok(default),
    }
}

fn env_first(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| std::env::var(name).ok())
}

fn env_bool(name: &str, default: bool) -> anyhow::Result<bool> {
    match std::env::var(name) {
        Ok(value) if value.eq_ignore_ascii_case("true") || value == "1" => Ok(true),
        Ok(value) if value.eq_ignore_ascii_case("false") || value == "0" => Ok(false),
        Ok(value) => Err(anyhow::anyhow!(
            "{name} must be true/false or 1/0, got `{value}`"
        )),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

pub(crate) fn enforce_cross_process_arxiv_gate(config: &mut ArxivClientConfig) {
    config.max_retries = 0;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deployment_environment_is_typed_and_rejects_typos() {
        assert_eq!(
            "dev".parse::<ApiEnvironment>().unwrap(),
            ApiEnvironment::Development
        );
        assert_eq!(
            "staging".parse::<ApiEnvironment>().unwrap(),
            ApiEnvironment::Staging
        );
        assert_eq!(
            "prod".parse::<ApiEnvironment>().unwrap(),
            ApiEnvironment::Production
        );
        assert!("production-ish".parse::<ApiEnvironment>().is_err());
    }

    #[test]
    fn dependent_features_require_accounts() {
        assert!(
            FeatureFlags {
                accounts: false,
                library: true,
                library_writes: false,
                comments: false
            }
            .validate()
            .is_err()
        );
        assert!(
            FeatureFlags {
                accounts: false,
                library: false,
                library_writes: false,
                comments: true
            }
            .validate()
            .is_err()
        );
        assert!(
            FeatureFlags {
                accounts: true,
                library: true,
                library_writes: true,
                comments: true
            }
            .validate()
            .is_ok()
        );
        assert!(
            FeatureFlags {
                accounts: true,
                library: false,
                library_writes: true,
                comments: false,
            }
            .validate()
            .is_err()
        );
    }

    #[test]
    fn library_policy_bounds_and_write_dependency_are_typed() {
        assert!(
            LibraryFeatureConfig {
                mutation_limit: 120,
                mutation_window: Duration::from_secs(60 * 60),
            }
            .validate()
            .is_ok()
        );
        assert!(
            LibraryFeatureConfig {
                mutation_limit: 0,
                mutation_window: Duration::from_secs(60),
            }
            .validate()
            .is_err()
        );
        assert!(
            LibraryFeatureConfig {
                mutation_limit: 1,
                mutation_window: Duration::from_secs(0),
            }
            .validate()
            .is_err()
        );
        assert!(
            LibraryFeatureConfig {
                mutation_limit: 1,
                mutation_window: Duration::from_secs(30 * 24 * 60 * 60 + 1),
            }
            .validate()
            .is_err()
        );
    }

    #[test]
    fn production_does_not_expose_runtime_openapi() {
        assert!(ApiEnvironment::Development.exposes_openapi());
        assert!(ApiEnvironment::Staging.exposes_openapi());
        assert!(!ApiEnvironment::Production.exposes_openapi());
    }

    #[test]
    fn deployed_cors_origins_are_explicit_and_production_uses_https() {
        let header = |value: &str| HeaderValue::from_str(value).unwrap();
        assert!(
            validate_cors_origin(
                ApiEnvironment::Staging,
                &header("https://staging.pakperk.org")
            )
            .is_ok()
        );
        assert!(
            validate_cors_origin(
                ApiEnvironment::Production,
                &header("https://app.pakperk.org")
            )
            .is_ok()
        );
        for value in [
            "*",
            "https://user:pass@app.pakperk.org",
            "https://app.pakperk.org/path",
            "https://app.pakperk.org?debug=true",
            "https://app.pakperk.org#fragment",
        ] {
            assert!(
                validate_cors_origin(ApiEnvironment::Production, &header(value)).is_err(),
                "accepted unsafe origin {value}"
            );
        }
        assert!(
            validate_cors_origin(
                ApiEnvironment::Production,
                &header("http://app.pakperk.org")
            )
            .is_err()
        );
        assert!(
            validate_cors_origin(
                ApiEnvironment::Staging,
                &header("http://staging.pakperk.org")
            )
            .is_err()
        );
    }

    #[test]
    fn oidc_issuer_transport_allows_local_http_only_in_development() {
        let local = Url::parse("http://localhost:8081/realms/pakperk").unwrap();
        assert!(validate_oidc_issuer_environment(ApiEnvironment::Development, &local).unwrap());
        let non_loopback = Url::parse("http://keycloak:8080/realms/pakperk").unwrap();
        assert!(
            validate_oidc_issuer_environment(ApiEnvironment::Development, &non_loopback).is_err()
        );
        let ipv6_loopback = Url::parse("http://[::1]:8081/realms/pakperk").unwrap();
        assert!(
            validate_oidc_issuer_environment(ApiEnvironment::Development, &ipv6_loopback).unwrap()
        );

        for environment in [ApiEnvironment::Staging, ApiEnvironment::Production] {
            let secure_loopback = Url::parse("https://127.0.0.1:8443/realms/pakperk").unwrap();
            assert!(validate_oidc_issuer_environment(environment, &local).is_err());
            assert!(validate_oidc_issuer_environment(environment, &secure_loopback).is_err());
            let deployed = Url::parse("https://identity.pakperk.org/realms/pakperk").unwrap();
            assert!(!validate_oidc_issuer_environment(environment, &deployed).unwrap());
        }
    }

    #[test]
    fn production_validation_enforces_safe_runtime_invariants() {
        let mut config = production_config();
        assert!(config.validate().is_ok());

        config.run_migrations = true;
        assert!(config.validate().is_err());
        config.run_migrations = false;

        config.fulltext_policy = FulltextPolicy::Prototype;
        assert!(config.validate().is_err());
        config.fulltext_policy = FulltextPolicy::Strict;

        config.llm = Some(ApiModelConfig::Deterministic {
            embedding_dimension: 8,
        });
        assert!(config.validate().is_err());
    }

    fn production_config() -> ApiConfig {
        ApiConfig {
            environment: ApiEnvironment::Production,
            features: FeatureFlags::default(),
            accounts: None,
            library: None,
            bind: "0.0.0.0:8080".parse().unwrap(),
            database_url: "postgresql://api@database/pakperk".to_owned(),
            database_pool_size: 10,
            run_migrations: false,
            request_timeout: Duration::from_secs(30),
            chat_request_timeout: Duration::from_secs(70),
            max_request_bytes: 64 * 1024,
            cors_allowed_origins: vec![HeaderValue::from_static("https://app.pakperk.org")],
            arxiv: ArxivClientConfig::default(),
            arxiv_cache_ttl: Duration::from_secs(86_400),
            fulltext_policy: FulltextPolicy::Strict,
            embedding_dimension: None,
            llm: None,
            prepare_requests_per_minute: 30,
            chat_requests_per_minute: 10,
        }
    }
}
