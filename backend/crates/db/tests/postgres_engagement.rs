use std::{sync::Arc, time::Duration};

use chrono::{NaiveTime, TimeDelta, Utc};
use db::{Database, LibraryItemMutation, LibraryMutationIntent, LibraryMutationOutcome};
use domain::{
    ArxivIdentifier, AuthenticatedUserId, Author, LibraryState, PaperMetadata,
    RecommendationReasonCode,
};
use engagement::{
    BriefFingerprint, BriefItemWrite, BriefMode, BriefProgressCommand, BriefProgressFingerprint,
    BriefProgressOutcome, BriefStatus, BriefStoreOutcome, BriefWrite, EngagementPolicy,
    EngagementRetentionCutoffs, EngagementService, EngagementStore, NotificationEntityType,
    NotificationListOutcome, NotificationMutationOutcome, NotificationPreferences,
    NotificationScope, NotificationType, NotificationTypeFrequencies, NotificationWorkItem,
    NotificationWorkKind, PreferenceReadOutcome, PreferenceWriteOutcome, QueueDecisionApplyOutcome,
    SubscriptionFingerprint, SubscriptionFrequency, SubscriptionIntent, SubscriptionKind,
    SubscriptionListOutcome, SubscriptionMutationOutcome, SubscriptionWrite, WorkClaim,
    WorkRetryDisposition, WorkRunOutcome,
};
use reading_feed::{
    ChronologicalRecommendationSource, CursorCodecError, CursorKeyEpoch, FeedItemSource,
    ReadingFeedCursorClaims, ReadingFeedCursorCodec, ReadingFeedPolicy, ReadingFeedService,
    RecommendationMode,
};
use serde_json::json;
use url::Url;
use uuid::Uuid;

struct UnusedCursorCodec;

impl ReadingFeedCursorCodec for UnusedCursorCodec {
    fn active_key_epoch(&self) -> CursorKeyEpoch {
        CursorKeyEpoch::parse("A".repeat(CursorKeyEpoch::ENCODED_BYTES)).unwrap()
    }

    fn seal(&self, _claims: &ReadingFeedCursorClaims) -> Result<String, CursorCodecError> {
        Err(CursorCodecError::Unavailable)
    }

    fn open(
        &self,
        _expected_user_id: AuthenticatedUserId,
        _token: &str,
        _now: chrono::DateTime<Utc>,
    ) -> Result<ReadingFeedCursorClaims, CursorCodecError> {
        Err(CursorCodecError::Invalid)
    }
}

