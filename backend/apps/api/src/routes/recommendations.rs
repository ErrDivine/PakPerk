use std::time::Instant;

use axum::{
    Extension, Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use chrono::Utc;
use db::{
    RecommendationBatchRepositoryError, RecommendationExplanationReadOutcome,
    RecommendationFeedbackOutcome, RecommendationFeedbackWrite,
};
use observability::{
    OperationClass, OperationOutcome,
    RecommendationFeedbackIngestionOutcome as FeedbackMetricOutcome,
    RecommendationFeedbackSignal as FeedbackMetricSignal,
    RecommendationModeClass as RecommendationModeMetricClass, record_operation,
    record_recommendation_feedback_ingestion, record_recommendation_feedback_signal,
};
use tracing::error;
use uuid::Uuid;

use crate::{
    AppState,
    dto::{
        RecommendationExplanationEnvelope, RecommendationFeedbackBody,
        RecommendationFeedbackEnvelope,
    },
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    routes::library::idempotency_key,
};

#[utoipa::path(
    get,
    path = "/v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation",
    tag = "recommendations",
    security(("oidcBearer" = [])),
    params(
        ("batch_id" = Uuid, Path, description = "Server-created recommendation batch"),
        ("paper_id" = Uuid, Path, description = "Paper belonging to that batch")
    ),
    responses(
        (status = 200, description = "Immutable template reasons revalidated against stored sources and features", body = RecommendationExplanationEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "RECOMMENDATION_ITEM_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or RECOMMENDATION_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn get_recommendation_explanation(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Path((batch_id, paper_id)): Path<(Uuid, Uuid)>,
) -> Result<Json<RecommendationExplanationEnvelope>, ApiError> {
    require_recommendations(&state, request_id)?;
    match state
        .database
        .recommendation_batches()
        .explanation(principal.user_id, batch_id, paper_id, Utc::now())
        .await
        .map_err(|error_value| repository_error(request_id, &error_value))?
    {
        RecommendationExplanationReadOutcome::Found {
            batch_id,
            paper_id,
            explanations,
        } => Ok(Json(RecommendationExplanationEnvelope {
            batch_id,
            paper_id,
            explanations: explanations.into_iter().map(Into::into).collect(),
        })),
        RecommendationExplanationReadOutcome::NotFound => Err(item_not_found(request_id)),
    }
}

#[utoipa::path(
    post,
    path = "/v1/discovery/batches/{batch_id}/feedback",
    tag = "recommendations",
    security(("oidcBearer" = [])),
    params(
        ("batch_id" = Uuid, Path, description = "Server-created recommendation batch"),
        ("Idempotency-Key" = Uuid, Header, description = "Required canonical non-nil operation UUID")
    ),
    request_body = RecommendationFeedbackBody,
    responses(
        (status = 201, description = "Explicit feedback accepted", body = RecommendationFeedbackEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 200, description = "Exact idempotent replay", body = RecommendationFeedbackEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "INVALID_IDEMPOTENCY_KEY or INVALID_RECOMMENDATION_FEEDBACK", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "RECOMMENDATION_ITEM_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "IDEMPOTENCY_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or RECOMMENDATION_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "recommendation.feedback",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn post_recommendation_feedback(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(batch_id): Path<Uuid>,
    Json(body): Json<RecommendationFeedbackBody>,
) -> Result<Response, ApiError> {
    let started = Instant::now();
    if let Err(error) = require_recommendations(&state, request_id) {
        record_operation(
            OperationClass::RecommendationFeedback,
            OperationOutcome::Rejected,
            started.elapsed(),
        );
        return Err(error);
    }
    let idempotency_key = match idempotency_key(&headers, request_id) {
        Ok(value) => value,
        Err(error) => {
            record_operation(
                OperationClass::RecommendationFeedback,
                OperationOutcome::Rejected,
                started.elapsed(),
            );
            return Err(error);
        }
    };
    let feedback_type = body.feedback_type.into();
    if feedback_type == db::RecommendationFeedbackType::Relevant && body.reason.is_some() {
        record_operation(
            OperationClass::RecommendationFeedback,
            OperationOutcome::Rejected,
            started.elapsed(),
        );
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RECOMMENDATION_FEEDBACK",
            "Relevant feedback does not accept a negative reason.",
            false,
        ));
    }
    let result = state
        .database
        .recommendation_batches()
        .record_feedback(RecommendationFeedbackWrite {
            user_id: principal.user_id,
            feedback_id: Uuid::now_v7(),
            idempotency_key,
            batch_id,
            paper_id: body.paper_id,
            feedback_type,
            reason: body.reason.map(Into::into),
            created_at: Utc::now(),
        })
        .await;
    record_operation(
        OperationClass::RecommendationFeedback,
        feedback_operation_outcome(&result),
        started.elapsed(),
    );
    if let Ok(outcome) = &result
        && let Some((mode, outcome)) = feedback_ingestion_metric(outcome)
    {
        record_recommendation_feedback_ingestion(mode, outcome);
    }
    if let Ok(outcome) = &result
        && let Some((mode, signal)) = fresh_feedback_signal_metric(outcome, feedback_type)
    {
        record_recommendation_feedback_signal(mode, signal);
    }
    let outcome = result.map_err(|error_value| repository_error(request_id, &error_value))?;
    match outcome {
        RecommendationFeedbackOutcome::Applied { feedback_id, .. } => Ok((
            StatusCode::CREATED,
            Json(RecommendationFeedbackEnvelope {
                feedback_id,
                replayed: false,
            }),
        )
            .into_response()),
        RecommendationFeedbackOutcome::Replayed { feedback_id, .. } => {
            Ok(Json(RecommendationFeedbackEnvelope {
                feedback_id,
                replayed: true,
            })
            .into_response())
        }
        RecommendationFeedbackOutcome::IdempotencyConflict { .. } => Err(ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "IDEMPOTENCY_CONFLICT",
            "Idempotency-Key was already used for different recommendation feedback.",
            false,
        )),
        RecommendationFeedbackOutcome::NotFound => Err(item_not_found(request_id)),
    }
}

fn feedback_operation_outcome(
    result: &Result<RecommendationFeedbackOutcome, RecommendationBatchRepositoryError>,
) -> OperationOutcome {
    match result {
        Ok(
            RecommendationFeedbackOutcome::Applied { .. }
            | RecommendationFeedbackOutcome::Replayed { .. },
        ) => OperationOutcome::Success,
        Ok(
            RecommendationFeedbackOutcome::IdempotencyConflict { .. }
            | RecommendationFeedbackOutcome::NotFound,
        )
        | Err(
            RecommendationBatchRepositoryError::InvalidRequest
            | RecommendationBatchRepositoryError::AccountNotFound
            | RecommendationBatchRepositoryError::AccountUnavailable,
        ) => OperationOutcome::Rejected,
        Err(
            RecommendationBatchRepositoryError::InvalidPersistedData
            | RecommendationBatchRepositoryError::Database(_),
        ) => OperationOutcome::RetryableFailure,
    }
}

fn feedback_ingestion_metric(
    outcome: &RecommendationFeedbackOutcome,
) -> Option<(RecommendationModeMetricClass, FeedbackMetricOutcome)> {
    let (mode, outcome) = match *outcome {
        RecommendationFeedbackOutcome::Applied { mode, .. } => {
            (mode, FeedbackMetricOutcome::Applied)
        }
        RecommendationFeedbackOutcome::Replayed { mode, .. } => {
            (mode, FeedbackMetricOutcome::Replayed)
        }
        RecommendationFeedbackOutcome::IdempotencyConflict { mode } => {
            (mode, FeedbackMetricOutcome::Conflict)
        }
        RecommendationFeedbackOutcome::NotFound => return None,
    };
    Some((recommendation_mode_metric(mode), outcome))
}

fn fresh_feedback_signal_metric(
    outcome: &RecommendationFeedbackOutcome,
    feedback_type: db::RecommendationFeedbackType,
) -> Option<(RecommendationModeMetricClass, FeedbackMetricSignal)> {
    let RecommendationFeedbackOutcome::Applied { mode, .. } = *outcome else {
        return None;
    };
    let signal = match feedback_type {
        db::RecommendationFeedbackType::Relevant => FeedbackMetricSignal::Relevant,
        db::RecommendationFeedbackType::NotRelevant => FeedbackMetricSignal::NotRelevant,
        db::RecommendationFeedbackType::Dismissed => FeedbackMetricSignal::Dismissed,
    };
    Some((recommendation_mode_metric(mode), signal))
}

const fn recommendation_mode_metric(
    mode: recommendations::RecommendationMode,
) -> RecommendationModeMetricClass {
    match mode {
        recommendations::RecommendationMode::Recent => RecommendationModeMetricClass::Recent,
        recommendations::RecommendationMode::Following => RecommendationModeMetricClass::Following,
        recommendations::RecommendationMode::ForYou => RecommendationModeMetricClass::ForYou,
        recommendations::RecommendationMode::Explore => RecommendationModeMetricClass::Explore,
    }
}

fn require_recommendations(state: &AppState, request_id: RequestId) -> Result<(), ApiError> {
    if state.feature_flags().recommendations {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "FEATURE_DISABLED",
            "Recommendation feedback and explanations are disabled.",
            false,
        ))
    }
}

