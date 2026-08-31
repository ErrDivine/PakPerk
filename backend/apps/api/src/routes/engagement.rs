use std::time::Instant;

use axum::{
    Extension, Json,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use chrono::{NaiveTime, Utc};
use engagement::{
    BriefCreateCommand, BriefProgressCommand, EngagementService, EngagementServiceError,
    NotificationPreferences, SubscriptionFrequency, SubscriptionKind, SubscriptionWrite,
};
use observability::{OperationClass, OperationOutcome, record_operation};
use tracing::error;
use uuid::Uuid;

use crate::{
    AppState,
    dto::{
        CreateReadingBriefBody, CreateSubscriptionBody, NotificationListParams,
        NotificationMutationEnvelope, NotificationPreferencesBody, NotificationPreferencesEnvelope,
        NotificationsEnvelope, ReadingBriefEnvelope, SubscriptionEnvelope, SubscriptionsEnvelope,
        UpdateReadingBriefProgressBody, UpdateSubscriptionBody,
    },
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    routes::support::apply_summary_policy,
};

use super::{
    library::idempotency_key,
    reading_feed::{discovery_defaults, effective_recommendation_mode},
};

#[utoipa::path(
    post,
    path = "/v1/me/reading-briefs",
    tag = "reading briefs",
    description = "Creates a bounded queue or discovery brief through the canonical reading-feed gate; never prepares a paper. Omitted mode and brief size use current research-profile defaults when profiles are enabled. An explicit mode wins, while an unavailable profile safely falls back to Recent and the service-default size.",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = Uuid, Header)),
    request_body(content = CreateReadingBriefBody),
    responses(
        (status = 200, body = crate::openapi::ReadingBriefEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "reading_brief.create",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn create_reading_brief(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<CreateReadingBriefBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().reading_briefs, request_id)?;
    let operation_id = matching_operation(&headers, body.operation_id, request_id)?;
    let now = Utc::now();
    let engagement = service(&state, request_id)?;
    let requested_recommendation_mode = body.recommendation_mode.map(Into::into);
    let defaults = discovery_defaults(
        &state,
        principal.user_id,
        request_id,
        engagement.default_brief_size(),
    )
    .await;
    let started = Instant::now();
    let result = engagement
        .create_brief(BriefCreateCommand {
            user_id: principal.user_id,
            operation_id,
            requested_recommendation_mode,
            effective_recommendation_mode: effective_recommendation_mode(
                requested_recommendation_mode,
                defaults,
            ),
            brief_size: defaults.brief_size,
            category: body.category,
            local_date: now.date_naive(),
            now,
        })
        .await;
    record_operation(
        OperationClass::ReadingBrief,
        brief_operation_outcome(&result),
        started.elapsed(),
    );
    let mut brief = result.map_err(|error_value| service_error(request_id, &error_value))?;
    mask_brief(&state, request_id, &mut brief).await?;
    Ok(Json(ReadingBriefEnvelope {
        brief: Some(brief.into()),
    }))
}

#[utoipa::path(
    get,
    path = "/v1/me/reading-briefs/current",
    tag = "reading briefs",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, body = crate::openapi::ReadingBriefEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn current_reading_brief(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().reading_briefs, request_id)?;
    let mut brief = service(&state, request_id)?
        .current_brief(principal.user_id)
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    if let Some(value) = &mut brief {
        mask_brief(&state, request_id, value).await?;
    }
    Ok(Json(ReadingBriefEnvelope {
        brief: brief.map(Into::into),
    }))
}

