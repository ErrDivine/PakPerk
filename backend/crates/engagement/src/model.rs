use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use domain::{AuthenticatedUserId, PaperId, PaperSummary, RecommendationReasonCode};
use reading_feed::{FeedItemSource, RecommendationMode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BriefMode {
    Queue,
    Discovery,
}

impl BriefMode {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queue => "queue",
            Self::Discovery => "discovery",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BriefStatus {
    Current,
    Complete,
    Superseded,
}

impl BriefStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Current => "current",
            Self::Complete => "complete",
            Self::Superseded => "superseded",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefFingerprint(pub [u8; 32]);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BriefItem {
    pub ordinal: u16,
    pub paper: PaperSummary,
    pub source: FeedItemSource,
    pub reason_codes: Vec<RecommendationReasonCode>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadingBrief {
    pub id: Uuid,
    pub mode: BriefMode,
    pub recommendation_mode: Option<RecommendationMode>,
    pub library_revision: i64,
    pub recommendation_batch_id: Option<Uuid>,
    pub local_date: NaiveDate,
    /// Zero-based next item to resume, or `items.len()` when complete.
    pub position: u16,
    pub progress_revision: i64,
    pub status: BriefStatus,
    pub items: Vec<BriefItem>,
    pub completed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefProgressFingerprint(pub [u8; 32]);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefProgressCommand {
    pub user_id: AuthenticatedUserId,
    pub operation_id: Uuid,
    pub brief_id: Uuid,
    pub expected_progress_revision: i64,
    pub position: u16,
    pub now: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefCreateCommand {
    pub user_id: AuthenticatedUserId,
    pub operation_id: Uuid,
    /// Client intent retained for idempotency. `None` means the account's
    /// profile default, not the effective value resolved for this attempt.
    pub requested_recommendation_mode: Option<RecommendationMode>,
    pub effective_recommendation_mode: RecommendationMode,
    /// Effective bounded size resolved from the current profile or service
    /// default. This is execution policy, not client-authored idempotency data.
    pub brief_size: u32,
    pub category: Option<String>,
    pub local_date: NaiveDate,
    pub now: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubscriptionKind {
    Topic,
    Category,
    Author,
    SavedQuery,
}

impl SubscriptionKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Topic => "topic",
            Self::Category => "category",
            Self::Author => "author",
            Self::SavedQuery => "saved_query",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubscriptionFrequency {
    Immediate,
    Daily,
    Weekly,
    Off,
}

impl SubscriptionFrequency {
    pub const ALL: [Self; 4] = [Self::Immediate, Self::Daily, Self::Weekly, Self::Off];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Immediate => "immediate",
            Self::Daily => "daily",
            Self::Weekly => "weekly",
            Self::Off => "off",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "immediate" => Some(Self::Immediate),
            "daily" => Some(Self::Daily),
            "weekly" => Some(Self::Weekly),
            "off" => Some(Self::Off),
            _ => None,
        }
    }

    #[must_use]
    pub const fn is_enabled(self) -> bool {
        !matches!(self, Self::Off)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubscriptionIntent {
    Create,
    Update,
    Delete,
}

impl SubscriptionIntent {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Update => "update",
            Self::Delete => "delete",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SavedQueryTarget {
    pub saved_search_id: Uuid,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SubscriptionWrite {
    pub id: Uuid,
    pub kind: SubscriptionKind,
    pub key: String,
    pub label: String,
    pub query_definition: Option<Value>,
    pub frequency: SubscriptionFrequency,
}

#[derive(Clone, PartialEq, Eq)]
pub struct SubscriptionFingerprint(pub [u8; 32]);

impl std::fmt::Debug for SubscriptionFingerprint {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SubscriptionFingerprint([redacted])")
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Subscription {
    pub id: Uuid,
    pub kind: SubscriptionKind,
    pub key: String,
    pub label: String,
    pub query_definition: Option<Value>,
    pub frequency: SubscriptionFrequency,
    pub last_evaluated_at: Option<DateTime<Utc>>,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationType {
    DiscoveryMatch,
    DiscoveryDigest,
    UserSelectedReminder,
    ActivePaperVersion,
    SyncFailure,
}

impl NotificationType {
    pub const ALL: [Self; 5] = [
        Self::DiscoveryMatch,
        Self::DiscoveryDigest,
        Self::UserSelectedReminder,
        Self::ActivePaperVersion,
        Self::SyncFailure,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::DiscoveryMatch => "discovery_match",
            Self::DiscoveryDigest => "discovery_digest",
            Self::UserSelectedReminder => "user_selected_reminder",
            Self::ActivePaperVersion => "active_paper_version",
            Self::SyncFailure => "sync_failure",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "discovery_match" => Some(Self::DiscoveryMatch),
            "discovery_digest" => Some(Self::DiscoveryDigest),
            "user_selected_reminder" => Some(Self::UserSelectedReminder),
            "active_paper_version" => Some(Self::ActivePaperVersion),
            "sync_failure" => Some(Self::SyncFailure),
            _ => None,
        }
    }
}

/// Canonical per-notification-type delivery frequencies.
///
/// The two discovery paths are intentionally mutually exclusive on writes:
/// direct matches take precedence when enabled, otherwise the digest frequency
/// controls delivery. Keeping that projection unambiguous lets older servers
/// continue using `discovery_frequency` during a rollback.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NotificationTypeFrequencies {
    pub discovery_match: SubscriptionFrequency,
    pub discovery_digest: SubscriptionFrequency,
    /// Queue-owned reminders selected explicitly on active library items.
    pub user_selected_reminder: SubscriptionFrequency,
    pub active_paper_version: SubscriptionFrequency,
    /// Reserved in the v0.1 contract even while no sync-failure producer is wired.
    pub sync_failure: SubscriptionFrequency,
}

impl NotificationTypeFrequencies {
    #[must_use]
    pub const fn from_legacy(
        discovery_frequency: SubscriptionFrequency,
        active_updates_enabled: bool,
    ) -> Self {
        let (discovery_match, discovery_digest) = match discovery_frequency {
            SubscriptionFrequency::Immediate => {
                (SubscriptionFrequency::Immediate, SubscriptionFrequency::Off)
            }
            SubscriptionFrequency::Daily => {
                (SubscriptionFrequency::Off, SubscriptionFrequency::Daily)
            }
            SubscriptionFrequency::Weekly => {
                (SubscriptionFrequency::Off, SubscriptionFrequency::Weekly)
            }
            SubscriptionFrequency::Off => (SubscriptionFrequency::Off, SubscriptionFrequency::Off),
        };
        Self {
            discovery_match,
            discovery_digest,
            user_selected_reminder: SubscriptionFrequency::Immediate,
            active_paper_version: if active_updates_enabled {
                SubscriptionFrequency::Immediate
            } else {
                SubscriptionFrequency::Off
            },
            sync_failure: SubscriptionFrequency::Immediate,
        }
    }

    #[must_use]
    pub const fn legacy_discovery_frequency(self) -> SubscriptionFrequency {
        if self.discovery_match.is_enabled() {
            self.discovery_match
        } else {
            self.discovery_digest
        }
    }

    #[must_use]
    pub const fn legacy_active_updates_enabled(self) -> bool {
        self.active_paper_version.is_enabled()
    }

    #[must_use]
    pub const fn discovery_enabled(self) -> bool {
        self.discovery_match.is_enabled() || self.discovery_digest.is_enabled()
    }

    #[must_use]
    pub const fn has_unambiguous_discovery_projection(self) -> bool {
        !(self.discovery_match.is_enabled() && self.discovery_digest.is_enabled())
    }

    #[must_use]
    pub const fn frequency_for(self, notification_type: NotificationType) -> SubscriptionFrequency {
        match notification_type {
            NotificationType::DiscoveryMatch => self.discovery_match,
            NotificationType::DiscoveryDigest => self.discovery_digest,
            NotificationType::UserSelectedReminder => self.user_selected_reminder,
            NotificationType::ActivePaperVersion => self.active_paper_version,
            NotificationType::SyncFailure => self.sync_failure,
        }
    }
}

impl Default for NotificationTypeFrequencies {
    fn default() -> Self {
        Self {
            discovery_match: SubscriptionFrequency::Off,
            discovery_digest: SubscriptionFrequency::Daily,
            user_selected_reminder: SubscriptionFrequency::Immediate,
            active_paper_version: SubscriptionFrequency::Off,
            sync_failure: SubscriptionFrequency::Immediate,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationScope {
    QueueOwned,
    Discovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationEntityType {
    Paper,
    Subscription,
    Digest,
    Sync,
}

impl NotificationEntityType {
    pub const ALL: [Self; 4] = [Self::Paper, Self::Subscription, Self::Digest, Self::Sync];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Paper => "paper",
            Self::Subscription => "subscription",
            Self::Digest => "digest",
            Self::Sync => "sync",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "paper" => Some(Self::Paper),
            "subscription" => Some(Self::Subscription),
            "digest" => Some(Self::Digest),
            "sync" => Some(Self::Sync),
            _ => None,
        }
    }
}

impl NotificationScope {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::QueueOwned => "queue_owned",
            Self::Discovery => "discovery",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationDeliveryEligibility {
    Eligible,
    DeferredQueueNonempty,
    DeferredUnknown,
    Expired,
}

impl NotificationDeliveryEligibility {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Eligible => "eligible",
            Self::DeferredQueueNonempty => "deferred_queue_nonempty",
            Self::DeferredUnknown => "deferred_unknown",
            Self::Expired => "expired",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Notification {
    pub id: Uuid,
    pub notification_type: NotificationType,
    pub scope: NotificationScope,
    pub entity_type: NotificationEntityType,
    pub entity_id: Option<Uuid>,
    pub payload: Value,
    pub delivery_eligibility: NotificationDeliveryEligibility,
    pub eligibility_library_revision: Option<i64>,
    pub created_at: DateTime<Utc>,
    pub read_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub papers: Vec<PaperSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[allow(clippy::struct_excessive_bools)]
pub struct NotificationPreferences {
    /// Deprecated compatibility projection of `type_frequencies` retained for
    /// clients and older servers during rollback.
    pub discovery_frequency: SubscriptionFrequency,
    pub type_frequencies: NotificationTypeFrequencies,
    pub quiet_hours_start: Option<NaiveTime>,
    pub quiet_hours_end: Option<NaiveTime>,
    pub timezone: String,
    pub in_app_enabled: bool,
    pub push_enabled: bool,
    pub email_enabled: bool,
    pub global_pause: bool,
    /// Deprecated compatibility projection of `active_paper_version`.
    pub active_updates_enabled: bool,
    pub daily_budget: u16,
    pub revision: i64,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorkScheduleSummary {
    pub subscriptions: u64,
    pub expirations: u64,
    pub queue_rechecks: u64,
    pub reminders: u64,
    pub active_updates: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationWorkKind {
    EvaluateSubscriptions,
    EvaluateReminders,
    EvaluateActivePapers,
    BuildNotificationDigest,
    ExpireNotifications,
    RecheckNotificationQueueEligibility,
}

impl NotificationWorkKind {
    pub const ALL: [Self; 6] = [
        Self::EvaluateSubscriptions,
        Self::EvaluateReminders,
        Self::EvaluateActivePapers,
        Self::BuildNotificationDigest,
        Self::ExpireNotifications,
        Self::RecheckNotificationQueueEligibility,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::EvaluateSubscriptions => "evaluate_subscriptions",
            Self::EvaluateReminders => "evaluate_reminders",
            Self::EvaluateActivePapers => "evaluate_active_papers",
            Self::BuildNotificationDigest => "build_notification_digest",
            Self::ExpireNotifications => "expire_notifications",
            Self::RecheckNotificationQueueEligibility => "recheck_notification_queue_eligibility",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationWorkItem {
    pub id: Uuid,
    pub user_id: AuthenticatedUserId,
    pub kind: NotificationWorkKind,
    pub subscription_id: Option<Uuid>,
    pub window_key: String,
    pub attempt: u16,
    pub max_attempts: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkClaim {
    pub worker_id: String,
    pub now: DateTime<Utc>,
    pub lease_seconds: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkClaimOutcome {
    pub item: Option<NotificationWorkItem>,
    /// Work kinds terminalized because their last lease expired. The store
    /// returns each bounded row so maintenance can account for every failure.
    pub lease_exhausted: Vec<NotificationWorkKind>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkRetryDisposition {
    Queued,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefItemWrite {
    pub ordinal: u16,
    pub paper_id: PaperId,
    pub source: FeedItemSource,
    pub reason_codes: Vec<RecommendationReasonCode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefWrite {
    pub id: Uuid,
    pub mode: BriefMode,
    pub recommendation_mode: Option<RecommendationMode>,
    pub library_revision: i64,
    pub recommendation_batch_id: Option<Uuid>,
    pub local_date: NaiveDate,
    pub items: Vec<BriefItemWrite>,
}

#[cfg(test)]
mod tests {
    use super::{
        NotificationEntityType, NotificationType, NotificationTypeFrequencies,
        SubscriptionFrequency,
    };

    #[test]
    fn notification_entity_types_are_an_exact_closed_wire_set() {
        let values = NotificationEntityType::ALL.map(NotificationEntityType::as_str);
        assert_eq!(values, ["paper", "subscription", "digest", "sync"]);
        assert_eq!(
            serde_json::to_value(NotificationEntityType::ALL).unwrap(),
            serde_json::json!(values)
        );
        assert!(values.iter().all(|value| {
            NotificationEntityType::parse(value).is_some_and(|kind| kind.as_str() == *value)
        }));
        assert_eq!(NotificationEntityType::parse("unknown"), None);
        assert!(serde_json::from_str::<NotificationEntityType>("\"unknown\"").is_err());
    }

    #[test]
    fn notification_frequencies_are_closed_and_have_exact_defaults() {
        let values = SubscriptionFrequency::ALL.map(SubscriptionFrequency::as_str);
        assert_eq!(values, ["immediate", "daily", "weekly", "off"]);
        assert!(values.iter().all(|value| {
            SubscriptionFrequency::parse(value)
                .is_some_and(|frequency| frequency.as_str() == *value)
        }));
        assert_eq!(SubscriptionFrequency::parse("unknown"), None);

        let notification_types = NotificationType::ALL.map(NotificationType::as_str);
        assert_eq!(
            notification_types,
            [
                "discovery_match",
                "discovery_digest",
                "user_selected_reminder",
                "active_paper_version",
                "sync_failure"
            ]
        );
        assert!(notification_types.iter().all(|value| {
            NotificationType::parse(value)
                .is_some_and(|notification_type| notification_type.as_str() == *value)
        }));
        assert_eq!(NotificationType::parse("unknown"), None);

        let defaults = NotificationTypeFrequencies::default();
        assert_eq!(
            serde_json::to_value(defaults).unwrap(),
            serde_json::json!({
                "discovery_match": "off",
                "discovery_digest": "daily",
                "user_selected_reminder": "immediate",
                "active_paper_version": "off",
                "sync_failure": "immediate"
            })
        );
        assert_eq!(
            defaults.frequency_for(NotificationType::SyncFailure),
            SubscriptionFrequency::Immediate
        );
        assert!(
            serde_json::from_value::<NotificationTypeFrequencies>(serde_json::json!({
                "discovery_match": "off",
                "discovery_digest": "daily",
                "user_selected_reminder": "immediate",
                "active_paper_version": "off",
                "sync_failure": "sometimes"
            }))
            .is_err()
        );
    }

    #[test]
    fn legacy_frequency_projection_is_deterministic_and_unambiguous() {
        for (legacy, expected_match, expected_digest) in [
            (
                SubscriptionFrequency::Immediate,
                SubscriptionFrequency::Immediate,
                SubscriptionFrequency::Off,
            ),
            (
                SubscriptionFrequency::Daily,
                SubscriptionFrequency::Off,
                SubscriptionFrequency::Daily,
            ),
            (
                SubscriptionFrequency::Weekly,
                SubscriptionFrequency::Off,
                SubscriptionFrequency::Weekly,
            ),
            (
                SubscriptionFrequency::Off,
                SubscriptionFrequency::Off,
                SubscriptionFrequency::Off,
            ),
        ] {
            let projected = NotificationTypeFrequencies::from_legacy(legacy, false);
            assert_eq!(projected.discovery_match, expected_match);
            assert_eq!(projected.discovery_digest, expected_digest);
            assert_eq!(projected.legacy_discovery_frequency(), legacy);
            assert!(projected.has_unambiguous_discovery_projection());
        }

        let active = NotificationTypeFrequencies::from_legacy(SubscriptionFrequency::Daily, true);
        assert_eq!(
            active.active_paper_version,
            SubscriptionFrequency::Immediate
        );
        assert!(active.legacy_active_updates_enabled());

        let ambiguous = NotificationTypeFrequencies {
            discovery_match: SubscriptionFrequency::Immediate,
            discovery_digest: SubscriptionFrequency::Daily,
            ..NotificationTypeFrequencies::default()
        };
        assert!(!ambiguous.has_unambiguous_discovery_projection());
    }
}
