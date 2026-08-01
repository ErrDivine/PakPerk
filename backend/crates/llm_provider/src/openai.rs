use std::{
    sync::Arc,
    time::{Duration, SystemTime},
};

use async_trait::async_trait;
use domain::ChatAnswer;
use reqwest::{Client, Response, StatusCode, header::RETRY_AFTER, redirect::Policy};
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::time::{sleep, timeout};
use url::Url;

use crate::{
    ChatCompletionRequest, ChatProvider, EmbeddingProvider, EmbeddingRequest, EmbeddingResponse,
    ProviderError, RelationshipProvider, RelationshipRequest, RelationshipSummary,
    prompt::{chat_payload, relationship_payload},
    validate_chat_output, validate_relationship_output,
};

#[derive(Clone)]
pub struct OpenAiCompatibleConfig {
    pub base_url: Url,
    /// Require an Internet-safe TLS endpoint. Staging and production callers
    /// set this to true; development may use a local HTTP model process.
    pub require_https: bool,
    pub api_key: Option<SecretString>,
    pub chat_model: String,
    pub embedding_model: String,
    pub embedding_dimension: usize,
    pub connect_timeout: Duration,
    pub request_timeout: Duration,
    pub maximum_response_bytes: usize,
    pub maximum_retries: usize,
}

impl std::fmt::Debug for OpenAiCompatibleConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OpenAiCompatibleConfig")
            // A provider URL can be operator-supplied. Keep it out of Debug so
            // a rejected credential/query value cannot reach startup logs.
            .field("base_url", &"[REDACTED]")
            .field("require_https", &self.require_https)
            .field("api_key", &self.api_key.as_ref().map(|_| "[REDACTED]"))
            .field("chat_model", &self.chat_model)
            .field("embedding_model", &self.embedding_model)
            .field("embedding_dimension", &self.embedding_dimension)
            .field("connect_timeout", &self.connect_timeout)
            .field("request_timeout", &self.request_timeout)
            .field("maximum_response_bytes", &self.maximum_response_bytes)
            .field("maximum_retries", &self.maximum_retries)
            .finish()
    }
}

impl Default for OpenAiCompatibleConfig {
    fn default() -> Self {
        Self {
            base_url: Url::parse("https://api.openai.com/v1")
                .expect("default provider URL is valid"),
            require_https: false,
            api_key: None,
            chat_model: String::new(),
            embedding_model: String::new(),
            embedding_dimension: 0,
            connect_timeout: Duration::from_secs(10),
            request_timeout: Duration::from_secs(60),
            maximum_response_bytes: 4 * 1024 * 1024,
            maximum_retries: 2,
        }
    }
}

#[derive(Debug, Clone)]
pub struct OpenAiCompatibleProvider {
    config: Arc<OpenAiCompatibleConfig>,
    http: Client,
}

impl OpenAiCompatibleProvider {
    pub fn new(config: OpenAiCompatibleConfig) -> Result<Self, ProviderError> {
        validate_config(&config)?;
        let http = Client::builder()
            .redirect(Policy::none())
            .connect_timeout(config.connect_timeout)
            .timeout(config.request_timeout)
            .build()?;
        Ok(Self {
            config: Arc::new(config),
            http,
        })
    }

    async fn post_json(&self, path: &str, payload: &Value) -> Result<Vec<u8>, ProviderError> {
        timeout(
            self.config.request_timeout,
            self.post_json_with_retries(path, payload),
        )
        .await
        .map_err(|_| ProviderError::OperationTimeout)?
    }

