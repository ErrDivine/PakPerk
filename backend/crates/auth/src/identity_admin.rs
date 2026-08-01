use std::{
    fmt, fs,
    io::Read as _,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use reqwest::{Client, Method, StatusCode, redirect::Policy};
use secrecy::{ExposeSecret as _, SecretString};
use serde::Deserialize;
use tokio::sync::Mutex;
use url::Url;

use crate::config::validate_url;

// Keycloak-generated user identifiers are non-nil UUIDs, and the adapter
// rejects nil as a real provider subject. The startup probe uses only this
// reserved identifier and therefore cannot return or mutate a real account.
const ADMIN_PERMISSION_PROBE_SUBJECT: &str = "00000000-0000-0000-0000-000000000000";

/// Whether an identity-administration adapter is safe to enable for account
/// deletion. Startup validation in the API must require `Functional` whenever
/// production deletion is enabled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityAdminReadiness {
    Functional,
    NotConfigured,
    Unwired,
}

/// Provider-neutral and sanitized identity administration failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum IdentityAdminError {
    #[error("identity administration is not configured")]
    NotConfigured,
    #[error("identity administration adapter is not implemented")]
    Unwired,
    #[error("identity provider administration is temporarily unavailable")]
    ProviderUnavailable,
    #[error("identity provider administration rejected its credentials")]
    Unauthorized,
    #[error("identity provider administration rejected the operation")]
    Rejected,
}

/// Destructive upstream operations are isolated from generic JWT validation.
/// Implementations must be idempotent when the identity or sessions are
/// already absent.
#[async_trait]
pub trait IdentityAdmin: Send + Sync {
    fn readiness(&self) -> IdentityAdminReadiness {
        IdentityAdminReadiness::Functional
    }

    async fn revoke_user_sessions(
        &self,
        issuer: &str,
        subject: &str,
    ) -> Result<(), IdentityAdminError>;

    async fn delete_identity(&self, issuer: &str, subject: &str) -> Result<(), IdentityAdminError>;
}

/// Explicitly incomplete local/test adapter. It never silently reports that a
/// destructive provider operation succeeded.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoopIdentityAdmin;

#[async_trait]
impl IdentityAdmin for NoopIdentityAdmin {
    fn readiness(&self) -> IdentityAdminReadiness {
        IdentityAdminReadiness::NotConfigured
    }

    async fn revoke_user_sessions(
        &self,
        _issuer: &str,
        _subject: &str,
    ) -> Result<(), IdentityAdminError> {
        Err(IdentityAdminError::NotConfigured)
    }

    async fn delete_identity(
        &self,
        _issuer: &str,
        _subject: &str,
    ) -> Result<(), IdentityAdminError> {
        Err(IdentityAdminError::NotConfigured)
    }
}

/// Non-secret Keycloak administration coordinates. The functional adapter
/// uses a confidential service account and bounded Admin REST calls; the
/// deletion worker supplies durable idempotency and retry semantics.
#[derive(Clone)]
pub struct KeycloakIdentityAdminConfig {
    pub admin_base_url: Url,
    /// Exact OIDC issuer accepted by the API. Provider operations refuse any
    /// verified identity from another issuer even if its subject looks valid.
    pub expected_issuer: Url,
    pub realm: String,
    pub client_id: String,
    /// Path to a mounted secret, never the client secret value itself.
    pub client_secret_file: PathBuf,
    pub allow_insecure_http: bool,
}

impl KeycloakIdentityAdminConfig {
    pub fn validate(&self) -> Result<(), IdentityAdminError> {
        validate_url(&self.admin_base_url, self.allow_insecure_http)
            .map_err(|()| IdentityAdminError::NotConfigured)?;
        validate_url(&self.expected_issuer, self.allow_insecure_http)
            .map_err(|()| IdentityAdminError::NotConfigured)?;
        if self.realm.is_empty()
            || self.realm.len() > 255
            || !self
                .realm
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
            || self.client_id.is_empty()
            || self.client_id.len() > 255
            || self.client_id.chars().any(char::is_control)
            || self.client_secret_file.as_os_str().is_empty()
        {
            return Err(IdentityAdminError::NotConfigured);
        }
        let issuer_realm_suffix = format!("/realms/{}", self.realm);
        if !self.expected_issuer.path().ends_with(&issuer_realm_suffix) {
            return Err(IdentityAdminError::NotConfigured);
        }
        Ok(())
    }
}

impl fmt::Debug for KeycloakIdentityAdminConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("KeycloakIdentityAdminConfig")
            .field("admin_base_url", &"[redacted]")
            .field("expected_issuer", &"[redacted]")
            .field("realm", &"[redacted]")
            .field("client_id", &"[redacted]")
            .field("client_secret_file", &"[redacted]")
            .field("allow_insecure_http", &self.allow_insecure_http)
            .finish()
    }
}

#[derive(Clone)]
pub struct KeycloakIdentityAdmin {
    config: KeycloakIdentityAdminConfig,
    client: Client,
    secret: SecretString,
    token: Arc<Mutex<Option<CachedToken>>>,
}

struct CachedToken {
    access_token: SecretString,
    refresh_at: Instant,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
    token_type: String,
}

