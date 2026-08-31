use std::time::Instant;

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
};
use db::DbError;
use domain::{DiffConfidenceStatus, VersionDiffStatus};
use observability::{
    VersionDiffMetricOperation, VersionDiffMetricOutcome, VersionDiffUncertainty,
    record_version_diff,
};
use uuid::Uuid;

use crate::{
    app::AppState,
    dto::{DocumentVersionsEnvelope, PaperVersionDiffEnvelope, VersionDiffParams},
    error::{ApiError, RequestId},
    middleware::RequestPrincipal,
};

use super::{enforce_derived_policy, internal_db_error};

struct VersionDiffLookupObservation {
    started: Instant,
    outcome: VersionDiffMetricOutcome,
    uncertainty: VersionDiffUncertainty,
    item_count: u64,
}

impl VersionDiffLookupObservation {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            outcome: VersionDiffMetricOutcome::Failure,
            uncertainty: VersionDiffUncertainty::None,
            item_count: 0,
        }
    }
}

impl Drop for VersionDiffLookupObservation {
    fn drop(&mut self) {
        record_version_diff(
            VersionDiffMetricOperation::Lookup,
            self.outcome,
            self.uncertainty,
            self.started.elapsed(),
            self.item_count,
        );
    }
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/versions",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Retained source-identifiable document versions", body = DocumentVersionsEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "Version diff feature disabled", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn paper_versions(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    require_version_diff(&state, request_id)?;
    let paper = enforce_derived_policy(&state, request_id, paper_id).await?;
    let versions = state
        .database
        .version_diffs()
        .versions(paper_id)
        .await
        .map_err(|error| version_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    Ok((
        StatusCode::OK,
        Json(DocumentVersionsEnvelope::new(
            paper_id,
            &paper.metadata.arxiv_id.base_id,
            versions,
        )),
    ))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/version-diff",
    security((), ("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path),
        ("from" = i32, Query, minimum = 1),
        ("to" = i32, Query, minimum = 2)
    ),
    responses(
        (status = 200, description = "Bounded structural paper-version diff", body = PaperVersionDiffEnvelope),
        (status = 400, description = "Invalid generation pair", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Diff is not ready", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "Version diff feature disabled", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn paper_version_diff(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
    Query(params): Query<VersionDiffParams>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    let mut observation = VersionDiffLookupObservation::new();
    if let Err(error) = require_version_diff(&state, request_id) {
        observation.outcome = VersionDiffMetricOutcome::Disabled;
        return Err(error);
    }
    if params.from <= 0 || params.to <= params.from {
        observation.outcome = VersionDiffMetricOutcome::InvalidRange;
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_VERSION_DIFF_RANGE",
            "The source and target document generations are invalid.",
            false,
        ));
    }
    let paper = enforce_derived_policy(&state, request_id, paper_id).await?;
    let diff = state
        .database
        .version_diffs()
        .diff(paper_id, params.from, params.to)
        .await
        .map_err(|error| version_db_error(request_id, &error))?
        .ok_or_else(|| {
            observation.outcome = VersionDiffMetricOutcome::NotReady;
            ApiError::new(
                request_id,
                StatusCode::CONFLICT,
                "VERSION_DIFF_NOT_READY",
                "The requested paper-version diff is not ready.",
                true,
            )
        })?;
    observation.item_count = u64::try_from(diff.items.len()).unwrap_or(u64::MAX);
    observation.uncertainty = if diff.parser_change_uncertainty {
        VersionDiffUncertainty::ParserChange
    } else if diff
        .items
        .iter()
        .any(|item| item.confidence_status != DiffConfidenceStatus::Supported)
    {
        VersionDiffUncertainty::ItemLevel
    } else {
        VersionDiffUncertainty::None
    };
    observation.outcome = match diff.status {
        VersionDiffStatus::Ready => VersionDiffMetricOutcome::Ready,
        VersionDiffStatus::Partial => VersionDiffMetricOutcome::Partial,
        VersionDiffStatus::Pending => {
            observation.outcome = VersionDiffMetricOutcome::NotReady;
            return Err(version_diff_not_ready(request_id));
        }
        VersionDiffStatus::Failed => {
            return Err(ApiError::new(
                request_id,
                StatusCode::CONFLICT,
                "VERSION_DIFF_FAILED",
                "The requested paper-version diff could not be produced.",
                true,
            ));
        }
    };
    let source_targets = state
        .database
        .version_diffs()
        .source_targets(diff.id)
        .await
        .map_err(|error| version_db_error(request_id, &error))?;
    Ok((
        StatusCode::OK,
        Json(PaperVersionDiffEnvelope::new(
            diff,
            &paper.metadata.arxiv_id.base_id,
            source_targets,
        )),
    ))
}

fn version_diff_not_ready(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "VERSION_DIFF_NOT_READY",
        "The requested paper-version diff is not ready.",
        true,
    )
}

fn require_version_diff(state: &AppState, request_id: RequestId) -> Result<(), ApiError> {
    if state.feature_flags().version_diff {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "FEATURE_DISABLED",
            "Paper-version comparison is disabled.",
            true,
        ))
    }
}

fn paper_not_found(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::NOT_FOUND,
        "PAPER_NOT_FOUND",
        "Paper not found.",
        false,
    )
}

fn version_db_error(request_id: RequestId, error: &DbError) -> ApiError {
    match error {
        DbError::InvalidData(message) if message.contains("generation") => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_VERSION_DIFF_RANGE",
            "The source and target document generations are invalid.",
            false,
        ),
        _ => internal_db_error(request_id, error),
    }
}
