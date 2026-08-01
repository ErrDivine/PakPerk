use std::{fmt, time::Duration};

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderValue};
use secrecy::{ExposeSecret as _, SecretString};
use serde::{Deserialize, Serialize};
use url::{Host, Url};

use crate::{
    ContentModerator, ModerationDecision, ModerationError, ModerationInput, ModerationReasonCode,
};

const MAXIMUM_RESPONSE_BYTES: usize = 64 * 1024;
const MAXIMUM_TIMEOUT: Duration = Duration::from_secs(10);

/// Validated configuration for the provider-neutral HTTP moderation seam.
#[derive(Clone)]
pub struct HttpModerationConfig {
    endpoint: Url,
    bearer_token: SecretString,
    timeout: Duration,
    allow_insecure_loopback: bool,
}

impl HttpModerationConfig {
    pub fn new(
        endpoint: Url,
        bearer_token: SecretString,
        timeout: Duration,
        allow_insecure_loopback: bool,
    ) -> Result<Self, ModerationError> {
        let config = Self {
            endpoint,
            bearer_token,
            timeout,
            allow_insecure_loopback,
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), ModerationError> {
        let loopback = match self.endpoint.host() {
            Some(Host::Ipv4(address)) => address.is_loopback(),
            Some(Host::Ipv6(address)) => address.is_loopback(),
            Some(Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
            None => false,
        };
        let scheme_allowed = self.endpoint.scheme() == "https"
            || (self.allow_insecure_loopback && self.endpoint.scheme() == "http" && loopback);
        if !scheme_allowed
            || self.endpoint.cannot_be_a_base()
            || self.endpoint.host_str().is_none()
            || !self.endpoint.username().is_empty()
            || self.endpoint.password().is_some()
            || self.endpoint.query().is_some()
            || self.endpoint.fragment().is_some()
            || self.timeout.is_zero()
            || self.timeout > MAXIMUM_TIMEOUT
        {
            return Err(ModerationError::InvalidConfiguration);
        }
        let token = self.bearer_token.expose_secret();
        if token.is_empty()
            || token.len() > 16 * 1024
            || token.trim() != token
            || token.chars().any(char::is_whitespace)
        {
            return Err(ModerationError::InvalidConfiguration);
        }
        Ok(())
    }
}

impl fmt::Debug for HttpModerationConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpModerationConfig")
            .field("endpoint", &"[redacted]")
            .field("bearer_token", &"[redacted]")
            .field("timeout", &self.timeout)
            .field("allow_insecure_loopback", &self.allow_insecure_loopback)
            .finish()
    }
}

/// Runtime adapter for a deliberately small provider-neutral JSON contract.
/// No response body, request body, endpoint, or credential enters diagnostics.
#[derive(Clone)]
pub struct HttpModerationAdapter {
    client: reqwest::Client,
    config: HttpModerationConfig,
}

impl HttpModerationAdapter {
    pub fn new(config: HttpModerationConfig) -> Result<Self, ModerationError> {
        config.validate()?;
        let client = reqwest::Client::builder()
            .connect_timeout(config.timeout)
            .timeout(config.timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| ModerationError::InvalidConfiguration)?;
        Ok(Self { client, config })
    }
}

impl fmt::Debug for HttpModerationAdapter {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("HttpModerationAdapter([redacted])")
    }
}

#[derive(Serialize)]
struct ProviderRequest<'a> {
    input: &'a str,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderResponse {
    decision: ProviderDecision,
    #[serde(default)]
    reason_code: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ProviderDecision {
    Publish,
    PendingReview,
    Reject,
}

