use std::{
    collections::HashMap,
    fmt,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use jsonwebtoken::{
    Algorithm, DecodingKey, Validation, decode, decode_header,
    errors::ErrorKind,
    jwk::{AlgorithmParameters, EllipticCurve, Jwk, JwkSet, KeyOperations, PublicKeyUse},
};
use observability::{
    OperationClass, OperationOutcome, TokenVerificationOutcome, record_operation,
    record_token_verification,
};
use serde::Deserialize;
use tokio::sync::{Mutex, RwLock};

use crate::{
    HttpOidcDocumentFetcher, OidcDocumentFetcher, OidcProviderMetadata, OidcStartupError,
    OidcVerifierConfig, VerifiedOidcClaims, VerifyError, config::validate_url,
    discovery::discover_provider,
};

const MAX_KEY_ID_BYTES: usize = 256;
// Keep this at or below the account-service/database identity bound so a
// successfully verified subject can always be mapped to a local account.
const MAX_SUBJECT_BYTES: usize = 512;
const MAX_AUDIENCES: usize = 64;
const MAX_AUDIENCE_BYTES: usize = 512;

/// Object-safe token verification seam used by API principal extractors and
/// deterministic route tests.
#[async_trait]
pub trait TokenVerifier: Send + Sync {
    async fn verify(&self, bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError>;
}

#[derive(Clone)]
pub struct OidcJwtVerifier {
    inner: Arc<VerifierInner>,
}

struct VerifierInner {
    config: OidcVerifierConfig,
    metadata: OidcProviderMetadata,
    fetcher: Arc<dyn OidcDocumentFetcher>,
    cache: RwLock<JwksCache>,
    refresh: Mutex<()>,
}

struct JwksCache {
    keys: HashMap<String, Jwk>,
    fetched_at: Instant,
    generation: u64,
    last_refresh_attempt: Option<Instant>,
}

impl OidcJwtVerifier {
    /// Discover provider metadata and eagerly fetch signing keys. Callers that
    /// want guest routes to survive provider downtime should translate a
    /// startup error into [`crate::AuthRuntime::unavailable`].
    pub async fn discover(config: OidcVerifierConfig) -> Result<Self, OidcStartupError> {
        config
            .validate()
            .map_err(|_| OidcStartupError::InvalidConfiguration)?;
        let fetcher = Arc::new(
            HttpOidcDocumentFetcher::new(config.discovery_timeout)
                .map_err(|_| OidcStartupError::ProviderUnavailable)?,
        );
        Self::discover_with_fetcher(config, fetcher).await
    }

    /// Injectable discovery path for deterministic integration tests.
    pub async fn discover_with_fetcher(
        config: OidcVerifierConfig,
        fetcher: Arc<dyn OidcDocumentFetcher>,
    ) -> Result<Self, OidcStartupError> {
        config
            .validate()
            .map_err(|_| OidcStartupError::InvalidConfiguration)?;
        let metadata = discover_provider(&config, Arc::clone(&fetcher)).await?;
        let jwks = fetch_jwks(&config, &metadata, Arc::clone(&fetcher)).await?;
        Self::from_parts(config, metadata, jwks, fetcher)
    }

    /// Construct from already-fetched documents while retaining a fetcher for
    /// on-demand rotation. This is primarily useful for deterministic tests or
    /// a process-level bootstrap coordinator.
    pub fn from_parts(
        config: OidcVerifierConfig,
        metadata: OidcProviderMetadata,
        jwks: JwkSet,
        fetcher: Arc<dyn OidcDocumentFetcher>,
    ) -> Result<Self, OidcStartupError> {
        validate_parts(&config, &metadata)?;
        let keys = build_key_map(jwks, config.max_jwks_keys)?;
        Ok(Self {
            inner: Arc::new(VerifierInner {
                config,
                metadata,
                fetcher,
                cache: RwLock::new(JwksCache {
                    keys,
                    fetched_at: Instant::now(),
                    generation: 1,
                    last_refresh_attempt: None,
                }),
                refresh: Mutex::new(()),
            }),
        })
    }

    async fn key_for(&self, key_id: &str) -> Result<Jwk, VerifyError> {
        let (key, fresh, observed_generation) = {
            let cache = self.inner.cache.read().await;
            (
                cache.keys.get(key_id).cloned(),
                cache_is_fresh(&cache, self.inner.config.jwks_cache_ttl),
                cache.generation,
            )
        };
        if fresh && let Some(key) = key {
            return Ok(key);
        }

        self.refresh_if_needed(observed_generation).await?;
        let cache = self.inner.cache.read().await;
        if !cache_is_fresh(&cache, self.inner.config.jwks_cache_ttl) {
            return Err(VerifyError::MetadataUnavailable);
        }
        cache
            .keys
            .get(key_id)
            .cloned()
            .ok_or(VerifyError::UnknownSigningKey)
    }

    async fn refresh_if_needed(&self, observed_generation: u64) -> Result<(), VerifyError> {
        let _guard = self.inner.refresh.lock().await;
        let now = Instant::now();
        {
            let mut cache = self.inner.cache.write().await;
            if cache.generation != observed_generation {
                return Ok(());
            }
            if cache.last_refresh_attempt.is_some_and(|last_attempt| {
                now.saturating_duration_since(last_attempt)
                    < self.inner.config.jwks_refresh_cooldown
            }) {
                return Ok(());
            }
            // Set before awaiting so cancellation still applies the cooldown
            // rather than allowing an attacker to create a tight retry loop.
            cache.last_refresh_attempt = Some(now);
        }

        let jwks = fetch_jwks(
            &self.inner.config,
            &self.inner.metadata,
            Arc::clone(&self.inner.fetcher),
        )
        .await
        .map_err(|_| VerifyError::MetadataUnavailable)?;
        let keys = build_key_map(jwks, self.inner.config.max_jwks_keys)
            .map_err(|_| VerifyError::MetadataUnavailable)?;

        let mut cache = self.inner.cache.write().await;
        cache.keys = keys;
        cache.fetched_at = Instant::now();
        cache.generation = cache.generation.saturating_add(1);
        Ok(())
    }

    async fn verify_inner(&self, bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError> {
        if bearer_token.len() > self.inner.config.max_token_bytes {
            return Err(VerifyError::TokenTooLarge);
        }
        if bearer_token.is_empty() {
            return Err(VerifyError::MalformedToken);
        }

        let header = decode_header(bearer_token).map_err(|_| VerifyError::MalformedToken)?;
        if !self.inner.config.allows(header.alg) {
            return Err(VerifyError::DisallowedAlgorithm);
        }
        let key_id = header.kid.as_deref().ok_or(VerifyError::MissingKeyId)?;
        if key_id.is_empty()
            || key_id.len() > MAX_KEY_ID_BYTES
            || key_id.chars().any(char::is_control)
        {
            return Err(VerifyError::MissingKeyId);
        }

        let jwk = self.key_for(key_id).await?;
        let decoding_key = decoding_key_for(&jwk, header.alg)?;
        let mut validation = Validation::new(header.alg);
        validation.algorithms = vec![header.alg];
        validation.leeway = self.inner.config.clock_skew.as_secs();
        validation.validate_exp = true;
        validation.validate_nbf = true;
        validation.validate_aud = true;
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.set_issuer(&[self.inner.config.issuer.as_str()]);
        validation.set_audience(&[self.inner.config.audience.as_str()]);

        let token = decode::<RawClaims>(bearer_token, &decoding_key, &validation)
            .map_err(|error| map_decode_error(&error))?;
        verified_claims(&self.inner.config, token.claims)
    }
}

impl fmt::Debug for OidcJwtVerifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OidcJwtVerifier")
            .field("provider", &"[redacted]")
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl TokenVerifier for OidcJwtVerifier {
    async fn verify(&self, bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError> {
        let started = Instant::now();
        let result = self.verify_inner(bearer_token).await;
        record_token_verification(token_outcome(&result), started.elapsed());
        result
    }
}

fn token_outcome(result: &Result<VerifiedOidcClaims, VerifyError>) -> TokenVerificationOutcome {
    match result {
        Ok(_) => TokenVerificationOutcome::Success,
        Err(VerifyError::Expired) => TokenVerificationOutcome::Expired,
        Err(
            VerifyError::TokenTooLarge | VerifyError::MalformedToken | VerifyError::MissingKeyId,
        ) => TokenVerificationOutcome::Malformed,
        Err(VerifyError::DisallowedAlgorithm) => TokenVerificationOutcome::DisallowedAlgorithm,
        Err(VerifyError::UnknownSigningKey) => TokenVerificationOutcome::SigningKeyUnavailable,
        Err(VerifyError::InvalidSignature) => TokenVerificationOutcome::InvalidSignature,
        Err(VerifyError::NotYetValid) => TokenVerificationOutcome::InvalidTime,
        Err(VerifyError::InvalidClaims) => TokenVerificationOutcome::InvalidClaims,
        Err(VerifyError::MetadataUnavailable) => TokenVerificationOutcome::MetadataUnavailable,
    }
}

fn validate_parts(
    config: &OidcVerifierConfig,
    metadata: &OidcProviderMetadata,
) -> Result<(), OidcStartupError> {
    config
        .validate()
        .map_err(|_| OidcStartupError::InvalidConfiguration)?;
    if metadata.issuer().as_str() != config.issuer.as_str()
        || validate_url(metadata.issuer(), config.allow_insecure_http).is_err()
        || validate_url(metadata.jwks_uri(), config.allow_insecure_http).is_err()
    {
        return Err(OidcStartupError::InvalidProviderMetadata);
    }
    Ok(())
}

async fn fetch_jwks(
    config: &OidcVerifierConfig,
    metadata: &OidcProviderMetadata,
    fetcher: Arc<dyn OidcDocumentFetcher>,
) -> Result<JwkSet, OidcStartupError> {
    let started = Instant::now();
    let result = async {
        let bytes = fetcher
            .fetch(metadata.jwks_uri(), config.max_jwks_bytes)
            .await
            .map_err(|_| OidcStartupError::ProviderUnavailable)?;
        if bytes.len() > config.max_jwks_bytes {
            return Err(OidcStartupError::InvalidSigningKeys);
        }
        serde_json::from_slice(&bytes).map_err(|_| OidcStartupError::InvalidSigningKeys)
    }
    .await;
    let outcome = match &result {
        Ok(_) => OperationOutcome::Success,
        Err(OidcStartupError::ProviderUnavailable) => OperationOutcome::RetryableFailure,
        Err(_) => OperationOutcome::Rejected,
    };
    record_operation(OperationClass::OidcJwksRefresh, outcome, started.elapsed());
    result
}

fn build_key_map(
    jwks: JwkSet,
    max_jwks_keys: usize,
) -> Result<HashMap<String, Jwk>, OidcStartupError> {
    if jwks.keys.len() > max_jwks_keys {
        return Err(OidcStartupError::InvalidSigningKeys);
    }
    let mut keys = HashMap::with_capacity(jwks.keys.len());
    for key in jwks.keys {
        let Some(key_id) = key.common.key_id.as_deref() else {
            continue;
        };
        if key_id.is_empty()
            || key_id.len() > MAX_KEY_ID_BYTES
            || key_id.chars().any(char::is_control)
            || keys.contains_key(key_id)
        {
            return Err(OidcStartupError::InvalidSigningKeys);
        }
        if !jwk_is_verification_key(&key) {
            continue;
        }
        DecodingKey::from_jwk(&key).map_err(|_| OidcStartupError::InvalidSigningKeys)?;
        keys.insert(key_id.to_owned(), key);
    }
    if keys.is_empty() {
        return Err(OidcStartupError::InvalidSigningKeys);
    }
    Ok(keys)
}

fn jwk_is_verification_key(jwk: &Jwk) -> bool {
    if jwk.common.public_key_use.is_some() && jwk.common.key_operations.is_some() {
        return false;
    }
    if !matches!(
        jwk.common.public_key_use.as_ref(),
        None | Some(PublicKeyUse::Signature)
    ) {
        return false;
    }
    if jwk
        .common
        .key_operations
        .as_ref()
        .is_some_and(|operations| !operations.contains(&KeyOperations::Verify))
    {
        return false;
    }
    has_sane_asymmetric_key_material(&jwk.algorithm)
}

fn has_sane_asymmetric_key_material(parameters: &AlgorithmParameters) -> bool {
    match parameters {
        AlgorithmParameters::RSA(rsa) => {
            decoded_length_in_range(&rsa.n, 256, 1024) && decoded_length_in_range(&rsa.e, 1, 8)
        }
        AlgorithmParameters::EllipticCurve(ec) => match ec.curve {
            EllipticCurve::P256 => {
                decoded_length_in_range(&ec.x, 32, 32) && decoded_length_in_range(&ec.y, 32, 32)
            }
            EllipticCurve::P384 => {
                decoded_length_in_range(&ec.x, 48, 48) && decoded_length_in_range(&ec.y, 48, 48)
            }
            _ => false,
        },
        AlgorithmParameters::OctetKeyPair(okp) => {
            okp.curve == EllipticCurve::Ed25519 && decoded_length_in_range(&okp.x, 32, 32)
        }
        _ => false,
    }
}

fn decoded_length_in_range(value: &str, minimum: usize, maximum: usize) -> bool {
    URL_SAFE_NO_PAD
        .decode(value)
        .is_ok_and(|decoded| (minimum..=maximum).contains(&decoded.len()))
}

fn decoding_key_for(jwk: &Jwk, algorithm: Algorithm) -> Result<DecodingKey, VerifyError> {
    if let Some(key_algorithm) = jwk.common.key_algorithm {
        let key_algorithm =
            Algorithm::try_from(key_algorithm).map_err(|_| VerifyError::InvalidSignature)?;
        if key_algorithm != algorithm {
            return Err(VerifyError::InvalidSignature);
        }
    }
    let key = DecodingKey::from_jwk(jwk).map_err(|_| VerifyError::MetadataUnavailable)?;
    if key.family() != algorithm.family() {
        return Err(VerifyError::InvalidSignature);
    }
    Ok(key)
}

fn cache_is_fresh(cache: &JwksCache, ttl: Duration) -> bool {
    Instant::now().saturating_duration_since(cache.fetched_at) < ttl
}

#[derive(Deserialize)]
struct RawClaims {
    iss: String,
    sub: String,
    aud: AudienceClaim,
    exp: i64,
    #[allow(dead_code)]
    nbf: Option<i64>,
    iat: Option<i64>,
    auth_time: Option<i64>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum AudienceClaim {
    One(String),
    Many(Vec<String>),
}

impl AudienceClaim {
    fn into_vec(self) -> Vec<String> {
        match self {
            Self::One(audience) => vec![audience],
            Self::Many(audiences) => audiences,
        }
    }
}

fn verified_claims(
    config: &OidcVerifierConfig,
    raw: RawClaims,
) -> Result<VerifiedOidcClaims, VerifyError> {
    let audiences = raw.aud.into_vec();
    if raw.iss != config.issuer.as_str()
        || raw.sub.trim().is_empty()
        || raw.sub.len() > MAX_SUBJECT_BYTES
        || audiences.is_empty()
        || audiences.len() > MAX_AUDIENCES
        || audiences
            .iter()
            .any(|audience| audience.is_empty() || audience.len() > MAX_AUDIENCE_BYTES)
        || !audiences
            .iter()
            .any(|audience| audience == &config.audience)
    {
        return Err(VerifyError::InvalidClaims);
    }
    let expires_at = timestamp(raw.exp)?;
    let issued_at = raw.iat.map(timestamp).transpose()?;
    let auth_time = raw.auth_time.map(timestamp).transpose()?;
    Ok(VerifiedOidcClaims::new(
        raw.iss, raw.sub, audiences, expires_at, issued_at, auth_time,
    ))
}

fn timestamp(seconds: i64) -> Result<DateTime<Utc>, VerifyError> {
    DateTime::from_timestamp(seconds, 0).ok_or(VerifyError::InvalidClaims)
}

fn map_decode_error(error: &jsonwebtoken::errors::Error) -> VerifyError {
    match error.kind() {
        ErrorKind::ExpiredSignature => VerifyError::Expired,
        ErrorKind::ImmatureSignature => VerifyError::NotYetValid,
        ErrorKind::InvalidSignature => VerifyError::InvalidSignature,
        ErrorKind::InvalidAlgorithm | ErrorKind::MissingAlgorithm => {
            VerifyError::DisallowedAlgorithm
        }
        ErrorKind::InvalidIssuer
        | ErrorKind::InvalidAudience
        | ErrorKind::InvalidSubject
        | ErrorKind::MissingRequiredClaim(_)
        | ErrorKind::InvalidClaimFormat(_)
        | ErrorKind::Json(_) => VerifyError::InvalidClaims,
        _ => VerifyError::MalformedToken,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        collections::VecDeque,
        sync::atomic::{AtomicUsize, Ordering},
    };

    use jsonwebtoken::{EncodingKey, Header, encode};
    use serde_json::json;
    use tokio::time::sleep;
    use url::Url;

    use super::*;
    use crate::{DocumentFetchError, OidcAlgorithm};

    // RFC 8410 PKCS#8 Ed25519 test key. Test-only; never used by production.
    const PRIVATE_ED25519_KEY: &[u8] = &[
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04,
        0x20, 0x6a, 0xc3, 0xfd, 0xee, 0xee, 0x29, 0x8a, 0x92, 0x63, 0x8b, 0x70, 0x0c, 0x4b, 0x11,
        0x7c, 0xc3, 0x2e, 0x2d, 0x2a, 0xce, 0x0d, 0xfd, 0x78, 0x76, 0x94, 0xe2, 0x4c, 0xae, 0x8a,
        0xd5, 0x82, 0x34,
    ];
    const PUBLIC_ED25519_X: &str = "2-Jj2UvNCvQiUPNYRgSi0cJSPiJI6Rs6D0UTeEpQVj8";

    struct SequenceFetcher {
        responses: Mutex<VecDeque<Result<Vec<u8>, DocumentFetchError>>>,
        calls: AtomicUsize,
        delay: Duration,
    }

    impl SequenceFetcher {
        fn new(responses: Vec<Result<Vec<u8>, DocumentFetchError>>) -> Self {
            Self {
                responses: Mutex::new(responses.into()),
                calls: AtomicUsize::new(0),
                delay: Duration::ZERO,
            }
        }

        fn delayed(responses: Vec<Result<Vec<u8>, DocumentFetchError>>) -> Self {
            Self {
                responses: Mutex::new(responses.into()),
                calls: AtomicUsize::new(0),
                delay: Duration::from_millis(25),
            }
        }
    }

    #[async_trait]
    impl OidcDocumentFetcher for SequenceFetcher {
        async fn fetch(
            &self,
            _url: &url::Url,
            max_bytes: usize,
        ) -> Result<Vec<u8>, DocumentFetchError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if !self.delay.is_zero() {
                sleep(self.delay).await;
            }
            let response = self
                .responses
                .lock()
                .await
                .pop_front()
                .unwrap_or(Err(DocumentFetchError::Network))?;
            if response.len() > max_bytes {
                return Err(DocumentFetchError::TooLarge);
            }
            Ok(response)
        }
    }

    fn config() -> OidcVerifierConfig {
        OidcVerifierConfig::new(
            Url::parse("https://identity.example/realms/pakperk").unwrap(),
            "pakperk-api",
            vec![OidcAlgorithm::EdDsa],
        )
    }

    fn metadata() -> OidcProviderMetadata {
        OidcProviderMetadata::new(
            config().issuer,
            Url::parse("https://identity.example/realms/pakperk/keys").unwrap(),
        )
    }

    fn jwk(key_id: &str) -> Jwk {
        serde_json::from_value(json!({
            "kty": "OKP",
            "use": "sig",
            "crv": "Ed25519",
            "x": PUBLIC_ED25519_X,
            "kid": key_id,
            "alg": "EdDSA"
        }))
        .unwrap()
    }

    fn jwks(key_ids: &[&str]) -> JwkSet {
        JwkSet {
            keys: key_ids.iter().map(|key_id| jwk(key_id)).collect(),
        }
    }

    fn jwks_bytes(key_ids: &[&str]) -> Vec<u8> {
        serde_json::to_vec(&jwks(key_ids)).unwrap()
    }

    fn verifier(
        config: OidcVerifierConfig,
        initial_keys: &[&str],
        fetcher: Arc<dyn OidcDocumentFetcher>,
    ) -> OidcJwtVerifier {
        OidcJwtVerifier::from_parts(config, metadata(), jwks(initial_keys), fetcher).unwrap()
    }

    fn claims() -> serde_json::Value {
        let now = Utc::now().timestamp();
        json!({
            "iss": "https://identity.example/realms/pakperk",
            "sub": "opaque-subject",
            "aud": "pakperk-api",
            "exp": now + 600,
            "nbf": now - 30,
            "iat": now - 30,
            "auth_time": now - 60
        })
    }

    fn token(key_id: Option<&str>, claims: &serde_json::Value) -> String {
        let mut header = Header::new(Algorithm::EdDSA);
        header.kid = key_id.map(str::to_owned);
        encode(
            &header,
            claims,
            &EncodingKey::from_ed_der(PRIVATE_ED25519_KEY),
        )
        .unwrap()
    }

    fn unused_fetcher() -> Arc<SequenceFetcher> {
        Arc::new(SequenceFetcher::new(Vec::new()))
    }

    #[tokio::test]
    async fn verifies_string_and_array_audiences() {
        let verifier = verifier(config(), &["current"], unused_fetcher());
        let single = verifier
            .verify(&token(Some("current"), &claims()))
            .await
            .unwrap();
        assert_eq!(single.subject(), "opaque-subject");
        assert_eq!(single.audience(), &["pakperk-api"]);

        let mut array_claims = claims();
        array_claims["aud"] = json!(["another-service", "pakperk-api"]);
        let array = verifier
            .verify(&token(Some("current"), &array_claims))
            .await
            .unwrap();
        assert_eq!(array.audience().len(), 2);
    }

    #[tokio::test]
    async fn issuer_and_audience_are_exact() {
        let verifier = verifier(config(), &["current"], unused_fetcher());
        let mut wrong_issuer = claims();
        wrong_issuer["iss"] = json!("https://identity.example/realms/other");
        assert_eq!(
            verifier
                .verify(&token(Some("current"), &wrong_issuer))
                .await,
            Err(VerifyError::InvalidClaims)
        );

        let mut wrong_audience = claims();
        wrong_audience["aud"] = json!("pakperk-mobile");
        assert_eq!(
            verifier
                .verify(&token(Some("current"), &wrong_audience))
                .await,
            Err(VerifyError::InvalidClaims)
        );
    }

    #[tokio::test]
    async fn expiration_not_before_and_subject_are_strict() {
        let verifier = verifier(config(), &["current"], unused_fetcher());
        let now = Utc::now().timestamp();

        let mut expired = claims();
        expired["exp"] = json!(now - 600);
        assert_eq!(
            verifier.verify(&token(Some("current"), &expired)).await,
            Err(VerifyError::Expired)
        );

        let mut future = claims();
        future["nbf"] = json!(now + 600);
        assert_eq!(
            verifier.verify(&token(Some("current"), &future)).await,
            Err(VerifyError::NotYetValid)
        );

        for subject in [json!(null), json!(""), json!("   ")] {
            let mut invalid = claims();
            invalid["sub"] = subject;
            assert_eq!(
                verifier.verify(&token(Some("current"), &invalid)).await,
                Err(VerifyError::InvalidClaims)
            );
        }

        let mut oversized_subject = claims();
        oversized_subject["sub"] = json!("s".repeat(MAX_SUBJECT_BYTES + 1));
        assert_eq!(
            verifier
                .verify(&token(Some("current"), &oversized_subject))
                .await,
            Err(VerifyError::InvalidClaims)
        );

        let mut missing_expiration = claims();
        missing_expiration.as_object_mut().unwrap().remove("exp");
        assert_eq!(
            verifier
                .verify(&token(Some("current"), &missing_expiration))
                .await,
            Err(VerifyError::InvalidClaims)
        );
    }

    #[tokio::test]
    async fn configured_clock_skew_is_applied_to_exp_and_nbf() {
        let verifier = verifier(config(), &["current"], unused_fetcher());
        let now = Utc::now().timestamp();
        let mut within_skew = claims();
        within_skew["exp"] = json!(now - 30);
        within_skew["nbf"] = json!(now + 30);
        assert!(
            verifier
                .verify(&token(Some("current"), &within_skew))
                .await
                .is_ok()
        );
    }

    #[tokio::test]
    async fn requires_kid_and_rejects_token_selected_hmac() {
        let verifier = verifier(config(), &["current"], unused_fetcher());
        assert_eq!(
            verifier.verify(&token(None, &claims())).await,
            Err(VerifyError::MissingKeyId)
        );

        let mut header = Header::new(Algorithm::HS256);
        header.kid = Some("current".into());
        let hmac = encode(
            &header,
            &claims(),
            &EncodingKey::from_secret(b"not-a-public-key"),
        )
        .unwrap();
        assert_eq!(
            verifier.verify(&hmac).await,
            Err(VerifyError::DisallowedAlgorithm)
        );
    }

    #[tokio::test]
    async fn token_byte_bound_is_checked_before_parsing() {
        let mut bounded = config();
        bounded.max_token_bytes = 256;
        let verifier = verifier(bounded, &["current"], unused_fetcher());
        let oversized = "private-token-material".repeat(20);
        assert_eq!(
            verifier.verify(&oversized).await,
            Err(VerifyError::TokenTooLarge)
        );
        assert!(!format!("{:?}", VerifyError::TokenTooLarge).contains(&oversized));
    }

    #[tokio::test]
    async fn altered_signature_is_rejected_without_leaking_the_token() {
        let verifier = verifier(config(), &["current"], unused_fetcher());
        let mut altered = token(Some("current"), &claims()).into_bytes();
        let signature_start = altered.iter().rposition(|byte| *byte == b'.').unwrap() + 1;
        altered[signature_start] = if altered[signature_start] == b'A' {
            b'B'
        } else {
            b'A'
        };
        let altered = String::from_utf8(altered).unwrap();
        let error = verifier.verify(&altered).await.unwrap_err();
        assert_eq!(error, VerifyError::InvalidSignature);
        assert!(!format!("{error:?}").contains(&altered));
    }

    #[tokio::test]
    async fn unknown_kid_refreshes_and_accepts_rotated_key() {
        let fetcher = Arc::new(SequenceFetcher::new(vec![Ok(jwks_bytes(&["rotated"]))]));
        let verifier = verifier(config(), &["current"], fetcher.clone());

        let claims = verifier
            .verify(&token(Some("rotated"), &claims()))
            .await
            .unwrap();
        assert_eq!(claims.subject(), "opaque-subject");
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn concurrent_unknown_kid_requests_share_one_refresh() {
        let fetcher = Arc::new(SequenceFetcher::delayed(vec![Ok(jwks_bytes(&["current"]))]));
        let verifier = verifier(config(), &["current"], fetcher.clone());
        let unknown = token(Some("missing"), &claims());
        let mut tasks = Vec::new();
        for _ in 0..12 {
            let verifier = verifier.clone();
            let unknown = unknown.clone();
            tasks.push(tokio::spawn(async move { verifier.verify(&unknown).await }));
        }
        for task in tasks {
            assert_eq!(task.await.unwrap(), Err(VerifyError::UnknownSigningKey));
        }
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 1);

        // The cooldown also prevents sequential attacker-controlled key IDs
        // from turning verification into an unbounded discovery request loop.
        assert_eq!(
            verifier.verify(&token(Some("another"), &claims())).await,
            Err(VerifyError::UnknownSigningKey)
        );
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn failed_rotation_fails_closed_without_upstream_details() {
        let fetcher = Arc::new(SequenceFetcher::new(vec![Err(DocumentFetchError::Network)]));
        let verifier = verifier(config(), &["current"], fetcher);
        assert_eq!(
            verifier.verify(&token(Some("rotated"), &claims())).await,
            Err(VerifyError::MetadataUnavailable)
        );
    }

    #[test]
    fn ambiguous_symmetric_or_weak_jwks_are_rejected() {
        assert_eq!(
            build_key_map(jwks(&["same", "same"]), 128),
            Err(OidcStartupError::InvalidSigningKeys)
        );
        let symmetric: Jwk = serde_json::from_value(json!({
            "kty": "oct",
            "k": "c2VjcmV0",
            "kid": "shared-secret",
            "alg": "HS256"
        }))
        .unwrap();
        assert_eq!(
            build_key_map(
                JwkSet {
                    keys: vec![symmetric]
                },
                128
            ),
            Err(OidcStartupError::InvalidSigningKeys)
        );
        let weak_rsa: Jwk = serde_json::from_value(json!({
            "kty": "RSA",
            "n": "AQ",
            "e": "AQAB",
            "kid": "weak",
            "alg": "RS256"
        }))
        .unwrap();
        assert_eq!(
            build_key_map(
                JwkSet {
                    keys: vec![weak_rsa]
                },
                128
            ),
            Err(OidcStartupError::InvalidSigningKeys)
        );
    }
}
