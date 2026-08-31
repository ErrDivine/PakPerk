//! Application state and router assembly.

use std::sync::Arc;

use ::reading_feed::{ReadingFeedService, RecommendationSource};
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
use db::{Database, DocumentRepository, EncryptedReadingFeedCursorCodec, PaperRepository};
use discovery_search::{DiscoverySearchPolicy, DiscoverySearchService};
use domain::FulltextPolicy;
use engagement::{EngagementPolicy, EngagementService};
use http_policy::strict_transport_security;
use library::{LibraryPolicy, LibraryService};
use llm_provider::{
    AssistantProvider, ChatProvider, DeterministicProvider, EmbeddingProvider,
    OpenAiCompatibleProvider,
};
use moderation::{ContentModerator, HttpModerationAdapter, ModerationPipeline};
use paper_resolution::{PaperImportService, PaperResolutionService};
use research_profiles::{ResearchProfilePolicy, ResearchProfileService};
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
    recommendation_source::BatchRecommendationSource,
    request_rate_limit::PublicRequestRateLimiter,
    routes::support::not_found,
    routes::{
        MAX_ANNOTATION_IMPORT_REQUEST_BYTES, assistant, assistant_feedback, assistant_provenance,
        block_user, chat, connections, create_comment, create_evidence_card, create_library_list,
        create_library_tag, create_memory_item, create_reading_brief, create_subscription,
        current_reading_brief, delete_annotation, delete_comment, delete_evidence_card,
        delete_library_item_tag, delete_library_list, delete_library_list_item, delete_library_tag,
        delete_library_v2_item, delete_me, delete_memory_item, delete_research_profile_author,
        delete_research_profile_topic, delete_saved_search, delete_subscription,
        dismiss_notification, document_blocks, document_outline, edit_comment, equations,
        explore_search, export_annotations, export_research_profile, feed, figure, figure_asset,
        figures, get_me, get_notification_preferences, get_recommendation_explanation,
        get_research_profile, get_research_profile_interests, health_cache_control, health_live,
        health_ready, import_annotations, import_library_paper, introduction, library_changes,
        library_v2_changes, list_annotation_conflicts, list_annotations, list_blocked_users,
        list_checkpoints, list_evidence_cards, list_library, list_library_lists, list_library_tags,
        list_library_v2_items, list_my_comments, list_notifications, list_paper_comments,
        list_saved_searches, list_subscriptions, lookup_search, mark_all_notifications_read,
        mark_notification_read, memory_review, paper_by_arxiv, paper_metadata, paper_version_diff,
        paper_versions, passport, passport_feedback, patch_library_v2_item, patch_me,
        post_interaction_batch, post_recommendation_feedback, prepare,
        private_account_cache_control, processing, put_annotation, put_checkpoint,
        put_evidence_card, put_library_item_tag, put_library_list_item, put_library_v2_item,
        put_memory_item, put_notification_preferences, reading_feed, reanchor_annotation,
        remove_library_item, report_comment, report_user, reset_research_profile,
        review_memory_item, save_library_item, save_search, search_papers, search_suggestions,
        semantic_spans, shared_provenance, table, tables, terms, unblock_user, update_library_list,
        update_library_tag, update_reading_brief_progress, update_research_profile,
        update_subscription, upsert_research_profile_author, upsert_research_profile_topic,
        verify_deletion_identity,
    },
    visual_assets::VisualAssetStore,
};

pub(crate) trait ApiModelProvider:
    AssistantProvider + ChatProvider + EmbeddingProvider
{
}

impl<T> ApiModelProvider for T where T: AssistantProvider + ChatProvider + EmbeddingProvider {}

