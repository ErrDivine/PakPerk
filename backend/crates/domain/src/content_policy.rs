use std::{fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use url::Url;

/// Controls whether full-text-derived artifacts may be generated or served.
///
/// The policy is deliberately evaluated both when a worker creates artifacts
/// and when the API serves them. Persisted prototype artifacts therefore
/// cannot bypass a later strict-mode deployment.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FulltextPolicy {
    #[default]
    Prototype,
    Strict,
}

impl FulltextPolicy {
    /// Returns whether derived content may be used for this recorded license.
    ///
    /// Strict mode fails closed for absent, malformed, unrecognized,
    /// non-commercial, and no-derivatives licenses.
    #[must_use]
    pub fn allows_derived_content(self, license_uri: Option<&Url>) -> bool {
        matches!(self, Self::Prototype) || license_uri.is_some_and(is_permissive_fulltext_license)
    }
}

impl FromStr for FulltextPolicy {
    type Err = FulltextPolicyParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "prototype" => Ok(Self::Prototype),
            "strict" => Ok(Self::Strict),
            _ => Err(FulltextPolicyParseError(value.to_owned())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FulltextPolicyParseError(String);

impl fmt::Display for FulltextPolicyParseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "FULLTEXT_POLICY must be prototype or strict, got `{}`",
            self.0
        )
    }
}

impl std::error::Error for FulltextPolicyParseError {}

/// Recognizes the explicit licenses that Pakperk's strict mode supports.
///
/// Host and path components are checked structurally. A URI that merely
/// contains a Creative Commons URL in its query string is not sufficient.
#[must_use]
pub fn is_permissive_fulltext_license(uri: &Url) -> bool {
    if !matches!(uri.scheme(), "http" | "https") {
        return false;
    }
    if !matches!(
        uri.host_str().map(str::to_ascii_lowercase),
        Some(host) if host == "creativecommons.org" || host == "www.creativecommons.org"
    ) {
        return false;
    }

    let path = uri.path().to_ascii_lowercase();
    path.starts_with("/licenses/by/")
        || path.starts_with("/licenses/by-sa/")
        || path.starts_with("/publicdomain/zero/")
        || path.starts_with("/publicdomain/mark/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_policy_names_and_rejects_unknown_values() {
        assert_eq!(
            "prototype".parse::<FulltextPolicy>().unwrap(),
            FulltextPolicy::Prototype
        );
        assert_eq!(
            " STRICT ".parse::<FulltextPolicy>().unwrap(),
            FulltextPolicy::Strict
        );
        assert!("public".parse::<FulltextPolicy>().is_err());
    }

    #[test]
    fn strict_mode_accepts_only_explicit_supported_licenses() {
        let cc_by = Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap();
        let cc_by_sa = Url::parse("http://creativecommons.org/licenses/by-sa/4.0/").unwrap();
        let cc_zero = Url::parse("https://creativecommons.org/publicdomain/zero/1.0/").unwrap();
        let non_commercial =
            Url::parse("https://creativecommons.org/licenses/by-nc-sa/4.0/").unwrap();
        let no_derivatives =
            Url::parse("https://creativecommons.org/licenses/by-nc-nd/4.0/").unwrap();
        let arxiv = Url::parse("http://arxiv.org/licenses/nonexclusive-distrib/1.0/").unwrap();
        let spoofed = Url::parse(
            "https://example.test/?license=https://creativecommons.org/licenses/by/4.0/",
        )
        .unwrap();

        let strict = FulltextPolicy::Strict;
        assert!(strict.allows_derived_content(Some(&cc_by)));
        assert!(strict.allows_derived_content(Some(&cc_by_sa)));
        assert!(strict.allows_derived_content(Some(&cc_zero)));
        assert!(!strict.allows_derived_content(Some(&non_commercial)));
        assert!(!strict.allows_derived_content(Some(&no_derivatives)));
        assert!(!strict.allows_derived_content(Some(&arxiv)));
        assert!(!strict.allows_derived_content(Some(&spoofed)));
        assert!(!strict.allows_derived_content(None));
    }

    #[test]
    fn prototype_mode_allows_missing_or_unrecognized_licenses() {
        let arxiv = Url::parse("http://arxiv.org/licenses/nonexclusive-distrib/1.0/").unwrap();
        assert!(FulltextPolicy::Prototype.allows_derived_content(None));
        assert!(FulltextPolicy::Prototype.allows_derived_content(Some(&arxiv)));
    }
}
