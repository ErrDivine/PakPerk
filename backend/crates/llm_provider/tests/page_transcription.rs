//! Page transcription over the real OpenAI-compatible wire protocol, against a
//! loopback mock endpoint.

use std::{collections::HashMap, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use domain::{RecoveryFailureHint, RecoverySegment, TranscribedBlockKind};
use llm_provider::{
    DocumentRecoveryProvider, DocumentRecoveryRequest, DocumentVisionProvider, ImageDetail,
    OpenAiCompatibleConfig, OpenAiCompatibleProvider, PageTranscriptionRequest, ProviderError,
    StructuredOutputMode, ThinkingMode, ValidationError,
};
use secrecy::SecretString;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::mpsc,
};
use url::Url;

const PNG: [u8; 12] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 9, 8, 7, 6];

const PAGE: &str = r#"{"blocks":[{"kind":"heading","level":1,"continues_previous":false,"text":"1 Introduction"},{"kind":"paragraph","level":null,"continues_previous":false,"text":"We study parsing."}]}"#;

fn completion_body(content: &str) -> String {
    json!({
        "id": "req-7",
        "model": "fixture-vision",
        "choices": [{"message": {"content": content}}],
        "usage": {"prompt_tokens": 1024, "completion_tokens": 60},
    })
    .to_string()
}

fn request() -> PageTranscriptionRequest<'static> {
    PageTranscriptionRequest {
        page_number: 2,
        page_count: 5,
        png: &PNG,
    }
}

fn provider(
    address: std::net::SocketAddr,
    config: impl FnOnce(&mut OpenAiCompatibleConfig),
) -> OpenAiCompatibleProvider {
    let mut settings = OpenAiCompatibleConfig {
        base_url: Url::parse(&format!("http://{address}/v1")).unwrap(),
        api_key: Some(SecretString::from("fixture-secret".to_owned())),
        chat_model: "fixture-chat".into(),
        embedding_model: "fixture-embedding".into(),
        embedding_dimension: 3,
        vision_model: Some("fixture-vision".into()),
        maximum_retries: 0,
        ..OpenAiCompatibleConfig::default()
    };
    config(&mut settings);
    OpenAiCompatibleProvider::new(settings).unwrap()
}

#[tokio::test]
async fn the_page_image_travels_to_the_vision_model_and_the_answer_is_validated() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let server = tokio::spawn(serve_json(
        listener,
        vec![completion_body(PAGE)],
        Duration::ZERO,
        sender,
    ));

    let completion = provider(address, |_| {})
        .transcribe_page(&request())
        .await
        .unwrap();
    server.await.unwrap();

    assert_eq!(completion.page.number, 2);
    assert_eq!(completion.page.blocks.len(), 2);
    assert_eq!(
        completion.page.blocks[0].kind,
        TranscribedBlockKind::Heading
    );
    assert_eq!(completion.page.blocks[0].level, Some(1));
    assert_eq!(completion.page.blocks[1].text, "We study parsing.");
    assert_eq!(completion.model_id.as_deref(), Some("fixture-vision"));
    assert_eq!(completion.provider_request_id.as_deref(), Some("req-7"));
    let usage = completion.token_usage.unwrap();
    assert_eq!((usage.input_tokens, usage.output_tokens), (1_024, 60));

    let captured = receiver.recv().await.unwrap();
    assert_eq!(captured.request_line, "POST /v1/chat/completions HTTP/1.1");
    assert_eq!(captured.headers["authorization"], "Bearer fixture-secret");
    let body: Value = serde_json::from_slice(&captured.body).unwrap();
    assert_eq!(
        body["model"], "fixture-vision",
        "page images go to the vision model, not the chat model"
    );
    assert_eq!(body["response_format"]["type"], "json_schema");
    assert!(
        body.get("thinking").is_none(),
        "nothing is sent unless configured"
    );
    let messages = body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["role"], "system");
    assert_eq!(messages[1]["role"], "user");
    let parts = messages[1]["content"].as_array().unwrap();
    assert!(parts[0]["text"].as_str().unwrap().contains("Page 2 of 5"));
    let url = parts[1]["image_url"]["url"].as_str().unwrap();
    let encoded = url.strip_prefix("data:image/png;base64,").unwrap();
    assert_eq!(STANDARD.decode(encoded).unwrap(), PNG);
    assert!(parts[1]["image_url"].get("detail").is_none());
}

