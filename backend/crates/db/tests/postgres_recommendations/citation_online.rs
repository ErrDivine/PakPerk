use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
    time::Duration,
};

use chrono::{DateTime, TimeDelta, Utc};
use db::{
    Database, LibraryItemMutation, LibraryMutationIntent, RecommendationBatchPersistOutcome,
    RecommendationBatchPersistRequest, RecommendationBatchRepositoryError,
    RecommendationBatchServeOutcome, RecommendationBatchServeRequest,
    RecommendationExplanationReadOutcome, RecommendationFeedbackOutcome,
    RecommendationFeedbackType, RecommendationFeedbackWrite, RecommendationGenerationEnqueue,
    RecommendationGenerationEnqueueOutcome,
};
use domain::{AuthenticatedUserId, LibrarySaveSourceKind, LibraryState, PaperId};
use reading_feed::{
    ReadingFeedSnapshot, ReadingFeedSnapshotRequest, ReadingFeedStore, RecommendationPage,
};
use recommendations::{
    BuiltRecommendationBatch, CandidateDocument, CandidateFanoutPolicy, CitationDirection,
    DiscoveryProfileSnapshot, ExplanationCode, LearnerWeights, ProvenEmptyQueueBinding,
    RECOMMENDATION_ALGORITHM_VERSION_V1, RecommendationBatchBuildRequest, RecommendationMode,
    RerankPolicy, SCORING_POLICY_VERSION_CITATION_ONLINE_V1 as CITATION_POLICY,
    SCORING_POLICY_VERSION_V1 as WEIGHTED_POLICY, ScoringPolicy, build_recommendation_batch,
};
use research_profiles::{
    ResearchProfilePolicy, ResearchProfileService, ResetProfileCommand, ResetScope,
    UpdateProfileCommand,
};
use uuid::Uuid;

use super::{RETENTION_FIXTURES, metadata};

async fn connect() -> Option<Database> {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL citation coverage");
        return None;
    };
    let database = Database::connect(&database_url, 12).await.unwrap();
    database.migrate_embedded().await.unwrap();
    Some(database)
}

async fn profile_user(database: &Database) -> AuthenticatedUserId {
    database
        .accounts()
        .provision_oidc_identity(
            &format!("https://citation-tests.example/{}", Uuid::now_v7()),
            "owner",
            Duration::from_mins(15),
        )
        .await
        .unwrap()
        .id
}

fn profile_service(database: &Database) -> ResearchProfileService {
    ResearchProfileService::new(
        Arc::new(database.research_profiles()),
        Arc::new(database.rate_limits()),
        ResearchProfilePolicy::default(),
    )
}

async fn set_consent(database: &Database, user_id: AuthenticatedUserId, enabled: bool) {
    let profile = profile_service(database);
    let revision = profile.get(user_id).await.unwrap().profile_revision;
    profile
        .update(
            user_id,
            UpdateProfileCommand {
                expected_revision: revision,
                operation_id: Uuid::now_v7(),
                personalization_enabled: Some(enabled),
                ..UpdateProfileCommand::default()
            },
        )
        .await
        .unwrap();
}

fn category() -> String {
    format!("cf.A{}", &Uuid::now_v7().simple().to_string()[18..26])
}

async fn paper(database: &Database, category: &str, published_at: DateTime<Utc>) -> PaperId {
    let key = Uuid::now_v7().simple().to_string();
    let mut row = metadata(&key);
    row.arxiv_id.base_id = format!("fixture.{}", &key[10..]);
    category.clone_into(&mut row.primary_category);
    row.categories = vec![category.to_owned()];
    row.published_at = published_at;
    row.updated_at = published_at;
    database.papers().upsert_metadata(&row).await.unwrap().id
}

async fn mutate_library(
    database: &Database,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
    intent: LibraryMutationIntent,
    state: LibraryState,
) {
    assert!(matches!(
        database
            .library()
            .mutate_item(
                user_id,
                paper_id,
                Uuid::now_v7(),
                intent,
                LibraryItemMutation::replace(
                    state,
                    Some("Private note absent from graph evidence".to_owned()),
                    Some(LibrarySaveSourceKind::ArxivId),
                ),
            )
            .await
            .unwrap(),
        db::LibraryMutationOutcome::Applied { .. }
    ));
}

async fn edges(database: &Database, citing: &[PaperId], cited: &[PaperId], generation: i32) {
    sqlx::query(
        r"
        WITH inserted_refs AS (
            INSERT INTO paper_references (
                citing_paper_id, generation, ordinal, raw_text,
                resolved_paper_id, resolution_status, resolution_confidence, resolution_method
            )
            SELECT citing.id, $3,
                   row_number() OVER (PARTITION BY citing.id ORDER BY cited.id) - 1,
                   'public reference', cited.id, 'resolved', 1.0, 'fixture'
            FROM unnest($1::uuid[]) AS citing(id)
            CROSS JOIN unnest($2::uuid[]) AS cited(id)
            RETURNING id, citing_paper_id, resolved_paper_id
        )
        INSERT INTO paper_connections (
            citing_paper_id, cited_paper_id, reference_id, generation,
            relation_type, summary, confidence, source_context_ids
        )
        SELECT citing_paper_id, resolved_paper_id, id, $3,
               'related_work', 'Resolved reference', 1.0, '{}'
        FROM inserted_refs
        ",
    )
    .bind(citing)
    .bind(cited)
    .bind(generation)
    .execute(database.pool())
    .await
    .unwrap();
}

