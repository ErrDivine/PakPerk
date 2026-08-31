use std::{sync::Arc, time::Duration};

use db::{
    PaperImportFinalization, PaperImportFinalizeOutcome, PaperImportFingerprint,
    PaperImportInputKind, PaperImportReadOutcome, PaperImportRepository, PaperImportReserveOutcome,
    PaperImportStatus, RateLimitRepository, RateLimitRequest, StoredPaperImportOperation,
};
use domain::{AccountStatus, AuthenticatedUserId, LibrarySaveSourceKind};
use library::{LibraryService, LibraryServiceError};
use sha2::{Digest as _, Sha256};
use tracing::Instrument as _;
use uuid::Uuid;

use crate::{
    PaperImportError, PaperImportLibrary, PaperImportOperationStore, PaperImportResult,
    PaperInputKind, PaperResolutionError, PaperResolutionRateLimitStore, PaperResolutionService,
    parse_paper_input,
};

const IMPORT_RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub struct PaperImportService {
    resolution: PaperResolutionService,
    operations: Arc<dyn PaperImportOperationStore>,
    library: Arc<dyn PaperImportLibrary>,
    rate_limits: Arc<dyn PaperResolutionRateLimitStore>,
    account_limit_per_minute: u32,
}

impl PaperImportService {
    #[must_use]
    pub fn new(
        resolution: PaperResolutionService,
        operations: PaperImportRepository,
        library: LibraryService,
        rate_limits: RateLimitRepository,
        account_limit_per_minute: u32,
    ) -> Self {
        Self::with_dependencies(
            resolution,
            Arc::new(operations),
            Arc::new(library),
            Arc::new(rate_limits),
            account_limit_per_minute,
        )
    }

    #[must_use]
    pub fn with_dependencies(
        resolution: PaperResolutionService,
        operations: Arc<dyn PaperImportOperationStore>,
        library: Arc<dyn PaperImportLibrary>,
        rate_limits: Arc<dyn PaperResolutionRateLimitStore>,
        account_limit_per_minute: u32,
    ) -> Self {
        Self {
            resolution,
            operations,
            library,
            rate_limits,
            account_limit_per_minute,
        }
    }

    #[allow(clippy::too_many_lines)] // Keep the crash-recovery sequence visible in one flow.
    pub async fn import(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperInputKind,
        value: &str,
    ) -> Result<PaperImportResult, PaperImportError> {
        self.import_with_source(
            user_id,
            operation_id,
            input_kind,
            value,
            default_save_source(input_kind),
        )
        .await
    }

