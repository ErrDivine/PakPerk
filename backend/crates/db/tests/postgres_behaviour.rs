use std::time::{Duration, Instant};

use chrono::{TimeDelta, Utc};
use db::{Database, PaperRepository};
use domain::{
    ArxivIdentifier, Author, Chunk, Connection, IntroductionDetection, PaperMetadata,
    ParsedCitationContext, ParsedPaper, ParsedParagraph, ParsedReference, ParsedSection,
    ProcessingStage, ReferenceResolutionStatus, RelationType, SectionKind,
};
use jobs::JobQueue;
use url::Url;
use uuid::Uuid;

/// Opt-in service integration coverage. It remains a normal (non-ignored) test:
/// developer machines without `PostgreSQL` skip it, while CI supplies
/// `TEST_DATABASE_URL` and exercises all assertions.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_prepare_leases_and_version_invalidation() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL behavior coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    database.ready().await.unwrap();

    let repository = database.papers();
    let unique = Uuid::now_v7().simple().to_string();
    let base_id = format!("test.{unique}");
    let metadata = metadata(&base_id, 1, Utc::now());
    let paper = repository.upsert_metadata(&metadata).await.unwrap();

    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..24 {
        let repository = repository.clone();
        tasks.spawn(async move { repository.prepare(paper.id, false).await.unwrap().unwrap() });
    }
    let mut enqueue_winners = 0;
    while let Some(result) = tasks.join_next().await {
        enqueue_winners += usize::from(result.unwrap().enqueued);
    }
    assert_eq!(
        enqueue_winners, 1,
        "exactly one concurrent prepare enqueues"
    );
    let job_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM jobs WHERE paper_id = $1 AND generation = 1")
            .bind(paper.id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(job_count, 1);

    let queue = JobQueue::new(database.pool().clone());
    let first = queue
        .claim("integration-a", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    sqlx::query("UPDATE jobs SET lease_expires_at = now() - interval '1 second' WHERE id = $1")
        .bind(first.id)
        .execute(database.pool())
        .await
        .unwrap();
    let recovered = queue
        .claim("integration-b", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(recovered.id, first.id);
    assert_eq!(recovered.attempt, 2);
    queue.complete(recovered.id, "integration-b").await.unwrap();

    repository
        .persist_parsed_document(
            paper.id,
            1,
            &parsed_document(),
            &["introduction".to_owned()],
            IntroductionDetection {
                confidence: 0.99,
                used_fallback: false,
            },
            "integration-parser",
        )
        .await
        .unwrap();
    assert!(repository.introduction(paper.id).await.unwrap().is_some());

    let mut second_version = metadata.clone();
    second_version.arxiv_id.version = 2;
    second_version.updated_at += TimeDelta::seconds(1);
    second_version.metadata_fetched_at += TimeDelta::seconds(1);
    repository.upsert_metadata(&second_version).await.unwrap();
    let invalidated = repository.processing(paper.id).await.unwrap().unwrap();
    assert_eq!(invalidated.generation, 2);
    assert_eq!(invalidated.stage, ProcessingStage::NotRequested);
    assert!(!invalidated.capabilities.introduction);
    assert!(repository.introduction(paper.id).await.unwrap().is_none());
    let retained_old_sections: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM paper_sections WHERE paper_id = $1 AND generation = 1",
    )
    .bind(paper.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        retained_old_sections, 2,
        "version invalidation retains both old-generation fixture sections"
    );

    repository.prepare(paper.id, false).await.unwrap();
    let current = queue
        .claim("integration-c", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    let mut third_version = second_version;
    third_version.arxiv_id.version = 3;
    third_version.updated_at += TimeDelta::seconds(1);
    third_version.metadata_fetched_at += TimeDelta::seconds(1);
    repository.upsert_metadata(&third_version).await.unwrap();
    let cancelled_state: String = sqlx::query_scalar("SELECT state FROM jobs WHERE id = $1")
        .bind(current.id)
        .fetch_one(database.pool())
        .await
        .unwrap();
    assert_eq!(cancelled_state, "cancelled");
    assert_eq!(
        repository
            .processing(paper.id)
            .await
            .unwrap()
            .unwrap()
            .generation,
        3
    );

    repository.prepare(paper.id, false).await.unwrap();
    let exhausted = queue
        .claim("integration-d", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    sqlx::query(
        "UPDATE jobs SET max_attempts = attempts, lease_expires_at = now() - interval '1 second' WHERE id = $1",
    )
    .bind(exhausted.id)
    .execute(database.pool())
    .await
    .unwrap();
    assert!(
        queue
            .claim("integration-e", Duration::from_secs(30))
            .await
            .unwrap()
            .is_none()
    );
    let exhausted_state = repository.processing(paper.id).await.unwrap().unwrap();
    assert_eq!(exhausted_state.stage, ProcessingStage::FailedRetryable);
    assert!(exhausted_state.retryable);
    let exhausted_started_at = exhausted_state.started_at;
    let exhausted_completed_at = exhausted_state.completed_at;

    // A late independent job must not erase the actionable failure before the
    // client explicitly retries the failed logical job.
    repository
        .set_stage(paper.id, 3, ProcessingStage::ResolvingReferences)
        .await
        .unwrap();
    let sticky_failure = repository.processing(paper.id).await.unwrap().unwrap();
    assert_eq!(sticky_failure.stage, ProcessingStage::FailedRetryable);
    assert!(sticky_failure.retryable);
    assert_eq!(sticky_failure.started_at, exhausted_started_at);
    assert_eq!(sticky_failure.completed_at, exhausted_completed_at);
    assert_eq!(
        sticky_failure
            .last_error
            .as_ref()
            .map(|error| error.code.as_str()),
        Some("LEASE_EXHAUSTED")
    );

    let retried = repository.prepare(paper.id, true).await.unwrap().unwrap();
    assert!(retried.enqueued);
    assert_eq!(retried.state.stage, ProcessingStage::Queued);
    assert!(!retried.state.retryable);
    let retry_claim = queue
        .claim("integration-f", Duration::from_secs(30))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(retry_claim.id, exhausted.id);
    assert_eq!(retry_claim.attempt, 1);
    queue
        .complete(retry_claim.id, "integration-f")
        .await
        .unwrap();

    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

/// Exercises database-native retrieval operators and capability publication
/// against stale-generation and foreign-paper decoys. The worker/API add a
/// second in-memory scope check, but the SQL boundary must independently avoid
/// returning either decoy.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_retrieval_and_connections_are_generation_scoped() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL retrieval coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    database.ready().await.unwrap();
    let repository = database.papers();
    let unique = Uuid::now_v7().simple().to_string();
    let source_base_id = format!("test.source.{unique}");
    let cited_base_id = format!("test.cited.{unique}");
    let now = Utc::now();

    let source_metadata_v1 = metadata(&source_base_id, 1, now);
    let source = repository
        .upsert_metadata(&source_metadata_v1)
        .await
        .unwrap();
    persist_document(&repository, source.id, 1, &parsed_document()).await;
    let stale_chunk = publish_chunk(
        &repository,
        source.id,
        1,
        "shared scope marker evidence from the stale generation",
    )
    .await;

    let cited_metadata = metadata(&cited_base_id, 1, now);
    let cited = repository.upsert_metadata(&cited_metadata).await.unwrap();
    assert_eq!(
        repository
            .get_by_arxiv_base(&cited_base_id)
            .await
            .unwrap()
            .unwrap()
            .id,
        cited.id
    );
    persist_document(&repository, cited.id, 1, &parsed_document()).await;
    let foreign_chunk = publish_chunk(
        &repository,
        cited.id,
        1,
        "shared scope marker evidence from a foreign paper",
    )
    .await;

    let mut source_metadata_v2 = source_metadata_v1;
    source_metadata_v2.arxiv_id.version = 2;
    source_metadata_v2.updated_at += TimeDelta::seconds(1);
    source_metadata_v2.metadata_fetched_at += TimeDelta::seconds(1);
    let updated_source = repository
        .upsert_metadata(&source_metadata_v2)
        .await
        .unwrap();
    assert_eq!(updated_source.id, source.id);
    assert_eq!(updated_source.metadata.arxiv_id.version, 2);
    let current_document =
        parsed_document_with_reference(&cited.metadata.title, &cited.metadata.arxiv_id.base_id);
    persist_document(&repository, source.id, 2, &current_document).await;
    let chunkable_sections = repository
        .sections_for_chunking(source.id, 2)
        .await
        .unwrap();
    assert!(
        chunkable_sections
            .iter()
            .any(|section| section.kind == SectionKind::Other),
        "substantive body sections with unrecognized headings must remain available to chat"
    );
    let current_chunk = publish_chunk(
        &repository,
        source.id,
        2,
        "shared scope marker evidence from the current generation",
    )
    .await;

    let decoy_count: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM paper_chunks
        WHERE id IN ($1, $2, $3)
        ",
    )
    .bind(stale_chunk)
    .bind(foreign_chunk)
    .bind(current_chunk)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(decoy_count, 3);

    let keyword = repository
        .keyword_candidates(source.id, 2, "shared scope marker evidence", 20)
        .await
        .unwrap();
    assert_eq!(keyword.len(), 1);
    assert_eq!(keyword[0].chunk.id, current_chunk);
    assert_eq!(keyword[0].chunk.paper_id, source.id);
    assert_eq!(keyword[0].chunk.generation, 2);

    let vector = repository
        .vector_candidates(source.id, 2, &[1.0, 0.0, 0.0], 20)
        .await
        .unwrap();
    assert_eq!(vector.len(), 1);
    assert_eq!(vector[0].chunk.id, current_chunk);
    assert_eq!(vector[0].chunk.paper_id, source.id);
    assert_eq!(vector[0].chunk.generation, 2);

    let references = repository.references(source.id, 2).await.unwrap();
    assert_eq!(references.len(), 1);
    let reference = &references[0];
    let contexts = repository.citation_contexts(reference.id).await.unwrap();
    assert_eq!(contexts.len(), 1);
    repository
        .update_reference_resolution(
            reference.id,
            ReferenceResolutionStatus::Resolved,
            Some(cited.id),
            Some(0.99),
            Some("integration_exact_arxiv"),
            Some(0.95),
        )
        .await
        .unwrap();
    repository
        .replace_connections_and_publish(
            source.id,
            2,
            &[Connection {
                id: Uuid::now_v7(),
                citing_paper_id: source.id,
                cited_paper_id: cited.id,
                reference_id: reference.id,
                generation: 2,
                relation_type: RelationType::Uses,
                summary: "The source paper uses the cited paper's retrieval method.".to_owned(),
                confidence: 0.93,
                source_context_ids: vec![contexts[0].id],
                model_id: Some("integration-relationship-model".to_owned()),
                prompt_version: Some("integration-relationship-v1".to_owned()),
            }],
            Some("integration-relationship-model"),
        )
        .await
        .unwrap();

    let processing = repository.processing(source.id).await.unwrap().unwrap();
    assert_eq!(processing.stage, ProcessingStage::Ready);
    assert!(processing.capabilities.all_ready());
    let connections = repository.connections(source.id).await.unwrap().unwrap();
    assert!(connections.ready);
    assert_eq!(connections.key_connections.len(), 1);
    assert_eq!(connections.key_connections[0].paper_id, cited.id);
    assert_eq!(
        connections.key_connections[0].relation_type,
        RelationType::Uses
    );
    assert_eq!(connections.references.len(), 1);
    assert!(connections.references[0].resolved);
    assert_eq!(connections.references[0].paper_id, Some(cited.id));

    let metrics = repository
        .verification_metrics(source.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(metrics.chat_chunk_count, 1);
    assert_eq!(metrics.resolved_reference_count, 1);
    assert_eq!(metrics.key_connection_count, 1);
    assert_eq!(metrics.resolved_arxiv_base_ids, [cited_base_id]);

    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(source.id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(cited.id)
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
async fn postgres_arxiv_gate_preserves_and_waits_for_shared_cooldown() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL arXiv gate coverage");
        return;
    };
    let database = Database::connect(&database_url, 4).await.unwrap();
    database.migrate_embedded().await.unwrap();
    database.ready().await.unwrap();
    let repository = database.papers();

    let long_block: chrono::DateTime<Utc> = sqlx::query_scalar(
        r"
        UPDATE external_rate_limits
        SET last_started_at = '1970-01-01T00:00:00Z'::timestamptz,
            blocked_until = now() + interval '10 seconds'
        WHERE service = 'arxiv'
        RETURNING blocked_until
        ",
    )
    .fetch_one(database.pool())
    .await
    .unwrap();
    repository
        .defer_arxiv_requests(Duration::from_secs(1))
        .await
        .unwrap();
    let preserved: chrono::DateTime<Utc> = sqlx::query_scalar(
        "SELECT blocked_until FROM external_rate_limits WHERE service = 'arxiv'",
    )
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(preserved, long_block, "a shorter cooldown must not win");

    sqlx::query(
        r"
        UPDATE external_rate_limits
        SET last_started_at = '1970-01-01T00:00:00Z'::timestamptz,
            blocked_until = '1970-01-01T00:00:00Z'::timestamptz
        WHERE service = 'arxiv'
        ",
    )
    .execute(database.pool())
    .await
    .unwrap();
    repository
        .defer_arxiv_requests(Duration::from_millis(150))
        .await
        .unwrap();
    let started = Instant::now();
    repository
        .reserve_arxiv_request(Duration::ZERO)
        .await
        .unwrap();
    let elapsed = started.elapsed();
    sqlx::query(
        r"
        UPDATE external_rate_limits
        SET last_started_at = '1970-01-01T00:00:00Z'::timestamptz,
            blocked_until = '1970-01-01T00:00:00Z'::timestamptz
        WHERE service = 'arxiv'
        ",
    )
    .execute(database.pool())
    .await
    .unwrap();
    assert!(
        elapsed >= Duration::from_millis(100),
        "shared cooldown was bypassed after {elapsed:?}"
    );
}

async fn persist_document(
    repository: &PaperRepository,
    paper_id: Uuid,
    generation: i32,
    document: &ParsedPaper,
) {
    repository
        .persist_parsed_document(
            paper_id,
            generation,
            document,
            &["introduction".to_owned()],
            IntroductionDetection {
                confidence: 0.99,
                used_fallback: false,
            },
            "integration-parser",
        )
        .await
        .unwrap();
}

async fn publish_chunk(
    repository: &PaperRepository,
    paper_id: Uuid,
    generation: i32,
    text: &str,
) -> Uuid {
    let section = repository
        .sections_for_chunking(paper_id, generation)
        .await
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    let chunk_id = Uuid::now_v7();
    repository
        .replace_chunks_and_publish(
            paper_id,
            generation,
            &[(
                Chunk {
                    id: chunk_id,
                    paper_id,
                    section_id: section.id,
                    generation,
                    ordinal: 0,
                    section_kind: section.kind,
                    section_heading: section.heading,
                    text: text.to_owned(),
                    page_start: section.page_start,
                    page_end: section.page_end,
                    token_count: text.split_whitespace().count(),
                },
                vec![1.0, 0.0, 0.0],
            )],
            "integration-embedding-model",
        )
        .await
        .unwrap();
    chunk_id
}

fn metadata(base_id: &str, version: u32, fetched_at: chrono::DateTime<Utc>) -> PaperMetadata {
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version,
        },
        title: format!("Integration Paper {base_id}"),
        abstract_text: "A database integration test paper.".to_owned(),
        authors: vec![Author {
            name: "Ada Tester".to_owned(),
        }],
        primary_category: "cs.AI".to_owned(),
        categories: vec!["cs.AI".to_owned()],
        published_at: fetched_at - TimeDelta::days(1),
        updated_at: fetched_at,
        abs_url: Url::parse("https://arxiv.org/abs/2401.00001v1").unwrap(),
        pdf_url: Url::parse("https://arxiv.org/pdf/2401.00001v1").unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: fetched_at,
    }
}

fn parsed_document() -> ParsedPaper {
    ParsedPaper {
        title: Some("Integration Paper".to_owned()),
        sections: vec![
            ParsedSection {
                source_id: "introduction".to_owned(),
                ordinal: 0,
                parent_source_id: None,
                kind: SectionKind::Introduction,
                heading: Some("1 Introduction".to_owned()),
                paragraphs: vec![ParsedParagraph {
                    ordinal: 0,
                    text: "This is a persisted introduction paragraph with enough content for the integration behavior test.".to_owned(),
                    citations: Vec::new(),
                    page_start: Some(1),
                    page_end: Some(1),
                }],
                page_start: Some(1),
                page_end: Some(1),
            },
            ParsedSection {
                source_id: "unrecognized-body-section".to_owned(),
                ordinal: 1,
                parent_source_id: None,
                kind: SectionKind::Other,
                heading: Some("Named System Component".to_owned()),
                paragraphs: vec![ParsedParagraph {
                    ordinal: 0,
                    text: "This substantive body section has a paper-specific heading and must still be indexed for grounded chat.".to_owned(),
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
    }
}

fn parsed_document_with_reference(cited_title: &str, cited_arxiv_id: &str) -> ParsedPaper {
    let mut document = parsed_document();
    document.references.push(ParsedReference {
        source_id: "reference-1".to_owned(),
        ordinal: 0,
        raw_text: format!("Ada Tester. {cited_title}. 2024."),
        title: Some(cited_title.to_owned()),
        authors: vec!["Ada Tester".to_owned()],
        year: Some(2024),
        doi: None,
        url: None,
        arxiv_id: Some(cited_arxiv_id.to_owned()),
    });
    document.citation_contexts.push(ParsedCitationContext {
        reference_source_id: "reference-1".to_owned(),
        section_source_id: "introduction".to_owned(),
        section_kind: SectionKind::Introduction,
        section_heading: Some("1 Introduction".to_owned()),
        context_text: "We use the cited retrieval method as the basis of our system.".to_owned(),
        page_number: Some(1),
        occurrence_ordinal: 0,
    });
    document
}
