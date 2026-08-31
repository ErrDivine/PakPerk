//! Transport-independent exact paper resolution.
//!
//! HTTP concerns stay in the API app. This crate owns strict import-input
//! classification and the reusable database/cache/arXiv orchestration needed
//! to turn a normalized arXiv identity into canonical Pakperk metadata.

mod error;
mod import;
mod input;
mod operation;
mod service;
mod store;

pub use error::{PaperImportError, PaperInputError, PaperResolutionError, PaperSearchError};
pub use import::PaperImportService;
pub use input::{ClassifiedPaperInput, PaperInputKind, classify_paper_input, parse_paper_input};
pub use operation::{PaperImportResult, PaperSearchCacheStatus, PaperSearchResult, ResolvedPaper};
pub use service::{PaperResolutionPolicy, PaperResolutionPolicyError, PaperResolutionService};
pub use store::{
    PaperImportLibrary, PaperImportOperationStore, PaperMetadataSource,
    PaperResolutionRateLimitStore, PaperResolutionStore,
};
