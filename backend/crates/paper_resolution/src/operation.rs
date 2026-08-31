use domain::{LibraryItem, PaperMetadata, PaperSummary};
use url::Url;
use uuid::Uuid;

/// Canonical metadata plus the policy input needed by transport adapters.
/// The service deliberately does not know how an HTTP response masks derived
/// capabilities under a deployment's full-text policy.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedPaper {
    pub summary: PaperSummary,
    pub license_uri: Option<Url>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperSearchCacheStatus {
    Hit,
    Miss,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PaperSearchResult {
    pub query_id: Uuid,
    pub normalized_query: String,
    pub candidates: Vec<PaperMetadata>,
    pub cache_status: PaperSearchCacheStatus,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PaperImportResult {
    pub input_kind: crate::PaperInputKind,
    pub canonical_arxiv_id: String,
    pub item: LibraryItem,
    pub paper: PaperSummary,
    pub license_uri: Option<Url>,
    pub replayed: bool,
}
