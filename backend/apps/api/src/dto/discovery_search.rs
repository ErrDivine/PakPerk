use discovery_search::{
    MatchKind, SavedSearch, SearchPage, SearchResult, SearchSort, SearchSource, SourceCoverage,
    SourceDiagnostic, SourceStatus,
};
use domain::{Capabilities, PaperSummary};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::format_timestamp;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LookupSearchParams {
    #[serde(rename = "q")]
    pub(crate) query: String,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SuggestionSearchParams {
    #[serde(rename = "q")]
    pub(crate) query: String,
}

impl std::fmt::Debug for SuggestionSearchParams {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SuggestionSearchParams")
            .field("query", &"[redacted]")
            .finish()
    }
}

impl std::fmt::Debug for LookupSearchParams {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LookupSearchParams")
            .field("query", &"[redacted]")
            .field("cursor_present", &self.cursor.is_some())
            .field("limit", &self.limit)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SearchSortBody {
    #[default]
    Relevance,
    Recency,
}

impl From<SearchSortBody> for SearchSort {
    fn from(value: SearchSortBody) -> Self {
        match value {
            SearchSortBody::Relevance => Self::Relevance,
            SearchSortBody::Recency => Self::Recency,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SearchSourceBody {
    Arxiv,
}

impl From<SearchSourceBody> for SearchSource {
    fn from(_: SearchSourceBody) -> Self {
        Self::ArxivMetadata
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct SearchFiltersBody {
    #[serde(default)]
    #[schema(max_items = 8)]
    pub(crate) categories: Vec<String>,
    #[serde(default)]
    #[schema(max_items = 8)]
    pub(crate) topics: Vec<String>,
    #[schema(example = "2024-01-01")]
    pub(crate) published_after: Option<String>,
    #[schema(example = "2026-08-19")]
    pub(crate) published_before: Option<String>,
    #[serde(default)]
    #[schema(max_items = 1)]
    pub(crate) sources: Vec<SearchSourceBody>,
}

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExploreSearchBody {
    #[schema(min_length = 2, max_length = 300)]
    pub(crate) query: String,
    #[serde(default)]
    pub(crate) filters: SearchFiltersBody,
    #[serde(default)]
    pub(crate) sort: SearchSortBody,
    #[schema(max_length = 512)]
    pub(crate) cursor: Option<String>,
    #[schema(minimum = 1, maximum = 50)]
    pub(crate) limit: Option<u32>,
}

impl std::fmt::Debug for ExploreSearchBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ExploreSearchBody")
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

#[derive(Clone, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct SaveSearchBody {
    pub(crate) operation_id: Uuid,
    #[schema(min_length = 2, max_length = 300)]
    pub(crate) query: String,
    #[serde(default)]
    pub(crate) filters: SearchFiltersBody,
    #[serde(default)]
    pub(crate) sort: SearchSortBody,
}

impl std::fmt::Debug for SaveSearchBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SaveSearchBody")
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

#[derive(Serialize)]
pub(crate) struct SearchResultResponse {
    pub(crate) paper: PaperSummary,
    pub(crate) match_kind: MatchKind,
    pub(crate) relevance_bucket: i64,
    pub(crate) source: SearchSource,
}

impl From<SearchResult> for SearchResultResponse {
    fn from(mut result: SearchResult) -> Self {
        // Search is metadata-only navigation. Never advertise already cached
        // derived capabilities as part of a search result.
        result.paper.capabilities = Capabilities::metadata_only();
        Self {
            paper: result.paper,
            match_kind: result.match_kind,
            relevance_bucket: result.relevance_bucket,
            source: result.source,
        }
    }
}

#[derive(Serialize)]
pub(crate) struct SourceDiagnosticResponse {
    pub(crate) source: SearchSource,
    pub(crate) status: SourceStatus,
    pub(crate) coverage: SourceCoverage,
    pub(crate) matches_returned: u32,
}

impl From<SourceDiagnostic> for SourceDiagnosticResponse {
    fn from(value: SourceDiagnostic) -> Self {
        Self {
            source: value.source,
            status: value.status,
            coverage: value.coverage,
            matches_returned: value.matches_returned,
        }
    }
}

#[derive(Serialize)]
pub(crate) struct SearchPageEnvelope {
    pub(crate) normalized_query: String,
    pub(crate) items: Vec<SearchResultResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) diagnostics: Vec<SourceDiagnosticResponse>,
    pub(crate) related_topics: Vec<discovery_search::RelatedTopic>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) disclaimer: Option<&'static str>,
}

impl SearchPageEnvelope {
    pub(crate) fn new(page: SearchPage, disclaimer: Option<&'static str>) -> Self {
        Self {
            normalized_query: page.normalized_query,
            items: page.items.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
            diagnostics: page.diagnostics.into_iter().map(Into::into).collect(),
            related_topics: page.related_topics,
            disclaimer,
        }
    }
}

#[derive(Serialize)]
pub(crate) struct SearchSuggestionsEnvelope {
    pub(crate) normalized_query: String,
    pub(crate) items: Vec<discovery_search::RelatedTopic>,
}

impl From<discovery_search::SearchSuggestions> for SearchSuggestionsEnvelope {
    fn from(value: discovery_search::SearchSuggestions) -> Self {
        Self {
            normalized_query: value.normalized_query,
            items: value.items,
        }
    }
}

#[derive(Serialize)]
pub(crate) struct SavedSearchResponse {
    pub(crate) id: Uuid,
    pub(crate) query: String,
    pub(crate) filters: SearchFiltersBody,
    pub(crate) sort: SearchSortBody,
    pub(crate) revision: i64,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

impl From<SavedSearch> for SavedSearchResponse {
    fn from(value: SavedSearch) -> Self {
        Self {
            id: value.id,
            query: value.definition.normalized_query,
            filters: SearchFiltersBody {
                categories: value.definition.filters.categories,
                topics: value.definition.filters.topics,
                published_after: value
                    .definition
                    .filters
                    .published_after
                    .map(|date| date.to_string()),
                published_before: value
                    .definition
                    .filters
                    .published_before
                    .map(|date| date.to_string()),
                sources: value
                    .definition
                    .filters
                    .sources
                    .into_iter()
                    .map(|_| SearchSourceBody::Arxiv)
                    .collect(),
            },
            sort: match value.definition.sort {
                SearchSort::Relevance => SearchSortBody::Relevance,
                SearchSort::Recency => SearchSortBody::Recency,
            },
            revision: value.revision,
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Serialize)]
pub(crate) struct SavedSearchEnvelope {
    pub(crate) saved_search: SavedSearchResponse,
}

impl From<SavedSearch> for SavedSearchEnvelope {
    fn from(value: SavedSearch) -> Self {
        Self {
            saved_search: value.into(),
        }
    }
}

#[derive(Serialize)]
pub(crate) struct SavedSearchListEnvelope {
    pub(crate) items: Vec<SavedSearchResponse>,
}

impl From<Vec<SavedSearch>> for SavedSearchListEnvelope {
    fn from(values: Vec<SavedSearch>) -> Self {
        Self {
            items: values.into_iter().map(Into::into).collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_debug_is_redacted_and_unknown_fields_fail_closed() {
        let body: ExploreSearchBody = serde_json::from_value(serde_json::json!({
            "query": "private research direction",
            "filters": {"categories": ["cs.AI"]}
        }))
        .unwrap();
        let debug = format!("{body:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("private research direction"));
        assert!(
            serde_json::from_value::<ExploreSearchBody>(serde_json::json!({
                "query": "bounded query",
                "save_to_queue": true
            }))
            .is_err()
        );
    }
}
