use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use db::{
    DbError, LibraryChangesOutcome, LibraryCollectionIntent, LibraryItemFilter,
    LibraryItemMutation, LibraryItemTagWrite, LibraryListItemWrite, LibraryListWrite,
    LibraryMutationIntent, LibraryMutationOutcome, LibraryOperationResolution, LibraryReadOutcome,
    LibraryRepository, LibraryTagWrite, LibraryV2MutationOutcome, LibraryV2ReadOutcome,
    RateLimitConfigError, RateLimitDecision, RateLimitRepository, RateLimitRequest,
    StoredLibraryChangesPage, StoredLibraryLists, StoredLibraryPage, StoredLibraryTags,
    StoredLibraryV2ChangesPage,
};
use domain::{
    AccountStatus, AuthenticatedUserId, LibraryChange, LibraryItem, LibraryItemTag, LibraryList,
    LibraryListItem, LibrarySaveSourceKind, LibraryState, LibraryTag, LibraryV2Change, PaperId,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryV2MutationResult<T> {
    pub value: T,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryListsPage {
    pub items: Vec<LibraryList>,
    pub sync_revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryTagsPage {
    pub items: Vec<LibraryTag>,
    pub sync_revision: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LibraryV2ChangesPage {
    pub items: Vec<LibraryV2Change>,
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
    #[error("library list was not found")]
    ListNotFound,
    #[error("library tag was not found")]
    TagNotFound,
    #[error("library membership was not found")]
    MembershipNotFound,
    #[error("library list or tag name already exists")]
    NameConflict,
    #[error("library item private note is invalid")]
    InvalidPrivateNote,
    #[error("library item reminder is invalid")]
    InvalidReminder,
    #[error("library list or tag name is invalid")]
    InvalidName,
    #[error("library description or membership note is invalid")]
    InvalidDescription,
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

    async fn resolve_item_operation(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        mutation: &LibraryItemMutation,
    ) -> Result<LibraryOperationResolution, DbError> {
        self.resolve_operation(user_id, paper_id, operation_id, intent, mutation.state)
            .await
    }

    async fn mutate_item(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        mutation: LibraryItemMutation,
    ) -> Result<LibraryMutationOutcome, DbError> {
        self.mutate(user_id, paper_id, operation_id, intent, mutation.state)
            .await
    }

    async fn list(
        &self,
        user_id: AuthenticatedUserId,
        state: LibraryState,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError>;

    /// v0.0 exposed one `to_read` collection. During the v2 compatibility
    /// window it must contain every state with active queue membership, while
    /// v2 state filters remain exact.
    async fn list_legacy_active(
        &self,
        user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        self.list(user_id, LibraryState::Inbox, cursor, limit).await
    }

    async fn list_items(
        &self,
        user_id: AuthenticatedUserId,
        filter: LibraryItemFilter,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        self.list(
            user_id,
            filter.state.unwrap_or(LibraryState::Inbox),
            cursor,
            limit,
        )
        .await
    }

    async fn mutate_list(
        &self,
        _user_id: AuthenticatedUserId,
        _operation_id: Uuid,
        _intent: LibraryCollectionIntent,
        _write: &LibraryListWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryList>, DbError> {
        Err(DbError::InvalidData(
            "library v2 list storage is unavailable".to_owned(),
        ))
    }

    async fn mutate_tag(
        &self,
        _user_id: AuthenticatedUserId,
        _operation_id: Uuid,
        _intent: LibraryCollectionIntent,
        _write: &LibraryTagWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryTag>, DbError> {
        Err(DbError::InvalidData(
            "library v2 tag storage is unavailable".to_owned(),
        ))
    }

    async fn mutate_list_item(
        &self,
        _user_id: AuthenticatedUserId,
        _operation_id: Uuid,
        _intent: LibraryCollectionIntent,
        _write: &LibraryListItemWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryListItem>, DbError> {
        Err(DbError::InvalidData(
            "library v2 list membership storage is unavailable".to_owned(),
        ))
    }

    async fn mutate_item_tag(
        &self,
        _user_id: AuthenticatedUserId,
        _operation_id: Uuid,
        _intent: LibraryCollectionIntent,
        _write: LibraryItemTagWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryItemTag>, DbError> {
        Err(DbError::InvalidData(
            "library v2 tag membership storage is unavailable".to_owned(),
        ))
    }

    async fn lists(
        &self,
        _user_id: AuthenticatedUserId,
        _limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryLists>, DbError> {
        Err(DbError::InvalidData(
            "library v2 list storage is unavailable".to_owned(),
        ))
    }

    async fn tags(
        &self,
        _user_id: AuthenticatedUserId,
        _limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryTags>, DbError> {
        Err(DbError::InvalidData(
            "library v2 tag storage is unavailable".to_owned(),
        ))
    }

    async fn v2_changes(
        &self,
        _user_id: AuthenticatedUserId,
        _after_revision: i64,
        _limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryV2ChangesPage>, DbError> {
        Err(DbError::InvalidData(
            "library v2 change storage is unavailable".to_owned(),
        ))
    }

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

    async fn resolve_item_operation(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        mutation: &LibraryItemMutation,
    ) -> Result<LibraryOperationResolution, DbError> {
        LibraryRepository::resolve_item_operation(
            self,
            user_id,
            paper_id,
            operation_id,
            intent,
            mutation,
        )
        .await
    }

    async fn mutate_item(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        mutation: LibraryItemMutation,
    ) -> Result<LibraryMutationOutcome, DbError> {
        LibraryRepository::mutate_item(self, user_id, paper_id, operation_id, intent, mutation)
            .await
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

    async fn list_legacy_active(
        &self,
        user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        LibraryRepository::list_active(self, user_id, cursor, limit).await
    }

    async fn list_items(
        &self,
        user_id: AuthenticatedUserId,
        filter: LibraryItemFilter,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
        LibraryRepository::list_items(self, user_id, filter, cursor, limit).await
    }

    async fn mutate_list(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: &LibraryListWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryList>, DbError> {
        LibraryRepository::mutate_list(self, user_id, operation_id, intent, write).await
    }

    async fn mutate_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: &LibraryTagWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryTag>, DbError> {
        LibraryRepository::mutate_tag(self, user_id, operation_id, intent, write).await
    }

    async fn mutate_list_item(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: &LibraryListItemWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryListItem>, DbError> {
        LibraryRepository::mutate_list_item(self, user_id, operation_id, intent, write).await
    }

    async fn mutate_item_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        write: LibraryItemTagWrite,
    ) -> Result<LibraryV2MutationOutcome<LibraryItemTag>, DbError> {
        LibraryRepository::mutate_item_tag(self, user_id, operation_id, intent, write).await
    }

    async fn lists(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryLists>, DbError> {
        LibraryRepository::lists(self, user_id, limit).await
    }

    async fn tags(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryTags>, DbError> {
        LibraryRepository::tags(self, user_id, limit).await
    }

    async fn v2_changes(
        &self,
        user_id: AuthenticatedUserId,
        after_revision: i64,
        limit: u32,
    ) -> Result<LibraryV2ReadOutcome<StoredLibraryV2ChangesPage>, DbError> {
        LibraryRepository::v2_changes(self, user_id, after_revision, limit).await
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
            LibraryState::Inbox,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn put_item_v2(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        state: LibraryState,
        private_note: Option<String>,
        save_source_kind: Option<LibrarySaveSourceKind>,
    ) -> Result<LibraryMutationResult, LibraryServiceError> {
        self.put_item_v2_with_reminder(
            user_id,
            paper_id,
            operation_id,
            state,
            private_note,
            save_source_kind,
            None,
            Utc::now(),
        )
        .await
    }

    /// Applies a canonical v2 item replacement with explicit reminder patch
    /// semantics: omission preserves, null clears, and a timestamp replaces.
    #[allow(clippy::too_many_arguments)]
    pub async fn put_item_v2_with_reminder(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        state: LibraryState,
        private_note: Option<String>,
        save_source_kind: Option<LibrarySaveSourceKind>,
        reminder_at: Option<Option<DateTime<Utc>>>,
        now: DateTime<Utc>,
    ) -> Result<LibraryMutationResult, LibraryServiceError> {
        validate_optional_text(private_note.as_deref(), 500, false)
            .map_err(|()| LibraryServiceError::InvalidPrivateNote)?;
        if reminder_at
            .flatten()
            .is_some_and(|selected| !state.is_active() || selected <= now)
        {
            return Err(LibraryServiceError::InvalidReminder);
        }
        let mutation = LibraryItemMutation::replace_with_reminder(
            state,
            private_note,
            save_source_kind,
            reminder_at,
        );
        self.mutate_v2_item(
            user_id,
            paper_id,
            operation_id,
            LibraryMutationIntent::Save,
            mutation,
        )
        .await
    }

    async fn mutate_v2_item(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        intent: LibraryMutationIntent,
        mutation: LibraryItemMutation,
    ) -> Result<LibraryMutationResult, LibraryServiceError> {
        if operation_id.is_nil() {
            return Err(LibraryServiceError::InvalidOperationId);
        }
        if let Some(result) = map_operation_resolution(
            self.library
                .resolve_item_operation(user_id, paper_id, operation_id, intent, &mutation)
                .await?,
        ) {
            return result;
        }
        self.check_mutation_rate(user_id).await?;
        match self
            .library
            .mutate_item(user_id, paper_id, operation_id, intent, mutation)
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

    pub async fn list_items_v2(
        &self,
        user_id: AuthenticatedUserId,
        filter: LibraryItemFilter,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<LibraryPage, LibraryServiceError> {
        validate_page(cursor, limit)?;
        map_library_page(
            self.library
                .list_items(user_id, filter, cursor, limit)
                .await?,
        )
    }

    pub async fn create_list(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        id: Uuid,
        name: String,
        description: Option<String>,
        sort_order: i32,
    ) -> Result<LibraryV2MutationResult<LibraryList>, LibraryServiceError> {
        self.write_list(
            user_id,
            operation_id,
            LibraryCollectionIntent::Create,
            id,
            name,
            description,
            sort_order,
        )
        .await
    }

    pub async fn update_list(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        id: Uuid,
        name: String,
        description: Option<String>,
        sort_order: i32,
    ) -> Result<LibraryV2MutationResult<LibraryList>, LibraryServiceError> {
        self.write_list(
            user_id,
            operation_id,
            LibraryCollectionIntent::Update,
            id,
            name,
            description,
            sort_order,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn write_list(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        id: Uuid,
        name: String,
        description: Option<String>,
        sort_order: i32,
    ) -> Result<LibraryV2MutationResult<LibraryList>, LibraryServiceError> {
        validate_operation_and_entity_ids(operation_id, id)?;
        let normalized_name = normalize_name(&name, 100)?;
        validate_optional_text(description.as_deref(), 500, true)
            .map_err(|()| LibraryServiceError::InvalidDescription)?;
        self.check_mutation_rate(user_id).await?;
        map_v2_mutation(
            self.library
                .mutate_list(
                    user_id,
                    operation_id,
                    intent,
                    &LibraryListWrite {
                        id,
                        name,
                        normalized_name,
                        description,
                        sort_order,
                    },
                )
                .await?,
        )
    }

    pub async fn delete_list(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        id: Uuid,
    ) -> Result<LibraryV2MutationResult<LibraryList>, LibraryServiceError> {
        validate_operation_and_entity_ids(operation_id, id)?;
        self.check_mutation_rate(user_id).await?;
        map_v2_mutation(
            self.library
                .mutate_list(
                    user_id,
                    operation_id,
                    LibraryCollectionIntent::Delete,
                    &LibraryListWrite {
                        id,
                        name: String::new(),
                        normalized_name: String::new(),
                        description: None,
                        sort_order: 0,
                    },
                )
                .await?,
        )
    }

    pub async fn lists(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<LibraryListsPage, LibraryServiceError> {
        match self.library.lists(user_id, MAX_LIST_LIMIT).await? {
            LibraryV2ReadOutcome::Found(StoredLibraryLists {
                items,
                sync_revision,
            }) => Ok(LibraryListsPage {
                items,
                sync_revision,
            }),
            outcome => Err(map_v2_read_error(&outcome)),
        }
    }

    pub async fn create_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        id: Uuid,
        name: String,
    ) -> Result<LibraryV2MutationResult<LibraryTag>, LibraryServiceError> {
        self.write_tag(
            user_id,
            operation_id,
            LibraryCollectionIntent::Create,
            id,
            name,
        )
        .await
    }

    pub async fn update_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        id: Uuid,
        name: String,
    ) -> Result<LibraryV2MutationResult<LibraryTag>, LibraryServiceError> {
        self.write_tag(
            user_id,
            operation_id,
            LibraryCollectionIntent::Update,
            id,
            name,
        )
        .await
    }

    async fn write_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        intent: LibraryCollectionIntent,
        id: Uuid,
        name: String,
    ) -> Result<LibraryV2MutationResult<LibraryTag>, LibraryServiceError> {
        validate_operation_and_entity_ids(operation_id, id)?;
        let normalized_name = normalize_name(&name, 60)?;
        self.check_mutation_rate(user_id).await?;
        map_v2_mutation(
            self.library
                .mutate_tag(
                    user_id,
                    operation_id,
                    intent,
                    &LibraryTagWrite {
                        id,
                        name,
                        normalized_name,
                    },
                )
                .await?,
        )
    }

    pub async fn delete_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        id: Uuid,
    ) -> Result<LibraryV2MutationResult<LibraryTag>, LibraryServiceError> {
        validate_operation_and_entity_ids(operation_id, id)?;
        self.check_mutation_rate(user_id).await?;
        map_v2_mutation(
            self.library
                .mutate_tag(
                    user_id,
                    operation_id,
                    LibraryCollectionIntent::Delete,
                    &LibraryTagWrite {
                        id,
                        name: String::new(),
                        normalized_name: String::new(),
                    },
                )
                .await?,
        )
    }

    pub async fn tags(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<LibraryTagsPage, LibraryServiceError> {
        match self.library.tags(user_id, MAX_LIST_LIMIT).await? {
            LibraryV2ReadOutcome::Found(StoredLibraryTags {
                items,
                sync_revision,
            }) => Ok(LibraryTagsPage {
                items,
                sync_revision,
            }),
            outcome => Err(map_v2_read_error(&outcome)),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn put_list_item(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        list_id: Uuid,
        paper_id: PaperId,
        position_rank: i64,
        note: Option<String>,
    ) -> Result<LibraryV2MutationResult<LibraryListItem>, LibraryServiceError> {
        validate_operation_and_entity_ids(operation_id, list_id)?;
        validate_optional_text(note.as_deref(), 500, true)
            .map_err(|()| LibraryServiceError::InvalidDescription)?;
        self.check_mutation_rate(user_id).await?;
        map_v2_mutation(
            self.library
                .mutate_list_item(
                    user_id,
                    operation_id,
                    LibraryCollectionIntent::Put,
                    &LibraryListItemWrite {
                        list_id,
                        paper_id,
                        position_rank,
                        note,
                    },
                )
                .await?,
        )
    }

    pub async fn remove_list_item(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        list_id: Uuid,
        paper_id: PaperId,
    ) -> Result<LibraryV2MutationResult<LibraryListItem>, LibraryServiceError> {
        validate_operation_and_entity_ids(operation_id, list_id)?;
        self.check_mutation_rate(user_id).await?;
        map_v2_mutation(
            self.library
                .mutate_list_item(
                    user_id,
                    operation_id,
                    LibraryCollectionIntent::Remove,
                    &LibraryListItemWrite {
                        list_id,
                        paper_id,
                        position_rank: 0,
                        note: None,
                    },
                )
                .await?,
        )
    }

    pub async fn put_item_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        paper_id: PaperId,
        tag_id: Uuid,
    ) -> Result<LibraryV2MutationResult<LibraryItemTag>, LibraryServiceError> {
        self.write_item_tag(
            user_id,
            operation_id,
            paper_id,
            tag_id,
            LibraryCollectionIntent::Put,
        )
        .await
    }

    pub async fn remove_item_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        paper_id: PaperId,
        tag_id: Uuid,
    ) -> Result<LibraryV2MutationResult<LibraryItemTag>, LibraryServiceError> {
        self.write_item_tag(
            user_id,
            operation_id,
            paper_id,
            tag_id,
            LibraryCollectionIntent::Remove,
        )
        .await
    }

    async fn write_item_tag(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        paper_id: PaperId,
        tag_id: Uuid,
        intent: LibraryCollectionIntent,
    ) -> Result<LibraryV2MutationResult<LibraryItemTag>, LibraryServiceError> {
        validate_operation_and_entity_ids(operation_id, tag_id)?;
        self.check_mutation_rate(user_id).await?;
        map_v2_mutation(
            self.library
                .mutate_item_tag(
                    user_id,
                    operation_id,
                    intent,
                    LibraryItemTagWrite { paper_id, tag_id },
                )
                .await?,
        )
    }

    pub async fn changes_v2(
        &self,
        user_id: AuthenticatedUserId,
        after_revision: i64,
        limit: u32,
    ) -> Result<LibraryV2ChangesPage, LibraryServiceError> {
        if after_revision < 0 {
            return Err(LibraryServiceError::InvalidAfterRevision);
        }
        if !(1..=MAX_CHANGES_LIMIT).contains(&limit) {
            return Err(LibraryServiceError::InvalidLimit);
        }
        match self
            .library
            .v2_changes(user_id, after_revision, limit)
            .await?
        {
            LibraryV2ReadOutcome::Found(StoredLibraryV2ChangesPage {
                items,
                next_after_revision,
                has_more,
                sync_revision,
                purged_through_revision: _,
            }) => Ok(LibraryV2ChangesPage {
                items,
                next_after_revision,
                has_more,
                sync_revision,
            }),
            LibraryV2ReadOutcome::ResetRequired {
                purged_through_revision,
                sync_revision,
            } => Err(LibraryServiceError::SyncResetRequired {
                purged_through_revision,
                sync_revision,
            }),
            outcome => Err(map_v2_read_error(&outcome)),
        }
    }

    async fn check_mutation_rate(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<(), LibraryServiceError> {
        let request = RateLimitRequest::library_mutation(
            user_id,
            self.policy.mutation_limit(),
            self.policy.mutation_window(),
        )
        .map_err(|_| LibraryServiceError::InvalidRateLimitPolicy)?;
        let decision = self.rate_limits.check(&request).await?;
        if decision.allowed {
            Ok(())
        } else {
            Err(LibraryServiceError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(1).max(1),
            })
        }
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
        let _ = state;
        match self
            .library
            .list_legacy_active(user_id, cursor, limit)
            .await?
        {
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

fn map_v2_mutation<T>(
    outcome: LibraryV2MutationOutcome<T>,
) -> Result<LibraryV2MutationResult<T>, LibraryServiceError> {
    match outcome {
        LibraryV2MutationOutcome::Applied { value, replayed } => {
            Ok(LibraryV2MutationResult { value, replayed })
        }
        LibraryV2MutationOutcome::AccountNotFound => Err(LibraryServiceError::AccountNotFound),
        LibraryV2MutationOutcome::Inactive(status) => Err(inactive_error(status)),
        LibraryV2MutationOutcome::PaperNotFound => Err(LibraryServiceError::PaperNotFound),
        LibraryV2MutationOutcome::ListNotFound => Err(LibraryServiceError::ListNotFound),
        LibraryV2MutationOutcome::TagNotFound => Err(LibraryServiceError::TagNotFound),
        LibraryV2MutationOutcome::MembershipNotFound => {
            Err(LibraryServiceError::MembershipNotFound)
        }
        LibraryV2MutationOutcome::NameConflict => Err(LibraryServiceError::NameConflict),
        LibraryV2MutationOutcome::IdempotencyConflict => {
            Err(LibraryServiceError::IdempotencyConflict)
        }
    }
}

fn map_v2_read_error<T>(outcome: &LibraryV2ReadOutcome<T>) -> LibraryServiceError {
    match outcome {
        LibraryV2ReadOutcome::AccountNotFound => LibraryServiceError::AccountNotFound,
        LibraryV2ReadOutcome::Inactive(status) => inactive_error(*status),
        LibraryV2ReadOutcome::InvalidAfterRevision => LibraryServiceError::InvalidAfterRevision,
        LibraryV2ReadOutcome::ResetRequired {
            purged_through_revision,
            sync_revision,
        } => LibraryServiceError::SyncResetRequired {
            purged_through_revision: *purged_through_revision,
            sync_revision: *sync_revision,
        },
        LibraryV2ReadOutcome::Found(_) => LibraryServiceError::Storage(DbError::InvalidData(
            "library read outcome was routed through an invalid branch".to_owned(),
        )),
    }
}

fn validate_page(cursor: Option<&str>, limit: u32) -> Result<(), LibraryServiceError> {
    if !(1..=MAX_LIST_LIMIT).contains(&limit) {
        return Err(LibraryServiceError::InvalidLimit);
    }
    if cursor.is_some_and(|cursor| cursor.len() > MAX_CURSOR_BYTES) {
        return Err(LibraryServiceError::InvalidCursor);
    }
    Ok(())
}

fn map_library_page(
    outcome: LibraryReadOutcome<StoredLibraryPage>,
) -> Result<LibraryPage, LibraryServiceError> {
    match outcome {
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

fn validate_operation_and_entity_ids(
    operation_id: Uuid,
    entity_id: Uuid,
) -> Result<(), LibraryServiceError> {
    if operation_id.is_nil() || entity_id.is_nil() {
        return Err(LibraryServiceError::InvalidOperationId);
    }
    Ok(())
}

fn normalize_name(value: &str, max_chars: usize) -> Result<String, LibraryServiceError> {
    if value.contains('\0') || value.trim() != value {
        return Err(LibraryServiceError::InvalidName);
    }
    let normalized_spacing = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized_spacing != value
        || !(1..=max_chars).contains(&value.chars().count())
        || value.contains(['\n', '\r'])
    {
        return Err(LibraryServiceError::InvalidName);
    }
    let normalized = value.to_lowercase();
    if normalized.chars().count() > max_chars {
        return Err(LibraryServiceError::InvalidName);
    }
    Ok(normalized)
}

fn validate_optional_text(
    value: Option<&str>,
    max_chars: usize,
    allow_newlines: bool,
) -> Result<(), ()> {
    let Some(value) = value else {
        return Ok(());
    };
    if value.trim() != value
        || value.contains('\0')
        || !(1..=max_chars).contains(&value.chars().count())
        || (!allow_newlines && value.contains(['\n', '\r']))
    {
        return Err(());
    }
    Ok(())
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
            state: LibraryState::Inbox,
            private_note: None,
            save_source_kind: None,
            reminder_at: None,
            saved_at: now,
            updated_at: now,
            reviewed_at: None,
            archived_at: None,
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
                LibraryState::Inbox,
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
                LibraryState::Inbox,
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
                    LibraryState::Inbox,
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
                .list(user_id, LibraryState::Inbox, Some("not a cursor"), 20)
                .await,
            Err(LibraryServiceError::InvalidCursor)
        ));
        let oversized = "a".repeat(MAX_CURSOR_BYTES + 1);
        assert!(matches!(
            service
                .list(user_id, LibraryState::Inbox, Some(&oversized), 20,)
                .await,
            Err(LibraryServiceError::InvalidCursor)
        ));
        assert!(matches!(
            service.list(user_id, LibraryState::Inbox, None, 0).await,
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

    #[tokio::test]
    async fn v2_private_values_and_names_are_bounded_before_storage_or_rate_limits() {
        let operation_id = Uuid::now_v7();
        let (service, mutations, checks, _) = fixture_service(
            LibraryMutationOutcome::PaperNotFound,
            true,
            AccountStatus::Active,
        );
        let user_id = AuthenticatedUserId::new(Uuid::now_v7());
        assert!(matches!(
            service
                .put_item_v2(
                    user_id,
                    Uuid::now_v7(),
                    operation_id,
                    LibraryState::Inbox,
                    Some("line one\nline two".to_owned()),
                    Some(LibrarySaveSourceKind::Other),
                )
                .await,
            Err(LibraryServiceError::InvalidPrivateNote)
        ));
        assert!(matches!(
            service
                .create_list(
                    user_id,
                    operation_id,
                    Uuid::now_v7(),
                    "  Later".to_owned(),
                    None,
                    0,
                )
                .await,
            Err(LibraryServiceError::InvalidName)
        ));
        assert_eq!(*checks.lock().unwrap(), 0);
        assert!(mutations.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn reminders_must_be_future_and_belong_to_active_items() {
        let operation_id = Uuid::now_v7();
        let (service, mutations, checks, _) = fixture_service(
            LibraryMutationOutcome::PaperNotFound,
            true,
            AccountStatus::Active,
        );
        let user_id = AuthenticatedUserId::new(Uuid::now_v7());
        let now = Utc.with_ymd_and_hms(2026, 8, 28, 12, 0, 0).unwrap();
        for (state, selected) in [
            (LibraryState::Inbox, now),
            (LibraryState::Reviewed, now + chrono::TimeDelta::hours(1)),
        ] {
            assert!(matches!(
                service
                    .put_item_v2_with_reminder(
                        user_id,
                        Uuid::now_v7(),
                        operation_id,
                        state,
                        None,
                        None,
                        Some(Some(selected)),
                        now,
                    )
                    .await,
                Err(LibraryServiceError::InvalidReminder)
            ));
        }
        assert_eq!(*checks.lock().unwrap(), 0);
        assert!(mutations.lock().unwrap().is_empty());
    }

    #[test]
    fn v2_name_normalization_is_closed_and_stable() {
        assert_eq!(normalize_name("Core Methods", 100).unwrap(), "core methods");
        for invalid in ["", " Core", "Core ", "Core  Methods", "Core\nMethods"] {
            assert!(matches!(
                normalize_name(invalid, 100),
                Err(LibraryServiceError::InvalidName)
            ));
        }
    }
}
