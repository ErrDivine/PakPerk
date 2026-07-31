//! Application state and router assembly.

use std::{sync::Arc, time::Duration};

use arxiv_client::ArxivClient;
use axum::{
    Router,
    extract::DefaultBodyLimit,
    http::{Method, header::CONTENT_TYPE},
    middleware,
    routing::{get, post},
};
use db::{Database, PaperRepository};
use domain::FulltextPolicy;
use llm_provider::{
    ChatProvider, DeterministicProvider, EmbeddingProvider, OpenAiCompatibleProvider,
};
use tower_http::{
    cors::{AllowOrigin, CorsLayer},
    trace::{DefaultMakeSpan, DefaultOnResponse, TraceLayer},
};
use tracing::Level;

use crate::{
    config::{ApiConfig, ApiModelConfig, FeatureFlags},
    middleware::{
        REQUEST_ID_HEADER, RateLimiter, SESSION_ID_HEADER, TimeoutConfig, request_id_middleware,
        stable_error_middleware, timeout_middleware,
    },
    openapi::openapi_json,
    routes::support::not_found,
    routes::{
        chat, connections, feed, health_live, health_ready, introduction, paper_by_arxiv,
        paper_metadata, prepare, processing,
    },
};

pub(crate) trait ApiModelProvider: ChatProvider + EmbeddingProvider {}

impl<T> ApiModelProvider for T where T: ChatProvider + EmbeddingProvider {}

#[derive(Clone)]
pub struct AppState {
    pub(crate) database: Database,
    pub(crate) papers: PaperRepository,
    pub(crate) arxiv: ArxivClient,
    pub(crate) arxiv_minimum_interval: Duration,
    pub(crate) arxiv_cache_ttl: Duration,
    pub(crate) fulltext_policy: FulltextPolicy,
    pub(crate) model_provider: Option<Arc<dyn ApiModelProvider>>,
    pub(crate) limiter: RateLimiter,
    pub(crate) prepare_limit: u32,
    pub(crate) chat_limit: u32,
    feature_flags: FeatureFlags,
}

impl AppState {
    pub fn new(database: Database, config: &ApiConfig) -> anyhow::Result<Self> {
        let papers = database.papers();
        let mut arxiv_config = config.arxiv.clone();
        crate::config::enforce_cross_process_arxiv_gate(&mut arxiv_config);
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
            feature_flags: config.features,
        })
    }

    /// Feature gates retained with application state for route/service
    /// assembly in later production phases.
    pub const fn feature_flags(&self) -> FeatureFlags {
        self.feature_flags
    }
}

pub fn build_router(state: AppState, config: &ApiConfig) -> Router {
    debug_assert_eq!(state.feature_flags(), config.features);
    let cors = if config.cors_allowed_origins.is_empty() {
        CorsLayer::new()
    } else {
        CorsLayer::new()
            .allow_origin(AllowOrigin::list(config.cors_allowed_origins.clone()))
            .allow_methods([Method::GET, Method::POST])
            .allow_headers([CONTENT_TYPE, SESSION_ID_HEADER, REQUEST_ID_HEADER])
    };

    let router = Router::new()
        .route("/health/live", get(health_live))
        .route("/health/ready", get(health_ready))
        .route("/v1/feed", get(feed))
        .route("/v1/papers/{paper_id}", get(paper_metadata))
        .route("/v1/papers/by-arxiv/{*arxiv_id}", get(paper_by_arxiv))
        .route("/v1/papers/{paper_id}/prepare", post(prepare))
        .route("/v1/papers/{paper_id}/processing", get(processing))
        .route("/v1/papers/{paper_id}/introduction", get(introduction))
        .route("/v1/papers/{paper_id}/chat", post(chat))
        .route("/v1/papers/{paper_id}/connections", get(connections));
    // Phase 0 deliberately registers no account-owned routes. Later phases
    // consume this manifest so a feature cannot bypass server-side gating.
    debug_assert!(production_feature_routes(config.features).is_empty());
    let router = if config.environment.exposes_openapi() {
        router.route("/openapi.json", get(openapi_json))
    } else {
        router
    };
    router
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

fn production_feature_routes(_features: FeatureFlags) -> &'static [&'static str] {
    &[]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feature_flags_do_not_publish_incomplete_routes() {
        let all_enabled = FeatureFlags {
            accounts: true,
            library: true,
            comments: true,
        };
        assert!(production_feature_routes(all_enabled).is_empty());
    }
}