#[utoipa::path(
    post,
    path = "/v1/me/reading-briefs/{id}/progress",
    tag = "reading briefs",
    description = "Persists the next resume position with an idempotency key and progress revision. Completing a brief never changes library state or proves queue emptiness.",
    security(("oidcBearer" = [])),
    params(("id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body(content = UpdateReadingBriefProgressBody),
    responses(
        (status = 200, body = crate::openapi::ReadingBriefEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(name = "reading_brief.progress", skip_all)]
pub(crate) async fn update_reading_brief_progress(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    Json(body): Json<UpdateReadingBriefProgressBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().reading_briefs, request_id)?;
    let operation_id = matching_operation(&headers, body.operation_id, request_id)?;
    let mut brief = service(&state, request_id)?
        .advance_brief(BriefProgressCommand {
            user_id: principal.user_id,
            operation_id,
            brief_id: id,
            expected_progress_revision: body.expected_progress_revision,
            position: body.position,
            now: Utc::now(),
        })
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    mask_brief(&state, request_id, &mut brief).await?;
    Ok(Json(ReadingBriefEnvelope {
        brief: Some(brief.into()),
    }))
}

#[utoipa::path(
    get,
    path = "/v1/subscriptions",
    tag = "subscriptions",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, body = crate::openapi::SubscriptionsEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_subscriptions(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().subscriptions, request_id)?;
    let items = service(&state, request_id)?
        .subscriptions(principal.user_id)
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(SubscriptionsEnvelope {
        items: items.into_iter().map(Into::into).collect(),
    }))
}

#[utoipa::path(
    post,
    path = "/v1/subscriptions",
    tag = "subscriptions",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = Uuid, Header)),
    request_body(content = CreateSubscriptionBody),
    responses(
        (status = 200, body = crate::openapi::SubscriptionEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn create_subscription(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<CreateSubscriptionBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().subscriptions, request_id)?;
    let operation_id = matching_operation(&headers, body.operation_id, request_id)?;
    let value = service(&state, request_id)?
        .create_subscription(
            principal.user_id,
            operation_id,
            subscription_write(
                body.id,
                body.kind.into(),
                body.key,
                body.label,
                body.saved_search_id,
                body.frequency.into(),
            ),
            Utc::now(),
        )
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(SubscriptionEnvelope {
        subscription: value.into(),
    }))
}

#[utoipa::path(
    patch,
    path = "/v1/subscriptions/{id}",
    tag = "subscriptions",
    security(("oidcBearer" = [])),
    params(("id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body(content = UpdateSubscriptionBody),
    responses(
        (status = 200, body = crate::openapi::SubscriptionEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn update_subscription(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    Json(body): Json<UpdateSubscriptionBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().subscriptions, request_id)?;
    let operation_id = matching_operation(&headers, body.operation_id, request_id)?;
    let value = service(&state, request_id)?
        .update_subscription(
            principal.user_id,
            operation_id,
            subscription_write(
                id,
                body.kind.into(),
                body.key,
                body.label,
                body.saved_search_id,
                body.frequency.into(),
            ),
            Utc::now(),
        )
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(SubscriptionEnvelope {
        subscription: value.into(),
    }))
}

#[utoipa::path(
    delete,
    path = "/v1/subscriptions/{id}",
    tag = "subscriptions",
    security(("oidcBearer" = [])),
    params(("id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    responses(
        (status = 200, body = crate::openapi::SubscriptionEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_subscription(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().subscriptions, request_id)?;
    let value = service(&state, request_id)?
        .delete_subscription(
            principal.user_id,
            idempotency_key(&headers, request_id)?,
            id,
            Utc::now(),
        )
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(SubscriptionEnvelope {
        subscription: value.into(),
    }))
}

#[utoipa::path(
    get,
    path = "/v1/notifications",
    tag = "notifications",
    security(("oidcBearer" = [])),
    params(NotificationListParams),
    responses(
        (status = 200, body = crate::openapi::NotificationsEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_notifications(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<NotificationListParams>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().notifications, request_id)?;
    let mut items = service(&state, request_id)?
        .notifications(principal.user_id, params.limit)
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    mask_notifications(&state, request_id, &mut items).await?;
    Ok(Json(NotificationsEnvelope {
        items: items.into_iter().map(Into::into).collect(),
    }))
}

#[utoipa::path(
    post,
    path = "/v1/notifications/{id}/read",
    tag = "notifications",
    security(("oidcBearer" = [])),
    params(("id" = Uuid, Path)),
    responses(
        (status = 200, body = crate::openapi::NotificationMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn mark_notification_read(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().notifications, request_id)?;
    let affected = service(&state, request_id)?
        .mark_notification_read(principal.user_id, id, Utc::now())
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(NotificationMutationEnvelope { affected }))
}

#[utoipa::path(
    post,
    path = "/v1/notifications/{id}/dismiss",
    tag = "notifications",
    description = "Dismisses one visible in-app notification without changing library or queue state.",
    security(("oidcBearer" = [])),
    params(("id" = Uuid, Path)),
    responses(
        (status = 200, body = crate::openapi::NotificationMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(name = "notification.dismiss", skip_all)]
pub(crate) async fn dismiss_notification(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().notifications, request_id)?;
    let affected = service(&state, request_id)?
        .dismiss_notification(principal.user_id, id, Utc::now())
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(NotificationMutationEnvelope { affected }))
}

#[utoipa::path(
    post,
    path = "/v1/notifications/read-all",
    tag = "notifications",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, body = crate::openapi::NotificationMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn mark_all_notifications_read(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().notifications, request_id)?;
    let affected = service(&state, request_id)?
        .mark_all_notifications_read(principal.user_id, Utc::now())
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(NotificationMutationEnvelope { affected }))
}

#[utoipa::path(
    get,
    path = "/v1/notification-preferences",
    tag = "notifications",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, body = crate::openapi::NotificationPreferencesEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn get_notification_preferences(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().notifications, request_id)?;
    let preferences = service(&state, request_id)?
        .preferences(principal.user_id)
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(NotificationPreferencesEnvelope {
        preferences: preferences.into(),
    }))
}

