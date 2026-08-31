use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ReadingFeedPolicyError {
    #[error("reading-feed page-limit policy is invalid")]
    InvalidPageLimits,
    #[error("reading-feed cursor TTL is invalid")]
    InvalidCursorTtl,
    #[error("reading-feed page limit is outside the supported range")]
    InvalidPageLimit,
    #[error("reading-feed category is invalid")]
    InvalidCategory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CursorCodecError {
    #[error("reading-feed cursor is invalid or expired")]
    Invalid,
    #[error("reading-feed cursor could not be issued")]
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ReadingFeedStoreError {
    #[error("account was not found")]
    AccountNotFound,
    #[error("account is suspended")]
    Suspended,
    #[error("account deletion is pending")]
    DeletionPending,
    #[error("account is deleted")]
    Deleted,
    #[error("reading-feed cursor revision is stale")]
    RevisionStale,
    #[error("reading-feed storage is unavailable")]
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum RecommendationError {
    #[error("reading-feed revision changed while recommendations were selected")]
    RevisionStale,
    #[error("recommendations are unavailable")]
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ReadingFeedServiceError {
    #[error("reading-feed policy rejected the request")]
    Policy(#[from] ReadingFeedPolicyError),
    #[error("reading-feed cursor is invalid or expired")]
    InvalidCursor,
    #[error("reading-feed cursor is stale")]
    CursorStale,
    #[error("account was not found")]
    AccountNotFound,
    #[error("account is suspended")]
    Suspended,
    #[error("account deletion is pending")]
    DeletionPending,
    #[error("account is deleted")]
    Deleted,
    #[error("the To Read queue could not be verified")]
    QueueAuthorityUnavailable,
    #[error("reading-feed cursor could not be issued")]
    CursorUnavailable,
    #[error("recommendations are unavailable")]
    RecommendationsUnavailable,
}