    /// Resolves and saves one canonical arXiv identity while preserving the
    /// closed, content-free UI provenance that created the import intent.
    ///
    /// The import endpoint is deliberately Inbox-only. The provenance is part
    /// of the idempotency fingerprint so one operation ID cannot be replayed
    /// with a different user intent.
    #[allow(clippy::too_many_lines)] // Keep the crash-recovery sequence visible in one flow.
    pub async fn import_with_source(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperInputKind,
        value: &str,
        save_source_kind: LibrarySaveSourceKind,
    ) -> Result<PaperImportResult, PaperImportError> {
        if operation_id.is_nil() {
            return Err(PaperImportError::InvalidOperationId);
        }
        if !save_source_matches_input(input_kind, save_source_kind) {
            return Err(PaperImportError::InvalidSaveSource);
        }
        let normalized = parse_paper_input(input_kind, value)?;
        let query_id = normalized.as_query_id();
        let stored_kind = stored_input_kind(input_kind);
        let fingerprint = import_fingerprint(stored_kind, save_source_kind, &query_id);

        match self
            .operations
            .read(user_id, operation_id, stored_kind, fingerprint)
            .await?
        {
            PaperImportReadOutcome::Replay(operation) => {
                return self
                    .replay(
                        user_id,
                        operation_id,
                        input_kind,
                        save_source_kind,
                        operation,
                    )
                    .await;
            }
            PaperImportReadOutcome::Conflict => return Err(PaperImportError::OperationConflict),
            PaperImportReadOutcome::AccountNotFound => {
                return Err(PaperImportError::AccountNotFound);
            }
            PaperImportReadOutcome::Inactive(status) => return Err(inactive_error(status)),
            PaperImportReadOutcome::Unknown | PaperImportReadOutcome::Resume(_) => {}
        }

        self.consume_rate_limit(user_id).await?;
        match self
            .operations
            .reserve(
                user_id,
                operation_id,
                stored_kind,
                fingerprint,
                Some(&normalized.base_id),
            )
            .await?
        {
            PaperImportReserveOutcome::Replay(operation) => {
                return self
                    .replay(
                        user_id,
                        operation_id,
                        input_kind,
                        save_source_kind,
                        operation,
                    )
                    .await;
            }
            PaperImportReserveOutcome::Conflict => {
                return Err(PaperImportError::OperationConflict);
            }
            PaperImportReserveOutcome::AccountNotFound => {
                return Err(PaperImportError::AccountNotFound);
            }
            PaperImportReserveOutcome::Inactive(status) => return Err(inactive_error(status)),
            PaperImportReserveOutcome::Reserved(_) | PaperImportReserveOutcome::Resume(_) => {}
        }

        let resolved = match self
            .resolution
            .resolve_exact(&query_id)
            .instrument(tracing::info_span!("paper_import.resolve"))
            .await
        {
            Ok(resolved) => resolved,
            Err(error) => {
                let (finalization, mapped) = resolution_failure(&normalized.base_id, error);
                self.finalize_failure(
                    user_id,
                    operation_id,
                    stored_kind,
                    fingerprint,
                    finalization,
                )
                .await?;
                return Err(mapped);
            }
        };
        let save = match self
            .library
            .save_to_read(
                user_id,
                resolved.summary.paper_id,
                operation_id,
                save_source_kind,
            )
            .instrument(tracing::info_span!("paper_import.library_save"))
            .await
        {
            Ok(save) => save,
            Err(error) => {
                let finalization = library_failure(&normalized.base_id, &error);
                self.finalize_failure(
                    user_id,
                    operation_id,
                    stored_kind,
                    fingerprint,
                    finalization,
                )
                .await?;
                return Err(map_library_error(error));
            }
        };
        match self
            .operations
            .finalize(
                user_id,
                operation_id,
                stored_kind,
                fingerprint,
                PaperImportFinalization::Completed {
                    normalized_arxiv_base: normalized.base_id,
                    paper_id: resolved.summary.paper_id,
                },
            )
            .await?
        {
            PaperImportFinalizeOutcome::Finalized(_) | PaperImportFinalizeOutcome::Replay(_) => {}
            PaperImportFinalizeOutcome::Conflict => {
                return Err(PaperImportError::OperationConflict);
            }
            PaperImportFinalizeOutcome::AccountNotFound => {
                return Err(PaperImportError::AccountNotFound);
            }
            PaperImportFinalizeOutcome::Inactive(status) => return Err(inactive_error(status)),
            PaperImportFinalizeOutcome::Unknown => return Err(PaperImportError::InconsistentState),
        }

        Ok(PaperImportResult {
            input_kind,
            canonical_arxiv_id: resolved.summary.arxiv_id.clone(),
            item: save.item,
            paper: resolved.summary,
            license_uri: resolved.license_uri,
            replayed: save.replayed,
        })
    }

    async fn consume_rate_limit(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<(), PaperImportError> {
        let request = RateLimitRequest::new(
            "paper_import",
            format!("user:{user_id}"),
            self.account_limit_per_minute,
            IMPORT_RATE_LIMIT_WINDOW,
        )
        .map_err(|_| PaperImportError::InvalidRateLimitPolicy)?;
        let decision = self.rate_limits.check(&request).await?;
        if !decision.allowed {
            return Err(PaperImportError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(60).max(1),
            });
        }
        Ok(())
    }

    async fn replay(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperInputKind,
        save_source_kind: LibrarySaveSourceKind,
        operation: StoredPaperImportOperation,
    ) -> Result<PaperImportResult, PaperImportError> {
        if operation.status == PaperImportStatus::TerminalFailure {
            return match operation.error_code.as_deref() {
                Some("PAPER_RESOLUTION_NOT_FOUND") => Err(PaperImportError::NotFound),
                _ => Err(PaperImportError::InconsistentState),
            };
        }
        if operation.status != PaperImportStatus::Completed {
            return Err(PaperImportError::InconsistentState);
        }
        let base = operation
            .normalized_arxiv_base
            .ok_or(PaperImportError::InconsistentState)?;
        let resolved = self
            .resolution
            .resolve_exact(&base)
            .await
            .map_err(map_resolution_error)?;
        if Some(resolved.summary.paper_id) != operation.paper_id {
            return Err(PaperImportError::InconsistentState);
        }
        let save = self
            .library
            .save_to_read(
                user_id,
                resolved.summary.paper_id,
                operation_id,
                save_source_kind,
            )
            .await
            .map_err(map_library_error)?;
        Ok(PaperImportResult {
            input_kind,
            canonical_arxiv_id: resolved.summary.arxiv_id.clone(),
            item: save.item,
            paper: resolved.summary,
            license_uri: resolved.license_uri,
            replayed: true,
        })
    }

