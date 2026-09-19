use std::sync::{Arc, Mutex};

use domain::{
    AssistantAnswerStyle, AssistantObjectKind, AssistantRequest, AssistantScope,
    AssistantScopeKind, AssistantTextSelection, AssistantTool, CitationEvidence, ObjectEvidence,
    PaperOutline, ReadPaperBlocks, SearchPaperEvidence,
};

use super::*;

async fn database() -> Option<(Database, String)> {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL assistant tools coverage");
        return None;
    };
    let database = Database::connect(&url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    Some((database, url))
}

fn request(paper_id: Uuid) -> AssistantRequest {
    AssistantRequest {
        paper_id,
        generation: 1,
        question: "Explain the experiment.".into(),
        scope: AssistantScope {
            kind: AssistantScopeKind::Paper,
            section_kinds: vec![],
            object_ids: vec![],
            selection: None,
            passport_field: None,
        },
        answer_style: AssistantAnswerStyle::Concise,
        thread_id: None,
    }
}

async fn paper(database: &Database) -> (Uuid, Uuid) {
    let paper = database
        .papers()
        .upsert_metadata(&metadata(
            &format!("test.tools.{}", Uuid::now_v7().simple()),
            "Tools fixture",
        ))
        .await
        .unwrap();
    let block = insert_assistant_document(database, paper.id).await;
    (paper.id, block)
}

