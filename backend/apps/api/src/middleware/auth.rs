use std::time::{Duration, Instant};

use accounts::{AccountServiceError, VerifiedIdentity};
use auth::{AuthRuntimeStatus, VerifyError};
use axum::{
    extract::FromRequestParts,
    http::{HeaderMap, StatusCode, header::AUTHORIZATION, request::Parts},
    response::{IntoResponse as _, Response},
};
use chrono::{DateTime, Utc};
use domain::{AccountStatus, AuthenticatedUserId};
use observability::{OperationClass, OperationOutcome, record_operation};
use uuid::Uuid;

use crate::{
    AppState,
    error::{ApiError, RequestId, account_service_error},
    middleware::SESSION_ID_HEADER,
};

const MAX_AUTHORIZATION_HEADER_BYTES: usize = 64 * 1024;
const METADATA_RETRY_AFTER: Duration = Duration::from_secs(30);

/// A verified OIDC identity mapped to a server-owned Pakperk user.
/// Provider subjects and bearer-token material are deliberately not retained.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct AuthenticatedPrincipal {
    pub(crate) user_id: AuthenticatedUserId,
    pub(crate) auth_time: Option<DateTime<Utc>>,
}

/// Transport-independent identity resolved for a public API request.
///
/// Account and anonymous identity remain separate on purpose. In particular,
/// the presence of `user_id` never changes the anonymous session used by the
/// v0.0 preparation and chat APIs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RequestPrincipal {
    pub user_id: Option<Uuid>,
    pub anonymous_session_id: Option<Uuid>,
    pub request_id: Uuid,
}

/// Verified provider identity for account deletion. Unlike ordinary account
/// authentication this never JIT-provisions and never rejects suspended or
/// deletion-pending accounts, so a lost response can be retried safely.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct AccountDeletionPrincipal {
    pub(crate) identity: VerifiedIdentity,
    pub(crate) auth_time: Option<DateTime<Utc>>,
}

impl std::fmt::Debug for AccountDeletionPrincipal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AccountDeletionPrincipal")
            .field("identity", &self.identity)
            .field("auth_time", &self.auth_time)
            .finish()
    }
}

impl FromRequestParts<AppState> for AuthenticatedPrincipal {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        authenticate(parts, state).await
    }
}

impl FromRequestParts<AppState> for RequestPrincipal {
    type Rejection = Response;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let authenticated = if !parts.headers.contains_key(AUTHORIZATION)
            || !matches!(state.auth.status(), AuthRuntimeStatus::Ready)
        {
            None
        } else {
            match authenticate(parts, state).await {
                Ok(principal) => Some(principal),
                // Public routes do not authorize from this principal. Provider
                // metadata/storage outages and inactive-account policy therefore
                // degrade to the same bounded public representation as a guest.
                // Malformed, expired, or cryptographically invalid credentials
                // still receive a challenge instead of being silently accepted.
                Err(error) if optional_auth_falls_back_to_guest(&error) => None,
                Err(error) => return Err(error.into_response()),
            }
        };
        Ok(Self {
            user_id: authenticated.map(|principal| principal.user_id.into_inner()),
            anonymous_session_id: anonymous_session_id(&parts.headers),
            request_id: request_id(parts).0,
        })
    }
}

impl FromRequestParts<AppState> for AccountDeletionPrincipal {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let request_id = request_id(parts);
        if state.account_deletion.is_none() {
            return Err(ApiError::new(
                request_id,
                StatusCode::NOT_FOUND,
                "FEATURE_DISABLED",
                "Account deletion is disabled.",
                false,
            ));
        }
        let token = bearer_token(parts, request_id)?;
        let verifier = state
            .auth
            .verifier()
            .ok_or_else(|| auth_runtime_error(request_id, state.auth.status()))?;
        let claims = verifier
            .verify(token)
            .await
            .map_err(|error| token_error(request_id, error))?;
        let identity =
            VerifiedIdentity::new(claims.issuer().to_owned(), claims.subject().to_owned())
                .map_err(|error| account_service_error(request_id, &error))?;
        Ok(Self {
            identity,
            auth_time: claims.auth_time(),
        })
    }
}

