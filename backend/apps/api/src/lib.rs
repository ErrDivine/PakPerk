use std::{
    collections::HashMap,
    net::SocketAddr,
    str::FromStr,
    sync::Arc,
    time::{Duration, Instant},
};

use arxiv_client::{ArxivClient, ArxivClientConfig, ArxivError, normalize_arxiv_id};
use axum::{
    Extension, Json, Router,
    extract::{ConnectInfo, DefaultBodyLimit, Path, Query, Request, State},
    http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, header::CONTENT_TYPE},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use db::{CursorError, Database, DbError, FeedCursor, FeedQuery, PaperRepository};
use domain::{
    ApiErrorBody, ApiErrorEnvelope, Capabilities, FailureCategory, FulltextPolicy,
    OverallProcessingState, Paper, PaperSummary, ProcessingError, ProcessingStage, ProcessingState,
};
use llm_provider::{
    ChatCompletionRequest, ChatProvider, DeterministicProvider, EmbeddingProvider,
    EmbeddingRequest, EvidenceExcerpt, OpenAiCompatibleConfig, OpenAiCompatibleProvider,
    ProviderError,
};
use retrieval::{
    ContextSelectionConfig, RetrievalScope, SearchHit, hybrid_rank, keyword_websearch_query,
    select_context,
};
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Mutex;
use tower_http::{
    cors::{AllowOrigin, CorsLayer},
    trace::{DefaultMakeSpan, DefaultOnResponse, TraceLayer},
};
use tracing::{Level, error, info};
use url::Url;
use uuid::Uuid;

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");
const SESSION_ID_HEADER: HeaderName = HeaderName::from_static("x-session-id");
const NEGATIVE_EXACT_ARXIV_CACHE_TTL: Duration = Duration::from_secs(15 * 60);

#[derive(Debug, Clone)]
pub struct ApiConfig {
    pub bind: SocketAddr,
    pub database_url: String,
    pub database_pool_size: u32,
    pub run_migrations: bool,
    pub request_timeout: Duration,
    pub chat_request_timeout: Duration,
    pub max_request_bytes: usize,
    pub cors_allowed_origins: Vec<HeaderValue>,
    pub arxiv: ArxivClientConfig,
    pub arxiv_cache_ttl: Duration,
    pub fulltext_policy: FulltextPolicy,
    pub embedding_dimension: Option<usize>,
    pub llm: Option<ApiModelConfig>,
    pub prepare_requests_per_minute: u32,
    pub chat_requests_per_minute: u32,
}

impl ApiConfig {
    pub fn from_env() -> anyhow::Result<Self> {
        let bind = std::env::var("API_BIND")
            .unwrap_or_else(|_| "0.0.0.0:8080".to_owned())
            .parse()?;
        let database_url = std::env::var("DATABASE_URL")
            .map_err(|_| anyhow::anyhow!("DATABASE_URL is required"))?;
        let request_timeout = Duration::from_secs(env_parse_alias(
            &["API_REQUEST_TIMEOUT_SECONDS", "REQUEST_TIMEOUT_SECONDS"],
            30_u64,
        )?);
        let max_request_bytes = env_parse("API_MAX_REQUEST_BYTES", 64 * 1024_usize)?;
        let cors_allowed_origins = env_first(&["CORS_ALLOWED_ORIGINS", "CORS_ALLOWED_ORIGIN"])
            .map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|origin| !origin.is_empty())
                    .map(HeaderValue::from_str)
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?
            .unwrap_or_default();

        let mut arxiv = ArxivClientConfig::default();
        arxiv.user_agent =
            std::env::var("ARXIV_USER_AGENT").unwrap_or_else(|_| arxiv.user_agent.clone());
        arxiv.contact_email =
            std::env::var("ARXIV_CONTACT_EMAIL").unwrap_or_else(|_| arxiv.contact_email.clone());
        arxiv.minimum_interval =
            Duration::from_millis(env_parse("ARXIV_MIN_INTERVAL_MS", 3_000_u64)?);
        arxiv.request_timeout = Duration::from_secs(env_parse_alias(
            &["ARXIV_TIMEOUT_SECONDS", "ARXIV_REQUEST_TIMEOUT_SECONDS"],
            30_u64,
        )?);
        arxiv.max_pdf_bytes = env_parse("MAX_PDF_BYTES", arxiv.max_pdf_bytes)?;
        // Every external attempt must first reserve the PostgreSQL-backed
        // cross-process gate. Disable the client's process-local retry loop;
        // mobile/API retry re-enters this reservation.
        enforce_cross_process_arxiv_gate(&mut arxiv);

        let configured_embedding_dimension = std::env::var("EMBEDDING_DIMENSION")
            .ok()
            .map(|value| value.parse())
            .transpose()?;
        let (embedding_dimension, llm) = provider_config_from_env(configured_embedding_dimension)?;
        let default_chat_timeout = llm
            .as_ref()
            .map_or(Duration::from_secs(65), ApiModelConfig::request_timeout)
            .saturating_add(Duration::from_secs(5));
        let chat_request_timeout = Duration::from_secs(env_parse(
            "CHAT_REQUEST_TIMEOUT_SECONDS",
            default_chat_timeout.as_secs(),
        )?);

        Ok(Self {
            bind,
            database_url,
            database_pool_size: env_parse("DATABASE_POOL_SIZE", 10_u32)?,
            run_migrations: env_bool("RUN_MIGRATIONS", true)?,
            request_timeout,
            chat_request_timeout,
            max_request_bytes,
            cors_allowed_origins,
            arxiv,
            arxiv_cache_ttl: Duration::from_secs(env_parse(
                "ARXIV_CACHE_TTL_SECONDS",
                24 * 60 * 60_u64,
            )?),
            fulltext_policy: std::env::var("FULLTEXT_POLICY")
                .unwrap_or_else(|_| "prototype".to_owned())
                .parse()?,
            embedding_dimension,
            llm,
            prepare_requests_per_minute: env_parse_alias(
                &[
                    "PREPARE_RATE_LIMIT_PER_MINUTE",
                    "PREPARE_REQUESTS_PER_MINUTE",
                ],
                30_u32,
            )?,
            chat_requests_per_minute: env_parse_alias(
                &["CHAT_RATE_LIMIT_PER_MINUTE", "CHAT_REQUESTS_PER_MINUTE"],
                10_u32,
            )?,
        })
    }
}

#[derive(Debug, Clone)]
pub enum ApiModelConfig {
    Deterministic { embedding_dimension: usize },
    OpenAiCompatible(OpenAiCompatibleConfig),
}

