use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use async_trait::async_trait;
use chrono::{TimeDelta, Utc};
use comments::{
    CommentService, CommentServiceConfig, CommentServiceError, CreateCommentRequest,
    EditCommentRequest, ReportCommentRequest, ReportUserRequest,
};
use db::{Database, RateLimitRequest};
use domain::{
    ArxivIdentifier, Author, CommentReportReason, CommunityGuidelinesVersion, PaperMetadata,
    TermsVersion,
};
use moderation::{ContentModerator, ModerationDecision, ModerationError, ModerationInput};
use tokio::{
    sync::{Barrier, Notify},
    task::JoinSet,
    time::{sleep, timeout},
};
use url::Url;
use uuid::Uuid;

const CONCURRENT_DUPLICATES: usize = 7;

#[tokio::test]
async fn duplicate_lock_waiters_do_not_block_an_unrelated_comment_key() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped comment coordinator availability coverage");
        return;
    };
    // A six-connection pool admits at most three successful coordination
    // guards. One owner plus a duplicate burst used to retain every permit
    // while polling and prevent the unrelated key below from acquiring one.
    let database = Database::connect(&database_url, 6).await.unwrap();
    let repository = database.comments();
    let owner_user = domain::AuthenticatedUserId::new(Uuid::now_v7());
    let owner_key = Uuid::now_v7();
    let owner = repository
        .coordinate_create(owner_user, owner_key)
        .await
        .unwrap();

    let start = Arc::new(Barrier::new(CONCURRENT_DUPLICATES + 1));
    let mut duplicates = JoinSet::new();
    for _ in 0..CONCURRENT_DUPLICATES {
        let repository = repository.clone();
        let start = Arc::clone(&start);
        duplicates.spawn(async move {
            start.wait().await;
            repository
                .coordinate_create(owner_user, owner_key)
                .await?
                .release()
                .await
        });
    }
    start.wait().await;
    sleep(Duration::from_millis(75)).await;

    let unrelated = timeout(
        Duration::from_secs(1),
        repository.coordinate_create(
            domain::AuthenticatedUserId::new(Uuid::now_v7()),
            Uuid::now_v7(),
        ),
    )
    .await
    .expect("duplicate waiters starved an unrelated coordination key")
    .unwrap();
    unrelated.release().await.unwrap();
    owner.release().await.unwrap();

    timeout(Duration::from_secs(5), async {
        while let Some(result) = duplicates.join_next().await {
            result.unwrap().unwrap();
        }
    })
    .await
    .expect("duplicate coordinators did not drain after their owner released");
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn accepted_replays_and_noops_bypass_exhausted_shared_buckets() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL comment-service coverage");
        return;
    };
    let database = Database::connect(&database_url, 12).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://comment-service.test/{unique}");
    let author = database
        .accounts()
        .provision_oidc_identity(&issuer, "author", Duration::from_secs(900))
        .await
        .unwrap();
    let reporter = database
        .accounts()
        .provision_oidc_identity(&issuer, "reporter", Duration::from_secs(900))
        .await
        .unwrap();
    let incomplete = database
        .accounts()
        .provision_oidc_identity(&issuer, "incomplete", Duration::from_secs(900))
        .await
        .unwrap();
    let policy_pending = database
        .accounts()
        .provision_oidc_identity(&issuer, "policy-pending", Duration::from_secs(900))
        .await
        .unwrap();
    let terms = TermsVersion::parse("2026-08-01").unwrap();
    let guidelines = CommunityGuidelinesVersion::parse("2026-08-01").unwrap();
    for (user_id, handle) in [
        (author.id, "service_author"),
        (reporter.id, "service_reporter"),
    ] {
        sqlx::query(
            r"
            UPDATE users
            SET handle = $2,
                terms_version = $3,
                terms_accepted_at = statement_timestamp(),
                community_guidelines_version = $4,
                community_guidelines_accepted_at = statement_timestamp(),
                updated_at = statement_timestamp()
            WHERE id = $1
            ",
        )
        .bind(user_id.into_inner())
        .bind(handle)
        .bind(terms.as_str())
        .bind(guidelines.as_str())
        .execute(database.pool())
        .await
        .unwrap();
    }
    sqlx::query("UPDATE users SET handle = $2 WHERE id = $1")
        .bind(policy_pending.id.into_inner())
        .bind("service_policy_pending")
        .execute(database.pool())
        .await
        .unwrap();
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("comment-service.{unique}")))
        .await
        .unwrap();
    let config = CommentServiceConfig::new(terms, guidelines)
        .with_create_rate_limit(1, Duration::from_secs(3_600))
        .unwrap()
        .with_mutation_rate_limit(1, Duration::from_secs(3_600))
        .unwrap()
        .with_report_rate_limit(1, Duration::from_secs(3_600))
        .unwrap()
        .with_origin_rate_limit(1, Duration::from_secs(3_600))
        .unwrap();
    let moderation_calls = Arc::new(AtomicUsize::new(0));
    let service = CommentService::new(
        database.comments(),
        database.rate_limits(),
        Arc::new(CountingModerator(Arc::clone(&moderation_calls))),
        config,
    );
    let origin_a = "a".repeat(64);
    let origin_b = "b".repeat(64);
    let origin_c = "c".repeat(64);
    let origin_d = "d".repeat(64);
    let origin_e = "e".repeat(64);
    let request_id = Uuid::now_v7();
    let created = service
        .create(
            author.id,
            paper.id,
            CreateCommentRequest {
                client_request_id: request_id,
                body: "A reproducible service-layer observation.".to_owned(),
                origin_scope: origin_a.clone(),
            },
        )
        .await
        .unwrap();
    assert!(!created.replayed);
    assert_eq!(moderation_calls.load(Ordering::SeqCst), 1);
    assert!(matches!(
        service
            .edit(
                reporter.id,
                created.comment.id,
                EditCommentRequest {
                    body: "An unauthorized replacement.".to_owned(),
                    expected_version: created.comment.version,
                },
            )
            .await,
        Err(CommentServiceError::CommentNotFound)
    ));
    assert!(matches!(
        service
            .edit(
                author.id,
                created.comment.id,
                EditCommentRequest {
                    body: "A stale replacement.".to_owned(),
                    expected_version: created.comment.version + 1,
                },
            )
            .await,
        Err(CommentServiceError::EditConflict { current_version })
            if current_version == created.comment.version
    ));
    assert_eq!(moderation_calls.load(Ordering::SeqCst), 1);
    let premature_mutation_buckets: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM shared_rate_limit_buckets WHERE bucket = 'comment_mutation' AND scope_key IN ($1, $2)",
    )
    .bind(format!("user:{}", author.id))
    .bind(format!("user:{}", reporter.id))
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(premature_mutation_buckets, 0);
    assert!(matches!(
        service
            .create(
                incomplete.id,
                paper.id,
                CreateCommentRequest {
                    client_request_id: Uuid::now_v7(),
                    body: "This profile is not eligible to publish.".to_owned(),
                    origin_scope: origin_c.clone(),
                },
            )
            .await,
        Err(CommentServiceError::AccountIncomplete)
    ));
    assert!(matches!(
        service
            .create(
                policy_pending.id,
                paper.id,
                CreateCommentRequest {
                    client_request_id: Uuid::now_v7(),
                    body: "This account must accept the current policies.".to_owned(),
                    origin_scope: origin_d,
                },
            )
            .await,
        Err(CommentServiceError::TermsAcceptanceRequired)
    ));
    assert_eq!(moderation_calls.load(Ordering::SeqCst), 1);
    assert!(matches!(
        service
            .create(
                author.id,
                paper.id,
                CreateCommentRequest {
                    client_request_id: Uuid::now_v7(),
                    body: "A novel request after the account bucket is full.".to_owned(),
                    origin_scope: origin_b.clone(),
                },
            )
            .await,
        Err(CommentServiceError::RateLimited { .. })
    ));
    let replay = service
        .create(
            author.id,
            paper.id,
            CreateCommentRequest {
                client_request_id: request_id,
                body: "A reproducible service-layer observation.".to_owned(),
                origin_scope: origin_a.clone(),
            },
        )
        .await
        .unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.comment.id, created.comment.id);
    assert!(matches!(
        service
            .create(
                author.id,
                paper.id,
                CreateCommentRequest {
                    client_request_id: request_id,
                    body: "A mismatched intent.".to_owned(),
                    origin_scope: origin_a.clone(),
                },
            )
            .await,
        Err(CommentServiceError::IdempotencyConflict)
    ));

    // One bucket is intentionally shared by create and report for the same
    // hashed direct origin, preventing cross-action budget multiplication.
    assert!(matches!(
        service
            .report(
                reporter.id,
                created.comment.id,
                ReportCommentRequest {
                    reason: CommentReportReason::Other,
                    detail: None,
                    origin_scope: origin_a.clone(),
                },
            )
            .await,
        Err(CommentServiceError::RateLimited { .. })
    ));
    sqlx::query(
        "DELETE FROM shared_rate_limit_buckets WHERE bucket = 'comment_report' AND scope_key = $1",
    )
    .bind(format!("user:{}", reporter.id))
    .execute(database.pool())
    .await
    .unwrap();
    let report = service
        .report(
            reporter.id,
            created.comment.id,
            ReportCommentRequest {
                reason: CommentReportReason::Other,
                detail: Some("Please review this observation.".to_owned()),
                origin_scope: origin_b.clone(),
            },
        )
        .await
        .unwrap();
    assert!(!report.replayed);
    assert!(
        !database
            .rate_limits()
            .check(
                &RateLimitRequest::comment_report(reporter.id, 1, Duration::from_secs(3_600),)
                    .unwrap(),
            )
            .await
            .unwrap()
            .allowed
    );
    assert!(
        !database
            .rate_limits()
            .check(
                &RateLimitRequest::comment_report_target(
                    created.comment.id,
                    1,
                    Duration::from_secs(3_600),
                )
                .unwrap(),
            )
            .await
            .unwrap()
            .allowed
    );
    let report_replay = service
        .report(
            reporter.id,
            created.comment.id,
            ReportCommentRequest {
                reason: CommentReportReason::Spam,
                detail: Some("This changed retry intent is ignored.".to_owned()),
                origin_scope: origin_b.clone(),
            },
        )
        .await
        .unwrap();
    assert!(report_replay.replayed);
    assert_eq!(report_replay.report, report.report);

    let user_report = service
        .report_user(
            reporter.id,
            author.id,
            ReportUserRequest {
                reason: CommentReportReason::Harassment,
                detail: Some("Please review this public profile.".to_owned()),
                origin_scope: origin_e.clone(),
            },
        )
        .await
        .unwrap();
    assert!(!user_report.replayed);
    for request in [
        RateLimitRequest::user_report(reporter.id, 1, Duration::from_secs(3_600)).unwrap(),
        RateLimitRequest::user_report_target(author.id, 1, Duration::from_secs(3_600)).unwrap(),
        RateLimitRequest::comment_origin(
            format!("origin:{origin_e}"),
            1,
            Duration::from_secs(3_600),
        )
        .unwrap(),
    ] {
        assert!(
            !database
                .rate_limits()
                .check(&request)
                .await
                .unwrap()
                .allowed
        );
    }
    let user_report_replay = service
        .report_user(
            reporter.id,
            author.id,
            ReportUserRequest {
                reason: CommentReportReason::Spam,
                detail: None,
                origin_scope: origin_e.clone(),
            },
        )
        .await
        .unwrap();
    assert!(user_report_replay.replayed);
    assert_eq!(user_report_replay.report, user_report.report);
    assert!(matches!(
        service
            .report_user(
                reporter.id,
                reporter.id,
                ReportUserRequest {
                    reason: CommentReportReason::Other,
                    detail: None,
                    origin_scope: origin_e.clone(),
                },
            )
            .await,
        Err(CommentServiceError::CannotReportSelf)
    ));
    let blocks_before_block: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM user_blocks WHERE blocker_user_id = $1 AND blocked_user_id = $2",
    )
    .bind(reporter.id.into_inner())
    .bind(author.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(blocks_before_block, 0);

    let blocked = service.block(reporter.id, author.id).await.unwrap();
    assert_eq!(blocked.blocked_user.user.id, author.id);
    assert!(
        !database
            .rate_limits()
            .check(
                &RateLimitRequest::comment_mutation(reporter.id, 1, Duration::from_secs(3_600),)
                    .unwrap(),
            )
            .await
            .unwrap()
            .allowed
    );
    assert_eq!(
        service
            .block(reporter.id, author.id)
            .await
            .unwrap()
            .blocked_user,
        blocked.blocked_user
    );

    sqlx::query(
        "DELETE FROM shared_rate_limit_buckets WHERE bucket = 'comment_mutation' AND scope_key = $1",
    )
    .bind(format!("user:{}", reporter.id))
    .execute(database.pool())
    .await
    .unwrap();
    let removed = service.unblock(reporter.id, author.id).await.unwrap();
    assert!(removed.existed);
    assert!(
        !database
            .rate_limits()
            .check(
                &RateLimitRequest::comment_mutation(reporter.id, 1, Duration::from_secs(3_600),)
                    .unwrap(),
            )
            .await
            .unwrap()
            .allowed
    );
    let remove_replay = service.unblock(reporter.id, author.id).await.unwrap();
    assert!(!remove_replay.existed);

    let deleted = service.delete(author.id, created.comment.id).await.unwrap();
    assert!(!deleted.replayed);
    assert!(
        !database
            .rate_limits()
            .check(
                &RateLimitRequest::comment_mutation(author.id, 1, Duration::from_secs(3_600),)
                    .unwrap(),
            )
            .await
            .unwrap()
            .allowed
    );
    let delete_replay = service.delete(author.id, created.comment.id).await.unwrap();
    assert!(delete_replay.replayed);
    assert_eq!(delete_replay.comment_id, deleted.comment_id);
    assert_eq!(delete_replay.version, deleted.version);

    sqlx::query(
        r"
        DELETE FROM comment_moderation_events
        WHERE comment_id IN (
            SELECT comments.id
            FROM paper_comments comments
            JOIN users ON users.id = comments.author_user_id
            WHERE users.oidc_issuer = $1
        )
        ",
    )
    .bind(&issuer)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(&issuer)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query(
        "DELETE FROM shared_rate_limit_buckets WHERE scope_key = $1 OR scope_key = $2 OR scope_key = $3 OR scope_key = $4",
    )
        .bind(format!("origin:{origin_a}"))
        .bind(format!("origin:{origin_b}"))
        .bind(format!("origin:{origin_c}"))
        .bind(format!("origin:{origin_e}"))
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn concurrent_retries_are_coordinated_before_limits_and_moderation() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped concurrent comment-service coverage");
        return;
    };
    let database = Database::connect(&database_url, 24).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://comment-concurrency.test/{unique}");
    let terms = TermsVersion::parse("2026-08-01").unwrap();
    let guidelines = CommunityGuidelinesVersion::parse("2026-08-01").unwrap();
    let author = provision_active_user(
        &database,
        &issuer,
        "author",
        "concurrent_author",
        &terms,
        &guidelines,
    )
    .await;
    let reporter = provision_active_user(
        &database,
        &issuer,
        "reporter",
        "concurrent_reporter",
        &terms,
        &guidelines,
    )
    .await;
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("comment-concurrency.{unique}")))
        .await
        .unwrap();

    let moderation_calls = Arc::new(AtomicUsize::new(0));
    let moderation_entered = Arc::new(Notify::new());
    let moderation_release = Arc::new(Notify::new());
    let config = CommentServiceConfig::new(terms, guidelines)
        .with_create_rate_limit(100, Duration::from_secs(3_600))
        .unwrap()
        .with_mutation_rate_limit(100, Duration::from_secs(3_600))
        .unwrap()
        .with_report_rate_limit(100, Duration::from_secs(3_600))
        .unwrap()
        .with_origin_rate_limit(100, Duration::from_secs(3_600))
        .unwrap();
    let service = Arc::new(CommentService::new(
        database.comments(),
        database.rate_limits(),
        Arc::new(GatedModerator {
            calls: Arc::clone(&moderation_calls),
            entered: Arc::clone(&moderation_entered),
            release: Arc::clone(&moderation_release),
        }),
        config,
    ));

    let request_id = Uuid::now_v7();
    let create_origin = "d".repeat(64);
    let first_service = Arc::clone(&service);
    let first_origin = create_origin.clone();
    let first_create = tokio::spawn(async move {
        first_service
            .create(
                author,
                paper.id,
                CreateCommentRequest {
                    client_request_id: request_id,
                    body: "One logical request across many replicas.".to_owned(),
                    origin_scope: first_origin,
                },
            )
            .await
    });
    timeout(Duration::from_secs(5), moderation_entered.notified())
        .await
        .expect("first create did not enter moderation");

    let create_barrier = Arc::new(Barrier::new(CONCURRENT_DUPLICATES + 1));
    let mut duplicate_creates = JoinSet::new();
    for _ in 0..CONCURRENT_DUPLICATES {
        let service = Arc::clone(&service);
        let barrier = Arc::clone(&create_barrier);
        let origin_scope = create_origin.clone();
        duplicate_creates.spawn(async move {
            barrier.wait().await;
            service
                .create(
                    author,
                    paper.id,
                    CreateCommentRequest {
                        client_request_id: request_id,
                        body: "One logical request across many replicas.".to_owned(),
                        origin_scope,
                    },
                )
                .await
        });
    }
    create_barrier.wait().await;
    // Give every duplicate enough time to contend while the canonical request
    // is deliberately stopped inside moderation. Without the outer database
    // coordinator they all reach moderation and spend independent permits.
    sleep(Duration::from_millis(150)).await;
    assert_eq!(moderation_calls.load(Ordering::SeqCst), 1);
    moderation_release.notify_waiters();

    let mut creates = vec![first_create.await.unwrap().unwrap()];
    while let Some(result) = duplicate_creates.join_next().await {
        creates.push(result.unwrap().unwrap());
    }
    assert_eq!(creates.len(), CONCURRENT_DUPLICATES + 1);
    assert_eq!(creates.iter().filter(|result| !result.replayed).count(), 1);
    let canonical_comment_id = creates[0].comment.id;
    assert!(
        creates
            .iter()
            .all(|result| result.comment.id == canonical_comment_id)
    );
    assert_eq!(
        bucket_count(&database, "comment_create", &format!("user:{author}"),).await,
        1
    );
    assert_eq!(
        bucket_count(
            &database,
            "comment_origin",
            &format!("origin:{create_origin}"),
        )
        .await,
        1
    );

    let report_origin = "e".repeat(64);
    let report_barrier = Arc::new(Barrier::new(CONCURRENT_DUPLICATES + 1));
    let mut reports = JoinSet::new();
    for _ in 0..CONCURRENT_DUPLICATES {
        let service = Arc::clone(&service);
        let barrier = Arc::clone(&report_barrier);
        let origin_scope = report_origin.clone();
        reports.spawn(async move {
            barrier.wait().await;
            service
                .report(
                    reporter,
                    canonical_comment_id,
                    ReportCommentRequest {
                        reason: CommentReportReason::Spam,
                        detail: None,
                        origin_scope,
                    },
                )
                .await
        });
    }
    report_barrier.wait().await;
    let mut report_results = Vec::new();
    while let Some(result) = reports.join_next().await {
        report_results.push(result.unwrap().unwrap());
    }
    assert_eq!(
        report_results
            .iter()
            .filter(|result| !result.replayed)
            .count(),
        1
    );
    assert!(
        report_results
            .iter()
            .all(|result| result.report == report_results[0].report)
    );
    for (bucket, scope_key) in [
        ("comment_report", format!("user:{reporter}")),
        (
            "comment_report_target",
            format!("comment:{canonical_comment_id}"),
        ),
        ("comment_origin", format!("origin:{report_origin}")),
    ] {
        assert_eq!(bucket_count(&database, bucket, &scope_key).await, 1);
    }

    let user_report_origin = "f".repeat(64);
    let user_report_barrier = Arc::new(Barrier::new(CONCURRENT_DUPLICATES + 1));
    let mut user_reports = JoinSet::new();
    for _ in 0..CONCURRENT_DUPLICATES {
        let service = Arc::clone(&service);
        let barrier = Arc::clone(&user_report_barrier);
        let origin_scope = user_report_origin.clone();
        user_reports.spawn(async move {
            barrier.wait().await;
            service
                .report_user(
                    reporter,
                    author,
                    ReportUserRequest {
                        reason: CommentReportReason::Impersonation,
                        detail: None,
                        origin_scope,
                    },
                )
                .await
        });
    }
    user_report_barrier.wait().await;
    let mut user_report_results = Vec::new();
    while let Some(result) = user_reports.join_next().await {
        user_report_results.push(result.unwrap().unwrap());
    }
    assert_eq!(
        user_report_results
            .iter()
            .filter(|result| !result.replayed)
            .count(),
        1
    );
    assert!(
        user_report_results
            .iter()
            .all(|result| result.report == user_report_results[0].report)
    );
    for (bucket, scope_key) in [
        ("user_report", format!("user:{reporter}")),
        ("user_report_target", format!("user:{author}")),
        ("comment_origin", format!("origin:{user_report_origin}")),
    ] {
        assert_eq!(bucket_count(&database, bucket, &scope_key).await, 1);
    }

    let block_barrier = Arc::new(Barrier::new(CONCURRENT_DUPLICATES + 1));
    let mut blocks = JoinSet::new();
    for _ in 0..CONCURRENT_DUPLICATES {
        let service = Arc::clone(&service);
        let barrier = Arc::clone(&block_barrier);
        blocks.spawn(async move {
            barrier.wait().await;
            service.block(reporter, author).await
        });
    }
    block_barrier.wait().await;
    let mut block_results = Vec::new();
    while let Some(result) = blocks.join_next().await {
        block_results.push(result.unwrap().unwrap());
    }
    assert!(block_results.iter().all(|result| {
        result.blocked_user == block_results[0].blocked_user
            && result.blocked_user.user.id == author
    }));
    assert_eq!(
        bucket_count(&database, "comment_mutation", &format!("user:{reporter}"),).await,
        1
    );

    sqlx::query(
        "DELETE FROM shared_rate_limit_buckets WHERE bucket = 'comment_mutation' AND scope_key = $1",
    )
    .bind(format!("user:{reporter}"))
    .execute(database.pool())
    .await
    .unwrap();
    let unblock_barrier = Arc::new(Barrier::new(CONCURRENT_DUPLICATES + 1));
    let mut unblocks = JoinSet::new();
    for _ in 0..CONCURRENT_DUPLICATES {
        let service = Arc::clone(&service);
        let barrier = Arc::clone(&unblock_barrier);
        unblocks.spawn(async move {
            barrier.wait().await;
            service.unblock(reporter, author).await
        });
    }
    unblock_barrier.wait().await;
    let mut unblock_results = Vec::new();
    while let Some(result) = unblocks.join_next().await {
        unblock_results.push(result.unwrap().unwrap());
    }
    assert_eq!(
        unblock_results
            .iter()
            .filter(|result| result.existed)
            .count(),
        1
    );
    assert_eq!(
        bucket_count(&database, "comment_mutation", &format!("user:{reporter}"),).await,
        1
    );

    let delete_barrier = Arc::new(Barrier::new(CONCURRENT_DUPLICATES + 1));
    let mut deletes = JoinSet::new();
    for _ in 0..CONCURRENT_DUPLICATES {
        let service = Arc::clone(&service);
        let barrier = Arc::clone(&delete_barrier);
        deletes.spawn(async move {
            barrier.wait().await;
            service.delete(author, canonical_comment_id).await
        });
    }
    delete_barrier.wait().await;
    let mut delete_results = Vec::new();
    while let Some(result) = deletes.join_next().await {
        delete_results.push(result.unwrap().unwrap());
    }
    assert_eq!(
        delete_results
            .iter()
            .filter(|result| !result.replayed)
            .count(),
        1
    );
    assert!(delete_results.iter().all(|result| {
        result.comment_id == canonical_comment_id && result.version == delete_results[0].version
    }));
    assert_eq!(
        bucket_count(&database, "comment_mutation", &format!("user:{author}"),).await,
        1
    );

    sqlx::query(
        r"
        DELETE FROM comment_moderation_events
        WHERE comment_id IN (
            SELECT comments.id
            FROM paper_comments comments
            JOIN users ON users.id = comments.author_user_id
            WHERE users.oidc_issuer = $1
        )
        ",
    )
    .bind(&issuer)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(&issuer)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query(
        r"
        DELETE FROM shared_rate_limit_buckets
        WHERE scope_key = $1
           OR scope_key = $2
           OR scope_key = $3
           OR scope_key = $4
           OR scope_key = $5
        ",
    )
    .bind(format!("user:{author}"))
    .bind(format!("user:{reporter}"))
    .bind(format!("origin:{create_origin}"))
    .bind(format!("origin:{report_origin}"))
    .bind(format!("origin:{user_report_origin}"))
    .execute(database.pool())
    .await
    .unwrap();
}

