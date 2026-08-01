use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{TimeDelta, Utc};
use db::{
    Database, LibraryChangesOutcome, LibraryMutationIntent, LibraryMutationOutcome,
    LibraryReadOutcome, RateLimitRequest,
};
use domain::{
    AccountStatus, ArxivIdentifier, AuthenticatedUserId, Author, LibraryItem, LibraryState,
    PaperMetadata,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_library_idempotency_sync_races_and_cleanup() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL library coverage");
        return;
    };
    let database = Database::connect(&database_url, 24)
        .await
        .unwrap()
        .with_cursor_codec(test_cursor_codec());
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://library.test/{unique}");
    let accounts = database.accounts();
    let owner = accounts
        .provision_oidc_identity(&issuer, "owner", Duration::from_secs(900))
        .await
        .unwrap();
    let other = accounts
        .provision_oidc_identity(&issuer, "other", Duration::from_secs(900))
        .await
        .unwrap();
    let suspended = accounts
        .provision_oidc_identity(&issuer, "suspended", Duration::from_secs(900))
        .await
        .unwrap();
    let cleanup_race_user = accounts
        .provision_oidc_identity(&issuer, "cleanup-race", Duration::from_secs(900))
        .await
        .unwrap();
    sqlx::query("UPDATE users SET status = 'suspended' WHERE id = $1")
        .bind(suspended.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();

    let papers = database.papers();
    let mut paper_ids = Vec::new();
    for index in 0..13 {
        let metadata = metadata(&format!("library.{unique}.{index}"), index);
        paper_ids.push(papers.upsert_metadata(&metadata).await.unwrap().id);
    }
    let repository = database.library();

    // Repeated identical operations return one accepted state. A different
    // semantic intent under the same ID is rejected without changing it.
    let first_operation = Uuid::now_v7();
    let first = applied(
        repository
            .mutate(
                owner.id,
                paper_ids[0],
                first_operation,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(!first.1);
    assert!(!first.0.removed());
    assert_eq!(first.0.last_operation_id, first_operation);
    let replay = applied(
        repository
            .mutate(
                owner.id,
                paper_ids[0],
                first_operation,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(replay.1);
    assert_eq!(replay.0, first.0);
    assert_eq!(
        repository
            .mutate(
                owner.id,
                paper_ids[0],
                first_operation,
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::IdempotencyConflict
    );
    assert_eq!(
        repository
            .mutate(
                owner.id,
                paper_ids[1],
                first_operation,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::IdempotencyConflict
    );

    // A new no-op save still receives a revision while preserving saved_at.
    let second_operation = Uuid::now_v7();
    let second = applied(
        repository
            .mutate(
                owner.id,
                paper_ids[0],
                second_operation,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(second.0.revision > first.0.revision);
    assert_eq!(second.0.saved_at, first.0.saved_at);
    assert_eq!(second.0.last_operation_id, second_operation);

    // Removal preserves the original saved time. Replaying the much older save
    // returns this current tombstone rather than regressing to active.
    let remove_operation = Uuid::now_v7();
    let removed = applied(
        repository
            .mutate(
                owner.id,
                paper_ids[0],
                remove_operation,
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(removed.0.removed());
    assert_eq!(removed.0.saved_at, first.0.saved_at);
    assert_eq!(removed.0.last_operation_id, remove_operation);
    let old_save_replay = applied(
        repository
            .mutate(
                owner.id,
                paper_ids[0],
                first_operation,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(old_save_replay.1);
    assert!(old_save_replay.0.removed());
    assert_eq!(old_save_replay.0.revision, removed.0.revision);
    assert_eq!(old_save_replay.0.last_operation_id, remove_operation);

    tokio::time::sleep(Duration::from_millis(2)).await;
    let resaved = applied(
        repository
            .mutate(
                owner.id,
                paper_ids[0],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(!resaved.0.removed());
    assert!(resaved.0.saved_at > removed.0.saved_at);

    // Removing an unseen paper creates a non-null-timestamp tombstone.
    let absent_remove = applied(
        repository
            .mutate(
                owner.id,
                paper_ids[1],
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(absent_remove.0.removed());
    assert_eq!(absent_remove.0.saved_at, absent_remove.0.updated_at);
    assert_eq!(absent_remove.0.removed_at, Some(absent_remove.0.updated_at));

    // Operation IDs are scoped to the account, while rows and reads are never
    // visible to a second active account. Revisions and empty-feed watermarks
    // are account-scoped, so neither account exposes the other's activity.
    let owner_watermark_before_other = user_watermark(database.pool(), owner.id).await;
    let empty_observer = found_changes(
        repository
            .changes(cleanup_race_user.id, 0, 20)
            .await
            .unwrap(),
    );
    assert_eq!(empty_observer.sync_revision, 0);
    assert_eq!(empty_observer.next_after_revision, 0);
    let other_save = applied(
        repository
            .mutate(
                other.id,
                paper_ids[2],
                first_operation,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(!other_save.0.removed());
    assert_eq!(other_save.0.revision, 1);
    assert_eq!(
        user_watermark(database.pool(), owner.id).await,
        owner_watermark_before_other
    );
    assert_eq!(
        user_watermark(database.pool(), cleanup_race_user.id).await,
        0
    );
    let other_page = found_page(
        repository
            .list(other.id, LibraryState::ToRead, None, 20)
            .await
            .unwrap(),
    );
    assert_eq!(other_page.items.len(), 1);
    assert_eq!(other_page.items[0].item.paper_id, paper_ids[2]);
    assert_eq!(other_page.sync_revision, 1);
    assert!(matches!(
        repository
            .list(suspended.id, LibraryState::ToRead, None, 20)
            .await
            .unwrap(),
        LibraryReadOutcome::Inactive(AccountStatus::Suspended)
    ));
    assert_eq!(
        repository
            .mutate(
                suspended.id,
                paper_ids[2],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Inactive(AccountStatus::Suspended)
    );
    assert_eq!(
        repository
            .mutate(
                AuthenticatedUserId::new(Uuid::now_v7()),
                paper_ids[2],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::AccountNotFound
    );
    assert_eq!(
        repository
            .mutate(
                owner.id,
                Uuid::now_v7(),
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::PaperNotFound
    );

    // Populate deterministic pages. Listing joins metadata only and never
    // prepares papers or inserts work.
    for paper_id in &paper_ids[3..8] {
        tokio::time::sleep(Duration::from_millis(2)).await;
        applied(
            repository
                .mutate(
                    owner.id,
                    *paper_id,
                    Uuid::now_v7(),
                    LibraryMutationIntent::Save,
                    LibraryState::ToRead,
                )
                .await
                .unwrap(),
        );
    }
    assert_eq!(user_watermark(database.pool(), other.id).await, 1);
    assert_eq!(
        found_changes(
            repository
                .changes(cleanup_race_user.id, 0, 20)
                .await
                .unwrap(),
        )
        .sync_revision,
        0
    );
    let first_page = found_page(
        repository
            .list(owner.id, LibraryState::ToRead, None, 2)
            .await
            .unwrap(),
    );
    assert_eq!(first_page.items.len(), 2);
    assert!(first_page.next_cursor.is_some());
    assert!(first_page.items.iter().all(|entry| !entry.item.removed()));
    assert!(
        first_page
            .items
            .windows(2)
            .all(|pair| pair[0].item.saved_at >= pair[1].item.saved_at)
    );

    // A mutation committed after the first-page fence is intentionally absent
    // from later keyset pages. The mandatory delta pass from sync_revision
    // carries that tombstone, so the full-list-plus-delta protocol converges.
    let post_fence_paper = paper_ids[3];
    assert!(
        first_page
            .items
            .iter()
            .all(|entry| entry.item.paper_id != post_fence_paper)
    );
    let post_fence_remove = applied(
        repository
            .mutate(
                owner.id,
                post_fence_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    )
    .0;
    let mut snapshot_paper_ids = first_page
        .items
        .iter()
        .map(|entry| entry.item.paper_id)
        .collect::<Vec<_>>();
    let mut next_cursor = first_page.next_cursor.clone();
    while let Some(encoded) = next_cursor {
        let page = found_page(
            repository
                .list(owner.id, LibraryState::ToRead, Some(&encoded), 2)
                .await
                .unwrap(),
        );
        assert_eq!(page.sync_revision, first_page.sync_revision);
        snapshot_paper_ids.extend(page.items.iter().map(|entry| entry.item.paper_id));
        next_cursor = page.next_cursor;
    }
    snapshot_paper_ids.sort_unstable();
    snapshot_paper_ids.dedup();
    assert!(!snapshot_paper_ids.contains(&post_fence_paper));
    let post_fence_delta = found_changes(
        repository
            .changes(owner.id, first_page.sync_revision, 100)
            .await
            .unwrap(),
    );
    assert!(post_fence_delta.items.iter().any(|change| {
        change.item.paper_id == post_fence_paper
            && change.item.revision == post_fence_remove.revision
            && change.item.removed()
    }));
    let jobs: i64 = sqlx::query_scalar("SELECT count(*) FROM jobs WHERE paper_id = ANY($1)")
        .bind(&paper_ids)
        .fetch_one(database.pool())
        .await
        .unwrap();
    assert_eq!(jobs, 0, "library metadata reads never enqueue preparation");
    let non_initial_processing: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM paper_processing WHERE paper_id = ANY($1) AND stage <> 'not_requested'",
    )
    .bind(&paper_ids)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(non_initial_processing, 0);

    // Incremental pages are ascending, fenced by the account's committed
    // watermark, and active changes always include metadata.
    let changes = found_changes(repository.changes(owner.id, 0, 2).await.unwrap());
    assert_eq!(changes.items.len(), 2);
    assert!(changes.has_more);
    assert_eq!(
        changes.next_after_revision,
        changes.items.last().unwrap().item.revision
    );
    assert!(
        changes
            .items
            .windows(2)
            .all(|pair| pair[0].item.revision < pair[1].item.revision)
    );
    assert!(
        changes
            .items
            .iter()
            .filter(|change| !change.item.removed())
            .all(|change| change.paper.is_some())
    );
    let empty_tail = found_changes(
        repository
            .changes(owner.id, changes.sync_revision, 100)
            .await
            .unwrap(),
    );
    assert!(empty_tail.items.is_empty());
    assert_eq!(empty_tail.next_after_revision, empty_tail.sync_revision);

    // Concurrent last-accepted mutations serialize per paper. The canonical
    // row exactly matches the maximum accepted revision, irrespective of task
    // scheduling order.
    let race_paper = paper_ids[8];
    let mut racers = tokio::task::JoinSet::new();
    for index in 0..32 {
        let repository = repository.clone();
        let user_id = owner.id;
        racers.spawn(async move {
            let intent = if index % 2 == 0 {
                LibraryMutationIntent::Save
            } else {
                LibraryMutationIntent::Remove
            };
            applied(
                repository
                    .mutate(
                        user_id,
                        race_paper,
                        Uuid::now_v7(),
                        intent,
                        LibraryState::ToRead,
                    )
                    .await
                    .unwrap(),
            )
            .0
        });
    }
    let mut race_results = Vec::new();
    while let Some(result) = racers.join_next().await {
        race_results.push(result.unwrap());
    }
    let latest = race_results
        .iter()
        .max_by_key(|item| item.revision)
        .unwrap();
    let race_change = found_changes(
        repository
            .changes(owner.id, latest.revision - 1, 10)
            .await
            .unwrap(),
    );
    assert_eq!(race_change.items[0].item, *latest);
    let mut revisions = race_results
        .iter()
        .map(|item| item.revision)
        .collect::<Vec<_>>();
    revisions.sort_unstable();
    revisions.dedup();
    assert_eq!(revisions.len(), 32);
    assert!(
        revisions.windows(2).all(|pair| pair[1] == pair[0] + 1),
        "same-account commits must receive a contiguous serialized order"
    );

    // A simultaneous duplicate operation is accepted once and replayed by all
    // other callers. A conflicting use of one ID has exactly one winner.
    let duplicate_paper = paper_ids[9];
    let duplicate_operation = Uuid::now_v7();
    let mut duplicates = tokio::task::JoinSet::new();
    for _ in 0..16 {
        let repository = repository.clone();
        let user_id = owner.id;
        duplicates.spawn(async move {
            applied(
                repository
                    .mutate(
                        user_id,
                        duplicate_paper,
                        duplicate_operation,
                        LibraryMutationIntent::Save,
                        LibraryState::ToRead,
                    )
                    .await
                    .unwrap(),
            )
        });
    }
    let mut duplicate_results = Vec::new();
    while let Some(result) = duplicates.join_next().await {
        duplicate_results.push(result.unwrap());
    }
    assert_eq!(
        duplicate_results
            .iter()
            .filter(|(_, replayed)| !replayed)
            .count(),
        1
    );
    assert!(
        duplicate_results
            .iter()
            .all(|(item, _)| item.revision == duplicate_results[0].0.revision)
    );
    let operation_rows: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM library_operations WHERE user_id = $1 AND operation_id = $2",
    )
    .bind(owner.id.into_inner())
    .bind(duplicate_operation)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(operation_rows, 1);

    let conflict_paper = paper_ids[10];
    let conflict_operation = Uuid::now_v7();
    let save = repository.clone();
    let remove = repository.clone();
    let save_task = tokio::spawn(async move {
        save.mutate(
            owner.id,
            conflict_paper,
            conflict_operation,
            LibraryMutationIntent::Save,
            LibraryState::ToRead,
        )
        .await
        .unwrap()
    });
    let remove_task = tokio::spawn(async move {
        remove
            .mutate(
                owner.id,
                conflict_paper,
                conflict_operation,
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap()
    });
    let conflict_results = [save_task.await.unwrap(), remove_task.await.unwrap()];
    assert_eq!(
        conflict_results
            .iter()
            .filter(|result| matches!(result, LibraryMutationOutcome::IdempotencyConflict))
            .count(),
        1
    );
    assert_eq!(
        conflict_results
            .iter()
            .filter(|result| matches!(result, LibraryMutationOutcome::Applied { .. }))
            .count(),
        1
    );

    // Failed preconditions never allocate or persist an operation.
    let clock_before = user_watermark(database.pool(), owner.id).await;
    let missing_operation = Uuid::now_v7();
    assert_eq!(
        repository
            .mutate(
                owner.id,
                Uuid::now_v7(),
                missing_operation,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::PaperNotFound
    );
    let clock_after = user_watermark(database.pool(), owner.id).await;
    assert_eq!(clock_after, clock_before);
    let missing_operation_rows: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM library_operations WHERE user_id = $1 AND operation_id = $2",
    )
    .bind(owner.id.into_inner())
    .bind(missing_operation)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(missing_operation_rows, 0);

    // The transactional per-user fence rolls back with its canonical write, so
    // readers never observe an abandoned revision or row.
    let rollback_paper = paper_ids[12];
    let rollback_operation = Uuid::now_v7();
    let committed_clock_before = user_watermark(database.pool(), cleanup_race_user.id).await;
    let mut rolled_back = database.pool().begin().await.unwrap();
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (
            user_id,
            current_revision,
            purged_through_revision
        )
        VALUES ($1, 0, 0)
        ON CONFLICT (user_id) DO NOTHING
        ",
    )
    .bind(cleanup_race_user.id.into_inner())
    .execute(&mut *rolled_back)
    .await
    .unwrap();
    let abandoned_revision: i64 = sqlx::query_scalar(
        r"
        UPDATE library_sync_metadata
        SET current_revision = current_revision + 1
        WHERE user_id = $1
        RETURNING current_revision
        ",
    )
    .bind(cleanup_race_user.id.into_inner())
    .fetch_one(&mut *rolled_back)
    .await
    .unwrap();
    assert!(abandoned_revision > committed_clock_before);
    sqlx::query(
        r"
        INSERT INTO user_paper_library (
            user_id,
            paper_id,
            state,
            saved_at,
            updated_at,
            revision,
            last_operation_id
        )
        VALUES ($1, $2, 'to_read', statement_timestamp(), statement_timestamp(), $3, $4)
        ",
    )
    .bind(cleanup_race_user.id.into_inner())
    .bind(rollback_paper)
    .bind(abandoned_revision)
    .bind(rollback_operation)
    .execute(&mut *rolled_back)
    .await
    .unwrap();
    rolled_back.rollback().await.unwrap();
    let committed_clock_after = user_watermark(database.pool(), cleanup_race_user.id).await;
    assert_eq!(committed_clock_after, committed_clock_before);
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM user_paper_library WHERE user_id = $1 AND paper_id = $2",
        )
        .bind(cleanup_race_user.id.into_inner())
        .bind(rollback_paper)
        .fetch_one(database.pool())
        .await
        .unwrap(),
        0
    );

    // The mutation bucket is shared across repository instances/API replicas.
    let rate_a = database.rate_limits();
    let rate_b = Database::from_pool(database.pool().clone()).rate_limits();
    let rate_user = AuthenticatedUserId::new(Uuid::now_v7());
    let rate = RateLimitRequest::library_mutation(rate_user, 2, Duration::from_secs(60)).unwrap();
    assert!(rate_a.check(&rate).await.unwrap().allowed);
    assert!(rate_b.check(&rate).await.unwrap().allowed);
    assert!(!rate_a.check(&rate).await.unwrap().allowed);

    // Force cleanup to commit between the change reader's floor lookup and row
    // query. The repeatable-read snapshot must still return the tombstone;
    // under READ COMMITTED this schedule would silently skip it and let the
    // caller advance to the watermark.
    let cleanup_race_paper = paper_ids[12];
    let cleanup_race_tombstone = applied(
        repository
            .mutate(
                cleanup_race_user.id,
                cleanup_race_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    )
    .0;
    let cleanup_race_old = Utc::now() - TimeDelta::days(91);
    sqlx::query(
        r"
        UPDATE user_paper_library
        SET saved_at = $3, updated_at = $3, removed_at = $3
        WHERE user_id = $1 AND paper_id = $2
        ",
    )
    .bind(cleanup_race_user.id.into_inner())
    .bind(cleanup_race_paper)
    .bind(cleanup_race_old)
    .execute(database.pool())
    .await
    .unwrap();

    let mut blocker = database.pool().begin().await.unwrap();
    sqlx::query("LOCK TABLE paper_processing IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *blocker)
        .await
        .unwrap();
    let change_repository = repository.clone();
    let cleanup_race_user_id = cleanup_race_user.id;
    let change_task = tokio::spawn(async move {
        change_repository
            .changes(cleanup_race_user_id, 0, 100)
            .await
            .unwrap()
    });
    let mut reader_is_waiting = false;
    for _ in 0..100 {
        reader_is_waiting = sqlx::query_scalar(
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
        .fetch_one(database.pool())
        .await
        .unwrap();
        if reader_is_waiting {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        reader_is_waiting,
        "change reader did not reach the forced lock"
    );
    assert_eq!(
        repository
            .cleanup_tombstones(Duration::from_secs(90 * 24 * 60 * 60), 100)
            .await
            .unwrap(),
        1
    );
    blocker.commit().await.unwrap();
    let raced_changes = found_changes(change_task.await.unwrap());
    assert_eq!(raced_changes.items.len(), 1);
    assert_eq!(
        raced_changes.items[0].item.revision,
        cleanup_race_tombstone.revision
    );
    assert!(raced_changes.items[0].item.removed());
    assert!(matches!(
        repository
            .changes(cleanup_race_user.id, 0, 100)
            .await
            .unwrap(),
        LibraryChangesOutcome::ResetRequired {
            purged_through_revision,
            ..
        } if purged_through_revision == cleanup_race_tombstone.revision
    ));

    // Cleanup locks an account's revision fence before its tombstones, exactly
    // like mutation. A transaction holding that same lock sequence makes the
    // schedule deterministic: cleanup must wait on its metadata fence rather
    // than locking or skip-locking the tombstone first. A real re-save queued
    // behind cleanup must then let both operations finish without a deadlock.
    let lock_order_paper = paper_ids[10];
    let lock_order_tombstone = applied(
        repository
            .mutate(
                cleanup_race_user.id,
                lock_order_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    )
    .0;
    sqlx::query(
        r"
        UPDATE user_paper_library
        SET saved_at = $3, updated_at = $3, removed_at = $3
        WHERE user_id = $1 AND paper_id = $2
        ",
    )
    .bind(cleanup_race_user.id.into_inner())
    .bind(lock_order_paper)
    .bind(cleanup_race_old)
    .execute(database.pool())
    .await
    .unwrap();

    let mut mutation_blocker = database.pool().begin().await.unwrap();
    let blocker_xid: String = sqlx::query_scalar("SELECT pg_current_xact_id()::text")
        .fetch_one(&mut *mutation_blocker)
        .await
        .unwrap();
    let blocked_user: Uuid = sqlx::query_scalar(
        r"
        SELECT user_id
        FROM library_sync_metadata
        WHERE user_id = $1
        FOR UPDATE
        ",
    )
    .bind(cleanup_race_user.id.into_inner())
    .fetch_one(&mut *mutation_blocker)
    .await
    .unwrap();
    assert_eq!(blocked_user, cleanup_race_user.id.into_inner());
    let blocked_paper: Uuid = sqlx::query_scalar(
        r"
        SELECT paper_id
        FROM user_paper_library
        WHERE user_id = $1 AND paper_id = $2
        FOR UPDATE
        ",
    )
    .bind(cleanup_race_user.id.into_inner())
    .bind(lock_order_paper)
    .fetch_one(&mut *mutation_blocker)
    .await
    .unwrap();
    assert_eq!(blocked_paper, lock_order_paper);

    let lock_order_cleanup = repository.clone();
    let cleanup_task = tokio::spawn(async move {
        lock_order_cleanup
            .cleanup_tombstones(Duration::from_secs(90 * 24 * 60 * 60), 1)
            .await
    });
    let mut cleanup_waits_on_fence = false;
    for _ in 0..100 {
        let waiters: i64 = sqlx::query_scalar(
            r"
            SELECT count(*)
            FROM pg_locks
            WHERE locktype = 'transactionid'
              AND transactionid::text = $1
              AND NOT granted
            ",
        )
        .bind(&blocker_xid)
        .fetch_one(database.pool())
        .await
        .unwrap();
        if waiters > 0 {
            cleanup_waits_on_fence = true;
            break;
        }
        assert!(
            !cleanup_task.is_finished(),
            "cleanup skipped the tombstone before locking its account fence"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        cleanup_waits_on_fence,
        "cleanup did not wait for the mutation-shaped metadata fence"
    );

    let mutation_repository = repository.clone();
    let lock_order_user_id = cleanup_race_user.id;
    let mutation_task = tokio::spawn(async move {
        mutation_repository
            .mutate(
                lock_order_user_id,
                lock_order_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
    });
    tokio::time::sleep(Duration::from_millis(25)).await;
    assert!(
        !mutation_task.is_finished(),
        "same-account mutation should queue behind cleanup's revision fence"
    );
    mutation_blocker.commit().await.unwrap();

    let removed = tokio::time::timeout(Duration::from_secs(5), cleanup_task)
        .await
        .expect("cleanup deadlocked")
        .unwrap()
        .unwrap();
    assert_eq!(removed, 1);
    let saved_after_cleanup = applied(
        tokio::time::timeout(Duration::from_secs(5), mutation_task)
            .await
            .expect("mutation deadlocked with cleanup")
            .unwrap()
            .unwrap(),
    )
    .0;
    assert!(!saved_after_cleanup.removed());
    assert!(saved_after_cleanup.revision > lock_order_tombstone.revision);

    // Cleanup is bounded, advances the reset floor transactionally, and leaves
    // the ledger able to answer an ancient duplicate without recreating a row.
    let cleanup_paper = paper_ids[11];
    let cleanup_save = Uuid::now_v7();
    applied(
        repository
            .mutate(
                owner.id,
                cleanup_paper,
                cleanup_save,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    let cleanup_remove = Uuid::now_v7();
    let cleanup_tombstone = applied(
        repository
            .mutate(
                owner.id,
                cleanup_paper,
                cleanup_remove,
                LibraryMutationIntent::Remove,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    )
    .0;
    let old = Utc::now() - TimeDelta::days(91);
    sqlx::query(
        r"
        UPDATE user_paper_library
        SET saved_at = $3, updated_at = $3, removed_at = $3
        WHERE user_id = $1 AND paper_id = $2
        ",
    )
    .bind(owner.id.into_inner())
    .bind(cleanup_paper)
    .bind(old)
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        repository
            .cleanup_tombstones(Duration::from_secs(90 * 24 * 60 * 60), 1)
            .await
            .unwrap(),
        1
    );
    let tombstone_rows: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM user_paper_library WHERE user_id = $1 AND paper_id = $2",
    )
    .bind(owner.id.into_inner())
    .bind(cleanup_paper)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(tombstone_rows, 0);
    assert!(matches!(
        repository.changes(owner.id, 0, 100).await.unwrap(),
        LibraryChangesOutcome::ResetRequired {
            purged_through_revision,
            ..
        } if purged_through_revision >= cleanup_tombstone.revision
    ));
    let compacted_replay = applied(
        repository
            .mutate(
                owner.id,
                cleanup_paper,
                cleanup_save,
                LibraryMutationIntent::Save,
                LibraryState::ToRead,
            )
            .await
            .unwrap(),
    );
    assert!(compacted_replay.1);
    assert!(compacted_replay.0.removed());
    assert_eq!(compacted_replay.0.last_operation_id, cleanup_remove);
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM user_paper_library WHERE user_id = $1 AND paper_id = $2",
        )
        .bind(owner.id.into_inner())
        .bind(cleanup_paper)
        .fetch_one(database.pool())
        .await
        .unwrap(),
        0
    );

    let index_definitions: Vec<String> = sqlx::query_scalar(
        r"
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename IN (
              'user_paper_library',
              'library_operations',
              'library_sync_metadata'
          )
        ",
    )
    .fetch_all(database.pool())
    .await
    .unwrap();
    let joined_indexes = index_definitions.join("\n");
    for required in [
        "user_paper_library_active_list_idx",
        "user_paper_library_active_paper_idx",
        "user_paper_library_changes_idx",
        "user_paper_library_tombstone_cleanup_idx",
        "library_operations_paper_revision_idx",
    ] {
        assert!(
            joined_indexes.contains(required),
            "missing index {required}"
        );
    }

    sqlx::query("DELETE FROM shared_rate_limit_buckets WHERE bucket = 'library_mutation'")
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(&issuer)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE arxiv_base_id LIKE $1")
        .bind(format!("library.{unique}.%"))
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines, clippy::similar_names)]
async fn postgres_library_forward_migration_rebases_each_user_and_forces_legacy_reset() {
    const PER_USER_EPOCH: i64 = 4_398_046_511_104;

    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL library migration coverage");
        return;
    };
    let database = Database::connect(&database_url, 2).await.unwrap();
    let schema = format!("library_migration_{}", Uuid::now_v7().simple());
    let mut connection = database.pool().acquire().await.unwrap();
    sqlx::query(&format!("CREATE SCHEMA {schema}"))
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::query(&format!("SET search_path TO {schema}, public"))
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::raw_sql(
        r"
        CREATE TABLE users (id uuid PRIMARY KEY);
        CREATE TABLE papers (id uuid PRIMARY KEY);
        ",
    )
    .execute(&mut *connection)
    .await
    .unwrap();
    sqlx::raw_sql(include_str!("../../../migrations/0006_library.sql"))
        .execute(&mut *connection)
        .await
        .unwrap();

    let user_a = Uuid::now_v7();
    let user_b = Uuid::now_v7();
    let paper_a = Uuid::now_v7();
    let paper_b = Uuid::now_v7();
    let operation_a_save = Uuid::now_v7();
    let operation_a_remove = Uuid::now_v7();
    let operation_b_save = Uuid::now_v7();
    sqlx::query("INSERT INTO users (id) VALUES ($1), ($2)")
        .bind(user_a)
        .bind(user_b)
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::query("INSERT INTO papers (id) VALUES ($1), ($2)")
        .bind(paper_a)
        .bind(paper_b)
        .execute(&mut *connection)
        .await
        .unwrap();

    let accepted_at = Utc::now() - TimeDelta::seconds(1);
    for (user_id, operation_id, paper_id, intent, revision, removed) in [
        (user_a, operation_a_save, paper_a, "save", 2_i64, false),
        (user_b, operation_b_save, paper_b, "save", 3_i64, false),
        (user_a, operation_a_remove, paper_a, "remove", 5_i64, true),
    ] {
        sqlx::query(
            r"
            INSERT INTO library_operations (
                user_id,
                operation_id,
                paper_id,
                intent,
                state,
                intent_fingerprint,
                accepted_revision,
                accepted_saved_at,
                accepted_updated_at,
                accepted_removed_at
            )
            VALUES (
                $1,
                $2,
                $3,
                $4,
                'to_read',
                digest($3::text || ':' || $4 || ':to_read', 'sha256'),
                $5,
                $6,
                $6,
                CASE WHEN $7 THEN $6 ELSE NULL END
            )
            ",
        )
        .bind(user_id)
        .bind(operation_id)
        .bind(paper_id)
        .bind(intent)
        .bind(revision)
        .bind(accepted_at)
        .bind(removed)
        .execute(&mut *connection)
        .await
        .unwrap();
    }
    sqlx::query(
        r"
        INSERT INTO user_paper_library (
            user_id,
            paper_id,
            state,
            saved_at,
            updated_at,
            removed_at,
            revision,
            last_operation_id
        )
        VALUES
            ($1, $2, 'to_read', $7, $7, $7, 5, $3),
            ($4, $5, 'to_read', $7, $7, NULL, 3, $6)
        ",
    )
    .bind(user_a)
    .bind(paper_a)
    .bind(operation_a_remove)
    .bind(user_b)
    .bind(paper_b)
    .bind(operation_b_save)
    .bind(accepted_at)
    .execute(&mut *connection)
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (
            user_id,
            current_revision,
            purged_through_revision
        )
        VALUES ($1, 5, 2), ($2, 3, 0)
        ",
    )
    .bind(user_a)
    .bind(user_b)
    .execute(&mut *connection)
    .await
    .unwrap();
    sqlx::query("UPDATE library_revision_clock SET current_revision = 5")
        .execute(&mut *connection)
        .await
        .unwrap();

    sqlx::raw_sql(include_str!(
        "../../../migrations/0007_per_user_library_revisions.sql"
    ))
    .execute(&mut *connection)
    .await
    .unwrap();

    let user_a_revisions: Vec<i64> = sqlx::query_scalar(
        "SELECT accepted_revision FROM library_operations WHERE user_id = $1 ORDER BY accepted_revision",
    )
    .bind(user_a)
    .fetch_all(&mut *connection)
    .await
    .unwrap();
    assert_eq!(
        user_a_revisions,
        vec![PER_USER_EPOCH + 1, PER_USER_EPOCH + 2]
    );
    let user_b_revisions: Vec<i64> = sqlx::query_scalar(
        "SELECT accepted_revision FROM library_operations WHERE user_id = $1 ORDER BY accepted_revision",
    )
    .bind(user_b)
    .fetch_all(&mut *connection)
    .await
    .unwrap();
    assert_eq!(user_b_revisions, vec![PER_USER_EPOCH + 1]);

    let canonical_a: i64 = sqlx::query_scalar(
        "SELECT revision FROM user_paper_library WHERE user_id = $1 AND paper_id = $2",
    )
    .bind(user_a)
    .bind(paper_a)
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    let canonical_b: i64 = sqlx::query_scalar(
        "SELECT revision FROM user_paper_library WHERE user_id = $1 AND paper_id = $2",
    )
    .bind(user_b)
    .bind(paper_b)
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    assert_eq!(canonical_a, PER_USER_EPOCH + 2);
    assert_eq!(canonical_b, PER_USER_EPOCH + 1);

    let metadata_a: (i64, i64) = sqlx::query_as(
        "SELECT current_revision, purged_through_revision FROM library_sync_metadata WHERE user_id = $1",
    )
    .bind(user_a)
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    let metadata_b: (i64, i64) = sqlx::query_as(
        "SELECT current_revision, purged_through_revision FROM library_sync_metadata WHERE user_id = $1",
    )
    .bind(user_b)
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    assert_eq!(metadata_a, (PER_USER_EPOCH + 2, PER_USER_EPOCH + 1));
    assert_eq!(metadata_b, (PER_USER_EPOCH + 1, PER_USER_EPOCH));
    assert!(5 < metadata_a.1 && 3 < metadata_b.1);

    let global_objects_retired: bool = sqlx::query_scalar(
        r"
        SELECT to_regclass('library_revision_clock') IS NULL
           AND to_regclass('library_revision_seq') IS NULL
        ",
    )
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    assert!(global_objects_retired);

    sqlx::query("SET search_path TO public")
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::query(&format!("DROP SCHEMA {schema} CASCADE"))
        .execute(&mut *connection)
        .await
        .unwrap();
}

fn metadata(base_id: &str, index: i64) -> PaperMetadata {
    let published_at = Utc::now() - TimeDelta::days(20 - index);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: format!("Library fixture {index}"),
        abstract_text: "A metadata-only library fixture.".to_owned(),
        authors: vec![Author::from("Ada Lovelace".to_owned())],
        primary_category: "cs.AI".to_owned(),
        categories: vec!["cs.AI".to_owned()],
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

fn applied(outcome: LibraryMutationOutcome) -> (LibraryItem, bool) {
    match outcome {
        LibraryMutationOutcome::Applied { item, replayed } => (item, replayed),
        unexpected => panic!("expected applied library mutation, got {unexpected:?}"),
    }
}

fn found_page(outcome: LibraryReadOutcome<db::StoredLibraryPage>) -> db::StoredLibraryPage {
    match outcome {
        LibraryReadOutcome::Found(page) => page,
        unexpected => panic!("expected library page, got {unexpected:?}"),
    }
}

fn test_cursor_codec() -> opaque_cursor::OpaqueCursorCodec {
    let key = STANDARD.encode([0x61; 32]);
    opaque_cursor::OpaqueCursorCodec::parse_keyring(&format!("library_test:{key}")).unwrap()
}

fn found_changes(outcome: LibraryChangesOutcome) -> db::StoredLibraryChangesPage {
    match outcome {
        LibraryChangesOutcome::Found(page) => page,
        unexpected => panic!("expected library changes, got {unexpected:?}"),
    }
}

async fn user_watermark(pool: &sqlx::PgPool, user_id: AuthenticatedUserId) -> i64 {
    sqlx::query_scalar(
        r"
        SELECT COALESCE(
            (
                SELECT current_revision
                FROM library_sync_metadata
                WHERE user_id = $1
            ),
            0
        )
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(pool)
    .await
    .unwrap()
}