#[utoipa::path(
    put,
    path = "/v1/notification-preferences",
    tag = "notifications",
    description = "Updates canonical per-notification-type in-app delivery; push and email must remain false. `type_frequencies` may be omitted by legacy clients, in which case `discovery_frequency` and `active_updates_enabled` project deterministically. When supplied, both discovery paths cannot be on and the deprecated projections must agree.",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = Uuid, Header)),
    request_body(content = NotificationPreferencesBody),
    responses(
        (status = 200, body = crate::openapi::NotificationPreferencesEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn put_notification_preferences(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<NotificationPreferencesBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_flag(state.feature_flags().notifications, request_id)?;
    let operation_id = matching_operation(&headers, body.operation_id, request_id)?;
    let type_frequencies = body.canonical_type_frequencies();
    let preferences = service(&state, request_id)?
        .put_preferences(
            principal.user_id,
            operation_id,
            NotificationPreferences {
                discovery_frequency: body.discovery_frequency.into(),
                type_frequencies,
                quiet_hours_start: parse_time(body.quiet_hours_start.as_deref(), request_id)?,
                quiet_hours_end: parse_time(body.quiet_hours_end.as_deref(), request_id)?,
                timezone: body.timezone,
                in_app_enabled: body.in_app_enabled,
                push_enabled: body.push_enabled,
                email_enabled: body.email_enabled,
                global_pause: body.global_pause,
                active_updates_enabled: body.active_updates_enabled,
                daily_budget: body.daily_budget,
                revision: 0,
                updated_at: Utc::now(),
            },
        )
        .await
        .map_err(|error_value| service_error(request_id, &error_value))?;
    Ok(Json(NotificationPreferencesEnvelope {
        preferences: preferences.into(),
    }))
}

fn service(state: &AppState, request_id: RequestId) -> Result<&EngagementService, ApiError> {
    state
        .engagement
        .as_ref()
        .ok_or_else(|| unavailable(request_id))
}

fn subscription_write(
    id: Uuid,
    kind: SubscriptionKind,
    key: String,
    label: String,
    saved_search_id: Option<Uuid>,
    frequency: SubscriptionFrequency,
) -> SubscriptionWrite {
    SubscriptionWrite {
        id,
        kind,
        key,
        label,
        query_definition: saved_search_id
            .map(|id| serde_json::json!({ "saved_search_id": id.to_string() })),
        frequency,
    }
}

fn matching_operation(
    headers: &HeaderMap,
    body_operation_id: Uuid,
    request_id: RequestId,
) -> Result<Uuid, ApiError> {
    let operation_id = idempotency_key(headers, request_id)?;
    if operation_id == body_operation_id {
        Ok(operation_id)
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "IDEMPOTENCY_KEY_MISMATCH",
            "Idempotency-Key must match operation_id.",
            false,
        ))
    }
}

