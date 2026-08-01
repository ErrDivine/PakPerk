//! Application state and router assembly.

use std::{sync::Arc, time::Duration};

use account_deletion::{AccountDeletionService, FileExternalDeletionLedger};
use accounts::AccountService;
use arxiv_client::ArxivClient;
use auth::{AuthRuntime, AuthUnavailableReason};
use axum::{
    Router,
    extract::DefaultBodyLimit,
    http::{
        HeaderName, HeaderValue, Method,
        header::{AUTHORIZATION, CONTENT_TYPE, ETAG, IF_MATCH, IF_NONE_MATCH, RETRY_AFTER},
    },
    middleware,
    routing::{get, post, put},
};
use comments::CommentService;
use db::{Database, PaperRepository};
use domain::FulltextPolicy;
use http_policy::strict_transport_security;
use library::{LibraryPolicy, LibraryService};
use llm_provider::{
    ChatProvider, DeterministicProvider, EmbeddingProvider, OpenAiCompatibleProvider,
};
use moderation::{ContentModerator, HttpModerationAdapter, ModerationPipeline};
use tower_http::{
    compression::CompressionLayer,
    cors::{AllowOrigin, CorsLayer},
};

use crate::{
    config::{ApiConfig, ApiModelConfig, CommentModerationProvider, FeatureFlags},
    middleware::{
        REQUEST_ID_HEADER, SESSION_ID_HEADER, TimeoutConfig, request_id_middleware,
        stable_error_middleware, telemetry_middleware, timeout_middleware,
    },
    openapi::openapi_json,
    request_rate_limit::PublicRequestRateLimiter,
    routes::support::not_found,
    routes::{
        block_user, chat, connections, create_comment, delete_comment, delete_me, edit_comment,
        feed, get_me, health_live, health_ready, introduction, library_changes, list_blocked_users,
        list_library, list_my_comments, list_paper_comments, paper_by_arxiv, paper_metadata,
        patch_me, prepare, private_account_cache_control, processing, remove_library_item,
        report_comment, report_user, save_library_item, unblock_user, verify_deletion_identity,
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
    pub(crate) request_limiter: PublicRequestRateLimiter,
    pub(crate) accounts: Option<AccountService>,
    pub(crate) account_deletion: Option<AccountDeletionService>,
    pub(crate) library: Option<LibraryService>,
    pub(crate) comments: Option<CommentService>,
    pub(crate) auth: AuthRuntime,
    feature_flags: FeatureFlags,
}

impl AppState {
    /// Compatibility constructor for guest-only tests and embedders. When
    /// accounts are enabled it installs a fail-closed unavailable runtime;
    /// production startup should perform bounded discovery and call
    /// [`Self::new_with_auth`].
    pub fn new(database: Database, config: &ApiConfig) -> anyhow::Result<Self> {
        let auth = config
            .accounts
            .as_ref()
            .map_or_else(AuthRuntime::disabled, |account| {
                AuthRuntime::unavailable(
                    AuthUnavailableReason::ProviderUnavailable,
                    account.auth_retry_initial,
                )
            });
        Self::new_with_auth(database, config, auth)
    }

    pub fn new_with_auth(
        database: Database,
        config: &ApiConfig,
        auth: AuthRuntime,
    ) -> anyhow::Result<Self> {
        validate_composition(config, &auth)?;
        let papers = database.papers();
        let mut arxiv_config = config.arxiv.clone();
        crate::config::enforce_cross_process_arxiv_gate(&mut arxiv_config);
        let model_provider = build_model_provider(config.llm.clone())?;
        let services = build_application_services(&database, config)?;
        let request_limiter = PublicRequestRateLimiter::new(
            database.rate_limits(),
            config.request_origin.clone(),
            config.prepare_requests_per_minute,
            config.chat_requests_per_minute,
        )?;
        Ok(Self {
            database,
            papers,
            arxiv: ArxivClient::new_with_external_gate(arxiv_config)?,
            arxiv_minimum_interval: config.arxiv.minimum_interval,
            arxiv_cache_ttl: config.arxiv_cache_ttl,
            fulltext_policy: config.fulltext_policy,
            model_provider,
            request_limiter,
            accounts: services.accounts,
            account_deletion: services.account_deletion,
            library: services.library,
            comments: services.comments,
            auth,
            feature_flags: config.features,
        })
    }

    /// Feature gates retained with application state for route/service
    /// assembly in later production phases.
    pub const fn feature_flags(&self) -> FeatureFlags {
        self.feature_flags
    }

    /// Cloneable maintenance handle without exposing persistence internals.
    pub fn library_service(&self) -> Option<LibraryService> {
        self.library.clone()
    }
}

fn validate_composition(config: &ApiConfig, auth: &AuthRuntime) -> anyhow::Result<()> {
    config.features.validate()?;
    if config.features.accounts != config.accounts.is_some()
        || config.features.accounts != auth.is_enabled()
        || config.features.library != config.library.is_some()
        || config.features.comments != config.comments.is_some()
        || config.features.account_deletion != config.account_deletion.is_some()
    {
        anyhow::bail!("feature configuration and authentication runtime are inconsistent");
    }
    Ok(())
}

fn build_model_provider(
    config: Option<ApiModelConfig>,
) -> anyhow::Result<Option<Arc<dyn ApiModelProvider>>> {
    match config {
        Some(ApiModelConfig::Deterministic {
            embedding_dimension,
        }) => Ok(Some(Arc::new(DeterministicProvider::new(
            embedding_dimension,
        )?))),
        Some(ApiModelConfig::OpenAiCompatible(config)) => {
            Ok(Some(Arc::new(OpenAiCompatibleProvider::new(*config)?)))
        }
        None => Ok(None),
    }
}

struct ApplicationServices {
    accounts: Option<AccountService>,
    account_deletion: Option<AccountDeletionService>,
    library: Option<LibraryService>,
    comments: Option<CommentService>,
}

fn build_application_services(
    database: &Database,
    config: &ApiConfig,
) -> anyhow::Result<ApplicationServices> {
    let accounts = config
        .accounts
        .as_ref()
        .map(|account| {
            let service = AccountService::new(
                database.accounts(),
                database.rate_limits(),
                account.account_policy()?,
            );
            Ok::<_, anyhow::Error>(
                account
                    .identity_fingerprints
                    .clone()
                    .map_or(service.clone(), |keyring| {
                        service.with_identity_fingerprints(keyring)
                    }),
            )
        })
        .transpose()?;
    let account_deletion = config
        .account_deletion
        .as_ref()
        .map(|deletion| {
            let external = FileExternalDeletionLedger::new(
                deletion.external_ledger_directory.clone(),
                deletion.signer.clone(),
            )?;
            AccountDeletionService::new(
                database.account_deletions(),
                deletion.identity_fingerprints.clone(),
                Arc::new(external),
                deletion.signer.clone(),
                deletion.provider_identity_cipher.clone(),
                deletion.policy.clone(),
            )
            .map_err(anyhow::Error::from)
        })
        .transpose()?;
    let library = config
        .library
        .map(|library| {
            Ok::<_, anyhow::Error>(LibraryService::new(
                database.library(),
                database.rate_limits(),
                LibraryPolicy::new(library.mutation_limit, library.mutation_window)?,
            ))
        })
        .transpose()?;
    let comments = config
        .comments
        .as_ref()
        .zip(config.accounts.as_ref())
        .map(|(comment, account)| {
            let adapter: Option<Arc<dyn ContentModerator>> = match comment.moderation_provider() {
                CommentModerationProvider::Rules => None,
                CommentModerationProvider::Http => Some(Arc::new(HttpModerationAdapter::new(
                    comment.moderation_http().cloned().ok_or_else(|| {
                        anyhow::anyhow!("HTTP moderation configuration is missing")
                    })?,
                )?)),
            };
            let moderator: Arc<dyn ContentModerator> = Arc::new(ModerationPipeline::new(adapter));
            Ok::<_, anyhow::Error>(CommentService::new(
                database.comments(),
                database.rate_limits(),
                moderator,
                comment.service_config(account, config.environment)?,
            ))
        })
        .transpose()?;
    Ok(ApplicationServices {
        accounts,
        account_deletion,
        library,
        comments,
    })
}

pub fn build_router(state: AppState, config: &ApiConfig) -> Router {
    debug_assert_eq!(state.feature_flags(), config.features);
    let cors = feed_aware_cors(&config.cors_allowed_origins);

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
    let router = if config.features.accounts {
        let route = get(get_me).patch(patch_me);
        if config.features.account_deletion {
            router.route("/v1/me", route.delete(delete_me)).route(
                "/v1/me/deletion-verification",
                get(verify_deletion_identity),
            )
        } else {
            router.route("/v1/me", route)
        }
    } else {
        router
    };
    let router = if config.features.accounts && config.features.library {
        router
            .route("/v1/me/library", get(list_library))
            .route("/v1/me/library/changes", get(library_changes))
            .route(
                "/v1/me/library/{paper_id}",
                put(save_library_item).delete(remove_library_item),
            )
    } else {
        router
    };
    let router = if config.features.accounts && config.features.comments {
        router
            .route(
                "/v1/papers/{paper_id}/comments",
                get(list_paper_comments).post(create_comment),
            )
            .route(
                "/v1/comments/{comment_id}",
                axum::routing::patch(edit_comment).delete(delete_comment),
            )
            .route("/v1/comments/{comment_id}/reports", post(report_comment))
            .route("/v1/users/{user_id}/reports", post(report_user))
            .route(
                "/v1/me/blocked-users/{user_id}",
                put(block_user).delete(unblock_user),
            )
            .route("/v1/me/blocked-users", get(list_blocked_users))
            .route("/v1/me/comments", get(list_my_comments))
    } else {
        router
    };
    let router = if config.environment.exposes_openapi() {
        router.route("/openapi.json", get(openapi_json))
    } else {
        router
    };
    router
        .fallback(not_found)
        .with_state(state)
        .layer(DefaultBodyLimit::max(config.max_request_bytes))
        // Production edges may recompress, but the origin still guarantees
        // Brotli/gzip negotiation for deployments that expose it directly.
        .layer(CompressionLayer::new())
        .layer(cors)
        .layer(middleware::from_fn_with_state(
            TimeoutConfig {
                default: config.request_timeout,
                chat: config.chat_request_timeout,
            },
            timeout_middleware,
        ))
        .layer(middleware::from_fn(stable_error_middleware))
        // Telemetry must wrap every response synthesizer so cancelled inner
        // futures still produce one status/latency observation.
        .layer(middleware::from_fn(telemetry_middleware))
        .layer(middleware::from_fn(request_id_middleware))
        .layer(middleware::from_fn(private_account_cache_control))
        // The TLS edge emits the same closed policy. Keep an origin guarantee
        // as defense in depth and cover direct-origin/error responses too.
        .layer(middleware::from_fn(strict_transport_security))
}

fn feed_aware_cors(allowed_origins: &[HeaderValue]) -> CorsLayer {
    if allowed_origins.is_empty() {
        CorsLayer::new()
    } else {
        CorsLayer::new()
            .allow_origin(AllowOrigin::list(allowed_origins.iter().cloned()))
            .allow_methods([
                Method::GET,
                Method::POST,
                Method::PUT,
                Method::PATCH,
                Method::DELETE,
                Method::OPTIONS,
            ])
            .allow_headers([
                AUTHORIZATION,
                CONTENT_TYPE,
                SESSION_ID_HEADER,
                REQUEST_ID_HEADER,
                HeaderName::from_static("idempotency-key"),
                IF_MATCH,
                IF_NONE_MATCH,
            ])
            .expose_headers([REQUEST_ID_HEADER, ETAG, RETRY_AFTER])
    }
}

#[cfg(test)]
fn production_feature_routes(features: FeatureFlags) -> Vec<&'static str> {
    let mut routes = Vec::new();
    if features.accounts {
        routes.push("/v1/me");
    }
    if features.accounts && features.library {
        routes.extend([
            "/v1/me/library",
            "/v1/me/library/changes",
            "/v1/me/library/{paper_id}",
        ]);
    }
    if features.accounts && features.comments {
        routes.extend([
            "/v1/papers/{paper_id}/comments",
            "/v1/comments/{comment_id}",
            "/v1/comments/{comment_id}/reports",
            "/v1/users/{user_id}/reports",
            "/v1/me/blocked-users/{user_id}",
            "/v1/me/blocked-users",
            "/v1/me/comments",
        ]);
    }
    routes
}

