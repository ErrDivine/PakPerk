use std::time::Duration;

use axum::{
    extract::{Request, State},
    http::{StatusCode, header::CONTENT_TYPE},
    middleware::Next,
    response::{IntoResponse, Response},
};
use uuid::Uuid;

use crate::error::{ApiError, RequestId};

#[derive(Debug, Clone, Copy)]
pub(crate) struct TimeoutConfig {
    pub(crate) default: Duration,
    pub(crate) chat: Duration,
}

pub(crate) async fn timeout_middleware(
    State(timeouts): State<TimeoutConfig>,
    request: Request,
    next: Next,
) -> Response {
    let request_id = request
        .extensions()
        .get::<RequestId>()
        .copied()
        .unwrap_or_else(|| RequestId(Uuid::now_v7()));
    let timeout = if request.uri().path().ends_with("/chat") {
        timeouts.chat
    } else {
        timeouts.default
    };
    match tokio::time::timeout(timeout, next.run(request)).await {
        Ok(response) => response,
        Err(_) => ApiError::new(
            request_id,
            StatusCode::GATEWAY_TIMEOUT,
            "REQUEST_TIMEOUT",
            "The request took too long. Please try again.",
            true,
        )
        .into_response(),
    }
}

pub(crate) async fn stable_error_middleware(request: Request, next: Next) -> Response {
    let request_id = request
        .extensions()
        .get::<RequestId>()
        .copied()
        .unwrap_or_else(|| RequestId(Uuid::now_v7()));
    let response = next.run(request).await;
    let status = response.status();
    let is_json = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("application/json"));
    if !status.is_client_error() && !status.is_server_error() || is_json {
        return response;
    }
    let (code, message, retryable) = match status {
        StatusCode::METHOD_NOT_ALLOWED => (
            "METHOD_NOT_ALLOWED",
            "That HTTP method is not supported for this route.",
            false,
        ),
        StatusCode::PAYLOAD_TOO_LARGE => (
            "REQUEST_BODY_TOO_LARGE",
            "The request body exceeds the service limit.",
            false,
        ),
        StatusCode::UNSUPPORTED_MEDIA_TYPE => (
            "UNSUPPORTED_MEDIA_TYPE",
            "This endpoint requires an application/json request body.",
            false,
        ),
        StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => (
            "INVALID_REQUEST",
            "The request body or path parameters are invalid.",
            false,
        ),
        _ if status.is_server_error() => (
            "INTERNAL_ERROR",
            "The service could not complete the request.",
            true,
        ),
        _ => ("REQUEST_REJECTED", "The request was rejected.", false),
    };
    ApiError::new(request_id, status, code, message, retryable).into_response()
}
