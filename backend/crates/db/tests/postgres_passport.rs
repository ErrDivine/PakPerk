use chrono::{TimeDelta, Utc};
use db::{ArtifactPersistOutcome, Database, DbError, FeedbackEvaluationOutcome};
use domain::{
    ArtifactConfidenceStatus, ArxivIdentifier, Author, DOCUMENT_SCHEMA_VERSION,
    PAPER_PASSPORT_SCHEMA_VERSION, PaperMetadata, PaperPassport, PassportFeedback,
    PassportFeedbackType, PassportField, PassportFieldKey, PassportFieldStatus, PassportStatus,
    ProvenanceActivityType, ProvenanceArtifactType, ProvenanceParameters, ProvenancePrincipal,
    ProvenanceRecord, SEMANTIC_FACET_SCHEMA_VERSION, SemanticDensity, SemanticFacet, SemanticSpan,
    SemanticSpanSourceKind, SemanticSupportStatus, content_hash,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_passport_artifacts_are_source_linked_and_generation_safe() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL Passport coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let base_id = format!("passport.{unique}");
    let now = Utc::now();
    let papers = database.papers();
    let paper = papers
        .upsert_metadata(&metadata(&base_id, 1, now))
        .await
        .unwrap();
    let block_id = Uuid::now_v7();
    let block_text = "A🦀B supports the queue-first result.";
    insert_document_generation(&database, paper.id, block_id, block_text, now).await;

    let repository = database.passports();
    let semantic_provenance = shared_provenance(
        Uuid::now_v7(),
        ProvenanceArtifactType::SemanticSpans,
        Uuid::now_v7(),
        ProvenanceActivityType::SemanticClassification,
        paper.id,
        1,
        vec![block_id],
        SEMANTIC_FACET_SCHEMA_VERSION,
        now,
    );
    let valid_span = SemanticSpan {
        id: Uuid::now_v7(),
        paper_id: paper.id,
        generation: 1,
        block_id,
        ordinal: 0,
        start_offset: 1,
        end_offset: 2,
        facet: SemanticFacet::Evidence,
        minimum_density: SemanticDensity::Key,
        source_kind: SemanticSpanSourceKind::Deterministic,
        confidence_basis_points: 9_500,
        support_status: SemanticSupportStatus::Supported,
        provenance_id: semantic_provenance.id,
        created_at: now,
    };
    let mut invalid_span = valid_span.clone();
    invalid_span.end_offset = 100;
    assert!(matches!(
        repository
            .replace_semantic_spans(
                paper.id,
                1,
                &semantic_provenance,
                &[invalid_span],
                SEMANTIC_FACET_SCHEMA_VERSION,
            )
            .await,
        Err(DbError::InvalidData(_))
    ));
    assert_eq!(
        repository
            .replace_semantic_spans(
                paper.id,
                1,
                &semantic_provenance,
                std::slice::from_ref(&valid_span),
                SEMANTIC_FACET_SCHEMA_VERSION,
            )
            .await
            .unwrap(),
        ArtifactPersistOutcome::Inserted
    );
    let semantic = repository
        .current_semantic_spans(paper.id, Some(block_id), SemanticDensity::Key)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(semantic.generation, 1);
    assert_eq!(semantic.spans, [valid_span]);
    assert_eq!(
        semantic.provenance.as_slice(),
        std::slice::from_ref(&semantic_provenance)
    );
    assert!(
        repository
            .current_semantic_spans(paper.id, Some(Uuid::now_v7()), SemanticDensity::Key)
            .await
            .is_err()
    );

    let (passport, passport_provenance) = passport_fixture(paper.id, block_id, now);
    assert_eq!(
        repository
            .publish_passport(
                &passport,
                &passport_provenance,
                PAPER_PASSPORT_SCHEMA_VERSION,
            )
            .await
            .unwrap(),
        ArtifactPersistOutcome::Inserted
    );
    assert_eq!(
        repository
            .publish_passport(
                &passport,
                &passport_provenance,
                PAPER_PASSPORT_SCHEMA_VERSION,
            )
            .await
            .unwrap(),
        ArtifactPersistOutcome::Unchanged
    );
    let current = repository
        .current_passport(paper.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(current.passport.id, passport.id);
    assert_eq!(
        current
            .passport
            .fields
            .iter()
            .map(|field| (field.key, field.id))
            .collect::<Vec<_>>(),
        passport
            .fields
            .iter()
            .map(|field| (field.key, field.id))
            .collect::<Vec<_>>()
    );
    assert!(
        repository
            .shared_provenance(Uuid::now_v7(), passport.provenance_id)
            .await
            .unwrap()
            .is_none()
    );
    assert_eq!(
        repository
            .shared_provenance(paper.id, passport.provenance_id)
            .await
            .unwrap()
            .unwrap()
            .artifact_id,
        passport.id
    );

    let supported_field = passport
        .fields
        .iter()
        .find(|field| field.key == PassportFieldKey::ResearchQuestion)
        .unwrap();
    let feedback = PassportFeedback {
        operation_id: Uuid::now_v7(),
        passport_id: passport.id,
        field_id: Some(supported_field.id),
        feedback_type: PassportFeedbackType::WrongEvidence,
        detail: Some("The cited block does not support this compression.".to_owned()),
    };
    let principal = ProvenancePrincipal::AnonymousSession(Uuid::now_v7());
    let inserted_feedback = repository
        .record_passport_feedback(paper.id, 1, principal, &feedback)
        .await
        .unwrap();
    let replayed_feedback = repository
        .record_passport_feedback(paper.id, 1, principal, &feedback)
        .await
        .unwrap();
    let FeedbackEvaluationOutcome::Inserted(feedback_id) = inserted_feedback else {
        panic!("first feedback write must insert");
    };
    assert_eq!(
        replayed_feedback,
        FeedbackEvaluationOutcome::Replayed(feedback_id)
    );
    let feedback_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM paper_passport_feedback_evaluations WHERE passport_id = $1",
    )
    .bind(passport.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(feedback_count, 1);
    let after_feedback = repository
        .current_passport(paper.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after_feedback.passport, current.passport);

    let mut version_two = metadata(&base_id, 2, now + TimeDelta::seconds(1));
    version_two.published_at = now - TimeDelta::days(1);
    papers.upsert_metadata(&version_two).await.unwrap();
    assert!(
        repository
            .current_passport(paper.id)
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        repository
            .current_semantic_spans(paper.id, None, SemanticDensity::Detailed)
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        repository
            .shared_provenance(paper.id, passport.provenance_id)
            .await
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        repository
            .record_passport_feedback(
                paper.id,
                1,
                principal,
                &PassportFeedback {
                    operation_id: Uuid::now_v7(),
                    ..feedback
                }
            )
            .await,
        Err(DbError::StaleGeneration)
    ));
    let retained_fields: i64 =
        sqlx::query_scalar("SELECT count(*) FROM paper_passport_fields WHERE passport_id = $1")
            .bind(passport.id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(retained_fields, 10);

    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

async fn insert_document_generation(
    database: &Database,
    paper_id: Uuid,
    block_id: Uuid,
    block_text: &str,
    now: chrono::DateTime<Utc>,
) {
    sqlx::query(
        r"
        INSERT INTO document_generations (
            paper_id, generation, arxiv_version, schema_version, parser_id, parser_version,
            document_hash, metadata_snapshot, metadata_hash, created_at, updated_at
        ) VALUES (
            $1, 1, 1, $2, 'grobid', 'passport-integration-v1', $3,
            jsonb_build_object('schema_version', 'paper-metadata-v1'), $3, $4, $4
        )
        ",
    )
    .bind(paper_id)
    .bind(DOCUMENT_SCHEMA_VERSION)
    .bind(content_hash("passport-document"))
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
            $3, $4, 2, 2, '[]'::jsonb, $5
        )
        ",
    )
    .bind(block_id)
    .bind(paper_id)
    .bind(block_text)
    .bind(content_hash(block_text))
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
}

