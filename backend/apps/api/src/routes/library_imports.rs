use std::time::Instant;

use axum::{
    Extension, Json,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use observability::{
    OperationClass, OperationOutcome, PaperImportMetricOutcome, record_operation,
    record_paper_import,
};
use paper_resolution::{PaperImportError, PaperInputError};

use crate::{
    AppState,
    dto::{PaperImportBody, PaperImportEnvelope},
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    routes::{
        library::{idempotency_key, library_service_error},
        support::{apply_summary_policy, internal_db_error, paper_resolution_error},
    },
};

#[utoipa::path(
    post,
    path = "/v1/me/library/imports",
    tag = "paper resolution",
    description = "Strictly parses a canonical arXiv URL or identifier, resolves metadata, and idempotently saves it to To Read. It never fetches the submitted URL and never schedules preparation.",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = Uuid, Header, description = "Required canonical UUID matching body operation_id")),
    request_body(
        content = PaperImportBody,
        example = json!({"operation_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","source":{"kind":"arxiv_url","value":"https://arxiv.org/abs/1706.03762"},"target_state":"inbox","save_source_kind":"arxiv_url"})
    ),
    responses(
        (status = 200, description = "Canonical saved library item and resolved paper", body = crate::openapi::PaperImportEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_IDEMPOTENCY_KEY, IDEMPOTENCY_KEY_MISMATCH, INVALID_PAPER_INPUT, or UNSUPPORTED_PAPER_URL", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "PAPER_RESOLUTION_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "PAPER_IMPORT_OPERATION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry"))),
        (status = 503, description = "FEATURE_DISABLED, DATABASE_UNAVAILABLE, ARXIV_UNAVAILABLE, LIBRARY_SERVICE_UNAVAILABLE, or SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn import_library_paper(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<PaperImportBody>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().library_import_writes {
        return Err(ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "FEATURE_DISABLED",
            "Paper imports are temporarily disabled.",
            false,
        ));
    }
    let header_operation_id = idempotency_key(&headers, request_id)?;
    if header_operation_id != body.operation_id {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "IDEMPOTENCY_KEY_MISMATCH",
            "Idempotency-Key must exactly match operation_id.",
            false,
        ));
    }
    // The dedicated import contract is intentionally Inbox-only. Keeping the
    // field explicit binds the client intent without opening a second state
    // mutation surface through paper resolution.
    let crate::dto::PaperImportTargetStateBody::Inbox = body.target_state;
    let service = state
        .paper_import
        .as_ref()
        .ok_or_else(|| unavailable(request_id))?;
    let started = Instant::now();
    let result = service
        .import_with_source(
            principal.user_id,
            body.operation_id,
            body.source.kind.into(),
            &body.source.value,
            body.save_source_kind.into(),
        )
        .await;
    let elapsed = started.elapsed();
    record_operation(
        OperationClass::PaperImport,
        import_outcome(&result),
        elapsed,
    );
    record_paper_import(import_metric_outcome(&result), elapsed);
    let mut result = result.map_err(|error| import_error(request_id, &error))?;
    apply_summary_policy(
        state.fulltext_policy,
        result.license_uri.as_ref(),
        &mut result.paper,
    );
    Ok(Json(PaperImportEnvelope::from(result)))
}

