use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use db::{
    DbError, LibraryChangesOutcome, LibraryMutationIntent, LibraryMutationOutcome,
    LibraryOperationResolution, LibraryReadOutcome, LibraryRepository, RateLimitConfigError,
    RateLimitDecision, RateLimitRepository, RateLimitRequest, StoredLibraryChangesPage,
    StoredLibraryPage,
};
use domain::{
    AccountStatus, AuthenticatedUserId, LibraryChange, LibraryItem, LibraryState, PaperId,
    SavedLibraryPaper,
};
use thiserror::Error;
use uuid::Uuid;

pub const TOMBSTONE_RETENTION: Duration = Duration::from_secs(90 * 24 * 60 * 60);
const MAX_LIST_LIMIT: u32 = 100;
const MAX_CHANGES_LIMIT: u32 = 500;
const MAX_CLEANUP_BATCH: u32 = 10_000;
const MAX_CURSOR_BYTES: usize = 512;

#[derive(Debug, Clone)]
pub struct LibraryPolicy {
    mutation_limit: u32,
    mutation_window: Duration,
}

impl LibraryPolicy {
    pub fn new(mutation_limit: u32, mutation_window: Duration) -> Result<Self, LibraryPolicyError> {
        RateLimitRequest::library_mutation(
            AuthenticatedUserId::new(Uuid::nil()),
            mutation_limit,
            mutation_window,
        )?;
        Ok(Self {
            mutation_limit,
            mutation_window,
        })
    }

    #[must_use]
    pub const fn mutation_limit(&self) -> u32 {
        self.mutation_limit
    }

