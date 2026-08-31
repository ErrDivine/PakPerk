use std::{collections::BTreeSet, time::Duration};

use chrono::Utc;
use db::{
    Database, InteractionEventType, InteractionFeedMode, InteractionPrincipal,
    PaperInteractionBatchRequest, PaperInteractionRepositoryError, PaperInteractionWrite,
    RecommendationBatchPersistOutcome, RecommendationBatchPersistRequest,
};
use domain::{ArxivIdentifier, Author, Capabilities, PaperMetadata, PaperSummary};
use recommendations::{
    CandidateDocument, DiscoveryProfileSnapshot, ProvenEmptyQueueBinding,
    RecommendationBatchBuildRequest, RecommendationMode, RerankPolicy, ScoringPolicy,
    build_recommendation_batch,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_interactions_are_closed_idempotent_retained_and_account_owned() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL interaction coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://interactions.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let metadata = metadata(&unique);
    let paper = database.papers().upsert_metadata(&metadata).await.unwrap();
    let now = Utc::now();
    let consent_error = database
        .paper_interactions()
        .ingest(PaperInteractionBatchRequest {
            principal: InteractionPrincipal::Account(account.id),
            events: vec![PaperInteractionWrite {
                id: Uuid::now_v7(),
                event_type: InteractionEventType::AbstractOpened,
                paper_id: paper.id,
                feed_mode: None,
                batch_id: None,
                position: None,
                occurred_at: now,
            }],
            received_at: now,
            retention: Duration::from_secs(24 * 60 * 60),
        })
        .await
        .unwrap_err();
    assert!(matches!(
        consent_error,
        PaperInteractionRepositoryError::ConsentRequired
    ));
    sqlx::query(
        "INSERT INTO research_profiles (user_id, personalization_enabled, profile_revision) VALUES ($1, true, 1)",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let document = CandidateDocument {
        paper: PaperSummary {
            paper_id: paper.id,
            arxiv_id: metadata.arxiv_id.versioned(),
            title: metadata.title.clone(),
            abstract_text: metadata.abstract_text.clone(),
            authors: metadata
                .authors
                .iter()
                .map(|author| author.name.clone())
                .collect(),
            primary_category: metadata.primary_category.clone(),
            categories: metadata.categories.clone(),
            published_at: metadata.published_at,
            updated_at: metadata.updated_at,
            abs_url: metadata.abs_url.clone(),
            pdf_url: metadata.pdf_url.clone(),
            capabilities: Capabilities::metadata_only(),
        },
        topics: BTreeSet::new(),
        embedding: Vec::new(),
        citation_neighbors: BTreeSet::new(),
        metadata_completeness: 1.0,
    };
    let profile = DiscoveryProfileSnapshot {
        personalization_enabled: true,
        categories: BTreeSet::new(),
        topics: BTreeSet::new(),
        authors: BTreeSet::new(),
        saved_query_matches: std::collections::BTreeMap::new(),
        feedback_categories: BTreeSet::from([metadata.primary_category.clone()]),
        inferred_categories: BTreeSet::from([metadata.primary_category.clone()]),
        historical_seeds: Vec::new(),
    };
    let recommendation = build_recommendation_batch(RecommendationBatchBuildRequest {
        mode: RecommendationMode::ForYou,
        queue: ProvenEmptyQueueBinding::from_decision(0, 0, true).unwrap(),
        profile_revision: Some(1),
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
    let batch_id = Uuid::now_v7();
    assert!(matches!(
        database
            .recommendation_batches()
            .persist_ready(RecommendationBatchPersistRequest {
                user_id: account.id,
                batch_id,
                query_key: "for_you:all",
                local_date: now.date_naive(),
                created_at: now,
                expires_at: now + chrono::Duration::days(7),
                next_position: None,
                saved_search_revision_digest: None,
                batch: &recommendation,
            })
            .await
            .unwrap(),
        RecommendationBatchPersistOutcome::Ready { .. }
    ));
    let batch_metadata: serde_json::Value =
        sqlx::query_scalar("SELECT metadata FROM recommendation_batches WHERE id = $1")
            .bind(batch_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(
        batch_metadata["metadata_embedding_version"],
        recommendations::METADATA_EMBEDDING_VERSION_V1
    );

    let repository = database.paper_interactions();
    let event_id = Uuid::now_v7();
    let request = PaperInteractionBatchRequest {
        principal: InteractionPrincipal::Account(account.id),
        events: vec![PaperInteractionWrite {
            id: event_id,
            event_type: InteractionEventType::ImpressionQualified,
            paper_id: paper.id,
            feed_mode: Some(InteractionFeedMode::ForYou),
            batch_id: Some(batch_id),
            position: Some(0),
            occurred_at: now,
        }],
        received_at: now,
        retention: Duration::from_secs(24 * 60 * 60),
    };
    assert_eq!(
        repository.ingest(request.clone()).await.unwrap().accepted,
        1
    );
    let replay = repository.ingest(request).await.unwrap();
    assert_eq!(replay.accepted, 0);
    assert_eq!(replay.duplicates, 1);
    let (reason_codes, metadata): (Vec<String>, serde_json::Value) =
        sqlx::query_as("SELECT reason_codes, metadata FROM paper_interactions WHERE id = $1")
            .bind(event_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert!(
        reason_codes.contains(&"feedback_category_affinity".to_owned()),
        "qualified feedback-affinity evidence must survive event binding"
    );
    assert!(
        reason_codes.contains(&"inferred_category_affinity".to_owned()),
        "qualified inferred-affinity evidence must survive event binding"
    );
    assert_eq!(metadata, serde_json::json!({}));

    let invalid = repository
        .ingest(PaperInteractionBatchRequest {
            principal: InteractionPrincipal::Account(account.id),
            events: vec![PaperInteractionWrite {
                id: Uuid::now_v7(),
                event_type: InteractionEventType::MarkedRelevant,
                paper_id: Uuid::now_v7(),
                feed_mode: Some(InteractionFeedMode::ForYou),
                batch_id: Some(batch_id),
                position: Some(0),
                occurred_at: now,
            }],
            received_at: now,
            retention: Duration::from_secs(24 * 60 * 60),
        })
        .await
        .unwrap_err();
    assert!(matches!(
        invalid,
        PaperInteractionRepositoryError::InvalidRecommendationPair
    ));

    let anonymous_session_id = Uuid::now_v7();
    let anonymous_event_ids = [Uuid::now_v7(), Uuid::now_v7()];
    for (event_id, event_type, feed_mode, position) in [
        (
            anonymous_event_ids[0],
            InteractionEventType::ImpressionQualified,
            Some(InteractionFeedMode::Recent),
            Some(0),
        ),
        (
            anonymous_event_ids[1],
            InteractionEventType::Saved,
            None,
            None,
        ),
    ] {
        let error = repository
            .ingest(PaperInteractionBatchRequest {
                principal: InteractionPrincipal::Anonymous(anonymous_session_id),
                events: vec![PaperInteractionWrite {
                    id: event_id,
                    event_type,
                    paper_id: paper.id,
                    feed_mode,
                    batch_id: None,
                    position,
                    occurred_at: now,
                }],
                received_at: now,
                retention: Duration::from_secs(24 * 60 * 60),
            })
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            PaperInteractionRepositoryError::ConsentRequired
        ));
    }
    let anonymous_rows: i64 =
        sqlx::query_scalar("SELECT count(*) FROM paper_interactions WHERE id = ANY($1)")
            .bind(anonymous_event_ids.as_slice())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(anonymous_rows, 0);
    assert_eq!(
        repository
            .cleanup_expired(now + chrono::Duration::days(2), 100)
            .await
            .unwrap(),
        1
    );

    let cascade_event_id = Uuid::now_v7();
    repository
        .ingest(PaperInteractionBatchRequest {
            principal: InteractionPrincipal::Account(account.id),
            events: vec![PaperInteractionWrite {
                id: cascade_event_id,
                event_type: InteractionEventType::AbstractOpened,
                paper_id: paper.id,
                feed_mode: None,
                batch_id: None,
                position: None,
                occurred_at: now,
            }],
            received_at: now,
            retention: Duration::from_secs(90 * 24 * 60 * 60),
        })
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let remaining: i64 =
        sqlx::query_scalar("SELECT count(*) FROM paper_interactions WHERE id = $1")
            .bind(cascade_event_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(remaining, 0);
}

fn metadata(unique: &str) -> PaperMetadata {
    let suffix = 10_000 + (Uuid::now_v7().as_u128() % 90_000) as u32;
    let arxiv_id = ArxivIdentifier {
        base_id: format!("2608.{suffix:05}"),
        version: 1,
    };
    PaperMetadata {
        arxiv_id: arxiv_id.clone(),
        title: format!("Interaction fixture {unique}"),
        abstract_text: "A bounded metadata-only interaction fixture.".to_owned(),
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
