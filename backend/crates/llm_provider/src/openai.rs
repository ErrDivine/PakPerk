use std::{
    borrow::Cow,
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
use uuid::Uuid;

use crate::{
    AssistantCompletion, AssistantCompletionRequest, AssistantProvider, AssistantTokenUsage,
    ChatCompletionRequest, ChatProvider, DocumentRecoveryCompletion, DocumentRecoveryProvider,
    DocumentRecoveryRequest, DocumentVisionProvider, EmbeddingProvider, EmbeddingRequest,
    EmbeddingResponse, PageTranscriptionCompletion, PageTranscriptionRequest, ProviderError,
    RelationshipProvider, RelationshipRequest, RelationshipSummary,
    prompt::{assistant_v2_payload, chat_payload, relationship_payload},
    recovery::recovery_payload,
    validate_assistant_output, validate_chat_output, validate_recovery_output,
    validate_relationship_output, validate_transcription_output,
    vision::transcription_payload,
};

/// How structured model output is requested. Strict `json_schema` is the
/// default. Endpoints that only implement JSON mode (for example `DeepSeek`'s
/// OpenAI-compatible API) need `json_object`, which carries the same schema in
/// a system instruction instead. Every response is validated identically.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum StructuredOutputMode {
    #[default]
    JsonSchema,
    JsonObject,
}

impl std::str::FromStr for StructuredOutputMode {
    type Err = ProviderError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "" | "json_schema" => Ok(Self::JsonSchema),
            "json_object" => Ok(Self::JsonObject),
            _ => Err(ProviderError::InvalidConfiguration(
                "LLM_STRUCTURED_OUTPUT must be json_schema or json_object".into(),
            )),
        }
    }
}

/// Whether the model reasons before answering, for endpoints that expose the
/// switch (`DeepSeek` enables it by default). `ProviderDefault` sends nothing,
/// so endpoints without the parameter are unaffected.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ThinkingMode {
    #[default]
    ProviderDefault,
    Enabled,
    Disabled,
}

impl std::str::FromStr for ThinkingMode {
    type Err = ProviderError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "" | "default" => Ok(Self::ProviderDefault),
            "enabled" => Ok(Self::Enabled),
            "disabled" => Ok(Self::Disabled),
            _ => Err(ProviderError::InvalidConfiguration(
                "LLM_THINKING must be default, enabled, or disabled".into(),
            )),
        }
    }
}

impl ThinkingMode {
    fn request_value(self) -> Option<Value> {
        match self {
            Self::ProviderDefault => None,
            Self::Enabled => Some(json!({"type": "enabled"})),
            Self::Disabled => Some(json!({"type": "disabled"})),
        }
    }
}

/// The optional `detail` hint on page images. `DeepSeek` documents `low` and
/// `original`; `OpenAI` documents `low`, `high`, and `auto`. Unset sends nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageDetail {
    Low,
    High,
    Original,
}

impl ImageDetail {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::High => "high",
            Self::Original => "original",
        }
    }

    /// `None` for an empty value or `auto`, which sends no hint.
    pub fn parse_optional(value: &str) -> Result<Option<Self>, ProviderError> {
        match value.trim().to_ascii_lowercase().as_str() {
            "" | "auto" => Ok(None),
            "low" => Ok(Some(Self::Low)),
            "high" => Ok(Some(Self::High)),
            "original" => Ok(Some(Self::Original)),
            _ => Err(ProviderError::InvalidConfiguration(
                "LLM_VISION_IMAGE_DETAIL must be auto, low, high, or original".into(),
            )),
        }
    }
}

