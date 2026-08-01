//! Validated deployment configuration and production feature gates.

use std::{
    fmt, fs,
    io::Read as _,
    net::{IpAddr, SocketAddr},
    path::Path,
    str::FromStr,
    time::Duration,
};

use accounts::{AccountPolicy, AccountPolicyError, IdentityFingerprintKeyring};
use arxiv_client::ArxivClientConfig;
use auth::{OidcAlgorithm, OidcVerifierConfig};
use axum::http::{HeaderMap, HeaderValue};
use domain::{
    COMMENT_MAX_BYTES, COMMENT_MAX_SCALARS, COMMENT_MAX_URLS, CommunityGuidelinesVersion,
    FulltextPolicy, TermsVersion,
};
use llm_provider::OpenAiCompatibleConfig;
use secrecy::{ExposeSecret as _, SecretString};
use sha2::{Digest as _, Sha256};
use url::{Host, Url};

use crate::deletion_config::{AccountDeletionFeatureConfig, load_identity_fingerprint_keyring};

const LOWERCASE_HEX: &[u8; 16] = b"0123456789abcdef";

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
    /// Registers the public/read and account safety surfaces for comments.
    pub comments: bool,
    /// Emergency kill switch for only new comment publication. Existing
    /// comments and every safety/moderation control remain available.
    pub comment_creation: bool,
    /// Registers the recent-auth DELETE surface and its durable local request
    /// path. The provider credentials remain worker-only.
    pub account_deletion: bool,
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
        if self.comment_creation && !self.comments {
            anyhow::bail!("COMMENT_CREATION_ENABLED requires COMMENTS_ENABLED");
        }
        if self.account_deletion && !self.accounts {
            anyhow::bail!("ACCOUNT_DELETION_ENABLED requires ACCOUNTS_ENABLED");
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
    /// Present exactly when public comments and their safety controls are
    /// registered.
    pub comments: Option<CommentFeatureConfig>,
    /// Present exactly when the account-deletion route is enabled.
    pub account_deletion: Option<AccountDeletionFeatureConfig>,
    /// Shared trusted-proxy boundary and keyed request-origin pseudonym used
    /// by public expensive-operation and UGC rate limits.
    pub request_origin: RequestOriginConfig,
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
    pub current_community_guidelines_version: CommunityGuidelinesVersion,
    pub last_seen_interval: Duration,
    pub profile_update_limit: u32,
    pub profile_update_window: Duration,
    pub auth_retry_initial: Duration,
    pub auth_retry_maximum: Duration,
    /// Required in deployed account APIs so JIT provisioning continues to
    /// honor deletion tombstones even while DELETE is feature-disabled.
    pub identity_fingerprints: Option<IdentityFingerprintKeyring>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LibraryFeatureConfig {
    pub mutation_limit: u32,
    pub mutation_window: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CommentModerationProvider {
    Rules,
}

impl FromStr for CommentModerationProvider {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "rules" => Ok(Self::Rules),
            _ => anyhow::bail!(
                "COMMENT_MODERATION_PROVIDER must be `rules`; no other provider is wired"
            ),
        }
    }
}

/// API-edge request-origin settings. The resolved address is HMAC-pseudonymized
/// before it enters `PostgreSQL` and is never exposed through diagnostics.
#[derive(Clone)]
pub struct RequestOriginConfig {
    origin_hasher: RequestOriginHasher,
    trusted_proxy_networks: Vec<TrustedProxyNetwork>,
}

impl fmt::Debug for RequestOriginConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RequestOriginConfig")
            .field("origin_hasher", &"[redacted]")
            .field(
                "trusted_proxy_network_count",
                &self.trusted_proxy_networks.len(),
            )
            .finish()
    }
}

impl RequestOriginConfig {
    fn from_env(environment: ApiEnvironment) -> anyhow::Result<Self> {
        let path = required_request_origin_env("API_ORIGIN_HASH_SECRET_FILE")?;
        let config = Self {
            origin_hasher: RequestOriginHasher::from_file(Path::new(&path))?,
            trusted_proxy_networks: parse_trusted_proxy_networks(
                std::env::var("API_TRUSTED_PROXY_CIDRS").ok().as_deref(),
                environment,
            )?,
        };
        config.validate(environment)?;
        Ok(config)
    }

    /// Constructs a direct-peer configuration for tests and local embedders.
    /// Deployed [`ApiConfig`] validation rejects the empty trusted-proxy set.
    pub fn for_local_development(secret: &str) -> anyhow::Result<Self> {
        Ok(Self {
            origin_hasher: RequestOriginHasher::new(secret)?,
            trusted_proxy_networks: Vec::new(),
        })
    }

    /// Adds the exact reverse-proxy source ranges trusted to supply
    /// `X-Forwarded-For`. The caller still chooses the deployment environment
    /// through [`ApiConfig`], whose validation requires ranges when deployed.
    pub fn with_trusted_proxy_cidrs(mut self, value: &str) -> anyhow::Result<Self> {
        self.trusted_proxy_networks =
            parse_trusted_proxy_networks(Some(value), ApiEnvironment::Development)?;
        Ok(self)
    }

    pub(crate) fn scope(&self, headers: &HeaderMap, peer: SocketAddr) -> String {
        self.origin_hasher
            .scope_for(self.client_origin_address(headers, peer))
    }

    fn client_origin_address(&self, headers: &HeaderMap, peer: SocketAddr) -> IpAddr {
        let peer = canonical_ip(peer.ip());
        if !self.is_trusted_proxy(peer) {
            return peer;
        }
        let Some(chain) = parse_x_forwarded_for(headers) else {
            // Missing, oversized, or malformed proxy metadata must not let a
            // caller select a fresh bucket. Fall back to the directly
            // connected peer as a conservative circuit breaker.
            return peer;
        };
        let mut current = peer;
        for candidate in chain.into_iter().rev() {
            if !self.is_trusted_proxy(current) {
                break;
            }
            current = canonical_ip(candidate);
        }
        current
    }

