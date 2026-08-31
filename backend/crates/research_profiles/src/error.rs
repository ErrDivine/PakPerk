use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum StoreError {
    #[error("research-profile storage is unavailable")]
    Unavailable,
    #[error("research-profile storage returned invalid data")]
    InvalidData,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ResearchProfilePolicyError {
    #[error("research-profile mutation limit must be positive")]
    InvalidMutationLimit,
    #[error("research-profile mutation window must be between one second and thirty days")]
    InvalidMutationWindow,
    #[error("research-profile operation retention must be between one and ninety days")]
    InvalidOperationRetention,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ResearchProfileServiceError {
    #[error("research-profile operation ID must not be nil")]
    InvalidOperationId,
    #[error("research-profile revision must be non-negative")]
    InvalidRevision,
    #[error("research-profile update contains no fields")]
    EmptyUpdate,
    #[error("research-profile category is invalid")]
    InvalidCategory,
    #[error("research-profile category list is invalid or too large")]
    InvalidCategories,
    #[error("research-profile brief size is outside the supported range")]
    InvalidBriefSize,
    #[error("research-profile weight is outside the supported range")]
    InvalidWeight,
    #[error("research-profile topic ID is invalid")]
    InvalidTopicId,
    #[error("research-profile topic alias is invalid")]
    InvalidTopicAlias,
    #[error("research-profile topic strength is outside the supported range")]
    InvalidTopicStrength,
    #[error("research-profile author key is invalid")]
    InvalidAuthorKey,
    #[error("research-profile author display name is invalid")]
    InvalidAuthorDisplayName,
    #[error("account was not found")]
    AccountNotFound,
    #[error("account is suspended")]
    Suspended,
    #[error("account deletion is pending")]
    DeletionPending,
    #[error("account is deleted")]
    Deleted,
    #[error("research-profile revision conflict; current revision is {current_revision}")]
    RevisionConflict { current_revision: i64 },
    #[error("topic was not found")]
    TopicNotFound,
    #[error("research-profile interest limit was reached")]
    InterestLimitReached,
    #[error("operation ID was already used for a different research-profile intent")]
    IdempotencyConflict,
    #[error("research-profile mutation is rate limited; retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("research-profile cleanup batch is outside the supported range")]
    InvalidCleanupBatch,
    #[error("research-profile storage is unavailable")]
    Storage(#[from] StoreError),
}
