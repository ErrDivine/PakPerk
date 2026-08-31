use arxiv_client::ArxivError;
use db::DbError;
use library::LibraryServiceError;
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum PaperInputError {
    #[error("the arXiv identifier is invalid")]
    InvalidArxivId,
    #[error("the paper URL is not an accepted arXiv URL")]
    UnsupportedPaperUrl,
}

#[derive(Debug, Error)]
pub enum PaperResolutionError {
    #[error("the arXiv identifier is invalid")]
    InvalidArxivId,
    #[error("the requested paper is not in the metadata cache")]
    NotFound,
    #[error("paper resolution storage is unavailable")]
    Storage(#[from] DbError),
    #[error("arXiv metadata is temporarily unavailable")]
    ArxivUnavailable {
        #[source]
        error: ArxivError,
        cooldown_publication_error: Option<DbError>,
    },
}

#[derive(Debug, Error)]
pub enum PaperSearchError {
    #[error("the normalized paper title is shorter than the configured minimum")]
    QueryTooShort,
    #[error("the paper title query is invalid")]
    InvalidQuery,
    #[error("the requested paper search result limit is invalid")]
    InvalidLimit,
    #[error("paper search is rate limited; retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("paper search storage is unavailable")]
    Storage(#[from] DbError),
    #[error("paper search rate-limit policy is invalid")]
    InvalidRateLimitPolicy,
    #[error("arXiv title search is temporarily unavailable")]
    ArxivUnavailable {
        #[source]
        error: ArxivError,
        cooldown_publication_error: Option<DbError>,
    },
}

#[derive(Debug, Error)]
pub enum PaperImportError {
    #[error("paper import operation ID must not be nil")]
    InvalidOperationId,
    #[error(transparent)]
    InvalidInput(#[from] PaperInputError),
    #[error("paper import provenance does not match the canonical input form")]
    InvalidSaveSource,
    #[error("paper import is rate limited; retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("paper import operation conflicts with an existing intent")]
    OperationConflict,
    #[error("account was not found")]
    AccountNotFound,
    #[error("account is suspended")]
    Suspended,
    #[error("account deletion is pending")]
    DeletionPending,
    #[error("account is deleted")]
    Deleted,
    #[error("the requested arXiv paper was not found")]
    NotFound,
    #[error("paper import storage is unavailable")]
    Storage(#[from] DbError),
    #[error("paper resolution failed during import")]
    Resolution(#[source] PaperResolutionError),
    #[error("paper import state is inconsistent")]
    InconsistentState,
    #[error("paper import rate-limit policy is invalid")]
    InvalidRateLimitPolicy,
    #[error("library save failed")]
    Library(#[source] LibraryServiceError),
}

impl PaperSearchError {
    #[must_use]
    pub const fn cooldown_publication_error(&self) -> Option<&DbError> {
        match self {
            Self::ArxivUnavailable {
                cooldown_publication_error,
                ..
            } => cooldown_publication_error.as_ref(),
            _ => None,
        }
    }
}

impl PaperResolutionError {
    #[must_use]
    pub const fn arxiv_error(&self) -> Option<&ArxivError> {
        match self {
            Self::ArxivUnavailable { error, .. } => Some(error),
            _ => None,
        }
    }

    #[must_use]
    pub const fn cooldown_publication_error(&self) -> Option<&DbError> {
        match self {
            Self::ArxivUnavailable {
                cooldown_publication_error,
                ..
            } => cooldown_publication_error.as_ref(),
            _ => None,
        }
    }
}
