//! GROBID TEI normalization.
//!
//! XML is parsed into a deliberately small namespace-local tree and then
//! normalized into provider- and persistence-neutral domain records. Limits
//! protect workers from pathologically deep or large untrusted documents.

mod introduction;
mod parser;
mod text;

pub use introduction::{DetectedIntroduction, detect_introduction};
pub use parser::{
    ParseLimits, ParsedTeiDocument, ParsedTeiEquation, ParsedTeiFigure, ParsedTeiObjectKind,
    ParsedTeiObjectReference, ParsedTeiTable, ParsedTeiTableCell, classify_section, parse_tei,
    parse_tei_document, parse_tei_document_with_limits, parse_tei_with_limits,
};
pub use text::normalize_text;

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DocumentError {
    #[error("TEI document is empty")]
    EmptyDocument,
    #[error("TEI document exceeds {maximum_bytes} bytes")]
    DocumentTooLarge { maximum_bytes: usize },
    #[error("TEI nesting exceeds {maximum_depth} levels")]
    TooDeep { maximum_depth: usize },
    #[error("TEI contains more than {maximum_nodes} elements")]
    TooManyNodes { maximum_nodes: usize },
    #[error("invalid TEI XML: {0}")]
    InvalidXml(String),
    #[error("TEI does not contain a body")]
    MissingBody,
    #[error("no trustworthy introduction section was detected")]
    IntroductionNotFound,
}
