use engagement::{
    BriefMode, BriefStatus, Notification, NotificationDeliveryEligibility, NotificationEntityType,
    NotificationPreferences, NotificationScope, NotificationType, NotificationTypeFrequencies,
    ReadingBrief, Subscription, SubscriptionFrequency, SubscriptionKind,
};
use reading_feed::{FeedItemSource, RecommendationMode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::format_timestamp;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RecommendationModeBody {
    Recent,
    Following,
    ForYou,
    Explore,
}

impl From<RecommendationModeBody> for RecommendationMode {
    fn from(value: RecommendationModeBody) -> Self {
        match value {
            RecommendationModeBody::Recent => Self::Recent,
            RecommendationModeBody::Following => Self::Following,
            RecommendationModeBody::ForYou => Self::ForYou,
            RecommendationModeBody::Explore => Self::Explore,
        }
    }
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct CreateReadingBriefBody {
    pub(crate) operation_id: Uuid,
    /// Explicit discovery mode. Omission uses the current research-profile
    /// preference when enabled, otherwise Recent.
    pub(crate) recommendation_mode: Option<RecommendationModeBody>,
    #[schema(max_length = 32)]
    pub(crate) category: Option<String>,
}

#[derive(Debug, Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpdateReadingBriefProgressBody {
    pub(crate) operation_id: Uuid,
    #[schema(minimum = 1)]
    pub(crate) expected_progress_revision: i64,
    #[schema(minimum = 0, maximum = 25)]
    pub(crate) position: u16,
}

impl std::fmt::Debug for CreateReadingBriefBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CreateReadingBriefBody")
            .field("operation_id", &self.operation_id)
            .field("recommendation_mode", &self.recommendation_mode)
            .field("category", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingBriefEnvelope {
    pub(crate) brief: Option<ReadingBriefResponse>,
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingBriefResponse {
    pub(crate) id: Uuid,
    pub(crate) mode: BriefMode,
    pub(crate) recommendation_mode: Option<RecommendationMode>,
    pub(crate) library_revision: i64,
    pub(crate) recommendation_batch_id: Option<Uuid>,
    pub(crate) local_date: String,
    pub(crate) position: u16,
    pub(crate) progress_revision: i64,
    pub(crate) status: BriefStatus,
    pub(crate) items: Vec<ReadingBriefItemResponse>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) completed_at: Option<String>,
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingBriefItemResponse {
    pub(crate) ordinal: u16,
    pub(crate) paper: domain::PaperSummary,
    pub(crate) source: FeedItemSource,
    pub(crate) reason_codes: Vec<domain::RecommendationReasonCode>,
}

impl From<ReadingBrief> for ReadingBriefResponse {
    fn from(value: ReadingBrief) -> Self {
        Self {
            id: value.id,
            mode: value.mode,
            recommendation_mode: value.recommendation_mode,
            library_revision: value.library_revision,
            recommendation_batch_id: value.recommendation_batch_id,
            local_date: value.local_date.to_string(),
            position: value.position,
            progress_revision: value.progress_revision,
            status: value.status,
            items: value
                .items
                .into_iter()
                .map(|item| ReadingBriefItemResponse {
                    ordinal: item.ordinal,
                    paper: item.paper,
                    source: item.source,
                    reason_codes: item.reason_codes,
                })
                .collect(),
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
            completed_at: value.completed_at.map(format_timestamp),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SubscriptionKindBody {
    Topic,
    Category,
    Author,
    SavedQuery,
}

impl From<SubscriptionKindBody> for SubscriptionKind {
    fn from(value: SubscriptionKindBody) -> Self {
        match value {
            SubscriptionKindBody::Topic => Self::Topic,
            SubscriptionKindBody::Category => Self::Category,
            SubscriptionKindBody::Author => Self::Author,
            SubscriptionKindBody::SavedQuery => Self::SavedQuery,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SubscriptionFrequencyBody {
    Immediate,
    Daily,
    Weekly,
    Off,
}

impl From<SubscriptionFrequencyBody> for SubscriptionFrequency {
    fn from(value: SubscriptionFrequencyBody) -> Self {
        match value {
            SubscriptionFrequencyBody::Immediate => Self::Immediate,
            SubscriptionFrequencyBody::Daily => Self::Daily,
            SubscriptionFrequencyBody::Weekly => Self::Weekly,
            SubscriptionFrequencyBody::Off => Self::Off,
        }
    }
}

impl From<SubscriptionFrequency> for SubscriptionFrequencyBody {
    fn from(value: SubscriptionFrequency) -> Self {
        match value {
            SubscriptionFrequency::Immediate => Self::Immediate,
            SubscriptionFrequency::Daily => Self::Daily,
            SubscriptionFrequency::Weekly => Self::Weekly,
            SubscriptionFrequency::Off => Self::Off,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct NotificationTypeFrequenciesBody {
    #[schema(default = "off")]
    pub(crate) discovery_match: SubscriptionFrequencyBody,
    #[schema(default = "daily")]
    pub(crate) discovery_digest: SubscriptionFrequencyBody,
    /// Omitted by pre-reminder clients; the server projects that omission to
    /// the canonical `immediate` default.
    #[schema(default = "immediate")]
    pub(crate) user_selected_reminder: Option<SubscriptionFrequencyBody>,
    #[schema(default = "off")]
    pub(crate) active_paper_version: SubscriptionFrequencyBody,
    #[schema(default = "immediate")]
    pub(crate) sync_failure: SubscriptionFrequencyBody,
}

impl From<NotificationTypeFrequenciesBody> for NotificationTypeFrequencies {
    fn from(value: NotificationTypeFrequenciesBody) -> Self {
        Self {
            discovery_match: value.discovery_match.into(),
            discovery_digest: value.discovery_digest.into(),
            user_selected_reminder: value
                .user_selected_reminder
                .unwrap_or(SubscriptionFrequencyBody::Immediate)
                .into(),
            active_paper_version: value.active_paper_version.into(),
            sync_failure: value.sync_failure.into(),
        }
    }
}

impl From<NotificationTypeFrequencies> for NotificationTypeFrequenciesBody {
    fn from(value: NotificationTypeFrequencies) -> Self {
        Self {
            discovery_match: value.discovery_match.into(),
            discovery_digest: value.discovery_digest.into(),
            user_selected_reminder: Some(value.user_selected_reminder.into()),
            active_paper_version: value.active_paper_version.into(),
            sync_failure: value.sync_failure.into(),
        }
    }
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct CreateSubscriptionBody {
    pub(crate) operation_id: Uuid,
    pub(crate) id: Uuid,
    pub(crate) kind: SubscriptionKindBody,
    #[schema(min_length = 1, max_length = 160)]
    pub(crate) key: String,
    #[schema(min_length = 1, max_length = 160)]
    pub(crate) label: String,
    pub(crate) saved_search_id: Option<Uuid>,
    pub(crate) frequency: SubscriptionFrequencyBody,
}

impl std::fmt::Debug for CreateSubscriptionBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CreateSubscriptionBody")
            .field("operation_id", &self.operation_id)
            .field("id", &self.id)
            .field("kind", &self.kind)
            .field("target", &"[redacted]")
            .field("frequency", &self.frequency)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpdateSubscriptionBody {
    pub(crate) operation_id: Uuid,
    pub(crate) kind: SubscriptionKindBody,
    #[schema(min_length = 1, max_length = 160)]
    pub(crate) key: String,
    #[schema(min_length = 1, max_length = 160)]
    pub(crate) label: String,
    pub(crate) saved_search_id: Option<Uuid>,
    pub(crate) frequency: SubscriptionFrequencyBody,
}

impl std::fmt::Debug for UpdateSubscriptionBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("UpdateSubscriptionBody")
            .field("operation_id", &self.operation_id)
            .field("kind", &self.kind)
            .field("target", &"[redacted]")
            .field("frequency", &self.frequency)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct SubscriptionsEnvelope {
    pub(crate) items: Vec<SubscriptionResponse>,
}

#[derive(Debug, Serialize)]
pub(crate) struct SubscriptionEnvelope {
    pub(crate) subscription: SubscriptionResponse,
}

#[derive(Debug, Serialize)]
pub(crate) struct SubscriptionResponse {
    pub(crate) id: Uuid,
    pub(crate) kind: SubscriptionKind,
    pub(crate) key: String,
    pub(crate) label: String,
    pub(crate) saved_search_id: Option<Uuid>,
    pub(crate) frequency: SubscriptionFrequencyBody,
    pub(crate) last_evaluated_at: Option<String>,
    pub(crate) revision: i64,
    pub(crate) deleted: bool,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

impl From<Subscription> for SubscriptionResponse {
    fn from(value: Subscription) -> Self {
        let saved_search_id = value
            .query_definition
            .as_ref()
            .and_then(|definition| definition.get("saved_search_id"))
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok());
        Self {
            id: value.id,
            kind: value.kind,
            key: value.key,
            label: value.label,
            saved_search_id,
            frequency: value.frequency.into(),
            last_evaluated_at: value.last_evaluated_at.map(format_timestamp),
            revision: value.revision,
            deleted: value.deleted_at.is_some(),
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Debug, Deserialize, utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
#[serde(deny_unknown_fields)]
pub(crate) struct NotificationListParams {
    #[param(minimum = 1, maximum = 50)]
    pub(crate) limit: Option<u16>,
}

#[derive(Debug, Serialize)]
pub(crate) struct NotificationsEnvelope {
    pub(crate) items: Vec<NotificationResponse>,
}

#[derive(Debug, Serialize)]
pub(crate) struct NotificationResponse {
    pub(crate) id: Uuid,
    pub(crate) notification_type: NotificationType,
    pub(crate) scope: NotificationScope,
    pub(crate) entity_type: NotificationEntityType,
    pub(crate) entity_id: Option<Uuid>,
    pub(crate) payload: Value,
    pub(crate) delivery_eligibility: NotificationDeliveryEligibility,
    pub(crate) eligibility_library_revision: Option<i64>,
    pub(crate) created_at: String,
    pub(crate) read_at: Option<String>,
    pub(crate) expires_at: Option<String>,
    pub(crate) papers: Vec<domain::PaperSummary>,
}

impl From<Notification> for NotificationResponse {
    fn from(value: Notification) -> Self {
        Self {
            id: value.id,
            notification_type: value.notification_type,
            scope: value.scope,
            entity_type: value.entity_type,
            entity_id: value.entity_id,
            payload: value.payload,
            delivery_eligibility: value.delivery_eligibility,
            eligibility_library_revision: value.eligibility_library_revision,
            created_at: format_timestamp(value.created_at),
            read_at: value.read_at.map(format_timestamp),
            expires_at: value.expires_at.map(format_timestamp),
            papers: value.papers,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct NotificationMutationEnvelope {
    pub(crate) affected: u64,
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
#[allow(clippy::struct_excessive_bools)] // Closed wire contract mirrors channel/pause switches.
pub(crate) struct NotificationPreferencesBody {
    pub(crate) operation_id: Uuid,
    /// Deprecated compatibility projection. Omitted canonical frequencies are
    /// deterministically derived from this field and `active_updates_enabled`.
    #[schema(schema_with = deprecated_notification_frequency_schema)]
    pub(crate) discovery_frequency: SubscriptionFrequencyBody,
    pub(crate) type_frequencies: Option<NotificationTypeFrequenciesBody>,
    #[schema(example = "22:00:00")]
    pub(crate) quiet_hours_start: Option<String>,
    #[schema(example = "07:00:00")]
    pub(crate) quiet_hours_end: Option<String>,
    #[schema(min_length = 1, max_length = 64, example = "Asia/Shanghai")]
    pub(crate) timezone: String,
    pub(crate) in_app_enabled: bool,
    #[schema(schema_with = disabled_notification_channel_schema)]
    pub(crate) push_enabled: bool,
    #[schema(schema_with = disabled_notification_channel_schema)]
    pub(crate) email_enabled: bool,
    pub(crate) global_pause: bool,
    /// Deprecated compatibility projection of `active_paper_version`.
    #[schema(deprecated)]
    pub(crate) active_updates_enabled: bool,
    #[schema(minimum = 1, maximum = 20)]
    pub(crate) daily_budget: u16,
}

impl NotificationPreferencesBody {
    #[must_use]
    pub(crate) fn canonical_type_frequencies(&self) -> NotificationTypeFrequencies {
        self.type_frequencies.map_or_else(
            || {
                NotificationTypeFrequencies::from_legacy(
                    self.discovery_frequency.into(),
                    self.active_updates_enabled,
                )
            },
            Into::into,
        )
    }
}

fn disabled_notification_channel_schema() -> utoipa::openapi::schema::Object {
    utoipa::openapi::schema::ObjectBuilder::new()
        .schema_type(utoipa::openapi::schema::Type::Boolean)
        .enum_values(Some([false]))
        .build()
}

fn deprecated_notification_frequency_schema() -> utoipa::openapi::schema::Object {
    utoipa::openapi::schema::ObjectBuilder::new()
        .schema_type(utoipa::openapi::schema::Type::String)
        .enum_values(Some(["immediate", "daily", "weekly", "off"]))
        .deprecated(Some(utoipa::openapi::Deprecated::True))
        .build()
}

impl std::fmt::Debug for NotificationPreferencesBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("NotificationPreferencesBody")
            .field("operation_id", &self.operation_id)
            .field("channels", &"[redacted]")
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct NotificationPreferencesEnvelope {
    pub(crate) preferences: NotificationPreferencesResponse,
}

#[derive(Debug, Serialize)]
#[allow(clippy::struct_excessive_bools)] // Response mirrors the validated preference record.
pub(crate) struct NotificationPreferencesResponse {
    /// Deprecated compatibility projection of `type_frequencies`.
    pub(crate) discovery_frequency: SubscriptionFrequencyBody,
    pub(crate) type_frequencies: NotificationTypeFrequenciesBody,
    pub(crate) quiet_hours_start: Option<String>,
    pub(crate) quiet_hours_end: Option<String>,
    pub(crate) timezone: String,
    pub(crate) in_app_enabled: bool,
    pub(crate) push_enabled: bool,
    pub(crate) email_enabled: bool,
    pub(crate) global_pause: bool,
    /// Deprecated compatibility projection of `active_paper_version`.
    pub(crate) active_updates_enabled: bool,
    pub(crate) daily_budget: u16,
    pub(crate) revision: i64,
    pub(crate) updated_at: String,
}

impl From<NotificationPreferences> for NotificationPreferencesResponse {
    fn from(value: NotificationPreferences) -> Self {
        let type_frequencies = value.type_frequencies;
        Self {
            discovery_frequency: type_frequencies.legacy_discovery_frequency().into(),
            type_frequencies: type_frequencies.into(),
            quiet_hours_start: value.quiet_hours_start.map(|time| time.to_string()),
            quiet_hours_end: value.quiet_hours_end.map(|time| time.to_string()),
            timezone: value.timezone,
            in_app_enabled: value.in_app_enabled,
            push_enabled: value.push_enabled,
            email_enabled: value.email_enabled,
            global_pause: value.global_pause,
            active_updates_enabled: type_frequencies.legacy_active_updates_enabled(),
            daily_budget: value.daily_budget,
            revision: value.revision,
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_bodies_are_strict_and_push_cannot_hide_in_unknown_fields() {
        assert!(
            serde_json::from_value::<CreateReadingBriefBody>(serde_json::json!({
                "operation_id": Uuid::now_v7(),
                "prepare": true
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<CreateSubscriptionBody>(serde_json::json!({
                "operation_id": Uuid::now_v7(),
                "id": Uuid::now_v7(),
                "kind": "topic",
                "key": "retrieval",
                "label": "Retrieval",
                "frequency": "daily",
                "raw_query": "private"
            }))
            .is_err()
        );
    }

    #[test]
    fn legacy_notification_preferences_project_to_the_canonical_object() {
        let body = serde_json::from_value::<NotificationPreferencesBody>(serde_json::json!({
            "operation_id": Uuid::now_v7(),
            "discovery_frequency": "weekly",
            "quiet_hours_start": null,
            "quiet_hours_end": null,
            "timezone": "UTC",
            "in_app_enabled": true,
            "push_enabled": false,
            "email_enabled": false,
            "global_pause": false,
            "active_updates_enabled": true,
            "daily_budget": 5
        }))
        .unwrap();
        assert_eq!(
            body.canonical_type_frequencies(),
            NotificationTypeFrequencies {
                discovery_match: SubscriptionFrequency::Off,
                discovery_digest: SubscriptionFrequency::Weekly,
                user_selected_reminder: SubscriptionFrequency::Immediate,
                active_paper_version: SubscriptionFrequency::Immediate,
                sync_failure: SubscriptionFrequency::Immediate,
            }
        );
    }

    #[test]
    fn canonical_notification_preferences_are_closed_and_exact() {
        let operation_id = Uuid::now_v7();
        let body = serde_json::from_value::<NotificationPreferencesBody>(serde_json::json!({
            "operation_id": operation_id,
            "discovery_frequency": "immediate",
            "type_frequencies": {
                "discovery_match": "immediate",
                "discovery_digest": "off",
                "user_selected_reminder": "weekly",
                "active_paper_version": "daily",
                "sync_failure": "off"
            },
            "quiet_hours_start": null,
            "quiet_hours_end": null,
            "timezone": "UTC",
            "in_app_enabled": true,
            "push_enabled": false,
            "email_enabled": false,
            "global_pause": false,
            "active_updates_enabled": true,
            "daily_budget": 5
        }))
        .unwrap();
        assert_eq!(
            body.canonical_type_frequencies().discovery_match,
            SubscriptionFrequency::Immediate
        );

        for invalid in [
            serde_json::json!({
                "discovery_match": "sometimes",
                "discovery_digest": "off",
                "user_selected_reminder": "immediate",
                "active_paper_version": "off",
                "sync_failure": "immediate"
            }),
            serde_json::json!({
                "discovery_match": "off",
                "discovery_digest": "daily",
                "user_selected_reminder": "immediate",
                "active_paper_version": "off",
                "sync_failure": "immediate",
                "other": "daily"
            }),
        ] {
            assert!(serde_json::from_value::<NotificationTypeFrequenciesBody>(invalid).is_err());
        }
    }

    #[test]
    fn notification_preference_response_always_includes_canonical_and_legacy_projections() {
        let type_frequencies = NotificationTypeFrequencies {
            discovery_match: SubscriptionFrequency::Off,
            discovery_digest: SubscriptionFrequency::Weekly,
            user_selected_reminder: SubscriptionFrequency::Immediate,
            active_paper_version: SubscriptionFrequency::Daily,
            sync_failure: SubscriptionFrequency::Off,
        };
        let value = serde_json::to_value(NotificationPreferencesResponse::from(
            NotificationPreferences {
                discovery_frequency: SubscriptionFrequency::Weekly,
                type_frequencies,
                quiet_hours_start: None,
                quiet_hours_end: None,
                timezone: "UTC".to_owned(),
                in_app_enabled: true,
                push_enabled: false,
                email_enabled: false,
                global_pause: false,
                active_updates_enabled: true,
                daily_budget: 5,
                revision: 1,
                updated_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
            },
        ))
        .unwrap();
        assert_eq!(value["discovery_frequency"], "weekly");
        assert_eq!(value["active_updates_enabled"], true);
        assert_eq!(
            value["type_frequencies"],
            serde_json::json!({
                "discovery_match": "off",
                "discovery_digest": "weekly",
                "user_selected_reminder": "immediate",
                "active_paper_version": "daily",
                "sync_failure": "off"
            })
        );
    }
}
