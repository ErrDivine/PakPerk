use std::fmt;

use domain::{PaperMetadata, PaperSummary};
use paper_resolution::{PaperImportResult, PaperInputKind, PaperSearchResult};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{LibrarySaveSourceBody, LibraryV2ItemResponse, format_timestamp};

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PaperSearchBody {
    #[schema(min_length = 3, max_length = 300)]
    pub(crate) query: String,
    #[schema(minimum = 1, maximum = 10, example = 8)]
    pub(crate) limit: Option<usize>,
}

impl fmt::Debug for PaperSearchBody {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PaperSearchBody")
            .field("query", &"[redacted]")
            .field("query_chars", &self.query.chars().count())
            .field("limit", &self.limit)
            .finish()
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct PaperSearchMatchResponse {
    pub(crate) kind: &'static str,
    pub(crate) rank: usize,
}

#[derive(Debug, Serialize)]
pub(crate) struct PaperSearchCandidateResponse {
    pub(crate) arxiv_id: String,
    pub(crate) title: String,
    pub(crate) authors: Vec<String>,
    #[serde(rename = "abstract")]
    pub(crate) abstract_text: String,
    pub(crate) primary_category: String,
    pub(crate) categories: Vec<String>,
    pub(crate) published_at: String,
    pub(crate) updated_at: String,
    pub(crate) abs_url: String,
    #[serde(rename = "match")]
    pub(crate) match_value: PaperSearchMatchResponse,
}

impl PaperSearchCandidateResponse {
    fn from_metadata(metadata: PaperMetadata, rank: usize) -> Self {
        Self {
            arxiv_id: metadata.arxiv_id.versioned(),
            title: metadata.title,
            authors: metadata
                .authors
                .into_iter()
                .map(|author| author.name)
                .collect(),
            abstract_text: metadata.abstract_text,
            primary_category: metadata.primary_category,
            categories: metadata.categories,
            published_at: format_timestamp(metadata.published_at),
            updated_at: format_timestamp(metadata.updated_at),
            abs_url: metadata.abs_url.to_string(),
            match_value: PaperSearchMatchResponse {
                kind: "title",
                rank,
            },
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct PaperSearchEnvelope {
    pub(crate) query_id: Uuid,
    pub(crate) normalized_query: String,
    pub(crate) candidates: Vec<PaperSearchCandidateResponse>,
}

impl From<PaperSearchResult> for PaperSearchEnvelope {
    fn from(result: PaperSearchResult) -> Self {
        Self {
            query_id: result.query_id,
            normalized_query: result.normalized_query,
            candidates: result
                .candidates
                .into_iter()
                .enumerate()
                .map(|(index, metadata)| {
                    PaperSearchCandidateResponse::from_metadata(metadata, index + 1)
                })
                .collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PaperInputKindBody {
    ArxivUrl,
    ArxivId,
}

impl From<PaperInputKindBody> for PaperInputKind {
    fn from(value: PaperInputKindBody) -> Self {
        match value {
            PaperInputKindBody::ArxivUrl => Self::ArxivUrl,
            PaperInputKindBody::ArxivId => Self::ArxivId,
        }
    }
}

impl From<PaperInputKind> for PaperInputKindBody {
    fn from(value: PaperInputKind) -> Self {
        match value {
            PaperInputKind::ArxivUrl => Self::ArxivUrl,
            PaperInputKind::ArxivId => Self::ArxivId,
        }
    }
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PaperImportSourceBody {
    pub(crate) kind: PaperInputKindBody,
    pub(crate) value: String,
}

impl fmt::Debug for PaperImportSourceBody {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PaperImportSourceBody")
            .field("kind", &self.kind)
            .field("value", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PaperImportBody {
    pub(crate) operation_id: Uuid,
    pub(crate) source: PaperImportSourceBody,
    pub(crate) target_state: PaperImportTargetStateBody,
    pub(crate) save_source_kind: LibrarySaveSourceBody,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PaperImportTargetStateBody {
    Inbox,
}

#[derive(Debug, Serialize)]
pub(crate) struct PaperImportResolutionResponse {
    pub(crate) input_kind: PaperInputKindBody,
    pub(crate) canonical_arxiv_id: String,
}

#[derive(Debug, Serialize)]
pub(crate) struct PaperImportEnvelope {
    pub(crate) result: &'static str,
    pub(crate) resolution: PaperImportResolutionResponse,
    pub(crate) item: LibraryV2ItemResponse,
    pub(crate) paper: PaperSummary,
    pub(crate) sync_revision: i64,
}

impl From<PaperImportResult> for PaperImportEnvelope {
    fn from(result: PaperImportResult) -> Self {
        let sync_revision = result.item.revision;
        Self {
            result: "saved",
            resolution: PaperImportResolutionResponse {
                input_kind: result.input_kind.into(),
                canonical_arxiv_id: result.canonical_arxiv_id,
            },
            item: LibraryV2ItemResponse::from(result.item),
            paper: result.paper,
            sync_revision,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sensitive_request_debug_is_redacted_and_json_is_strict() {
        let search: PaperSearchBody =
            serde_json::from_str(r#"{"query":"private title","limit":8}"#).unwrap();
        assert!(!format!("{search:?}").contains("private title"));
        assert!(
            serde_json::from_str::<PaperSearchBody>(
                r#"{"query":"paper","limit":8,"auto_save":true}"#
            )
            .is_err()
        );

        let operation_id = Uuid::now_v7();
        let import: PaperImportBody = serde_json::from_str(&format!(
            r#"{{"operation_id":"{operation_id}","source":{{"kind":"arxiv_url","value":"https://arxiv.org/abs/1706.03762"}},"target_state":"inbox","save_source_kind":"arxiv_url"}}"#
        ))
        .unwrap();
        assert!(!format!("{:?}", import.source).contains("1706.03762"));
        assert!(
            serde_json::from_str::<PaperImportBody>(&format!(
                r#"{{"operation_id":"{operation_id}","source":{{"kind":"arxiv_id","value":"1706.03762"}},"target_state":"inbox","save_source_kind":"arxiv_id","prepare":true}}"#
            ))
            .is_err(),
            "imports must not expose a preparation control"
        );
    }
}