#[async_trait]
impl ContentModerator for HttpModerationAdapter {
    async fn evaluate(
        &self,
        input: ModerationInput,
    ) -> Result<ModerationDecision, ModerationError> {
        let mut authorization = HeaderValue::from_str(&format!(
            "Bearer {}",
            self.config.bearer_token.expose_secret()
        ))
        .map_err(|_| ModerationError::InvalidConfiguration)?;
        authorization.set_sensitive(true);
        let mut response = self
            .client
            .post(self.config.endpoint.clone())
            .header(AUTHORIZATION, authorization)
            .header(CONTENT_TYPE, "application/json")
            .json(&ProviderRequest {
                input: input.body().as_str(),
            })
            .send()
            .await
            .map_err(|_| ModerationError::Unavailable)?;
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|length| length > MAXIMUM_RESPONSE_BYTES as u64)
        {
            return Err(ModerationError::Unavailable);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| ModerationError::Unavailable)?
        {
            if bytes.len().saturating_add(chunk.len()) > MAXIMUM_RESPONSE_BYTES {
                return Err(ModerationError::InvalidDecision);
            }
            bytes.extend_from_slice(&chunk);
        }
        decode_response(&bytes)
    }
}

fn decode_response(bytes: &[u8]) -> Result<ModerationDecision, ModerationError> {
    let response: ProviderResponse =
        serde_json::from_slice(bytes).map_err(|_| ModerationError::InvalidDecision)?;
    match (response.decision, response.reason_code) {
        (ProviderDecision::Publish, None) => Ok(ModerationDecision::Publish),
        (ProviderDecision::PendingReview, Some(reason)) => Ok(ModerationDecision::PendingReview {
            reason_code: ModerationReasonCode::parse(reason)
                .map_err(|_| ModerationError::InvalidDecision)?,
        }),
        (ProviderDecision::Reject, Some(reason)) => Ok(ModerationDecision::Reject {
            reason_code: ModerationReasonCode::parse(reason)
                .map_err(|_| ModerationError::InvalidDecision)?,
        }),
        _ => Err(ModerationError::InvalidDecision),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use domain::CommentBody;
    use tokio::{
        io::{AsyncReadExt as _, AsyncWriteExt as _},
        net::{TcpListener, TcpStream},
        time::timeout,
    };

    use super::*;

    #[tokio::test]
    async fn http_adapter_sends_exact_authenticated_json_contract() {
        let Some(listener) = bind_loopback().await else {
            return;
        };
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let request = read_request(&mut stream).await;
            assert_eq!(request.request_line, "POST /evaluate HTTP/1.1");
            assert_eq!(
                request.headers.get("authorization").map(String::as_str),
                Some("Bearer transport-secret")
            );
            assert_eq!(
                request.headers.get("content-type").map(String::as_str),
                Some("application/json")
            );
            assert_eq!(request.body, br#"{"input":"A \"quoted\" line\nsecond"}"#);
            write_response(&mut stream, "200 OK", &[], br#"{"decision":"publish"}"#)
                .await
                .unwrap();
        });

        let adapter = test_adapter(address, Duration::from_secs(2));
        let decision = adapter
            .evaluate(test_input("A \"quoted\" line\nsecond"))
            .await
            .unwrap();

        assert_eq!(decision, ModerationDecision::Publish);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn redirects_are_not_followed_and_map_to_unavailable() {
        for status in [
            "301 Moved Permanently",
            "302 Found",
            "303 See Other",
            "307 Temporary Redirect",
            "308 Permanent Redirect",
        ] {
            let Some(source) = bind_loopback().await else {
                return;
            };
            let Some(sink) = bind_loopback().await else {
                return;
            };
            let source_address = source.local_addr().unwrap();
            let sink_address = sink.local_addr().unwrap();
            let source_server = tokio::spawn(async move {
                let (mut stream, _) = source.accept().await.unwrap();
                let request = read_request(&mut stream).await;
                assert_eq!(
                    request.headers.get("authorization").map(String::as_str),
                    Some("Bearer transport-secret")
                );
                assert!(!request.body.is_empty());
                let location = format!("http://{sink_address}/credential-sink");
                write_response(&mut stream, status, &[("Location", location.as_str())], b"")
                    .await
                    .unwrap();
            });

            let adapter = test_adapter(source_address, Duration::from_secs(2));
            assert_eq!(
                adapter.evaluate(test_input("redirect sentinel")).await,
                Err(ModerationError::Unavailable)
            );
            source_server.await.unwrap();
            assert!(
                timeout(Duration::from_millis(250), sink.accept())
                    .await
                    .is_err(),
                "redirect status {status} was followed"
            );
        }
    }

    #[tokio::test]
    async fn non_success_status_maps_to_unavailable_without_decoding_the_body() {
        for status in [
            "401 Unauthorized",
            "429 Too Many Requests",
            "503 Unavailable",
        ] {
            let Some(listener) = bind_loopback().await else {
                return;
            };
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let _request = read_request(&mut stream).await;
                write_response(&mut stream, status, &[], br#"{"decision":"publish"}"#)
                    .await
                    .unwrap();
            });

            let adapter = test_adapter(address, Duration::from_secs(2));
            assert_eq!(
                adapter.evaluate(test_input("status sentinel")).await,
                Err(ModerationError::Unavailable)
            );
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn declared_and_streamed_oversized_responses_are_rejected() {
        let mut oversized_body = br#"{"decision":"publish"}"#.to_vec();
        oversized_body.resize(MAXIMUM_RESPONSE_BYTES + 1, b' ');

        let Some(listener) = bind_loopback().await else {
            return;
        };
        let address = listener.local_addr().unwrap();
        let declared_body = oversized_body.clone();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let _request = read_request(&mut stream).await;
            write_response_headers(&mut stream, "200 OK", &[], declared_body.len())
                .await
                .unwrap();
            // The adapter is allowed to close as soon as it sees the declared size.
            let _ = stream.write_all(&declared_body).await;
        });
        let adapter = test_adapter(address, Duration::from_secs(2));
        assert_eq!(
            adapter.evaluate(test_input("declared size sentinel")).await,
            Err(ModerationError::Unavailable)
        );
        server.await.unwrap();

        let Some(listener) = bind_loopback().await else {
            return;
        };
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let _request = read_request(&mut stream).await;
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
                .await
                .unwrap();
            write_chunked_body(&mut stream, &oversized_body).await;
        });
        let adapter = test_adapter(address, Duration::from_secs(2));
        assert_eq!(
            adapter.evaluate(test_input("streamed size sentinel")).await,
            Err(ModerationError::InvalidDecision)
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn timeout_and_broken_transport_map_to_unavailable() {
        let Some(listener) = bind_loopback().await else {
            return;
        };
        let address = listener.local_addr().unwrap();
        let timeout_server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let _request = read_request(&mut stream).await;
            std::future::pending::<()>().await;
        });
        let adapter = test_adapter(address, Duration::from_millis(100));
        assert_eq!(
            adapter.evaluate(test_input("timeout sentinel")).await,
            Err(ModerationError::Unavailable)
        );
        timeout_server.abort();
        let _ = timeout_server.await;

        let Some(listener) = bind_loopback().await else {
            return;
        };
        let address = listener.local_addr().unwrap();
        let broken_server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            drop(stream);
        });
        let adapter = test_adapter(address, Duration::from_secs(2));
        assert_eq!(
            adapter
                .evaluate(test_input("broken transport sentinel"))
                .await,
            Err(ModerationError::Unavailable)
        );
        broken_server.await.unwrap();
    }

    #[test]
    fn provider_contract_is_strict_and_reason_codes_are_bounded() {
        assert_eq!(
            decode_response(br#"{"decision":"publish"}"#).unwrap(),
            ModerationDecision::Publish
        );
        assert!(matches!(
            decode_response(br#"{"decision":"pending_review","reason_code":"provider:risk"}"#),
            Ok(ModerationDecision::PendingReview { .. })
        ));
        for invalid in [
            br#"{"decision":"publish","reason_code":"not-allowed"}"#.as_slice(),
            br#"{"decision":"reject"}"#,
            br#"{"decision":"reject","reason_code":"UPPER"}"#,
            br#"{"decision":"publish","extra":true}"#,
        ] {
            assert_eq!(
                decode_response(invalid),
                Err(ModerationError::InvalidDecision)
            );
        }
    }

    #[test]
    fn configuration_rejects_unsafe_transport_and_redacts_debug() {
        let secret = SecretString::from("sentinel-secret".to_owned());
        assert!(
            HttpModerationConfig::new(
                Url::parse("http://moderator.example/evaluate").unwrap(),
                secret.clone(),
                Duration::from_secs(2),
                false,
            )
            .is_err()
        );
        let config = HttpModerationConfig::new(
            Url::parse("https://moderator.example/evaluate").unwrap(),
            secret,
            Duration::from_secs(2),
            false,
        )
        .unwrap();
        let debug = format!("{config:?}");
        assert!(!debug.contains("sentinel-secret"));
        assert!(!debug.contains("moderator.example"));
    }

    fn test_adapter(
        address: std::net::SocketAddr,
        request_timeout: Duration,
    ) -> HttpModerationAdapter {
        let config = HttpModerationConfig::new(
            Url::parse(&format!("http://{address}/evaluate")).unwrap(),
            SecretString::from("transport-secret".to_owned()),
            request_timeout,
            true,
        )
        .unwrap();
        HttpModerationAdapter::new(config).unwrap()
    }

    fn test_input(value: &str) -> ModerationInput {
        ModerationInput::new(CommentBody::parse(value).unwrap())
    }

    async fn bind_loopback() -> Option<TcpListener> {
        match TcpListener::bind("127.0.0.1:0").await {
            Ok(listener) => Some(listener),
            Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
                eprintln!(
                    "loopback sockets are unavailable; skipped moderation transport coverage"
                );
                None
            }
            Err(error) => panic!("could not bind moderation test server: {error}"),
        }
    }

    #[derive(Debug)]
    struct CapturedRequest {
        request_line: String,
        headers: HashMap<String, String>,
        body: Vec<u8>,
    }

    async fn read_request(stream: &mut TcpStream) -> CapturedRequest {
        let bytes = read_http_message(stream).await;
        let header_end = bytes
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .unwrap();
        let header_text = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
        let mut lines = header_text.lines();
        let request_line = lines.next().unwrap().to_owned();
        let headers = lines
            .filter_map(|line| {
                let (name, value) = line.split_once(':')?;
                Some((name.to_ascii_lowercase(), value.trim().to_owned()))
            })
            .collect();
        CapturedRequest {
            request_line,
            headers,
            body: bytes[header_end + 4..].to_vec(),
        }
    }

    async fn read_http_message(stream: &mut TcpStream) -> Vec<u8> {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4_096];
        let mut expected_length = None;
        loop {
            let count = stream.read(&mut buffer).await.unwrap();
            if count == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..count]);
            if expected_length.is_none()
                && let Some(header_end) =
                    request.windows(4).position(|window| window == b"\r\n\r\n")
            {
                let headers = String::from_utf8_lossy(&request[..header_end]);
                let content_length = headers.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                });
                expected_length = content_length.map(|length| header_end + 4 + length);
            }
            if expected_length.is_some_and(|length| request.len() >= length) {
                break;
            }
        }
        request
    }

    async fn write_response(
        stream: &mut TcpStream,
        status: &str,
        headers: &[(&str, &str)],
        body: &[u8],
    ) -> std::io::Result<()> {
        write_response_headers(stream, status, headers, body.len()).await?;
        stream.write_all(body).await
    }

    async fn write_response_headers(
        stream: &mut TcpStream,
        status: &str,
        headers: &[(&str, &str)],
        content_length: usize,
    ) -> std::io::Result<()> {
        let mut response = format!("HTTP/1.1 {status}\r\n").into_bytes();
        for (name, value) in headers {
            response.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
        }
        response.extend_from_slice(
            format!(
                "Content-Type: application/json\r\nContent-Length: {content_length}\r\nConnection: close\r\n\r\n"
            )
            .as_bytes(),
        );
        stream.write_all(&response).await
    }

    async fn write_chunked_body(stream: &mut TcpStream, body: &[u8]) {
        for chunk in body.chunks(4_096) {
            if stream
                .write_all(format!("{:X}\r\n", chunk.len()).as_bytes())
                .await
                .is_err()
            {
                return;
            }
            if stream.write_all(chunk).await.is_err() || stream.write_all(b"\r\n").await.is_err() {
                return;
            }
        }
        let _ = stream.write_all(b"0\r\n\r\n").await;
    }
}