async fn provision_active_user(
    database: &Database,
    issuer: &str,
    subject: &str,
    handle: &str,
    terms: &TermsVersion,
    guidelines: &CommunityGuidelinesVersion,
) -> domain::AuthenticatedUserId {
    let user = database
        .accounts()
        .provision_oidc_identity(issuer, subject, Duration::from_secs(900))
        .await
        .unwrap();
    sqlx::query(
        r"
        UPDATE users
        SET handle = $2,
            terms_version = $3,
            terms_accepted_at = statement_timestamp(),
            community_guidelines_version = $4,
            community_guidelines_accepted_at = statement_timestamp(),
            updated_at = statement_timestamp()
        WHERE id = $1
        ",
    )
    .bind(user.id.into_inner())
    .bind(handle)
    .bind(terms.as_str())
    .bind(guidelines.as_str())
    .execute(database.pool())
    .await
    .unwrap();
    user.id
}

async fn bucket_count(database: &Database, bucket: &str, scope_key: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT request_count FROM shared_rate_limit_buckets WHERE bucket = $1 AND scope_key = $2",
    )
    .bind(bucket)
    .bind(scope_key)
    .fetch_one(database.pool())
    .await
    .unwrap()
}

struct CountingModerator(Arc<AtomicUsize>);

#[async_trait]
impl ContentModerator for CountingModerator {
    async fn evaluate(
        &self,
        _input: ModerationInput,
    ) -> Result<ModerationDecision, ModerationError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Ok(ModerationDecision::Publish)
    }
}

struct GatedModerator {
    calls: Arc<AtomicUsize>,
    entered: Arc<Notify>,
    release: Arc<Notify>,
}

#[async_trait]
impl ContentModerator for GatedModerator {
    async fn evaluate(
        &self,
        _input: ModerationInput,
    ) -> Result<ModerationDecision, ModerationError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.entered.notify_one();
        self.release.notified().await;
        Ok(ModerationDecision::Publish)
    }
}

fn metadata(base_id: &str) -> PaperMetadata {
    let published_at = Utc::now() - TimeDelta::days(1);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: "Comment service fixture".to_owned(),
        abstract_text: "A metadata-only comment service fixture.".to_owned(),
        authors: vec![Author::from("Grace Hopper".to_owned())],
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
