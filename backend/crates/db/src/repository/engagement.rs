use std::str::FromStr as _;

use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use domain::{AccountStatus, AuthenticatedUserId, PaperSummary, RecommendationReasonCode};
use engagement::{
    BriefFingerprint, BriefItem, BriefMode, BriefProgressCommand, BriefProgressFingerprint,
    BriefProgressOutcome, BriefStatus, BriefStoreOutcome, BriefWrite, EngagementRetentionCutoffs,
    EngagementRetentionSummary, EngagementStore, EngagementStoreError, Notification,
    NotificationDeliveryEligibility, NotificationEntityType, NotificationListOutcome,
    NotificationMutationOutcome, NotificationPreferences, NotificationScope, NotificationType,
    NotificationTypeFrequencies, NotificationWorkItem, NotificationWorkKind, PreferenceReadOutcome,
    PreferenceWriteOutcome, QueueDecisionApplyOutcome, ReadingBrief, Subscription,
    SubscriptionFingerprint, SubscriptionFrequency, SubscriptionIntent, SubscriptionKind,
    SubscriptionListOutcome, SubscriptionMutationOutcome, SubscriptionWrite, WorkClaim,
    WorkClaimOutcome, WorkRetryDisposition, WorkScheduleSummary,
};
use reading_feed::{FeedItemSource, RecommendationMode};
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::rows::PaperSummaryRow;

#[derive(Clone)]
pub struct EngagementRepository {
    pool: PgPool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeferredDiscoveryMetrics {
    pub items: u64,
    pub oldest_age_seconds: Option<f64>,
    /// Aggregate local-day delivery slots remaining for active accounts with
    /// live deferred discovery work and discovery delivery enabled.
    pub release_budget_remaining: u64,
}

impl EngagementRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Returns one content-free aggregate from live deferred discovery rows.
    /// Existing eligible notifications of every type consume the same
    /// account-local daily budget used by delivery, so this does not overstate
    /// the configured slots remaining for discovery release.
    pub async fn deferred_discovery_metrics(
        &self,
        now: DateTime<Utc>,
    ) -> Result<DeferredDiscoveryMetrics, EngagementStoreError> {
        let (items, oldest_age_seconds, release_budget_remaining): (i64, Option<f64>, i64) =
            sqlx::query_as(
                r"
                WITH deferred_accounts AS MATERIALIZED (
                    SELECT notification.user_id,
                           count(*)::bigint AS items,
                           min(notification.created_at) AS oldest_created_at
                    FROM notifications AS notification
                    JOIN users AS account ON account.id = notification.user_id
                    WHERE account.status = 'active'
                      AND notification.notification_scope = 'discovery'
                      AND notification.delivery_eligibility IN (
                          'deferred_unknown', 'deferred_queue_nonempty'
                      )
                      AND notification.dismissed_at IS NULL
                      AND (
                          notification.expires_at IS NULL
                          OR notification.expires_at > $1
                      )
                    GROUP BY notification.user_id
                ), policy AS MATERIALIZED (
                    SELECT deferred.user_id,
                           deferred.items,
                           deferred.oldest_created_at,
                           COALESCE(preference.daily_budget, 5)::bigint AS daily_budget,
                           COALESCE(preference.timezone, 'UTC') AS timezone,
                           COALESCE(preference.in_app_enabled, TRUE)
                             AND NOT COALESCE(preference.global_pause, FALSE)
                             AND (
                                COALESCE(preference.discovery_match_frequency, 'off') <> 'off'
                                OR COALESCE(
                                    preference.discovery_digest_frequency,
                                    'daily'
                                ) <> 'off'
                             ) AS discovery_enabled
                    FROM deferred_accounts AS deferred
                    LEFT JOIN notification_preferences AS preference
                      ON preference.user_id = deferred.user_id
                ), capacity AS MATERIALIZED (
                    SELECT policy.*,
                           (
                               SELECT count(*)::bigint
                               FROM notifications AS delivered
                               WHERE delivered.user_id = policy.user_id
                                 AND delivered.eligible_at IS NOT NULL
                                 AND (
                                    delivered.eligible_at AT TIME ZONE policy.timezone
                                 )::date = ($1::timestamptz AT TIME ZONE policy.timezone)::date
                           ) AS delivered_today
                    FROM policy
                )
                SELECT COALESCE(sum(items), 0)::bigint,
                       extract(epoch FROM ($1 - min(oldest_created_at)))::double precision,
                       COALESCE(sum(
                           CASE WHEN discovery_enabled
                               THEN greatest(daily_budget - delivered_today, 0)
                               ELSE 0
                           END
                       ), 0)::bigint
                FROM capacity
                ",
            )
            .bind(now)
            .fetch_one(&self.pool)
            .await
            .map_err(store_sql)?;
        Ok(DeferredDiscoveryMetrics {
            items: u64::try_from(items.max(0)).unwrap_or(u64::MAX),
            oldest_age_seconds,
            release_budget_remaining: u64::try_from(release_budget_remaining.max(0))
                .unwrap_or(u64::MAX),
        })
    }
}

#[async_trait]
impl EngagementStore for EngagementRepository {
    #[allow(clippy::too_many_lines)]
    async fn store_brief(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: &BriefFingerprint,
        write: &BriefWrite,
    ) -> Result<BriefStoreOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(BriefStoreOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(BriefStoreOutcome::Inactive(status));
        }
        if let Some((brief_id, matches)) = sqlx::query_as::<_, (Uuid, bool)>(
            r"
            SELECT id, intent_fingerprint = $3
            FROM reading_briefs
            WHERE user_id = $1 AND operation_id = $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(fingerprint.0.as_slice())
        .fetch_optional(&mut *transaction)
        .await
        .map_err(store_sql)?
        {
            if !matches {
                return Ok(BriefStoreOutcome::Conflict);
            }
            let brief = load_brief(&mut transaction, user_id, brief_id)
                .await?
                .ok_or(EngagementStoreError::Inconsistent)?;
            if !brief_has_replay_authority(&mut transaction, user_id, &brief).await? {
                return Ok(BriefStoreOutcome::AuthorityStale);
            }
            transaction.commit().await.map_err(store_sql)?;
            return Ok(BriefStoreOutcome::Replay(brief));
        }

        let authority = queue_authority(&mut transaction, user_id).await?;
        let authority_matches = brief_authority_shape_matches(
            BriefStatus::Current,
            write.mode,
            write.recommendation_mode,
            write.recommendation_batch_id,
            write.library_revision,
            authority,
        );
        if !authority_matches {
            return Ok(BriefStoreOutcome::AuthorityStale);
        }
        if let (Some(batch_id), Some(mode)) =
            (write.recommendation_batch_id, write.recommendation_mode)
            && !recommendation_batch_is_valid(
                &mut transaction,
                user_id,
                batch_id,
                write.library_revision,
                mode,
            )
            .await?
        {
            return Ok(BriefStoreOutcome::AuthorityStale);
        }
        sqlx::query(
            r"
            UPDATE reading_briefs
            SET status = 'superseded', updated_at = statement_timestamp()
            WHERE user_id = $1 AND status = 'current'
            ",
        )
        .bind(user_id.into_inner())
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        sqlx::query(
            r"
            INSERT INTO reading_briefs (
                id, user_id, operation_id, intent_fingerprint, source_mode,
                recommendation_mode, library_revision, recommendation_batch_id,
                local_date, item_count, status
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'current')
            ",
        )
        .bind(write.id)
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(fingerprint.0.as_slice())
        .bind(write.mode.as_str())
        .bind(write.recommendation_mode.map(RecommendationMode::as_str))
        .bind(write.library_revision)
        .bind(write.recommendation_batch_id)
        .bind(write.local_date)
        .bind(i32::try_from(write.items.len()).map_err(|_| EngagementStoreError::Inconsistent)?)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        for item in &write.items {
            let reason_codes = item
                .reason_codes
                .iter()
                .map(|code| code.as_str().to_owned())
                .collect::<Vec<_>>();
            sqlx::query(
                r"
                INSERT INTO reading_brief_items (
                    user_id, brief_id, ordinal, paper_id, source, reason_codes
                ) VALUES ($1, $2, $3, $4, $5, $6)
                ",
            )
            .bind(user_id.into_inner())
            .bind(write.id)
            .bind(i32::from(item.ordinal))
            .bind(item.paper_id)
            .bind(feed_source_str(item.source))
            .bind(&reason_codes)
            .execute(&mut *transaction)
            .await
            .map_err(store_sql)?;
        }
        let brief = load_brief(&mut transaction, user_id, write.id)
            .await?
            .ok_or(EngagementStoreError::Inconsistent)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(BriefStoreOutcome::Stored(brief))
    }

