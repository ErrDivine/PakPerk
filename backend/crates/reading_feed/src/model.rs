use chrono::{DateTime, Utc};
use domain::{
    AuthenticatedUserId, LibrarySaveSourceKind, LibraryState, PaperId, PaperSummary,
    RecommendationReasonCode,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// The two closed modes exposed by the authenticated reading feed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedMode {
    ToRead,
    Recommendations,
}

/// A closed source label suitable for API serialization and bounded metrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedItemSource {
    ToRead,
    DiscoveryV1,
    RecentV1,
    FollowingV1,
    ForYouV1,
    ExploreV1,
}

/// User preference applied only after the same server snapshot proves the
/// active queue empty. It never influences queue eligibility.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecommendationMode {
    #[default]
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
}

/// Stable ordering policy encoded into every continuation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadingFeedCursorOrdering {
    QueueFifoV1,
    DiscoveryNewestV1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ToReadPosition {
    #[serde(rename = "at")]
    pub saved_at: DateTime<Utc>,
    #[serde(rename = "id")]
    pub paper_id: PaperId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecommendationPosition {
    #[serde(rename = "at")]
    pub published_at: DateTime<Utc>,
    #[serde(rename = "id")]
    pub paper_id: PaperId,
}

/// Mode-specific ordering coordinates. The redundant mode and ordering claims
/// intentionally make policy changes fail closed instead of being inferred.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ReadingFeedCursorPosition {
    ToRead {
        #[serde(flatten)]
        position: ToReadPosition,
    },
    Recommendations {
        #[serde(flatten)]
        position: RecommendationPosition,
    },
}

impl ReadingFeedCursorPosition {
    #[must_use]
    pub const fn mode(self) -> FeedMode {
        match self {
            Self::ToRead { .. } => FeedMode::ToRead,
            Self::Recommendations { .. } => FeedMode::Recommendations,
        }
    }

    #[must_use]
    pub const fn ordering(self) -> ReadingFeedCursorOrdering {
        match self {
            Self::ToRead { .. } => ReadingFeedCursorOrdering::QueueFifoV1,
            Self::Recommendations { .. } => ReadingFeedCursorOrdering::DiscoveryNewestV1,
        }
    }
}

/// URL-safe, non-secret fingerprint of the active encryption key.
///
/// The concrete encrypted codec creates this value from the opaque cursor
/// keyring. Keeping the representation bounded prevents attacker-controlled
/// cursor payload growth.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CursorKeyEpoch(String);

impl CursorKeyEpoch {
    pub const ENCODED_BYTES: usize = 43;

    pub fn parse(value: impl Into<String>) -> Option<Self> {
        let value = value.into();
        if valid_key_epoch(&value) {
            Some(Self(value))
        } else {
            None
        }
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    fn is_valid(&self) -> bool {
        valid_key_epoch(&self.0)
    }
}

fn valid_key_epoch(value: &str) -> bool {
    value.len() == CursorKeyEpoch::ENCODED_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

/// Authenticated, encrypted continuation claims for the personalized feed.
/// Compact field names keep the complete opaque token below the codec's hard
/// size limit; callers interact only with the descriptive Rust fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReadingFeedCursorClaims {
    #[serde(rename = "u")]
    pub user_id: AuthenticatedUserId,
    #[serde(rename = "m")]
    pub mode: FeedMode,
    #[serde(rename = "r")]
    pub library_revision: i64,
    #[serde(rename = "o")]
    pub ordering: ReadingFeedCursorOrdering,
    #[serde(rename = "p")]
    pub position: ReadingFeedCursorPosition,
    #[serde(rename = "c")]
    pub category: Option<String>,
    #[serde(rename = "d")]
    pub recommendation_mode: RecommendationMode,
    #[serde(rename = "l")]
    pub page_size: u32,
    #[serde(rename = "v")]
    pub page_policy_version: u16,
    #[serde(rename = "k")]
    pub key_epoch: CursorKeyEpoch,
    #[serde(rename = "e")]
    pub expires_at: DateTime<Utc>,
}

impl ReadingFeedCursorClaims {
    /// Validate relationships between redundant claims before they influence a
    /// database request. Time, account scope, and active-key checks belong to
    /// the concrete encrypted codec.
    #[must_use]
    pub fn structurally_valid(&self) -> bool {
        self.library_revision >= 0
            && self.page_size > 0
            && self.page_policy_version > 0
            && self.key_epoch.is_valid()
            && self.mode == self.position.mode()
            && self.ordering == self.position.ordering()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadingFeedRequest {
    pub user_id: AuthenticatedUserId,
    pub category: Option<String>,
    pub recommendation_mode: RecommendationMode,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
    /// Injected observation time keeps expiry and response tests deterministic.
    pub now: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadingFeedDecision {
    pub library_revision: i64,
    pub active_to_read_count: u64,
    pub queue_proven_empty: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueMetadata {
    pub state: LibraryState,
    pub saved_at: DateTime<Utc>,
    pub revision: i64,
    pub save_source_kind: Option<LibrarySaveSourceKind>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadingFeedItem {
    pub paper: PaperSummary,
    pub queue: Option<QueueMetadata>,
    pub source: FeedItemSource,
    pub recommendation: Option<RecommendationMetadata>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecommendationMetadata {
    pub mode: RecommendationMode,
    pub reason_codes: Vec<RecommendationReasonCode>,
    pub reason_label: String,
    pub explanation_available: bool,
}

pub const RECOMMENDATION_BATCH_VERSION_MAX_BYTES: usize = 64;

/// Immutable batch authority and implementation versions returned with every
/// persisted recommendation page. The metadata is absent for queue and
/// unbatched chronological pages.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecommendationBatchMetadata {
    pub profile_revision: Option<i64>,
    pub feedback_revision: i64,
    pub algorithm_version: String,
    pub recommendation_policy_version: String,
}

impl RecommendationBatchMetadata {
    /// Mirrors the persisted recommendation-batch revision and version
    /// constraints so corrupt storage or an invalid source cannot escape.
    #[must_use]
    pub fn structurally_valid(&self) -> bool {
        self.profile_revision.is_none_or(|revision| revision >= 0)
            && self.feedback_revision >= 0
            && valid_batch_version(&self.algorithm_version)
            && valid_batch_version(&self.recommendation_policy_version)
    }
}

fn valid_batch_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= RECOMMENDATION_BATCH_VERSION_MAX_BYTES
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || (index > 0 && matches!(byte, b'.' | b'_' | b'-'))
        })
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadingFeedPage {
    pub mode: FeedMode,
    pub decision: ReadingFeedDecision,
    /// Page-scoped persisted recommendation provenance. A non-null value may
    /// coexist with `next_cursor`; the next page can have a different batch.
    pub batch_id: Option<Uuid>,
    pub batch_metadata: Option<RecommendationBatchMetadata>,
    pub items: Vec<ReadingFeedItem>,
    pub next_cursor: Option<String>,
    pub server_time: DateTime<Utc>,
}