impl ApiModelConfig {
    fn request_timeout(&self) -> Duration {
        match self {
            Self::Deterministic { .. } => Duration::from_secs(60),
            Self::OpenAiCompatible(config) => config.request_timeout,
        }
    }
}

fn provider_config_from_env(
    embedding_dimension: Option<usize>,
) -> anyhow::Result<(Option<usize>, Option<ApiModelConfig>)> {
    let demo_mode = env_bool("DEMO_MODE", true)?;
    let provider = std::env::var("LLM_PROVIDER").unwrap_or_else(|_| {
        if demo_mode {
            "deterministic"
        } else {
            "disabled"
        }
        .to_owned()
    });
    if provider.eq_ignore_ascii_case("disabled") {
        return Ok((embedding_dimension, None));
    }
    if provider.eq_ignore_ascii_case("deterministic") {
        let dimension = embedding_dimension.unwrap_or(384);
        return Ok((
            Some(dimension),
            Some(ApiModelConfig::Deterministic {
                embedding_dimension: dimension,
            }),
        ));
    }
    let mut config = OpenAiCompatibleConfig::default();
    if let Ok(base_url) = std::env::var("LLM_BASE_URL")
        && !base_url.trim().is_empty()
    {
        config.base_url = Url::parse(&base_url)?;
    }
    config.api_key = std::env::var("LLM_API_KEY")
        .ok()
        .filter(|key| !key.is_empty())
        .map(SecretString::from);
    config.chat_model = std::env::var("LLM_CHAT_MODEL")
        .map_err(|_| anyhow::anyhow!("LLM_CHAT_MODEL is required when LLM_PROVIDER is enabled"))?;
    config.embedding_model = std::env::var("LLM_EMBEDDING_MODEL").map_err(|_| {
        anyhow::anyhow!("LLM_EMBEDDING_MODEL is required when LLM_PROVIDER is enabled")
    })?;
    config.embedding_dimension = embedding_dimension.ok_or_else(|| {
        anyhow::anyhow!("EMBEDDING_DIMENSION is required when LLM_PROVIDER is enabled")
    })?;
    config.request_timeout = Duration::from_secs(env_parse("LLM_TIMEOUT_SECONDS", 60_u64)?);
    config.maximum_response_bytes = env_parse("LLM_MAX_RESPONSE_BYTES", 4 * 1024 * 1024_usize)?;
    config.maximum_retries = env_parse("LLM_MAX_RETRIES", 2_usize)?;
    Ok((
        embedding_dimension,
        Some(ApiModelConfig::OpenAiCompatible(config)),
    ))
}

trait ApiModelProvider: ChatProvider + EmbeddingProvider {}

impl<T> ApiModelProvider for T where T: ChatProvider + EmbeddingProvider {}

fn env_parse<T>(name: &str, default: T) -> anyhow::Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    match std::env::var(name) {
        Ok(value) => Ok(value.parse()?),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

fn env_parse_alias<T>(names: &[&str], default: T) -> anyhow::Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    match env_first(names) {
        Some(value) => Ok(value.parse()?),
        None => Ok(default),
    }
}

fn env_first(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| std::env::var(name).ok())
}