    async fn post_json_with_retries(
        &self,
        path: &str,
        payload: &Value,
    ) -> Result<Vec<u8>, ProviderError> {
        let url = endpoint(&self.config.base_url, path);
        let mut attempt = 0usize;
        loop {
            let mut request = self
                .http
                .post(url.clone())
                .headers(observability::current_trace_headers())
                .json(payload);
            if let Some(api_key) = &self.config.api_key {
                request = request.bearer_auth(api_key.expose_secret());
            }
            match request.send().await {
                Ok(response) if response.status().is_success() => {
                    return read_bounded(response, self.config.maximum_response_bytes).await;
                }
                Ok(response) => {
                    let status = response.status();
                    if attempt >= self.config.maximum_retries || !retryable_status(status) {
                        return Err(ProviderError::HttpStatus {
                            status: status.as_u16(),
                        });
                    }
                    let delay = retry_after(&response).unwrap_or_else(|| backoff_delay(attempt));
                    attempt += 1;
                    sleep(delay).await;
                }
                Err(error) => {
                    let retryable = error.is_timeout() || error.is_connect();
                    if attempt >= self.config.maximum_retries || !retryable {
                        return Err(ProviderError::Transport(error));
                    }
                    let delay = backoff_delay(attempt);
                    attempt += 1;
                    sleep(delay).await;
                }
            }
        }
    }
}

#[async_trait]
impl ChatProvider for OpenAiCompatibleProvider {
    async fn answer(&self, request: &ChatCompletionRequest) -> Result<ChatAnswer, ProviderError> {
        let payload = chat_payload(request, &self.config.chat_model)?;
        let bytes = self.post_json("chat/completions", &payload).await?;
        let response: ChatEnvelope = serde_json::from_slice(&bytes).map_err(|_| {
            ProviderError::InvalidResponse("chat response is not the expected JSON envelope".into())
        })?;
        let content = response
            .choices
            .into_iter()
            .next()
            .map(|choice| choice.message.content)
            .filter(|content| !content.trim().is_empty())
            .ok_or_else(|| {
                ProviderError::InvalidResponse("chat response contains no content".into())
            })?;
        let model_id = validated_provider_identifier(
            response.model.as_deref().unwrap_or(&self.config.chat_model),
            "model",
        )?;
        let provider_request_id = response
            .id
            .as_deref()
            .map(|value| validated_provider_identifier(value, "request"))
            .transpose()?;
        validate_chat_output(&content, request, Some(model_id), provider_request_id)
            .map_err(ProviderError::from)
    }
}

#[async_trait]
impl EmbeddingProvider for OpenAiCompatibleProvider {
    async fn embed(&self, request: &EmbeddingRequest) -> Result<EmbeddingResponse, ProviderError> {
        request.validate()?;
        let payload = json!({
            "model": self.config.embedding_model,
            "input": request.inputs,
            "encoding_format": "float",
            "dimensions": self.config.embedding_dimension,
        });
        let bytes = self.post_json("embeddings", &payload).await?;
        let mut response: EmbeddingEnvelope = serde_json::from_slice(&bytes).map_err(|_| {
            ProviderError::InvalidResponse(
                "embedding response is not the expected JSON envelope".into(),
            )
        })?;
        response.data.sort_by_key(|item| item.index);
        if response.data.len() != request.inputs.len() {
            return Err(ProviderError::InvalidResponse(
                "embedding count does not match input count".into(),
            ));
        }
        let mut vectors = Vec::with_capacity(response.data.len());
        for (expected_index, item) in response.data.into_iter().enumerate() {
            if item.index != expected_index
                || item.embedding.len() != self.config.embedding_dimension
                || item.embedding.iter().any(|value| !value.is_finite())
            {
                return Err(ProviderError::InvalidResponse(
                    "embedding index, dimension, or values are invalid".into(),
                ));
            }
            vectors.push(item.embedding);
        }
        let model_id = validated_provider_identifier(
            response
                .model
                .as_deref()
                .unwrap_or(&self.config.embedding_model),
            "model",
        )?;
        let provider_request_id = response
            .id
            .as_deref()
            .map(|value| validated_provider_identifier(value, "request"))
            .transpose()?;
        Ok(EmbeddingResponse {
            vectors,
            model_id,
            provider_request_id,
        })
    }
}

