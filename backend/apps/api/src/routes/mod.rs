use std::{net::SocketAddr, time::Instant};

use arxiv_client::ArxivError;
use axum::{
    Extension, Json,
    extract::{ConnectInfo, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use db::{CursorError, DbError, FeedQuery};
use domain::{
    Capabilities, FailureCategory, FulltextPolicy, OverallProcessingState, Paper, PaperSummary,
    ProcessingError, ProcessingStage, ProcessingState,
};
use llm_provider::{ChatCompletionRequest, EmbeddingRequest, EvidenceExcerpt, ProviderError};
use paper_resolution::PaperResolutionError;
use retrieval::{
    ContextSelectionConfig, RetrievalScope, SearchHit, hybrid_rank, keyword_websearch_query,
    select_context,
};
use serde_json::json;
use tracing::{error, info};
use url::Url;
use uuid::Uuid;

use crate::{
    app::AppState,
    dto::{ChatBody, ChatResponse, FeedParams, PrepareBody},
    error::{ApiError, RequestId},
    request_rate_limit::{PublicRequestAction, PublicRequestRateLimitError},
};

pub(crate) mod account;
pub(crate) mod assistant_v2;
pub(crate) mod chat;
pub(crate) mod comments;
pub(crate) mod discovery_search;
pub(crate) mod document_reader;
pub(crate) mod engagement;
pub(crate) mod feed;
pub(crate) mod health;
pub(crate) mod interactions;
pub(crate) mod library;
pub(crate) mod library_imports;
pub(crate) mod library_v2;
pub(crate) mod paper_search;
pub(crate) mod papers;
pub(crate) mod passport;
pub(crate) mod reading_feed;
pub(crate) mod recommendations;
pub(crate) mod research_memory;
pub(crate) mod research_profiles;
pub(crate) mod support;
pub(crate) mod version_diff;

use support::{
    apply_processing_policy, apply_summary_policy, capability_not_ready, cursor_error,
    enforce_derived_policy, enforce_public_request_limit, internal_db_error, paper_not_found,
    paper_resolution_error, provider_error, reciprocal_rank_score, retrieval_error, valid_category,
};

pub(crate) use account::{
    delete_me, get_me, patch_me, private_account_cache_control, verify_deletion_identity,
};
pub(crate) use assistant_v2::{assistant, assistant_feedback, assistant_provenance};
pub(crate) use chat::chat;
pub(crate) use comments::{
    block_user, create_comment, delete_comment, edit_comment, list_blocked_users, list_my_comments,
    list_paper_comments, report_comment, report_user, unblock_user,
};
pub(crate) use discovery_search::{
    delete_saved_search, explore_search, list_saved_searches, lookup_search, save_search,
    search_suggestions,
};
pub(crate) use document_reader::{
    document_blocks, document_outline, equations, figure, figure_asset, figures, table, tables,
    terms,
};
pub(crate) use engagement::{
    create_reading_brief, create_subscription, current_reading_brief, delete_subscription,
    dismiss_notification, get_notification_preferences, list_notifications, list_subscriptions,
    mark_all_notifications_read, mark_notification_read, put_notification_preferences,
    update_reading_brief_progress, update_subscription,
};
pub(crate) use feed::feed;
pub(crate) use health::{health_cache_control, health_live, health_ready};
pub(crate) use interactions::post_interaction_batch;
pub(crate) use library::{library_changes, list_library, remove_library_item, save_library_item};
pub(crate) use library_imports::import_library_paper;
pub(crate) use library_v2::{
    create_library_list, create_library_tag, delete_library_item_tag, delete_library_list,
    delete_library_list_item, delete_library_tag, delete_library_v2_item, library_v2_changes,
    list_library_lists, list_library_tags, list_library_v2_items, patch_library_v2_item,
    put_library_item_tag, put_library_list_item, put_library_v2_item, update_library_list,
    update_library_tag,
};
pub(crate) use paper_search::search_papers;
pub(crate) use papers::{
    connections, introduction, paper_by_arxiv, paper_metadata, prepare, processing,
};
pub(crate) use passport::{passport, passport_feedback, semantic_spans, shared_provenance};
pub(crate) use reading_feed::reading_feed;
pub(crate) use recommendations::{get_recommendation_explanation, post_recommendation_feedback};
pub(crate) use research_memory::{
    MAX_ANNOTATION_IMPORT_REQUEST_BYTES, create_evidence_card, create_memory_item,
    delete_annotation, delete_evidence_card, delete_memory_item, export_annotations,
    import_annotations, list_annotation_conflicts, list_annotations, list_checkpoints,
    list_evidence_cards, memory_review, put_annotation, put_checkpoint, put_evidence_card,
    put_memory_item, reanchor_annotation, review_memory_item,
};
pub(crate) use research_profiles::{
    delete_research_profile_author, delete_research_profile_topic, export_research_profile,
    get_research_profile, get_research_profile_interests, reset_research_profile,
    update_research_profile, upsert_research_profile_author, upsert_research_profile_topic,
};
pub(crate) use version_diff::{paper_version_diff, paper_versions};

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    use arxiv_client::ArxivClientConfig;
    use axum::{
        Router,
        body::Body,
        extract::DefaultBodyLimit,
        http::{
            Method, Request as HttpRequest,
            header::{CACHE_CONTROL, CONTENT_TYPE, ETAG, IF_NONE_MATCH, VARY},
        },
        middleware,
        response::Response,
        routing::post,
    };
    use chrono::{TimeDelta, Utc};
    use db::Database;
    use domain::{
        ApiErrorEnvelope, ArxivIdentifier, Author, IntroductionDetection, PaperMetadata,
        ParsedPaper, ParsedParagraph, ParsedSection, SectionKind,
    };
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt as _;

    use super::chat::validate_chat_body;
    use crate::{
        build_router,
        config::{
            ApiConfig, ApiEnvironment, ApiModelConfig, FeatureFlags,
            enforce_cross_process_arxiv_gate,
        },
        middleware::{
            REQUEST_ID_HEADER, RequestPrincipal, SESSION_ID_HEADER, request_id_middleware,
            stable_error_middleware,
        },
    };

    #[tokio::test]
    async fn personalized_features_default_to_absent_private_routes() {
        let config = test_api_config(
            "postgres://test:test@127.0.0.1/test",
            FulltextPolicy::Prototype,
        );
        assert!(!config.features.reading_feed);
        assert!(!config.features.library_v2);
        assert!(!config.features.research_profiles);
        assert!(!config.features.recommendations);
        assert!(!config.features.recommendation_events);
        let database = Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        );
        let app = build_router(AppState::new(database, &config).unwrap(), &config);

        for path in [
            "/v1/me/reading-feed",
            "/v1/me/paper-searches",
            "/v1/me/library/imports",
            "/v1/library/items",
            "/v1/library/lists",
            "/v1/library/tags",
            "/v1/library/changes",
            "/v1/discovery/profile",
            "/v1/discovery/batches/0198f4d7-a4ce-7b40-8ee8-4f350350810c/feedback",
            "/v1/discovery/batches/0198f4d7-a4ce-7b40-8ee8-4f350350810c/papers/0198f4d7-a4ce-7b40-8ee8-4f350350810d/explanation",
            "/v1/events/batch",
            "/v1/annotation-conflicts",
        ] {
            let response = app
                .clone()
                .oneshot(HttpRequest::get(path).body(Body::empty()).unwrap())
                .await
                .unwrap();

            assert_eq!(response.status(), StatusCode::NOT_FOUND);
            assert_eq!(response.headers()[CACHE_CONTROL], "private, no-store");
            assert!(response.headers().get_all(VARY).iter().any(|value| {
                value.to_str().is_ok_and(|value| {
                    value
                        .split(',')
                        .any(|name| name.trim().eq_ignore_ascii_case("authorization"))
                })
            }));
        }
    }

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
        let valid = ChatBody {
            thread_id: None,
            message: "安全ですか？".repeat(50),
        };
        assert_eq!(
            validate_chat_body(request_id, Some(session), &valid).unwrap(),
            session
        );
        let too_long = ChatBody {
            thread_id: None,
            message: "問".repeat(501),
        };
        assert_eq!(
            validate_chat_body(request_id, Some(session), &too_long)
                .unwrap_err()
                .status,
            StatusCode::PAYLOAD_TOO_LARGE
        );
    }

    #[test]
    fn signed_in_chat_keeps_the_explicit_anonymous_session_scope() {
        let user_id = Uuid::now_v7();
        let session_id = Uuid::new_v4();
        let principal = RequestPrincipal {
            user_id: Some(user_id),
            anonymous_session_id: Some(session_id),
            request_id: Uuid::now_v7(),
        };
        let body = ChatBody {
            thread_id: None,
            message: "Keep these histories separate.".to_owned(),
        };

        assert_ne!(user_id, session_id);
        assert_eq!(
            validate_chat_body(
                RequestId(principal.request_id),
                principal.anonymous_session_id,
                &body,
            )
            .unwrap(),
            session_id
        );

        let account_only = RequestPrincipal {
            anonymous_session_id: None,
            ..principal
        };
        let error = validate_chat_body(
            RequestId(account_only.request_id),
            account_only.anonymous_session_id,
            &body,
        )
        .unwrap_err();
        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "INVALID_SESSION_ID");
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
                visual_objects: true,
                terms: true,
                semantic_facets: true,
                paper_passport: true,
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

    #[tokio::test]
    async fn feed_route_revalidates_an_unchanged_first_page_and_detects_updates() {
        let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
            eprintln!("TEST_DATABASE_URL is absent; skipped feed ETag API coverage");
            return;
        };
        let database = Database::connect(&database_url, 4).await.unwrap();
        database.migrate_embedded().await.unwrap();
        let repository = database.papers();
        let unique = Uuid::now_v7().simple().to_string();
        let base_id = format!("test.etag.{unique}");
        let category = format!("cs.E{}", &unique[..8]);
        let now = Utc::now();
        let metadata = |version, title: &str, fetched_at| PaperMetadata {
            arxiv_id: ArxivIdentifier {
                base_id: base_id.clone(),
                version,
            },
            title: title.to_owned(),
            abstract_text: "Public cache validation metadata.".to_owned(),
            authors: vec![Author {
                name: "Ada Validator".to_owned(),
            }],
            primary_category: category.clone(),
            categories: vec![category.clone()],
            published_at: now,
            updated_at: now,
            abs_url: Url::parse("https://arxiv.org/abs/2401.99999v1").unwrap(),
            pdf_url: Url::parse("https://arxiv.org/pdf/2401.99999v1").unwrap(),
            doi: None,
            journal_reference: None,
            comment: None,
            license_uri: None,
            metadata_fetched_at: fetched_at,
        };
        let paper = repository
            .upsert_metadata(&metadata(1, "Initial validator title", now))
            .await
            .unwrap();
        let config = test_api_config(&database_url, FulltextPolicy::Prototype);
        let app = build_router(AppState::new(database, &config).unwrap(), &config);
        let path = format!("/v1/feed?category={category}&limit=1");

        let response = app
            .clone()
            .oneshot(HttpRequest::get(&path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let entity_tag = response.headers()[ETAG].clone();
        assert_eq!(
            response.headers()[CACHE_CONTROL],
            "public, max-age=60, stale-while-revalidate=300"
        );
        assert_eq!(
            response_json(response).await["items"][0]["paper_id"],
            paper.id.to_string()
        );

        let response = app
            .clone()
            .oneshot(
                HttpRequest::get(&path)
                    .header(IF_NONE_MATCH, entity_tag.clone())
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_MODIFIED);
        assert_eq!(response.headers()[ETAG], entity_tag);
        assert!(
            axum::body::to_bytes(response.into_body(), 1024)
                .await
                .unwrap()
                .is_empty()
        );

        repository
            .upsert_metadata(&metadata(
                2,
                "Updated validator title",
                now + TimeDelta::seconds(1),
            ))
            .await
            .unwrap();
        let response = app
            .oneshot(
                HttpRequest::get(&path)
                    .header(IF_NONE_MATCH, entity_tag.clone())
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_ne!(response.headers()[ETAG], entity_tag);
        assert_eq!(
            response_json(response).await["items"][0]["title"],
            "Updated validator title"
        );
    }

    fn test_api_config(database_url: &str, fulltext_policy: FulltextPolicy) -> ApiConfig {
        let arxiv = ArxivClientConfig {
            user_agent: "PakperkPolicyTest/0.1".to_owned(),
            contact_email: "engineering@pakperk.org".to_owned(),
            ..ArxivClientConfig::default()
        };
        ApiConfig {
            environment: ApiEnvironment::Development,
            features: FeatureFlags::default(),
            accounts: None,
            library: None,
            comments: None,
            account_deletion: None,
            visual_assets: None,
            paper_resolution: crate::config::PaperResolutionFeatureConfig::default(),
            reading_feed: crate::config::ReadingFeedFeatureConfig::default(),
            request_origin: crate::config::RequestOriginConfig::for_local_development(
                "route-test-request-origin-secret-0123456789",
            )
            .unwrap(),
            cursors: crate::config::CursorConfig::for_local_development(
                "route-module-cursor-test-seed",
            )
            .unwrap(),
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

    #[tokio::test]
    async fn annotation_import_limit_overrides_global_limit_but_stays_bounded() {
        async fn import_json(Json(_body): Json<serde_json::Value>) -> StatusCode {
            StatusCode::NO_CONTENT
        }
        let app = Router::new()
            .route(
                "/import",
                post(import_json).layer(DefaultBodyLimit::max(MAX_ANNOTATION_IMPORT_REQUEST_BYTES)),
            )
            .layer(DefaultBodyLimit::max(64 * 1024));
        let valid_export = serde_json::to_vec(&serde_json::json!({
            "schema_version": "pakperk.research-export.v1",
            "padding": "x".repeat(70 * 1024),
        }))
        .unwrap();
        let accepted = app
            .clone()
            .oneshot(
                HttpRequest::post("/import")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(valid_export))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(accepted.status(), StatusCode::NO_CONTENT);

        let rejected = app
            .oneshot(
                HttpRequest::post("/import")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(vec![
                        b' ';
                        MAX_ANNOTATION_IMPORT_REQUEST_BYTES + 1
                    ]))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(rejected.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }
}