async fn block(database: &Database, paper_id: Uuid, ordinal: i32, text: &str, kind: &str) -> Uuid {
    let id = Uuid::now_v7();
    sqlx::query("INSERT INTO document_blocks (id,paper_id,generation,stable_key,ordinal,section_path,kind,text,content_hash,page_start)
        VALUES ($1,$2,1,$3,$4,ARRAY['Results'],$5,$6,$7,3)")
        .bind(id).bind(paper_id).bind(format!("block:{ordinal}")).bind(ordinal).bind(kind).bind(text)
        .bind(domain::content_hash(text)).execute(database.pool()).await.unwrap();
    id
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn five_tools_read_exact_sources_and_reject_foreign_or_stale_data() {
    let Some((database, _)) = database().await else {
        return;
    };
    let (paper_id, first) = paper(&database).await;
    let (foreign_id, foreign_block) = paper(&database).await;
    let heading = block(&database, paper_id, 1, "Azimuth experiments", "heading").await;
    let evidence = block(
        &database,
        paper_id,
        2,
        "The azimuth is measured. 界🙂",
        "paragraph",
    )
    .await;
    let oversized = block(&database, paper_id, 3, &"x".repeat(20_001), "paragraph").await;
    let equation = Uuid::now_v7();
    sqlx::query("INSERT INTO paper_equations (id,paper_id,generation,ordinal,plain_text,context_block_id,content_hash)
        VALUES ($1,$2,1,0,'x = 1',$3,$4)").bind(equation).bind(paper_id).bind(evidence).bind("a".repeat(64))
        .execute(database.pool()).await.unwrap();
    let reference = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO paper_references (id,citing_paper_id,generation,ordinal,raw_text)
        VALUES ($1,$2,1,0,'An earlier measurement method')",
    )
    .bind(reference)
    .bind(paper_id)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query("UPDATE document_blocks SET inline_spans = $1 WHERE id = $2")
        .bind(
            json!([{"kind":"bibliography_reference","target_id":reference,"start":0,"end":3},
            {"kind":"equation_reference","target_id":equation,"start":4,"end":11}]),
        )
        .bind(evidence)
        .execute(database.pool())
        .await
        .unwrap();
    let repository = database.assistant_context();
    let mut request = request(paper_id);
    let search = AssistantTool::SearchPaperEvidence(SearchPaperEvidence {
        query: "azimuth".into(),
        section_kinds: vec![],
        limit: 6,
    });
    let result = repository.execute_tool(&request, &search).await.unwrap();
    assert_eq!(result.status, "ok");
    assert_eq!(result.sources.len(), 2);
    assert!(
        result
            .sources
            .iter()
            .all(|source| source.paper_id == paper_id)
    );
    let empty = repository
        .execute_tool(
            &request,
            &AssistantTool::SearchPaperEvidence(SearchPaperEvidence {
                query: "absentword".into(),
                section_kinds: vec![],
                limit: 6,
            }),
        )
        .await
        .unwrap();
    assert!(empty.sources.is_empty());
    assert_eq!(empty.status, "no_matches");
    let outline = repository
        .execute_tool(
            &request,
            &AssistantTool::GetPaperOutline(PaperOutline { limit: 1 }),
        )
        .await
        .unwrap();
    assert_eq!(outline.sources[0].block_id, heading);
    let read = |ids| {
        AssistantTool::ReadPaperBlocks(ReadPaperBlocks {
            block_ids: ids,
            neighbors: 0,
        })
    };
    assert!(
        repository
            .execute_tool(&request, &read(vec![evidence, foreign_block]))
            .await
            .is_err()
    );
    let result = repository
        .execute_tool(&request, &read(vec![oversized]))
        .await
        .unwrap();
    assert_eq!(result.status, "content_too_large");
    assert!(result.sources[0].text.is_none());
    let objects = repository
        .execute_tool(
            &request,
            &AssistantTool::GetObjectEvidence(ObjectEvidence {
                object_id: equation,
                kind: AssistantObjectKind::Equation,
            }),
        )
        .await
        .unwrap();
    assert_eq!(objects.sources[0].block_id, evidence);
    assert_eq!(objects.object_status.as_deref(), Some("supported"));
    let citations = repository
        .execute_tool(
            &request,
            &AssistantTool::GetCitationContext(CitationEvidence {
                reference_id: reference,
                limit: 4,
            }),
        )
        .await
        .unwrap();
    assert_eq!(citations.sources[0].block_id, evidence);
    assert_eq!(
        citations.sources[0].text.as_deref(),
        Some("The azimuth is measured. 界🙂")
    );
    request.scope = AssistantScope {
        kind: AssistantScopeKind::Selection,
        section_kinds: vec![],
        object_ids: vec![],
        passport_field: None,
        selection: Some(AssistantTextSelection {
            block_id: evidence,
            start: 24,
            end: 26,
        }),
    };
    let neighbors = repository
        .execute_tool(
            &request,
            &AssistantTool::ReadPaperBlocks(ReadPaperBlocks {
                block_ids: vec![evidence],
                neighbors: 1,
            }),
        )
        .await
        .unwrap();
    assert_eq!(neighbors.sources.len(), 1);
    let mut invalid_selection = request.clone();
    invalid_selection.scope.selection.as_mut().unwrap().end = 50_000;
    assert!(
        repository
            .execute_tool(&invalid_selection, &read(vec![evidence]))
            .await
            .is_err()
    );
    assert!(
        repository
            .execute_tool(&request, &read(vec![first]))
            .await
            .is_err()
    );
    assert!(
        repository
            .execute_tool(
                &request,
                &AssistantTool::GetPaperOutline(PaperOutline { limit: 20 })
            )
            .await
            .is_err()
    );
    // An adjacent block must not expand a section-limited request.
    let section_id = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO paper_sections (id,paper_id,generation,ordinal,heading,kind,text,visible_in_app)
        VALUES ($1,$2,1,0,'Results','result','The azimuth is measured.',true)",
    )
    .bind(section_id)
    .bind(paper_id)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query("UPDATE document_blocks SET section_id = $1 WHERE id = $2")
        .bind(section_id)
        .bind(evidence)
        .execute(database.pool())
        .await
        .unwrap();
    request.scope = AssistantScope {
        kind: AssistantScopeKind::Section,
        section_kinds: vec![SectionKind::Result],
        object_ids: vec![],
        selection: None,
        passport_field: None,
    };
    let section_sources = repository
        .execute_tool(
            &request,
            &AssistantTool::ReadPaperBlocks(ReadPaperBlocks {
                block_ids: vec![evidence],
                neighbors: 1,
            }),
        )
        .await
        .unwrap();
    assert_eq!(section_sources.sources.len(), 1);
    assert_eq!(section_sources.sources[0].block_id, evidence);
    assert!(
        repository
            .execute_tool(&request, &read(vec![heading]))
            .await
            .is_err()
    );
    request.paper_id = foreign_id;
    assert!(
        repository
            .execute_tool(&request, &read(vec![evidence]))
            .await
            .is_err()
    );
    request.paper_id = paper_id;
    request.generation = 2;
    assert!(matches!(
        repository.execute_tool(&request, &search).await,
        Err(db::DbError::AssistantContextNotReady)
    ));
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn tool_search_then_read_persists_new_evidence_and_preserves_original_question() {
    let Some((database, database_url)) = database().await else {
        return;
    };
    let (paper_id, _) = paper(&database).await;
    for ordinal in 1..5 {
        block(
            &database,
            paper_id,
            ordinal,
            "General experiment background.",
            "paragraph",
        )
        .await;
    }
    let source_text = "The azimuth is measured.";
    let evidence = block(&database, paper_id, 5, source_text, "paragraph").await;
    let question = "Explain the experiment.";
    let source = database
        .assistant_context()
        .retrieve(&request(paper_id))
        .await
        .unwrap();
    assert!(
        !source
            .blocks
            .iter()
            .take(4)
            .any(|block| block.block_id == evidence)
    );
    let responses = Arc::new(Mutex::new(Vec::<Value>::new()));
    let captured = responses.clone();
    let handler = move |axum::Json(body): axum::Json<Value>| {
        let captured = captured.clone();
        async move {
            let mut requests = captured.lock().unwrap();
            let index = requests.len();
            requests.push(body);
            let message = match index {
                0 => json!({"finish_reason":"tool_calls", "message":{"content":null,"tool_calls":[{
                    "id":"call_search","type":"function","function":{"name":"search_paper_evidence","arguments":r#"{"query":"azimuth"}"#},
                }]}}),
                1 => json!({"finish_reason":"tool_calls", "message":{"tool_calls":[{
                    "id":"call_read","type":"function","function":{"name":"read_paper_blocks","arguments":json!({"block_ids":[evidence]}).to_string()},
                }]}}),
                _ => json!({"finish_reason":"stop","message":{"content":json!({
                    "answer":source_text,"status":"supported","limitations":[],
                    "claims":[{"text":source_text,"support":"direct","evidence":[{"block_id":evidence,"start":0,"end":23}]}],
                }).to_string()}}),
            };
            axum::Json(
                json!({"id":"fixture-request","model":"fixture-chat", "choices":[message],
                "usage":{"prompt_tokens":10,"completion_tokens":5}}),
            )
        }
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            axum::Router::new().route("/v1/chat/completions", axum::routing::post(handler)),
        )
        .await
        .unwrap();
    });
    let mut config = api_config(database_url);
    config.features = FeatureFlags {
        deep_reader: true,
        assistant_v2: true,
        assistant_tools: true,
        ..FeatureFlags::default()
    };
    config.chat_request_timeout = Duration::from_secs(55);
    config.llm = Some(ApiModelConfig::OpenAiCompatible(Box::new(
        llm_provider::OpenAiCompatibleConfig {
            base_url: Url::parse(&format!("http://{address}/v1")).unwrap(),
            chat_model: "fixture-chat".into(),
            embedding_model: "fixture-embedding".into(),
            embedding_dimension: 16,
            maximum_retries: 0,
            ..llm_provider::OpenAiCompatibleConfig::default()
        },
    )));
    let app = build_router(AppState::new(database.clone(), &config).unwrap(), &config);
    let principal = Uuid::now_v7();
    let response = app
        .oneshot(connected_json_request(
            format!("/v1/papers/{paper_id}/assistant"),
            principal,
            &serde_json::to_value(request(paper_id)).unwrap(),
        ))
        .await
        .unwrap();
    let status = response.status();
    let body: Value = response_json(response).await;
    server.abort();
    assert_eq!(status, StatusCode::OK, "{body}");
    let requests = responses.lock().unwrap().clone();
    assert_eq!(requests.len(), 3);
    let final_request = &requests[2];
    assert!(final_request.get("tools").is_none());
    let final_input = final_request["messages"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()["content"]
        .as_str()
        .unwrap();
    assert!(final_input.contains(question));
    assert!(final_input.contains(&evidence.to_string()));
    let provenance_id: Uuid = body["provenance_id"].as_str().unwrap().parse().unwrap();
    let provenance = database
        .assistant_context()
        .provenance(
            domain::ProvenancePrincipal::AnonymousSession(principal),
            provenance_id,
        )
        .await
        .unwrap()
        .unwrap();
    assert!(provenance.input_entity_ids.contains(&evidence));
    let saved_question: String = sqlx::query_scalar(
        "SELECT content FROM assistant_messages WHERE thread_id = $1 AND role = 'user'",
    )
    .bind(body["thread_id"].as_str().unwrap().parse::<Uuid>().unwrap())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(saved_question, question);
    assert!(
        body["prompt_version"]
            .as_str()
            .unwrap()
            .contains("paper-assistant-tools-v1")
    );
}

#[tokio::test]
async fn deletion_accepted_during_inference_prevents_exchange_publication() {
    let Some((database, _)) = database().await else {
        return;
    };
    let (paper_id, _) = paper(&database).await;
    let request = request(paper_id);
    let owner = Uuid::now_v7();
    sqlx::query("INSERT INTO users (id,oidc_issuer,oidc_subject) VALUES ($1,'assistant-test',$2)")
        .bind(owner)
        .bind(owner.to_string())
        .execute(database.pool())
        .await
        .unwrap();
    let principal = domain::ProvenancePrincipal::OwnerUser(owner);
    let repository = database.assistant_context();
    let context = repository.retrieve(&request).await.unwrap();
    let session = repository.open_thread(principal, &request).await.unwrap();
    let answer = domain::AssistantAnswer {
        answer: domain::ASSISTANT_NOT_FOUND_ANSWER.into(),
        status: domain::AssistantAnswerStatus::NotFound,
        claims: vec![],
        limitations: vec![],
        provenance_id: Uuid::now_v7(),
        model_id: Some("fixture".into()),
        provider_request_id: None,
        prompt_version: "paper-assistant-tools-v1".into(),
    };
    sqlx::query("UPDATE users SET status = 'deletion_pending' WHERE id = $1")
        .bind(owner)
        .execute(database.pool())
        .await
        .unwrap();
    assert!(matches!(
        repository
            .persist_exchange(
                principal,
                &request,
                session.thread_id,
                &context,
                &answer,
                "fixture"
            )
            .await,
        Err(db::DbError::InvalidAssistantThread)
    ));
    let count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM assistant_messages WHERE thread_id = $1")
            .bind(session.thread_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(count, 0);
    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM provenance_records WHERE id = $1)")
            .bind(answer.provenance_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert!(!exists);
}
