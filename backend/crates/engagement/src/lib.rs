//! Queue-authorized reading briefs, subscriptions, and in-app notifications.
//!
//! This crate deliberately depends on the canonical reading-feed gate. It does
//! not infer queue emptiness, fetch PDFs, or accept arbitrary delivery jobs.

mod model;
mod service;
mod store;

pub use model::{
    BriefCreateCommand, BriefFingerprint, BriefItem, BriefItemWrite, BriefMode,
    BriefProgressCommand, BriefProgressFingerprint, BriefStatus, BriefWrite, Notification,
    NotificationDeliveryEligibility, NotificationEntityType, NotificationPreferences,
    NotificationScope, NotificationType, NotificationTypeFrequencies, NotificationWorkItem,
    NotificationWorkKind, ReadingBrief, SavedQueryTarget, Subscription, SubscriptionFingerprint,
    SubscriptionFrequency, SubscriptionIntent, SubscriptionKind, SubscriptionWrite, WorkClaim,
    WorkClaimOutcome, WorkRetryDisposition, WorkScheduleSummary,
};
pub use service::{
    EngagementPolicy, EngagementService, EngagementServiceError, WorkRunOutcome, WorkRunResult,
};
pub use store::{
    BriefProgressOutcome, BriefStoreOutcome, EngagementRetentionCutoffs,
    EngagementRetentionSummary, EngagementStore, EngagementStoreError, NotificationListOutcome,
    NotificationMutationOutcome, PreferenceReadOutcome, PreferenceWriteOutcome,
    QueueDecisionApplyOutcome, SubscriptionListOutcome, SubscriptionMutationOutcome,
};
