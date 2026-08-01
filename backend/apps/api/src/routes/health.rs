use super::{
    AppState, Extension, IntoResponse, Json, RequestId, State, StatusCode, internal_db_error, json,
};
use axum::{
    extract::Request,
    http::{HeaderValue, header::CACHE_CONTROL},
    middleware::Next,
    response::Response,
};
use db::DbError;

const HEALTH_CACHE_CONTROL: &str = "no-store";

#[utoipa::path(get, path = "/health/live", responses((status = 200, description = "Process is live", body = crate::openapi::HealthResponseSchema, headers(("Cache-Control" = String, description = "Always no-store")), example = json!({"status": "ok"}))))]
pub(crate) async fn health_live() -> Response {
    health_response("ok")
}

#[utoipa::path(get, path = "/health/ready", responses((status = 200, description = "Database is ready", body = crate::openapi::HealthResponseSchema, headers(("Cache-Control" = String, description = "Always no-store")), example = json!({"status": "ready"})), (status = 503, description = "Dependency unavailable", body = crate::openapi::ErrorEnvelopeSchema, headers(("Cache-Control" = String, description = "Always no-store")))))]
pub(crate) async fn health_ready(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
) -> Response {
    health_ready_response(request_id, state.database.ready().await)
}

pub(crate) async fn health_cache_control(request: Request, next: Next) -> Response {
    let is_health = matches!(request.uri().path(), "/health/live" | "/health/ready");
    let response = next.run(request).await;
    if is_health {
        with_no_store(response)
    } else {
        response
    }
}

fn health_ready_response(request_id: RequestId, readiness: Result<(), DbError>) -> Response {
    match readiness {
        Ok(()) => health_response("ready"),
        Err(error) => with_no_store(internal_db_error(request_id, &error).into_response()),
    }
}

fn health_response(status: &'static str) -> Response {
    with_no_store((StatusCode::OK, Json(json!({"status": status}))).into_response())
}

fn with_no_store(mut response: Response) -> Response {
    response.headers_mut().insert(
        CACHE_CONTROL,
        HeaderValue::from_static(HEALTH_CACHE_CONTROL),
    );
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::middleware::{TimeoutConfig, timeout_middleware};
    use axum::{Router, body::Body, middleware, routing::get};
    use std::time::Duration;
    use tower::ServiceExt as _;
    use uuid::Uuid;

    fn assert_exact_no_store(response: &Response) {
        assert_eq!(response.headers().get_all(CACHE_CONTROL).iter().count(), 1);
        assert_eq!(response.headers()[CACHE_CONTROL], HEALTH_CACHE_CONTROL);
    }

    #[tokio::test]
    async fn successful_health_responses_are_never_cacheable() {
        let live = health_live().await;
        assert_eq!(live.status(), StatusCode::OK);
        assert_exact_no_store(&live);

        let ready = health_ready_response(RequestId(Uuid::nil()), Ok(()));
        assert_eq!(ready.status(), StatusCode::OK);
        assert_exact_no_store(&ready);
    }

    #[test]
    fn failed_readiness_response_is_never_cacheable() {
        let response = health_ready_response(
            RequestId(Uuid::nil()),
            Err(DbError::InvalidData("readiness fixture".to_owned())),
        );

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_exact_no_store(&response);
    }

    #[tokio::test]
    async fn outer_health_policy_covers_middleware_generated_timeouts() {
        let app = Router::new()
            .route(
                "/health/ready",
                get(|| async {
                    std::future::pending::<()>().await;
                    StatusCode::OK
                }),
            )
            .layer(middleware::from_fn_with_state(
                TimeoutConfig {
                    default: Duration::from_millis(1),
                    chat: Duration::from_millis(1),
                },
                timeout_middleware,
            ))
            .layer(middleware::from_fn(health_cache_control));

        let response = app
            .oneshot(
                axum::http::Request::get("/health/ready")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::GATEWAY_TIMEOUT);
        assert_exact_no_store(&response);
    }
}
