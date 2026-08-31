use std::{fmt, str::FromStr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{PaperId, PaperSummary};

/// The canonical Plan 02 library state. Active queue authority is a property
/// of this closed enum, never a second persisted boolean.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibraryState {
    Inbox,
    ReadNext,
    Reading,
    Reviewed,
    Archived,
}

impl LibraryState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Inbox => "inbox",
            Self::ReadNext => "read_next",
            Self::Reading => "reading",
            Self::Reviewed => "reviewed",
            Self::Archived => "archived",
        }
    }

    #[must_use]
    pub const fn is_active(self) -> bool {
        matches!(self, Self::Inbox | Self::ReadNext | Self::Reading)
    }
}

impl fmt::Display for LibraryState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for LibraryState {
    type Err = LibraryStateParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "inbox" => Ok(Self::Inbox),
            "read_next" => Ok(Self::ReadNext),
            "reading" => Ok(Self::Reading),
            "reviewed" => Ok(Self::Reviewed),
            "archived" => Ok(Self::Archived),
            _ => Err(LibraryStateParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown library state")]
pub struct LibraryStateParseError;

/// Content-free provenance for a deliberate save. This is queue provenance,
/// not a recommendation explanation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibrarySaveSourceKind {
    Discovery,
    Lookup,
    TitleSearch,
    ArxivUrl,
    ArxivId,
    Connection,
    Other,
}

impl LibrarySaveSourceKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Discovery => "discovery",
            Self::Lookup => "lookup",
            Self::TitleSearch => "title_search",
            Self::ArxivUrl => "arxiv_url",
            Self::ArxivId => "arxiv_id",
            Self::Connection => "connection",
            Self::Other => "other",
        }
    }
}

impl FromStr for LibrarySaveSourceKind {
    type Err = LibrarySaveSourceKindParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "discovery" => Ok(Self::Discovery),
            "lookup" => Ok(Self::Lookup),
            "title_search" => Ok(Self::TitleSearch),
            "arxiv_url" => Ok(Self::ArxivUrl),
            "arxiv_id" => Ok(Self::ArxivId),
            "connection" => Ok(Self::Connection),
            "other" => Ok(Self::Other),
            _ => Err(LibrarySaveSourceKindParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown library save source")]
pub struct LibrarySaveSourceKindParseError;

/// A canonical server library record. `removed_at` is retained so clients can
/// converge after an unsave without interpreting absence as stale data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryItem {
    pub paper_id: PaperId,
    pub state: LibraryState,
    pub private_note: Option<String>,
    pub save_source_kind: Option<LibrarySaveSourceKind>,
    /// User-selected UTC delivery time. Only active, non-removed items may
    /// retain a reminder; the private note is never copied into notifications.
    pub reminder_at: Option<DateTime<Utc>>,
    pub saved_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub reviewed_at: Option<DateTime<Utc>>,
    pub archived_at: Option<DateTime<Utc>>,
    pub removed_at: Option<DateTime<Utc>>,
    pub revision: i64,
    pub last_operation_id: Uuid,
}

impl LibraryItem {
    #[must_use]
    pub const fn removed(&self) -> bool {
        self.removed_at.is_some()
    }

    #[must_use]
    pub const fn active(&self) -> bool {
        !self.removed() && self.state.is_active()
    }
}

/// A library record paired with public metadata. Loading this value is
/// metadata-only and must never enqueue paper preparation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SavedLibraryPaper {
    #[serde(flatten)]
    pub item: LibraryItem,
    pub paper: PaperSummary,
}

/// One v0-compatible incremental synchronization record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LibraryChange {
    #[serde(flatten)]
    pub item: LibraryItem,
    pub paper: Option<PaperSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryList {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
    pub sort_order: i32,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_operation_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryListItem {
    pub list_id: Uuid,
    pub paper_id: PaperId,
    pub position_rank: i64,
    pub note: Option<String>,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_operation_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryTag {
    pub id: Uuid,
    pub name: String,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_operation_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryItemTag {
    pub paper_id: PaperId,
    pub tag_id: Uuid,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_operation_id: Uuid,
}

/// The v2 change feed shares the canonical per-account library revision across
/// paper state, lists, tags, and membership changes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "entity", rename_all = "snake_case")]
pub enum LibraryV2Change {
    Item {
        item: LibraryItem,
        paper: Option<Box<PaperSummary>>,
    },
    List {
        list: LibraryList,
    },
    ListItem {
        list_item: LibraryListItem,
    },
    Tag {
        tag: LibraryTag,
    },
    ItemTag {
        item_tag: LibraryItemTag,
    },
}

impl LibraryV2Change {
    #[must_use]
    pub const fn revision(&self) -> i64 {
        match self {
            Self::Item { item, .. } => item.revision,
            Self::List { list } => list.revision,
            Self::ListItem { list_item } => list_item.revision,
            Self::Tag { tag } => tag.revision,
            Self::ItemTag { item_tag } => item_tag.revision,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn five_states_are_closed_and_active_membership_is_explicit() {
        let states = [
            ("inbox", LibraryState::Inbox, true),
            ("read_next", LibraryState::ReadNext, true),
            ("reading", LibraryState::Reading, true),
            ("reviewed", LibraryState::Reviewed, false),
            ("archived", LibraryState::Archived, false),
        ];
        for (wire, state, active) in states {
            assert_eq!(LibraryState::from_str(wire), Ok(state));
            assert_eq!(state.to_string(), wire);
            assert_eq!(state.is_active(), active);
        }
        assert!(LibraryState::from_str("to_read").is_err());
        assert!(LibraryState::from_str("favorites").is_err());
    }

    #[test]
    fn save_sources_are_closed_content_free_codes() {
        for source in [
            LibrarySaveSourceKind::Discovery,
            LibrarySaveSourceKind::Lookup,
            LibrarySaveSourceKind::TitleSearch,
            LibrarySaveSourceKind::ArxivUrl,
            LibrarySaveSourceKind::ArxivId,
            LibrarySaveSourceKind::Connection,
            LibrarySaveSourceKind::Other,
        ] {
            assert_eq!(LibrarySaveSourceKind::from_str(source.as_str()), Ok(source));
        }
        assert!(LibrarySaveSourceKind::from_str("private_note").is_err());
    }
}
