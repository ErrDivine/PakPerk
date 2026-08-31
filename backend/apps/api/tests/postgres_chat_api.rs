use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    time::Duration,
};

use arxiv_client::ArxivClientConfig;
use axum::{
    body::{Body, to_bytes},
    extract::ConnectInfo,
    http::{
        Request, StatusCode,
        header::{CONTENT_TYPE, RETRY_AFTER},
    },
};
use chrono::{TimeDelta, Utc};
use db::{Database, PaperRepository};
use domain::{
    ArxivIdentifier, Author, Chunk, ConnectionsResponse, FulltextPolicy, Introduction,
    IntroductionDetection, PaperMetadata, ParsedPaper, ParsedParagraph, ParsedSection, SectionKind,
};
use llm_provider::{DeterministicProvider, EmbeddingProvider, EmbeddingRequest};
use pakperk_api::{
    ApiConfig, ApiEnvironment, ApiModelConfig, AppState, FeatureFlags, RequestOriginConfig,
    build_router,
};
use serde_json::{Value, json};
use tower::ServiceExt as _;
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_backed_router_serves_scoped_chat_and_prepared_capabilities() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL API integration coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    database.ready().await.unwrap();
    let papers = database.papers();
    let unique = Uuid::now_v7().simple().to_string();
    let source = papers
        .upsert_metadata(&metadata(
            &format!("test.api.source.{unique}"),
            "Source Paper",
        ))
        .await
        .unwrap();
    let foreign = papers
        .upsert_metadata(&metadata(
            &format!("test.api.foreign.{unique}"),
            "Foreign Paper",
        ))
        .await
        .unwrap();

    persist_document(&papers, source.id).await;
    persist_document(&papers, foreign.id).await;
    let source_text =
        "The retrieval module ranks paragraph chunks using lexical and vector evidence.";
    let source_chunk = publish_chat_chunk(&papers, source.id, source_text).await;
    let foreign_text =
        "FORBIDDEN_DECOY retrieval module ranks chunks using a different private corpus.";
    let foreign_chunk = publish_chat_chunk(&papers, foreign.id, foreign_text).await;
    assert_ne!(source_chunk, foreign_chunk);
    papers
        .replace_connections_and_publish(source.id, 1, &[], None)
        .await
        .unwrap();

    let config = api_config(database_url);
    let state = AppState::new(database.clone(), &config).unwrap();
    let app = build_router(state, &config);

    let introduction_response = app
        .clone()
        .oneshot(
            Request::get(format!("/v1/papers/{}/introduction", source.id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(introduction_response.status(), StatusCode::OK);
    let introduction: Introduction = response_json(introduction_response).await;
    assert_eq!(introduction.paper_id, source.id);
    assert_eq!(introduction.generation, 1);
    assert_eq!(introduction.paragraphs.len(), 1);

    let connections_response = app
        .clone()
        .oneshot(
            Request::get(format!("/v1/papers/{}/connections", source.id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(connections_response.status(), StatusCode::OK);
    let connections: ConnectionsResponse = response_json(connections_response).await;
    assert_eq!(connections.generation, 1);
    assert!(connections.ready);
    assert!(connections.key_connections.is_empty());

    let session_id = Uuid::new_v4();
    let mut chat_request = Request::post(format!("/v1/papers/{}/chat", source.id))
        .header(CONTENT_TYPE, "application/json")
        .header("x-session-id", session_id.to_string())
        .body(Body::from(
            json!({"thread_id": null, "message": "How does retrieval rank chunks?"}).to_string(),
        ))
        .unwrap();
    chat_request
        .extensions_mut()
        .insert(ConnectInfo(SocketAddr::new(
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            41_234,
        )));
    let chat_response = app.oneshot(chat_request).await.unwrap();
    assert_eq!(chat_response.status(), StatusCode::OK);
    let chat: Value = response_json(chat_response).await;
    assert_eq!(chat["generation"], 1);
    assert_eq!(chat["insufficient_evidence"], false);
    assert!(
        chat["answer_markdown"]
            .as_str()
            .unwrap()
            .contains("lexical and vector evidence")
    );
    assert!(
        !chat["answer_markdown"]
            .as_str()
            .unwrap()
            .contains("FORBIDDEN_DECOY")
    );
    let evidence = chat["evidence"].as_array().unwrap();
    assert_eq!(evidence.len(), 1);
    assert_eq!(evidence[0]["chunk_id"], source_chunk.to_string());
    assert_eq!(evidence[0]["section_kind"], "method");
    assert_eq!(evidence[0]["section_heading"], "2 Method");
    let thread_id = Uuid::parse_str(chat["thread_id"].as_str().unwrap()).unwrap();
    let persisted_message_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM chat_messages WHERE thread_id = $1")
            .bind(thread_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(persisted_message_count, 2);
    let assistant_prompt_version: String = sqlx::query_scalar(
        "SELECT prompt_version FROM chat_messages WHERE thread_id = $1 AND role = 'assistant'",
    )
    .bind(thread_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(assistant_prompt_version, "paper-chat-v1-deterministic-v2");

    sqlx::query("DELETE FROM papers WHERE id IN ($1, $2)")
        .bind(source.id)
        .bind(foreign.id)
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_assistant_feedback_is_evidence_scoped_idempotent_and_generation_fenced() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped assistant-feedback API coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(
            &format!("test.api.assistant-feedback.{unique}"),
            "Evidence Feedback Paper",
        ))
        .await
        .unwrap();
    let block_id = insert_assistant_document(&database, paper.id).await;

    let mut config = api_config(database_url);
    config.features = FeatureFlags {
        deep_reader: true,
        assistant_v2: true,
        ..FeatureFlags::default()
    };
    let app = build_router(AppState::new(database.clone(), &config).unwrap(), &config);
    let session_id = Uuid::new_v4();
    let assistant_response = app
        .clone()
        .oneshot(assistant_request(paper.id, session_id))
        .await
        .unwrap();
    assert_eq!(assistant_response.status(), StatusCode::OK);
    assert_eq!(
        assistant_response.headers()["cache-control"],
        "private, no-store"
    );
    let answer: Value = response_json(assistant_response).await;
    assert_eq!(answer["generation"], 1);
    assert_eq!(answer["status"], "supported");
    assert_eq!(
        answer["claims"][0]["evidence"][0]["block_id"],
        block_id.to_string()
    );
    let thread_id = Uuid::parse_str(answer["thread_id"].as_str().unwrap()).unwrap();
    let response_id = Uuid::parse_str(answer["response_id"].as_str().unwrap()).unwrap();
    let provenance_id = Uuid::parse_str(answer["provenance_id"].as_str().unwrap()).unwrap();
    let operation_id = Uuid::now_v7();
    let feedback_body = json!({
        "operation_id": operation_id,
        "paper_id": paper.id,
        "generation": 1,
        "thread_id": thread_id,
        "response_id": response_id,
        "provenance_id": provenance_id,
        "feedback_type": "incorrect_citation",
        "claim_index": 0,
        "evidence_block_id": block_id,
        "detail": "The cited range should be narrower."
    });

    let created = app
        .clone()
        .oneshot(assistant_feedback_request(
            paper.id,
            session_id,
            &feedback_body,
        ))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::CREATED);
    assert_eq!(created.headers()["cache-control"], "private, no-store");
    let created: Value = response_json(created).await;
    assert_eq!(created["status"], "stored");
    let feedback_id = Uuid::parse_str(created["feedback_id"].as_str().unwrap()).unwrap();

    let replay = app
        .clone()
        .oneshot(assistant_feedback_request(
            paper.id,
            session_id,
            &feedback_body,
        ))
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::OK);
    let replay: Value = response_json(replay).await;
    assert_eq!(replay["status"], "replayed");
    assert_eq!(replay["feedback_id"], feedback_id.to_string());

    let mut conflicting = feedback_body.clone();
    conflicting["detail"] = json!("Different content under the same operation ID.");
    let conflict = app
        .clone()
        .oneshot(assistant_feedback_request(
            paper.id,
            session_id,
            &conflicting,
        ))
        .await
        .unwrap();
    assert_eq!(conflict.status(), StatusCode::CONFLICT);
    assert_eq!(
        response_json::<Value>(conflict).await["error"]["code"],
        "ASSISTANT_FEEDBACK_IDEMPOTENCY_CONFLICT"
    );

    let mut wrong_target = feedback_body.clone();
    wrong_target["operation_id"] = json!(Uuid::now_v7());
    wrong_target["evidence_block_id"] = json!(Uuid::now_v7());
    let mismatch = app
        .clone()
        .oneshot(assistant_feedback_request(
            paper.id,
            session_id,
            &wrong_target,
        ))
        .await
        .unwrap();
    assert_eq!(mismatch.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        response_json::<Value>(mismatch).await["error"]["code"],
        "INVALID_ASSISTANT_FEEDBACK"
    );

    let mut cross_session = feedback_body.clone();
    cross_session["operation_id"] = json!(Uuid::now_v7());
    let not_owned = app
        .clone()
        .oneshot(assistant_feedback_request(
            paper.id,
            Uuid::new_v4(),
            &cross_session,
        ))
        .await
        .unwrap();
    assert_eq!(not_owned.status(), StatusCode::NOT_FOUND);

    sqlx::query("UPDATE paper_processing SET generation = 2 WHERE paper_id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
    let mut stale_generation = feedback_body;
    stale_generation["operation_id"] = json!(Uuid::now_v7());
    let stale = app
        .oneshot(assistant_feedback_request(
            paper.id,
            session_id,
            &stale_generation,
        ))
        .await
        .unwrap();
    assert_eq!(stale.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM assistant_evidence_feedback_evaluations WHERE id = $1",
        )
        .bind(feedback_id)
        .fetch_one(database.pool())
        .await
        .unwrap(),
        1
    );

    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
async fn postgres_public_limits_are_shared_and_untrusted_forwarding_cannot_rotate_origin() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL public rate-limit coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let mut config = api_config(database_url);
    config.request_origin = RequestOriginConfig::for_local_development(&format!(
        "public-rate-limit-{unique}-strong-random-material"
    ))
    .unwrap();
    config.prepare_requests_per_minute = 1;
    config.chat_requests_per_minute = 2;
    let first = build_router(AppState::new(database.clone(), &config).unwrap(), &config);
    let second = build_router(AppState::new(database, &config).unwrap(), &config);
    let peer = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(198, 51, 100, 81)), 41_234);
    let missing_paper = Uuid::now_v7();

    let prepare = |forwarded_for: &str, session: Uuid| {
        let mut request = Request::post(format!("/v1/papers/{missing_paper}/prepare"))
            .header(CONTENT_TYPE, "application/json")
            .header("x-forwarded-for", forwarded_for)
            .header("x-session-id", session.to_string())
            .body(Body::from(r#"{"retry":false}"#))
            .unwrap();
        request.extensions_mut().insert(ConnectInfo(peer));
        request
    };
    let accepted = first
        .clone()
        .oneshot(prepare("203.0.113.10", Uuid::now_v7()))
        .await
        .unwrap();
    assert_eq!(accepted.status(), StatusCode::NOT_FOUND);
    let denied = second
        .clone()
        .oneshot(prepare("192.0.2.44", Uuid::now_v7()))
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(denied.headers().contains_key(RETRY_AFTER));

    let chat = |forwarded_for: &str, session: Uuid| {
        let mut request = Request::post(format!("/v1/papers/{missing_paper}/chat"))
            .header(CONTENT_TYPE, "application/json")
            .header("x-forwarded-for", forwarded_for)
            .header("x-session-id", session.to_string())
            .body(Body::from(
                json!({"thread_id": null, "message": "Is this paper ready?"}).to_string(),
            ))
            .unwrap();
        request.extensions_mut().insert(ConnectInfo(peer));
        request
    };
    for (app, forwarded_for) in [
        (first.clone(), "203.0.113.11"),
        (second.clone(), "192.0.2.45"),
    ] {
        let response = app
            .oneshot(chat(forwarded_for, Uuid::now_v7()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }
    let denied = first
        .oneshot(chat("203.0.113.99", Uuid::now_v7()))
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(denied.headers().contains_key(RETRY_AFTER));
}

fn api_config(database_url: String) -> ApiConfig {
    let arxiv = ArxivClientConfig {
        contact_email: "integration@pakperk.dev".to_owned(),
        max_retries: 0,
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
        paper_resolution: pakperk_api::PaperResolutionFeatureConfig::default(),
        reading_feed: pakperk_api::ReadingFeedFeatureConfig::default(),
        request_origin: RequestOriginConfig::for_local_development(
            "postgres-chat-api-request-origin-secret-0123456789",
        )
        .unwrap(),
        cursors: pakperk_api::CursorConfig::for_local_development(
            "postgres-chat-api-cursor-test-seed",
        )
        .unwrap(),
        bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        database_url,
        database_pool_size: 8,
        run_migrations: false,
        request_timeout: Duration::from_secs(5),
        chat_request_timeout: Duration::from_secs(5),
        max_request_bytes: 64 * 1024,
        cors_allowed_origins: Vec::new(),
        arxiv,
        arxiv_cache_ttl: Duration::from_secs(60),
        fulltext_policy: FulltextPolicy::Prototype,
        embedding_dimension: Some(16),
        llm: Some(ApiModelConfig::Deterministic {
            embedding_dimension: 16,
        }),
        prepare_requests_per_minute: 100,
        chat_requests_per_minute: 100,
    }
}

fn metadata(base_id: &str, title: &str) -> PaperMetadata {
    let now = Utc::now();
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: title.to_owned(),
        abstract_text: "API integration fixture abstract.".to_owned(),
        authors: vec![Author {
            name: "Ada Tester".to_owned(),
        }],
        primary_category: "cs.IR".to_owned(),
        categories: vec!["cs.IR".to_owned()],
        published_at: now - TimeDelta::days(1),
        updated_at: now,
        abs_url: Url::parse("https://arxiv.org/abs/2401.00001v1").unwrap(),
        pdf_url: Url::parse("https://arxiv.org/pdf/2401.00001v1").unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: now,
    }
}

async fn persist_document(papers: &PaperRepository, paper_id: Uuid) {
    papers
        .persist_parsed_document(
            paper_id,
            1,
            &ParsedPaper {
                title: Some("API Integration Paper".to_owned()),
                sections: vec![
                    ParsedSection {
                        source_id: "introduction".to_owned(),
                        ordinal: 0,
                        parent_source_id: None,
                        kind: SectionKind::Introduction,
                        heading: Some("1 Introduction".to_owned()),
                        paragraphs: vec![ParsedParagraph {
                            ordinal: 0,
                            text: "This introduction is served through the real API handler."
                                .to_owned(),
                            citations: Vec::new(),
                            page_start: Some(1),
                            page_end: Some(1),
                        }],
                        page_start: Some(1),
                        page_end: Some(1),
                    },
                    ParsedSection {
                        source_id: "method".to_owned(),
                        ordinal: 1,
                        parent_source_id: None,
                        kind: SectionKind::Method,
                        heading: Some("2 Method".to_owned()),
                        paragraphs: vec![ParsedParagraph {
                            ordinal: 0,
                            text: "A method section reserved for the chat chunk.".to_owned(),
                            citations: Vec::new(),
                            page_start: Some(2),
                            page_end: Some(2),
                        }],
                        page_start: Some(2),
                        page_end: Some(2),
                    },
                ],
                references: Vec::new(),
                citation_contexts: Vec::new(),
            },
            &["introduction".to_owned()],
            IntroductionDetection {
                confidence: 0.99,
                used_fallback: false,
            },
            "api-integration-parser",
        )
        .await
        .unwrap();
}

async fn publish_chat_chunk(papers: &PaperRepository, paper_id: Uuid, text: &str) -> Uuid {
    let section = papers
        .sections_for_chunking(paper_id, 1)
        .await
        .unwrap()
        .into_iter()
        .find(|section| section.kind == SectionKind::Method)
        .unwrap();
    let provider = DeterministicProvider::new(16).unwrap();
    let embedding = provider
        .embed(&EmbeddingRequest {
            inputs: vec![text.to_owned()],
        })
        .await
        .unwrap()
        .vectors
        .into_iter()
        .next()
        .unwrap();
    let chunk_id = Uuid::now_v7();
    papers
        .replace_chunks_and_publish(
            paper_id,
            1,
            &[(
                Chunk {
                    id: chunk_id,
                    paper_id,
                    section_id: section.id,
                    generation: 1,
                    ordinal: 0,
                    section_kind: section.kind,
                    section_heading: section.heading,
                    text: text.to_owned(),
                    page_start: section.page_start,
                    page_end: section.page_end,
                    token_count: text.split_whitespace().count(),
                },
                embedding,
            )],
            "deterministic-hash-v1-16",
        )
        .await
        .unwrap();
    chunk_id
}

async fn insert_assistant_document(database: &Database, paper_id: Uuid) -> Uuid {
    let block_id = Uuid::now_v7();
    let now = Utc::now();
    sqlx::query(
        r"
        INSERT INTO document_generations (
            paper_id, generation, arxiv_version, schema_version, parser_id,
            parser_version, document_hash, metadata_snapshot, metadata_hash,
            created_at, updated_at
        ) VALUES (
            $1, 1, 1, 'document.v1', 'grobid', 'api-feedback-v1', $2,
            jsonb_build_object('schema_version', 'paper-metadata-v1'), $2, $3, $3
        )
        ",
    )
    .bind(paper_id)
    .bind("a".repeat(64))
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO document_blocks (
            id, paper_id, generation, stable_key, ordinal, section_path,
            kind, text, content_hash, page_start, page_end, inline_spans, created_at
        ) VALUES (
            $1, $2, 1, 'results:p0', 0, ARRAY['Results'], 'paragraph',
            'The result is supported by the measured evidence.', $3,
            3, 3, '[]'::jsonb, $4
        )
        ",
    )
    .bind(block_id)
    .bind(paper_id)
    .bind("b".repeat(64))
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    block_id
}

fn assistant_request(paper_id: Uuid, session_id: Uuid) -> Request<Body> {
    let body = json!({
        "paper_id": paper_id,
        "generation": 1,
        "question": "What evidence supports the result?",
        "scope": {
            "kind": "paper",
            "section_kinds": [],
            "object_ids": [],
            "selection": null,
            "passport_field": null
        },
        "answer_style": "concise",
        "thread_id": null
    });
    connected_json_request(
        format!("/v1/papers/{paper_id}/assistant"),
        session_id,
        &body,
    )
}

fn assistant_feedback_request(paper_id: Uuid, session_id: Uuid, body: &Value) -> Request<Body> {
    connected_json_request(
        format!("/v1/papers/{paper_id}/assistant/feedback"),
        session_id,
        body,
    )
}

fn connected_json_request(uri: String, session_id: Uuid, body: &Value) -> Request<Body> {
    let mut request = Request::post(uri)
        .header(CONTENT_TYPE, "application/json")
        .header("x-session-id", session_id.to_string())
        .body(Body::from(body.to_string()))
        .unwrap();
    request.extensions_mut().insert(ConnectInfo(SocketAddr::new(
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        41_235,
    )));
    request
}

async fn response_json<T>(response: axum::response::Response) -> T
where
    T: serde::de::DeserializeOwned,
{
    let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}
