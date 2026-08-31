use std::time::Duration;

use chrono::{TimeDelta, Utc};
use db::{
    Database, LibraryCollectionIntent, LibraryItemFilter, LibraryItemMutation, LibraryItemTagWrite,
    LibraryListItemWrite, LibraryListWrite, LibraryMutationIntent, LibraryMutationOutcome,
    LibraryOperationResolution, LibraryReadOutcome, LibraryTagWrite, LibraryV2MutationOutcome,
    LibraryV2ReadOutcome,
};
use domain::{
    ArxivIdentifier, Author, LibrarySaveSourceKind, LibraryState, LibraryV2Change, PaperMetadata,
};
use reading_feed::{ReadingFeedSnapshot, ReadingFeedSnapshotRequest, ReadingFeedStore as _};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_library_v2_is_revisioned_account_scoped_and_queue_authoritative() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL library-v2 coverage");
        return;
    };
    let database = Database::connect(&database_url, 16).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let accounts = database.accounts();
    let owner = accounts
        .provision_oidc_identity(
            &format!("https://library-v2.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let other = accounts
        .provision_oidc_identity(
            &format!("https://library-v2.test/{unique}"),
            "other",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let papers = database.papers();
    let inbox_paper = papers
        .upsert_metadata(&metadata(&unique, 1))
        .await
        .unwrap()
        .id;
    let archived_paper = papers
        .upsert_metadata(&metadata(&unique, 2))
        .await
        .unwrap()
        .id;
    let library = database.library();

    let inbox_operation = Uuid::now_v7();
    let inbox = applied_item(
        library
            .mutate_item(
                owner.id,
                inbox_paper,
                inbox_operation,
                LibraryMutationIntent::Save,
                LibraryItemMutation::replace(
                    LibraryState::Inbox,
                    Some("Revisit the core proof".to_owned()),
                    Some(LibrarySaveSourceKind::TitleSearch),
                ),
            )
            .await
            .unwrap(),
    );
    assert_eq!(inbox.revision, 1);
    assert_eq!(
        inbox.private_note.as_deref(),
        Some("Revisit the core proof")
    );
    assert_eq!(
        inbox.save_source_kind,
        Some(LibrarySaveSourceKind::TitleSearch)
    );
    let archived = applied_item(
        library
            .mutate_item(
                owner.id,
                archived_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryItemMutation::replace(
                    LibraryState::Archived,
                    None,
                    Some(LibrarySaveSourceKind::Discovery),
                ),
            )
            .await
            .unwrap(),
    );
    assert_eq!(archived.revision, 2);
    assert!(archived.archived_at.is_some());
    assert!(!archived.active());

    let active = found_page(library.list_active(owner.id, None, 20).await.unwrap());
    assert_eq!(
        active
            .items
            .iter()
            .map(|entry| entry.item.paper_id)
            .collect::<Vec<_>>(),
        vec![inbox_paper]
    );
    let archived_page = found_page(
        library
            .list_items(
                owner.id,
                LibraryItemFilter {
                    state: Some(LibraryState::Archived),
                    ..LibraryItemFilter::default()
                },
                None,
                20,
            )
            .await
            .unwrap(),
    );
    assert_eq!(archived_page.items[0].item.paper_id, archived_paper);

    let list_id = Uuid::now_v7();
    let list_operation = Uuid::now_v7();
    let list_write = LibraryListWrite {
        id: list_id,
        name: "Core methods".to_owned(),
        normalized_name: "core methods".to_owned(),
        description: Some("Methods to compare".to_owned()),
        sort_order: 10,
    };
    let created_list = applied_v2(
        library
            .mutate_list(
                owner.id,
                list_operation,
                LibraryCollectionIntent::Create,
                &list_write,
            )
            .await
            .unwrap(),
    );
    assert_eq!(created_list.value.revision, 3);
    let replay = applied_v2(
        library
            .mutate_list(
                owner.id,
                list_operation,
                LibraryCollectionIntent::Create,
                &list_write,
            )
            .await
            .unwrap(),
    );
    assert!(replay.replayed);
    let mut conflicting_list = list_write.clone();
    conflicting_list.name = "Different".to_owned();
    conflicting_list.normalized_name = "different".to_owned();
    assert!(matches!(
        library
            .mutate_list(
                owner.id,
                list_operation,
                LibraryCollectionIntent::Create,
                &conflicting_list,
            )
            .await
            .unwrap(),
        LibraryV2MutationOutcome::IdempotencyConflict
    ));
    applied_v2(
        library
            .mutate_list_item(
                owner.id,
                Uuid::now_v7(),
                LibraryCollectionIntent::Put,
                &LibraryListItemWrite {
                    list_id,
                    paper_id: inbox_paper,
                    position_rank: 20,
                    note: Some("Compare baselines".to_owned()),
                },
            )
            .await
            .unwrap(),
    );

    let tag_id = Uuid::now_v7();
    applied_v2(
        library
            .mutate_tag(
                owner.id,
                Uuid::now_v7(),
                LibraryCollectionIntent::Create,
                &LibraryTagWrite {
                    id: tag_id,
                    name: "Theory".to_owned(),
                    normalized_name: "theory".to_owned(),
                },
            )
            .await
            .unwrap(),
    );
    applied_v2(
        library
            .mutate_item_tag(
                owner.id,
                Uuid::now_v7(),
                LibraryCollectionIntent::Put,
                LibraryItemTagWrite {
                    paper_id: inbox_paper,
                    tag_id,
                },
            )
            .await
            .unwrap(),
    );

    for filter in [
        LibraryItemFilter {
            list_id: Some(list_id),
            ..LibraryItemFilter::default()
        },
        LibraryItemFilter {
            tag_id: Some(tag_id),
            ..LibraryItemFilter::default()
        },
    ] {
        let page = found_page(
            library
                .list_items(owner.id, filter, None, 20)
                .await
                .unwrap(),
        );
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].item.paper_id, inbox_paper);
    }
    assert!(matches!(
        library
            .mutate_list_item(
                other.id,
                Uuid::now_v7(),
                LibraryCollectionIntent::Put,
                &LibraryListItemWrite {
                    list_id,
                    paper_id: inbox_paper,
                    position_rank: 0,
                    note: None,
                },
            )
            .await
            .unwrap(),
        LibraryV2MutationOutcome::ListNotFound
    ));

    let changes = match library.v2_changes(owner.id, 0, 100).await.unwrap() {
        LibraryV2ReadOutcome::Found(page) => page,
        unexpected => panic!("unexpected library-v2 change outcome: {unexpected:?}"),
    };
    assert_eq!(changes.sync_revision, 6);
    assert_eq!(changes.next_after_revision, 6);
    assert!(!changes.has_more);
    assert_eq!(
        changes
            .items
            .iter()
            .map(LibraryV2Change::revision)
            .collect::<Vec<_>>(),
        vec![1, 2, 3, 4, 5, 6]
    );

    let queue = database
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
    } = queue
    else {
        panic!("an Inbox item must keep queue authority");
    };
    assert_eq!(active_to_read_count.get(), 1);
    assert_eq!(items[0].state, LibraryState::Inbox);
    assert_eq!(
        items[0].save_source_kind,
        Some(LibrarySaveSourceKind::TitleSearch)
    );

    for (state, expected_revision) in [(LibraryState::ReadNext, 7), (LibraryState::Reading, 8)] {
        let transitioned = applied_item(
            library
                .mutate_item(
                    owner.id,
                    inbox_paper,
                    Uuid::now_v7(),
                    LibraryMutationIntent::Save,
                    LibraryItemMutation::replace(
                        state,
                        Some("Revisit the core proof".to_owned()),
                        Some(LibrarySaveSourceKind::TitleSearch),
                    ),
                )
                .await
                .unwrap(),
        );
        assert_eq!(transitioned.revision, expected_revision);
        let queue = database
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
            library_revision,
            items,
            ..
        } = queue
        else {
            panic!("an active state transition must retain queue authority");
        };
        assert_eq!(library_revision, expected_revision);
        assert_eq!(items[0].state, state);
    }

    let reviewed = applied_item(
        library
            .mutate_item(
                owner.id,
                inbox_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryItemMutation::replace(
                    LibraryState::Reviewed,
                    Some("Revisit the core proof".to_owned()),
                    Some(LibrarySaveSourceKind::TitleSearch),
                ),
            )
            .await
            .unwrap(),
    );
    assert_eq!(reviewed.revision, 9);
    assert!(reviewed.reviewed_at.is_some());
    assert!(
        found_page(library.list_active(owner.id, None, 20).await.unwrap())
            .items
            .is_empty()
    );
}

