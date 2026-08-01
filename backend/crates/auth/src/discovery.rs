use std::{
    fmt,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use observability::{OperationClass, OperationOutcome, record_operation};
use reqwest::{Client, redirect::Policy};
use serde::Deserialize;
use url::Url;

use crate::{OidcStartupError, OidcVerifierConfig, config::validate_url};

const MAX_DOCUMENT_TIMEOUT: Duration = Duration::from_secs(30);

/// Sanitized OIDC document transport failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum DocumentFetchError {
    #[error("OIDC document request failed")]
    Network,
    #[error("OIDC document endpoint returned an unsuccessful status")]
    UnexpectedStatus,
    #[error("OIDC document exceeded its configured byte limit")]
    TooLarge,
}

/// Injectable boundary for deterministic discovery and key-rotation tests.
/// Implementations must honor `max_bytes` before returning a body.
#[async_trait]
pub trait OidcDocumentFetcher: Send + Sync {
    async fn fetch(&self, url: &Url, max_bytes: usize) -> Result<Vec<u8>, DocumentFetchError>;
}

/// Redirect-free, timeout-bounded HTTPS client for OIDC metadata and JWKS.
#[derive(Clone)]
pub struct HttpOidcDocumentFetcher {
    client: Client,
}

impl HttpOidcDocumentFetcher {
    pub fn new(timeout: Duration) -> Result<Self, DocumentFetchError> {
        if timeout.is_zero() || timeout > MAX_DOCUMENT_TIMEOUT {
            return Err(DocumentFetchError::Network);
        }
        let client = Client::builder()
            .redirect(Policy::none())
            .connect_timeout(timeout.min(Duration::from_secs(5)))
            .timeout(timeout)
            .user_agent("Pakperk-API/0.1 OIDC verifier")
            .build()
            .map_err(|_| DocumentFetchError::Network)?;
        Ok(Self { client })
    }
}

impl fmt::Debug for HttpOidcDocumentFetcher {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpOidcDocumentFetcher")
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl OidcDocumentFetcher for HttpOidcDocumentFetcher {
    async fn fetch(&self, url: &Url, max_bytes: usize) -> Result<Vec<u8>, DocumentFetchError> {
        if max_bytes == 0 {
            return Err(DocumentFetchError::TooLarge);
        }
        let mut response = self
            .client
            .get(url.clone())
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|_| DocumentFetchError::Network)?;
        if !response.status().is_success() {
            return Err(DocumentFetchError::UnexpectedStatus);
        }
        if response
            .content_length()
            .is_some_and(|length| length > max_bytes as u64)
        {
            return Err(DocumentFetchError::TooLarge);
        }

        let mut body = Vec::with_capacity(
            response
                .content_length()
                .and_then(|length| usize::try_from(length).ok())
                .unwrap_or_default()
                .min(max_bytes),
        );
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| DocumentFetchError::Network)?
        {
            let new_length = body
                .len()
                .checked_add(chunk.len())
                .ok_or(DocumentFetchError::TooLarge)?;
            if new_length > max_bytes {
                return Err(DocumentFetchError::TooLarge);
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    }
}

/// The small discovery subset needed to verify resource-server tokens.
#[derive(Clone, PartialEq, Eq)]
pub struct OidcProviderMetadata {
    issuer: Url,
    jwks_uri: Url,
}

impl OidcProviderMetadata {
    pub fn new(issuer: Url, jwks_uri: Url) -> Self {
        Self { issuer, jwks_uri }
    }

    pub fn issuer(&self) -> &Url {
        &self.issuer
    }

    pub fn jwks_uri(&self) -> &Url {
        &self.jwks_uri
    }
}

impl fmt::Debug for OidcProviderMetadata {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OidcProviderMetadata")
            .field("issuer", &"[redacted]")
            .field("jwks_uri", &"[redacted]")
            .finish()
    }
}

#[derive(Deserialize)]
struct RawProviderMetadata {
    issuer: String,
    jwks_uri: String,
}

pub(crate) async fn discover_provider(
    config: &OidcVerifierConfig,
    fetcher: Arc<dyn OidcDocumentFetcher>,
) -> Result<OidcProviderMetadata, OidcStartupError> {
    let started = Instant::now();
    let result = async {
        let discovery_url = config
            .discovery_url()
            .map_err(|_| OidcStartupError::InvalidConfiguration)?;
        let bytes = fetcher
            .fetch(&discovery_url, config.max_metadata_bytes)
            .await
            .map_err(|_| OidcStartupError::ProviderUnavailable)?;
        parse_provider_metadata(config, &bytes)
    }
    .await;
    record_operation(
        OperationClass::OidcDiscovery,
        startup_outcome(&result),
        started.elapsed(),
    );
    result
}

fn startup_outcome<T>(result: &Result<T, OidcStartupError>) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(OidcStartupError::ProviderUnavailable) => OperationOutcome::RetryableFailure,
        Err(
            OidcStartupError::InvalidConfiguration
            | OidcStartupError::InvalidProviderMetadata
            | OidcStartupError::InvalidSigningKeys,
        ) => OperationOutcome::Rejected,
    }
}

