use std::{fmt, str::FromStr, time::Duration};

use jsonwebtoken::Algorithm;
use url::{Host, Url};

use crate::ConfigError;

const MAX_NETWORK_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_JWKS_CACHE_TTL: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_CLOCK_SKEW: Duration = Duration::from_secs(5 * 60);
const MAX_TOKEN_BYTES: usize = 64 * 1024;
const MAX_METADATA_BYTES: usize = 1024 * 1024;
const MAX_JWKS_BYTES: usize = 4 * 1024 * 1024;
const MAX_JWKS_KEYS: usize = 1024;

/// Asymmetric signature algorithms supported at the Pakperk OIDC boundary.
///
/// HMAC algorithms are deliberately impossible to configure: a resource
/// server must never interpret public OIDC verification material as a shared
/// MAC secret.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OidcAlgorithm {
    Rs256,
    Rs384,
    Rs512,
    Ps256,
    Ps384,
    Ps512,
    Es256,
    Es384,
    EdDsa,
}

impl OidcAlgorithm {
    pub(crate) const fn jsonwebtoken(self) -> Algorithm {
        match self {
            Self::Rs256 => Algorithm::RS256,
            Self::Rs384 => Algorithm::RS384,
            Self::Rs512 => Algorithm::RS512,
            Self::Ps256 => Algorithm::PS256,
            Self::Ps384 => Algorithm::PS384,
            Self::Ps512 => Algorithm::PS512,
            Self::Es256 => Algorithm::ES256,
            Self::Es384 => Algorithm::ES384,
            Self::EdDsa => Algorithm::EdDSA,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rs256 => "RS256",
            Self::Rs384 => "RS384",
            Self::Rs512 => "RS512",
            Self::Ps256 => "PS256",
            Self::Ps384 => "PS384",
            Self::Ps512 => "PS512",
            Self::Es256 => "ES256",
            Self::Es384 => "ES384",
            Self::EdDsa => "EdDSA",
        }
    }

    pub fn parse_csv(value: &str) -> Result<Vec<Self>, ConfigError> {
        let algorithms = value
            .split(',')
            .map(str::trim)
            .map(Self::from_str)
            .collect::<Result<Vec<_>, _>>()?;
        if algorithms.is_empty() {
            return Err(ConfigError::InvalidAlgorithms);
        }
        Ok(algorithms)
    }
}

impl fmt::Display for OidcAlgorithm {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for OidcAlgorithm {
    type Err = ConfigError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "RS256" => Ok(Self::Rs256),
            "RS384" => Ok(Self::Rs384),
            "RS512" => Ok(Self::Rs512),
            "PS256" => Ok(Self::Ps256),
            "PS384" => Ok(Self::Ps384),
            "PS512" => Ok(Self::Ps512),
            "ES256" => Ok(Self::Es256),
            "ES384" => Ok(Self::Es384),
            "EdDSA" => Ok(Self::EdDsa),
            _ => Err(ConfigError::InvalidAlgorithms),
        }
    }
}

/// Fully bounded OIDC verifier configuration.
#[derive(Clone)]
pub struct OidcVerifierConfig {
    pub issuer: Url,
    pub audience: String,
    pub allowed_algorithms: Vec<OidcAlgorithm>,
    pub discovery_timeout: Duration,
    pub jwks_cache_ttl: Duration,
    pub jwks_refresh_cooldown: Duration,
    pub clock_skew: Duration,
    pub max_token_bytes: usize,
    pub max_metadata_bytes: usize,
    pub max_jwks_bytes: usize,
    pub max_jwks_keys: usize,
    /// Permits plain HTTP only when deliberately enabled for local/test
    /// deployments. Production configuration should always leave this false.
    pub allow_insecure_http: bool,
}

impl OidcVerifierConfig {
    pub fn new(
        issuer: Url,
        audience: impl Into<String>,
        allowed_algorithms: Vec<OidcAlgorithm>,
    ) -> Self {
        Self {
            issuer,
            audience: audience.into(),
            allowed_algorithms,
            discovery_timeout: Duration::from_secs(5),
            jwks_cache_ttl: Duration::from_secs(15 * 60),
            jwks_refresh_cooldown: Duration::from_secs(30),
            clock_skew: Duration::from_secs(60),
            max_token_bytes: 16 * 1024,
            max_metadata_bytes: 64 * 1024,
            max_jwks_bytes: 1024 * 1024,
            max_jwks_keys: 128,
            allow_insecure_http: false,
        }
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        validate_url(&self.issuer, self.allow_insecure_http)
            .map_err(|()| ConfigError::InvalidIssuer)?;
        if self.audience.is_empty()
            || self.audience.len() > 512
            || self.audience.chars().any(char::is_control)
        {
            return Err(ConfigError::InvalidAudience);
        }
        if self.allowed_algorithms.is_empty() {
            return Err(ConfigError::InvalidAlgorithms);
        }
        let mut unique = self.allowed_algorithms.clone();
        unique.sort_unstable_by_key(|algorithm| algorithm.as_str());
        unique.dedup();
        if unique.len() != self.allowed_algorithms.len() {
            return Err(ConfigError::InvalidAlgorithms);
        }
        if self.discovery_timeout.is_zero() || self.discovery_timeout > MAX_NETWORK_TIMEOUT {
            return Err(ConfigError::InvalidTimeout);
        }
        if self.jwks_cache_ttl.is_zero()
            || self.jwks_cache_ttl > MAX_JWKS_CACHE_TTL
            || self.jwks_refresh_cooldown.is_zero()
            || self.jwks_refresh_cooldown > self.jwks_cache_ttl
            || self.clock_skew > MAX_CLOCK_SKEW
        {
            return Err(ConfigError::InvalidCacheTiming);
        }
        if !(256..=MAX_TOKEN_BYTES).contains(&self.max_token_bytes)
            || !(128..=MAX_METADATA_BYTES).contains(&self.max_metadata_bytes)
            || !(128..=MAX_JWKS_BYTES).contains(&self.max_jwks_bytes)
            || !(1..=MAX_JWKS_KEYS).contains(&self.max_jwks_keys)
        {
            return Err(ConfigError::InvalidSizeLimit);
        }
        Ok(())
    }

