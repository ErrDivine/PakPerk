use chrono::{DateTime, Utc};
use domain::{
    LibraryItem, LibraryItemTag, LibraryList, LibraryListItem, LibrarySaveSourceKind, LibraryState,
    LibraryTag, LibraryV2Change, PaperSummary, SavedLibraryPaper,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{ProfilePatchField, format_timestamp};

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LibraryV2StateBody {
    Inbox,
    ReadNext,
    Reading,
    Reviewed,
    Archived,
}

impl From<LibraryV2StateBody> for LibraryState {
    fn from(value: LibraryV2StateBody) -> Self {
        match value {
            LibraryV2StateBody::Inbox => Self::Inbox,
            LibraryV2StateBody::ReadNext => Self::ReadNext,
            LibraryV2StateBody::Reading => Self::Reading,
            LibraryV2StateBody::Reviewed => Self::Reviewed,
            LibraryV2StateBody::Archived => Self::Archived,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LibrarySaveSourceBody {
    Discovery,
    Lookup,
    TitleSearch,
    ArxivUrl,
    ArxivId,
    Connection,
    Other,
}

impl From<LibrarySaveSourceBody> for LibrarySaveSourceKind {
    fn from(value: LibrarySaveSourceBody) -> Self {
        match value {
            LibrarySaveSourceBody::Discovery => Self::Discovery,
            LibrarySaveSourceBody::Lookup => Self::Lookup,
            LibrarySaveSourceBody::TitleSearch => Self::TitleSearch,
            LibrarySaveSourceBody::ArxivUrl => Self::ArxivUrl,
            LibrarySaveSourceBody::ArxivId => Self::ArxivId,
            LibrarySaveSourceBody::Connection => Self::Connection,
            LibrarySaveSourceBody::Other => Self::Other,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryV2ListParams {
    pub(crate) state: Option<LibraryV2StateBody>,
    pub(crate) list_id: Option<Uuid>,
    pub(crate) tag_id: Option<Uuid>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryV2ChangesParams {
    pub(crate) after_revision: Option<i64>,
    pub(crate) limit: Option<u32>,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryV2ItemWriteBody {
    pub(crate) operation_id: Uuid,
    pub(crate) state: LibraryV2StateBody,
    #[schema(max_length = 500)]
    pub(crate) private_note: Option<String>,
    pub(crate) save_source_kind: Option<LibrarySaveSourceBody>,
    /// Omitted preserves the existing reminder, null clears it, and a UTC
    /// date-time replaces it. The service rejects past or inactive reminders.
    #[serde(default)]
    #[schema(required = false, nullable, value_type = String, format = DateTime)]
    pub(crate) reminder_at: ProfilePatchField<DateTime<Utc>>,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryListWriteBody {
    pub(crate) operation_id: Uuid,
    pub(crate) id: Uuid,
    #[schema(max_length = 100)]
    pub(crate) name: String,
    #[schema(max_length = 500)]
    pub(crate) description: Option<String>,
    #[serde(default)]
    pub(crate) sort_order: i32,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryListPatchBody {
    pub(crate) operation_id: Uuid,
    #[schema(max_length = 100)]
    pub(crate) name: String,
    #[schema(max_length = 500)]
    pub(crate) description: Option<String>,
    #[serde(default)]
    pub(crate) sort_order: i32,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryTagWriteBody {
    pub(crate) operation_id: Uuid,
    pub(crate) id: Uuid,
    #[schema(max_length = 60)]
    pub(crate) name: String,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryTagPatchBody {
    pub(crate) operation_id: Uuid,
    #[schema(max_length = 60)]
    pub(crate) name: String,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct LibraryListItemWriteBody {
    pub(crate) operation_id: Uuid,
    #[serde(default)]
    pub(crate) position_rank: i64,
    #[schema(max_length = 500)]
    pub(crate) note: Option<String>,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryV2ItemResponse {
    pub(crate) paper_id: Uuid,
    pub(crate) state: LibraryState,
    pub(crate) private_note: Option<String>,
    pub(crate) save_source_kind: Option<LibrarySaveSourceKind>,
    pub(crate) reminder_at: Option<String>,
    pub(crate) saved_at: String,
    pub(crate) updated_at: String,
    pub(crate) reviewed_at: Option<String>,
    pub(crate) archived_at: Option<String>,
    pub(crate) removed: bool,
    pub(crate) removed_at: Option<String>,
    pub(crate) revision: i64,
    pub(crate) last_operation_id: Uuid,
}

impl From<LibraryItem> for LibraryV2ItemResponse {
    fn from(item: LibraryItem) -> Self {
        let removed = item.removed();
        Self {
            paper_id: item.paper_id,
            state: item.state,
            private_note: item.private_note,
            save_source_kind: item.save_source_kind,
            reminder_at: item.reminder_at.map(format_timestamp),
            saved_at: format_timestamp(item.saved_at),
            updated_at: format_timestamp(item.updated_at),
            reviewed_at: item.reviewed_at.map(format_timestamp),
            archived_at: item.archived_at.map(format_timestamp),
            removed,
            removed_at: item.removed_at.map(format_timestamp),
            revision: item.revision,
            last_operation_id: item.last_operation_id,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryV2EntryResponse {
    pub(crate) item: LibraryV2ItemResponse,
    pub(crate) paper: PaperSummary,
}

impl From<SavedLibraryPaper> for LibraryV2EntryResponse {
    fn from(value: SavedLibraryPaper) -> Self {
        Self {
            item: value.item.into(),
            paper: value.paper,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryV2ItemsEnvelope {
    pub(crate) items: Vec<LibraryV2EntryResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) sync_revision: i64,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryV2ItemMutationEnvelope {
    pub(crate) item: LibraryV2ItemResponse,
    pub(crate) replayed: bool,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryListsEnvelope {
    pub(crate) items: Vec<LibraryList>,
    pub(crate) sync_revision: i64,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryListMutationEnvelope {
    pub(crate) list: LibraryList,
    pub(crate) replayed: bool,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryTagsEnvelope {
    pub(crate) items: Vec<LibraryTag>,
    pub(crate) sync_revision: i64,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryTagMutationEnvelope {
    pub(crate) tag: LibraryTag,
    pub(crate) replayed: bool,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryListItemMutationEnvelope {
    pub(crate) list_item: LibraryListItem,
    pub(crate) replayed: bool,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryItemTagMutationEnvelope {
    pub(crate) item_tag: LibraryItemTag,
    pub(crate) replayed: bool,
}

#[derive(Debug, Serialize)]
pub(crate) struct LibraryV2ChangesEnvelope {
    pub(crate) items: Vec<LibraryV2Change>,
    pub(crate) next_after_revision: i64,
    pub(crate) has_more: bool,
    pub(crate) sync_revision: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mutation_bodies_are_strict_and_use_closed_states_and_sources() {
        let operation_id = Uuid::now_v7();
        let valid = format!(
            r#"{{"operation_id":"{operation_id}","state":"read_next","private_note":"Compare proofs","save_source_kind":"title_search"}}"#
        );
        let body: LibraryV2ItemWriteBody = serde_json::from_str(&valid).unwrap();
        assert!(matches!(body.state, LibraryV2StateBody::ReadNext));
        assert_eq!(body.private_note.as_deref(), Some("Compare proofs"));
        assert!(matches!(
            body.save_source_kind,
            Some(LibrarySaveSourceBody::TitleSearch)
        ));
        assert!(matches!(body.reminder_at, ProfilePatchField::Omitted));
        let cleared: LibraryV2ItemWriteBody = serde_json::from_str(&format!(
            r#"{{"operation_id":"{operation_id}","state":"inbox","reminder_at":null}}"#
        ))
        .unwrap();
        assert!(matches!(cleared.reminder_at, ProfilePatchField::Null));
        let selected: LibraryV2ItemWriteBody = serde_json::from_str(&format!(
            r#"{{"operation_id":"{operation_id}","state":"inbox","reminder_at":"2026-09-03T07:30:00+08:00"}}"#
        ))
        .unwrap();
        assert!(matches!(
            selected.reminder_at,
            ProfilePatchField::Value(value)
                if value == "2026-09-02T23:30:00Z".parse::<DateTime<Utc>>().unwrap()
        ));
        assert!(
            serde_json::from_str::<LibraryV2ItemWriteBody>(&format!(
                r#"{{"operation_id":"{operation_id}","state":"to_read"}}"#
            ))
            .is_err()
        );
        assert!(
            serde_json::from_str::<LibraryV2ItemWriteBody>(&format!(
                r#"{{"operation_id":"{operation_id}","state":"inbox","prepare":true}}"#
            ))
            .is_err(),
            "library writes must not expose paper preparation"
        );
        assert!(
            serde_json::from_str::<LibraryListWriteBody>(&format!(
                r#"{{"operation_id":"{operation_id}","id":"{}","name":"Methods","shared":true}}"#,
                Uuid::now_v7()
            ))
            .is_err(),
            "v0.1 lists remain private and deny sharing controls"
        );
    }
}