#[cfg(test)]
mod tests {
    use axum::{
        body::Body,
        http::{
            Request,
            header::{
                ACCEPT_ENCODING, ACCESS_CONTROL_ALLOW_HEADERS, ACCESS_CONTROL_ALLOW_METHODS,
                ACCESS_CONTROL_EXPOSE_HEADERS, ACCESS_CONTROL_REQUEST_HEADERS,
                ACCESS_CONTROL_REQUEST_METHOD, CONTENT_ENCODING, ORIGIN, VARY,
            },
        },
    };
    use tower::ServiceExt as _;

    use super::*;

    #[test]
    fn feature_flags_do_not_publish_incomplete_routes() {
        let all_enabled = FeatureFlags {
            accounts: true,
            library: true,
            library_writes: true,
            comments: true,
            comment_creation: true,
            account_deletion: true,
        };
        assert_eq!(
            production_feature_routes(all_enabled),
            vec![
                "/v1/me",
                "/v1/me/library",
                "/v1/me/library/changes",
                "/v1/me/library/{paper_id}",
                "/v1/papers/{paper_id}/comments",
                "/v1/comments/{comment_id}",
                "/v1/comments/{comment_id}/reports",
                "/v1/users/{user_id}/reports",
                "/v1/me/blocked-users/{user_id}",
                "/v1/me/blocked-users",
                "/v1/me/comments",
            ]
        );
        assert_eq!(
            production_feature_routes(FeatureFlags {
                accounts: true,
                library: false,
                library_writes: false,
                comments: false,
                comment_creation: false,
                account_deletion: false,
            }),
            vec!["/v1/me"]
        );
        let mut comments_read_only = all_enabled;
        comments_read_only.comment_creation = false;
        assert_eq!(
            production_feature_routes(comments_read_only),
            production_feature_routes(all_enabled),
            "the creation kill switch must not unregister reads or safety routes"
        );
    }