impl KeycloakIdentityAdmin {
    pub fn new(config: KeycloakIdentityAdminConfig) -> Result<Self, IdentityAdminError> {
        config.validate()?;
        let secret = read_secret_file(&config.client_secret_file)?;
        let client = Client::builder()
            .redirect(Policy::none())
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|_| IdentityAdminError::NotConfigured)?;
        Ok(Self {
            config,
            client,
            secret,
            token: Arc::new(Mutex::new(None)),
        })
    }

    #[deprecated(note = "use KeycloakIdentityAdmin::new")]
    pub fn unwired(config: KeycloakIdentityAdminConfig) -> Result<Self, IdentityAdminError> {
        Self::new(config)
    }

    pub fn config(&self) -> &KeycloakIdentityAdminConfig {
        &self.config
    }

    /// Performs a client-credentials exchange followed by two
    /// non-destructive, permissioned reads of the reserved absent user UUID.
    /// Keycloak must return both the bounded direct-lookup 404 and a bounded,
    /// JSON `[]` from its exact ID search. The second response prevents a
    /// generic reverse-proxy 404 from being mistaken for a permission proof.
    pub async fn probe_permissions(&self) -> Result<(), IdentityAdminError> {
        let token = self.access_token(true).await?;
        let direct_response = self
            .client
            .get(self.user_url(ADMIN_PERMISSION_PROBE_SUBJECT, false)?)
            .bearer_auth(token.expose_secret())
            .send()
            .await
            .map_err(|_| IdentityAdminError::ProviderUnavailable)?;
        if direct_response.status() != StatusCode::NOT_FOUND {
            return Err(provider_status_error(direct_response.status()));
        }
        bounded_body(direct_response).await?;

        let search_response = self
            .client
            .get(self.users_url()?)
            .query(&[
                ("search", format!("id:{ADMIN_PERMISSION_PROBE_SUBJECT}")),
                ("first", "0".to_owned()),
                ("max", "1".to_owned()),
                ("briefRepresentation", "true".to_owned()),
            ])
            .bearer_auth(token.expose_secret())
            .send()
            .await
            .map_err(|_| IdentityAdminError::ProviderUnavailable)?;
        if search_response.status() != StatusCode::OK {
            return Err(provider_status_error(search_response.status()));
        }
        if !json_content_type(search_response.headers()) {
            return Err(IdentityAdminError::Rejected);
        }
        let body = bounded_body(search_response).await?;
        let matches: Vec<serde_json::Value> =
            serde_json::from_slice(&body).map_err(|_| IdentityAdminError::Rejected)?;
        if !matches.is_empty() {
            return Err(IdentityAdminError::Rejected);
        }
        Ok(())
    }

    fn validate_identity(&self, issuer: &str, subject: &str) -> Result<(), IdentityAdminError> {
        let issuer = Url::parse(issuer).map_err(|_| IdentityAdminError::Rejected)?;
        let subject_id =
            uuid::Uuid::parse_str(subject).map_err(|_| IdentityAdminError::Rejected)?;
        if issuer != self.config.expected_issuer
            || subject_id.is_nil()
            || subject_id.hyphenated().to_string() != subject
        {
            return Err(IdentityAdminError::Rejected);
        }
        Ok(())
    }

    fn token_url(&self) -> Result<Url, IdentityAdminError> {
        append_segments(
            &self.config.admin_base_url,
            &[
                "realms",
                &self.config.realm,
                "protocol",
                "openid-connect",
                "token",
            ],
        )
    }

    fn user_url(&self, subject: &str, logout: bool) -> Result<Url, IdentityAdminError> {
        let mut segments = vec!["admin", "realms", &self.config.realm, "users", subject];
        if logout {
            segments.push("logout");
        }
        append_segments(&self.config.admin_base_url, &segments)
    }

    fn users_url(&self) -> Result<Url, IdentityAdminError> {
        append_segments(
            &self.config.admin_base_url,
            &["admin", "realms", &self.config.realm, "users"],
        )
    }

    async fn access_token(&self, force_refresh: bool) -> Result<SecretString, IdentityAdminError> {
        let mut cache = self.token.lock().await;
        if !force_refresh
            && let Some(cached) = cache.as_ref()
            && Instant::now() < cached.refresh_at
        {
            return Ok(cached.access_token.clone());
        }
        let response = self
            .client
            .post(self.token_url()?)
            .basic_auth(&self.config.client_id, Some(self.secret.expose_secret()))
            .form(&[("grant_type", "client_credentials")])
            .send()
            .await
            .map_err(|_| IdentityAdminError::ProviderUnavailable)?;
        let status = response.status();
        if !status.is_success() {
            return Err(provider_status_error(status));
        }
        if !json_content_type(response.headers()) {
            return Err(IdentityAdminError::Rejected);
        }
        let bytes = bounded_body(response).await?;
        let parsed: TokenResponse =
            serde_json::from_slice(&bytes).map_err(|_| IdentityAdminError::Rejected)?;
        if parsed.access_token.is_empty()
            || parsed.access_token.len() > 16 * 1024
            || parsed
                .access_token
                .bytes()
                .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
            || parsed.expires_in < 5
            || parsed.expires_in > 24 * 60 * 60
            || !parsed.token_type.eq_ignore_ascii_case("bearer")
        {
            return Err(IdentityAdminError::Rejected);
        }
        let refresh_seconds = parsed.expires_in.saturating_sub(30).max(1);
        let token = SecretString::from(parsed.access_token);
        *cache = Some(CachedToken {
            access_token: token.clone(),
            refresh_at: Instant::now() + Duration::from_secs(refresh_seconds),
        });
        Ok(token)
    }

    async fn admin_operation(&self, method: Method, url: Url) -> Result<(), IdentityAdminError> {
        for refresh in [false, true] {
            let token = self.access_token(refresh).await?;
            let response = self
                .client
                .request(method.clone(), url.clone())
                .bearer_auth(token.expose_secret())
                .send()
                .await
                .map_err(|_| IdentityAdminError::ProviderUnavailable)?;
            let status = response.status();
            if status == StatusCode::UNAUTHORIZED && !refresh {
                *self.token.lock().await = None;
                continue;
            }
            // Keycloak returns 204 for success. A missing user/session is the
            // idempotent success case after response loss or admin replay.
            if status == StatusCode::NO_CONTENT || status == StatusCode::NOT_FOUND {
                bounded_body(response).await?;
                return Ok(());
            }
            return Err(provider_status_error(status));
        }
        Err(IdentityAdminError::Unauthorized)
    }
}