    #[must_use]
    pub const fn mutation_window(&self) -> Duration {
        self.mutation_window
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum LibraryPolicyError {
    #[error(transparent)]
    InvalidRateLimit(#[from] RateLimitConfigError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryMutationResult {
    pub item: LibraryItem,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LibraryPage {
    pub items: Vec<SavedLibraryPaper>,
    pub next_cursor: Option<String>,
    pub sync_revision: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LibraryChangesPage {
    pub items: Vec<LibraryChange>,
    pub next_after_revision: i64,
    pub has_more: bool,
    pub sync_revision: i64,
}

#[derive(Debug, Error)]
pub enum LibraryServiceError {
    #[error("library operation ID must not be nil")]
    InvalidOperationId,
    #[error("library page limit is outside the supported range")]
    InvalidLimit,
    #[error("library change revision must be non-negative")]
    InvalidAfterRevision,
    #[error("library cursor is invalid")]
    InvalidCursor,
    #[error("account was not found")]
    AccountNotFound,
    #[error("account is suspended")]
    Suspended,
    #[error("account deletion is pending")]
    DeletionPending,
    #[error("account is deleted")]
    Deleted,
    #[error("paper was not found")]
    PaperNotFound,
    #[error("operation ID was already used for a different library intent")]
    IdempotencyConflict,
    #[error(
        "library synchronization requires a full reset; tombstones were purged through revision {purged_through_revision}"
    )]
    SyncResetRequired {
        purged_through_revision: i64,
        sync_revision: i64,
    },
    #[error("library mutation is rate limited; retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("library cleanup batch is outside the supported range")]
    InvalidCleanupBatch,
    #[error("library storage is unavailable")]
    Storage(#[from] DbError),
    #[error("library service rate-limit policy is invalid")]
    InvalidRateLimitPolicy,
}

#[async_trait]
pub trait LibraryStore: Send + Sync {
    async fn resolve_operation(
        &self,
        _user_id: AuthenticatedUserId,
        _paper_id: PaperId,
        _operation_id: Uuid,
        _intent: LibraryMutationIntent,
        _state: LibraryState,
    ) -> Result<LibraryOperationResolution, DbError> {
        Ok(LibraryOperationResolution::Unknown)
    }

    async fn mutate(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        state: LibraryState,
    ) -> Result<LibraryMutationOutcome, DbError>;

    async fn list(
        &self,
        user_id: AuthenticatedUserId,
        state: LibraryState,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError>;

    async fn changes(
        &self,
        user_id: AuthenticatedUserId,
        after_revision: i64,
        limit: u32,
    ) -> Result<LibraryChangesOutcome, DbError>;

    async fn cleanup_tombstones(
        &self,
        retention: Duration,
        batch_size: u32,
    ) -> Result<u64, DbError>;
}

#[async_trait]
impl LibraryStore for LibraryRepository {
    async fn resolve_operation(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        state: LibraryState,
    ) -> Result<LibraryOperationResolution, DbError> {
        LibraryRepository::resolve_operation(self, user_id, paper_id, operation_id, intent, state)
            .await
    }

    async fn mutate(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        state: LibraryState,
    ) -> Result<LibraryMutationOutcome, DbError> {
        LibraryRepository::mutate(self, user_id, paper_id, operation_id, intent, state).await
    }

    async fn list(
        &self,
        user_id: AuthenticatedUserId,
        state: LibraryState,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        LibraryRepository::list(self, user_id, state, cursor, limit).await
    }

    async fn changes(
        &self,
        user_id: AuthenticatedUserId,
        after_revision: i64,
        limit: u32,
    ) -> Result<LibraryChangesOutcome, DbError> {
        LibraryRepository::changes(self, user_id, after_revision, limit).await
    }

    async fn cleanup_tombstones(
        &self,
        retention: Duration,
        batch_size: u32,
    ) -> Result<u64, DbError> {
        LibraryRepository::cleanup_tombstones(self, retention, batch_size).await
    }
}

#[async_trait]
pub trait RateLimitStore: Send + Sync {
    async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError>;
}

#[async_trait]
impl RateLimitStore for RateLimitRepository {
    async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
        RateLimitRepository::check(self, request).await
    }
}

#[derive(Clone)]
pub struct LibraryService {
    library: Arc<dyn LibraryStore>,
    rate_limits: Arc<dyn RateLimitStore>,
    policy: LibraryPolicy,
}

impl LibraryService {
    #[must_use]
    pub fn new(
        library: LibraryRepository,
        rate_limits: RateLimitRepository,
        policy: LibraryPolicy,
    ) -> Self {
        Self::with_stores(Arc::new(library), Arc::new(rate_limits), policy)
    }

    #[must_use]
    pub const fn with_stores(
        library: Arc<dyn LibraryStore>,
        rate_limits: Arc<dyn RateLimitStore>,
        policy: LibraryPolicy,
    ) -> Self {
        Self {
            library,
            rate_limits,
            policy,
        }
    }

    #[must_use]
    pub const fn policy(&self) -> &LibraryPolicy {
        &self.policy
    }

    pub async fn save(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        state: LibraryState,
    ) -> Result<LibraryMutationResult, LibraryServiceError> {
        self.mutate(
            user_id,
            paper_id,
            operation_id,
            LibraryMutationIntent::Save,
            state,
        )
        .await
    }

    pub async fn remove(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
    ) -> Result<LibraryMutationResult, LibraryServiceError> {
        self.mutate(
            user_id,
            paper_id,
            operation_id,
            LibraryMutationIntent::Remove,
            LibraryState::ToRead,
        )
        .await
    }

    async fn mutate(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        state: LibraryState,
    ) -> Result<LibraryMutationResult, LibraryServiceError> {
        if operation_id.is_nil() {
            return Err(LibraryServiceError::InvalidOperationId);
        }
        if let Some(result) = map_operation_resolution(
            self.library
                .resolve_operation(user_id, paper_id, operation_id, intent, state)
                .await?,
        ) {
            return result;
        }
        let request = RateLimitRequest::library_mutation(
            user_id,
            self.policy.mutation_limit(),
            self.policy.mutation_window(),
        )
        .map_err(|_| LibraryServiceError::InvalidRateLimitPolicy)?;
        let decision = self.rate_limits.check(&request).await?;
        if !decision.allowed {
            // A concurrent request may have accepted this operation between
            // preflight and the shared rate check. Resolve once more so that a
            // now-durable replay/conflict keeps its promised semantic result.
            if let Some(result) = map_operation_resolution(
                self.library
                    .resolve_operation(user_id, paper_id, operation_id, intent, state)
                    .await?,
            ) {
                return result;
            }
            return Err(LibraryServiceError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(1).max(1),
            });
        }

        match self
            .library
            .mutate(user_id, paper_id, operation_id, intent, state)
            .await?
        {
            LibraryMutationOutcome::Applied { item, replayed } => {
                Ok(LibraryMutationResult { item, replayed })
            }
            LibraryMutationOutcome::AccountNotFound => Err(LibraryServiceError::AccountNotFound),
            LibraryMutationOutcome::Inactive(status) => Err(inactive_error(status)),
            LibraryMutationOutcome::PaperNotFound => Err(LibraryServiceError::PaperNotFound),
            LibraryMutationOutcome::IdempotencyConflict => {
                Err(LibraryServiceError::IdempotencyConflict)
            }
        }
    }

    pub async fn list(
        &self,
        user_id: AuthenticatedUserId,
        state: LibraryState,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryPage, LibraryServiceError> {
        if !(1..=MAX_LIST_LIMIT).contains(&limit) {
            return Err(LibraryServiceError::InvalidLimit);
        }
        if cursor.is_some_and(|cursor| cursor.len() > MAX_CURSOR_BYTES) {
            return Err(LibraryServiceError::InvalidCursor);
        }
        match self.library.list(user_id, state, cursor, limit).await? {
            LibraryReadOutcome::Found(StoredLibraryPage {
                items,
                next_cursor,
                sync_revision,
            }) => Ok(LibraryPage {
                items,
                next_cursor,
                sync_revision,
            }),
            LibraryReadOutcome::AccountNotFound => Err(LibraryServiceError::AccountNotFound),
            LibraryReadOutcome::Inactive(status) => Err(inactive_error(status)),
            LibraryReadOutcome::InvalidCursor => Err(LibraryServiceError::InvalidCursor),
        }
    }

    pub async fn changes(
        &self,
        user_id: AuthenticatedUserId,
        after_revision: i64,
        limit: u32,
    ) -> Result<LibraryChangesPage, LibraryServiceError> {
        if after_revision < 0 {
            return Err(LibraryServiceError::InvalidAfterRevision);
        }
        if !(1..=MAX_CHANGES_LIMIT).contains(&limit) {
            return Err(LibraryServiceError::InvalidLimit);
        }
        match self.library.changes(user_id, after_revision, limit).await? {
            LibraryChangesOutcome::Found(StoredLibraryChangesPage {
                items,
                next_after_revision,
                has_more,
                sync_revision,
                purged_through_revision: _,
            }) => Ok(LibraryChangesPage {
                items,
                next_after_revision,
                has_more,
                sync_revision,
            }),
            LibraryChangesOutcome::AccountNotFound => Err(LibraryServiceError::AccountNotFound),
            LibraryChangesOutcome::Inactive(status) => Err(inactive_error(status)),
            LibraryChangesOutcome::InvalidAfterRevision => {
                Err(LibraryServiceError::InvalidAfterRevision)
            }
            LibraryChangesOutcome::ResetRequired {
                purged_through_revision,
                sync_revision,
            } => Err(LibraryServiceError::SyncResetRequired {
                purged_through_revision,
                sync_revision,
            }),
        }
    }

    pub async fn cleanup_tombstones(&self, batch_size: u32) -> Result<u64, LibraryServiceError> {
        if !(1..=MAX_CLEANUP_BATCH).contains(&batch_size) {
            return Err(LibraryServiceError::InvalidCleanupBatch);
        }
        self.library
            .cleanup_tombstones(TOMBSTONE_RETENTION, batch_size)
            .await
            .map_err(LibraryServiceError::from)
    }
}

fn map_operation_resolution(
    resolution: LibraryOperationResolution,
) -> Option<Result<LibraryMutationResult, LibraryServiceError>> {
    match resolution {
        LibraryOperationResolution::Unknown => None,
        LibraryOperationResolution::Replay(item) => Some(Ok(LibraryMutationResult {
            item,
            replayed: true,
        })),
        LibraryOperationResolution::AccountNotFound => {
            Some(Err(LibraryServiceError::AccountNotFound))
        }
        LibraryOperationResolution::Inactive(status) => Some(Err(inactive_error(status))),
        LibraryOperationResolution::IdempotencyConflict => {
            Some(Err(LibraryServiceError::IdempotencyConflict))
        }
    }
}

fn inactive_error(status: AccountStatus) -> LibraryServiceError {
    match status {
        AccountStatus::Active => LibraryServiceError::Storage(DbError::InvalidData(
            "active account was returned as inactive".to_owned(),
        )),
        AccountStatus::Suspended => LibraryServiceError::Suspended,
        AccountStatus::DeletionPending => LibraryServiceError::DeletionPending,
        AccountStatus::Deleted => LibraryServiceError::Deleted,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use chrono::{TimeZone as _, Utc};

    use super::*;

    #[derive(Clone)]
    struct FakeLibraryStore {
        mutation: LibraryMutationOutcome,
        read_status: AccountStatus,
        mutations: Arc<Mutex<Vec<(Uuid, LibraryMutationIntent)>>>,
        cleanup: Arc<Mutex<Vec<(Duration, u32)>>>,
    }

    #[async_trait]
    impl LibraryStore for FakeLibraryStore {
        async fn resolve_operation(
            &self,
            _user_id: AuthenticatedUserId,
            _paper_id: PaperId,
            _operation_id: Uuid,
            _intent: LibraryMutationIntent,
            _state: LibraryState,
        ) -> Result<LibraryOperationResolution, DbError> {
            Ok(match &self.mutation {
                LibraryMutationOutcome::Applied {
                    item,
                    replayed: true,
                } => LibraryOperationResolution::Replay(item.clone()),
                LibraryMutationOutcome::IdempotencyConflict => {
                    LibraryOperationResolution::IdempotencyConflict
                }
                LibraryMutationOutcome::AccountNotFound => {
                    LibraryOperationResolution::AccountNotFound
                }
                LibraryMutationOutcome::Inactive(status) => {
                    LibraryOperationResolution::Inactive(*status)
                }
                LibraryMutationOutcome::Applied {
                    replayed: false, ..
                }
                | LibraryMutationOutcome::PaperNotFound => LibraryOperationResolution::Unknown,
            })
        }

        async fn mutate(
            &self,
            _user_id: AuthenticatedUserId,
            _paper_id: PaperId,
            operation_id: Uuid,
            intent: LibraryMutationIntent,
            _state: LibraryState,
        ) -> Result<LibraryMutationOutcome, DbError> {
            self.mutations.lock().unwrap().push((operation_id, intent));
            Ok(self.mutation.clone())
        }

        async fn list(
            &self,
            _user_id: AuthenticatedUserId,
            _state: LibraryState,
            cursor: Option<&str>,
            _limit: u32,
        ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
            if cursor.is_some() {
                return Ok(LibraryReadOutcome::InvalidCursor);
            }
            if self.read_status.is_active() {
                Ok(LibraryReadOutcome::Found(StoredLibraryPage {
                    items: Vec::new(),
                    next_cursor: None,
                    sync_revision: 7,
                }))
            } else {
                Ok(LibraryReadOutcome::Inactive(self.read_status))
            }
        }

        async fn changes(
            &self,
            _user_id: AuthenticatedUserId,
            _after_revision: i64,
            _limit: u32,
        ) -> Result<LibraryChangesOutcome, DbError> {
            Ok(LibraryChangesOutcome::ResetRequired {
                purged_through_revision: 5,
                sync_revision: 9,
            })
        }

        async fn cleanup_tombstones(
            &self,
            retention: Duration,
            batch_size: u32,
        ) -> Result<u64, DbError> {
            self.cleanup.lock().unwrap().push((retention, batch_size));
            Ok(u64::from(batch_size))
        }
    }

    struct FakeRateLimitStore {
        allowed: bool,
        checks: Arc<Mutex<u32>>,
    }

    type ServiceFixture = (
        LibraryService,
        Arc<Mutex<Vec<(Uuid, LibraryMutationIntent)>>>,
        Arc<Mutex<u32>>,
        Arc<Mutex<Vec<(Duration, u32)>>>,
    );

    #[async_trait]
    impl RateLimitStore for FakeRateLimitStore {
        async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
            *self.checks.lock().unwrap() += 1;
            Ok(RateLimitDecision {
                allowed: self.allowed,
                limit: request.limit(),
                remaining: u32::from(self.allowed),
                reset_at: Utc.with_ymd_and_hms(2026, 8, 1, 0, 0, 0).unwrap(),
                retry_after_seconds: (!self.allowed).then_some(13),
            })
        }
    }

    fn item(operation_id: Uuid) -> LibraryItem {
        let now = Utc.with_ymd_and_hms(2026, 7, 31, 12, 0, 0).unwrap();
        LibraryItem {
            paper_id: Uuid::now_v7(),
            state: LibraryState::ToRead,
            saved_at: now,
            updated_at: now,
            removed_at: None,
            revision: 3,
            last_operation_id: operation_id,
        }
    }

    fn fixture_service(
        mutation: LibraryMutationOutcome,
        allowed: bool,
        status: AccountStatus,
    ) -> ServiceFixture {
        let mutations = Arc::new(Mutex::new(Vec::new()));
        let checks = Arc::new(Mutex::new(0));
        let cleanup = Arc::new(Mutex::new(Vec::new()));
        let store = FakeLibraryStore {
            mutation,
            read_status: status,
            mutations: Arc::clone(&mutations),
            cleanup: Arc::clone(&cleanup),
        };
        let limiter = FakeRateLimitStore {
            allowed,
            checks: Arc::clone(&checks),
        };
        let policy = LibraryPolicy::new(120, Duration::from_secs(3_600)).unwrap();
        (
            LibraryService::with_stores(Arc::new(store), Arc::new(limiter), policy),
            mutations,
            checks,
            cleanup,
        )
    }

    #[tokio::test]
    async fn durable_replay_bypasses_a_denying_rate_limiter() {
        let operation_id = Uuid::now_v7();
        let expected = item(operation_id);
        let paper_id = expected.paper_id;
        let (service, mutations, checks, _) = fixture_service(
            LibraryMutationOutcome::Applied {
                item: expected.clone(),
                replayed: true,
            },
            false,
            AccountStatus::Active,
        );
        let result = service
            .save(
                AuthenticatedUserId::new(Uuid::now_v7()),
                paper_id,
                operation_id,
                LibraryState::ToRead,
            )
            .await
            .unwrap();
        assert_eq!(result.item, expected);
        assert!(result.replayed);
        assert_eq!(*checks.lock().unwrap(), 0);
        assert!(mutations.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn genuinely_new_save_consumes_a_permit_and_mutates() {
        let operation_id = Uuid::now_v7();
        let expected = item(operation_id);
        let paper_id = expected.paper_id;
        let (service, mutations, checks, _) = fixture_service(
            LibraryMutationOutcome::Applied {
                item: expected.clone(),
                replayed: false,
            },
            true,
            AccountStatus::Active,
        );
        let result = service
            .save(
                AuthenticatedUserId::new(Uuid::now_v7()),
                paper_id,
                operation_id,
                LibraryState::ToRead,
            )
            .await
            .unwrap();
        assert_eq!(result.item, expected);
        assert!(!result.replayed);
        assert_eq!(*checks.lock().unwrap(), 1);
        assert_eq!(
            mutations.lock().unwrap().as_slice(),
            &[(operation_id, LibraryMutationIntent::Save)]
        );
    }

    #[tokio::test]
    async fn durable_idempotency_conflict_bypasses_a_denying_rate_limiter() {
        let operation_id = Uuid::now_v7();
        let (service, mutations, checks, _) = fixture_service(
            LibraryMutationOutcome::IdempotencyConflict,
            false,
            AccountStatus::Active,
        );
        assert!(matches!(
            service
                .remove(
                    AuthenticatedUserId::new(Uuid::now_v7()),
                    Uuid::now_v7(),
                    operation_id,
                )
                .await,
            Err(LibraryServiceError::IdempotencyConflict)
        ));
        assert_eq!(*checks.lock().unwrap(), 0);
        assert!(mutations.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn invalid_id_and_denial_fail_before_storage() {
        let operation_id = Uuid::now_v7();
        let outcome = LibraryMutationOutcome::Applied {
            item: item(operation_id),
            replayed: false,
        };
        let (service, mutations, checks, _) =
            fixture_service(outcome.clone(), true, AccountStatus::Active);
        assert!(matches!(
            service
                .remove(
                    AuthenticatedUserId::new(Uuid::now_v7()),
                    Uuid::now_v7(),
                    Uuid::nil(),
                )
                .await,
            Err(LibraryServiceError::InvalidOperationId)
        ));
        assert_eq!(*checks.lock().unwrap(), 0);
        assert!(mutations.lock().unwrap().is_empty());

        let (service, mutations, _, _) = fixture_service(outcome, false, AccountStatus::Active);
        assert!(matches!(
            service
                .remove(
                    AuthenticatedUserId::new(Uuid::now_v7()),
                    Uuid::now_v7(),
                    operation_id,
                )
                .await,
            Err(LibraryServiceError::RateLimited {
                retry_after_seconds: 13
            })
        ));
        assert!(mutations.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn inactive_accounts_and_sync_reset_are_specific() {
        let operation_id = Uuid::now_v7();
        let (service, _, _, _) = fixture_service(
            LibraryMutationOutcome::Inactive(AccountStatus::Suspended),
            true,
            AccountStatus::Suspended,
        );
        assert!(matches!(
            service
                .remove(
                    AuthenticatedUserId::new(Uuid::now_v7()),
                    Uuid::now_v7(),
                    operation_id,
                )
                .await,
            Err(LibraryServiceError::Suspended)
        ));
        assert!(matches!(
            service
                .list(
                    AuthenticatedUserId::new(Uuid::now_v7()),
                    LibraryState::ToRead,
                    None,
                    20,
                )
                .await,
            Err(LibraryServiceError::Suspended)
        ));

        assert!(matches!(
            service
                .changes(AuthenticatedUserId::new(Uuid::now_v7()), 5, 100)
                .await,
            Err(LibraryServiceError::SyncResetRequired {
                purged_through_revision: 5,
                sync_revision: 9
            })
        ));
    }

    #[tokio::test]
    async fn cursors_limits_and_cleanup_are_bounded() {
        let operation_id = Uuid::now_v7();
        let (service, _, _, cleanup) = fixture_service(
            LibraryMutationOutcome::Applied {
                item: item(operation_id),
                replayed: false,
            },
            true,
            AccountStatus::Active,
        );
        let user_id = AuthenticatedUserId::new(Uuid::now_v7());
        assert!(matches!(
            service
                .list(user_id, LibraryState::ToRead, Some("not a cursor"), 20)
                .await,
            Err(LibraryServiceError::InvalidCursor)
        ));
        let oversized = "a".repeat(MAX_CURSOR_BYTES + 1);
        assert!(matches!(
            service
                .list(user_id, LibraryState::ToRead, Some(&oversized), 20,)
                .await,
            Err(LibraryServiceError::InvalidCursor)
        ));
        assert!(matches!(
            service.list(user_id, LibraryState::ToRead, None, 0).await,
            Err(LibraryServiceError::InvalidLimit)
        ));
        assert!(matches!(
            service.changes(user_id, -1, 20).await,
            Err(LibraryServiceError::InvalidAfterRevision)
        ));
        assert!(matches!(
            service.cleanup_tombstones(0).await,
            Err(LibraryServiceError::InvalidCleanupBatch)
        ));
        assert_eq!(service.cleanup_tombstones(500).await.unwrap(), 500);
        assert_eq!(
            cleanup.lock().unwrap().as_slice(),
            &[(TOMBSTONE_RETENTION, 500)]
        );
    }

    #[test]
    fn mutation_policy_rejects_zero_or_unbounded_windows() {
        assert!(LibraryPolicy::new(0, Duration::from_secs(60)).is_err());
        assert!(LibraryPolicy::new(1, Duration::ZERO).is_err());
    }
}
