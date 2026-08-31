use std::{future::Future, time::Instant};

use axum::{
    Extension, Json,
    body::Bytes,
    extract::{Path, State},
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{ETAG, IF_MATCH},
    },
    response::{IntoResponse, Response},
};
use chrono::Utc;
use observability::{OperationClass, OperationOutcome, record_operation};
use research_profiles::{
    DeleteAuthorCommand, DeleteTopicCommand, ExplicitCategoryInput, ResearchProfileService,
    ResearchProfileServiceError, ResetProfileCommand, UpdateProfileCommand, UpsertAuthorCommand,
    UpsertTopicCommand,
};
use tracing::error;
use uuid::Uuid;

use crate::{
    AppState,
    dto::{
        ResearchProfileEnvelope, ResearchProfileExportEnvelope, ResearchProfileInterestsEnvelope,
        ResetResearchProfileBody, UpdateResearchProfileBody, UpsertProfileAuthorBody,
        UpsertProfileTopicBody,
    },
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
};

use super::library::idempotency_key;

const MAX_IF_MATCH_BYTES: usize = 64;

#[utoipa::path(
    get,
    path = "/v1/discovery/profile",
    tag = "research profiles",
    description = "Returns future-discovery preferences for the authenticated account. This dormant feature never reads or changes queue state.",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, description = "Current profile, including a virtual revision-zero default before the first mutation", body = ResearchProfileEnvelope, headers(("ETag" = String, description = "Strong validator in the form quoted research-profile-N"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.read",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn get_research_profile(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<Response, ApiError> {
    let profile = observe_profile(
        OperationClass::ResearchProfileRead,
        profile_service(&state, request_id)?.get(principal.user_id),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    profile_response(request_id, &profile)
}

#[utoipa::path(
    put,
    path = "/v1/discovery/profile",
    tag = "research profiles",
    description = "Updates only future-discovery preferences and explicit categories. It never changes active queue state.",
    security(("oidcBearer" = [])),
    params(
        ("If-Match" = String, Header, description = "Required exact research-profile ETag"),
        ("Idempotency-Key" = Uuid, Header, description = "Required canonical operation UUID matching operation_id")
    ),
    request_body(content = UpdateResearchProfileBody, description = "Strict profile patch; unknown and queue-control fields are rejected"),
    responses(
        (status = 200, description = "Updated profile or durable exact replay", body = ResearchProfileEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_IDEMPOTENCY_KEY, IDEMPOTENCY_KEY_MISMATCH, INVALID_RESEARCH_PROFILE_REVISION, or INVALID_RESEARCH_PROFILE_UPDATE", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "RESEARCH_PROFILE_OPERATION_CONFLICT or RESEARCH_PROFILE_LIMIT_REACHED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "RESEARCH_PROFILE_REVISION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema, headers(("ETag" = String, description = "Current profile validator"))),
        (status = 428, description = "RESEARCH_PROFILE_REVISION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.write",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn update_research_profile(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<UpdateResearchProfileBody>,
) -> Result<Response, ApiError> {
    let expected_revision = expected_revision(&headers, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let profile = observe_profile(
        OperationClass::ResearchProfileWrite,
        profile_service(&state, request_id)?.update(
            principal.user_id,
            UpdateProfileCommand {
                expected_revision,
                operation_id,
                personalization_enabled: body.personalization_enabled,
                preferred_discovery_mode: body.preferred_discovery_mode.map(Into::into),
                discovery_mode: body.discovery_mode.map(Into::into),
                brief_size: body.brief_size,
                recency_weight: body.recency_weight,
                novelty_weight: body.novelty_weight,
                diversity_weight: body.diversity_weight,
                explicit_categories: body.explicit_categories.map(|categories| {
                    categories
                        .into_iter()
                        .map(|category| ExplicitCategoryInput {
                            category: category.category,
                            weight: category.weight,
                        })
                        .collect()
                }),
            },
        ),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    profile_response(request_id, &profile)
}

#[utoipa::path(
    get,
    path = "/v1/discovery/profile/interests",
    tag = "research profiles",
    description = "Returns explicit, feedback, and inferred interests in separate groups. Inferred interests are never silently represented as follows.",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, description = "Current separated interest groups", body = ResearchProfileInterestsEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.read",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn get_research_profile_interests(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<Response, ApiError> {
    let profile = observe_profile(
        OperationClass::ResearchProfileRead,
        profile_service(&state, request_id)?.get(principal.user_id),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    response_with_tag(
        request_id,
        profile.profile_revision,
        Json(ResearchProfileInterestsEnvelope::from(&profile)).into_response(),
    )
}

#[utoipa::path(
    put,
    path = "/v1/discovery/profile/topics/{topic_id}",
    tag = "research profiles",
    security(("oidcBearer" = [])),
    params(
        ("topic_id" = Uuid, Path, description = "Canonical topic ID"),
        ("If-Match" = String, Header, description = "Required exact research-profile ETag"),
        ("Idempotency-Key" = Uuid, Header, description = "Required canonical operation UUID matching operation_id")
    ),
    request_body(content = UpsertProfileTopicBody, description = "Creates or replaces only an explicit topic follow"),
    responses(
        (status = 200, description = "Updated profile or durable exact replay", body = ResearchProfileEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "Invalid request, idempotency metadata, or profile precondition", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "TOPIC_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "RESEARCH_PROFILE_OPERATION_CONFLICT or RESEARCH_PROFILE_LIMIT_REACHED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "RESEARCH_PROFILE_REVISION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 428, description = "RESEARCH_PROFILE_REVISION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.write",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn upsert_research_profile_topic(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(topic_id): Path<Uuid>,
    Json(body): Json<UpsertProfileTopicBody>,
) -> Result<Response, ApiError> {
    let expected_revision = expected_revision(&headers, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let profile = observe_profile(
        OperationClass::ResearchProfileWrite,
        profile_service(&state, request_id)?.upsert_topic(
            principal.user_id,
            UpsertTopicCommand {
                expected_revision,
                operation_id,
                topic_id,
                polarity: body.polarity.into(),
                strength: body.strength,
                user_alias: body.user_alias,
            },
        ),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    profile_response(request_id, &profile)
}

#[utoipa::path(
    delete,
    path = "/v1/discovery/profile/topics/{topic_id}",
    tag = "research profiles",
    description = "Removes only the explicit topic row. DELETE bodies are rejected.",
    security(("oidcBearer" = [])),
    params(
        ("topic_id" = Uuid, Path, description = "Canonical topic ID"),
        ("If-Match" = String, Header, description = "Required exact research-profile ETag"),
        ("Idempotency-Key" = Uuid, Header, description = "Required canonical operation UUID")
    ),
    responses(
        (status = 200, description = "Updated profile or durable exact replay", body = ResearchProfileEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST or invalid precondition/idempotency metadata", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "RESEARCH_PROFILE_OPERATION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "RESEARCH_PROFILE_REVISION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 428, description = "RESEARCH_PROFILE_REVISION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.write",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn delete_research_profile_topic(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(topic_id): Path<Uuid>,
    body: Bytes,
) -> Result<Response, ApiError> {
    reject_delete_body(&body, request_id)?;
    let profile = observe_profile(
        OperationClass::ResearchProfileWrite,
        profile_service(&state, request_id)?.delete_topic(
            principal.user_id,
            DeleteTopicCommand {
                expected_revision: expected_revision(&headers, request_id)?,
                operation_id: idempotency_key(&headers, request_id)?,
                topic_id,
            },
        ),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    profile_response(request_id, &profile)
}

#[utoipa::path(
    put,
    path = "/v1/discovery/profile/authors/{author_key}",
    tag = "research profiles",
    security(("oidcBearer" = [])),
    params(
        ("author_key" = String, Path, description = "Normalized public-source author key"),
        ("If-Match" = String, Header, description = "Required exact research-profile ETag"),
        ("Idempotency-Key" = Uuid, Header, description = "Required canonical operation UUID matching operation_id")
    ),
    request_body(content = UpsertProfileAuthorBody, description = "Creates or replaces only an explicit author follow"),
    responses(
        (status = 200, description = "Updated profile or durable exact replay", body = ResearchProfileEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "Invalid request, idempotency metadata, or profile precondition", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "RESEARCH_PROFILE_OPERATION_CONFLICT or RESEARCH_PROFILE_LIMIT_REACHED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "RESEARCH_PROFILE_REVISION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 428, description = "RESEARCH_PROFILE_REVISION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.write",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn upsert_research_profile_author(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(author_key): Path<String>,
    Json(body): Json<UpsertProfileAuthorBody>,
) -> Result<Response, ApiError> {
    let expected_revision = expected_revision(&headers, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let profile = observe_profile(
        OperationClass::ResearchProfileWrite,
        profile_service(&state, request_id)?.upsert_author(
            principal.user_id,
            UpsertAuthorCommand {
                expected_revision,
                operation_id,
                author_key,
                display_name: body.display_name,
            },
        ),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    profile_response(request_id, &profile)
}

#[utoipa::path(
    delete,
    path = "/v1/discovery/profile/authors/{author_key}",
    tag = "research profiles",
    description = "Removes only the explicit author row. DELETE bodies are rejected.",
    security(("oidcBearer" = [])),
    params(
        ("author_key" = String, Path, description = "Normalized public-source author key"),
        ("If-Match" = String, Header, description = "Required exact research-profile ETag"),
        ("Idempotency-Key" = Uuid, Header, description = "Required canonical operation UUID")
    ),
    responses(
        (status = 200, description = "Updated profile or durable exact replay", body = ResearchProfileEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST or invalid precondition/idempotency metadata", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "RESEARCH_PROFILE_OPERATION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "RESEARCH_PROFILE_REVISION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 428, description = "RESEARCH_PROFILE_REVISION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.write",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn delete_research_profile_author(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(author_key): Path<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    reject_delete_body(&body, request_id)?;
    let profile = observe_profile(
        OperationClass::ResearchProfileWrite,
        profile_service(&state, request_id)?.delete_author(
            principal.user_id,
            DeleteAuthorCommand {
                expected_revision: expected_revision(&headers, request_id)?,
                operation_id: idempotency_key(&headers, request_id)?,
                author_key,
            },
        ),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    profile_response(request_id, &profile)
}

#[utoipa::path(
    post,
    path = "/v1/discovery/profile/reset",
    tag = "research profiles",
    description = "Resets inferred interests or the complete recommendation profile. Queue and library state are outside this transaction and remain unchanged.",
    security(("oidcBearer" = [])),
    params(
        ("If-Match" = String, Header, description = "Required exact research-profile ETag"),
        ("Idempotency-Key" = Uuid, Header, description = "Required canonical operation UUID matching operation_id")
    ),
    request_body(content = ResetResearchProfileBody, description = "Strict reset scope"),
    responses(
        (status = 200, description = "Reset profile or durable exact replay", body = ResearchProfileEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "Invalid request, idempotency metadata, or profile precondition", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "RESEARCH_PROFILE_OPERATION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 412, description = "RESEARCH_PROFILE_REVISION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 428, description = "RESEARCH_PROFILE_REVISION_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.reset",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn reset_research_profile(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<ResetResearchProfileBody>,
) -> Result<Response, ApiError> {
    let expected_revision = expected_revision(&headers, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let profile = observe_profile(
        OperationClass::ResearchProfileReset,
        profile_service(&state, request_id)?.reset(
            principal.user_id,
            ResetProfileCommand {
                expected_revision,
                operation_id,
                scope: body.scope.into(),
            },
        ),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    profile_response(request_id, &profile)
}

#[utoipa::path(
    get,
    path = "/v1/discovery/profile/export",
    tag = "research profiles",
    description = "Exports the bounded current profile and separated interests. It excludes bearer data, idempotency hashes, and raw interaction history.",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, description = "Privacy-bounded current profile export", body = ResearchProfileExportEnvelope, headers(("ETag" = String, description = "Current research-profile validator"), ("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "RESEARCH_PROFILE_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "research_profile.read",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn export_research_profile(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<Response, ApiError> {
    let profile = observe_profile(
        OperationClass::ResearchProfileRead,
        profile_service(&state, request_id)?.get(principal.user_id),
    )
    .await
    .map_err(|error_value| profile_service_error(request_id, &error_value))?;
    response_with_tag(
        request_id,
        profile.profile_revision,
        Json(ResearchProfileExportEnvelope::new(&profile, Utc::now())).into_response(),
    )
}

fn profile_service(
    state: &AppState,
    request_id: RequestId,
) -> Result<&ResearchProfileService, ApiError> {
    state.research_profiles.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "FEATURE_DISABLED",
            "Research profiles are disabled.",
            false,
        )
    })
}

async fn observe_profile<T>(
    class: OperationClass,
    future: impl Future<Output = Result<T, ResearchProfileServiceError>>,
) -> Result<T, ResearchProfileServiceError> {
    let started = Instant::now();
    let result = future.await;
    record_operation(class, profile_operation_outcome(&result), started.elapsed());
    result
}

fn profile_operation_outcome<T>(
    result: &Result<T, ResearchProfileServiceError>,
) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(ResearchProfileServiceError::Storage(_)) => OperationOutcome::RetryableFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

fn matching_operation_id(
    headers: &HeaderMap,
    body_operation_id: Uuid,
    request_id: RequestId,
) -> Result<Uuid, ApiError> {
    let operation_id = idempotency_key(headers, request_id)?;
    if operation_id != body_operation_id {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "IDEMPOTENCY_KEY_MISMATCH",
            "Idempotency-Key must exactly match operation_id.",
            false,
        ));
    }
    Ok(operation_id)
}

fn reject_delete_body(body: &[u8], request_id: RequestId) -> Result<(), ApiError> {
    if body.is_empty() {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "DELETE research-profile mutations do not accept a request body.",
            false,
        ))
    }
}

fn expected_revision(headers: &HeaderMap, request_id: RequestId) -> Result<i64, ApiError> {
    let mut values = headers.get_all(IF_MATCH).iter();
    let Some(value) = values.next() else {
        return Err(ApiError::new(
            request_id,
            StatusCode::PRECONDITION_REQUIRED,
            "RESEARCH_PROFILE_REVISION_REQUIRED",
            "If-Match with the current research-profile ETag is required.",
            false,
        ));
    };
    if values.next().is_some() {
        return Err(invalid_revision(request_id));
    }
    let raw = value.to_str().map_err(|_| invalid_revision(request_id))?;
    if raw.len() > MAX_IF_MATCH_BYTES || raw.trim() != raw {
        return Err(invalid_revision(request_id));
    }
    let revision = raw
        .strip_prefix("\"research-profile-")
        .and_then(|value| value.strip_suffix('"'))
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|revision| *revision >= 0)
        .ok_or_else(|| invalid_revision(request_id))?;
    if research_profile_entity_tag(revision).as_ref() != Some(value) {
        return Err(invalid_revision(request_id));
    }
    Ok(revision)
}

fn invalid_revision(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_RESEARCH_PROFILE_REVISION",
        "If-Match must be an exact strong research-profile ETag.",
        false,
    )
}

fn research_profile_entity_tag(revision: i64) -> Option<HeaderValue> {
    (revision >= 0)
        .then(|| HeaderValue::from_str(&format!("\"research-profile-{revision}\"")))
        .transpose()
        .ok()
        .flatten()
}

fn profile_response(
    request_id: RequestId,
    profile: &research_profiles::ResearchProfileSnapshot,
) -> Result<Response, ApiError> {
    response_with_tag(
        request_id,
        profile.profile_revision,
        Json(ResearchProfileEnvelope::from(profile)).into_response(),
    )
}

fn response_with_tag(
    request_id: RequestId,
    revision: i64,
    mut response: Response,
) -> Result<Response, ApiError> {
    let tag = research_profile_entity_tag(revision).ok_or_else(|| {
        profile_service_error(request_id, &ResearchProfileServiceError::InvalidRevision)
    })?;
    response.headers_mut().insert(ETAG, tag);
    Ok(response)
}

fn profile_service_error(
    request_id: RequestId,
    error_value: &ResearchProfileServiceError,
) -> ApiError {
    use ResearchProfileServiceError::{
        AccountNotFound, Deleted, DeletionPending, EmptyUpdate, IdempotencyConflict,
        InterestLimitReached, InvalidAuthorDisplayName, InvalidAuthorKey, InvalidBriefSize,
        InvalidCategories, InvalidCategory, InvalidCleanupBatch, InvalidOperationId,
        InvalidRevision, InvalidTopicAlias, InvalidTopicId, InvalidTopicStrength, InvalidWeight,
        RateLimited, RevisionConflict, Storage, Suspended, TopicNotFound,
    };

    match error_value {
        InvalidOperationId => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_IDEMPOTENCY_KEY",
            "Idempotency-Key must contain one non-nil canonical UUID.",
            false,
        ),
        InvalidRevision => invalid_revision(request_id),
        EmptyUpdate
        | InvalidCategory
        | InvalidCategories
        | InvalidBriefSize
        | InvalidWeight
        | InvalidTopicId
        | InvalidTopicAlias
        | InvalidTopicStrength
        | InvalidAuthorKey
        | InvalidAuthorDisplayName => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RESEARCH_PROFILE_UPDATE",
            "The research-profile update is invalid.",
            false,
        ),
        Suspended => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_SUSPENDED",
            "This account is suspended.",
            false,
        ),
        DeletionPending | Deleted => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_DELETION_PENDING",
            "This account is unavailable.",
            false,
        ),
        RevisionConflict { current_revision } => revision_conflict(request_id, *current_revision),
        TopicNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "TOPIC_NOT_FOUND",
            "The requested topic was not found.",
            false,
        ),
        InterestLimitReached => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "RESEARCH_PROFILE_LIMIT_REACHED",
            "The research-profile interest limit was reached.",
            false,
        ),
        IdempotencyConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "RESEARCH_PROFILE_OPERATION_CONFLICT",
            "The operation ID was already used for a different profile intent.",
            false,
        ),
        RateLimited {
            retry_after_seconds,
        } => ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many research-profile updates. Please wait before retrying.",
            true,
        )
        .with_retry_after(*retry_after_seconds),
        AccountNotFound | Storage(_) | InvalidCleanupBatch => {
            error!(request_id = %request_id.0, error.kind = "research_profile_service", "research-profile operation failed");
            ApiError::new(
                request_id,
                StatusCode::SERVICE_UNAVAILABLE,
                "RESEARCH_PROFILE_SERVICE_UNAVAILABLE",
                "The research-profile service is temporarily unavailable.",
                true,
            )
        }
    }
}

fn revision_conflict(request_id: RequestId, current_revision: i64) -> ApiError {
    let error = ApiError::new(
        request_id,
        StatusCode::PRECONDITION_FAILED,
        "RESEARCH_PROFILE_REVISION_CONFLICT",
        "The research profile changed. Reload it before trying again.",
        false,
    );
    if let Some(tag) = research_profile_entity_tag(current_revision) {
        error.with_entity_tag(tag)
    } else {
        error
    }
}

#[cfg(test)]
mod tests {
    use research_profiles::StoreError;

    use super::*;

    #[test]
    fn revision_validator_accepts_virtual_zero_and_rejects_weak_or_ambiguous_values() {
        let request_id = RequestId(Uuid::nil());
        let mut headers = HeaderMap::new();
        headers.insert(IF_MATCH, HeaderValue::from_static("\"research-profile-0\""));
        assert_eq!(expected_revision(&headers, request_id).unwrap(), 0);

        for value in [
            "W/\"research-profile-0\"",
            "\"research-profile--1\"",
            "\"profile-0\"",
            "\"research-profile-01\"",
        ] {
            let mut invalid = HeaderMap::new();
            invalid.insert(IF_MATCH, HeaderValue::from_str(value).unwrap());
            assert_eq!(
                expected_revision(&invalid, request_id).unwrap_err().code,
                "INVALID_RESEARCH_PROFILE_REVISION"
            );
        }
        assert_eq!(
            expected_revision(&HeaderMap::new(), request_id)
                .unwrap_err()
                .status,
            StatusCode::PRECONDITION_REQUIRED
        );
    }

    #[test]
    fn stable_service_errors_preserve_conflict_and_retry_metadata() {
        let request_id = RequestId(Uuid::nil());
        let conflict = profile_service_error(
            request_id,
            &ResearchProfileServiceError::RevisionConflict {
                current_revision: 7,
            },
        );
        assert_eq!(conflict.status, StatusCode::PRECONDITION_FAILED);
        assert_eq!(conflict.code, "RESEARCH_PROFILE_REVISION_CONFLICT");

        let limited = profile_service_error(
            request_id,
            &ResearchProfileServiceError::RateLimited {
                retry_after_seconds: 19,
            },
        );
        assert_eq!(limited.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(limited.retry_after_seconds, Some(19));
    }

    #[test]
    fn profile_observability_outcomes_are_closed() {
        assert_eq!(
            profile_operation_outcome(&Ok::<(), ResearchProfileServiceError>(())),
            OperationOutcome::Success
        );
        assert_eq!(
            profile_operation_outcome(&Err::<(), _>(ResearchProfileServiceError::InvalidCategory,)),
            OperationOutcome::Rejected
        );
        assert_eq!(
            profile_operation_outcome(&Err::<(), _>(ResearchProfileServiceError::Storage(
                StoreError::Unavailable
            ),)),
            OperationOutcome::RetryableFailure
        );
    }
}