fn provider_status_error(status: StatusCode) -> IdentityAdminError {
    if matches!(status, StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) {
        IdentityAdminError::Unauthorized
    } else if matches!(
        status,
        StatusCode::REQUEST_TIMEOUT | StatusCode::TOO_MANY_REQUESTS
    ) || status.is_server_error()
    {
        IdentityAdminError::ProviderUnavailable
    } else {
        IdentityAdminError::Rejected
    }
}

impl fmt::Debug for KeycloakIdentityAdmin {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("KeycloakIdentityAdmin")
            .field("status", &"functional")
            .finish()
    }
}

#[async_trait]
impl IdentityAdmin for KeycloakIdentityAdmin {
    fn readiness(&self) -> IdentityAdminReadiness {
        IdentityAdminReadiness::Functional
    }

    async fn revoke_user_sessions(
        &self,
        issuer: &str,
        subject: &str,
    ) -> Result<(), IdentityAdminError> {
        self.validate_identity(issuer, subject)?;
        self.admin_operation(Method::POST, self.user_url(subject, true)?)
            .await
    }

    async fn delete_identity(&self, issuer: &str, subject: &str) -> Result<(), IdentityAdminError> {
        self.validate_identity(issuer, subject)?;
        self.admin_operation(Method::DELETE, self.user_url(subject, false)?)
            .await
    }
}

fn append_segments(base: &Url, segments: &[&str]) -> Result<Url, IdentityAdminError> {
    let mut url = base.clone();
    if url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(IdentityAdminError::NotConfigured);
    }
    {
        let mut path = url
            .path_segments_mut()
            .map_err(|()| IdentityAdminError::NotConfigured)?;
        path.pop_if_empty();
        for segment in segments {
            path.push(segment);
        }
    }
    Ok(url)
}

