use arxiv_client::{NormalizedArxivId, normalize_arxiv_id};
use url::Url;

use crate::PaperInputError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperInputKind {
    ArxivId,
    ArxivUrl,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClassifiedPaperInput {
    pub kind: PaperInputKind,
    pub arxiv_id: NormalizedArxivId,
}

/// Classify an obvious URL as an arXiv URL and all other input as a bare ID.
/// This does not perform I/O and never returns a caller-controlled URL.
pub fn classify_paper_input(input: &str) -> Result<ClassifiedPaperInput, PaperInputError> {
    let kind = if input.trim().contains("://") {
        PaperInputKind::ArxivUrl
    } else {
        PaperInputKind::ArxivId
    };
    let arxiv_id = parse_paper_input(kind, input)?;
    Ok(ClassifiedPaperInput { kind, arxiv_id })
}

/// Strictly parse the input form selected by the caller.
///
/// URL parsing intentionally accepts only the canonical `https://arxiv.org`
/// host and `/abs/` or `/pdf/` paths. `export.arxiv.org` is not an accepted
/// user-input host in this first slice; it remains a trusted outbound API host
/// configured inside `arxiv_client`.
pub fn parse_paper_input(
    kind: PaperInputKind,
    input: &str,
) -> Result<NormalizedArxivId, PaperInputError> {
    match kind {
        PaperInputKind::ArxivId => parse_bare_arxiv_id(input),
        PaperInputKind::ArxivUrl => parse_arxiv_url(input),
    }
}

fn parse_bare_arxiv_id(input: &str) -> Result<NormalizedArxivId, PaperInputError> {
    let candidate = input.trim();
    if candidate.is_empty()
        || candidate.contains("://")
        || candidate.contains(['?', '#', '%', '\\'])
        || candidate.strip_suffix(".pdf").is_some()
    {
        return Err(PaperInputError::InvalidArxivId);
    }
    normalize_arxiv_id(candidate).map_err(|_| PaperInputError::InvalidArxivId)
}

fn parse_arxiv_url(input: &str) -> Result<NormalizedArxivId, PaperInputError> {
    let candidate = input.trim();
    if candidate.is_empty() || candidate.contains(['%', '\\']) {
        return Err(PaperInputError::UnsupportedPaperUrl);
    }

    let (scheme, remainder) = candidate
        .split_once("://")
        .ok_or(PaperInputError::UnsupportedPaperUrl)?;
    if !scheme.eq_ignore_ascii_case("https") {
        return Err(PaperInputError::UnsupportedPaperUrl);
    }
    let authority = remainder
        .split(['/', '?', '#'])
        .next()
        .ok_or(PaperInputError::UnsupportedPaperUrl)?;
    if !authority.eq_ignore_ascii_case("arxiv.org") {
        return Err(PaperInputError::UnsupportedPaperUrl);
    }
    let raw_path = remainder
        .strip_prefix(authority)
        .unwrap_or_default()
        .split(['?', '#'])
        .next()
        .unwrap_or_default();
    if raw_path
        .split('/')
        .any(|segment| segment == "." || segment == "..")
    {
        return Err(PaperInputError::UnsupportedPaperUrl);
    }

    let url = Url::parse(candidate).map_err(|_| PaperInputError::UnsupportedPaperUrl)?;
    if url.scheme() != "https"
        || url.host_str() != Some("arxiv.org")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(PaperInputError::UnsupportedPaperUrl);
    }

    let path = url.path();
    let identifier = if let Some(identifier) = path.strip_prefix("/abs/") {
        if identifier.strip_suffix(".pdf").is_some() {
            return Err(PaperInputError::UnsupportedPaperUrl);
        }
        identifier
    } else if let Some(identifier) = path.strip_prefix("/pdf/") {
        identifier.strip_suffix(".pdf").unwrap_or(identifier)
    } else {
        return Err(PaperInputError::UnsupportedPaperUrl);
    };
    if identifier.is_empty() || identifier.ends_with('/') {
        return Err(PaperInputError::UnsupportedPaperUrl);
    }

    normalize_arxiv_id(identifier).map_err(|_| PaperInputError::UnsupportedPaperUrl)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_id(input: &str, expected_base: &str, expected_version: Option<u32>) {
        let parsed = parse_paper_input(PaperInputKind::ArxivId, input).unwrap();
        assert_eq!(parsed.base_id, expected_base);
        assert_eq!(parsed.version, expected_version);
    }

    fn assert_url(input: &str, expected_base: &str, expected_version: Option<u32>) {
        let parsed = parse_paper_input(PaperInputKind::ArxivUrl, input).unwrap();
        assert_eq!(parsed.base_id, expected_base);
        assert_eq!(parsed.version, expected_version);
    }

    #[test]
    fn accepts_modern_and_legacy_bare_identifiers() {
        assert_id("2401.12345", "2401.12345", None);
        assert_id(" arXiv:2401.12345v2 ", "2401.12345", Some(2));
        assert_id("hep-th/9901001v3", "hep-th/9901001", Some(3));
    }

    #[test]
    fn accepts_only_canonical_abs_and_pdf_urls() {
        assert_url("https://arxiv.org/abs/2401.12345v2", "2401.12345", Some(2));
        assert_url("https://arxiv.org/pdf/2401.12345v2", "2401.12345", Some(2));
        assert_url(
            "https://arxiv.org/pdf/2401.12345v2.pdf",
            "2401.12345",
            Some(2),
        );
        assert_url(
            "https://arxiv.org/abs/hep-th/9901001v3",
            "hep-th/9901001",
            Some(3),
        );
    }

    #[test]
    fn rejects_noncanonical_hosts_and_destinations() {
        for input in [
            "http://arxiv.org/abs/2401.12345",
            "https://www.arxiv.org/abs/2401.12345",
            "https://export.arxiv.org/abs/2401.12345",
            "https://arxiv.org.evil.example/abs/2401.12345",
            "https://evil.example/arxiv.org/abs/2401.12345",
            "https://127.0.0.1/abs/2401.12345",
            "https://arxiv.org:8443/abs/2401.12345",
            "https://user@arxiv.org/abs/2401.12345",
            "https://example.com/paper.pdf",
        ] {
            assert_eq!(
                parse_paper_input(PaperInputKind::ArxivUrl, input),
                Err(PaperInputError::UnsupportedPaperUrl),
                "unexpectedly accepted {input}",
            );
        }
    }

    #[test]
    fn rejects_queries_fragments_encoded_paths_and_traversal() {
        for input in [
            "https://arxiv.org/abs/2401.12345?download=1",
            "https://arxiv.org/abs/2401.12345#page=2",
            "https://arxiv.org/abs/2401%2E12345",
            "https://arxiv.org/abs/../2401.12345",
            "https://arxiv.org/abs/%2e%2e/2401.12345",
            "https://arxiv.org/pdf/2401.12345.pdf/extra",
            "https://arxiv.org/abs/2401.12345.pdf",
            "https://arxiv.org/search/2401.12345",
        ] {
            assert_eq!(
                parse_paper_input(PaperInputKind::ArxivUrl, input),
                Err(PaperInputError::UnsupportedPaperUrl),
                "unexpectedly accepted {input}",
            );
        }
    }

    #[test]
    fn bare_id_mode_never_accepts_url_or_url_suffix_syntax() {
        for input in [
            "https://arxiv.org/abs/2401.12345",
            "2401.12345?download=1",
            "2401.12345#fragment",
            "2401.12345.pdf",
            "2401%2E12345",
            "2401.12345v0",
        ] {
            assert_eq!(
                parse_paper_input(PaperInputKind::ArxivId, input),
                Err(PaperInputError::InvalidArxivId),
                "unexpectedly accepted {input}",
            );
        }
    }

    #[test]
    fn classifier_returns_only_a_normalized_identity() {
        let classified = classify_paper_input("https://arxiv.org/pdf/2401.12345v4.pdf").unwrap();
        assert_eq!(classified.kind, PaperInputKind::ArxivUrl);
        assert_eq!(classified.arxiv_id.as_query_id(), "2401.12345v4");

        let classified = classify_paper_input("hep-th/9901001").unwrap();
        assert_eq!(classified.kind, PaperInputKind::ArxivId);
        assert_eq!(classified.arxiv_id.as_query_id(), "hep-th/9901001");
    }
}
