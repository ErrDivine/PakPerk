use std::{
    sync::Arc,
    time::{Duration, SystemTime},
};

use async_trait::async_trait;
use domain::ChatAnswer;
use reqwest::{Client, Response, StatusCode, header::RETRY_AFTER};
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
            .field("base_url", &self.base_url)
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
            let mut request = self.http.post(url.clone()).json(payload);
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
        validate_chat_output(
            &content,
            request,
            response
                .model
                .or_else(|| Some(self.config.chat_model.clone())),
            response.id,
        )
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
        Ok(EmbeddingResponse {
            vectors,
            model_id: response
                .model
                .unwrap_or_else(|| self.config.embedding_model.clone()),
            provider_request_id: response.id,
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
        validate_relationship_output(
            &content,
            request,
            response
                .model
                .or_else(|| Some(self.config.chat_model.clone())),
            response.id,
        )
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
    if !matches!(config.base_url.scheme(), "http" | "https")
        || config.chat_model.trim().is_empty()
        || config.embedding_model.trim().is_empty()
        || config.embedding_dimension == 0
        || config.connect_timeout.is_zero()
        || config.request_timeout.is_zero()
        || config.maximum_response_bytes == 0
        || config.maximum_retries > 5
    {
        return Err(ProviderError::InvalidConfiguration(
            "base URL, model IDs, dimension, positive timeouts/limit, and at most five retries are required".into(),
        ));
    }
    Ok(())
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
            api_key: Some(SecretString::from("super-secret".to_owned())),
            ..OpenAiCompatibleConfig::default()
        };
        let debug = format!("{config:?}");
        assert!(!debug.contains("super-secret"));
        assert!(debug.contains("REDACTED"));
    }
}
