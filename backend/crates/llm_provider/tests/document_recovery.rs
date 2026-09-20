//! Document-structure recovery over the real OpenAI-compatible wire protocol,
//! against a loopback mock endpoint.

use std::collections::HashMap;

use domain::{
    RECOVERY_WINDOW_SEGMENTS, RecoveryFailureHint, RecoveryHeading, RecoveryRange, RecoverySegment,
};
use llm_provider::{
    DocumentRecoveryProvider, DocumentRecoveryRequest, OpenAiCompatibleConfig,
    OpenAiCompatibleProvider, ProviderError, StructuredOutputMode, ValidationError,
};
use secrecy::SecretString;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::mpsc,
};
use url::Url;

fn request(first: u32, count: u32, total: u32) -> DocumentRecoveryRequest {
    DocumentRecoveryRequest {
        failure: RecoveryFailureHint::InvalidTei,
        total_segments: total,
        segments: (first..first + count)
            .map(|index| RecoverySegment {
                index,
                text: format!("segment {index}"),
            })
            .collect(),
    }
}

fn completion_body(content: &str) -> String {
    json!({
        "id": "req-1",
        "model": "fixture-chat",
        "choices": [{"message": {"content": content}}],
        "usage": {"prompt_tokens": 21, "completion_tokens": 8},
    })
    .to_string()
}

const GOOD_CLASSIFICATION: &str = r#"{"title_segment":0,"headings":[{"segment":1,"level":1}],"noise_segments":[4],"continuation_segments":[3],"reference_ranges":[{"start":5,"end":5}]}"#;

fn provider(address: std::net::SocketAddr, mode: StructuredOutputMode) -> OpenAiCompatibleProvider {
    OpenAiCompatibleProvider::new(OpenAiCompatibleConfig {
        base_url: Url::parse(&format!("http://{address}/v1")).unwrap(),
        api_key: Some(SecretString::from("fixture-secret".to_owned())),
        structured_output: mode,
        chat_model: "fixture-chat".into(),
        embedding_model: "fixture-embedding".into(),
        embedding_dimension: 3,
        maximum_retries: 0,
        ..OpenAiCompatibleConfig::default()
    })
    .unwrap()
}

#[tokio::test]
async fn strict_schema_mode_sends_the_segments_and_validates_the_classification() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let server = tokio::spawn(serve_json(
        listener,
        vec![completion_body(GOOD_CLASSIFICATION)],
        sender,
    ));

    let completion = provider(address, StructuredOutputMode::JsonSchema)
        .annotate_document_structure(&request(0, 6, 6))
        .await
        .unwrap();
    server.await.unwrap();

    assert_eq!(completion.annotation.title_segment, Some(0));
    assert_eq!(
        completion.annotation.headings,
        [RecoveryHeading {
            segment: 1,
            level: 1
        }]
    );
    assert_eq!(completion.annotation.noise_segments, [4]);
    assert_eq!(completion.annotation.continuation_segments, [3]);
    assert_eq!(
        completion.annotation.reference_ranges,
        [RecoveryRange { start: 5, end: 5 }]
    );
    assert_eq!(completion.model_id.as_deref(), Some("fixture-chat"));
    assert_eq!(completion.provider_request_id.as_deref(), Some("req-1"));
    let usage = completion.token_usage.unwrap();
    assert_eq!((usage.input_tokens, usage.output_tokens), (21, 8));

    let captured = receiver.recv().await.unwrap();
    assert_eq!(captured.request_line, "POST /v1/chat/completions HTTP/1.1");
    assert_eq!(captured.headers["authorization"], "Bearer fixture-secret");
    let body: Value = serde_json::from_slice(&captured.body).unwrap();
    assert_eq!(body["model"], "fixture-chat");
    assert_eq!(body["temperature"], 0);
    assert_eq!(body["response_format"]["type"], "json_schema");
    assert_eq!(body["response_format"]["json_schema"]["strict"], true);
    let messages = body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert!(
        messages[0]["content"]
            .as_str()
            .unwrap()
            .contains("untrusted")
    );
    assert!(
        !messages[0]["content"]
            .as_str()
            .unwrap()
            .contains("segment 0"),
        "document text never enters the system message"
    );
    let user = messages[1]["content"].as_str().unwrap();
    assert!(user.contains(r#"{"i":0,"t":"segment 0"}"#));
    assert!(user.contains("the extracted XML was malformed"));
}

#[tokio::test]
async fn json_mode_endpoints_get_the_schema_in_a_system_message() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let server = tokio::spawn(serve_json(
        listener,
        vec![completion_body(GOOD_CLASSIFICATION)],
        sender,
    ));

    let completion = provider(address, StructuredOutputMode::JsonObject)
        .annotate_document_structure(&request(0, 6, 6))
        .await
        .unwrap();
    server.await.unwrap();
    assert_eq!(completion.annotation.title_segment, Some(0));

    let body: Value = serde_json::from_slice(&receiver.recv().await.unwrap().body).unwrap();
    assert_eq!(body["response_format"], json!({"type": "json_object"}));
    let messages = body["messages"].as_array().unwrap();
    assert_eq!(
        messages.len(),
        3,
        "the schema instruction is one extra message"
    );
    assert_eq!(messages[0]["role"], "system");
    assert_eq!(messages[1]["role"], "system");
    let instruction = messages[1]["content"].as_str().unwrap();
    assert!(instruction.contains("JSON Schema"));
    assert!(instruction.contains("continuation_segments"));
    assert_eq!(messages[2]["role"], "user");
    assert!(
        messages[2]["content"]
            .as_str()
            .unwrap()
            .contains("segment 5")
    );
}