fn env_bool(name: &str, default: bool) -> anyhow::Result<bool> {
    match std::env::var(name) {
        Ok(value) if value.eq_ignore_ascii_case("true") || value == "1" => Ok(true),
        Ok(value) if value.eq_ignore_ascii_case("false") || value == "0" => Ok(false),
        Ok(value) => Err(anyhow::anyhow!(
            "{name} must be true/false or 1/0, got `{value}`"
        )),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

fn enforce_cross_process_arxiv_gate(config: &mut ArxivClientConfig) {
    config.max_retries = 0;
}

#[derive(Clone)]
pub struct AppState {
    database: Database,
    papers: PaperRepository,
    arxiv: ArxivClient,
    arxiv_minimum_interval: Duration,
    arxiv_cache_ttl: Duration,
    fulltext_policy: FulltextPolicy,
    model_provider: Option<Arc<dyn ApiModelProvider>>,
    limiter: RateLimiter,
    prepare_limit: u32,
    chat_limit: u32,
}

impl AppState {
    pub fn new(database: Database, config: &ApiConfig) -> anyhow::Result<Self> {
        let papers = database.papers();
        let mut arxiv_config = config.arxiv.clone();
        // Programmatic construction has the same cross-process invariant as
        // environment construction: no HTTP retry may reuse one DB permit.
        enforce_cross_process_arxiv_gate(&mut arxiv_config);
        let model_provider: Option<Arc<dyn ApiModelProvider>> = match config.llm.clone() {
            Some(ApiModelConfig::Deterministic {
                embedding_dimension,
            }) => Some(Arc::new(DeterministicProvider::new(embedding_dimension)?)),
            Some(ApiModelConfig::OpenAiCompatible(config)) => {
                Some(Arc::new(OpenAiCompatibleProvider::new(config)?))
            }
            None => None,
        };
        Ok(Self {
            database,
            papers,
            arxiv: ArxivClient::new_with_external_gate(arxiv_config)?,
            arxiv_minimum_interval: config.arxiv.minimum_interval,
            arxiv_cache_ttl: config.arxiv_cache_ttl,
            fulltext_policy: config.fulltext_policy,
            model_provider,
            limiter: RateLimiter::default(),
            prepare_limit: config.prepare_requests_per_minute.max(1),
            chat_limit: config.chat_requests_per_minute.max(1),
        })
    }
}

pub fn build_router(state: AppState, config: &ApiConfig) -> Router {
    let cors = if config.cors_allowed_origins.is_empty() {
        CorsLayer::new()
    } else {
        CorsLayer::new()
            .allow_origin(AllowOrigin::list(config.cors_allowed_origins.clone()))
            .allow_methods([Method::GET, Method::POST])
            .allow_headers([CONTENT_TYPE, SESSION_ID_HEADER, REQUEST_ID_HEADER])
    };

    Router::new()
        .route("/health/live", get(health_live))
        .route("/health/ready", get(health_ready))
        .route("/v1/feed", get(feed))
        .route("/v1/papers/{paper_id}", get(paper_metadata))
        .route("/v1/papers/by-arxiv/{*arxiv_id}", get(paper_by_arxiv))
        .route("/v1/papers/{paper_id}/prepare", post(prepare))
        .route("/v1/papers/{paper_id}/processing", get(processing))
        .route("/v1/papers/{paper_id}/introduction", get(introduction))
        .route("/v1/papers/{paper_id}/chat", post(chat))
        .route("/v1/papers/{paper_id}/connections", get(connections))
        .fallback(not_found)
        .with_state(state)
        .layer(DefaultBodyLimit::max(config.max_request_bytes))
        .layer(cors)
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(
                    DefaultMakeSpan::new()
                        .level(Level::INFO)
                        .include_headers(false),
                )
                .on_response(DefaultOnResponse::new().level(Level::INFO)),
        )
        .layer(middleware::from_fn_with_state(
            TimeoutConfig {
                default: config.request_timeout,
                chat: config.chat_request_timeout,
            },
            timeout_middleware,
        ))
        .layer(middleware::from_fn(stable_error_middleware))
        .layer(middleware::from_fn(request_id_middleware))
}

#[derive(Debug, Clone, Copy)]
struct RequestId(Uuid);

struct ChatObservation {
    request_id: RequestId,
    paper_id: Uuid,
    generation: Option<i32>,
    started: Instant,
    outcome: &'static str,
    evidence_count: usize,
}

impl ChatObservation {
    fn new(request_id: RequestId, paper_id: Uuid) -> Self {
        Self {
            request_id,
            paper_id,
            generation: None,
            started: Instant::now(),
            outcome: "error_or_rejected",
            evidence_count: 0,
        }
    }
}

impl Drop for ChatObservation {
    fn drop(&mut self) {
        info!(
            metric.name = "chat_request",
            request_id = %self.request_id.0,
            paper_id = %self.paper_id,
            generation = ?self.generation,
            chat.latency_ms = self.started.elapsed().as_millis(),
            chat.outcome = self.outcome,
            chat.evidence_count = self.evidence_count,
            "paper chat request completed"
        );
    }
}

async fn request_id_middleware(mut request: Request, next: Next) -> Response {
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

async fn timeout_middleware(
    State(timeouts): State<TimeoutConfig>,
    request: Request,
    next: Next,
) -> Response {
    let request_id = request
        .extensions()
        .get::<RequestId>()
        .copied()
        .unwrap_or_else(|| RequestId(Uuid::now_v7()));
    let timeout = if request.uri().path().ends_with("/chat") {
        timeouts.chat
    } else {
        timeouts.default
    };
    match tokio::time::timeout(timeout, next.run(request)).await {
        Ok(response) => response,
        Err(_) => ApiError::new(
            request_id,
            StatusCode::GATEWAY_TIMEOUT,
            "REQUEST_TIMEOUT",
            "The request took too long. Please try again.",
            true,
        )
        .into_response(),
    }
}

async fn stable_error_middleware(request: Request, next: Next) -> Response {
    let request_id = request
        .extensions()
        .get::<RequestId>()
        .copied()
        .unwrap_or_else(|| RequestId(Uuid::now_v7()));
    let response = next.run(request).await;
    let status = response.status();
    let is_json = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("application/json"));
    if !status.is_client_error() && !status.is_server_error() || is_json {
        return response;
    }
    let (code, message, retryable) = match status {
        StatusCode::METHOD_NOT_ALLOWED => (
            "METHOD_NOT_ALLOWED",
            "That HTTP method is not supported for this route.",
            false,
        ),
        StatusCode::PAYLOAD_TOO_LARGE => (
            "REQUEST_BODY_TOO_LARGE",
            "The request body exceeds the service limit.",
            false,
        ),
        StatusCode::UNSUPPORTED_MEDIA_TYPE => (
            "UNSUPPORTED_MEDIA_TYPE",
            "This endpoint requires an application/json request body.",
            false,
        ),
        StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => (
            "INVALID_REQUEST",
            "The request body or path parameters are invalid.",
            false,
        ),
        _ if status.is_server_error() => (
            "INTERNAL_ERROR",
            "The service could not complete the request.",
            true,
        ),
        _ => ("REQUEST_REJECTED", "The request was rejected.", false),
    };
    ApiError::new(request_id, status, code, message, retryable).into_response()
}

#[derive(Debug, Clone, Copy)]
struct TimeoutConfig {
    default: Duration,
    chat: Duration,
}

async fn health_live() -> impl IntoResponse {
    (StatusCode::OK, Json(json!({"status": "ok"})))
}

async fn health_ready(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
) -> Result<impl IntoResponse, ApiError> {
    state
        .database
        .ready()
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    Ok((StatusCode::OK, Json(json!({"status": "ready"}))))
}

#[derive(Debug, Deserialize)]
struct FeedParams {
    category: Option<String>,
    cursor: Option<String>,
    limit: Option<u32>,
}

async fn feed(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Query(params): Query<FeedParams>,
) -> Result<impl IntoResponse, ApiError> {
    if let Some(category) = &params.category
        && !valid_category(category)
    {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_CATEGORY",
            "Category must be an arXiv category such as cs.AI.",
            false,
        ));
    }
    let cursor = params
        .cursor
        .as_deref()
        .map(FeedCursor::decode)
        .transpose()
        .map_err(|error| cursor_error(request_id, &error))?;
    let mut page = state
        .papers
        .feed(&FeedQuery {
            category: params.category,
            cursor,
            limit: params.limit.unwrap_or(20),
        })
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let paper_ids = page
            .items
            .iter()
            .map(|paper| paper.paper_id)
            .collect::<Vec<_>>();
        let licenses = state
            .papers
            .license_uris(&paper_ids)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?;
        for paper in &mut page.items {
            apply_summary_policy(
                state.fulltext_policy,
                licenses.get(&paper.paper_id).and_then(Option::as_ref),
                paper,
            );
        }
    }
    Ok((StatusCode::OK, Json(page)))
}