fn optional_auth_falls_back_to_guest(error: &ApiError) -> bool {
    matches!(
        error.code,
        "AUTHENTICATION_UNAVAILABLE"
            | "ACCOUNT_SERVICE_UNAVAILABLE"
            | "ACCOUNT_SUSPENDED"
            | "ACCOUNT_DELETION_PENDING"
            | "FEATURE_DISABLED"
    )
}

async fn authenticate(parts: &Parts, state: &AppState) -> Result<AuthenticatedPrincipal, ApiError> {
    let request_id = request_id(parts);
    let token = bearer_token(parts, request_id)?;
    let verifier = state
        .auth
        .verifier()
        .ok_or_else(|| auth_runtime_error(request_id, state.auth.status()))?;
    let claims = verifier
        .verify(token)
        .await
        .map_err(|error| token_error(request_id, error))?;
    let identity = VerifiedIdentity::new(claims.issuer().to_owned(), claims.subject().to_owned())
        .map_err(|error| account_service_error(request_id, &error))?;
    let service = state.accounts.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "FEATURE_DISABLED",
            "Account features are disabled.",
            false,
        )
    })?;
    let started = Instant::now();
    let user = service.provision_authenticated(&identity).await;
    record_operation(
        OperationClass::JitProvisioning,
        account_operation_outcome(&user),
        started.elapsed(),
    );
    let user = user.map_err(|error| account_service_error(request_id, &error))?;
    match user.status {
        AccountStatus::Active => Ok(AuthenticatedPrincipal {
            user_id: user.id,
            auth_time: claims.auth_time(),
        }),
        AccountStatus::Suspended => Err(account_service_error(
            request_id,
            &AccountServiceError::Suspended,
        )),
        AccountStatus::DeletionPending => Err(account_service_error(
            request_id,
            &AccountServiceError::DeletionPending,
        )),
        AccountStatus::Deleted => Err(account_service_error(
            request_id,
            &AccountServiceError::Deleted,
        )),
    }
}

fn request_id(parts: &Parts) -> RequestId {
    parts
        .extensions
        .get::<RequestId>()
        .copied()
        .unwrap_or_else(|| RequestId(Uuid::now_v7()))
}

fn anonymous_session_id(headers: &HeaderMap) -> Option<Uuid> {
    let mut values = headers.get_all(&SESSION_ID_HEADER).iter();
    let value = values.next()?;
    if values.next().is_some() {
        return None;
    }
    value
        .to_str()
        .ok()
        .and_then(|value| Uuid::parse_str(value).ok())
}

fn account_operation_outcome<T>(result: &Result<T, AccountServiceError>) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(AccountServiceError::Storage(_) | AccountServiceError::RateLimited { .. }) => {
            OperationOutcome::RetryableFailure
        }
        Err(
            AccountServiceError::InvalidRateLimitPolicy
            | AccountServiceError::InvalidFingerprint(_),
        ) => OperationOutcome::TerminalFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

fn bearer_token(parts: &Parts, request_id: RequestId) -> Result<&str, ApiError> {
    let mut values = parts.headers.get_all(AUTHORIZATION).iter();
    let Some(value) = values.next() else {
        return Err(unauthenticated(request_id, "Sign in to continue."));
    };
    if values.next().is_some() {
        return Err(unauthenticated(
            request_id,
            "The authorization header is invalid.",
        ));
    }
    let value = value
        .to_str()
        .map_err(|_| unauthenticated(request_id, "The authorization header is invalid."))?;
    if value.len() > MAX_AUTHORIZATION_HEADER_BYTES {
        return Err(unauthenticated(
            request_id,
            "The authorization header is invalid.",
        ));
    }
    let Some((scheme, token)) = value.split_once(' ') else {
        return Err(unauthenticated(
            request_id,
            "The authorization header is invalid.",
        ));
    };
    if !scheme.eq_ignore_ascii_case("Bearer")
        || token.is_empty()
        || token.bytes().any(|byte| byte.is_ascii_whitespace())
    {
        return Err(unauthenticated(
            request_id,
            "The authorization header is invalid.",
        ));
    }
    Ok(token)
}