    fn is_trusted_proxy(&self, address: IpAddr) -> bool {
        self.trusted_proxy_networks
            .iter()
            .any(|network| network.contains(address))
    }

    fn validate(&self, environment: ApiEnvironment) -> anyhow::Result<()> {
        if environment.is_deployed() && self.trusted_proxy_networks.is_empty() {
            anyhow::bail!(
                "API_TRUSTED_PROXY_CIDRS must enumerate the ingress proxy source ranges outside development"
            );
        }
        Ok(())
    }
}

/// API-edge settings that must not cross into domain/service diagnostics.
#[derive(Clone)]
pub struct CommentFeatureConfig {
    maximum_comment_scalars: usize,
    maximum_comment_bytes: usize,
    maximum_comment_urls: usize,
    moderation_provider: CommentModerationProvider,
    support_contact_url: Url,
    maximum_page_size: u32,
    create_limit: u32,
    create_window: Duration,
    mutation_limit: u32,
    mutation_window: Duration,
    report_limit: u32,
    report_window: Duration,
    origin_limit: u32,
    origin_window: Duration,
}

impl fmt::Debug for CommentFeatureConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CommentFeatureConfig")
            .field("maximum_comment_scalars", &self.maximum_comment_scalars)
            .field("maximum_comment_bytes", &self.maximum_comment_bytes)
            .field("maximum_comment_urls", &self.maximum_comment_urls)
            .field("moderation_provider", &self.moderation_provider)
            .field("support_contact_url", &self.support_contact_url.as_str())
            .field("maximum_page_size", &self.maximum_page_size)
            .field("create_limit", &self.create_limit)
            .field("create_window", &self.create_window)
            .field("mutation_limit", &self.mutation_limit)
            .field("mutation_window", &self.mutation_window)
            .field("report_limit", &self.report_limit)
            .field("report_window", &self.report_window)
            .field("origin_limit", &self.origin_limit)
            .field("origin_window", &self.origin_window)
            .finish()
    }
}

impl CommentFeatureConfig {
    fn from_env(environment: ApiEnvironment) -> anyhow::Result<Self> {
        let moderation_provider = std::env::var("COMMENT_MODERATION_PROVIDER").ok();
        let config = Self {
            maximum_comment_scalars: env_parse("COMMENT_MAX_SCALARS", COMMENT_MAX_SCALARS)?,
            maximum_comment_bytes: env_parse("COMMENT_MAX_BYTES", COMMENT_MAX_BYTES)?,
            maximum_comment_urls: env_parse("COMMENT_MAX_URLS", COMMENT_MAX_URLS)?,
            moderation_provider: parse_comment_moderation_provider(moderation_provider.as_deref())?,
            support_contact_url: parse_comment_support_contact_url(
                environment,
                &required_comments_env("COMMENT_SUPPORT_CONTACT_URL")?,
            )?,
            maximum_page_size: env_parse("COMMENT_MAXIMUM_PAGE_SIZE", 50_u32)?,
            create_limit: env_parse("COMMENT_CREATE_LIMIT", 10_u32)?,
            create_window: Duration::from_secs(env_parse(
                "COMMENT_CREATE_WINDOW_SECONDS",
                60 * 60_u64,
            )?),
            mutation_limit: env_parse("COMMENT_MUTATION_LIMIT", 60_u32)?,
            mutation_window: Duration::from_secs(env_parse(
                "COMMENT_MUTATION_WINDOW_SECONDS",
                60 * 60_u64,
            )?),
            report_limit: env_parse("COMMENT_REPORT_LIMIT", 30_u32)?,
            report_window: Duration::from_secs(env_parse(
                "COMMENT_REPORT_WINDOW_SECONDS",
                60 * 60_u64,
            )?),
            origin_limit: env_parse("COMMENT_ORIGIN_LIMIT", 120_u32)?,
            origin_window: Duration::from_secs(env_parse(
                "COMMENT_ORIGIN_WINDOW_SECONDS",
                60 * 60_u64,
            )?),
        };
        config.validate(environment)?;
        Ok(config)
    }

    /// Deterministic bounded policy for repository integration tests.
    ///
    /// Production configuration must continue to use [`ApiConfig::from_env`]
    /// so the deployed support contact and every explicit limit are validated.
    #[doc(hidden)]
    pub fn for_test() -> anyhow::Result<Self> {
        Ok(Self {
            maximum_comment_scalars: COMMENT_MAX_SCALARS,
            maximum_comment_bytes: COMMENT_MAX_BYTES,
            maximum_comment_urls: COMMENT_MAX_URLS,
            moderation_provider: CommentModerationProvider::Rules,
            support_contact_url: Url::parse("https://pakperk.app/support")?,
            maximum_page_size: 50,
            create_limit: 10,
            create_window: Duration::from_secs(60 * 60),
            mutation_limit: 60,
            mutation_window: Duration::from_secs(60 * 60),
            report_limit: 30,
            report_window: Duration::from_secs(60 * 60),
            origin_limit: 120,
            origin_window: Duration::from_secs(60 * 60),
        })
    }

    pub(crate) const fn moderation_provider(&self) -> CommentModerationProvider {
        self.moderation_provider
    }