fn passport_fixture(
    paper_id: Uuid,
    block_id: Uuid,
    now: chrono::DateTime<Utc>,
) -> (PaperPassport, Vec<ProvenanceRecord>) {
    let passport_id = Uuid::now_v7();
    let passport_provenance_id = Uuid::now_v7();
    let mut provenance = vec![shared_provenance(
        passport_provenance_id,
        ProvenanceArtifactType::PaperPassport,
        passport_id,
        ProvenanceActivityType::PassportSynthesis,
        paper_id,
        1,
        vec![block_id],
        PAPER_PASSPORT_SCHEMA_VERSION,
        now,
    )];
    let fields = PassportFieldKey::ALL
        .into_iter()
        .map(|key| {
            let id = Uuid::now_v7();
            let provenance_id = Uuid::now_v7();
            let supported = key == PassportFieldKey::ResearchQuestion;
            let source_block_ids = if supported {
                vec![block_id]
            } else {
                Vec::new()
            };
            provenance.push(shared_provenance(
                provenance_id,
                ProvenanceArtifactType::PaperPassportField,
                id,
                ProvenanceActivityType::PassportSynthesis,
                paper_id,
                1,
                source_block_ids.clone(),
                PAPER_PASSPORT_SCHEMA_VERSION,
                now,
            ));
            PassportField {
                id,
                key,
                value_text: supported.then(|| "What result does the paper support?".to_owned()),
                value_json: None,
                status: if supported {
                    PassportFieldStatus::Supported
                } else {
                    PassportFieldStatus::NotFound
                },
                source_block_ids,
                confidence_status: if supported {
                    ArtifactConfidenceStatus::Supported
                } else {
                    ArtifactConfidenceStatus::Uncertain
                },
                provenance_id,
                created_at: now,
            }
        })
        .collect();
    (
        PaperPassport {
            id: passport_id,
            paper_id,
            generation: 1,
            schema_version: PAPER_PASSPORT_SCHEMA_VERSION.to_owned(),
            status: PassportStatus::Partial,
            parser_id: "grobid".to_owned(),
            model_id: None,
            prompt_version: None,
            provenance_id: passport_provenance_id,
            fields,
            created_at: now,
            updated_at: now,
        },
        provenance,
    )
}

