use chrono::{DateTime, Utc};
use db::{ResearchAnnotationImport, ResearchAnnotationImportResult, StoredAnnotationConflict};
use domain::{
    Annotation, AnnotationAnchorStatus, AnnotationColorRole, AnnotationConflict,
    AnnotationConflictResolution, AnnotationKind, AnnotationWrite, EvidenceCard, EvidenceCardWrite,
    EvidenceVerificationStatus, MemoryItem, MemoryItemWrite, MemorySourceType, MemoryStatus,
    ReaderMode, ReaderStage, ReadingCheckpoint, ReadingCheckpointWrite, TextQuotePositionSelector,
};
use serde::{Deserialize, Serialize};
use utoipa::{IntoParams, ToSchema};
use uuid::Uuid;

use super::format_timestamp;

#[derive(Clone, Copy, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AnnotationKindBody {
    Highlight,
    Note,
    Question,
    Evidence,
}

impl From<AnnotationKindBody> for AnnotationKind {
    fn from(value: AnnotationKindBody) -> Self {
        match value {
            AnnotationKindBody::Highlight => Self::Highlight,
            AnnotationKindBody::Note => Self::Note,
            AnnotationKindBody::Question => Self::Question,
            AnnotationKindBody::Evidence => Self::Evidence,
        }
    }
}

#[derive(Clone, Copy, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AnnotationColorRoleBody {
    Yellow,
    Blue,
    Green,
    Pink,
    Purple,
}

impl From<AnnotationColorRoleBody> for AnnotationColorRole {
    fn from(value: AnnotationColorRoleBody) -> Self {
        match value {
            AnnotationColorRoleBody::Yellow => Self::Yellow,
            AnnotationColorRoleBody::Blue => Self::Blue,
            AnnotationColorRoleBody::Green => Self::Green,
            AnnotationColorRoleBody::Pink => Self::Pink,
            AnnotationColorRoleBody::Purple => Self::Purple,
        }
    }
}

#[derive(Clone, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct TextSelectorBody {
    #[serde(rename = "type")]
    pub(crate) selector_type: String,
    pub(crate) exact: String,
    pub(crate) prefix: Option<String>,
    pub(crate) suffix: Option<String>,
    pub(crate) start: Option<u32>,
    pub(crate) end: Option<u32>,
}

impl TextSelectorBody {
    pub(crate) fn into_domain(self) -> Result<TextQuotePositionSelector, &'static str> {
        if self.selector_type != "TextQuoteAndPosition" {
            return Err("selector.type must be TextQuoteAndPosition");
        }
        Ok(TextQuotePositionSelector {
            exact: self.exact,
            prefix: self.prefix,
            suffix: self.suffix,
            start: self.start,
            end: self.end,
        })
    }
}

#[derive(Clone, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct AnnotationWriteBody {
    pub(crate) operation_id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) block_id: Uuid,
    pub(crate) kind: AnnotationKindBody,
    pub(crate) body: Option<String>,
    pub(crate) color_role: Option<AnnotationColorRoleBody>,
    pub(crate) selector: TextSelectorBody,
    #[serde(default)]
    pub(crate) section_hint: Vec<String>,
    pub(crate) page_hint: Option<u32>,
    pub(crate) base_revision: i64,
    pub(crate) resolves_conflict_id: Option<Uuid>,
}

impl AnnotationWriteBody {
    pub(crate) fn into_domain(self, id: Uuid) -> Result<AnnotationWrite, &'static str> {
        Ok(AnnotationWrite {
            id,
            operation_id: self.operation_id,
            paper_id: self.paper_id,
            generation: self.generation,
            block_id: Some(self.block_id),
            kind: self.kind.into(),
            body: self.body,
            color_role: self.color_role.map(Into::into),
            selector: self.selector.into_domain()?,
            section_hint: self.section_hint,
            page_hint: self.page_hint,
            base_revision: self.base_revision,
        })
    }
}

#[derive(Debug, Deserialize, IntoParams)]
#[serde(deny_unknown_fields)]
pub(crate) struct AnnotationListParams {
    pub(crate) paper_id: Option<Uuid>,
    pub(crate) after_revision: Option<i64>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Deserialize, IntoParams)]
