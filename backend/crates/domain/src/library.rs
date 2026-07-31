use std::{fmt, str::FromStr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{PaperId, PaperSummary};

/// The deliberately small first-release library state. Additional lists must
/// become explicit variants rather than being accepted as arbitrary strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibraryState {
    ToRead,
}

impl LibraryState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ToRead => "to_read",
        }
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
            "to_read" => Ok(Self::ToRead),
            _ => Err(LibraryStateParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown library state")]
pub struct LibraryStateParseError;

/// A canonical server library record. `removed_at` is retained so clients can
/// converge after an unsave without interpreting absence as stale data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryItem {
    pub paper_id: PaperId,
    pub state: LibraryState,
    pub saved_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub removed_at: Option<DateTime<Utc>>,
    pub revision: i64,
    pub last_operation_id: Uuid,
}

impl LibraryItem {
    #[must_use]
    pub const fn removed(&self) -> bool {
        self.removed_at.is_some()
    }
}

/// An active library record paired with public metadata. Loading this value is
/// metadata-only and must never enqueue paper preparation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SavedLibraryPaper {
    #[serde(flatten)]
    pub item: LibraryItem,
    pub paper: PaperSummary,
}

/// One incremental synchronization record. Active records always carry paper
/// metadata; the optional shape lets a future retention policy deliver a
/// tombstone even after its public paper record has been administratively
/// removed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LibraryChange {
    #[serde(flatten)]
    pub item: LibraryItem,
    pub paper: Option<PaperSummary>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_v0_library_state_is_accepted() {
        assert_eq!(LibraryState::from_str("to_read"), Ok(LibraryState::ToRead));
        assert!(LibraryState::from_str("favorites").is_err());
        assert_eq!(LibraryState::ToRead.to_string(), "to_read");
    }
}