    fn validate(&self, environment: ApiEnvironment) -> anyhow::Result<()> {
        validate_comment_content_limits(
            self.maximum_comment_scalars,
            self.maximum_comment_bytes,
            self.maximum_comment_urls,
        )?;
        validate_comment_support_contact_url(environment, &self.support_contact_url)?;
        Ok(())
    }

    pub(crate) fn service_config(
        &self,
        account: &AccountFeatureConfig,
        environment: ApiEnvironment,
    ) -> anyhow::Result<comments::CommentServiceConfig> {
        self.validate(environment)?;
        comments::CommentServiceConfig::new(
            account.current_terms_version.clone(),
            account.current_community_guidelines_version.clone(),
        )
        .with_maximum_page_size(self.maximum_page_size)?
        .with_create_rate_limit(self.create_limit, self.create_window)?
        .with_mutation_rate_limit(self.mutation_limit, self.mutation_window)?
        .with_report_rate_limit(self.report_limit, self.report_window)?
        .with_origin_rate_limit(self.origin_limit, self.origin_window)
        .map_err(Into::into)
    }
}

fn parse_comment_moderation_provider(
    value: Option<&str>,
) -> anyhow::Result<CommentModerationProvider> {
    value.unwrap_or("rules").parse()
}

fn validate_comment_content_limits(
    maximum_scalars: usize,
    maximum_bytes: usize,
    maximum_urls: usize,
) -> anyhow::Result<()> {
    if maximum_scalars != COMMENT_MAX_SCALARS {
        anyhow::bail!("COMMENT_MAX_SCALARS must equal the enforced domain limit of 2000");
    }
    if maximum_bytes != COMMENT_MAX_BYTES {
        anyhow::bail!("COMMENT_MAX_BYTES must equal the enforced domain limit of 8000");
    }
    if maximum_urls != COMMENT_MAX_URLS {
        anyhow::bail!("COMMENT_MAX_URLS must equal the enforced domain limit of 3");
    }
    Ok(())
}

fn parse_comment_support_contact_url(
    environment: ApiEnvironment,
    value: &str,
) -> anyhow::Result<Url> {
    if value.trim() != value || value.len() > 2_048 {
        anyhow::bail!("COMMENT_SUPPORT_CONTACT_URL must be a bounded absolute URL");
    }
    let url = Url::parse(value)
        .map_err(|error| anyhow::anyhow!("COMMENT_SUPPORT_CONTACT_URL is invalid: {error}"))?;
    validate_comment_support_contact_url(environment, &url)?;
    Ok(url)
}