async fn paper_metadata(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let mut paper = state
        .papers
        .get_summary(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let persisted = state
            .papers
            .get(paper_id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_summary_policy(
            state.fulltext_policy,
            persisted.metadata.license_uri.as_ref(),
            &mut paper,
        );
    }
    Ok((StatusCode::OK, Json(paper)))
}

async fn paper_by_arxiv(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(arxiv_id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let normalized = normalize_arxiv_id(&arxiv_id).map_err(|_| invalid_arxiv_id(request_id))?;
    if let Some(paper) = state
        .papers
        .get_by_arxiv_base(&normalized.base_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
    {
        let mut summary = state
            .papers
            .get_summary(paper.id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_summary_policy(
            state.fulltext_policy,
            paper.metadata.license_uri.as_ref(),
            &mut summary,
        );
        return Ok((StatusCode::OK, Json(summary)));
    }

    let cache_key = format!("exact:{}", normalized.as_query_id());
    let metadata = if let Some(mut cached) = state
        .papers
        .get_cached_arxiv(&cache_key)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
    {
        cached.pop()
    } else {
        state
            .papers
            .reserve_arxiv_request(state.arxiv_minimum_interval)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?;
        let outcome = state.arxiv.fetch_by_id(&normalized.as_query_id()).await;
        let fetched = observe_arxiv_result(&state, request_id, outcome).await?;
        match &fetched {
            Some(metadata) => {
                state
                    .papers
                    .put_cached_arxiv(
                        &cache_key,
                        "exact_id",
                        std::slice::from_ref(metadata),
                        state.arxiv_cache_ttl,
                    )
                    .await
                    .map_err(|error| internal_db_error(request_id, &error))?;
            }
            None => {
                state
                    .papers
                    .put_cached_arxiv(
                        &cache_key,
                        "exact_id",
                        &[],
                        negative_exact_cache_ttl(state.arxiv_cache_ttl),
                    )
                    .await
                    .map_err(|error| internal_db_error(request_id, &error))?;
            }
        }
        fetched
    }
    .ok_or_else(|| paper_not_found(request_id))?;
    let paper = state
        .papers
        .upsert_metadata(&metadata)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    let mut summary = state
        .papers
        .get_summary(paper.id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    apply_summary_policy(
        state.fulltext_policy,
        paper.metadata.license_uri.as_ref(),
        &mut summary,
    );
    Ok((StatusCode::OK, Json(summary)))
}

#[derive(Debug, Default, Deserialize)]
struct PrepareBody {
    #[serde(default)]
    retry: bool,
}

#[axum::debug_handler]
async fn prepare(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    remote: ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<PrepareBody>,
) -> Result<impl IntoResponse, ApiError> {
    state
        .limiter
        .check_all(
            "prepare",
            client_keys(&headers, Some(&remote)),
            state.prepare_limit,
            Duration::from_secs(60),
        )
        .await
        .map_err(|_| rate_limited(request_id))?;
    let mut result = state
        .papers
        .prepare(paper_id, body.retry)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let paper = state
            .papers
            .get(paper_id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_processing_policy(
            state.fulltext_policy,
            paper.metadata.license_uri.as_ref(),
            &mut result.state,
        );
    }
    let status = if result.state.is_ready() || (result.state.failed() && !result.enqueued) {
        StatusCode::OK
    } else {
        StatusCode::ACCEPTED
    };
    Ok((status, Json(result.state)))
}

async fn processing(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let mut processing = state
        .papers
        .processing(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if state.fulltext_policy == FulltextPolicy::Strict {
        let paper = state
            .papers
            .get(paper_id)
            .await
            .map_err(|error| internal_db_error(request_id, &error))?
            .ok_or_else(|| paper_not_found(request_id))?;
        apply_processing_policy(
            state.fulltext_policy,
            paper.metadata.license_uri.as_ref(),
            &mut processing,
        );
    }
    Ok((StatusCode::OK, Json(processing)))
}

async fn introduction(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    enforce_derived_policy(&state, request_id, paper_id).await?;
    if let Some(introduction) = state
        .papers
        .introduction(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
    {
        return Ok((StatusCode::OK, Json(introduction)));
    }
    let processing = state
        .papers
        .processing(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    Err(capability_not_ready(
        request_id,
        "The introduction is still being prepared.",
        &processing,
    ))
}

#[axum::debug_handler]
#[allow(clippy::too_many_lines)]
async fn chat(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    remote: ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<ChatBody>,
) -> Result<impl IntoResponse, ApiError> {
    let mut observation = ChatObservation::new(request_id, paper_id);
    state
        .limiter
        .check_all(
            "chat",
            client_keys(&headers, Some(&remote)),
            state.chat_limit,
            Duration::from_secs(60),
        )
        .await
        .map_err(|_| rate_limited(request_id))?;
    let session_id = validate_chat_body(request_id, &headers, paper_id, &body)?;
    let paper = enforce_derived_policy(&state, request_id, paper_id).await?;
    let processing = state
        .papers
        .processing(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    observation.generation = Some(processing.generation);
    if !processing.capabilities.chat {
        return Err(capability_not_ready(
            request_id,
            "Chat is still indexing later sections.",
            &processing,
        ));
    }
    let provider = state.model_provider.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "MODEL_UNAVAILABLE",
            "Paper chat is temporarily unavailable.",
            true,
        )
    })?;
    let chat_session = state
        .papers
        .open_chat(session_id, paper_id, processing.generation, body.thread_id)
        .await
        .map_err(|error| match error {
            DbError::InvalidChatThread => ApiError::new(
                request_id,
                StatusCode::NOT_FOUND,
                "CHAT_THREAD_NOT_FOUND",
                "The chat thread does not belong to this paper and session.",
                false,
            ),
            _ => internal_db_error(request_id, &error),
        })?;
    let question = body.message.trim();
    let embedded = provider
        .embed(&EmbeddingRequest {
            inputs: vec![question.to_owned()],
        })
        .await
        .map_err(|error| provider_error(request_id, &error))?;
    let query_embedding = embedded.vectors.first().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::BAD_GATEWAY,
            "MODEL_INVALID_RESPONSE",
            "The model provider returned no query embedding.",
            true,
        )
    })?;
    let keyword_query = keyword_websearch_query(question);
    let (vector, keyword) = tokio::try_join!(
        state
            .papers
            .vector_candidates(paper_id, processing.generation, query_embedding, 24,),
        state
            .papers
            .keyword_candidates(paper_id, processing.generation, &keyword_query, 24)
    )
    .map_err(|error| internal_db_error(request_id, &error))?;
    let scope = RetrievalScope {
        paper_id,
        generation: processing.generation,
    };
    let vector_hits = vector
        .into_iter()
        .map(|candidate| SearchHit {
            score: reciprocal_rank_score(candidate.rank),
            chunk: candidate.chunk,
        })
        .collect();
    let keyword_hits = keyword
        .into_iter()
        .map(|candidate| SearchHit {
            score: reciprocal_rank_score(candidate.rank),
            chunk: candidate.chunk,
        })
        .collect();
    // Keep enough fused candidates for the bounded context selector to
    // preserve exact lexical passages alongside vector/fused leaders.
    let fused = hybrid_rank(scope, vector_hits, keyword_hits, 24)
        .map_err(|error| retrieval_error(request_id, &error))?;
    let context = select_context(scope, &fused, ContextSelectionConfig::default())
        .map_err(|error| retrieval_error(request_id, &error))?;
    if context.is_empty() {
        return Err(ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "PAPER_CONTEXT_EMPTY",
            "No indexed paper excerpts could support an answer.",
            true,
        ));
    }
    let evidence = context
        .into_iter()
        .map(|chunk| EvidenceExcerpt {
            chunk_id: chunk.id,
            section_kind: chunk.section_kind,
            section_heading: chunk.section_heading,
            page_start: chunk.page_start,
            page_end: chunk.page_end,
            text: chunk.text,
        })
        .collect();
    let answer = provider
        .answer(&ChatCompletionRequest {
            paper_title: paper.metadata.title,
            question: question.to_owned(),
            recent_turns: chat_session.recent_turns,
            evidence,
        })
        .await
        .map_err(|error| provider_error(request_id, &error))?;
    state
        .papers
        .persist_chat_exchange(
            session_id,
            paper_id,
            chat_session.thread_id,
            question,
            &answer,
        )
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    observation.outcome = if answer.insufficient_evidence {
        "insufficient_evidence"
    } else {
        "answered"
    };
    observation.evidence_count = answer.evidence.len();

    Ok((
        StatusCode::OK,
        Json(ChatResponse {
            thread_id: chat_session.thread_id,
            answer,
        }),
    ))
}

#[derive(Debug, Deserialize)]
struct ChatBody {
    thread_id: Option<Uuid>,
    message: String,
}

#[derive(Debug, Serialize)]
struct ChatResponse {
    thread_id: Uuid,
    #[serde(flatten)]
    answer: domain::ChatAnswer,
}

fn validate_chat_body(
    request_id: RequestId,
    headers: &HeaderMap,
    _paper_id: Uuid,
    body: &ChatBody,
) -> Result<Uuid, ApiError> {
    let session_id = headers
        .get(&SESSION_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_SESSION_ID",
                "X-Session-Id must contain an anonymous UUID.",
                false,
            )
        })?;
    let message = body.message.trim();
    if message.is_empty() {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "EMPTY_QUESTION",
            "The question must not be empty.",
            false,
        ));
    }
    if message.chars().count() > 500 {
        return Err(ApiError::new(
            request_id,
            StatusCode::PAYLOAD_TOO_LARGE,
            "QUESTION_TOO_LONG",
            "Questions may contain at most 500 characters.",
            false,
        ));
    }
    Ok(session_id)
}

