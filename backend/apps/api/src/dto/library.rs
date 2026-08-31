use domain::{LibraryItem, LibraryState, PaperSummary, SavedLibraryPaper};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{LibrarySaveSourceBody, format_timestamp};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryListParams {
    pub(crate) state: Option<String>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryChangesParams {
    pub(crate) after_revision: Option<i64>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LibraryStateBody {
    ToRead,
}

impl From<LibraryStateBody> for LibraryState {
    fn from(value: LibraryStateBody) -> Self {
        match value {
            LibraryStateBody::ToRead => Self::Inbox,
        }
    }
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibrarySaveBody {
    pub(crate) operation_id: Uuid,
    pub(crate) state: LibraryStateBody,
    pub(crate) save_source_kind: Option<LibrarySaveSourceBody>,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryItemResponse {
    pub(crate) paper_id: Uuid,
    pub(crate) state: LibraryStateBody,
    pub(crate) saved_at: String,
    pub(crate) updated_at: String,
    pub(crate) removed: bool,
    pub(crate) removed_at: Option<String>,
    pub(crate) revision: i64,
    pub(crate) last_operation_id: Uuid,
}

impl From<LibraryItem> for LibraryItemResponse {
    fn from(item: LibraryItem) -> Self {
        let removed = item.removed() || !item.state.is_active();
        let removed_at = item
            .removed_at
            .or_else(|| (!item.state.is_active()).then_some(item.updated_at));
        Self {
            paper_id: item.paper_id,
            state: LibraryStateBody::ToRead,
            saved_at: format_timestamp(item.saved_at),
            updated_at: format_timestamp(item.updated_at),
            removed,
            removed_at: removed_at.map(format_timestamp),
            revision: item.revision,
            last_operation_id: item.last_operation_id,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryMutationEnvelope {
    pub(crate) item: LibraryItemResponse,
}

impl From<LibraryItem> for LibraryMutationEnvelope {
    fn from(item: LibraryItem) -> Self {
        Self { item: item.into() }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryListEntryResponse {
    pub(crate) item: LibraryItemResponse,
    pub(crate) paper: PaperSummary,
}

impl From<SavedLibraryPaper> for LibraryListEntryResponse {
    fn from(saved: SavedLibraryPaper) -> Self {
        Self {
            item: saved.item.into(),
            paper: saved.paper,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryListEnvelope {
    pub(crate) items: Vec<LibraryListEntryResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) sync_revision: i64,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryChangeEntryResponse {
    pub(crate) item: LibraryItemResponse,
    pub(crate) paper: Option<PaperSummary>,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryChangesEnvelope {
    pub(crate) items: Vec<LibraryChangeEntryResponse>,
    pub(crate) next_after_revision: i64,
    pub(crate) has_more: bool,
    pub(crate) sync_revision: i64,
}