#[tokio::test]
async fn postgres_deferred_discovery_metrics_are_aggregate_and_budget_aware() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped deferred-notification telemetry coverage");
        return;
    };
    let database = Database::connect(&database_url, 4).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://deferred-telemetry.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let now = Utc::now();
    sqlx::query("INSERT INTO notification_preferences (user_id, daily_budget) VALUES ($1, 5)")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    for (index, age_hours, eligibility) in [
        (1_u8, 2_i64, "deferred_unknown"),
        (2_u8, 1_i64, "deferred_queue_nonempty"),
    ] {
        sqlx::query(
            r"
            INSERT INTO notifications (
                id, user_id, notification_type, notification_scope,
                entity_type, entity_id, payload, batch_key,
                delivery_eligibility, created_at, expires_at
            ) VALUES (
                $1, $2, 'discovery_match', 'discovery', 'paper', $3,
                '{}'::jsonb, $4, $5, $6, $6 + interval '30 days'
            )
            ",
        )
        .bind(Uuid::now_v7())
        .bind(account.id.into_inner())
        .bind(Uuid::now_v7())
        .bind(format!("deferred-telemetry-{unique}-{index}"))
        .bind(eligibility)
        .bind(now - TimeDelta::hours(age_hours))
        .execute(database.pool())
        .await
        .unwrap();
    }
    sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope,
            entity_type, payload, batch_key, delivery_eligibility,
            eligible_at, created_at, expires_at
        ) VALUES (
            $1, $2, 'sync_failure', 'queue_owned', 'sync', '{}'::jsonb,
            $3, 'eligible', $4, $4, $4 + interval '30 days'
        )
        ",
    )
    .bind(Uuid::now_v7())
    .bind(account.id.into_inner())
    .bind(format!("eligible-telemetry-{unique}"))
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();

    let metrics = database
        .engagement()
        .deferred_discovery_metrics(now)
        .await
        .unwrap();
    assert_eq!(metrics.items, 2);
    assert!(metrics.oldest_age_seconds.is_some_and(|age| age >= 7_199.0));
    assert_eq!(metrics.release_budget_remaining, 4);

    sqlx::query("UPDATE notification_preferences SET global_pause = TRUE WHERE user_id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let paused = database
        .engagement()
        .deferred_discovery_metrics(now)
        .await
        .unwrap();
    assert_eq!(paused.items, 2);
    assert_eq!(paused.release_budget_remaining, 0);

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_notification_frequency_projection_is_rollback_safe_and_closed() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL engagement coverage");
        return;
    };
    let database = Database::connect(&database_url, 4).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://frequency-compatibility.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();

    sqlx::query(
        r"
        INSERT INTO notification_preferences (
            user_id, discovery_frequency, active_updates_enabled
        ) VALUES ($1, 'weekly', TRUE)
        ",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let frequencies = sqlx::query_as::<_, (String, String, String, String, String, bool)>(
        r"
        SELECT discovery_frequency, discovery_match_frequency,
               discovery_digest_frequency, active_paper_version_frequency,
               sync_failure_frequency, active_updates_enabled
        FROM notification_preferences WHERE user_id = $1
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        frequencies,
        (
            "weekly".to_owned(),
            "off".to_owned(),
            "weekly".to_owned(),
            "immediate".to_owned(),
            "immediate".to_owned(),
            true,
        )
    );

    sqlx::query(
        r"
        UPDATE notification_preferences
        SET discovery_frequency = 'immediate', active_updates_enabled = FALSE
        WHERE user_id = $1
        ",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let legacy_projected = sqlx::query_as::<_, (String, String, String)>(
        r"
        SELECT discovery_match_frequency, discovery_digest_frequency,
               active_paper_version_frequency
        FROM notification_preferences WHERE user_id = $1
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        legacy_projected,
        ("immediate".to_owned(), "off".to_owned(), "off".to_owned())
    );

    sqlx::query(
        r"
        UPDATE notification_preferences
        SET discovery_match_frequency = 'off',
            discovery_digest_frequency = 'weekly',
            active_paper_version_frequency = 'daily',
            sync_failure_frequency = 'off'
        WHERE user_id = $1
        ",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let canonical_projected = sqlx::query_as::<_, (String, bool, String)>(
        r"
        SELECT discovery_frequency, active_updates_enabled, sync_failure_frequency
        FROM notification_preferences WHERE user_id = $1
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        canonical_projected,
        ("weekly".to_owned(), true, "off".to_owned())
    );
    sqlx::query(
        "UPDATE notification_preferences SET discovery_frequency = 'daily' WHERE user_id = $1",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let preserved_sync: String = sqlx::query_scalar(
        "SELECT sync_failure_frequency FROM notification_preferences WHERE user_id = $1",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(preserved_sync, "off");
    assert!(matches!(
        database.engagement().preferences(account.id).await.unwrap(),
        PreferenceReadOutcome::Found(preferences)
            if preferences.type_frequencies == (NotificationTypeFrequencies {
                discovery_match: SubscriptionFrequency::Off,
                discovery_digest: SubscriptionFrequency::Daily,
                user_selected_reminder: SubscriptionFrequency::Immediate,
                active_paper_version: SubscriptionFrequency::Daily,
                sync_failure: SubscriptionFrequency::Off,
            })
                && preferences.discovery_frequency == SubscriptionFrequency::Daily
                && preferences.active_updates_enabled
    ));

    for statement in [
        r"
        UPDATE notification_preferences
        SET discovery_frequency = 'weekly',
            discovery_match_frequency = 'immediate',
            discovery_digest_frequency = 'off'
        WHERE user_id = $1
        ",
        r"
        UPDATE notification_preferences
        SET discovery_match_frequency = 'immediate',
            discovery_digest_frequency = 'daily'
        WHERE user_id = $1
        ",
        r"
        UPDATE notification_preferences
        SET sync_failure_frequency = 'sometimes'
        WHERE user_id = $1
        ",
    ] {
        let error = sqlx::query(statement)
            .bind(account.id.into_inner())
            .execute(database.pool())
            .await
            .unwrap_err();
        assert!(check_violation(&error));
    }
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_notification_work_scheduling_uses_canonical_type_frequencies() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL engagement coverage");
        return;
    };
    let database = Database::connect(&database_url, 4).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://frequency-scheduling.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let repository = database.engagement();
    let subscription = SubscriptionWrite {
        id: Uuid::now_v7(),
        kind: SubscriptionKind::Category,
        key: "cs.ai".to_owned(),
        label: "Artificial Intelligence".to_owned(),
        query_definition: None,
        frequency: SubscriptionFrequency::Immediate,
    };
    assert!(matches!(
        repository
            .mutate_subscription(
                account.id,
                Uuid::now_v7(),
                SubscriptionIntent::Create,
                &SubscriptionFingerprint([0xa1; 32]),
                &subscription,
            )
            .await
            .unwrap(),
        SubscriptionMutationOutcome::Applied(_)
    ));
    let now = Utc::now();
    let active_only = NotificationTypeFrequencies {
        discovery_match: SubscriptionFrequency::Off,
        discovery_digest: SubscriptionFrequency::Off,
        user_selected_reminder: SubscriptionFrequency::Immediate,
        active_paper_version: SubscriptionFrequency::Daily,
        sync_failure: SubscriptionFrequency::Immediate,
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0xa2; 32]),
                &NotificationPreferences {
                    discovery_frequency: SubscriptionFrequency::Off,
                    type_frequencies: active_only,
                    quiet_hours_start: None,
                    quiet_hours_end: None,
                    timezone: "UTC".to_owned(),
                    in_app_enabled: true,
                    push_enabled: false,
                    email_enabled: false,
                    global_pause: false,
                    active_updates_enabled: true,
                    daily_budget: 5,
                    revision: 0,
                    updated_at: now,
                },
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    let first = repository.schedule_due_work(now, 100).await.unwrap();
    assert_eq!(first.subscriptions, 0);
    assert_eq!(first.active_updates, 1);
    sqlx::query(
        r"
        UPDATE notification_work_items
        SET state = 'complete', completed_at = $2, updated_at = $2
        WHERE user_id = $1 AND work_kind = 'evaluate_active_papers'
        ",
    )
    .bind(account.id.into_inner())
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        repository
            .schedule_due_work(now + TimeDelta::hours(1), 100)
            .await
            .unwrap()
            .active_updates,
        0,
        "daily active-paper work must not be rescheduled hourly"
    );

    let digest_enabled = NotificationTypeFrequencies {
        discovery_digest: SubscriptionFrequency::Daily,
        ..active_only
    };
    let current_preferences = match repository.preferences(account.id).await.unwrap() {
        PreferenceReadOutcome::Found(preferences) => preferences,
        other => panic!("expected persisted preferences, got {other:?}"),
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0xa3; 32]),
                &NotificationPreferences {
                    discovery_frequency: SubscriptionFrequency::Daily,
                    type_frequencies: digest_enabled,
                    active_updates_enabled: true,
                    ..current_preferences
                },
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    let digest_schedule = repository
        .schedule_due_work(now + TimeDelta::hours(1), 100)
        .await
        .unwrap();
    assert_eq!(digest_schedule.subscriptions, 1);
    assert_eq!(digest_schedule.active_updates, 0);
    assert_eq!(
        repository
            .schedule_due_work(now + TimeDelta::days(1) + TimeDelta::seconds(1), 100)
            .await
            .unwrap()
            .active_updates,
        1
    );
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_due_reminders_are_queue_owned_private_idempotent_and_dismiss_only() {
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
            &format!("https://reminder-worker.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let paper_id = database
        .papers()
        .upsert_metadata(&metadata(&unique, 91))
        .await
        .unwrap()
        .id;
    let due_at = Utc::now() - TimeDelta::minutes(2);
    assert!(matches!(
        database
            .library()
            .mutate_item(
                account.id,
                paper_id,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryItemMutation::replace_with_reminder(
                    LibraryState::Inbox,
                    Some("private: never copy this".to_owned()),
                    None,
                    Some(Some(due_at)),
                ),
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    let repository = database.engagement();
    let now = Utc::now();
    assert_eq!(
        repository
            .schedule_due_work_with_reminders(now, 100, false)
            .await
            .unwrap()
            .reminders,
        0,
        "a notification-feature rollback must leave reminder work dormant"
    );
    assert_eq!(
        repository
            .schedule_due_work(now, 100)
            .await
            .unwrap()
            .reminders,
        1
    );
    let leased_before_rollback = repository
        .claim_work(&WorkClaim {
            worker_id: "pre-rollback-reminder-worker".to_owned(),
            now,
            lease_seconds: 1,
        })
        .await
        .unwrap()
        .item
        .expect("scheduled reminder work must be claimable");
    assert_eq!(
        leased_before_rollback.kind,
        NotificationWorkKind::EvaluateReminders
    );
    let reading_feed = ReadingFeedService::with_dependencies(
        Arc::new(database.reading_feed()),
        Arc::new(ChronologicalRecommendationSource),
        Arc::new(UnusedCursorCodec),
        ReadingFeedPolicy::new(20, 50, Duration::from_secs(86_400)).unwrap(),
    );
    let service = EngagementService::new(
        Arc::new(repository.clone()),
        reading_feed,
        EngagementPolicy::default(),
    );
    let rollback_run = service
        .run_work_once_with_reminders(
            "post-rollback-reminder-worker",
            now + TimeDelta::seconds(2),
            false,
        )
        .await
        .unwrap();
    assert_eq!(
        rollback_run.outcome,
        WorkRunOutcome::Completed(NotificationWorkKind::EvaluateReminders)
    );
    let notification_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM notifications WHERE user_id = $1 AND notification_type = 'user_selected_reminder'",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        notification_count, 0,
        "expired leased work must retire without delivery during rollback"
    );
    let work = NotificationWorkItem {
        id: Uuid::now_v7(),
        user_id: account.id,
        kind: NotificationWorkKind::EvaluateReminders,
        subscription_id: None,
        window_key: "reminder-test".to_owned(),
        attempt: 1,
        max_attempts: 5,
    };
    assert_eq!(repository.evaluate_reminders(&work, now).await.unwrap(), 1);
    assert_eq!(repository.evaluate_reminders(&work, now).await.unwrap(), 0);

    let notification = match repository.notifications(account.id, 20).await.unwrap() {
        NotificationListOutcome::Found(items) => items
            .into_iter()
            .find(|item| item.notification_type == NotificationType::UserSelectedReminder)
            .expect("due reminder must be visible"),
        other => panic!("expected notifications, got {other:?}"),
    };
    assert_eq!(notification.scope, NotificationScope::QueueOwned);
    assert_eq!(notification.entity_type, NotificationEntityType::Paper);
    assert_eq!(notification.entity_id, Some(paper_id));
    assert_eq!(
        notification
            .payload
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["reminder_at_epoch_ms"]
    );
    assert!(!notification.payload.to_string().contains("private"));
    database
        .library()
        .mutate_item(
            account.id,
            paper_id,
            Uuid::now_v7(),
            LibraryMutationIntent::Save,
            LibraryItemMutation::replace_with_reminder(
                LibraryState::Inbox,
                Some("private: never copy this".to_owned()),
                None,
                Some(None),
            ),
        )
        .await
        .unwrap();
    assert!(matches!(
        repository.notifications(account.id, 20).await.unwrap(),
        NotificationListOutcome::Found(items)
            if items.iter().all(|item| item.id != notification.id)
    ));
    let before: (String, chrono::DateTime<Utc>, i64) = sqlx::query_as(
        "SELECT state, updated_at, revision FROM user_paper_library WHERE user_id = $1 AND paper_id = $2",
    )
    .bind(account.id.into_inner())
    .bind(paper_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert!(matches!(
        repository
            .dismiss_notification(account.id, notification.id, now)
            .await
            .unwrap(),
        NotificationMutationOutcome::Applied { affected: 1 }
    ));
    let after: (String, chrono::DateTime<Utc>, i64) = sqlx::query_as(
        "SELECT state, updated_at, revision FROM user_paper_library WHERE user_id = $1 AND paper_id = $2",
    )
    .bind(account.id.into_inner())
    .bind(paper_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(after, before, "dismissal must never mutate queue authority");

    sqlx::query(
        "UPDATE notification_preferences SET user_selected_reminder_frequency = 'off' WHERE user_id = $1",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let second_paper = database
        .papers()
        .upsert_metadata(&metadata(&unique, 92))
        .await
        .unwrap()
        .id;
    database
        .library()
        .mutate_item(
            account.id,
            second_paper,
            Uuid::now_v7(),
            LibraryMutationIntent::Save,
            LibraryItemMutation::replace_with_reminder(
                LibraryState::Inbox,
                None,
                None,
                Some(Some(due_at)),
            ),
        )
        .await
        .unwrap();
    assert_eq!(repository.evaluate_reminders(&work, now).await.unwrap(), 0);

    let stale_due_at = now - TimeDelta::hours(25);
    database
        .library()
        .mutate_item(
            account.id,
            second_paper,
            Uuid::now_v7(),
            LibraryMutationIntent::Save,
            LibraryItemMutation::replace_with_reminder(
                LibraryState::Inbox,
                None,
                None,
                Some(Some(stale_due_at)),
            ),
        )
        .await
        .unwrap();
    sqlx::query(
        "UPDATE notification_preferences SET user_selected_reminder_frequency = 'immediate' WHERE user_id = $1",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    sqlx::query(
        "DELETE FROM notification_work_items WHERE user_id = $1 AND work_kind = 'evaluate_reminders'",
    )
    .bind(account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        repository
            .schedule_due_work(now, 100)
            .await
            .unwrap()
            .reminders,
        0,
        "reminders more than 24 hours overdue must not resurrect after rollout"
    );
    assert_eq!(
        repository.evaluate_reminders(&work, now).await.unwrap(),
        0,
        "direct evaluation must enforce the same expiry window"
    );
    let stale_notification_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope, entity_type,
            entity_id, payload, batch_key, delivery_eligibility, eligible_at,
            expires_at
        ) VALUES (
            $1, $2, 'user_selected_reminder', 'queue_owned', 'paper', $3,
            '{}'::jsonb,
            concat('reminder-', floor(extract(epoch FROM $4::timestamptz) * 1000000)::bigint),
            'eligible', $5, $5 + interval '30 days'
        )
        ",
    )
    .bind(stale_notification_id)
    .bind(account.id.into_inner())
    .bind(second_paper)
    .bind(stale_due_at)
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    assert!(matches!(
        repository.notifications(account.id, 20).await.unwrap(),
        NotificationListOutcome::Found(items)
            if items.iter().all(|item| item.id != stale_notification_id)
    ));
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_engagement_is_idempotent_leased_and_account_owned() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL engagement coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://engagement.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let repository = database.engagement();
    let subscription_id = Uuid::now_v7();
    let operation_id = Uuid::now_v7();
    let write = SubscriptionWrite {
        id: subscription_id,
        kind: SubscriptionKind::Category,
        key: "cs.ai".to_owned(),
        label: "Artificial Intelligence".to_owned(),
        query_definition: None,
        frequency: SubscriptionFrequency::Daily,
    };
    let fingerprint = SubscriptionFingerprint([0x11; 32]);
    assert!(matches!(
        repository
            .mutate_subscription(
                account.id,
                operation_id,
                SubscriptionIntent::Create,
                &fingerprint,
                &write,
            )
            .await
            .unwrap(),
        SubscriptionMutationOutcome::Applied(_)
    ));
    assert!(matches!(
        repository
            .mutate_subscription(
                account.id,
                operation_id,
                SubscriptionIntent::Create,
                &fingerprint,
                &write,
            )
            .await
            .unwrap(),
        SubscriptionMutationOutcome::Replay(_)
    ));
    assert!(matches!(
        repository.subscriptions(account.id, 100).await.unwrap(),
        SubscriptionListOutcome::Found(items) if items.len() == 1
    ));

    let now = Utc::now();
    let preference_operation = Uuid::now_v7();
    let preference_fingerprint = SubscriptionFingerprint([0x22; 32]);
    let preferences = NotificationPreferences {
        discovery_frequency: SubscriptionFrequency::Daily,
        type_frequencies: NotificationTypeFrequencies::from_legacy(
            SubscriptionFrequency::Daily,
            false,
        ),
        quiet_hours_start: None,
        quiet_hours_end: None,
        timezone: "UTC".to_owned(),
        in_app_enabled: true,
        push_enabled: false,
        email_enabled: false,
        global_pause: false,
        active_updates_enabled: false,
        daily_budget: 5,
        revision: 0,
        updated_at: now,
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                preference_operation,
                &preference_fingerprint,
                &preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(value)
            if value.revision == 1 && !value.push_enabled && !value.email_enabled
    ));
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                preference_operation,
                &preference_fingerprint,
                &preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Replay(value) if value.revision == 1
    ));
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x23; 32]),
                &NotificationPreferences {
                    timezone: "Invalid/Private_Zone".to_owned(),
                    ..preferences.clone()
                },
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::InvalidTimezone
    ));

    let scheduled = repository.schedule_due_work(now, 100).await.unwrap();
    assert_eq!(scheduled.subscriptions, 1);
    assert_eq!(
        repository
            .schedule_due_work(now, 100)
            .await
            .unwrap()
            .subscriptions,
        0
    );
    let queued: i64 =
        sqlx::query_scalar("SELECT count(*) FROM notification_work_items WHERE user_id = $1")
            .bind(account.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(queued, 1);
    let work_now = Utc::now() + TimeDelta::seconds(1);
    let work = repository
        .claim_work(&WorkClaim {
            worker_id: "postgres-engagement-test".to_owned(),
            now: work_now,
            lease_seconds: 30,
        })
        .await
        .unwrap()
        .item
        .unwrap();
    assert_eq!(work.kind, NotificationWorkKind::EvaluateSubscriptions);
    repository
        .complete_work(work.id, "postgres-engagement-test", work_now)
        .await
        .unwrap();

    let notification_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope, entity_type,
            payload, delivery_eligibility, eligible_at
        ) VALUES ($1, $2, 'sync_failure', 'queue_owned', 'sync',
                  '{}'::jsonb, 'eligible', $3)
        ",
    )
    .bind(notification_id)
    .bind(account.id.into_inner())
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    assert!(matches!(
        repository.notifications(account.id, 20).await.unwrap(),
        NotificationListOutcome::Found(items)
            if items.len() == 1 && items[0].entity_type == NotificationEntityType::Sync
    ));
    let notification_mutation_at = Utc::now() + TimeDelta::seconds(1);
    assert_eq!(
        repository
            .mark_notification_read(account.id, notification_id, notification_mutation_at)
            .await
            .unwrap(),
        NotificationMutationOutcome::Applied { affected: 1 }
    );
    assert_eq!(
        repository
            .dismiss_notification(account.id, notification_id, notification_mutation_at)
            .await
            .unwrap(),
        NotificationMutationOutcome::Applied { affected: 1 }
    );
    assert!(matches!(
        repository.notifications(account.id, 20).await.unwrap(),
        NotificationListOutcome::Found(items) if items.is_empty()
    ));

    let papers = database.papers();
    let first_paper = papers
        .upsert_metadata(&metadata(&unique, 0))
        .await
        .unwrap()
        .id;
    let second_paper = papers
        .upsert_metadata(&metadata(&unique, 1))
        .await
        .unwrap()
        .id;
    let active_paper = papers
        .upsert_metadata(&metadata(&unique, 2))
        .await
        .unwrap()
        .id;
    let category_work = NotificationWorkItem {
        id: Uuid::now_v7(),
        user_id: account.id,
        kind: NotificationWorkKind::EvaluateSubscriptions,
        subscription_id: Some(subscription_id),
        window_key: "category-casing-acceptance".to_owned(),
        attempt: 1,
        max_attempts: 8,
    };
    assert_eq!(
        repository
            .evaluate_subscription(&category_work, now)
            .await
            .unwrap(),
        3,
        "normalized cs.ai subscriptions must match canonical cs.AI metadata"
    );
    let off_write = SubscriptionWrite {
        frequency: SubscriptionFrequency::Off,
        ..write.clone()
    };
    assert!(matches!(
        repository
            .mutate_subscription(
                account.id,
                Uuid::now_v7(),
                SubscriptionIntent::Update,
                &SubscriptionFingerprint([0x28; 32]),
                &off_write,
            )
            .await
            .unwrap(),
        SubscriptionMutationOutcome::Applied(subscription)
            if subscription.frequency == SubscriptionFrequency::Off
    ));
    let invalidated_matches: i64 = sqlx::query_scalar(
        r"
        SELECT count(*) FROM notifications
        WHERE user_id = $1
          AND payload ->> 'subscription_id' = $2::uuid::text
          AND delivery_eligibility = 'expired'
          AND dismissed_at IS NOT NULL
        ",
    )
    .bind(account.id.into_inner())
    .bind(subscription_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        invalidated_matches, 3,
        "turning a subscription off must transactionally withdraw its pending matches"
    );
    sqlx::query("DELETE FROM notifications WHERE user_id = $1 AND batch_key = 'subscription-1'")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    for (paper_id, batch_key) in [
        (first_paper, "candidate-first"),
        (second_paper, "candidate-second"),
    ] {
        sqlx::query(
            r"
            INSERT INTO notifications (
                id, user_id, notification_type, notification_scope, entity_type,
                entity_id, payload, batch_key, delivery_eligibility, expires_at
            ) VALUES (
                $1, $2, 'discovery_match', 'discovery', 'paper', $3,
                '{}'::jsonb, $4, 'deferred_unknown', $5 + interval '30 days'
            )
            ",
        )
        .bind(Uuid::now_v7())
        .bind(account.id.into_inner())
        .bind(paper_id)
        .bind(batch_key)
        .bind(now)
        .execute(database.pool())
        .await
        .unwrap();
    }
    let decision_now = Utc::now() + TimeDelta::seconds(1);

    let midnight = NaiveTime::from_hms_opt(0, 0, 0).unwrap();
    let quiet_preferences = NotificationPreferences {
        discovery_frequency: SubscriptionFrequency::Immediate,
        type_frequencies: NotificationTypeFrequencies::from_legacy(
            SubscriptionFrequency::Immediate,
            false,
        ),
        quiet_hours_start: Some(midnight),
        quiet_hours_end: Some(midnight),
        daily_budget: 5,
        ..preferences.clone()
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x24; 32]),
                &quiet_preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    assert_eq!(
        repository
            .apply_queue_decision(account.id, 0, true, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    assert_eq!(
        discovery_eligibility_count(&database, account.id, "deferred_unknown").await,
        2,
        "all-day quiet hours must fail closed"
    );

    let exhausted_preferences = NotificationPreferences {
        discovery_frequency: SubscriptionFrequency::Immediate,
        type_frequencies: NotificationTypeFrequencies::from_legacy(
            SubscriptionFrequency::Immediate,
            false,
        ),
        quiet_hours_start: None,
        quiet_hours_end: None,
        daily_budget: 1,
        ..preferences.clone()
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x25; 32]),
                &exhausted_preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    assert_eq!(
        repository
            .apply_queue_decision(account.id, 0, true, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    assert_eq!(
        discovery_eligibility_count(&database, account.id, "deferred_unknown").await,
        2,
        "the dismissed eligible notification still consumes today's budget"
    );

    let library = database.library();
    assert!(matches!(
        library
            .mutate(
                account.id,
                active_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    let nonempty_revision = library_revision(&database, account.id).await;
    assert_eq!(
        repository
            .apply_queue_decision(account.id, nonempty_revision, false, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    assert_eq!(
        discovery_eligibility_count(&database, account.id, "deferred_queue_nonempty").await,
        2,
        "a nonempty queue must keep all discovery notifications deferred"
    );
    assert!(matches!(
        library
            .mutate(
                account.id,
                active_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    let empty_revision = library_revision(&database, account.id).await;
    let digest_preferences = NotificationPreferences {
        discovery_frequency: SubscriptionFrequency::Daily,
        type_frequencies: NotificationTypeFrequencies::from_legacy(
            SubscriptionFrequency::Daily,
            false,
        ),
        quiet_hours_start: None,
        quiet_hours_end: None,
        daily_budget: 5,
        ..preferences.clone()
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x26; 32]),
                &digest_preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    assert_eq!(
        repository
            .apply_queue_decision(account.id, empty_revision, true, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: true
        }
    );
    assert_eq!(
        repository
            .build_digest(account.id, empty_revision, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    let digest_items: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM notification_digest_items AS item
        JOIN notifications AS notification ON notification.id = item.notification_id
        WHERE notification.user_id = $1
          AND notification.notification_type = 'discovery_digest'
          AND notification.delivery_eligibility = 'eligible'
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        digest_items, 2,
        "proven-empty release must be bounded and complete"
    );
    let digest_id: Uuid = sqlx::query_scalar(
        r"
        SELECT id FROM notifications
        WHERE user_id = $1 AND notification_type = 'discovery_digest'
          AND delivery_eligibility = 'eligible'
        ORDER BY created_at, id
        LIMIT 1
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();

    assert!(matches!(
        library
            .mutate(
                account.id,
                active_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    let digest_hidden_revision = library_revision(&database, account.id).await;
    assert_eq!(
        repository
            .apply_queue_decision(account.id, digest_hidden_revision, false, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    let hidden_digest_eligibility: String =
        sqlx::query_scalar("SELECT delivery_eligibility FROM notifications WHERE id = $1")
            .bind(digest_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(hidden_digest_eligibility, "deferred_queue_nonempty");
    assert!(matches!(
        library
            .mutate(
                account.id,
                active_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    let digest_restore_revision = library_revision(&database, account.id).await;
    assert_eq!(
        repository
            .apply_queue_decision(account.id, digest_restore_revision, true, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        },
        "a daily digest must not be restored twice inside one cadence window"
    );
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x29; 32]),
                &NotificationPreferences {
                    discovery_frequency: SubscriptionFrequency::Immediate,
                    type_frequencies: NotificationTypeFrequencies::from_legacy(
                        SubscriptionFrequency::Immediate,
                        false,
                    ),
                    ..digest_preferences.clone()
                },
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    assert_eq!(
        repository
            .apply_queue_decision(account.id, digest_restore_revision, true, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        },
        "direct-match delivery must take precedence over a deferred digest"
    );
    assert_eq!(
        repository
            .build_digest(account.id, digest_restore_revision, decision_now)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    let still_deferred: String =
        sqlx::query_scalar("SELECT delivery_eligibility FROM notifications WHERE id = $1")
            .bind(digest_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(still_deferred, "deferred_queue_nonempty");

    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x2a; 32]),
                &digest_preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    let digest_restore_at = decision_now + TimeDelta::days(1) + TimeDelta::seconds(1);
    assert_eq!(
        repository
            .apply_queue_decision(account.id, digest_restore_revision, true, digest_restore_at)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: true
        },
        "a due digest path must restore one queue-deferred digest"
    );
    assert_eq!(
        repository
            .build_digest(account.id, digest_restore_revision, digest_restore_at)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    let (restored_id, restored_revision): (Uuid, Option<i64>) = sqlx::query_as(
        r"
        SELECT id, eligibility_library_revision
        FROM notifications
        WHERE user_id = $1 AND notification_type = 'discovery_digest'
          AND delivery_eligibility = 'eligible'
        ORDER BY created_at, id
        LIMIT 1
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(restored_id, digest_id);
    assert_eq!(restored_revision, Some(digest_restore_revision));
    let digest_count: i64 = sqlx::query_scalar(
        r"
        SELECT count(*) FROM notifications
        WHERE user_id = $1 AND notification_type = 'discovery_digest'
          AND delivery_eligibility = 'eligible'
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        digest_count, 1,
        "restoring a digest must not create a burst"
    );

    assert!(matches!(
        library
            .mutate(
                account.id,
                active_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    sqlx::query("UPDATE papers SET arxiv_version = 2, updated_at = $2 WHERE id = $1")
        .bind(active_paper)
        .bind(now + TimeDelta::hours(1))
        .execute(database.pool())
        .await
        .unwrap();
    let active_work = NotificationWorkItem {
        id: Uuid::now_v7(),
        user_id: account.id,
        kind: NotificationWorkKind::EvaluateActivePapers,
        subscription_id: None,
        window_key: "active-paper-acceptance".to_owned(),
        attempt: 1,
        max_attempts: 8,
    };
    assert_eq!(
        repository
            .evaluate_active_papers(&active_work, decision_now)
            .await
            .unwrap(),
        0,
        "active-paper updates must be opt-in"
    );
    let active_preferences = NotificationPreferences {
        active_updates_enabled: true,
        discovery_frequency: SubscriptionFrequency::Daily,
        type_frequencies: NotificationTypeFrequencies::from_legacy(
            SubscriptionFrequency::Daily,
            true,
        ),
        quiet_hours_start: None,
        quiet_hours_end: None,
        daily_budget: 5,
        ..preferences.clone()
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x27; 32]),
                &active_preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    let active_schedule_at = Utc::now();
    assert_eq!(
        repository
            .schedule_due_work(active_schedule_at, 100)
            .await
            .unwrap()
            .active_updates,
        1
    );
    assert_eq!(
        repository
            .schedule_due_work(active_schedule_at, 100)
            .await
            .unwrap()
            .active_updates,
        0,
        "an outstanding active-paper evaluation must deduplicate periodic scheduling"
    );
    let active_claim_at = Utc::now() + TimeDelta::seconds(1);
    let scheduled_active = repository
        .claim_work(&WorkClaim {
            worker_id: "postgres-active-paper-test".to_owned(),
            now: active_claim_at,
            lease_seconds: 30,
        })
        .await
        .unwrap()
        .item
        .unwrap();
    assert_eq!(
        scheduled_active.kind,
        NotificationWorkKind::EvaluateActivePapers
    );
    assert_eq!(
        repository
            .evaluate_active_papers(&scheduled_active, active_claim_at)
            .await
            .unwrap(),
        1,
        "opted-in active-paper version work must emit one deduplicated alert"
    );
    repository
        .complete_work(
            scheduled_active.id,
            "postgres-active-paper-test",
            active_claim_at,
        )
        .await
        .unwrap();
    let active_version_notifications: i64 = sqlx::query_scalar(
        r"
        SELECT count(*) FROM notifications
        WHERE user_id = $1 AND notification_type = 'active_paper_version'
          AND notification_scope = 'queue_owned'
          AND delivery_eligibility = 'eligible'
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(active_version_notifications, 1);
    assert!(
        matches!(
            repository.notifications(account.id, 100).await.unwrap(),
            NotificationListOutcome::Found(items)
                if !items.is_empty()
                    && items.iter().all(|item| item.scope == NotificationScope::QueueOwned)
        ),
        "a nonempty queue must suppress stale discovery notifications at read time"
    );

    let brief_id = Uuid::now_v7();
    let brief_library_revision = library_revision(&database, account.id).await;
    let library_rows_before_brief: i64 =
        sqlx::query_scalar("SELECT count(*) FROM user_paper_library WHERE user_id = $1")
            .bind(account.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    sqlx::query(
        r"
        INSERT INTO reading_briefs (
            id, user_id, operation_id, intent_fingerprint, source_mode,
            library_revision, local_date, item_count, status
        ) VALUES ($1, $2, $3, $4, 'queue', $5, $6, 20, 'current')
        ",
    )
    .bind(brief_id)
    .bind(account.id.into_inner())
    .bind(Uuid::now_v7())
    .bind([0x33_u8; 32].as_slice())
    .bind(brief_library_revision)
    .bind(now.date_naive())
    .execute(database.pool())
    .await
    .unwrap();
    let brief_progress_now = Utc::now() + TimeDelta::seconds(1);
    let progress_operation = Uuid::now_v7();
    let progress = BriefProgressCommand {
        user_id: account.id,
        operation_id: progress_operation,
        brief_id,
        expected_progress_revision: 1,
        position: 6,
        now: brief_progress_now,
    };
    let progress_fingerprint = BriefProgressFingerprint([0x44; 32]);
    assert!(matches!(
        repository
            .advance_brief(&progress, &progress_fingerprint)
            .await
            .unwrap(),
        BriefProgressOutcome::Applied(brief)
            if brief.position == 6
                && brief.progress_revision == 2
                && brief.status == BriefStatus::Current
    ));
    assert!(matches!(
        repository
            .advance_brief(&progress, &progress_fingerprint)
            .await
            .unwrap(),
        BriefProgressOutcome::Replay(brief) if brief.position == 6
    ));
    let completion = BriefProgressCommand {
        operation_id: Uuid::now_v7(),
        expected_progress_revision: 2,
        position: 20,
        ..progress
    };
    let completion_fingerprint = BriefProgressFingerprint([0x55; 32]);
    assert!(matches!(
        repository
            .advance_brief(&completion, &completion_fingerprint)
            .await
            .unwrap(),
        BriefProgressOutcome::Applied(brief)
            if brief.position == 20 && brief.status == BriefStatus::Complete
    ));
    assert!(matches!(
        repository
            .advance_brief(&completion, &completion_fingerprint)
            .await
            .unwrap(),
        BriefProgressOutcome::Replay(brief)
            if brief.position == 20 && brief.status == BriefStatus::Complete
    ));
    let library_rows: i64 =
        sqlx::query_scalar("SELECT count(*) FROM user_paper_library WHERE user_id = $1")
            .bind(account.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(
        library_rows, library_rows_before_brief,
        "brief completion must not mutate queue state"
    );

    assert!(matches!(
        library
            .mutate(
                account.id,
                active_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Reading,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    assert_eq!(
        repository
            .advance_brief(&completion, &completion_fingerprint)
            .await
            .unwrap(),
        BriefProgressOutcome::RevisionStale,
        "an idempotent progress retry must not replay a prior library authority"
    );

    let replay_operation = Uuid::now_v7();
    let replay_fingerprint = BriefFingerprint([0x66; 32]);
    let replay_write = BriefWrite {
        id: Uuid::now_v7(),
        mode: BriefMode::Queue,
        recommendation_mode: None,
        library_revision: library_revision(&database, account.id).await,
        recommendation_batch_id: None,
        local_date: now.date_naive(),
        items: vec![BriefItemWrite {
            ordinal: 0,
            paper_id: active_paper,
            source: FeedItemSource::ToRead,
            reason_codes: Vec::new(),
        }],
    };
    assert!(matches!(
        repository
            .store_brief(
                account.id,
                replay_operation,
                &replay_fingerprint,
                &replay_write,
            )
            .await
            .unwrap(),
        BriefStoreOutcome::Stored(_)
    ));
    assert!(matches!(
        repository
            .store_brief(
                account.id,
                replay_operation,
                &replay_fingerprint,
                &replay_write,
            )
            .await
            .unwrap(),
        BriefStoreOutcome::Replay(_)
    ));
    assert!(matches!(
        library
            .mutate(
                account.id,
                active_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::ReadNext,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    assert_eq!(
        repository
            .store_brief(
                account.id,
                replay_operation,
                &replay_fingerprint,
                &replay_write,
            )
            .await
            .unwrap(),
        BriefStoreOutcome::AuthorityStale,
        "an idempotent create retry must not replay a prior library authority"
    );

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    for table in [
        "reading_briefs",
        "reading_brief_progress_operations",
        "subscriptions",
        "subscription_operations",
        "notification_preferences",
        "notification_preference_operations",
        "notifications",
        "notification_work_items",
    ] {
        let statement = format!("SELECT count(*) FROM {table} WHERE user_id = $1");
        let count: i64 = sqlx::query_scalar(&statement)
            .bind(account.id.into_inner())
            .fetch_one(database.pool())
            .await
            .unwrap();
        assert_eq!(count, 0, "{table} did not cascade on account deletion");
    }
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_notification_work_rejects_stale_leases_and_terminalizes_crashed_final_attempts() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL notification lease coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://notification-lease.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let repository = database.engagement();
    let now = Utc::now();

    let exhausted_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notification_work_items (
            id, user_id, work_kind, window_key, state, attempts, max_attempts,
            available_at, lease_owner, lease_expires_at, created_at, updated_at
        ) VALUES (
            $1, $2, 'expire_notifications', 'crashed-final-attempt',
            'leased', 3, 3, $3, 'dead-worker', $3 - interval '1 second', $3, $3
        )
        ",
    )
    .bind(exhausted_id)
    .bind(account.id.into_inner())
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    let exhausted_claim = repository
        .claim_work(&WorkClaim {
            worker_id: "replacement-worker".to_owned(),
            now,
            lease_seconds: 5,
        })
        .await
        .unwrap();
    assert!(exhausted_claim.item.is_none());
    assert_eq!(
        exhausted_claim.lease_exhausted,
        vec![NotificationWorkKind::ExpireNotifications]
    );
    let exhausted: (String, Option<String>, bool) = sqlx::query_as(
        "SELECT state, last_error_code, completed_at IS NOT NULL FROM notification_work_items WHERE id = $1",
    )
    .bind(exhausted_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        exhausted,
        (
            "failed".to_owned(),
            Some("LEASE_EXHAUSTED".to_owned()),
            true
        )
    );

    let reclaimed_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notification_work_items (
            id, user_id, work_kind, window_key, state, attempts, max_attempts,
            available_at, created_at, updated_at
        ) VALUES (
            $1, $2, 'expire_notifications', 'reclaimed-owner',
            'queued', 0, 3, $3, $3, $3
        )
        ",
    )
    .bind(reclaimed_id)
    .bind(account.id.into_inner())
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    let first = repository
        .claim_work(&WorkClaim {
            worker_id: "first-worker".to_owned(),
            now,
            lease_seconds: 5,
        })
        .await
        .unwrap()
        .item
        .unwrap();
    assert_eq!(first.id, reclaimed_id);
    let reclaimed_at = now + TimeDelta::seconds(6);
    let second = repository
        .claim_work(&WorkClaim {
            worker_id: "second-worker".to_owned(),
            now: reclaimed_at,
            lease_seconds: 5,
        })
        .await
        .unwrap()
        .item
        .unwrap();
    assert_eq!(second.id, reclaimed_id);
    assert_eq!(second.attempt, 2);
    let stale_finished_at = reclaimed_at + TimeDelta::seconds(1);
    assert!(
        repository
            .complete_work(reclaimed_id, "first-worker", stale_finished_at)
            .await
            .is_err()
    );
    assert!(
        repository
            .retry_work(
                &first,
                "first-worker",
                "STORE_UNAVAILABLE",
                stale_finished_at,
            )
            .await
            .is_err()
    );
    repository
        .complete_work(reclaimed_id, "second-worker", stale_finished_at)
        .await
        .unwrap();
    let completed: (String, i32) =
        sqlx::query_as("SELECT state, attempts FROM notification_work_items WHERE id = $1")
            .bind(reclaimed_id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(completed, ("complete".to_owned(), 2));

    let queued_retry_id = Uuid::now_v7();
    let queued_retry_at = stale_finished_at + TimeDelta::seconds(1);
    sqlx::query(
        r"
        INSERT INTO notification_work_items (
            id, user_id, work_kind, window_key, state, attempts, max_attempts,
            available_at, created_at, updated_at
        ) VALUES (
            $1, $2, 'expire_notifications', 'queued-retry',
            'queued', 0, 3, $3, $3, $3
        )
        ",
    )
    .bind(queued_retry_id)
    .bind(account.id.into_inner())
    .bind(queued_retry_at)
    .execute(database.pool())
    .await
    .unwrap();
    let queued_retry = repository
        .claim_work(&WorkClaim {
            worker_id: "retry-worker".to_owned(),
            now: queued_retry_at,
            lease_seconds: 5,
        })
        .await
        .unwrap()
        .item
        .unwrap();
    assert_eq!(queued_retry.id, queued_retry_id);
    assert_eq!(queued_retry.attempt, 1);
    assert_eq!(
        repository
            .retry_work(
                &queued_retry,
                "retry-worker",
                "STORE_UNAVAILABLE",
                queued_retry_at + TimeDelta::seconds(1),
            )
            .await
            .unwrap(),
        WorkRetryDisposition::Queued
    );

    let terminal_retry_id = Uuid::now_v7();
    let terminal_retry_at = queued_retry_at + TimeDelta::seconds(2);
    sqlx::query(
        r"
        INSERT INTO notification_work_items (
            id, user_id, work_kind, window_key, state, attempts, max_attempts,
            available_at, created_at, updated_at
        ) VALUES (
            $1, $2, 'build_notification_digest', 'terminal-retry',
            'queued', 0, 1, $3, $3, $3
        )
        ",
    )
    .bind(terminal_retry_id)
    .bind(account.id.into_inner())
    .bind(terminal_retry_at)
    .execute(database.pool())
    .await
    .unwrap();
    let terminal_retry = repository
        .claim_work(&WorkClaim {
            worker_id: "terminal-worker".to_owned(),
            now: terminal_retry_at,
            lease_seconds: 5,
        })
        .await
        .unwrap()
        .item
        .unwrap();
    assert_eq!(terminal_retry.id, terminal_retry_id);
    assert_eq!(terminal_retry.attempt, 1);
    assert_eq!(
        repository
            .retry_work(
                &terminal_retry,
                "terminal-worker",
                "STORE_UNAVAILABLE",
                terminal_retry_at + TimeDelta::seconds(1),
            )
            .await
            .unwrap(),
        WorkRetryDisposition::Failed
    );
    let terminal_state: (String, bool) = sqlx::query_as(
        "SELECT state, completed_at IS NOT NULL FROM notification_work_items WHERE id = $1",
    )
    .bind(terminal_retry_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(terminal_state, ("failed".to_owned(), true));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
async fn postgres_engagement_rejects_unknown_reason_codes_and_notification_entities() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL closed engagement values");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://engagement-closed-values.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let paper_id = database
        .papers()
        .upsert_metadata(&metadata(&unique, 91))
        .await
        .unwrap()
        .id;
    let (_, _, brief) =
        store_discovery_brief(&database, account.id, &[paper_id], "closed-values").await;

    let reason_error = sqlx::query(
        "UPDATE reading_brief_items SET reason_codes = ARRAY['unknown']::text[] WHERE brief_id = $1",
    )
    .bind(brief.id)
    .execute(database.pool())
    .await
    .unwrap_err();
    assert!(check_violation(&reason_error));

    let entity_error = sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope, entity_type,
            payload, delivery_eligibility, eligible_at
        ) VALUES ($1, $2, 'sync_failure', 'queue_owned', 'unknown',
                  '{}'::jsonb, 'eligible', $3)
        ",
    )
    .bind(Uuid::now_v7())
    .bind(account.id.into_inner())
    .bind(Utc::now())
    .execute(database.pool())
    .await
    .unwrap_err();
    assert!(check_violation(&entity_error));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_engagement_retention_deletes_expired_rows_but_keeps_live_state() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL engagement retention coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    for index_name in [
        "reading_briefs_retention_idx",
        "notifications_retention_idx",
        "notification_work_terminal_retention_idx",
        "notification_work_pending_retention_idx",
        "reading_brief_progress_operations_retention_idx",
        "subscription_operations_retention_idx",
        "notification_preference_operations_retention_idx",
    ] {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1)",
        )
        .bind(index_name)
        .fetch_one(database.pool())
        .await
        .unwrap();
        assert!(exists, "missing bounded-retention index {index_name}");
    }
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://engagement-retention.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let paper_id = database
        .papers()
        .upsert_metadata(&metadata(&unique, 40))
        .await
        .unwrap()
        .id;
    let repository = database.engagement();
    let (_, _, brief) =
        store_discovery_brief(&database, account.id, &[paper_id], "retention").await;
    let progress_operation = Uuid::now_v7();
    assert!(matches!(
        repository
            .advance_brief(
                &BriefProgressCommand {
                    user_id: account.id,
                    operation_id: progress_operation,
                    brief_id: brief.id,
                    expected_progress_revision: 1,
                    position: 1,
                    now: Utc::now(),
                },
                &BriefProgressFingerprint([0x81; 32]),
            )
            .await
            .unwrap(),
        BriefProgressOutcome::Applied(_)
    ));

    let subscription_operation = Uuid::now_v7();
    assert!(matches!(
        repository
            .mutate_subscription(
                account.id,
                subscription_operation,
                SubscriptionIntent::Create,
                &SubscriptionFingerprint([0x82; 32]),
                &SubscriptionWrite {
                    id: Uuid::now_v7(),
                    kind: SubscriptionKind::Category,
                    key: "cs.ai".to_owned(),
                    label: "Artificial Intelligence".to_owned(),
                    query_definition: None,
                    frequency: SubscriptionFrequency::Daily,
                },
            )
            .await
            .unwrap(),
        SubscriptionMutationOutcome::Applied(_)
    ));
    let preference_operation = Uuid::now_v7();
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                preference_operation,
                &SubscriptionFingerprint([0x83; 32]),
                &NotificationPreferences {
                    discovery_frequency: SubscriptionFrequency::Daily,
                    type_frequencies: NotificationTypeFrequencies::from_legacy(
                        SubscriptionFrequency::Daily,
                        false,
                    ),
                    quiet_hours_start: None,
                    quiet_hours_end: None,
                    timezone: "UTC".to_owned(),
                    in_app_enabled: true,
                    push_enabled: false,
                    email_enabled: false,
                    global_pause: false,
                    active_updates_enabled: false,
                    daily_budget: 5,
                    revision: 0,
                    updated_at: Utc::now(),
                },
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));

    let old = Utc::now() - TimeDelta::days(45);
    sqlx::query("UPDATE reading_briefs SET created_at = $2 WHERE id = $1")
        .bind(brief.id)
        .bind(old)
        .execute(database.pool())
        .await
        .unwrap();
    for (table, operation_id) in [
        ("reading_brief_progress_operations", progress_operation),
        ("subscription_operations", subscription_operation),
        ("notification_preference_operations", preference_operation),
    ] {
        let statement =
            format!("UPDATE {table} SET created_at = $3 WHERE user_id = $1 AND operation_id = $2");
        sqlx::query(&statement)
            .bind(account.id.into_inner())
            .bind(operation_id)
            .bind(old)
            .execute(database.pool())
            .await
            .unwrap();
    }

    let old_notification = Uuid::now_v7();
    let live_notification = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope, entity_type,
            payload, batch_key, delivery_eligibility, eligible_at, created_at, expires_at
        ) VALUES
            ($1, $3, 'sync_failure', 'queue_owned', 'sync', '{}'::jsonb, 'retention-old',
             'eligible', $4, $4, $4 + interval '1 day'),
            ($2, $3, 'sync_failure', 'queue_owned', 'sync', '{}'::jsonb, 'retention-live',
             'eligible', $5, $5, $5 + interval '1 day')
        ",
    )
    .bind(old_notification)
    .bind(live_notification)
    .bind(account.id.into_inner())
    .bind(old)
    .bind(Utc::now())
    .execute(database.pool())
    .await
    .unwrap();
    let old_work = Uuid::now_v7();
    let old_queued_work = Uuid::now_v7();
    let old_expired_lease = Uuid::now_v7();
    let old_live_lease = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notification_work_items (
            id, user_id, work_kind, window_key, state, attempts, max_attempts,
            available_at, lease_owner, lease_expires_at,
            created_at, updated_at, completed_at
        ) VALUES (
            $1, $2, 'expire_notifications', 'retention-old', 'complete', 1, 8,
            $6, NULL, NULL, $6, $6, $6
        ), (
            $3, $2, 'expire_notifications', 'retention-old-queued', 'queued', 0, 8,
            $6, NULL, NULL, $6, $6, NULL
        ), (
            $4, $2, 'expire_notifications', 'retention-old-expired-lease', 'leased', 1, 8,
            $6, 'expired-worker', $6, $6, $6, NULL
        ), (
            $5, $2, 'expire_notifications', 'retention-old-live-lease', 'leased', 1, 8,
            $6, 'live-worker', statement_timestamp() + interval '1 day', $6, $6, NULL
        )
        ",
    )
    .bind(old_work)
    .bind(account.id.into_inner())
    .bind(old_queued_work)
    .bind(old_expired_lease)
    .bind(old_live_lease)
    .bind(old)
    .execute(database.pool())
    .await
    .unwrap();

    let now = Utc::now();
    let removed = repository
        .cleanup_retention(
            EngagementRetentionCutoffs {
                briefs_before: now - TimeDelta::days(35),
                notifications_before: now - TimeDelta::days(30),
                operations_before: now - TimeDelta::days(30),
                work_before: now - TimeDelta::days(30),
            },
            100,
        )
        .await
        .unwrap();
    assert_eq!(removed.briefs, 1);
    assert_eq!(removed.notifications, 1);
    assert_eq!(removed.operations, 3);
    assert_eq!(removed.work_items, 3);
    assert_eq!(removed.total(), 8);

    let remaining_notifications: Vec<Uuid> =
        sqlx::query_scalar("SELECT id FROM notifications WHERE user_id = $1 ORDER BY id")
            .bind(account.id.into_inner())
            .fetch_all(database.pool())
            .await
            .unwrap();
    assert_eq!(remaining_notifications, vec![live_notification]);
    assert!(matches!(
        repository.subscriptions(account.id, 100).await.unwrap(),
        SubscriptionListOutcome::Found(items) if items.len() == 1
    ));
    assert!(matches!(
        repository.preferences(account.id).await.unwrap(),
        engagement::PreferenceReadOutcome::Found(_)
    ));
    let remaining_work: Vec<Uuid> =
        sqlx::query_scalar("SELECT id FROM notification_work_items WHERE user_id = $1 ORDER BY id")
            .bind(account.id.into_inner())
            .fetch_all(database.pool())
            .await
            .unwrap();
    assert_eq!(remaining_work, vec![old_live_lease]);

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_engagement_revalidates_brief_and_notification_authority_after_waiting() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL engagement authority races");
        return;
    };
    let database = Database::connect(&database_url, 12).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let accounts = database.accounts();
    let replay_account = accounts
        .provision_oidc_identity(
            &format!("https://engagement-authority.test/{unique}"),
            "replay",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let brief_race_account = accounts
        .provision_oidc_identity(
            &format!("https://engagement-authority.test/{unique}"),
            "brief-race",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let notification_race_account = accounts
        .provision_oidc_identity(
            &format!("https://engagement-authority.test/{unique}"),
            "notification-race",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let papers = database.papers();
    let mut paper_ids = Vec::new();
    for index in 10..13 {
        paper_ids.push(
            papers
                .upsert_metadata(&metadata(&unique, index))
                .await
                .unwrap()
                .id,
        );
    }
    let repository = database.engagement();

    let (create_operation, create_fingerprint, replay_write) =
        store_discovery_brief(&database, replay_account.id, &paper_ids[..2], "replay").await;
    let progress = BriefProgressCommand {
        user_id: replay_account.id,
        operation_id: Uuid::now_v7(),
        brief_id: replay_write.id,
        expected_progress_revision: 1,
        position: 1,
        now: Utc::now(),
    };
    let progress_fingerprint = BriefProgressFingerprint([0x62; 32]);
    assert!(matches!(
        repository
            .advance_brief(&progress, &progress_fingerprint)
            .await
            .unwrap(),
        BriefProgressOutcome::Applied(brief)
            if brief.mode == BriefMode::Discovery
                && brief.position == 1
                && brief.items.len() == 2
    ));
    assert!(matches!(
        database
            .library()
            .mutate(
                replay_account.id,
                paper_ids[2],
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    assert_eq!(
        repository
            .store_brief(
                replay_account.id,
                create_operation,
                &create_fingerprint,
                &replay_write,
            )
            .await
            .unwrap(),
        BriefStoreOutcome::AuthorityStale,
        "an exact create replay must not return superseded recommendation items"
    );
    assert_eq!(
        repository
            .advance_brief(&progress, &progress_fingerprint)
            .await
            .unwrap(),
        BriefProgressOutcome::RevisionStale,
        "an exact progress replay must not return superseded recommendation items"
    );
    assert!(
        repository
            .current_brief(replay_account.id)
            .await
            .unwrap()
            .is_none()
    );

    let (_, _, race_write) = store_discovery_brief(
        &database,
        brief_race_account.id,
        &paper_ids[..2],
        "current-race",
    )
    .await;
    assert_eq!(
        repository
            .current_brief(brief_race_account.id)
            .await
            .unwrap()
            .map(|brief| brief.id),
        Some(race_write.id)
    );
    let mut brief_blocker = database.pool().begin().await.unwrap();
    sqlx::query("SELECT id FROM users WHERE id = $1 FOR UPDATE")
        .bind(brief_race_account.id.into_inner())
        .fetch_one(&mut *brief_blocker)
        .await
        .unwrap();
    let brief_blocker_xid: String = sqlx::query_scalar("SELECT pg_current_xact_id()::text")
        .fetch_one(&mut *brief_blocker)
        .await
        .unwrap();
    let brief_reader_repository = repository.clone();
    let brief_race_user_id = brief_race_account.id;
    let brief_reader = tokio::spawn(async move {
        brief_reader_repository
            .current_brief(brief_race_user_id)
            .await
            .unwrap()
    });
    wait_until_transaction_waiter(database.pool(), &brief_blocker_xid).await;
    force_library_authority_change(&mut brief_blocker, brief_race_account.id, paper_ids[2]).await;
    brief_blocker.commit().await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(5), brief_reader)
            .await
            .unwrap()
            .unwrap()
            .is_none()
    );

    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (
            user_id, current_revision, purged_through_revision, updated_at
        ) VALUES ($1, 0, 0, statement_timestamp())
        ON CONFLICT (user_id) DO NOTHING
        ",
    )
    .bind(notification_race_account.id.into_inner())
    .execute(database.pool())
    .await
    .unwrap();
    let discovery_notification_id = Uuid::now_v7();
    let queue_notification_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO notifications (
            id, user_id, notification_type, notification_scope, entity_type,
            entity_id, payload, batch_key, delivery_eligibility,
            eligibility_library_revision, eligible_at, expires_at
        ) VALUES (
            $1, $2, 'discovery_match', 'discovery', 'paper', $3,
            '{}'::jsonb, 'forced-list-race', 'eligible', 0, $4, $4 + interval '1 day'
        ), (
            $5, $2, 'sync_failure', 'queue_owned', 'sync', NULL,
            '{}'::jsonb, NULL, 'eligible', NULL, $4, $4 + interval '1 day'
        )
        ",
    )
    .bind(discovery_notification_id)
    .bind(notification_race_account.id.into_inner())
    .bind(paper_ids[0])
    .bind(Utc::now())
    .bind(queue_notification_id)
    .execute(database.pool())
    .await
    .unwrap();
    let mut notification_blocker = database.pool().begin().await.unwrap();
    sqlx::query("SELECT id FROM users WHERE id = $1 FOR UPDATE")
        .bind(notification_race_account.id.into_inner())
        .fetch_one(&mut *notification_blocker)
        .await
        .unwrap();
    let notification_blocker_xid: String = sqlx::query_scalar("SELECT pg_current_xact_id()::text")
        .fetch_one(&mut *notification_blocker)
        .await
        .unwrap();
    let notification_reader_repository = repository.clone();
    let notification_race_user_id = notification_race_account.id;
    let notification_reader = tokio::spawn(async move {
        notification_reader_repository
            .notifications(notification_race_user_id, 20)
            .await
            .unwrap()
    });
    wait_until_transaction_waiter(database.pool(), &notification_blocker_xid).await;
    force_library_authority_change(
        &mut notification_blocker,
        notification_race_account.id,
        paper_ids[2],
    )
    .await;
    notification_blocker.commit().await.unwrap();
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(5), notification_reader)
            .await
            .unwrap()
            .unwrap(),
        NotificationListOutcome::Found(items)
            if items.len() == 1
                && items[0].id == queue_notification_id
                && items[0].scope == NotificationScope::QueueOwned
    ));

    sqlx::query("DELETE FROM users WHERE id = ANY($1)")
        .bind(
            &[
                replay_account.id.into_inner(),
                brief_race_account.id.into_inner(),
                notification_race_account.id.into_inner(),
            ][..],
        )
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_subscription_delete_serializes_after_evaluation_and_withdraws_matches() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL subscription race coverage");
        return;
    };
    let database = Database::connect(&database_url, 10).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://subscription-race.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    database
        .papers()
        .upsert_metadata(&metadata(&unique, 30))
        .await
        .unwrap();

    let repository = database.engagement();
    let subscription_id = Uuid::now_v7();
    let write = SubscriptionWrite {
        id: subscription_id,
        kind: SubscriptionKind::Category,
        key: "cs.ai".to_owned(),
        label: "Artificial Intelligence".to_owned(),
        query_definition: None,
        frequency: SubscriptionFrequency::Immediate,
    };
    assert!(matches!(
        repository
            .mutate_subscription(
                account.id,
                Uuid::now_v7(),
                SubscriptionIntent::Create,
                &SubscriptionFingerprint([0x71; 32]),
                &write,
            )
            .await
            .unwrap(),
        SubscriptionMutationOutcome::Applied(_)
    ));
    let work = NotificationWorkItem {
        id: Uuid::now_v7(),
        user_id: account.id,
        kind: NotificationWorkKind::EvaluateSubscriptions,
        subscription_id: Some(subscription_id),
        window_key: "forced-unsubscribe-race".to_owned(),
        attempt: 1,
        max_attempts: 8,
    };

    // Force both operations behind the same account lock. Evaluation enters
    // the waiter queue first, so it may create matches, but the subsequent
    // delete must invalidate them before either release path can observe them.
    let mut blocker = database.pool().begin().await.unwrap();
    sqlx::query("SELECT id FROM users WHERE id = $1 FOR UPDATE")
        .bind(account.id.into_inner())
        .fetch_one(&mut *blocker)
        .await
        .unwrap();
    let blocker_xid: String = sqlx::query_scalar("SELECT pg_current_xact_id()::text")
        .fetch_one(&mut *blocker)
        .await
        .unwrap();
    let evaluation_repository = repository.clone();
    let evaluation = tokio::spawn(async move {
        evaluation_repository
            .evaluate_subscription(&work, Utc::now())
            .await
            .unwrap()
    });
    wait_until_transaction_waiter_count(database.pool(), &blocker_xid, 1).await;

    let deletion_repository = repository.clone();
    let deletion_write = write.clone();
    let deletion_user_id = account.id;
    let mut deletion = tokio::spawn(async move {
        deletion_repository
            .mutate_subscription(
                deletion_user_id,
                Uuid::now_v7(),
                SubscriptionIntent::Delete,
                &SubscriptionFingerprint([0x72; 32]),
                &deletion_write,
            )
            .await
            .unwrap()
    });
    assert!(
        tokio::time::timeout(Duration::from_millis(100), &mut deletion)
            .await
            .is_err(),
        "subscription deletion must wait behind the serialized evaluation"
    );
    blocker.commit().await.unwrap();

    let inserted = tokio::time::timeout(Duration::from_secs(5), evaluation)
        .await
        .unwrap()
        .unwrap();
    assert!(
        inserted > 0,
        "the forced evaluation must exercise withdrawal"
    );
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(5), deletion)
            .await
            .unwrap()
            .unwrap(),
        SubscriptionMutationOutcome::Applied(subscription)
            if subscription.deleted_at.is_some()
    ));

    let (derived, invalidated): (i64, i64) = sqlx::query_as(
        r"
        SELECT
            count(*),
            count(*) FILTER (
                WHERE delivery_eligibility = 'expired' AND dismissed_at IS NOT NULL
            )
        FROM notifications
        WHERE user_id = $1
          AND payload ->> 'subscription_id' = $2::uuid::text
        ",
    )
    .bind(account.id.into_inner())
    .bind(subscription_id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(derived, i64::try_from(inserted).unwrap());
    assert_eq!(invalidated, derived);
    assert_eq!(
        repository
            .apply_queue_decision(account.id, 0, true, Utc::now())
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    assert!(matches!(
        repository.notifications(account.id, 50).await.unwrap(),
        NotificationListOutcome::Found(items) if items.is_empty()
    ));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_engagement_collapses_duplicate_papers_and_applies_saved_topics() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL engagement coverage");
        return;
    };
    let database = Database::connect(&database_url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let account = database
        .accounts()
        .provision_oidc_identity(
            &format!("https://engagement-dedupe.test/{unique}"),
            "owner",
            Duration::from_secs(900),
        )
        .await
        .unwrap();
    let repository = database.engagement();
    let papers = database.papers();
    let first_paper = papers
        .upsert_metadata(&metadata(&unique, 0))
        .await
        .unwrap()
        .id;
    let second_paper = papers
        .upsert_metadata(&metadata(&unique, 1))
        .await
        .unwrap()
        .id;
    let matching_search_id = Uuid::now_v7();
    let mismatching_search_id = Uuid::now_v7();
    for (saved_search_id, fingerprint, topic) in [
        (matching_search_id, vec![0x91_u8; 32], "metadata"),
        (mismatching_search_id, vec![0x92_u8; 32], "quantum"),
    ] {
        sqlx::query(
            r"
            INSERT INTO saved_searches (
                id, user_id, definition_fingerprint, normalized_query,
                topics, sources, sort
            ) VALUES ($1, $2, $3, 'engagement', ARRAY[$4]::text[],
                      ARRAY['arxiv']::text[], 'recency')
            ",
        )
        .bind(saved_search_id)
        .bind(account.id.into_inner())
        .bind(fingerprint)
        .bind(topic)
        .execute(database.pool())
        .await
        .unwrap();
    }

    let now = Utc::now();
    for (index, saved_search_id) in [matching_search_id, mismatching_search_id]
        .into_iter()
        .enumerate()
    {
        let subscription_id = Uuid::now_v7();
        let write = SubscriptionWrite {
            id: subscription_id,
            kind: SubscriptionKind::SavedQuery,
            key: saved_search_id.to_string(),
            label: format!("Saved search {index}"),
            query_definition: Some(json!({ "saved_search_id": saved_search_id })),
            frequency: SubscriptionFrequency::Daily,
        };
        assert!(matches!(
            repository
                .mutate_subscription(
                    account.id,
                    Uuid::now_v7(),
                    SubscriptionIntent::Create,
                    &SubscriptionFingerprint(
                        [0x93_u8.saturating_add(u8::try_from(index).unwrap()); 32]
                    ),
                    &write,
                )
                .await
                .unwrap(),
            SubscriptionMutationOutcome::Applied(_)
        ));
        let inserted = repository
            .evaluate_subscription(
                &NotificationWorkItem {
                    id: Uuid::now_v7(),
                    user_id: account.id,
                    kind: NotificationWorkKind::EvaluateSubscriptions,
                    subscription_id: Some(subscription_id),
                    window_key: format!("saved-topic-{index}"),
                    attempt: 1,
                    max_attempts: 8,
                },
                now,
            )
            .await
            .unwrap();
        if index == 0 {
            assert_eq!(inserted, 2, "a matching saved topic must retain results");
        } else {
            assert_eq!(
                inserted, 0,
                "a nonmatching saved topic must exclude results"
            );
        }
    }

    sqlx::query("DELETE FROM notifications WHERE user_id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    let immediate_preferences = NotificationPreferences {
        discovery_frequency: SubscriptionFrequency::Immediate,
        type_frequencies: NotificationTypeFrequencies::from_legacy(
            SubscriptionFrequency::Immediate,
            false,
        ),
        quiet_hours_start: None,
        quiet_hours_end: None,
        timezone: "UTC".to_owned(),
        in_app_enabled: true,
        push_enabled: false,
        email_enabled: false,
        global_pause: false,
        active_updates_enabled: false,
        daily_budget: 5,
        revision: 0,
        updated_at: now,
    };
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x95; 32]),
                &immediate_preferences,
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    insert_duplicate_discovery_matches(&database, account.id, first_paper, second_paper, now).await;
    assert_eq!(
        repository
            .apply_queue_decision(account.id, 0, true, now + TimeDelta::seconds(1))
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    let (eligible_rows, eligible_papers): (i64, i64) = sqlx::query_as(
        r"
        SELECT count(*), count(DISTINCT entity_id)
        FROM notifications
        WHERE user_id = $1 AND notification_type = 'discovery_match'
          AND delivery_eligibility = 'eligible' AND dismissed_at IS NULL
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!((eligible_rows, eligible_papers), (2, 2));

    let queue_paper = papers
        .upsert_metadata(&metadata(&unique, 2))
        .await
        .unwrap()
        .id;
    let library = database.library();
    assert!(matches!(
        library
            .mutate(
                account.id,
                queue_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Save,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    let queue_revision = library_revision(&database, account.id).await;
    assert_eq!(
        repository
            .apply_queue_decision(
                account.id,
                queue_revision,
                false,
                now + TimeDelta::seconds(2)
            )
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    assert!(matches!(
        library
            .mutate(
                account.id,
                queue_paper,
                Uuid::now_v7(),
                LibraryMutationIntent::Remove,
                LibraryState::Inbox,
            )
            .await
            .unwrap(),
        LibraryMutationOutcome::Applied { .. }
    ));
    let empty_revision = library_revision(&database, account.id).await;
    let backlog_release_at = now + TimeDelta::seconds(3);
    assert_eq!(
        repository
            .apply_queue_decision(account.id, empty_revision, true, backlog_release_at)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: true
        }
    );
    let individually_released: i64 = sqlx::query_scalar(
        r"
        SELECT count(*) FROM notifications
        WHERE user_id = $1 AND notification_type = 'discovery_match'
          AND delivery_eligibility = 'eligible' AND dismissed_at IS NULL
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        individually_released, 0,
        "Immediate mode must not burst a queue-deferred backlog"
    );
    assert_eq!(
        repository
            .build_digest(account.id, empty_revision, backlog_release_at)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    let (backlog_digests, backlog_items): (i64, i64) = sqlx::query_as(
        r"
        SELECT count(DISTINCT notification.id), count(item.paper_id)
        FROM notifications AS notification
        JOIN notification_digest_items AS item ON item.notification_id = notification.id
        WHERE notification.user_id = $1
          AND notification.notification_type = 'discovery_digest'
          AND notification.delivery_eligibility = 'eligible'
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!((backlog_digests, backlog_items), (1, 2));

    sqlx::query("DELETE FROM notifications WHERE user_id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
    assert!(matches!(
        repository
            .put_preferences(
                account.id,
                Uuid::now_v7(),
                &SubscriptionFingerprint([0x96; 32]),
                &NotificationPreferences {
                    discovery_frequency: SubscriptionFrequency::Daily,
                    type_frequencies: NotificationTypeFrequencies::from_legacy(
                        SubscriptionFrequency::Daily,
                        false,
                    ),
                    ..immediate_preferences
                },
            )
            .await
            .unwrap(),
        PreferenceWriteOutcome::Applied(_)
    ));
    insert_duplicate_discovery_matches(&database, account.id, first_paper, second_paper, now).await;
    let decision_at = now + TimeDelta::seconds(4);
    assert_eq!(
        repository
            .apply_queue_decision(account.id, empty_revision, true, decision_at)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: true
        }
    );
    assert_eq!(
        repository
            .build_digest(account.id, empty_revision, decision_at)
            .await
            .unwrap(),
        QueueDecisionApplyOutcome::Applied {
            digest_needed: false
        }
    );
    let digest_items: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM notification_digest_items AS item
        JOIN notifications AS notification ON notification.id = item.notification_id
        WHERE notification.user_id = $1
          AND notification.notification_type = 'discovery_digest'
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(digest_items, 2);
    let dismissed_matches: i64 = sqlx::query_scalar(
        r"
        SELECT count(*) FROM notifications
        WHERE user_id = $1 AND notification_type = 'discovery_match'
          AND dismissed_at IS NOT NULL
        ",
    )
    .bind(account.id.into_inner())
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(dismissed_matches, 3);

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(account.id.into_inner())
        .execute(database.pool())
        .await
        .unwrap();
}

async fn insert_duplicate_discovery_matches(
    database: &Database,
    user_id: AuthenticatedUserId,
    first_paper: Uuid,
    second_paper: Uuid,
    now: chrono::DateTime<Utc>,
) {
    for (index, paper_id) in [first_paper, first_paper, second_paper]
        .into_iter()
        .enumerate()
    {
        sqlx::query(
            r"
            INSERT INTO notifications (
                id, user_id, notification_type, notification_scope, entity_type,
                entity_id, payload, batch_key, delivery_eligibility, expires_at
            ) VALUES (
                $1, $2, 'discovery_match', 'discovery', 'paper', $3,
                '{}'::jsonb, $4, 'deferred_unknown', $5 + interval '30 days'
            )
            ",
        )
        .bind(Uuid::now_v7())
        .bind(user_id.into_inner())
        .bind(paper_id)
        .bind(format!("dedupe-{index}"))
        .bind(now)
        .execute(database.pool())
        .await
        .unwrap();
    }
}

async fn store_discovery_brief(
    database: &Database,
    user_id: AuthenticatedUserId,
    paper_ids: &[Uuid],
    key: &str,
) -> (Uuid, BriefFingerprint, BriefWrite) {
    let now = Utc::now();
    let batch_id = Uuid::now_v7();
    sqlx::query(
        r"
        INSERT INTO recommendation_batches (
            id, user_id, mode, query_key, local_date, profile_revision,
            feedback_revision, library_revision, queue_proven_empty,
            algorithm_version, policy_version, seed, created_at, expires_at, status
        ) VALUES (
            $1, $2, 'recent', $3, $4, NULL, 0, 0, TRUE,
            'engagement-test-v1', 'engagement-test-v1', 1, $5,
            $5 + interval '1 day', 'served'
        )
        ",
    )
    .bind(batch_id)
    .bind(user_id.into_inner())
    .bind(format!("engagement-brief-{key}"))
    .bind(now.date_naive())
    .bind(now)
    .execute(database.pool())
    .await
    .unwrap();
    let operation_id = Uuid::now_v7();
    let fingerprint = BriefFingerprint([0x61; 32]);
    let write = BriefWrite {
        id: Uuid::now_v7(),
        mode: BriefMode::Discovery,
        recommendation_mode: Some(RecommendationMode::Recent),
        library_revision: 0,
        recommendation_batch_id: Some(batch_id),
        local_date: now.date_naive(),
        items: paper_ids
            .iter()
            .enumerate()
            .map(|(ordinal, paper_id)| BriefItemWrite {
                ordinal: u16::try_from(ordinal).unwrap(),
                paper_id: *paper_id,
                source: FeedItemSource::RecentV1,
                reason_codes: vec![RecommendationReasonCode::RecentCategory],
            })
            .collect(),
    };
    assert!(matches!(
        database
            .engagement()
            .store_brief(user_id, operation_id, &fingerprint, &write)
            .await
            .unwrap(),
        BriefStoreOutcome::Stored(brief)
            if brief.mode == BriefMode::Discovery && brief.items.len() == paper_ids.len()
    ));
    (operation_id, fingerprint, write)
}

async fn force_library_authority_change(
    transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: Uuid,
) {
    let revision: i64 = sqlx::query_scalar(
        r"
        UPDATE library_sync_metadata
        SET current_revision = current_revision + 1,
            updated_at = statement_timestamp()
        WHERE user_id = $1
        RETURNING current_revision
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO user_paper_library (
            user_id, paper_id, state, saved_at, updated_at, revision, last_operation_id
        ) VALUES (
            $1, $2, 'inbox', statement_timestamp(), statement_timestamp(), $3, $4
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .bind(revision)
    .bind(Uuid::now_v7())
    .execute(&mut **transaction)
    .await
    .unwrap();
}

fn check_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(sqlx::error::DatabaseError::code)
        .is_some_and(|code| code == "23514")
}

async fn wait_until_transaction_waiter(pool: &sqlx::PgPool, blocker_xid: &str) {
    wait_until_transaction_waiter_count(pool, blocker_xid, 1).await;
}

async fn wait_until_transaction_waiter_count(
    pool: &sqlx::PgPool,
    blocker_xid: &str,
    expected: i64,
) {
    for _ in 0..100 {
        let waiting: i64 = sqlx::query_scalar(
            r"
            SELECT count(*) FROM pg_locks
            WHERE locktype = 'transactionid'
              AND transactionid::text = $1
              AND NOT granted
            ",
        )
        .bind(blocker_xid)
        .fetch_one(pool)
        .await
        .unwrap();
        if waiting >= expected {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("{expected} engagement operations did not reach the forced account lock");
}

async fn discovery_eligibility_count(
    database: &Database,
    user_id: AuthenticatedUserId,
    eligibility: &str,
) -> i64 {
    sqlx::query_scalar(
        r"
        SELECT count(*) FROM notifications
        WHERE user_id = $1 AND notification_scope = 'discovery'
          AND delivery_eligibility = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(eligibility)
    .fetch_one(database.pool())
    .await
    .unwrap()
}

async fn library_revision(database: &Database, user_id: AuthenticatedUserId) -> i64 {
    sqlx::query_scalar("SELECT current_revision FROM library_sync_metadata WHERE user_id = $1")
        .bind(user_id.into_inner())
        .fetch_one(database.pool())
        .await
        .unwrap()
}

fn metadata(unique: &str, index: i64) -> PaperMetadata {
    let base_id = format!("engagement.{unique}.{index}");
    let published_at = Utc::now() - TimeDelta::hours(index + 1);
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.clone(),
            version: 1,
        },
        title: format!("Engagement fixture {index}"),
        abstract_text: "A metadata-only engagement fixture.".to_owned(),
        authors: vec![Author::from("Ada Engagement".to_owned())],
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
