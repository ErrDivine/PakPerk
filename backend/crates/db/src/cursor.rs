use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedCursor {
    pub published_at: DateTime<Utc>,
    pub paper_id: Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LibraryCursor {
    pub saved_at: DateTime<Utc>,
    pub paper_id: Uuid,
    /// The first page's committed revision fence. Every later page repeats it
    /// so pagination never absorbs a mutation that happened mid-walk.
    pub sync_revision: i64,
}

#[derive(Debug, Error)]
pub enum CursorError {
    #[error("cursor is not valid base64")]
    Base64(#[from] base64::DecodeError),
    #[error("cursor payload is invalid")]
    Json(#[from] serde_json::Error),
}

impl FeedCursor {
    #[must_use]
    pub fn encode(self) -> String {
        let bytes = serde_json::to_vec(&self).expect("FeedCursor is always serializable");
        URL_SAFE_NO_PAD.encode(bytes)
    }

    pub fn decode(value: &str) -> Result<Self, CursorError> {
        let bytes = URL_SAFE_NO_PAD.decode(value)?;
        Ok(serde_json::from_slice(&bytes)?)
    }
}

impl LibraryCursor {
    #[must_use]
    pub fn encode(self) -> String {
        let bytes = serde_json::to_vec(&self).expect("LibraryCursor is always serializable");
        URL_SAFE_NO_PAD.encode(bytes)
    }

    pub fn decode(value: &str) -> Result<Self, CursorError> {
        let bytes = URL_SAFE_NO_PAD.decode(value)?;
        Ok(serde_json::from_slice(&bytes)?)
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone as _;

    use super::*;

    #[test]
    fn opaque_cursor_round_trips() {
        let cursor = FeedCursor {
            published_at: Utc.with_ymd_and_hms(2026, 7, 29, 12, 13, 14).unwrap(),
            paper_id: Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba686").unwrap(),
        };
        let encoded = cursor.encode();

        assert!(!encoded.contains(['+', '/', '=']));
        assert_eq!(FeedCursor::decode(&encoded).unwrap(), cursor);
    }

    #[test]
    fn malformed_cursor_is_rejected() {
        assert!(FeedCursor::decode("not a cursor!").is_err());
    }

    #[test]
    fn library_cursor_round_trips() {
        let cursor = LibraryCursor {
            saved_at: Utc.with_ymd_and_hms(2026, 7, 31, 12, 13, 14).unwrap(),
            paper_id: Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba686").unwrap(),
            sync_revision: 42,
        };
        assert_eq!(LibraryCursor::decode(&cursor.encode()).unwrap(), cursor);
    }

    #[test]
    fn library_cursor_rejects_unknown_payload_fields() {
        let payload = URL_SAFE_NO_PAD.encode(
            br#"{"saved_at":"2026-07-31T12:13:14Z","paper_id":"0198fa17-3499-7a02-8406-846ab42ba686","sync_revision":42,"extra":true}"#,
        );
        assert!(LibraryCursor::decode(&payload).is_err());
    }
}
