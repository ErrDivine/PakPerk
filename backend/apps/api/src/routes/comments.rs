use std::{net::SocketAddr, time::Instant};

use axum::{
    Extension, Json,
    body::Bytes,
    extract::{ConnectInfo, FromRequestParts, Path, Query, State},
    http::{StatusCode, request::Parts},
    response::{IntoResponse, Response},
};
use comments::{
    CommentServiceError, CreateCommentRequest, EditCommentRequest, ReportCommentRequest,
    ReportUserRequest,
};
use domain::{AccountStatus, AuthenticatedUserId};
use observability::{OperationClass, OperationOutcome, record_operation};
use tracing::error;
use uuid::Uuid;

use crate::{
    AppState,
    dto::{
        BlockedUserEnvelope, BlockedUserPageEnvelope, CommentEnvelope, CommentListParams,
        CommentPageEnvelope, CommentReportEnvelope, CreateCommentBody, EditCommentBody,
        ReportCommentBody, ReportUserBody, UserReportEnvelope,
    },
    error::{ApiError, RequestId},
    middleware::{AuthenticatedPrincipal, RequestPrincipal},
};

const DEFAULT_PAGE_LIMIT: u32 = 50;
const MAXIMUM_PAGE_LIMIT: u32 = 200;
const MAXIMUM_CURSOR_BYTES: usize = 512;

pub(crate) struct CommentCreationEnabled;

impl FromRequestParts<AppState> for CommentCreationEnabled {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let request_id = request_id(parts);
        if state.feature_flags().comment_creation {
            Ok(Self)
        } else {
            Err(ApiError::new(
                request_id,
                StatusCode::SERVICE_UNAVAILABLE,
                "FEATURE_DISABLED",
                "New comments are temporarily disabled.",
                false,
            ))
        }
    }
}

pub(crate) struct TrustedCommentOrigin(String);

impl FromRequestParts<AppState> for TrustedCommentOrigin {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let request_id = request_id(parts);
        let remote = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .copied()
            .ok_or_else(|| comment_service_unavailable(request_id))?;
        Ok(Self(
            state.request_limiter.origin_scope(&parts.headers, remote.0),
        ))
    }
}