async fn authorized_page(
    database: &Database,
    user_id: AuthenticatedUserId,
    category: &str,
    limit: u32,
) -> (i64, RecommendationPage) {
    let ReadingFeedSnapshot::Empty {
        library_revision,
        recommendations,
    } = database
        .reading_feed()
        .snapshot(&ReadingFeedSnapshotRequest {
            user_id,
            category: Some(category.to_owned()),
            continuation: None,
            limit,
        })
        .await
        .unwrap()
    else {
        panic!("fixture account must have an empty queue");
    };
    (library_revision, recommendations)
}

async fn insert_fixture_feedback(
    database: &Database,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
    kind: &str,
    mask: Option<i16>,
    created_at: DateTime<Utc>,
) {
    sqlx::query(
        r"
        INSERT INTO recommendation_feedback (
            id, user_id, paper_id, feedback_type, feature_mask, idempotency_key, created_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7)
        ",
    )
    .bind(Uuid::now_v7())
    .bind(user_id.into_inner())
    .bind(paper_id)
    .bind(kind)
    .bind(mask)
    .bind(Uuid::now_v7())
    .bind(created_at)
    .execute(database.pool())
    .await
    .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn graph_is_bounded_by_ranked_roots_and_chronological_page() {
    let _retention = RETENTION_FIXTURES.lock().await;
    let Some(database) = connect().await else {
        return;
    };
    let user_id = profile_user(&database).await;
    set_consent(&database, user_id, true).await;
    let now = Utc::now();
    let page_category = category();
    let roots_category = category();
    let mut roots = Vec::new();
    for index in 0..66 {
        let root = paper(&database, &roots_category, now - TimeDelta::days(2)).await;
        let state = if matches!(index, 1 | 2) {
            LibraryState::Archived
        } else {
            LibraryState::Reviewed
        };
        mutate_library(&database, user_id, root, LibraryMutationIntent::Save, state).await;
        roots.push(root);
    }
    mutate_library(
        &database,
        user_id,
        roots[4],
        LibraryMutationIntent::Remove,
        LibraryState::Inbox,
    )
    .await;
    sqlx::query(
        r"
        UPDATE user_paper_library
        SET saved_at = $3,
            reviewed_at = CASE WHEN state = 'reviewed' THEN $3 END,
            archived_at = CASE WHEN state = 'archived' THEN $3 END,
            updated_at = CASE WHEN paper_id = $2 THEN $3 ELSE $4 END
        WHERE user_id = $1 AND removed_at IS NULL
        ",
    )
    .bind(user_id.into_inner())
    .bind(roots[0])
    .bind(now - TimeDelta::days(3))
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();

    // A consented positive with mask zero qualifies. The null-mask dismissal
    // independently vetoes a positive on the same reviewed root.
    for (root, kind, mask) in [
        (roots[0], "relevant", Some(0)),
        (roots[1], "relevant", Some(0)),
        (roots[2], "relevant", None),
        (roots[3], "dismissed", None),
        (roots[3], "relevant", Some(0)),
    ] {
        insert_fixture_feedback(&database, user_id, root, kind, mask, now).await;
    }

    let mut candidates = Vec::new();
    for index in 0..52 {
        candidates.push(paper(&database, &page_category, now - TimeDelta::seconds(index)).await);
    }
    let wrong_category = paper(&database, &category(), now + TimeDelta::days(1)).await;
    edges(&database, &roots, &candidates, 1).await;
    edges(&database, &[candidates[0]], &[roots[0]], 1).await;
    edges(&database, &[candidates[1]], &[roots[0]], 2).await;
    edges(&database, &[wrong_category], &[roots[0]], 1).await;

    let mut weakest = roots[5..].to_vec();
    weakest.sort_unstable();
    let mut selected = weakest[..9].iter().copied().collect::<BTreeSet<_>>();
    selected.insert(roots[0]);
    for limit in [20, 50] {
        let (revision, page) = authorized_page(&database, user_id, &page_category, limit).await;
        let ids = page
            .items
            .iter()
            .map(|item| item.paper_id)
            .collect::<Vec<_>>();
        assert_eq!(ids, candidates[..limit as usize]);
        assert_eq!(
            page.next_position.unwrap().paper_id,
            ids[limit as usize - 1]
        );
        let context = database
            .recommendation_batches()
            .citation_learning_context(user_id, &ids, now)
            .await
            .unwrap();
        assert_eq!(context.library_revision, revision);
        assert_eq!(context.feedback.revision, page.feedback_revision);
        assert!(
            context
                .historical_seeds
                .iter()
                .all(|seed| seed.paper_id != roots[0])
        );
        assert_eq!(context.citation.pairs.len(), 10 * ids.len());
        for pair in &context.citation.pairs {
            assert!(selected.contains(&pair.root.paper_id));
            assert!(ids.contains(&pair.candidate_paper_id));
            assert_eq!(
                pair.direction,
                if pair.root.paper_id == roots[0] && pair.candidate_paper_id == candidates[0] {
                    CitationDirection::Reciprocal
                } else {
                    CitationDirection::Reference
                }
            );
            assert!(pair.root.title.starts_with("Recommendation fixture"));
            assert_eq!(
                pair.root.tier,
                if pair.root.paper_id == roots[0] { 4 } else { 3 }
            );
        }
    }

    sqlx::query(
        "UPDATE user_paper_library SET removed_at = $2 WHERE user_id = $1 AND paper_id = ANY($3)",
    )
    .bind(user_id.into_inner())
    .bind(now)
    .bind(&weakest[1..])
    .execute(database.pool())
    .await
    .unwrap();
    let context = database
        .recommendation_batches()
        .citation_learning_context(user_id, &candidates[..2], now)
        .await
        .unwrap();
    assert_eq!(context.citation.pairs.len(), 6);
    assert_eq!(
        context
            .citation
            .pairs
            .iter()
            .map(|pair| (pair.root.paper_id, pair.root.tier))
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([(roots[0], 4), (weakest[0], 3), (roots[1], 2)])
    );
    set_consent(&database, user_id, false).await;
    set_consent(&database, user_id, true).await;
    let context = database
        .recommendation_batches()
        .citation_learning_context(user_id, &candidates[..2], now)
        .await
        .unwrap();
    assert_eq!(
        context
            .citation
            .pairs
            .iter()
            .map(|pair| (pair.root.paper_id, pair.root.tier))
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([(roots[0], 3), (weakest[0], 3)])
    );
}

async fn build(
    database: &Database,
    user_id: AuthenticatedUserId,
    paper_ids: &[PaperId],
    now: DateTime<Utc>,
    policy: &str,
) -> BuiltRecommendationBatch {
    let context = database
        .recommendation_batches()
        .citation_learning_context(user_id, paper_ids, now)
        .await
        .unwrap();
    let mut documents = Vec::new();
    for paper_id in paper_ids {
        documents.push(CandidateDocument {
            paper: database
                .papers()
                .get_summary(*paper_id)
                .await
                .unwrap()
                .unwrap(),
            topics: BTreeSet::new(),
            embedding: Vec::new(),
            citation_neighbors: BTreeSet::new(),
            metadata_completeness: 1.0,
        });
    }
    build_recommendation_batch(RecommendationBatchBuildRequest {
        mode: if policy == CITATION_POLICY {
            RecommendationMode::ForYou
        } else {
            RecommendationMode::Recent
        },
        queue: ProvenEmptyQueueBinding::from_decision(context.library_revision, 0, true).unwrap(),
        profile_revision: context.profile_revision,
        feedback_revision: context.feedback.revision,
        profile: &DiscoveryProfileSnapshot {
            personalization_enabled: context.personalization_enabled,
            categories: BTreeSet::new(),
            topics: BTreeSet::new(),
            authors: BTreeSet::from(["Ada Reader".to_owned()]),
            saved_query_matches: BTreeMap::new(),
            feedback_categories: BTreeSet::new(),
            inferred_categories: BTreeSet::new(),
            historical_seeds: context.historical_seeds,
        },
        documents: &documents,
        candidate_history: &context.feedback.history,
        now,
        candidate_limit: 20,
        fanout_policy: CandidateFanoutPolicy::default(),
        generator_observer: None,
        rerank_policy: RerankPolicy {
            max_per_author: 20,
            max_per_category: 20,
            ..RerankPolicy::default()
        },
        scoring_policy: ScoringPolicy {
            version: policy.to_owned(),
            ..ScoringPolicy::default()
        },
        citation_online: (policy == CITATION_POLICY).then_some(&context.citation),
    })
    .await
    .unwrap()
}

async fn publish(
    database: &Database,
    user_id: AuthenticatedUserId,
    batch_id: Uuid,
    batch: &BuiltRecommendationBatch,
    now: DateTime<Utc>,
) -> RecommendationBatchPersistOutcome {
    database
        .recommendation_batches()
        .persist_ready(RecommendationBatchPersistRequest {
            user_id,
            batch_id,
            query_key: &format!("fixture-{batch_id}"),
            local_date: now.date_naive(),
            created_at: now,
            expires_at: now + TimeDelta::hours(24),
            next_position: None,
            saved_search_revision_digest: None,
            batch,
        })
        .await
        .unwrap()
}

fn serve_request(
    user_id: AuthenticatedUserId,
    batch_id: Uuid,
    batch: &BuiltRecommendationBatch,
    now: DateTime<Utc>,
) -> RecommendationBatchServeRequest<'_> {
    RecommendationBatchServeRequest {
        user_id,
        batch_id,
        now,
        mode: batch.mode,
        policy_version: &batch.policy_version,
        library_revision: batch.library_revision,
        limit: 20,
    }
}