#[derive(Clone)]
pub struct AppState {
    pub(crate) database: Database,
    pub(crate) papers: PaperRepository,
    pub(crate) documents: DocumentRepository,
    pub(crate) paper_resolution: PaperResolutionService,
    pub(crate) paper_import: Option<PaperImportService>,
    pub(crate) reading_feed: Option<ReadingFeedService>,
    recommendation_generation: Option<BatchRecommendationSource>,
    pub(crate) research_profiles: Option<ResearchProfileService>,
    pub(crate) discovery_search: Option<DiscoverySearchService>,
    pub(crate) engagement: Option<EngagementService>,
    pub(crate) cursor_key_epoch: [u8; 32],
    pub(crate) fulltext_policy: FulltextPolicy,
    pub(crate) model_provider: Option<Arc<dyn ApiModelProvider>>,
    pub(crate) request_limiter: PublicRequestRateLimiter,
    pub(crate) accounts: Option<AccountService>,
    pub(crate) account_deletion: Option<AccountDeletionService>,
    pub(crate) library: Option<LibraryService>,
    pub(crate) comments: Option<CommentService>,
    pub(crate) auth: AuthRuntime,
    pub(crate) visual_assets: Option<VisualAssetStore>,
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

    #[allow(clippy::too_many_lines)] // Explicit composition keeps every optional service auditable.
    pub fn new_with_auth(
        database: Database,
        config: &ApiConfig,
        auth: AuthRuntime,
    ) -> anyhow::Result<Self> {
        validate_composition(config, &auth)?;
        let cursor_key_epoch = config.cursors.active_key_epoch();
        let database = database.with_cursor_codec(config.cursors.codec());
        let papers = database.papers();
        let documents = database.documents();
        let mut arxiv_config = config.arxiv.clone();
        crate::config::enforce_cross_process_arxiv_gate(&mut arxiv_config);
        let arxiv = ArxivClient::new_with_external_gate(arxiv_config)?;
        let paper_resolution = PaperResolutionService::with_search(
            papers.clone(),
            arxiv,
            database.rate_limits(),
            config
                .paper_resolution
                .policy(config.arxiv.minimum_interval, config.arxiv_cache_ttl)?,
        );
        let model_provider = build_model_provider(config.llm.clone())?;
        let services = build_application_services(&database, config)?;
        let discovery_search = (config.features.search_lookup
            || config.features.search_explore
            || config.features.saved_queries)
            .then(|| {
                let repository = Arc::new(database.discovery_search());
                DiscoverySearchService::new(
                    repository.clone(),
                    repository,
                    DiscoverySearchPolicy::default(),
                )
            });
        let paper_import = if config.features.paper_resolution {
            services.library.clone().map(|library| {
                PaperImportService::new(
                    paper_resolution.clone(),
                    database.paper_imports(),
                    library,
                    database.rate_limits(),
                    config.paper_resolution.import_account_limit_per_minute,
                )
            })
        } else {
            None
        };
        let recommendation_generation = config.features.recommendations.then(|| {
            BatchRecommendationSource::new(
                database.recommendation_batches(),
                services.research_profiles.clone(),
            )
        });
        let reading_feed = config
            .features
            .reading_feed
            .then(|| {
                let recommendation_source: Arc<dyn RecommendationSource> =
                    if let Some(source) = &recommendation_generation {
                        Arc::new(source.clone())
                    } else {
                        Arc::new(BatchRecommendationSource::recent_only(
                            database.recommendation_batches(),
                        ))
                    };
                Ok::<_, anyhow::Error>(ReadingFeedService::with_dependencies(
                    Arc::new(database.reading_feed()),
                    recommendation_source,
                    Arc::new(EncryptedReadingFeedCursorCodec::new(config.cursors.codec())),
                    config.reading_feed.policy()?,
                ))
            })
            .transpose()?;
        let engagement = (config.features.reading_briefs
            || config.features.subscriptions
            || config.features.notifications)
            .then(|| {
                let authority = reading_feed.clone().ok_or_else(|| {
                    anyhow::anyhow!("engagement features require reading-feed authority")
                })?;
                Ok::<_, anyhow::Error>(EngagementService::new(
                    Arc::new(database.engagement()),
                    authority,
                    EngagementPolicy::default(),
                ))
            })
            .transpose()?;
        let request_limiter = PublicRequestRateLimiter::new(
            database.rate_limits(),
            config.request_origin.clone(),
            config.prepare_requests_per_minute,
            config.chat_requests_per_minute,
            config.paper_resolution.search_account_limit_per_minute,
        )?;
        let visual_assets = config
            .visual_assets
            .as_ref()
            .map(|assets| VisualAssetStore::new(&assets.directory, assets.maximum_asset_bytes))
            .transpose()?;
        Ok(Self {
            database,
            papers,
            documents,
            paper_resolution,
            paper_import,
            reading_feed,
            recommendation_generation,
            research_profiles: services.research_profiles,
            discovery_search,
            engagement,
            cursor_key_epoch,
            fulltext_policy: config.fulltext_policy,
            model_provider,
            request_limiter,
            accounts: services.accounts,
            account_deletion: services.account_deletion,
            library: services.library,
            comments: services.comments,
            auth,
            visual_assets,
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

    /// Cloneable privacy-maintenance handle. Absent while research profiles
    /// are dormant.
    pub fn research_profile_service(&self) -> Option<ResearchProfileService> {
        self.research_profiles.clone()
    }

    /// Cloneable account-delivery maintenance handle. Absent while every
    /// Phase G feature is dormant.
    pub fn engagement_service(&self) -> Option<EngagementService> {
        self.engagement.clone()
    }

    /// Starts the durable account-owned recommendation processor only while
    /// enhanced recommendations are enabled. Retention remains always-on.
    pub fn spawn_recommendation_generation_worker(&self) -> Option<tokio::task::JoinHandle<()>> {
        crate::maintenance::spawn_recommendation_generation(self.recommendation_generation.clone())
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
    research_profiles: Option<ResearchProfileService>,
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
    let research_profiles = config.features.research_profiles.then(|| {
        ResearchProfileService::new(
            Arc::new(database.research_profiles()),
            Arc::new(database.rate_limits()),
            ResearchProfilePolicy::default(),
        )
    });
    Ok(ApplicationServices {
        accounts,
        account_deletion,
        library,
        comments,
        research_profiles,
    })
}

#[allow(clippy::too_many_lines)] // Feature gates stay explicit so dormant routes are auditable.
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
    let router = register_document_reader_routes(router, config.features);
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
    let router = register_library_v2_routes(router, config.features);
    let router = register_reading_feed_route(router, config.features);
    let router = register_research_profile_routes(router, config.features);
    let router = register_recommendation_routes(router, config.features);
    let router = register_interaction_route(router, config.features);
    let router = register_discovery_search_routes(router, config.features);
    let router = register_paper_resolution_routes(router, config.features);
    let router = register_engagement_routes(router, config.features);
    let router = register_research_memory_routes(router, config.features);
    let router = register_version_diff_routes(router, config.features);
    let router = register_assistant_v2_routes(router, config.features);
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
        // This must remain outside the timeout/error layers so their synthetic
        // health responses cannot accidentally become cacheable.
        .layer(middleware::from_fn(health_cache_control))
}

fn register_document_reader_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    let router = if features.deep_reader {
        router
            .route(
                "/v1/papers/{paper_id}/document/outline",
                get(document_outline),
            )
            .route(
                "/v1/papers/{paper_id}/document/blocks",
                get(document_blocks),
            )
    } else {
        router
    };
    let router = if features.visual_objects {
        router
            .route("/v1/papers/{paper_id}/figures", get(figures))
            .route("/v1/papers/{paper_id}/figures/{figure_id}", get(figure))
            .route(
                "/v1/papers/{paper_id}/figures/{figure_id}/asset",
                get(figure_asset),
            )
            .route("/v1/papers/{paper_id}/tables", get(tables))
            .route("/v1/papers/{paper_id}/tables/{table_id}", get(table))
            .route("/v1/papers/{paper_id}/equations", get(equations))
    } else {
        router
    };
    let router = if features.semantic_facets {
        router
            .route("/v1/papers/{paper_id}/terms", get(terms))
            .route("/v1/papers/{paper_id}/semantic-spans", get(semantic_spans))
    } else {
        router
    };
    let router = if features.paper_passport {
        router
            .route("/v1/papers/{paper_id}/passport", get(passport))
            .route(
                "/v1/papers/{paper_id}/passport/feedback",
                post(passport_feedback),
            )
    } else {
        router
    };
    if features.visual_objects || features.semantic_facets || features.paper_passport {
        router.route(
            "/v1/papers/{paper_id}/provenance/{provenance_id}",
            get(shared_provenance),
        )
    } else {
        router
    }
}

fn register_version_diff_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    if features.version_diff {
        router
            .route("/v1/papers/{paper_id}/versions", get(paper_versions))
            .route(
                "/v1/papers/{paper_id}/version-diff",
                get(paper_version_diff),
            )
    } else {
        router
    }
}

fn register_assistant_v2_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    if features.assistant_v2 {
        router
            .route("/v1/papers/{paper_id}/assistant", post(assistant))
            .route(
                "/v1/papers/{paper_id}/assistant/feedback",
                post(assistant_feedback),
            )
            .route(
                "/v1/assistant/provenance/{provenance_id}",
                get(assistant_provenance),
            )
    } else {
        router
    }
}