async fn connections(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let connections = state
        .papers
        .connections(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    Ok((StatusCode::OK, Json(connections)))
}

async fn not_found(Extension(request_id): Extension<RequestId>) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::NOT_FOUND,
        "ROUTE_NOT_FOUND",
        "The requested API route does not exist.",
        false,
    )
}

#[derive(Debug)]
struct ApiError {
    request_id: RequestId,
    status: StatusCode,
    code: &'static str,
    message: String,
    retryable: bool,
}

impl ApiError {
    fn new(
        request_id: RequestId,
        status: StatusCode,
        code: &'static str,
        message: impl Into<String>,
        retryable: bool,
    ) -> Self {
        Self {
            request_id,
            status,
            code,
            message: message.into(),
            retryable,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = ApiErrorEnvelope {
            error: ApiErrorBody {
                code: self.code.to_owned(),
                message: self.message,
                retryable: self.retryable,
                request_id: self.request_id.0,
            },
        };
        (self.status, Json(body)).into_response()
    }
}

const FULLTEXT_POLICY_DENIED_MESSAGE: &str = "Derived paper content is unavailable under the configured full-text policy. \
     Metadata and original arXiv links remain available.";

async fn enforce_derived_policy(
    state: &AppState,
    request_id: RequestId,
    paper_id: Uuid,
) -> Result<Paper, ApiError> {
    let paper = state
        .papers
        .get(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if !state
        .fulltext_policy
        .allows_derived_content(paper.metadata.license_uri.as_ref())
    {
        return Err(fulltext_policy_denied(request_id));
    }
    Ok(paper)
}

fn apply_summary_policy(
    policy: FulltextPolicy,
    license_uri: Option<&Url>,
    paper: &mut PaperSummary,
) {
    if !policy.allows_derived_content(license_uri) {
        paper.capabilities = Capabilities::metadata_only();
    }
}

fn apply_processing_policy(
    policy: FulltextPolicy,
    license_uri: Option<&Url>,
    processing: &mut ProcessingState,
) {
    if policy.allows_derived_content(license_uri) {
        return;
    }
    let had_derived_state = processing.capabilities.introduction
        || processing.capabilities.chat
        || processing.capabilities.connections
        || matches!(
            processing.stage,
            ProcessingStage::IntroductionReady
                | ProcessingStage::IndexingChat
                | ProcessingStage::ResolvingReferences
                | ProcessingStage::Ready
        );
    processing.capabilities = Capabilities::metadata_only();
    if had_derived_state {
        processing.overall_state = OverallProcessingState::Failed;
        processing.stage = ProcessingStage::FailedTerminal;
        processing.retryable = false;
        processing.last_error = Some(ProcessingError {
            category: FailureCategory::Validation,
            code: "FULLTEXT_POLICY_DENIED".to_owned(),
            message: FULLTEXT_POLICY_DENIED_MESSAGE.to_owned(),
        });
        processing.completed_at = Some(processing.updated_at);
        processing.parser_version = None;
        processing.embedding_model = None;
        processing.summary_model = None;
    }
}

fn fulltext_policy_denied(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::FORBIDDEN,
        "FULLTEXT_POLICY_DENIED",
        FULLTEXT_POLICY_DENIED_MESSAGE,
        false,
    )
}

fn paper_not_found(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::NOT_FOUND,
        "PAPER_NOT_FOUND",
        "The requested paper is not in the metadata cache.",
        false,
    )
}

fn invalid_arxiv_id(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_ARXIV_ID",
        "The arXiv identifier is invalid.",
        false,
    )
}

fn rate_limited(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::TOO_MANY_REQUESTS,
        "RATE_LIMITED",
        "Too many requests. Please wait before retrying.",
        true,
    )
}

fn cursor_error(request_id: RequestId, _error: &CursorError) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_CURSOR",
        "The feed cursor is invalid or expired.",
        false,
    )
}

fn internal_db_error(request_id: RequestId, error_value: &DbError) -> ApiError {
    error!(
        request_id = %request_id.0,
        error = %error_value,
        "database operation failed"
    );
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "DATABASE_UNAVAILABLE",
        "The service could not access prepared paper data.",
        true,
    )
}

