//! Shared public HTTP response policy for Pakperk origins.

use axum::{extract::Request, middleware::Next, response::Response};
use http::{HeaderValue, header::STRICT_TRANSPORT_SECURITY};

/// Two years, all subdomains, and preload eligibility. The ingress controller
/// is configured to emit this exact value at TLS termination; origins repeat
/// it so a controller change cannot silently strip the browser contract.
pub const HSTS_HEADER_VALUE: &str = "max-age=63072000; includeSubDomains; preload";

/// Adds the closed Pakperk HSTS policy to every response, including fallbacks.
pub async fn strict_transport_security(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        STRICT_TRANSPORT_SECURITY,
        HeaderValue::from_static(HSTS_HEADER_VALUE),
    );
    response
}

#[cfg(test)]
mod tests {
    use axum::{
        Router,
        body::Body,
        http::{Request, StatusCode, header::STRICT_TRANSPORT_SECURITY},
        middleware,
        routing::get,
    };
    use tower::ServiceExt as _;

    use super::*;

    #[tokio::test]
    async fn policy_wraps_success_and_fallback_responses() {
        let app = Router::new()
            .route("/ok", get(|| async { StatusCode::NO_CONTENT }))
            .fallback(|| async { StatusCode::NOT_FOUND })
            .layer(middleware::from_fn(strict_transport_security));

        for (path, expected_status) in [
            ("/ok", StatusCode::NO_CONTENT),
            ("/missing", StatusCode::NOT_FOUND),
        ] {
            let response = app
                .clone()
                .oneshot(Request::get(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), expected_status);
            assert_eq!(
                response.headers()[STRICT_TRANSPORT_SECURITY],
                HSTS_HEADER_VALUE
            );
        }
    }
}