fn register_research_memory_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    let annotation_routes = features.accounts && features.deep_reader && features.annotations;
    let router = if annotation_routes {
        router
            .route("/v1/annotations", get(list_annotations))
            .route("/v1/annotation-conflicts", get(list_annotation_conflicts))
            .route("/v1/annotations/export", get(export_annotations))
            .route(
                "/v1/annotations/import",
                post(import_annotations)
                    .layer(DefaultBodyLimit::max(MAX_ANNOTATION_IMPORT_REQUEST_BYTES)),
            )
            .route(
                "/v1/annotations/{annotation_id}",
                put(put_annotation).delete(delete_annotation),
            )
            .route(
                "/v1/annotations/{annotation_id}/reanchor",
                post(reanchor_annotation),
            )
            .route(
                "/v1/evidence-cards",
                get(list_evidence_cards).post(create_evidence_card),
            )
            .route(
                "/v1/evidence-cards/{id}",
                put(put_evidence_card).delete(delete_evidence_card),
            )
    } else {
        router
    };
    let router =
        if !annotation_routes && features.accounts && features.deep_reader && features.assistant_v2
        {
            router.route("/v1/annotations/export", get(export_annotations))
        } else {
            router
        };
    let router = if features.accounts && features.deep_reader {
        router
            .route("/v1/reading/checkpoints", get(list_checkpoints))
            .route("/v1/reading/checkpoints/{paper_id}", put(put_checkpoint))
    } else {
        router
    };
    if features.accounts && features.deep_reader && features.annotations && features.research_memory
    {
        router
            .route("/v1/memory/review", get(memory_review))
            .route("/v1/memory/items", post(create_memory_item))
            .route(
                "/v1/memory/items/{id}",
                put(put_memory_item).delete(delete_memory_item),
            )
            .route("/v1/memory/items/{id}/review", post(review_memory_item))
    } else {
        router
    }
}