async fn observe_arxiv_result<T>(
    state: &AppState,
    request_id: RequestId,
    outcome: Result<T, ArxivError>,
) -> Result<T, ApiError> {
    match outcome {
        Ok(value) => Ok(value),
        Err(error_value) => {
            if let Some(cooldown) = error_value.shared_cooldown()
                && let Err(database_error) = state.papers.defer_arxiv_requests(cooldown).await
            {
                error!(
                    request_id = %request_id.0,
                    error = %database_error,
                    cooldown_seconds = cooldown.as_secs(),
                    "could not publish shared arXiv cooldown"
                );
            }
            Err(arxiv_error(request_id, &error_value))
        }
    }
}

fn negative_exact_cache_ttl(configured: Duration) -> Duration {
    configured
        .min(NEGATIVE_EXACT_ARXIV_CACHE_TTL)
        .max(Duration::from_secs(1))
}

fn arxiv_error(request_id: RequestId, error_value: &ArxivError) -> ApiError {
    error!(
        request_id = %request_id.0,
        error = %error_value,
        "arXiv request failed"
    );
    let (status, code, retryable) = match error_value {
        ArxivError::InvalidIdentifier(_) => (StatusCode::BAD_REQUEST, "INVALID_ARXIV_ID", false),
        _ => (StatusCode::SERVICE_UNAVAILABLE, "ARXIV_UNAVAILABLE", true),
    };
    ApiError::new(
        request_id,
        status,
        code,
        "arXiv metadata is temporarily unavailable.",
        retryable,
    )
}

fn provider_error(request_id: RequestId, error_value: &ProviderError) -> ApiError {
    error!(
        request_id = %request_id.0,
        error = %error_value,
        "model provider request failed"
    );
    let (status, code, retryable) = match error_value {
        ProviderError::InvalidRequest(_) => {
            (StatusCode::BAD_REQUEST, "INVALID_MODEL_REQUEST", false)
        }
        ProviderError::StructuredOutput(_) | ProviderError::InvalidResponse(_) => {
            (StatusCode::BAD_GATEWAY, "MODEL_INVALID_RESPONSE", true)
        }
        _ => (StatusCode::SERVICE_UNAVAILABLE, "MODEL_UNAVAILABLE", true),
    };
    ApiError::new(
        request_id,
        status,
        code,
        "Paper chat is temporarily unavailable.",
        retryable,
    )
}

fn retrieval_error(request_id: RequestId, error_value: &retrieval::RetrievalError) -> ApiError {
    error!(
        request_id = %request_id.0,
        error = %error_value,
        "paper retrieval failed"
    );
    ApiError::new(
        request_id,
        StatusCode::INTERNAL_SERVER_ERROR,
        "RETRIEVAL_FAILED",
        "The indexed paper context could not be retrieved safely.",
        true,
    )
}

fn reciprocal_rank_score(rank: usize) -> f32 {
    let bounded_rank = u16::try_from(rank.max(1)).unwrap_or(u16::MAX);
    1.0 / f32::from(bounded_rank)
}

fn capability_not_ready(
    request_id: RequestId,
    message: &str,
    processing: &ProcessingState,
) -> ApiError {
    if matches!(processing.stage, domain::ProcessingStage::FailedTerminal) {
        ApiError::new(
            request_id,
            StatusCode::UNPROCESSABLE_ENTITY,
            "CAPABILITY_UNAVAILABLE",
            processing
                .last_error
                .as_ref()
                .map_or(message, |error| error.message.as_str()),
            false,
        )
    } else {
        ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "CAPABILITY_NOT_READY",
            message,
            true,
        )
    }
}

fn valid_category(category: &str) -> bool {
    let Some((archive, subject)) = category.split_once('.') else {
        return false;
    };
    !archive.is_empty()
        && !subject.is_empty()
        && category.len() <= 32
        && archive
            .chars()
            .all(|character| character.is_ascii_lowercase())
        && subject
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '-')
}

