use std::collections::HashMap;

use db::{VersionDiffSourceSide, VersionDiffSourceTarget};
use domain::{
    DiffConfidenceStatus, DocumentVersionManifest, PaperVersionDiff, VersionChangeType,
    VersionDiffItem, VersionDiffItemKind, VersionDiffStatus,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{SourceLocatorResponse, format_timestamp};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct VersionDiffParams {
    pub(crate) from: i32,
    pub(crate) to: i32,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DocumentVersionResponse {
    pub(crate) generation: i32,
    pub(crate) arxiv_version: u32,
    pub(crate) arxiv_id: String,
    pub(crate) source_abs_url: String,
    pub(crate) source_pdf_url: String,
    pub(crate) schema_version: String,
    pub(crate) parser_id: String,
    pub(crate) parser_version: String,
    pub(crate) document_hash: String,
    pub(crate) is_current: bool,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) generated_at: String,
}

impl DocumentVersionResponse {
    fn from_manifest(value: DocumentVersionManifest, arxiv_base_id: &str) -> Self {
        let arxiv_id = format!("{arxiv_base_id}v{}", value.arxiv_version);
        Self {
            generation: value.generation,
            arxiv_version: value.arxiv_version,
            source_abs_url: format!("https://arxiv.org/abs/{arxiv_id}"),
            source_pdf_url: format!("https://arxiv.org/pdf/{arxiv_id}"),
            arxiv_id,
            schema_version: value.schema_version,
            parser_id: value.parser.parser_id,
            parser_version: value.parser.parser_version,
            document_hash: value.document_hash,
            is_current: value.is_current,
            generated_at: format_timestamp(value.created_at),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DocumentVersionsEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) items: Vec<DocumentVersionResponse>,
}

impl DocumentVersionsEnvelope {
    #[must_use]
    pub(crate) fn new(
        paper_id: Uuid,
        arxiv_base_id: &str,
        versions: Vec<DocumentVersionManifest>,
    ) -> Self {
        Self {
            paper_id,
            items: versions
                .into_iter()
                .map(|version| DocumentVersionResponse::from_manifest(version, arxiv_base_id))
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum VersionDiffStatusResponse {
    Pending,
    Ready,
    Partial,
    Failed,
}

impl From<VersionDiffStatus> for VersionDiffStatusResponse {
    fn from(value: VersionDiffStatus) -> Self {
        match value {
            VersionDiffStatus::Pending => Self::Pending,
            VersionDiffStatus::Ready => Self::Ready,
            VersionDiffStatus::Partial => Self::Partial,
            VersionDiffStatus::Failed => Self::Failed,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum VersionDiffItemKindResponse {
    Metadata,
    Section,
    Block,
    Figure,
    Table,
    Equation,
    PassportField,
    Reference,
    AnnotationAnchor,
}

impl From<VersionDiffItemKind> for VersionDiffItemKindResponse {
    fn from(value: VersionDiffItemKind) -> Self {
        match value {
            VersionDiffItemKind::Metadata => Self::Metadata,
            VersionDiffItemKind::Section => Self::Section,
            VersionDiffItemKind::Block => Self::Block,
            VersionDiffItemKind::Figure => Self::Figure,
            VersionDiffItemKind::Table => Self::Table,
            VersionDiffItemKind::Equation => Self::Equation,
            VersionDiffItemKind::PassportField => Self::PassportField,
            VersionDiffItemKind::Reference => Self::Reference,
            VersionDiffItemKind::AnnotationAnchor => Self::AnnotationAnchor,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum VersionChangeTypeResponse {
    Added,
    Removed,
    Modified,
    Moved,
}

impl From<VersionChangeType> for VersionChangeTypeResponse {
    fn from(value: VersionChangeType) -> Self {
        match value {
            VersionChangeType::Added => Self::Added,
            VersionChangeType::Removed => Self::Removed,
            VersionChangeType::Modified => Self::Modified,
            VersionChangeType::Moved => Self::Moved,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DiffConfidenceStatusResponse {
    Supported,
    Uncertain,
    Unavailable,
}

impl From<DiffConfidenceStatus> for DiffConfidenceStatusResponse {
    fn from(value: DiffConfidenceStatus) -> Self {
        match value {
            DiffConfidenceStatus::Supported => Self::Supported,
            DiffConfidenceStatus::Uncertain => Self::Uncertain,
            DiffConfidenceStatus::Unavailable => Self::Unavailable,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct VersionDiffItemResponse {
    pub(crate) id: Uuid,
    pub(crate) ordinal: u32,
    pub(crate) kind: VersionDiffItemKindResponse,
    pub(crate) old_object_id: Option<Uuid>,
    pub(crate) new_object_id: Option<Uuid>,
    pub(crate) change_type: VersionChangeTypeResponse,
    pub(crate) similarity: Option<f32>,
    pub(crate) old_content_hash: Option<String>,
    pub(crate) new_content_hash: Option<String>,
    pub(crate) confidence_status: DiffConfidenceStatusResponse,
    pub(crate) old_source: Option<VersionDiffSourceTargetResponse>,
    pub(crate) new_source: Option<VersionDiffSourceTargetResponse>,
}

impl VersionDiffItemResponse {
    fn new(
        value: VersionDiffItem,
        old_source: Option<VersionDiffSourceTarget>,
        new_source: Option<VersionDiffSourceTarget>,
        arxiv_base_id: &str,
        from_arxiv_version: u32,
        to_arxiv_version: u32,
    ) -> Self {
        Self {
            id: value.id,
            ordinal: value.ordinal,
            kind: value.kind.into(),
            old_object_id: value.old_object_id,
            new_object_id: value.new_object_id,
            change_type: value.change_type.into(),
            similarity: value.similarity,
            old_content_hash: value.old_content_hash,
            new_content_hash: value.new_content_hash,
            confidence_status: value.confidence_status.into(),
            old_source: old_source.map(|target| {
                VersionDiffSourceTargetResponse::new(target, arxiv_base_id, from_arxiv_version)
            }),
            new_source: new_source.map(|target| {
                VersionDiffSourceTargetResponse::new(target, arxiv_base_id, to_arxiv_version)
            }),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct VersionDiffSourceTargetResponse {
    pub(crate) object_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) page_start: Option<u32>,
    pub(crate) page_end: Option<u32>,
    pub(crate) source_locator: Option<SourceLocatorResponse>,
    pub(crate) source_abs_url: String,
    pub(crate) source_pdf_url: String,
    /// Exact retained PDF version plus a standards-compatible page fragment.
    /// Absent when extraction did not provide a trustworthy source page.
    pub(crate) source_page_url: Option<String>,
}

impl VersionDiffSourceTargetResponse {
    fn new(target: VersionDiffSourceTarget, arxiv_base_id: &str, arxiv_version: u32) -> Self {
        let arxiv_id = format!("{arxiv_base_id}v{arxiv_version}");
        let source_abs_url = format!("https://arxiv.org/abs/{arxiv_id}");
        let source_pdf_url = format!("https://arxiv.org/pdf/{arxiv_id}");
        let page_number = target
            .source_locator
            .as_ref()
            .and_then(|locator| locator.page_number)
            .or(target.page_start);
        Self {
            object_id: target.object_id,
            generation: target.generation,
            page_start: target.page_start,
            page_end: target.page_end,
            source_locator: target.source_locator.map(Into::into),
            source_page_url: page_number.map(|page| format!("{source_pdf_url}#page={page}")),
            source_abs_url,
            source_pdf_url,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct VersionDiffSummaryResponse {
    pub(crate) added: u32,
    pub(crate) removed: u32,
    pub(crate) modified: u32,
    pub(crate) moved: u32,
    pub(crate) warnings: Vec<String>,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct PaperVersionDiffEnvelope {
    pub(crate) id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) from_generation: i32,
    pub(crate) to_generation: i32,
    pub(crate) from_arxiv_version: u32,
    pub(crate) to_arxiv_version: u32,
    pub(crate) from_source_abs_url: String,
    pub(crate) to_source_abs_url: String,
    pub(crate) algorithm_version: String,
    pub(crate) schema_version: String,
    pub(crate) from_parser_id: String,
    pub(crate) from_parser_version: String,
    pub(crate) to_parser_id: String,
    pub(crate) to_parser_version: String,
    pub(crate) parser_change_uncertainty: bool,
    pub(crate) status: VersionDiffStatusResponse,
    pub(crate) summary: VersionDiffSummaryResponse,
    pub(crate) failure_code: Option<String>,
    pub(crate) items: Vec<VersionDiffItemResponse>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    #[schema(value_type = Option<String>, format = DateTime)]
    pub(crate) completed_at: Option<String>,
}

impl PaperVersionDiffEnvelope {
    #[must_use]
    pub(crate) fn new(
        value: PaperVersionDiff,
        arxiv_base_id: &str,
        source_targets: Vec<VersionDiffSourceTarget>,
    ) -> Self {
        let from_arxiv_id = format!("{arxiv_base_id}v{}", value.from_arxiv_version);
        let to_arxiv_id = format!("{arxiv_base_id}v{}", value.to_arxiv_version);
        let from_generation = value.from_generation;
        let to_generation = value.to_generation;
        let from_arxiv_version = value.from_arxiv_version;
        let to_arxiv_version = value.to_arxiv_version;
        let mut source_targets = source_targets
            .into_iter()
            .map(|target| ((target.diff_item_id, target.side), target))
            .collect::<HashMap<_, _>>();
        let items = value
            .items
            .into_iter()
            .map(|item| {
                let old_source = source_targets
                    .remove(&(item.id, VersionDiffSourceSide::Old))
                    .filter(|target| {
                        target.generation == from_generation
                            && target.kind == item.kind
                            && Some(target.object_id) == item.old_object_id
                    });
                let new_source = source_targets
                    .remove(&(item.id, VersionDiffSourceSide::New))
                    .filter(|target| {
                        target.generation == to_generation
                            && target.kind == item.kind
                            && Some(target.object_id) == item.new_object_id
                    });
                VersionDiffItemResponse::new(
                    item,
                    old_source,
                    new_source,
                    arxiv_base_id,
                    from_arxiv_version,
                    to_arxiv_version,
                )
            })
            .collect();
        Self {
            id: value.id,
            paper_id: value.paper_id,
            from_generation: value.from_generation,
            to_generation: value.to_generation,
            from_arxiv_version: value.from_arxiv_version,
            to_arxiv_version: value.to_arxiv_version,
            from_source_abs_url: format!("https://arxiv.org/abs/{from_arxiv_id}"),
            to_source_abs_url: format!("https://arxiv.org/abs/{to_arxiv_id}"),
            algorithm_version: value.algorithm_version,
            schema_version: value.schema_version,
            from_parser_id: value.from_parser.parser_id,
            from_parser_version: value.from_parser.parser_version,
            to_parser_id: value.to_parser.parser_id,
            to_parser_version: value.to_parser.parser_version,
            parser_change_uncertainty: value.parser_change_uncertainty,
            status: value.status.into(),
            summary: VersionDiffSummaryResponse {
                added: value.summary.added,
                removed: value.summary.removed,
                modified: value.summary.modified,
                moved: value.summary.moved,
                warnings: value.summary.warnings,
            },
            failure_code: value.failure_code,
            items,
            created_at: format_timestamp(value.created_at),
            completed_at: value.completed_at.map(format_timestamp),
        }
    }
}
