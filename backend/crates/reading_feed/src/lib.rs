//! Transport-independent queue-first reading-feed policy.
//!
//! This crate owns the decision that recommendations are permitted only after
//! a consistent account snapshot proves the To Read queue empty. HTTP, SQL,
//! full-text preparation, and recommendation ranking implementations remain
//! outside this boundary.

mod error;
mod model;
mod policy;
mod recommendation;
mod service;
mod store;

pub use error::{
    CursorCodecError, ReadingFeedPolicyError, ReadingFeedServiceError, ReadingFeedStoreError,
    RecommendationError,
};
pub use model::{
    CursorKeyEpoch, FeedItemSource, FeedMode, QueueMetadata,
    RECOMMENDATION_BATCH_VERSION_MAX_BYTES, ReadingFeedCursorClaims, ReadingFeedCursorOrdering,
    ReadingFeedCursorPosition, ReadingFeedDecision, ReadingFeedItem, ReadingFeedPage,
    ReadingFeedRequest, RecommendationBatchMetadata, RecommendationMetadata, RecommendationMode,
    RecommendationPosition, ToReadPosition,
};
pub use policy::{READING_FEED_CURSOR_POLICY_VERSION, ReadingFeedPolicy};
pub use recommendation::{
    ChronologicalRecommendationSource, RecommendationPage, RecommendationRequest,
    RecommendationResultItem, RecommendationResultPage, RecommendationSource,
};
pub use service::{ReadingFeedCursorCodec, ReadingFeedService};
pub use store::{
    QueueSnapshotItem, ReadingFeedContinuation, ReadingFeedSnapshot, ReadingFeedSnapshotRequest,
    ReadingFeedStore,
};
