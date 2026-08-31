use std::{net::SocketAddr, time::Instant};

use axum::{
    Extension, Json,
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use observability::{
    OperationClass, OperationOutcome, PaperSearchCacheClass, PaperSearchMetricOutcome,
    record_operation, record_paper_search,
};
use paper_resolution::{PaperSearchCacheStatus, PaperSearchError};

use crate::{
    AppState,
    dto::{PaperSearchBody, PaperSearchEnvelope},
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    request_rate_limit::PublicRequestAction,
    routes::support::enforce_public_request_limit,
};

const DEFAULT_SEARCH_LIMIT: usize = 8;

#[utoipa::path(
    post,
    path = "/v1/me/paper-searches",
    tag = "paper resolution",
    description = "Runs a bounded authenticated arXiv title search. Results are candidates only: this route never saves a paper or schedules preparation.",
    security(("oidcBearer" = [])),
    request_body(
        content = PaperSearchBody,
        example = json!({"query":"Attention Is All You Need","limit":8})
    ),
    responses(
        (status = 200, description = "Bounded title candidates ranked in upstream order", body = crate::openapi::PaperSearchEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_PAPER_INPUT or PAPER_SEARCH_QUERY_TOO_SHORT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry"))),
        (status = 503, description = "FEATURE_DISABLED, AUTHENTICATION_UNAVAILABLE, or PAPER_SEARCH_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(name = "paper_search.request", skip_all)]
pub(crate) async fn search_papers(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<PaperSearchBody>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().paper_title_search {
        return Err(feature_disabled(request_id));
    }
    enforce_public_request_limit(
        &state,
        PublicRequestAction::PaperSearch,
        request_id,
        &headers,
        peer,
        None,
    )
    .await?;
    let started = Instant::now();
    let result = state
        .paper_resolution
        .search_title(
            principal.user_id,
            &body.query,
            body.limit.unwrap_or(DEFAULT_SEARCH_LIMIT),
        )
        .await;
    let elapsed = started.elapsed();
    record_operation(
        OperationClass::PaperSearch,
        search_outcome(&result),
        elapsed,
    );
    let (metric_outcome, cache, candidates) = paper_search_metric(&result);
    record_paper_search(metric_outcome, cache, elapsed, candidates);
    Ok(Json(PaperSearchEnvelope::from(
        result.map_err(|error| search_error(request_id, &error))?,
    )))
}

fn feature_disabled(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "FEATURE_DISABLED",
        "Paper title search is temporarily disabled.",
        false,
    )
}

fn search_error(request_id: RequestId, error: &PaperSearchError) -> ApiError {
    match error {
        PaperSearchError::QueryTooShort => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "PAPER_SEARCH_QUERY_TOO_SHORT",
            "The normalized paper title is too short.",
            false,
        ),
        PaperSearchError::InvalidQuery | PaperSearchError::InvalidLimit => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_PAPER_INPUT",
            "The paper search request is invalid.",
            false,
        ),
        PaperSearchError::RateLimited {
            retry_after_seconds,
        } => ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many paper searches. Please wait before retrying.",
            true,
        )
        .with_retry_after(*retry_after_seconds),
        PaperSearchError::ArxivUnavailable { error, .. } => {
            let response = unavailable(request_id);
            if let Some(cooldown) = error.shared_cooldown() {
                response.with_retry_after(cooldown.as_secs().max(1))
            } else {
                response
            }
        }
        PaperSearchError::Storage(_) | PaperSearchError::InvalidRateLimitPolicy => {
            unavailable(request_id)
        }
    }
}

fn unavailable(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "PAPER_SEARCH_UNAVAILABLE",
        "Paper title search is temporarily unavailable.",
        true,
    )
}

fn search_outcome(
    result: &Result<paper_resolution::PaperSearchResult, PaperSearchError>,
) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(
            PaperSearchError::RateLimited { .. }
            | PaperSearchError::Storage(_)
            | PaperSearchError::ArxivUnavailable { .. },
        ) => OperationOutcome::RetryableFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

