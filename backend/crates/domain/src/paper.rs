use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use url::Url;
use uuid::Uuid;

use crate::Capabilities;

pub type PaperId = Uuid;
pub type ProcessingGeneration = i32;

/// A validated split arXiv identifier. Validation and normalization live in
/// `arxiv_client`; this type is the stable representation used after validation.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ArxivIdentifier {
    pub base_id: String,
    pub version: u32,
}

impl ArxivIdentifier {
    #[must_use]
    pub fn versioned(&self) -> String {
        format!("{}v{}", self.base_id, self.version)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Author {
    pub name: String,
}

impl From<String> for Author {
    fn from(name: String) -> Self {
        Self { name }
    }
}

/// Full metadata persisted for one latest-known arXiv paper version.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperMetadata {
    pub arxiv_id: ArxivIdentifier,
    pub title: String,
    pub abstract_text: String,
    pub authors: Vec<Author>,
    pub primary_category: String,
    pub categories: Vec<String>,
    pub published_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub abs_url: Url,
    pub pdf_url: Url,
    pub doi: Option<String>,
    pub journal_reference: Option<String>,
    pub comment: Option<String>,
    pub license_uri: Option<Url>,
    pub metadata_fetched_at: DateTime<Utc>,
}

/// Full persisted paper record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Paper {
    pub id: PaperId,
    #[serde(flatten)]
    pub metadata: PaperMetadata,
}

/// Metadata exposed in feed and paper-summary API responses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperSummary {
    pub paper_id: PaperId,
    /// Latest versioned identifier, for example `2401.12345v2`.
    pub arxiv_id: String,
    pub title: String,
    #[serde(rename = "abstract")]
    pub abstract_text: String,
    pub authors: Vec<String>,
    pub primary_category: String,
    pub categories: Vec<String>,
    pub published_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub abs_url: Url,
    pub pdf_url: Url,
    pub capabilities: Capabilities,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FeedPage {
    pub items: Vec<PaperSummary>,
    pub next_cursor: Option<String>,
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    #[test]
    fn feed_summary_uses_public_abstract_field_name() {
        let now = Utc.with_ymd_and_hms(2026, 7, 29, 12, 0, 0).unwrap();
        let summary = PaperSummary {
            paper_id: Uuid::new_v4(),
            arxiv_id: "2401.12345v2".into(),
            title: "Fixture".into(),
            abstract_text: "Readable abstract".into(),
            authors: vec!["Ada Lovelace".into()],
            primary_category: "cs.AI".into(),
            categories: vec!["cs.AI".into()],
            published_at: now,
            updated_at: now,
            abs_url: Url::parse("https://arxiv.org/abs/2401.12345v2").unwrap(),
            pdf_url: Url::parse("https://arxiv.org/pdf/2401.12345v2").unwrap(),
            capabilities: Capabilities::metadata_only(),
        };
        let json = serde_json::to_value(summary).unwrap();
        assert_eq!(json["abstract"], "Readable abstract");
        assert!(json.get("abstract_text").is_none());
    }
}