fn parse_time(value: Option<&str>, request_id: RequestId) -> Result<Option<NaiveTime>, ApiError> {
    value
        .map(|value| {
            NaiveTime::parse_from_str(value, "%H:%M:%S").map_err(|_| {
                ApiError::new(
                    request_id,
                    StatusCode::BAD_REQUEST,
                    "INVALID_NOTIFICATION_PREFERENCES",
                    "Quiet hours must use HH:MM:SS.",
                    false,
                )
            })
        })
        .transpose()
}

fn require_flag(enabled: bool, request_id: RequestId) -> Result<(), ApiError> {
    if enabled {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "FEATURE_DISABLED",
            "This account feature is disabled.",
            false,
        ))
    }
}

fn unavailable(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "ENGAGEMENT_SERVICE_UNAVAILABLE",
        "The account engagement service is temporarily unavailable.",
        true,
    )
}

#[allow(clippy::too_many_lines)]
fn service_error(request_id: RequestId, error_value: &EngagementServiceError) -> ApiError {
    match error_value {
        EngagementServiceError::InvalidPolicy
        | EngagementServiceError::InvalidOperation
        | EngagementServiceError::InvalidSubscription
        | EngagementServiceError::InvalidPreferences => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_ENGAGEMENT_REQUEST",
            "The engagement request is invalid.",
            false,
        ),
        EngagementServiceError::NoEligibleBriefItems => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "READING_BRIEF_EMPTY",
            "No eligible papers are available for a reading brief.",
            false,
        ),
        EngagementServiceError::BriefNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "READING_BRIEF_NOT_FOUND",
            "The reading brief was not found.",
            false,
        ),
        EngagementServiceError::BriefProgressStale => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "READING_BRIEF_PROGRESS_STALE",
            "The reading brief position changed. Refresh and retry.",
            true,
        ),
        EngagementServiceError::QueueAuthorityUnavailable => ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "QUEUE_AUTHORITY_UNAVAILABLE",
            "The active queue could not be verified.",
            true,
        ),
        EngagementServiceError::AccountNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "ACCOUNT_NOT_FOUND",
            "The account was not found.",
            false,
        ),
        EngagementServiceError::AccountInactive(domain::AccountStatus::Suspended) => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_SUSPENDED",
            "The account is suspended.",
            false,
        ),
        EngagementServiceError::AccountInactive(_) => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_DELETION_PENDING",
            "The account is unavailable.",
            false,
        ),
        EngagementServiceError::IdempotencyConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "ENGAGEMENT_OPERATION_CONFLICT",
            "The operation key was already used for another request.",
            false,
        ),
        EngagementServiceError::SubscriptionConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "SUBSCRIPTION_CONFLICT",
            "That subscription already exists.",
            false,
        ),
        EngagementServiceError::SubscriptionNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "SUBSCRIPTION_NOT_FOUND",
            "The subscription was not found.",
            false,
        ),
        EngagementServiceError::SavedQueryNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "SAVED_QUERY_NOT_FOUND",
            "The saved query was not found.",
            false,
        ),
        EngagementServiceError::NotificationNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "NOTIFICATION_NOT_FOUND",
            "The notification was not found.",
            false,
        ),
        EngagementServiceError::Store(_) => {
            error!(request_id = %request_id.0, error.kind = "engagement_store", "engagement persistence failed");
            unavailable(request_id)
        }
    }
}