    async fn finalize_failure(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        kind: PaperImportInputKind,
        fingerprint: PaperImportFingerprint,
        finalization: PaperImportFinalization,
    ) -> Result<(), PaperImportError> {
        match self
            .operations
            .finalize(user_id, operation_id, kind, fingerprint, finalization)
            .await?
        {
            PaperImportFinalizeOutcome::Finalized(_) | PaperImportFinalizeOutcome::Replay(_) => {
                Ok(())
            }
            PaperImportFinalizeOutcome::Conflict => Err(PaperImportError::OperationConflict),
            PaperImportFinalizeOutcome::AccountNotFound => Err(PaperImportError::AccountNotFound),
            PaperImportFinalizeOutcome::Inactive(status) => Err(inactive_error(status)),
            PaperImportFinalizeOutcome::Unknown => Err(PaperImportError::InconsistentState),
        }
    }
}

const fn stored_input_kind(kind: PaperInputKind) -> PaperImportInputKind {
    match kind {
        PaperInputKind::ArxivUrl => PaperImportInputKind::ArxivUrl,
        PaperInputKind::ArxivId => PaperImportInputKind::ArxivId,
    }
}

fn import_fingerprint(
    kind: PaperImportInputKind,
    save_source_kind: LibrarySaveSourceKind,
    normalized_id: &str,
) -> PaperImportFingerprint {
    let digest = Sha256::digest(
        [
            b"pakperk/paper-import/v2\0".as_slice(),
            kind.as_str().as_bytes(),
            b"\0".as_slice(),
            b"inbox\0".as_slice(),
            save_source_kind.as_str().as_bytes(),
            b"\0".as_slice(),
            normalized_id.as_bytes(),
        ]
        .concat(),
    );
    PaperImportFingerprint::new(digest.into())
}

const fn default_save_source(input_kind: PaperInputKind) -> LibrarySaveSourceKind {
    match input_kind {
        PaperInputKind::ArxivUrl => LibrarySaveSourceKind::ArxivUrl,
        PaperInputKind::ArxivId => LibrarySaveSourceKind::ArxivId,
    }
}

const fn save_source_matches_input(
    input_kind: PaperInputKind,
    save_source_kind: LibrarySaveSourceKind,
) -> bool {
    match save_source_kind {
        LibrarySaveSourceKind::ArxivUrl => matches!(input_kind, PaperInputKind::ArxivUrl),
        LibrarySaveSourceKind::ArxivId => matches!(input_kind, PaperInputKind::ArxivId),
        LibrarySaveSourceKind::Discovery
        | LibrarySaveSourceKind::Lookup
        | LibrarySaveSourceKind::TitleSearch
        | LibrarySaveSourceKind::Connection
        | LibrarySaveSourceKind::Other => true,
    }
}

fn inactive_error(status: AccountStatus) -> PaperImportError {
    match status {
        AccountStatus::Active => PaperImportError::InconsistentState,
        AccountStatus::Suspended => PaperImportError::Suspended,
        AccountStatus::DeletionPending => PaperImportError::DeletionPending,
        AccountStatus::Deleted => PaperImportError::Deleted,
    }
}

fn resolution_failure(
    normalized_base: &str,
    error: PaperResolutionError,
) -> (PaperImportFinalization, PaperImportError) {
    match error {
        PaperResolutionError::NotFound => (
            PaperImportFinalization::TerminalFailure {
                normalized_arxiv_base: Some(normalized_base.to_owned()),
                error_code: "PAPER_RESOLUTION_NOT_FOUND".to_owned(),
            },
            PaperImportError::NotFound,
        ),
        other => (
            PaperImportFinalization::RetryableFailure {
                normalized_arxiv_base: Some(normalized_base.to_owned()),
                error_code: "PAPER_RESOLUTION_UNAVAILABLE".to_owned(),
            },
            map_resolution_error(other),
        ),
    }
}

fn map_resolution_error(error: PaperResolutionError) -> PaperImportError {
    match error {
        PaperResolutionError::NotFound => PaperImportError::NotFound,
        PaperResolutionError::InvalidArxivId => PaperImportError::InconsistentState,
        other @ (PaperResolutionError::Storage(_)
        | PaperResolutionError::ArxivUnavailable { .. }) => PaperImportError::Resolution(other),
    }
}