#[tokio::test]
async fn json_mode_endpoints_get_the_schema_thinking_switch_and_detail_hint() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let server = tokio::spawn(serve_json(
        listener,
        vec![completion_body(PAGE)],
        Duration::ZERO,
        sender,
    ));

    provider(address, |config| {
        config.structured_output = StructuredOutputMode::JsonObject;
        config.thinking = ThinkingMode::Disabled;
        config.vision_image_detail = Some(ImageDetail::Original);
    })
    .transcribe_page(&request())
    .await
    .unwrap();
    server.await.unwrap();

    let body: Value = serde_json::from_slice(&receiver.recv().await.unwrap().body).unwrap();
    assert_eq!(body["response_format"], json!({"type": "json_object"}));
    assert_eq!(body["thinking"], json!({"type": "disabled"}));
    let messages = body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3, "the schema is one extra system message");
    assert_eq!(messages[1]["role"], "system");
    assert!(
        messages[1]["content"]
            .as_str()
            .unwrap()
            .contains("JSON Schema")
    );
    assert_eq!(messages[2]["role"], "user");
    assert_eq!(
        messages[2]["content"][1]["image_url"]["detail"], "original",
        "the image stays a structured user part"
    );
}

#[tokio::test]
async fn unusable_transcriptions_are_rejected_not_repaired() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (sender, _receiver) = mpsc::unbounded_channel();
    let bodies = vec![
        completion_body("Sure! The page says hello."),
        completion_body(r#"{"blocks":[{"kind":"paragraph","text":"x","confidence":0.9}]}"#),
        completion_body(r#"{"blocks":[{"kind":"heading","text":"Method"}]}"#),
        json!({"choices": []}).to_string(),
        completion_body("   "),
    ];
    let count = bodies.len();
    let server = tokio::spawn(serve_json(listener, bodies, Duration::ZERO, sender));
    let provider = provider(address, |_| {});

    let mut errors = Vec::new();
    for _ in 0..count {
        errors.push(provider.transcribe_page(&request()).await.unwrap_err());
    }
    server.await.unwrap();

    assert!(matches!(
        errors[0],
        ProviderError::StructuredOutput(ValidationError::InvalidJson)
    ));
    assert!(matches!(
        errors[1],
        ProviderError::StructuredOutput(ValidationError::InvalidJson)
    ));
    assert!(matches!(
        errors[2],
        ProviderError::StructuredOutput(ValidationError::InvalidPageTranscription)
    ));
    assert!(matches!(errors[3], ProviderError::InvalidResponse(_)));
    assert!(matches!(errors[4], ProviderError::InvalidResponse(_)));
}

#[tokio::test]
async fn a_slow_page_gets_its_own_budget_while_chat_keeps_the_short_one() {
    let Some(listener) = bind_loopback().await else {
        return;
    };
    let address = listener.local_addr().unwrap();
    let (sender, _receiver) = mpsc::unbounded_channel();
    let recovery_body = completion_body(
        r#"{"title_segment":null,"headings":[],"noise_segments":[],"continuation_segments":[],"reference_ranges":[]}"#,
    );
    let server = tokio::spawn(serve_json(
        listener,
        vec![completion_body(PAGE), recovery_body],
        Duration::from_millis(700),
        sender,
    ));
    let provider = provider(address, |config| {
        config.request_timeout = Duration::from_millis(250);
        config.vision_request_timeout = Duration::from_secs(10);
    });

    provider
        .transcribe_page(&request())
        .await
        .expect("the vision budget outlasts the slow reply");

    let error = provider
        .annotate_document_structure(&DocumentRecoveryRequest {
            failure: RecoveryFailureHint::InvalidTei,
            total_segments: 1,
            segments: vec![RecoverySegment {
                index: 0,
                text: "segment".into(),
            }],
        })
        .await
        .unwrap_err();
    assert!(
        matches!(
            error,
            ProviderError::OperationTimeout | ProviderError::Transport(_)
        ),
        "{error:?}"
    );
    server.abort();
}

#[tokio::test]
async fn an_oversized_or_malformed_request_never_reaches_the_network() {
    // Nothing listens on this address; the request must be refused locally.
    let provider = provider("127.0.0.1:1".parse().unwrap(), |_| {});
    let not_a_png = PageTranscriptionRequest {
        page_number: 1,
        page_count: 1,
        png: b"definitely not a PNG",
    };
    assert!(matches!(
        provider.transcribe_page(&not_a_png).await.unwrap_err(),
        ProviderError::InvalidRequest(_)
    ));
}

async fn bind_loopback() -> Option<TcpListener> {
    match TcpListener::bind("127.0.0.1:0").await {
        Ok(listener) => Some(listener),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            eprintln!("loopback sockets are unavailable; skipped page-transcription coverage");
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
    delay: Duration,
    sender: mpsc::UnboundedSender<CapturedRequest>,
) {
    for body in responses {
        let (mut stream, _) = listener.accept().await.unwrap();
        // The receiver may already be gone in tests that ignore requests.
        let _ = sender.send(read_request(&mut stream).await);
        tokio::time::sleep(delay).await;
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        // The client may have given up on a slow reply.
        let _ = stream.write_all(response.as_bytes()).await;
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