    pub(crate) fn discovery_url(&self) -> Result<Url, ConfigError> {
        self.validate()?;
        let issuer = self.issuer.as_str().trim_end_matches('/');
        Url::parse(&format!("{issuer}/.well-known/openid-configuration"))
            .map_err(|_| ConfigError::InvalidIssuer)
    }

    pub(crate) fn allows(&self, algorithm: Algorithm) -> bool {
        self.allowed_algorithms
            .iter()
            .any(|allowed| allowed.jsonwebtoken() == algorithm)
    }
}

impl fmt::Debug for OidcVerifierConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OidcVerifierConfig")
            .field("issuer", &"[redacted]")
            .field("audience", &"[redacted]")
            .field("allowed_algorithms", &self.allowed_algorithms)
            .field("discovery_timeout", &self.discovery_timeout)
            .field("jwks_cache_ttl", &self.jwks_cache_ttl)
            .field("jwks_refresh_cooldown", &self.jwks_refresh_cooldown)
            .field("clock_skew", &self.clock_skew)
            .field("max_token_bytes", &self.max_token_bytes)
            .field("max_metadata_bytes", &self.max_metadata_bytes)
            .field("max_jwks_bytes", &self.max_jwks_bytes)
            .field("max_jwks_keys", &self.max_jwks_keys)
            .field("allow_insecure_http", &self.allow_insecure_http)
            .finish()
    }
}

pub(crate) fn validate_url(url: &Url, allow_insecure_http: bool) -> Result<(), ()> {
    let scheme_allowed = url.scheme() == "https"
        || (allow_insecure_http
            && url.scheme() == "http"
            && match url.host() {
                Some(Host::Ipv4(address)) => address.is_loopback(),
                Some(Host::Ipv6(address)) => address.is_loopback(),
                Some(Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
                None => false,
            });
    if !scheme_allowed
        || url.cannot_be_a_base()
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> OidcVerifierConfig {
        OidcVerifierConfig::new(
            Url::parse("https://identity.example/realms/pakperk").unwrap(),
            "pakperk-api",
            vec![OidcAlgorithm::Rs256],
        )
    }

    #[test]
    fn only_explicit_asymmetric_algorithms_parse() {
        assert_eq!(
            OidcAlgorithm::parse_csv("RS256, EdDSA").unwrap(),
            vec![OidcAlgorithm::Rs256, OidcAlgorithm::EdDsa]
        );
        assert_eq!(
            OidcAlgorithm::parse_csv("HS256"),
            Err(ConfigError::InvalidAlgorithms)
        );
        assert_eq!(
            OidcAlgorithm::parse_csv("none"),
            Err(ConfigError::InvalidAlgorithms)
        );
    }

    #[test]
    fn configuration_requires_https_unless_explicitly_overridden() {
        let mut value = config();
        value.issuer = Url::parse("http://localhost:8081/realms/pakperk").unwrap();
        assert_eq!(value.validate(), Err(ConfigError::InvalidIssuer));

        value.allow_insecure_http = true;
        assert_eq!(value.validate(), Ok(()));

        value.issuer = Url::parse("http://identity.internal/realm").unwrap();
        assert_eq!(value.validate(), Err(ConfigError::InvalidIssuer));
    }

    #[test]
    fn issuer_rejects_credentials_queries_and_fragments() {
        for issuer in [
            "https://user@identity.example/realm",
            "https://identity.example/realm?tenant=secret",
            "https://identity.example/realm#fragment",
        ] {
            let mut value = config();
            value.issuer = Url::parse(issuer).unwrap();
            assert_eq!(value.validate(), Err(ConfigError::InvalidIssuer));
        }
    }

    #[test]
    fn discovery_url_preserves_an_issuer_path() {
        assert_eq!(
            config().discovery_url().unwrap().as_str(),
            "https://identity.example/realms/pakperk/.well-known/openid-configuration"
        );
    }

    #[test]
    fn bounds_and_duplicate_algorithms_are_rejected() {
        let mut value = config();
        value.allowed_algorithms.push(OidcAlgorithm::Rs256);
        assert_eq!(value.validate(), Err(ConfigError::InvalidAlgorithms));

        let mut value = config();
        value.discovery_timeout = Duration::from_secs(31);
        assert_eq!(value.validate(), Err(ConfigError::InvalidTimeout));

        let mut value = config();
        value.max_token_bytes = MAX_TOKEN_BYTES + 1;
        assert_eq!(value.validate(), Err(ConfigError::InvalidSizeLimit));
    }

    #[test]
    fn debug_redacts_provider_and_audience() {
        let rendered = format!("{:?}", config());
        assert!(!rendered.contains("identity.example"));
        assert!(!rendered.contains("pakperk-api"));
    }
}