fn rating(
    user_id: AuthenticatedUserId,
    batch_id: Uuid,
    paper_id: PaperId,
    feedback_type: RecommendationFeedbackType,
    created_at: DateTime<Utc>,
) -> RecommendationFeedbackWrite {
    RecommendationFeedbackWrite {
        user_id,
        batch_id,
        paper_id,
        feedback_type,
        created_at,
        feedback_id: Uuid::now_v7(),
        idempotency_key: Uuid::now_v7(),
        reason: None,
    }
}

async fn mask(database: &Database, feedback_id: Uuid) -> Option<i16> {
    sqlx::query_scalar("SELECT feature_mask FROM recommendation_feedback WHERE id = $1")
        .bind(feedback_id)
        .fetch_one(database.pool())
        .await
        .unwrap()
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn served_feedback_replays_from_stored_evidence_and_retains_votes_past_batch_expiry() {
    let _retention = RETENTION_FIXTURES.lock().await;
    let Some(database) = connect().await else {
        return;
    };
    let repository = database.recommendation_batches();
    let user_id = profile_user(&database).await;
    let other = profile_user(&database).await;
    let unaffected = profile_user(&database).await;
    set_consent(&database, user_id, true).await;
    let now = Utc::now();
    let paper_category = category();
    let root = paper(&database, &category(), now - TimeDelta::days(5)).await;
    let candidate = paper(&database, &paper_category, now).await;
    let unserved = paper(&database, &paper_category, now - TimeDelta::days(1)).await;
    let extra = paper(&database, &paper_category, now - TimeDelta::days(2)).await;
    mutate_library(
        &database,
        user_id,
        root,
        LibraryMutationIntent::Save,
        LibraryState::Reviewed,
    )
    .await;
    edges(&database, &[root], &[candidate, unserved], 1).await;
    edges(&database, &[candidate], &[root], 1).await;
    let (library_revision, page) = authorized_page(&database, user_id, &paper_category, 2).await;
    let batch = build(
        &database,
        user_id,
        &[candidate, unserved],
        now,
        CITATION_POLICY,
    )
    .await;
    assert_eq!(
        batch.candidates[0].scored.candidate.document.paper.paper_id,
        candidate
    );
    assert_eq!(
        batch.candidates[0]
            .citation_evidence
            .as_ref()
            .unwrap()
            .feature_mask,
        7
    );
    let batch_id = Uuid::now_v7();
    let mut corrupt = batch.clone();
    corrupt.candidates[0].citation_evidence = None;
    assert!(matches!(
        repository
            .persist_ready(RecommendationBatchPersistRequest {
                user_id,
                batch_id,
                query_key: "invalid-evidence",
                local_date: now.date_naive(),
                created_at: now,
                expires_at: now + TimeDelta::days(1),
                batch: &corrupt,
                next_position: None,
                saved_search_revision_digest: None,
            })
            .await,
        Err(RecommendationBatchRepositoryError::InvalidRequest)
    ));
    let stale_build = build(&database, user_id, &[extra], now, CITATION_POLICY).await;
    let stale_ready_id = Uuid::now_v7();
    publish(&database, user_id, stale_ready_id, &stale_build, now).await;
    publish(&database, user_id, batch_id, &batch, now).await;

    let apply = RecommendationFeedbackType::Relevant;
    let write = rating(user_id, batch_id, candidate, apply, now);
    assert_eq!(
        repository
            .record_feedback(RecommendationFeedbackWrite {
                user_id: other,
                ..write
            })
            .await
            .unwrap(),
        RecommendationFeedbackOutcome::NotFound,
    );
    assert_eq!(
        repository
            .record_feedback(RecommendationFeedbackWrite {
                created_at: now + TimeDelta::days(1),
                ..write
            })
            .await
            .unwrap(),
        RecommendationFeedbackOutcome::NotFound,
    );
    assert!(matches!(
        repository.serve_ready(RecommendationBatchServeRequest {
            limit: 1, ..serve_request(user_id, batch_id, &batch, now)
        }).await.unwrap(),
        RecommendationBatchServeOutcome::Found { items, batch_metadata, .. }
            if items[0].paper.paper_id == candidate
                && batch_metadata.recommendation_policy_version == CITATION_POLICY
    ));

    sqlx::query("UPDATE paper_processing SET generation = 2 WHERE paper_id = $1 OR paper_id = $2")
        .bind(root)
        .bind(candidate)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("UPDATE papers SET title = 'New title after the serve' WHERE id = $1")
        .bind(root)
        .execute(database.pool())
        .await
        .unwrap();
    let revised_category = category();
    sqlx::query(
        r#"UPDATE papers
         SET authors = '[{"name":"Revised Author"}]'::jsonb, primary_category = $2,
             categories = ARRAY[$2, primary_category]
         WHERE id = $1"#,
    )
    .bind(candidate)
    .bind(&revised_category)
    .execute(database.pool())
    .await
    .unwrap();
    let RecommendationBatchServeOutcome::Found { items, .. } = repository
        .serve_ready(RecommendationBatchServeRequest {
            limit: 1,
            ..serve_request(user_id, batch_id, &batch, now)
        })
        .await
        .unwrap()
    else {
        panic!("the original batch should remain servable after a metadata revision");
    };
    assert_eq!(items[0].paper.paper_id, candidate);
    assert_eq!(items[0].paper.primary_category, revised_category);
    assert_eq!(items[0].paper.authors, ["Revised Author"]);
    let RecommendationExplanationReadOutcome::Found { explanations, .. } = repository
        .explanation(user_id, batch_id, candidate, now)
        .await
        .unwrap()
    else {
        panic!("the served evidence should replay with its original direction and title");
    };
    assert_eq!(explanations[0].code, ExplanationCode::ReviewedPaperCitation);
    assert!(explanations[0].detail.contains("cite each other"));
    assert!(explanations[0].detail.contains("Recommendation fixture"));
    assert_eq!(explanations[0].seed_paper_id, Some(root));
    assert_eq!(explanations, batch.candidates[0].explanations);

    let unserved_write = rating(user_id, batch_id, unserved, apply, now);
    assert!(matches!(
        repository.record_feedback(unserved_write).await.unwrap(),
        RecommendationFeedbackOutcome::Applied { .. }
    ));
    assert_eq!(mask(&database, unserved_write.feedback_id).await, Some(0));
    assert!(matches!(
        repository.record_feedback(write).await.unwrap(),
        RecommendationFeedbackOutcome::Applied { .. }
    ));
    assert_eq!(mask(&database, write.feedback_id).await, Some(7));

    // This author-only record is valid in isolation, but contradicts the
    // reciprocal citation reasons and sources stored for the served item.
    let replace_evidence = "UPDATE recommendation_candidates SET citation_evidence = $3 WHERE batch_id = $1 AND paper_id = $2";
    sqlx::query(replace_evidence)
        .bind(batch_id)
        .bind(candidate)
        .bind(serde_json::json!({
            "tier": 1,
            "feature_mask": 4,
            "overlap": false,
            "learned_adjustment": 0.0,
            "supporting_roots": [],
        }))
        .execute(database.pool())
        .await
        .unwrap();
    let fresh_write = rating(user_id, batch_id, candidate, apply, now);
    assert!(matches!(
        repository.record_feedback(fresh_write).await,
        Err(RecommendationBatchRepositoryError::InvalidPersistedData)
    ));
    assert!(matches!(
        repository.record_feedback(write).await.unwrap(),
        RecommendationFeedbackOutcome::Replayed { feedback_id, .. } if feedback_id == write.feedback_id
    ));
    assert_eq!(mask(&database, write.feedback_id).await, Some(7));
    assert!(matches!(
        repository
            .record_feedback(RecommendationFeedbackWrite {
                feedback_type: RecommendationFeedbackType::NotRelevant,
                ..write
            })
            .await
            .unwrap(),
        RecommendationFeedbackOutcome::IdempotencyConflict { .. }
    ));
    sqlx::query(replace_evidence)
        .bind(batch_id)
        .bind(candidate)
        .bind(serde_json::to_value(&batch.candidates[0].citation_evidence).unwrap())
        .execute(database.pool())
        .await
        .unwrap();
    let dismiss = rating(
        user_id,
        batch_id,
        candidate,
        RecommendationFeedbackType::Dismissed,
        now,
    );
    assert!(matches!(
        repository.record_feedback(dismiss).await.unwrap(),
        RecommendationFeedbackOutcome::Applied { .. }
    ));
    assert_eq!(mask(&database, dismiss.feedback_id).await, Some(0));

    assert_eq!(
        database
            .recommendation_generation()
            .enqueue(RecommendationGenerationEnqueue {
                user_id,
                job_id: Uuid::now_v7(),
                batch_id: Uuid::now_v7(),
                mode: RecommendationMode::ForYou,
                query_key: "page-read-before-feedback",
                local_date: now.date_naive(),
                profile_revision: profile_service(&database)
                    .get(user_id)
                    .await
                    .unwrap()
                    .profile_revision
                    .into(),
                feedback_revision: page.feedback_revision,
                library_revision,
                algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
                policy_version: CITATION_POLICY,
                seed: 3,
                page_limit: 2,
                candidate_paper_ids: &[candidate, unserved],
                saved_search_revision_digest: None,
                next_position: page.next_position,
                max_attempts: 2,
                now,
            })
            .await
            .unwrap(),
        RecommendationGenerationEnqueueOutcome::ContextChanged,
    );
    assert!(matches!(
        publish(&database, user_id, Uuid::now_v7(), &stale_build, now).await,
        RecommendationBatchPersistOutcome::Superseded { .. }
    ));
    assert!(matches!(
        repository
            .serve_ready(serve_request(user_id, stale_ready_id, &stale_build, now))
            .await
            .unwrap(),
        RecommendationBatchServeOutcome::AuthorityChanged { .. }
    ));

    let expired_at = now + TimeDelta::days(1);
    let vote_before = repository
        .citation_learning_context(user_id, &[], expired_at)
        .await
        .unwrap();
    assert!((vote_before.citation.weights.values()[0] - 7.0 / 13.0).abs() < 1.0e-6);
    assert_eq!(vote_before.feedback.revision, 3);
    repository
        .cleanup_retention(expired_at, now - TimeDelta::days(180), 1_000)
        .await
        .unwrap();
    let batch_fk: Option<Uuid> =
        sqlx::query_scalar("SELECT batch_id FROM recommendation_feedback WHERE id = $1")
            .bind(write.feedback_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(batch_fk, None);
    let vote_after = repository
        .citation_learning_context(user_id, &[], expired_at)
        .await
        .unwrap();
    assert_eq!(vote_before.citation.weights, vote_after.citation.weights);
    assert_eq!(vote_after.feedback.revision, 3);

    // A second account's old feedback advances its fence in the same cleanup
    // transaction. A third account has no expired feedback.
    insert_fixture_feedback(&database, other, extra, "not_relevant", None, now).await;
    mutate_library(
        &database,
        user_id,
        unserved,
        LibraryMutationIntent::Save,
        LibraryState::Reviewed,
    )
    .await;
    edges(&database, &[unserved], &[extra], 1).await;
    let context = repository
        .citation_learning_context(user_id, &[extra], expired_at)
        .await
        .unwrap();
    assert_eq!(context.citation.pairs[0].root.tier, 4);
    let late_batch = build(&database, user_id, &[extra], expired_at, CITATION_POLICY).await;
    let late_batch_id = Uuid::now_v7();
    publish(&database, user_id, late_batch_id, &late_batch, expired_at).await;
    repository
        .serve_ready(serve_request(
            user_id,
            late_batch_id,
            &late_batch,
            expired_at,
        ))
        .await
        .unwrap();
    repository
        .cleanup_retention(expired_at, now, 1_000)
        .await
        .unwrap();
    assert!(matches!(
        repository
            .serve_ready(serve_request(
                user_id,
                late_batch_id,
                &late_batch,
                expired_at
            ))
            .await
            .unwrap(),
        RecommendationBatchServeOutcome::AuthorityChanged { .. }
    ));
    repository
        .cleanup_retention(expired_at, now, 1_000)
        .await
        .unwrap();
    for (account, revision) in [(user_id, 4), (other, 1), (unaffected, 0)] {
        assert_eq!(
            repository
                .feedback_context(account, &[], expired_at)
                .await
                .unwrap()
                .revision,
            revision,
        );
    }
}

#[tokio::test]
async fn feedback_consent_is_gated_on_the_item_and_policy() {
    let _retention = RETENTION_FIXTURES.lock().await;
    let Some(database) = connect().await else {
        return;
    };
    let user_id = profile_user(&database).await;
    let repository = database.recommendation_batches();
    let now = Utc::now();
    let baseline = paper(&database, &category(), now).await;
    let ready = paper(&database, &category(), now).await;
    for (paper_id, policy, consent, actually_served, expected_mask) in [
        (baseline, WEIGHTED_POLICY, false, true, None),
        (baseline, WEIGHTED_POLICY, true, true, Some(0)),
        (ready, CITATION_POLICY, true, false, Some(0)),
    ] {
        if consent
            && !profile_service(&database)
                .get(user_id)
                .await
                .unwrap()
                .settings
                .personalization_enabled
        {
            set_consent(&database, user_id, true).await;
        }
        let batch = build(&database, user_id, &[paper_id], now, policy).await;
        let batch_id = Uuid::now_v7();
        publish(&database, user_id, batch_id, &batch, now).await;
        if actually_served {
            assert!(matches!(
                repository
                    .serve_ready(serve_request(user_id, batch_id, &batch, now))
                    .await
                    .unwrap(),
                RecommendationBatchServeOutcome::Found { .. }
            ));
        }
        let write = rating(
            user_id,
            batch_id,
            paper_id,
            RecommendationFeedbackType::Relevant,
            now,
        );
        assert!(matches!(
            repository.record_feedback(write).await.unwrap(),
            RecommendationFeedbackOutcome::Applied { .. }
        ));
        assert_eq!(mask(&database, write.feedback_id).await, expected_mask);
    }
    let profile = profile_service(&database).get(user_id).await.unwrap();
    assert_eq!(profile.interests.feedback.categories.len(), 2);
    set_consent(&database, user_id, false).await;
    let count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM recommendation_feedback WHERE user_id = $1 AND feature_mask IS NULL",
    )
    .bind(user_id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(count, 3);
    assert_eq!(
        repository
            .feedback_context(user_id, &[], now)
            .await
            .unwrap()
            .revision,
        4
    );
}

async fn wait_for_account_lock(database: &Database, user_id: AuthenticatedUserId) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let result = sqlx::query("SELECT id FROM users WHERE id = $1 FOR UPDATE NOWAIT")
                .bind(user_id.into_inner())
                .execute(database.pool())
                .await;
            match result {
                Ok(_) => tokio::time::sleep(Duration::from_millis(10)).await,
                Err(sqlx::Error::Database(error)) if error.code().as_deref() == Some("55P03") => {
                    break;
                }
                Err(error) => panic!("{error}"),
            }
        }
    })
    .await
    .expect("the first writer should lock the account before its blocked mutation");
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn feedback_and_privacy_writers_serialize_in_both_orders() {
    let _retention = RETENTION_FIXTURES.lock().await;
    let Some(database) = connect().await else {
        return;
    };
    for feedback_first in [true, false] {
        let user_id = profile_user(&database).await;
        set_consent(&database, user_id, true).await;
        let now = Utc::now();
        let reviewed = paper(&database, &category(), now).await;
        let candidate = paper(&database, &category(), now).await;
        let batch = build(&database, user_id, &[reviewed], now, CITATION_POLICY).await;
        let batch_id = Uuid::now_v7();
        let repository = database.recommendation_batches();
        publish(&database, user_id, batch_id, &batch, now).await;
        repository
            .serve_ready(serve_request(user_id, batch_id, &batch, now))
            .await
            .unwrap();
        // A negative avoids changing the profile revision expected by the
        // concurrent settings operation, and remains a root veto after erasure.
        let write = rating(
            user_id,
            batch_id,
            reviewed,
            RecommendationFeedbackType::NotRelevant,
            now,
        );
        let service = profile_service(&database);
        let opt_out = UpdateProfileCommand {
            expected_revision: 1,
            operation_id: Uuid::now_v7(),
            personalization_enabled: Some(false),
            ..UpdateProfileCommand::default()
        };
        let mut blocker = database.pool().begin().await.unwrap();
        if feedback_first {
            sqlx::query("LOCK TABLE recommendation_feedback IN SHARE MODE")
                .execute(&mut *blocker)
                .await
                .unwrap();
        } else {
            sqlx::query("LOCK TABLE research_profiles IN SHARE MODE")
                .execute(&mut *blocker)
                .await
                .unwrap();
        }

        let start_feedback =
            || tokio::spawn(async move { repository.record_feedback(write).await });
        let start_opt_out = || tokio::spawn(async move { service.update(user_id, opt_out).await });
        let (feedback, opt_out) = if feedback_first {
            let feedback = start_feedback();
            wait_for_account_lock(&database, user_id).await;
            (feedback, start_opt_out())
        } else {
            let opt_out = start_opt_out();
            wait_for_account_lock(&database, user_id).await;
            (start_feedback(), opt_out)
        };
        blocker.commit().await.unwrap();
        let accepted = feedback.await.unwrap().unwrap();
        assert!(matches!(
            accepted,
            RecommendationFeedbackOutcome::Applied { .. }
        ));
        opt_out.await.unwrap().unwrap();
        assert_eq!(mask(&database, write.feedback_id).await, None);
        set_consent(&database, user_id, true).await;
        let repository = database.recommendation_batches();
        assert!(matches!(
            repository.record_feedback(write).await.unwrap(),
            RecommendationFeedbackOutcome::Replayed { .. }
        ));
        assert_eq!(mask(&database, write.feedback_id).await, None);

        mutate_library(
            &database,
            user_id,
            reviewed,
            LibraryMutationIntent::Save,
            LibraryState::Reviewed,
        )
        .await;
        edges(&database, &[reviewed], &[candidate], 1).await;
        let context = repository
            .citation_learning_context(user_id, &[candidate], now)
            .await
            .unwrap();
        assert_eq!(context.citation.weights, LearnerWeights::default());
        assert!(
            context.citation.pairs.is_empty(),
            "erased negative still vetoes its root"
        );
        assert_eq!(
            context.feedback.revision,
            if feedback_first { 2 } else { 1 }
        );

        if feedback_first {
            // Reset clears feedback and its fence, including a rating already
            // waiting for the account lock. Its accepted item is then gone.
            let service = profile_service(&database);
            let revision = service.get(user_id).await.unwrap().profile_revision;
            let mut blocker = database.pool().begin().await.unwrap();
            sqlx::query("LOCK TABLE recommendation_feedback IN SHARE MODE")
                .execute(&mut *blocker)
                .await
                .unwrap();
            let reset = tokio::spawn(async move {
                service
                    .reset(
                        user_id,
                        ResetProfileCommand {
                            expected_revision: revision,
                            operation_id: Uuid::now_v7(),
                            scope: ResetScope::All,
                        },
                    )
                    .await
            });
            wait_for_account_lock(&database, user_id).await;
            let waiting = tokio::spawn(async move {
                repository
                    .record_feedback(RecommendationFeedbackWrite {
                        idempotency_key: Uuid::now_v7(),
                        feedback_id: Uuid::now_v7(),
                        ..write
                    })
                    .await
            });
            blocker.commit().await.unwrap();
            reset.await.unwrap().unwrap();
            assert_eq!(
                waiting.await.unwrap().unwrap(),
                RecommendationFeedbackOutcome::NotFound
            );
            let repository = database.recommendation_batches();
            assert_eq!(
                repository
                    .feedback_context(user_id, &[], now)
                    .await
                    .unwrap()
                    .revision,
                0
            );
            sqlx::query("DELETE FROM users WHERE id = $1")
                .bind(user_id.into_inner())
                .execute(database.pool())
                .await
                .unwrap();
        } else {
            let mut blocker = database.pool().begin().await.unwrap();
            sqlx::query("LOCK TABLE recommendation_feedback IN SHARE MODE")
                .execute(&mut *blocker)
                .await
                .unwrap();
            let pool = database.pool().clone();
            let deletion = tokio::spawn(async move {
                sqlx::query("DELETE FROM users WHERE id = $1")
                    .bind(user_id.into_inner())
                    .execute(&pool)
                    .await
            });
            wait_for_account_lock(&database, user_id).await;
            let waiting = tokio::spawn(async move { repository.record_feedback(write).await });
            blocker.commit().await.unwrap();
            deletion.await.unwrap().unwrap();
            assert_eq!(
                waiting.await.unwrap().unwrap(),
                RecommendationFeedbackOutcome::NotFound
            );
        }
        let remaining_feedback: i64 =
            sqlx::query_scalar("SELECT count(*) FROM recommendation_feedback WHERE user_id = $1")
                .bind(user_id.into_inner())
                .fetch_one(database.pool())
                .await
                .unwrap();
        assert_eq!(remaining_feedback, 0);
    }
}