fn client_keys(headers: &HeaderMap, remote: Option<&ConnectInfo<SocketAddr>>) -> Vec<String> {
    let mut keys = vec![remote.map_or_else(
        || "ip:unknown".to_owned(),
        |remote| format!("ip:{}", remote.0.ip()),
    )];
    if let Some(session) = headers
        .get(&SESSION_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
    {
        keys.push(format!("session:{session}"));
    }
    // Forwarded headers are deliberately ignored. Trusting them without an
    // explicit trusted-proxy boundary would let clients rotate their rate key.
    keys
}

#[derive(Debug, Clone, Default)]
struct RateLimiter {
    buckets: Arc<Mutex<HashMap<(String, String), WindowBucket>>>,
}

#[derive(Debug, Clone, Copy)]
struct WindowBucket {
    started: Instant,
    count: u32,
}

#[derive(Debug, Clone, Copy)]
struct RateLimited;

impl RateLimiter {
    async fn check_all(
        &self,
        action: &str,
        keys: Vec<String>,
        limit: u32,
        window: Duration,
    ) -> Result<(), RateLimited> {
        for key in keys {
            self.check(action, key, limit, window).await?;
        }
        Ok(())
    }

    async fn check(
        &self,
        action: &str,
        key: String,
        limit: u32,
        window: Duration,
    ) -> Result<(), RateLimited> {
        let now = Instant::now();
        let mut buckets = self.buckets.lock().await;
        if buckets.len() > 10_000 {
            buckets.retain(|_, bucket| now.duration_since(bucket.started) < window);
        }
        let bucket = buckets
            .entry((action.to_owned(), key))
            .or_insert(WindowBucket {
                started: now,
                count: 0,
            });
        if now.duration_since(bucket.started) >= window {
            *bucket = WindowBucket {
                started: now,
                count: 0,
            };
        }
        if bucket.count >= limit {
            return Err(RateLimited);
        }
        bucket.count += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request as HttpRequest};
    use chrono::{TimeDelta, Utc};
    use domain::{
        ArxivIdentifier, Author, IntroductionDetection, PaperMetadata, ParsedPaper,
        ParsedParagraph, ParsedSection, SectionKind,
    };
    use tower::ServiceExt as _;

    #[test]
    fn category_validation_is_conservative() {
        assert!(valid_category("cs.AI"));
        assert!(valid_category("stat.ML"));
        assert!(!valid_category("cs"));
        assert!(!valid_category("cs.AI OR *:*"));
    }

    #[test]
    fn chat_validation_counts_unicode_characters() {
        let request_id = RequestId(Uuid::nil());
        let session = Uuid::new_v4();
        let mut headers = HeaderMap::new();
        headers.insert(SESSION_ID_HEADER, session.to_string().parse().unwrap());
        let valid = ChatBody {
            thread_id: None,
            message: "安全ですか？".repeat(50),
        };
        assert_eq!(
            validate_chat_body(request_id, &headers, Uuid::nil(), &valid).unwrap(),
            session
        );
        let too_long = ChatBody {
            thread_id: None,
            message: "問".repeat(501),
        };
        assert_eq!(
            validate_chat_body(request_id, &headers, Uuid::nil(), &too_long)
                .unwrap_err()
                .status,
            StatusCode::PAYLOAD_TOO_LARGE
        );
    }

    #[test]
    fn strict_policy_masks_cached_capabilities_and_ready_processing() {
        let now = Utc::now();
        let mut summary = PaperSummary {
            paper_id: Uuid::new_v4(),
            arxiv_id: "2401.12345v1".to_owned(),
            title: "Cached prototype paper".to_owned(),
            abstract_text: "Metadata remains readable.".to_owned(),
            authors: vec!["Ada Tester".to_owned()],
            primary_category: "cs.AI".to_owned(),
            categories: vec!["cs.AI".to_owned()],
            published_at: now,
            updated_at: now,
            abs_url: Url::parse("https://arxiv.org/abs/2401.12345v1").unwrap(),
            pdf_url: Url::parse("https://arxiv.org/pdf/2401.12345v1").unwrap(),
            capabilities: Capabilities {
                metadata: true,
                introduction: true,
                chat: true,
                connections: true,
            },
        };
        let mut processing = ProcessingState {
            paper_id: summary.paper_id,
            generation: 1,
            overall_state: OverallProcessingState::Ready,
            stage: ProcessingStage::Ready,
            capabilities: summary.capabilities,
            retryable: false,
            last_error: None,
            started_at: Some(now),
            updated_at: now,
            completed_at: Some(now),
            parser_version: Some("prototype-parser".to_owned()),
            embedding_model: Some("prototype-embedding".to_owned()),
            summary_model: Some("prototype-summary".to_owned()),
        };

        apply_summary_policy(FulltextPolicy::Strict, None, &mut summary);
        apply_processing_policy(FulltextPolicy::Strict, None, &mut processing);

        assert_eq!(summary.capabilities, Capabilities::metadata_only());
        assert_eq!(processing.capabilities, Capabilities::metadata_only());
        assert_eq!(processing.stage, ProcessingStage::FailedTerminal);
        assert_eq!(
            processing
                .last_error
                .as_ref()
                .map(|error| error.code.as_str()),
            Some("FULLTEXT_POLICY_DENIED")
        );
        assert!(processing.parser_version.is_none());
        assert!(processing.embedding_model.is_none());
        assert!(processing.summary_model.is_none());
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn strict_restart_denies_persisted_prototype_artifacts_at_every_route() {
        let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
            eprintln!("TEST_DATABASE_URL is absent; skipped strict API policy coverage");
            return;
        };
        let database = Database::connect(&database_url, 6).await.unwrap();
        database.migrate_embedded().await.unwrap();
        database.ready().await.unwrap();
        let repository = database.papers();
        let unique = Uuid::now_v7().simple().to_string();
        let now = Utc::now();
        let paper = repository
            .upsert_metadata(&PaperMetadata {
                arxiv_id: ArxivIdentifier {
                    base_id: format!("test.policy.{unique}"),
                    version: 1,
                },
                title: "Prototype Artifact Policy Regression".to_owned(),
                abstract_text: "This metadata must remain available in strict mode.".to_owned(),
                authors: vec![Author {
                    name: "Ada Policy".to_owned(),
                }],
                primary_category: "cs.P0".to_owned(),
                categories: vec!["cs.P0".to_owned()],
                published_at: now - TimeDelta::days(1),
                updated_at: now,
                abs_url: Url::parse("https://arxiv.org/abs/2401.00001v1").unwrap(),
                pdf_url: Url::parse("https://arxiv.org/pdf/2401.00001v1").unwrap(),
                doi: None,
                journal_reference: None,
                comment: None,
                license_uri: None,
                metadata_fetched_at: now,
            })
            .await
            .unwrap();
        repository
            .persist_parsed_document(
                paper.id,
                1,
                &ParsedPaper {
                    title: Some("Prototype Artifact Policy Regression".to_owned()),
                    sections: vec![ParsedSection {
                        source_id: "introduction".to_owned(),
                        ordinal: 0,
                        parent_source_id: None,
                        kind: SectionKind::Introduction,
                        heading: Some("1 Introduction".to_owned()),
                        paragraphs: vec![ParsedParagraph {
                            ordinal: 0,
                            text: "A prototype-derived paragraph that strict mode must not serve."
                                .to_owned(),
                            citations: Vec::new(),
                            page_start: Some(1),
                            page_end: Some(1),
                        }],
                        page_start: Some(1),
                        page_end: Some(1),
                    }],
                    references: Vec::new(),
                    citation_contexts: Vec::new(),
                },
                &["introduction".to_owned()],
                IntroductionDetection {
                    confidence: 0.99,
                    used_fallback: false,
                },
                "prototype-parser",
            )
            .await
            .unwrap();
        assert!(repository.introduction(paper.id).await.unwrap().is_some());

        let strict_config = test_api_config(&database_url, FulltextPolicy::Strict);
        let strict_app = build_router(
            AppState::new(database.clone(), &strict_config).unwrap(),
            &strict_config,
        );

        for path in [
            format!("/v1/papers/{}/introduction", paper.id),
            format!("/v1/papers/{}/connections", paper.id),
        ] {
            let response = strict_app
                .clone()
                .oneshot(
                    HttpRequest::builder()
                        .uri(path)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::FORBIDDEN);
            let body = response_json(response).await;
            assert_eq!(body["error"]["code"], "FULLTEXT_POLICY_DENIED");
            assert_eq!(body["error"]["retryable"], false);
        }

        let session_id = Uuid::new_v4();
        let mut chat_request = HttpRequest::builder()
            .method(Method::POST)
            .uri(format!("/v1/papers/{}/chat", paper.id))
            .header(CONTENT_TYPE, "application/json")
            .header(SESSION_ID_HEADER, session_id.to_string())
            .body(Body::from(r#"{"thread_id":null,"message":"What is new?"}"#))
            .unwrap();
        chat_request
            .extensions_mut()
            .insert(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 30_001))));
        let response = strict_app.clone().oneshot(chat_request).await.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "FULLTEXT_POLICY_DENIED"
        );

        let response = strict_app
            .clone()
            .oneshot(
                HttpRequest::builder()
                    .uri(format!("/v1/papers/{}", paper.id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let metadata = response_json(response).await;
        assert_eq!(
            metadata["abstract"],
            "This metadata must remain available in strict mode."
        );
        assert_eq!(metadata["abs_url"], "https://arxiv.org/abs/2401.00001v1");
        assert_eq!(metadata["capabilities"]["introduction"], false);
        assert_eq!(metadata["capabilities"]["chat"], false);
        assert_eq!(metadata["capabilities"]["connections"], false);

        let response = strict_app
            .clone()
            .oneshot(
                HttpRequest::builder()
                    .uri(format!("/v1/papers/{}/processing", paper.id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let processing = response_json(response).await;
        assert_eq!(processing["stage"], "failed_terminal");
        assert_eq!(processing["last_error"]["code"], "FULLTEXT_POLICY_DENIED");
        assert_eq!(processing["capabilities"]["introduction"], false);

        let response = strict_app
            .clone()
            .oneshot(
                HttpRequest::builder()
                    .uri("/v1/feed?category=cs.P0&limit=100")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let feed = response_json(response).await;
        let item = feed["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["paper_id"] == paper.id.to_string())
            .expect("seeded policy paper must appear in its category feed");
        assert_eq!(item["capabilities"]["introduction"], false);
        assert_eq!(item["capabilities"]["chat"], false);
        assert_eq!(item["capabilities"]["connections"], false);

        let prototype_config = test_api_config(&database_url, FulltextPolicy::Prototype);
        let prototype_app = build_router(
            AppState::new(database, &prototype_config).unwrap(),
            &prototype_config,
        );
        let response = prototype_app
            .oneshot(
                HttpRequest::builder()
                    .uri(format!("/v1/papers/{}/introduction", paper.id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response_json(response).await["paragraphs"][0]["text"],
            "A prototype-derived paragraph that strict mode must not serve."
        );
    }

    fn test_api_config(database_url: &str, fulltext_policy: FulltextPolicy) -> ApiConfig {
        let arxiv = ArxivClientConfig {
            user_agent: "PakperkPolicyTest/0.1".to_owned(),
            contact_email: "engineering@pakperk.org".to_owned(),
            ..ArxivClientConfig::default()
        };
        ApiConfig {
            bind: SocketAddr::from(([127, 0, 0, 1], 0)),
            database_url: database_url.to_owned(),
            database_pool_size: 6,
            run_migrations: false,
            request_timeout: Duration::from_secs(5),
            chat_request_timeout: Duration::from_secs(5),
            max_request_bytes: 64 * 1024,
            cors_allowed_origins: Vec::new(),
            arxiv,
            arxiv_cache_ttl: Duration::from_secs(60),
            fulltext_policy,
            embedding_dimension: Some(8),
            llm: Some(ApiModelConfig::Deterministic {
                embedding_dimension: 8,
            }),
            prepare_requests_per_minute: 10,
            chat_requests_per_minute: 10,
        }
    }

    async fn response_json(response: Response) -> serde_json::Value {
        let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[tokio::test]
    async fn fixed_window_limiter_rejects_excess() {
        let limiter = RateLimiter::default();
        assert!(
            limiter
                .check("chat", "session".to_owned(), 2, Duration::from_secs(60))
                .await
                .is_ok()
        );
        assert!(
            limiter
                .check("chat", "session".to_owned(), 2, Duration::from_secs(60))
                .await
                .is_ok()
        );
        assert!(
            limiter
                .check("chat", "session".to_owned(), 2, Duration::from_secs(60))
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn rotating_session_ids_cannot_bypass_ip_bucket() {
        let limiter = RateLimiter::default();
        let remote = ConnectInfo(SocketAddr::from(([203, 0, 113, 10], 1234)));
        let mut first = HeaderMap::new();
        first.insert(
            SESSION_ID_HEADER,
            Uuid::new_v4().to_string().parse().unwrap(),
        );
        let mut second = HeaderMap::new();
        second.insert(
            SESSION_ID_HEADER,
            Uuid::new_v4().to_string().parse().unwrap(),
        );
        assert!(
            limiter
                .check_all(
                    "prepare",
                    client_keys(&first, Some(&remote)),
                    1,
                    Duration::from_secs(60),
                )
                .await
                .is_ok()
        );
        assert!(
            limiter
                .check_all(
                    "prepare",
                    client_keys(&second, Some(&remote)),
                    1,
                    Duration::from_secs(60),
                )
                .await
                .is_err()
        );
    }

    #[test]
    fn untrusted_forwarded_headers_never_change_rate_limit_identity() {
        let remote = ConnectInfo(SocketAddr::from(([198, 51, 100, 8], 4321)));
        let mut first = HeaderMap::new();
        first.insert("x-forwarded-for", "203.0.113.1".parse().unwrap());
        first.insert("forwarded", "for=203.0.113.2".parse().unwrap());
        let mut second = HeaderMap::new();
        second.insert("x-forwarded-for", "192.0.2.55".parse().unwrap());
        second.insert("forwarded", "for=192.0.2.56".parse().unwrap());
        assert_eq!(
            client_keys(&first, Some(&remote)),
            client_keys(&second, Some(&remote))
        );
        assert_eq!(client_keys(&first, Some(&remote)), ["ip:198.51.100.8"]);
    }

    #[test]
    fn arxiv_internal_retries_cannot_bypass_database_gate() {
        let mut config = ArxivClientConfig {
            max_retries: 9,
            ..ArxivClientConfig::default()
        };
        enforce_cross_process_arxiv_gate(&mut config);
        assert_eq!(config.max_retries, 0);
    }

    #[tokio::test]
    async fn extractor_rejections_use_stable_error_envelope() {
        async fn json_only(Json(_body): Json<serde_json::Value>) -> StatusCode {
            StatusCode::NO_CONTENT
        }
        let app = Router::new()
            .route("/json", post(json_only))
            .layer(DefaultBodyLimit::max(8))
            .layer(middleware::from_fn(stable_error_middleware))
            .layer(middleware::from_fn(request_id_middleware));
        let response = app
            .oneshot(
                HttpRequest::post("/json")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"far":"too long"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert!(response.headers().contains_key(REQUEST_ID_HEADER));
        let bytes = axum::body::to_bytes(response.into_body(), 1024)
            .await
            .unwrap();
        let envelope: ApiErrorEnvelope = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(envelope.error.code, "REQUEST_BODY_TOO_LARGE");
    }
}
