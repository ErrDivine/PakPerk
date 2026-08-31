use std::{collections::BTreeSet, sync::Arc, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{TimeDelta, Utc};
use db::{Database, LibraryMutationIntent, LibraryMutationOutcome};
use discovery_search::{
    DiscoverySearchError, DiscoverySearchPolicy, DiscoverySearchService, MatchKind,
    SaveSearchCommand, SearchFilters, SearchSort, SearchSource,
};
use domain::{ArxivIdentifier, Author, LibraryState, PaperMetadata};
use reading_feed::{
    FeedMode, ReadingFeedSnapshot, ReadingFeedSnapshotRequest, ReadingFeedStore as _,
};
use serde::Deserialize;
use url::Url;
use uuid::Uuid;

const LOOKUP_QUALITY_FIXTURE: &str =
    include_str!("fixtures/discovery_search/lookup_exact_matches_v1.json");
const QUEUE_SUPPRESSION_FIXTURE: &str =
    include_str!("fixtures/discovery_search/queue_suppression_v1.json");

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LookupQualityFixture {
    schema_version: u32,
    cases: Vec<LookupQualityCase>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LookupQualityCase {
    name: String,
    query_source: LookupQuerySource,
    expected_paper: ExpectedPaper,
    expected_match_kind: MatchKind,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum LookupQuerySource {
    FirstArxivBase,
    SharedTitle,
    AuthorWithTitleTokens,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ExpectedPaper {
    First,
    AuthorMatch,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct QueueSuppressionFixture {
    schema_version: u32,
    initial_library_rows: i64,
    after_explicit_search_library_rows: i64,
    canonical_save_state: LibraryState,
    expected_feed_mode: FeedMode,
    expected_active_count: u64,
    recommendations_allowed: bool,
    expected_processing_stage: String,
    expected_job_count: i64,
}

#[test]
fn phase_d_search_fixtures_are_strict_complete_and_fail_closed() {
    let lookup_fixture: LookupQualityFixture =
        serde_json::from_str(LOOKUP_QUALITY_FIXTURE).unwrap();
    assert_eq!(lookup_fixture.schema_version, 1);
    assert_eq!(lookup_fixture.cases.len(), 3);
    let names = lookup_fixture
        .cases
        .iter()
        .map(|case| case.name.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        names,
        BTreeSet::from([
            "exact_arxiv_identifier_wins",
            "exact_normalized_title_wins",
            "exact_author_with_title_tokens_wins",
        ])
    );
    assert!(lookup_fixture.cases.iter().any(|case| {
        matches!(case.query_source, LookupQuerySource::FirstArxivBase)
            && matches!(case.expected_paper, ExpectedPaper::First)
            && case.expected_match_kind == MatchKind::ExactArxivId
    }));
    assert!(lookup_fixture.cases.iter().any(|case| {
        matches!(case.query_source, LookupQuerySource::SharedTitle)
            && matches!(case.expected_paper, ExpectedPaper::First)
            && case.expected_match_kind == MatchKind::ExactTitle
    }));
    assert!(lookup_fixture.cases.iter().any(|case| {
        matches!(case.query_source, LookupQuerySource::AuthorWithTitleTokens)
            && matches!(case.expected_paper, ExpectedPaper::AuthorMatch)
            && case.expected_match_kind == MatchKind::ExactAuthor
    }));

    let queue_fixture: QueueSuppressionFixture =
        serde_json::from_str(QUEUE_SUPPRESSION_FIXTURE).unwrap();
    assert_eq!(queue_fixture.schema_version, 1);
    assert_eq!(queue_fixture.initial_library_rows, 0);
    assert_eq!(queue_fixture.after_explicit_search_library_rows, 0);
    assert_eq!(queue_fixture.canonical_save_state, LibraryState::Inbox);
    assert_eq!(queue_fixture.expected_feed_mode, FeedMode::ToRead);
    assert_eq!(queue_fixture.expected_active_count, 1);
    assert!(!queue_fixture.recommendations_allowed);
    assert_eq!(queue_fixture.expected_processing_stage, "not_requested");
    assert_eq!(queue_fixture.expected_job_count, 0);
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_search_is_deterministic_private_and_never_mutates_queue_state() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL discovery-search coverage");
        return;
    };
    let database = Database::connect(&database_url, 16)
        .await
        .unwrap()
        .with_cursor_codec(test_cursor_codec());
    database.migrate_embedded().await.unwrap();
    let lookup_fixture: LookupQualityFixture =
        serde_json::from_str(LOOKUP_QUALITY_FIXTURE).unwrap();
    let queue_fixture: QueueSuppressionFixture =
        serde_json::from_str(QUEUE_SUPPRESSION_FIXTURE).unwrap();
    assert_eq!(lookup_fixture.schema_version, 1);
    assert_eq!(queue_fixture.schema_version, 1);

    let unique = Uuid::now_v7().simple().to_string();
    let suffix = 10_000 + (Uuid::now_v7().as_u128() % 80_000) as u32;
    let category = format!("ds.A{}", &unique[..8]);
    let accounts = database.accounts();
    let owner = accounts
        .provision_oidc_identity(
            &format!("https://discovery-search.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let other = accounts
        .provision_oidc_identity(
            &format!("https://discovery-search.test/{unique}"),
            "other",
            Duration::from_secs(900),
        )
        .await
        .unwrap();

    let papers = database.papers();
    let first = papers
        .upsert_metadata(&metadata(
            &format!("2608.{suffix:05}"),
            2,
            "Bounded Retrieval Systems",
            "Grace Hopper",
            &category,
        ))
        .await
        .unwrap();
    let second = papers
        .upsert_metadata(&metadata(
            &format!("2607.{:05}", suffix + 1),
            1,
            "Bounded Retrieval Systems",
            "Katherine Johnson",
            &category,
        ))
        .await
        .unwrap();
    let author_match = papers
        .upsert_metadata(&metadata(
            &format!("2606.{:05}", suffix + 2),
            0,
            "Auditable Metadata Navigation",
            "Ada Lovelace",
            &category,
        ))
        .await
        .unwrap();

    let repository = Arc::new(database.discovery_search());
    let service = DiscoverySearchService::new(
        repository.clone(),
        repository,
        DiscoverySearchPolicy::default(),
    );
    let topic_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO topics (
            id, canonical_key, label, normalized_label, source_vocabulary
        ) VALUES ($1, $2, $3, $4, 'fixture')
        ",
    )
    .bind(topic_id)
    .bind(format!("fixture:retrieval-{}", &unique[..8]))
    .bind(format!("Retrieval Systems {}", &unique[..8]))
    .bind(format!("retrieval systems {}", &unique[..8]))
    .execute(database.pool())
    .await
    .unwrap();

    for case in lookup_fixture.cases {
        let query = match case.query_source {
            LookupQuerySource::FirstArxivBase => first.metadata.arxiv_id.base_id.as_str(),
            LookupQuerySource::SharedTitle => "Bounded Retrieval Systems",
            LookupQuerySource::AuthorWithTitleTokens => "Ada Lovelace metadata",
        };
        let expected_paper = match case.expected_paper {
            ExpectedPaper::First => first.id,
            ExpectedPaper::AuthorMatch => author_match.id,
        };
        let result = service.lookup(query, None, 20).await.unwrap();
        assert_eq!(
            result.items[0].paper.paper_id, expected_paper,
            "{} returned the wrong leading paper",
            case.name
        );
        assert_eq!(
            result.items[0].match_kind, case.expected_match_kind,
            "{} returned the wrong exact-match tier",
            case.name
        );
    }

    let author_only = service.lookup("Ada Lovelace", None, 20).await.unwrap();
    assert_eq!(author_only.items[0].paper.paper_id, author_match.id);
    assert_eq!(author_only.items[0].match_kind, MatchKind::RelatedText);

    let first_page = service
        .lookup("Bounded Retrieval Systems", None, 1)
        .await
        .unwrap();
    assert_eq!(first_page.items.len(), 1);
    assert_eq!(first_page.items[0].paper.paper_id, first.id);
    assert_eq!(first_page.items[0].match_kind, MatchKind::ExactTitle);
    let cursor = first_page.next_cursor.as_deref().unwrap();
    let second_page = service
        .lookup("Bounded Retrieval Systems", Some(cursor), 1)
        .await
        .unwrap();
    assert_eq!(second_page.items[0].paper.paper_id, second.id);
    assert!(matches!(
        service
            .lookup("different private query", Some(cursor), 1)
            .await,
        Err(DiscoverySearchError::InvalidCursor)
    ));

    let generation: i32 =
        sqlx::query_scalar("SELECT generation FROM paper_processing WHERE paper_id = $1")
            .bind(first.id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    sqlx::query("UPDATE paper_processing SET connections_ready = TRUE WHERE paper_id = $1")
        .bind(first.id)
        .execute(database.pool())
        .await
        .unwrap();
    let reference_id: Uuid = sqlx::query_scalar(
        r"
        INSERT INTO paper_references (
            citing_paper_id, generation, ordinal, raw_text, resolved_paper_id,
            resolution_status, resolution_confidence, resolution_method
        ) VALUES ($1, $2, 0, 'Auditable metadata navigation', $3,
                  'resolved', 0.99, 'fixture')
        RETURNING id
        ",
    )
    .bind(first.id)
    .bind(generation)
    .bind(author_match.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO paper_connections (
            citing_paper_id, cited_paper_id, reference_id, generation,
            relation_type, summary, confidence, source_context_ids
        ) VALUES ($1, $2, $3, $4, 'related_work',
                  'Fixture citation neighbor.', 0.99, ARRAY[]::uuid[])
        ",
    )
    .bind(first.id)
    .bind(author_match.id)
    .bind(reference_id)
    .bind(generation)
    .execute(database.pool())
    .await
    .unwrap();
    let citation_union = service
        .explore(
            "bounded",
            SearchFilters {
                sources: vec![SearchSource::ArxivMetadata],
                ..SearchFilters::default()
            },
            SearchSort::Relevance,
            None,
            20,
        )
        .await
        .unwrap();
    assert!(
        citation_union
            .items
            .iter()
            .any(|item| item.paper.paper_id == author_match.id),
        "published citation neighbors participate in the Explore candidate union"
    );

    let explore = service
        .explore(
            "retrieval",
            SearchFilters {
                categories: vec![category.clone()],
                sources: vec![SearchSource::ArxivMetadata],
                ..SearchFilters::default()
            },
            SearchSort::Recency,
            None,
            20,
        )
        .await
        .unwrap();
    assert_eq!(explore.items.len(), 3);
    assert_eq!(explore.diagnostics.len(), 1);
    assert_eq!(explore.diagnostics[0].source, SearchSource::ArxivMetadata);
    assert_eq!(explore.diagnostics[0].matches_returned, 3);
    let filtered_union = service
        .explore(
            "unrelated quantum term",
            SearchFilters {
                categories: vec![format!("ds.A{}", &unique[..8])],
                sources: vec![SearchSource::ArxivMetadata],
                ..SearchFilters::default()
            },
            SearchSort::Recency,
            None,
            20,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered_union.items.len(),
        3,
        "explicit category filters participate in the auditable candidate union"
    );
    let suggestions = service.suggestions("retrieval systems").await.unwrap();
    assert!(suggestions.items.len() <= 8);
    assert!(
        suggestions
            .items
            .iter()
            .any(|suggestion| suggestion.topic_id == topic_id)
    );

    let operation_id = Uuid::now_v7();
    let saved = service
        .save(
            owner.id,
            SaveSearchCommand {
                operation_id,
                query: "Retrieval Systems".to_owned(),
                filters: SearchFilters {
                    categories: vec![category],
                    ..SearchFilters::default()
                },
                sort: SearchSort::Relevance,
            },
        )
        .await
        .unwrap();
    assert_eq!(saved.user_id, owner.id);
    assert_eq!(
        service.list_saved(owner.id).await.unwrap(),
        vec![saved.clone()]
    );
    assert!(service.list_saved(other.id).await.unwrap().is_empty());
    let duplicate_operation_id = Uuid::now_v7();
    service
        .save(
            owner.id,
            SaveSearchCommand {
                operation_id: duplicate_operation_id,
                query: "Retrieval Systems".to_owned(),
                filters: SearchFilters {
                    categories: vec![format!("ds.A{}", &unique[..8])],
                    ..SearchFilters::default()
                },
                sort: SearchSort::Relevance,
            },
        )
        .await
        .unwrap();
    assert!(matches!(
        service
            .save(
                owner.id,
                SaveSearchCommand {
                    operation_id: duplicate_operation_id,
                    query: "Different Intent".to_owned(),
                    filters: SearchFilters::default(),
                    sort: SearchSort::Recency,
                },
            )
            .await,
        Err(DiscoverySearchError::IdempotencyConflict)
    ));
    sqlx::query(
        r"
        UPDATE saved_search_operations
        SET expires_at = statement_timestamp() - interval '1 second'
        WHERE user_id = $1 AND operation_id = $2
        ",
    )
    .bind(owner.id.into_inner())
    .bind(operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        database
            .discovery_search()
            .cleanup_expired_operations(10)
            .await
            .unwrap(),
        1
    );

    let other_saved = service
        .save(
            other.id,
            SaveSearchCommand {
                operation_id: Uuid::now_v7(),
                query: "Other account retrieval".to_owned(),
                filters: SearchFilters::default(),
                sort: SearchSort::Recency,
            },
        )
        .await
        .unwrap();
    let foreign = service
        .delete_saved(owner.id, other_saved.id)
        .await
        .unwrap();
    assert!(
        !foreign.deleted,
        "foreign ownership must remain undisclosed"
    );
    assert_eq!(
        service.list_saved(other.id).await.unwrap(),
        vec![other_saved]
    );

    let subscription_id = Uuid::now_v7();
    let subscription_operation_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO subscriptions (
            id, user_id, kind, key, label, query_definition, frequency,
            revision, created_at, updated_at, last_operation_id
        ) VALUES (
            $1, $2, 'saved_query', $3, 'Retrieval Systems',
            jsonb_build_object('saved_search_id', $3::text), 'daily',
            1, statement_timestamp(), statement_timestamp(), $4
        )
        ",
    )
    .bind(subscription_id)
    .bind(owner.id.into_inner())
    .bind(saved.id.to_string())
    .bind(subscription_operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    let match_notification_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope,
            entity_type, entity_id, payload, batch_key,
            delivery_eligibility, expires_at
        ) VALUES (
            $1, $2, 'discovery_match', 'discovery', 'paper', $3,
            jsonb_build_object('subscription_id', $4::uuid::text),
            'saved-query-delete-fixture', 'deferred_unknown',
            statement_timestamp() + interval '30 days'
        )
        ",
    )
    .bind(match_notification_id)
    .bind(owner.id.into_inner())
    .bind(first.id)
    .bind(subscription_id)
    .execute(database.pool())
    .await
    .unwrap();
    let digest_notification_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope,
            entity_type, payload, batch_key, delivery_eligibility, expires_at
        ) VALUES (
            $1, $2, 'discovery_digest', 'discovery', 'digest', '{}'::jsonb,
            'saved-query-delete-digest', 'deferred_unknown',
            statement_timestamp() + interval '30 days'
        )
        ",
    )
    .bind(digest_notification_id)
    .bind(owner.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO notification_digest_items (notification_id, paper_id, ordinal) VALUES ($1, $2, 0)",
    )
    .bind(digest_notification_id)
    .bind(first.id)
    .execute(database.pool())
    .await
    .unwrap();
    let work_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notification_work_items (
            id, user_id, work_kind, subscription_id, window_key,
            state, available_at
        ) VALUES (
            $1, $2, 'evaluate_subscriptions', $3,
            'saved-query-delete-fixture', 'queued', statement_timestamp()
        )
        ",
    )
    .bind(work_id)
    .bind(owner.id.into_inner())
    .bind(subscription_id)
    .execute(database.pool())
    .await
    .unwrap();

    let deleted = service.delete_saved(owner.id, saved.id).await.unwrap();
    assert!(deleted.deleted);
    assert_eq!(deleted.linked_subscriptions_deleted, 1);
    let replay = service.delete_saved(owner.id, saved.id).await.unwrap();
    assert!(!replay.deleted, "DELETE retries are successful no-ops");
    assert!(service.list_saved(owner.id).await.unwrap().is_empty());
    let retained_save_operations: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM saved_search_operations WHERE user_id = $1 AND saved_search_id = $2",
    )
    .bind(owner.id.into_inner())
    .bind(saved.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        retained_save_operations, 0,
        "deleting a saved query must cascade its bounded save-retry bindings"
    );

    let retired_subscription: (bool, String, String) = sqlx::query_as(
        r"
        SELECT deleted_at IS NOT NULL, frequency, label
        FROM subscriptions WHERE user_id = $1 AND id = $2
        ",
    )
    .bind(owner.id.into_inner())
    .bind(subscription_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        retired_subscription,
        (true, "off".to_owned(), "Deleted saved query".to_owned())
    );
    let invalidated_notifications: i64 = sqlx::query_scalar(
        r"
        SELECT count(*) FROM notifications
        WHERE user_id = $1 AND id = ANY($2::uuid[])
          AND delivery_eligibility = 'expired' AND dismissed_at IS NOT NULL
        ",
    )
    .bind(owner.id.into_inner())
    .bind(vec![match_notification_id, digest_notification_id])
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(invalidated_notifications, 2);
    let work_state: String =
        sqlx::query_scalar("SELECT state FROM notification_work_items WHERE id = $1")
            .bind(work_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(work_state, "complete");

    let library_rows: i64 =
        sqlx::query_scalar("SELECT count(*) FROM user_paper_library WHERE user_id = $1")
            .bind(owner.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(library_rows, queue_fixture.initial_library_rows);
    assert_eq!(
        library_rows, queue_fixture.after_explicit_search_library_rows,
        "explicit search must not insert queue/library rows"
    );
    let processing_stages: Vec<String> = sqlx::query_scalar(
        "SELECT stage FROM paper_processing WHERE paper_id = ANY($1::uuid[]) ORDER BY paper_id",
    )
    .bind(vec![first.id, second.id, author_match.id])
    .fetch_all(database.pool())
    .await
    .unwrap();
    assert_eq!(processing_stages.len(), 3);
    assert!(
        processing_stages
            .iter()
            .all(|stage| stage == &queue_fixture.expected_processing_stage),
        "search must not advance derived processing"
    );
    let job_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM jobs WHERE paper_id = ANY($1::uuid[])")
            .bind(vec![first.id, second.id, author_match.id])
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(job_count, queue_fixture.expected_job_count);

    let saved = database
        .library()
        .mutate(
            owner.id,
            first.id,
            Uuid::now_v7(),
            LibraryMutationIntent::Save,
            queue_fixture.canonical_save_state,
        )
        .await
        .unwrap();
    assert!(matches!(saved, LibraryMutationOutcome::Applied { .. }));
    let feed = database
        .reading_feed()
        .snapshot(&ReadingFeedSnapshotRequest {
            user_id: owner.id,
            category: None,
            continuation: None,
            limit: 20,
        })
        .await
        .unwrap();
    let ReadingFeedSnapshot::Queue {
        active_to_read_count,
        items,
        ..
    } = feed
    else {
        panic!("canonical search-result save did not suppress recommendations")
    };
    assert_eq!(queue_fixture.expected_feed_mode, FeedMode::ToRead);
    assert!(!queue_fixture.recommendations_allowed);
    assert_eq!(
        active_to_read_count.get(),
        queue_fixture.expected_active_count
    );
    assert_eq!(items[0].paper.paper_id, first.id);

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let retained_queries: i64 =
        sqlx::query_scalar("SELECT count(*) FROM saved_searches WHERE user_id = $1")
            .bind(owner.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(retained_queries, 0);
    let retained_operations: i64 =
        sqlx::query_scalar("SELECT count(*) FROM saved_search_operations WHERE user_id = $1")
            .bind(owner.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(retained_operations, 0);
}

fn metadata(
    base_id: &str,
    age_days: i64,
    title: &str,
    author: &str,
    category: &str,
) -> PaperMetadata {
    let published_at = Utc::now() - TimeDelta::days(age_days + 1);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: title.to_owned(),
        abstract_text: format!(
            "A retrieval study for deterministic, auditable search fixture {base_id}."
        ),
        authors: vec![Author {
            name: author.to_owned(),
        }],
        primary_category: category.to_owned(),
        categories: vec![category.to_owned()],
        published_at,
        updated_at: published_at,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: None,
        metadata_fetched_at: Utc::now(),
    }
}

fn test_cursor_codec() -> opaque_cursor::OpaqueCursorCodec {
    let key = STANDARD.encode([0x5Du8; 32]);
    opaque_cursor::OpaqueCursorCodec::parse_keyring(&format!("discovery_search_test:{key}"))
        .unwrap()
}
