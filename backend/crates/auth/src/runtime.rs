use std::{
    fmt,
    sync::{Arc, RwLock},
    time::Duration,
};

use crate::{OidcJwtVerifier, OidcStartupError, OidcVerifierConfig, TokenVerifier};

/// Sanitized reason an enabled authentication boundary is not ready.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthUnavailableReason {
    InvalidConfiguration,
    ProviderUnavailable,
    InvalidProviderMetadata,
    InvalidSigningKeys,
}

impl From<OidcStartupError> for AuthUnavailableReason {
    fn from(error: OidcStartupError) -> Self {
        match error {
            OidcStartupError::InvalidConfiguration => Self::InvalidConfiguration,
            OidcStartupError::ProviderUnavailable => Self::ProviderUnavailable,
            OidcStartupError::InvalidProviderMetadata => Self::InvalidProviderMetadata,
            OidcStartupError::InvalidSigningKeys => Self::InvalidSigningKeys,
        }
    }
}

/// Copyable public view of the authentication boundary. It contains no token,
/// identity, key, issuer, or verifier material.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthRuntimeStatus {
    Disabled,
    Unavailable {
        reason: AuthUnavailableReason,
        retry_after: Duration,
    },
    Ready,
}

enum RuntimeState {
    Disabled,
    Unavailable {
        reason: AuthUnavailableReason,
        retry_after: Duration,
    },
    Ready(Arc<dyn TokenVerifier>),
}

/// Cloneable, atomically publishable authentication readiness handle.
///
/// The API can install this handle into an Axum router while discovery is
/// unavailable. A bounded background retry later calls `publish_ready` without
/// rebuilding the router. Public guest routes remain independent; account
/// routes inspect `status`/`verifier` and fail closed while unavailable.
#[derive(Clone)]
pub struct AuthRuntime {
    state: Arc<RwLock<RuntimeState>>,
}

impl AuthRuntime {
    pub fn disabled() -> Self {
        Self::from_state(RuntimeState::Disabled)
    }

    pub fn ready(verifier: Arc<dyn TokenVerifier>) -> Self {
        Self::from_state(RuntimeState::Ready(verifier))
    }

    pub fn unavailable(reason: AuthUnavailableReason, retry_after: Duration) -> Self {
        Self::from_state(RuntimeState::Unavailable {
            reason,
            retry_after,
        })
    }

    fn from_state(state: RuntimeState) -> Self {
        Self {
            state: Arc::new(RwLock::new(state)),
        }
    }

    /// Initialize authentication without making OIDC availability a condition
    /// of serving public guest routes. Deployment code can still choose to
    /// reject `InvalidConfiguration` as an operator error.
    pub async fn initialize(
        enabled: bool,
        config: OidcVerifierConfig,
        retry_after: Duration,
    ) -> Self {
        if !enabled {
            return Self::disabled();
        }
        match OidcJwtVerifier::discover(config).await {
            Ok(verifier) => Self::ready(Arc::new(verifier)),
            Err(error) => Self::unavailable(error.into(), retry_after),
        }
    }

    /// Atomically publishes a verifier after a successful background retry.
    pub fn publish_ready(&self, verifier: Arc<dyn TokenVerifier>) {
        *self.write_state() = RuntimeState::Ready(verifier);
    }

    /// Atomically fails account routes closed after a refresh/discovery outage.
    pub fn publish_unavailable(&self, reason: AuthUnavailableReason, retry_after: Duration) {
        *self.write_state() = RuntimeState::Unavailable {
            reason,
            retry_after,
        };
    }

    pub fn disable(&self) {
        *self.write_state() = RuntimeState::Disabled;
    }

    pub fn status(&self) -> AuthRuntimeStatus {
        match &*self.read_state() {
            RuntimeState::Disabled => AuthRuntimeStatus::Disabled,
            RuntimeState::Unavailable {
                reason,
                retry_after,
            } => AuthRuntimeStatus::Unavailable {
                reason: *reason,
                retry_after: *retry_after,
            },
            RuntimeState::Ready(_) => AuthRuntimeStatus::Ready,
        }
    }

    pub fn is_enabled(&self) -> bool {
        !matches!(self.status(), AuthRuntimeStatus::Disabled)
    }

    pub fn is_ready(&self) -> bool {
        matches!(self.status(), AuthRuntimeStatus::Ready)
    }

    /// Returns a cloned verifier so no synchronization guard is held across an
    /// async signature-verification call.
    pub fn verifier(&self) -> Option<Arc<dyn TokenVerifier>> {
        match &*self.read_state() {
            RuntimeState::Ready(verifier) => Some(Arc::clone(verifier)),
            RuntimeState::Disabled | RuntimeState::Unavailable { .. } => None,
        }
    }

    fn read_state(&self) -> std::sync::RwLockReadGuard<'_, RuntimeState> {
        self.state
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn write_state(&self) -> std::sync::RwLockWriteGuard<'_, RuntimeState> {
        self.state
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl fmt::Debug for AuthRuntime {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("AuthRuntime")
            .field(&self.status())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use chrono::{TimeZone as _, Utc};

    use super::*;
    use crate::{VerifiedOidcClaims, VerifyError};

    struct DeterministicVerifier;

    #[async_trait]
    impl TokenVerifier for DeterministicVerifier {
        async fn verify(&self, _bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError> {
            Ok(VerifiedOidcClaims::new(
                "issuer".into(),
                "subject".into(),
                vec!["audience".into()],
                Utc.timestamp_opt(1_800_000_000, 0).unwrap(),
                None,
                None,
            ))
        }
    }

    #[tokio::test]
    async fn ready_runtime_exposes_the_testable_verifier_seam() {
        let runtime = AuthRuntime::ready(Arc::new(DeterministicVerifier));
        assert!(runtime.is_enabled());
        assert!(runtime.is_ready());
        let claims = runtime
            .verifier()
            .unwrap()
            .verify("opaque-token")
            .await
            .unwrap();
        assert_eq!(claims.subject(), "subject");
        assert_eq!(runtime.status(), AuthRuntimeStatus::Ready);
    }

    #[tokio::test]
    async fn cloned_router_handle_observes_background_publication() {
        let runtime = AuthRuntime::unavailable(
            AuthUnavailableReason::ProviderUnavailable,
            Duration::from_secs(5),
        );
        let router_handle = runtime.clone();
        assert!(router_handle.verifier().is_none());

        runtime.publish_ready(Arc::new(DeterministicVerifier));
        assert_eq!(router_handle.status(), AuthRuntimeStatus::Ready);
        assert!(router_handle.verifier().is_some());

        router_handle.publish_unavailable(
            AuthUnavailableReason::InvalidSigningKeys,
            Duration::from_secs(10),
        );
        assert_eq!(
            runtime.status(),
            AuthRuntimeStatus::Unavailable {
                reason: AuthUnavailableReason::InvalidSigningKeys,
                retry_after: Duration::from_secs(10)
            }
        );
    }

    #[test]
    fn unavailable_and_disabled_are_distinct() {
        let unavailable = AuthRuntime::unavailable(
            AuthUnavailableReason::ProviderUnavailable,
            Duration::from_secs(5),
        );
        assert!(unavailable.is_enabled());
        assert!(!unavailable.is_ready());
        assert!(unavailable.verifier().is_none());

        let disabled = AuthRuntime::disabled();
        assert!(!disabled.is_enabled());
        assert!(!disabled.is_ready());
        assert_eq!(disabled.status(), AuthRuntimeStatus::Disabled);
    }
}
