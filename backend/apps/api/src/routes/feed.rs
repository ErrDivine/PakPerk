use super::{
    ApiError, AppState, Extension, FeedCursor, FeedParams, FeedQuery, FulltextPolicy, IntoResponse,
    Json, Query, RequestId, State, StatusCode, apply_summary_policy, cursor_error,
    internal_db_error, valid_category,
};

#[utoipa::path(get, path = "/v1/feed", params(("category" = Option<String>, Query, description = "arXiv category"), ("cursor" = Option<String>, Query, description = "Opaque page cursor"), ("limit" = Option<u32>, Query, description = "Page size")), responses((status = 200, description = "Paper summary page", body = crate::openapi::FeedPageSchema), (status = 400, description = "Invalid query", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn feed(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Query(params): Query<FeedParams>,
) -> Result<impl IntoResponse, ApiError> {
    if let Some(category) = &params.category
        && !valid_category(category)
    {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_CATEGORY",
            "Category must be an arXiv category such as cs.AI.",
            false,
        ));
    }
    let cursor = params
        .cursor
        .as_deref()
        .map(FeedCursor::decode)
        .transpose()
        .map_err(|error| cursor_error(request_id, &error))?;
    let mut page = state
        .papers
        .feed(&FeedQuery {
            category: params.category,
            cursor,
            limit: params.limit.unwrap_or(20),
        })
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let paper_ids = page
            .items
            .iter()
            .map(|paper| paper.paper_id)
            .collect::<Vec<_>>();
        let licenses = state
            .papers
            .license_uris(&paper_ids)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?;
        for paper in &mut page.items {
            apply_summary_policy(
                state.fulltext_policy,
                licenses.get(&paper.paper_id).and_then(Option::as_ref),
                paper,
            );
        }
    }
    Ok((StatusCode::OK, Json(page)))
}
