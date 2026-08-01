use std::time::Duration;

use chrono::{TimeDelta, Utc};
use db::{
    AdminCommentAction, AdminReportResolution, AdminUserStatusOutcome, CommentCreateOutcome,
    CommentCreateResolution, CommentMutationOutcome, CommentReadOutcome, CommentReportOutcome,
    Database, StoredAdminActor, UserBlockOutcome, UserReportOutcome,
};
use domain::{
    AccountStatus, ArxivIdentifier, Author, CommentBody, CommentReportReason, CommentStatus,
    CommunityGuidelinesVersion, PaperMetadata, TermsVersion,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_comments_idempotency_permissions_pagination_and_moderation() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL comment coverage");
        return;
    };
    let database = Database::connect(&database_url, 16).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://comments.test/{unique}");
    let accounts = database.accounts();
    let author = accounts
        .provision_oidc_identity(&issuer, "author", Duration::from_secs(900))
        .await
        .unwrap();
    let reader = accounts
        .provision_oidc_identity(&issuer, "reader", Duration::from_secs(900))
        .await
        .unwrap();
    let incomplete = accounts
        .provision_oidc_identity(&issuer, "incomplete", Duration::from_secs(900))
        .await
        .unwrap();
    let policy_pending = accounts
        .provision_oidc_identity(&issuer, "policy-pending", Duration::from_secs(900))
        .await
        .unwrap();
    let suspended = accounts
        .provision_oidc_identity(&issuer, "suspended", Duration::from_secs(900))
        .await
        .unwrap();
    let terms = TermsVersion::parse("2026-08-01").unwrap();
    let guidelines = CommunityGuidelinesVersion::parse("2026-08-01").unwrap();
    for (user_id, handle) in [(author.id, "comment_author"), (reader.id, "comment_reader")] {
        sqlx::query(
            r"
            UPDATE users
            SET handle = $2,
                terms_version = $3,
                terms_accepted_at = statement_timestamp(),
                community_guidelines_version = $4,
                community_guidelines_accepted_at = statement_timestamp(),
                profile_version = profile_version + 1,
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
        .bind("comment_policy_pending")
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("UPDATE users SET status = 'suspended' WHERE id = $1")
        .bind(suspended.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();

    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("comments.{unique}")))
        .await
        .unwrap();
    let jobs_before: i64 = sqlx::query_scalar("SELECT count(*) FROM jobs WHERE paper_id = $1")
        .bind(paper.id)
        .fetch_one(database.pool())
        .await
        .unwrap();
    let repository = database.comments();
    let body = CommentBody::parse("A useful observation about the ablation.").unwrap();
    let request_id = Uuid::now_v7();
    assert_eq!(
        repository
            .resolve_create(author.id, paper.id, request_id, &body)
            .await
            .unwrap(),
        CommentCreateResolution::Unknown
    );
    let first = match repository
        .create(
            Uuid::now_v7(),
            author.id,
            paper.id,
            request_id,
            &body,
            CommentStatus::Published,
            None,
            &terms,
            &guidelines,
        )
        .await
        .unwrap()
    {
        CommentCreateOutcome::Applied { comment, replayed } => {
            assert!(!replayed);
            comment
        }
        other => panic!("expected first comment, got {other:?}"),
    };
    assert!(matches!(
        repository
            .resolve_create(author.id, paper.id, request_id, &body)
            .await
            .unwrap(),
        CommentCreateResolution::Replay(ref comment) if comment.id == first.id
    ));
    assert_eq!(
        repository
            .resolve_create(
                author.id,
                paper.id,
                request_id,
                &CommentBody::parse("Different normalized intent.").unwrap(),
            )
            .await
            .unwrap(),
        CommentCreateResolution::IdempotencyConflict
    );
    assert_eq!(
        repository
            .create(
                Uuid::now_v7(),
                incomplete.id,
                paper.id,
                Uuid::now_v7(),
                &body,
                CommentStatus::Published,
                None,
                &terms,
                &guidelines,
            )
            .await
            .unwrap(),
        CommentCreateOutcome::AccountIncomplete
    );
    assert_eq!(
        repository
            .create(
                Uuid::now_v7(),
                policy_pending.id,
                paper.id,
                Uuid::now_v7(),
                &body,
                CommentStatus::Published,
                None,
                &terms,
                &guidelines,
            )
            .await
            .unwrap(),
        CommentCreateOutcome::TermsAcceptanceRequired
    );
    assert_eq!(
        repository
            .create(
                Uuid::now_v7(),
                suspended.id,
                paper.id,
                Uuid::now_v7(),
                &body,
                CommentStatus::Published,
                None,
                &terms,
                &guidelines,
            )
            .await
            .unwrap(),
        CommentCreateOutcome::Inactive(AccountStatus::Suspended)
    );

    let edited = match repository
        .edit(
            author.id,
            first.id,
            first.version,
            &CommentBody::parse("A corrected observation.").unwrap(),
            CommentStatus::Published,
            None,
        )
        .await
        .unwrap()
    {
        CommentMutationOutcome::Updated(comment) => comment,
        other => panic!("expected edit, got {other:?}"),
    };
    assert_eq!(edited.version, first.version + 1);
    assert_eq!(
        repository
            .edit(
                author.id,
                first.id,
                first.version,
                &body,
                CommentStatus::Published,
                None,
            )
            .await
            .unwrap(),
        CommentMutationOutcome::VersionConflict {
            current_version: edited.version,
        }
    );
    assert_eq!(
        repository
            .edit(
                reader.id,
                first.id,
                edited.version,
                &body,
                CommentStatus::Published,
                None,
            )
            .await
            .unwrap(),
        CommentMutationOutcome::NotAuthor
    );

    let report = match repository
        .report(reader.id, first.id, CommentReportReason::Other, None)
        .await
        .unwrap()
    {
        CommentReportOutcome::Accepted { report, replayed } => {
            assert!(!replayed);
            report
        }
        other => panic!("expected report, got {other:?}"),
    };
    assert!(matches!(
        repository
            .report(
                reader.id,
                first.id,
                CommentReportReason::Spam,
                None,
            )
            .await
            .unwrap(),
        CommentReportOutcome::Accepted { report: ref replay, replayed: true }
            if replay.id == report.id && replay.reason == CommentReportReason::Other
    ));

    let user_report = match repository
        .report_user(reader.id, author.id, CommentReportReason::Harassment, None)
        .await
        .unwrap()
    {
        UserReportOutcome::Accepted { report, replayed } => {
            assert!(!replayed);
            report
        }
        other => panic!("expected user report, got {other:?}"),
    };
    assert!(matches!(
        repository
            .report_user(reader.id, author.id, CommentReportReason::Spam, None)
            .await
            .unwrap(),
        UserReportOutcome::Accepted { report: ref replay, replayed: true }
            if replay.id == user_report.id
                && replay.reason == CommentReportReason::Harassment
    ));
    assert!(matches!(
        repository
            .report_user(reader.id, reader.id, CommentReportReason::Other, None)
            .await
            .unwrap(),
        UserReportOutcome::CannotReportSelf
    ));
    let blocks_before_block: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM user_blocks WHERE blocker_user_id = $1 AND blocked_user_id = $2",
    )
    .bind(reader.id.into_inner())
    .bind(author.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        blocks_before_block, 0,
        "a user report must not create a block"
    );

    let block = repository.block(reader.id, author.id).await.unwrap();
    assert!(matches!(
        block,
        UserBlockOutcome::Applied { ref blocked_user }
            if blocked_user.user.id == author.id
    ));
    let filtered = found_comments(
        repository
            .list_public(paper.id, Some(reader.id), None, 20)
            .await
            .unwrap(),
    );
    assert!(filtered.items.is_empty());
    let guest = found_comments(
        repository
            .list_public(paper.id, None, None, 20)
            .await
            .unwrap(),
    );
    assert_eq!(guest.items.len(), 1);
    assert!(matches!(
        repository.unblock(reader.id, author.id).await.unwrap(),
        UserBlockOutcome::Removed { existed: true }
    ));
    assert!(matches!(
        repository.unblock(reader.id, author.id).await.unwrap(),
        UserBlockOutcome::Removed { existed: false }
    ));

    let pending = match repository
        .create(
            Uuid::now_v7(),
            author.id,
            paper.id,
            Uuid::now_v7(),
            &CommentBody::parse("A second observation awaiting review.").unwrap(),
            CommentStatus::PendingReview,
            Some("deterministic_high_risk"),
            &terms,
            &guidelines,
        )
        .await
        .unwrap()
    {
        CommentCreateOutcome::Applied { comment, .. } => comment,
        other => panic!("expected pending comment, got {other:?}"),
    };
    assert_eq!(
        found_comments(
            repository
                .list_public(paper.id, None, None, 20)
                .await
                .unwrap(),
        )
        .items
        .len(),
        1
    );
    let own = found_comments(repository.list_own(author.id, None, 1).await.unwrap());
    assert_eq!(own.items.len(), 1);
    assert!(own.next_cursor.is_some());
    let own_second = found_comments(
        repository
            .list_own(author.id, own.next_cursor.as_deref(), 1)
            .await
            .unwrap(),
    );
    assert_eq!(own_second.items.len(), 1);
    assert_ne!(own.items[0].id, own_second.items[0].id);
    assert!(matches!(
        repository
            .list_own(author.id, Some("invalid"), 10)
            .await
            .unwrap(),
        CommentReadOutcome::InvalidCursor
    ));

    let moderation = database.moderation();
    let actor = StoredAdminActor::Label(format!("phase5-{unique}"));
    let queue = moderation.list_pending(None, 100).await.unwrap();
    assert!(queue.items.iter().any(|item| item.comment_id == pending.id));
    let inspection = moderation.inspect(pending.id).await.unwrap().unwrap();
    assert_eq!(
        inspection.body.as_str(),
        "A second observation awaiting review."
    );
    let restored = moderation
        .moderate_comment(
            pending.id,
            &actor,
            AdminCommentAction::Restore,
            "review_approved",
        )
        .await
        .unwrap();
    assert!(matches!(restored, db::AdminCommentOutcome::Updated(_)));
    let hidden = moderation
        .moderate_comment(
            pending.id,
            &actor,
            AdminCommentAction::Hide,
            "policy_violation",
        )
        .await
        .unwrap();
    assert!(matches!(hidden, db::AdminCommentOutcome::Updated(_)));
    let hidden_edit = match repository
        .edit(
            author.id,
            pending.id,
            moderation
                .inspect(pending.id)
                .await
                .unwrap()
                .unwrap()
                .version,
            &CommentBody::parse("Revised after moderator feedback.").unwrap(),
            CommentStatus::Published,
            None,
        )
        .await
        .unwrap()
    {
        CommentMutationOutcome::Updated(comment) => comment,
        other => panic!("expected hidden edit, got {other:?}"),
    };
    assert_eq!(hidden_edit.status, CommentStatus::PendingReview);

    let user_report_queue = moderation
        .list_user_reports("open", None, 100)
        .await
        .unwrap();
    assert!(
        user_report_queue
            .items
            .iter()
            .any(|item| item.report_id == user_report.id
                && item.reported_user_id == author.id
                && item.reporter_user_id == reader.id)
    );
    let user_report_inspection = moderation
        .inspect_user_report(user_report.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(user_report_inspection.reported_user_id, author.id);
    assert_eq!(user_report_inspection.reporter_user_id, reader.id);
    let resolved_user_report = moderation
        .resolve_user_report(
            user_report.id,
            &actor,
            AdminReportResolution::Reviewed,
            "review_complete",
        )
        .await
        .unwrap();
    assert!(matches!(
        resolved_user_report,
        db::AdminReportOutcome::Updated { .. }
    ));

    let resolved = moderation
        .resolve_report(
            report.id,
            &actor,
            AdminReportResolution::Dismissed,
            "review_complete",
        )
        .await
        .unwrap();
    assert!(matches!(resolved, db::AdminReportOutcome::Updated { .. }));
    assert!(moderation.report_age_metrics().await.unwrap().open_count >= 0);
    assert_eq!(
        moderation
            .set_user_suspended(incomplete.id, &actor, true, "repeat_offender")
            .await
            .unwrap(),
        AdminUserStatusOutcome::Updated(AccountStatus::Suspended)
    );
    assert_eq!(
        moderation
            .set_user_suspended(incomplete.id, &actor, false, "appeal_approved")
            .await
            .unwrap(),
        AdminUserStatusOutcome::Updated(AccountStatus::Active)
    );
    let audit_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM comment_moderation_events WHERE actor_label = $1")
            .bind(format!("phase5-{unique}"))
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert!(audit_count >= 6);

    let deleted = match repository.delete(author.id, first.id).await.unwrap() {
        CommentMutationOutcome::Deleted { comment, replayed } => {
            assert!(!replayed);
            comment
        }
        other => panic!("expected delete, got {other:?}"),
    };
    assert_eq!(deleted.status, CommentStatus::Deleted);
    assert!(matches!(
        repository.delete(author.id, first.id).await.unwrap(),
        CommentMutationOutcome::Deleted { replayed: true, .. }
    ));
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM jobs WHERE paper_id = $1")
            .bind(paper.id)
            .fetch_one(database.pool())
            .await
            .unwrap(),
        jobs_before,
        "comment operations must not prepare papers"
    );

    let index_definitions: String = sqlx::query_scalar::<_, String>(
        r"
        SELECT string_agg(indexname, ',')
        FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename IN ('paper_comments', 'comment_reports', 'user_reports', 'user_blocks')
        ",
    )
    .fetch_one(database.pool())
    .await
    .unwrap();
    for required in [
        "paper_comments_public_page_idx",
        "paper_comments_author_page_idx",
        "comment_reports_status_age_idx",
        "user_reports_status_age_idx",
        "user_reports_reported_user_idx",
        "user_reports_reporter_user_idx",
        "user_reports_reviewed_by_idx",
    ] {
        assert!(
            index_definitions.contains(required),
            "missing index {required}"
        );
    }

    sqlx::query(
        r"
        DELETE FROM comment_moderation_events
        WHERE actor_label = $1
           OR comment_id IN (
                SELECT comments.id
                FROM paper_comments comments
                JOIN users ON users.id = comments.author_user_id
                WHERE users.oidc_issuer = $2
           )
           OR target_user_id IN (SELECT id FROM users WHERE oidc_issuer = $2)
        ",
    )
    .bind(format!("phase5-{unique}"))
    .bind(&issuer)
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(&issuer)
        .execute(database.pool())
        .await
        .unwrap();
}

fn found_comments(outcome: CommentReadOutcome<domain::CommentPage>) -> domain::CommentPage {
    match outcome {
        CommentReadOutcome::Found(page) => page,
        other => panic!("expected comment page, got {other:?}"),
    }
}

fn metadata(base_id: &str) -> PaperMetadata {
    let published_at = Utc::now() - TimeDelta::days(2);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: "Comment repository fixture".to_owned(),
        abstract_text: "A metadata-only comment fixture.".to_owned(),
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