fn import_error(request_id: RequestId, error: &PaperImportError) -> ApiError {
    match error {
        PaperImportError::InvalidInput(PaperInputError::UnsupportedPaperUrl) => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "UNSUPPORTED_PAPER_URL",
            "The submitted URL is not an accepted canonical arXiv URL.",
            false,
        ),
        PaperImportError::InvalidOperationId
        | PaperImportError::InvalidSaveSource
        | PaperImportError::InvalidInput(PaperInputError::InvalidArxivId) => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_PAPER_INPUT",
            "The submitted paper input is invalid.",
            false,
        ),
        PaperImportError::OperationConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "PAPER_IMPORT_OPERATION_CONFLICT",
            "This operation ID was already used for a different paper import.",
            false,
        ),
        PaperImportError::Suspended => account_error(
            request_id,
            "ACCOUNT_SUSPENDED",
            "This account is suspended.",
        ),
        PaperImportError::DeletionPending | PaperImportError::Deleted => account_error(
            request_id,
            "ACCOUNT_DELETION_PENDING",
            "This account is unavailable.",
        ),
        PaperImportError::NotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "PAPER_RESOLUTION_NOT_FOUND",
            "The requested arXiv paper was not found.",
            false,
        ),
        PaperImportError::RateLimited {
            retry_after_seconds,
        } => ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many paper imports. Please wait before retrying.",
            true,
        )
        .with_retry_after(*retry_after_seconds),
        PaperImportError::AccountNotFound
        | PaperImportError::InconsistentState
        | PaperImportError::InvalidRateLimitPolicy => unavailable(request_id),
        PaperImportError::Storage(error) => internal_db_error(request_id, error),
        PaperImportError::Resolution(error) => paper_resolution_error(request_id, error),
        PaperImportError::Library(error) => library_service_error(request_id, error),
    }
}

fn account_error(request_id: RequestId, code: &'static str, message: &'static str) -> ApiError {
    ApiError::new(request_id, StatusCode::FORBIDDEN, code, message, false)
}

fn unavailable(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "SERVICE_UNAVAILABLE",
        "Paper import is temporarily unavailable.",
        true,
    )
}

fn import_outcome(
    result: &Result<paper_resolution::PaperImportResult, PaperImportError>,
) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(
            PaperImportError::RateLimited { .. }
            | PaperImportError::Storage(_)
            | PaperImportError::Resolution(_)
            | PaperImportError::Library(_),
        ) => OperationOutcome::RetryableFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

fn import_metric_outcome(
    result: &Result<paper_resolution::PaperImportResult, PaperImportError>,
) -> PaperImportMetricOutcome {
    match result {
        Ok(result) => paper_import_success_outcome(result.replayed),
        Err(PaperImportError::NotFound) => PaperImportMetricOutcome::NotFound,
        Err(PaperImportError::OperationConflict) => PaperImportMetricOutcome::Conflict,
        Err(PaperImportError::RateLimited { .. }) => PaperImportMetricOutcome::RateLimited,
        Err(
            PaperImportError::AccountNotFound
            | PaperImportError::Storage(_)
            | PaperImportError::Resolution(_)
            | PaperImportError::InconsistentState
            | PaperImportError::InvalidRateLimitPolicy
            | PaperImportError::Library(_),
        ) => PaperImportMetricOutcome::Unavailable,
        Err(_) => PaperImportMetricOutcome::Rejected,
    }
}

const fn paper_import_success_outcome(replayed: bool) -> PaperImportMetricOutcome {
    if replayed {
        PaperImportMetricOutcome::Replay
    } else {
        PaperImportMetricOutcome::Fresh
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_import_input_errors_are_distinct() {
        let request_id = RequestId(uuid::Uuid::nil());
        assert_eq!(
            import_error(
                request_id,
                &PaperImportError::InvalidInput(PaperInputError::InvalidArxivId)
            )
            .code,
            "INVALID_PAPER_INPUT"
        );
        assert_eq!(
            import_error(
                request_id,
                &PaperImportError::InvalidInput(PaperInputError::UnsupportedPaperUrl)
            )
            .code,
            "UNSUPPORTED_PAPER_URL"
        );
    }

    #[test]
    fn import_metric_errors_are_closed_and_content_free() {
        assert_eq!(
            import_metric_outcome(&Err(PaperImportError::OperationConflict)),
            PaperImportMetricOutcome::Conflict
        );
        assert_eq!(
            import_metric_outcome(&Err(PaperImportError::InvalidOperationId)),
            PaperImportMetricOutcome::Rejected
        );
        assert_eq!(
            paper_import_success_outcome(false),
            PaperImportMetricOutcome::Fresh
        );
        assert_eq!(
            paper_import_success_outcome(true),
            PaperImportMetricOutcome::Replay
        );
    }
}