async fn bounded_body(mut response: reqwest::Response) -> Result<Vec<u8>, IdentityAdminError> {
    const MAXIMUM_BYTES: usize = 64 * 1024;
    if response
        .content_length()
        .is_some_and(|length| length > MAXIMUM_BYTES as u64)
    {
        return Err(IdentityAdminError::Rejected);
    }
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| IdentityAdminError::ProviderUnavailable)?
    {
        if body.len().saturating_add(chunk.len()) > MAXIMUM_BYTES {
            return Err(IdentityAdminError::Rejected);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn json_content_type(headers: &reqwest::header::HeaderMap) -> bool {
    let mut values = headers.get_all(reqwest::header::CONTENT_TYPE).iter();
    let Some(value) = values.next() else {
        return false;
    };
    if values.next().is_some() {
        return false;
    }
    value
        .to_str()
        .ok()
        .and_then(|value| value.split(';').next())
        .is_some_and(|media_type| media_type.trim().eq_ignore_ascii_case("application/json"))
}

fn read_secret_file(path: &PathBuf) -> Result<SecretString, IdentityAdminError> {
    let path_metadata =
        fs::symlink_metadata(path).map_err(|_| IdentityAdminError::NotConfigured)?;
    if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
        return Err(IdentityAdminError::NotConfigured);
    }
    let mut file = fs::File::open(path).map_err(|_| IdentityAdminError::NotConfigured)?;
    let metadata = file
        .metadata()
        .map_err(|_| IdentityAdminError::NotConfigured)?;
    if !metadata.is_file() || !(32..=4_096).contains(&metadata.len()) {
        return Err(IdentityAdminError::NotConfigured);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if path_metadata.dev() != metadata.dev()
            || path_metadata.ino() != metadata.ino()
            || metadata.mode() & 0o077 != 0
        {
            return Err(IdentityAdminError::NotConfigured);
        }
    }
    let expected_length = metadata.len();
    let mut bytes = Vec::with_capacity(usize::try_from(expected_length).unwrap_or(4_096));
    (&mut file)
        .take(4_097)
        .read_to_end(&mut bytes)
        .map_err(|_| IdentityAdminError::NotConfigured)?;
    let final_metadata = file
        .metadata()
        .map_err(|_| IdentityAdminError::NotConfigured)?;
    let final_path_metadata =
        fs::symlink_metadata(path).map_err(|_| IdentityAdminError::NotConfigured)?;
    if final_path_metadata.file_type().is_symlink()
        || !final_path_metadata.is_file()
        || !final_metadata.is_file()
        || final_metadata.len() != expected_length
        || final_path_metadata.len() != expected_length
        || u64::try_from(bytes.len()).ok() != Some(expected_length)
    {
        return Err(IdentityAdminError::NotConfigured);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if final_metadata.dev() != metadata.dev()
            || final_metadata.ino() != metadata.ino()
            || final_path_metadata.dev() != metadata.dev()
            || final_path_metadata.ino() != metadata.ino()
            || final_metadata.mode() & 0o077 != 0
            || final_path_metadata.mode() & 0o077 != 0
        {
            return Err(IdentityAdminError::NotConfigured);
        }
    }
    let value = String::from_utf8(bytes).map_err(|_| IdentityAdminError::NotConfigured)?;
    let value = value.trim_end_matches(['\r', '\n']);
    let lowercase = value.to_ascii_lowercase();
    if value.len() < 32
        || value.trim() != value
        || value.chars().any(char::is_control)
        || ["change-me", "changeme", "example", "placeholder"]
            .iter()
            .any(|marker| lowercase.contains(marker))
    {
        return Err(IdentityAdminError::NotConfigured);
    }
    Ok(SecretString::from(value.to_owned()))
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashMap,
        sync::atomic::{AtomicUsize, Ordering},
    };

    use axum::{
        Router,
        http::{Response, header::CONTENT_TYPE, header::LOCATION},
        routing::{delete, get, post},
    };
    use tokio::net::TcpListener;

    use super::*;

    const SUBJECT: &str = "0198f4d7-a4ce-7b40-8ee8-4f350350810c";

    async fn serve(app: Router) -> Option<(Url, tokio::task::JoinHandle<()>)> {
        let listener = TcpListener::bind("127.0.0.1:0").await.ok()?;
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Some((Url::parse(&format!("http://{address}/")).unwrap(), task))
    }

    fn test_adapter(base: &Url) -> KeycloakIdentityAdmin {
        let secret = tempfile::NamedTempFile::new().unwrap();
        fs::write(secret.path(), "unit-test-keycloak-client-secret-7J9q3Px4").unwrap();
        KeycloakIdentityAdmin::new(KeycloakIdentityAdminConfig {
            admin_base_url: base.clone(),
            expected_issuer: base.join("realms/pakperk").unwrap(),
            realm: "pakperk".into(),
            client_id: "pakperk-admin".into(),
            client_secret_file: secret.path().into(),
            allow_insecure_http: true,
        })
        .unwrap()
    }

    fn token_response(token: &str) -> Response<String> {
        Response::builder()
            .status(StatusCode::OK)
            .header(CONTENT_TYPE, "application/json; charset=utf-8")
            .body(format!(
                r#"{{"access_token":"{token}","expires_in":300,"token_type":"Bearer"}}"#
            ))
            .unwrap()
    }

    #[tokio::test]
    async fn noop_never_fakes_destructive_success() {
        let adapter = NoopIdentityAdmin;
        assert_eq!(adapter.readiness(), IdentityAdminReadiness::NotConfigured);
        assert_eq!(
            adapter
                .revoke_user_sessions("private-issuer", "private-subject")
                .await,
            Err(IdentityAdminError::NotConfigured)
        );
        assert_eq!(
            adapter
                .delete_identity("private-issuer", "private-subject")
                .await,
            Err(IdentityAdminError::NotConfigured)
        );
    }

    #[tokio::test]
    async fn keycloak_adapter_is_functional_and_issuer_bound() {
        let secret = tempfile::NamedTempFile::new().unwrap();
        fs::write(secret.path(), "unit-test-keycloak-client-secret-7J9q3Px4").unwrap();
        let adapter = KeycloakIdentityAdmin::new(KeycloakIdentityAdminConfig {
            admin_base_url: Url::parse("https://identity-admin.example/").unwrap(),
            expected_issuer: Url::parse("https://identity.example/realms/pakperk").unwrap(),
            realm: "pakperk".into(),
            client_id: "pakperk-admin".into(),
            client_secret_file: secret.path().into(),
            allow_insecure_http: false,
        })
        .unwrap();
        assert_eq!(adapter.readiness(), IdentityAdminReadiness::Functional);
        assert_eq!(
            adapter
                .delete_identity(
                    "https://other.example/realms/pakperk",
                    "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
                )
                .await,
            Err(IdentityAdminError::Rejected)
        );
        assert_eq!(
            adapter
                .delete_identity("https://identity.example/realms/pakperk", "NOT-A-UUID")
                .await,
            Err(IdentityAdminError::Rejected)
        );
        assert_eq!(
            adapter
                .delete_identity(
                    "https://identity.example/realms/pakperk",
                    ADMIN_PERMISSION_PROBE_SUBJECT,
                )
                .await,
            Err(IdentityAdminError::Rejected)
        );
        assert_eq!(
            adapter
                .delete_identity(
                    "https://identity.example/realms/pakperk",
                    "0198F4D7-A4CE-7B40-8EE8-4F350350810C",
                )
                .await,
            Err(IdentityAdminError::Rejected)
        );
        let rendered = format!("{:?}", adapter.config());
        assert!(!rendered.contains("identity-admin.example"));
        assert!(!rendered.contains("pakperk-admin"));
        assert!(!rendered.contains("/run/secrets"));
    }

    #[test]
    fn keycloak_coordinates_require_explicit_local_http_override() {
        let mut config = KeycloakIdentityAdminConfig {
            admin_base_url: Url::parse("http://localhost:8080/").unwrap(),
            expected_issuer: Url::parse("http://localhost:8080/realms/pakperk").unwrap(),
            realm: "pakperk".into(),
            client_id: "pakperk-admin".into(),
            client_secret_file: "/run/secrets/keycloak-admin-client".into(),
            allow_insecure_http: false,
        };
        assert_eq!(config.validate(), Err(IdentityAdminError::NotConfigured));
        config.allow_insecure_http = true;
        assert_eq!(config.validate(), Ok(()));
        config.admin_base_url = Url::parse("http://keycloak:8080/").unwrap();
        assert_eq!(config.validate(), Err(IdentityAdminError::NotConfigured));
    }

    #[test]
    fn keycloak_issuer_must_end_in_the_configured_realm() {
        let config = KeycloakIdentityAdminConfig {
            admin_base_url: Url::parse("https://identity-admin.example/").unwrap(),
            expected_issuer: Url::parse("https://identity.example/realms/other").unwrap(),
            realm: "pakperk".into(),
            client_id: "pakperk-admin".into(),
            client_secret_file: "/run/secrets/keycloak-admin-client".into(),
            allow_insecure_http: false,
        };
        assert_eq!(config.validate(), Err(IdentityAdminError::NotConfigured));
    }

    #[tokio::test]
    async fn token_fetch_is_single_flight_cached_and_provider_absence_is_idempotent() {
        let token_calls = Arc::new(AtomicUsize::new(0));
        let admin_calls = Arc::new(AtomicUsize::new(0));
        let token_counter = Arc::clone(&token_calls);
        let logout_counter = Arc::clone(&admin_calls);
        let delete_counter = Arc::clone(&admin_calls);
        let app = Router::new()
            .route(
                "/realms/pakperk/protocol/openid-connect/token",
                post(move || {
                    let token_counter = Arc::clone(&token_counter);
                    async move {
                        token_counter.fetch_add(1, Ordering::SeqCst);
                        token_response("provider-token")
                    }
                }),
            )
            .route(
                "/admin/realms/pakperk/users/{subject}/logout",
                post(move || {
                    let logout_counter = Arc::clone(&logout_counter);
                    async move {
                        logout_counter.fetch_add(1, Ordering::SeqCst);
                        StatusCode::NO_CONTENT
                    }
                }),
            )
            .route(
                "/admin/realms/pakperk/users/{subject}",
                delete(move || {
                    let delete_counter = Arc::clone(&delete_counter);
                    async move {
                        delete_counter.fetch_add(1, Ordering::SeqCst);
                        StatusCode::NOT_FOUND
                    }
                }),
            );
        let Some((base, server)) = serve(app).await else {
            return;
        };
        let adapter = Arc::new(test_adapter(&base));
        let issuer = base.join("realms/pakperk").unwrap().to_string();
        let (first, second) = tokio::join!(
            adapter.revoke_user_sessions(&issuer, SUBJECT),
            adapter.revoke_user_sessions(&issuer, SUBJECT),
        );
        assert_eq!(first, Ok(()));
        assert_eq!(second, Ok(()));
        assert_eq!(adapter.delete_identity(&issuer, SUBJECT).await, Ok(()));
        assert_eq!(token_calls.load(Ordering::SeqCst), 1);
        assert_eq!(admin_calls.load(Ordering::SeqCst), 3);
        server.abort();
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)] // Keep the complete fail-closed HTTP status matrix together.
    async fn permission_probe_is_non_destructive_and_accepts_only_bounded_absence() {
        for (token_status, probe_status, oversized_probe_body, expected) in [
            (StatusCode::OK, StatusCode::NOT_FOUND, false, Ok(())),
            (
                StatusCode::UNAUTHORIZED,
                StatusCode::NOT_FOUND,
                false,
                Err(IdentityAdminError::Unauthorized),
            ),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                StatusCode::NOT_FOUND,
                false,
                Err(IdentityAdminError::ProviderUnavailable),
            ),
            (
                StatusCode::REQUEST_TIMEOUT,
                StatusCode::NOT_FOUND,
                false,
                Err(IdentityAdminError::ProviderUnavailable),
            ),
            (
                StatusCode::OK,
                StatusCode::UNAUTHORIZED,
                false,
                Err(IdentityAdminError::Unauthorized),
            ),
            (
                StatusCode::OK,
                StatusCode::FORBIDDEN,
                false,
                Err(IdentityAdminError::Unauthorized),
            ),
            (
                StatusCode::OK,
                StatusCode::TOO_MANY_REQUESTS,
                false,
                Err(IdentityAdminError::ProviderUnavailable),
            ),
            (
                StatusCode::OK,
                StatusCode::INTERNAL_SERVER_ERROR,
                false,
                Err(IdentityAdminError::ProviderUnavailable),
            ),
            (
                StatusCode::OK,
                StatusCode::REQUEST_TIMEOUT,
                false,
                Err(IdentityAdminError::ProviderUnavailable),
            ),
            (
                StatusCode::OK,
                StatusCode::OK,
                false,
                Err(IdentityAdminError::Rejected),
            ),
            (
                StatusCode::OK,
                StatusCode::NO_CONTENT,
                false,
                Err(IdentityAdminError::Rejected),
            ),
            (
                StatusCode::OK,
                StatusCode::FOUND,
                false,
                Err(IdentityAdminError::Rejected),
            ),
            (
                StatusCode::OK,
                StatusCode::BAD_REQUEST,
                false,
                Err(IdentityAdminError::Rejected),
            ),
            (
                StatusCode::OK,
                StatusCode::NOT_FOUND,
                true,
                Err(IdentityAdminError::Rejected),
            ),
        ] {
            let probe_calls = Arc::new(AtomicUsize::new(0));
            let search_calls = Arc::new(AtomicUsize::new(0));
            let destructive_calls = Arc::new(AtomicUsize::new(0));
            let observed_probe_subject = Arc::new(Mutex::new(None));
            let observed_search_query = Arc::new(Mutex::new(None));
            let probe_counter = Arc::clone(&probe_calls);
            let search_counter = Arc::clone(&search_calls);
            let observed_subject = Arc::clone(&observed_probe_subject);
            let observed_query = Arc::clone(&observed_search_query);
            let logout_calls = Arc::clone(&destructive_calls);
            let delete_calls = Arc::clone(&destructive_calls);
            let app = Router::new()
                .route(
                    "/realms/pakperk/protocol/openid-connect/token",
                    post(move || async move {
                        if token_status == StatusCode::OK {
                            token_response("startup-probe-token")
                        } else {
                            Response::builder()
                                .status(token_status)
                                .body("provider diagnostic must stay private".to_owned())
                                .unwrap()
                        }
                    }),
                )
                .route(
                    "/admin/realms/pakperk/users/{subject}/logout",
                    post(move || {
                        let logout_calls = Arc::clone(&logout_calls);
                        async move {
                            logout_calls.fetch_add(1, Ordering::SeqCst);
                            StatusCode::NO_CONTENT
                        }
                    }),
                )
                .route(
                    "/admin/realms/pakperk/users",
                    get(
                        move |axum::extract::Query(query): axum::extract::Query<
                            HashMap<String, String>,
                        >| {
                            let search_counter = Arc::clone(&search_counter);
                            let observed_query = Arc::clone(&observed_query);
                            async move {
                                search_counter.fetch_add(1, Ordering::SeqCst);
                                *observed_query.lock().await = Some(query);
                                Response::builder()
                                    .status(StatusCode::OK)
                                    .header(CONTENT_TYPE, "application/json")
                                    .body("[]".to_owned())
                                    .unwrap()
                            }
                        },
                    ),
                )
                .route(
                    "/admin/realms/pakperk/users/{subject}",
                    get(
                        move |axum::extract::Path(subject): axum::extract::Path<String>| {
                            let probe_counter = Arc::clone(&probe_counter);
                            let observed_subject = Arc::clone(&observed_subject);
                            async move {
                                probe_counter.fetch_add(1, Ordering::SeqCst);
                                *observed_subject.lock().await = Some(subject);
                                let mut response = Response::builder().status(probe_status);
                                if probe_status.is_redirection() {
                                    response = response.header(LOCATION, "/redirected");
                                }
                                response
                                    .body(if oversized_probe_body {
                                        "x".repeat(64 * 1024 + 1)
                                    } else {
                                        String::new()
                                    })
                                    .unwrap()
                            }
                        },
                    )
                    .delete(move || {
                        let delete_calls = Arc::clone(&delete_calls);
                        async move {
                            delete_calls.fetch_add(1, Ordering::SeqCst);
                            StatusCode::NO_CONTENT
                        }
                    }),
                )
                .route("/redirected", get(|| async { StatusCode::NOT_FOUND }));
            let Some((base, server)) = serve(app).await else {
                return;
            };
            let adapter = test_adapter(&base);
            let result = adapter.probe_permissions().await;
            assert_eq!(result, expected);
            let expected_probe_calls = usize::from(token_status == StatusCode::OK);
            let expected_search_calls = usize::from(
                token_status == StatusCode::OK
                    && probe_status == StatusCode::NOT_FOUND
                    && !oversized_probe_body,
            );
            assert_eq!(probe_calls.load(Ordering::SeqCst), expected_probe_calls);
            assert_eq!(search_calls.load(Ordering::SeqCst), expected_search_calls);
            assert_eq!(destructive_calls.load(Ordering::SeqCst), 0);
            if expected_probe_calls == 1 {
                assert_eq!(
                    observed_probe_subject.lock().await.as_deref(),
                    Some(ADMIN_PERMISSION_PROBE_SUBJECT)
                );
            }
            if expected_search_calls == 1 {
                let query = observed_search_query.lock().await;
                let query = query.as_ref().unwrap();
                assert_eq!(
                    query.get("search").map(String::as_str),
                    Some("id:00000000-0000-0000-0000-000000000000")
                );
                assert_eq!(query.get("first").map(String::as_str), Some("0"));
                assert_eq!(query.get("max").map(String::as_str), Some("1"));
                assert_eq!(
                    query.get("briefRepresentation").map(String::as_str),
                    Some("true")
                );
            }
            assert!(!format!("{result:?}").contains("provider diagnostic"));
            server.abort();
        }
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)] // Exercise every fail-closed origin-proof response shape together.
    async fn permission_probe_rejects_generic_404_and_invalid_exact_search_responses() {
        let oversized = "x".repeat(64 * 1024 + 1);
        for (status, content_type, body, expected) in [
            (
                StatusCode::NOT_FOUND,
                None,
                String::new(),
                IdentityAdminError::Rejected,
            ),
            (
                StatusCode::UNAUTHORIZED,
                None,
                String::new(),
                IdentityAdminError::Unauthorized,
            ),
            (
                StatusCode::FORBIDDEN,
                None,
                String::new(),
                IdentityAdminError::Unauthorized,
            ),
            (
                StatusCode::REQUEST_TIMEOUT,
                None,
                String::new(),
                IdentityAdminError::ProviderUnavailable,
            ),
            (
                StatusCode::TOO_MANY_REQUESTS,
                None,
                String::new(),
                IdentityAdminError::ProviderUnavailable,
            ),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                None,
                String::new(),
                IdentityAdminError::ProviderUnavailable,
            ),
            (
                StatusCode::FOUND,
                None,
                String::new(),
                IdentityAdminError::Rejected,
            ),
            (
                StatusCode::OK,
                Some("text/plain"),
                "[]".to_owned(),
                IdentityAdminError::Rejected,
            ),
            (
                StatusCode::OK,
                Some("application/json"),
                "{}".to_owned(),
                IdentityAdminError::Rejected,
            ),
            (
                StatusCode::OK,
                Some("application/json"),
                "[{}]".to_owned(),
                IdentityAdminError::Rejected,
            ),
            (
                StatusCode::OK,
                Some("application/json"),
                oversized,
                IdentityAdminError::Rejected,
            ),
        ] {
            let search_calls = Arc::new(AtomicUsize::new(0));
            let destructive_calls = Arc::new(AtomicUsize::new(0));
            let search_counter = Arc::clone(&search_calls);
            let delete_calls = Arc::clone(&destructive_calls);
            let logout_calls = Arc::clone(&destructive_calls);
            let body = Arc::<str>::from(body);
            let app = Router::new()
                .route(
                    "/realms/pakperk/protocol/openid-connect/token",
                    post(|| async { token_response("startup-probe-token") }),
                )
                .route(
                    "/admin/realms/pakperk/users",
                    get(move || {
                        let search_counter = Arc::clone(&search_counter);
                        let body = Arc::clone(&body);
                        async move {
                            search_counter.fetch_add(1, Ordering::SeqCst);
                            let mut response = Response::builder().status(status);
                            if let Some(content_type) = content_type {
                                response = response.header(CONTENT_TYPE, content_type);
                            }
                            if status.is_redirection() {
                                response = response.header(LOCATION, "/redirected");
                            }
                            response.body(body.to_string()).unwrap()
                        }
                    }),
                )
                .route(
                    "/admin/realms/pakperk/users/{subject}/logout",
                    post(move || {
                        let logout_calls = Arc::clone(&logout_calls);
                        async move {
                            logout_calls.fetch_add(1, Ordering::SeqCst);
                            StatusCode::NO_CONTENT
                        }
                    }),
                )
                .route(
                    "/admin/realms/pakperk/users/{subject}",
                    get(|| async { StatusCode::NOT_FOUND }).delete(move || {
                        let delete_calls = Arc::clone(&delete_calls);
                        async move {
                            delete_calls.fetch_add(1, Ordering::SeqCst);
                            StatusCode::NO_CONTENT
                        }
                    }),
                )
                .route(
                    "/redirected",
                    get(|| async {
                        Response::builder()
                            .status(StatusCode::OK)
                            .header(CONTENT_TYPE, "application/json")
                            .body("[]".to_owned())
                            .unwrap()
                    }),
                );
            let Some((base, server)) = serve(app).await else {
                return;
            };
            let result = test_adapter(&base).probe_permissions().await;
            assert_eq!(result, Err(expected));
            assert_eq!(search_calls.load(Ordering::SeqCst), 1);
            assert_eq!(destructive_calls.load(Ordering::SeqCst), 0);
            server.abort();
        }
    }

    #[tokio::test]
    async fn one_unauthorized_operation_refreshes_once_then_returns_unauthorized() {
        let token_calls = Arc::new(AtomicUsize::new(0));
        let admin_calls = Arc::new(AtomicUsize::new(0));
        let token_counter = Arc::clone(&token_calls);
        let admin_counter = Arc::clone(&admin_calls);
        let app = Router::new()
            .route(
                "/realms/pakperk/protocol/openid-connect/token",
                post(move || {
                    let token_counter = Arc::clone(&token_counter);
                    async move {
                        let generation = token_counter.fetch_add(1, Ordering::SeqCst) + 1;
                        token_response(&format!("provider-token-{generation}"))
                    }
                }),
            )
            .route(
                "/admin/realms/pakperk/users/{subject}",
                delete(move || {
                    let admin_counter = Arc::clone(&admin_counter);
                    async move {
                        admin_counter.fetch_add(1, Ordering::SeqCst);
                        StatusCode::UNAUTHORIZED
                    }
                }),
            );
        let Some((base, server)) = serve(app).await else {
            return;
        };
        let adapter = test_adapter(&base);
        let issuer = base.join("realms/pakperk").unwrap().to_string();
        assert_eq!(
            adapter.delete_identity(&issuer, SUBJECT).await,
            Err(IdentityAdminError::Unauthorized)
        );
        assert_eq!(token_calls.load(Ordering::SeqCst), 2);
        assert_eq!(admin_calls.load(Ordering::SeqCst), 2);
        server.abort();
    }

    #[tokio::test]
    async fn provider_statuses_are_classified_without_exposing_bodies() {
        for (status, expected) in [
            (StatusCode::FORBIDDEN, IdentityAdminError::Unauthorized),
            (
                StatusCode::REQUEST_TIMEOUT,
                IdentityAdminError::ProviderUnavailable,
            ),
            (
                StatusCode::TOO_MANY_REQUESTS,
                IdentityAdminError::ProviderUnavailable,
            ),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                IdentityAdminError::ProviderUnavailable,
            ),
        ] {
            let app = Router::new()
                .route(
                    "/realms/pakperk/protocol/openid-connect/token",
                    post(|| async { token_response("provider-token") }),
                )
                .route(
                    "/admin/realms/pakperk/users/{subject}",
                    delete(move || async move {
                        Response::builder()
                            .status(status)
                            .body("secret provider diagnostic".to_owned())
                            .unwrap()
                    }),
                );
            let Some((base, server)) = serve(app).await else {
                return;
            };
            let adapter = test_adapter(&base);
            let issuer = base.join("realms/pakperk").unwrap().to_string();
            let error = adapter.delete_identity(&issuer, SUBJECT).await.unwrap_err();
            assert_eq!(error, expected);
            assert!(!format!("{error:?} {error}").contains("provider diagnostic"));
            server.abort();
        }
    }

    #[tokio::test]
    async fn token_redirect_content_type_shape_and_size_fail_closed() {
        let oversized = "x".repeat(64 * 1024 + 1);
        let cases = vec![
            Response::builder()
                .status(StatusCode::FOUND)
                .header(reqwest::header::LOCATION, "/redirected")
                .body(String::new())
                .unwrap(),
            Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, "text/plain")
                .body(
                    r#"{"access_token":"token","expires_in":300,"token_type":"Bearer"}"#.to_owned(),
                )
                .unwrap(),
            Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, "application/json")
                .body(r#"{"access_token":"token","expires_in":300}"#.to_owned())
                .unwrap(),
            Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, "application/json")
                .body("{".to_owned())
                .unwrap(),
            Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, "application/json")
                .body(oversized)
                .unwrap(),
        ];
        for response in cases {
            let response = Arc::new(Mutex::new(Some(response)));
            let response_state = Arc::clone(&response);
            let app = Router::new().route(
                "/realms/pakperk/protocol/openid-connect/token",
                post(move || {
                    let response_state = Arc::clone(&response_state);
                    async move { response_state.lock().await.take().unwrap() }
                }),
            );
            let Some((base, server)) = serve(app).await else {
                return;
            };
            let adapter = test_adapter(&base);
            let issuer = base.join("realms/pakperk").unwrap().to_string();
            assert_eq!(
                adapter.delete_identity(&issuer, SUBJECT).await,
                Err(IdentityAdminError::Rejected)
            );
            server.abort();
        }
    }

    #[tokio::test]
    async fn network_failure_is_retryable() {
        let Ok(listener) = TcpListener::bind("127.0.0.1:0").await else {
            return;
        };
        let address = listener.local_addr().unwrap();
        drop(listener);
        let base = Url::parse(&format!("http://{address}/")).unwrap();
        let adapter = test_adapter(&base);
        let issuer = base.join("realms/pakperk").unwrap().to_string();
        assert_eq!(
            adapter.delete_identity(&issuer, SUBJECT).await,
            Err(IdentityAdminError::ProviderUnavailable)
        );
    }

    #[test]
    fn secret_file_must_remain_owner_only() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;

            let secret = tempfile::NamedTempFile::new().unwrap();
            fs::write(secret.path(), "unit-test-secret-that-is-long-enough-1234").unwrap();
            fs::set_permissions(secret.path(), fs::Permissions::from_mode(0o644)).unwrap();
            assert!(matches!(
                read_secret_file(&secret.path().to_path_buf()),
                Err(IdentityAdminError::NotConfigured)
            ));
        }
    }
}