fn item_not_found(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::NOT_FOUND,
        "RECOMMENDATION_ITEM_NOT_FOUND",
        "The recommendation batch item was not found.",
        false,
    )
}

fn repository_error(
    request_id: RequestId,
    error_value: &RecommendationBatchRepositoryError,
) -> ApiError {
    match error_value {
        RecommendationBatchRepositoryError::InvalidRequest => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RECOMMENDATION_FEEDBACK",
            "The recommendation request is invalid.",
            false,
        ),
        RecommendationBatchRepositoryError::AccountNotFound => item_not_found(request_id),
        RecommendationBatchRepositoryError::AccountUnavailable => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_UNAVAILABLE",
            "This account is unavailable.",
            false,
        ),
        RecommendationBatchRepositoryError::InvalidPersistedData
        | RecommendationBatchRepositoryError::Database(_) => {
            error!(
                request_id = %request_id.0,
                error.kind = "recommendation_repository",
                "recommendation persistence operation failed"
            );
            ApiError::new(
                request_id,
                StatusCode::SERVICE_UNAVAILABLE,
                "RECOMMENDATION_SERVICE_UNAVAILABLE",
                "Recommendation feedback and explanations are temporarily unavailable.",
                true,
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feedback_observability_distinguishes_acceptance_and_rejection() {
        let feedback_id = Uuid::now_v7();
        assert_eq!(
            feedback_operation_outcome(&Ok(RecommendationFeedbackOutcome::Applied {
                feedback_id,
                mode: recommendations::RecommendationMode::ForYou,
            })),
            OperationOutcome::Success
        );
        assert_eq!(
            feedback_operation_outcome(&Ok(RecommendationFeedbackOutcome::IdempotencyConflict {
                mode: recommendations::RecommendationMode::Recent,
            })),
            OperationOutcome::Rejected
        );
        assert_eq!(
            feedback_operation_outcome(&Ok(RecommendationFeedbackOutcome::NotFound)),
            OperationOutcome::Rejected
        );
        assert_eq!(
            feedback_ingestion_metric(&RecommendationFeedbackOutcome::Applied {
                feedback_id,
                mode: recommendations::RecommendationMode::ForYou,
            }),
            Some((
                RecommendationModeMetricClass::ForYou,
                FeedbackMetricOutcome::Applied,
            ))
        );
        assert_eq!(
            feedback_ingestion_metric(&RecommendationFeedbackOutcome::NotFound),
            None
        );
        assert_eq!(
            fresh_feedback_signal_metric(
                &RecommendationFeedbackOutcome::Applied {
                    feedback_id,
                    mode: recommendations::RecommendationMode::Following,
                },
                db::RecommendationFeedbackType::Dismissed,
            ),
            Some((
                RecommendationModeMetricClass::Following,
                FeedbackMetricSignal::Dismissed,
            ))
        );
        assert_eq!(
            fresh_feedback_signal_metric(
                &RecommendationFeedbackOutcome::Replayed {
                    feedback_id,
                    mode: recommendations::RecommendationMode::Following,
                },
                db::RecommendationFeedbackType::Relevant,
            ),
            None
        );
    }
}