fn brief_operation_outcome<T>(result: &Result<T, EngagementServiceError>) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(EngagementServiceError::NoEligibleBriefItems) => OperationOutcome::NoResult,
        Err(EngagementServiceError::QueueAuthorityUnavailable) => OperationOutcome::Deferred,
        Err(EngagementServiceError::Store(_)) => OperationOutcome::RetryableFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

async fn mask_brief(
    state: &AppState,
    request_id: RequestId,
    brief: &mut engagement::ReadingBrief,
) -> Result<(), ApiError> {
    if state.fulltext_policy != domain::FulltextPolicy::Strict || brief.items.is_empty() {
        return Ok(());
    }
    let paper_ids = brief
        .items
        .iter()
        .map(|item| item.paper.paper_id)
        .collect::<Vec<_>>();
    let licenses = state
        .papers
        .license_uris(&paper_ids)
        .await
        .map_err(|_error_value| unavailable(request_id))?;
    for item in &mut brief.items {
        let license = licenses.get(&item.paper.paper_id).and_then(Option::as_ref);
        apply_summary_policy(state.fulltext_policy, license, &mut item.paper);
    }
    Ok(())
}

async fn mask_notifications(
    state: &AppState,
    request_id: RequestId,
    notifications: &mut [engagement::Notification],
) -> Result<(), ApiError> {
    if state.fulltext_policy != domain::FulltextPolicy::Strict {
        return Ok(());
    }
    let paper_ids = notifications
        .iter()
        .flat_map(|notification| notification.papers.iter().map(|paper| paper.paper_id))
        .collect::<Vec<_>>();
    if paper_ids.is_empty() {
        return Ok(());
    }
    let licenses = state
        .papers
        .license_uris(&paper_ids)
        .await
        .map_err(|_error_value| unavailable(request_id))?;
    for notification in notifications {
        for paper in &mut notification.papers {
            let license = licenses.get(&paper.paper_id).and_then(Option::as_ref);
            apply_summary_policy(state.fulltext_policy, license, paper);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use engagement::EngagementStoreError;

    use super::*;

    #[test]
    fn parsers_fail_closed_and_saved_queries_persist_only_identity() {
        let request_id = RequestId(Uuid::nil());
        assert!(parse_time(Some("22:30:00"), request_id).is_ok());
        assert!(parse_time(Some("22:30"), request_id).is_err());
        let saved_search_id = Uuid::now_v7();
        let write = subscription_write(
            Uuid::now_v7(),
            SubscriptionKind::SavedQuery,
            saved_search_id.to_string(),
            "Private label".to_owned(),
            Some(saved_search_id),
            SubscriptionFrequency::Daily,
        );
        assert_eq!(
            write.query_definition,
            Some(serde_json::json!({"saved_search_id": saved_search_id.to_string()}))
        );
    }

    #[test]
    fn brief_observability_distinguishes_empty_deferred_and_failed() {
        assert_eq!(
            brief_operation_outcome(&Ok::<(), EngagementServiceError>(())),
            OperationOutcome::Success
        );
        assert_eq!(
            brief_operation_outcome(&Err::<(), _>(EngagementServiceError::NoEligibleBriefItems,)),
            OperationOutcome::NoResult
        );
        assert_eq!(
            brief_operation_outcome(&Err::<(), _>(
                EngagementServiceError::QueueAuthorityUnavailable,
            )),
            OperationOutcome::Deferred
        );
        assert_eq!(
            brief_operation_outcome(&Err::<(), _>(EngagementServiceError::Store(
                EngagementStoreError::Unavailable,
            ))),
            OperationOutcome::RetryableFailure
        );
    }
}
