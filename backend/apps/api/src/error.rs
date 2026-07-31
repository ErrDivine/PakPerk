//! Stable public error-envelope translation.

use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use domain::{ApiErrorBody, ApiErrorEnvelope};
use uuid::Uuid;

#[derive(Debug, Clone, Copy)]
pub(crate) struct RequestId(pub(crate) Uuid);

#[derive(Debug)]
pub(crate) struct ApiError {
    pub(crate) request_id: RequestId,
    pub(crate) status: StatusCode,
    pub(crate) code: &'static str,
    pub(crate) message: String,
    pub(crate) retryable: bool,
}

impl ApiError {
    pub(crate) fn new(
        request_id: RequestId,
        status: StatusCode,
        code: &'static str,
        message: impl Into<String>,
        retryable: bool,
    ) -> Self {
        Self {
            request_id,
            status,
            code,
            message: message.into(),
            retryable,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = ApiErrorEnvelope {
            error: ApiErrorBody {
                code: self.code.to_owned(),
                message: self.message,
                retryable: self.retryable,
                request_id: self.request_id.0,
            },
        };
        (self.status, Json(body)).into_response()
    }
}
