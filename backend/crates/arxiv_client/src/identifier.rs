use std::sync::OnceLock;

use regex::Regex;
use url::Url;

use crate::ArxivError;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NormalizedArxivId {
    pub base_id: String,
    /// Missing when the caller supplied an unversioned identifier.
    pub version: Option<u32>,
}

impl NormalizedArxivId {
    #[must_use]
    pub fn as_query_id(&self) -> String {
        self.version.map_or_else(
            || self.base_id.clone(),
            |version| format!("{}v{version}", self.base_id),
        )
    }
}

/// Normalize a modern or legacy arXiv identifier, including common `abs` and
/// `pdf` URLs. The function rejects URLs on non-arXiv hosts.
pub fn normalize_arxiv_id(input: &str) -> Result<NormalizedArxivId, ArxivError> {
    let mut candidate = input.trim();
    if let Some(without_prefix) = candidate.strip_prefix("arXiv:") {
        candidate = without_prefix.trim();
    } else if let Some(without_prefix) = candidate.strip_prefix("arxiv:") {
        candidate = without_prefix.trim();
    }

    let owned;
    if candidate.starts_with("http://") || candidate.starts_with("https://") {
        let url =
            Url::parse(candidate).map_err(|_| ArxivError::InvalidIdentifier(input.to_owned()))?;
        let host = url
            .host_str()
            .ok_or_else(|| ArxivError::InvalidIdentifier(input.to_owned()))?
            .to_ascii_lowercase();
        if host != "arxiv.org" && host != "www.arxiv.org" && host != "export.arxiv.org" {
            return Err(ArxivError::InvalidIdentifier(input.to_owned()));
        }
        let path = url.path().trim_matches('/');
        owned = path
            .strip_prefix("abs/")
            .or_else(|| path.strip_prefix("pdf/"))
            .unwrap_or(path)
            .strip_suffix(".pdf")
            .unwrap_or(
                path.strip_prefix("abs/")
                    .or_else(|| path.strip_prefix("pdf/"))
                    .unwrap_or(path),
            )
            .to_owned();
        candidate = &owned;
    }

    let candidate = candidate
        .split(['?', '#'])
        .next()
        .unwrap_or(candidate)
        .trim()
        .trim_end_matches(".pdf");

    let captures = identifier_regex()
        .captures(candidate)
        .ok_or_else(|| ArxivError::InvalidIdentifier(input.to_owned()))?;
    let base_id = captures
        .name("modern")
        .or_else(|| captures.name("legacy"))
        .expect("identifier expression always captures a base")
        .as_str()
        .to_owned();
    let version = captures
        .name("version")
        .map(|value| value.as_str().parse::<u32>())
        .transpose()
        .map_err(|_| ArxivError::InvalidIdentifier(input.to_owned()))?;

    if version == Some(0) {
        return Err(ArxivError::InvalidIdentifier(input.to_owned()));
    }

    Ok(NormalizedArxivId { base_id, version })
}

fn identifier_regex() -> &'static Regex {
    static IDENTIFIER: OnceLock<Regex> = OnceLock::new();
    IDENTIFIER.get_or_init(|| {
        Regex::new(
            r"^(?:(?P<modern>\d{4}\.\d{4,5})|(?P<legacy>[A-Za-z][A-Za-z0-9.-]*/\d{7}))(?:v(?P<version>\d+))?$",
        )
        .expect("arXiv identifier regex is valid")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_modern_identifier_and_version() {
        assert_eq!(
            normalize_arxiv_id(" arXiv:2401.12345v2 ").unwrap(),
            NormalizedArxivId {
                base_id: "2401.12345".into(),
                version: Some(2),
            }
        );
    }

    #[test]
    fn normalizes_legacy_pdf_url() {
        assert_eq!(
            normalize_arxiv_id("https://arxiv.org/pdf/hep-th/9901001v3.pdf").unwrap(),
            NormalizedArxivId {
                base_id: "hep-th/9901001".into(),
                version: Some(3),
            }
        );
    }

    #[test]
    fn rejects_non_arxiv_url_and_bad_versions() {
        assert!(normalize_arxiv_id("https://example.com/abs/2401.12345").is_err());
        assert!(normalize_arxiv_id("2401.12345v0").is_err());
        assert!(normalize_arxiv_id("../../etc/passwd").is_err());
    }
}