#[async_trait]
impl RelationshipProvider for OpenAiCompatibleProvider {
    async fn summarize_relationship(
        &self,
        request: &RelationshipRequest,
    ) -> Result<RelationshipSummary, ProviderError> {
        let payload = relationship_payload(request, &self.config.chat_model)?;
        let bytes = self.post_json("chat/completions", &payload).await?;
        let response: ChatEnvelope = serde_json::from_slice(&bytes).map_err(|_| {
            ProviderError::InvalidResponse(
                "relationship response is not the expected JSON envelope".into(),
            )
        })?;
        let content = response
            .choices
            .into_iter()
            .next()
            .map(|choice| choice.message.content)
            .filter(|content| !content.trim().is_empty())
            .ok_or_else(|| {
                ProviderError::InvalidResponse("relationship response contains no content".into())
            })?;
        let model_id = validated_provider_identifier(
            response.model.as_deref().unwrap_or(&self.config.chat_model),
            "model",
        )?;
        let provider_request_id = response
            .id
            .as_deref()
            .map(|value| validated_provider_identifier(value, "request"))
            .transpose()?;
        validate_relationship_output(&content, request, Some(model_id), provider_request_id)
            .map_err(ProviderError::from)
    }
}

#[derive(Debug, Deserialize)]
struct ChatEnvelope {
    id: Option<String>,
    model: Option<String>,
    choices: Vec<ChatChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: ChatMessage,
}

#[derive(Debug, Deserialize)]
struct ChatMessage {
    content: String,
}

#[derive(Debug, Deserialize)]
struct EmbeddingEnvelope {
    id: Option<String>,
    model: Option<String>,
    data: Vec<EmbeddingItem>,
}

#[derive(Debug, Deserialize)]
struct EmbeddingItem {
    index: usize,
    embedding: Vec<f32>,
}

fn validate_config(config: &OpenAiCompatibleConfig) -> Result<(), ProviderError> {
    let host_is_loopback = config.base_url.host().is_some_and(|host| match host {
        url::Host::Domain(host) => host.eq_ignore_ascii_case("localhost"),
        url::Host::Ipv4(address) => address.is_loopback(),
        url::Host::Ipv6(address) => address.is_loopback(),
    });
    if !matches!(config.base_url.scheme(), "http" | "https")
        || config.base_url.host().is_none()
        || !config.base_url.username().is_empty()
        || config.base_url.password().is_some()
        || config.base_url.query().is_some()
        || config.base_url.fragment().is_some()
        || (config.require_https && (config.base_url.scheme() != "https" || host_is_loopback))
        || config.chat_model.trim().is_empty()
        || config.embedding_model.trim().is_empty()
        || config.embedding_dimension == 0
        || config.connect_timeout.is_zero()
        || config.request_timeout.is_zero()
        || config.maximum_response_bytes == 0
        || config.maximum_retries > 5
        || !is_safe_provider_identifier(&config.chat_model)
        || !is_safe_provider_identifier(&config.embedding_model)
    {
        return Err(ProviderError::InvalidConfiguration(
            "a credential-free provider URL, safe model IDs, dimension, positive timeouts/limit, and at most five retries are required; deployed endpoints require non-loopback HTTPS".into(),
        ));
    }
    Ok(())
}

fn validated_provider_identifier(value: &str, kind: &'static str) -> Result<String, ProviderError> {
    if !is_safe_provider_identifier(value) {
        return Err(ProviderError::InvalidResponse(format!(
            "provider {kind} identifier is invalid"
        )));
    }
    Ok(value.to_owned())
}

fn is_safe_provider_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'/' | b':')
        })
}

fn endpoint(base_url: &Url, path: &str) -> Url {
    let mut endpoint = base_url.clone();
    endpoint.set_query(None);
    endpoint.set_fragment(None);
    endpoint.set_path(&format!(
        "{}/{}",
        endpoint.path().trim_end_matches('/'),
        path.trim_start_matches('/')
    ));
    endpoint
}