fn validate_comment_support_contact_url(
    environment: ApiEnvironment,
    url: &Url,
) -> anyhow::Result<()> {
    let Some(host) = url.host() else {
        anyhow::bail!("COMMENT_SUPPORT_CONTACT_URL must be an absolute HTTP(S) URL");
    };
    if !url.username().is_empty() || url.password().is_some() {
        anyhow::bail!("COMMENT_SUPPORT_CONTACT_URL must not contain credentials");
    }
    let lowercase = url.as_str().to_ascii_lowercase();
    let placeholder_host = match &host {
        Host::Domain(host) => {
            matches!(
                *host,
                "example.com" | "example.org" | "example.net" | "invalid"
            ) || host.ends_with(".example.com")
                || host.ends_with(".example.org")
                || host.ends_with(".example.net")
                || host.ends_with(".invalid")
        }
        Host::Ipv4(_) | Host::Ipv6(_) => false,
    };
    if placeholder_host
        || ["change-me", "changeme", "placeholder", "todo"]
            .iter()
            .any(|marker| lowercase.contains(marker))
    {
        anyhow::bail!("COMMENT_SUPPORT_CONTACT_URL must not be a placeholder");
    }

    let is_loopback = match &host {
        Host::Ipv4(address) => address.is_loopback(),
        Host::Ipv6(address) => address.is_loopback(),
        Host::Domain(host) => host.eq_ignore_ascii_case("localhost"),
    };
    match url.scheme() {
        "https" if environment.is_deployed() && is_loopback => {
            anyhow::bail!(
                "COMMENT_SUPPORT_CONTACT_URL must not use a loopback host outside development"
            )
        }
        "https" => Ok(()),
        "http" if environment == ApiEnvironment::Development && is_loopback => Ok(()),
        "http" if environment == ApiEnvironment::Development => {
            anyhow::bail!("development HTTP COMMENT_SUPPORT_CONTACT_URL must use a loopback host")
        }
        "http" => {
            anyhow::bail!("COMMENT_SUPPORT_CONTACT_URL must use HTTPS outside development")
        }
        _ => anyhow::bail!("COMMENT_SUPPORT_CONTACT_URL must be an absolute HTTP(S) URL"),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TrustedProxyNetwork {
    network: IpAddr,
    prefix_length: u8,
}

impl FromStr for TrustedProxyNetwork {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (address, prefix_length) = value.split_once('/').ok_or_else(|| {
            anyhow::anyhow!("trusted proxy range `{value}` must use CIDR notation")
        })?;
        let network: IpAddr = address
            .parse()
            .map_err(|_| anyhow::anyhow!("trusted proxy range `{value}` has an invalid address"))?;
        if matches!(network, IpAddr::V6(address) if address.to_ipv4_mapped().is_some()) {
            anyhow::bail!(
                "trusted proxy range `{value}` must use IPv4 notation for IPv4-mapped addresses"
            );
        }
        let prefix_length: u8 = prefix_length.parse().map_err(|_| {
            anyhow::anyhow!("trusted proxy range `{value}` has an invalid prefix length")
        })?;
        let maximum = match network {
            IpAddr::V4(_) => 32,
            IpAddr::V6(_) => 128,
        };
        if prefix_length == 0 || prefix_length > maximum {
            anyhow::bail!(
                "trusted proxy range `{value}` must be narrower than an internet-wide range"
            );
        }
        let canonical = mask_ip(network, prefix_length);
        if canonical != network {
            anyhow::bail!("trusted proxy range `{value}` must use its canonical network address");
        }
        Ok(Self {
            network,
            prefix_length,
        })
    }
}

impl TrustedProxyNetwork {
    fn contains(self, address: IpAddr) -> bool {
        let address = canonical_ip(address);
        match (self.network, address) {
            (IpAddr::V4(_), IpAddr::V4(_)) | (IpAddr::V6(_), IpAddr::V6(_)) => {
                mask_ip(address, self.prefix_length) == self.network
            }
            _ => false,
        }
    }
}

fn mask_ip(address: IpAddr, prefix_length: u8) -> IpAddr {
    match address {
        IpAddr::V4(address) => {
            let shift = 32_u32 - u32::from(prefix_length);
            let mask = u32::MAX.checked_shl(shift).unwrap_or(0);
            IpAddr::V4((u32::from(address) & mask).into())
        }
        IpAddr::V6(address) => {
            let shift = 128_u32 - u32::from(prefix_length);
            let mask = u128::MAX.checked_shl(shift).unwrap_or(0);
            IpAddr::V6((u128::from(address) & mask).into())
        }
    }
}

fn canonical_ip(address: IpAddr) -> IpAddr {
    match address {
        IpAddr::V6(address) => address
            .to_ipv4_mapped()
            .map_or(IpAddr::V6(address), IpAddr::V4),
        address @ IpAddr::V4(_) => address,
    }
}

fn parse_trusted_proxy_networks(
    value: Option<&str>,
    environment: ApiEnvironment,
) -> anyhow::Result<Vec<TrustedProxyNetwork>> {
    let Some(value) = value.filter(|value| !value.trim().is_empty()) else {
        if environment.is_deployed() {
            anyhow::bail!("API_TRUSTED_PROXY_CIDRS is required outside development");
        }
        return Ok(Vec::new());
    };
    if value.len() > 4_096 || value.trim() != value {
        anyhow::bail!("API_TRUSTED_PROXY_CIDRS must be a bounded comma-separated CIDR list");
    }
    let values: Vec<_> = value.split(',').map(str::trim).collect();
    if values.len() > 64 || values.iter().any(|value| value.is_empty()) {
        anyhow::bail!("API_TRUSTED_PROXY_CIDRS must contain 1 to 64 CIDR ranges");
    }
    let networks: Vec<TrustedProxyNetwork> = values
        .into_iter()
        .map(str::parse)
        .collect::<anyhow::Result<_>>()?;
    if networks.iter().enumerate().any(|(index, network)| {
        networks
            .iter()
            .skip(index + 1)
            .any(|other| other == network)
    }) {
        anyhow::bail!("API_TRUSTED_PROXY_CIDRS must not contain duplicate ranges");
    }
    Ok(networks)
}

fn parse_x_forwarded_for(headers: &HeaderMap) -> Option<Vec<IpAddr>> {
    const MAXIMUM_BYTES: usize = 2_048;
    const MAXIMUM_ADDRESSES: usize = 32;

    let mut total_bytes = 0_usize;
    let mut addresses = Vec::new();
    let mut saw_header = false;
    for value in headers.get_all("x-forwarded-for") {
        saw_header = true;
        let value = value.to_str().ok()?;
        total_bytes = total_bytes.checked_add(value.len())?;
        if total_bytes > MAXIMUM_BYTES {
            return None;
        }
        for address in value.split(',').map(str::trim) {
            if address.is_empty() || addresses.len() == MAXIMUM_ADDRESSES {
                return None;
            }
            addresses.push(address.parse().ok()?);
        }
    }
    saw_header
        .then_some(addresses)
        .filter(|chain| !chain.is_empty())
}

#[derive(Clone)]
struct RequestOriginHasher {
    secret: SecretString,
}

impl RequestOriginHasher {
    fn from_file(path: &Path) -> anyhow::Result<Self> {
        let path_metadata = fs::symlink_metadata(path).map_err(|error| {
            anyhow::anyhow!("could not read API_ORIGIN_HASH_SECRET_FILE metadata: {error}")
        })?;
        if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
            anyhow::bail!("API_ORIGIN_HASH_SECRET_FILE must be a regular non-symlink file");
        }
        let mut file = fs::File::open(path).map_err(|error| {
            anyhow::anyhow!("could not open API_ORIGIN_HASH_SECRET_FILE: {error}")
        })?;
        let metadata = file.metadata().map_err(|error| {
            anyhow::anyhow!("could not read opened API_ORIGIN_HASH_SECRET_FILE metadata: {error}")
        })?;
        if !metadata.is_file() {
            anyhow::bail!("API_ORIGIN_HASH_SECRET_FILE must be a regular file");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            if path_metadata.dev() != metadata.dev() || path_metadata.ino() != metadata.ino() {
                anyhow::bail!("API_ORIGIN_HASH_SECRET_FILE changed while it was opened");
            }
        }
        let expected_length = metadata.len();
        if !(32..=4_096).contains(&expected_length) {
            anyhow::bail!("API_ORIGIN_HASH_SECRET_FILE must contain 32 to 4096 bytes");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            if metadata.mode() & 0o077 != 0 {
                anyhow::bail!(
                    "API_ORIGIN_HASH_SECRET_FILE must not be accessible by group or others"
                );
            }
        }
        let mut bytes = Vec::with_capacity(usize::try_from(expected_length).unwrap_or(4_096));
        (&mut file)
            .take(4_097)
            .read_to_end(&mut bytes)
            .map_err(|error| {
                anyhow::anyhow!("could not read API_ORIGIN_HASH_SECRET_FILE: {error}")
            })?;
        let final_metadata = file.metadata().map_err(|error| {
            anyhow::anyhow!("could not recheck API_ORIGIN_HASH_SECRET_FILE metadata: {error}")
        })?;
        if final_metadata.len() != expected_length
            || u64::try_from(bytes.len()).ok() != Some(expected_length)
        {
            anyhow::bail!("API_ORIGIN_HASH_SECRET_FILE changed while it was read");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            if final_metadata.mode() & 0o077 != 0 {
                anyhow::bail!(
                    "API_ORIGIN_HASH_SECRET_FILE must not be accessible by group or others"
                );
            }
        }
        let value = String::from_utf8(bytes)
            .map_err(|_| anyhow::anyhow!("API_ORIGIN_HASH_SECRET_FILE must contain UTF-8"))?;
        Self::new(value.trim_end_matches(['\r', '\n']))
    }

    fn new(value: &str) -> anyhow::Result<Self> {
        let lowercase = value.to_ascii_lowercase();
        let weak_marker = ["change-me", "changeme", "example", "placeholder"]
            .iter()
            .any(|marker| lowercase.contains(marker));
        let repeated = value
            .as_bytes()
            .first()
            .is_some_and(|first| value.as_bytes().iter().all(|byte| byte == first));
        if !(32..=4_096).contains(&value.len()) || value.trim() != value || weak_marker || repeated
        {
            anyhow::bail!(
                "API_ORIGIN_HASH_SECRET_FILE must contain a non-placeholder 32 to 4096 byte secret"
            );
        }
        Ok(Self {
            secret: SecretString::from(value.to_owned()),
        })
    }

    fn scope_for(&self, address: IpAddr) -> String {
        let (family, octets): (u8, Vec<u8>) = match address {
            IpAddr::V4(address) => (4, address.octets().to_vec()),
            IpAddr::V6(address) => address.to_ipv4_mapped().map_or_else(
                || (6, address.octets().to_vec()),
                |address| (4, address.octets().to_vec()),
            ),
        };
        let mut message = b"pakperk:request-origin:v1\0".to_vec();
        message.push(family);
        message.extend_from_slice(&octets);
        let digest = hmac_sha256(self.secret.expose_secret().as_bytes(), &message);
        let mut scope = String::with_capacity(64);
        for byte in digest {
            scope.push(char::from(LOWERCASE_HEX[usize::from(byte >> 4)]));
            scope.push(char::from(LOWERCASE_HEX[usize::from(byte & 0x0f)]));
        }
        scope
    }
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    const BLOCK_SIZE: usize = 64;
    let mut normalized = [0_u8; BLOCK_SIZE];
    if key.len() > BLOCK_SIZE {
        normalized[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        normalized[..key.len()].copy_from_slice(key);
    }
    let mut inner_pad = [0x36_u8; BLOCK_SIZE];
    let mut outer_pad = [0x5c_u8; BLOCK_SIZE];
    for ((inner, outer), key) in inner_pad
        .iter_mut()
        .zip(outer_pad.iter_mut())
        .zip(normalized)
    {
        *inner ^= key;
        *outer ^= key;
    }
    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(message);
    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner.finalize());
    outer.finalize().into()
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
    fn from_env(
        environment: ApiEnvironment,
        require_identity_fingerprints: bool,
    ) -> anyhow::Result<Self> {
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
            current_community_guidelines_version: CommunityGuidelinesVersion::parse(
                &required_env("CURRENT_COMMUNITY_GUIDELINES_VERSION")?,
            )?,
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
            identity_fingerprints: if require_identity_fingerprints
                || std::env::var_os("ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE").is_some()
            {
                Some(load_identity_fingerprint_keyring()?)
            } else {
                None
            },
        };
        config.validate()?;
        Ok(config)
    }

    pub fn account_policy(&self) -> Result<AccountPolicy, AccountPolicyError> {
        AccountPolicy::new(
            self.current_terms_version.clone(),
            self.current_community_guidelines_version.clone(),
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

fn validate_database_pool_capacity(
    features: FeatureFlags,
    database_pool_size: u32,
) -> anyhow::Result<()> {
    if database_pool_size == 0 {
        anyhow::bail!("DATABASE_POOL_SIZE must be greater than zero");
    }
    if features.comments && database_pool_size < 2 {
        anyhow::bail!("DATABASE_POOL_SIZE must be at least two when comments are enabled");
    }
    Ok(())
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
            comment_creation: env_bool("COMMENT_CREATION_ENABLED", false)?,
            account_deletion: env_bool("ACCOUNT_DELETION_ENABLED", false)?,
        }
        .validate()?;
        let request_origin = RequestOriginConfig::from_env(environment)?;
        let accounts = features
            .accounts
            .then(|| AccountFeatureConfig::from_env(environment, true))
            .transpose()?;
        let library = features
            .library
            .then(LibraryFeatureConfig::from_env)
            .transpose()?;
        let comments = features
            .comments
            .then(|| CommentFeatureConfig::from_env(environment))
            .transpose()?;
        let account_deletion = features
            .account_deletion
            .then(|| {
                let keyring = accounts
                    .as_ref()
                    .and_then(|account| account.identity_fingerprints.clone())
                    .ok_or_else(|| {
                        anyhow::anyhow!(
                            "identity fingerprint keys are required for account deletion"
                        )
                    })?;
                AccountDeletionFeatureConfig::from_env(environment, keyring)
            })
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
        let (embedding_dimension, llm) =
            provider_config_from_env(environment, configured_embedding_dimension)?;
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
            comments,
            account_deletion,
            request_origin,
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
        self.request_origin.validate(self.environment)?;
        self.validate_feature_configs()?;
        validate_database_pool_capacity(self.features, self.database_pool_size)?;
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

    fn validate_feature_configs(&self) -> anyhow::Result<()> {
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
        match (self.features.comments, self.comments.as_ref()) {
            (true, Some(comments)) => {
                let account = self.accounts.as_ref().ok_or_else(|| {
                    anyhow::anyhow!("account configuration is required when comments are enabled")
                })?;
                comments.service_config(account, self.environment)?;
            }
            (false, None) => {}
            (true, None) => {
                anyhow::bail!("comment configuration is required when comments are enabled")
            }
            (false, Some(_)) => {
                anyhow::bail!("comment configuration requires comments to be enabled")
            }
        }
        match (
            self.features.account_deletion,
            self.account_deletion.as_ref(),
        ) {
            (true, Some(deletion)) => deletion.validate(self.environment)?,
            (false, None) => {}
            (true, None) => {
                anyhow::bail!("account-deletion configuration is required when deletion is enabled")
            }
            (false, Some(_)) => {
                anyhow::bail!("account-deletion configuration requires deletion to be enabled")
            }
        }
        if self.features.accounts
            && self
                .accounts
                .as_ref()
                .and_then(|account| account.identity_fingerprints.as_ref())
                .is_none()
        {
            anyhow::bail!("account APIs require ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE");
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

fn required_comments_env(name: &str) -> anyhow::Result<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("{name} is required when comments are enabled"))
}

fn required_request_origin_env(name: &str) -> anyhow::Result<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("{name} is required for shared public rate limits"))
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
    OpenAiCompatible(Box<OpenAiCompatibleConfig>),
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
    environment: ApiEnvironment,
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
    config.require_https = environment.is_deployed();
    config.api_key = model_api_key(environment)?;
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
        Some(ApiModelConfig::OpenAiCompatible(Box::new(config))),
    ))
}