#[tokio::test]
async fn postgres_library_reminder_patch_is_idempotent_and_exact() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL reminder coverage");
        return;
    };
    let database = Database::connect(&database_url, 4).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://library-reminder.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let paper_id = database
        .papers()
        .upsert_metadata(&metadata(&unique, 31))
        .await
        .unwrap()
        .id;
    let repository = database.library();
    let selected = Utc::now() + TimeDelta::days(2);
    let base = |reminder_at| {
        LibraryItemMutation::replace_with_reminder(
            LibraryState::Inbox,
            None,
            Some(LibrarySaveSourceKind::Other),
            reminder_at,
        )
    };

    for (operation_id, mutation, expected) in [
        (Uuid::now_v7(), base(Some(Some(selected))), Some(selected)),
        (Uuid::now_v7(), base(None), Some(selected)),
        (Uuid::now_v7(), base(Some(None)), None),
    ] {
        let applied = repository
            .mutate_item(
                account.id,
                paper_id,
                operation_id,
                LibraryMutationIntent::Save,
                mutation.clone(),
            )
            .await
            .unwrap();
        assert_eq!(applied_item(applied).reminder_at, expected);
        assert!(matches!(
            repository
                .mutate_item(
                    account.id,
                    paper_id,
                    operation_id,
                    LibraryMutationIntent::Save,
                    mutation.clone(),
                )
                .await
                .unwrap(),
            LibraryMutationOutcome::Applied { replayed: true, .. }
        ));
        for conflict in [base(None), base(Some(None)), base(Some(Some(selected)))] {
            if conflict != mutation {
                assert!(matches!(
                    repository
                        .mutate_item(
                            account.id,
                            paper_id,
                            operation_id,
                            LibraryMutationIntent::Save,
                            conflict,
                        )
                        .await
                        .unwrap(),
                    LibraryMutationOutcome::IdempotencyConflict
                ));
            }
        }
    }
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_library_replays_v0_operations_and_writes_dual_compatible_v2_operations() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL library compatibility coverage");
        return;
    };
    let database = Database::connect(&database_url, 4).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://library-compat.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let paper_id = database
        .papers()
        .upsert_metadata(&metadata(&unique, 32))
        .await
        .unwrap()
        .id;
    let operation_id = Uuid::now_v7();
    let saved_at = Utc::now() - TimeDelta::minutes(5);
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (user_id, current_revision)
        VALUES ($1, 1)
        ON CONFLICT (user_id) DO UPDATE SET current_revision = 1
        ",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO user_paper_library (
            user_id, paper_id, state, saved_at, updated_at, revision, last_operation_id
        ) VALUES ($1, $2, 'to_read', $3, $3, 1, $4)
        ",
    )
    .bind(account.id.into_inner())
    .bind(paper_id)
    .bind(saved_at)
    .bind(operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO library_operations (
            user_id, operation_id, paper_id, intent, state, intent_fingerprint,
            accepted_revision, accepted_saved_at, accepted_updated_at
        ) VALUES (
            $1, $2, $3, 'save', 'to_read',
            digest($3::text || ':save:to_read', 'sha256'), 1, $4, $4
        )
        ",
    )
    .bind(account.id.into_inner())
    .bind(operation_id)
    .bind(paper_id)
    .bind(saved_at)
    .execute(database.pool())
    .await
    .unwrap();

    let repository = database.library();
    assert!(matches!(
        repository
            .resolve_operation(
                account.id,
                paper_id,
                operation_id,
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryOperationResolution::Replay(item)
            if item.state == LibraryState::Inbox && item.revision == 1
    ));
    assert!(matches!(
        repository
            .resolve_item_operation(
                account.id,
                paper_id,
                operation_id,
                LibraryMutationIntent::Save,
                &LibraryItemMutation::replace(
                    LibraryState::Inbox,
                    Some("new metadata must conflict".to_owned()),
                    None,
                ),
            )
            .await
            .unwrap(),
        LibraryOperationResolution::IdempotencyConflict
    ));

    let v2_operation_id = Uuid::now_v7();
    applied_item(
        repository
            .mutate_item(
                account.id,
                paper_id,
                v2_operation_id,
                LibraryMutationIntent::Save,
                LibraryItemMutation::replace(
                    LibraryState::Inbox,
                    Some("Full v2 intent".to_owned()),
                    Some(LibrarySaveSourceKind::Other),
                ),
            )
            .await
            .unwrap(),
    );
    let dual_compatible: (String, bool, bool) = sqlx::query_as(
        r"
        SELECT state,
               intent_fingerprint = digest(
                   paper_id::text || ':' || intent || ':' || state,
                   'sha256'
               ),
               v2_intent_fingerprint IS NOT NULL
        FROM library_operations
        WHERE user_id = $1 AND operation_id = $2
        ",
    )
    .bind(account.id.into_inner())
    .bind(v2_operation_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(dual_compatible, ("to_read".to_owned(), true, true));
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_library_v2_migration_preserves_v0_state_fingerprint_and_rollback_writes() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL library-v2 migration coverage");
        return;
    };
    let database = Database::connect(&database_url, 2).await.unwrap();
    let schema = format!("library_v2_migration_{}", Uuid::now_v7().simple());
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
    sqlx::raw_sql(include_str!(
        "../../../migrations/0007_per_user_library_revisions.sql"
    ))
    .execute(&mut *connection)
    .await
    .unwrap();

    let user_id = Uuid::now_v7();
    let paper_id = Uuid::now_v7();
    let operation_id = Uuid::now_v7();
    let saved_at = Utc::now() - TimeDelta::hours(1);
    sqlx::query("INSERT INTO users (id) VALUES ($1)")
        .bind(user_id)
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::query("INSERT INTO papers (id) VALUES ($1)")
        .bind(paper_id)
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (user_id, current_revision)
        VALUES ($1, 7)
        ON CONFLICT (user_id) DO UPDATE SET current_revision = 7
        ",
    )
    .bind(user_id)
    .execute(&mut *connection)
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO user_paper_library (
            user_id, paper_id, state, saved_at, updated_at, revision, last_operation_id
        ) VALUES ($1, $2, 'to_read', $3, $3, 7, $4)
        ",
    )
    .bind(user_id)
    .bind(paper_id)
    .bind(saved_at)
    .bind(operation_id)
    .execute(&mut *connection)
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO library_operations (
            user_id, operation_id, paper_id, intent, state, intent_fingerprint,
            accepted_revision, accepted_saved_at, accepted_updated_at
        ) VALUES (
            $1, $2, $3, 'save', 'to_read',
            digest($3::text || ':save:to_read', 'sha256'), 7, $4, $4
        )
        ",
    )
    .bind(user_id)
    .bind(operation_id)
    .bind(paper_id)
    .bind(saved_at)
    .execute(&mut *connection)
    .await
    .unwrap();

    sqlx::raw_sql(include_str!("../../../migrations/0012_library_v2.sql"))
        .execute(&mut *connection)
        .await
        .unwrap();
    let row: (String, chrono::DateTime<Utc>, i64, Uuid) = sqlx::query_as(
        "SELECT state, saved_at, revision, last_operation_id FROM user_paper_library WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    assert_eq!(row, ("to_read".to_owned(), saved_at, 7, operation_id));
    let (operation_state, legacy_fingerprint_valid, v2_fingerprint_absent): (String, bool, bool) =
        sqlx::query_as(
            r"
        SELECT state,
               intent_fingerprint = digest(
                   paper_id::text || ':' || intent || ':' || state,
                   'sha256'
               ),
               v2_intent_fingerprint IS NULL
        FROM library_operations
        WHERE user_id = $1 AND operation_id = $2
        ",
        )
        .bind(user_id)
        .bind(operation_id)
        .fetch_one(&mut *connection)
        .await
        .unwrap();
    assert_eq!(operation_state, "to_read");
    assert!(legacy_fingerprint_valid);
    assert!(v2_fingerprint_absent);
    assert_eq!(
        sqlx::query_scalar::<_, i64>(
            "SELECT current_revision FROM library_sync_metadata WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_one(&mut *connection)
        .await
        .unwrap(),
        7
    );

    // Representative v0 SQL still reads the migrated row and can write a new
    // durable operation without knowing any of the nullable v2 columns.
    let rollback_paper_id = Uuid::now_v7();
    let rollback_operation_id = Uuid::now_v7();
    let rollback_saved_at = Utc::now();
    sqlx::query("INSERT INTO papers (id) VALUES ($1)")
        .bind(rollback_paper_id)
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::query(
        r"
        INSERT INTO user_paper_library (
            user_id, paper_id, state, saved_at, updated_at, revision, last_operation_id
        ) VALUES ($1, $2, 'to_read', $3, $3, 8, $4)
        ",
    )
    .bind(user_id)
    .bind(rollback_paper_id)
    .bind(rollback_saved_at)
    .bind(rollback_operation_id)
    .execute(&mut *connection)
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO library_operations (
            user_id, operation_id, paper_id, intent, state, intent_fingerprint,
            accepted_revision, accepted_saved_at, accepted_updated_at
        ) VALUES (
            $1, $2, $3, 'save', 'to_read',
            digest($3::text || ':save:to_read', 'sha256'), 8, $4, $4
        )
        ",
    )
    .bind(user_id)
    .bind(rollback_operation_id)
    .bind(rollback_paper_id)
    .bind(rollback_saved_at)
    .execute(&mut *connection)
    .await
    .unwrap();
    sqlx::query("UPDATE library_sync_metadata SET current_revision = 8 WHERE user_id = $1")
        .bind(user_id)
        .execute(&mut *connection)
        .await
        .unwrap();
    let legacy_visible: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM user_paper_library WHERE user_id = $1 AND state = 'to_read' AND removed_at IS NULL",
    )
    .bind(user_id)
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    assert_eq!(legacy_visible, 2);
    let rollback_replay_valid: bool = sqlx::query_scalar(
        r"
        SELECT state = 'to_read'
           AND intent_fingerprint = digest(
               paper_id::text || ':' || intent || ':' || state,
               'sha256'
           )
           AND v2_intent_fingerprint IS NULL
        FROM library_operations
        WHERE user_id = $1 AND operation_id = $2
        ",
    )
    .bind(user_id)
    .bind(rollback_operation_id)
    .fetch_one(&mut *connection)
    .await
    .unwrap();
    assert!(rollback_replay_valid);
    sqlx::query("SET search_path TO public")
        .execute(&mut *connection)
        .await
        .unwrap();
    sqlx::query(&format!("DROP SCHEMA {schema} CASCADE"))
        .execute(&mut *connection)
        .await
        .unwrap();
}