pub(crate) fn parse_provider_metadata(
    config: &OidcVerifierConfig,
    bytes: &[u8],
) -> Result<OidcProviderMetadata, OidcStartupError> {
    if bytes.len() > config.max_metadata_bytes {
        return Err(OidcStartupError::InvalidProviderMetadata);
    }
    let raw: RawProviderMetadata =
        serde_json::from_slice(bytes).map_err(|_| OidcStartupError::InvalidProviderMetadata)?;

    // Compare the serialized identifiers, not merely URL equivalence. OIDC
    // issuer matching is an exact, case-sensitive string comparison.
    if raw.issuer != config.issuer.as_str() {
        return Err(OidcStartupError::InvalidProviderMetadata);
    }
    let issuer = Url::parse(&raw.issuer).map_err(|_| OidcStartupError::InvalidProviderMetadata)?;
    let jwks_uri =
        Url::parse(&raw.jwks_uri).map_err(|_| OidcStartupError::InvalidProviderMetadata)?;
    validate_url(&issuer, config.allow_insecure_http)
        .map_err(|()| OidcStartupError::InvalidProviderMetadata)?;
    validate_url(&jwks_uri, config.allow_insecure_http)
        .map_err(|()| OidcStartupError::InvalidProviderMetadata)?;

    Ok(OidcProviderMetadata::new(issuer, jwks_uri))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::{
        Router,
        body::Body,
        http::{Response, StatusCode, header::LOCATION},
        routing::get,
    };
    use tokio::net::TcpListener;

    use super::*;
    use crate::OidcAlgorithm;

    fn config(issuer: Url) -> OidcVerifierConfig {
        let mut config = OidcVerifierConfig::new(issuer, "pakperk-api", vec![OidcAlgorithm::EdDsa]);
        config.allow_insecure_http = true;
        config
    }

    async fn serve(app: Router) -> (Url, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (Url::parse(&format!("http://{address}/")).unwrap(), task)
    }

    #[test]
    fn discovery_requires_an_exact_issuer_string() {
        let issuer = Url::parse("https://identity.example/realm/").unwrap();
        let config = config(issuer);
        let body = br#"{
            "issuer":"https://identity.example/realm",
            "jwks_uri":"https://identity.example/realm/keys"
        }"#;
        assert_eq!(
            parse_provider_metadata(&config, body),
            Err(OidcStartupError::InvalidProviderMetadata)
        );
    }

    #[test]
    fn metadata_rejects_an_insecure_jwks_endpoint() {
        let issuer = Url::parse("https://identity.example/realm").unwrap();
        let config = OidcVerifierConfig::new(issuer, "pakperk-api", vec![OidcAlgorithm::EdDsa]);
        let body = br#"{
            "issuer":"https://identity.example/realm",
            "jwks_uri":"http://identity.example/realm/keys"
        }"#;
        assert_eq!(
            parse_provider_metadata(&config, body),
            Err(OidcStartupError::InvalidProviderMetadata)
        );
    }

    #[tokio::test]
    async fn http_fetcher_refuses_redirects() {
        let app = Router::new().route(
            "/document",
            get(|| async {
                Response::builder()
                    .status(StatusCode::FOUND)
                    .header(LOCATION, "/elsewhere")
                    .body(Body::empty())
                    .unwrap()
            }),
        );
        let (base, server) = serve(app).await;
        let fetcher = HttpOidcDocumentFetcher::new(Duration::from_secs(1)).unwrap();

        assert_eq!(
            fetcher.fetch(&base.join("document").unwrap(), 1024).await,
            Err(DocumentFetchError::UnexpectedStatus)
        );
        server.abort();
    }

    #[tokio::test]
    async fn http_fetcher_enforces_response_size() {
        let app = Router::new().route("/document", get(|| async { "x".repeat(4096) }));
        let (base, server) = serve(app).await;
        let fetcher = HttpOidcDocumentFetcher::new(Duration::from_secs(1)).unwrap();

        assert_eq!(
            fetcher.fetch(&base.join("document").unwrap(), 128).await,
            Err(DocumentFetchError::TooLarge)
        );
        server.abort();
    }

    #[tokio::test]
    async fn http_fetcher_enforces_the_request_timeout() {
        let app = Router::new().route(
            "/document",
            get(|| async {
                tokio::time::sleep(Duration::from_millis(100)).await;
                "{}"
            }),
        );
        let (base, server) = serve(app).await;
        let fetcher = HttpOidcDocumentFetcher::new(Duration::from_millis(10)).unwrap();

        assert_eq!(
            fetcher.fetch(&base.join("document").unwrap(), 128).await,
            Err(DocumentFetchError::Network)
        );
        server.abort();
    }

    #[tokio::test]
    async fn discover_uses_the_bounded_document_client() {
        let base_slot = Arc::new(tokio::sync::OnceCell::<Url>::new());
        let slot = Arc::clone(&base_slot);
        let app = Router::new().route(
            "/realm/.well-known/openid-configuration",
            get(move || {
                let slot = Arc::clone(&slot);
                async move {
                    let base = slot.get().unwrap();
                    format!(r#"{{"issuer":"{base}realm","jwks_uri":"{base}keys"}}"#)
                }
            }),
        );
        let (base, server) = serve(app).await;
        base_slot.set(base.clone()).unwrap();
        let issuer = base.join("realm").unwrap();
        let config = config(issuer);
        let fetcher = Arc::new(HttpOidcDocumentFetcher::new(Duration::from_secs(1)).unwrap());

        let metadata = discover_provider(&config, fetcher).await.unwrap();
        assert_eq!(metadata.jwks_uri(), &base.join("keys").unwrap());
        server.abort();
    }
}