#[tokio::test]
async fn retention_skips_an_account_whose_opt_out_is_in_progress() {
    let _retention = RETENTION_FIXTURES.lock().await;
    let Some(database) = connect().await else {
        return;
    };
    let blocked = profile_user(&database).await;
    let other = profile_user(&database).await;
    set_consent(&database, blocked, true).await;
    let now = Utc::now();
    let old = now - TimeDelta::days(181);
    let rated = paper(&database, &category(), old).await;
    insert_fixture_feedback(&database, blocked, rated, "relevant", Some(4), old).await;
    insert_fixture_feedback(&database, other, rated, "not_relevant", None, old).await;

    let mut locked_vote = database.pool().begin().await.unwrap();
    sqlx::query("SELECT id FROM recommendation_feedback WHERE user_id = $1 FOR UPDATE")
        .bind(blocked.into_inner())
        .execute(&mut *locked_vote)
        .await
        .unwrap();
    let service = profile_service(&database);
    let opt_out = tokio::spawn(async move {
        service
            .update(
                blocked,
                UpdateProfileCommand {
                    expected_revision: 1,
                    operation_id: Uuid::now_v7(),
                    personalization_enabled: Some(false),
                    ..UpdateProfileCommand::default()
                },
            )
            .await
    });
    wait_for_account_lock(&database, blocked).await;
    let repository = database.recommendation_batches();
    tokio::time::timeout(
        Duration::from_secs(3),
        repository.cleanup_retention(now, old, 1_000),
    )
    .await
    .expect("retention should skip the busy account and advance other fences")
    .unwrap();
    assert_eq!(
        repository
            .feedback_context(other, &[], now)
            .await
            .unwrap()
            .revision,
        1
    );
    assert_eq!(
        repository
            .feedback_context(blocked, &[], now)
            .await
            .unwrap()
            .revision,
        0
    );

    locked_vote.commit().await.unwrap();
    opt_out.await.unwrap().unwrap();
    let remaining_mask: Option<i16> =
        sqlx::query_scalar("SELECT feature_mask FROM recommendation_feedback WHERE user_id = $1")
            .bind(blocked.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(remaining_mask, None);
    repository.cleanup_retention(now, old, 1_000).await.unwrap();
    assert_eq!(
        repository
            .feedback_context(blocked, &[], now)
            .await
            .unwrap()
            .revision,
        2
    );
}

#[tokio::test]
async fn served_mask_round_trips_for_every_feature_combination() {
    let _retention = RETENTION_FIXTURES.lock().await;
    let Some(database) = connect().await else {
        return;
    };
    let user_id = profile_user(&database).await;
    set_consent(&database, user_id, true).await;
    let now = Utc::now();
    let root = paper(&database, &category(), now).await;
    mutate_library(
        &database,
        user_id,
        root,
        LibraryMutationIntent::Save,
        LibraryState::Reviewed,
    )
    .await;
    let mut candidates = Vec::new();
    let category = category();
    for _ in 0..8 {
        candidates.push(paper(&database, &category, now).await);
    }
    sqlx::query(
        r#"UPDATE papers SET authors = '[{"name":"Unfollowed Author"}]' WHERE id = ANY($1)"#,
    )
    .bind(&candidates[..4])
    .execute(database.pool())
    .await
    .unwrap();
    edges(
        &database,
        &[root],
        &[candidates[1], candidates[3], candidates[5], candidates[7]],
        1,
    )
    .await;
    edges(
        &database,
        &[candidates[2], candidates[3], candidates[6], candidates[7]],
        &[root],
        1,
    )
    .await;

    let repository = database.recommendation_batches();
    let batch = build(&database, user_id, &candidates, now, CITATION_POLICY).await;
    assert_eq!(batch.candidates.len(), candidates.len());
    let batch_id = Uuid::now_v7();
    publish(&database, user_id, batch_id, &batch, now).await;
    assert!(matches!(
        repository
            .serve_ready(serve_request(user_id, batch_id, &batch, now))
            .await
            .unwrap(),
        RecommendationBatchServeOutcome::Found { items, .. } if items.len() == 8
    ));
    for (expected_mask, paper_id) in (0..8).zip(candidates) {
        let write = rating(
            user_id,
            batch_id,
            paper_id,
            RecommendationFeedbackType::Relevant,
            now,
        );
        assert!(matches!(
            repository.record_feedback(write).await.unwrap(),
            RecommendationFeedbackOutcome::Applied { .. }
        ));
        assert_eq!(
            mask(&database, write.feedback_id).await,
            Some(expected_mask)
        );
    }
}