    async fn current_brief(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<Option<ReadingBrief>, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(None);
        };
        if !status.is_active() {
            return Ok(None);
        }
        let id = sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT id FROM reading_briefs
            WHERE user_id = $1 AND status = 'current'
            ORDER BY local_date DESC, created_at DESC, id DESC
            LIMIT 1
            ",
        )
        .bind(user_id.into_inner())
        .fetch_optional(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let value = match id {
            Some(id) => {
                let brief = load_brief(&mut transaction, user_id, id).await?;
                match brief {
                    Some(brief)
                        if brief_has_current_authority(&mut transaction, user_id, &brief)
                            .await? =>
                    {
                        Some(brief)
                    }
                    Some(_) | None => None,
                }
            }
            None => None,
        };
        transaction.commit().await.map_err(store_sql)?;
        Ok(value)
    }

    async fn brief(
        &self,
        user_id: AuthenticatedUserId,
        brief_id: Uuid,
    ) -> Result<Option<ReadingBrief>, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(None);
        };
        if !status.is_active() {
            return Ok(None);
        }
        let value = match load_brief(&mut transaction, user_id, brief_id).await? {
            Some(brief) => {
                let valid = brief.status != BriefStatus::Superseded
                    && brief_has_replay_authority(&mut transaction, user_id, &brief).await?;
                valid.then_some(brief)
            }
            None => None,
        };
        transaction.commit().await.map_err(store_sql)?;
        Ok(value)
    }

    #[allow(clippy::too_many_lines)]
    async fn advance_brief(
        &self,
        command: &BriefProgressCommand,
        fingerprint: &BriefProgressFingerprint,
    ) -> Result<BriefProgressOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, command.user_id).await? else {
            return Ok(BriefProgressOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(BriefProgressOutcome::Inactive(status));
        }
        if let Some((brief_id, matches)) = sqlx::query_as::<_, (Uuid, bool)>(
            r"
            SELECT brief_id, payload_fingerprint = $3
            FROM reading_brief_progress_operations
            WHERE user_id = $1 AND operation_id = $2
            ",
        )
        .bind(command.user_id.into_inner())
        .bind(command.operation_id)
        .bind(fingerprint.0.as_slice())
        .fetch_optional(&mut *transaction)
        .await
        .map_err(store_sql)?
        {
            if !matches || brief_id != command.brief_id {
                return Ok(BriefProgressOutcome::Conflict);
            }
            let brief = load_brief(&mut transaction, command.user_id, brief_id)
                .await?
                .ok_or(EngagementStoreError::Inconsistent)?;
            if !brief_has_replay_authority(&mut transaction, command.user_id, &brief).await? {
                return Ok(BriefProgressOutcome::RevisionStale);
            }
            transaction.commit().await.map_err(store_sql)?;
            return Ok(BriefProgressOutcome::Replay(brief));
        }
        let row = sqlx::query_as::<_, (i32, i32, i64, String)>(
            r"
            SELECT position, item_count, progress_revision, status
            FROM reading_briefs
            WHERE user_id = $1 AND id = $2
            FOR UPDATE
            ",
        )
        .bind(command.user_id.into_inner())
        .bind(command.brief_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let Some((position, item_count, progress_revision, brief_status)) = row else {
            return Ok(BriefProgressOutcome::NotFound);
        };
        if progress_revision != command.expected_progress_revision
            || brief_status != BriefStatus::Current.as_str()
            || i32::from(command.position) < position
            || i32::from(command.position) > item_count
        {
            return Ok(BriefProgressOutcome::RevisionStale);
        }
        let brief = load_brief(&mut transaction, command.user_id, command.brief_id)
            .await?
            .ok_or(EngagementStoreError::Inconsistent)?;
        if !brief_has_current_authority(&mut transaction, command.user_id, &brief).await? {
            return Ok(BriefProgressOutcome::RevisionStale);
        }
        let next_revision = progress_revision
            .checked_add(1)
            .ok_or(EngagementStoreError::Inconsistent)?;
        let complete = i32::from(command.position) == item_count;
        sqlx::query(
            r"
            UPDATE reading_briefs
            SET position = $3, progress_revision = $4,
                status = CASE WHEN $5 THEN 'complete' ELSE 'current' END,
                completed_at = CASE WHEN $5 THEN $6 ELSE NULL END,
                updated_at = $6
            WHERE user_id = $1 AND id = $2
            ",
        )
        .bind(command.user_id.into_inner())
        .bind(command.brief_id)
        .bind(i32::from(command.position))
        .bind(next_revision)
        .bind(complete)
        .bind(command.now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        sqlx::query(
            r"
            INSERT INTO reading_brief_progress_operations (
                user_id, operation_id, brief_id, payload_fingerprint,
                accepted_progress_revision
            ) VALUES ($1, $2, $3, $4, $5)
            ",
        )
        .bind(command.user_id.into_inner())
        .bind(command.operation_id)
        .bind(command.brief_id)
        .bind(fingerprint.0.as_slice())
        .bind(next_revision)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let brief = load_brief(&mut transaction, command.user_id, command.brief_id)
            .await?
            .ok_or(EngagementStoreError::Inconsistent)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(BriefProgressOutcome::Applied(brief))
    }

    #[allow(clippy::too_many_lines)]
    async fn mutate_subscription(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: SubscriptionIntent,
        fingerprint: &SubscriptionFingerprint,
        write: &SubscriptionWrite,
    ) -> Result<SubscriptionMutationOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(SubscriptionMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(SubscriptionMutationOutcome::Inactive(status));
        }
        if let Some((subscription_id, matches)) = sqlx::query_as::<_, (Uuid, bool)>(
            r"
            SELECT subscription_id, payload_fingerprint = $3
            FROM subscription_operations
            WHERE user_id = $1 AND operation_id = $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(fingerprint.0.as_slice())
        .fetch_optional(&mut *transaction)
        .await
        .map_err(store_sql)?
        {
            if !matches || subscription_id != write.id {
                return Ok(SubscriptionMutationOutcome::Conflict);
            }
            let value = load_subscription(&mut transaction, user_id, write.id)
                .await?
                .ok_or(EngagementStoreError::Inconsistent)?;
            transaction.commit().await.map_err(store_sql)?;
            return Ok(SubscriptionMutationOutcome::Replay(value));
        }
        let existing = load_subscription(&mut transaction, user_id, write.id).await?;
        if matches!(intent, SubscriptionIntent::Create) && existing.is_some() {
            return Ok(SubscriptionMutationOutcome::Conflict);
        }
        if !matches!(intent, SubscriptionIntent::Create) && existing.is_none() {
            return Ok(SubscriptionMutationOutcome::NotFound);
        }
        if matches!(write.kind, SubscriptionKind::SavedQuery)
            && !matches!(intent, SubscriptionIntent::Delete)
        {
            let exists = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS (SELECT 1 FROM saved_searches WHERE user_id = $1 AND id::text = $2)",
            )
            .bind(user_id.into_inner())
            .bind(&write.key)
            .fetch_one(&mut *transaction)
            .await
            .map_err(store_sql)?;
            if !exists {
                return Ok(SubscriptionMutationOutcome::SavedQueryNotFound);
            }
        }
        let revision = next_subscription_revision(&mut transaction, user_id).await?;
        let result = match intent {
            SubscriptionIntent::Create => {
                sqlx::query_as::<_, SubscriptionRow>(
                    r"
                    INSERT INTO subscriptions (
                        id, user_id, kind, key, label, query_definition, frequency,
                        revision, deleted_at, created_at, updated_at, last_operation_id
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7, $8, NULL,
                        statement_timestamp(), statement_timestamp(), $9
                    )
                    RETURNING id, kind, key, label, query_definition, frequency,
                              last_evaluated_at, revision, deleted_at, created_at, updated_at
                    ",
                )
                .bind(write.id)
                .bind(user_id.into_inner())
                .bind(write.kind.as_str())
                .bind(&write.key)
                .bind(&write.label)
                .bind(&write.query_definition)
                .bind(write.frequency.as_str())
                .bind(revision)
                .bind(operation_id)
                .fetch_one(&mut *transaction)
                .await
            }
            SubscriptionIntent::Update => {
                sqlx::query_as::<_, SubscriptionRow>(
                    r"
                    UPDATE subscriptions
                    SET kind = $3, key = $4, label = $5, query_definition = $6,
                        frequency = $7, revision = $8, deleted_at = NULL,
                        updated_at = statement_timestamp(), last_operation_id = $9
                    WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                    RETURNING id, kind, key, label, query_definition, frequency,
                              last_evaluated_at, revision, deleted_at, created_at, updated_at
                    ",
                )
                .bind(user_id.into_inner())
                .bind(write.id)
                .bind(write.kind.as_str())
                .bind(&write.key)
                .bind(&write.label)
                .bind(&write.query_definition)
                .bind(write.frequency.as_str())
                .bind(revision)
                .bind(operation_id)
                .fetch_one(&mut *transaction)
                .await
            }
            SubscriptionIntent::Delete => {
                sqlx::query_as::<_, SubscriptionRow>(
                    r"
                    UPDATE subscriptions
                    SET revision = $3, deleted_at = statement_timestamp(),
                        updated_at = statement_timestamp(), last_operation_id = $4
                    WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                    RETURNING id, kind, key, label, query_definition, frequency,
                              last_evaluated_at, revision, deleted_at, created_at, updated_at
                    ",
                )
                .bind(user_id.into_inner())
                .bind(write.id)
                .bind(revision)
                .bind(operation_id)
                .fetch_one(&mut *transaction)
                .await
            }
        };
        let row = match result {
            Ok(row) => row,
            Err(error_value) if unique_violation(&error_value) => {
                return Ok(SubscriptionMutationOutcome::NameConflict);
            }
            Err(error_value) => return Err(store_sql(error_value)),
        };
        sqlx::query(
            r"
            INSERT INTO subscription_operations (
                user_id, operation_id, subscription_id, intent,
                payload_fingerprint, accepted_revision
            ) VALUES ($1, $2, $3, $4, $5, $6)
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(write.id)
        .bind(intent.as_str())
        .bind(fingerprint.0.as_slice())
        .bind(revision)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        if !matches!(intent, SubscriptionIntent::Create) {
            invalidate_subscription_notifications(&mut transaction, user_id, write.id).await?;
        }
        let value = subscription(row)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(SubscriptionMutationOutcome::Applied(value))
    }

    async fn subscriptions(
        &self,
        user_id: AuthenticatedUserId,
        limit: u16,
    ) -> Result<SubscriptionListOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = account_status(&mut transaction, user_id).await? else {
            return Ok(SubscriptionListOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(SubscriptionListOutcome::Inactive(status));
        }
        let rows = sqlx::query_as::<_, SubscriptionRow>(
            r"
            SELECT id, kind, key, label, query_definition, frequency,
                   last_evaluated_at, revision, deleted_at, created_at, updated_at
            FROM subscriptions
            WHERE user_id = $1 AND deleted_at IS NULL
            ORDER BY updated_at DESC, id DESC
            LIMIT $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(i64::from(limit))
        .fetch_all(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let items = rows
            .into_iter()
            .map(subscription)
            .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(SubscriptionListOutcome::Found(items))
    }

    async fn preferences(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<PreferenceReadOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = account_status(&mut transaction, user_id).await? else {
            return Ok(PreferenceReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(PreferenceReadOutcome::Inactive(status));
        }
        let value = load_preferences(&mut transaction, user_id)
            .await?
            .unwrap_or_else(default_preferences);
        transaction.commit().await.map_err(store_sql)?;
        Ok(PreferenceReadOutcome::Found(value))
    }

    // Preference validation, idempotency, timezone lookup, and revision allocation
    // intentionally share one account-locked transaction.
    #[allow(clippy::too_many_lines)]
    async fn put_preferences(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: &SubscriptionFingerprint,
        preferences: &NotificationPreferences,
    ) -> Result<PreferenceWriteOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(PreferenceWriteOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(PreferenceWriteOutcome::Inactive(status));
        }
        if let Some(matches) = sqlx::query_scalar::<_, bool>(
            r"
            SELECT payload_fingerprint = $3
            FROM notification_preference_operations
            WHERE user_id = $1 AND operation_id = $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(fingerprint.0.as_slice())
        .fetch_optional(&mut *transaction)
        .await
        .map_err(store_sql)?
        {
            if !matches {
                return Ok(PreferenceWriteOutcome::Conflict);
            }
            let value = load_preferences(&mut transaction, user_id)
                .await?
                .ok_or(EngagementStoreError::Inconsistent)?;
            transaction.commit().await.map_err(store_sql)?;
            return Ok(PreferenceWriteOutcome::Replay(value));
        }
        let timezone_valid = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)",
        )
        .bind(&preferences.timezone)
        .fetch_one(&mut *transaction)
        .await
        .map_err(store_sql)?;
        if !timezone_valid {
            return Ok(PreferenceWriteOutcome::InvalidTimezone);
        }
        let revision = sqlx::query_scalar::<_, i64>(
            "SELECT COALESCE((SELECT revision FROM notification_preferences WHERE user_id = $1), 0) + 1",
        )
        .bind(user_id.into_inner())
        .fetch_one(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let row = sqlx::query_as::<_, PreferenceRow>(
            r"
            INSERT INTO notification_preferences (
                user_id, discovery_frequency,
                discovery_match_frequency, discovery_digest_frequency,
                user_selected_reminder_frequency,
                active_paper_version_frequency, sync_failure_frequency,
                quiet_hours_start, quiet_hours_end, timezone, in_app_enabled,
                push_enabled, email_enabled, global_pause, active_updates_enabled,
                daily_budget, revision, last_operation_id
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
                FALSE, FALSE, $12, $13, $14, $15, $16
            )
            ON CONFLICT (user_id) DO UPDATE
            SET discovery_frequency = EXCLUDED.discovery_frequency,
                discovery_match_frequency = EXCLUDED.discovery_match_frequency,
                discovery_digest_frequency = EXCLUDED.discovery_digest_frequency,
                user_selected_reminder_frequency = EXCLUDED.user_selected_reminder_frequency,
                active_paper_version_frequency = EXCLUDED.active_paper_version_frequency,
                sync_failure_frequency = EXCLUDED.sync_failure_frequency,
                quiet_hours_start = EXCLUDED.quiet_hours_start,
                quiet_hours_end = EXCLUDED.quiet_hours_end,
                timezone = EXCLUDED.timezone,
                in_app_enabled = EXCLUDED.in_app_enabled,
                push_enabled = FALSE,
                email_enabled = FALSE,
                global_pause = EXCLUDED.global_pause,
                active_updates_enabled = EXCLUDED.active_updates_enabled,
                daily_budget = EXCLUDED.daily_budget,
                revision = EXCLUDED.revision,
                last_operation_id = EXCLUDED.last_operation_id,
                updated_at = statement_timestamp()
            RETURNING discovery_frequency, discovery_match_frequency,
                      discovery_digest_frequency, user_selected_reminder_frequency,
                      active_paper_version_frequency,
                      sync_failure_frequency, quiet_hours_start, quiet_hours_end,
                      timezone, in_app_enabled, push_enabled, email_enabled, global_pause,
                      active_updates_enabled, daily_budget, revision, updated_at
            ",
        )
        .bind(user_id.into_inner())
        .bind(
            preferences
                .type_frequencies
                .legacy_discovery_frequency()
                .as_str(),
        )
        .bind(preferences.type_frequencies.discovery_match.as_str())
        .bind(preferences.type_frequencies.discovery_digest.as_str())
        .bind(preferences.type_frequencies.user_selected_reminder.as_str())
        .bind(preferences.type_frequencies.active_paper_version.as_str())
        .bind(preferences.type_frequencies.sync_failure.as_str())
        .bind(preferences.quiet_hours_start)
        .bind(preferences.quiet_hours_end)
        .bind(&preferences.timezone)
        .bind(preferences.in_app_enabled)
        .bind(preferences.global_pause)
        .bind(preferences.type_frequencies.legacy_active_updates_enabled())
        .bind(i32::from(preferences.daily_budget))
        .bind(revision)
        .bind(operation_id)
        .fetch_one(&mut *transaction)
        .await
        .map_err(store_sql)?;
        sqlx::query(
            r"
            INSERT INTO notification_preference_operations (
                user_id, operation_id, payload_fingerprint, accepted_revision
            ) VALUES ($1, $2, $3, $4)
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(fingerprint.0.as_slice())
        .bind(revision)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let value = preferences_from_row(row)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(PreferenceWriteOutcome::Applied(value))
    }

    async fn notifications(
        &self,
        user_id: AuthenticatedUserId,
        limit: u16,
    ) -> Result<NotificationListOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(NotificationListOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(NotificationListOutcome::Inactive(status));
        }
        let (library_revision, active_count) = queue_authority(&mut transaction, user_id).await?;
        let rows = sqlx::query_as::<_, NotificationRow>(
            r"
            SELECT id, notification_type, notification_scope, entity_type, entity_id,
                   payload, delivery_eligibility, eligibility_library_revision,
                   created_at, read_at, expires_at
            FROM notifications AS notification
            WHERE user_id = $1
              AND delivery_eligibility = 'eligible'
              AND dismissed_at IS NULL
              AND (expires_at IS NULL OR expires_at > statement_timestamp())
              AND COALESCE((
                    SELECT in_app_enabled AND NOT global_pause
                    FROM notification_preferences WHERE user_id = $1
                  ), TRUE)
              AND (
                    notification.notification_type <> 'user_selected_reminder'
                    OR EXISTS (
                        SELECT 1
                        FROM user_paper_library AS library
                        WHERE library.user_id = notification.user_id
                          AND library.paper_id = notification.entity_id
                          AND library.removed_at IS NULL
                          AND library.state IN ('to_read', 'inbox', 'read_next', 'reading')
                          AND library.reminder_at IS NOT NULL
                          AND library.reminder_at > statement_timestamp() - interval '24 hours'
                          AND notification.batch_key = concat(
                              'reminder-',
                              floor(extract(epoch FROM library.reminder_at) * 1000000)::bigint
                          )
                    )
                  )
              AND (
                    notification_scope = 'queue_owned'
                    OR (
                        notification_scope = 'discovery'
                        AND $3 = 0
                        AND eligibility_library_revision = $4
                    )
                  )
            ORDER BY created_at DESC, id DESC
            LIMIT $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(i64::from(limit))
        .bind(active_count)
        .bind(library_revision)
        .fetch_all(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let papers = load_notification_papers(&mut transaction, row.id, row.entity_id).await?;
            items.push(notification(row, papers)?);
        }
        transaction.commit().await.map_err(store_sql)?;
        Ok(NotificationListOutcome::Found(items))
    }

    async fn mark_notification_read(
        &self,
        user_id: AuthenticatedUserId,
        notification_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<NotificationMutationOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(NotificationMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(NotificationMutationOutcome::Inactive(status));
        }
        let result = sqlx::query(
            r"
            UPDATE notifications SET read_at = COALESCE(read_at, $3)
            WHERE user_id = $1 AND id = $2 AND delivery_eligibility = 'eligible'
              AND dismissed_at IS NULL
            ",
        )
        .bind(user_id.into_inner())
        .bind(notification_id)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        if result.rows_affected() == 0 {
            return Ok(NotificationMutationOutcome::NotFound);
        }
        transaction.commit().await.map_err(store_sql)?;
        Ok(NotificationMutationOutcome::Applied { affected: 1 })
    }

    async fn mark_all_notifications_read(
        &self,
        user_id: AuthenticatedUserId,
        now: DateTime<Utc>,
    ) -> Result<NotificationMutationOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(NotificationMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(NotificationMutationOutcome::Inactive(status));
        }
        let result = sqlx::query(
            r"
            UPDATE notifications SET read_at = COALESCE(read_at, $2)
            WHERE user_id = $1 AND delivery_eligibility = 'eligible'
              AND dismissed_at IS NULL AND read_at IS NULL
            ",
        )
        .bind(user_id.into_inner())
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(NotificationMutationOutcome::Applied {
            affected: result.rows_affected(),
        })
    }

    async fn dismiss_notification(
        &self,
        user_id: AuthenticatedUserId,
        notification_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<NotificationMutationOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(NotificationMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(NotificationMutationOutcome::Inactive(status));
        }
        let result = sqlx::query(
            r"
            UPDATE notifications
            SET dismissed_at = $3
            WHERE user_id = $1 AND id = $2 AND dismissed_at IS NULL
              AND delivery_eligibility = 'eligible'
            ",
        )
        .bind(user_id.into_inner())
        .bind(notification_id)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        if result.rows_affected() == 0 {
            return Ok(NotificationMutationOutcome::NotFound);
        }
        transaction.commit().await.map_err(store_sql)?;
        Ok(NotificationMutationOutcome::Applied { affected: 1 })
    }

    // Scheduling deliberately keeps all candidate classes in one short transaction so
    // deduplication and the returned aggregate describe the same database snapshot.
    #[allow(clippy::too_many_lines)]
    async fn schedule_due_work_with_reminders(
        &self,
        now: DateTime<Utc>,
        limit: u32,
        reminders_enabled: bool,
    ) -> Result<WorkScheduleSummary, EngagementStoreError> {
        if !(1..=1_000).contains(&limit) {
            return Err(EngagementStoreError::Inconsistent);
        }
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let window = now.timestamp().div_euclid(60).to_string();
        let subscriptions = sqlx::query(
            r"
            INSERT INTO notification_work_items (
                id, user_id, work_kind, subscription_id, window_key,
                payload, state, available_at
            )
            SELECT gen_random_uuid(), subscription.user_id,
                   'evaluate_subscriptions', subscription.id, $2,
                   '{}'::jsonb, 'queued', $1
            FROM subscriptions AS subscription
            JOIN users AS account ON account.id = subscription.user_id
            LEFT JOIN notification_preferences AS preference
              ON preference.user_id = subscription.user_id
            WHERE account.status = 'active'
              AND subscription.deleted_at IS NULL
              AND subscription.frequency <> 'off'
              AND COALESCE(preference.in_app_enabled, TRUE) IS TRUE
              AND COALESCE(preference.global_pause, FALSE) IS FALSE
              AND (
                    COALESCE(preference.discovery_match_frequency, 'off') <> 'off'
                    OR COALESCE(preference.discovery_digest_frequency, 'daily') <> 'off'
                  )
              AND NOT EXISTS (
                    SELECT 1 FROM notification_work_items AS pending
                    WHERE pending.subscription_id = subscription.id
                      AND pending.work_kind = 'evaluate_subscriptions'
                      AND pending.state IN ('queued', 'leased')
                  )
              AND (
                subscription.last_evaluated_at IS NULL
                OR subscription.last_evaluated_at <= $1 - CASE subscription.frequency
                    WHEN 'immediate' THEN interval '5 minutes'
                    WHEN 'daily' THEN interval '1 day'
                    WHEN 'weekly' THEN interval '7 days'
                    ELSE interval '100 years'
                END
              )
            ORDER BY subscription.last_evaluated_at NULLS FIRST,
                     subscription.updated_at, subscription.id
            LIMIT $3
            ON CONFLICT DO NOTHING
            ",
        )
        .bind(now)
        .bind(format!("subscription-{window}"))
        .bind(i64::from(limit))
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?
        .rows_affected();
        let expirations = schedule_account_work(
            &mut transaction,
            now,
            limit,
            NotificationWorkKind::ExpireNotifications,
            &format!("expire-{}", now.timestamp().div_euclid(3_600)),
            r"
            SELECT DISTINCT notification.user_id
            FROM notifications AS notification
            JOIN users AS account ON account.id = notification.user_id
            WHERE account.status = 'active'
              AND notification.expires_at <= $1
              AND notification.delivery_eligibility <> 'expired'
              AND NOT EXISTS (
                    SELECT 1 FROM notification_work_items AS pending
                    WHERE pending.user_id = notification.user_id
                      AND pending.work_kind = 'expire_notifications'
                      AND pending.state IN ('queued', 'leased')
                  )
            ORDER BY notification.user_id
            LIMIT $2
            ",
        )
        .await?;
        let queue_rechecks = schedule_account_work(
            &mut transaction,
            now,
            limit,
            NotificationWorkKind::RecheckNotificationQueueEligibility,
            &format!("recheck-{window}"),
            r"
            SELECT DISTINCT notification.user_id
            FROM notifications AS notification
            JOIN users AS account ON account.id = notification.user_id
            LEFT JOIN notification_preferences AS preference
              ON preference.user_id = notification.user_id
            WHERE account.status = 'active'
              AND notification.notification_scope = 'discovery'
              AND notification.delivery_eligibility IN (
                    'deferred_unknown', 'deferred_queue_nonempty'
                  )
              AND notification.dismissed_at IS NULL
              AND (notification.expires_at IS NULL OR notification.expires_at > $1)
              AND COALESCE(preference.in_app_enabled, TRUE) IS TRUE
              AND COALESCE(preference.global_pause, FALSE) IS FALSE
              AND (
                    notification.notification_type = 'discovery_match'
                    OR COALESCE(preference.discovery_match_frequency, 'off') = 'off'
                  )
              AND CASE
                    WHEN COALESCE(preference.discovery_match_frequency, 'off') <> 'off'
                        THEN COALESCE(preference.discovery_match_frequency, 'off')
                    ELSE COALESCE(preference.discovery_digest_frequency, 'daily')
                  END <> 'off'
              AND NOT EXISTS (
                    SELECT 1
                    FROM notifications AS delivered
                    WHERE delivered.user_id = notification.user_id
                      AND delivered.notification_type = CASE
                          WHEN COALESCE(preference.discovery_match_frequency, 'off') <> 'off'
                              THEN 'discovery_match'
                          ELSE 'discovery_digest'
                      END
                      AND delivered.eligible_at > $1 - CASE
                          WHEN COALESCE(preference.discovery_match_frequency, 'off') <> 'off'
                              THEN CASE preference.discovery_match_frequency
                                  WHEN 'immediate' THEN interval '0 seconds'
                                  WHEN 'daily' THEN interval '1 day'
                                  WHEN 'weekly' THEN interval '7 days'
                                  ELSE interval '100 years'
                              END
                          ELSE CASE COALESCE(preference.discovery_digest_frequency, 'daily')
                              WHEN 'immediate' THEN interval '0 seconds'
                              WHEN 'daily' THEN interval '1 day'
                              WHEN 'weekly' THEN interval '7 days'
                              ELSE interval '100 years'
                          END
                      END
                  )
              AND NOT EXISTS (
                    SELECT 1 FROM notification_work_items AS pending
                    WHERE pending.user_id = notification.user_id
                      AND pending.work_kind = 'recheck_notification_queue_eligibility'
                      AND pending.state IN ('queued', 'leased')
                  )
            ORDER BY notification.user_id
            LIMIT $2
            ",
        )
        .await?;
        let reminders = if reminders_enabled {
            schedule_account_work(
                &mut transaction,
                now,
                limit,
                NotificationWorkKind::EvaluateReminders,
                &format!("reminder-{window}"),
                r"
            SELECT DISTINCT library.user_id
            FROM user_paper_library AS library
            JOIN users AS account ON account.id = library.user_id
            LEFT JOIN notification_preferences AS preference
              ON preference.user_id = library.user_id
            WHERE account.status = 'active'
              AND library.removed_at IS NULL
              AND library.state IN ('to_read', 'inbox', 'read_next', 'reading')
              AND library.reminder_at IS NOT NULL
              AND library.reminder_at <= $1
              AND library.reminder_at > $1 - interval '24 hours'
              AND COALESCE(preference.in_app_enabled, TRUE) IS TRUE
              AND COALESCE(preference.global_pause, FALSE) IS FALSE
              AND COALESCE(preference.user_selected_reminder_frequency, 'immediate') <> 'off'
              AND NOT EXISTS (
                    SELECT 1
                    FROM notifications AS notification
                    WHERE notification.user_id = library.user_id
                      AND notification.notification_type = 'user_selected_reminder'
                      AND notification.entity_type = 'paper'
                      AND notification.entity_id = library.paper_id
                      AND notification.batch_key = concat(
                          'reminder-',
                          floor(extract(epoch FROM library.reminder_at) * 1000000)::bigint
                      )
                  )
              AND NOT EXISTS (
                    SELECT 1 FROM notification_work_items AS pending
                    WHERE pending.user_id = library.user_id
                      AND pending.work_kind = 'evaluate_reminders'
                      AND pending.state IN ('queued', 'leased')
                  )
            ORDER BY library.user_id
            LIMIT $2
            ",
            )
            .await?
        } else {
            0
        };
        let active_updates = schedule_account_work(
            &mut transaction,
            now,
            limit,
            NotificationWorkKind::EvaluateActivePapers,
            &format!("active-{}", now.timestamp().div_euclid(3_600)),
            r"
            SELECT preference.user_id
            FROM notification_preferences AS preference
            JOIN users AS account ON account.id = preference.user_id
            WHERE account.status = 'active'
              AND preference.in_app_enabled IS TRUE
              AND preference.global_pause IS FALSE
              AND preference.active_paper_version_frequency <> 'off'
              AND NOT EXISTS (
                    SELECT 1
                    FROM notification_work_items AS completed
                    WHERE completed.user_id = preference.user_id
                      AND completed.work_kind = 'evaluate_active_papers'
                      AND completed.state = 'complete'
                      AND completed.completed_at > $1 - CASE
                          preference.active_paper_version_frequency
                          WHEN 'immediate' THEN interval '1 hour'
                          WHEN 'daily' THEN interval '1 day'
                          WHEN 'weekly' THEN interval '7 days'
                          ELSE interval '100 years'
                      END
                  )
              AND NOT EXISTS (
                    SELECT 1 FROM notification_work_items AS pending
                    WHERE pending.user_id = preference.user_id
                      AND pending.work_kind = 'evaluate_active_papers'
                      AND pending.state IN ('queued', 'leased')
                  )
            ORDER BY preference.user_id
            LIMIT $2
            ",
        )
        .await?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(WorkScheduleSummary {
            subscriptions,
            expirations,
            queue_rechecks,
            reminders,
            active_updates,
        })
    }

    async fn enqueue_work(
        &self,
        user_id: AuthenticatedUserId,
        kind: NotificationWorkKind,
        subscription_id: Option<Uuid>,
        window_key: &str,
        now: DateTime<Utc>,
    ) -> Result<(), EngagementStoreError> {
        sqlx::query(
            r"
            INSERT INTO notification_work_items (
                id, user_id, work_kind, subscription_id, window_key,
                payload, state, available_at
            ) VALUES ($1, $2, $3, $4, $5, '{}'::jsonb, 'queued', $6)
            ON CONFLICT (
                user_id,
                work_kind,
                COALESCE(subscription_id, '00000000-0000-0000-0000-000000000000'::uuid),
                window_key
            ) DO NOTHING
            ",
        )
        .bind(Uuid::now_v7())
        .bind(user_id.into_inner())
        .bind(kind.as_str())
        .bind(subscription_id)
        .bind(window_key)
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(store_sql)?;
        Ok(())
    }

    async fn claim_work(
        &self,
        claim: &WorkClaim,
    ) -> Result<WorkClaimOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let lease_exhausted = sqlx::query_scalar::<_, String>(
            r"
            WITH exhausted AS (
                SELECT id
                FROM notification_work_items
                WHERE state = 'leased'
                  AND lease_expires_at <= $1
                  AND attempts >= max_attempts
                ORDER BY lease_expires_at, id
                LIMIT 100
                FOR UPDATE SKIP LOCKED
            )
            UPDATE notification_work_items AS work
            SET state = 'failed', lease_owner = NULL, lease_expires_at = NULL,
                last_error_code = 'LEASE_EXHAUSTED', completed_at = $1,
                updated_at = $1
            FROM exhausted
            WHERE work.id = exhausted.id
            RETURNING work.work_kind
            ",
        )
        .bind(claim.now)
        .fetch_all(&mut *transaction)
        .await
        .map_err(store_sql)?
        .into_iter()
        .map(|kind| parse_work_kind(&kind))
        .collect::<Result<Vec<_>, _>>()?;
        let row = sqlx::query_as::<_, WorkRow>(
            r"
            WITH candidate AS (
                SELECT id
                FROM notification_work_items
                WHERE (
                    state = 'queued' AND available_at <= $1
                ) OR (
                    state = 'leased' AND lease_expires_at <= $1
                )
                ORDER BY available_at, created_at, id
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            UPDATE notification_work_items AS work
            SET state = 'leased', attempts = attempts + 1,
                lease_owner = $2,
                lease_expires_at = $1 + make_interval(secs => $3),
                updated_at = $1
            FROM candidate
            WHERE work.id = candidate.id AND work.attempts < work.max_attempts
            RETURNING work.id, work.user_id, work.work_kind, work.subscription_id,
                      work.window_key, work.attempts, work.max_attempts
            ",
        )
        .bind(claim.now)
        .bind(&claim.worker_id)
        .bind(i32::try_from(claim.lease_seconds).map_err(|_| EngagementStoreError::Inconsistent)?)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(store_sql)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(WorkClaimOutcome {
            item: row.map(work_item).transpose()?,
            lease_exhausted,
        })
    }

    async fn evaluate_subscription(
        &self,
        item: &NotificationWorkItem,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError> {
        let Some(subscription_id) = item.subscription_id else {
            return Err(EngagementStoreError::Inconsistent);
        };
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, item.user_id).await? else {
            return Ok(0);
        };
        if !status.is_active() {
            return Ok(0);
        }
        let Some(subscription) =
            load_subscription(&mut transaction, item.user_id, subscription_id).await?
        else {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(0);
        };
        if subscription.deleted_at.is_some()
            || matches!(subscription.frequency, SubscriptionFrequency::Off)
        {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(0);
        }
        let preferences = load_preferences(&mut transaction, item.user_id)
            .await?
            .unwrap_or_else(default_preferences);
        if !preferences.type_frequencies.discovery_enabled() {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(0);
        }
        let since = subscription
            .last_evaluated_at
            .unwrap_or_else(|| now - chrono::Duration::days(7));
        let paper_ids =
            matching_papers(&mut transaction, item.user_id, &subscription, since, 20).await?;
        let mut inserted = 0_u64;
        for paper_id in paper_ids {
            let result = sqlx::query(
                r"
                INSERT INTO notifications (
                    id, user_id, notification_type, notification_scope,
                    entity_type, entity_id, payload, batch_key,
                    delivery_eligibility, expires_at
                ) VALUES (
                    $1, $2, 'discovery_match', 'discovery', 'paper', $3,
                    jsonb_build_object(
                        'subscription_id', $4::uuid::text,
                        'reason_code', $5::text
                    ),
                    $6, 'deferred_unknown', $7 + interval '30 days'
                )
                ON CONFLICT DO NOTHING
                ",
            )
            .bind(Uuid::now_v7())
            .bind(item.user_id.into_inner())
            .bind(paper_id)
            .bind(subscription.id)
            .bind(subscription_reason(subscription.kind))
            .bind(format!("subscription-{}", subscription.revision))
            .bind(now)
            .execute(&mut *transaction)
            .await
            .map_err(store_sql)?;
            inserted += result.rows_affected();
        }
        sqlx::query(
            "UPDATE subscriptions SET last_evaluated_at = $3 WHERE user_id = $1 AND id = $2",
        )
        .bind(item.user_id.into_inner())
        .bind(subscription.id)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(inserted)
    }

    // The account lock, preference/capacity decision, candidate read, and inserts must
    // remain transactionally coupled to avoid eligibility races.
    #[allow(clippy::too_many_lines)]
    async fn evaluate_active_papers(
        &self,
        item: &NotificationWorkItem,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError> {
        if item.subscription_id.is_some() {
            return Err(EngagementStoreError::Inconsistent);
        }
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, item.user_id).await? else {
            return Ok(0);
        };
        if !status.is_active() {
            return Ok(0);
        }
        let preferences = load_preferences(&mut transaction, item.user_id)
            .await?
            .unwrap_or_else(default_preferences);
        let active_frequency = preferences.type_frequencies.active_paper_version;
        if !active_frequency.is_enabled()
            || !notification_frequency_due(
                &mut transaction,
                item.user_id,
                NotificationType::ActivePaperVersion,
                active_frequency,
                now,
            )
            .await?
        {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(0);
        }
        let capacity = delivery_capacity(&mut transaction, item.user_id, &preferences, now).await?;
        if capacity == 0 {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(0);
        }
        let candidates = sqlx::query_as::<_, (Uuid, i32)>(
            r"
            SELECT library.paper_id, paper.arxiv_version
            FROM user_paper_library AS library
            JOIN papers AS paper ON paper.id = library.paper_id
            WHERE library.user_id = $1 AND library.removed_at IS NULL
              AND library.state IN ('to_read', 'inbox', 'read_next', 'reading')
              AND paper.updated_at > library.saved_at
              AND NOT EXISTS (
                    SELECT 1 FROM notifications AS notification
                    WHERE notification.user_id = library.user_id
                      AND notification.notification_type = 'active_paper_version'
                      AND notification.entity_type = 'paper'
                      AND notification.entity_id = library.paper_id
                      AND notification.batch_key = 'version-' || paper.arxiv_version::text
                  )
            ORDER BY paper.updated_at, library.paper_id
            LIMIT $2
            ",
        )
        .bind(item.user_id.into_inner())
        .bind(i64::from(capacity))
        .fetch_all(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let mut inserted = 0_u64;
        for (paper_id, version) in candidates {
            inserted += sqlx::query(
                r"
                INSERT INTO notifications (
                    id, user_id, notification_type, notification_scope,
                    entity_type, entity_id, payload, batch_key,
                    delivery_eligibility, eligible_at, expires_at
                ) VALUES (
                    $1, $2, 'active_paper_version', 'queue_owned',
                    'paper', $3,
                    jsonb_build_object(
                        'reason_code', 'active_paper_version',
                        'arxiv_version', $4::integer
                    ),
                    concat('version-', $4::integer),
                    'eligible', $5, $5 + interval '30 days'
                )
                ON CONFLICT DO NOTHING
                ",
            )
            .bind(Uuid::now_v7())
            .bind(item.user_id.into_inner())
            .bind(paper_id)
            .bind(version)
            .bind(now)
            .execute(&mut *transaction)
            .await
            .map_err(store_sql)?
            .rows_affected();
        }
        transaction.commit().await.map_err(store_sql)?;
        Ok(inserted)
    }

    // Reminder timestamps are private, explicit user input on active queue items.
    // The account lock keeps preference/budget checks and idempotent inserts atomic.
    async fn evaluate_reminders(
        &self,
        item: &NotificationWorkItem,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError> {
        if item.subscription_id.is_some() {
            return Err(EngagementStoreError::Inconsistent);
        }
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, item.user_id).await? else {
            return Ok(0);
        };
        if !status.is_active() {
            return Ok(0);
        }
        let preferences = load_preferences(&mut transaction, item.user_id)
            .await?
            .unwrap_or_else(default_preferences);
        let frequency = preferences.type_frequencies.user_selected_reminder;
        if !frequency.is_enabled()
            || !notification_frequency_due(
                &mut transaction,
                item.user_id,
                NotificationType::UserSelectedReminder,
                frequency,
                now,
            )
            .await?
        {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(0);
        }
        let capacity = delivery_capacity(&mut transaction, item.user_id, &preferences, now).await?;
        if capacity == 0 {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(0);
        }
        let inserted = sqlx::query(
            r"
            WITH due AS MATERIALIZED (
                SELECT library.paper_id, library.reminder_at
                FROM user_paper_library AS library
                WHERE library.user_id = $1
                  AND library.removed_at IS NULL
                  AND library.state IN ('to_read', 'inbox', 'read_next', 'reading')
                  AND library.reminder_at IS NOT NULL
                  AND library.reminder_at <= $2
                  AND library.reminder_at > $2 - interval '24 hours'
                ORDER BY library.reminder_at, library.paper_id
                LIMIT $3
            )
            INSERT INTO notifications (
                id, user_id, notification_type, notification_scope,
                entity_type, entity_id, payload, batch_key,
                delivery_eligibility, eligible_at, expires_at
            )
            SELECT gen_random_uuid(), $1, 'user_selected_reminder', 'queue_owned',
                   'paper', due.paper_id,
                   jsonb_build_object(
                       'reminder_at_epoch_ms',
                       floor(extract(epoch FROM due.reminder_at) * 1000)::bigint
                   ),
                   concat(
                       'reminder-',
                       floor(extract(epoch FROM due.reminder_at) * 1000000)::bigint
                   ),
                   'eligible', $2, $2 + interval '30 days'
            FROM due
            ON CONFLICT DO NOTHING
            ",
        )
        .bind(item.user_id.into_inner())
        .bind(now)
        .bind(i64::from(capacity))
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?
        .rows_affected();
        transaction.commit().await.map_err(store_sql)?;
        Ok(inserted)
    }

    #[allow(clippy::too_many_lines)]
    async fn apply_queue_decision(
        &self,
        user_id: AuthenticatedUserId,
        library_revision: i64,
        queue_proven_empty: bool,
        now: DateTime<Utc>,
    ) -> Result<QueueDecisionApplyOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(QueueDecisionApplyOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(QueueDecisionApplyOutcome::Inactive(status));
        }
        let authority = queue_authority(&mut transaction, user_id).await?;
        if authority.0 != library_revision || (authority.1 == 0) != queue_proven_empty {
            return Ok(QueueDecisionApplyOutcome::Stale);
        }
        if !queue_proven_empty {
            sqlx::query(
                r"
                UPDATE notifications
                SET delivery_eligibility = 'deferred_queue_nonempty',
                    eligibility_library_revision = NULL
                WHERE user_id = $1 AND notification_scope = 'discovery'
                  AND delivery_eligibility <> 'expired'
                  AND dismissed_at IS NULL
                ",
            )
            .bind(user_id.into_inner())
            .execute(&mut *transaction)
            .await
            .map_err(store_sql)?;
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        let preferences = load_preferences(&mut transaction, user_id)
            .await?
            .unwrap_or_else(default_preferences);
        if !preferences.type_frequencies.discovery_enabled()
            || !delivery_window_open(&mut transaction, &preferences, now).await?
        {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        let match_frequency = preferences.type_frequencies.discovery_match;
        if match_frequency.is_enabled() {
            let capacity = delivery_capacity(&mut transaction, user_id, &preferences, now).await?;
            if capacity == 0
                || !notification_frequency_due(
                    &mut transaction,
                    user_id,
                    NotificationType::DiscoveryMatch,
                    match_frequency,
                    now,
                )
                .await?
            {
                transaction.commit().await.map_err(store_sql)?;
                return Ok(QueueDecisionApplyOutcome::Applied {
                    digest_needed: false,
                });
            }
            sqlx::query(
                r"
                WITH canonical_per_paper AS MATERIALIZED (
                    SELECT DISTINCT ON (entity_id) id, entity_id, created_at
                    FROM notifications
                    WHERE user_id = $1
                      AND notification_scope = 'discovery'
                      AND notification_type = 'discovery_match'
                      AND delivery_eligibility IN (
                          'deferred_unknown',
                          'deferred_queue_nonempty'
                      )
                      AND dismissed_at IS NULL
                      AND entity_id IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1
                          FROM notifications AS published
                          WHERE published.user_id = notifications.user_id
                            AND published.notification_scope = 'discovery'
                            AND published.notification_type = 'discovery_match'
                            AND published.entity_id = notifications.entity_id
                            AND published.delivery_eligibility = 'eligible'
                            AND published.dismissed_at IS NULL
                      )
                    ORDER BY entity_id, created_at, id
                ), candidate AS (
                    SELECT id FROM canonical_per_paper
                    ORDER BY created_at, id
                    LIMIT $4
                )
                UPDATE notifications AS notification
                SET delivery_eligibility = 'eligible',
                    eligibility_library_revision = $2, eligible_at = $3
                FROM candidate
                WHERE notification.id = candidate.id
                ",
            )
            .bind(user_id.into_inner())
            .bind(library_revision)
            .bind(now)
            .bind(i64::from(capacity))
            .execute(&mut *transaction)
            .await
            .map_err(store_sql)?;
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }

        let digest_frequency = preferences.type_frequencies.discovery_digest;
        if !digest_frequency.is_enabled()
            || !notification_frequency_due(
                &mut transaction,
                user_id,
                NotificationType::DiscoveryDigest,
                digest_frequency,
                now,
            )
            .await?
        {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        let has_redeferred_digest = sqlx::query_scalar::<_, bool>(
            r"
            SELECT EXISTS (
                SELECT 1 FROM notifications
                WHERE user_id = $1 AND notification_scope = 'discovery'
                  AND notification_type = 'discovery_digest'
                  AND delivery_eligibility = 'deferred_queue_nonempty'
                  AND dismissed_at IS NULL AND read_at IS NULL
                  AND (expires_at IS NULL OR expires_at > $2)
            )
            ",
        )
        .bind(user_id.into_inner())
        .bind(now)
        .fetch_one(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let capacity = delivery_capacity(&mut transaction, user_id, &preferences, now).await?;
        let digest_needed = has_redeferred_digest
            || (capacity > 0
                && sqlx::query_scalar::<_, bool>(
                    r"
                SELECT EXISTS (
                    SELECT 1 FROM notifications
                    WHERE user_id = $1 AND notification_scope = 'discovery'
                      AND notification_type = 'discovery_match'
                      AND delivery_eligibility IN (
                          'deferred_unknown',
                          'deferred_queue_nonempty'
                      )
                      AND dismissed_at IS NULL
                      AND (expires_at IS NULL OR expires_at > $2)
                )
                ",
                )
                .bind(user_id.into_inner())
                .bind(now)
                .fetch_one(&mut *transaction)
                .await
                .map_err(store_sql)?);
        transaction.commit().await.map_err(store_sql)?;
        Ok(QueueDecisionApplyOutcome::Applied { digest_needed })
    }

    #[allow(clippy::too_many_lines)]
    async fn build_digest(
        &self,
        user_id: AuthenticatedUserId,
        library_revision: i64,
        now: DateTime<Utc>,
    ) -> Result<QueueDecisionApplyOutcome, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let Some(status) = lock_account(&mut transaction, user_id).await? else {
            return Ok(QueueDecisionApplyOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(QueueDecisionApplyOutcome::Inactive(status));
        }
        let authority = queue_authority(&mut transaction, user_id).await?;
        if authority.0 != library_revision || authority.1 != 0 {
            return Ok(QueueDecisionApplyOutcome::Stale);
        }
        let preferences = load_preferences(&mut transaction, user_id)
            .await?
            .unwrap_or_else(default_preferences);
        if preferences.type_frequencies.discovery_match.is_enabled()
            || !preferences.type_frequencies.discovery_digest.is_enabled()
            || !delivery_window_open(&mut transaction, &preferences, now).await?
            || !notification_frequency_due(
                &mut transaction,
                user_id,
                NotificationType::DiscoveryDigest,
                preferences.type_frequencies.discovery_digest,
                now,
            )
            .await?
        {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        // A digest that was already eligible can be hidden by a later save. Its
        // source matches were deliberately dismissed when it was first built,
        // so restore that same bounded digest at the new empty-queue revision
        // before considering any new source rows.
        sqlx::query(
            r"
            UPDATE notifications
            SET delivery_eligibility = 'expired',
                eligibility_library_revision = NULL,
                dismissed_at = COALESCE(dismissed_at, $2)
            WHERE user_id = $1 AND notification_scope = 'discovery'
              AND notification_type = 'discovery_digest'
              AND delivery_eligibility = 'deferred_queue_nonempty'
              AND dismissed_at IS NULL AND read_at IS NOT NULL
            ",
        )
        .bind(user_id.into_inner())
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        let restored = sqlx::query(
            r"
            WITH candidate AS (
                SELECT id
                FROM notifications
                WHERE user_id = $1 AND notification_scope = 'discovery'
                  AND notification_type = 'discovery_digest'
                  AND delivery_eligibility = 'deferred_queue_nonempty'
                  AND dismissed_at IS NULL AND read_at IS NULL
                  AND (expires_at IS NULL OR expires_at > $3)
                ORDER BY created_at, id
                LIMIT 1
                FOR UPDATE
            )
            UPDATE notifications AS notification
            SET delivery_eligibility = 'eligible',
                eligibility_library_revision = $2
            FROM candidate
            WHERE notification.id = candidate.id
            ",
        )
        .bind(user_id.into_inner())
        .bind(library_revision)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        if restored.rows_affected() == 1 {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        let capacity = delivery_capacity(&mut transaction, user_id, &preferences, now).await?;
        if capacity == 0 {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        let batch_key = format!("digest-{}-{library_revision}", now.date_naive());
        let candidates = sqlx::query_as::<_, (Uuid, Uuid)>(
            r"
            SELECT id, entity_id
            FROM (
                SELECT DISTINCT ON (entity_id)
                       id, entity_id, created_at
                FROM notifications
                WHERE user_id = $1
                  AND notification_type = 'discovery_match'
                  AND notification_scope = 'discovery'
                  AND delivery_eligibility IN (
                      'deferred_unknown',
                      'deferred_queue_nonempty'
                  )
                  AND dismissed_at IS NULL
                  AND entity_id IS NOT NULL
                  AND (expires_at IS NULL OR expires_at > $3)
                ORDER BY entity_id, created_at, id
            ) AS canonical_per_paper
            ORDER BY created_at, id
            LIMIT $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(i64::from(capacity))
        .bind(now)
        .fetch_all(&mut *transaction)
        .await
        .map_err(store_sql)?;
        if candidates.is_empty() {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        let digest_id = Uuid::now_v7();
        let insert = sqlx::query(
            r"
            INSERT INTO notifications (
                id, user_id, notification_type, notification_scope,
                entity_type, entity_id, payload, batch_key,
                delivery_eligibility, eligibility_library_revision, eligible_at, expires_at
            ) VALUES (
                $1, $2, 'discovery_digest', 'discovery', 'digest', $1,
                jsonb_build_object('item_count', $3::integer), $4,
                'eligible', $5, $6, $6 + interval '30 days'
            )
            ON CONFLICT DO NOTHING
            ",
        )
        .bind(digest_id)
        .bind(user_id.into_inner())
        .bind(i32::try_from(candidates.len()).map_err(|_| EngagementStoreError::Inconsistent)?)
        .bind(&batch_key)
        .bind(library_revision)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        if insert.rows_affected() == 0 {
            transaction.commit().await.map_err(store_sql)?;
            return Ok(QueueDecisionApplyOutcome::Applied {
                digest_needed: false,
            });
        }
        for (ordinal, (_, paper_id)) in candidates.iter().enumerate() {
            sqlx::query(
                "INSERT INTO notification_digest_items (notification_id, paper_id, ordinal) VALUES ($1, $2, $3)",
            )
            .bind(digest_id)
            .bind(paper_id)
            .bind(i32::try_from(ordinal).map_err(|_| EngagementStoreError::Inconsistent)?)
            .execute(&mut *transaction)
            .await
            .map_err(store_sql)?;
        }
        let paper_ids = candidates
            .iter()
            .map(|(_, paper_id)| *paper_id)
            .collect::<Vec<_>>();
        sqlx::query(
            r"
            UPDATE notifications
            SET dismissed_at = $2
            WHERE user_id = $1
              AND notification_type = 'discovery_match'
              AND notification_scope = 'discovery'
              AND entity_id = ANY($3)
              AND dismissed_at IS NULL
            ",
        )
        .bind(user_id.into_inner())
        .bind(now)
        .bind(&paper_ids)
        .execute(&mut *transaction)
        .await
        .map_err(store_sql)?;
        transaction.commit().await.map_err(store_sql)?;
        Ok(QueueDecisionApplyOutcome::Applied {
            digest_needed: false,
        })
    }

    async fn expire_notifications(
        &self,
        user_id: AuthenticatedUserId,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError> {
        let result = sqlx::query(
            r"
            UPDATE notifications
            SET delivery_eligibility = 'expired'
            WHERE user_id = $1 AND expires_at <= $2
              AND delivery_eligibility <> 'expired'
            ",
        )
        .bind(user_id.into_inner())
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(store_sql)?;
        Ok(result.rows_affected())
    }

    async fn cleanup_retention(
        &self,
        cutoffs: EngagementRetentionCutoffs,
        limit: u32,
    ) -> Result<EngagementRetentionSummary, EngagementStoreError> {
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        let limit = i64::from(limit);

        let progress_operations = delete_expired_rows(
            &mut transaction,
            "reading_brief_progress_operations",
            cutoffs.operations_before,
            limit,
            "created_at",
            None,
        )
        .await?;
        let subscription_operations = delete_expired_rows(
            &mut transaction,
            "subscription_operations",
            cutoffs.operations_before,
            limit,
            "created_at",
            None,
        )
        .await?;
        let preference_operations = delete_expired_rows(
            &mut transaction,
            "notification_preference_operations",
            cutoffs.operations_before,
            limit,
            "created_at",
            None,
        )
        .await?;
        let notifications = delete_expired_rows(
            &mut transaction,
            "notifications",
            cutoffs.notifications_before,
            limit,
            "created_at",
            None,
        )
        .await?;
        let briefs = delete_expired_rows(
            &mut transaction,
            "reading_briefs",
            cutoffs.briefs_before,
            limit,
            "created_at",
            None,
        )
        .await?;
        let work_items = delete_expired_rows(
            &mut transaction,
            "notification_work_items",
            cutoffs.work_before,
            limit,
            "updated_at",
            Some(
                "(state IN ('complete', 'failed', 'queued') \
                 OR (state = 'leased' AND lease_expires_at <= statement_timestamp()))",
            ),
        )
        .await?;
        transaction.commit().await.map_err(store_sql)?;

        Ok(EngagementRetentionSummary {
            briefs,
            notifications,
            operations: progress_operations
                .saturating_add(subscription_operations)
                .saturating_add(preference_operations),
            work_items,
        })
    }

    async fn complete_work(
        &self,
        item_id: Uuid,
        worker_id: &str,
        now: DateTime<Utc>,
    ) -> Result<(), EngagementStoreError> {
        let result = sqlx::query(
            r"
            UPDATE notification_work_items
            SET state = 'complete', lease_owner = NULL, lease_expires_at = NULL,
                completed_at = $3, updated_at = $3, last_error_code = NULL
            WHERE id = $1 AND state = 'leased' AND lease_owner = $2
              AND lease_expires_at > $3
            ",
        )
        .bind(item_id)
        .bind(worker_id)
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(store_sql)?;
        if result.rows_affected() == 1 {
            Ok(())
        } else {
            Err(EngagementStoreError::Unavailable)
        }
    }

    async fn retry_work(
        &self,
        item: &NotificationWorkItem,
        worker_id: &str,
        error_code: &str,
        now: DateTime<Utc>,
    ) -> Result<WorkRetryDisposition, EngagementStoreError> {
        let terminal = item.attempt >= item.max_attempts;
        let result = sqlx::query(
            r"
            UPDATE notification_work_items
            SET state = CASE WHEN $4 THEN 'failed' ELSE 'queued' END,
                available_at = CASE WHEN $4 THEN available_at ELSE $3 + interval '30 seconds' END,
                lease_owner = NULL, lease_expires_at = NULL,
                last_error_code = $5, updated_at = $3,
                completed_at = CASE WHEN $4 THEN $3 ELSE NULL END
            WHERE id = $1 AND state = 'leased' AND lease_owner = $2
              AND lease_expires_at > $3
            ",
        )
        .bind(item.id)
        .bind(worker_id)
        .bind(now)
        .bind(terminal)
        .bind(error_code)
        .execute(&self.pool)
        .await
        .map_err(store_sql)?;
        if result.rows_affected() == 1 {
            Ok(if terminal {
                WorkRetryDisposition::Failed
            } else {
                WorkRetryDisposition::Queued
            })
        } else {
            Err(EngagementStoreError::Unavailable)
        }
    }
}

async fn delete_expired_rows(
    transaction: &mut Transaction<'_, Postgres>,
    table: &str,
    cutoff: DateTime<Utc>,
    limit: i64,
    timestamp_column: &str,
    predicate: Option<&str>,
) -> Result<u64, EngagementStoreError> {
    // Every identifier and optional predicate is selected from this private,
    // closed call site; no request value can reach the SQL text.
    let predicate = predicate.map_or_else(String::new, |value| format!(" AND {value}"));
    let statement = format!(
        "WITH victims AS (\
             SELECT ctid FROM {table} \
             WHERE {timestamp_column} < $1{predicate} \
             ORDER BY {timestamp_column}, ctid \
             LIMIT $2 FOR UPDATE SKIP LOCKED\
         ) \
         DELETE FROM {table} WHERE ctid IN (SELECT ctid FROM victims)"
    );
    sqlx::query(&statement)
        .bind(cutoff)
        .bind(limit)
        .execute(&mut **transaction)
        .await
        .map(|result| result.rows_affected())
        .map_err(store_sql)
}

#[derive(Debug, FromRow)]
struct BriefRow {
    id: Uuid,
    source_mode: String,
    recommendation_mode: Option<String>,
    library_revision: i64,
    recommendation_batch_id: Option<Uuid>,
    local_date: NaiveDate,
    position: i32,
    progress_revision: i64,
    status: String,
    completed_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct BriefItemRow {
    ordinal: i32,
    source: String,
    reason_codes: Vec<String>,
    #[sqlx(flatten)]
    paper: PaperSummaryRow,
}

#[derive(Debug, FromRow)]
struct SubscriptionRow {
    id: Uuid,
    kind: String,
    key: String,
    label: String,
    query_definition: Option<Value>,
    frequency: String,
    last_evaluated_at: Option<DateTime<Utc>>,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, FromRow)]
#[allow(clippy::struct_excessive_bools)]
struct PreferenceRow {
    discovery_frequency: String,
    discovery_match_frequency: String,
    discovery_digest_frequency: String,
    user_selected_reminder_frequency: String,
    active_paper_version_frequency: String,
    sync_failure_frequency: String,
    quiet_hours_start: Option<NaiveTime>,
    quiet_hours_end: Option<NaiveTime>,
    timezone: String,
    in_app_enabled: bool,
    push_enabled: bool,
    email_enabled: bool,
    global_pause: bool,
    active_updates_enabled: bool,
    daily_budget: i32,
    revision: i64,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct NotificationRow {
    id: Uuid,
    notification_type: String,
    notification_scope: String,
    entity_type: String,
    entity_id: Option<Uuid>,
    payload: Value,
    delivery_eligibility: String,
    eligibility_library_revision: Option<i64>,
    created_at: DateTime<Utc>,
    read_at: Option<DateTime<Utc>>,
    expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, FromRow)]
struct WorkRow {
    id: Uuid,
    user_id: Uuid,
    work_kind: String,
    subscription_id: Option<Uuid>,
    window_key: String,
    attempts: i32,
    max_attempts: i32,
}

async fn schedule_account_work(
    transaction: &mut Transaction<'_, Postgres>,
    now: DateTime<Utc>,
    limit: u32,
    kind: NotificationWorkKind,
    window_key: &str,
    candidate_query: &str,
) -> Result<u64, EngagementStoreError> {
    let statement = format!(
        r"
        WITH candidate AS ({candidate_query})
        INSERT INTO notification_work_items (
            id, user_id, work_kind, subscription_id, window_key,
            payload, state, available_at
        )
        SELECT gen_random_uuid(), candidate.user_id, $3, NULL, $4,
               '{{}}'::jsonb, 'queued', $1
        FROM candidate
        ON CONFLICT DO NOTHING
        "
    );
    sqlx::query(&statement)
        .bind(now)
        .bind(i64::from(limit))
        .bind(kind.as_str())
        .bind(window_key)
        .execute(&mut **transaction)
        .await
        .map_err(store_sql)
        .map(|result| result.rows_affected())
}

/// Checks the rolling delivery cadence for one canonical notification type.
/// Global pause, channel availability, quiet hours, and budget are enforced by
/// `delivery_capacity`; this helper deliberately owns only per-type cadence.
async fn notification_frequency_due(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    notification_type: NotificationType,
    frequency: SubscriptionFrequency,
    now: DateTime<Utc>,
) -> Result<bool, EngagementStoreError> {
    let interval = match frequency {
        SubscriptionFrequency::Immediate => return Ok(true),
        SubscriptionFrequency::Daily => chrono::Duration::days(1),
        SubscriptionFrequency::Weekly => chrono::Duration::days(7),
        SubscriptionFrequency::Off => return Ok(false),
    };
    let last_eligible = sqlx::query_scalar::<_, Option<DateTime<Utc>>>(
        r"
        SELECT max(eligible_at)
        FROM notifications
        WHERE user_id = $1 AND notification_type = $2
          AND eligible_at IS NOT NULL
        ",
    )
    .bind(user_id.into_inner())
    .bind(notification_type.as_str())
    .fetch_one(&mut **transaction)
    .await
    .map_err(store_sql)?;
    Ok(last_eligible.is_none_or(|eligible_at| eligible_at <= now - interval))
}

async fn delivery_capacity(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    preferences: &NotificationPreferences,
    now: DateTime<Utc>,
) -> Result<u16, EngagementStoreError> {
    if !delivery_window_open(transaction, preferences, now).await? {
        return Ok(0);
    }
    let delivered = sqlx::query_scalar::<_, i64>(
        r"
        SELECT count(*)
        FROM notifications
        WHERE user_id = $1 AND eligible_at IS NOT NULL
          AND (eligible_at AT TIME ZONE $2)::date = ($3::timestamptz AT TIME ZONE $2)::date
        ",
    )
    .bind(user_id.into_inner())
    .bind(&preferences.timezone)
    .bind(now)
    .fetch_one(&mut **transaction)
    .await
    .map_err(store_sql)?;
    let delivered = u16::try_from(delivered).unwrap_or(u16::MAX);
    Ok(preferences.daily_budget.saturating_sub(delivered))
}

async fn delivery_window_open(
    transaction: &mut Transaction<'_, Postgres>,
    preferences: &NotificationPreferences,
    now: DateTime<Utc>,
) -> Result<bool, EngagementStoreError> {
    if !preferences.in_app_enabled || preferences.global_pause {
        return Ok(false);
    }
    let local_time =
        sqlx::query_scalar::<_, NaiveTime>("SELECT ($1::timestamptz AT TIME ZONE $2)::time")
            .bind(now)
            .bind(&preferences.timezone)
            .fetch_one(&mut **transaction)
            .await
            .map_err(store_sql)?;
    if matches!(
        (preferences.quiet_hours_start, preferences.quiet_hours_end),
        (Some(start), Some(end)) if time_in_window(local_time, start, end)
    ) {
        return Ok(false);
    }
    Ok(true)
}

fn time_in_window(value: NaiveTime, start: NaiveTime, end: NaiveTime) -> bool {
    if start < end {
        value >= start && value < end
    } else {
        value >= start || value < end
    }
}

async fn lock_account(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<AccountStatus>, EngagementStoreError> {
    let status =
        sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1 FOR UPDATE")
            .bind(user_id.into_inner())
            .fetch_optional(&mut **transaction)
            .await
            .map_err(store_sql)?;
    status.map(|value| account_status_value(&value)).transpose()
}

async fn account_status(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<AccountStatus>, EngagementStoreError> {
    let status = sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1")
        .bind(user_id.into_inner())
        .fetch_optional(&mut **transaction)
        .await
        .map_err(store_sql)?;
    status.map(|value| account_status_value(&value)).transpose()
}

fn account_status_value(value: &str) -> Result<AccountStatus, EngagementStoreError> {
    AccountStatus::from_str(value).map_err(|_| EngagementStoreError::Inconsistent)
}

async fn queue_authority(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<(i64, i64), EngagementStoreError> {
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (
            user_id, current_revision, purged_through_revision, updated_at
        ) VALUES ($1, 0, 0, statement_timestamp())
        ON CONFLICT (user_id) DO NOTHING
        ",
    )
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await
    .map_err(store_sql)?;
    let revision = sqlx::query_scalar::<_, i64>(
        "SELECT current_revision FROM library_sync_metadata WHERE user_id = $1 FOR UPDATE",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await
    .map_err(store_sql)?;
    let count = sqlx::query_scalar::<_, i64>(
        r"
        SELECT count(*) FROM user_paper_library
        WHERE user_id = $1 AND removed_at IS NULL
          AND state IN ('to_read', 'inbox', 'read_next', 'reading')
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await
    .map_err(store_sql)?;
    Ok((revision, count))
}

fn brief_authority_shape_matches(
    status: BriefStatus,
    mode: BriefMode,
    recommendation_mode: Option<RecommendationMode>,
    recommendation_batch_id: Option<Uuid>,
    library_revision: i64,
    authority: (i64, i64),
) -> bool {
    status == BriefStatus::Current
        && library_revision == authority.0
        && match mode {
            BriefMode::Queue => {
                authority.1 > 0
                    && recommendation_mode.is_none()
                    && recommendation_batch_id.is_none()
            }
            BriefMode::Discovery => {
                authority.1 == 0
                    && recommendation_mode.is_some()
                    && recommendation_batch_id.is_some()
            }
        }
}

async fn brief_has_current_authority(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    brief: &ReadingBrief,
) -> Result<bool, EngagementStoreError> {
    if brief.status != BriefStatus::Current {
        return Ok(false);
    }
    brief_has_replay_authority(transaction, user_id, brief).await
}

async fn brief_has_replay_authority(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    brief: &ReadingBrief,
) -> Result<bool, EngagementStoreError> {
    let authority = queue_authority(transaction, user_id).await?;
    if !brief_authority_shape_matches(
        BriefStatus::Current,
        brief.mode,
        brief.recommendation_mode,
        brief.recommendation_batch_id,
        brief.library_revision,
        authority,
    ) {
        return Ok(false);
    }
    let (Some(batch_id), Some(mode)) = (brief.recommendation_batch_id, brief.recommendation_mode)
    else {
        return Ok(matches!(brief.mode, BriefMode::Queue));
    };
    recommendation_batch_is_valid(transaction, user_id, batch_id, brief.library_revision, mode)
        .await
}

async fn recommendation_batch_is_valid(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    batch_id: Uuid,
    library_revision: i64,
    mode: RecommendationMode,
) -> Result<bool, EngagementStoreError> {
    sqlx::query_scalar::<_, bool>(
        r"
        SELECT EXISTS (
            SELECT 1
            FROM recommendation_batches
            WHERE id = $1 AND user_id = $2
              AND library_revision = $3 AND mode = $4
              AND queue_proven_empty IS TRUE
              AND status IN ('ready', 'served')
              AND expires_at > statement_timestamp()
        )
        ",
    )
    .bind(batch_id)
    .bind(user_id.into_inner())
    .bind(library_revision)
    .bind(mode.as_str())
    .fetch_one(&mut **transaction)
    .await
    .map_err(store_sql)
}

async fn load_brief(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    brief_id: Uuid,
) -> Result<Option<ReadingBrief>, EngagementStoreError> {
    let row = sqlx::query_as::<_, BriefRow>(
        r"
        SELECT id, source_mode, recommendation_mode, library_revision,
               recommendation_batch_id, local_date, position, progress_revision,
               status, completed_at, created_at, updated_at
        FROM reading_briefs WHERE user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(brief_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(store_sql)?;
    let Some(row) = row else {
        return Ok(None);
    };
    let item_rows = sqlx::query_as::<_, BriefItemRow>(
        r"
        SELECT item.ordinal, item.source, item.reason_codes,
               paper.id, paper.arxiv_base_id, paper.arxiv_version, paper.title,
               paper.abstract AS abstract_text, paper.authors, paper.primary_category,
               paper.categories, paper.published_at, paper.updated_at, paper.abs_url,
               paper.pdf_url, processing.metadata_ready, processing.introduction_ready,
               processing.chat_ready, processing.connections_ready
        FROM reading_brief_items AS item
        JOIN papers AS paper ON paper.id = item.paper_id
        JOIN paper_processing AS processing ON processing.paper_id = paper.id
        WHERE item.user_id = $1 AND item.brief_id = $2
        ORDER BY item.ordinal
        ",
    )
    .bind(user_id.into_inner())
    .bind(brief_id)
    .fetch_all(&mut **transaction)
    .await
    .map_err(store_sql)?;
    let items = item_rows
        .into_iter()
        .map(|item| {
            Ok(BriefItem {
                ordinal: u16::try_from(item.ordinal)
                    .map_err(|_| EngagementStoreError::Inconsistent)?,
                paper: PaperSummary::try_from(item.paper)
                    .map_err(|_| EngagementStoreError::Inconsistent)?,
                source: parse_feed_source(&item.source)?,
                reason_codes: parse_reason_codes(item.reason_codes)?,
            })
        })
        .collect::<Result<Vec<_>, EngagementStoreError>>()?;
    Ok(Some(ReadingBrief {
        id: row.id,
        mode: parse_brief_mode(&row.source_mode)?,
        recommendation_mode: row
            .recommendation_mode
            .as_deref()
            .map(parse_recommendation_mode)
            .transpose()?,
        library_revision: row.library_revision,
        recommendation_batch_id: row.recommendation_batch_id,
        local_date: row.local_date,
        position: u16::try_from(row.position).map_err(|_| EngagementStoreError::Inconsistent)?,
        progress_revision: row.progress_revision,
        status: parse_brief_status(&row.status)?,
        items,
        completed_at: row.completed_at,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }))
}

/// A subscription mutation wins over every pending delivery derived from an
/// older revision. Digest membership stores paper identities rather than raw
/// subscription data, so any digest containing one of those papers is hidden
/// as a whole instead of risking delivery of a withdrawn match.
async fn invalidate_subscription_notifications(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    subscription_id: Uuid,
) -> Result<(), EngagementStoreError> {
    sqlx::query(
        r"
        WITH subscription_matches AS MATERIALIZED (
            SELECT id, entity_id AS paper_id
            FROM notifications
            WHERE user_id = $1
              AND notification_scope = 'discovery'
              AND notification_type = 'discovery_match'
              AND payload ->> 'subscription_id' = $2::uuid::text
        ), affected_digests AS (
            SELECT DISTINCT digest.id
            FROM notifications AS digest
            JOIN notification_digest_items AS item
              ON item.notification_id = digest.id
            JOIN subscription_matches AS matched
              ON matched.paper_id = item.paper_id
            WHERE digest.user_id = $1
              AND digest.notification_scope = 'discovery'
              AND digest.notification_type = 'discovery_digest'
        ), affected AS (
            SELECT id FROM subscription_matches
            UNION
            SELECT id FROM affected_digests
        )
        UPDATE notifications AS notification
        SET delivery_eligibility = 'expired',
            eligibility_library_revision = NULL,
            dismissed_at = COALESCE(
                notification.dismissed_at,
                statement_timestamp()
            )
        FROM affected
        WHERE notification.id = affected.id
          AND notification.user_id = $1
        ",
    )
    .bind(user_id.into_inner())
    .bind(subscription_id)
    .execute(&mut **transaction)
    .await
    .map_err(store_sql)?;
    Ok(())
}

async fn load_subscription(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
) -> Result<Option<Subscription>, EngagementStoreError> {
    sqlx::query_as::<_, SubscriptionRow>(
        r"
        SELECT id, kind, key, label, query_definition, frequency,
               last_evaluated_at, revision, deleted_at, created_at, updated_at
        FROM subscriptions WHERE user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(store_sql)?
    .map(subscription)
    .transpose()
}

fn subscription(row: SubscriptionRow) -> Result<Subscription, EngagementStoreError> {
    Ok(Subscription {
        id: row.id,
        kind: parse_subscription_kind(&row.kind)?,
        key: row.key,
        label: row.label,
        query_definition: row.query_definition,
        frequency: parse_frequency(&row.frequency)?,
        last_evaluated_at: row.last_evaluated_at,
        revision: row.revision,
        deleted_at: row.deleted_at,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

async fn next_subscription_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, EngagementStoreError> {
    sqlx::query_scalar(
        "SELECT COALESCE(MAX(revision), 0) + 1 FROM subscriptions WHERE user_id = $1",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await
    .map_err(store_sql)
}

async fn load_preferences(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<NotificationPreferences>, EngagementStoreError> {
    sqlx::query_as::<_, PreferenceRow>(
        r"
        SELECT discovery_frequency, discovery_match_frequency,
               discovery_digest_frequency, user_selected_reminder_frequency,
               active_paper_version_frequency,
               sync_failure_frequency, quiet_hours_start, quiet_hours_end,
               timezone, in_app_enabled, push_enabled, email_enabled,
               global_pause, active_updates_enabled, daily_budget, revision, updated_at
        FROM notification_preferences WHERE user_id = $1
        ",
    )
    .bind(user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await
    .map_err(store_sql)?
    .map(preferences_from_row)
    .transpose()
}

fn preferences_from_row(
    row: PreferenceRow,
) -> Result<NotificationPreferences, EngagementStoreError> {
    let discovery_frequency = parse_frequency(&row.discovery_frequency)?;
    let type_frequencies = NotificationTypeFrequencies {
        discovery_match: parse_frequency(&row.discovery_match_frequency)?,
        discovery_digest: parse_frequency(&row.discovery_digest_frequency)?,
        user_selected_reminder: parse_frequency(&row.user_selected_reminder_frequency)?,
        active_paper_version: parse_frequency(&row.active_paper_version_frequency)?,
        sync_failure: parse_frequency(&row.sync_failure_frequency)?,
    };
    if !type_frequencies.has_unambiguous_discovery_projection()
        || discovery_frequency != type_frequencies.legacy_discovery_frequency()
        || row.active_updates_enabled != type_frequencies.legacy_active_updates_enabled()
    {
        return Err(EngagementStoreError::Inconsistent);
    }
    Ok(NotificationPreferences {
        discovery_frequency,
        type_frequencies,
        quiet_hours_start: row.quiet_hours_start,
        quiet_hours_end: row.quiet_hours_end,
        timezone: row.timezone,
        in_app_enabled: row.in_app_enabled,
        push_enabled: row.push_enabled,
        email_enabled: row.email_enabled,
        global_pause: row.global_pause,
        active_updates_enabled: row.active_updates_enabled,
        daily_budget: u16::try_from(row.daily_budget)
            .map_err(|_| EngagementStoreError::Inconsistent)?,
        revision: row.revision,
        updated_at: row.updated_at,
    })
}

fn default_preferences() -> NotificationPreferences {
    let type_frequencies = NotificationTypeFrequencies::default();
    NotificationPreferences {
        discovery_frequency: type_frequencies.legacy_discovery_frequency(),
        type_frequencies,
        quiet_hours_start: None,
        quiet_hours_end: None,
        timezone: "UTC".to_owned(),
        in_app_enabled: true,
        push_enabled: false,
        email_enabled: false,
        global_pause: false,
        active_updates_enabled: type_frequencies.legacy_active_updates_enabled(),
        daily_budget: 5,
        revision: 0,
        updated_at: DateTime::<Utc>::UNIX_EPOCH,
    }
}

async fn load_notification_papers(
    transaction: &mut Transaction<'_, Postgres>,
    notification_id: Uuid,
    entity_id: Option<Uuid>,
) -> Result<Vec<PaperSummary>, EngagementStoreError> {
    let rows = sqlx::query_as::<_, PaperSummaryRow>(
        r"
        SELECT paper.id, paper.arxiv_base_id, paper.arxiv_version, paper.title,
               paper.abstract AS abstract_text, paper.authors, paper.primary_category,
               paper.categories, paper.published_at, paper.updated_at, paper.abs_url,
               paper.pdf_url, processing.metadata_ready, processing.introduction_ready,
               processing.chat_ready, processing.connections_ready
        FROM papers AS paper
        JOIN paper_processing AS processing ON processing.paper_id = paper.id
        WHERE paper.id IN (
            SELECT paper_id FROM notification_digest_items WHERE notification_id = $1
            UNION ALL
            SELECT $2::uuid WHERE $2 IS NOT NULL
        )
        ORDER BY paper.published_at DESC, paper.id DESC
        ",
    )
    .bind(notification_id)
    .bind(entity_id)
    .fetch_all(&mut **transaction)
    .await
    .map_err(store_sql)?;
    rows.into_iter()
        .map(|row| PaperSummary::try_from(row).map_err(|_| EngagementStoreError::Inconsistent))
        .collect()
}

fn notification(
    row: NotificationRow,
    papers: Vec<PaperSummary>,
) -> Result<Notification, EngagementStoreError> {
    Ok(Notification {
        id: row.id,
        notification_type: parse_notification_type(&row.notification_type)?,
        scope: parse_notification_scope(&row.notification_scope)?,
        entity_type: parse_notification_entity_type(&row.entity_type)?,
        entity_id: row.entity_id,
        payload: row.payload,
        delivery_eligibility: parse_eligibility(&row.delivery_eligibility)?,
        eligibility_library_revision: row.eligibility_library_revision,
        created_at: row.created_at,
        read_at: row.read_at,
        expires_at: row.expires_at,
        papers,
    })
}

fn work_item(row: WorkRow) -> Result<NotificationWorkItem, EngagementStoreError> {
    Ok(NotificationWorkItem {
        id: row.id,
        user_id: AuthenticatedUserId::new(row.user_id),
        kind: parse_work_kind(&row.work_kind)?,
        subscription_id: row.subscription_id,
        window_key: row.window_key,
        attempt: u16::try_from(row.attempts).map_err(|_| EngagementStoreError::Inconsistent)?,
        max_attempts: u16::try_from(row.max_attempts)
            .map_err(|_| EngagementStoreError::Inconsistent)?,
    })
}

// Each closed subscription kind owns one bounded SQL shape; keeping the dispatch
// together makes the account exclusion and result cap reviewable as one policy.
#[allow(clippy::too_many_lines)]
async fn matching_papers(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    subscription: &Subscription,
    since: DateTime<Utc>,
    limit: i64,
) -> Result<Vec<Uuid>, EngagementStoreError> {
    let rows = match subscription.kind {
        SubscriptionKind::Category => sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT paper.id FROM papers AS paper
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE processing.metadata_ready
              AND paper.published_at > $2
              AND (
                lower(paper.primary_category) = $1
                OR EXISTS (
                    SELECT 1 FROM unnest(paper.categories) AS category(value)
                    WHERE lower(category.value) = $1
                )
              )
              AND NOT EXISTS (
                  SELECT 1 FROM user_paper_library AS library
                  WHERE library.user_id = $3 AND library.paper_id = paper.id
                    AND library.removed_at IS NULL
              )
            ORDER BY paper.published_at DESC, paper.id DESC LIMIT $4
            ",
        )
        .bind(&subscription.key)
        .bind(since)
        .bind(user_id.into_inner())
        .bind(limit)
        .fetch_all(&mut **transaction)
        .await,
        SubscriptionKind::Author => sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT paper.id FROM papers AS paper
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE processing.metadata_ready AND paper.published_at > $2
              AND EXISTS (
                  SELECT 1 FROM jsonb_array_elements(paper.authors) AS author(value)
                  WHERE lower(btrim(coalesce(
                      author.value ->> 'name', trim(both chr(34) from author.value::text)
                  ))) = $1
              )
              AND NOT EXISTS (
                  SELECT 1 FROM user_paper_library AS library
                  WHERE library.user_id = $3 AND library.paper_id = paper.id
                    AND library.removed_at IS NULL
              )
            ORDER BY paper.published_at DESC, paper.id DESC LIMIT $4
            ",
        )
        .bind(&subscription.key)
        .bind(since)
        .bind(user_id.into_inner())
        .bind(limit)
        .fetch_all(&mut **transaction)
        .await,
        SubscriptionKind::Topic => sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT paper.id FROM papers AS paper
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE processing.metadata_ready AND paper.published_at > $2
              AND paper.search_document @@ plainto_tsquery('english'::regconfig, $1)
              AND NOT EXISTS (
                  SELECT 1 FROM user_paper_library AS library
                  WHERE library.user_id = $3 AND library.paper_id = paper.id
                    AND library.removed_at IS NULL
              )
            ORDER BY paper.published_at DESC, paper.id DESC LIMIT $4
            ",
        )
        .bind(&subscription.key)
        .bind(since)
        .bind(user_id.into_inner())
        .bind(limit)
        .fetch_all(&mut **transaction)
        .await,
        SubscriptionKind::SavedQuery => sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT paper.id
            FROM saved_searches AS search
            JOIN papers AS paper ON (
                paper.search_document @@ websearch_to_tsquery(
                    'english'::regconfig, search.normalized_query
                )
            )
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE search.user_id = $1 AND search.id::text = $2
              AND processing.metadata_ready AND paper.published_at > $3
              AND (cardinality(search.categories) = 0 OR paper.categories && search.categories)
              AND (
                  cardinality(search.topics) = 0
                  OR EXISTS (
                      SELECT 1
                      FROM unnest(search.topics) AS requested_topic(value)
                      WHERE paper.search_document @@ websearch_to_tsquery(
                          'english'::regconfig,
                          requested_topic.value
                      )
                  )
              )
              AND (search.published_after IS NULL OR paper.published_at::date >= search.published_after)
              AND (search.published_before IS NULL OR paper.published_at::date <= search.published_before)
              AND NOT EXISTS (
                  SELECT 1 FROM user_paper_library AS library
                  WHERE library.user_id = $1 AND library.paper_id = paper.id
                    AND library.removed_at IS NULL
              )
            ORDER BY paper.published_at DESC, paper.id DESC LIMIT $4
            ",
        )
        .bind(user_id.into_inner())
        .bind(&subscription.key)
        .bind(since)
        .bind(limit)
        .fetch_all(&mut **transaction)
        .await,
    };
    rows.map_err(store_sql)
}

const fn subscription_reason(kind: SubscriptionKind) -> &'static str {
    match kind {
        SubscriptionKind::Topic => "followed_topic",
        SubscriptionKind::Category => "followed_category",
        SubscriptionKind::Author => "followed_author",
        SubscriptionKind::SavedQuery => "saved_query_match",
    }
}

fn unique_violation(error_value: &sqlx::Error) -> bool {
    error_value
        .as_database_error()
        .and_then(sqlx::error::DatabaseError::code)
        .as_deref()
        == Some("23505")
}

fn store_sql(_error_value: sqlx::Error) -> EngagementStoreError {
    EngagementStoreError::Unavailable
}

fn parse_brief_mode(value: &str) -> Result<BriefMode, EngagementStoreError> {
    match value {
        "queue" => Ok(BriefMode::Queue),
        "discovery" => Ok(BriefMode::Discovery),
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

fn parse_brief_status(value: &str) -> Result<BriefStatus, EngagementStoreError> {
    match value {
        "current" => Ok(BriefStatus::Current),
        "complete" => Ok(BriefStatus::Complete),
        "superseded" => Ok(BriefStatus::Superseded),
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

fn parse_recommendation_mode(value: &str) -> Result<RecommendationMode, EngagementStoreError> {
    match value {
        "recent" => Ok(RecommendationMode::Recent),
        "following" => Ok(RecommendationMode::Following),
        "for_you" => Ok(RecommendationMode::ForYou),
        "explore" => Ok(RecommendationMode::Explore),
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

const fn feed_source_str(value: FeedItemSource) -> &'static str {
    match value {
        FeedItemSource::ToRead => "to_read",
        FeedItemSource::DiscoveryV1 => "discovery_v1",
        FeedItemSource::RecentV1 => "recent_v1",
        FeedItemSource::FollowingV1 => "following_v1",
        FeedItemSource::ForYouV1 => "for_you_v1",
        FeedItemSource::ExploreV1 => "explore_v1",
    }
}

fn parse_feed_source(value: &str) -> Result<FeedItemSource, EngagementStoreError> {
    match value {
        "to_read" => Ok(FeedItemSource::ToRead),
        "discovery_v1" => Ok(FeedItemSource::DiscoveryV1),
        "recent_v1" => Ok(FeedItemSource::RecentV1),
        "following_v1" => Ok(FeedItemSource::FollowingV1),
        "for_you_v1" => Ok(FeedItemSource::ForYouV1),
        "explore_v1" => Ok(FeedItemSource::ExploreV1),
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

fn parse_reason_codes(
    values: Vec<String>,
) -> Result<Vec<RecommendationReasonCode>, EngagementStoreError> {
    values
        .into_iter()
        .map(|value| {
            RecommendationReasonCode::parse(&value).ok_or(EngagementStoreError::Inconsistent)
        })
        .collect()
}

fn parse_subscription_kind(value: &str) -> Result<SubscriptionKind, EngagementStoreError> {
    match value {
        "topic" => Ok(SubscriptionKind::Topic),
        "category" => Ok(SubscriptionKind::Category),
        "author" => Ok(SubscriptionKind::Author),
        "saved_query" => Ok(SubscriptionKind::SavedQuery),
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

fn parse_frequency(value: &str) -> Result<SubscriptionFrequency, EngagementStoreError> {
    SubscriptionFrequency::parse(value).ok_or(EngagementStoreError::Inconsistent)
}

fn parse_notification_type(value: &str) -> Result<NotificationType, EngagementStoreError> {
    NotificationType::parse(value).ok_or(EngagementStoreError::Inconsistent)
}

fn parse_notification_scope(value: &str) -> Result<NotificationScope, EngagementStoreError> {
    match value {
        "queue_owned" => Ok(NotificationScope::QueueOwned),
        "discovery" => Ok(NotificationScope::Discovery),
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

fn parse_notification_entity_type(
    value: &str,
) -> Result<NotificationEntityType, EngagementStoreError> {
    NotificationEntityType::parse(value).ok_or(EngagementStoreError::Inconsistent)
}

fn parse_eligibility(value: &str) -> Result<NotificationDeliveryEligibility, EngagementStoreError> {
    match value {
        "eligible" => Ok(NotificationDeliveryEligibility::Eligible),
        "deferred_queue_nonempty" => Ok(NotificationDeliveryEligibility::DeferredQueueNonempty),
        "deferred_unknown" => Ok(NotificationDeliveryEligibility::DeferredUnknown),
        "expired" => Ok(NotificationDeliveryEligibility::Expired),
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

fn parse_work_kind(value: &str) -> Result<NotificationWorkKind, EngagementStoreError> {
    match value {
        "evaluate_subscriptions" => Ok(NotificationWorkKind::EvaluateSubscriptions),
        "evaluate_reminders" => Ok(NotificationWorkKind::EvaluateReminders),
        "evaluate_active_papers" => Ok(NotificationWorkKind::EvaluateActivePapers),
        "build_notification_digest" => Ok(NotificationWorkKind::BuildNotificationDigest),
        "expire_notifications" => Ok(NotificationWorkKind::ExpireNotifications),
        "recheck_notification_queue_eligibility" => {
            Ok(NotificationWorkKind::RecheckNotificationQueueEligibility)
        }
        _ => Err(EngagementStoreError::Inconsistent),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_preference_row() -> PreferenceRow {
        PreferenceRow {
            discovery_frequency: "daily".to_owned(),
            discovery_match_frequency: "off".to_owned(),
            discovery_digest_frequency: "daily".to_owned(),
            user_selected_reminder_frequency: "immediate".to_owned(),
            active_paper_version_frequency: "off".to_owned(),
            sync_failure_frequency: "immediate".to_owned(),
            quiet_hours_start: None,
            quiet_hours_end: None,
            timezone: "UTC".to_owned(),
            in_app_enabled: true,
            push_enabled: false,
            email_enabled: false,
            global_pause: false,
            active_updates_enabled: false,
            daily_budget: 5,
            revision: 1,
            updated_at: DateTime::<Utc>::UNIX_EPOCH,
        }
    }

    fn frequency_allowlist_after<'a>(migration: &'a str, column: &str) -> Vec<&'a str> {
        let marker = format!("{column} text NOT NULL DEFAULT");
        migration
            .split_once(&marker)
            .and_then(|(_, remainder)| remainder.split_once(&format!("{column} IN (")))
            .and_then(|(_, remainder)| remainder.split_once(')'))
            .map_or_else(
                || panic!("missing frequency allowlist for {column}"),
                |(allowlist, _)| {
                    allowlist
                        .split(',')
                        .map(|value| value.trim().trim_matches('\''))
                        .collect()
                },
            )
    }

    fn reason_allowlist_after<'a>(migration: &'a str, constraint: &str) -> Vec<&'a str> {
        migration
            .split_once(constraint)
            .and_then(|(_, remainder)| remainder.split_once("reason_codes <@ ARRAY["))
            .and_then(|(_, remainder)| remainder.split_once("]::text[]"))
            .map_or_else(
                || panic!("missing reason allowlist for {constraint}"),
                |(allowlist, _)| {
                    allowlist
                        .split(',')
                        .map(|value| value.trim().trim_matches('\''))
                        .collect()
                },
            )
    }

    fn text_allowlist_after<'a>(migration: &'a str, marker: &str) -> Vec<&'a str> {
        migration
            .split_once(marker)
            .and_then(|(_, remainder)| remainder.split_once(')'))
            .map_or_else(
                || panic!("missing allowlist after {marker}"),
                |(allowlist, _)| {
                    allowlist
                        .split(',')
                        .map(|value| value.trim().trim_matches('\''))
                        .collect()
                },
            )
    }

    #[test]
    fn quiet_window_handles_daytime_overnight_and_all_day_ranges() {
        let at = |hour, minute| NaiveTime::from_hms_opt(hour, minute, 0).unwrap();
        assert!(time_in_window(at(12, 0), at(9, 0), at(17, 0)));
        assert!(!time_in_window(at(18, 0), at(9, 0), at(17, 0)));
        assert!(time_in_window(at(23, 0), at(22, 0), at(7, 0)));
        assert!(time_in_window(at(6, 0), at(22, 0), at(7, 0)));
        assert!(!time_in_window(at(12, 0), at(22, 0), at(7, 0)));
        assert!(time_in_window(at(12, 0), at(0, 0), at(0, 0)));
    }

    #[test]
    fn persisted_reason_and_entity_vocabularies_fail_closed() {
        assert_eq!(
            parse_reason_codes(vec!["recent_category".to_owned()]).unwrap(),
            vec![RecommendationReasonCode::RecentCategory]
        );
        assert!(parse_reason_codes(vec!["unknown".to_owned()]).is_err());
        assert_eq!(
            parse_notification_entity_type("digest").unwrap(),
            NotificationEntityType::Digest
        );
        assert!(parse_notification_entity_type("unknown").is_err());
    }

    #[test]
    fn persisted_notification_frequencies_fail_closed_when_unknown_or_inconsistent() {
        let decoded = preferences_from_row(valid_preference_row()).unwrap();
        assert_eq!(
            decoded.type_frequencies,
            NotificationTypeFrequencies::default()
        );

        let corruptions: [fn(&mut PreferenceRow); 5] = [
            |row: &mut PreferenceRow| row.discovery_match_frequency = "sometimes".to_owned(),
            |row: &mut PreferenceRow| row.discovery_digest_frequency = "sometimes".to_owned(),
            |row: &mut PreferenceRow| {
                row.user_selected_reminder_frequency = "sometimes".to_owned();
            },
            |row: &mut PreferenceRow| {
                row.active_paper_version_frequency = "sometimes".to_owned();
            },
            |row: &mut PreferenceRow| row.sync_failure_frequency = "sometimes".to_owned(),
        ];
        for corrupt in corruptions {
            let mut row = valid_preference_row();
            corrupt(&mut row);
            assert!(matches!(
                preferences_from_row(row),
                Err(EngagementStoreError::Inconsistent)
            ));
        }

        let mut ambiguous = valid_preference_row();
        ambiguous.discovery_match_frequency = "immediate".to_owned();
        assert!(preferences_from_row(ambiguous).is_err());

        let mut legacy_mismatch = valid_preference_row();
        legacy_mismatch.discovery_frequency = "weekly".to_owned();
        assert!(preferences_from_row(legacy_mismatch).is_err());

        let mut active_mismatch = valid_preference_row();
        active_mismatch.active_updates_enabled = true;
        assert!(preferences_from_row(active_mismatch).is_err());
    }

    #[test]
    fn notification_frequency_migration_is_exact_and_rollback_compatible() {
        let migration =
            include_str!("../../../../migrations/0016_subscriptions_notifications_briefs.sql");
        let expected = SubscriptionFrequency::ALL
            .map(SubscriptionFrequency::as_str)
            .to_vec();
        for (column, default) in [
            ("discovery_frequency", "daily"),
            ("discovery_match_frequency", "off"),
            ("discovery_digest_frequency", "daily"),
            ("user_selected_reminder_frequency", "immediate"),
            ("active_paper_version_frequency", "off"),
            ("sync_failure_frequency", "immediate"),
        ] {
            assert_eq!(frequency_allowlist_after(migration, column), expected);
            assert!(migration.contains(&format!("{column} text NOT NULL DEFAULT '{default}'")));
        }
        for contract in [
            "notification_preferences_discovery_exclusive_check",
            "notification_preferences_discovery_projection_check",
            "notification_preferences_active_projection_check",
            "CREATE FUNCTION synchronize_notification_preference_frequencies()",
            "BEFORE INSERT OR UPDATE ON notification_preferences",
        ] {
            assert!(
                migration.contains(contract),
                "missing SQL contract {contract}"
            );
        }
    }

    #[test]
    fn every_plan02_reason_constraint_matches_the_domain_exactly() {
        let expected = RecommendationReasonCode::ALL
            .map(RecommendationReasonCode::as_str)
            .to_vec();
        for (migration, constraint) in [
            (
                include_str!("../../../../migrations/0014_recommendation_foundation.sql"),
                "recommendation_candidates_reasons_check",
            ),
            (
                include_str!("../../../../migrations/0014_recommendation_foundation.sql"),
                "paper_interactions_reasons_check",
            ),
            (
                include_str!("../../../../migrations/0016_subscriptions_notifications_briefs.sql"),
                "reading_brief_items_reasons_check",
            ),
            (
                include_str!("../../../../migrations/0017_plan02_contract_fixes.sql"),
                "paper_interactions_reasons_check",
            ),
            (
                include_str!("../../../../migrations/0018_recommendation_generation_jobs.sql"),
                "recommendation_candidates_reasons_check",
            ),
            (
                include_str!("../../../../migrations/0018_recommendation_generation_jobs.sql"),
                "paper_interactions_reasons_check",
            ),
        ] {
            assert_eq!(reason_allowlist_after(migration, constraint), expected);
        }
    }

    #[test]
    fn notification_entity_constraint_matches_the_domain_exactly() {
        let migration =
            include_str!("../../../../migrations/0016_subscriptions_notifications_briefs.sql");
        let values = migration
            .split_once("entity_type text NOT NULL CHECK (entity_type IN (")
            .and_then(|(_, remainder)| remainder.split_once("))"))
            .map(|(allowlist, _)| {
                allowlist
                    .split(',')
                    .map(|value| value.trim().trim_matches('\''))
                    .collect::<Vec<_>>()
            })
            .expect("notification entity allowlist must remain explicit");
        assert_eq!(
            values,
            NotificationEntityType::ALL
                .map(NotificationEntityType::as_str)
                .to_vec()
        );
    }

    #[test]
    fn notification_and_work_constraints_match_the_domain_exactly() {
        let migration =
            include_str!("../../../../migrations/0016_subscriptions_notifications_briefs.sql");
        assert_eq!(
            text_allowlist_after(migration, "notification_type IN ("),
            NotificationType::ALL.map(NotificationType::as_str).to_vec()
        );
        assert_eq!(
            text_allowlist_after(migration, "work_kind IN ("),
            NotificationWorkKind::ALL
                .map(NotificationWorkKind::as_str)
                .to_vec()
        );
    }

    #[test]
    fn brief_authority_requires_current_exact_mode_and_revision() {
        let batch_id = Uuid::now_v7();
        assert!(brief_authority_shape_matches(
            BriefStatus::Current,
            BriefMode::Queue,
            None,
            None,
            7,
            (7, 1),
        ));
        assert!(brief_authority_shape_matches(
            BriefStatus::Current,
            BriefMode::Discovery,
            Some(RecommendationMode::Recent),
            Some(batch_id),
            7,
            (7, 0),
        ));
        for stale in [
            brief_authority_shape_matches(
                BriefStatus::Superseded,
                BriefMode::Discovery,
                Some(RecommendationMode::Recent),
                Some(batch_id),
                7,
                (7, 0),
            ),
            brief_authority_shape_matches(
                BriefStatus::Current,
                BriefMode::Discovery,
                Some(RecommendationMode::Recent),
                Some(batch_id),
                7,
                (8, 0),
            ),
            brief_authority_shape_matches(
                BriefStatus::Current,
                BriefMode::Discovery,
                Some(RecommendationMode::Recent),
                Some(batch_id),
                7,
                (7, 1),
            ),
            brief_authority_shape_matches(
                BriefStatus::Current,
                BriefMode::Discovery,
                Some(RecommendationMode::Recent),
                None,
                7,
                (7, 0),
            ),
        ] {
            assert!(!stale);
        }
    }
}
