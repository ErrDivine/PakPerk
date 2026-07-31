use std::{fmt, path::PathBuf};

use async_trait::async_trait;
use url::Url;

use crate::config::validate_url;

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

/// Non-secret Keycloak administration coordinates. Credential acquisition and
/// the actual Admin REST calls intentionally remain unwired until the Phase 6
/// deletion state machine can provide idempotency and retry semantics.
#[derive(Clone)]
pub struct KeycloakIdentityAdminConfig {
    pub admin_base_url: Url,
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
        if self.realm.is_empty()
            || self.realm.len() > 255
            || self.realm.chars().any(char::is_control)
            || self.client_id.is_empty()
            || self.client_id.len() > 255
            || self.client_id.chars().any(char::is_control)
            || self.client_secret_file.as_os_str().is_empty()
        {
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
            .field("realm", &"[redacted]")
            .field("client_id", &"[redacted]")
            .field("client_secret_file", &"[redacted]")
            .field("allow_insecure_http", &self.allow_insecure_http)
            .finish()
    }
}

/// Honest Phase 3 adapter skeleton. Constructing it validates coordinates, but
/// its operations return `Unwired` until Phase 6 supplies credential loading,
/// provider calls, bounded retries, and deletion idempotency.
#[derive(Clone)]
pub struct KeycloakIdentityAdmin {
    config: KeycloakIdentityAdminConfig,
}

impl KeycloakIdentityAdmin {
    pub fn unwired(config: KeycloakIdentityAdminConfig) -> Result<Self, IdentityAdminError> {
        config.validate()?;
        Ok(Self { config })
    }

    pub fn config(&self) -> &KeycloakIdentityAdminConfig {
        &self.config
    }
}

impl fmt::Debug for KeycloakIdentityAdmin {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("KeycloakIdentityAdmin")
            .field("status", &"unwired")
            .finish()
    }
}

#[async_trait]
impl IdentityAdmin for KeycloakIdentityAdmin {
    fn readiness(&self) -> IdentityAdminReadiness {
        IdentityAdminReadiness::Unwired
    }

    async fn revoke_user_sessions(
        &self,
        _issuer: &str,
        _subject: &str,
    ) -> Result<(), IdentityAdminError> {
        Err(IdentityAdminError::Unwired)
    }

    async fn delete_identity(
        &self,
        _issuer: &str,
        _subject: &str,
    ) -> Result<(), IdentityAdminError> {
        Err(IdentityAdminError::Unwired)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    async fn keycloak_skeleton_is_validated_but_honestly_unwired() {
        let adapter = KeycloakIdentityAdmin::unwired(KeycloakIdentityAdminConfig {
            admin_base_url: Url::parse("https://identity-admin.example/").unwrap(),
            realm: "pakperk".into(),
            client_id: "pakperk-admin".into(),
            client_secret_file: "/run/secrets/keycloak-admin-client".into(),
            allow_insecure_http: false,
        })
        .unwrap();
        assert_eq!(adapter.readiness(), IdentityAdminReadiness::Unwired);
        assert_eq!(
            adapter
                .delete_identity("private-issuer", "private-subject")
                .await,
            Err(IdentityAdminError::Unwired)
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
}