#[derive(Clone)]
pub struct OpenAiCompatibleConfig {
    pub base_url: Url,
    /// Require an Internet-safe TLS endpoint. Staging and production callers
    /// set this to true; development may use a local HTTP model process.
    pub require_https: bool,
    pub api_key: Option<SecretString>,
    pub structured_output: StructuredOutputMode,
    pub thinking: ThinkingMode,
    /// Thinking mode for assistant tool-selection steps; `ProviderDefault`
    /// means the same as `thinking`. `DeepSeek` requires the reasoning of every
    /// earlier step of a tool loop to be sent back while thinking is on, and
    /// selecting tools needs no reasoning, so operators disable it here.
    pub tool_thinking: ThinkingMode,
    pub chat_model: String,
    pub embedding_model: String,
    pub embedding_dimension: usize,
    /// Vision-capable model used to transcribe page images. `None` disables
    /// page transcription.
    pub vision_model: Option<String>,
    pub vision_image_detail: Option<ImageDetail>,
    pub connect_timeout: Duration,
    pub request_timeout: Duration,
    /// Total budget, retries included, for one page transcription. Reading an
    /// image and writing out a page takes longer than a chat turn.
    pub vision_request_timeout: Duration,
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
            .field("structured_output", &self.structured_output)
            .field("thinking", &self.thinking)
            .field("tool_thinking", &self.tool_thinking)
            .field("chat_model", &self.chat_model)
            .field("embedding_model", &self.embedding_model)
            .field("embedding_dimension", &self.embedding_dimension)
            .field("vision_model", &self.vision_model)
            .field("vision_image_detail", &self.vision_image_detail)
            .field("connect_timeout", &self.connect_timeout)
            .field("request_timeout", &self.request_timeout)
            .field("vision_request_timeout", &self.vision_request_timeout)
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
            structured_output: StructuredOutputMode::default(),
            thinking: ThinkingMode::default(),
            tool_thinking: ThinkingMode::default(),
            chat_model: String::new(),
            embedding_model: String::new(),
            embedding_dimension: 0,
            vision_model: None,
            vision_image_detail: None,
            connect_timeout: Duration::from_secs(10),
            request_timeout: Duration::from_secs(60),
            vision_request_timeout: Duration::from_secs(120),
            maximum_response_bytes: 4 * 1024 * 1024,
            maximum_retries: 2,
        }
    }
}

#[derive(Debug, Clone)]
pub struct OpenAiCompatibleProvider {
    config: Arc<OpenAiCompatibleConfig>,
    http: Client,
    assistant_tools: bool,
    assistant_json_object: bool,
    embedding_enabled: bool,
}

impl OpenAiCompatibleProvider {
    pub fn new(config: OpenAiCompatibleConfig) -> Result<Self, ProviderError> {
        Self::new_with_mode(config, true)
    }

    /// Assistant-only provider: no embedding endpoint or model is required.
    pub fn new_assistant_only(config: OpenAiCompatibleConfig) -> Result<Self, ProviderError> {
        Self::new_with_mode(config, false)
    }

    fn new_with_mode(
        config: OpenAiCompatibleConfig,
        embedding_enabled: bool,
    ) -> Result<Self, ProviderError> {
        validate_config_for_mode(&config, embedding_enabled)?;
        let http = Client::builder()
            .redirect(Policy::none())
            .connect_timeout(config.connect_timeout)
            .timeout(config.request_timeout)
            .build()?;
        Ok(Self {
            config: Arc::new(config),
            http,
            assistant_tools: false,
            assistant_json_object: !embedding_enabled,
            embedding_enabled,
        })
    }

    /// Explicit deployment opt-in; compatible endpoint names do not imply
    /// that the configured model supports native function tools.
    #[must_use]
    pub const fn with_assistant_tools(mut self, enabled: bool) -> Self {
        self.assistant_tools = enabled;
        self
    }

    fn assistant_payload(
        &self,
        request: &AssistantCompletionRequest,
    ) -> Result<Value, ProviderError> {
        let mut payload = assistant_v2_payload(request, &self.config.chat_model)?;
        if self.assistant_json_object {
            // JSON mode checks syntax only. Keep the same output contract in the
            // prompt when the endpoint does not support json_schema.
            let schema = payload["response_format"]["json_schema"]["schema"].to_string();
            let system = payload["messages"][0]["content"].as_str().ok_or_else(|| {
                ProviderError::InvalidRequest("missing assistant system prompt".into())
            })?;
            payload["messages"][0]["content"] = Value::String(format!(
                "{system}\n\nReturn a JSON object matching this schema exactly. Include every required field and no extra fields: {schema}"
            ));
            payload["response_format"] = serde_json::json!({"type": "json_object"});
        }
        Ok(payload)
    }

