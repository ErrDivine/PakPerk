use std::sync::OnceLock;

use regex::Regex;
use url::Url;

use crate::{ArxivError, NormalizedArxivId};

pub const MAX_EXACT_IDS_PER_REQUEST: usize = 50;

pub fn build_category_query(
    base_url: &Url,
    categories: &[String],
    limit: usize,
) -> Result<Url, ArxivError> {
    validate_limit(limit)?;
    if categories.is_empty() {
        return Err(ArxivError::InvalidCategory(
            "at least one category is required".into(),
        ));
    }
    for category in categories {
        if !category_regex().is_match(category) {
            return Err(ArxivError::InvalidCategory(category.clone()));
        }
    }
    let search_query = categories
        .iter()
        .map(|category| format!("cat:{category}"))
        .collect::<Vec<_>>()
        .join(" OR ");
    Ok(with_query(
        base_url,
        &[
            ("search_query", search_query),
            ("start", "0".into()),
            ("max_results", limit.to_string()),
            ("sortBy", "submittedDate".into()),
            ("sortOrder", "descending".into()),
        ],
    ))
}

pub fn build_exact_id_query(base_url: &Url, id: &NormalizedArxivId) -> Url {
    build_exact_ids_query(base_url, std::slice::from_ref(id))
        .expect("a single normalized identifier is a valid batch")
}

pub fn build_exact_ids_query(base_url: &Url, ids: &[NormalizedArxivId]) -> Result<Url, ArxivError> {
    if ids.is_empty() || ids.len() > MAX_EXACT_IDS_PER_REQUEST {
        return Err(ArxivError::InvalidConfiguration(format!(
            "exact arXiv ID batches must contain 1 to {MAX_EXACT_IDS_PER_REQUEST} identifiers"
        )));
    }
    let id_list = ids
        .iter()
        .map(NormalizedArxivId::as_query_id)
        .collect::<Vec<_>>()
        .join(",");
    Ok(with_query(
        base_url,
        &[("id_list", id_list), ("max_results", ids.len().to_string())],
    ))
}

pub fn build_title_query(base_url: &Url, title: &str, limit: usize) -> Result<Url, ArxivError> {
    validate_limit(limit)?;
    let normalized = title.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() || normalized.len() > 500 {
        return Err(ArxivError::InvalidConfiguration(
            "title query must contain 1 to 500 characters".into(),
        ));
    }
    // Quoting constrains arXiv's field query. `Url` performs all escaping; raw
    // user text is never concatenated into a URL.
    let query = format!("ti:\"{}\"", normalized.replace('"', " "));
    Ok(with_query(
        base_url,
        &[
            ("search_query", query),
            ("start", "0".into()),
            ("max_results", limit.to_string()),
            ("sortBy", "relevance".into()),
            ("sortOrder", "descending".into()),
        ],
    ))
}

fn validate_limit(limit: usize) -> Result<(), ArxivError> {
    if !(1..=2_000).contains(&limit) {
        return Err(ArxivError::InvalidConfiguration(
            "arXiv query limit must be between 1 and 2000".into(),
        ));
    }
    Ok(())
}

fn with_query(base_url: &Url, values: &[(&str, String)]) -> Url {
    let mut url = base_url.clone();
    {
        let mut pairs = url.query_pairs_mut();
        pairs.clear();
        pairs.extend_pairs(values.iter().map(|(key, value)| (*key, value.as_str())));
    }
    url
}

fn category_regex() -> &'static Regex {
    static CATEGORY: OnceLock<Regex> = OnceLock::new();
    CATEGORY.get_or_init(|| {
        Regex::new(r"^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)?$")
            .expect("category regex is valid")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_encoded_category_query() {
        let url = build_category_query(
            &Url::parse("https://export.arxiv.org/api/query").unwrap(),
            &["cs.AI".into(), "cs.CL".into()],
            100,
        )
        .unwrap();
        let pairs = url
            .query_pairs()
            .collect::<std::collections::HashMap<_, _>>();
        assert_eq!(pairs["search_query"], "cat:cs.AI OR cat:cs.CL");
        assert_eq!(pairs["sortBy"], "submittedDate");
        assert_eq!(pairs["max_results"], "100");
    }

    #[test]
    fn rejects_query_injection_as_category() {
        assert!(
            build_category_query(
                &Url::parse("https://export.arxiv.org/api/query").unwrap(),
                &["cs.AI OR all:*".into()],
                10,
            )
            .is_err()
        );
    }

    #[test]
    fn rejects_unbounded_result_limits() {
        assert!(
            build_category_query(
                &Url::parse("https://export.arxiv.org/api/query").unwrap(),
                &["cs.AI".into()],
                0,
            )
            .is_err()
        );
        assert!(
            build_title_query(
                &Url::parse("https://export.arxiv.org/api/query").unwrap(),
                "safe title",
                2_001,
            )
            .is_err()
        );
    }

    #[test]
    fn builds_bounded_exact_id_batches() {
        let ids = [
            NormalizedArxivId {
                base_id: "2401.12345".to_owned(),
                version: Some(2),
            },
            NormalizedArxivId {
                base_id: "hep-th/9901001".to_owned(),
                version: None,
            },
        ];
        let url = build_exact_ids_query(
            &Url::parse("https://export.arxiv.org/api/query").unwrap(),
            &ids,
        )
        .unwrap();
        let pairs = url
            .query_pairs()
            .collect::<std::collections::HashMap<_, _>>();
        assert_eq!(pairs["id_list"], "2401.12345v2,hep-th/9901001");
        assert_eq!(pairs["max_results"], "2");
        assert!(
            build_exact_ids_query(
                &Url::parse("https://export.arxiv.org/api/query").unwrap(),
                &[]
            )
            .is_err()
        );
    }
}