fn applied_item(outcome: LibraryMutationOutcome) -> domain::LibraryItem {
    match outcome {
        LibraryMutationOutcome::Applied { item, .. } => item,
        unexpected => panic!("unexpected item mutation outcome: {unexpected:?}"),
    }
}

struct AppliedV2<T> {
    value: T,
    replayed: bool,
}

fn applied_v2<T>(outcome: LibraryV2MutationOutcome<T>) -> AppliedV2<T> {
    match outcome {
        LibraryV2MutationOutcome::Applied { value, replayed } => AppliedV2 { value, replayed },
        _ => panic!("unexpected library-v2 mutation outcome"),
    }
}

fn found_page(outcome: LibraryReadOutcome<db::StoredLibraryPage>) -> db::StoredLibraryPage {
    match outcome {
        LibraryReadOutcome::Found(page) => page,
        unexpected => panic!("unexpected library read outcome: {unexpected:?}"),
    }
}

fn metadata(unique: &str, index: u32) -> PaperMetadata {
    let base_id = format!("2608.{:05}", 40_000 + index);
    let now = Utc::now() - TimeDelta::days(i64::from(index));
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.clone(),
            version: 1,
        },
        title: format!("Library v2 fixture {unique} {index}"),
        abstract_text: "Bounded test metadata.".to_owned(),
        authors: vec![Author {
            name: "Library Tester".to_owned(),
        }],
        primary_category: "cs.AI".to_owned(),
        categories: vec!["cs.AI".to_owned()],
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