    #[tokio::test]
    async fn cors_allows_feed_revalidation_and_exposes_the_validator() {
        let origin = HeaderValue::from_static("https://app.pakperk.org");
        let app = Router::new()
            .route(
                "/v1/feed",
                get(|| async {
                    (
                        [
                            (ETAG, HeaderValue::from_static("\"opaque-validator\"")),
                            (RETRY_AFTER, HeaderValue::from_static("10")),
                        ],
                        "{}",
                    )
                }),
            )
            .layer(feed_aware_cors(std::slice::from_ref(&origin)));

        let preflight = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::OPTIONS)
                    .uri("/v1/feed")
                    .header(ORIGIN, origin.clone())
                    .header(ACCESS_CONTROL_REQUEST_METHOD, "PATCH")
                    .header(
                        ACCESS_CONTROL_REQUEST_HEADERS,
                        "Authorization, Content-Type, X-Session-Id, X-Request-Id, Idempotency-Key, If-Match, If-None-Match",
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(preflight.status(), axum::http::StatusCode::OK);
        let allowed_headers = preflight.headers()[ACCESS_CONTROL_ALLOW_HEADERS]
            .to_str()
            .unwrap();
        for expected in [
            "authorization",
            "content-type",
            "x-session-id",
            "x-request-id",
            "idempotency-key",
            "if-match",
            "if-none-match",
        ] {
            assert!(
                allowed_headers
                    .split(',')
                    .any(|header| header.trim().eq_ignore_ascii_case(expected))
            );
        }
        let allowed_methods = preflight.headers()[ACCESS_CONTROL_ALLOW_METHODS]
            .to_str()
            .unwrap();
        for expected in ["patch", "put", "delete"] {
            assert!(
                allowed_methods
                    .split(',')
                    .any(|method| method.trim().eq_ignore_ascii_case(expected)),
                "CORS must permit {expected}"
            );
        }

        let response = app
            .oneshot(
                Request::get("/v1/feed")
                    .header(ORIGIN, origin)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert!(response.headers().contains_key(ETAG));
        let exposed = response.headers()[ACCESS_CONTROL_EXPOSE_HEADERS]
            .to_str()
            .unwrap();
        for expected in ["x-request-id", "etag", "retry-after"] {
            assert!(
                exposed
                    .split(',')
                    .any(|header| header.trim().eq_ignore_ascii_case(expected))
            );
        }
    }

    #[tokio::test]
    async fn origin_negotiates_compression_for_large_public_responses() {
        let app = Router::new()
            .route("/v1/feed", get(|| async { "paper metadata ".repeat(256) }))
            .layer(CompressionLayer::new());

        let response = app
            .oneshot(
                Request::get("/v1/feed")
                    .header(ACCEPT_ENCODING, "br, gzip")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.headers()[CONTENT_ENCODING], "br");
        assert!(
            response.headers()[VARY]
                .to_str()
                .unwrap()
                .split(',')
                .any(|value| value.trim().eq_ignore_ascii_case("accept-encoding"))
        );
    }
}
