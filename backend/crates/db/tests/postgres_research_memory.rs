use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{TimeDelta, Utc};
use db::{
    AssistantEvidenceFeedbackOutcome, Database, LibraryMutationIntent, LibraryMutationOutcome,
    ResearchAnnotationImport, ResearchAnnotationImportOutcome, ResearchMutationOutcome,
    ResearchReadOutcome,
};
use domain::{
    AnnotationColorRole, AnnotationConflictResolution, AnnotationKind, AnnotationWrite,
    ArxivIdentifier, AssistantEvidenceFeedback, AssistantEvidenceFeedbackType, Author,
    EvidenceCardWrite, EvidenceVerificationStatus, LibraryState, MemoryItemWrite, MemorySourceType,
    MemoryStatus, PaperMetadata, ProvenancePrincipal, ReaderMode, ReaderStage,
    ReadingCheckpointWrite, TextQuotePositionSelector,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_private_research_artifacts_preserve_conflicts_and_library_authority() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL research-memory coverage");
        return;
    };
    let database = Database::connect(&database_url, 16)
        .await
        .unwrap()
        .with_cursor_codec(test_cursor_codec());
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://research-memory.test/{unique}");
    let owner = database
        .accounts()
        .provision_oidc_identity(&issuer, "owner", Duration::from_secs(900))
        .await
        .unwrap();
    let other = database
        .accounts()
        .provision_oidc_identity(&issuer, "other", Duration::from_secs(900))
        .await
        .unwrap();
    let now = Utc::now();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("research.{unique}"), now))
        .await
        .unwrap();
    let block_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO document_generations (
            paper_id, generation, arxiv_version, schema_version, parser_id, parser_version,
            document_hash, metadata_snapshot, metadata_hash, created_at, updated_at
        ) VALUES (
            $1, 1, 1, 'document.v1', 'grobid', 'integration-v1', $2,
            jsonb_build_object('schema_version', 'paper-metadata-v1'), $2, $3, $3
        )
        ",
    )
    .bind(paper.id)
    .bind("1".repeat(64))
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
            $1, $2, 1, 'methods:p0', 0, ARRAY['Methods'], 'paragraph',
            'Methods support this result.', $3, 2, 2, '[]'::jsonb, $4
        )
        ",
    )
    .bind(block_id)
    .bind(paper.id)
    .bind("2".repeat(64))
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();

    let library_result = database
        .library()
        .mutate(
            owner.id,
            paper.id,
            Uuid::now_v7(),
            LibraryMutationIntent::Save,
            LibraryState::Reading,
        )
        .await
        .unwrap();
    assert!(matches!(
        library_result,
        LibraryMutationOutcome::Applied { .. }
    ));
    let library_before = library_snapshot(&database, owner.id.into_inner(), paper.id).await;

    let repository = database.research_memory();
    let annotation_id = Uuid::now_v7();
    let initial_write = annotation_write(
        annotation_id,
        Uuid::now_v7(),
        paper.id,
        block_id,
        0,
        "initial private note",
    );
    let initial = applied_annotation(
        repository
            .put_annotation(owner.id, &initial_write)
            .await
            .unwrap(),
    );
    assert!(!initial.1);
    let replay = applied_annotation(
        repository
            .put_annotation(owner.id, &initial_write)
            .await
            .unwrap(),
    );
    assert!(replay.1);
    assert_eq!(replay.0.revision, initial.0.revision);

    // Both devices start from the same accepted revision. Advisory locking
    // serializes the writes: one commits and the other persists a private
    // conflict record containing both bodies instead of overwriting either.
    let first_device = annotation_write(
        annotation_id,
        Uuid::now_v7(),
        paper.id,
        block_id,
        initial.0.revision,
        "device A private edit",
    );
    let second_device = annotation_write(
        annotation_id,
        Uuid::now_v7(),
        paper.id,
        block_id,
        initial.0.revision,
        "device B private edit",
    );
    let first_repository = repository.clone();
    let second_repository = repository.clone();
    let (first_result, second_result) = tokio::join!(
        first_repository.put_annotation(owner.id, &first_device),
        second_repository.put_annotation(owner.id, &second_device),
    );
    let first_result = first_result.unwrap();
    let second_result = second_result.unwrap();
    let (
        (
            ResearchMutationOutcome::Applied {
                value: accepted, ..
            },
            ResearchMutationOutcome::AnnotationConflict(conflict),
        )
        | (
            ResearchMutationOutcome::AnnotationConflict(conflict),
            ResearchMutationOutcome::Applied {
                value: accepted, ..
            },
        ),
    ) = ((first_result, second_result),)
    else {
        panic!("concurrent body edits did not produce one commit and one conflict");
    };
    let retained_bodies = [
        accepted.body.as_deref().unwrap(),
        conflict.attempted_body.as_deref().unwrap(),
        conflict.server_body.as_deref().unwrap(),
    ];
    assert!(retained_bodies.contains(&"device A private edit"));
    assert!(retained_bodies.contains(&"device B private edit"));
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM annotation_conflicts WHERE user_id = $1 AND annotation_id = $2",
        )
        .bind(owner.id.into_inner())
        .bind(annotation_id)
        .fetch_one(database.pool())
        .await
        .unwrap(),
        1
    );

    let resolved = applied_annotation(
        repository
            .put_annotation_resolving(
                owner.id,
                &annotation_write(
                    annotation_id,
                    Uuid::now_v7(),
                    paper.id,
                    block_id,
                    conflict.server_revision,
                    "merged without data loss",
                ),
                Some(conflict.conflict_id),
            )
            .await
            .unwrap(),
    );
    assert_eq!(resolved.0.body.as_deref(), Some("merged without data loss"));

    // Principal scope is enforced at the SQL boundary, not by caller-supplied
    // IDs. Another account sees no rows and cannot edit the owner's UUID.
    let ResearchReadOutcome::Found(other_page) = repository
        .annotations(other.id, Some(paper.id), 0, 50)
        .await
        .unwrap()
    else {
        panic!("other principal annotation read failed");
    };
    assert!(other_page.items.is_empty());
    let cross_account_write = annotation_write(
        annotation_id,
        Uuid::now_v7(),
        paper.id,
        block_id,
        accepted.revision,
        "cross-account edit",
    );
    assert!(matches!(
        repository
            .put_annotation(other.id, &cross_account_write)
            .await
            .unwrap(),
        ResearchMutationOutcome::ArtifactNotFound
    ));

    let checkpoint = applied_checkpoint(
        repository
            .put_checkpoint(
                owner.id,
                paper.id,
                &ReadingCheckpointWrite {
                    operation_id: Uuid::now_v7(),
                    base_revision: 0,
                    generation: 1,
                    mode: ReaderMode::Inspect,
                    stage: ReaderStage::Introduction,
                    block_id: Some(block_id),
                    scroll_fraction: Some(0.42),
                    last_read_at: now,
                },
            )
            .await
            .unwrap(),
    );
    assert_eq!(checkpoint.mode, ReaderMode::Inspect);
    assert_eq!(
        library_snapshot(&database, owner.id.into_inner(), paper.id).await,
        library_before,
        "checkpoint writes must not advance or mutate canonical Library authority"
    );

    let evidence_id = Uuid::now_v7();
    let evidence = applied_evidence(
        repository
            .put_evidence_card(
                owner.id,
                &EvidenceCardWrite {
                    id: evidence_id,
                    operation_id: Uuid::now_v7(),
                    paper_id: paper.id,
                    generation: 1,
                    title: "Validated result".to_owned(),
                    claim_or_question: Some("Does the evidence support the result?".to_owned()),
                    user_note: Some("User-reviewed evidence".to_owned()),
                    source_block_ids: vec![block_id],
                    figure_ids: Vec::new(),
                    table_ids: Vec::new(),
                    citation_context_ids: Vec::new(),
                    verification_status: EvidenceVerificationStatus::UserReviewed,
                    base_revision: 0,
                },
            )
            .await
            .unwrap(),
    );
    assert_eq!(evidence.id, evidence_id);

    let memory_id = Uuid::now_v7();
    let memory = applied_memory(
        repository
            .put_memory_item(
                owner.id,
                &MemoryItemWrite {
                    id: memory_id,
                    operation_id: Uuid::now_v7(),
                    paper_id: paper.id,
                    generation: 1,
                    source_type: MemorySourceType::EvidenceCard,
                    source_id: evidence_id,
                    prompt_text: Some("Why was this saved?".to_owned()),
                    answer_text: Some("Because the result has direct evidence.".to_owned()),
                    status: MemoryStatus::Active,
                    next_review_at: None,
                    base_revision: 0,
                },
            )
            .await
            .unwrap(),
    );
    let review_started_at: chrono::DateTime<Utc> =
        sqlx::query_scalar("SELECT statement_timestamp()")
            .fetch_one(database.pool())
            .await
            .unwrap();
    let snoozed = applied_memory(
        repository
            .review_memory_item(
                owner.id,
                memory_id,
                Uuid::now_v7(),
                memory.revision,
                MemoryStatus::Snoozed,
                Some(now + TimeDelta::days(1)),
                now + TimeDelta::days(365),
            )
            .await
            .unwrap(),
    );
    let review_finished_at: chrono::DateTime<Utc> =
        sqlx::query_scalar("SELECT statement_timestamp()")
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(snoozed.review_count, 1);
    assert_eq!(snoozed.status, MemoryStatus::Snoozed);
    assert!(snoozed.updated_at >= review_started_at);
    assert!(
        snoozed.updated_at <= review_finished_at,
        "client-supplied future review time must not poison server ordering"
    );
    assert_eq!(
        library_snapshot(&database, owner.id.into_inner(), paper.id).await,
        library_before,
        "memory scheduling must not mutate Library state or revision"
    );

    let thread_id = Uuid::now_v7();
    let user_message_id = Uuid::now_v7();
    let assistant_message_id = Uuid::now_v7();
    let provenance_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO assistant_threads (
            id, owner_user_id, paper_id, generation,
            created_at, updated_at, expires_at
        ) VALUES ($1, $2, $3, 1, $4, $4, $4 + interval '30 days')
        ",
    )
    .bind(thread_id)
    .bind(owner.id.into_inner())
    .bind(paper.id)
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r#"
        INSERT INTO provenance_records (
            id, artifact_type, artifact_id, paper_id, generation,
            activity_type, model_provider, model_id,
            prompt_or_schema_version, input_entity_ids, parameters,
            owner_user_id, created_at
        ) VALUES (
            $1, 'assistant_answer', $2, $3, 1,
            'assistant_generation', 'test', 'integration-model',
            'assistant.v2', ARRAY[$4]::uuid[], '{"temperature": 0}'::jsonb,
            $5, $6
        )
        "#,
    )
    .bind(provenance_id)
    .bind(assistant_message_id)
    .bind(paper.id)
    .bind(block_id)
    .bind(owner.id.into_inner())
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    let evidence_map = serde_json::json!([{
        "text": "The methods block supports the result.",
        "support": "direct",
        "evidence": [{
            "block_id": block_id,
            "start": 0,
            "end": 7,
            "page_start": 2,
            "section": "Methods"
        }]
    }]);
    sqlx::query(
        r"
        INSERT INTO assistant_messages (
            id, thread_id, ordinal, role, content, provenance_id,
            evidence_map, created_at
        ) VALUES
            ($1, $3, 0, 'user', 'What supports this result?', NULL, '[]'::jsonb, $5),
            ($2, $3, 1, 'assistant', 'The saved methods block supports it.', $4, $6, $5)
        ",
    )
    .bind(user_message_id)
    .bind(assistant_message_id)
    .bind(thread_id)
    .bind(provenance_id)
    .bind(now)
    .bind(evidence_map)
    .execute(database.pool())
    .await
    .unwrap();

    let feedback = AssistantEvidenceFeedback {
        operation_id: Uuid::now_v7(),
        paper_id: paper.id,
        generation: 1,
        thread_id,
        response_id: assistant_message_id,
        provenance_id,
        feedback_type: AssistantEvidenceFeedbackType::IncorrectCitation,
        claim_index: Some(0),
        evidence_block_id: Some(block_id),
        detail: Some("The cited range should be narrower.".to_owned()),
    };
    let feedback_id = match database
        .assistant_context()
        .record_evidence_feedback(
            ProvenancePrincipal::OwnerUser(owner.id.into_inner()),
            &feedback,
        )
        .await
        .unwrap()
    {
        AssistantEvidenceFeedbackOutcome::Created { feedback_id } => feedback_id,
        outcome => panic!("feedback was not created: {outcome:?}"),
    };
    assert_eq!(
        database
            .assistant_context()
            .record_evidence_feedback(
                ProvenancePrincipal::OwnerUser(owner.id.into_inner()),
                &feedback,
            )
            .await
            .unwrap(),
        AssistantEvidenceFeedbackOutcome::Replayed { feedback_id }
    );
    let mut conflicting_feedback = feedback.clone();
    conflicting_feedback.detail = Some("A different correction.".to_owned());
    assert_eq!(
        database
            .assistant_context()
            .record_evidence_feedback(
                ProvenancePrincipal::OwnerUser(owner.id.into_inner()),
                &conflicting_feedback,
            )
            .await
            .unwrap(),
        AssistantEvidenceFeedbackOutcome::IdempotencyConflict
    );
    let mut invalid_target = feedback.clone();
    invalid_target.operation_id = Uuid::now_v7();
    invalid_target.evidence_block_id = Some(Uuid::now_v7());
    assert_eq!(
        database
            .assistant_context()
            .record_evidence_feedback(
                ProvenancePrincipal::OwnerUser(owner.id.into_inner()),
                &invalid_target,
            )
            .await
            .unwrap(),
        AssistantEvidenceFeedbackOutcome::TargetMismatch
    );
    assert_eq!(
        database
            .assistant_context()
            .record_evidence_feedback(
                ProvenancePrincipal::OwnerUser(other.id.into_inner()),
                &feedback,
            )
            .await
            .unwrap(),
        AssistantEvidenceFeedbackOutcome::TargetNotFound
    );

    let ResearchReadOutcome::Found(export) = repository
        .export_research_artifacts(owner.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("bounded research export failed");
    };
    assert_eq!(export.annotations.len(), 1);
    assert_eq!(export.annotation_conflicts.len(), 1);
    assert_eq!(
        export.annotation_conflicts[0].resolution,
        Some(AnnotationConflictResolution::Merged)
    );
    assert_eq!(
        export.annotation_conflicts[0].merged_body.as_deref(),
        Some("merged without data loss")
    );
    assert_eq!(export.evidence_cards.len(), 1);
    assert_eq!(export.reading_checkpoints.len(), 1);
    assert_eq!(export.memory_items.len(), 1);
    assert_eq!(export.assistant_threads.len(), 1);
    assert_eq!(export.assistant_messages.len(), 2);
    assert_eq!(export.assistant_evidence_feedback.len(), 1);
    assert_eq!(export.assistant_evidence_feedback[0].id, feedback_id);
    assert_eq!(
        export.assistant_evidence_feedback[0].detail.as_deref(),
        Some("The cited range should be narrower.")
    );
    assert_eq!(export.private_provenance.len(), 1);
    assert_eq!(export.library_items.len(), 1);
    let export_json = serde_json::to_string(&export).unwrap();
    assert!(export_json.contains("What supports this result?"));
    assert!(export_json.contains("The cited range should be narrower."));
    assert!(!export_json.contains("owner_user_id"));
    assert!(!export_json.contains(&owner.id.into_inner().to_string()));
    let import_operation_id = Uuid::now_v7();
    let import_archive = ResearchAnnotationImport {
        schema_version: export.schema_version.to_owned(),
        annotations: export.annotations.clone(),
        annotation_conflicts: export.annotation_conflicts.clone(),
        annotation_reanchor_attempts: export.annotation_reanchor_attempts.clone(),
    };
    let ResearchAnnotationImportOutcome::Applied {
        result: import_result,
        replayed: false,
    } = repository
        .import_annotations(other.id, import_operation_id, &import_archive)
        .await
        .unwrap()
    else {
        panic!("annotation archive was not imported");
    };
    assert_eq!(import_result.imported_annotations, 1);
    assert_eq!(import_result.imported_conflicts, 1);
    assert!(matches!(
        repository
            .import_annotations(other.id, import_operation_id, &import_archive)
            .await
            .unwrap(),
        ResearchAnnotationImportOutcome::Applied { replayed: true, .. }
    ));
    let ResearchReadOutcome::Found(round_trip) = repository
        .export_research_artifacts(other.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("imported annotation archive was not exportable");
    };
    assert_eq!(round_trip.annotations[0].id, export.annotations[0].id);
    assert_eq!(round_trip.annotations[0].body, export.annotations[0].body);
    assert_eq!(
        round_trip.annotations[0].selector,
        export.annotations[0].selector
    );
    assert_eq!(round_trip.annotation_conflicts, export.annotation_conflicts);
    let ResearchReadOutcome::Found(manifest) = repository
        .research_export_manifest(owner.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("research export manifest failed");
    };
    assert_eq!(manifest.papers.len(), 1);
    assert_eq!(manifest.papers[0].paper_id, paper.id);
    assert!(manifest.papers[0].artifact_count >= 10);
    sqlx::query(
        "UPDATE annotation_conflicts SET merged_body = merged_body || ' 🧠' WHERE user_id = $1 AND id = $2",
    )
    .bind(owner.id.into_inner())
    .bind(conflict.conflict_id)
    .execute(database.pool())
    .await
    .unwrap();
    let ResearchReadOutcome::Found(expanded_manifest) = repository
        .research_export_manifest(owner.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("expanded research export manifest failed");
    };
    assert_eq!(
        expanded_manifest.papers[0].private_scalar_count,
        manifest.papers[0].private_scalar_count + 2,
        "manifest scalar preflight must include the retained merged body"
    );
    assert_eq!(
        expanded_manifest.papers[0].private_byte_count,
        manifest.papers[0].private_byte_count + 5,
        "manifest byte preflight must include merged-body UTF-8 bytes"
    );

    // Account deletion's application purge deletes the users row; every
    // Plan-03 private table is principal-FK-cascaded from that row.
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    for table in [
        "annotations",
        "annotation_conflicts",
        "annotation_reanchor_attempts",
        "annotation_imports",
        "evidence_cards",
        "reading_checkpoints",
        "reading_sessions",
        "memory_items",
        "research_artifact_operations",
        "research_artifact_sync_metadata",
        "user_paper_library",
    ] {
        let count: i64 =
            sqlx::query_scalar(&format!("SELECT count(*) FROM {table} WHERE user_id = $1"))
                .bind(owner.id.into_inner())
                .fetch_one(database.pool())
                .await
                .unwrap();
        assert_eq!(count, 0, "{table} retained deleted-account data");
    }
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM assistant_threads WHERE owner_user_id = $1",
        )
        .bind(owner.id.into_inner())
        .fetch_one(database.pool())
        .await
        .unwrap(),
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM provenance_records WHERE owner_user_id = $1",
        )
        .bind(owner.id.into_inner())
        .fetch_one(database.pool())
        .await
        .unwrap(),
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM assistant_messages WHERE thread_id = $1",
        )
        .bind(thread_id)
        .fetch_one(database.pool())
        .await
        .unwrap(),
        0
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM assistant_evidence_feedback_evaluations WHERE id = $1",
        )
        .bind(feedback_id)
        .fetch_one(database.pool())
        .await
        .unwrap(),
        0,
        "assistant evidence feedback must cascade with account/thread deletion"
    );

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(other.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_export_preflight_rejects_utf8_bytes_before_materializing_rows() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL UTF-8 export coverage");
        return;
    };
    let database = Database::connect(&database_url, 8)
        .await
        .unwrap()
        .with_cursor_codec(test_cursor_codec());
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://research-export-bytes.test/{unique}");
    let owner = database
        .accounts()
        .provision_oidc_identity(&issuer, "owner", Duration::from_secs(900))
        .await
        .unwrap();
    let now = Utc::now();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("export-bytes.{unique}"), now))
        .await
        .unwrap();
    let block_id = Uuid::now_v7();
    let source_quote = "🧠".repeat(12_500);
    insert_document_generation(
        &database,
        paper.id,
        1,
        1,
        now,
        &[(block_id, "utf8:p0", 0, &source_quote)],
    )
    .await;
    let body = "🧠".repeat(99_990);
    let repository = database.research_memory();
    for _ in 0..20 {
        let outcome = repository
            .put_annotation(
                owner.id,
                &AnnotationWrite {
                    id: Uuid::now_v7(),
                    operation_id: Uuid::now_v7(),
                    paper_id: paper.id,
                    generation: 1,
                    block_id: Some(block_id),
                    kind: AnnotationKind::Note,
                    body: Some(body.clone()),
                    color_role: Some(AnnotationColorRole::Yellow),
                    selector: TextQuotePositionSelector {
                        exact: source_quote.clone(),
                        prefix: None,
                        suffix: None,
                        start: Some(0),
                        end: Some(12_500),
                    },
                    section_hint: vec!["Methods".to_owned()],
                    page_hint: Some(1),
                    base_revision: 0,
                },
            )
            .await
            .unwrap();
        assert!(matches!(outcome, ResearchMutationOutcome::Applied { .. }));
    }

    let ResearchReadOutcome::ExportTooLarge {
        artifact_count,
        private_scalar_count,
        source_quote_scalar_count,
        private_byte_count,
        source_quote_byte_count,
    } = repository
        .export_research_artifacts(owner.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("UTF-8-heavy paper passed export preflight and materialized all rows");
    };
    assert_eq!(artifact_count, 20);
    assert_eq!(private_scalar_count, 1_999_800);
    assert_eq!(source_quote_scalar_count, 250_000);
    assert_eq!(private_byte_count, 7_999_200);
    assert_eq!(source_quote_byte_count, 1_000_000);

    let mut cursor = None;
    let mut exported_annotations = 0_usize;
    let mut maximum_page_bytes = 0_usize;
    loop {
        let ResearchReadOutcome::Found(page) = repository
            .export_research_artifact_page(owner.id, Some(paper.id), cursor.as_deref())
            .await
            .unwrap()
        else {
            panic!("valid private artifacts were not page-exportable");
        };
        exported_annotations += page.export.annotations.len();
        maximum_page_bytes =
            maximum_page_bytes.max(serde_json::to_vec(&page.export).unwrap().len());
        cursor = page.next_cursor;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(exported_annotations, 20);
    assert!(maximum_page_bytes < 8 * 1024 * 1024);

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_checkpoint_exact_scope_is_not_hidden_by_global_cap() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL checkpoint-scope coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://checkpoint-scope.test/{unique}");
    let owner = database
        .accounts()
        .provision_oidc_identity(&issuer, "owner", Duration::from_secs(900))
        .await
        .unwrap();
    let now = Utc::now();
    let requested = database
        .papers()
        .upsert_metadata(&metadata(&format!("checkpoint-oldest.{unique}"), now))
        .await
        .unwrap();
    let other_prefix = format!("checkpoint-other.{unique}");
    sqlx::query(
        r"
        INSERT INTO papers (
            id, arxiv_base_id, arxiv_version, title, abstract, authors,
            primary_category, categories, published_at, updated_at,
            abs_url, pdf_url, metadata_fetched_at
        )
        SELECT gen_random_uuid(), $1 || '.' || ordinal::text, 1,
               'Checkpoint cap fixture ' || ordinal::text, 'fixture', '[]'::jsonb,
               'cs.AI', ARRAY['cs.AI'], $2, $2,
               'https://arxiv.org/abs/' || $1 || '.' || ordinal::text,
               'https://arxiv.org/pdf/' || $1 || '.' || ordinal::text,
               $2
        FROM generate_series(1, 1001) AS ordinal
        ",
    )
    .bind(&other_prefix)
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        WITH numbered AS (
            SELECT id, row_number() OVER (ORDER BY id)::bigint AS revision
            FROM papers
            WHERE arxiv_base_id LIKE $2 || '.%'
        ), inserted_operations AS (
            INSERT INTO research_artifact_operations (
                user_id, operation_id, accepted_revision, artifact_kind,
                artifact_id, request_hash, created_at
            )
            SELECT $1, gen_random_uuid(), revision, 'checkpoint', id,
                   repeat('a', 64), $3
            FROM numbered
            RETURNING operation_id, artifact_id, accepted_revision
        )
        INSERT INTO reading_checkpoints (
            user_id, paper_id, generation, mode, stage, block_id,
            scroll_fraction, last_read_at, revision, last_operation_id, updated_at
        )
        SELECT $1, artifact_id, 1, 'read', 'abstract', NULL,
               0.5, $3, accepted_revision, operation_id, $3
        FROM inserted_operations
        ",
    )
    .bind(owner.id.into_inner())
    .bind(&other_prefix)
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    let requested_operation = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO research_artifact_operations (
            user_id, operation_id, accepted_revision, artifact_kind,
            artifact_id, request_hash, created_at
        ) VALUES ($1, $2, 1002, 'checkpoint', $3, $4, $5)
        ",
    )
    .bind(owner.id.into_inner())
    .bind(requested_operation)
    .bind(requested.id)
    .bind("b".repeat(64))
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO reading_checkpoints (
            user_id, paper_id, generation, mode, stage, block_id,
            scroll_fraction, last_read_at, revision, last_operation_id, updated_at
        ) VALUES ($1, $2, 1, 'read', 'abstract', NULL, 0.25,
                  $3 - interval '30 days', 1002, $4, $3)
        ",
    )
    .bind(owner.id.into_inner())
    .bind(requested.id)
    .bind(now)
    .bind(requested_operation)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO research_artifact_sync_metadata (
            user_id, current_revision, purged_through_revision, updated_at
        ) VALUES ($1, 1002, 0, $2)
        ",
    )
    .bind(owner.id.into_inner())
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();

    let repository = database.research_memory();
    let ResearchReadOutcome::Found(global) = repository.checkpoints(owner.id, None).await.unwrap()
    else {
        panic!("global checkpoint read failed");
    };
    assert_eq!(global.items.len(), 1000);
    assert!(
        global
            .items
            .iter()
            .all(|item| item.paper_id != requested.id),
        "the oldest checkpoint must exercise the global cap"
    );
    let ResearchReadOutcome::Found(exact) = repository
        .checkpoints(owner.id, Some(requested.id))
        .await
        .unwrap()
    else {
        panic!("paper-scoped checkpoint read failed");
    };
    assert_eq!(exact.items.len(), 1);
    assert_eq!(exact.items[0].paper_id, requested.id);

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1 OR arxiv_base_id LIKE $2 || '.%'")
        .bind(requested.id)
        .bind(&other_prefix)
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_imported_unresolved_conflict_resolves_at_fresh_annotation_revision() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL conflict-import coverage");
        return;
    };
    let database = Database::connect(&database_url, 8)
        .await
        .unwrap()
        .with_cursor_codec(test_cursor_codec());
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://annotation-import.test/{unique}");
    let source = database
        .accounts()
        .provision_oidc_identity(&issuer, "source", Duration::from_secs(900))
        .await
        .unwrap();
    let target = database
        .accounts()
        .provision_oidc_identity(&issuer, "target", Duration::from_secs(900))
        .await
        .unwrap();
    let now = Utc::now();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("conflict-import.{unique}"), now))
        .await
        .unwrap();
    let block_id = Uuid::now_v7();
    insert_document_generation(
        &database,
        paper.id,
        1,
        1,
        now,
        &[(block_id, "methods:p0", 0, "Methods support this result.")],
    )
    .await;

    let repository = database.research_memory();
    let annotation_id = Uuid::now_v7();
    let initial = applied_annotation(
        repository
            .put_annotation(
                source.id,
                &annotation_write(
                    annotation_id,
                    Uuid::now_v7(),
                    paper.id,
                    block_id,
                    0,
                    "initial body",
                ),
            )
            .await
            .unwrap(),
    )
    .0;
    let accepted = applied_annotation(
        repository
            .put_annotation(
                source.id,
                &annotation_write(
                    annotation_id,
                    Uuid::now_v7(),
                    paper.id,
                    block_id,
                    initial.revision,
                    "accepted body",
                ),
            )
            .await
            .unwrap(),
    )
    .0;
    let ResearchMutationOutcome::AnnotationConflict(conflict) = repository
        .put_annotation(
            source.id,
            &annotation_write(
                annotation_id,
                Uuid::now_v7(),
                paper.id,
                block_id,
                initial.revision,
                "retained attempted body",
            ),
        )
        .await
        .unwrap()
    else {
        panic!("stale private-body edit did not retain a conflict");
    };
    assert_eq!(conflict.server_revision, accepted.revision);

    let ResearchReadOutcome::Found(source_export) = repository
        .export_research_artifacts(source.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("unresolved conflict export failed");
    };
    assert_eq!(source_export.annotation_conflicts[0].resolution, None);
    let archive = ResearchAnnotationImport {
        schema_version: source_export.schema_version.to_owned(),
        annotations: source_export.annotations.clone(),
        annotation_conflicts: source_export.annotation_conflicts.clone(),
        annotation_reanchor_attempts: source_export.annotation_reanchor_attempts.clone(),
    };
    assert!(matches!(
        repository
            .import_annotations(target.id, Uuid::now_v7(), &archive)
            .await
            .unwrap(),
        ResearchAnnotationImportOutcome::Applied {
            replayed: false,
            ..
        }
    ));

    let ResearchReadOutcome::Found(imported) = repository
        .export_research_artifacts(target.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("imported unresolved conflict was not exportable");
    };
    assert_eq!(
        imported.annotation_conflicts,
        source_export.annotation_conflicts
    );
    let imported_revision = imported.annotations[0].revision;
    assert_ne!(
        imported_revision, conflict.server_revision,
        "coverage requires import to allocate a revision distinct from archived history"
    );
    let ResearchReadOutcome::Found(conflict_page) = repository
        .unresolved_annotation_conflicts(target.id, None, 1)
        .await
        .unwrap()
    else {
        panic!("imported unresolved conflict was not discoverable through sync");
    };
    assert_eq!(conflict_page.items.len(), 1);
    assert!(conflict_page.next_cursor.is_none());
    assert_eq!(conflict_page.items[0].paper_id, paper.id);
    assert_eq!(
        conflict_page.items[0].conflict.server_revision, conflict.server_revision,
        "sync must retain the archived conflict revision as history"
    );
    assert_eq!(
        conflict_page.items[0].current_annotation_revision, imported_revision,
        "sync must expose the fresh optimistic revision required for resolution"
    );
    assert!(matches!(
        repository
            .unresolved_annotation_conflicts(target.id, Some(&"x".repeat(2_049)), 1)
            .await
            .unwrap(),
        ResearchReadOutcome::InvalidCursor
    ));

    let resolved = applied_annotation(
        repository
            .put_annotation_resolving(
                target.id,
                &annotation_write(
                    annotation_id,
                    Uuid::now_v7(),
                    paper.id,
                    block_id,
                    imported_revision,
                    "merged after import",
                ),
                Some(conflict.conflict_id),
            )
            .await
            .unwrap(),
    )
    .0;
    assert_eq!(resolved.body.as_deref(), Some("merged after import"));
    let ResearchReadOutcome::Found(resolved_export) = repository
        .export_research_artifacts(target.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("resolved imported conflict was not exportable");
    };
    let resolved_conflict = &resolved_export.annotation_conflicts[0];
    assert_eq!(resolved_conflict.server_revision, conflict.server_revision);
    assert_eq!(
        resolved_conflict.resolution,
        Some(AnnotationConflictResolution::Merged)
    );
    assert_eq!(
        resolved_conflict.merged_body.as_deref(),
        Some("merged after import")
    );

    for user_id in [source.id, target.id] {
        sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(user_id.into_inner())
            .execute(database.pool())
            .await
            .unwrap();
    }
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_annotation_reanchors_are_conservative_idempotent_and_user_overridable() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL annotation-reanchor coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://annotation-reanchor.test/{unique}");
    let owner = database
        .accounts()
        .provision_oidc_identity(&issuer, "owner", Duration::from_secs(900))
        .await
        .unwrap();
    let restore_owner = database
        .accounts()
        .provision_oidc_identity(&issuer, "restore", Duration::from_secs(900))
        .await
        .unwrap();
    let now = Utc::now();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("reanchor.{unique}"), now))
        .await
        .unwrap();
    let old_exact_block = Uuid::now_v7();
    let old_manual_block = Uuid::now_v7();
    insert_document_generation(
        &database,
        paper.id,
        1,
        1,
        now,
        &[
            (
                old_exact_block,
                "methods:exact",
                0,
                "old critical method worked",
            ),
            (
                old_manual_block,
                "results:old",
                1,
                "old manually attached quote",
            ),
        ],
    )
    .await;

    let repository = database.research_memory();
    let exact_id = Uuid::now_v7();
    let exact = applied_annotation(
        repository
            .put_annotation(
                owner.id,
                &AnnotationWrite {
                    id: exact_id,
                    operation_id: Uuid::now_v7(),
                    paper_id: paper.id,
                    generation: 1,
                    block_id: Some(old_exact_block),
                    kind: AnnotationKind::Note,
                    body: Some("private exact-anchor note".to_owned()),
                    color_role: Some(AnnotationColorRole::Yellow),
                    selector: TextQuotePositionSelector {
                        exact: "critical method".to_owned(),
                        prefix: Some("old ".to_owned()),
                        suffix: Some(" worked".to_owned()),
                        start: Some(4),
                        end: Some(19),
                    },
                    section_hint: vec!["Methods".to_owned()],
                    page_hint: Some(1),
                    base_revision: 0,
                },
            )
            .await
            .unwrap(),
    )
    .0;
    let manual_id = Uuid::now_v7();
    let manual = applied_annotation(
        repository
            .put_annotation(
                owner.id,
                &AnnotationWrite {
                    id: manual_id,
                    operation_id: Uuid::now_v7(),
                    paper_id: paper.id,
                    generation: 1,
                    block_id: Some(old_manual_block),
                    kind: AnnotationKind::Note,
                    body: Some("private manual-anchor note".to_owned()),
                    color_role: Some(AnnotationColorRole::Blue),
                    selector: TextQuotePositionSelector {
                        exact: "manually attached quote".to_owned(),
                        prefix: Some("old ".to_owned()),
                        suffix: None,
                        start: Some(4),
                        end: Some(27),
                    },
                    section_hint: vec!["Results".to_owned()],
                    page_hint: Some(2),
                    base_revision: 0,
                },
            )
            .await
            .unwrap(),
    )
    .0;

    let mut version_two = metadata(
        &paper.metadata.arxiv_id.base_id,
        now + TimeDelta::minutes(1),
    );
    version_two.arxiv_id.version = 2;
    version_two.abs_url = Url::parse(&format!(
        "https://arxiv.org/abs/{}v2",
        paper.metadata.arxiv_id.base_id
    ))
    .unwrap();
    version_two.pdf_url = Url::parse(&format!(
        "https://arxiv.org/pdf/{}v2",
        paper.metadata.arxiv_id.base_id
    ))
    .unwrap();
    database
        .papers()
        .upsert_metadata(&version_two)
        .await
        .unwrap();
    let new_exact_block = Uuid::now_v7();
    let new_manual_block = Uuid::now_v7();
    insert_document_generation(
        &database,
        paper.id,
        2,
        2,
        now + TimeDelta::minutes(1),
        &[
            (
                new_exact_block,
                "methods:exact",
                0,
                "new critical method works",
            ),
            (
                new_manual_block,
                "results:revised",
                1,
                "new manually attached quote",
            ),
        ],
    )
    .await;

    let pending = repository
        .pending_annotation_reanchors(paper.id, 2, None, 50)
        .await
        .unwrap();
    assert_eq!(pending.len(), 2);
    assert!(
        pending
            .iter()
            .all(|item| item.user_id == owner.id.into_inner())
    );
    let stale_manual_revision = pending
        .iter()
        .find(|item| item.annotation_id == manual_id)
        .unwrap()
        .base_revision;

    let operation_id = Uuid::now_v7();
    let ResearchMutationOutcome::Applied {
        value: observed,
        replayed: false,
    } = repository
        .reanchor_annotation_observed(owner.id, exact_id, operation_id, exact.revision, 2)
        .await
        .unwrap()
    else {
        panic!("exact reanchor was not applied");
    };
    assert_eq!(
        observed.strategy,
        Some(domain::ReanchorStrategy::StableBlockExact)
    );
    assert_eq!(observed.result, domain::AnnotationAnchorStatus::Anchored);
    let reanchored = observed.annotation;
    assert_eq!(reanchored.generation, 2);
    assert_eq!(reanchored.block_id, Some(new_exact_block));
    assert_eq!(
        reanchored.selector.as_ref().unwrap().prefix.as_deref(),
        Some("new ")
    );
    assert_eq!(
        reanchored.selector.as_ref().unwrap().suffix.as_deref(),
        Some(" works")
    );
    assert!(matches!(
        repository
            .reanchor_annotation_observed(owner.id, exact_id, operation_id, exact.revision, 2)
            .await
            .unwrap(),
        ResearchMutationOutcome::Applied {
            value,
            replayed: true,
        } if value.strategy == Some(domain::ReanchorStrategy::StableBlockExact)
            && value.result == domain::AnnotationAnchorStatus::Anchored
    ));

    let manual_operation = Uuid::now_v7();
    let manual_write = AnnotationWrite {
        id: manual_id,
        operation_id: manual_operation,
        paper_id: paper.id,
        generation: 2,
        block_id: Some(new_manual_block),
        kind: AnnotationKind::Note,
        body: manual.body.clone(),
        color_role: manual.color_role,
        selector: TextQuotePositionSelector {
            exact: "manually attached quote".to_owned(),
            prefix: Some("new ".to_owned()),
            suffix: None,
            start: Some(4),
            end: Some(27),
        },
        section_hint: vec!["Results".to_owned()],
        page_hint: Some(2),
        base_revision: manual.revision,
    };
    let manual_reanchored = applied_annotation(
        repository
            .put_annotation(owner.id, &manual_write)
            .await
            .unwrap(),
    )
    .0;
    assert_eq!(manual_reanchored.generation, 2);
    assert_eq!(manual_reanchored.block_id, Some(new_manual_block));
    assert!(matches!(
        repository
            .reanchor_annotation(
                owner.id,
                manual_id,
                Uuid::now_v7(),
                stale_manual_revision,
                2,
            )
            .await
            .unwrap(),
        ResearchMutationOutcome::RevisionConflict { current_revision }
            if current_revision == manual_reanchored.revision
    ));
    assert!(matches!(
        repository
            .reanchor_annotation(
                owner.id,
                manual_id,
                Uuid::now_v7(),
                manual_reanchored.revision,
                2,
            )
            .await
            .unwrap(),
        ResearchMutationOutcome::StaleGeneration
    ));

    assert!(
        repository
            .pending_annotation_reanchors(paper.id, 2, None, 50)
            .await
            .unwrap()
            .is_empty()
    );
    let attempts = sqlx::query_as::<_, (Uuid, String, String, i32, i32)>(
        r"
        SELECT annotation_id, strategy, result, from_generation, to_generation
        FROM annotation_reanchor_attempts
        WHERE user_id = $1 AND annotation_id = ANY($2)
        ORDER BY annotation_id
        ",
    )
    .bind(owner.id.into_inner())
    .bind(vec![exact_id, manual_id])
    .fetch_all(database.pool())
    .await
    .unwrap();
    assert_eq!(attempts.len(), 2);
    assert!(attempts.iter().all(|row| row.2 == "anchored"));
    assert!(attempts.iter().all(|row| row.3 == 1 && row.4 == 2));
    assert!(attempts.iter().any(|row| row.1 == "stable_block_exact"));
    assert!(attempts.iter().any(|row| row.1 == "manual"));

    let ResearchReadOutcome::Found(export) = repository
        .export_research_artifacts(owner.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("re-anchor archive export failed");
    };
    let archive = ResearchAnnotationImport {
        schema_version: export.schema_version.to_owned(),
        annotations: export.annotations,
        annotation_conflicts: export.annotation_conflicts,
        annotation_reanchor_attempts: export.annotation_reanchor_attempts.clone(),
    };
    assert!(matches!(
        repository
            .import_annotations(restore_owner.id, Uuid::now_v7(), &archive)
            .await
            .unwrap(),
        ResearchAnnotationImportOutcome::Applied {
            replayed: false,
            ..
        }
    ));
    let ResearchReadOutcome::Found(restored) = repository
        .export_research_artifacts(restore_owner.id, Some(paper.id), Utc::now())
        .await
        .unwrap()
    else {
        panic!("re-anchor archive round trip failed");
    };
    assert!(
        restored.annotation_reanchor_attempts == archive.annotation_reanchor_attempts,
        "re-anchor history changed during import/export round trip"
    );

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(restore_owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

fn annotation_write(
    id: Uuid,
    operation_id: Uuid,
    paper_id: Uuid,
    block_id: Uuid,
    base_revision: i64,
    body: &str,
) -> AnnotationWrite {
    AnnotationWrite {
        id,
        operation_id,
        paper_id,
        generation: 1,
        block_id: Some(block_id),
        kind: AnnotationKind::Note,
        body: Some(body.to_owned()),
        color_role: Some(AnnotationColorRole::Yellow),
        selector: TextQuotePositionSelector {
            exact: "support".to_owned(),
            prefix: Some("Methods ".to_owned()),
            suffix: Some(" this result.".to_owned()),
            start: Some(8),
            end: Some(15),
        },
        section_hint: vec!["Methods".to_owned()],
        page_hint: Some(2),
        base_revision,
    }
}

fn applied_annotation(
    outcome: ResearchMutationOutcome<domain::Annotation>,
) -> (domain::Annotation, bool) {
    match outcome {
        ResearchMutationOutcome::Applied { value, replayed } => (value, replayed),
        _ => panic!("expected applied annotation"),
    }
}

fn applied_checkpoint(
    outcome: ResearchMutationOutcome<domain::ReadingCheckpoint>,
) -> domain::ReadingCheckpoint {
    match outcome {
        ResearchMutationOutcome::Applied { value, .. } => value,
        _ => panic!("expected applied checkpoint"),
    }
}

fn applied_evidence(
    outcome: ResearchMutationOutcome<domain::EvidenceCard>,
) -> domain::EvidenceCard {
    match outcome {
        ResearchMutationOutcome::Applied { value, .. } => value,
        _ => panic!("expected applied evidence card"),
    }
}

fn applied_memory(outcome: ResearchMutationOutcome<domain::MemoryItem>) -> domain::MemoryItem {
    match outcome {
        ResearchMutationOutcome::Applied { value, .. } => value,
        _ => panic!("expected applied memory item"),
    }
}

async fn insert_document_generation(
    database: &Database,
    paper_id: Uuid,
    generation: i32,
    arxiv_version: i32,
    created_at: chrono::DateTime<Utc>,
    blocks: &[(Uuid, &str, i32, &str)],
) {
    let document_hash = format!("{generation:064x}");
    sqlx::query(
        r"
        INSERT INTO document_generations (
            paper_id, generation, arxiv_version, schema_version, parser_id, parser_version,
            document_hash, metadata_snapshot, metadata_hash, created_at, updated_at
        ) VALUES (
            $1, $2, $3, 'document.v1', 'grobid', 'integration-v1', $4,
            jsonb_build_object('schema_version', 'paper-metadata-v1'), $4, $5, $5
        )
        ",
    )
    .bind(paper_id)
    .bind(generation)
    .bind(arxiv_version)
    .bind(document_hash)
    .bind(created_at)
    .execute(database.pool())
    .await
    .unwrap();
    for (id, stable_key, ordinal, text) in blocks {
        let content_hash = format!(
            "{:064x}",
            i64::from(generation) * 10_000 + i64::from(*ordinal)
        );
        sqlx::query(
            r"
            INSERT INTO document_blocks (
                id, paper_id, generation, stable_key, ordinal, section_path,
                kind, text, content_hash, page_start, page_end, inline_spans, created_at
            ) VALUES (
                $1, $2, $3, $4, $5,
                CASE WHEN $5 = 0 THEN ARRAY['Methods'] ELSE ARRAY['Results'] END,
                'paragraph', $6, $7, $5 + 1, $5 + 1, '[]'::jsonb, $8
            )
            ",
        )
        .bind(id)
        .bind(paper_id)
        .bind(generation)
        .bind(stable_key)
        .bind(ordinal)
        .bind(text)
        .bind(content_hash)
        .bind(created_at)
        .execute(database.pool())
        .await
        .unwrap();
    }
}

async fn library_snapshot(
    database: &Database,
    user_id: Uuid,
    paper_id: Uuid,
) -> (String, i64, i64) {
    sqlx::query_as(
        r"
        SELECT library.state, library.revision, metadata.current_revision
        FROM user_paper_library AS library
        JOIN library_sync_metadata AS metadata ON metadata.user_id = library.user_id
        WHERE library.user_id = $1 AND library.paper_id = $2
        ",
    )
    .bind(user_id)
    .bind(paper_id)
    .fetch_one(database.pool())
    .await
    .unwrap()
}

fn metadata(base_id: &str, now: chrono::DateTime<Utc>) -> PaperMetadata {
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: "Private research memory integration".to_owned(),
        abstract_text: "An abstract used only for integration coverage.".to_owned(),
        authors: vec![Author {
            name: "Ada Reader".to_owned(),
        }],
        primary_category: "cs.HC".to_owned(),
        categories: vec!["cs.HC".to_owned()],
        published_at: now,
        updated_at: now,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v1")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v1")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: None,
        metadata_fetched_at: now,
    }
}

fn test_cursor_codec() -> opaque_cursor::OpaqueCursorCodec {
    let key = STANDARD.encode([0x72; 32]);
    opaque_cursor::OpaqueCursorCodec::parse_keyring(&format!("research_test:{key}")).unwrap()
}