fn register_reading_feed_route(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    if features.accounts && features.library && features.reading_feed {
        router.route("/v1/me/reading-feed", get(reading_feed))
    } else {
        router
    }
}

fn register_research_profile_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    if features.accounts && features.research_profiles {
        router
            .route(
                "/v1/discovery/profile",
                get(get_research_profile).put(update_research_profile),
            )
            .route(
                "/v1/discovery/profile/interests",
                get(get_research_profile_interests),
            )
            .route(
                "/v1/discovery/profile/topics/{topic_id}",
                put(upsert_research_profile_topic).delete(delete_research_profile_topic),
            )
            .route(
                "/v1/discovery/profile/authors/{author_key}",
                put(upsert_research_profile_author).delete(delete_research_profile_author),
            )
            .route("/v1/discovery/profile/reset", post(reset_research_profile))
            .route("/v1/discovery/profile/export", get(export_research_profile))
    } else {
        router
    }
}

fn register_recommendation_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    if features.accounts && features.library && features.reading_feed && features.recommendations {
        router
            .route(
                "/v1/discovery/batches/{batch_id}/feedback",
                post(post_recommendation_feedback),
            )
            .route(
                "/v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation",
                get(get_recommendation_explanation),
            )
    } else {
        router
    }
}

fn register_interaction_route(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    if features.recommendation_events {
        router.route(
            "/v1/events/batch",
            post(post_interaction_batch).layer(DefaultBodyLimit::max(64 * 1024)),
        )
    } else {
        router
    }
}

