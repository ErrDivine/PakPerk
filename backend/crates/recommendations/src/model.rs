use std::collections::{BTreeMap, BTreeSet};

use domain::{PaperId, PaperSummary};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::RecommendationFeatures;

/// User-selectable discovery sources. The reading-feed queue gate sits above
/// this enum and may refuse to invoke every mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecommendationMode {
    Recent,
    Following,
    ForYou,
    Explore,
}

impl RecommendationMode {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Recent => "recent",
            Self::Following => "following",
            Self::ForYou => "for_you",
            Self::Explore => "explore",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "recent" => Some(Self::Recent),
            "following" => Some(Self::Following),
            "for_you" => Some(Self::ForYou),
            "explore" => Some(Self::Explore),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CandidateSource {
    Recent,
    CategoryFollow,
    TopicFollow,
    AuthorFollow,
    SavedQuery,
    FeedbackAffinity,
    InferredAffinity,
    Semantic,
    Citation,
    Exploration,
}

impl CandidateSource {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Recent => "recent",
            Self::CategoryFollow => "category_follow",
            Self::TopicFollow => "topic_follow",
            Self::AuthorFollow => "author_follow",
            Self::SavedQuery => "saved_query",
            Self::FeedbackAffinity => "feedback_affinity",
            Self::InferredAffinity => "inferred_affinity",
            Self::Semantic => "semantic",
            Self::Citation => "citation",
            Self::Exploration => "exploration",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "recent" => Some(Self::Recent),
            "category_follow" => Some(Self::CategoryFollow),
            "topic_follow" => Some(Self::TopicFollow),
            "author_follow" => Some(Self::AuthorFollow),
            "saved_query" => Some(Self::SavedQuery),
            "feedback_affinity" => Some(Self::FeedbackAffinity),
            "inferred_affinity" => Some(Self::InferredAffinity),
            "semantic" => Some(Self::Semantic),
            "citation" => Some(Self::Citation),
            "exploration" => Some(Self::Exploration),
            _ => None,
        }
    }
}

/// Only inactive historical library rows may seed personalized discovery.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HistoricalSeedState {
    Reviewed,
    Archived,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HistoricalSeed {
    pub paper_id: PaperId,
    pub title: String,
    pub state: HistoricalSeedState,
    #[serde(default)]
    pub topics: BTreeSet<String>,
    #[serde(default)]
    pub embedding: Vec<f32>,
}

/// Metadata-only candidate material. Full text, private notes, annotations,
/// dwell time, comments, and provider identity are intentionally impossible to
/// represent in this boundary.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CandidateDocument {
    pub paper: PaperSummary,
    #[serde(default)]
    pub topics: BTreeSet<String>,
    #[serde(default)]
    pub embedding: Vec<f32>,
    #[serde(default)]
    pub citation_neighbors: BTreeSet<PaperId>,
    pub metadata_completeness: f32,
}

/// Bounded, content-free history applied after candidate generation. Explicit
/// recommendation feedback is authoritative; qualified impressions are an
/// optional penalty signal and never decide queue eligibility.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecommendationCandidateHistory {
    pub qualified_impressions: u32,
    pub hidden: bool,
    pub negative_feedback: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiscoveryProfileSnapshot {
    pub personalization_enabled: bool,
    /// User-declared follows only. Feedback and inferred interests are kept in
    /// separate fields so explanations can never silently call them follows.
    #[serde(default)]
    pub categories: BTreeSet<String>,
    #[serde(default)]
    pub topics: BTreeSet<String>,
    #[serde(default)]
    pub authors: BTreeSet<String>,
    /// Candidate identities matched by an explicit account-owned saved query.
    /// The query text never crosses into the generation or explanation model.
    #[serde(default)]
    pub saved_query_matches: BTreeMap<PaperId, Uuid>,
    #[serde(default)]
    pub feedback_categories: BTreeSet<String>,
    #[serde(default)]
    pub inferred_categories: BTreeSet<String>,
    #[serde(default)]
    pub historical_seeds: Vec<HistoricalSeed>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ReasonEvidence {
    RecentCategory {
        category: String,
    },
    FollowedCategory {
        category: String,
    },
    FollowedTopic {
        topic: String,
    },
    FollowedAuthor {
        author: String,
    },
    SavedQuery {
        saved_search_id: Uuid,
    },
    FeedbackCategoryAffinity {
        category: String,
    },
    InferredCategoryAffinity {
        category: String,
    },
    HistoricalSeed {
        paper_id: PaperId,
        title: String,
        state: HistoricalSeedState,
        relation: HistoricalRelation,
    },
    Exploration {
        role: ExplorationRole,
    },
    DiversitySlot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HistoricalRelation {
    Semantic,
    Citation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExplorationRole {
    AdjacentTopic,
    UnderrepresentedCategory,
}

/// Candidate plus the exact inspectable evidence used to produce and explain
/// it. Reranking may reorder this value but may not invent sources or reasons.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GeneratedCandidate {
    pub document: CandidateDocument,
    pub sources: BTreeSet<CandidateSource>,
    pub features: RecommendationFeatures,
    pub reasons: Vec<ReasonEvidence>,
    pub qualified_impressions: u32,
    pub hidden: bool,
    pub negative_feedback: bool,
}
