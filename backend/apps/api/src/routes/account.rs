use account_deletion::{AccountDeletionServiceError, RequestDeletionOutcome};
use accounts::{AccountServiceError, PatchValue, ProfileUpdateCommand};
use axum::{
    Extension, Json,
    body::Bytes,
    extract::{Request, State},
    http::{
        HeaderMap, HeaderValue, Method, StatusCode,
        header::{AUTHORIZATION, CACHE_CONTROL, ETAG, IF_MATCH, VARY},
    },
    middleware::Next,
    response::{IntoResponse, Response},
};

use crate::{
    AppState,
    dto::{
        AccountDeletionEnvelope, AccountProfileEnvelope, DeletionVerificationEnvelope,
        ProfilePatchField, ProfileUpdateBody,
    },
    error::{ApiError, RequestId, account_service_error, profile_entity_tag},
    middleware::{AccountDeletionPrincipal, AuthenticatedPrincipal},
};

const ACCOUNT_CACHE_CONTROL: &str = "private, no-store";
const MAX_IF_MATCH_BYTES: usize = 64;

pub(crate) async fn private_account_cache_control(request: Request, next: Next) -> Response {
    let path = request.uri().path();
    let method = request.method().clone();
    let is_paper_comments = path.starts_with("/v1/papers/") && path.ends_with("/comments");
    let is_assistant_route = path.starts_with("/v1/papers/")
        && (path.ends_with("/assistant") || path.ends_with("/assistant/feedback"));
    let is_figure_asset =
        path.starts_with("/v1/papers/") && path.contains("/figures/") && path.ends_with("/asset");
    let is_passport_feedback =
        path.starts_with("/v1/papers/") && path.ends_with("/passport/feedback");
    let is_search_route = path.starts_with("/v1/search/");
    let is_private_account_route = path == "/v1/me"
        || path.starts_with("/v1/me/")
        || path == "/v1/library"
        || path.starts_with("/v1/library/")
        || path == "/v1/discovery/profile"
        || path.starts_with("/v1/discovery/profile/")
        || path.starts_with("/v1/discovery/batches/")
        || path == "/v1/subscriptions"
        || path.starts_with("/v1/subscriptions/")
        || path == "/v1/notifications"
        || path.starts_with("/v1/notifications/")
        || path == "/v1/notification-preferences"
        || path == "/v1/events/batch"
        || path.starts_with("/v1/comments/")
        || path.starts_with("/v1/users/")
        || path == "/v1/annotations"
        || path == "/v1/annotation-conflicts"
        || path.starts_with("/v1/annotations/")
        || path == "/v1/evidence-cards"
        || path.starts_with("/v1/evidence-cards/")
        || path == "/v1/reading/checkpoints"
        || path.starts_with("/v1/reading/checkpoints/")
        || path == "/v1/memory/review"
        || path == "/v1/memory/items"
        || path.starts_with("/v1/memory/items/")
        || path.starts_with("/v1/assistant/provenance/")
        || is_assistant_route
        || is_figure_asset
        || is_passport_feedback
        || is_search_route
        || (is_paper_comments
            && (method == Method::POST || request.headers().contains_key(AUTHORIZATION)));
    let mut response = next.run(request).await;
    if is_private_account_route && !(is_figure_asset && response.status().is_success()) {
        response.headers_mut().insert(
            CACHE_CONTROL,
            HeaderValue::from_static(ACCOUNT_CACHE_CONTROL),
        );
    }
    if is_paper_comments || is_private_account_route {
        response
            .headers_mut()
            .append(VARY, HeaderValue::from_static("Authorization"));
    }
    response
}

