use super::{
    ApiError, AppState, Extension, IntoResponse, Json, RequestId, State, StatusCode,
    internal_db_error, json,
};

#[utoipa::path(get, path = "/health/live", responses((status = 200, description = "Process is live", body = crate::openapi::HealthResponseSchema, example = json!({"status": "ok"}))))]
pub(crate) async fn health_live() -> impl IntoResponse {
    (StatusCode::OK, Json(json!({"status": "ok"})))
}

#[utoipa::path(get, path = "/health/ready", responses((status = 200, description = "Database is ready", body = crate::openapi::HealthResponseSchema, example = json!({"status": "ready"})), (status = 503, description = "Dependency unavailable", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn health_ready(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
) -> Result<impl IntoResponse, ApiError> {
    state
        .database
        .ready()
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    Ok((StatusCode::OK, Json(json!({"status": "ready"}))))
}
