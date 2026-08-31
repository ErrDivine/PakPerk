use async_trait::async_trait;
use chrono::{DateTime, Utc};
use domain::{AccountStatus, AuthenticatedUserId};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    BriefFingerprint, BriefProgressCommand, BriefProgressFingerprint, BriefWrite, Notification,
    NotificationPreferences, NotificationWorkItem, NotificationWorkKind, ReadingBrief,
    Subscription, SubscriptionFingerprint, SubscriptionIntent, SubscriptionWrite, WorkClaim,
    WorkClaimOutcome, WorkRetryDisposition, WorkScheduleSummary,
};

#[derive(Debug, Error)]
pub enum EngagementStoreError {
    #[error("engagement persistence is unavailable")]
    Unavailable,
    #[error("engagement persistence returned inconsistent data")]
    Inconsistent,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BriefStoreOutcome {
    Stored(ReadingBrief),
    Replay(ReadingBrief),
    Conflict,
    AuthorityStale,
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum BriefProgressOutcome {
    Applied(ReadingBrief),
    Replay(ReadingBrief),
    Conflict,
    RevisionStale,
    NotFound,
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum SubscriptionMutationOutcome {
    Applied(Subscription),
    Replay(Subscription),
    Conflict,
    NameConflict,
    NotFound,
    SavedQueryNotFound,
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum SubscriptionListOutcome {
    Found(Vec<Subscription>),
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum PreferenceReadOutcome {
    Found(NotificationPreferences),
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum PreferenceWriteOutcome {
    Applied(NotificationPreferences),
    Replay(NotificationPreferences),
    Conflict,
    InvalidTimezone,
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum NotificationListOutcome {
    Found(Vec<Notification>),
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotificationMutationOutcome {
    Applied { affected: u64 },
    NotFound,
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueDecisionApplyOutcome {
    Applied { digest_needed: bool },
    Stale,
    AccountNotFound,
    Inactive(AccountStatus),
}

/// Bounded deletion watermarks for account-owned engagement records.
///
/// The API maintenance loop computes these from the reviewed retention
/// schedule. Keeping absolute timestamps in the store contract makes the
/// deletion query deterministic and straightforward to exercise in database
/// tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngagementRetentionCutoffs {
    pub briefs_before: DateTime<Utc>,
    pub notifications_before: DateTime<Utc>,
    pub operations_before: DateTime<Utc>,
    pub work_before: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EngagementRetentionSummary {
    pub briefs: u64,
    pub notifications: u64,
    pub operations: u64,
    pub work_items: u64,
}

impl EngagementRetentionSummary {
    #[must_use]
    pub const fn total(self) -> u64 {
        self.briefs + self.notifications + self.operations + self.work_items
    }
}

#[async_trait]
pub trait EngagementStore: Send + Sync {
    async fn store_brief(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: &BriefFingerprint,
        write: &BriefWrite,
    ) -> Result<BriefStoreOutcome, EngagementStoreError>;

    async fn current_brief(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<Option<ReadingBrief>, EngagementStoreError>;

    /// Loads one account-owned brief only while its persisted queue or
    /// recommendation authority still matches the current library revision.
    async fn brief(
        &self,
        user_id: AuthenticatedUserId,
        brief_id: Uuid,
    ) -> Result<Option<ReadingBrief>, EngagementStoreError>;

    async fn advance_brief(
        &self,
        command: &BriefProgressCommand,
        fingerprint: &BriefProgressFingerprint,
    ) -> Result<BriefProgressOutcome, EngagementStoreError>;

    async fn mutate_subscription(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: SubscriptionIntent,
        fingerprint: &SubscriptionFingerprint,
        write: &SubscriptionWrite,
    ) -> Result<SubscriptionMutationOutcome, EngagementStoreError>;

    async fn subscriptions(
        &self,
        user_id: AuthenticatedUserId,
        limit: u16,
    ) -> Result<SubscriptionListOutcome, EngagementStoreError>;

    async fn preferences(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<PreferenceReadOutcome, EngagementStoreError>;

    async fn put_preferences(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: &SubscriptionFingerprint,
        preferences: &NotificationPreferences,
    ) -> Result<PreferenceWriteOutcome, EngagementStoreError>;

    async fn notifications(
        &self,
        user_id: AuthenticatedUserId,
        limit: u16,
    ) -> Result<NotificationListOutcome, EngagementStoreError>;

    async fn mark_notification_read(
        &self,
        user_id: AuthenticatedUserId,
        notification_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<NotificationMutationOutcome, EngagementStoreError>;

    async fn mark_all_notifications_read(
        &self,
        user_id: AuthenticatedUserId,
        now: DateTime<Utc>,
    ) -> Result<NotificationMutationOutcome, EngagementStoreError>;

    async fn dismiss_notification(
        &self,
        user_id: AuthenticatedUserId,
        notification_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<NotificationMutationOutcome, EngagementStoreError>;

    async fn schedule_due_work(
        &self,
        now: DateTime<Utc>,
        limit: u32,
    ) -> Result<WorkScheduleSummary, EngagementStoreError> {
        self.schedule_due_work_with_reminders(now, limit, true)
            .await
    }

    /// Schedules bounded work while allowing a rolled-back deployment to keep
    /// reminder work dormant without disabling subscriptions or retention.
    async fn schedule_due_work_with_reminders(
        &self,
        now: DateTime<Utc>,
        limit: u32,
        reminders_enabled: bool,
    ) -> Result<WorkScheduleSummary, EngagementStoreError>;

    async fn enqueue_work(
        &self,
        user_id: AuthenticatedUserId,
        kind: NotificationWorkKind,
        subscription_id: Option<Uuid>,
        window_key: &str,
        now: DateTime<Utc>,
    ) -> Result<(), EngagementStoreError>;

    async fn claim_work(&self, claim: &WorkClaim)
    -> Result<WorkClaimOutcome, EngagementStoreError>;

    async fn evaluate_subscription(
        &self,
        item: &NotificationWorkItem,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError>;

    async fn evaluate_active_papers(
        &self,
        item: &NotificationWorkItem,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError>;

    async fn evaluate_reminders(
        &self,
        item: &NotificationWorkItem,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError>;

    async fn apply_queue_decision(
        &self,
        user_id: AuthenticatedUserId,
        library_revision: i64,
        queue_proven_empty: bool,
        now: DateTime<Utc>,
    ) -> Result<QueueDecisionApplyOutcome, EngagementStoreError>;

    async fn build_digest(
        &self,
        user_id: AuthenticatedUserId,
        library_revision: i64,
        now: DateTime<Utc>,
    ) -> Result<QueueDecisionApplyOutcome, EngagementStoreError>;

    async fn expire_notifications(
        &self,
        user_id: AuthenticatedUserId,
        now: DateTime<Utc>,
    ) -> Result<u64, EngagementStoreError>;

    /// Permanently removes at most `limit` expired rows from each engagement
    /// retention class. Account deletion remains the immediate, unbounded
    /// authority for one account; this method is only routine age-based
    /// cleanup.
    async fn cleanup_retention(
        &self,
        cutoffs: EngagementRetentionCutoffs,
        limit: u32,
    ) -> Result<EngagementRetentionSummary, EngagementStoreError>;

    async fn complete_work(
        &self,
        item_id: Uuid,
        worker_id: &str,
        now: DateTime<Utc>,
    ) -> Result<(), EngagementStoreError>;

    async fn retry_work(
        &self,
        item: &NotificationWorkItem,
        worker_id: &str,
        error_code: &str,
        now: DateTime<Utc>,
    ) -> Result<WorkRetryDisposition, EngagementStoreError>;
}
