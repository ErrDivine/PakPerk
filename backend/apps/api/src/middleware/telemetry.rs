use std::time::Instant;

use axum::{
    extract::{MatchedPath, Request},
    http::Method,
    middleware::Next,
    response::Response,
};
use observability::{
    PreparationDecision, PreparationTriggerClass, VisualObjectClass, VisualObjectOperation,
    VisualObjectOutcome, record_http_request, record_preparation_decision, record_visual_object,
    set_parent_from_headers,
};
use tracing::{Instrument as _, info_span};

#[cfg(test)]
#[derive(Clone, Default)]
pub(crate) struct TelemetryTestProbe(std::sync::Arc<std::sync::Mutex<Vec<u16>>>);

#[cfg(test)]
impl TelemetryTestProbe {
    fn statuses(&self) -> Vec<u16> {
        self.0
            .lock()
            .expect("telemetry test probe poisoned")
            .clone()
    }
}

/// Creates the HTTP server span from bounded router metadata and records the
/// matching low-cardinality metric. Raw URIs, query strings, headers, bodies,
/// account subjects, and tokens never enter either signal.
pub(crate) async fn telemetry_middleware(request: Request, next: Next) -> Response {
    let started = Instant::now();
    #[cfg(test)]
    let test_probe = request.extensions().get::<TelemetryTestProbe>().cloned();
    let route = request
        .extensions()
        .get::<MatchedPath>()
        .map_or("unmatched", MatchedPath::as_str)
        .to_owned();
    let method = normalized_method(request.method());
    let span = info_span!(
        "http.server.request",
        http.request.method = method,
        http.route = %route,
        http.response.status_code = tracing::field::Empty,
    );
    let _has_remote_parent = set_parent_from_headers(&span, request.headers());
    let response = next.run(request).instrument(span.clone()).await;
    let status = response.status().as_u16();
    span.record("http.response.status_code", status);
    // Axum route templates and methods originate in the static router, but the
    // metric API accepts owned strings to keep this middleware generic.
    record_http_request(&route, method, status, started.elapsed());
    if method == "GET"
        && let Some(object) = visual_object_for_route(&route)
    {
        record_visual_object(
            VisualObjectOperation::Delivery,
            object,
            visual_delivery_outcome(status),
        );
    }
    if method == "POST"
        && route == "/v1/papers/{paper_id}/prepare"
        && matches!(status, 400 | 422 | 429)
    {
        record_preparation_decision(
            PreparationTriggerClass::UnparsedPublicRequest,
            PreparationDecision::Rejected,
        );
    }
    #[cfg(test)]
    if let Some(probe) = test_probe {
        probe
            .0
            .lock()
            .expect("telemetry test probe poisoned")
            .push(status);
    }
    response
}

fn visual_object_for_route(route: &str) -> Option<VisualObjectClass> {
    match route {
        "/v1/papers/{paper_id}/figures"
        | "/v1/papers/{paper_id}/figures/{figure_id}"
        | "/v1/papers/{paper_id}/figures/{figure_id}/asset" => Some(VisualObjectClass::Figure),
        "/v1/papers/{paper_id}/tables" | "/v1/papers/{paper_id}/tables/{table_id}" => {
            Some(VisualObjectClass::Table)
        }
        "/v1/papers/{paper_id}/equations" => Some(VisualObjectClass::Equation),
        _ => None,
    }
}

const fn visual_delivery_outcome(status: u16) -> VisualObjectOutcome {
    match status {
        200..=299 => VisualObjectOutcome::Success,
        403 => VisualObjectOutcome::PolicyDenied,
        404 => VisualObjectOutcome::NotFound,
        409 => VisualObjectOutcome::NotReady,
        _ => VisualObjectOutcome::Failure,
    }
}

fn normalized_method(method: &Method) -> &'static str {
    match *method {
        Method::GET => "GET",
        Method::POST => "POST",
        Method::PUT => "PUT",
        Method::PATCH => "PATCH",
        Method::DELETE => "DELETE",
        Method::OPTIONS => "OPTIONS",
        Method::HEAD => "HEAD",
        _ => "OTHER",
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use axum::{
        Extension, Router,
        body::Body,
        http::{Request, StatusCode},
        middleware,
        routing::get,
    };
    use tower::ServiceExt as _;

    use crate::middleware::{TimeoutConfig, stable_error_middleware, timeout_middleware};

    use super::*;

    #[test]
    fn extension_methods_collapse_to_one_bounded_label() {
        assert_eq!(normalized_method(&Method::GET), "GET");
        assert_eq!(
            normalized_method(&Method::from_bytes(b"ATTACKER-CHOSEN-METHOD").unwrap()),
            "OTHER"
        );
    }

    #[test]
    fn visual_delivery_metrics_accept_only_static_routes_and_closed_outcomes() {
        assert_eq!(
            visual_object_for_route("/v1/papers/{paper_id}/figures/{figure_id}"),
            Some(VisualObjectClass::Figure)
        );
        assert_eq!(
            visual_object_for_route("/v1/papers/{paper_id}/figures/{figure_id}/asset"),
            Some(VisualObjectClass::Figure)
        );
        assert_eq!(
            visual_object_for_route("/v1/papers/private-id/figures"),
            None
        );
        assert_eq!(
            visual_delivery_outcome(StatusCode::CONFLICT.as_u16()),
            VisualObjectOutcome::NotReady
        );
    }

    #[tokio::test]
    async fn timeout_response_is_observed_exactly_once() {
        let probe = TelemetryTestProbe::default();
        let app = Router::new()
            .route(
                "/slow",
                get(|| async {
                    tokio::time::sleep(Duration::from_secs(1)).await;
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
            .layer(middleware::from_fn(stable_error_middleware))
            .layer(middleware::from_fn(telemetry_middleware))
            .layer(Extension(probe.clone()));

        let response = app
            .oneshot(Request::get("/slow").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::GATEWAY_TIMEOUT);
        assert_eq!(probe.statuses(), vec![StatusCode::GATEWAY_TIMEOUT.as_u16()]);
    }
}