    async fn post_json(&self, path: &str, payload: &Value) -> Result<Vec<u8>, ProviderError> {
        self.post_json_within(
            path,
            payload,
            self.config.request_timeout,
            self.config.thinking,
        )
        .await
    }

    /// Posts within an explicit total budget that covers every retry.
    async fn post_json_within(
        &self,
        path: &str,
        payload: &Value,
        budget: Duration,
        thinking: ThinkingMode,
    ) -> Result<Vec<u8>, ProviderError> {
        let payload = self.adapt_payload_with(path, payload, thinking);
        timeout(budget, self.post_json_with_retries(path, &payload, budget))
            .await
            .map_err(|_| ProviderError::OperationTimeout)?
    }

    /// Applies the endpoint-specific adjustments configured for this provider.
    /// Only `chat/completions` requests carry them.
    #[cfg(test)]
    fn adapt_payload<'a>(&self, path: &str, payload: &'a Value) -> Cow<'a, Value> {
        self.adapt_payload_with(path, payload, self.config.thinking)
    }

    fn adapt_payload_with<'a>(
        &self,
        path: &str,
        payload: &'a Value,
        thinking: ThinkingMode,
    ) -> Cow<'a, Value> {
        let mut adapted = match self.config.structured_output {
            StructuredOutputMode::JsonSchema => None,
            StructuredOutputMode::JsonObject => json_object_payload(payload),
        };
        if path == "chat/completions"
            && let Some(thinking) = thinking.request_value()
        {
            adapted.get_or_insert_with(|| payload.clone())["thinking"] = thinking;
        }
        adapted.map_or(Cow::Borrowed(payload), Cow::Owned)
    }

    async fn post_json_with_retries(
        &self,
        path: &str,
        payload: &Value,
        budget: Duration,
    ) -> Result<Vec<u8>, ProviderError> {
        let url = endpoint(&self.config.base_url, path);
        let mut attempt = 0usize;
        loop {
            let mut request = self
                .http
                .post(url.clone())
                .headers(observability::current_trace_headers())
                .timeout(budget)
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
impl AssistantProvider for OpenAiCompatibleProvider {
    fn supports_assistant_tools(&self) -> bool {
        self.assistant_tools
    }

    async fn select_assistant_tools(
        &self,
        request: &crate::AssistantToolStepRequest,
    ) -> Result<crate::AssistantToolStep, ProviderError> {
        if !self.assistant_tools {
            return Err(ProviderError::InvalidConfiguration(
                "assistant tools are disabled".into(),
            ));
        }
        let payload = crate::tools::tool_payload(request, &self.config.chat_model)?;
        let thinking = match self.config.tool_thinking {
            ThinkingMode::ProviderDefault => self.config.thinking,
            explicit => explicit,
        };
        let bytes = self
            .post_json_within(
                "chat/completions",
                &payload,
                self.config.request_timeout,
                thinking,
            )
            .await?;
        let response: ToolEnvelope =
            serde_json::from_slice(&bytes).map_err(|_| crate::tools::invalid_tool_response())?;
        if response.choices.len() != 1 {
            return Err(crate::tools::invalid_tool_response());
        }
        let choice = response
            .choices
            .into_iter()
            .next()
            .ok_or_else(crate::tools::invalid_tool_response)?;
        let calls = choice.message.tool_calls.unwrap_or_default();
        if (calls.is_empty() && choice.finish_reason != "stop")
            || (!calls.is_empty() && choice.finish_reason != "tool_calls")
        {
            return Err(crate::tools::invalid_tool_response());
        }
        let mut seen = request
            .exchanges
            .iter()
            .flat_map(|exchange| exchange.calls.iter().map(|call| call.id.clone()))
            .collect();
        crate::tools::validate_calls(&calls, &mut seen)?;
        Ok(crate::AssistantToolStep {
            calls,
            token_usage: response
                .usage
                .map(ChatUsage::try_into_assistant_usage)
                .transpose()?,
        })
    }

    fn provenance_provider_id(&self) -> &'static str {
        "openai_compatible"
    }

    async fn answer_with_evidence(
        &self,
        request: &AssistantCompletionRequest,
    ) -> Result<AssistantCompletion, ProviderError> {
        let payload = self.assistant_payload(request)?;
        let bytes = self.post_json("chat/completions", &payload).await?;
        let response: ChatEnvelope = serde_json::from_slice(&bytes).map_err(|_| {
            ProviderError::InvalidResponse(
                "assistant response is not the expected JSON envelope".into(),
            )
        })?;
        let token_usage = response
            .usage
            .map(ChatUsage::try_into_assistant_usage)
            .transpose()?;
        let content = response
            .choices
            .into_iter()
            .next()
            .map(|choice| choice.message.content)
            .filter(|content| !content.trim().is_empty())
            .ok_or_else(|| {
                ProviderError::InvalidResponse("assistant response contains no content".into())
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
        let answer = validate_assistant_output(
            &content,
            request,
            Uuid::now_v7(),
            Some(model_id),
            provider_request_id,
        )
        .map_err(ProviderError::from)?;
        Ok(AssistantCompletion {
            answer,
            token_usage,
        })
    }
}

#[async_trait]
impl EmbeddingProvider for OpenAiCompatibleProvider {
    async fn embed(&self, request: &EmbeddingRequest) -> Result<EmbeddingResponse, ProviderError> {
        if !self.embedding_enabled {
            return Err(ProviderError::InvalidConfiguration(
                "assistant-only provider cannot generate embeddings".into(),
            ));
        }
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

#[async_trait]
impl DocumentRecoveryProvider for OpenAiCompatibleProvider {
    async fn annotate_document_structure(
        &self,
        request: &DocumentRecoveryRequest,
    ) -> Result<DocumentRecoveryCompletion, ProviderError> {
        let payload = recovery_payload(request, &self.config.chat_model)?;
        let bytes = self.post_json("chat/completions", &payload).await?;
        let reply = parse_chat_content(&bytes, "document recovery", &self.config.chat_model)?;
        let annotation =
            validate_recovery_output(&reply.content, request).map_err(ProviderError::from)?;
        Ok(DocumentRecoveryCompletion {
            annotation,
            model_id: Some(reply.model_id),
            provider_request_id: reply.provider_request_id,
            token_usage: reply.token_usage,
        })
    }
}

#[async_trait]
impl DocumentVisionProvider for OpenAiCompatibleProvider {
    async fn transcribe_page(
        &self,
        request: &PageTranscriptionRequest<'_>,
    ) -> Result<PageTranscriptionCompletion, ProviderError> {
        let model = self.config.vision_model.as_deref().ok_or_else(|| {
            ProviderError::InvalidConfiguration("LLM_VISION_MODEL is not configured".into())
        })?;
        let payload = transcription_payload(request, model, self.config.vision_image_detail)?;
        let bytes = self
            .post_json_within(
                "chat/completions",
                &payload,
                self.config.vision_request_timeout,
                self.config.thinking,
            )
            .await?;
        let reply = parse_chat_content(&bytes, "page transcription", model)?;
        let page =
            validate_transcription_output(&reply.content, request).map_err(ProviderError::from)?;
        Ok(PageTranscriptionCompletion {
            page,
            model_id: Some(reply.model_id),
            provider_request_id: reply.provider_request_id,
            token_usage: reply.token_usage,
        })
    }
}

/// What every JSON-mode completion carries once its envelope is checked.
struct ChatReply {
    content: String,
    model_id: String,
    provider_request_id: Option<String>,
    token_usage: Option<AssistantTokenUsage>,
}

fn parse_chat_content(
    bytes: &[u8],
    what: &'static str,
    default_model: &str,
) -> Result<ChatReply, ProviderError> {
    let response: ChatEnvelope = serde_json::from_slice(bytes).map_err(|_| {
        ProviderError::InvalidResponse(format!("{what} response is not the expected JSON envelope"))
    })?;
    let token_usage = response
        .usage
        .map(ChatUsage::try_into_assistant_usage)
        .transpose()?;
    let content = response
        .choices
        .into_iter()
        .next()
        .map(|choice| choice.message.content)
        .filter(|content| !content.trim().is_empty())
        .ok_or_else(|| {
            ProviderError::InvalidResponse(format!("{what} response contains no content"))
        })?;
    let model_id =
        validated_provider_identifier(response.model.as_deref().unwrap_or(default_model), "model")?;
    let provider_request_id = response
        .id
        .as_deref()
        .map(|value| validated_provider_identifier(value, "request"))
        .transpose()?;
    Ok(ChatReply {
        content,
        model_id,
        provider_request_id,
        token_usage,
    })
}

/// Rewrites a strict `json_schema` request for endpoints that only support
/// JSON mode. The schema moves into a system instruction placed after the
/// leading system messages. Requests without a `json_schema` format (tool
/// selection, embeddings) are left untouched.
fn json_object_payload(payload: &Value) -> Option<Value> {
    if payload
        .pointer("/response_format/type")
        .and_then(Value::as_str)
        != Some("json_schema")
    {
        return None;
    }
    let schema = payload.pointer("/response_format/json_schema/schema")?;
    let instruction = format!(
        "Reply with exactly one JSON object and nothing else: no Markdown fences and no commentary. The object must validate against this JSON Schema:\n{schema}"
    );
    let mut adapted = payload.clone();
    adapted["response_format"] = json!({"type": "json_object"});
    let messages = adapted.get_mut("messages")?.as_array_mut()?;
    let position = messages
        .iter()
        .take_while(|message| message["role"] == "system")
        .count();
    messages.insert(position, json!({"role": "system", "content": instruction}));
    Some(adapted)
}

#[derive(Debug, Deserialize)]
struct ChatEnvelope {
    id: Option<String>,
    model: Option<String>,
    choices: Vec<ChatChoice>,
    usage: Option<ChatUsage>,
}

#[derive(Deserialize)]
struct ToolEnvelope {
    choices: Vec<ToolChoice>,
    usage: Option<ChatUsage>,
}

#[derive(Deserialize)]
struct ToolChoice {
    message: ToolMessage,
    finish_reason: String,
}

#[derive(Deserialize)]
struct ToolMessage {
    // Provider prose is deliberately ignored, never published as an answer.
    tool_calls: Option<Vec<crate::AssistantToolCall>>,
}

#[derive(Debug, Deserialize)]
struct ChatUsage {
    prompt_tokens: u64,
    completion_tokens: u64,
}

impl ChatUsage {
    fn try_into_assistant_usage(self) -> Result<AssistantTokenUsage, ProviderError> {
        const MAX_REPORTED_TOKENS: u64 = 10_000_000;
        if self.prompt_tokens > MAX_REPORTED_TOKENS
            || self.completion_tokens > MAX_REPORTED_TOKENS
            || self
                .prompt_tokens
                .checked_add(self.completion_tokens)
                .is_none()
        {
            return Err(ProviderError::InvalidResponse(
                "assistant token usage exceeds its telemetry bound".to_owned(),
            ));
        }
        Ok(AssistantTokenUsage {
            input_tokens: self.prompt_tokens,
            output_tokens: self.completion_tokens,
        })
    }
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

fn validate_config_for_mode(
    config: &OpenAiCompatibleConfig,
    embedding_required: bool,
) -> Result<(), ProviderError> {
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
        || (embedding_required
            && (config.embedding_model.trim().is_empty() || config.embedding_dimension == 0))
        || config.connect_timeout.is_zero()
        || config.request_timeout.is_zero()
        || config.maximum_response_bytes == 0
        || config.maximum_retries > 5
        || config.vision_request_timeout.is_zero()
        || config.vision_request_timeout > Duration::from_secs(15 * 60)
        || !is_safe_provider_identifier(&config.chat_model)
        || (embedding_required && !is_safe_provider_identifier(&config.embedding_model))
        || config
            .vision_model
            .as_deref()
            .is_some_and(|model| !is_safe_provider_identifier(model))
    {
        return Err(ProviderError::InvalidConfiguration(
            "a credential-free provider URL, safe model IDs, dimension, positive timeouts/limit (a vision timeout of at most fifteen minutes), and at most five retries are required; deployed endpoints require non-loopback HTTPS".into(),
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

    #[tokio::test]
    async fn assistant_only_uses_json_object_and_keeps_local_validation() {
        use domain::{AssistantAnswerStyle, AssistantRequest, AssistantScope, AssistantScopeKind};

        let paper_id = Uuid::new_v4();
        let request = AssistantCompletionRequest {
            paper_title: "Test paper".to_owned(),
            request: AssistantRequest {
                paper_id,
                generation: 1,
                question: "What does retrieval augment?".to_owned(),
                scope: AssistantScope {
                    kind: AssistantScopeKind::Paper,
                    section_kinds: Vec::new(),
                    object_ids: Vec::new(),
                    selection: None,
                    passport_field: None,
                },
                answer_style: AssistantAnswerStyle::Concise,
                thread_id: None,
            },
            recent_turns: Vec::new(),
            evidence: vec![crate::BlockEvidenceExcerpt {
                block_id: Uuid::new_v4(),
                paper_id,
                generation: 1,
                section_heading: Some("Introduction".to_owned()),
                page_start: Some(1),
                text: "Retrieval augments generation with passages.".to_owned(),
            }],
        };
        let config = OpenAiCompatibleConfig {
            base_url: Url::parse("https://api.deepseek.com").unwrap(),
            chat_model: "deepseek-flash".to_owned(),
            ..OpenAiCompatibleConfig::default()
        };
        assert!(OpenAiCompatibleProvider::new(config.clone()).is_err());
        let provider = OpenAiCompatibleProvider::new_assistant_only(config).unwrap();
        let payload = provider.assistant_payload(&request).unwrap();
        assert_eq!(payload["response_format"]["type"], "json_object");
        let system = payload["messages"][0]["content"].as_str().unwrap();
        let schema = system.split_once("no extra fields: ").unwrap().1;
        let schema: Value = serde_json::from_str(schema).unwrap();
        assert_eq!(
            schema["required"],
            json!(["answer", "status", "claims", "limitations"])
        );
        assert_eq!(
            schema["properties"]["claims"]["items"]["required"],
            json!(["text", "support", "evidence"])
        );
        assert_eq!(
            schema["properties"]["claims"]["items"]["properties"]["evidence"]["items"]["required"],
            json!(["block_id", "start", "end"])
        );
        assert!(
            provider
                .embed(&EmbeddingRequest {
                    inputs: vec!["test".to_owned()],
                })
                .await
                .is_err()
        );

        let not_found = serde_json::json!({
            "answer": "Not found in this paper.",
            "status": "not_found",
            "claims": [],
            "limitations": [],
        });
        assert!(validate_assistant_output(
            &not_found.to_string(),
            &request,
            Uuid::new_v4(),
            None,
            None,
        )
        .is_ok());
        assert!(
            validate_assistant_output("not json", &request, Uuid::new_v4(), None, None,).is_err()
        );
        let unsupported = serde_json::json!({
            "answer": "Unsupported claim",
            "status": "supported",
            "claims": [{
                "text": "Unsupported claim",
                "support": "direct",
                "evidence": [{"block_id": Uuid::new_v4(), "start": 0, "end": 4}],
            }],
            "limitations": [],
        });
        assert!(
            validate_assistant_output(
                &unsupported.to_string(),
                &request,
                Uuid::new_v4(),
                None,
                None,
            )
            .is_err()
        );
    }

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

        assert!(validate_config_for_mode(&valid("http://localhost:11434/v1", false), true).is_ok());
        assert!(
            validate_config_for_mode(&valid("https://models.pakperk.app/v1", true), true).is_ok()
        );
        for url in [
            "https://user:secret@models.pakperk.app/v1",
            "https://models.pakperk.app/v1?api_key=secret",
            "https://models.pakperk.app/v1#secret",
        ] {
            assert!(
                validate_config_for_mode(&valid(url, false), true).is_err(),
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
                validate_config_for_mode(&valid(url, true), true).is_err(),
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

    #[test]
    fn structured_output_mode_defaults_to_strict_schema_and_rejects_unknown_values() {
        assert_eq!(
            OpenAiCompatibleConfig::default().structured_output,
            StructuredOutputMode::JsonSchema
        );
        assert!(matches!(
            "".parse::<StructuredOutputMode>(),
            Ok(StructuredOutputMode::JsonSchema)
        ));
        assert!(matches!(
            "json_schema".parse::<StructuredOutputMode>(),
            Ok(StructuredOutputMode::JsonSchema)
        ));
        assert!(matches!(
            " JSON_OBJECT ".parse::<StructuredOutputMode>(),
            Ok(StructuredOutputMode::JsonObject)
        ));
        assert!("yaml".parse::<StructuredOutputMode>().is_err());
    }

    #[test]
    fn json_object_mode_moves_the_schema_into_a_system_instruction() {
        let payload = json!({
            "model": "m",
            "messages": [
                {"role": "system", "content": "rules"},
                {"role": "user", "content": "question"},
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "x", "strict": true, "schema": {
                    "type": "object", "additionalProperties": false,
                    "required": ["answer"], "properties": {"answer": {"type": "string"}},
                }},
            },
        });
        let adapted = json_object_payload(&payload).expect("json_schema payloads are rewritten");
        assert_eq!(adapted["response_format"], json!({"type": "json_object"}));
        let messages = adapted["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[0]["content"], "rules");
        assert_eq!(messages[1]["role"], "system");
        let instruction = messages[1]["content"].as_str().unwrap();
        assert!(instruction.contains("JSON"));
        assert!(instruction.contains(r#""required":["answer"]"#));
        assert_eq!(messages[2]["content"], "question");
        assert_eq!(
            payload["response_format"]["type"], "json_schema",
            "input is not mutated"
        );
    }

    #[test]
    fn json_object_mode_leaves_other_requests_untouched() {
        assert!(json_object_payload(&json!({"model": "m", "input": ["a"]})).is_none());
        assert!(
            json_object_payload(&json!({
                "messages": [{"role": "user", "content": "x"}],
                "response_format": {"type": "json_object"},
            }))
            .is_none()
        );
    }

    fn provider_with(
        structured_output: StructuredOutputMode,
        thinking: ThinkingMode,
    ) -> OpenAiCompatibleProvider {
        OpenAiCompatibleProvider::new(OpenAiCompatibleConfig {
            base_url: Url::parse("http://localhost:11434/v1").unwrap(),
            structured_output,
            thinking,
            chat_model: "chat-model".to_owned(),
            embedding_model: "embedding-model".to_owned(),
            embedding_dimension: 4,
            ..OpenAiCompatibleConfig::default()
        })
        .unwrap()
    }

    fn strict_payload() -> Value {
        json!({
            "model": "m",
            "messages": [{"role": "system", "content": "rules"}, {"role": "user", "content": "q"}],
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "x", "strict": true, "schema": {
                    "type": "object", "additionalProperties": false,
                    "required": ["a"], "properties": {"a": {"type": "string"}},
                }},
            },
        })
    }

    #[test]
    fn thinking_mode_defaults_to_sending_nothing_and_rejects_unknown_values() {
        assert_eq!(
            OpenAiCompatibleConfig::default().thinking,
            ThinkingMode::ProviderDefault
        );
        assert_eq!(
            "".parse::<ThinkingMode>().unwrap(),
            ThinkingMode::ProviderDefault
        );
        assert_eq!(
            " Default ".parse::<ThinkingMode>().unwrap(),
            ThinkingMode::ProviderDefault
        );
        assert_eq!(
            "DISABLED".parse::<ThinkingMode>().unwrap(),
            ThinkingMode::Disabled
        );
        assert_eq!(
            "enabled".parse::<ThinkingMode>().unwrap(),
            ThinkingMode::Enabled
        );
        assert!("high".parse::<ThinkingMode>().is_err());
    }

    #[test]
    fn image_detail_parses_the_documented_hints() {
        assert_eq!(ImageDetail::parse_optional("").unwrap(), None);
        assert_eq!(ImageDetail::parse_optional(" AUTO ").unwrap(), None);
        assert_eq!(
            ImageDetail::parse_optional("original").unwrap(),
            Some(ImageDetail::Original)
        );
        assert_eq!(
            ImageDetail::parse_optional("Low").unwrap(),
            Some(ImageDetail::Low)
        );
        assert_eq!(
            ImageDetail::parse_optional("high").unwrap(),
            Some(ImageDetail::High)
        );
        assert!(ImageDetail::parse_optional("ultra").is_err());
    }

    #[test]
    fn thinking_is_added_to_chat_requests_only_when_configured() {
        let payload = strict_payload();

        let unchanged = provider_with(
            StructuredOutputMode::JsonSchema,
            ThinkingMode::ProviderDefault,
        )
        .adapt_payload("chat/completions", &payload);
        assert!(matches!(unchanged, Cow::Borrowed(_)), "nothing to adapt");

        let disabled = provider_with(StructuredOutputMode::JsonSchema, ThinkingMode::Disabled)
            .adapt_payload("chat/completions", &payload);
        assert_eq!(disabled["thinking"], json!({"type": "disabled"}));
        assert_eq!(disabled["response_format"]["type"], "json_schema");

        let enabled = provider_with(StructuredOutputMode::JsonSchema, ThinkingMode::Enabled)
            .adapt_payload("chat/completions", &payload);
        assert_eq!(enabled["thinking"], json!({"type": "enabled"}));

        // Embeddings never carry it.
        let embedding = json!({"model": "m", "input": ["a"]});
        let untouched = provider_with(StructuredOutputMode::JsonSchema, ThinkingMode::Disabled)
            .adapt_payload("embeddings", &embedding);
        assert!(untouched.get("thinking").is_none());

        // It combines with JSON mode.
        let both = provider_with(StructuredOutputMode::JsonObject, ThinkingMode::Disabled)
            .adapt_payload("chat/completions", &payload);
        assert_eq!(both["thinking"], json!({"type": "disabled"}));
        assert_eq!(both["response_format"], json!({"type": "json_object"}));
        assert_eq!(payload.get("thinking"), None, "input is not mutated");
    }

    #[test]
    fn vision_settings_are_validated() {
        let valid = OpenAiCompatibleConfig {
            base_url: Url::parse("http://localhost:11434/v1").unwrap(),
            chat_model: "chat-model".to_owned(),
            embedding_model: "embedding-model".to_owned(),
            embedding_dimension: 4,
            ..OpenAiCompatibleConfig::default()
        };
        let check = |config: OpenAiCompatibleConfig| validate_config_for_mode(&config, true);
        assert!(check(valid.clone()).is_ok());
        assert!(
            check(OpenAiCompatibleConfig {
                vision_model: Some("vision-model".to_owned()),
                ..valid.clone()
            })
            .is_ok()
        );
        for model in ["", "vision model", "Bearer token", "vision\nmodel"] {
            assert!(
                check(OpenAiCompatibleConfig {
                    vision_model: Some(model.to_owned()),
                    ..valid.clone()
                })
                .is_err(),
                "accepted {model:?}"
            );
        }
        for timeout in [Duration::ZERO, Duration::from_secs(16 * 60)] {
            assert!(
                check(OpenAiCompatibleConfig {
                    vision_request_timeout: timeout,
                    ..valid.clone()
                })
                .is_err()
            );
        }
        // An assistant-only provider never validates the embedding settings, but
        // it still validates the vision ones.
        assert!(
            validate_config_for_mode(
                &OpenAiCompatibleConfig {
                    embedding_model: String::new(),
                    ..valid.clone()
                },
                false
            )
            .is_ok()
        );
        assert!(
            validate_config_for_mode(
                &OpenAiCompatibleConfig {
                    embedding_model: String::new(),
                    vision_model: Some("vision model".to_owned()),
                    ..valid
                },
                false
            )
            .is_err()
        );
    }

    #[test]
    fn page_transcription_needs_a_configured_vision_model() {
        let provider = provider_with(
            StructuredOutputMode::JsonSchema,
            ThinkingMode::ProviderDefault,
        );
        let png = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0];
        let request = PageTranscriptionRequest {
            page_number: 1,
            page_count: 1,
            png: &png,
        };
        let error = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(provider.transcribe_page(&request))
            .unwrap_err();
        assert!(matches!(error, ProviderError::InvalidConfiguration(_)));
    }

    #[test]
    fn assistant_token_usage_is_bounded_and_content_free() {
        assert_eq!(
            ChatUsage {
                prompt_tokens: 120,
                completion_tokens: 45,
            }
            .try_into_assistant_usage()
            .unwrap(),
            AssistantTokenUsage {
                input_tokens: 120,
                output_tokens: 45,
            }
        );
        assert!(
            ChatUsage {
                prompt_tokens: 10_000_001,
                completion_tokens: 0,
            }
            .try_into_assistant_usage()
            .is_err()
        );
    }
}
