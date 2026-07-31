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
    EditCommentRequest, ReportCommentRequest,
};
use db::{Database, RateLimitRequest};
use domain::{
    ArxivIdentifier, Author, CommentReportReason, CommunityGuidelinesVersion, PaperMetadata,
    TermsVersion,
};
use moderation::{ContentModerator, ModerationDecision, ModerationError, ModerationInput};
use url::Url;
use uuid::Uuid;

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
        Err(CommentServiceError::ProfileIncomplete)
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
        "DELETE FROM shared_rate_limit_buckets WHERE scope_key = $1 OR scope_key = $2 OR scope_key = $3",
    )
        .bind(format!("origin:{origin_a}"))
        .bind(format!("origin:{origin_b}"))
        .bind(format!("origin:{origin_c}"))
        .execute(database.pool())
        .await
        .unwrap();
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