#[tokio::test]
async fn unusable_model_output_is_rejected_not_repaired() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (sender, _receiver) = mpsc::unbounded_channel();
    let bodies = vec![
        completion_body("Sure! The title is segment 0."),
        // segment 99 was never shown to the model
        completion_body(
            r#"{"title_segment":99,"headings":[],"noise_segments":[],"continuation_segments":[],"reference_ranges":[]}"#,
        ),
        // an invented field carrying document text
        completion_body(
            r#"{"title_segment":0,"headings":[],"noise_segments":[],"continuation_segments":[],"reference_ranges":[],"text":"rewritten paragraph"}"#,
        ),
        json!({"choices": []}).to_string(),
        completion_body("   "),
    ];
    let count = bodies.len();
    let server = tokio::spawn(serve_json(listener, bodies, sender));
    let provider = provider(address, StructuredOutputMode::JsonSchema);
    let window = request(0, 6, 6);

    let mut errors = Vec::new();
    for _ in 0..count {
        errors.push(
            provider
                .annotate_document_structure(&window)
                .await
                .unwrap_err(),
        );
    }
    server.await.unwrap();

    assert!(matches!(
        errors[0],
        ProviderError::StructuredOutput(ValidationError::InvalidJson)
    ));
    assert!(matches!(
        errors[1],
        ProviderError::StructuredOutput(ValidationError::InvalidRecoveryAnnotation)
    ));
    assert!(matches!(
        errors[2],
        ProviderError::StructuredOutput(ValidationError::InvalidJson)
    ));
    assert!(matches!(errors[3], ProviderError::InvalidResponse(_)));
    assert!(matches!(errors[4], ProviderError::InvalidResponse(_)));
}

#[tokio::test]
async fn oversized_windows_fail_before_any_network_access() {
    // Nothing listens on this address; the request must be refused locally.
    let provider = provider(
        "127.0.0.1:1".parse().unwrap(),
        StructuredOutputMode::JsonSchema,
    );
    let too_many = u32::try_from(RECOVERY_WINDOW_SEGMENTS + 1).unwrap();
    let error = provider
        .annotate_document_structure(&request(0, too_many, too_many))
        .await
        .unwrap_err();
    assert!(matches!(error, ProviderError::InvalidRequest(_)));
}

async fn bind_loopback() -> Option<TcpListener> {
    match TcpListener::bind("127.0.0.1:0").await {
        Ok(listener) => Some(listener),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            eprintln!("loopback sockets are unavailable; skipped document-recovery coverage");
            None
        }
        Err(error) => panic!("could not bind mock-provider server: {error}"),
    }
}

#[derive(Debug)]
struct CapturedRequest {
    request_line: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

async fn serve_json(
    listener: TcpListener,
    responses: Vec<String>,
    sender: mpsc::UnboundedSender<CapturedRequest>,
) {
    for body in responses {
        let (mut stream, _) = listener.accept().await.unwrap();
        // The receiver may already be gone in tests that ignore requests.
        let _ = sender.send(read_request(&mut stream).await);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).await.unwrap();
    }
}

async fn read_request(stream: &mut TcpStream) -> CapturedRequest {
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 4096];
    let mut expected_length = None;
    loop {
        let count = stream.read(&mut buffer).await.unwrap();
        if count == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..count]);
        if expected_length.is_none()
            && let Some(header_end) = bytes.windows(4).position(|window| window == b"\r\n\r\n")
        {
            let headers = String::from_utf8_lossy(&bytes[..header_end]);
            let content_length = headers.lines().find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            });
            expected_length = content_length.map(|length| header_end + 4 + length);
        }
        if expected_length.is_some_and(|length| bytes.len() >= length) {
            break;
        }
    }
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
