use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    time::Duration,
};

use arxiv_client::ArxivClientConfig;
use axum::{
    body::{Body, to_bytes},
    extract::ConnectInfo,
    http::{Request, StatusCode, header::CONTENT_TYPE},
};
use chrono::{TimeDelta, Utc};
use db::{Database, PaperRepository};
use domain::{
    ArxivIdentifier, Author, Chunk, ConnectionsResponse, FulltextPolicy, Introduction,
    IntroductionDetection, PaperMetadata, ParsedPaper, ParsedParagraph, ParsedSection, SectionKind,
};
use llm_provider::{DeterministicProvider, EmbeddingProvider, EmbeddingRequest};
use pakperk_api::{
    ApiConfig, ApiEnvironment, ApiModelConfig, AppState, FeatureFlags, build_router,
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

async fn response_json<T>(response: axum::response::Response) -> T
where
    T: serde::de::DeserializeOwned,
{
    let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}