async fn read_bounded(
    mut response: Response,
    maximum_bytes: usize,
) -> Result<Vec<u8>, ProviderError> {
    if let Some(length) = response.content_length()
        && length > maximum_bytes as u64
    {
        return Err(ProviderError::ResponseTooLarge { maximum_bytes });
    }
    let advertised = response
        .content_length()
        .unwrap_or(0)
        .min(u64::try_from(maximum_bytes).unwrap_or(u64::MAX));
    let mut body = Vec::with_capacity(usize::try_from(advertised).unwrap_or(maximum_bytes));
    while let Some(chunk) = response.chunk().await? {
        if body.len().saturating_add(chunk.len()) > maximum_bytes {
            return Err(ProviderError::ResponseTooLarge { maximum_bytes });
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn retry_after(response: &Response) -> Option<Duration> {
    let value = response.headers().get(RETRY_AFTER)?.to_str().ok()?;
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }
    let date = httpdate::parse_http_date(value).ok()?;
    date.duration_since(SystemTime::now()).ok()
}

const fn retryable_status(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::TOO_MANY_REQUESTS
            | StatusCode::BAD_GATEWAY
            | StatusCode::SERVICE_UNAVAILABLE
            | StatusCode::GATEWAY_TIMEOUT
    )
}

fn backoff_delay(attempt: usize) -> Duration {
    let exponent = u32::try_from(attempt.min(8)).expect("value is bounded to eight");
    Duration::from_millis(500 * 2_u64.saturating_pow(exponent))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_openai_paths_without_dropping_v1() {
        assert_eq!(
            endpoint(
                &Url::parse("https://provider.example/v1/").unwrap(),
                "chat/completions"
            )
            .as_str(),
            "https://provider.example/v1/chat/completions"
        );
    }

    #[test]
    fn redacts_api_key_in_configuration_debug() {
        let config = OpenAiCompatibleConfig {
            base_url: Url::parse(
                "https://user:query-secret@provider.example/v1?token=query-secret",
            )
            .unwrap(),
            api_key: Some(SecretString::from("super-secret".to_owned())),
            ..OpenAiCompatibleConfig::default()
        };
        let debug = format!("{config:?}");
        assert!(!debug.contains("super-secret"));
        assert!(!debug.contains("query-secret"));
        assert!(!debug.contains("provider.example"));
        assert!(debug.contains("REDACTED"));
    }

    #[test]
    fn provider_url_rejects_credentials_query_fragment_and_deployed_plaintext() {
        let valid = |base_url: &str, require_https: bool| OpenAiCompatibleConfig {
            base_url: Url::parse(base_url).unwrap(),
            require_https,
            chat_model: "chat-model".to_owned(),
            embedding_model: "embedding-model".to_owned(),
            embedding_dimension: 384,
            ..OpenAiCompatibleConfig::default()
        };

        assert!(validate_config(&valid("http://localhost:11434/v1", false)).is_ok());
        assert!(validate_config(&valid("https://models.pakperk.app/v1", true)).is_ok());
        for url in [
            "https://user:secret@models.pakperk.app/v1",
            "https://models.pakperk.app/v1?api_key=secret",
            "https://models.pakperk.app/v1#secret",
        ] {
            assert!(
                validate_config(&valid(url, false)).is_err(),
                "accepted {url}"
            );
        }
        for url in [
            "http://models.pakperk.app/v1",
            "https://localhost:8443/v1",
            "https://127.0.0.1:8443/v1",
            "https://[::1]:8443/v1",
        ] {
            assert!(
                validate_config(&valid(url, true)).is_err(),
                "accepted {url}"
            );
        }
    }

    #[test]
    fn provider_identifiers_reject_content_and_credential_sentinels() {
        for sentinel in [
            "maintainer@pakperk.test",
            "Bearer token-sentinel",
            "access_token=token-sentinel",
            "model\nforged-field",
        ] {
            assert!(!is_safe_provider_identifier(sentinel));
            assert!(validated_provider_identifier(sentinel, "model").is_err());
        }
        let oversized = "x".repeat(129);
        assert!(!is_safe_provider_identifier(&oversized));
        assert!(validated_provider_identifier(&oversized, "model").is_err());
        assert!(is_safe_provider_identifier("text-embedding-3-small"));
        assert!(is_safe_provider_identifier("provider/model:v1"));
    }
}