#[utoipa::path(
    get,
    path = "/v1/me",
    tag = "accounts",
    description = "Registered only when ACCOUNTS_ENABLED=true; the route is absent when the account feature is disabled.",
    security(("oidcBearer" = [])),
    responses(
        (
            status = 200,
            description = "Current account profile and terms state",
            body = AccountProfileEnvelope,
            headers(
                ("ETag" = String, description = "Strong profile validator in the form quoted profile-N"),
                ("Cache-Control" = String, description = "Always private, no-store")
            ),
            example = json!({
                "account": {
                    "id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
                    "handle": "ada_reader",
                    "display_name": "Ada Reader",
                    "status": "active",
                    "profile_version": 2,
                    "profile_complete": true,
                    "terms_version": "2026-07-31",
                    "terms_accepted_at": "2026-07-31T12:00:00.000Z",
                    "current_terms_version": "2026-07-31",
                    "terms_current": true,
                    "community_guidelines_version": "2026-07-31",
                    "community_guidelines_accepted_at": "2026-07-31T12:00:00.000Z",
                    "current_community_guidelines_version": "2026-07-31",
                    "community_guidelines_current": true,
                    "comment_profile_complete": true,
                    "created_at": "2026-07-31T11:00:00.000Z",
                    "updated_at": "2026-07-31T12:00:00.000Z"
                }
            })
        ),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or ACCOUNT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry when known")))
    )
)]
pub(crate) async fn get_me(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<Response, ApiError> {
    let service = account_service(&state, request_id)?;
    let user = service
        .get_profile(principal.user_id)
        .await
        .map_err(|error| account_service_error(request_id, &error))?;
    account_response(&state, request_id, &user)
}

#[utoipa::path(
    patch,
    path = "/v1/me",
    tag = "accounts",
    description = "Registered only when ACCOUNTS_ENABLED=true; the route is absent when the account feature is disabled. Updates use an exact strong profile ETag for compare-and-swap.",
    security(("oidcBearer" = [])),
    params(
        ("If-Match" = String, Header, description = "Required exact strong profile validator returned by GET /v1/me", example = "\"profile-2\"")
    ),
    request_body(
        content = ProfileUpdateBody,
        description = "Supported profile fields; explicit null clears only display_name",
        example = json!({"handle": "ada_reader", "display_name": "Ada Reader", "accept_terms_version": "2026-07-31", "accept_community_guidelines_version": "2026-07-31"})
    ),
    responses(
        (
            status = 200,
            description = "Updated account profile",
            body = AccountProfileEnvelope,
            headers(
                ("ETag" = String, description = "New strong profile validator"),
                ("Cache-Control" = String, description = "Always private, no-store")
            )
        ),
        (status = 400, description = "INVALID_REQUEST, INVALID_PROFILE_VERSION, INVALID_PROFILE_UPDATE, INVALID_HANDLE, INVALID_DISPLAY_NAME, INVALID_TERMS_VERSION, TERMS_VERSION_MISMATCH, INVALID_COMMUNITY_GUIDELINES_VERSION, or COMMUNITY_GUIDELINES_VERSION_MISMATCH", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "HANDLE_ALREADY_SET or HANDLE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "PROFILE_VERSION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema, headers(("ETag" = String, description = "Current strong profile validator"))),
        (status = 428, description = "PROFILE_VERSION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or ACCOUNT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry when known")))
    )
)]
pub(crate) async fn patch_me(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<ProfileUpdateBody>,
) -> Result<Response, ApiError> {
    let expected_profile_version = expected_profile_version(&headers, request_id)?;
    let handle = match body.handle {
        ProfilePatchField::Omitted => None,
        ProfilePatchField::Value(value) => Some(value),
        ProfilePatchField::Null => {
            return Err(ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_HANDLE",
                "The account handle cannot be null.",
                false,
            ));
        }
    };
    let display_name = match body.display_name {
        ProfilePatchField::Omitted => PatchValue::Omitted,
        ProfilePatchField::Null => PatchValue::Null,
        ProfilePatchField::Value(value) => PatchValue::Value(value),
    };
    let accept_terms_version = match body.accept_terms_version {
        ProfilePatchField::Omitted => None,
        ProfilePatchField::Value(value) => Some(value),
        ProfilePatchField::Null => {
            return Err(ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_TERMS_VERSION",
                "The accepted terms version cannot be null.",
                false,
            ));
        }
    };
    let accept_community_guidelines_version = match body.accept_community_guidelines_version {
        ProfilePatchField::Omitted => None,
        ProfilePatchField::Value(value) => Some(value),
        ProfilePatchField::Null => {
            return Err(ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_COMMUNITY_GUIDELINES_VERSION",
                "The accepted Community Guidelines version cannot be null.",
                false,
            ));
        }
    };
    let service = account_service(&state, request_id)?;
    let user = service
        .update_profile(
            principal.user_id,
            ProfileUpdateCommand {
                expected_profile_version,
                handle,
                display_name,
                accept_terms_version,
                accept_community_guidelines_version,
            },
        )
        .await
        .map_err(|error| account_service_error(request_id, &error))?;
    account_response(&state, request_id, &user)
}

#[utoipa::path(
    delete,
    path = "/v1/me",
    tag = "accounts",
    description = "Registered only when ACCOUNT_DELETION_ENABLED=true. Every request, including an identity-scoped replay, requires recent authentication. The verified issuer/subject is the replay key; no Idempotency-Key header is accepted. A replay resumes durable externalization and returns the original operation. ACCOUNT_DELETION_UNAVAILABLE is unusual: the account is already locally deletion_pending, ordinary access remains blocked, and the worker/operator owns completion even though the external tombstone was not yet acknowledged durable.",
    security(("oidcBearer" = [])),
    responses(
        (
            status = 202,
            description = "Deletion accepted or identity-scoped replay; clients must immediately clear credentials and account-owned local data",
            body = AccountDeletionEnvelope,
            headers(("Cache-Control" = String, description = "Always private, no-store")),
            example = json!({
                "deletion": {
                    "operation_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
                    "state": "requested",
                    "requested_at": "2026-07-31T12:34:56.789Z",
                    "updated_at": "2026-07-31T12:34:56.789Z"
                }
            })
        ),
        (status = 400, description = "INVALID_REQUEST when the DELETE body is non-empty or any Idempotency-Key header is supplied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED, TOKEN_EXPIRED, or REAUTHENTICATION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 429, description = "RATE_LIMITED for a new operation only; identity-scoped replays never consume quota", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry"))),
        (status = 503, description = "ACCOUNT_DELETION_UNAVAILABLE proves post-commit local disable and asynchronous ownership. SERVICE_UNAVAILABLE is ambiguous and never asserts acceptance. Clients fail closed for either response after dispatch.", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry")))
    )
)]
pub(crate) async fn delete_me(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AccountDeletionPrincipal,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    validate_delete_request(request_id, &headers, &body)?;
    let service = deletion_service(&state, request_id)?;
    require_recent_auth(
        request_id,
        principal.auth_time,
        service.policy().recent_auth(),
    )?;
    match service
        .request(&principal.identity)
        .await
        .map_err(|error| deletion_service_error(request_id, &error))?
    {
        RequestDeletionOutcome::Accepted { operation, .. } => Ok((
            StatusCode::ACCEPTED,
            Json(AccountDeletionEnvelope::from(operation)),
        )
            .into_response()),
        RequestDeletionOutcome::RateLimited {
            retry_after_seconds,
        } => Err(ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many account deletion requests. Please wait before retrying.",
            true,
        )
        .with_retry_after(retry_after_seconds)),
    }
}

fn validate_delete_request(
    request_id: RequestId,
    headers: &HeaderMap,
    body: &[u8],
) -> Result<(), ApiError> {
    if body.is_empty() && !headers.contains_key("idempotency-key") {
        return Ok(());
    }
    Err(ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_REQUEST",
        "DELETE /v1/me accepts neither a request body nor Idempotency-Key.",
        false,
    ))
}

