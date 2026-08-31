use chrono::{DateTime, Utc};
use domain::AuthenticatedUserId;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PreferredDiscoveryMode {
    Recent,
    Following,
    ForYou,
    Explore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiscoveryMode {
    Focused,
    Balanced,
    Exploratory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InterestSource {
    Explicit,
    Feedback,
    Inferred,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TopicPolarity {
    Positive,
    Negative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResetScope {
    Inferred,
    All,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileSettings {
    pub personalization_enabled: bool,
    pub preferred_discovery_mode: PreferredDiscoveryMode,
    pub discovery_mode: DiscoveryMode,
    pub brief_size: u16,
    pub recency_weight: f32,
    pub novelty_weight: f32,
    pub diversity_weight: f32,
}

impl Default for ProfileSettings {
    fn default() -> Self {
        Self {
            // Behavioral personalization is opt-in even after the route flag
            // is enabled. Explicit Following preferences remain usable.
            personalization_enabled: false,
            preferred_discovery_mode: PreferredDiscoveryMode::Recent,
            discovery_mode: DiscoveryMode::Balanced,
            brief_size: 20,
            recency_weight: 0.5,
            novelty_weight: 0.3,
            diversity_weight: 0.3,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileCategory {
    pub category: String,
    pub weight: f32,
    pub source: InterestSource,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Topic {
    pub id: Uuid,
    pub canonical_key: String,
    pub label: String,
    pub normalized_label: String,
    pub source_vocabulary: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileTopic {
    pub topic: Topic,
    pub polarity: TopicPolarity,
    pub strength: f32,
    pub source: InterestSource,
    pub user_alias: Option<String>,
    pub explanation_source_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileAuthor {
    pub author_key: String,
    pub display_name: String,
    pub source: InterestSource,
    pub explanation_source_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct InterestGroup {
    pub categories: Vec<ProfileCategory>,
    pub topics: Vec<ProfileTopic>,
    pub authors: Vec<ProfileAuthor>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProfileInterests {
    pub explicit: InterestGroup,
    pub feedback: InterestGroup,
    pub inferred: InterestGroup,
}

impl ProfileInterests {
    #[must_use]
    pub fn group_mut(&mut self, source: InterestSource) -> &mut InterestGroup {
        match source {
            InterestSource::Explicit => &mut self.explicit,
            InterestSource::Feedback => &mut self.feedback,
            InterestSource::Inferred => &mut self.inferred,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResearchProfileSnapshot {
    pub user_id: AuthenticatedUserId,
    pub settings: ProfileSettings,
    /// Zero denotes a virtual default profile with no persisted mutation yet.
    pub profile_revision: i64,
    pub interests: ProfileInterests,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ExplicitCategoryInput {
    pub category: String,
    pub weight: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TopicFollowInput {
    pub topic_id: Uuid,
    pub polarity: TopicPolarity,
    pub strength: f32,
    pub user_alias: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthorFollowInput {
    pub author_key: String,
    pub display_name: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProfileSettingsPatch {
    pub personalization_enabled: Option<bool>,
    pub preferred_discovery_mode: Option<PreferredDiscoveryMode>,
    pub discovery_mode: Option<DiscoveryMode>,
    pub brief_size: Option<u16>,
    pub recency_weight: Option<f32>,
    pub novelty_weight: Option<f32>,
    pub diversity_weight: Option<f32>,
    /// Replaces only explicit categories; feedback and inferred rows remain
    /// separate unless personalization is disabled or reset.
    pub explicit_categories: Option<Vec<ExplicitCategoryInput>>,
}

impl ProfileSettingsPatch {
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.personalization_enabled.is_none()
            && self.preferred_discovery_mode.is_none()
            && self.discovery_mode.is_none()
            && self.brief_size.is_none()
            && self.recency_weight.is_none()
            && self.novelty_weight.is_none()
            && self.diversity_weight.is_none()
            && self.explicit_categories.is_none()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileMutationKind {
    UpdateSettings,
    UpsertTopic,
    DeleteTopic,
    UpsertAuthor,
    DeleteAuthor,
    ResetInferred,
    ResetAll,
}

impl ProfileMutationKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::UpdateSettings => "update_settings",
            Self::UpsertTopic => "upsert_topic",
            Self::DeleteTopic => "delete_topic",
            Self::UpsertAuthor => "upsert_author",
            Self::DeleteAuthor => "delete_author",
            Self::ResetInferred => "reset_inferred",
            Self::ResetAll => "reset_all",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ProfileMutation {
    UpdateSettings(ProfileSettingsPatch),
    UpsertTopic(TopicFollowInput),
    DeleteTopic { topic_id: Uuid },
    UpsertAuthor(AuthorFollowInput),
    DeleteAuthor { author_key: String },
    Reset(ResetScope),
}

impl ProfileMutation {
    #[must_use]
    pub const fn kind(&self) -> ProfileMutationKind {
        match self {
            Self::UpdateSettings(_) => ProfileMutationKind::UpdateSettings,
            Self::UpsertTopic(_) => ProfileMutationKind::UpsertTopic,
            Self::DeleteTopic { .. } => ProfileMutationKind::DeleteTopic,
            Self::UpsertAuthor(_) => ProfileMutationKind::UpsertAuthor,
            Self::DeleteAuthor { .. } => ProfileMutationKind::DeleteAuthor,
            Self::Reset(ResetScope::Inferred) => ProfileMutationKind::ResetInferred,
            Self::Reset(ResetScope::All) => ProfileMutationKind::ResetAll,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct MutationFingerprint([u8; 32]);

impl MutationFingerprint {
    #[must_use]
    pub const fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl std::fmt::Debug for MutationFingerprint {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("MutationFingerprint([redacted])")
    }
}