fn paper_search_metric(
    result: &Result<paper_resolution::PaperSearchResult, PaperSearchError>,
) -> (PaperSearchMetricOutcome, PaperSearchCacheClass, u64) {
    match result {
        Ok(result) => paper_search_success_metric(result.candidates.len(), result.cache_status),
        Err(PaperSearchError::RateLimited { .. }) => (
            PaperSearchMetricOutcome::RateLimited,
            PaperSearchCacheClass::NotApplicable,
            0,
        ),
        Err(
            PaperSearchError::Storage(_)
            | PaperSearchError::ArxivUnavailable { .. }
            | PaperSearchError::InvalidRateLimitPolicy,
        ) => (
            PaperSearchMetricOutcome::Unavailable,
            PaperSearchCacheClass::NotApplicable,
            0,
        ),
        Err(_) => (
            PaperSearchMetricOutcome::Rejected,
            PaperSearchCacheClass::NotApplicable,
            0,
        ),
    }
}

fn paper_search_success_metric(
    candidates: usize,
    cache_status: PaperSearchCacheStatus,
) -> (PaperSearchMetricOutcome, PaperSearchCacheClass, u64) {
    let outcome = match candidates {
        0 => PaperSearchMetricOutcome::NoResult,
        1 => PaperSearchMetricOutcome::Single,
        _ => PaperSearchMetricOutcome::Ambiguous,
    };
    let cache = match cache_status {
        PaperSearchCacheStatus::Hit => PaperSearchCacheClass::Hit,
        PaperSearchCacheStatus::Miss => PaperSearchCacheClass::Miss,
    };
    (
        outcome,
        cache,
        u64::try_from(candidates).unwrap_or(u64::MAX),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_search_errors_do_not_echo_private_queries() {
        let request_id = RequestId(uuid::Uuid::nil());
        for (error, code) in [
            (
                PaperSearchError::QueryTooShort,
                "PAPER_SEARCH_QUERY_TOO_SHORT",
            ),
            (PaperSearchError::InvalidQuery, "INVALID_PAPER_INPUT"),
            (PaperSearchError::InvalidLimit, "INVALID_PAPER_INPUT"),
        ] {
            let mapped = search_error(request_id, &error);
            assert_eq!(mapped.code, code);
            assert!(!mapped.message.contains("private"));
        }
    }

    #[test]
    fn title_search_metric_errors_are_closed_and_content_free() {
        assert_eq!(
            paper_search_metric(&Err(PaperSearchError::RateLimited {
                retry_after_seconds: 3,
            })),
            (
                PaperSearchMetricOutcome::RateLimited,
                PaperSearchCacheClass::NotApplicable,
                0,
            )
        );
        assert_eq!(
            paper_search_metric(&Err(PaperSearchError::InvalidQuery)),
            (
                PaperSearchMetricOutcome::Rejected,
                PaperSearchCacheClass::NotApplicable,
                0,
            )
        );
    }

    #[test]
    fn title_search_metric_cardinality_and_cache_mapping_are_exact() {
        assert_eq!(
            paper_search_success_metric(0, PaperSearchCacheStatus::Miss),
            (
                PaperSearchMetricOutcome::NoResult,
                PaperSearchCacheClass::Miss,
                0,
            )
        );
        assert_eq!(
            paper_search_success_metric(1, PaperSearchCacheStatus::Hit),
            (
                PaperSearchMetricOutcome::Single,
                PaperSearchCacheClass::Hit,
                1,
            )
        );
        assert_eq!(
            paper_search_success_metric(2, PaperSearchCacheStatus::Miss),
            (
                PaperSearchMetricOutcome::Ambiguous,
                PaperSearchCacheClass::Miss,
                2,
            )
        );
    }
}
