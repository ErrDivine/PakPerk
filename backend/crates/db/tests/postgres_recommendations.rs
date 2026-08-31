use std::{collections::BTreeSet, time::Duration};

use chrono::{Days, Utc};
use db::{
    Database, LibraryMutationIntent, RecommendationBatchBlockOutcome,
    RecommendationBatchBlockRequest, RecommendationBatchPersistOutcome,
    RecommendationBatchPersistRequest, RecommendationBatchServeOutcome,
    RecommendationBatchServeRequest, RecommendationExplanationReadOutcome,
    RecommendationFeedbackOutcome, RecommendationFeedbackReason, RecommendationFeedbackType,
    RecommendationFeedbackWrite, RecommendationGenerationEnqueue,
    RecommendationGenerationEnqueueOutcome, RecommendationGenerationJobState,
    RecommendationGenerationRepositoryError, StoredRecommendationBatchStatus,
};
use domain::{ArxivIdentifier, Author, Capabilities, LibraryState, PaperMetadata, PaperSummary};
use reading_feed::RecommendationPosition;
use recommendations::{
    CandidateDocument, DiscoveryProfileSnapshot, ProvenEmptyQueueBinding,
    RECOMMENDATION_ALGORITHM_VERSION_V1, RecommendationBatchBuildRequest, RecommendationMode,
    RerankPolicy, ScoringPolicy, build_recommendation_batch,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_batches_recheck_queue_replay_and_supersede_on_library_mutation() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL recommendation coverage");
        return;
    };
    let database = Database::connect(&database_url, 12).await.unwrap();
    database.migrate_embedded().await.unwrap();
    for index_name in [
        "recommendation_generation_jobs_claim_idx",
        "recommendation_generation_jobs_lease_idx",
        "recommendation_generation_jobs_retention_idx",
        "recommendation_generation_jobs_pending_retention_idx",
    ] {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1)",
        )
        .bind(index_name)
        .fetch_one(database.pool())
        .await
        .unwrap();
        assert!(exists, "missing recommendation queue index {index_name}");
    }

    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://recommendations.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let paper_metadata = metadata(&unique);
    let paper = database
        .papers()
        .upsert_metadata(&paper_metadata)
        .await
        .unwrap();
    let document = CandidateDocument {
        paper: PaperSummary {
            paper_id: paper.id,
            arxiv_id: paper_metadata.arxiv_id.versioned(),
            title: paper_metadata.title.clone(),
            abstract_text: paper_metadata.abstract_text.clone(),
            authors: paper_metadata
                .authors
                .iter()
                .map(|author| author.name.clone())
                .collect(),
            primary_category: paper_metadata.primary_category.clone(),
            categories: paper_metadata.categories.clone(),
            published_at: paper_metadata.published_at,
            updated_at: paper_metadata.updated_at,
            abs_url: paper_metadata.abs_url.clone(),
            pdf_url: paper_metadata.pdf_url.clone(),
            capabilities: Capabilities::metadata_only(),
        },
        topics: BTreeSet::from(["retrieval".to_owned()]),
        embedding: vec![1.0, 0.0],
        citation_neighbors: BTreeSet::new(),
        metadata_completeness: 1.0,
    };
    let profile = DiscoveryProfileSnapshot {
        personalization_enabled: false,
        categories: BTreeSet::new(),
        topics: BTreeSet::new(),
        authors: BTreeSet::new(),
        saved_query_matches: std::collections::BTreeMap::new(),
        feedback_categories: BTreeSet::new(),
        inferred_categories: BTreeSet::new(),
        historical_seeds: Vec::new(),
    };
    let now = Utc::now();
    let batch = build_recommendation_batch(RecommendationBatchBuildRequest {
        mode: RecommendationMode::Recent,
        queue: ProvenEmptyQueueBinding::from_decision(0, 0, true).unwrap(),
        profile_revision: None,
        feedback_revision: 0,
        profile: &profile,
        documents: &[document],
        candidate_history: &std::collections::BTreeMap::new(),
        now,
        candidate_limit: 20,
        fanout_policy: recommendations::CandidateFanoutPolicy::default(),
        generator_observer: None,
        rerank_policy: RerankPolicy::default(),
        scoring_policy: ScoringPolicy::default(),
    })
    .await
    .unwrap();
    let repository = database.recommendation_batches();
    let seed = database
        .papers()
        .upsert_metadata(&metadata(&format!("{unique}-citation-seed")))
        .await
        .unwrap();
    let reference_id: Uuid = sqlx::query_scalar(
        r"
        INSERT INTO paper_references (
            citing_paper_id, generation, ordinal, raw_text,
            resolved_paper_id, resolution_status, resolution_confidence,
            resolution_method
        ) VALUES ($1, 1, 0, 'Resolved fixture reference', $2, 'resolved', 1.0, 'fixture')
        RETURNING id
        ",
    )
    .bind(paper.id)
    .bind(seed.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO paper_connections (
            citing_paper_id, cited_paper_id, reference_id, generation,
            relation_type, summary, confidence, source_context_ids
        ) VALUES ($1, $2, $3, 1, 'related_work', 'Resolved fixture edge', 1.0, '{}')
        ",
    )
    .bind(paper.id)
    .bind(seed.id)
    .bind(reference_id)
    .execute(database.pool())
    .await
    .unwrap();
    let neighbors = repository.citation_neighbors(&[paper.id]).await.unwrap();
    assert_eq!(neighbors[&paper.id], BTreeSet::from([seed.id]));
    let local_date = now.date_naive();
    let continuation = RecommendationPosition {
        published_at: paper_metadata.published_at,
        paper_id: paper.id,
    };
    let first_batch_id = Uuid::now_v7();
    assert!(matches!(
        repository
            .persist_ready(RecommendationBatchPersistRequest {
                user_id: account.id,
                batch_id: first_batch_id,
                query_key: "recent:all",
                local_date,
                created_at: now,
                expires_at: now + chrono::Duration::days(7),
                next_position: Some(continuation),
                saved_search_revision_digest: None,
                batch: &batch,
            })
            .await
            .unwrap(),
        RecommendationBatchPersistOutcome::Ready {
            batch_id,
            library_revision: 0,
            candidate_count: 1,
        } if batch_id == first_batch_id
    ));
    assert!(matches!(
        repository
            .persist_ready(RecommendationBatchPersistRequest {
                user_id: account.id,
                batch_id: Uuid::now_v7(),
                query_key: "recent:all",
                local_date,
                created_at: now,
                expires_at: now + chrono::Duration::days(7),
                next_position: Some(continuation),
                saved_search_revision_digest: None,
                batch: &batch,
            })
            .await
            .unwrap(),
        RecommendationBatchPersistOutcome::Replayed {
            batch_id,
            status: StoredRecommendationBatchStatus::Ready,
        } if batch_id == first_batch_id
    ));
    assert!(matches!(
        repository
            .serve_ready(RecommendationBatchServeRequest {
                user_id: account.id,
                batch_id: first_batch_id,
                mode: RecommendationMode::Recent,
                library_revision: 0,
                limit: 20,
                now,
            })
            .await
            .unwrap(),
        RecommendationBatchServeOutcome::Found {
            batch_id,
            ref batch_metadata,
            next_position: Some(next),
            ref items,
            ..
        } if batch_id == first_batch_id
            && batch_metadata.profile_revision.is_none()
            && batch_metadata.feedback_revision == 0
            && batch_metadata.algorithm_version == RECOMMENDATION_ALGORITHM_VERSION_V1
            && batch_metadata.recommendation_policy_version == "weighted_v1"
            && next == continuation
            && items.len() == 1
            && items[0].paper.paper_id == paper.id
    ));
    assert!(matches!(
        repository
            .explanation(account.id, first_batch_id, paper.id, now)
            .await
            .unwrap(),
        RecommendationExplanationReadOutcome::Found {
            batch_id,
            paper_id,
            explanations,
        } if batch_id == first_batch_id
            && paper_id == paper.id
            && !explanations.is_empty()
            && explanations.iter().all(|explanation| !explanation.behavior_used)
    ));

    // Relevant feedback is still stored and fenced while personalization is
    // off, but it must not create a feedback-derived profile or affinity.
    let opt_out_batch_id = Uuid::now_v7();
    assert!(matches!(
        repository
            .persist_ready(RecommendationBatchPersistRequest {
                user_id: account.id,
                batch_id: opt_out_batch_id,
                query_key: "recent:personalization-off-affinity",
                local_date,
                created_at: now,
                expires_at: now + chrono::Duration::days(7),
                next_position: None,
                saved_search_revision_digest: None,
                batch: &batch,
            })
            .await
            .unwrap(),
        RecommendationBatchPersistOutcome::Ready { batch_id, .. }
            if batch_id == opt_out_batch_id
    ));
    let relevant_feedback_id = Uuid::now_v7();
    assert_eq!(
        repository
            .record_feedback(RecommendationFeedbackWrite {
                user_id: account.id,
                feedback_id: relevant_feedback_id,
                idempotency_key: Uuid::now_v7(),
                batch_id: opt_out_batch_id,
                paper_id: paper.id,
                feedback_type: RecommendationFeedbackType::Relevant,
                reason: None,
                created_at: now,
            })
            .await
            .unwrap(),
        RecommendationFeedbackOutcome::Applied {
            feedback_id: relevant_feedback_id,
            mode: RecommendationMode::Recent,
        }
    );
    let derived_profile_rows: (i64, i64) = sqlx::query_as(
        r"
        SELECT
          (SELECT count(*) FROM research_profiles WHERE user_id = $1)::bigint,
          (SELECT count(*) FROM profile_categories
             WHERE user_id = $1 AND source = 'feedback')::bigint
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(derived_profile_rows, (0, 0));

    let feedback_id = Uuid::now_v7();
    let feedback_key = Uuid::now_v7();
    let feedback = RecommendationFeedbackWrite {
        user_id: account.id,
        feedback_id,
        idempotency_key: feedback_key,
        batch_id: first_batch_id,
        paper_id: paper.id,
        feedback_type: RecommendationFeedbackType::NotRelevant,
        reason: Some(RecommendationFeedbackReason::OffTopic),
        created_at: now,
    };
    assert_eq!(
        repository.record_feedback(feedback).await.unwrap(),
        RecommendationFeedbackOutcome::Applied {
            feedback_id,
            mode: RecommendationMode::Recent,
        }
    );
    assert_eq!(
        repository.record_feedback(feedback).await.unwrap(),
        RecommendationFeedbackOutcome::Replayed {
            feedback_id,
            mode: RecommendationMode::Recent,
        }
    );
    let feedback_context = repository
        .feedback_context(account.id, &[paper.id], now)
        .await
        .unwrap();
    assert_eq!(feedback_context.revision, 2);
    assert!(feedback_context.history[&paper.id].negative_feedback);
    let feedback_superseded: String =
        sqlx::query_scalar("SELECT status FROM recommendation_batches WHERE id = $1")
            .bind(first_batch_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(feedback_superseded, "superseded");
    assert_eq!(
        repository
            .record_feedback(RecommendationFeedbackWrite {
                feedback_type: RecommendationFeedbackType::Relevant,
                reason: None,
                ..feedback
            })
            .await
            .unwrap(),
        RecommendationFeedbackOutcome::IdempotencyConflict {
            mode: RecommendationMode::Recent,
        }
    );

    let library = database.library();
    assert!(matches!(
        library
            .mutate(
                account.id,
                paper.id,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        db::LibraryMutationOutcome::Applied { .. }
    ));
    let status: String =
        sqlx::query_scalar("SELECT status FROM recommendation_batches WHERE id = $1")
            .bind(first_batch_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(status, "superseded");

    let later_date = local_date.checked_add_days(Days::new(1)).unwrap();
    assert!(matches!(
        repository
            .persist_ready(RecommendationBatchPersistRequest {
                user_id: account.id,
                batch_id: Uuid::now_v7(),
                query_key: "recent:all",
                local_date: later_date,
                created_at: now,
                expires_at: now + chrono::Duration::days(7),
                next_position: None,
                saved_search_revision_digest: None,
                batch: &batch,
            })
            .await
            .unwrap(),
        RecommendationBatchPersistOutcome::Superseded {
            current_library_revision: 1,
            active_count: 1,
            ..
        }
    ));
    let blocked_id = Uuid::now_v7();
    assert!(matches!(
        repository
            .record_blocked_by_queue(RecommendationBatchBlockRequest {
                user_id: account.id,
                batch_id: blocked_id,
                mode: RecommendationMode::Following,
                query_key: "following:all",
                local_date,
                profile_revision: None,
                feedback_revision: 2,
                saved_search_revision_digest: None,
                algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
                policy_version: "weighted_v1",
                seed: 7,
                created_at: now,
                expires_at: now + chrono::Duration::days(7),
            })
            .await
            .unwrap(),
        RecommendationBatchBlockOutcome::BlockedByQueue {
            batch_id,
            library_revision: 1,
            active_count: 1,
        } if batch_id == blocked_id
    ));

    assert!(matches!(
        library
            .mutate(
                account.id,
                paper.id,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        db::LibraryMutationOutcome::Applied { .. }
    ));
    assert_eq!(
        repository
            .record_blocked_by_queue(RecommendationBatchBlockRequest {
                user_id: account.id,
                batch_id: Uuid::now_v7(),
                mode: RecommendationMode::Explore,
                query_key: "explore:all",
                local_date,
                profile_revision: None,
                feedback_revision: 2,
                saved_search_revision_digest: None,
                algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
                policy_version: "weighted_v1",
                seed: 8,
                created_at: now,
                expires_at: now + chrono::Duration::days(7),
            })
            .await
            .unwrap(),
        RecommendationBatchBlockOutcome::QueueProvenEmpty {
            library_revision: 2
        }
    );

    assert!(matches!(
        library
            .mutate(
                account.id,
                paper.id,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Reviewed,
            )
            .await
            .unwrap(),
        db::LibraryMutationOutcome::Applied { .. }
    ));
    let historical_seeds = repository.historical_seeds(account.id, 10).await.unwrap();
    assert_eq!(historical_seeds.len(), 1);
    assert_eq!(
        historical_seeds[0].embedding.len(),
        recommendations::METADATA_EMBEDDING_DIMENSIONS_V1
    );
    assert!(
        historical_seeds[0]
            .embedding
            .iter()
            .any(|value| *value > 0.0)
    );

    let cleanup = repository
        .cleanup_retention(
            now + chrono::Duration::days(200),
            now + chrono::Duration::days(181),
            100,
        )
        .await
        .unwrap();
    assert!(cleanup.batches >= 2);
    assert_eq!(cleanup.feedback, 2);
    let remaining_batches: i64 =
        sqlx::query_scalar("SELECT count(*) FROM recommendation_batches WHERE user_id = $1")
            .bind(account.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    let remaining_feedback: i64 =
        sqlx::query_scalar("SELECT count(*) FROM recommendation_feedback WHERE user_id = $1")
            .bind(account.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(remaining_batches, 0);
    assert_eq!(remaining_feedback, 0);
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_generation_jobs_bind_context_leases_retention_and_account_cascade() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL generation-job coverage");
        return;
    };
    let database = Database::connect(&database_url, 12).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://recommendation-jobs.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let paper_metadata = metadata(&format!("{unique}-job"));
    let paper = database
        .papers()
        .upsert_metadata(&paper_metadata)
        .await
        .unwrap();
    let saved_search_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO saved_searches (
            id, user_id, definition_fingerprint, normalized_query,
            categories, topics, sources, sort
        ) VALUES ($1, $2, $3, 'bounded metadata recommendation',
                  ARRAY['cs.CL'], ARRAY['quantum', 'metadata'], ARRAY['arxiv'], 'relevance')
        ",
    )
    .bind(saved_search_id)
    .bind(account.id.into_inner())
    .bind(vec![0x71_u8; 32])
    .execute(database.pool())
    .await
    .unwrap();

    let repository = database.recommendation_generation();
    let paper_ids = [paper.id];
    let saved_context = repository
        .saved_search_context(account.id, &paper_ids)
        .await
        .unwrap();
    assert_eq!(
        saved_context.matches.get(&paper.id),
        Some(&saved_search_id),
        "Following must preserve Explore's any-topic saved-search semantics"
    );
    let now = Utc::now();
    let next_position = RecommendationPosition {
        published_at: paper_metadata.published_at,
        paper_id: paper.id,
    };
    let job_id = Uuid::now_v7();
    let batch_id = Uuid::now_v7();
    let request = RecommendationGenerationEnqueue {
        user_id: account.id,
        job_id,
        batch_id,
        mode: RecommendationMode::Following,
        query_key: "following:v2:first",
        local_date: now.date_naive(),
        profile_revision: None,
        feedback_revision: 0,
        library_revision: 0,
        algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
        policy_version: "weighted_v1",
        seed: 41,
        page_limit: 1,
        candidate_paper_ids: &paper_ids,
        saved_search_revision_digest: Some(saved_context.revision_digest),
        next_position: Some(next_position),
        max_attempts: 3,
        now,
    };
    assert_eq!(
        repository.enqueue(request).await.unwrap(),
        RecommendationGenerationEnqueueOutcome::Queued { job_id, batch_id }
    );
    assert!(matches!(
        repository
            .enqueue(RecommendationGenerationEnqueue {
                job_id: Uuid::now_v7(),
                batch_id: Uuid::now_v7(),
                ..request
            })
            .await
            .unwrap(),
        RecommendationGenerationEnqueueOutcome::Replayed {
            job_id: replayed_job,
            batch_id: replayed_batch,
            state: RecommendationGenerationJobState::Queued,
        } if replayed_job == job_id && replayed_batch == batch_id
    ));
    let claimed = repository
        .claim("generation-worker-one", now, Duration::from_secs(5))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(claimed.job_id, job_id);
    assert_eq!(claimed.next_position, Some(next_position));
    assert_eq!(claimed.candidate_count, 1);
    assert_eq!(
        repository.candidates(job_id).await.unwrap()[0].paper_id,
        paper.id
    );

    let reclaimed_at = now + chrono::Duration::seconds(6);
    let reclaimed = repository
        .claim(
            "generation-worker-two",
            reclaimed_at,
            Duration::from_secs(5),
        )
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reclaimed.job_id, job_id);
    assert_eq!(reclaimed.attempt, 2);
    assert!(matches!(
        repository
            .complete(
                job_id,
                "generation-worker-one",
                reclaimed_at + chrono::Duration::seconds(1),
                RecommendationGenerationJobState::Completed,
            )
            .await,
        Err(RecommendationGenerationRepositoryError::LeaseLost)
    ));
    repository
        .complete(
            job_id,
            "generation-worker-two",
            reclaimed_at + chrono::Duration::seconds(1),
            RecommendationGenerationJobState::Completed,
        )
        .await
        .unwrap();
    assert!(matches!(
        repository
            .enqueue(RecommendationGenerationEnqueue {
                job_id: Uuid::now_v7(),
                batch_id: Uuid::now_v7(),
                ..request
            })
            .await
            .unwrap(),
        RecommendationGenerationEnqueueOutcome::Replayed {
            state: RecommendationGenerationJobState::Completed,
            ..
        }
    ));

    sqlx::query(
        "UPDATE saved_searches SET revision = revision + 1, updated_at = statement_timestamp() WHERE id = $1",
    )
    .bind(saved_search_id)
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        repository
            .enqueue(RecommendationGenerationEnqueue {
                job_id: Uuid::now_v7(),
                batch_id: Uuid::now_v7(),
                ..request
            })
            .await
            .unwrap(),
        RecommendationGenerationEnqueueOutcome::ContextChanged
    );
    sqlx::query(
        "UPDATE recommendation_generation_jobs SET completed_at = $2, created_at = $2, updated_at = $2 WHERE id = $1",
    )
    .bind(job_id)
    .bind(now - chrono::Duration::days(40))
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        repository
            .cleanup_completed(now - chrono::Duration::days(30), 100)
            .await
            .unwrap()
            .removed,
        1
    );

    let current_saved_context = repository
        .saved_search_context(account.id, &paper_ids)
        .await
        .unwrap();
    let old_queued_id = Uuid::now_v7();
    repository
        .enqueue(RecommendationGenerationEnqueue {
            user_id: account.id,
            job_id: old_queued_id,
            batch_id: Uuid::now_v7(),
            mode: RecommendationMode::Following,
            query_key: "following:v2:rollback-old",
            local_date: now.date_naive(),
            profile_revision: None,
            feedback_revision: 0,
            library_revision: 0,
            algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
            policy_version: "weighted_v1",
            seed: 42,
            page_limit: 1,
            candidate_paper_ids: &paper_ids,
            saved_search_revision_digest: Some(current_saved_context.revision_digest),
            next_position: Some(next_position),
            max_attempts: 3,
            now,
        })
        .await
        .unwrap();
    sqlx::query(
        "UPDATE recommendation_generation_jobs SET created_at = $2, updated_at = $2 WHERE id = $1",
    )
    .bind(old_queued_id)
    .bind(now - chrono::Duration::days(40))
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        repository
            .cleanup_completed(now - chrono::Duration::days(30), 100)
            .await
            .unwrap()
            .removed,
        1,
        "rollback-safe retention removes old queued work"
    );

    let live_job_id = Uuid::now_v7();
    repository
        .enqueue(RecommendationGenerationEnqueue {
            user_id: account.id,
            job_id: live_job_id,
            batch_id: Uuid::now_v7(),
            mode: RecommendationMode::Following,
            query_key: "following:v2:live-lease",
            local_date: now.date_naive(),
            profile_revision: None,
            feedback_revision: 0,
            library_revision: 0,
            algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
            policy_version: "weighted_v1",
            seed: 43,
            page_limit: 1,
            candidate_paper_ids: &paper_ids,
            saved_search_revision_digest: Some(current_saved_context.revision_digest),
            next_position: Some(next_position),
            max_attempts: 3,
            now,
        })
        .await
        .unwrap();
    repository
        .claim("generation-live-owner", Utc::now(), Duration::from_secs(60))
        .await
        .unwrap()
        .unwrap();
    sqlx::query("UPDATE recommendation_generation_jobs SET created_at = $2 WHERE id = $1")
        .bind(live_job_id)
        .bind(now - chrono::Duration::days(40))
        .execute(database.pool())
        .await
        .unwrap();
    let live_cleanup = repository
        .cleanup_completed(now - chrono::Duration::days(30), 100)
        .await
        .unwrap();
    assert_eq!(live_cleanup.removed, 0, "retention preserves a live lease");
    assert_eq!(live_cleanup.backlog_items, 1);
    assert!(
        live_cleanup
            .oldest_age_seconds
            .is_some_and(|age| age >= 0.0)
    );
    sqlx::query(
        "UPDATE recommendation_generation_jobs SET lease_expires_at = statement_timestamp() - interval '1 second' WHERE id = $1",
    )
    .bind(live_job_id)
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        repository
            .cleanup_completed(now - chrono::Duration::days(30), 100)
            .await
            .unwrap()
            .removed,
        1,
        "retention removes only an expired old lease"
    );

    let cascade_job_id = Uuid::now_v7();
    repository
        .enqueue(RecommendationGenerationEnqueue {
            user_id: account.id,
            job_id: cascade_job_id,
            batch_id: Uuid::now_v7(),
            mode: RecommendationMode::Following,
            query_key: "following:v2:account-cascade",
            local_date: now.date_naive(),
            profile_revision: None,
            feedback_revision: 0,
            library_revision: 0,
            algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
            policy_version: "weighted_v1",
            seed: 44,
            page_limit: 1,
            candidate_paper_ids: &paper_ids,
            saved_search_revision_digest: Some(current_saved_context.revision_digest),
            next_position: Some(next_position),
            max_attempts: 3,
            now,
        })
        .await
        .unwrap();
    assert!(matches!(
        database
            .library()
            .mutate(
                account.id,
                paper.id,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        db::LibraryMutationOutcome::Applied { .. }
    ));
    assert!(matches!(
        repository
            .enqueue(RecommendationGenerationEnqueue {
                user_id: account.id,
                job_id: Uuid::now_v7(),
                batch_id: Uuid::now_v7(),
                mode: RecommendationMode::Following,
                query_key: "following:v2:blocked",
                local_date: now.date_naive(),
                profile_revision: None,
                feedback_revision: 0,
                library_revision: 0,
                algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
                policy_version: "weighted_v1",
                seed: 45,
                page_limit: 1,
                candidate_paper_ids: &paper_ids,
                saved_search_revision_digest: Some(current_saved_context.revision_digest),
                next_position: Some(next_position),
                max_attempts: 3,
                now,
            })
            .await
            .unwrap(),
        RecommendationGenerationEnqueueOutcome::AuthorityChanged {
            library_revision: 1,
            active_count: 1,
        }
    ));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let remaining_jobs: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM recommendation_generation_jobs WHERE user_id = $1",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    let remaining_candidates: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM recommendation_generation_candidates WHERE job_id = $1",
    )
    .bind(cascade_job_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(remaining_jobs, 0);
    assert_eq!(remaining_candidates, 0);
}

fn metadata(unique: &str) -> PaperMetadata {
    let suffix = 10_000 + (Uuid::now_v7().as_u128() % 90_000) as u32;
    let arxiv_id = ArxivIdentifier {
        base_id: format!("2608.{suffix:05}"),
        version: 1,
    };
    PaperMetadata {
        arxiv_id: arxiv_id.clone(),
        title: format!("Recommendation fixture {unique}"),
        abstract_text: "A bounded metadata-only recommendation fixture.".to_owned(),
        authors: vec![Author::from("Ada Reader".to_owned())],
        primary_category: "cs.CL".to_owned(),
        categories: vec!["cs.CL".to_owned()],
        published_at: Utc::now() - chrono::Duration::days(1),
        updated_at: Utc::now() - chrono::Duration::days(1),
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{}", arxiv_id.versioned())).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{}", arxiv_id.versioned())).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: None,
        metadata_fetched_at: Utc::now(),
    }
}
