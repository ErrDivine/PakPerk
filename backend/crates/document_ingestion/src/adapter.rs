use async_trait::async_trait;
use domain::{NormalizedDocument, PaperId, ProcessingGeneration};
use thiserror::Error;

use crate::GrobidAdapter;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsePayload {
    GrobidTei(String),
    /// Strict, versioned normalized JSON emitted by a separately sandboxed
    /// Docling process. It is unavailable unless the experimental feature is
    /// compiled and explicitly enabled at runtime.
    DoclingJson(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseInput {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub arxiv_version: u32,
    pub payload: ParsePayload,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ParserSelection {
    #[default]
    Grobid,
    DoclingExperimental,
}

#[async_trait]
pub trait ScholarlyDocumentParser: Send + Sync {
    fn parser_id(&self) -> &'static str;
    fn parser_version(&self) -> String;
    async fn parse(&self, input: ParseInput) -> Result<NormalizedDocument, ParseError>;
}

pub fn default_parser(grobid_version: impl Into<String>) -> Result<GrobidAdapter, ParseError> {
    GrobidAdapter::new(grobid_version)
}

pub fn select_parser(
    selection: ParserSelection,
    parser_version: impl Into<String>,
    experimental_runtime_enabled: bool,
) -> Result<Box<dyn ScholarlyDocumentParser>, ParseError> {
    let parser_version = parser_version.into();
    match selection {
        ParserSelection::Grobid => Ok(Box::new(GrobidAdapter::new(parser_version)?)),
        ParserSelection::DoclingExperimental => {
            select_docling(parser_version, experimental_runtime_enabled)
        }
    }
}

#[cfg(feature = "docling-experimental")]
fn select_docling(
    parser_version: String,
    experimental_runtime_enabled: bool,
) -> Result<Box<dyn ScholarlyDocumentParser>, ParseError> {
    Ok(Box::new(crate::DoclingAdapter::new(
        parser_version,
        experimental_runtime_enabled,
    )?))
}

#[cfg(not(feature = "docling-experimental"))]
fn select_docling(
    _parser_version: String,
    _experimental_runtime_enabled: bool,
) -> Result<Box<dyn ScholarlyDocumentParser>, ParseError> {
    Err(ParseError::AdapterDisabled("docling"))
}

#[derive(Debug, Error)]
pub enum ParseError {
    #[error("parse input is invalid: {0}")]
    InvalidInput(&'static str),
    #[error("parser adapter `{0}` is disabled")]
    AdapterDisabled(&'static str),
    #[error("parser adapter `{0}` is unavailable")]
    AdapterUnavailable(&'static str),
    #[error("parser output is invalid")]
    InvalidOutput,
    #[error("GROBID TEI normalization failed")]
    Grobid(#[from] document_model::DocumentError),
    #[error("normalized document validation failed")]
    Validation(#[from] domain::DocumentValidationError),
}

pub(crate) fn validate_input_scope(input: &ParseInput) -> Result<(), ParseError> {
    if input.paper_id.is_nil() || input.generation <= 0 || input.arxiv_version == 0 {
        return Err(ParseError::InvalidInput("paper scope"));
    }
    Ok(())
}

pub(crate) fn valid_parser_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value == value.trim()
        && !value.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grobid_is_the_only_default() {
        let parser = default_parser("0.9.0").unwrap();
        assert_eq!(parser.parser_id(), "grobid");
        assert!(matches!(
            ParserSelection::default(),
            ParserSelection::Grobid
        ));
    }

    #[cfg(not(feature = "docling-experimental"))]
    #[test]
    fn docling_selection_fails_closed_without_feature() {
        let result = select_parser(ParserSelection::DoclingExperimental, "dev", true);
        assert!(matches!(
            result,
            Err(ParseError::AdapterDisabled("docling"))
        ));
    }
}