fn model_api_key(environment: ApiEnvironment) -> anyhow::Result<Option<SecretString>> {
    let inline = std::env::var("LLM_API_KEY")
        .ok()
        .filter(|value| !value.is_empty());
    let file = std::env::var("LLM_API_KEY_FILE")
        .ok()
        .filter(|value| !value.is_empty());
    validate_model_api_key_sources(environment, inline.is_some(), file.is_some())?;
    if let Some(path) = file {
        return Ok(Some(SecretString::from(read_model_api_key_file(
            Path::new(&path),
        )?)));
    }
    Ok(inline.map(SecretString::from))
}

fn validate_model_api_key_sources(
    environment: ApiEnvironment,
    has_inline: bool,
    has_file: bool,
) -> anyhow::Result<()> {
    if has_inline && has_file {
        anyhow::bail!("set only one of LLM_API_KEY or LLM_API_KEY_FILE");
    }
    if environment.is_deployed() && has_inline {
        anyhow::bail!("LLM_API_KEY_FILE is required instead of LLM_API_KEY in deployed APIs");
    }
    Ok(())
}

fn read_model_api_key_file(path: &Path) -> anyhow::Result<String> {
    let path_metadata = fs::symlink_metadata(path)
        .map_err(|error| anyhow::anyhow!("could not read LLM_API_KEY_FILE metadata: {error}"))?;
    if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
        anyhow::bail!("LLM_API_KEY_FILE must reference a regular non-symlink file");
    }
    let mut file = fs::File::open(path)
        .map_err(|error| anyhow::anyhow!("could not open LLM_API_KEY_FILE: {error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| anyhow::anyhow!("could not read opened LLM_API_KEY_FILE: {error}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if path_metadata.dev() != metadata.dev() || path_metadata.ino() != metadata.ino() {
            anyhow::bail!("LLM_API_KEY_FILE changed while it was opened");
        }
        if metadata.mode() & 0o077 != 0 {
            anyhow::bail!("LLM_API_KEY_FILE must not be accessible by group or others");
        }
    }
    if !(1..=16_384).contains(&metadata.len()) {
        anyhow::bail!("LLM_API_KEY_FILE must contain 1 to 16384 bytes");
    }
    let expected_length = metadata.len();
    let mut bytes = Vec::with_capacity(usize::try_from(expected_length).unwrap_or(16_384));
    (&mut file)
        .take(16_385)
        .read_to_end(&mut bytes)
        .map_err(|error| anyhow::anyhow!("could not read LLM_API_KEY_FILE: {error}"))?;
    let final_metadata = file
        .metadata()
        .map_err(|error| anyhow::anyhow!("could not recheck LLM_API_KEY_FILE: {error}"))?;
    if final_metadata.len() != expected_length
        || u64::try_from(bytes.len()).ok() != Some(expected_length)
    {
        anyhow::bail!("LLM_API_KEY_FILE changed while it was read");
    }
    let value = String::from_utf8(bytes)
        .map_err(|_| anyhow::anyhow!("LLM_API_KEY_FILE must contain UTF-8"))?
        .trim_end_matches(['\r', '\n'])
        .to_owned();
    if value.is_empty() || value.trim() != value || value.chars().any(char::is_control) {
        anyhow::bail!("LLM_API_KEY_FILE must contain one non-blank line");
    }
    Ok(value)
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
                comments: false,
                comment_creation: false,
                account_deletion: false,
            }
            .validate()
            .is_err()
        );
        assert!(
            FeatureFlags {
                accounts: false,
                library: false,
                library_writes: false,
                comments: true,
                comment_creation: false,
                account_deletion: false,
            }
            .validate()
            .is_err()
        );
        assert!(
            FeatureFlags {
                accounts: true,
                library: true,
                library_writes: true,
                comments: true,
                comment_creation: true,
                account_deletion: true,
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
                comment_creation: false,
                account_deletion: false,
            }
            .validate()
            .is_err()
        );
        assert!(
            FeatureFlags {
                accounts: true,
                library: false,
                library_writes: false,
                comments: false,
                comment_creation: true,
                account_deletion: false,
            }
            .validate()
            .is_err()
        );
    }

    #[test]
    fn request_origin_scope_is_keyed_canonical_and_never_contains_the_address() {
        let first = RequestOriginConfig::for_local_development(
            "a-strong-random-development-secret-0123456789",
        )
        .unwrap();
        let second = RequestOriginConfig::for_local_development(
            "another-strong-random-development-secret-987654321",
        )
        .unwrap();
        let replica = RequestOriginConfig::for_local_development(
            "a-strong-random-development-secret-0123456789",
        )
        .unwrap();
        let address = "203.0.113.7:12345".parse().unwrap();
        let same_ip_other_port = "203.0.113.7:54321".parse().unwrap();
        let mapped = "[::ffff:203.0.113.7]:12345".parse().unwrap();
        let headers = HeaderMap::new();
        let scope = first.scope(&headers, address);
        assert_eq!(scope.len(), 64);
        assert!(
            scope
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
        assert!(!scope.contains("203.0.113.7"));
        assert_eq!(scope, first.scope(&headers, same_ip_other_port));
        assert_eq!(scope, first.scope(&headers, mapped));
        assert_eq!(scope, replica.scope(&headers, address));
        assert_ne!(scope, second.scope(&headers, address));
        let debug = format!("{first:?}");
        assert!(!debug.contains("development-secret"));
        assert!(debug.contains("origin_hasher: \"[redacted]\""));

        assert!(
            RequestOriginConfig::for_local_development("change-me-change-me-change-me-change-me")
                .is_err()
        );
        assert!(RequestOriginConfig::for_local_development(&"x".repeat(64)).is_err());
    }

    #[test]
    fn trusted_proxy_chain_uses_the_rightmost_untrusted_address() {
        let mut config = RequestOriginConfig::for_local_development(
            "a-strong-random-development-secret-0123456789",
        )
        .unwrap();
        config.trusted_proxy_networks = parse_trusted_proxy_networks(
            Some("10.244.0.0/16,10.0.0.0/24,2001:db8:abcd::/48"),
            ApiEnvironment::Development,
        )
        .unwrap();

        let peer = "10.244.7.8:43123".parse().unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-for",
            "203.0.113.99, 198.51.100.24, 10.0.0.9".parse().unwrap(),
        );
        assert_eq!(
            config.client_origin_address(&headers, peer),
            "198.51.100.24".parse::<IpAddr>().unwrap()
        );

        let untrusted_peer = "192.0.2.10:43123".parse().unwrap();
        assert_eq!(
            config.client_origin_address(&headers, untrusted_peer),
            "192.0.2.10".parse::<IpAddr>().unwrap()
        );
    }

    #[test]
    fn malformed_forwarding_metadata_falls_back_to_the_direct_peer() {
        let mut config = RequestOriginConfig::for_local_development(
            "a-strong-random-development-secret-0123456789",
        )
        .unwrap();
        config.trusted_proxy_networks =
            parse_trusted_proxy_networks(Some("10.244.0.0/16"), ApiEnvironment::Development)
                .unwrap();
        let peer = "10.244.7.8:43123".parse().unwrap();
        for value in ["not-an-address", "198.51.100.2,", "198.51.100.2:1234"] {
            let mut headers = HeaderMap::new();
            headers.insert("x-forwarded-for", value.parse().unwrap());
            assert_eq!(
                config.client_origin_address(&headers, peer),
                "10.244.7.8".parse::<IpAddr>().unwrap()
            );
        }
    }

    #[test]
    fn trusted_proxy_cidrs_are_bounded_canonical_and_not_internet_wide() {
        assert!(
            parse_trusted_proxy_networks(None, ApiEnvironment::Development)
                .unwrap()
                .is_empty()
        );
        assert!(parse_trusted_proxy_networks(None, ApiEnvironment::Staging).is_err());
        for invalid in [
            "0.0.0.0/0",
            "::/0",
            "10.244.1.1/16",
            "10.244.0.0/33",
            "::ffff:10.244.0.0/120",
            "10.244.0.0/16,10.244.0.0/16",
            "10.244.0.0/16,",
        ] {
            assert!(
                parse_trusted_proxy_networks(Some(invalid), ApiEnvironment::Development).is_err(),
                "accepted invalid trusted proxy list: {invalid}"
            );
        }
    }

    #[test]
    fn comment_content_limit_configuration_must_match_the_domain_policy() {
        assert!(
            validate_comment_content_limits(
                COMMENT_MAX_SCALARS,
                COMMENT_MAX_BYTES,
                COMMENT_MAX_URLS
            )
            .is_ok()
        );
        assert!(
            validate_comment_content_limits(
                COMMENT_MAX_SCALARS - 1,
                COMMENT_MAX_BYTES,
                COMMENT_MAX_URLS
            )
            .is_err()
        );
        assert!(
            validate_comment_content_limits(
                COMMENT_MAX_SCALARS,
                COMMENT_MAX_BYTES + 1,
                COMMENT_MAX_URLS
            )
            .is_err()
        );
        assert!(
            validate_comment_content_limits(
                COMMENT_MAX_SCALARS,
                COMMENT_MAX_BYTES,
                COMMENT_MAX_URLS + 1
            )
            .is_err()
        );
    }

    #[test]
    fn comment_moderation_provider_rejects_unwired_values() {
        assert_eq!(
            parse_comment_moderation_provider(None).unwrap(),
            CommentModerationProvider::Rules
        );
        assert_eq!(
            parse_comment_moderation_provider(Some("rules")).unwrap(),
            CommentModerationProvider::Rules
        );
        for unsupported in ["", "Rules", "model", "external", "off"] {
            assert!(
                parse_comment_moderation_provider(Some(unsupported)).is_err(),
                "accepted unwired moderation provider {unsupported}"
            );
        }
    }

    #[test]
    fn comment_support_url_is_absolute_non_placeholder_and_environment_safe() {
        for environment in [
            ApiEnvironment::Development,
            ApiEnvironment::Staging,
            ApiEnvironment::Production,
        ] {
            assert!(
                parse_comment_support_contact_url(environment, "https://pakperk.app/support")
                    .is_ok()
            );
        }
        for local in [
            "http://localhost:8080/support",
            "http://127.0.0.1:8080/support",
            "http://[::1]:8080/support",
        ] {
            assert!(parse_comment_support_contact_url(ApiEnvironment::Development, local).is_ok());
            assert!(parse_comment_support_contact_url(ApiEnvironment::Staging, local).is_err());
        }
        for invalid in [
            "/support",
            "mailto:support@pakperk.app",
            "http://pakperk.app/support",
            "https://example.com/support",
            "https://pakperk.app/placeholder",
            "https://user:secret@pakperk.app/support",
            " https://pakperk.app/support",
        ] {
            assert!(
                parse_comment_support_contact_url(ApiEnvironment::Production, invalid).is_err(),
                "accepted unsafe support URL {invalid}"
            );
        }
        assert!(
            parse_comment_support_contact_url(
                ApiEnvironment::Development,
                "http://dev.pakperk.app/support"
            )
            .is_err()
        );
        assert!(
            parse_comment_support_contact_url(
                ApiEnvironment::Production,
                "https://127.0.0.1/support"
            )
            .is_err()
        );
    }

    #[test]
    fn keyed_hash_uses_standard_hmac_sha256() {
        let actual = hmac_sha256(&[0x0b; 20], b"Hi There");
        assert_eq!(
            actual,
            [
                0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53, 0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b,
                0xf1, 0x2b, 0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7, 0x26, 0xe9, 0x37, 0x6c,
                0x2e, 0x32, 0xcf, 0xf7,
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn request_origin_secret_file_is_bounded_owner_only_and_not_a_symlink() {
        use std::{
            fs::OpenOptions,
            io::Write as _,
            os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _},
        };

        let path = std::env::temp_dir().join(format!(
            "pakperk-request-origin-secret-{}",
            uuid::Uuid::now_v7()
        ));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        file.write_all(b"owner-only-random-secret-material-0123456789")
            .unwrap();
        drop(file);
        assert!(RequestOriginHasher::from_file(&path).is_ok());

        let link = path.with_extension("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(RequestOriginHasher::from_file(&link).is_err());
        fs::remove_file(link).unwrap();

        fs::set_permissions(&path, fs::Permissions::from_mode(0o400)).unwrap();
        assert!(RequestOriginHasher::from_file(&path).is_ok());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(RequestOriginHasher::from_file(&path).is_err());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn deployed_model_credentials_require_the_file_boundary() {
        assert!(validate_model_api_key_sources(ApiEnvironment::Development, true, false).is_ok());
        assert!(validate_model_api_key_sources(ApiEnvironment::Production, false, true).is_ok());
        assert!(validate_model_api_key_sources(ApiEnvironment::Staging, true, false).is_err());
        assert!(validate_model_api_key_sources(ApiEnvironment::Production, true, true).is_err());
    }

    #[test]
    fn deployed_api_model_configuration_requires_https() {
        assert!(ApiEnvironment::Staging.is_deployed());
        assert!(ApiEnvironment::Production.is_deployed());
        assert!(!ApiEnvironment::Development.is_deployed());
    }

    #[cfg(unix)]
    #[test]
    fn model_api_key_file_is_owner_only_bounded_and_not_a_symlink() {
        use std::{
            fs::OpenOptions,
            io::Write as _,
            os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _},
        };

        let path =
            std::env::temp_dir().join(format!("pakperk-model-api-key-{}", uuid::Uuid::now_v7()));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        file.write_all(b"owner-only-model-credential\n").unwrap();
        drop(file);
        assert_eq!(
            read_model_api_key_file(&path).unwrap(),
            "owner-only-model-credential"
        );

        let link = path.with_extension("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(read_model_api_key_file(&link).is_err());
        fs::remove_file(link).unwrap();

        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_model_api_key_file(&path).is_err());
        fs::remove_file(path).unwrap();
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

    #[test]
    fn comments_reserve_capacity_for_the_coordination_and_write_paths() {
        let features = FeatureFlags {
            accounts: true,
            library: false,
            library_writes: false,
            comments: true,
            comment_creation: false,
            account_deletion: false,
        };

        assert_eq!(
            validate_database_pool_capacity(features, 1)
                .unwrap_err()
                .to_string(),
            "DATABASE_POOL_SIZE must be at least two when comments are enabled",
        );
        assert!(validate_database_pool_capacity(features, 2).is_ok());
    }

    fn production_config() -> ApiConfig {
        ApiConfig {
            environment: ApiEnvironment::Production,
            features: FeatureFlags::default(),
            accounts: None,
            library: None,
            comments: None,
            account_deletion: None,
            request_origin: RequestOriginConfig::for_local_development(
                "production-config-request-origin-secret-0123456789",
            )
            .unwrap()
            .with_trusted_proxy_cidrs("10.244.0.0/16")
            .unwrap(),
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