#[utoipa::path(
    get,
    path = "/v1/me/deletion-verification",
    tag = "accounts",
    description = "Registered only when ACCOUNT_DELETION_ENABLED=true. Resolves a verified OIDC identity to a bounded existing account record without JIT provisioning. This endpoint intentionally accepts a currently valid access token regardless of auth_time; DELETE /v1/me alone enforces recent authentication.",
    security(("oidcBearer" = [])),
    responses(
        (
            status = 200,
            description = "Existing account identity used to bind the destructive confirmation flow",
            body = DeletionVerificationEnvelope,
            headers(("Cache-Control" = String, description = "Always private, no-store")),
            example = json!({
                "account": {
                    "id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
                    "status": "active",
                    "deletion_operation_id": null
                }
            })
        ),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 404, description = "ACCOUNT_NOT_FOUND or FEATURE_DISABLED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or ACCOUNT_DELETION_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry")))
    )
)]
pub(crate) async fn verify_deletion_identity(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AccountDeletionPrincipal,
) -> Result<Response, ApiError> {
    let service = deletion_service(&state, request_id)?;
    let Some(verification) = service
        .verify_identity(&principal.identity)
        .await
        .map_err(|error| deletion_service_error(request_id, &error))?
    else {
        return Err(ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "ACCOUNT_NOT_FOUND",
            "No existing account is associated with this identity.",
            false,
        ));
    };
    Ok(Json(DeletionVerificationEnvelope::from(verification)).into_response())
}

fn require_recent_auth(
    request_id: RequestId,
    auth_time: Option<chrono::DateTime<chrono::Utc>>,
    maximum_age: std::time::Duration,
) -> Result<(), ApiError> {
    require_recent_auth_at(request_id, auth_time, maximum_age, chrono::Utc::now())
}

fn require_recent_auth_at(
    request_id: RequestId,
    auth_time: Option<chrono::DateTime<chrono::Utc>>,
    maximum_age: std::time::Duration,
    now: chrono::DateTime<chrono::Utc>,
) -> Result<(), ApiError> {
    let Some(auth_time) = auth_time else {
        return Err(reauthentication_required(request_id));
    };
    let maximum_age =
        chrono::TimeDelta::from_std(maximum_age).unwrap_or_else(|_| chrono::TimeDelta::seconds(0));
    if auth_time > now || now.signed_duration_since(auth_time) > maximum_age {
        return Err(reauthentication_required(request_id));
    }
    Ok(())
}

fn reauthentication_required(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::UNAUTHORIZED,
        "REAUTHENTICATION_REQUIRED",
        "Sign in again before deleting your account.",
        false,
    )
    .with_bearer_challenge()
}

fn deletion_service(
    state: &AppState,
    request_id: RequestId,
) -> Result<&account_deletion::AccountDeletionService, ApiError> {
    state.account_deletion.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "FEATURE_DISABLED",
            "Account deletion is disabled.",
            false,
        )
    })
}

fn deletion_service_error(
    request_id: RequestId,
    error_value: &AccountDeletionServiceError,
) -> ApiError {
    let (error_kind, post_commit) = match error_value {
        AccountDeletionServiceError::InvalidPolicy => ("invalid_policy", false),
        AccountDeletionServiceError::Fingerprint(_) => ("fingerprint", false),
        AccountDeletionServiceError::Storage(_) => ("storage", false),
        AccountDeletionServiceError::ExternalizationUnavailable { .. } => ("externalization", true),
        AccountDeletionServiceError::PostCommitStorageUnavailable { .. } => {
            ("post_commit_storage", true)
        }
        AccountDeletionServiceError::ExternalLedger(_) => ("external_ledger", false),
        AccountDeletionServiceError::ProviderIdentity(_) => ("provider_identity", false),
    };
    tracing::error!(request_id = %request_id.0, error.kind = error_kind, "account deletion request failed");
    if post_commit {
        ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "ACCOUNT_DELETION_UNAVAILABLE",
            "Your account is disabled, but durable deletion processing is temporarily unavailable. Cleanup will continue automatically.",
            true,
        )
        .with_retry_after(30)
    } else {
        ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "SERVICE_UNAVAILABLE",
            "Account deletion is temporarily unavailable. Please try again.",
            true,
        )
        .with_retry_after(30)
    }
}

fn account_service(
    state: &AppState,
    request_id: RequestId,
) -> Result<&accounts::AccountService, ApiError> {
    state.accounts.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "FEATURE_DISABLED",
            "Account features are disabled.",
            false,
        )
    })
}

fn account_response(
    state: &AppState,
    request_id: RequestId,
    user: &domain::User,
) -> Result<Response, ApiError> {
    let service = account_service(state, request_id)?;
    let entity_tag = profile_entity_tag(user.profile_version).ok_or_else(|| {
        account_service_error(request_id, &AccountServiceError::InvalidProfileVersion)
    })?;
    let mut response = Json(AccountProfileEnvelope::new(
        user,
        service.policy().current_terms_version(),
        service.policy().current_community_guidelines_version(),
    ))
    .into_response();
    response.headers_mut().insert(ETAG, entity_tag);
    response.headers_mut().insert(
        CACHE_CONTROL,
        HeaderValue::from_static(ACCOUNT_CACHE_CONTROL),
    );
    Ok(response)
}

fn expected_profile_version(headers: &HeaderMap, request_id: RequestId) -> Result<i64, ApiError> {
    let mut values = headers.get_all(IF_MATCH).iter();
    let Some(value) = values.next() else {
        return Err(ApiError::new(
            request_id,
            StatusCode::PRECONDITION_REQUIRED,
            "PROFILE_VERSION_REQUIRED",
            "If-Match with the current profile ETag is required.",
            false,
        ));
    };
    if values.next().is_some() {
        return Err(invalid_profile_version(request_id));
    }
    let raw = value
        .to_str()
        .map_err(|_| invalid_profile_version(request_id))?;
    if raw.len() > MAX_IF_MATCH_BYTES {
        return Err(invalid_profile_version(request_id));
    }
    let version = raw
        .strip_prefix("\"profile-")
        .and_then(|value| value.strip_suffix('"'))
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|version| *version > 0)
        .ok_or_else(|| invalid_profile_version(request_id))?;
    if profile_entity_tag(version).as_ref() != Some(value) {
        return Err(invalid_profile_version(request_id));
    }
    Ok(version)
}

