use std::sync::Arc;

use chrono::{DateTime, Utc};
use domain::{AccountStatus, AuthenticatedUserId};
use reading_feed::{
    FeedMode, ReadingFeedRequest, ReadingFeedService, ReadingFeedServiceError, RecommendationMode,
};
use serde_json::to_vec;
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    BriefCreateCommand, BriefFingerprint, BriefItemWrite, BriefMode, BriefProgressCommand,
    BriefProgressFingerprint, BriefProgressOutcome, BriefStoreOutcome, BriefWrite,
    EngagementRetentionCutoffs, EngagementRetentionSummary, EngagementStore, EngagementStoreError,
    Notification, NotificationListOutcome, NotificationMutationOutcome, NotificationPreferences,
    NotificationWorkKind, PreferenceReadOutcome, PreferenceWriteOutcome, QueueDecisionApplyOutcome,
    ReadingBrief, SavedQueryTarget, Subscription, SubscriptionFingerprint, SubscriptionFrequency,
    SubscriptionIntent, SubscriptionKind, SubscriptionListOutcome, SubscriptionMutationOutcome,
    SubscriptionWrite, WorkClaim, WorkRetryDisposition, WorkScheduleSummary,
};

const MAX_SUBSCRIPTIONS: u16 = 100;
const MAX_NOTIFICATIONS: u16 = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngagementPolicy {
    pub brief_size: u32,
    pub work_lease_seconds: u32,
}

impl EngagementPolicy {
    pub fn new(brief_size: u32, work_lease_seconds: u32) -> Result<Self, EngagementServiceError> {
        if !(15..=25).contains(&brief_size) || !(5..=300).contains(&work_lease_seconds) {
            return Err(EngagementServiceError::InvalidPolicy);
        }
        Ok(Self {
            brief_size,
            work_lease_seconds,
        })
    }
}

impl Default for EngagementPolicy {
    fn default() -> Self {
        Self {
            brief_size: 20,
            work_lease_seconds: 30,
        }
    }
}

