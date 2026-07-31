//! Cross-cutting HTTP middleware seams.

mod rate_limit;
mod request_id;
mod timeout;

use axum::http::HeaderName;

pub(crate) use rate_limit::RateLimiter;
pub(crate) use request_id::request_id_middleware;
pub(crate) use timeout::{TimeoutConfig, stable_error_middleware, timeout_middleware};

pub(crate) const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");
pub(crate) const SESSION_ID_HEADER: HeaderName = HeaderName::from_static("x-session-id");
