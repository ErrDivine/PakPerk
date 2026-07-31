use chrono::{DateTime, Utc};

const MAX_ISSUER_BYTES: usize = 2_048;
// Match the local account identity boundary. Downstream test verifiers must
// not be able to construct claims that production account mapping rejects.
const MAX_SUBJECT_BYTES: usize = 512;
const MAX_AUDIENCES: usize = 64;
const MAX_AUDIENCE_BYTES: usize = 512;

/// Identity assertions extracted from a successfully verified access token.
///
/// This type intentionally does not model a Pakperk account. The API maps the
/// `(issuer, subject)` pair to an application user in its own transaction.
#[derive(Clone, PartialEq, Eq)]
pub struct VerifiedOidcClaims {
    issuer: String,
    subject: String,
    audience: Vec<String>,
    expires_at: DateTime<Utc>,
    issued_at: Option<DateTime<Utc>>,
    auth_time: Option<DateTime<Utc>>,
}

impl VerifiedOidcClaims {
    /// Constructs claims for a trusted [`crate::TokenVerifier`] implementation.
    ///
    /// This validates the representation's safety bounds, but it does not
    /// verify a token signature or authorize an audience. Production callers
    /// should normally obtain this value from [`crate::OidcJwtVerifier`]. The
    /// constructor is public so downstream deterministic verifiers can exercise
    /// the same principal-extraction boundary without real signing keys.
    pub fn try_from_verified_parts(
        issuer: String,
        subject: String,
        audience: Vec<String>,
        expires_at: DateTime<Utc>,
        issued_at: Option<DateTime<Utc>>,
        auth_time: Option<DateTime<Utc>>,
    ) -> Result<Self, VerifiedClaimsConstructionError> {
        if !valid_identity(&issuer, MAX_ISSUER_BYTES)
            || !valid_identity(&subject, MAX_SUBJECT_BYTES)
            || audience.is_empty()
            || audience.len() > MAX_AUDIENCES
            || audience
                .iter()
                .any(|value| !valid_identity(value, MAX_AUDIENCE_BYTES))
        {
            return Err(VerifiedClaimsConstructionError);
        }
        Ok(Self::new(
            issuer, subject, audience, expires_at, issued_at, auth_time,
        ))
    }

    pub(crate) fn new(
        issuer: String,
        subject: String,
        audience: Vec<String>,
        expires_at: DateTime<Utc>,
        issued_at: Option<DateTime<Utc>>,
        auth_time: Option<DateTime<Utc>>,
    ) -> Self {
        Self {
            issuer,
            subject,
            audience,
            expires_at,
            issued_at,
            auth_time,
        }
    }

    pub fn issuer(&self) -> &str {
        &self.issuer
    }

    pub fn subject(&self) -> &str {
        &self.subject
    }

    pub fn audience(&self) -> &[String] {
        &self.audience
    }

    pub fn expires_at(&self) -> DateTime<Utc> {
        self.expires_at
    }

    pub fn issued_at(&self) -> Option<DateTime<Utc>> {
        self.issued_at
    }

    pub fn auth_time(&self) -> Option<DateTime<Utc>> {
        self.auth_time
    }
}

fn valid_identity(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_bytes
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

/// Sanitized failure returned when a trusted verifier attempts to construct an
/// unsafe or unbounded claims representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VerifiedClaimsConstructionError;

impl std::fmt::Display for VerifiedClaimsConstructionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("verified claims are invalid")
    }
}

impl std::error::Error for VerifiedClaimsConstructionError {}

/// Do not expose an OIDC subject through routine structured debugging.
impl std::fmt::Debug for VerifiedOidcClaims {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("VerifiedOidcClaims")
            .field("issuer", &"[redacted]")
            .field("subject", &"[redacted]")
            .field("audience_count", &self.audience.len())
            .field("expires_at", &self.expires_at)
            .field("issued_at", &self.issued_at)
            .field("auth_time", &self.auth_time)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone as _;

    use super::*;

    #[test]
    fn debug_redacts_identity_values() {
        let claims = VerifiedOidcClaims::new(
            "https://identity.example/secret-tenant".into(),
            "private-subject".into(),
            vec!["pakperk".into()],
            Utc.timestamp_opt(1_800_000_000, 0).unwrap(),
            None,
            None,
        );

        let rendered = format!("{claims:?}");
        assert!(!rendered.contains("secret-tenant"));
        assert!(!rendered.contains("private-subject"));
        assert!(rendered.contains("[redacted]"));
    }

    #[test]
    fn downstream_verifier_constructor_is_bounded_and_sanitized() {
        let expiry = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let claims = VerifiedOidcClaims::try_from_verified_parts(
            "https://identity.example/realm".into(),
            "opaque-subject".into(),
            vec!["pakperk-api".into()],
            expiry,
            None,
            None,
        )
        .unwrap();
        assert_eq!(claims.subject(), "opaque-subject");

        assert!(
            VerifiedOidcClaims::try_from_verified_parts(
                "https://identity.example/realm".into(),
                "s".repeat(MAX_SUBJECT_BYTES + 1),
                vec!["pakperk-api".into()],
                expiry,
                None,
                None,
            )
            .is_err()
        );

        let error = VerifiedOidcClaims::try_from_verified_parts(
            "https://identity.example/realm".into(),
            " subject ".into(),
            vec!["pakperk-api".into()],
            expiry,
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "verified claims are invalid");
        assert!(!format!("{error:?}").contains("subject"));
    }
}