fn library_failure(normalized_base: &str, error: &LibraryServiceError) -> PaperImportFinalization {
    let error_code = match error {
        LibraryServiceError::IdempotencyConflict => "PAPER_IMPORT_OPERATION_CONFLICT",
        LibraryServiceError::RateLimited { .. } => "RATE_LIMITED",
        _ => "LIBRARY_SERVICE_UNAVAILABLE",
    };
    // A library failure is safe to re-run: the library operation ledger uses
    // this same operation ID and converges exact replays. Keeping these
    // retryable also avoids persisting a terminal code the replay path cannot
    // faithfully reconstruct after account state changes.
    PaperImportFinalization::RetryableFailure {
        normalized_arxiv_base: Some(normalized_base.to_owned()),
        error_code: error_code.to_owned(),
    }
}

fn map_library_error(error: LibraryServiceError) -> PaperImportError {
    match error {
        LibraryServiceError::AccountNotFound => PaperImportError::AccountNotFound,
        LibraryServiceError::Suspended => PaperImportError::Suspended,
        LibraryServiceError::DeletionPending => PaperImportError::DeletionPending,
        LibraryServiceError::Deleted => PaperImportError::Deleted,
        LibraryServiceError::IdempotencyConflict => PaperImportError::OperationConflict,
        LibraryServiceError::RateLimited {
            retry_after_seconds,
        } => PaperImportError::RateLimited {
            retry_after_seconds,
        },
        other => PaperImportError::Library(other),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use arxiv_client::ArxivError;
    use async_trait::async_trait;
    use chrono::{TimeZone as _, Utc};
    use db::{DbError, RateLimitDecision};
    use domain::{
        ArxivIdentifier, Author, Capabilities, LibraryItem, LibraryState, Paper, PaperMetadata,
        PaperSummary,
    };
    use library::LibraryMutationResult;
    use url::Url;

    use super::*;
    use crate::{PaperMetadataSource, PaperResolutionStore};

    #[test]
    fn import_fingerprint_is_versioned_fixed_width_and_input_kind_bound() {
        let id = "1706.03762v7";
        let by_id = import_fingerprint(
            PaperImportInputKind::ArxivId,
            LibrarySaveSourceKind::ArxivId,
            id,
        );
        let by_url = import_fingerprint(
            PaperImportInputKind::ArxivUrl,
            LibrarySaveSourceKind::ArxivUrl,
            id,
        );
        let by_title_search = import_fingerprint(
            PaperImportInputKind::ArxivId,
            LibrarySaveSourceKind::TitleSearch,
            id,
        );
        assert_ne!(by_id, by_url);
        assert_ne!(by_id, by_title_search);
        assert_eq!(by_id.as_bytes().len(), 32);
        assert!(!format!("{by_id:?}").contains(id));
    }

    #[test]
    fn direct_provenance_must_match_the_canonical_input_form() {
        assert!(save_source_matches_input(
            PaperInputKind::ArxivUrl,
            LibrarySaveSourceKind::ArxivUrl,
        ));
        assert!(save_source_matches_input(
            PaperInputKind::ArxivId,
            LibrarySaveSourceKind::TitleSearch,
        ));
        assert!(!save_source_matches_input(
            PaperInputKind::ArxivId,
            LibrarySaveSourceKind::ArxivUrl,
        ));
        assert!(!save_source_matches_input(
            PaperInputKind::ArxivUrl,
            LibrarySaveSourceKind::ArxivId,
        ));
    }

    struct ExistingPaperStore {
        paper: Paper,
        summary: PaperSummary,
    }

    #[async_trait]
    impl PaperResolutionStore for ExistingPaperStore {
        async fn get_by_arxiv_base(&self, base_id: &str) -> Result<Option<Paper>, DbError> {
            assert_eq!(base_id, self.paper.metadata.arxiv_id.base_id);
            Ok(Some(self.paper.clone()))
        }

        async fn get_summary(
            &self,
            paper_id: domain::PaperId,
        ) -> Result<Option<PaperSummary>, DbError> {
            assert_eq!(paper_id, self.summary.paper_id);
            Ok(Some(self.summary.clone()))
        }

        async fn get_cached_arxiv(
            &self,
            _cache_key: &str,
        ) -> Result<Option<Vec<PaperMetadata>>, DbError> {
            unreachable!("persisted exact paper must bypass arXiv cache")
        }

        async fn reserve_arxiv_request(&self, _minimum_interval: Duration) -> Result<(), DbError> {
            unreachable!("persisted exact paper must bypass the arXiv gate")
        }

        async fn defer_arxiv_requests(&self, _cooldown: Duration) -> Result<(), DbError> {
            unreachable!("persisted exact paper never publishes an arXiv cooldown")
        }

        async fn put_cached_arxiv(
            &self,
            _cache_key: &str,
            _query_kind: &str,
            _papers: &[PaperMetadata],
            _ttl: Duration,
        ) -> Result<(), DbError> {
            unreachable!("persisted exact paper must not write an arXiv cache entry")
        }

        async fn upsert_metadata(&self, _metadata: &PaperMetadata) -> Result<Paper, DbError> {
            unreachable!("persisted exact paper must not upsert")
        }
    }

    struct NoNetworkSource;

    #[async_trait]
    impl PaperMetadataSource for NoNetworkSource {
        async fn fetch_by_id(&self, _arxiv_id: &str) -> Result<Option<PaperMetadata>, ArxivError> {
            unreachable!("persisted exact paper must not fetch")
        }

        async fn search_by_title(
            &self,
            _normalized_title: &str,
            _limit: usize,
        ) -> Result<Vec<PaperMetadata>, ArxivError> {
            unreachable!("an exact import must never invoke title search")
        }
    }

    struct FakeOperations {
        operation: StoredPaperImportOperation,
        finalizations: Mutex<Vec<PaperImportFinalization>>,
    }

    #[async_trait]
    impl PaperImportOperationStore for FakeOperations {
        async fn reserve(
            &self,
            _user_id: AuthenticatedUserId,
            _operation_id: Uuid,
            _input_kind: PaperImportInputKind,
            _fingerprint: PaperImportFingerprint,
            normalized_arxiv_base: Option<&str>,
        ) -> Result<PaperImportReserveOutcome, DbError> {
            assert_eq!(normalized_arxiv_base, Some("1706.03762"));
            Ok(PaperImportReserveOutcome::Reserved(self.operation.clone()))
        }

        async fn read(
            &self,
            _user_id: AuthenticatedUserId,
            _operation_id: Uuid,
            _input_kind: PaperImportInputKind,
            _fingerprint: PaperImportFingerprint,
        ) -> Result<PaperImportReadOutcome, DbError> {
            Ok(PaperImportReadOutcome::Unknown)
        }

        async fn finalize(
            &self,
            _user_id: AuthenticatedUserId,
            _operation_id: Uuid,
            _input_kind: PaperImportInputKind,
            _fingerprint: PaperImportFingerprint,
            finalization: PaperImportFinalization,
        ) -> Result<PaperImportFinalizeOutcome, DbError> {
            self.finalizations.lock().unwrap().push(finalization);
            let mut completed = self.operation.clone();
            completed.status = PaperImportStatus::Completed;
            completed.normalized_arxiv_base = Some("1706.03762".to_owned());
            completed.paper_id = Some(self.operation.paper_id.unwrap());
            Ok(PaperImportFinalizeOutcome::Finalized(completed))
        }
    }

    struct FakeLibrary {
        item: LibraryItem,
        calls: Mutex<Vec<(domain::PaperId, Uuid, LibrarySaveSourceKind)>>,
    }

    #[async_trait]
    impl PaperImportLibrary for FakeLibrary {
        async fn save_to_read(
            &self,
            _user_id: AuthenticatedUserId,
            paper_id: domain::PaperId,
            operation_id: Uuid,
            save_source_kind: LibrarySaveSourceKind,
        ) -> Result<LibraryMutationResult, LibraryServiceError> {
            self.calls
                .lock()
                .unwrap()
                .push((paper_id, operation_id, save_source_kind));
            Ok(LibraryMutationResult {
                item: self.item.clone(),
                replayed: false,
            })
        }
    }

    #[derive(Default)]
    struct AllowRateLimit(Mutex<usize>);

    #[async_trait]
    impl PaperResolutionRateLimitStore for AllowRateLimit {
        async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
            *self.0.lock().unwrap() += 1;
            assert_eq!(request.bucket(), "paper_import");
            Ok(RateLimitDecision {
                allowed: true,
                limit: request.limit(),
                remaining: request.limit().saturating_sub(1),
                reset_at: Utc::now() + chrono::Duration::minutes(1),
                retry_after_seconds: None,
            })
        }
    }

    #[tokio::test]
    async fn exact_import_saves_once_finalizes_and_never_searches_or_prepares() {
        let (paper, summary, item, operation) = fixture();
        let resolution = PaperResolutionService::with_dependencies(
            Arc::new(ExistingPaperStore {
                paper,
                summary: summary.clone(),
            }),
            Arc::new(NoNetworkSource),
            Duration::from_secs(3),
            Duration::from_secs(86_400),
        );
        let operations = Arc::new(FakeOperations {
            operation,
            finalizations: Mutex::new(Vec::new()),
        });
        let library = Arc::new(FakeLibrary {
            item: item.clone(),
            calls: Mutex::new(Vec::new()),
        });
        let rate_limits = Arc::new(AllowRateLimit::default());
        let service = PaperImportService::with_dependencies(
            resolution,
            operations.clone(),
            library.clone(),
            rate_limits.clone(),
            20,
        );

        let result = service
            .import(
                Uuid::from_u128(9).into(),
                item.last_operation_id,
                PaperInputKind::ArxivUrl,
                "https://arxiv.org/abs/1706.03762v7",
            )
            .await
            .unwrap();

        assert_eq!(result.paper, summary);
        assert_eq!(result.item, item);
        assert_eq!(
            result.item.save_source_kind,
            Some(LibrarySaveSourceKind::ArxivUrl)
        );
        assert_eq!(
            library.calls.lock().unwrap().as_slice(),
            &[(
                result.paper.paper_id,
                result.item.last_operation_id,
                LibrarySaveSourceKind::ArxivUrl,
            )]
        );
        assert_eq!(*rate_limits.0.lock().unwrap(), 1);
        assert!(matches!(
            operations.finalizations.lock().unwrap().as_slice(),
            [PaperImportFinalization::Completed {
                normalized_arxiv_base,
                paper_id,
            }] if normalized_arxiv_base == "1706.03762" && *paper_id == result.paper.paper_id
        ));
        // This crate has no jobs/prepare dependency; success ends after the
        // durable library save and import finalization above.
    }

    fn fixture() -> (Paper, PaperSummary, LibraryItem, StoredPaperImportOperation) {
        let now = Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap();
        let paper_id = Uuid::from_u128(10);
        let operation_id = Uuid::from_u128(11);
        let abs_url = Url::parse("https://arxiv.org/abs/1706.03762v7").unwrap();
        let pdf_url = Url::parse("https://arxiv.org/pdf/1706.03762v7").unwrap();
        let metadata = PaperMetadata {
            arxiv_id: ArxivIdentifier {
                base_id: "1706.03762".to_owned(),
                version: 7,
            },
            title: "Attention Is All You Need".to_owned(),
            abstract_text: "Abstract".to_owned(),
            authors: vec![Author::from("Ashish Vaswani".to_owned())],
            primary_category: "cs.CL".to_owned(),
            categories: vec!["cs.CL".to_owned()],
            published_at: now,
            updated_at: now,
            abs_url: abs_url.clone(),
            pdf_url: pdf_url.clone(),
            doi: None,
            journal_reference: None,
            comment: None,
            license_uri: None,
            metadata_fetched_at: now,
        };
        let paper = Paper {
            id: paper_id,
            metadata,
        };
        let summary = PaperSummary {
            paper_id,
            arxiv_id: "1706.03762v7".to_owned(),
            title: paper.metadata.title.clone(),
            abstract_text: paper.metadata.abstract_text.clone(),
            authors: vec!["Ashish Vaswani".to_owned()],
            primary_category: "cs.CL".to_owned(),
            categories: vec!["cs.CL".to_owned()],
            published_at: now,
            updated_at: now,
            abs_url,
            pdf_url,
            capabilities: Capabilities::metadata_only(),
        };
        let item = LibraryItem {
            paper_id,
            state: LibraryState::Inbox,
            private_note: None,
            save_source_kind: Some(LibrarySaveSourceKind::ArxivUrl),
            reminder_at: None,
            saved_at: now,
            updated_at: now,
            reviewed_at: None,
            archived_at: None,
            removed_at: None,
            revision: 7,
            last_operation_id: operation_id,
        };
        let operation = StoredPaperImportOperation {
            operation_id,
            input_kind: PaperImportInputKind::ArxivUrl,
            normalized_arxiv_base: Some("1706.03762".to_owned()),
            paper_id: Some(paper_id),
            status: PaperImportStatus::Resolving,
            error_code: None,
            created_at: now,
            updated_at: now,
            completed_at: None,
        };
        (paper, summary, item, operation)
    }
}
