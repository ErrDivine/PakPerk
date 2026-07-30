use std::{collections::HashMap, time::Duration};

use arxiv_client::{ArxivClient, ArxivClientConfig, ArxivError};
use reqwest::StatusCode;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
};
use url::Url;

#[tokio::test]
async fn mocked_atom_api_uses_exact_encoded_query_identity_and_cache() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (request_sender, request_receiver) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        request_sender
            .send(read_headers(&mut stream).await)
            .unwrap();
        let body = include_str!("../fixtures/feed.xml");
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/atom+xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).await.unwrap();
    });
    let client = ArxivClient::new(ArxivClientConfig {
        api_url: Url::parse(&format!("http://{address}/api/query")).unwrap(),
        pdf_base_url: Url::parse(&format!("http://{address}/pdf/")).unwrap(),
        user_agent: "PakperkBoundary/0.1".to_owned(),
        contact_email: "maintainer@pakperk.dev".to_owned(),
        minimum_interval: Duration::from_secs(3),
        request_timeout: Duration::from_secs(5),
        max_retries: 0,
        max_atom_bytes: 32 * 1024,
        max_pdf_bytes: 32 * 1024,
    })
    .unwrap();

    let first = client
        .fetch_by_id("https://arxiv.org/abs/2401.12345v2")
        .await
        .unwrap()
        .unwrap();
    let cached = client
        .fetch_by_id("arXiv:2401.12345v2")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(first, cached);
    assert_eq!(first.arxiv_id.base_id, "2401.12345");
    assert_eq!(first.arxiv_id.version, 2);

    server.await.unwrap();
    let request = request_receiver.await.unwrap();
    let (path, _) = request.request_line.split_once(' ').unwrap();
    assert_eq!(path, "GET");
    let request_target = request.request_line.split_whitespace().nth(1).unwrap();
    let parsed = Url::parse(&format!("http://{address}{request_target}")).unwrap();
    assert_eq!(parsed.path(), "/api/query");
    let query = parsed.query_pairs().collect::<HashMap<_, _>>();
    assert_eq!(
        query.get("id_list").map(AsRef::as_ref),
        Some("2401.12345v2")
    );
    assert_eq!(query.get("max_results").map(AsRef::as_ref), Some("1"));
    assert_eq!(
        request.headers.get("user-agent").map(String::as_str),
        Some("PakperkBoundary/0.1 (maintainer@pakperk.dev)")
    );
}

#[tokio::test]
async fn mocked_atom_api_batches_exact_identifiers_in_one_request() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (request_sender, request_receiver) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        request_sender
            .send(read_headers(&mut stream).await)
            .unwrap();
        let body = include_str!("../fixtures/feed.xml");
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/atom+xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).await.unwrap();
    });
    let client = boundary_client(address);

    let records = client
        .fetch_by_ids(&[
            "arXiv:2401.12345v2".to_owned(),
            "hep-th/9901001v3".to_owned(),
            "2501.00001v1".to_owned(),
        ])
        .await
        .unwrap();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].arxiv_id.base_id, "2401.12345");
    assert_eq!(records[1].arxiv_id.base_id, "hep-th/9901001");
    assert!(
        client.fetch_by_id("2501.00001v1").await.unwrap().is_none(),
        "partial response omissions should use the short negative process cache"
    );

    server.await.unwrap();
    let request = request_receiver.await.unwrap();
    let request_target = request.request_line.split_whitespace().nth(1).unwrap();
    let parsed = Url::parse(&format!("http://{address}{request_target}")).unwrap();
    let query = parsed.query_pairs().collect::<HashMap<_, _>>();
    assert_eq!(
        query.get("id_list").map(AsRef::as_ref),
        Some("2401.12345v2,hep-th/9901001v3,2501.00001v1")
    );
    assert_eq!(query.get("max_results").map(AsRef::as_ref), Some("3"));
}

#[tokio::test]
async fn mocked_rate_limit_preserves_retry_after_for_shared_cooldown() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let _ = read_headers(&mut stream).await;
        stream
            .write_all(
                b"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 17\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await
            .unwrap();
    });
    let client = boundary_client(address);

    let error = client.fetch_by_id("2401.12345v2").await.unwrap_err();
    assert!(matches!(
        &error,
        ArxivError::HttpStatus {
            status,
            retry_after: Some(delay),
        } if *status == StatusCode::TOO_MANY_REQUESTS && *delay == Duration::from_secs(17)
    ));
    assert_eq!(error.shared_cooldown(), Some(Duration::from_secs(17)));
    server.await.unwrap();
}

fn boundary_client(address: std::net::SocketAddr) -> ArxivClient {
    ArxivClient::new(ArxivClientConfig {
        api_url: Url::parse(&format!("http://{address}/api/query")).unwrap(),
        pdf_base_url: Url::parse(&format!("http://{address}/pdf/")).unwrap(),
        user_agent: "PakperkBoundary/0.1".to_owned(),
        contact_email: "maintainer@pakperk.dev".to_owned(),
        minimum_interval: Duration::from_secs(3),
        request_timeout: Duration::from_secs(5),
        max_retries: 0,
        max_atom_bytes: 32 * 1024,
        max_pdf_bytes: 32 * 1024,
    })
    .unwrap()
}

async fn bind_loopback() -> Option<TcpListener> {
    match TcpListener::bind("127.0.0.1:0").await {
        Ok(listener) => Some(listener),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            eprintln!("loopback sockets are unavailable; skipped mocked arXiv boundary coverage");
            None
        }
        Err(error) => panic!("could not bind mocked arXiv server: {error}"),
    }
}

#[derive(Debug)]
struct CapturedHeaders {
    request_line: String,
    headers: HashMap<String, String>,
}

async fn read_headers(stream: &mut TcpStream) -> CapturedHeaders {
    let mut request = Vec::new();
    let mut buffer = [0_u8; 2048];
    while !request.windows(4).any(|window| window == b"\r\n\r\n") {
        let count = stream.read(&mut buffer).await.unwrap();
        assert!(count > 0, "client closed before sending complete headers");
        request.extend_from_slice(&buffer[..count]);
    }
    let header_end = request
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .unwrap();
    let header_text = String::from_utf8(request[..header_end].to_vec()).unwrap();
    let mut lines = header_text.lines();
    CapturedHeaders {
        request_line: lines.next().unwrap().to_owned(),
        headers: lines
            .filter_map(|line| {
                let (name, value) = line.split_once(':')?;
                Some((name.to_ascii_lowercase(), value.trim().to_owned()))
            })
            .collect(),
    }
}