fn invalid_profile_version(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_PROFILE_VERSION",
        "If-Match must be an exact strong profile ETag.",
        false,
    )
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };

    use accounts::{AccountPolicy, AccountService, AccountStore, RateLimitStore};
    use arxiv_client::ArxivClientConfig;
    use async_trait::async_trait;
    use auth::{
        AuthRuntime, AuthUnavailableReason, TokenVerifier, VerifiedOidcClaims, VerifyError,
    };
    use axum::{
        Router,
        body::Body,
        http::{
            Method, Request,
            header::{AUTHORIZATION, CONTENT_TYPE, RETRY_AFTER, WWW_AUTHENTICATE},
        },
        middleware,
        routing::{get, post},
    };
    use chrono::{TimeZone as _, Utc};
    use db::{DbError, ProfilePatch, ProfileUpdateOutcome, RateLimitDecision, RateLimitRequest};
    use domain::{
        AccountStatus, AuthenticatedUserId, DisplayName, FulltextPolicy, Handle, TermsVersion, User,
    };
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt as _;
    use uuid::Uuid;

    use super::*;
    use crate::{
        AccountFeatureConfig, ApiConfig, ApiEnvironment, FeatureFlags, build_router,
        middleware::{
            REQUEST_ID_HEADER, RequestPrincipal, SESSION_ID_HEADER, request_id_middleware,
        },
    };

    #[test]
    fn profile_validator_is_exact_strong_and_positive() {
        let request_id = RequestId(Uuid::nil());
        for invalid in [
            "profile-2",
            "W/\"profile-2\"",
            "\"profile-0\"",
            "\"profile-02\"",
            "\"profile--1\"",
            "\"profile-2\", \"profile-3\"",
            "*",
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(IF_MATCH, HeaderValue::from_str(invalid).unwrap());
            let error = expected_profile_version(&headers, request_id).unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST, "accepted {invalid}");
            assert_eq!(error.code, "INVALID_PROFILE_VERSION");
        }
        let missing = expected_profile_version(&HeaderMap::new(), request_id).unwrap_err();
        assert_eq!(missing.status, StatusCode::PRECONDITION_REQUIRED);
        assert_eq!(missing.code, "PROFILE_VERSION_REQUIRED");

        let mut valid = HeaderMap::new();
        valid.insert(IF_MATCH, HeaderValue::from_static("\"profile-42\""));
        assert_eq!(expected_profile_version(&valid, request_id).unwrap(), 42);
    }

    #[test]
    fn delete_rejects_any_idempotency_key_and_nonempty_body() {
        let request_id = RequestId(Uuid::nil());
        assert!(validate_delete_request(request_id, &HeaderMap::new(), b"").is_ok());

        let mut headers = HeaderMap::new();
        headers.append("idempotency-key", HeaderValue::from_static(""));
        let error = validate_delete_request(request_id, &headers, b"").unwrap_err();
        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "INVALID_REQUEST");

        headers.append("idempotency-key", HeaderValue::from_static("second"));
        assert_eq!(
            validate_delete_request(request_id, &headers, b"")
                .unwrap_err()
                .code,
            "INVALID_REQUEST"
        );
        assert_eq!(
            validate_delete_request(request_id, &HeaderMap::new(), b"{}")
                .unwrap_err()
                .code,
            "INVALID_REQUEST"
        );
    }

    #[test]
    fn deletion_errors_distinguish_proven_acceptance_from_ambiguous_failure() {
        let request_id = RequestId(Uuid::nil());
        let pre_commit = deletion_service_error(
            request_id,
            &AccountDeletionServiceError::Storage(DbError::InvalidData("sentinel".to_owned())),
        );
        assert_eq!(pre_commit.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(pre_commit.code, "SERVICE_UNAVAILABLE");
        assert!(!pre_commit.message.contains("account is disabled"));

        let operation = domain::AccountDeletionOperation {
            operation_id: Uuid::now_v7(),
            state: domain::AccountDeletionState::Requested,
            requested_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let post_commit = deletion_service_error(
            request_id,
            &AccountDeletionServiceError::ExternalizationUnavailable {
                operation,
                source: account_deletion::ExternalDeletionLedgerError::Unavailable,
            },
        );
        assert_eq!(post_commit.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(post_commit.code, "ACCOUNT_DELETION_UNAVAILABLE");
        assert!(post_commit.message.contains("account is disabled"));
        assert_eq!(post_commit.retry_after_seconds, Some(30));
    }

    #[test]
    fn recent_auth_rejects_missing_future_and_stale_claims_at_exact_boundaries() {
        let request_id = RequestId(Uuid::nil());
        let now = Utc.with_ymd_and_hms(2026, 8, 1, 12, 0, 0).unwrap();
        let maximum_age = Duration::from_secs(300);
        assert!(require_recent_auth_at(request_id, Some(now), maximum_age, now).is_ok());
        assert!(
            require_recent_auth_at(
                request_id,
                Some(now - chrono::TimeDelta::seconds(300)),
                maximum_age,
                now,
            )
            .is_ok()
        );
        for invalid in [
            None,
            Some(now + chrono::TimeDelta::milliseconds(1)),
            Some(now - chrono::TimeDelta::milliseconds(300_001)),
        ] {
            let error = require_recent_auth_at(request_id, invalid, maximum_age, now).unwrap_err();
            assert_eq!(error.status, StatusCode::UNAUTHORIZED);
            assert_eq!(error.code, "REAUTHENTICATION_REQUIRED");
        }
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn personalized_surfaces_are_private_and_vary_on_authorization() {
        let app = Router::new()
            .route(
                "/v1/papers/{paper_id}/comments",
                get(|| async { StatusCode::OK }).post(|| async { StatusCode::OK }),
            )
            .route(
                "/v1/comments/{comment_id}",
                axum::routing::patch(|| async { StatusCode::OK }),
            )
            .route("/v1/me/reading-feed", get(|| async { StatusCode::OK }))
            .route("/v1/discovery/profile", get(|| async { StatusCode::OK }))
            .route(
                "/v1/discovery/batches/{batch_id}/feedback",
                post(|| async { StatusCode::SERVICE_UNAVAILABLE }),
            )
            .route("/v1/me/paper-searches", post(|| async { StatusCode::OK }))
            .route("/v1/search/lookup", get(|| async { StatusCode::OK }))
            .route("/v1/events/batch", post(|| async { StatusCode::OK }))
            .route(
                "/v1/me/reading-briefs",
                post(|| async { StatusCode::SERVICE_UNAVAILABLE }),
            )
            .route("/v1/subscriptions", get(|| async { StatusCode::OK }))
            .route(
                "/v1/notifications",
                get(|| async { StatusCode::SERVICE_UNAVAILABLE }),
            )
            .route(
                "/v1/notification-preferences",
                get(|| async { StatusCode::OK }),
            )
            .route("/v1/library/items", get(|| async { StatusCode::OK }))
            .route(
                "/v1/library/lists",
                post(|| async { StatusCode::SERVICE_UNAVAILABLE }),
            )
            .route(
                "/v1/me/library/imports",
                post(|| async { StatusCode::SERVICE_UNAVAILABLE }),
            )
            .route(
                "/v1/papers/{paper_id}/figures/{figure_id}/asset",
                get(|| async {
                    let mut response = StatusCode::OK.into_response();
                    response.headers_mut().insert(
                        CACHE_CONTROL,
                        HeaderValue::from_static("private, max-age=86400, immutable"),
                    );
                    response
                }),
            )
            .route(
                "/v1/papers/{paper_id}/assistant/feedback",
                post(|| async { StatusCode::CREATED }),
            )
            .layer(middleware::from_fn(private_account_cache_control));

        let guest = app
            .clone()
            .oneshot(
                Request::get(format!("/v1/papers/{}/comments", Uuid::now_v7()))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(guest.status(), StatusCode::OK);
        assert!(!guest.headers().contains_key(CACHE_CONTROL));
        assert_eq!(guest.headers()[VARY], "Authorization");

        let personalized = app
            .clone()
            .oneshot(
                Request::get(format!("/v1/papers/{}/comments", Uuid::now_v7()))
                    .header(AUTHORIZATION, "Bearer opaque")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(personalized.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(personalized.headers()[VARY], "Authorization");

        let reading_feed = app
            .clone()
            .oneshot(
                Request::get("/v1/me/reading-feed")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(reading_feed.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(reading_feed.headers()[VARY], "Authorization");

        let figure_asset = app
            .clone()
            .oneshot(
                Request::get(format!(
                    "/v1/papers/{}/figures/{}/asset",
                    Uuid::now_v7(),
                    Uuid::now_v7()
                ))
                .body(Body::empty())
                .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            figure_asset.headers()[CACHE_CONTROL],
            "private, max-age=86400, immutable"
        );
        assert_eq!(figure_asset.headers()[VARY], "Authorization");

        let personalized_error = app
            .clone()
            .oneshot(
                Request::post("/v1/me/library/imports")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(personalized_error.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(
            personalized_error.headers()[CACHE_CONTROL],
            ACCOUNT_CACHE_CONTROL
        );
        assert_eq!(personalized_error.headers()[VARY], "Authorization");

        for request in [
            Request::post(format!("/v1/papers/{}/comments", Uuid::now_v7()))
                .body(Body::empty())
                .unwrap(),
            Request::patch(format!("/v1/comments/{}", Uuid::now_v7()))
                .body(Body::empty())
                .unwrap(),
            Request::post(format!("/v1/users/{}/reports", Uuid::now_v7()))
                .body(Body::empty())
                .unwrap(),
            Request::post("/v1/me/paper-searches")
                .body(Body::empty())
                .unwrap(),
            Request::get("/v1/search/lookup?q=private")
                .body(Body::empty())
                .unwrap(),
            Request::post("/v1/events/batch")
                .body(Body::empty())
                .unwrap(),
            Request::post("/v1/me/reading-briefs")
                .body(Body::empty())
                .unwrap(),
            Request::get("/v1/subscriptions")
                .body(Body::empty())
                .unwrap(),
            Request::get("/v1/notifications")
                .body(Body::empty())
                .unwrap(),
            Request::get("/v1/notification-preferences")
                .body(Body::empty())
                .unwrap(),
            Request::get("/v1/library/items")
                .body(Body::empty())
                .unwrap(),
            Request::post("/v1/library/lists")
                .body(Body::empty())
                .unwrap(),
            Request::get("/v1/discovery/profile")
                .body(Body::empty())
                .unwrap(),
            Request::post(format!("/v1/discovery/batches/{}/feedback", Uuid::now_v7()))
                .body(Body::empty())
                .unwrap(),
            Request::post(format!("/v1/papers/{}/assistant/feedback", Uuid::now_v7()))
                .body(Body::empty())
                .unwrap(),
        ] {
            let response = app.clone().oneshot(request).await.unwrap();
            assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
            assert_eq!(response.headers()[VARY], "Authorization");
        }
    }

    #[test]
    fn patch_json_distinguishes_omitted_null_and_value_and_denies_unknown_fields() {
        let body: ProfileUpdateBody = serde_json::from_str(r#"{"display_name":null}"#).unwrap();
        assert_eq!(body.handle, ProfilePatchField::Omitted);
        assert_eq!(body.display_name, ProfilePatchField::Null);
        assert_eq!(body.accept_terms_version, ProfilePatchField::Omitted);
        assert_eq!(
            body.accept_community_guidelines_version,
            ProfilePatchField::Omitted
        );

        let body: ProfileUpdateBody =
            serde_json::from_str(r#"{"handle":"Ada_Reader","display_name":"Ada"}"#).unwrap();
        assert_eq!(
            body.handle,
            ProfilePatchField::Value("Ada_Reader".to_owned())
        );
        assert_eq!(
            body.display_name,
            ProfilePatchField::Value("Ada".to_owned())
        );
        assert!(serde_json::from_str::<ProfileUpdateBody>(r#"{"admin":true}"#).is_err());
    }

    #[test]
    fn response_exposes_separate_account_and_comment_consent_state() {
        let terms = TermsVersion::parse("2026-07-31").unwrap();
        let guidelines = domain::CommunityGuidelinesVersion::parse("2026-08-01").unwrap();
        let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let mut user = User {
            id: AuthenticatedUserId::new(Uuid::now_v7()),
            handle: Some(Handle::parse("ada_reader").unwrap()),
            display_name: None,
            status: AccountStatus::Active,
            profile_version: 1,
            terms_version: None,
            terms_accepted_at: None,
            community_guidelines_version: None,
            community_guidelines_accepted_at: None,
            created_at: now,
            updated_at: now,
            last_seen_at: now,
        };
        let envelope = AccountProfileEnvelope::new(&user, &terms, &guidelines);
        assert!(!envelope.account.profile_complete);
        assert!(!envelope.account.terms_current);
        assert!(!envelope.account.community_guidelines_current);
        assert!(!envelope.account.comment_profile_complete);

        user.terms_version = Some(terms.clone());
        user.terms_accepted_at = Some(now);
        let envelope = AccountProfileEnvelope::new(&user, &terms, &guidelines);
        assert!(envelope.account.profile_complete);
        assert!(envelope.account.terms_current);
        assert!(!envelope.account.comment_profile_complete);

        user.community_guidelines_version = Some(guidelines.clone());
        user.community_guidelines_accepted_at = Some(now);
        let envelope = AccountProfileEnvelope::new(&user, &terms, &guidelines);
        assert!(envelope.account.community_guidelines_current);
        assert!(envelope.account.comment_profile_complete);
    }

    #[derive(Clone)]
    struct FakeAccountStore {
        user: Arc<Mutex<User>>,
        provision_count: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl AccountStore for FakeAccountStore {
        async fn provision_oidc_identity(
            &self,
            issuer: &str,
            subject: &str,
            _last_seen_interval: Duration,
        ) -> Result<User, DbError> {
            assert_eq!(issuer, "https://identity.example/realms/pakperk");
            assert_eq!(subject, "private-subject");
            self.provision_count.fetch_add(1, Ordering::SeqCst);
            Ok(self.user.lock().unwrap().clone())
        }

        async fn get(&self, user_id: AuthenticatedUserId) -> Result<Option<User>, DbError> {
            let user = self.user.lock().unwrap().clone();
            Ok((user.id == user_id).then_some(user))
        }

        async fn update_profile(
            &self,
            user_id: AuthenticatedUserId,
            expected_profile_version: i64,
            patch: &ProfilePatch,
        ) -> Result<ProfileUpdateOutcome, DbError> {
            let mut user = self.user.lock().unwrap();
            if user.id != user_id {
                return Ok(ProfileUpdateOutcome::NotFound);
            }
            if user.profile_version != expected_profile_version {
                return Ok(ProfileUpdateOutcome::VersionConflict {
                    current_version: user.profile_version,
                });
            }
            if patch.handle.is_some() && user.handle.is_some() {
                return Ok(ProfileUpdateOutcome::HandleAlreadySet);
            }
            if let Some(handle) = &patch.handle {
                user.handle = Some(handle.clone());
            }
            if let Some(display_name) = &patch.display_name {
                user.display_name = display_name.clone();
            }
            let update_time = user.updated_at + chrono::TimeDelta::seconds(1);
            if let Some(terms) = &patch.terms_version {
                user.terms_version = Some(terms.clone());
                user.terms_accepted_at = Some(update_time);
            }
            if let Some(guidelines) = &patch.community_guidelines_version {
                user.community_guidelines_version = Some(guidelines.clone());
                user.community_guidelines_accepted_at = Some(update_time);
            }
            user.profile_version += 1;
            user.updated_at = update_time;
            Ok(ProfileUpdateOutcome::Updated(user.clone()))
        }
    }

    #[derive(Debug)]
    struct AllowingRateLimit;

    #[async_trait]
    impl RateLimitStore for AllowingRateLimit {
        async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
            Ok(RateLimitDecision {
                allowed: true,
                limit: request.limit(),
                remaining: request.limit().saturating_sub(1),
                reset_at: Utc::now() + chrono::TimeDelta::minutes(1),
                retry_after_seconds: None,
            })
        }
    }

    struct AcceptingVerifier;

    #[async_trait]
    impl TokenVerifier for AcceptingVerifier {
        async fn verify(&self, _bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError> {
            Ok(VerifiedOidcClaims::try_from_verified_parts(
                "https://identity.example/realms/pakperk".to_owned(),
                "private-subject".to_owned(),
                vec!["pakperk-api".to_owned()],
                Utc::now() + chrono::TimeDelta::minutes(5),
                Some(Utc::now()),
                Some(Utc::now()),
            )
            .unwrap())
        }
    }

    struct RejectingVerifier(VerifyError);

    #[async_trait]
    impl TokenVerifier for RejectingVerifier {
        async fn verify(&self, _bearer_token: &str) -> Result<VerifiedOidcClaims, VerifyError> {
            Err(self.0)
        }
    }

    fn account_api_config(enabled: bool) -> ApiConfig {
        let terms = TermsVersion::parse("2026-07-31").unwrap();
        let account = enabled.then(|| AccountFeatureConfig {
            oidc: auth::OidcVerifierConfig::new(
                "https://identity.example/realms/pakperk".parse().unwrap(),
                "pakperk-api",
                vec![auth::OidcAlgorithm::Rs256],
            ),
            current_terms_version: terms,
            current_community_guidelines_version: domain::CommunityGuidelinesVersion::parse(
                "2026-08-01",
            )
            .unwrap(),
            last_seen_interval: Duration::from_secs(15 * 60),
            profile_update_limit: 5,
            profile_update_window: Duration::from_secs(60 * 60),
            auth_retry_initial: Duration::from_secs(5),
            auth_retry_maximum: Duration::from_secs(5 * 60),
            identity_fingerprints: None,
        });
        ApiConfig {
            environment: ApiEnvironment::Development,
            features: FeatureFlags {
                accounts: enabled,
                library: false,
                library_writes: false,
                comments: false,
                comment_creation: false,
                account_deletion: false,
                ..FeatureFlags::default()
            },
            accounts: account,
            library: None,
            comments: None,
            account_deletion: None,
            visual_assets: None,
            paper_resolution: crate::config::PaperResolutionFeatureConfig::default(),
            reading_feed: crate::config::ReadingFeedFeatureConfig::default(),
            request_origin: crate::config::RequestOriginConfig::for_local_development(
                "account-route-request-origin-secret-0123456789",
            )
            .unwrap(),
            cursors: crate::config::CursorConfig::for_local_development(
                "account-route-cursor-test-seed",
            )
            .unwrap(),
            bind: "127.0.0.1:0".parse().unwrap(),
            database_url: "postgres://test:test@127.0.0.1/test".to_owned(),
            database_pool_size: 1,
            run_migrations: false,
            request_timeout: Duration::from_secs(30),
            chat_request_timeout: Duration::from_secs(70),
            max_request_bytes: 64 * 1024,
            cors_allowed_origins: Vec::new(),
            arxiv: ArxivClientConfig {
                user_agent: "PakperkAccountApiTest/0.1".to_owned(),
                contact_email: "testing@pakperk.org".to_owned(),
                ..ArxivClientConfig::default()
            },
            arxiv_cache_ttl: Duration::from_secs(60),
            fulltext_policy: FulltextPolicy::Prototype,
            embedding_dimension: None,
            llm: None,
            prepare_requests_per_minute: 10,
            chat_requests_per_minute: 10,
        }
    }

    fn lazy_database() -> db::Database {
        db::Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        )
    }

    fn active_user() -> User {
        let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        User {
            id: AuthenticatedUserId::new(Uuid::now_v7()),
            handle: None,
            display_name: Some(DisplayName::parse("Ada Reader").unwrap()),
            status: AccountStatus::Active,
            profile_version: 1,
            terms_version: None,
            terms_accepted_at: None,
            community_guidelines_version: None,
            community_guidelines_accepted_at: None,
            created_at: now,
            updated_at: now,
            last_seen_at: now,
        }
    }

    fn account_test_state_with(
        verifier: Arc<dyn TokenVerifier>,
        user: User,
    ) -> (AppState, Arc<AtomicUsize>) {
        let config = account_api_config(true);
        let auth = AuthRuntime::ready(verifier);
        let mut state = AppState::new_with_auth(lazy_database(), &config, auth).unwrap();
        let user = Arc::new(Mutex::new(user));
        let provision_count = Arc::new(AtomicUsize::new(0));
        state.accounts = Some(AccountService::with_stores(
            Arc::new(FakeAccountStore {
                user,
                provision_count: Arc::clone(&provision_count),
            }),
            Arc::new(AllowingRateLimit),
            AccountPolicy::new(
                TermsVersion::parse("2026-07-31").unwrap(),
                domain::CommunityGuidelinesVersion::parse("2026-08-01").unwrap(),
                Duration::from_secs(15 * 60),
                5,
                Duration::from_secs(60 * 60),
            )
            .unwrap(),
        ));
        (state, provision_count)
    }

    fn account_test_app_with(
        verifier: Arc<dyn TokenVerifier>,
        user: User,
    ) -> (Router, Arc<AtomicUsize>) {
        let config = account_api_config(true);
        let (state, provision_count) = account_test_state_with(verifier, user);
        (build_router(state, &config), provision_count)
    }

    fn account_test_app() -> (Router, Arc<AtomicUsize>) {
        account_test_app_with(Arc::new(AcceptingVerifier), active_user())
    }

    #[tokio::test]
    async fn request_principal_keeps_valid_bearer_and_anonymous_session_distinct() {
        let user = active_user();
        let user_id = user.id.into_inner();
        let session_id = Uuid::new_v4();
        let request_id = Uuid::now_v7();
        assert_ne!(user_id, session_id);
        let (state, provision_count) = account_test_state_with(Arc::new(AcceptingVerifier), user);
        let app = Router::new()
            .route(
                "/principal",
                get(|principal: RequestPrincipal| async move {
                    Json(serde_json::json!({
                        "user_id": principal.user_id,
                        "anonymous_session_id": principal.anonymous_session_id,
                        "request_id": principal.request_id,
                    }))
                }),
            )
            .with_state(state)
            .layer(middleware::from_fn(request_id_middleware));

        let response = app
            .oneshot(
                Request::get("/principal")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .header(SESSION_ID_HEADER, session_id.to_string())
                    .header(REQUEST_ID_HEADER, request_id.to_string())
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response_json(response).await,
            serde_json::json!({
                "user_id": user_id,
                "anonymous_session_id": session_id,
                "request_id": request_id,
            })
        );
        assert_eq!(provision_count.load(Ordering::SeqCst), 1);
    }

    async fn patch_profile(app: &Router, profile_etag: Option<&str>, body: &str) -> Response {
        let mut request = Request::builder()
            .method(Method::PATCH)
            .uri("/v1/me")
            .header(AUTHORIZATION, "Bearer private-token")
            .header(CONTENT_TYPE, "application/json");
        if let Some(profile_etag) = profile_etag {
            request = request.header(IF_MATCH, profile_etag);
        }
        app.clone()
            .oneshot(request.body(Body::from(body.to_owned())).unwrap())
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn account_router_jit_provisions_and_enforces_profile_etags() {
        let (app, provision_count) = account_test_app();

        let response = app
            .clone()
            .oneshot(Request::get("/v1/me").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(response.headers()[WWW_AUTHENTICATE], "Bearer");
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);

        let response = app
            .clone()
            .oneshot(
                Request::get("/v1/me")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[ETAG], "\"profile-1\"");
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        let body = response_json(response).await;
        assert_eq!(body["account"]["profile_complete"], false);
        assert_eq!(body["account"]["terms_current"], false);
        assert!(!body.to_string().contains("private-token"));
        assert!(!body.to_string().contains("private-subject"));

        let response = patch_profile(&app, None, r#"{"display_name":null}"#).await;
        assert_eq!(response.status(), StatusCode::PRECONDITION_REQUIRED);
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "PROFILE_VERSION_REQUIRED"
        );

        let response = patch_profile(
            &app,
            Some("\"profile-1\""),
            r#"{"handle":"Ada_Reader","accept_terms_version":"2026-07-31"}"#,
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[ETAG], "\"profile-2\"");
        let body = response_json(response).await;
        assert_eq!(body["account"]["handle"], "ada_reader");
        assert_eq!(body["account"]["profile_complete"], true);
        assert_eq!(body["account"]["terms_current"], true);
        assert_eq!(body["account"]["community_guidelines_current"], false);
        assert_eq!(body["account"]["comment_profile_complete"], false);

        let response = patch_profile(
            &app,
            Some("\"profile-2\""),
            r#"{"accept_community_guidelines_version":"2026-08-01"}"#,
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[ETAG], "\"profile-3\"");
        let body = response_json(response).await;
        assert_eq!(body["account"]["community_guidelines_current"], true);
        assert_eq!(body["account"]["comment_profile_complete"], true);

        let response =
            patch_profile(&app, Some("\"profile-1\""), r#"{"display_name":"Changed"}"#).await;
        assert_eq!(response.status(), StatusCode::PRECONDITION_FAILED);
        assert_eq!(response.headers()[ETAG], "\"profile-3\"");
        assert_eq!(
            response_json(response).await["error"]["code"],
            "PROFILE_VERSION_CONFLICT"
        );
        assert_eq!(provision_count.load(Ordering::SeqCst), 5);
    }

    #[tokio::test]
    async fn account_json_rejections_are_stable_and_private() {
        let (app, _) = account_test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/v1/me")
                    .header(AUTHORIZATION, "Bearer private-token")
                    .header(IF_MATCH, "\"profile-1\"")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"unknown":true}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "INVALID_REQUEST"
        );
    }

    #[tokio::test]
    async fn account_feature_off_is_404_and_unavailable_oidc_does_not_gate_optional_routes() {
        let disabled_config = account_api_config(false);
        let disabled = build_router(
            AppState::new(lazy_database(), &disabled_config).unwrap(),
            &disabled_config,
        );
        assert_eq!(
            disabled
                .oneshot(Request::get("/v1/me").body(Body::empty()).unwrap())
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );

        let config = account_api_config(true);
        let auth = AuthRuntime::unavailable(
            AuthUnavailableReason::ProviderUnavailable,
            Duration::from_secs(19),
        );
        let state = AppState::new_with_auth(lazy_database(), &config, auth).unwrap();
        let public = Router::new()
            .route(
                "/public",
                get(|principal: RequestPrincipal| async move {
                    assert!(principal.user_id.is_none());
                    StatusCode::OK
                }),
            )
            .route(
                "/required",
                get(|_principal: AuthenticatedPrincipal| async { StatusCode::OK }),
            )
            .with_state(state)
            .layer(middleware::from_fn(request_id_middleware));
        let response = public
            .clone()
            .oneshot(
                Request::get("/public")
                    .header(AUTHORIZATION, "Bearer ignored-while-offline")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let response = public
            .oneshot(
                Request::get("/required")
                    .header(AUTHORIZATION, "Bearer cannot-be-verified")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(response.headers()[RETRY_AFTER], "19");
        assert_eq!(
            response_json(response).await["error"]["code"],
            "AUTHENTICATION_UNAVAILABLE"
        );
    }

    #[tokio::test]
    async fn public_paper_route_treats_ready_metadata_outage_as_guest() {
        let (app, provision_count) = account_test_app_with(
            Arc::new(RejectingVerifier(VerifyError::MetadataUnavailable)),
            active_user(),
        );
        let response = app
            .oneshot(
                Request::get("/v1/papers/by-arxiv/definitely-invalid")
                    .header(AUTHORIZATION, "Bearer cannot-be-verified-now")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "INVALID_ARXIV_ID"
        );
        assert_eq!(provision_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn public_paper_route_treats_inactive_account_as_guest_but_private_route_denies_it() {
        let mut suspended = active_user();
        suspended.status = AccountStatus::Suspended;
        let (app, provision_count) = account_test_app_with(Arc::new(AcceptingVerifier), suspended);

        let response = app
            .clone()
            .oneshot(
                Request::get("/v1/papers/by-arxiv/definitely-invalid")
                    .header(AUTHORIZATION, "Bearer suspended-account-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "INVALID_ARXIV_ID"
        );

        let response = app
            .oneshot(
                Request::get("/v1/me")
                    .header(AUTHORIZATION, "Bearer suspended-account-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert_eq!(response.headers()[CACHE_CONTROL], ACCOUNT_CACHE_CONTROL);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "ACCOUNT_SUSPENDED"
        );
        assert_eq!(provision_count.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn public_paper_route_rejects_malformed_and_cryptographically_invalid_bearers() {
        let (app, provision_count) = account_test_app_with(
            Arc::new(RejectingVerifier(VerifyError::InvalidSignature)),
            active_user(),
        );

        for authorization in ["Basic credentials", "Bearer invalid-signature"] {
            let response = app
                .clone()
                .oneshot(
                    Request::get("/v1/papers/by-arxiv/definitely-invalid")
                        .header(AUTHORIZATION, authorization)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
            assert_eq!(response.headers()[WWW_AUTHENTICATE], "Bearer");
            assert_eq!(
                response_json(response).await["error"]["code"],
                "UNAUTHENTICATED"
            );
        }
        assert_eq!(provision_count.load(Ordering::SeqCst), 0);
    }

    async fn response_json(response: Response) -> serde_json::Value {
        let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
}
