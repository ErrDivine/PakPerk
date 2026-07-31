//! Non-blocking authentication bootstrap for account-enabled deployments.

use std::sync::Arc;

use auth::{AuthRuntime, AuthRuntimeStatus, OidcJwtVerifier};
use tokio::task::JoinHandle;
use tracing::{info, warn};

use crate::AccountFeatureConfig;

/// Performs one timeout-bounded discovery attempt. Failure intentionally does
/// not prevent the public API from starting; required account routes inspect
/// the returned runtime and fail closed until recovery succeeds.
pub async fn initialize_auth_runtime(config: Option<&AccountFeatureConfig>) -> AuthRuntime {
    let Some(config) = config else {
        return AuthRuntime::disabled();
    };
    AuthRuntime::initialize(true, config.oidc.clone(), config.auth_retry_initial).await
}

/// Starts bounded exponential discovery retries only while an enabled runtime
/// is unavailable. A successful verifier is atomically published into the
/// already-running router.
pub fn spawn_auth_recovery(
    runtime: AuthRuntime,
    config: &AccountFeatureConfig,
) -> Option<JoinHandle<()>> {
    if !matches!(runtime.status(), AuthRuntimeStatus::Unavailable { .. }) {
        return None;
    }
    let oidc = config.oidc.clone();
    let initial = config.auth_retry_initial;
    let maximum = config.auth_retry_maximum;
    Some(tokio::spawn(async move {
        let base_ceiling = maximum.saturating_sub(std::time::Duration::from_millis(1));
        let mut base_delay = initial.min(base_ceiling);
        let mut delay = add_positive_jitter(base_delay, maximum, rand::random());
        if let AuthRuntimeStatus::Unavailable { reason, .. } = runtime.status() {
            runtime.publish_unavailable(reason, delay);
        }
        loop {
            tokio::time::sleep(delay).await;
            match OidcJwtVerifier::discover(oidc.clone()).await {
                Ok(verifier) => {
                    runtime.publish_ready(Arc::new(verifier));
                    info!("OIDC verification metadata recovered");
                    return;
                }
                Err(error) => {
                    base_delay = base_delay.saturating_mul(2).min(base_ceiling);
                    delay = add_positive_jitter(base_delay, maximum, rand::random());
                    runtime.publish_unavailable(error.into(), delay);
                    warn!(reason = ?auth::AuthUnavailableReason::from(error), retry_after_seconds = delay.as_secs(), "OIDC verification metadata remains unavailable");
                }
            }
        }
    }))
}

fn add_positive_jitter(
    base: std::time::Duration,
    maximum: std::time::Duration,
    sample: u64,
) -> std::time::Duration {
    let headroom = maximum.saturating_sub(base);
    let jitter_cap = (base / 5).min(headroom);
    let jitter_cap_millis = u64::try_from(jitter_cap.as_millis()).unwrap_or(u64::MAX);
    if jitter_cap_millis == 0 {
        return base.min(maximum);
    }
    let jitter_millis = 1 + sample % jitter_cap_millis;
    base.saturating_add(std::time::Duration::from_millis(jitter_millis))
        .min(maximum)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn recovery_jitter_is_positive_deterministic_and_bounded() {
        let base = Duration::from_secs(10);
        let maximum = Duration::from_secs(30);
        assert_eq!(
            add_positive_jitter(base, maximum, 0),
            Duration::from_millis(10_001)
        );
        assert_eq!(
            add_positive_jitter(base, maximum, 1_999),
            Duration::from_secs(12)
        );
        assert_eq!(
            add_positive_jitter(Duration::from_millis(29_999), maximum, 9),
            maximum
        );
    }
}