#[serde(deny_unknown_fields)]
pub(crate) struct AnnotationConflictListParams {
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Deserialize, IntoParams)]
#[serde(deny_unknown_fields)]
pub(crate) struct CheckpointListParams {
    pub(crate) paper_id: Option<Uuid>,
}

#[derive(Debug, Deserialize, IntoParams)]
#[serde(deny_unknown_fields)]
pub(crate) struct RevisionDeleteParams {
    pub(crate) operation_id: Uuid,
    pub(crate) base_revision: i64,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct AnnotationReanchorBody {
    pub(crate) operation_id: Uuid,
    pub(crate) base_revision: i64,
    pub(crate) to_generation: i32,
}

#[derive(Debug, Deserialize, IntoParams)]
#[serde(deny_unknown_fields)]
pub(crate) struct ResearchExportParams {
    pub(crate) format: Option<ResearchExportFormat>,
    pub(crate) paper_id: Option<Uuid>,
    /// Opts into the lossless cursor contract. Supplying a cursor also opts in.
    pub(crate) paged: Option<bool>,
    pub(crate) cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ResearchExportFormat {
    #[default]
    Json,
    Markdown,
    Manifest,
}

/// Importable annotation subset of `pakperk.research-export.v1`. Other fields
/// in the full research export are intentionally ignored by this narrowly
/// scoped endpoint rather than being represented as caller authority.
#[derive(Deserialize, ToSchema)]
pub(crate) struct ResearchAnnotationImportBody {
    pub(crate) schema_version: String,
    #[serde(default)]
    #[schema(value_type = Vec<Object>)]
    pub(crate) annotations: Vec<serde_json::Value>,
    #[serde(default)]
    #[schema(value_type = Vec<Object>)]
    pub(crate) annotation_conflicts: Vec<serde_json::Value>,
    #[serde(default)]
    #[schema(value_type = Vec<Object>)]
    pub(crate) annotation_reanchor_attempts: Vec<serde_json::Value>,
    /// Page metadata is transport state, not annotation import authority.
    #[serde(default)]
    #[schema(value_type = Option<Object>)]
    pub(crate) export_page: Option<serde_json::Value>,
}

impl ResearchAnnotationImportBody {
    pub(crate) fn into_domain(self) -> Result<ResearchAnnotationImport, serde_json::Error> {
        let Self {
            schema_version,
            annotations,
            annotation_conflicts,
            annotation_reanchor_attempts,
            export_page,
        } = self;
        if export_page.is_some_and(|value| !value.is_object()) {
            return Err(serde_json::Error::io(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "research export page metadata is not an object",
            )));
        }
        serde_json::from_value(serde_json::json!({
            "schema_version": schema_version,
            "annotations": annotations,
            "annotation_conflicts": annotation_conflicts,
            "annotation_reanchor_attempts": annotation_reanchor_attempts,
        }))
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct ResearchAnnotationImportEnvelope {
    pub(crate) imported_annotations: i32,
    pub(crate) imported_conflicts: i32,
    pub(crate) imported_reanchor_attempts: i32,
    pub(crate) skipped_annotations: i32,
    pub(crate) replayed: bool,
}

impl ResearchAnnotationImportEnvelope {
    pub(crate) const fn from_result(value: ResearchAnnotationImportResult, replayed: bool) -> Self {
        Self {
            imported_annotations: value.imported_annotations,
            imported_conflicts: value.imported_conflicts,
            imported_reanchor_attempts: value.imported_reanchor_attempts,
            skipped_annotations: value.skipped_annotations,
            replayed,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AnnotationAnchorStatusResponse {
    Anchored,
    Uncertain,
    Orphaned,
}

impl From<AnnotationAnchorStatus> for AnnotationAnchorStatusResponse {
    fn from(value: AnnotationAnchorStatus) -> Self {
        match value {
            AnnotationAnchorStatus::Anchored => Self::Anchored,
            AnnotationAnchorStatus::Uncertain => Self::Uncertain,
            AnnotationAnchorStatus::Orphaned => Self::Orphaned,
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct TextSelectorResponse {
    #[serde(rename = "type")]
    pub(crate) selector_type: &'static str,
    pub(crate) exact: String,
    pub(crate) prefix: Option<String>,
    pub(crate) suffix: Option<String>,
    pub(crate) start: Option<u32>,
    pub(crate) end: Option<u32>,
}

impl From<TextQuotePositionSelector> for TextSelectorResponse {
    fn from(value: TextQuotePositionSelector) -> Self {
        Self {
            selector_type: "TextQuoteAndPosition",
            exact: value.exact,
            prefix: value.prefix,
            suffix: value.suffix,
            start: value.start,
            end: value.end,
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct AnnotationResponse {
    pub(crate) id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) block_id: Option<Uuid>,
    pub(crate) kind: AnnotationKindBodyResponse,
    pub(crate) body: Option<String>,
    pub(crate) color_role: Option<AnnotationColorRoleResponse>,
    pub(crate) selector: Option<TextSelectorResponse>,
    pub(crate) section_hint: Vec<String>,
    pub(crate) page_hint: Option<u32>,
    pub(crate) anchor_status: AnnotationAnchorStatusResponse,
    pub(crate) revision: i64,
    pub(crate) deleted_at: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

impl From<Annotation> for AnnotationResponse {
    fn from(value: Annotation) -> Self {
        Self {
            id: value.id,
            paper_id: value.paper_id,
            generation: value.generation,
            block_id: value.block_id,
            kind: value.kind.into(),
            body: value.body,
            color_role: value.color_role.map(Into::into),
            selector: value.selector.map(Into::into),
            section_hint: value.section_hint,
            page_hint: value.page_hint,
            anchor_status: value.anchor_status.into(),
            revision: value.revision,
            deleted_at: value.deleted_at.map(format_timestamp),
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AnnotationKindBodyResponse {
    Highlight,
    Note,
    Question,
    Evidence,
}

impl From<AnnotationKind> for AnnotationKindBodyResponse {
    fn from(value: AnnotationKind) -> Self {
        match value {
            AnnotationKind::Highlight => Self::Highlight,
            AnnotationKind::Note => Self::Note,
            AnnotationKind::Question => Self::Question,
            AnnotationKind::Evidence => Self::Evidence,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AnnotationColorRoleResponse {
    Yellow,
    Blue,
    Green,
    Pink,
    Purple,
}

impl From<AnnotationColorRole> for AnnotationColorRoleResponse {
    fn from(value: AnnotationColorRole) -> Self {
        match value {
            AnnotationColorRole::Yellow => Self::Yellow,
            AnnotationColorRole::Blue => Self::Blue,
            AnnotationColorRole::Green => Self::Green,
            AnnotationColorRole::Pink => Self::Pink,
            AnnotationColorRole::Purple => Self::Purple,
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct AnnotationMutationEnvelope {
    pub(crate) annotation: AnnotationResponse,
    pub(crate) replayed: bool,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct AnnotationPageEnvelope {
    pub(crate) items: Vec<AnnotationResponse>,
    pub(crate) next_after_revision: i64,
    pub(crate) has_more: bool,
    pub(crate) sync_revision: i64,
    pub(crate) purged_through_revision: i64,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct AnnotationConflictResponse {
    pub(crate) conflict_id: Uuid,
    pub(crate) annotation_id: Uuid,
    pub(crate) attempted_operation_id: Uuid,
    pub(crate) base_revision: i64,
    pub(crate) server_revision: i64,
    pub(crate) attempted_body: Option<String>,
    pub(crate) server_body: Option<String>,
    pub(crate) created_at: String,
    pub(crate) resolution: Option<AnnotationConflictResolutionResponse>,
    pub(crate) merged_body: Option<String>,
    pub(crate) resolved_at: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AnnotationConflictResolutionResponse {
    KeepServer,
    KeepAttempted,
    Merged,
    Dismissed,
}

impl From<AnnotationConflict> for AnnotationConflictResponse {
    fn from(value: AnnotationConflict) -> Self {
        Self {
            conflict_id: value.conflict_id,
            annotation_id: value.annotation_id,
            attempted_operation_id: value.attempted_operation_id,
            base_revision: value.base_revision,
            server_revision: value.server_revision,
            attempted_body: value.attempted_body,
            server_body: value.server_body,
            created_at: format_timestamp(value.created_at),
            resolution: value.resolution.map(|resolution| match resolution {
                AnnotationConflictResolution::KeepServer => {
                    AnnotationConflictResolutionResponse::KeepServer
                }
                AnnotationConflictResolution::KeepAttempted => {
                    AnnotationConflictResolutionResponse::KeepAttempted
                }
                AnnotationConflictResolution::Merged => {
                    AnnotationConflictResolutionResponse::Merged
                }
                AnnotationConflictResolution::Dismissed => {
                    AnnotationConflictResolutionResponse::Dismissed
                }
            }),
            merged_body: value.merged_body,
            resolved_at: value.resolved_at.map(format_timestamp),
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct AnnotationConflictEnvelope {
    pub(crate) conflict: AnnotationConflictResponse,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct AnnotationConflictSyncResponse {
    pub(crate) conflict: AnnotationConflictResponse,
    pub(crate) paper_id: Uuid,
    pub(crate) current_annotation_revision: i64,
}

impl From<StoredAnnotationConflict> for AnnotationConflictSyncResponse {
    fn from(value: StoredAnnotationConflict) -> Self {
        Self {
            conflict: value.conflict.into(),
            paper_id: value.paper_id,
            current_annotation_revision: value.current_annotation_revision,
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct AnnotationConflictPageEnvelope {
    pub(crate) items: Vec<AnnotationConflictSyncResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) sync_revision: i64,
}

#[derive(Clone, Copy, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum EvidenceVerificationBody {
    UserSelected,
    UserReviewed,
    Superseded,
}

impl From<EvidenceVerificationBody> for EvidenceVerificationStatus {
    fn from(value: EvidenceVerificationBody) -> Self {
        match value {
            EvidenceVerificationBody::UserSelected => Self::UserSelected,
            EvidenceVerificationBody::UserReviewed => Self::UserReviewed,
            EvidenceVerificationBody::Superseded => Self::Superseded,
        }
    }
}

#[derive(Clone, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct EvidenceCardWriteBody {
    pub(crate) id: Option<Uuid>,
    pub(crate) operation_id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) title: String,
    pub(crate) claim_or_question: Option<String>,
    pub(crate) user_note: Option<String>,
    #[serde(default)]
    pub(crate) source_block_ids: Vec<Uuid>,
    #[serde(default)]
    pub(crate) figure_ids: Vec<Uuid>,
    #[serde(default)]
    pub(crate) table_ids: Vec<Uuid>,
    #[serde(default)]
    pub(crate) citation_context_ids: Vec<Uuid>,
    pub(crate) verification_status: EvidenceVerificationBody,
    pub(crate) base_revision: i64,
}

impl EvidenceCardWriteBody {
    pub(crate) fn into_domain(
        self,
        path_id: Option<Uuid>,
    ) -> Result<EvidenceCardWrite, &'static str> {
        let id = match (path_id, self.id) {
            (Some(path), Some(body)) if path != body => return Err("path and body IDs differ"),
            (Some(path), _) => path,
            (None, Some(body)) => body,
            (None, None) => return Err("id is required"),
        };
        Ok(EvidenceCardWrite {
            id,
            operation_id: self.operation_id,
            paper_id: self.paper_id,
            generation: self.generation,
            title: self.title,
            claim_or_question: self.claim_or_question,
            user_note: self.user_note,
            source_block_ids: self.source_block_ids,
            figure_ids: self.figure_ids,
            table_ids: self.table_ids,
            citation_context_ids: self.citation_context_ids,
            verification_status: self.verification_status.into(),
            base_revision: self.base_revision,
        })
    }
}

#[derive(Debug, Deserialize, IntoParams)]
#[serde(deny_unknown_fields)]
pub(crate) struct CursorPageParams {
    pub(crate) paper_id: Option<Uuid>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct EvidenceCardResponse {
    pub(crate) id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) title: Option<String>,
    pub(crate) claim_or_question: Option<String>,
    pub(crate) user_note: Option<String>,
    pub(crate) source_block_ids: Vec<Uuid>,
    pub(crate) figure_ids: Vec<Uuid>,
    pub(crate) table_ids: Vec<Uuid>,
    pub(crate) citation_context_ids: Vec<Uuid>,
    pub(crate) verification_status: EvidenceVerificationResponse,
    pub(crate) revision: i64,
    pub(crate) deleted_at: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

#[derive(Debug, Clone, Copy, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum EvidenceVerificationResponse {
    UserSelected,
    UserReviewed,
    Superseded,
}

impl From<EvidenceCard> for EvidenceCardResponse {
    fn from(value: EvidenceCard) -> Self {
        Self {
            id: value.id,
            paper_id: value.paper_id,
            generation: value.generation,
            title: value.title,
            claim_or_question: value.claim_or_question,
            user_note: value.user_note,
            source_block_ids: value.source_block_ids,
            figure_ids: value.figure_ids,
            table_ids: value.table_ids,
            citation_context_ids: value.citation_context_ids,
            verification_status: match value.verification_status {
                EvidenceVerificationStatus::UserSelected => {
                    EvidenceVerificationResponse::UserSelected
                }
                EvidenceVerificationStatus::UserReviewed => {
                    EvidenceVerificationResponse::UserReviewed
                }
                EvidenceVerificationStatus::Superseded => EvidenceVerificationResponse::Superseded,
            },
            revision: value.revision,
            deleted_at: value.deleted_at.map(format_timestamp),
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct EvidenceCardMutationEnvelope {
    pub(crate) evidence_card: EvidenceCardResponse,
    pub(crate) replayed: bool,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct EvidenceCardPageEnvelope {
    pub(crate) items: Vec<EvidenceCardResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) sync_revision: i64,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReaderModeBody {
    Skim,
    Read,
    Inspect,
}

impl From<ReaderModeBody> for ReaderMode {
    fn from(value: ReaderModeBody) -> Self {
        match value {
            ReaderModeBody::Skim => Self::Skim,
            ReaderModeBody::Read => Self::Read,
            ReaderModeBody::Inspect => Self::Inspect,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReaderStageBody {
    Abstract,
    Introduction,
    Connections,
}

impl From<ReaderStageBody> for ReaderStage {
    fn from(value: ReaderStageBody) -> Self {
        match value {
            ReaderStageBody::Abstract => Self::Abstract,
            ReaderStageBody::Introduction => Self::Introduction,
            ReaderStageBody::Connections => Self::Connections,
        }
    }
}

#[derive(Debug, Clone, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReadingCheckpointWriteBody {
    pub(crate) operation_id: Uuid,
    pub(crate) base_revision: i64,
    pub(crate) generation: i32,
    pub(crate) mode: ReaderModeBody,
    pub(crate) stage: ReaderStageBody,
    pub(crate) block_id: Option<Uuid>,
    pub(crate) scroll_fraction: Option<f32>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) last_read_at: DateTime<Utc>,
}

impl From<ReadingCheckpointWriteBody> for ReadingCheckpointWrite {
    fn from(value: ReadingCheckpointWriteBody) -> Self {
        Self {
            operation_id: value.operation_id,
            base_revision: value.base_revision,
            generation: value.generation,
            mode: value.mode.into(),
            stage: value.stage.into(),
            block_id: value.block_id,
            scroll_fraction: value.scroll_fraction,
            last_read_at: value.last_read_at,
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct ReadingCheckpointResponse {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) mode: ReaderModeBody,
    pub(crate) stage: ReaderStageBody,
    pub(crate) block_id: Option<Uuid>,
    pub(crate) scroll_fraction: Option<f32>,
    pub(crate) last_read_at: String,
    pub(crate) revision: i64,
}

impl From<ReadingCheckpoint> for ReadingCheckpointResponse {
    fn from(value: ReadingCheckpoint) -> Self {
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            mode: match value.mode {
                ReaderMode::Skim => ReaderModeBody::Skim,
                ReaderMode::Read => ReaderModeBody::Read,
                ReaderMode::Inspect => ReaderModeBody::Inspect,
            },
            stage: match value.stage {
                ReaderStage::Abstract => ReaderStageBody::Abstract,
                ReaderStage::Introduction => ReaderStageBody::Introduction,
                ReaderStage::Connections => ReaderStageBody::Connections,
            },
            block_id: value.block_id,
            scroll_fraction: value.scroll_fraction,
            last_read_at: format_timestamp(value.last_read_at),
            revision: value.revision,
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct CheckpointMutationEnvelope {
    pub(crate) checkpoint: ReadingCheckpointResponse,
    pub(crate) replayed: bool,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct CheckpointsEnvelope {
    pub(crate) items: Vec<ReadingCheckpointResponse>,
    pub(crate) sync_revision: i64,
}

#[derive(Clone, Copy, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MemorySourceBody {
    Annotation,
    EvidenceCard,
    PassportField,
    UserQuestion,
}

impl From<MemorySourceBody> for MemorySourceType {
    fn from(value: MemorySourceBody) -> Self {
        match value {
            MemorySourceBody::Annotation => Self::Annotation,
            MemorySourceBody::EvidenceCard => Self::EvidenceCard,
            MemorySourceBody::PassportField => Self::PassportField,
            MemorySourceBody::UserQuestion => Self::UserQuestion,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MemoryStatusBody {
    Active,
    Snoozed,
    Retired,
}

impl From<MemoryStatusBody> for MemoryStatus {
    fn from(value: MemoryStatusBody) -> Self {
        match value {
            MemoryStatusBody::Active => Self::Active,
            MemoryStatusBody::Snoozed => Self::Snoozed,
            MemoryStatusBody::Retired => Self::Retired,
        }
    }
}

#[derive(Clone, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct MemoryItemWriteBody {
    pub(crate) id: Option<Uuid>,
    pub(crate) operation_id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) source_type: MemorySourceBody,
    pub(crate) source_id: Uuid,
    pub(crate) prompt_text: Option<String>,
    pub(crate) answer_text: Option<String>,
    pub(crate) status: MemoryStatusBody,
    #[schema(value_type = Option<String>, format = DateTime)]
    pub(crate) next_review_at: Option<DateTime<Utc>>,
    pub(crate) base_revision: i64,
}

impl MemoryItemWriteBody {
    pub(crate) fn into_domain(
        self,
        path_id: Option<Uuid>,
    ) -> Result<MemoryItemWrite, &'static str> {
        let id = match (path_id, self.id) {
            (Some(path), Some(body)) if path != body => return Err("path and body IDs differ"),
            (Some(path), _) => path,
            (None, Some(body)) => body,
            (None, None) => return Err("id is required"),
        };
        Ok(MemoryItemWrite {
            id,
            operation_id: self.operation_id,
            paper_id: self.paper_id,
            generation: self.generation,
            source_type: self.source_type.into(),
            source_id: self.source_id,
            prompt_text: self.prompt_text,
            answer_text: self.answer_text,
            status: self.status.into(),
            next_review_at: self.next_review_at,
            base_revision: self.base_revision,
        })
    }
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct MemoryReviewBody {
    pub(crate) operation_id: Uuid,
    pub(crate) base_revision: i64,
    pub(crate) status: MemoryStatusBody,
    #[schema(value_type = Option<String>, format = DateTime)]
    pub(crate) next_review_at: Option<DateTime<Utc>>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) reviewed_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize, IntoParams)]
#[serde(deny_unknown_fields)]
pub(crate) struct MemoryReviewParams {
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct MemoryItemResponse {
    pub(crate) id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) source_type: MemorySourceResponse,
    pub(crate) source_id: Uuid,
    pub(crate) prompt_text: Option<String>,
    pub(crate) answer_text: Option<String>,
    pub(crate) status: MemoryStatusBody,
    pub(crate) next_review_at: Option<String>,
    pub(crate) review_count: u32,
    pub(crate) revision: i64,
    pub(crate) deleted_at: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

#[derive(Debug, Clone, Copy, Serialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MemorySourceResponse {
    Annotation,
    EvidenceCard,
    PassportField,
    UserQuestion,
}

impl From<MemoryItem> for MemoryItemResponse {
    fn from(value: MemoryItem) -> Self {
        Self {
            id: value.id,
            paper_id: value.paper_id,
            generation: value.generation,
            source_type: match value.source_type {
                MemorySourceType::Annotation => MemorySourceResponse::Annotation,
                MemorySourceType::EvidenceCard => MemorySourceResponse::EvidenceCard,
                MemorySourceType::PassportField => MemorySourceResponse::PassportField,
                MemorySourceType::UserQuestion => MemorySourceResponse::UserQuestion,
            },
            source_id: value.source_id,
            prompt_text: value.prompt_text,
            answer_text: value.answer_text,
            status: match value.status {
                MemoryStatus::Active => MemoryStatusBody::Active,
                MemoryStatus::Snoozed => MemoryStatusBody::Snoozed,
                MemoryStatus::Retired => MemoryStatusBody::Retired,
            },
            next_review_at: value.next_review_at.map(format_timestamp),
            review_count: value.review_count,
            revision: value.revision,
            deleted_at: value.deleted_at.map(format_timestamp),
            created_at: format_timestamp(value.created_at),
            updated_at: format_timestamp(value.updated_at),
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct MemoryMutationEnvelope {
    pub(crate) memory_item: MemoryItemResponse,
    pub(crate) replayed: bool,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct MemoryPageEnvelope {
    pub(crate) items: Vec<MemoryItemResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) sync_revision: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_write_bodies_reject_caller_supplied_authority() {
        let json = r#"{
            "operation_id":"0198f4da-383f-77f0-9404-e6d6614d26e1",
            "paper_id":"0198f4da-383f-77f0-9404-e6d6614d26e2",
            "generation":1,
            "block_id":"0198f4da-383f-77f0-9404-e6d6614d26e3",
            "kind":"note",
            "body":"private",
            "color_role":null,
            "selector":{"type":"TextQuoteAndPosition","exact":"quote","prefix":null,"suffix":null,"start":0,"end":5},
            "section_hint":[],"page_hint":null,"base_revision":0,
            "user_id":"0198f4da-383f-77f0-9404-e6d6614d26e4"
        }"#;
        assert!(serde_json::from_str::<AnnotationWriteBody>(json).is_err());
        assert!(!std::any::type_name::<AnnotationWriteBody>().contains("user_id"));
    }

    #[test]
    fn selector_type_is_exact_and_path_owns_annotation_id() {
        let selector = TextSelectorBody {
            selector_type: "TextPositionSelector".to_owned(),
            exact: "quote".to_owned(),
            prefix: None,
            suffix: None,
            start: Some(0),
            end: Some(5),
        };
        assert!(selector.into_domain().is_err());
    }

    #[test]
    fn annotation_import_rejects_unknown_nested_authority_fields() {
        let body = ResearchAnnotationImportBody {
            schema_version: "pakperk.research-export.v1".to_owned(),
            annotations: Vec::new(),
            annotation_conflicts: vec![serde_json::json!({
                "conflict_id": "0198f4da-383f-77f0-9404-e6d6614d26e1",
                "annotation_id": "0198f4da-383f-77f0-9404-e6d6614d26e2",
                "attempted_operation_id": "0198f4da-383f-77f0-9404-e6d6614d26e3",
                "base_revision": 1,
                "server_revision": 2,
                "attempted_body": "attempted",
                "server_body": "server",
                "created_at": "2026-08-31T00:00:00Z",
                "resolution": null,
                "merged_body": null,
                "resolved_at": null,
                "user_id": "0198f4da-383f-77f0-9404-e6d6614d26e4"
            })],
            annotation_reanchor_attempts: Vec::new(),
            export_page: None,
        };
        assert!(body.into_domain().is_err());
    }

    #[test]
    fn annotation_import_accepts_only_object_export_page_metadata() {
        let page = ResearchAnnotationImportBody {
            schema_version: "pakperk.research-export.v1".to_owned(),
            annotations: Vec::new(),
            annotation_conflicts: Vec::new(),
            annotation_reanchor_attempts: Vec::new(),
            export_page: Some(serde_json::json!({
                "schema_version": "pakperk.research-export-page.v1",
                "page_number": 1,
                "complete": true
            })),
        };
        assert!(page.into_domain().is_ok());

        let invalid = ResearchAnnotationImportBody {
            schema_version: "pakperk.research-export.v1".to_owned(),
            annotations: Vec::new(),
            annotation_conflicts: Vec::new(),
            annotation_reanchor_attempts: Vec::new(),
            export_page: Some(serde_json::json!("not metadata")),
        };
        assert!(invalid.into_domain().is_err());
    }

    #[test]
    fn checkpoint_list_scope_is_optional_and_strict() {
        let empty = serde_json::from_value::<CheckpointListParams>(serde_json::json!({}));
        assert!(empty.is_ok());
        let scoped = serde_json::from_value::<CheckpointListParams>(serde_json::json!({
            "paper_id": "0198f4da-383f-77f0-9404-e6d6614d26e2"
        }))
        .unwrap();
        assert_eq!(
            scoped.paper_id,
            Some(Uuid::parse_str("0198f4da-383f-77f0-9404-e6d6614d26e2").unwrap())
        );
        assert!(
            serde_json::from_value::<CheckpointListParams>(serde_json::json!({
                "paper_id": "0198f4da-383f-77f0-9404-e6d6614d26e2",
                "user_id": "0198f4da-383f-77f0-9404-e6d6614d26e3"
            }))
            .is_err()
        );
    }
}
