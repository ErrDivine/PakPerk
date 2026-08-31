use research_profiles::{
    DiscoveryMode, InterestGroup, InterestSource, PreferredDiscoveryMode, ProfileAuthor,
    ProfileCategory, ProfileTopic, ResearchProfileSnapshot, ResetScope, TopicPolarity,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::format_timestamp;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PreferredDiscoveryModeBody {
    Recent,
    Following,
    ForYou,
    Explore,
}

impl From<PreferredDiscoveryModeBody> for PreferredDiscoveryMode {
    fn from(value: PreferredDiscoveryModeBody) -> Self {
        match value {
            PreferredDiscoveryModeBody::Recent => Self::Recent,
            PreferredDiscoveryModeBody::Following => Self::Following,
            PreferredDiscoveryModeBody::ForYou => Self::ForYou,
            PreferredDiscoveryModeBody::Explore => Self::Explore,
        }
    }
}

impl From<PreferredDiscoveryMode> for PreferredDiscoveryModeBody {
    fn from(value: PreferredDiscoveryMode) -> Self {
        match value {
            PreferredDiscoveryMode::Recent => Self::Recent,
            PreferredDiscoveryMode::Following => Self::Following,
            PreferredDiscoveryMode::ForYou => Self::ForYou,
            PreferredDiscoveryMode::Explore => Self::Explore,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DiscoveryModeBody {
    Focused,
    Balanced,
    Exploratory,
}

impl From<DiscoveryModeBody> for DiscoveryMode {
    fn from(value: DiscoveryModeBody) -> Self {
        match value {
            DiscoveryModeBody::Focused => Self::Focused,
            DiscoveryModeBody::Balanced => Self::Balanced,
            DiscoveryModeBody::Exploratory => Self::Exploratory,
        }
    }
}

impl From<DiscoveryMode> for DiscoveryModeBody {
    fn from(value: DiscoveryMode) -> Self {
        match value {
            DiscoveryMode::Focused => Self::Focused,
            DiscoveryMode::Balanced => Self::Balanced,
            DiscoveryMode::Exploratory => Self::Exploratory,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TopicPolarityBody {
    Positive,
    Negative,
}

impl From<TopicPolarityBody> for TopicPolarity {
    fn from(value: TopicPolarityBody) -> Self {
        match value {
            TopicPolarityBody::Positive => Self::Positive,
            TopicPolarityBody::Negative => Self::Negative,
        }
    }
}

impl From<TopicPolarity> for TopicPolarityBody {
    fn from(value: TopicPolarity) -> Self {
        match value {
            TopicPolarity::Positive => Self::Positive,
            TopicPolarity::Negative => Self::Negative,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum InterestSourceBody {
    Explicit,
    Feedback,
    Inferred,
}

impl From<InterestSource> for InterestSourceBody {
    fn from(value: InterestSource) -> Self {
        match value {
            InterestSource::Explicit => Self::Explicit,
            InterestSource::Feedback => Self::Feedback,
            InterestSource::Inferred => Self::Inferred,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ResetScopeBody {
    Inferred,
    All,
}

impl From<ResetScopeBody> for ResetScope {
    fn from(value: ResetScopeBody) -> Self {
        match value {
            ResetScopeBody::Inferred => Self::Inferred,
            ResetScopeBody::All => Self::All,
        }
    }
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExplicitCategoryBody {
    #[schema(min_length = 1, max_length = 32, example = "cs.CL")]
    pub(crate) category: String,
    #[schema(minimum = 0, maximum = 1, example = 0.8)]
    pub(crate) weight: f32,
}

impl std::fmt::Debug for ExplicitCategoryBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ExplicitCategoryBody")
            .field("category", &"[redacted]")
            .field("weight", &self.weight)
            .finish()
    }
}

#[derive(Clone, Default, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpdateResearchProfileBody {
    pub(crate) operation_id: Uuid,
    pub(crate) personalization_enabled: Option<bool>,
    pub(crate) preferred_discovery_mode: Option<PreferredDiscoveryModeBody>,
    pub(crate) discovery_mode: Option<DiscoveryModeBody>,
    #[schema(minimum = 15, maximum = 25)]
    pub(crate) brief_size: Option<u16>,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) recency_weight: Option<f32>,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) novelty_weight: Option<f32>,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) diversity_weight: Option<f32>,
    #[schema(max_items = 32)]
    pub(crate) explicit_categories: Option<Vec<ExplicitCategoryBody>>,
}

impl std::fmt::Debug for UpdateResearchProfileBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("UpdateResearchProfileBody")
            .field("operation_id", &self.operation_id)
            .field("preferences", &"[redacted]")
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpsertProfileTopicBody {
    pub(crate) operation_id: Uuid,
    pub(crate) polarity: TopicPolarityBody,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) strength: f32,
    #[schema(required = false, nullable, min_length = 1, max_length = 160)]
    pub(crate) user_alias: Option<String>,
}

impl std::fmt::Debug for UpsertProfileTopicBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("UpsertProfileTopicBody")
            .field("operation_id", &self.operation_id)
            .field("interest", &"[redacted]")
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpsertProfileAuthorBody {
    pub(crate) operation_id: Uuid,
    #[schema(min_length = 1, max_length = 200)]
    pub(crate) display_name: String,
}

impl std::fmt::Debug for UpsertProfileAuthorBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("UpsertProfileAuthorBody")
            .field("operation_id", &self.operation_id)
            .field("display_name", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ResetResearchProfileBody {
    pub(crate) operation_id: Uuid,
    pub(crate) scope: ResetScopeBody,
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct ResearchProfileEnvelope {
    pub(crate) profile: ResearchProfileResponse,
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct ResearchProfileResponse {
    pub(crate) personalization_enabled: bool,
    pub(crate) preferred_discovery_mode: PreferredDiscoveryModeBody,
    pub(crate) discovery_mode: DiscoveryModeBody,
    #[schema(minimum = 15, maximum = 25)]
    pub(crate) brief_size: u16,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) recency_weight: f32,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) novelty_weight: f32,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) diversity_weight: f32,
    #[schema(minimum = 0)]
    pub(crate) profile_revision: i64,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
    /// These settings configure only the future fallback after server-proven
    /// queue emptiness; they never change queue state.
    pub(crate) queue_override: bool,
}

impl From<&ResearchProfileSnapshot> for ResearchProfileResponse {
    fn from(value: &ResearchProfileSnapshot) -> Self {
        Self {
            personalization_enabled: value.settings.personalization_enabled,
            preferred_discovery_mode: value.settings.preferred_discovery_mode.into(),
            discovery_mode: value.settings.discovery_mode.into(),
            brief_size: value.settings.brief_size,
            recency_weight: value.settings.recency_weight,
            novelty_weight: value.settings.novelty_weight,
            diversity_weight: value.settings.diversity_weight,
            profile_revision: value.profile_revision,
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
            queue_override: false,
        }
    }
}

impl From<&ResearchProfileSnapshot> for ResearchProfileEnvelope {
    fn from(value: &ResearchProfileSnapshot) -> Self {
        Self {
            profile: value.into(),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct ProfileCategoryResponse {
    pub(crate) category: String,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) weight: f32,
    pub(crate) source: InterestSourceBody,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
}

impl From<&ProfileCategory> for ProfileCategoryResponse {
    fn from(value: &ProfileCategory) -> Self {
        Self {
            category: value.category.clone(),
            weight: value.weight,
            source: value.source.into(),
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct ProfileTopicResponse {
    pub(crate) topic_id: Uuid,
    pub(crate) canonical_key: String,
    pub(crate) label: String,
    pub(crate) source_vocabulary: String,
    pub(crate) polarity: TopicPolarityBody,
    #[schema(minimum = 0, maximum = 1)]
    pub(crate) strength: f32,
    pub(crate) source: InterestSourceBody,
    #[schema(required = true, nullable)]
    pub(crate) user_alias: Option<String>,
    #[schema(required = true, nullable)]
    pub(crate) explanation_source_id: Option<Uuid>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
}

impl From<&ProfileTopic> for ProfileTopicResponse {
    fn from(value: &ProfileTopic) -> Self {
        Self {
            topic_id: value.topic.id,
            canonical_key: value.topic.canonical_key.clone(),
            label: value.topic.label.clone(),
            source_vocabulary: value.topic.source_vocabulary.clone(),
            polarity: value.polarity.into(),
            strength: value.strength,
            source: value.source.into(),
            user_alias: value.user_alias.clone(),
            explanation_source_id: value.explanation_source_id,
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct ProfileAuthorResponse {
    pub(crate) author_key: String,
    pub(crate) display_name: String,
    pub(crate) source: InterestSourceBody,
    #[schema(required = true, nullable)]
    pub(crate) explanation_source_id: Option<Uuid>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
}

impl From<&ProfileAuthor> for ProfileAuthorResponse {
    fn from(value: &ProfileAuthor) -> Self {
        Self {
            author_key: value.author_key.clone(),
            display_name: value.display_name.clone(),
            source: value.source.into(),
            explanation_source_id: value.explanation_source_id,
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct InterestGroupResponse {
    pub(crate) categories: Vec<ProfileCategoryResponse>,
    pub(crate) topics: Vec<ProfileTopicResponse>,
    pub(crate) authors: Vec<ProfileAuthorResponse>,
}

impl From<&InterestGroup> for InterestGroupResponse {
    fn from(value: &InterestGroup) -> Self {
        Self {
            categories: value.categories.iter().map(Into::into).collect(),
            topics: value.topics.iter().map(Into::into).collect(),
            authors: value.authors.iter().map(Into::into).collect(),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct ResearchProfileInterestsEnvelope {
    #[schema(minimum = 0)]
    pub(crate) profile_revision: i64,
    pub(crate) explicit: InterestGroupResponse,
    pub(crate) feedback: InterestGroupResponse,
    pub(crate) inferred: InterestGroupResponse,
}

impl From<&ResearchProfileSnapshot> for ResearchProfileInterestsEnvelope {
    fn from(value: &ResearchProfileSnapshot) -> Self {
        Self {
            profile_revision: value.profile_revision,
            explicit: (&value.interests.explicit).into(),
            feedback: (&value.interests.feedback).into(),
            inferred: (&value.interests.inferred).into(),
        }
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub(crate) struct ResearchProfileExportEnvelope {
    pub(crate) schema_version: u16,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) exported_at: String,
    pub(crate) profile: ResearchProfileResponse,
    pub(crate) interests: ResearchProfileInterestsEnvelope,
    pub(crate) operation_ledger_included: bool,
    pub(crate) raw_interaction_history_included: bool,
}

impl ResearchProfileExportEnvelope {
    pub(crate) fn new(
        value: &ResearchProfileSnapshot,
        exported_at: chrono::DateTime<chrono::Utc>,
    ) -> Self {
        Self {
            schema_version: 1,
            exported_at: format_timestamp(exported_at),
            profile: value.into(),
            interests: value.into(),
            // The idempotency ledger contains only operational hashes and is
            // neither user profile content nor useful export material.
            operation_ledger_included: false,
            raw_interaction_history_included: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone as _, Utc};
    use domain::AuthenticatedUserId;
    use research_profiles::{ProfileInterests, ProfileSettings};

    use super::*;

    #[test]
    fn write_bodies_are_strict_and_debug_redacts_interest_text() {
        let operation_id = Uuid::now_v7();
        let body: UpdateResearchProfileBody = serde_json::from_value(serde_json::json!({
            "operation_id": operation_id,
            "explicit_categories": [{"category":"cs.CL","weight":0.8}]
        }))
        .unwrap();
        let debug = format!("{body:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("cs.CL"));
        assert!(
            serde_json::from_value::<UpdateResearchProfileBody>(serde_json::json!({
                "operation_id": operation_id,
                "queue_state": "empty"
            }))
            .is_err()
        );
    }

    #[test]
    fn export_is_current_bounded_and_omits_account_and_operation_material() {
        let now = Utc.with_ymd_and_hms(2026, 8, 19, 0, 0, 0).unwrap();
        let snapshot = ResearchProfileSnapshot {
            user_id: AuthenticatedUserId::new(Uuid::now_v7()),
            settings: ProfileSettings::default(),
            profile_revision: 0,
            interests: ProfileInterests::default(),
            created_at: now,
            updated_at: now,
        };
        let json =
            serde_json::to_value(ResearchProfileExportEnvelope::new(&snapshot, now)).unwrap();
        assert!(json.get("user_id").is_none());
        assert!(json["profile"].get("user_id").is_none());
        assert_eq!(json["operation_ledger_included"], false);
        assert_eq!(json["raw_interaction_history_included"], false);
        assert!(json["interests"]["explicit"].is_object());
        assert!(json["interests"]["feedback"].is_object());
        assert!(json["interests"]["inferred"].is_object());
    }
}