fn unauthenticated(request_id: RequestId, message: &'static str) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::UNAUTHORIZED,
        "UNAUTHENTICATED",
        message,
        false,
    )
    .with_bearer_challenge()
}

fn token_error(request_id: RequestId, error: VerifyError) -> ApiError {
    match error {
        VerifyError::Expired => ApiError::new(
            request_id,
            StatusCode::UNAUTHORIZED,
            "TOKEN_EXPIRED",
            "The access token has expired.",
            false,
        )
        .with_bearer_challenge(),
        VerifyError::MetadataUnavailable => ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "AUTHENTICATION_UNAVAILABLE",
            "Sign-in validation is temporarily unavailable.",
            true,
        )
        .with_retry_after(METADATA_RETRY_AFTER.as_secs()),
        VerifyError::TokenTooLarge
        | VerifyError::MalformedToken
        | VerifyError::MissingKeyId
        | VerifyError::DisallowedAlgorithm
        | VerifyError::UnknownSigningKey
        | VerifyError::InvalidSignature
        | VerifyError::NotYetValid
        | VerifyError::InvalidClaims => unauthenticated(request_id, "The access token is invalid."),
    }
}

fn auth_runtime_error(request_id: RequestId, status: AuthRuntimeStatus) -> ApiError {
    match status {
        AuthRuntimeStatus::Unavailable { retry_after, .. } => ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "AUTHENTICATION_UNAVAILABLE",
            "Sign-in validation is temporarily unavailable.",
            true,
        )
        .with_retry_after(retry_after_seconds(retry_after)),
        AuthRuntimeStatus::Disabled => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "FEATURE_DISABLED",
            "Account features are disabled.",
            false,
        ),
        AuthRuntimeStatus::Ready => ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "AUTHENTICATION_UNAVAILABLE",
            "Sign-in validation is temporarily unavailable.",
            true,
        )
        .with_retry_after(METADATA_RETRY_AFTER.as_secs()),
    }
}

fn retry_after_seconds(duration: Duration) -> u64 {
    duration
        .as_secs()
        .saturating_add(u64::from(duration.subsec_nanos() > 0))
        .max(1)
}

#[cfg(test)]
mod tests {
    use axum::http::{HeaderMap, HeaderValue, Request};

    use super::*;

    fn parts(headers: HeaderMap) -> Parts {
        let mut request = Request::new(());
        *request.headers_mut() = headers;
        request.into_parts().0
    }

    #[test]
    fn bearer_parser_is_strict_and_does_not_return_header_details_in_errors() {
        let request_id = RequestId(Uuid::nil());
        let mut valid_headers = HeaderMap::new();
        valid_headers.insert(
            AUTHORIZATION,
            HeaderValue::from_static("bearer signed.jwt.value"),
        );
        assert_eq!(
            bearer_token(&parts(valid_headers), request_id).unwrap(),
            "signed.jwt.value"
        );

        for value in [
            "Basic private",
            "Bearer",
            "Bearer ",
            "Bearer private token",
            "Bearer\tprivate",
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(AUTHORIZATION, HeaderValue::from_str(value).unwrap());
            let error = bearer_token(&parts(headers), request_id).unwrap_err();
            assert_eq!(error.status, StatusCode::UNAUTHORIZED);
            assert_eq!(error.code, "UNAUTHENTICATED");
            assert!(!error.message.contains("private"));
        }
    }

    #[test]
    fn unavailable_runtime_error_is_retryable_and_sanitized() {
        let error = auth_runtime_error(
            RequestId(Uuid::nil()),
            AuthRuntimeStatus::Unavailable {
                reason: auth::AuthUnavailableReason::ProviderUnavailable,
                retry_after: Duration::from_secs(17),
            },
        );
        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(error.code, "AUTHENTICATION_UNAVAILABLE");
        assert_eq!(error.retry_after_seconds, Some(17));
    }
}
