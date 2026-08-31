use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{TimeDelta, Utc};
use db::{
    Database, EncryptedReadingFeedCursorCodec, LibraryItemMutation, LibraryMutationIntent,
    LibraryMutationOutcome,
};
use domain::{ArxivIdentifier, Author, LibrarySaveSourceKind, LibraryState, PaperMetadata};
use reading_feed::{
    FeedMode, ReadingFeedContinuation, ReadingFeedCursorPosition, ReadingFeedPolicy,
    ReadingFeedRequest, ReadingFeedService, ReadingFeedSnapshot, ReadingFeedSnapshotRequest,
    ReadingFeedStore, ReadingFeedStoreError, RecommendationError, RecommendationMode,
    RecommendationRequest, RecommendationResultItem, RecommendationResultPage,
    RecommendationSource, ToReadPosition,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_reading_feed_snapshot_is_fifo_excluded_revision_fenced_and_consistent() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL reading-feed coverage");
        return;
    };
    let cursor_codec = test_cursor_codec();
    let database = Database::connect(&database_url, 24)
        .await
        .unwrap()
        .with_cursor_codec(cursor_codec.clone());
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let category = format!("rf.A{}", &unique[..8]);
    let issuer = format!("https://reading-feed.test/{unique}");
    let accounts = database.accounts();
    let owner = accounts
        .provision_oidc_identity(&issuer, "owner", Duration::from_secs(900))
        .await
        .unwrap();
    let other = accounts
        .provision_oidc_identity(&issuer, "other", Duration::from_secs(900))
        .await
        .unwrap();
    let race_user = accounts
        .provision_oidc_identity(&issuer, "race", Duration::from_secs(900))
        .await
        .unwrap();

    let papers = database.papers();
    let mut paper_ids = Vec::new();
    for index in 0..6 {
        paper_ids.push(
            papers
                .upsert_metadata(&metadata(&unique, &category, index))
                .await
                .unwrap()
                .id,
        );
    }
    // A candidate that is not publishable metadata must not enter discovery.
    sqlx::query("UPDATE paper_processing SET metadata_ready = false WHERE paper_id = $1")
        .bind(paper_ids[5])
        .execute(database.pool())
        .await
        .unwrap();

    let library = database.library();
    // A retained removal tombstone is an exclusion, even though it leaves the
    // active count authoritatively empty.
    applied(
        &library
            .mutate(
                owner.id,
                paper_ids[4],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
    );
    applied(
        &library
            .mutate(
                owner.id,
                paper_ids[4],
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
    );

    let repository = database.reading_feed();
    let discovery = repository
        .snapshot(&ReadingFeedSnapshotRequest {
            user_id: owner.id,
            category: Some(category.clone()),
            continuation: None,
            limit: 2,
        })
        .await
        .unwrap();
    let (empty_revision, recommendation_page) = match discovery {
        ReadingFeedSnapshot::Empty {
            library_revision,
            recommendations,
        } => (library_revision, recommendations),
        unexpected @ ReadingFeedSnapshot::Queue { .. } => {
            panic!("expected recommendation snapshot, got {unexpected:?}")
        }
    };
    assert_eq!(empty_revision, 2);
    assert_eq!(
        recommendation_page
            .items
            .iter()
            .map(|paper| paper.paper_id)
            .collect::<Vec<_>>(),
        vec![paper_ids[3], paper_ids[2]],
    );
    assert!(
        recommendation_page
            .items
            .iter()
            .all(|paper| paper.paper_id != paper_ids[4] && paper.paper_id != paper_ids[5])
    );
    assert_eq!(
        recommendation_page.next_position,
        Some(reading_feed::RecommendationPosition {
            published_at: recommendation_page.items[1].published_at,
            paper_id: paper_ids[2],
        })
    );

    for paper_id in [paper_ids[0], paper_ids[1], paper_ids[2]] {
        let mutation = if paper_id == paper_ids[2] {
            LibraryItemMutation::replace(
                LibraryState::ReadNext,
                None,
                Some(LibrarySaveSourceKind::TitleSearch),
            )
        } else {
            LibraryItemMutation::legacy(LibraryState::Inbox)
        };
        applied(
            &library
                .mutate_item(
                    owner.id,
                    paper_id,
                    Uuid::now_v7(),
                    LibraryMutationIntent::Save,
                    mutation,
                )
                .await
                .unwrap(),
        );
    }
    let oldest = Utc::now() - TimeDelta::hours(3);
    let middle = oldest + TimeDelta::hours(1);
    let newest = oldest + TimeDelta::hours(2);
    for (paper_id, saved_at) in [
        (paper_ids[1], oldest),
        (paper_ids[2], middle),
        (paper_ids[0], newest),
    ] {
        sqlx::query(
            "UPDATE user_paper_library SET saved_at = $3 WHERE user_id = $1 AND paper_id = $2",
        )
        .bind(owner.id.into_inner())
        .bind(paper_id)
        .bind(saved_at)
        .execute(database.pool())
        .await
        .unwrap();
    }

    let queue = repository
        .snapshot(&ReadingFeedSnapshotRequest {
            user_id: owner.id,
            category: Some(category.clone()),
            continuation: None,
            limit: 2,
        })
        .await
        .unwrap();
    let (queue_revision, queue_count, queue_items, next_position) = queue_parts(queue);
    assert_eq!(queue_revision, 5);
    assert_eq!(queue_count, 3);
    assert_eq!(
        queue_items
            .iter()
            .map(|item| item.paper.paper_id)
            .collect::<Vec<_>>(),
        vec![paper_ids[1], paper_ids[2]],
    );
    assert_eq!(queue_items[0].state, LibraryState::Inbox);
    assert_eq!(queue_items[0].save_source_kind, None);
    assert_eq!(queue_items[1].state, LibraryState::ReadNext);
    assert_eq!(
        queue_items[1].save_source_kind,
        Some(LibrarySaveSourceKind::TitleSearch)
    );
    let next_position = next_position.expect("three rows with limit two have a continuation");
    assert_eq!(next_position.saved_at, middle);
    assert_eq!(next_position.paper_id, paper_ids[2]);

    // The service-level queue branch must not invoke its injected recommender.
    let counting_source = Arc::new(CountingRecommendationSource::default());
    let service = ReadingFeedService::with_dependencies(
        Arc::new(repository.clone()),
        counting_source.clone(),
        Arc::new(EncryptedReadingFeedCursorCodec::new(cursor_codec.clone())),
        ReadingFeedPolicy::new(20, 50, Duration::from_secs(86_400)).unwrap(),
    );
    let page = service
        .page(ReadingFeedRequest {
            user_id: owner.id,
            category: Some(category.clone()),
            recommendation_mode: RecommendationMode::Recent,
            cursor: None,
            limit: Some(50),
            now: Utc::now(),
        })
        .await
        .unwrap();
    assert_eq!(page.mode, FeedMode::ToRead);
    assert_eq!(counting_source.calls.load(Ordering::SeqCst), 0);

    let stale_continuation = ReadingFeedContinuation {
        mode: FeedMode::ToRead,
        library_revision: queue_revision,
        position: ReadingFeedCursorPosition::ToRead {
            position: next_position,
        },
    };
    applied(
        &library
            .mutate(
                owner.id,
                paper_ids[3],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
    );
    assert_eq!(
        repository
            .snapshot(&ReadingFeedSnapshotRequest {
                user_id: owner.id,
                category: Some(category.clone()),
                continuation: Some(stale_continuation),
                limit: 2,
            })
            .await,
        Err(ReadingFeedStoreError::RevisionStale)
    );

    let fresh = repository
        .snapshot(&ReadingFeedSnapshotRequest {
            user_id: owner.id,
            category: Some(category.clone()),
            continuation: None,
            limit: 2,
        })
        .await
        .unwrap();
    let (fresh_revision, fresh_count, _, fresh_position) = queue_parts(fresh);
    assert_eq!(fresh_revision, 6);
    assert_eq!(fresh_count, 4);
    let cross_account_continuation = ReadingFeedContinuation {
        mode: FeedMode::ToRead,
        library_revision: fresh_revision,
        position: ReadingFeedCursorPosition::ToRead {
            position: fresh_position.unwrap(),
        },
    };
    applied(
        &library
            .mutate(
                other.id,
                paper_ids[0],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
    );
    let cross_account_page = repository
        .snapshot(&ReadingFeedSnapshotRequest {
            user_id: owner.id,
            category: Some(category.clone()),
            continuation: Some(cross_account_continuation),
            limit: 2,
        })
        .await
        .unwrap();
    let (revision_after_other_write, count_after_other_write, _, _) =
        queue_parts(cross_account_page);
    assert_eq!(revision_after_other_write, fresh_revision);
    assert_eq!(count_after_other_write, fresh_count);

    // Force a second row to commit after the reader's count but before its
    // joined page query. Repeatable read must return the old count and old page
    // together; a read-committed implementation would mix the two states.
    applied(
        &library
            .mutate(
                race_user.id,
                paper_ids[0],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
    );
    let mut blocker = database.pool().begin().await.unwrap();
    sqlx::query("LOCK TABLE paper_processing IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *blocker)
        .await
        .unwrap();
    let race_repository = repository.clone();
    let race_category = category.clone();
    let race_user_id = race_user.id;
    let reader = tokio::spawn(async move {
        race_repository
            .snapshot(&ReadingFeedSnapshotRequest {
                user_id: race_user_id,
                category: Some(race_category),
                continuation: None,
                limit: 50,
            })
            .await
            .unwrap()
    });
    wait_until_reader_blocks_on_processing(database.pool()).await;

    let mut concurrent_write = database.pool().begin().await.unwrap();
    let concurrent_revision: i64 = sqlx::query_scalar(
        r"
        UPDATE library_sync_metadata
        SET current_revision = current_revision + 1,
            updated_at = statement_timestamp()
        WHERE user_id = $1
        RETURNING current_revision
        ",
    )
    .bind(race_user.id.into_inner())
    .fetch_one(&mut *concurrent_write)
    .await
    .unwrap();
    assert_eq!(concurrent_revision, 2);
    sqlx::query(
        r"
        INSERT INTO user_paper_library (
            user_id, paper_id, state, saved_at, updated_at, revision, last_operation_id
        )
        VALUES ($1, $2, 'inbox', statement_timestamp(), statement_timestamp(), $3, $4)
        ",
    )
    .bind(race_user.id.into_inner())
    .bind(paper_ids[1])
    .bind(concurrent_revision)
    .bind(Uuid::now_v7())
    .execute(&mut *concurrent_write)
    .await
    .unwrap();
    concurrent_write.commit().await.unwrap();
    blocker.commit().await.unwrap();

    let raced_snapshot = reader.await.unwrap();
    let (raced_revision, raced_count, raced_items, _) = queue_parts(raced_snapshot);
    assert_eq!(raced_revision, 1);
    assert_eq!(raced_count, 1);
    assert_eq!(raced_items.len(), 1);
    assert_eq!(raced_items[0].paper.paper_id, paper_ids[0]);
    let current_snapshot = repository
        .snapshot(&ReadingFeedSnapshotRequest {
            user_id: race_user.id,
            category: Some(category),
            continuation: None,
            limit: 50,
        })
        .await
        .unwrap();
    let (current_revision, current_count, current_items, _) = queue_parts(current_snapshot);
    assert_eq!(current_revision, 2);
    assert_eq!(current_count, 2);
    assert_eq!(current_items.len(), 2);
}

#[derive(Default)]
struct CountingRecommendationSource {
    calls: AtomicUsize,
}

#[async_trait]
impl RecommendationSource for CountingRecommendationSource {
    async fn page(
        &self,
        request: RecommendationRequest,
    ) -> Result<RecommendationResultPage, RecommendationError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(RecommendationResultPage {
            batch_id: None,
            batch_metadata: None,
            items: request
                .candidates
                .items
                .into_iter()
                .map(|paper| RecommendationResultItem {
                    paper,
                    source: reading_feed::FeedItemSource::DiscoveryV1,
                    recommendation: None,
                })
                .collect(),
            next_position: request.candidates.next_position,
        })
    }
}

fn queue_parts(
    snapshot: ReadingFeedSnapshot,
) -> (
    i64,
    u64,
    Vec<reading_feed::QueueSnapshotItem>,
    Option<ToReadPosition>,
) {
    match snapshot {
        ReadingFeedSnapshot::Queue {
            library_revision,
            active_to_read_count,
            items,
            next_position,
        } => (
            library_revision,
            active_to_read_count.get(),
            items,
            next_position,
        ),
        unexpected @ ReadingFeedSnapshot::Empty { .. } => {
            panic!("expected queue snapshot, got {unexpected:?}")
        }
    }
}

async fn wait_until_reader_blocks_on_processing(pool: &sqlx::PgPool) {
    for _ in 0..100 {
        let waiting: bool = sqlx::query_scalar(
            r"
            SELECT EXISTS (
                SELECT 1
                FROM pg_locks
                WHERE relation = 'paper_processing'::regclass
                  AND mode = 'AccessShareLock'
                  AND NOT granted
            )
            ",
        )
        .fetch_one(pool)
        .await
        .unwrap();
        if waiting {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("reading-feed query did not reach the forced processing-table lock");
}

fn applied(outcome: &LibraryMutationOutcome) {
    assert!(
        matches!(outcome, LibraryMutationOutcome::Applied { .. }),
        "expected applied library mutation, got {outcome:?}"
    );
}

fn metadata(unique: &str, category: &str, index: i64) -> PaperMetadata {
    let base_id = format!("rf.{unique}.{index}");
    let published_at = Utc::now() - TimeDelta::days(20 - index);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.clone(),
            version: 1,
        },
        title: format!("Reading-feed fixture {index}"),
        abstract_text: "A metadata-only reading-feed fixture.".to_owned(),
        authors: vec![Author::from("Ada Reader".to_owned())],
        primary_category: category.to_owned(),
        categories: vec![category.to_owned()],
        published_at,
        updated_at: published_at,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v1")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v1")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: Utc::now(),
    }
}

fn test_cursor_codec() -> opaque_cursor::OpaqueCursorCodec {
    let key = STANDARD.encode([0x71; 32]);
    opaque_cursor::OpaqueCursorCodec::parse_keyring(&format!("reading_feed_test:{key}")).unwrap()
}
