//! Conservative arXiv integration.
//!
//! A standalone [`ArxivClient`] spaces starts through one process-wide gate.
//! Multi-process deployments should reserve every request through shared
//! storage and construct with [`ArxivClient::new_with_external_gate`], which
//! disables local delay and hidden retries so the HTTP start stays adjacent to
//! its cross-process reservation. Atom parsing does not depend on a namespace
//! prefix spelling.

mod atom;
mod client;
mod identifier;
mod query;
mod rate_gate;

pub use atom::parse_atom_feed;
pub use client::{ArxivClient, ArxivClientConfig, DownloadedPdf, DownloadedPdfFile};
pub use identifier::{NormalizedArxivId, normalize_arxiv_id};
pub use query::{
    MAX_EXACT_IDS_PER_REQUEST, build_category_query, build_exact_id_query, build_exact_ids_query,
    build_title_query,
};
pub use rate_gate::RateGate;

use std::time::Duration;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ArxivError {
    #[error("invalid arXiv identifier: {0}")]
    InvalidIdentifier(String),
    #[error("invalid arXiv category: {0}")]
    InvalidCategory(String),
    #[error("invalid arXiv client configuration: {0}")]
    InvalidConfiguration(String),
    #[error("could not construct arXiv URL: {0}")]
    Url(#[from] url::ParseError),
    #[error("arXiv request failed")]
    Transport(#[from] reqwest::Error),
    #[error("arXiv returned HTTP {status}")]
    HttpStatus {
        status: reqwest::StatusCode,
        retry_after: Option<Duration>,
    },
    #[error("arXiv response XML is invalid: {0}")]
    Xml(String),
    #[error("arXiv entry is missing required field `{0}`")]
    MissingField(&'static str),
    #[error("arXiv timestamp is invalid: {0}")]
    InvalidTimestamp(String),
    #[error("arXiv returned an unsafe or unexpected URL")]
    UnsafeUrl,
    #[error("PDF exceeds configured limit of {maximum_bytes} bytes")]
    PdfTooLarge { maximum_bytes: usize },
    #[error("Atom response exceeds configured limit of {maximum_bytes} bytes")]
    AtomTooLarge { maximum_bytes: usize },
    #[error("could not create or write the temporary PDF")]
    TemporaryFile(#[from] std::io::Error),
}

impl ArxivError {
    /// Cooldown that should be published to the cross-process request gate.
    /// A 429 without `Retry-After` receives a conservative default instead of
    /// allowing every process to retry again after only the normal 3 seconds.
    #[must_use]
    pub fn shared_cooldown(&self) -> Option<Duration> {
        match self {
            Self::HttpStatus {
                status,
                retry_after,
            } if *status == reqwest::StatusCode::TOO_MANY_REQUESTS => {
                Some(retry_after.unwrap_or(Duration::from_secs(60)))
            }
            Self::HttpStatus {
                status,
                retry_after: Some(retry_after),
            } if status.is_server_error() => Some(*retry_after),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limit_errors_recommend_a_shared_cooldown() {
        let explicit = ArxivError::HttpStatus {
            status: reqwest::StatusCode::TOO_MANY_REQUESTS,
            retry_after: Some(Duration::from_secs(17)),
        };
        assert_eq!(explicit.shared_cooldown(), Some(Duration::from_secs(17)));
        let missing = ArxivError::HttpStatus {
            status: reqwest::StatusCode::TOO_MANY_REQUESTS,
            retry_after: None,
        };
        assert_eq!(missing.shared_cooldown(), Some(Duration::from_secs(60)));
        let permanent = ArxivError::HttpStatus {
            status: reqwest::StatusCode::NOT_FOUND,
            retry_after: Some(Duration::from_secs(20)),
        };
        assert_eq!(permanent.shared_cooldown(), None);
    }
}