fn request_id(parts: &Parts) -> RequestId {
    parts
        .extensions
        .get::<RequestId>()
        .copied()
        .unwrap_or_else(|| RequestId(Uuid::now_v7()))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/comments",
    tag = "comments",
    description = "Newest-first published comments. Guests receive the public view; an authenticated view additionally applies durable blocks. Registered only when COMMENTS_ENABLED=true.",
    security((), ("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path, description = "Existing cached paper ID"),
        ("cursor" = Option<String>, Query, max_length = 512, description = "Opaque cursor from next_cursor"),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 200, description = "Bounded page size; defaults to 50")
    ),
    responses(
        (status = 200, description = "Published comments visible to this guest or viewer", body = CommentPageEnvelope),
        (status = 400, description = "INVALID_REQUEST, INVALID_COMMENT_CURSOR, or INVALID_COMMENT_LIMIT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "A supplied bearer token is invalid or expired", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 404, description = "PAPER_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_paper_comments(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
    Query(params): Query<CommentListParams>,
) -> Result<Json<CommentPageEnvelope>, ApiError> {
    let request_id = RequestId(principal.request_id);
    let (cursor, limit) = list_parameters(&params, request_id)?;
    let page = comment_service(&state, request_id)?
        .list_paper(
            paper_id,
            principal.user_id.map(AuthenticatedUserId::new),
            cursor,
            limit,
        )
        .await
        .map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(Json(page.into()))
}

#[utoipa::path(
    post,
    path = "/v1/papers/{paper_id}/comments",
    tag = "comments",
    description = "Creates one normalized flat comment. COMMENT_CREATION_ENABLED can reject only this operation while preserving reads and all safety controls.",
    security(("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path, description = "Existing cached paper ID")),
    request_body(
        content = CreateCommentBody,
        description = "Strict comment intent; client_request_id is the durable idempotency key",
        example = json!({"client_request_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","body":"The ablation changes how I read the main result."})
    ),
    responses(
        (status = 201, description = "Canonical accepted comment, published or privately pending review", body = CommentEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 200, description = "Exact idempotent replay of the canonical comment", body = CommentEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST, INVALID_CLIENT_REQUEST_ID, or INVALID_COMMENT_BODY", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_INCOMPLETE, TERMS_ACCEPTANCE_REQUIRED, ACCOUNT_SUSPENDED, or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "PAPER_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "IDEMPOTENCY_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 422, description = "COMMENT_REJECTED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared account or origin window resets"))),
        (status = 503, description = "FEATURE_DISABLED, AUTHENTICATION_UNAVAILABLE, or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn create_comment(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(paper_id): Path<Uuid>,
    principal: AuthenticatedPrincipal,
    _creation_enabled: CommentCreationEnabled,
    TrustedCommentOrigin(origin_scope): TrustedCommentOrigin,
    Json(body): Json<CreateCommentBody>,
) -> Result<Response, ApiError> {
    let started = Instant::now();
    let result = comment_service(&state, request_id)?
        .create(
            principal.user_id,
            paper_id,
            CreateCommentRequest {
                client_request_id: body.client_request_id,
                body: body.body,
                origin_scope,
            },
        )
        .await;
    record_operation(
        OperationClass::CommentCreate,
        comment_operation_outcome(&result),
        started.elapsed(),
    );
    record_operation(
        OperationClass::DatabaseWrite,
        comment_operation_outcome(&result),
        started.elapsed(),
    );
    let result = result.map_err(|error_value| comment_error(request_id, &error_value))?;
    let status = if result.replayed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    Ok((status, Json(CommentEnvelope::from(result.comment))).into_response())
}

#[utoipa::path(
    patch,
    path = "/v1/comments/{comment_id}",
    tag = "comments",
    description = "Replaces the authenticated author's comment body using optimistic version concurrency. The comment-creation kill switch does not disable author edits.",
    security(("oidcBearer" = [])),
    params(("comment_id" = Uuid, Path, description = "Comment ID")),
    request_body(content = EditCommentBody, example = json!({"body":"Updated observation.","expected_version":2})),
    responses(
        (status = 200, description = "Canonical edited comment", body = CommentEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST, INVALID_COMMENT_BODY, or INVALID_COMMENT_VERSION", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "COMMENT_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "COMMENT_EDIT_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 422, description = "COMMENT_REJECTED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared mutation window resets"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn edit_comment(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(comment_id): Path<Uuid>,
    principal: AuthenticatedPrincipal,
    Json(body): Json<EditCommentBody>,
) -> Result<Json<CommentEnvelope>, ApiError> {
    let started = Instant::now();
    let comment = comment_service(&state, request_id)?
        .edit(
            principal.user_id,
            comment_id,
            EditCommentRequest {
                body: body.body,
                expected_version: body.expected_version,
            },
        )
        .await;
    record_operation(
        OperationClass::CommentEdit,
        comment_operation_outcome(&comment),
        started.elapsed(),
    );
    record_operation(
        OperationClass::DatabaseWrite,
        comment_operation_outcome(&comment),
        started.elapsed(),
    );
    let comment = comment.map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(Json(comment.into()))
}

#[utoipa::path(
    delete,
    path = "/v1/comments/{comment_id}",
    tag = "comments",
    description = "Repeat-safe author deletion. Request bodies are rejected; COMMENT_CREATION_ENABLED does not disable deletion.",
    security(("oidcBearer" = [])),
    params(("comment_id" = Uuid, Path, description = "Comment ID")),
    responses(
        (status = 204, description = "Comment is deleted", headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "COMMENT_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared mutation window resets"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_comment(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(comment_id): Path<Uuid>,
    principal: AuthenticatedPrincipal,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    require_empty_body(&body, request_id)?;
    comment_service(&state, request_id)?
        .delete(principal.user_id, comment_id)
        .await
        .map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(StatusCode::NO_CONTENT)
}

#[utoipa::path(
    post,
    path = "/v1/comments/{comment_id}/reports",
    tag = "comments",
    description = "Creates or returns the authenticated user's canonical report. Report detail never appears in the response or diagnostics.",
    security(("oidcBearer" = [])),
    params(("comment_id" = Uuid, Path, description = "Comment ID")),
    request_body(content = ReportCommentBody, example = json!({"reason":"harassment","detail":"Optional bounded context"})),
    responses(
        (status = 200, description = "Canonical idempotent report receipt", body = CommentReportEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST or INVALID_REPORT_DETAIL", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "COMMENT_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared account or origin window resets"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn report_comment(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(comment_id): Path<Uuid>,
    principal: AuthenticatedPrincipal,
    TrustedCommentOrigin(origin_scope): TrustedCommentOrigin,
    Json(body): Json<ReportCommentBody>,
) -> Result<Json<CommentReportEnvelope>, ApiError> {
    let started = Instant::now();
    let result = comment_service(&state, request_id)?
        .report(
            principal.user_id,
            comment_id,
            ReportCommentRequest {
                reason: body.reason.into(),
                detail: body.detail,
                origin_scope,
            },
        )
        .await;
    record_operation(
        OperationClass::CommentReport,
        comment_operation_outcome(&result),
        started.elapsed(),
    );
    record_operation(
        OperationClass::DatabaseWrite,
        comment_operation_outcome(&result),
        started.elapsed(),
    );
    let result = result.map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(Json(result.report.into()))
}

#[utoipa::path(
    post,
    path = "/v1/users/{user_id}/reports",
    tag = "comments",
    description = "Creates or returns the authenticated user's canonical report about a public user. Reporting is independent from blocking and never changes comment visibility.",
    security(("oidcBearer" = [])),
    params(("user_id" = Uuid, Path, description = "Local public user ID to report")),
    request_body(content = ReportUserBody, example = json!({"reason":"impersonation","detail":"Optional bounded context"})),
    responses(
        (status = 200, description = "Canonical idempotent user-report receipt", body = UserReportEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST, INVALID_REPORT_DETAIL, or CANNOT_REPORT_SELF", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "USER_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared account, target, or origin window resets"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn report_user(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(user_id): Path<Uuid>,
    principal: AuthenticatedPrincipal,
    TrustedCommentOrigin(origin_scope): TrustedCommentOrigin,
    Json(body): Json<ReportUserBody>,
) -> Result<Json<UserReportEnvelope>, ApiError> {
    let started = Instant::now();
    let result = comment_service(&state, request_id)?
        .report_user(
            principal.user_id,
            AuthenticatedUserId::new(user_id),
            ReportUserRequest {
                reason: body.reason.into(),
                detail: body.detail,
                origin_scope,
            },
        )
        .await;
    record_operation(
        OperationClass::CommentReport,
        comment_operation_outcome(&result),
        started.elapsed(),
    );
    record_operation(
        OperationClass::DatabaseWrite,
        comment_operation_outcome(&result),
        started.elapsed(),
    );
    let result = result.map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(Json(result.report.into()))
}

#[utoipa::path(
    put,
    path = "/v1/me/blocked-users/{user_id}",
    tag = "comments",
    description = "Idempotently blocks a public comment author. The authenticated comment view filters that author immediately and durably.",
    security(("oidcBearer" = [])),
    params(("user_id" = Uuid, Path, description = "Local user ID to block")),
    responses(
        (status = 200, description = "Canonical blocked-user projection", body = BlockedUserEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST or CANNOT_BLOCK_SELF", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "USER_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared mutation window resets"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn block_user(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(user_id): Path<Uuid>,
    principal: AuthenticatedPrincipal,
    body: Bytes,
) -> Result<Json<BlockedUserEnvelope>, ApiError> {
    require_empty_body(&body, request_id)?;
    let result = comment_service(&state, request_id)?
        .block(principal.user_id, AuthenticatedUserId::new(user_id))
        .await
        .map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(Json(result.blocked_user.into()))
}

#[utoipa::path(
    delete,
    path = "/v1/me/blocked-users/{user_id}",
    tag = "comments",
    description = "Idempotently removes a user block. Request bodies are rejected.",
    security(("oidcBearer" = [])),
    params(("user_id" = Uuid, Path, description = "Local user ID to unblock")),
    responses(
        (status = 204, description = "User is not blocked", headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST or CANNOT_BLOCK_SELF", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared mutation window resets"))),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn unblock_user(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(user_id): Path<Uuid>,
    principal: AuthenticatedPrincipal,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    require_empty_body(&body, request_id)?;
    comment_service(&state, request_id)?
        .unblock(principal.user_id, AuthenticatedUserId::new(user_id))
        .await
        .map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(StatusCode::NO_CONTENT)
}

#[utoipa::path(
    get,
    path = "/v1/me/blocked-users",
    tag = "comments",
    description = "Newest-first account-owned block list with opaque cursor pagination.",
    security(("oidcBearer" = [])),
    params(
        ("cursor" = Option<String>, Query, max_length = 512, description = "Opaque cursor from next_cursor"),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 200, description = "Bounded page size; defaults to 50")
    ),
    responses(
        (status = 200, description = "Blocked users", body = BlockedUserPageEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST, INVALID_COMMENT_CURSOR, or INVALID_COMMENT_LIMIT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_blocked_users(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<CommentListParams>,
) -> Result<Json<BlockedUserPageEnvelope>, ApiError> {
    let (cursor, limit) = list_parameters(&params, request_id)?;
    let page = comment_service(&state, request_id)?
        .list_blocks(principal.user_id, cursor, limit)
        .await
        .map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(Json(page.into()))
}

#[utoipa::path(
    get,
    path = "/v1/me/comments",
    tag = "comments",
    description = "Newest-first comments owned by the authenticated account, including private pending-review status.",
    security(("oidcBearer" = [])),
    params(
        ("cursor" = Option<String>, Query, max_length = 512, description = "Opaque cursor from next_cursor"),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 200, description = "Bounded page size; defaults to 50")
    ),
    responses(
        (status = 200, description = "Authenticated user's comments", body = CommentPageEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST, INVALID_COMMENT_CURSOR, or INVALID_COMMENT_LIMIT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or COMMENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_my_comments(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<CommentListParams>,
) -> Result<Json<CommentPageEnvelope>, ApiError> {
    let (cursor, limit) = list_parameters(&params, request_id)?;
    let page = comment_service(&state, request_id)?
        .list_mine(principal.user_id, cursor, limit)
        .await
        .map_err(|error_value| comment_error(request_id, &error_value))?;
    Ok(Json(page.into()))
}

fn list_parameters(
    params: &CommentListParams,
    request_id: RequestId,
) -> Result<(Option<&str>, u32), ApiError> {
    if params
        .cursor
        .as_ref()
        .is_some_and(|cursor| cursor.is_empty() || cursor.len() > MAXIMUM_CURSOR_BYTES)
    {
        return Err(invalid_cursor(request_id));
    }
    let limit = params.limit.unwrap_or(DEFAULT_PAGE_LIMIT);
    if !(1..=MAXIMUM_PAGE_LIMIT).contains(&limit) {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_COMMENT_LIMIT",
            "The comment page limit must be between 1 and 200.",
            false,
        ));
    }
    Ok((params.cursor.as_deref(), limit))
}

fn require_empty_body(body: &Bytes, request_id: RequestId) -> Result<(), ApiError> {
    if body.is_empty() {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "This operation does not accept a request body.",
            false,
        ))
    }
}

fn comment_service(
    state: &AppState,
    request_id: RequestId,
) -> Result<&comments::CommentService, ApiError> {
    state
        .comments
        .as_ref()
        .ok_or_else(|| comment_service_unavailable(request_id))
}

#[allow(clippy::too_many_lines)] // Exhaustive stable HTTP mapping stays centralized and auditable.
fn comment_error(request_id: RequestId, error_value: &CommentServiceError) -> ApiError {
    match error_value {
        CommentServiceError::InvalidClientRequestId => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_CLIENT_REQUEST_ID",
            "client_request_id must be a non-nil UUID.",
            false,
        ),
        CommentServiceError::InvalidExpectedVersion => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_COMMENT_VERSION",
            "expected_version must be a positive integer.",
            false,
        ),
        CommentServiceError::InvalidPageLimit => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_COMMENT_LIMIT",
            "The comment page limit is invalid.",
            false,
        ),
        CommentServiceError::InvalidCursor => invalid_cursor(request_id),
        CommentServiceError::InvalidBody(_) => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_COMMENT_BODY",
            "The comment body does not meet the text policy.",
            false,
        ),
        CommentServiceError::InvalidReportDetail(_) => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REPORT_DETAIL",
            "The optional report detail does not meet the text policy.",
            false,
        ),
        CommentServiceError::ContentRejected => ApiError::new(
            request_id,
            StatusCode::UNPROCESSABLE_ENTITY,
            "COMMENT_REJECTED",
            "The comment could not be accepted under the content policy.",
            false,
        ),
        CommentServiceError::Inactive(AccountStatus::Suspended) => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_SUSPENDED",
            "This account is suspended.",
            false,
        ),
        CommentServiceError::Inactive(AccountStatus::DeletionPending | AccountStatus::Deleted) => {
            ApiError::new(
                request_id,
                StatusCode::FORBIDDEN,
                "ACCOUNT_DELETION_PENDING",
                "This account is unavailable.",
                false,
            )
        }
        CommentServiceError::AccountIncomplete => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_INCOMPLETE",
            "Choose a handle before posting.",
            false,
        ),
        CommentServiceError::TermsAcceptanceRequired => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "TERMS_ACCEPTANCE_REQUIRED",
            "Accept the current Terms and Community Guidelines before posting.",
            false,
        ),
        CommentServiceError::PaperNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "PAPER_NOT_FOUND",
            "The requested paper is not in the metadata cache.",
            false,
        ),
        CommentServiceError::CommentNotFound
        | CommentServiceError::AlreadyDeleted
        | CommentServiceError::NotAuthor => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "COMMENT_NOT_FOUND",
            "The requested comment is unavailable.",
            false,
        ),
        CommentServiceError::EditConflict { .. } => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "COMMENT_EDIT_CONFLICT",
            "The comment changed. Reload it before editing again.",
            false,
        ),
        CommentServiceError::IdempotencyConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "IDEMPOTENCY_CONFLICT",
            "This client request ID was already used for a different comment intent.",
            false,
        ),
        CommentServiceError::CannotBlockSelf => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "CANNOT_BLOCK_SELF",
            "An account cannot block itself.",
            false,
        ),
        CommentServiceError::CannotReportSelf => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "CANNOT_REPORT_SELF",
            "An account cannot report itself.",
            false,
        ),
        CommentServiceError::BlockTargetNotFound | CommentServiceError::ReportTargetNotFound => {
            ApiError::new(
                request_id,
                StatusCode::NOT_FOUND,
                "USER_NOT_FOUND",
                "The requested user does not exist.",
                false,
            )
        }
        CommentServiceError::RateLimited {
            retry_after_seconds,
        } => ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many comment actions. Please wait before retrying.",
            true,
        )
        .with_retry_after(*retry_after_seconds),
        CommentServiceError::AccountNotFound
        | CommentServiceError::Inactive(AccountStatus::Active)
        | CommentServiceError::InvalidOriginScope
        | CommentServiceError::Storage(_)
        | CommentServiceError::InvalidRateLimitPolicy => {
            error!(request_id = %request_id.0, error.kind = "comment_service", "comment service operation failed");
            comment_service_unavailable(request_id)
        }
    }
}

