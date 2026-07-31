//! Stable public error-envelope translation.

use axum::{
    Json,
    http::{
        HeaderValue, StatusCode,
        header::{ETAG, RETRY_AFTER, WWW_AUTHENTICATE},
    },
    response::{IntoResponse, Response},
};
use domain::{ApiErrorBody, ApiErrorEnvelope};
use tracing::error;
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
    pub(crate) retry_after_seconds: Option<u64>,
    entity_tag: Option<HeaderValue>,
    bearer_challenge: bool,
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
            retry_after_seconds: None,
            entity_tag: None,
            bearer_challenge: false,
        }
    }

    pub(crate) const fn with_retry_after(mut self, seconds: u64) -> Self {
        self.retry_after_seconds = Some(seconds);
        self
    }

    pub(crate) fn with_entity_tag(mut self, entity_tag: HeaderValue) -> Self {
        self.entity_tag = Some(entity_tag);
        self
    }

    pub(crate) const fn with_bearer_challenge(mut self) -> Self {
        self.bearer_challenge = true;
        self
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
        let mut response = (self.status, Json(body)).into_response();
        if let Some(seconds) = self.retry_after_seconds
            && let Ok(value) = HeaderValue::from_str(&seconds.to_string())
        {
            response.headers_mut().insert(RETRY_AFTER, value);
        }
        if let Some(entity_tag) = self.entity_tag {
            response.headers_mut().insert(ETAG, entity_tag);
        }
        if self.bearer_challenge {
            response
                .headers_mut()
                .insert(WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        }
        response
    }
}

pub(crate) fn profile_entity_tag(profile_version: i64) -> Option<HeaderValue> {
    (profile_version > 0)
        .then(|| HeaderValue::from_str(&format!("\"profile-{profile_version}\"")))
        .transpose()
        .ok()
        .flatten()
}

pub(crate) fn account_service_error(
    request_id: RequestId,
    error_value: &accounts::AccountServiceError,
) -> ApiError {
    use accounts::AccountServiceError;

    match error_value {
        AccountServiceError::InvalidIdentity => ApiError::new(
            request_id,
            StatusCode::UNAUTHORIZED,
            "UNAUTHENTICATED",
            "The access token identity is invalid.",
            false,
        )
        .with_bearer_challenge(),
        AccountServiceError::Suspended => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_SUSPENDED",
            "This account is suspended.",
            false,
        ),
        AccountServiceError::DeletionPending | AccountServiceError::Deleted => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_DELETION_PENDING",
            "This account is unavailable.",
            false,
        ),
        AccountServiceError::ProfileVersionConflict { current_version } => {
            let error = ApiError::new(
                request_id,
                StatusCode::PRECONDITION_FAILED,
                "PROFILE_VERSION_CONFLICT",
                "The profile changed. Reload it before trying again.",
                false,
            );
            if let Some(tag) = profile_entity_tag(*current_version) {
                error.with_entity_tag(tag)
            } else {
                error
            }
        }
        AccountServiceError::HandleAlreadySet => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "HANDLE_ALREADY_SET",
            "The account handle cannot be changed.",
            false,
        ),
        AccountServiceError::HandleUnavailable => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "HANDLE_UNAVAILABLE",
            "That handle is unavailable.",
            false,
        ),
        AccountServiceError::RateLimited {
            retry_after_seconds,
        } => ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many profile updates. Please wait before retrying.",
            true,
        )
        .with_retry_after(*retry_after_seconds),
        AccountServiceError::NotFound
        | AccountServiceError::Storage(_)
        | AccountServiceError::InvalidRateLimitPolicy => {
            error!(request_id = %request_id.0, error = %error_value, "account service operation failed");
            ApiError::new(
                request_id,
                StatusCode::SERVICE_UNAVAILABLE,
                "ACCOUNT_SERVICE_UNAVAILABLE",
                "The account service is temporarily unavailable.",
                true,
            )
        }
        AccountServiceError::InvalidProfileVersion
        | AccountServiceError::EmptyProfileUpdate
        | AccountServiceError::InvalidHandle(_)
        | AccountServiceError::InvalidDisplayName(_)
        | AccountServiceError::InvalidTermsVersion(_)
        | AccountServiceError::TermsVersionMismatch => account_input_error(request_id, error_value),
    }
}

fn account_input_error(
    request_id: RequestId,
    error_value: &accounts::AccountServiceError,
) -> ApiError {
    use accounts::AccountServiceError;

    let (code, message) = match error_value {
        AccountServiceError::InvalidProfileVersion => {
            ("INVALID_PROFILE_VERSION", "The profile version is invalid.")
        }
        AccountServiceError::EmptyProfileUpdate => (
            "INVALID_PROFILE_UPDATE",
            "Provide at least one supported profile field.",
        ),
        AccountServiceError::InvalidHandle(_) => {
            ("INVALID_HANDLE", "The requested handle is invalid.")
        }
        AccountServiceError::InvalidDisplayName(_) => {
            ("INVALID_DISPLAY_NAME", "The display name is invalid.")
        }
        AccountServiceError::InvalidTermsVersion(_) => {
            ("INVALID_TERMS_VERSION", "The terms version is invalid.")
        }
        AccountServiceError::TermsVersionMismatch => (
            "TERMS_VERSION_MISMATCH",
            "Only the current terms version can be accepted.",
        ),
        _ => ("INVALID_PROFILE_UPDATE", "The profile update is invalid."),
    };
    ApiError::new(request_id, StatusCode::BAD_REQUEST, code, message, false)
}
