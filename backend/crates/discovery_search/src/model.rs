use chrono::{DateTime, NaiveDate, Utc};
use domain::{AuthenticatedUserId, PaperSummary};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SearchSort {
    Relevance,
    Recency,
}

impl SearchSort {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Relevance => "relevance",
            Self::Recency => "recency",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SearchSource {
    #[serde(rename = "arxiv")]
    ArxivMetadata,
}

impl SearchSource {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ArxivMetadata => "arxiv",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchKind {
    ExactArxivId,
    ExactDoi,
    ExactTitle,
    ExactAuthor,
    Phrase,
    RelatedText,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceStatus {
    Queried,
    NoMatches,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceCoverage {
    Partial,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceDiagnostic {
    pub source: SearchSource,
    pub status: SourceStatus,
    pub coverage: SourceCoverage,
    pub matches_returned: u32,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelatedTopic {
    pub topic_id: Uuid,
    pub label: String,
    pub source_vocabulary: String,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchSuggestions {
    pub normalized_query: String,
    pub items: Vec<RelatedTopic>,
}

impl std::fmt::Debug for SearchSuggestions {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SearchSuggestions")
            .field("query", &"[redacted]")
            .field("item_count", &self.items.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct SearchResult {
    pub paper: PaperSummary,
    pub match_kind: MatchKind,
    /// Deterministic integer bucket used only to explain result ordering.
    pub relevance_bucket: i64,
    pub source: SearchSource,
}

impl std::fmt::Debug for SearchResult {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SearchResult")
            .field("paper_id", &self.paper.paper_id)
            .field("match_kind", &self.match_kind)
            .field("relevance_bucket", &self.relevance_bucket)
            .field("source", &self.source)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct SearchPage {
    pub normalized_query: String,
    pub items: Vec<SearchResult>,
    pub next_cursor: Option<String>,
    pub diagnostics: Vec<SourceDiagnostic>,
    pub related_topics: Vec<RelatedTopic>,
}

impl std::fmt::Debug for SearchPage {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SearchPage")
            .field("query", &"[redacted]")
            .field("item_count", &self.items.len())
            .field("cursor_present", &self.next_cursor.is_some())
            .field("diagnostic_count", &self.diagnostics.len())
            .field("related_topic_count", &self.related_topics.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchFilters {
    pub categories: Vec<String>,
    pub topics: Vec<String>,
    pub published_after: Option<NaiveDate>,
    pub published_before: Option<NaiveDate>,
    pub sources: Vec<SearchSource>,
}

impl std::fmt::Debug for SearchFilters {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SearchFilters")
            .field("category_count", &self.categories.len())
            .field("topic_count", &self.topics.len())
            .field("published_after", &self.published_after)
            .field("published_before", &self.published_before)
            .field("sources", &self.sources)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct LookupSearchRequest {
    pub normalized_query: String,
    pub exact_arxiv_base_id: Option<String>,
    pub cursor: Option<String>,
    pub limit: u32,
}

impl std::fmt::Debug for LookupSearchRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LookupSearchRequest")
            .field("query", &"[redacted]")
            .field("cursor_present", &self.cursor.is_some())
            .field("limit", &self.limit)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ExploreSearchRequest {
    pub normalized_query: String,
    pub filters: SearchFilters,
    pub sort: SearchSort,
    pub cursor: Option<String>,
    pub limit: u32,
}

impl std::fmt::Debug for ExploreSearchRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ExploreSearchRequest")
            .field("query", &"[redacted]")
            .field(
                "filter_count",
                &(self.filters.categories.len() + self.filters.topics.len()),
            )
            .field("sort", &self.sort)
            .field("cursor_present", &self.cursor.is_some())
            .field("limit", &self.limit)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSearchDefinition {
    pub normalized_query: String,
    pub filters: SearchFilters,
    pub sort: SearchSort,
}

impl std::fmt::Debug for SavedSearchDefinition {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SavedSearchDefinition")
            .field("query", &"[redacted]")
            .field(
                "filter_count",
                &(self.filters.categories.len() + self.filters.topics.len()),
            )
            .field("sort", &self.sort)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSearch {
    pub id: Uuid,
    pub user_id: AuthenticatedUserId,
    pub definition: SavedSearchDefinition,
    pub revision: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl std::fmt::Debug for SavedSearch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SavedSearch")
            .field("id", &self.id)
            .field("account", &"[redacted]")
            .field("definition", &self.definition)
            .field("revision", &self.revision)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct SaveSearchCommand {
    pub operation_id: Uuid,
    pub query: String,
    pub filters: SearchFilters,
    pub sort: SearchSort,
}

/// Account-scoped receipt for a repeat-safe saved-query deletion.
///
/// `deleted` is false when the query was already absent from the caller's
/// account. The service deliberately does not distinguish an unknown ID from
/// an ID owned by another account.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SavedSearchDeleteReceipt {
    pub saved_search_id: Uuid,
    pub deleted: bool,
    pub linked_subscriptions_deleted: u32,
}

impl std::fmt::Debug for SaveSearchCommand {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SaveSearchCommand")
            .field("operation_id", &self.operation_id)
            .field("query", &"[redacted]")
            .field(
                "filter_count",
                &(self.filters.categories.len() + self.filters.topics.len()),
            )
            .field("sort", &self.sort)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct SearchFingerprint([u8; 32]);

impl SearchFingerprint {
    #[must_use]
    pub const fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl std::fmt::Debug for SearchFingerprint {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SearchFingerprint([redacted])")
    }
}