fn comment_operation_outcome<T>(result: &Result<T, CommentServiceError>) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(CommentServiceError::Storage(_) | CommentServiceError::RateLimited { .. }) => {
            OperationOutcome::RetryableFailure
        }
        Err(CommentServiceError::InvalidRateLimitPolicy) => OperationOutcome::TerminalFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

fn invalid_cursor(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_COMMENT_CURSOR",
        "The comment cursor is invalid or expired.",
        false,
    )
}

fn comment_service_unavailable(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "COMMENT_SERVICE_UNAVAILABLE",
        "The comment service is temporarily unavailable.",
        true,
    )
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use arxiv_client::ArxivClientConfig;
    use auth::{AuthRuntime, AuthUnavailableReason};
    use axum::{
        Router,
        body::Body,
        http::{Request, header::AUTHORIZATION},
        middleware,
        routing::get,
    };
    use domain::{CommunityGuidelinesVersion, FulltextPolicy, TermsVersion};
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt as _;

    use super::*;
    use crate::{
        AccountFeatureConfig, ApiConfig, ApiEnvironment, CommentFeatureConfig, FeatureFlags,
        middleware::request_id_middleware,
    };

    #[test]
    fn list_validation_is_bounded_and_cursors_remain_opaque() {
        let request_id = RequestId(Uuid::nil());
        let valid = CommentListParams {
            cursor: Some("opaque-token".to_owned()),
            limit: Some(25),
        };
        assert_eq!(
            list_parameters(&valid, request_id).unwrap(),
            (Some("opaque-token"), 25)
        );
        for params in [
            CommentListParams {
                cursor: None,
                limit: Some(0),
            },
            CommentListParams {
                cursor: None,
                limit: Some(201),
            },
        ] {
            assert_eq!(
                list_parameters(&params, request_id).unwrap_err().code,
                "INVALID_COMMENT_LIMIT"
            );
        }
        let oversized = CommentListParams {
            cursor: Some("x".repeat(MAXIMUM_CURSOR_BYTES + 1)),
            limit: None,
        };
        assert_eq!(
            list_parameters(&oversized, request_id).unwrap_err().code,
            "INVALID_COMMENT_CURSOR"
        );
    }

    #[test]
    fn service_errors_are_stable_and_never_include_ugc_or_moderation_reasons() {
        let request_id = RequestId(Uuid::nil());
        let invalid = CommentServiceError::InvalidBody(
            domain::CommentBody::parse("sentinel-private-ugc\u{0007}").unwrap_err(),
        );
        let response = comment_error(request_id, &invalid);
        assert_eq!(response.code, "INVALID_COMMENT_BODY");
        assert!(!response.message.contains("sentinel-private-ugc"));

        let conflict = comment_error(
            request_id,
            &CommentServiceError::EditConflict {
                current_version: 42,
            },
        );
        assert_eq!(conflict.code, "COMMENT_EDIT_CONFLICT");
        assert!(!conflict.message.contains("42"));

        let incomplete = comment_error(request_id, &CommentServiceError::AccountIncomplete);
        assert_eq!(incomplete.status, StatusCode::FORBIDDEN);
        assert_eq!(incomplete.code, "ACCOUNT_INCOMPLETE");
        let policies = comment_error(request_id, &CommentServiceError::TermsAcceptanceRequired);
        assert_eq!(policies.status, StatusCode::FORBIDDEN);
        assert_eq!(policies.code, "TERMS_ACCEPTANCE_REQUIRED");

        let missing = comment_error(request_id, &CommentServiceError::CommentNotFound);
        let foreign = comment_error(request_id, &CommentServiceError::NotAuthor);
        assert_eq!(foreign.status, StatusCode::NOT_FOUND);
        assert_eq!(foreign.code, missing.code);
        assert_eq!(foreign.message, missing.message);
    }

    #[tokio::test]
    async fn public_comment_auth_degrades_to_guest_when_oidc_metadata_is_unavailable() {
        let config = comment_api_config();
        let database = db::Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        );
        let state = AppState::new_with_auth(
            database,
            &config,
            AuthRuntime::unavailable(
                AuthUnavailableReason::ProviderUnavailable,
                Duration::from_secs(30),
            ),
        )
        .unwrap();
        let app = Router::new()
            .route(
                "/comments",
                get(|principal: RequestPrincipal| async move {
                    Json(serde_json::json!({"authenticated": principal.user_id.is_some()}))
                }),
            )
            .with_state(state)
            .layer(middleware::from_fn(request_id_middleware));

        for authorization in [None, Some("Bearer temporarily-unverifiable")] {
            let mut request = Request::get("/comments");
            if let Some(value) = authorization {
                request = request.header(AUTHORIZATION, value);
            }
            let response = app
                .clone()
                .oneshot(request.body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let body = axum::body::to_bytes(response.into_body(), 1_024)
                .await
                .unwrap();
            assert_eq!(
                serde_json::from_slice::<serde_json::Value>(&body).unwrap(),
                serde_json::json!({"authenticated": false})
            );
        }
    }

    fn comment_api_config() -> ApiConfig {
        ApiConfig {
            environment: ApiEnvironment::Development,
            features: FeatureFlags {
                accounts: true,
                library: false,
                library_writes: false,
                comments: true,
                comment_creation: false,
                account_deletion: false,
            },
            accounts: Some(AccountFeatureConfig {
                oidc: auth::OidcVerifierConfig::new(
                    "https://identity.example/realms/pakperk".parse().unwrap(),
                    "pakperk-api",
                    vec![auth::OidcAlgorithm::Rs256],
                ),
                current_terms_version: TermsVersion::parse("2026-08-01").unwrap(),
                current_community_guidelines_version: CommunityGuidelinesVersion::parse(
                    "2026-08-01",
                )
                .unwrap(),
                last_seen_interval: Duration::from_secs(15 * 60),
                profile_update_limit: 5,
                profile_update_window: Duration::from_secs(60 * 60),
                auth_retry_initial: Duration::from_secs(5),
                auth_retry_maximum: Duration::from_secs(5 * 60),
                identity_fingerprints: None,
            }),
            library: None,
            comments: Some(CommentFeatureConfig::for_test().unwrap()),
            account_deletion: None,
            request_origin: crate::config::RequestOriginConfig::for_local_development(
                "strong-comment-origin-test-secret-0123456789",
            )
            .unwrap(),
            bind: "127.0.0.1:0".parse().unwrap(),
            database_url: "postgres://test:test@127.0.0.1/test".to_owned(),
            database_pool_size: 1,
            run_migrations: false,
            request_timeout: Duration::from_secs(5),
            chat_request_timeout: Duration::from_secs(5),
            max_request_bytes: 64 * 1024,
            cors_allowed_origins: Vec::new(),
            arxiv: ArxivClientConfig {
                user_agent: "PakperkCommentApiTest/0.1".to_owned(),
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
}
