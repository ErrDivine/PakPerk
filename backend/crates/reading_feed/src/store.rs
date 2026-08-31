use std::num::NonZeroU64;

use async_trait::async_trait;
use domain::{AuthenticatedUserId, LibrarySaveSourceKind, LibraryState, PaperSummary};

use crate::{
    FeedMode, ReadingFeedCursorPosition, ReadingFeedStoreError, RecommendationPage, ToReadPosition,
};

/// Cursor fence presented to the snapshot store. Implementations must compare
/// the revision inside the same consistent read that chooses the feed mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadingFeedContinuation {
    pub mode: FeedMode,
    pub library_revision: i64,
    pub position: ReadingFeedCursorPosition,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadingFeedSnapshotRequest {
    pub user_id: AuthenticatedUserId,
    /// Applies to recommendation selection only. A category must never filter
    /// or hide an active account queue.
    pub category: Option<String>,
    pub continuation: Option<ReadingFeedContinuation>,
    pub limit: u32,
}

/// One active queue record already joined to its bounded public summary.
#[derive(Debug, Clone, PartialEq)]
pub struct QueueSnapshotItem {
    pub paper: PaperSummary,
    pub state: LibraryState,
    pub saved_at: chrono::DateTime<chrono::Utc>,
    pub revision: i64,
    pub save_source_kind: Option<LibrarySaveSourceKind>,
}

/// A closed result prevents unavailable authority from being represented as an
/// empty queue. SQL implementations must produce this from one consistent
/// account/revision/count/page snapshot.
#[derive(Debug, Clone, PartialEq)]
pub enum ReadingFeedSnapshot {
    Queue {
        library_revision: i64,
        active_to_read_count: NonZeroU64,
        items: Vec<QueueSnapshotItem>,
        /// When present, this is exactly the final returned item's position.
        next_position: Option<ToReadPosition>,
    },
    Empty {
        library_revision: i64,
        /// Bounded, excluded candidates selected in the same consistent read
        /// that proved the queue empty. The recommendation source may only
        /// rank or filter this page; it must not introduce unchecked papers.
        recommendations: RecommendationPage,
    },
}

#[async_trait]
pub trait ReadingFeedStore: Send + Sync {
    async fn snapshot(
        &self,
        request: &ReadingFeedSnapshotRequest,
    ) -> Result<ReadingFeedSnapshot, ReadingFeedStoreError>;
}