fn register_discovery_search_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    let router = if features.search_lookup {
        router
            .route("/v1/search/lookup", get(lookup_search))
            .route("/v1/search/suggestions", get(search_suggestions))
    } else {
        router
    };
    let router = if features.search_explore {
        router.route("/v1/search/explore", post(explore_search))
    } else {
        router
    };
    if features.accounts && features.saved_queries {
        router
            .route(
                "/v1/search/saved",
                get(list_saved_searches).post(save_search),
            )
            .route(
                "/v1/search/saved/{saved_search_id}",
                axum::routing::delete(delete_saved_search),
            )
    } else {
        router
    }
}

fn register_paper_resolution_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    let router = if features.accounts && features.paper_title_search {
        router.route("/v1/me/paper-searches", post(search_papers))
    } else {
        router
    };
    if features.accounts && features.library && features.paper_resolution {
        router.route("/v1/me/library/imports", post(import_library_paper))
    } else {
        router
    }
}

fn register_engagement_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    let router = if features.reading_briefs {
        router
            .route("/v1/me/reading-briefs", post(create_reading_brief))
            .route("/v1/me/reading-briefs/current", get(current_reading_brief))
            .route(
                "/v1/me/reading-briefs/{id}/progress",
                post(update_reading_brief_progress),
            )
    } else {
        router
    };
    let router = if features.subscriptions {
        router
            .route(
                "/v1/subscriptions",
                get(list_subscriptions).post(create_subscription),
            )
            .route(
                "/v1/subscriptions/{id}",
                axum::routing::patch(update_subscription).delete(delete_subscription),
            )
    } else {
        router
    };
    if features.notifications {
        router
            .route("/v1/notifications", get(list_notifications))
            .route("/v1/notifications/{id}/read", post(mark_notification_read))
            .route("/v1/notifications/{id}/dismiss", post(dismiss_notification))
            .route(
                "/v1/notifications/read-all",
                post(mark_all_notifications_read),
            )
            .route(
                "/v1/notification-preferences",
                get(get_notification_preferences).put(put_notification_preferences),
            )
    } else {
        router
    }
}

