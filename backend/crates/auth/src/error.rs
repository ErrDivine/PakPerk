use std::fmt;

/// Sanitized verifier configuration failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ConfigError {
    #[error("OIDC issuer configuration is invalid")]
    InvalidIssuer,
    #[error("OIDC audience configuration is invalid")]
    InvalidAudience,
    #[error("OIDC allowed-algorithm configuration is invalid")]
    InvalidAlgorithms,
    #[error("OIDC timeout configuration is outside supported bounds")]
    InvalidTimeout,
    #[error("OIDC cache timing configuration is outside supported bounds")]
    InvalidCacheTiming,
    #[error("OIDC document or token size limit is outside supported bounds")]
    InvalidSizeLimit,
}

/// Sanitized failures while bootstrapping OIDC validation metadata.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum OidcStartupError {
    #[error("OIDC verifier configuration is invalid")]
    InvalidConfiguration,
    #[error("OIDC provider metadata is unavailable")]
    ProviderUnavailable,
    #[error("OIDC provider metadata is invalid")]
    InvalidProviderMetadata,
    #[error("OIDC signing keys are invalid")]
    InvalidSigningKeys,
}

/// Public verification categories. No variant retains token material, claims,
/// provider response bodies, issuer URLs, key IDs, or upstream error strings.
#[derive(Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum VerifyError {
    #[error("bearer token is too large")]
    TokenTooLarge,
    #[error("bearer token is malformed")]
    MalformedToken,
    #[error("bearer token has no signing key identifier")]
    MissingKeyId,
    #[error("bearer token uses a disallowed signing algorithm")]
    DisallowedAlgorithm,
    #[error("bearer token signing key is unknown")]
    UnknownSigningKey,
    #[error("bearer token signature is invalid")]
    InvalidSignature,
    #[error("bearer token is expired")]
    Expired,
    #[error("bearer token is not valid yet")]
    NotYetValid,
    #[error("bearer token claims are invalid")]
    InvalidClaims,
    #[error("OIDC validation metadata is temporarily unavailable")]
    MetadataUnavailable,
}

impl fmt::Debug for VerifyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, formatter)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verification_errors_have_only_sanitized_debug_output() {
        for error in [
            VerifyError::MalformedToken,
            VerifyError::UnknownSigningKey,
            VerifyError::MetadataUnavailable,
        ] {
            assert_eq!(format!("{error:?}"), error.to_string());
        }
    }
}
