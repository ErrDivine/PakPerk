//! Cross-cutting HTTP middleware seams.

mod auth;
mod request_id;
mod telemetry;
mod timeout;

use axum::http::HeaderName;

pub(crate) use request_id::request_id_middleware;
pub(crate) use telemetry::telemetry_middleware;
pub(crate) use timeout::{TimeoutConfig, stable_error_middleware, timeout_middleware};

pub(crate) const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");
pub(crate) const SESSION_ID_HEADER: HeaderName = HeaderName::from_static("x-session-id");
pub use auth::RequestPrincipal;
pub(crate) use auth::{AccountDeletionPrincipal, AuthenticatedPrincipal};