#[allow(clippy::too_many_arguments)]
fn shared_provenance(
    id: Uuid,
    artifact_type: ProvenanceArtifactType,
    artifact_id: Uuid,
    activity_type: ProvenanceActivityType,
    paper_id: Uuid,
    generation: i32,
    input_entity_ids: Vec<Uuid>,
    schema_version: &str,
    created_at: chrono::DateTime<Utc>,
) -> ProvenanceRecord {
    ProvenanceRecord {
        id,
        artifact_type,
        artifact_id,
        paper_id,
        generation,
        activity_type,
        parser_id: Some("grobid".to_owned()),
        parser_version: Some("passport-integration-v1".to_owned()),
        model_provider: None,
        model_id: None,
        prompt_or_schema_version: Some(schema_version.to_owned()),
        input_entity_ids,
        parameters: ProvenanceParameters::default(),
        principal: None,
        created_at,
        superseded_by: None,
    }
}

fn metadata(base_id: &str, version: u32, fetched_at: chrono::DateTime<Utc>) -> PaperMetadata {
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version,
        },
        title: format!("Passport fixture v{version}"),
        abstract_text: "A source-linked Passport integration fixture.".to_owned(),
        authors: vec![Author::from("Ada Tester".to_owned())],
        primary_category: "cs.AI".to_owned(),
        categories: vec!["cs.AI".to_owned()],
        published_at: fetched_at - TimeDelta::days(1),
        updated_at: fetched_at,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v{version}")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v{version}")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: fetched_at,
    }
}
