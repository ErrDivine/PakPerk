use std::time::{Duration, Instant};

use axum::{
    Extension, Json,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use chrono::Utc;
use db::{
    InteractionPrincipal, PaperInteractionBatchRequest, PaperInteractionRepositoryError,
    PaperInteractionWrite, RateLimitRequest,
};
use domain::AuthenticatedUserId;
use observability::{OperationClass, OperationOutcome, record_operation};
use tracing::error;

use crate::{
    AppState,
    dto::{PaperInteractionBatchBody, PaperInteractionBatchEnvelope},
    error::{ApiError, RequestId},
    middleware::RequestPrincipal,
};

const INTERACTION_RETENTION: Duration = Duration::from_secs(90 * 24 * 60 * 60);
const INTERACTION_BATCH_LIMIT: u32 = 60;
const INTERACTION_BATCH_WINDOW: Duration = Duration::from_secs(60);

#[utoipa::path(
    post,
    path = "/v1/events/batch",
    tag = "events",
    security((), ("oidcBearer" = [])),
    request_body = PaperInteractionBatchBody,
    responses(
        (status = 202, description = "Bounded content-free events accepted; duplicate event IDs are ignored", body = PaperInteractionBatchEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "INVALID_EVENT_BATCH, INVALID_EVENT_PRINCIPAL, INVALID_RECOMMENDATION_EVENT, or INTERACTION_CONSENT_REQUIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "A supplied bearer token is invalid or expired", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared principal window resets"))),
        (status = 503, description = "FEATURE_DISABLED or EVENT_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "recommendation.event_batch",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
#[allow(clippy::too_many_lines)] // One auditable transport path keeps validation, shared limiting, persistence, and stable error mapping together.
pub(crate) async fn post_interaction_batch(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: RequestPrincipal,
    Json(body): Json<PaperInteractionBatchBody>,
) -> Result<Response, ApiError> {
    let started = Instant::now();
    let record = |outcome| {
        record_operation(
            OperationClass::RecommendationEvent,
            outcome,
            started.elapsed(),
        );
    };
    if !state.feature_flags().recommendation_events {
        record(OperationOutcome::Rejected);
        return Err(ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "FEATURE_DISABLED",
            "Interaction event ingestion is disabled.",
            false,
        ));
    }
    let (principal, rate_limit_scope) = if let Some(user_id) = principal.user_id {
        (
            InteractionPrincipal::Account(AuthenticatedUserId::new(user_id)),
            format!("user:{user_id}"),
        )
    } else if let Some(session_id) = principal.anonymous_session_id {
        (
            InteractionPrincipal::Anonymous(session_id),
            format!("session:{session_id}"),
        )
    } else {
        record(OperationOutcome::Rejected);
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_EVENT_PRINCIPAL",
            "A valid account or anonymous session is required.",
            false,
        ));
    };
    let Ok(rate_limit) = RateLimitRequest::interaction_batch(
        rate_limit_scope,
        INTERACTION_BATCH_LIMIT,
        INTERACTION_BATCH_WINDOW,
    ) else {
        record(OperationOutcome::TerminalFailure);
        return Err(event_service_unavailable(request_id));
    };
    let decision = match state.database.rate_limits().check(&rate_limit).await {
        Ok(value) => value,
        Err(_error_value) => {
            record(OperationOutcome::RetryableFailure);
            return Err(event_service_unavailable(request_id));
        }
    };
    if !decision.allowed {
        record(OperationOutcome::Rejected);
        return Err(ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many event batches. Please wait before retrying.",
            true,
        )
        .with_retry_after(decision.retry_after_seconds.unwrap_or(1).max(1)));
    }
    let received_at = Utc::now();
    let events = body
        .events
        .into_iter()
        .map(|event| PaperInteractionWrite {
            id: event.event_id,
            event_type: event.event_type.into(),
            paper_id: event.paper_id,
            feed_mode: event.feed_mode.map(Into::into),
            batch_id: event.batch_id,
            position: event.position,
            occurred_at: event.occurred_at,
        })
        .collect();
    let result = state
        .database
        .paper_interactions()
        .ingest(PaperInteractionBatchRequest {
            principal,
            events,
            received_at,
            retention: INTERACTION_RETENTION,
        })
        .await;
    record(interaction_operation_outcome(&result));
    let outcome = result.map_err(|error_value| interaction_error(request_id, &error_value))?;
    Ok((
        StatusCode::ACCEPTED,
        Json(PaperInteractionBatchEnvelope {
            accepted: outcome.accepted,
            duplicates: outcome.duplicates,
        }),
    )
        .into_response())
}

fn interaction_operation_outcome<T>(
    result: &Result<T, PaperInteractionRepositoryError>,
) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(
            PaperInteractionRepositoryError::InvalidRequest
            | PaperInteractionRepositoryError::InvalidRecommendationPair
            | PaperInteractionRepositoryError::ConsentRequired,
        ) => OperationOutcome::Rejected,
        Err(PaperInteractionRepositoryError::Database(_)) => OperationOutcome::RetryableFailure,
    }
}

fn interaction_error(
    request_id: RequestId,
    error_value: &PaperInteractionRepositoryError,
) -> ApiError {
    match error_value {
        PaperInteractionRepositoryError::InvalidRequest => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_EVENT_BATCH",
            "The event batch is invalid.",
            false,
        ),
        PaperInteractionRepositoryError::InvalidRecommendationPair => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RECOMMENDATION_EVENT",
            "The recommendation event does not match a servable batch item.",
            false,
        ),
        PaperInteractionRepositoryError::ConsentRequired => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INTERACTION_CONSENT_REQUIRED",
            "Interaction collection requires an enabled account preference; guest collection is unavailable in this release.",
            false,
        ),
        PaperInteractionRepositoryError::Database(_) => {
            error!(
                request_id = %request_id.0,
                error.kind = "interaction_repository",
                "interaction event ingestion failed"
            );
            event_service_unavailable(request_id)
        }
    }
}

fn event_service_unavailable(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "EVENT_SERVICE_UNAVAILABLE",
        "Event ingestion is temporarily unavailable.",
        true,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_observability_distinguishes_acceptance_and_rejection() {
        assert_eq!(
            interaction_operation_outcome(&Ok::<(), PaperInteractionRepositoryError>(())),
            OperationOutcome::Success
        );
        assert_eq!(
            interaction_operation_outcome(&Err::<(), _>(
                PaperInteractionRepositoryError::InvalidRequest,
            )),
            OperationOutcome::Rejected
        );
        assert_eq!(
            interaction_operation_outcome(&Err::<(), _>(
                PaperInteractionRepositoryError::InvalidRecommendationPair,
            )),
            OperationOutcome::Rejected
        );
        assert_eq!(
            interaction_operation_outcome(&Err::<(), _>(
                PaperInteractionRepositoryError::ConsentRequired,
            )),
            OperationOutcome::Rejected
        );
        let error = interaction_error(
            RequestId(uuid::Uuid::nil()),
            &PaperInteractionRepositoryError::ConsentRequired,
        );
        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "INTERACTION_CONSENT_REQUIRED");
        assert!(!error.retryable);
    }
}