#[derive(Debug, Error)]
pub enum EngagementServiceError {
    #[error("engagement policy is invalid")]
    InvalidPolicy,
    #[error("operation identity is invalid")]
    InvalidOperation,
    #[error("subscription is invalid")]
    InvalidSubscription,
    #[error("notification preferences are invalid")]
    InvalidPreferences,
    #[error("reading brief has no eligible items")]
    NoEligibleBriefItems,
    #[error("reading brief does not exist")]
    BriefNotFound,
    #[error("reading brief progress revision is stale")]
    BriefProgressStale,
    #[error("reading-feed queue authority is unavailable")]
    QueueAuthorityUnavailable,
    #[error("account does not exist")]
    AccountNotFound,
    #[error("account is inactive")]
    AccountInactive(AccountStatus),
    #[error("idempotency key conflicts with an existing operation")]
    IdempotencyConflict,
    #[error("subscription already exists")]
    SubscriptionConflict,
    #[error("subscription does not exist")]
    SubscriptionNotFound,
    #[error("saved query does not exist")]
    SavedQueryNotFound,
    #[error("notification does not exist")]
    NotificationNotFound,
    #[error("engagement persistence is unavailable")]
    Store(#[from] EngagementStoreError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkRunOutcome {
    Idle,
    Completed(NotificationWorkKind),
    Retrying(NotificationWorkKind),
    Failed(NotificationWorkKind),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkRunResult {
    pub outcome: WorkRunOutcome,
    pub lease_exhausted: Vec<NotificationWorkKind>,
}

#[derive(Clone)]
pub struct EngagementService {
    store: Arc<dyn EngagementStore>,
    reading_feed: ReadingFeedService,
    policy: EngagementPolicy,
}

impl EngagementService {
    #[must_use]
    pub const fn new(
        store: Arc<dyn EngagementStore>,
        reading_feed: ReadingFeedService,
        policy: EngagementPolicy,
    ) -> Self {
        Self {
            store,
            reading_feed,
            policy,
        }
    }

    pub async fn create_brief(
        &self,
        command: BriefCreateCommand,
    ) -> Result<ReadingBrief, EngagementServiceError> {
        validate_operation(command.operation_id)?;
        if !(15..=25).contains(&command.brief_size)
            || command
                .requested_recommendation_mode
                .is_some_and(|requested| requested != command.effective_recommendation_mode)
        {
            return Err(EngagementServiceError::InvalidOperation);
        }
        let page = self
            .reading_feed
            .page(ReadingFeedRequest {
                user_id: command.user_id,
                category: command.category.clone(),
                recommendation_mode: command.effective_recommendation_mode,
                cursor: None,
                limit: Some(command.brief_size),
                now: command.now,
            })
            .await
            .map_err(map_feed_error)?;
        if page.items.is_empty() {
            return Err(EngagementServiceError::NoEligibleBriefItems);
        }
        let mode = match page.mode {
            FeedMode::ToRead => BriefMode::Queue,
            FeedMode::Recommendations => BriefMode::Discovery,
        };
        let recommendation_batch_id = page.batch_id;
        if matches!(mode, BriefMode::Discovery) && recommendation_batch_id.is_none() {
            return Err(EngagementServiceError::QueueAuthorityUnavailable);
        }
        let effective_recommendation_mode = match mode {
            BriefMode::Queue => None,
            BriefMode::Discovery => {
                let Some(selected) = page
                    .items
                    .first()
                    .and_then(|item| item.recommendation.as_ref())
                    .map(|metadata| metadata.mode)
                else {
                    return Err(EngagementServiceError::QueueAuthorityUnavailable);
                };
                if page.items.iter().any(|item| {
                    item.recommendation
                        .as_ref()
                        .is_none_or(|metadata| metadata.mode != selected)
                }) {
                    return Err(EngagementServiceError::QueueAuthorityUnavailable);
                }
                Some(selected)
            }
        };
        let write = BriefWrite {
            id: Uuid::now_v7(),
            mode,
            recommendation_mode: effective_recommendation_mode,
            library_revision: page.decision.library_revision,
            recommendation_batch_id,
            local_date: command.local_date,
            items: page
                .items
                .into_iter()
                .enumerate()
                .map(|(ordinal, item)| BriefItemWrite {
                    ordinal: u16::try_from(ordinal).unwrap_or(u16::MAX),
                    paper_id: item.paper.paper_id,
                    source: item.source,
                    reason_codes: item
                        .recommendation
                        .map_or_else(Vec::new, |value| value.reason_codes),
                })
                .collect(),
        };
        let fingerprint = brief_fingerprint(&command);
        match self
            .store
            .store_brief(command.user_id, command.operation_id, &fingerprint, &write)
            .await?
        {
            BriefStoreOutcome::Stored(value) | BriefStoreOutcome::Replay(value) => Ok(value),
            BriefStoreOutcome::Conflict => Err(EngagementServiceError::IdempotencyConflict),
            BriefStoreOutcome::AuthorityStale => {
                Err(EngagementServiceError::QueueAuthorityUnavailable)
            }
            BriefStoreOutcome::AccountNotFound => Err(EngagementServiceError::AccountNotFound),
            BriefStoreOutcome::Inactive(status) => {
                Err(EngagementServiceError::AccountInactive(status))
            }
        }
    }

    pub async fn current_brief(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<Option<ReadingBrief>, EngagementServiceError> {
        self.store.current_brief(user_id).await.map_err(Into::into)
    }

    pub async fn brief(
        &self,
        user_id: AuthenticatedUserId,
        brief_id: Uuid,
    ) -> Result<Option<ReadingBrief>, EngagementServiceError> {
        if brief_id.is_nil() {
            return Err(EngagementServiceError::BriefNotFound);
        }
        self.store
            .brief(user_id, brief_id)
            .await
            .map_err(Into::into)
    }

    #[must_use]
    pub const fn default_brief_size(&self) -> u32 {
        self.policy.brief_size
    }

    pub async fn advance_brief(
        &self,
        command: BriefProgressCommand,
    ) -> Result<ReadingBrief, EngagementServiceError> {
        validate_operation(command.operation_id)?;
        if command.brief_id.is_nil() || command.expected_progress_revision <= 0 {
            return Err(EngagementServiceError::InvalidOperation);
        }
        let fingerprint = brief_progress_fingerprint(&command);
        match self.store.advance_brief(&command, &fingerprint).await? {
            BriefProgressOutcome::Applied(value) | BriefProgressOutcome::Replay(value) => Ok(value),
            BriefProgressOutcome::Conflict => Err(EngagementServiceError::IdempotencyConflict),
            BriefProgressOutcome::RevisionStale => Err(EngagementServiceError::BriefProgressStale),
            BriefProgressOutcome::NotFound => Err(EngagementServiceError::BriefNotFound),
            BriefProgressOutcome::AccountNotFound => Err(EngagementServiceError::AccountNotFound),
            BriefProgressOutcome::Inactive(status) => {
                Err(EngagementServiceError::AccountInactive(status))
            }
        }
    }

    pub async fn create_subscription(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        write: SubscriptionWrite,
        now: DateTime<Utc>,
    ) -> Result<Subscription, EngagementServiceError> {
        self.mutate_subscription(
            user_id,
            operation_id,
            SubscriptionIntent::Create,
            write,
            now,
        )
        .await
    }

    pub async fn update_subscription(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        write: SubscriptionWrite,
        now: DateTime<Utc>,
    ) -> Result<Subscription, EngagementServiceError> {
        self.mutate_subscription(
            user_id,
            operation_id,
            SubscriptionIntent::Update,
            write,
            now,
        )
        .await
    }

    pub async fn delete_subscription(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<Subscription, EngagementServiceError> {
        self.mutate_subscription(
            user_id,
            operation_id,
            SubscriptionIntent::Delete,
            SubscriptionWrite {
                id,
                kind: SubscriptionKind::Topic,
                key: String::new(),
                label: String::new(),
                query_definition: None,
                frequency: SubscriptionFrequency::Off,
            },
            now,
        )
        .await
    }

    async fn mutate_subscription(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: SubscriptionIntent,
        mut write: SubscriptionWrite,
        now: DateTime<Utc>,
    ) -> Result<Subscription, EngagementServiceError> {
        validate_operation(operation_id)?;
        if write.id.is_nil() {
            return Err(EngagementServiceError::InvalidSubscription);
        }
        if !matches!(intent, SubscriptionIntent::Delete) {
            validate_subscription(&mut write)?;
        }
        let fingerprint = subscription_fingerprint(intent, &write)?;
        let outcome = self
            .store
            .mutate_subscription(user_id, operation_id, intent, &fingerprint, &write)
            .await?;
        let value = match outcome {
            SubscriptionMutationOutcome::Applied(value)
            | SubscriptionMutationOutcome::Replay(value) => value,
            SubscriptionMutationOutcome::Conflict => {
                return Err(EngagementServiceError::IdempotencyConflict);
            }
            SubscriptionMutationOutcome::NameConflict => {
                return Err(EngagementServiceError::SubscriptionConflict);
            }
            SubscriptionMutationOutcome::NotFound => {
                return Err(EngagementServiceError::SubscriptionNotFound);
            }
            SubscriptionMutationOutcome::SavedQueryNotFound => {
                return Err(EngagementServiceError::SavedQueryNotFound);
            }
            SubscriptionMutationOutcome::AccountNotFound => {
                return Err(EngagementServiceError::AccountNotFound);
            }
            SubscriptionMutationOutcome::Inactive(status) => {
                return Err(EngagementServiceError::AccountInactive(status));
            }
        };
        if !matches!(intent, SubscriptionIntent::Delete)
            && !matches!(value.frequency, SubscriptionFrequency::Off)
        {
            self.store
                .enqueue_work(
                    user_id,
                    NotificationWorkKind::EvaluateSubscriptions,
                    Some(value.id),
                    &format!("subscription-{}", value.revision),
                    now,
                )
                .await?;
        }
        Ok(value)
    }

    pub async fn subscriptions(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<Vec<Subscription>, EngagementServiceError> {
        match self.store.subscriptions(user_id, MAX_SUBSCRIPTIONS).await? {
            SubscriptionListOutcome::Found(items) => Ok(items),
            SubscriptionListOutcome::AccountNotFound => {
                Err(EngagementServiceError::AccountNotFound)
            }
            SubscriptionListOutcome::Inactive(status) => {
                Err(EngagementServiceError::AccountInactive(status))
            }
        }
    }

    pub async fn preferences(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<NotificationPreferences, EngagementServiceError> {
        match self.store.preferences(user_id).await? {
            PreferenceReadOutcome::Found(value) => Ok(value),
            PreferenceReadOutcome::AccountNotFound => Err(EngagementServiceError::AccountNotFound),
            PreferenceReadOutcome::Inactive(status) => {
                Err(EngagementServiceError::AccountInactive(status))
            }
        }
    }

    pub async fn put_preferences(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        preferences: NotificationPreferences,
    ) -> Result<NotificationPreferences, EngagementServiceError> {
        validate_operation(operation_id)?;
        validate_preferences(&preferences)?;
        let fingerprint = preference_fingerprint(&preferences);
        match self
            .store
            .put_preferences(user_id, operation_id, &fingerprint, &preferences)
            .await?
        {
            PreferenceWriteOutcome::Applied(value) | PreferenceWriteOutcome::Replay(value) => {
                Ok(value)
            }
            PreferenceWriteOutcome::Conflict => Err(EngagementServiceError::IdempotencyConflict),
            PreferenceWriteOutcome::InvalidTimezone => {
                Err(EngagementServiceError::InvalidPreferences)
            }
            PreferenceWriteOutcome::AccountNotFound => Err(EngagementServiceError::AccountNotFound),
            PreferenceWriteOutcome::Inactive(status) => {
                Err(EngagementServiceError::AccountInactive(status))
            }
        }
    }

    pub async fn notifications(
        &self,
        user_id: AuthenticatedUserId,
        limit: Option<u16>,
    ) -> Result<Vec<Notification>, EngagementServiceError> {
        let limit = limit.unwrap_or(20);
        if !(1..=MAX_NOTIFICATIONS).contains(&limit) {
            return Err(EngagementServiceError::InvalidPreferences);
        }
        match self.store.notifications(user_id, limit).await? {
            NotificationListOutcome::Found(items) => Ok(items),
            NotificationListOutcome::AccountNotFound => {
                Err(EngagementServiceError::AccountNotFound)
            }
            NotificationListOutcome::Inactive(status) => {
                Err(EngagementServiceError::AccountInactive(status))
            }
        }
    }

    pub async fn mark_notification_read(
        &self,
        user_id: AuthenticatedUserId,
        notification_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementServiceError> {
        if notification_id.is_nil() {
            return Err(EngagementServiceError::NotificationNotFound);
        }
        let outcome = self
            .store
            .mark_notification_read(user_id, notification_id, now)
            .await?;
        map_notification_mutation(&outcome)
    }

    pub async fn mark_all_notifications_read(
        &self,
        user_id: AuthenticatedUserId,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementServiceError> {
        let outcome = self.store.mark_all_notifications_read(user_id, now).await?;
        map_notification_mutation(&outcome)
    }

    pub async fn dismiss_notification(
        &self,
        user_id: AuthenticatedUserId,
        notification_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementServiceError> {
        if notification_id.is_nil() {
            return Err(EngagementServiceError::NotificationNotFound);
        }
        let outcome = self
            .store
            .dismiss_notification(user_id, notification_id, now)
            .await?;
        map_notification_mutation(&outcome)
    }

    pub async fn schedule_due_work(
        &self,
        now: DateTime<Utc>,
        limit: u32,
    ) -> Result<WorkScheduleSummary, EngagementServiceError> {
        self.schedule_due_work_with_reminders(now, limit, true)
            .await
    }

    /// Keeps reminder scheduling aligned with the independently deployable
    /// notifications feature while leaving other engagement work available.
    pub async fn schedule_due_work_with_reminders(
        &self,
        now: DateTime<Utc>,
        limit: u32,
        reminders_enabled: bool,
    ) -> Result<WorkScheduleSummary, EngagementServiceError> {
        if !(1..=1_000).contains(&limit) {
            return Err(EngagementServiceError::InvalidPolicy);
        }
        self.store
            .schedule_due_work_with_reminders(now, limit, reminders_enabled)
            .await
            .map_err(Into::into)
    }

    /// Executes one bounded routine-retention pass. Immediate account deletion
    /// is enforced independently by database ownership cascades.
    pub async fn cleanup_retention(
        &self,
        cutoffs: EngagementRetentionCutoffs,
        limit: u32,
    ) -> Result<EngagementRetentionSummary, EngagementServiceError> {
        if !(1..=10_000).contains(&limit) {
            return Err(EngagementServiceError::InvalidPolicy);
        }
        self.store
            .cleanup_retention(cutoffs, limit)
            .await
            .map_err(Into::into)
    }

    pub async fn run_work_once(
        &self,
        worker_id: &str,
        now: DateTime<Utc>,
    ) -> Result<WorkRunResult, EngagementServiceError> {
        self.run_work_once_with_reminders(worker_id, now, true)
            .await
    }

    /// Claims all closed work kinds so rollback does not strand leases, but
    /// completes reminder work without evaluating it when notifications are
    /// disabled for this deployment.
    pub async fn run_work_once_with_reminders(
        &self,
        worker_id: &str,
        now: DateTime<Utc>,
        reminders_enabled: bool,
    ) -> Result<WorkRunResult, EngagementServiceError> {
        if worker_id.is_empty()
            || worker_id.len() > 128
            || worker_id.trim() != worker_id
            || worker_id.chars().any(char::is_control)
        {
            return Err(EngagementServiceError::InvalidPolicy);
        }
        let claim = self
            .store
            .claim_work(&WorkClaim {
                worker_id: worker_id.to_owned(),
                now,
                lease_seconds: self.policy.work_lease_seconds,
            })
            .await?;
        let Some(item) = claim.item else {
            return Ok(WorkRunResult {
                outcome: WorkRunOutcome::Idle,
                lease_exhausted: claim.lease_exhausted,
            });
        };
        let result = if work_enabled(item.kind, reminders_enabled) {
            self.execute_work(&item, now).await
        } else {
            Ok(())
        };
        let finished_at = Utc::now().max(now);
        match result {
            Ok(()) => {
                self.store
                    .complete_work(item.id, worker_id, finished_at)
                    .await?;
                Ok(WorkRunResult {
                    outcome: WorkRunOutcome::Completed(item.kind),
                    lease_exhausted: claim.lease_exhausted,
                })
            }
            Err(error_value) => {
                let disposition = self
                    .store
                    .retry_work(&item, worker_id, work_error_code(&error_value), finished_at)
                    .await?;
                Ok(WorkRunResult {
                    outcome: retry_run_outcome(item.kind, disposition),
                    lease_exhausted: claim.lease_exhausted,
                })
            }
        }
    }

    async fn execute_work(
        &self,
        item: &crate::NotificationWorkItem,
        now: DateTime<Utc>,
    ) -> Result<(), EngagementServiceError> {
        match item.kind {
            NotificationWorkKind::EvaluateSubscriptions => {
                self.store.evaluate_subscription(item, now).await?;
                self.store
                    .enqueue_work(
                        item.user_id,
                        NotificationWorkKind::RecheckNotificationQueueEligibility,
                        None,
                        &format!("evaluation-{}", now.date_naive()),
                        now,
                    )
                    .await?;
                Ok(())
            }
            NotificationWorkKind::EvaluateActivePapers => {
                self.store.evaluate_active_papers(item, now).await?;
                Ok(())
            }
            NotificationWorkKind::EvaluateReminders => {
                self.store.evaluate_reminders(item, now).await?;
                Ok(())
            }
            NotificationWorkKind::RecheckNotificationQueueEligibility => {
                let decision = self.queue_decision(item.user_id, now).await?;
                let outcome = self
                    .store
                    .apply_queue_decision(item.user_id, decision.0, decision.1, now)
                    .await?;
                if matches!(
                    outcome,
                    QueueDecisionApplyOutcome::Applied {
                        digest_needed: true
                    }
                ) {
                    self.store
                        .enqueue_work(
                            item.user_id,
                            NotificationWorkKind::BuildNotificationDigest,
                            None,
                            &format!("digest-{}-{}", now.date_naive(), decision.0),
                            now,
                        )
                        .await?;
                }
                ensure_queue_outcome(outcome)
            }
            NotificationWorkKind::BuildNotificationDigest => {
                let decision = self.queue_decision(item.user_id, now).await?;
                if !decision.1 {
                    return ensure_queue_outcome(
                        self.store
                            .apply_queue_decision(item.user_id, decision.0, false, now)
                            .await?,
                    );
                }
                ensure_queue_outcome(
                    self.store
                        .build_digest(item.user_id, decision.0, now)
                        .await?,
                )
            }
            NotificationWorkKind::ExpireNotifications => {
                self.store.expire_notifications(item.user_id, now).await?;
                Ok(())
            }
        }
    }

    async fn queue_decision(
        &self,
        user_id: AuthenticatedUserId,
        now: DateTime<Utc>,
    ) -> Result<(i64, bool), EngagementServiceError> {
        let page = self
            .reading_feed
            .page(ReadingFeedRequest {
                user_id,
                category: None,
                recommendation_mode: RecommendationMode::Recent,
                cursor: None,
                limit: Some(1),
                now,
            })
            .await
            .map_err(map_feed_error)?;
        Ok((
            page.decision.library_revision,
            page.decision.queue_proven_empty,
        ))
    }
}

const fn work_enabled(kind: NotificationWorkKind, reminders_enabled: bool) -> bool {
    !matches!(kind, NotificationWorkKind::EvaluateReminders) || reminders_enabled
}

fn validate_operation(operation_id: Uuid) -> Result<(), EngagementServiceError> {
    if operation_id.is_nil() {
        Err(EngagementServiceError::InvalidOperation)
    } else {
        Ok(())
    }
}

fn validate_subscription(write: &mut SubscriptionWrite) -> Result<(), EngagementServiceError> {
    write.key = write.key.trim().to_lowercase();
    write.label = write.label.trim().to_owned();
    if write.key.is_empty()
        || write.key.chars().count() > 160
        || write.label.is_empty()
        || write.label.chars().count() > 160
        || write.key.chars().any(char::is_control)
        || write.label.chars().any(char::is_control)
    {
        return Err(EngagementServiceError::InvalidSubscription);
    }
    match write.kind {
        SubscriptionKind::SavedQuery => {
            let definition = write
                .query_definition
                .as_ref()
                .ok_or(EngagementServiceError::InvalidSubscription)?;
            let target: SavedQueryTarget = serde_json::from_value(definition.clone())
                .map_err(|_| EngagementServiceError::InvalidSubscription)?;
            if target.saved_search_id.is_nil()
                || write.key != target.saved_search_id.to_string().to_lowercase()
            {
                return Err(EngagementServiceError::InvalidSubscription);
            }
        }
        _ if write.query_definition.is_some() => {
            return Err(EngagementServiceError::InvalidSubscription);
        }
        _ => {}
    }
    Ok(())
}

fn validate_preferences(
    preferences: &NotificationPreferences,
) -> Result<(), EngagementServiceError> {
    if !preferences
        .type_frequencies
        .has_unambiguous_discovery_projection()
        || preferences.discovery_frequency
            != preferences.type_frequencies.legacy_discovery_frequency()
        || preferences.active_updates_enabled
            != preferences.type_frequencies.legacy_active_updates_enabled()
        || preferences.push_enabled
        || preferences.email_enabled
        || !(1..=20).contains(&preferences.daily_budget)
        || preferences.timezone.is_empty()
        || preferences.timezone.len() > 64
        || preferences.timezone.trim() != preferences.timezone
        || preferences.timezone.chars().any(|character| {
            !(character.is_ascii_alphanumeric() || matches!(character, '_' | '+' | '.' | '/' | '-'))
        })
        || (preferences.quiet_hours_start.is_some() != preferences.quiet_hours_end.is_some())
    {
        return Err(EngagementServiceError::InvalidPreferences);
    }
    Ok(())
}

fn brief_fingerprint(command: &BriefCreateCommand) -> BriefFingerprint {
    let mut digest = Sha256::new();
    match command.requested_recommendation_mode {
        Some(mode) => {
            digest.update(b"explicit");
            digest.update([0]);
            digest.update(mode.as_str().as_bytes());
        }
        None => digest.update(b"profile_default"),
    }
    digest.update([0]);
    // Brief size is profile-owned in v1. Bind the selection source rather
    // than a mutable resolved value so an identical retry stays identical.
    digest.update(b"profile_default_brief_size");
    digest.update([0]);
    digest.update(command.category.as_deref().unwrap_or_default().as_bytes());
    digest.update([0]);
    digest.update(command.local_date.to_string().as_bytes());
    BriefFingerprint(digest.finalize().into())
}

fn brief_progress_fingerprint(command: &BriefProgressCommand) -> BriefProgressFingerprint {
    let mut digest = Sha256::new();
    digest.update(command.brief_id.as_bytes());
    digest.update(command.expected_progress_revision.to_be_bytes());
    digest.update(command.position.to_be_bytes());
    BriefProgressFingerprint(digest.finalize().into())
}

fn subscription_fingerprint(
    intent: SubscriptionIntent,
    write: &SubscriptionWrite,
) -> Result<SubscriptionFingerprint, EngagementServiceError> {
    let mut digest = Sha256::new();
    digest.update(intent.as_str().as_bytes());
    digest.update(write.id.as_bytes());
    digest.update(write.kind.as_str().as_bytes());
    digest.update(write.key.as_bytes());
    digest.update(write.label.as_bytes());
    digest.update(write.frequency.as_str().as_bytes());
    if let Some(definition) = &write.query_definition {
        digest.update(to_vec(definition).map_err(|_| EngagementServiceError::InvalidSubscription)?);
    }
    Ok(SubscriptionFingerprint(digest.finalize().into()))
}

fn preference_fingerprint(preferences: &NotificationPreferences) -> SubscriptionFingerprint {
    let mut digest = Sha256::new();
    for frequency in [
        preferences.type_frequencies.discovery_match,
        preferences.type_frequencies.discovery_digest,
        preferences.type_frequencies.active_paper_version,
        preferences.type_frequencies.sync_failure,
    ] {
        digest.update(frequency.as_str().as_bytes());
        digest.update([0]);
    }
    digest.update(
        preferences
            .quiet_hours_start
            .map(|value| value.to_string())
            .unwrap_or_default()
            .as_bytes(),
    );
    digest.update([0]);
    digest.update(
        preferences
            .quiet_hours_end
            .map(|value| value.to_string())
            .unwrap_or_default()
            .as_bytes(),
    );
    digest.update([0]);
    digest.update(preferences.timezone.as_bytes());
    digest.update([
        u8::from(preferences.in_app_enabled),
        u8::from(preferences.push_enabled),
        u8::from(preferences.email_enabled),
        u8::from(preferences.global_pause),
    ]);
    digest.update(preferences.daily_budget.to_be_bytes());
    SubscriptionFingerprint(digest.finalize().into())
}

fn map_feed_error(error_value: ReadingFeedServiceError) -> EngagementServiceError {
    match error_value {
        ReadingFeedServiceError::AccountNotFound => EngagementServiceError::AccountNotFound,
        ReadingFeedServiceError::Suspended => {
            EngagementServiceError::AccountInactive(AccountStatus::Suspended)
        }
        ReadingFeedServiceError::DeletionPending => {
            EngagementServiceError::AccountInactive(AccountStatus::DeletionPending)
        }
        ReadingFeedServiceError::Deleted => {
            EngagementServiceError::AccountInactive(AccountStatus::Deleted)
        }
        _ => EngagementServiceError::QueueAuthorityUnavailable,
    }
}

fn map_notification_mutation(
    outcome: &NotificationMutationOutcome,
) -> Result<u64, EngagementServiceError> {
    match outcome {
        NotificationMutationOutcome::Applied { affected } => Ok(*affected),
        NotificationMutationOutcome::NotFound => Err(EngagementServiceError::NotificationNotFound),
        NotificationMutationOutcome::AccountNotFound => {
            Err(EngagementServiceError::AccountNotFound)
        }
        NotificationMutationOutcome::Inactive(status) => {
            Err(EngagementServiceError::AccountInactive(*status))
        }
    }
}

fn ensure_queue_outcome(outcome: QueueDecisionApplyOutcome) -> Result<(), EngagementServiceError> {
    match outcome {
        QueueDecisionApplyOutcome::Applied { .. } => Ok(()),
        QueueDecisionApplyOutcome::Stale => Err(EngagementServiceError::QueueAuthorityUnavailable),
        QueueDecisionApplyOutcome::AccountNotFound => Err(EngagementServiceError::AccountNotFound),
        QueueDecisionApplyOutcome::Inactive(status) => {
            Err(EngagementServiceError::AccountInactive(status))
        }
    }
}

const fn work_error_code(error_value: &EngagementServiceError) -> &'static str {
    match error_value {
        EngagementServiceError::QueueAuthorityUnavailable => "QUEUE_AUTHORITY_UNAVAILABLE",
        EngagementServiceError::Store(_) => "STORE_UNAVAILABLE",
        EngagementServiceError::AccountNotFound | EngagementServiceError::AccountInactive(_) => {
            "ACCOUNT_UNAVAILABLE"
        }
        _ => "WORK_REJECTED",
    }
}

const fn retry_run_outcome(
    kind: NotificationWorkKind,
    disposition: WorkRetryDisposition,
) -> WorkRunOutcome {
    match disposition {
        WorkRetryDisposition::Queued => WorkRunOutcome::Retrying(kind),
        WorkRetryDisposition::Failed => WorkRunOutcome::Failed(kind),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NotificationTypeFrequencies;

    #[test]
    fn subscription_validation_rejects_untyped_saved_queries_and_control_text() {
        let mut write = SubscriptionWrite {
            id: Uuid::now_v7(),
            kind: SubscriptionKind::SavedQuery,
            key: Uuid::now_v7().to_string(),
            label: "Saved query".to_owned(),
            query_definition: Some(serde_json::json!({ "raw_query": "private" })),
            frequency: SubscriptionFrequency::Daily,
        };
        assert!(matches!(
            validate_subscription(&mut write),
            Err(EngagementServiceError::InvalidSubscription)
        ));
        write.kind = SubscriptionKind::Topic;
        write.query_definition = None;
        write.label = "bad\nlabel".to_owned();
        assert!(matches!(
            validate_subscription(&mut write),
            Err(EngagementServiceError::InvalidSubscription)
        ));
    }

    #[test]
    fn preferences_keep_push_and_email_dormant() {
        let preferences = NotificationPreferences {
            discovery_frequency: SubscriptionFrequency::Daily,
            type_frequencies: NotificationTypeFrequencies::default(),
            quiet_hours_start: None,
            quiet_hours_end: None,
            timezone: "UTC".to_owned(),
            in_app_enabled: true,
            push_enabled: true,
            email_enabled: false,
            global_pause: false,
            active_updates_enabled: false,
            daily_budget: 5,
            revision: 1,
            updated_at: Utc::now(),
        };
        assert!(matches!(
            validate_preferences(&preferences),
            Err(EngagementServiceError::InvalidPreferences)
        ));
        let muted = NotificationPreferences {
            push_enabled: false,
            in_app_enabled: false,
            ..preferences
        };
        assert!(validate_preferences(&muted).is_ok());
    }

    #[test]
    fn preference_idempotency_ignores_server_assigned_metadata() {
        let first = NotificationPreferences {
            discovery_frequency: SubscriptionFrequency::Daily,
            type_frequencies: NotificationTypeFrequencies::default(),
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
            updated_at: Utc::now(),
        };
        let mut replay = first.clone();
        replay.revision = 42;
        replay.updated_at += chrono::Duration::hours(1);
        assert_eq!(
            preference_fingerprint(&first),
            preference_fingerprint(&replay)
        );
        replay.type_frequencies.sync_failure = SubscriptionFrequency::Off;
        assert_ne!(
            preference_fingerprint(&first),
            preference_fingerprint(&replay),
            "canonical per-type changes must affect idempotency"
        );
    }

    #[test]
    fn preference_compatibility_projection_rejects_ambiguous_or_disagreeing_writes() {
        let canonical =
            NotificationTypeFrequencies::from_legacy(SubscriptionFrequency::Weekly, true);
        let preferences = NotificationPreferences {
            discovery_frequency: SubscriptionFrequency::Weekly,
            type_frequencies: canonical,
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
            updated_at: Utc::now(),
        };
        assert!(validate_preferences(&preferences).is_ok());

        let active_daily = NotificationPreferences {
            type_frequencies: NotificationTypeFrequencies {
                active_paper_version: SubscriptionFrequency::Daily,
                ..canonical
            },
            ..preferences.clone()
        };
        assert!(validate_preferences(&active_daily).is_ok());

        let disagreeing_legacy = NotificationPreferences {
            discovery_frequency: SubscriptionFrequency::Daily,
            ..preferences.clone()
        };
        assert!(matches!(
            validate_preferences(&disagreeing_legacy),
            Err(EngagementServiceError::InvalidPreferences)
        ));

        let disagreeing_active_projection = NotificationPreferences {
            active_updates_enabled: false,
            ..preferences.clone()
        };
        assert!(matches!(
            validate_preferences(&disagreeing_active_projection),
            Err(EngagementServiceError::InvalidPreferences)
        ));

        let ambiguous = NotificationPreferences {
            discovery_frequency: SubscriptionFrequency::Immediate,
            type_frequencies: NotificationTypeFrequencies {
                discovery_match: SubscriptionFrequency::Immediate,
                discovery_digest: SubscriptionFrequency::Daily,
                ..canonical
            },
            ..preferences
        };
        assert!(matches!(
            validate_preferences(&ambiguous),
            Err(EngagementServiceError::InvalidPreferences)
        ));
    }

    #[test]
    fn brief_idempotency_binds_intent_not_a_later_feed_snapshot() {
        let first = BriefCreateCommand {
            user_id: AuthenticatedUserId::new(Uuid::now_v7()),
            operation_id: Uuid::now_v7(),
            requested_recommendation_mode: None,
            effective_recommendation_mode: RecommendationMode::Recent,
            brief_size: 20,
            category: Some("cs.AI".to_owned()),
            local_date: Utc::now().date_naive(),
            now: Utc::now(),
        };
        let mut retry = first.clone();
        retry.now += chrono::Duration::minutes(5);
        retry.effective_recommendation_mode = RecommendationMode::ForYou;
        retry.brief_size = 25;
        assert_eq!(brief_fingerprint(&first), brief_fingerprint(&retry));
        retry.requested_recommendation_mode = Some(RecommendationMode::Recent);
        retry.effective_recommendation_mode = RecommendationMode::Recent;
        assert_ne!(brief_fingerprint(&first), brief_fingerprint(&retry));
        retry.requested_recommendation_mode = None;
        retry.category = Some("cs.LG".to_owned());
        assert_ne!(brief_fingerprint(&first), brief_fingerprint(&retry));
    }

    #[test]
    fn policy_is_bounded() {
        assert!(EngagementPolicy::new(15, 5).is_ok());
        assert!(EngagementPolicy::new(25, 300).is_ok());
        assert!(matches!(
            EngagementPolicy::new(26, 30),
            Err(EngagementServiceError::InvalidPolicy)
        ));
    }

    #[test]
    fn retry_disposition_preserves_terminal_failure() {
        let kind = NotificationWorkKind::BuildNotificationDigest;
        assert_eq!(
            retry_run_outcome(kind, WorkRetryDisposition::Queued),
            WorkRunOutcome::Retrying(kind)
        );
        assert_eq!(
            retry_run_outcome(kind, WorkRetryDisposition::Failed),
            WorkRunOutcome::Failed(kind)
        );
    }

    #[test]
    fn notification_rollback_retires_only_reminder_work_without_execution() {
        for kind in NotificationWorkKind::ALL {
            assert_eq!(
                work_enabled(kind, false),
                kind != NotificationWorkKind::EvaluateReminders,
                "rollback execution policy drifted for {}",
                kind.as_str()
            );
            assert!(work_enabled(kind, true));
        }
    }
}
