use super::{
    ApiError, AppState, ConnectInfo, FulltextPolicy, HeaderMap, IntoResponse, Json, Path,
    PrepareBody, PublicRequestAction, RequestId, SocketAddr, State, StatusCode, Uuid,
    apply_processing_policy, apply_summary_policy, capability_not_ready, enforce_derived_policy,
    enforce_public_request_limit, internal_db_error, invalid_arxiv_id, negative_exact_cache_ttl,
    normalize_arxiv_id, observe_arxiv_result, paper_not_found,
};
use crate::middleware::RequestPrincipal;

#[utoipa::path(get, path = "/v1/papers/{paper_id}", security((), ("oidcBearer" = [])), params(("paper_id" = Uuid, Path)), responses((status = 200, description = "Paper metadata", body = crate::openapi::PaperSummarySchema), (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn paper_metadata(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    let mut paper = state
        .papers
        .get_summary(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let persisted = state
            .papers
            .get(paper_id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_summary_policy(
            state.fulltext_policy,
            persisted.metadata.license_uri.as_ref(),
            &mut paper,
        );
    }
    Ok((StatusCode::OK, Json(paper)))
}

#[utoipa::path(get, path = "/v1/papers/by-arxiv/{arxiv_id}", security((), ("oidcBearer" = [])), params(("arxiv_id" = String, Path)), responses((status = 200, description = "Paper metadata", body = crate::openapi::PaperSummarySchema), (status = 400, description = "Invalid arXiv identifier", body = crate::openapi::ErrorEnvelopeSchema), (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn paper_by_arxiv(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(arxiv_id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    let normalized = normalize_arxiv_id(&arxiv_id).map_err(|_| invalid_arxiv_id(request_id))?;
    if let Some(paper) = state
        .papers
        .get_by_arxiv_base(&normalized.base_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
    {
        let mut summary = state
            .papers
            .get_summary(paper.id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_summary_policy(
            state.fulltext_policy,
            paper.metadata.license_uri.as_ref(),
            &mut summary,
        );
        return Ok((StatusCode::OK, Json(summary)));
    }

    let cache_key = format!("exact:{}", normalized.as_query_id());
    let metadata = if let Some(mut cached) = state
        .papers
        .get_cached_arxiv(&cache_key)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
    {
        cached.pop()
    } else {
        state
            .papers
            .reserve_arxiv_request(state.arxiv_minimum_interval)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?;
        let outcome = state.arxiv.fetch_by_id(&normalized.as_query_id()).await;
        let fetched = observe_arxiv_result(&state, request_id, outcome).await?;
        match &fetched {
            Some(metadata) => {
                state
                    .papers
                    .put_cached_arxiv(
                        &cache_key,
                        "exact_id",
                        std::slice::from_ref(metadata),
                        state.arxiv_cache_ttl,
                    )
                    .await
                    .map_err(|error| internal_db_error(request_id, &error))?;
            }
            None => {
                state
                    .papers
                    .put_cached_arxiv(
                        &cache_key,
                        "exact_id",
                        &[],
                        negative_exact_cache_ttl(state.arxiv_cache_ttl),
                    )
                    .await
                    .map_err(|error| internal_db_error(request_id, &error))?;
            }
        }
        fetched
    }
    .ok_or_else(|| paper_not_found(request_id))?;
    let paper = state
        .papers
        .upsert_metadata(&metadata)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    let mut summary = state
        .papers
        .get_summary(paper.id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    apply_summary_policy(
        state.fulltext_policy,
        paper.metadata.license_uri.as_ref(),
        &mut summary,
    );
    Ok((StatusCode::OK, Json(summary)))
}

#[axum::debug_handler]
#[utoipa::path(post, path = "/v1/papers/{paper_id}/prepare", security((), ("oidcBearer" = [])), request_body = PrepareBody, params(("paper_id" = Uuid, Path)), responses((status = 200, description = "Already ready or terminal", body = crate::openapi::ProcessingStateSchema), (status = 202, description = "Preparation accepted", body = crate::openapi::ProcessingStateSchema), (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema), (status = 429, description = "Rate limited", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn prepare(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    remote: ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<PrepareBody>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_public_request_limit(
        &state,
        PublicRequestAction::Prepare,
        request_id,
        &headers,
        remote.0,
        principal.anonymous_session_id,
    )
    .await?;
    let mut result = state
        .papers
        .prepare(paper_id, body.retry)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let paper = state
            .papers
            .get(paper_id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_processing_policy(
            state.fulltext_policy,
            paper.metadata.license_uri.as_ref(),
            &mut result.state,
        );
    }
    let status = if result.state.is_ready() || (result.state.failed() && !result.enqueued) {
        StatusCode::OK
    } else {
        StatusCode::ACCEPTED
    };
    Ok((status, Json(result.state)))
}

#[utoipa::path(get, path = "/v1/papers/{paper_id}/processing", security((), ("oidcBearer" = [])), params(("paper_id" = Uuid, Path)), responses((status = 200, description = "Processing state", body = crate::openapi::ProcessingStateSchema), (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn processing(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    let mut processing = state
        .papers
        .processing(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let paper = state
            .papers
            .get(paper_id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_processing_policy(
            state.fulltext_policy,
            paper.metadata.license_uri.as_ref(),
            &mut processing,
        );
    }
    Ok((StatusCode::OK, Json(processing)))
}

#[utoipa::path(get, path = "/v1/papers/{paper_id}/introduction", security((), ("oidcBearer" = [])), params(("paper_id" = Uuid, Path)), responses((status = 200, description = "Paper introduction", body = crate::openapi::IntroductionSchema), (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema), (status = 409, description = "Capability not ready", body = crate::openapi::ErrorEnvelopeSchema), (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn introduction(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    if let Some(introduction) = state
        .papers
        .introduction(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
    {
        return Ok((StatusCode::OK, Json(introduction)));
    }
    let processing = state
        .papers
        .processing(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    Err(capability_not_ready(
        request_id,
        "The introduction is still being prepared.",
        &processing,
    ))
}

#[utoipa::path(get, path = "/v1/papers/{paper_id}/connections", security((), ("oidcBearer" = [])), params(("paper_id" = Uuid, Path)), responses((status = 200, description = "Paper connections", body = crate::openapi::ConnectionsResponseSchema), (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema), (status = 409, description = "Capability not ready", body = crate::openapi::ErrorEnvelopeSchema), (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn connections(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let connections = state
        .papers
        .connections(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    Ok((StatusCode::OK, Json(connections)))
}
