use std::time::Duration;

use chrono::{TimeDelta, Utc};
use db::{
    Database, PaperImportFinalization, PaperImportFinalizeOutcome, PaperImportFingerprint,
    PaperImportInputKind, PaperImportReadOutcome, PaperImportReserveOutcome, PaperImportStatus,
};
use domain::{AccountStatus, ArxivIdentifier, AuthenticatedUserId, Author, PaperMetadata};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_paper_import_reservation_replay_conflict_and_privacy() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL paper import coverage");
        return;
    };
    let database = Database::connect(&database_url, 24).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://paper-import.test/{unique}");
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
    sqlx::query("UPDATE users SET status = 'suspended' WHERE id = $1")
        .bind(suspended.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();

    let papers = database.papers();
    let arxiv_suffix = 10_000 + (Uuid::now_v7().as_u128() % 90_000) as u32;
    let first_metadata = metadata(&format!("2401.{arxiv_suffix:05}"), 0);
    let second_metadata = metadata(&format!("2402.{arxiv_suffix:05}"), 1);
    let first_paper = papers.upsert_metadata(&first_metadata).await.unwrap();
    let second_paper = papers.upsert_metadata(&second_metadata).await.unwrap();
    let repository = database.paper_imports();
    let fingerprint = PaperImportFingerprint::new([0x31; 32]);
    let conflicting_fingerprint = PaperImportFingerprint::new([0x32; 32]);

    let operation_id = Uuid::now_v7();
    let initial_reservation = reserved(
        repository
            .reserve(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
                Some(&first_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
    );
    assert_eq!(initial_reservation.status, PaperImportStatus::Resolving);
    assert_eq!(
        initial_reservation.normalized_arxiv_base.as_deref(),
        Some(first_metadata.arxiv_id.base_id.as_str())
    );
    assert!(initial_reservation.paper_id.is_none());
    assert!(initial_reservation.error_code.is_none());

    assert!(matches!(
        repository
            .read(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
            )
            .await
            .unwrap(),
        PaperImportReadOutcome::Resume(operation)
            if operation.status == PaperImportStatus::Resolving
    ));
    assert_eq!(
        repository
            .read(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                conflicting_fingerprint,
            )
            .await
            .unwrap(),
        PaperImportReadOutcome::Conflict
    );
    assert_eq!(
        repository
            .reserve(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivId,
                fingerprint,
                Some(&first_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
        PaperImportReserveOutcome::Conflict
    );

    let completed_operation = finalized(
        repository
            .finalize(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
                PaperImportFinalization::Completed {
                    normalized_arxiv_base: first_metadata.arxiv_id.base_id.clone(),
                    paper_id: first_paper.id,
                },
            )
            .await
            .unwrap(),
    );
    assert_eq!(completed_operation.status, PaperImportStatus::Completed);
    assert_eq!(completed_operation.paper_id, Some(first_paper.id));
    assert!(completed_operation.completed_at.is_some());
    assert!(matches!(
        repository
            .read(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
            )
            .await
            .unwrap(),
        PaperImportReadOutcome::Replay(operation)
            if operation.paper_id == Some(first_paper.id)
    ));
    assert!(matches!(
        repository
            .reserve(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
                Some(&first_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
        PaperImportReserveOutcome::Replay(operation)
            if operation.paper_id == Some(first_paper.id)
    ));
    assert_eq!(
        repository
            .reserve(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
                Some(&second_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
        PaperImportReserveOutcome::Conflict
    );
    assert!(matches!(
        repository
            .finalize(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
                PaperImportFinalization::Completed {
                    normalized_arxiv_base: first_metadata.arxiv_id.base_id.clone(),
                    paper_id: first_paper.id,
                },
            )
            .await
            .unwrap(),
        PaperImportFinalizeOutcome::Replay(operation)
            if operation.paper_id == Some(first_paper.id)
    ));
    assert_eq!(
        repository
            .finalize(
                owner.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
                PaperImportFinalization::Completed {
                    normalized_arxiv_base: first_metadata.arxiv_id.base_id.clone(),
                    paper_id: second_paper.id,
                },
            )
            .await
            .unwrap(),
        PaperImportFinalizeOutcome::Conflict
    );

    // Retryable failure is resumable. Reserving it again clears the bounded
    // error and commits `resolving` before any caller performs external I/O.
    let retry_operation_id = Uuid::now_v7();
    reserved(
        repository
            .reserve(
                owner.id,
                retry_operation_id,
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x41; 32]),
                Some(&second_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
    );
    let retryable = finalized(
        repository
            .finalize(
                owner.id,
                retry_operation_id,
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x41; 32]),
                PaperImportFinalization::RetryableFailure {
                    normalized_arxiv_base: Some(second_metadata.arxiv_id.base_id.clone()),
                    error_code: "PAPER_SEARCH_UNAVAILABLE".to_owned(),
                },
            )
            .await
            .unwrap(),
    );
    assert_eq!(retryable.status, PaperImportStatus::RetryableFailure);
    assert_eq!(
        retryable.error_code.as_deref(),
        Some("PAPER_SEARCH_UNAVAILABLE")
    );
    assert!(retryable.completed_at.is_none());
    let resumed = resumed(
        repository
            .reserve(
                owner.id,
                retry_operation_id,
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x41; 32]),
                Some(&second_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
    );
    assert_eq!(resumed.status, PaperImportStatus::Resolving);
    assert!(resumed.error_code.is_none());
    assert!(resumed.completed_at.is_none());

    let terminal_operation_id = Uuid::now_v7();
    reserved(
        repository
            .reserve(
                owner.id,
                terminal_operation_id,
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x51; 32]),
                Some(&second_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
    );
    let terminal = finalized(
        repository
            .finalize(
                owner.id,
                terminal_operation_id,
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x51; 32]),
                PaperImportFinalization::TerminalFailure {
                    normalized_arxiv_base: Some(second_metadata.arxiv_id.base_id.clone()),
                    error_code: "PAPER_RESOLUTION_NOT_FOUND".to_owned(),
                },
            )
            .await
            .unwrap(),
    );
    assert_eq!(terminal.status, PaperImportStatus::TerminalFailure);
    assert!(terminal.completed_at.is_some());
    assert!(matches!(
        repository
            .read(
                owner.id,
                terminal_operation_id,
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x51; 32]),
            )
            .await
            .unwrap(),
        PaperImportReadOutcome::Replay(operation)
            if operation.status == PaperImportStatus::TerminalFailure
    ));

    // The operation key is account-scoped. Concurrent identical reservations
    // produce one row and one `Reserved` winner; every other caller resumes the
    // same durable operation.
    let concurrent_operation_id = Uuid::now_v7();
    let mut callers = tokio::task::JoinSet::new();
    for _ in 0..12 {
        let repository = repository.clone();
        let base_id = first_metadata.arxiv_id.base_id.clone();
        callers.spawn(async move {
            repository
                .reserve(
                    owner.id,
                    concurrent_operation_id,
                    PaperImportInputKind::ArxivUrl,
                    PaperImportFingerprint::new([0x61; 32]),
                    Some(&base_id),
                )
                .await
                .unwrap()
        });
    }
    let mut reserved_count = 0;
    let mut resumed_count = 0;
    while let Some(result) = callers.join_next().await {
        match result.unwrap() {
            PaperImportReserveOutcome::Reserved(_) => reserved_count += 1,
            PaperImportReserveOutcome::Resume(_) => resumed_count += 1,
            unexpected => panic!("unexpected concurrent reservation: {unexpected:?}"),
        }
    }
    assert_eq!(reserved_count, 1);
    assert_eq!(resumed_count, 11);
    let concurrent_rows: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM paper_import_operations WHERE user_id = $1 AND operation_id = $2",
    )
    .bind(owner.id.into_inner())
    .bind(concurrent_operation_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(concurrent_rows, 1);

    assert!(matches!(
        repository
            .reserve(
                other.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
                Some(&first_metadata.arxiv_id.base_id),
            )
            .await
            .unwrap(),
        PaperImportReserveOutcome::Reserved(_)
    ));
    assert_eq!(
        repository
            .read(
                suspended.id,
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
            )
            .await
            .unwrap(),
        PaperImportReadOutcome::Inactive(AccountStatus::Suspended)
    );
    assert_eq!(
        repository
            .read(
                AuthenticatedUserId::new(Uuid::now_v7()),
                operation_id,
                PaperImportInputKind::ArxivUrl,
                fingerprint,
            )
            .await
            .unwrap(),
        PaperImportReadOutcome::AccountNotFound
    );
    assert_eq!(
        repository
            .read(
                owner.id,
                Uuid::now_v7(),
                PaperImportInputKind::ArxivUrl,
                fingerprint,
            )
            .await
            .unwrap(),
        PaperImportReadOutcome::Unknown
    );
    assert_eq!(
        repository
            .finalize(
                owner.id,
                Uuid::now_v7(),
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x81; 32]),
                PaperImportFinalization::Completed {
                    normalized_arxiv_base: second_metadata.arxiv_id.base_id.clone(),
                    paper_id: second_paper.id,
                },
            )
            .await
            .unwrap(),
        PaperImportFinalizeOutcome::Unknown
    );
    assert_eq!(
        repository
            .finalize(
                suspended.id,
                Uuid::now_v7(),
                PaperImportInputKind::ArxivId,
                PaperImportFingerprint::new([0x82; 32]),
                PaperImportFinalization::Completed {
                    normalized_arxiv_base: second_metadata.arxiv_id.base_id.clone(),
                    paper_id: second_paper.id,
                },
            )
            .await
            .unwrap(),
        PaperImportFinalizeOutcome::Inactive(AccountStatus::Suspended)
    );

    // Title results stay in the existing shared cache. The migration adds no
    // second title-specific cache and stores no raw import value/title column.
    let title_cache_key = format!("title:v1:{}", "a".repeat(64));
    papers
        .put_cached_arxiv(
            &title_cache_key,
            "title_search",
            std::slice::from_ref(&second_metadata),
            Duration::from_secs(60),
        )
        .await
        .unwrap();
    let cached = papers
        .get_cached_arxiv(&title_cache_key)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(cached.len(), 1);
    assert_eq!(cached[0].arxiv_id.base_id, second_metadata.arxiv_id.base_id);
    let cache_tables: Vec<String> = sqlx::query_scalar(
        r"
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND (table_name LIKE '%query_cache%' OR table_name LIKE '%search_cache%')
        ORDER BY table_name
        ",
    )
    .fetch_all(database.pool())
    .await
    .unwrap();
    assert_eq!(cache_tables, vec!["arxiv_query_cache"]);
    let raw_input_columns: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'paper_import_operations'
          AND column_name IN ('input_value', 'raw_input', 'submitted_url', 'title')
        ",
    )
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(raw_input_columns, 0);

    // The database remains the final boundary for the fixed-width digest and
    // both closed vocabularies, even if a future caller bypasses this typed
    // repository API.
    assert!(
        sqlx::query(
            r"
            INSERT INTO paper_import_operations (
                user_id, operation_id, input_kind, input_fingerprint, status
            )
            VALUES ($1, $2, 'arxiv_id', $3, 'resolving')
            ",
        )
        .bind(owner.id.into_inner())
        .bind(Uuid::now_v7())
        .bind(vec![0x71_u8; 31])
        .execute(database.pool())
        .await
        .is_err()
    );
    assert!(
        sqlx::query(
            r"
            INSERT INTO paper_import_operations (
                user_id, operation_id, input_kind, input_fingerprint, status
            )
            VALUES ($1, $2, 'raw_url', $3, 'resolving')
            ",
        )
        .bind(owner.id.into_inner())
        .bind(Uuid::now_v7())
        .bind(vec![0x72_u8; 32])
        .execute(database.pool())
        .await
        .is_err()
    );
    assert!(
        sqlx::query(
            r"
            INSERT INTO paper_import_operations (
                user_id, operation_id, input_kind, input_fingerprint, status
            )
            VALUES ($1, $2, 'arxiv_id', $3, 'failed')
            ",
        )
        .bind(owner.id.into_inner())
        .bind(Uuid::now_v7())
        .bind(vec![0x73_u8; 32])
        .execute(database.pool())
        .await
        .is_err()
    );
    let index_definitions: Vec<String> = sqlx::query_scalar(
        r"
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'paper_import_operations'
        ORDER BY indexname
        ",
    )
    .fetch_all(database.pool())
    .await
    .unwrap();
    let indexes = index_definitions.join("\n");
    for required in [
        "paper_import_operations_terminal_cleanup_idx",
        "paper_import_operations_incomplete_cleanup_idx",
        "paper_import_operations_paper_idx",
    ] {
        assert!(indexes.contains(required), "missing index {required}");
    }

    // User deletion owns cleanup through the foreign-key cascade. Paper rows
    // remain independently reusable after the account-private ledger is gone.
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let owner_rows: i64 =
        sqlx::query_scalar("SELECT count(*) FROM paper_import_operations WHERE user_id = $1")
            .bind(owner.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(owner_rows, 0);
    let papers_still_exist: i64 =
        sqlx::query_scalar("SELECT count(*) FROM papers WHERE id = ANY($1)")
            .bind([first_paper.id, second_paper.id])
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(papers_still_exist, 2);

    sqlx::query("DELETE FROM arxiv_query_cache WHERE cache_key = $1")
        .bind(title_cache_key)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(&issuer)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM papers WHERE id = ANY($1)")
        .bind([first_paper.id, second_paper.id])
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_paper_import_retention_is_bounded_and_preserves_inflight_rows() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!(
            "TEST_DATABASE_URL is absent; skipped PostgreSQL paper import retention coverage"
        );
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://paper-import-retention.test/{unique}");
    let owner = database
        .accounts()
        .provision_oidc_identity(&issuer, "owner", Duration::from_secs(900))
        .await
        .unwrap();
    let repository = database.paper_imports();
    let now = Utc::now();
    let cutoff = now - TimeDelta::days(30);
    let oldest_terminal = Uuid::now_v7();
    let newer_terminal = Uuid::now_v7();
    let live_terminal = Uuid::now_v7();
    let resolving = Uuid::now_v7();
    let retryable = Uuid::now_v7();

    sqlx::query(
        r"
        INSERT INTO paper_import_operations (
            user_id, operation_id, input_kind, input_fingerprint,
            status, error_code, created_at, updated_at, completed_at
        )
        VALUES
            ($1, $2, 'arxiv_id', $7, 'terminal_failure', 'NOT_FOUND', $8, $8, $8),
            ($1, $3, 'arxiv_id', $7, 'terminal_failure', 'NOT_FOUND', $9, $9, $9),
            ($1, $4, 'arxiv_id', $7, 'terminal_failure', 'NOT_FOUND', $10, $10, $10),
            ($1, $5, 'arxiv_id', $7, 'resolving', NULL, $8, $8, NULL),
            ($1, $6, 'arxiv_id', $7, 'retryable_failure', 'UPSTREAM_BUSY', $8, $8, NULL)
        ",
    )
    .bind(owner.id.into_inner())
    .bind(oldest_terminal)
    .bind(newer_terminal)
    .bind(live_terminal)
    .bind(resolving)
    .bind(retryable)
    .bind(vec![0x91_u8; 32])
    .bind(now - TimeDelta::days(40))
    .bind(now - TimeDelta::days(35))
    .bind(now - TimeDelta::days(20))
    .execute(database.pool())
    .await
    .unwrap();

    assert!(
        repository
            .cleanup_terminal_operations(cutoff, 0)
            .await
            .is_err()
    );
    assert!(
        repository
            .cleanup_terminal_operations(cutoff, 10_001)
            .await
            .is_err()
    );
    assert_eq!(
        repository
            .cleanup_terminal_operations(cutoff, 1)
            .await
            .unwrap(),
        1
    );
    let oldest_exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM paper_import_operations WHERE user_id = $1 AND operation_id = $2)",
    )
    .bind(owner.id.into_inner())
    .bind(oldest_terminal)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert!(
        !oldest_exists,
        "the deterministic oldest row is removed first"
    );

    assert_eq!(
        repository
            .cleanup_terminal_operations(cutoff, 10)
            .await
            .unwrap(),
        1
    );
    let preserved: Vec<Uuid> = sqlx::query_scalar(
        r"
        SELECT operation_id
        FROM paper_import_operations
        WHERE user_id = $1
        ORDER BY operation_id
        ",
    )
    .bind(owner.id.into_inner())
    .fetch_all(database.pool())
    .await
    .unwrap();
    assert_eq!(preserved.len(), 3);
    assert!(preserved.contains(&live_terminal));
    assert!(preserved.contains(&resolving));
    assert!(preserved.contains(&retryable));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(owner.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

fn metadata(base_id: &str, index: i64) -> PaperMetadata {
    let published_at = Utc::now() - TimeDelta::days(2 - index);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: format!("Paper import fixture {index}"),
        abstract_text: "A bounded metadata-only paper import fixture.".to_owned(),
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

fn reserved(outcome: PaperImportReserveOutcome) -> db::StoredPaperImportOperation {
    match outcome {
        PaperImportReserveOutcome::Reserved(operation) => operation,
        unexpected => panic!("expected reserved paper import, got {unexpected:?}"),
    }
}

fn resumed(outcome: PaperImportReserveOutcome) -> db::StoredPaperImportOperation {
    match outcome {
        PaperImportReserveOutcome::Resume(operation) => operation,
        unexpected => panic!("expected resumable paper import, got {unexpected:?}"),
    }
}

fn finalized(outcome: PaperImportFinalizeOutcome) -> db::StoredPaperImportOperation {
    match outcome {
        PaperImportFinalizeOutcome::Finalized(operation) => operation,
        unexpected => panic!("expected finalized paper import, got {unexpected:?}"),
    }
}
