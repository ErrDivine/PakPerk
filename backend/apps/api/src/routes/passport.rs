use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
};
use db::DbError;
use domain::{ProvenancePrincipal, SemanticDensity};
use uuid::Uuid;

use crate::{
    app::AppState,
    dto::{
        PassportEnvelope, PassportFeedbackBody, PassportFeedbackEnvelope, ProvenanceEnvelope,
        ProvenanceRecordResponse, SemanticDensityBody, SemanticSpansEnvelope, SemanticSpansParams,
    },
    error::{ApiError, RequestId},
    middleware::RequestPrincipal,
};

use super::{enforce_derived_policy, internal_db_error};

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/passport",
    tag = "papers",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current-generation Paper Passport with exact source blocks and bounded provenance", body = PassportEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Paper Passport is not ready for the current generation", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn passport(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let current = state
        .database
        .passports()
        .current_passport(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| passport_not_ready(request_id))?;
    let response = PassportEnvelope::try_from(current)
        .map_err(|error| invalid_persisted_provenance(request_id, &error))?;
    Ok((StatusCode::OK, Json(response)))
}

#[utoipa::path(
    post,
    path = "/v1/papers/{paper_id}/passport/feedback",
    tag = "papers",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    request_body = PassportFeedbackBody,
    responses(
        (status = 201, description = "Immutable Passport quality evaluation recorded", body = PassportFeedbackEnvelope),
        (status = 200, description = "Idempotent feedback operation replayed", body = PassportFeedbackEnvelope),
        (status = 400, description = "Invalid feedback or anonymous session", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Passport generation changed or is not ready", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn passport_feedback(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<PassportFeedbackBody>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    let feedback = body
        .into_domain()
        .map_err(|_| invalid_feedback(request_id))?;
    let feedback_principal = feedback_principal(request_id, &principal)?;
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let repository = state.database.passports();
    let current = repository
        .current_passport(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| passport_not_ready(request_id))?;
    if feedback.passport_id != current.passport.id {
        return Err(stale_passport(request_id));
    }
    let outcome = repository
        .record_passport_feedback(
            paper_id,
            current.passport.generation,
            feedback_principal,
            &feedback,
        )
        .await
        .map_err(|error| feedback_db_error(request_id, &error))?;
    let status = if matches!(outcome, db::FeedbackEvaluationOutcome::Inserted(_)) {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(PassportFeedbackEnvelope::from(outcome))))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/semantic-spans",
    tag = "papers",
    security((), ("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path),
        ("block_id" = Option<Uuid>, Query, description = "Exact current-generation source block"),
        ("density" = Option<SemanticDensityBody>, Query, description = "Off, key, or detailed facet density")
    ),
    responses(
        (status = 200, description = "Validated Unicode-scalar semantic spans and bounded provenance", body = SemanticSpansEnvelope),
        (status = 400, description = "Block is outside the current document", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Semantic facets are not ready for the current generation", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn semantic_spans(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
    Query(params): Query<SemanticSpansParams>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let density = params
        .density
        .map_or(SemanticDensity::Key, SemanticDensity::from);
    let current = state
        .database
        .passports()
        .current_semantic_spans(paper_id, params.block_id, density)
        .await
        .map_err(|error| semantic_span_db_error(request_id, &error))?
        .ok_or_else(|| semantic_facets_not_ready(request_id))?;
    let response = SemanticSpansEnvelope::try_new(density, current)
        .map_err(|error| invalid_persisted_provenance(request_id, &error))?;
    Ok((StatusCode::OK, Json(response)))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/provenance/{provenance_id}",
    tag = "papers",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path), ("provenance_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current-generation shared artifact provenance", body = ProvenanceEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Shared provenance not found in the current paper generation", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn shared_provenance(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path((paper_id, provenance_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let record = state
        .database
        .passports()
        .shared_provenance(paper_id, provenance_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| provenance_not_found(request_id))?;
    let provenance = ProvenanceRecordResponse::try_from(record)
        .map_err(|error| invalid_persisted_provenance(request_id, &error))?;
    Ok((StatusCode::OK, Json(ProvenanceEnvelope { provenance })))
}

fn feedback_principal(
    request_id: RequestId,
    principal: &RequestPrincipal,
) -> Result<ProvenancePrincipal, ApiError> {
    if let Some(user_id) = principal.user_id {
        return Ok(ProvenancePrincipal::OwnerUser(user_id));
    }
    principal
        .anonymous_session_id
        .map(ProvenancePrincipal::AnonymousSession)
        .ok_or_else(|| {
            ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_FEEDBACK_PRINCIPAL",
                "Sign in or provide one valid X-Session-Id to submit Passport feedback.",
                false,
            )
        })
}

fn feedback_db_error(request_id: RequestId, error: &DbError) -> ApiError {
    match error {
        DbError::InvalidData(_) => invalid_feedback(request_id),
        DbError::StaleGeneration => stale_passport(request_id),
        _ => internal_db_error(request_id, error),
    }
}

fn semantic_span_db_error(request_id: RequestId, error: &DbError) -> ApiError {
    match error {
        DbError::InvalidData(message) if message.contains("semantic span block") => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_SOURCE_BLOCK",
            "The requested block is outside the current document generation.",
            false,
        ),
        _ => internal_db_error(request_id, error),
    }
}

fn invalid_persisted_provenance(request_id: RequestId, error: &serde_json::Error) -> ApiError {
    internal_db_error(request_id, &DbError::InvalidData(error.to_string()))
}

fn invalid_feedback(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_PASSPORT_FEEDBACK",
        "Passport feedback must name a current artifact and use bounded valid fields.",
        false,
    )
}

fn stale_passport(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "STALE_PASSPORT",
        "The Paper Passport changed; refresh it before submitting feedback.",
        true,
    )
}

fn passport_not_ready(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "PASSPORT_NOT_READY",
        "The Paper Passport is not ready for the current paper generation.",
        true,
    )
}

fn semantic_facets_not_ready(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "SEMANTIC_FACETS_NOT_READY",
        "Semantic facets are not ready for the current paper generation.",
        true,
    )
}

fn provenance_not_found(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::NOT_FOUND,
        "PROVENANCE_NOT_FOUND",
        "Shared provenance was not found in the current paper generation.",
        false,
    )
}
