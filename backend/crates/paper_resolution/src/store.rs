use std::time::Duration;

use arxiv_client::{ArxivClient, ArxivError};
use async_trait::async_trait;
use db::{
    DbError, PaperImportFinalization, PaperImportFinalizeOutcome, PaperImportFingerprint,
    PaperImportInputKind, PaperImportReadOutcome, PaperImportRepository, PaperImportReserveOutcome,
    PaperRepository, RateLimitDecision, RateLimitRepository, RateLimitRequest,
};
use domain::{
    AuthenticatedUserId, LibrarySaveSourceKind, LibraryState, Paper, PaperId, PaperMetadata,
    PaperSummary,
};
use library::{LibraryMutationResult, LibraryService, LibraryServiceError};
use uuid::Uuid;

#[async_trait]
pub trait PaperResolutionStore: Send + Sync {
    async fn get_by_arxiv_base(&self, base_id: &str) -> Result<Option<Paper>, DbError>;
    async fn get_summary(&self, paper_id: domain::PaperId)
    -> Result<Option<PaperSummary>, DbError>;
    async fn get_cached_arxiv(
        &self,
        cache_key: &str,
    ) -> Result<Option<Vec<PaperMetadata>>, DbError>;
    async fn reserve_arxiv_request(&self, minimum_interval: Duration) -> Result<(), DbError>;
    async fn defer_arxiv_requests(&self, cooldown: Duration) -> Result<(), DbError>;
    async fn put_cached_arxiv(
        &self,
        cache_key: &str,
        query_kind: &str,
        papers: &[PaperMetadata],
        ttl: Duration,
    ) -> Result<(), DbError>;
    async fn upsert_metadata(&self, metadata: &PaperMetadata) -> Result<Paper, DbError>;
}

#[async_trait]
impl PaperResolutionStore for PaperRepository {
    async fn get_by_arxiv_base(&self, base_id: &str) -> Result<Option<Paper>, DbError> {
        PaperRepository::get_by_arxiv_base(self, base_id).await
    }

    async fn get_summary(
        &self,
        paper_id: domain::PaperId,
    ) -> Result<Option<PaperSummary>, DbError> {
        PaperRepository::get_summary(self, paper_id).await
    }

    async fn get_cached_arxiv(
        &self,
        cache_key: &str,
    ) -> Result<Option<Vec<PaperMetadata>>, DbError> {
        PaperRepository::get_cached_arxiv(self, cache_key).await
    }

    async fn reserve_arxiv_request(&self, minimum_interval: Duration) -> Result<(), DbError> {
        PaperRepository::reserve_arxiv_request(self, minimum_interval).await
    }

    async fn defer_arxiv_requests(&self, cooldown: Duration) -> Result<(), DbError> {
        PaperRepository::defer_arxiv_requests(self, cooldown).await
    }

    async fn put_cached_arxiv(
        &self,
        cache_key: &str,
        query_kind: &str,
        papers: &[PaperMetadata],
        ttl: Duration,
    ) -> Result<(), DbError> {
        PaperRepository::put_cached_arxiv(self, cache_key, query_kind, papers, ttl).await
    }

    async fn upsert_metadata(&self, metadata: &PaperMetadata) -> Result<Paper, DbError> {
        PaperRepository::upsert_metadata(self, metadata).await
    }
}

#[async_trait]
pub trait PaperMetadataSource: Send + Sync {
    async fn fetch_by_id(&self, arxiv_id: &str) -> Result<Option<PaperMetadata>, ArxivError>;
    async fn search_by_title(
        &self,
        normalized_title: &str,
        limit: usize,
    ) -> Result<Vec<PaperMetadata>, ArxivError>;
}

#[async_trait]
impl PaperMetadataSource for ArxivClient {
    async fn fetch_by_id(&self, arxiv_id: &str) -> Result<Option<PaperMetadata>, ArxivError> {
        ArxivClient::fetch_by_id(self, arxiv_id).await
    }

    async fn search_by_title(
        &self,
        normalized_title: &str,
        limit: usize,
    ) -> Result<Vec<PaperMetadata>, ArxivError> {
        ArxivClient::search_by_title(self, normalized_title, limit).await
    }
}

#[async_trait]
pub trait PaperResolutionRateLimitStore: Send + Sync {
    async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError>;
}

#[async_trait]
impl PaperResolutionRateLimitStore for RateLimitRepository {
    async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
        RateLimitRepository::check(self, request).await
    }
}

#[async_trait]
pub trait PaperImportOperationStore: Send + Sync {
    async fn reserve(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        fingerprint: PaperImportFingerprint,
        normalized_arxiv_base: Option<&str>,
    ) -> Result<PaperImportReserveOutcome, DbError>;

    async fn read(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        fingerprint: PaperImportFingerprint,
    ) -> Result<PaperImportReadOutcome, DbError>;

    async fn finalize(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        fingerprint: PaperImportFingerprint,
        finalization: PaperImportFinalization,
    ) -> Result<PaperImportFinalizeOutcome, DbError>;
}

#[async_trait]
impl PaperImportOperationStore for PaperImportRepository {
    async fn reserve(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        fingerprint: PaperImportFingerprint,
        normalized_arxiv_base: Option<&str>,
    ) -> Result<PaperImportReserveOutcome, DbError> {
        PaperImportRepository::reserve(
            self,
            user_id,
            operation_id,
            input_kind,
            fingerprint,
            normalized_arxiv_base,
        )
        .await
    }

    async fn read(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        fingerprint: PaperImportFingerprint,
    ) -> Result<PaperImportReadOutcome, DbError> {
        PaperImportRepository::read(self, user_id, operation_id, input_kind, fingerprint).await
    }

    async fn finalize(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        input_kind: PaperImportInputKind,
        fingerprint: PaperImportFingerprint,
        finalization: PaperImportFinalization,
    ) -> Result<PaperImportFinalizeOutcome, DbError> {
        PaperImportRepository::finalize(
            self,
            user_id,
            operation_id,
            input_kind,
            fingerprint,
            finalization,
        )
        .await
    }
}

#[async_trait]
pub trait PaperImportLibrary: Send + Sync {
    async fn save_to_read(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        save_source_kind: LibrarySaveSourceKind,
    ) -> Result<LibraryMutationResult, LibraryServiceError>;
}

#[async_trait]
impl PaperImportLibrary for LibraryService {
    async fn save_to_read(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        operation_id: Uuid,
        save_source_kind: LibrarySaveSourceKind,
    ) -> Result<LibraryMutationResult, LibraryServiceError> {
        self.put_item_v2(
            user_id,
            paper_id,
            operation_id,
            LibraryState::Inbox,
            None,
            Some(save_source_kind),
        )
        .await
    }
}
