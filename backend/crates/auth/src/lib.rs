//! Provider-neutral `OpenID` Connect token verification and identity administration.
//!
//! This crate deliberately stops at the identity boundary. Verified OIDC claims
//! are not application users, and no provider access token or subject is ever
//! retained in an error value.

mod claims;
mod config;
mod discovery;
mod error;
mod identity_admin;
mod runtime;
mod verifier;

pub use claims::{VerifiedClaimsConstructionError, VerifiedOidcClaims};
pub use config::{OidcAlgorithm, OidcVerifierConfig};
pub use discovery::{
    DocumentFetchError, HttpOidcDocumentFetcher, OidcDocumentFetcher, OidcProviderMetadata,
};
pub use error::{ConfigError, OidcStartupError, VerifyError};
pub use identity_admin::{
    IdentityAdmin, IdentityAdminError, IdentityAdminReadiness, KeycloakIdentityAdmin,
    KeycloakIdentityAdminConfig, NoopIdentityAdmin,
};
pub use runtime::{AuthRuntime, AuthRuntimeStatus, AuthUnavailableReason};
pub use verifier::{OidcJwtVerifier, TokenVerifier};
