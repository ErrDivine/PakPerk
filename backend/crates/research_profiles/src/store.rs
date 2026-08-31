use std::time::Duration;

use async_trait::async_trait;
use domain::{AccountStatus, AuthenticatedUserId};
use uuid::Uuid;

use crate::{
    MutationFingerprint, ProfileMutation, ProfileMutationKind, ResearchProfileSnapshot, StoreError,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MutationRateDecision {
    pub allowed: bool,
    pub retry_after_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ProfileReadOutcome {
    Found(Box<ResearchProfileSnapshot>),
    AccountNotFound,
    Inactive(AccountStatus),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ProfileOperationResolution {
    Unknown,
    Replay {
        profile: Box<ResearchProfileSnapshot>,
        accepted_revision: i64,
    },
    AccountNotFound,
    Inactive(AccountStatus),
    IdempotencyConflict,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ProfileMutationOutcome {
    Applied {
        profile: Box<ResearchProfileSnapshot>,
        accepted_revision: i64,
        replayed: bool,
    },
    AccountNotFound,
    Inactive(AccountStatus),
    RevisionConflict {
        current_revision: i64,
    },
    TopicNotFound,
    InterestLimitReached,
    IdempotencyConflict,
}

#[async_trait]
pub trait ResearchProfileStore: Send + Sync {
    async fn read(&self, user_id: AuthenticatedUserId) -> Result<ProfileReadOutcome, StoreError>;

    async fn resolve_operation(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        kind: ProfileMutationKind,
        fingerprint: MutationFingerprint,
    ) -> Result<ProfileOperationResolution, StoreError>;

    async fn mutate(
        &self,
        user_id: AuthenticatedUserId,
        expected_revision: i64,
        operation_id: Uuid,
        fingerprint: MutationFingerprint,
        mutation: &ProfileMutation,
        operation_retention: Duration,
    ) -> Result<ProfileMutationOutcome, StoreError>;

    async fn cleanup_operations(&self, batch_size: u32) -> Result<u64, StoreError>;
}

#[async_trait]
pub trait ResearchProfileRateLimitStore: Send + Sync {
    async fn check_profile_mutation(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
        window: Duration,
    ) -> Result<MutationRateDecision, StoreError>;
}
