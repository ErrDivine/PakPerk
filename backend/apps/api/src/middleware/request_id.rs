use axum::{extract::Request, http::HeaderValue, middleware::Next, response::Response};
use uuid::Uuid;

use crate::{error::RequestId, middleware::REQUEST_ID_HEADER};

pub(crate) async fn request_id_middleware(mut request: Request, next: Next) -> Response {
    let request_id = request
        .headers()
        .get(&REQUEST_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or_else(Uuid::now_v7);
    request.extensions_mut().insert(RequestId(request_id));
    let mut response = next.run(request).await;
    if let Ok(header) = HeaderValue::from_str(&request_id.to_string()) {
        response.headers_mut().insert(REQUEST_ID_HEADER, header);
    }
    response
}