fn register_library_v2_routes(
    router: Router<AppState>,
    features: FeatureFlags,
) -> Router<AppState> {
    if features.accounts && features.library && features.library_v2 {
        router
            .route("/v1/library/items", get(list_library_v2_items))
            .route(
                "/v1/library/papers/{paper_id}",
                put(put_library_v2_item)
                    .patch(patch_library_v2_item)
                    .delete(delete_library_v2_item),
            )
            .route(
                "/v1/library/lists",
                get(list_library_lists).post(create_library_list),
            )
            .route(
                "/v1/library/lists/{list_id}",
                axum::routing::patch(update_library_list).delete(delete_library_list),
            )
            .route(
                "/v1/library/lists/{list_id}/papers/{paper_id}",
                put(put_library_list_item).delete(delete_library_list_item),
            )
            .route(
                "/v1/library/tags",
                get(list_library_tags).post(create_library_tag),
            )
            .route(
                "/v1/library/tags/{tag_id}",
                axum::routing::patch(update_library_tag).delete(delete_library_tag),
            )
            .route(
                "/v1/library/papers/{paper_id}/tags/{tag_id}",
                put(put_library_item_tag).delete(delete_library_item_tag),
            )
            .route("/v1/library/changes", get(library_v2_changes))
    } else {
        router
    }
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
#[allow(clippy::too_many_lines)] // Mirrors the intentionally explicit production route gates.
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
    if features.accounts && features.library && features.library_v2 {
        routes.extend([
            "/v1/library/items",
            "/v1/library/papers/{paper_id}",
            "/v1/library/lists",
            "/v1/library/lists/{list_id}",
            "/v1/library/lists/{list_id}/papers/{paper_id}",
            "/v1/library/tags",
            "/v1/library/tags/{tag_id}",
            "/v1/library/papers/{paper_id}/tags/{tag_id}",
            "/v1/library/changes",
        ]);
    }
    if features.accounts && features.library && features.reading_feed {
        routes.push("/v1/me/reading-feed");
    }
    if features.deep_reader {
        routes.extend([
            "/v1/papers/{paper_id}/document/outline",
            "/v1/papers/{paper_id}/document/blocks",
        ]);
    }
    if features.visual_objects {
        routes.extend([
            "/v1/papers/{paper_id}/figures",
            "/v1/papers/{paper_id}/figures/{figure_id}",
            "/v1/papers/{paper_id}/figures/{figure_id}/asset",
            "/v1/papers/{paper_id}/tables",
            "/v1/papers/{paper_id}/tables/{table_id}",
            "/v1/papers/{paper_id}/equations",
        ]);
    }
    if features.semantic_facets {
        routes.extend([
            "/v1/papers/{paper_id}/terms",
            "/v1/papers/{paper_id}/semantic-spans",
        ]);
    }
    if features.paper_passport {
        routes.extend([
            "/v1/papers/{paper_id}/passport",
            "/v1/papers/{paper_id}/passport/feedback",
        ]);
    }
    if features.visual_objects || features.semantic_facets || features.paper_passport {
        routes.push("/v1/papers/{paper_id}/provenance/{provenance_id}");
    }
    if features.accounts && features.deep_reader && features.annotations {
        routes.extend([
            "/v1/annotations",
            "/v1/annotation-conflicts",
            "/v1/annotations/export",
            "/v1/annotations/import",
            "/v1/annotations/{annotation_id}",
            "/v1/annotations/{annotation_id}/reanchor",
            "/v1/evidence-cards",
            "/v1/evidence-cards/{id}",
        ]);
    } else if features.accounts && features.deep_reader && features.assistant_v2 {
        routes.push("/v1/annotations/export");
    }
    if features.accounts && features.deep_reader {
        routes.extend([
            "/v1/reading/checkpoints",
            "/v1/reading/checkpoints/{paper_id}",
        ]);
    }
    if features.accounts && features.deep_reader && features.annotations && features.research_memory
    {
        routes.extend([
            "/v1/memory/review",
            "/v1/memory/items",
            "/v1/memory/items/{id}",
            "/v1/memory/items/{id}/review",
        ]);
    }
    if features.version_diff {
        routes.extend([
            "/v1/papers/{paper_id}/versions",
            "/v1/papers/{paper_id}/version-diff",
        ]);
    }
    if features.assistant_v2 {
        routes.extend([
            "/v1/papers/{paper_id}/assistant",
            "/v1/papers/{paper_id}/assistant/feedback",
            "/v1/assistant/provenance/{provenance_id}",
        ]);
    }
    if features.accounts && features.research_profiles {
        routes.extend([
            "/v1/discovery/profile",
            "/v1/discovery/profile/interests",
            "/v1/discovery/profile/topics/{topic_id}",
            "/v1/discovery/profile/authors/{author_key}",
            "/v1/discovery/profile/reset",
            "/v1/discovery/profile/export",
        ]);
    }
    if features.accounts && features.library && features.reading_feed && features.recommendations {
        routes.extend([
            "/v1/discovery/batches/{batch_id}/feedback",
            "/v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation",
        ]);
    }
    if features.recommendation_events {
        routes.push("/v1/events/batch");
    }
    if features.search_lookup {
        routes.extend(["/v1/search/lookup", "/v1/search/suggestions"]);
    }
    if features.search_explore {
        routes.push("/v1/search/explore");
    }
    if features.accounts && features.saved_queries {
        routes.extend(["/v1/search/saved", "/v1/search/saved/{saved_search_id}"]);
    }
    if features.accounts && features.paper_title_search {
        routes.push("/v1/me/paper-searches");
    }
    if features.accounts && features.library && features.paper_resolution {
        routes.push("/v1/me/library/imports");
    }
    if features.reading_briefs {
        routes.extend([
            "/v1/me/reading-briefs",
            "/v1/me/reading-briefs/current",
            "/v1/me/reading-briefs/{id}/progress",
        ]);
    }
    if features.subscriptions {
        routes.extend(["/v1/subscriptions", "/v1/subscriptions/{id}"]);
    }
    if features.notifications {
        routes.extend([
            "/v1/notifications",
            "/v1/notifications/{id}/read",
            "/v1/notifications/{id}/dismiss",
            "/v1/notifications/read-all",
            "/v1/notification-preferences",
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
    #[allow(clippy::too_many_lines)] // One closed expectation makes accidental route drift obvious.
    fn feature_flags_do_not_publish_incomplete_routes() {
        let all_enabled = FeatureFlags {
            accounts: true,
            library: true,
            library_writes: true,
            library_v2: true,
            comments: true,
            comment_creation: true,
            account_deletion: true,
            paper_resolution: true,
            paper_title_search: true,
            library_import_writes: true,
            reading_feed: true,
            to_read_first_enforcement: true,
            research_profiles: true,
            recommendations: true,
            recommendation_events: true,
            search_lookup: true,
            search_explore: true,
            saved_queries: true,
            reading_briefs: true,
            subscriptions: true,
            notifications: true,
            deep_reader: true,
            paper_passport: true,
            semantic_facets: true,
            visual_objects: true,
            assistant_v2: true,
            annotations: true,
            research_memory: true,
            version_diff: true,
            docling_experiment: true,
        };
        assert_eq!(
            production_feature_routes(all_enabled),
            vec![
                "/v1/me",
                "/v1/me/library",
                "/v1/me/library/changes",
                "/v1/me/library/{paper_id}",
                "/v1/library/items",
                "/v1/library/papers/{paper_id}",
                "/v1/library/lists",
                "/v1/library/lists/{list_id}",
                "/v1/library/lists/{list_id}/papers/{paper_id}",
                "/v1/library/tags",
                "/v1/library/tags/{tag_id}",
                "/v1/library/papers/{paper_id}/tags/{tag_id}",
                "/v1/library/changes",
                "/v1/me/reading-feed",
                "/v1/papers/{paper_id}/document/outline",
                "/v1/papers/{paper_id}/document/blocks",
                "/v1/papers/{paper_id}/figures",
                "/v1/papers/{paper_id}/figures/{figure_id}",
                "/v1/papers/{paper_id}/figures/{figure_id}/asset",
                "/v1/papers/{paper_id}/tables",
                "/v1/papers/{paper_id}/tables/{table_id}",
                "/v1/papers/{paper_id}/equations",
                "/v1/papers/{paper_id}/terms",
                "/v1/papers/{paper_id}/semantic-spans",
                "/v1/papers/{paper_id}/passport",
                "/v1/papers/{paper_id}/passport/feedback",
                "/v1/papers/{paper_id}/provenance/{provenance_id}",
                "/v1/annotations",
                "/v1/annotation-conflicts",
                "/v1/annotations/export",
                "/v1/annotations/import",
                "/v1/annotations/{annotation_id}",
                "/v1/annotations/{annotation_id}/reanchor",
                "/v1/evidence-cards",
                "/v1/evidence-cards/{id}",
                "/v1/reading/checkpoints",
                "/v1/reading/checkpoints/{paper_id}",
                "/v1/memory/review",
                "/v1/memory/items",
                "/v1/memory/items/{id}",
                "/v1/memory/items/{id}/review",
                "/v1/papers/{paper_id}/versions",
                "/v1/papers/{paper_id}/version-diff",
                "/v1/papers/{paper_id}/assistant",
                "/v1/papers/{paper_id}/assistant/feedback",
                "/v1/assistant/provenance/{provenance_id}",
                "/v1/discovery/profile",
                "/v1/discovery/profile/interests",
                "/v1/discovery/profile/topics/{topic_id}",
                "/v1/discovery/profile/authors/{author_key}",
                "/v1/discovery/profile/reset",
                "/v1/discovery/profile/export",
                "/v1/discovery/batches/{batch_id}/feedback",
                "/v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation",
                "/v1/events/batch",
                "/v1/search/lookup",
                "/v1/search/suggestions",
                "/v1/search/explore",
                "/v1/search/saved",
                "/v1/search/saved/{saved_search_id}",
                "/v1/me/paper-searches",
                "/v1/me/library/imports",
                "/v1/me/reading-briefs",
                "/v1/me/reading-briefs/current",
                "/v1/me/reading-briefs/{id}/progress",
                "/v1/subscriptions",
                "/v1/subscriptions/{id}",
                "/v1/notifications",
                "/v1/notifications/{id}/read",
                "/v1/notifications/{id}/dismiss",
                "/v1/notifications/read-all",
                "/v1/notification-preferences",
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
                ..FeatureFlags::default()
            }),
            vec!["/v1/me"]
        );
        assert_eq!(
            production_feature_routes(FeatureFlags {
                deep_reader: true,
                ..FeatureFlags::default()
            }),
            vec![
                "/v1/papers/{paper_id}/document/outline",
                "/v1/papers/{paper_id}/document/blocks",
            ],
            "deep Reader alone must not publish dormant enrichment routes"
        );
        assert_eq!(
            production_feature_routes(FeatureFlags {
                accounts: true,
                deep_reader: true,
                ..FeatureFlags::default()
            }),
            vec![
                "/v1/me",
                "/v1/papers/{paper_id}/document/outline",
                "/v1/papers/{paper_id}/document/blocks",
                "/v1/reading/checkpoints",
                "/v1/reading/checkpoints/{paper_id}",
            ],
            "authenticated checkpoint restore must not depend on annotations"
        );
        assert_eq!(
            production_feature_routes(FeatureFlags {
                accounts: true,
                deep_reader: true,
                assistant_v2: true,
                ..FeatureFlags::default()
            }),
            vec![
                "/v1/me",
                "/v1/papers/{paper_id}/document/outline",
                "/v1/papers/{paper_id}/document/blocks",
                "/v1/annotations/export",
                "/v1/reading/checkpoints",
                "/v1/reading/checkpoints/{paper_id}",
                "/v1/papers/{paper_id}/assistant",
                "/v1/papers/{paper_id}/assistant/feedback",
                "/v1/assistant/provenance/{provenance_id}",
            ],
            "authenticated assistant history must retain research export without annotations"
        );
        assert_eq!(
            production_feature_routes(FeatureFlags {
                accounts: true,
                research_memory: true,
                ..FeatureFlags::default()
            }),
            vec!["/v1/me"],
            "research memory must fail closed unless its full dependency edge is enabled"
        );
        assert_eq!(
            production_feature_routes(FeatureFlags {
                deep_reader: true,
                visual_objects: true,
                ..FeatureFlags::default()
            }),
            vec![
                "/v1/papers/{paper_id}/document/outline",
                "/v1/papers/{paper_id}/document/blocks",
                "/v1/papers/{paper_id}/figures",
                "/v1/papers/{paper_id}/figures/{figure_id}",
                "/v1/papers/{paper_id}/figures/{figure_id}/asset",
                "/v1/papers/{paper_id}/tables",
                "/v1/papers/{paper_id}/tables/{table_id}",
                "/v1/papers/{paper_id}/equations",
                "/v1/papers/{paper_id}/provenance/{provenance_id}",
            ],
            "visual object publication has its own gate"
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
